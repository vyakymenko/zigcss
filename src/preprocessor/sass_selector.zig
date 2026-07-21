//! Bounded selector-value parsing for the private native Sass evaluator.
//! This is deliberately independent of provider runtimes and remains internal
//! until the native Sass adapter passes its complete conformance gate.

const std = @import("std");

pub const Limits = struct {
    max_selectors: usize = 200_000,
    max_bytes: usize = 10 * 1024 * 1024,
    max_complex_components: usize = 200_000,
    max_temporary_bytes: usize = 10 * 1024 * 1024,
    max_relation_operations: u64 = 100_000_000,
    max_normalization_operations: u64 = 100_000_000,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidSelector,
    SelectorLimitExceeded,
    UnsupportedSelectorRelation,
    UnsupportedSelectorExtension,
    UnsupportedSelectorUnification,
};

pub const SelectorList = struct {
    allocator: std.mem.Allocator,
    items: [][]u8,
    selector_count: usize,

    pub fn deinit(self: *SelectorList) void {
        for (self.items) |item| self.allocator.free(item);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

const maximum_selector_list_pseudo_depth = 64;

const NormalizationContext = struct {
    limits: Limits,
    selector_count: *usize,
    operations: *u64,
    temporary_bytes: *usize,
    depth: usize = 0,

    fn reserveSelector(self: *NormalizationContext) Error!void {
        if (self.selector_count.* >= self.limits.max_selectors) {
            return error.SelectorLimitExceeded;
        }
        self.selector_count.* += 1;
    }

    fn consume(self: *NormalizationContext, count: u64) Error!void {
        const next = std.math.add(u64, self.operations.*, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_normalization_operations) {
            return error.SelectorLimitExceeded;
        }
        self.operations.* = next;
    }

    fn reserveTemporary(self: *NormalizationContext, count: usize) Error!void {
        const next = std.math.add(usize, self.temporary_bytes.*, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_temporary_bytes) {
            return error.SelectorLimitExceeded;
        }
        self.temporary_bytes.* = next;
    }

    fn releaseTemporary(self: *NormalizationContext, count: usize) void {
        std.debug.assert(self.temporary_bytes.* >= count);
        self.temporary_bytes.* -= count;
    }

    fn enterSelectorListPseudo(self: *NormalizationContext) Error!void {
        if (self.depth >= maximum_selector_list_pseudo_depth) {
            return error.SelectorLimitExceeded;
        }
        self.depth += 1;
    }

    fn leaveSelectorListPseudo(self: *NormalizationContext) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    allow_parent: bool = false,
    items: std.ArrayList([]u8) = .empty,
    byte_count: usize = 0,
    bounded_selector_count: usize = 0,
    normalization_operations: u64 = 0,
    normalization_temporary_bytes: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendSegment(self: *Builder, raw: []const u8) Error!void {
        const trimmed = trimWhitespace(raw);
        if (trimmed.len == 0) return;
        var context = NormalizationContext{
            .limits = self.limits,
            .selector_count = &self.bounded_selector_count,
            .operations = &self.normalization_operations,
            .temporary_bytes = &self.normalization_temporary_bytes,
        };
        const owned = try canonicalize(
            self.allocator,
            trimmed,
            self.limits.max_bytes,
            self.allow_parent,
            &context,
        );
        self.admitOwned(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn appendToken(self: *Builder, raw: []const u8) Error!void {
        const owned = if (raw.len > 0 and raw[0] == '[')
            try normalizeAttribute(self.allocator, raw, self.limits.max_bytes)
        else
            try self.allocator.dupe(u8, raw);
        self.admitOwned(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn admitOwned(self: *Builder, owned: []u8) Error!void {
        if (self.bounded_selector_count >= self.limits.max_selectors)
            return error.SelectorLimitExceeded;
        const next = std.math.add(usize, self.byte_count, owned.len) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_bytes) return error.SelectorLimitExceeded;
        try self.items.append(self.allocator, owned);
        self.bounded_selector_count += 1;
        self.byte_count = next;
    }

    fn finish(self: *Builder) Error!SelectorList {
        return .{
            .allocator = self.allocator,
            .items = try self.items.toOwnedSlice(self.allocator),
            .selector_count = self.bounded_selector_count,
        };
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    return parseInternal(allocator, input, limits, false);
}

fn parseInternal(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
    allow_parent: bool,
) Error!SelectorList {
    if (limits.max_selectors == 0 or limits.max_bytes == 0 or
        limits.max_normalization_operations == 0)
    {
        return error.SelectorLimitExceeded;
    }
    var builder = Builder{
        .allocator = allocator,
        .limits = limits,
        .allow_parent = allow_parent,
    };
    errdefer builder.deinit();

    var segment_start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (byte == '/' and index + 1 < input.len and input[index + 1] == '*') {
            index = commentEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return error.InvalidSelector;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            ',' => if (paren_depth == 0 and square_depth == 0) {
                if (builder.items.items.len == 0 and
                    trimWhitespace(input[segment_start..index]).len == 0)
                {
                    return error.InvalidSelector;
                }
                try builder.appendSegment(input[segment_start..index]);
                segment_start = index + 1;
            },
            else => {},
        }
        index += 1;
    }
    if (quote != null or paren_depth != 0 or square_depth != 0) {
        return error.InvalidSelector;
    }
    try builder.appendSegment(input[segment_start..]);
    if (builder.items.items.len == 0) return error.InvalidSelector;
    return builder.finish();
}

pub fn simpleSelectors(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    var parsed = try parse(allocator, input, limits);
    defer parsed.deinit();
    if (parsed.items.len != 1 or !isSingleCompound(parsed.items[0])) {
        return error.InvalidSelector;
    }

    var builder = Builder{ .allocator = allocator, .limits = limits };
    errdefer builder.deinit();
    var cursor: usize = 0;
    while (cursor < parsed.items[0].len) {
        const end = try simpleTokenEnd(parsed.items[0], cursor);
        if (end <= cursor) return error.InvalidSelector;
        try builder.appendToken(parsed.items[0][cursor..end]);
        cursor = end;
    }
    if (builder.items.items.len == 0) return error.InvalidSelector;
    return builder.finish();
}

pub fn append(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    limits: Limits,
) Error!SelectorList {
    if (inputs.len == 0) return error.InvalidSelector;
    var current = try parseInternal(allocator, inputs[0], limits, false);
    errdefer current.deinit();
    for (inputs[1..]) |input| {
        const replacement = try appendStep(allocator, &current, input, limits);
        current.deinit();
        current = replacement;
    }
    return current;
}

fn appendStep(
    allocator: std.mem.Allocator,
    left: *const SelectorList,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    var right = try parseInternal(allocator, input, limits, false);
    defer right.deinit();
    var builder = Builder{ .allocator = allocator, .limits = limits };
    errdefer builder.deinit();
    for (left.items) |prefix| {
        if (endsWithCombinator(prefix)) return error.InvalidSelector;
        for (right.items) |suffix| {
            if (startsWithCombinator(suffix)) return error.InvalidSelector;
            const length = std.math.add(usize, prefix.len, suffix.len) catch
                return error.SelectorLimitExceeded;
            if (length > limits.max_bytes) return error.SelectorLimitExceeded;
            const combined = try allocator.alloc(u8, length);
            std.mem.copyForwards(u8, combined[0..prefix.len], prefix);
            std.mem.copyForwards(u8, combined[prefix.len..], suffix);
            validateComplex(combined, false) catch |err| {
                allocator.free(combined);
                return err;
            };
            builder.admitOwned(combined) catch |err| {
                allocator.free(combined);
                return err;
            };
        }
    }
    return builder.finish();
}

pub fn nest(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    limits: Limits,
) Error!SelectorList {
    if (inputs.len == 0) return error.InvalidSelector;
    var current = try parseInternal(allocator, inputs[0], limits, true);
    errdefer current.deinit();
    for (inputs[1..]) |input| {
        const replacement = try nestStep(allocator, &current, input, limits);
        current.deinit();
        current = replacement;
    }
    return current;
}

const UnifyContext = struct {
    allocator: ?std.mem.Allocator = null,
    limits: Limits,
    component_count: usize = 0,
    temporary_bytes: usize = 0,
    operations: u64 = 0,
    selector_list_pseudo_depth: usize = 0,

    fn reserveComponents(self: *UnifyContext, count: usize) Error!void {
        const next = std.math.add(usize, self.component_count, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_complex_components) {
            return error.SelectorLimitExceeded;
        }
        self.component_count = next;
    }

    fn releaseComponents(self: *UnifyContext, count: usize) void {
        std.debug.assert(self.component_count >= count);
        self.component_count -= count;
    }

    fn reserveTemporary(self: *UnifyContext, count: usize) Error!void {
        const next = std.math.add(usize, self.temporary_bytes, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_temporary_bytes) {
            return error.SelectorLimitExceeded;
        }
        self.temporary_bytes = next;
    }

    fn releaseTemporary(self: *UnifyContext, count: usize) void {
        std.debug.assert(self.temporary_bytes >= count);
        self.temporary_bytes -= count;
    }

    fn consume(self: *UnifyContext, count: u64) Error!void {
        const next = std.math.add(u64, self.operations, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_relation_operations) {
            return error.SelectorLimitExceeded;
        }
        self.operations = next;
    }

    fn enterSelectorListPseudo(self: *UnifyContext) Error!void {
        if (self.selector_list_pseudo_depth >= maximum_selector_list_pseudo_depth) {
            return error.SelectorLimitExceeded;
        }
        self.selector_list_pseudo_depth += 1;
    }

    fn leaveSelectorListPseudo(self: *UnifyContext) void {
        std.debug.assert(self.selector_list_pseudo_depth > 0);
        self.selector_list_pseudo_depth -= 1;
    }
};

fn buildUnifyComplexList(
    allocator: std.mem.Allocator,
    selectors: *const SelectorList,
    context: *UnifyContext,
) Error!RelationComplexList {
    const list_bytes = std.math.mul(
        usize,
        selectors.items.len,
        @sizeOf(RelationComplex),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(list_bytes);
    const items = try allocator.alloc(RelationComplex, selectors.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| allocator.free(item.components);
        allocator.free(items);
    }
    for (selectors.items, 0..) |selector, index| {
        items[index] = try buildUnifyComplex(allocator, selector, context);
        initialized += 1;
    }
    return .{ .allocator = allocator, .items = items };
}

fn buildUnifyComplex(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *UnifyContext,
) Error!RelationComplex {
    const counted = try scanRelationComplex(input, null);
    if (counted.leading_combinator != null) {
        return error.UnsupportedSelectorUnification;
    }
    try context.reserveComponents(counted.component_count);
    const component_bytes = std.math.mul(
        usize,
        counted.component_count,
        @sizeOf(RelationComponent),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(component_bytes);
    const components = try allocator.alloc(RelationComponent, counted.component_count);
    errdefer allocator.free(components);
    const filled = try scanRelationComplex(input, components);
    std.debug.assert(filled.component_count == counted.component_count);
    std.debug.assert(filled.leading_combinator == null);
    if (components[components.len - 1].combinator != .none) {
        return error.UnsupportedSelectorUnification;
    }
    for (components) |component| {
        try validateUnifyCompoundAvailability(component.compound, context);
    }
    return .{ .leading_combinator = null, .components = components };
}

fn validateUnifyCompoundAvailability(
    input: []const u8,
    context: *UnifyContext,
) Error!void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        const escaped = std.mem.indexOfScalar(u8, token, '\\') != null;
        if ((escaped and token[0] != ':') or
            (token[0] == ':' and normalizedPseudoUnavailableForUnify(token)))
        {
            return error.UnsupportedSelectorUnification;
        }
        try context.consume(1);
        try context.reserveComponents(1);
        cursor = end;
    }
    if (cursor == 0) return error.InvalidSelector;
}

const UnifyCompound = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *UnifyCompound) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

const QualifiedUnification = union(enum) {
    conflict,
    keep,
    replace: []u8,
};

const NamespaceIntersection = union(enum) {
    conflict,
    value: ?[]const u8,
};

/// Returns the selector intersection for every left/right list pair. This slice
/// owns compounds, complex subject replacement, exact/shared ancestry, strict
/// child/adjacent-sibling ancestry, bounded disjoint ancestry weaving, and exact
/// shared descendant anchors with one-sided rigid ancestry suffixes plus
/// two-component terminal sibling weaving. Partial shared anchors, ambiguous
/// dual-rigid weaving and host-selector semantics remain unavailable. Bounded
/// identifier, simple-pseudo, attribute, and selector-list functional-pseudo
/// spellings are canonical before this stage. Non-identical functional-pseudo
/// inference remains unavailable except for the admitted selector-list and
/// formula-exact `:nth-child()`/`:nth-last-child()` relation rules.
pub fn unify(
    allocator: std.mem.Allocator,
    left_input: []const u8,
    right_input: []const u8,
    limits: Limits,
) Error!?SelectorList {
    if (limits.max_selectors == 0 or limits.max_bytes == 0 or
        limits.max_complex_components == 0 or limits.max_temporary_bytes == 0 or
        limits.max_relation_operations == 0)
    {
        return error.SelectorLimitExceeded;
    }

    var left = try parseInternal(allocator, left_input, limits, false);
    defer left.deinit();
    const left_usage = try selectorUsage(&left);
    if (left_usage.selectors >= limits.max_selectors or
        left_usage.bytes >= limits.max_bytes)
    {
        return error.SelectorLimitExceeded;
    }
    var right_limits = limits;
    right_limits.max_selectors -= left_usage.selectors;
    right_limits.max_bytes -= left_usage.bytes;
    var right = try parseInternal(allocator, right_input, right_limits, false);
    defer right.deinit();

    const right_usage = try selectorUsage(&right);
    const input_selectors = std.math.add(
        usize,
        left_usage.selectors,
        right_usage.selectors,
    ) catch return error.SelectorLimitExceeded;
    const input_bytes = std.math.add(
        usize,
        left_usage.bytes,
        right_usage.bytes,
    ) catch return error.SelectorLimitExceeded;
    if (input_selectors >= limits.max_selectors or input_bytes >= limits.max_bytes) {
        return error.SelectorLimitExceeded;
    }
    var output_limits = limits;
    output_limits.max_selectors -= input_selectors;
    output_limits.max_bytes -= input_bytes;
    var context = UnifyContext{ .limits = limits };
    var left_complexes = try buildUnifyComplexList(allocator, &left, &context);
    defer left_complexes.deinit();
    var right_complexes = try buildUnifyComplexList(allocator, &right, &context);
    defer right_complexes.deinit();
    var builder = Builder{ .allocator = allocator, .limits = output_limits };
    errdefer builder.deinit();

    for (left_complexes.items) |left_complex| {
        for (right_complexes.items) |right_complex| {
            try context.consume(1);
            try unifySelectorPair(
                allocator,
                left_complex,
                right_complex,
                &context,
                &builder,
            );
        }
    }
    if (builder.items.items.len == 0) {
        builder.deinit();
        return null;
    }
    return @as(?SelectorList, try builder.finish());
}

const ExtensionMode = enum {
    extend,
    replace,
};

const ExtensionReplacement = union(enum) {
    no_match,
    replacement: []u8,
};

const ExtensionPattern = struct {
    allocator: std.mem.Allocator,
    storage: [][]const u8,
    tokens: [][]const u8,

    fn deinit(self: *ExtensionPattern) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

const ExtensionCandidate = struct {
    bytes: []u8,
    complex: RelationComplex,
    original: bool,
    removed: bool = false,
    bytes_transferred: bool = false,
    complex_released: bool = false,
};

const ExtensionCandidates = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ExtensionCandidate) = .empty,

    fn deinit(self: *ExtensionCandidates) void {
        for (self.items.items) |candidate| {
            if (!candidate.complex_released) {
                self.allocator.free(candidate.complex.components);
            }
            if (!candidate.bytes_transferred) self.allocator.free(candidate.bytes);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

const ExtensionListOptions = struct {
    allocator: std.mem.Allocator,
    items: []std.ArrayList([]u8),

    fn deinit(self: *ExtensionListOptions) void {
        for (self.items) |*options| {
            for (options.items) |item| self.allocator.free(item);
            options.deinit(self.allocator);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

fn extensionBaseline(
    complex: RelationComplex,
    rewrites: ?[]const ?[]u8,
    index: usize,
) []const u8 {
    if (rewrites) |items| {
        if (items[index]) |owned| return owned;
    }
    return complex.components[index].compound;
}

fn installExtensionBaseline(
    allocator: std.mem.Allocator,
    rewrites: *?[]?[]u8,
    component_count: usize,
    index: usize,
    owned: []u8,
    context: *UnifyContext,
) Error!void {
    if (rewrites.* == null) {
        const pointer_bytes = std.math.mul(
            usize,
            component_count,
            @sizeOf(?[]u8),
        ) catch {
            allocator.free(owned);
            return error.SelectorLimitExceeded;
        };
        context.reserveTemporary(pointer_bytes) catch |err| {
            allocator.free(owned);
            return err;
        };
        const storage = allocator.alloc(?[]u8, component_count) catch |err| {
            allocator.free(owned);
            return err;
        };
        @memset(storage, null);
        rewrites.* = storage;
    }
    std.debug.assert(rewrites.*.?[index] == null);
    rewrites.*.?[index] = owned;
}

fn deinitExtensionBaselines(
    allocator: std.mem.Allocator,
    rewrites: ?[]?[]u8,
) void {
    if (rewrites) |items| {
        for (items) |item| {
            if (item) |owned| allocator.free(owned);
        }
        allocator.free(items);
    }
}

const extension_trim_threshold = 100;

/// Adds every selector produced by extending bounded compound extendees with
/// bounded compound extenders. Complex target selectors and every standard
/// combinator are preserved, and each matching compound participates in Dart
/// Sass's earliest-component-fastest expansion order. Extendee list members are
/// applied sequentially. Duplicate simples, reordered equivalent members, and
/// bounded attributes, identifier escapes, ordinary simple pseudo-classes, and
/// the admitted lowercase selector-list functional pseudos normalize for
/// matching and trimming without rewriting specificity. Lowercase nth-child
/// functions additionally own bounded An+B grammar and optional selector-list
/// arguments. Functional arguments recurse under the shared limits, including
/// relative `:has()` branches.
/// Complex extendees/extenders, namespace inference, non-selector functions,
/// pseudo-element extension, and host-selector semantics remain unavailable.
pub fn extend(
    allocator: std.mem.Allocator,
    selector_input: []const u8,
    extendee_input: []const u8,
    extender_input: []const u8,
    limits: Limits,
) Error!SelectorList {
    return selectorExtension(
        allocator,
        selector_input,
        extendee_input,
        extender_input,
        limits,
        .extend,
    );
}

/// Replaces every matching compound occurrence using the same bounded native
/// substitution core as `extend()`, without retaining partial/original paths.
pub fn replace(
    allocator: std.mem.Allocator,
    selector_input: []const u8,
    extendee_input: []const u8,
    extender_input: []const u8,
    limits: Limits,
) Error!SelectorList {
    return selectorExtension(
        allocator,
        selector_input,
        extendee_input,
        extender_input,
        limits,
        .replace,
    );
}

fn selectorExtension(
    allocator: std.mem.Allocator,
    selector_input: []const u8,
    extendee_input: []const u8,
    extender_input: []const u8,
    limits: Limits,
    mode: ExtensionMode,
) Error!SelectorList {
    if (limits.max_selectors == 0 or limits.max_bytes == 0 or
        limits.max_complex_components == 0 or limits.max_temporary_bytes == 0 or
        limits.max_relation_operations == 0)
    {
        return error.SelectorLimitExceeded;
    }

    var selectors = try parseInternal(allocator, selector_input, limits, false);
    defer selectors.deinit();
    const selector_usage = try selectorUsage(&selectors);
    if (selector_usage.selectors >= limits.max_selectors or
        selector_usage.bytes >= limits.max_bytes)
    {
        return error.SelectorLimitExceeded;
    }

    var extendee_limits = limits;
    extendee_limits.max_selectors -= selector_usage.selectors;
    extendee_limits.max_bytes -= selector_usage.bytes;
    var extendees = try parseInternal(
        allocator,
        extendee_input,
        extendee_limits,
        false,
    );
    defer extendees.deinit();
    const extendee_usage = try selectorUsage(&extendees);
    const first_input_selectors = std.math.add(
        usize,
        selector_usage.selectors,
        extendee_usage.selectors,
    ) catch return error.SelectorLimitExceeded;
    const first_input_bytes = std.math.add(
        usize,
        selector_usage.bytes,
        extendee_usage.bytes,
    ) catch return error.SelectorLimitExceeded;
    if (first_input_selectors >= limits.max_selectors or
        first_input_bytes >= limits.max_bytes)
    {
        return error.SelectorLimitExceeded;
    }

    var extender_limits = limits;
    extender_limits.max_selectors -= first_input_selectors;
    extender_limits.max_bytes -= first_input_bytes;
    var extenders = try parseInternal(
        allocator,
        extender_input,
        extender_limits,
        false,
    );
    defer extenders.deinit();
    const extender_usage = try selectorUsage(&extenders);
    const input_selectors = std.math.add(
        usize,
        first_input_selectors,
        extender_usage.selectors,
    ) catch return error.SelectorLimitExceeded;
    const input_bytes = std.math.add(
        usize,
        first_input_bytes,
        extender_usage.bytes,
    ) catch return error.SelectorLimitExceeded;
    if (input_selectors >= limits.max_selectors or input_bytes >= limits.max_bytes) {
        return error.SelectorLimitExceeded;
    }

    var output_limits = limits;
    output_limits.max_selectors -= input_selectors;
    output_limits.max_bytes -= input_bytes;
    var context = UnifyContext{ .allocator = allocator, .limits = limits };
    var selector_complexes = try buildExtensionComplexList(
        allocator,
        &selectors,
        &context,
    );
    defer selector_complexes.deinit();
    var extendee_complexes = try buildExtensionComplexList(
        allocator,
        &extendees,
        &context,
    );
    defer extendee_complexes.deinit();
    var extender_complexes = try buildExtensionComplexList(
        allocator,
        &extenders,
        &context,
    );
    defer extender_complexes.deinit();

    for (extendee_complexes.items) |complex| {
        if (complex.components.len != 1) return error.UnsupportedSelectorExtension;
    }
    for (extender_complexes.items) |complex| {
        if (complex.components.len != 1) return error.UnsupportedSelectorExtension;
    }
    const list_mode = extendee_complexes.items.len > 1 or
        extender_complexes.items.len > 1;
    if (list_mode) {
        return selectorExtensionLists(
            allocator,
            selector_complexes.items,
            extendee_complexes.items,
            extender_complexes.items,
            output_limits,
            mode,
            &context,
        );
    }

    var pattern = try loadExtensionPattern(
        allocator,
        extendee_complexes.items[0].components[0].compound,
        &context,
    );
    defer pattern.deinit();
    var candidates = ExtensionCandidates{ .allocator = allocator };
    defer candidates.deinit();
    var extension_applied = false;
    for (selector_complexes.items) |complex| {
        extension_applied = try emitExtensionCandidates(
            allocator,
            complex,
            &pattern,
            extender_complexes.items,
            mode,
            output_limits.max_selectors,
            &context,
            &candidates,
        ) or extension_applied;
    }
    if (extension_applied) {
        switch (mode) {
            .extend => try pruneExtensionListCandidates(
                allocator,
                &candidates,
                &context,
            ),
            .replace => try pruneExtensionCandidates(mode, &candidates, &context),
        }
    }

    return finishExtensionCandidates(allocator, &candidates, output_limits);
}

fn finishExtensionCandidates(
    allocator: std.mem.Allocator,
    candidates: *ExtensionCandidates,
    output_limits: Limits,
) Error!SelectorList {
    var builder = Builder{ .allocator = allocator, .limits = output_limits };
    errdefer builder.deinit();
    var selector_count: usize = 0;
    for (candidates.items.items) |*candidate| {
        allocator.free(candidate.complex.components);
        candidate.complex_released = true;
        if (candidate.removed) continue;
        const candidate_selectors = try canonicalSelectorListMemberCount(
            candidate.bytes,
            0,
        );
        selector_count = std.math.add(
            usize,
            selector_count,
            candidate_selectors,
        ) catch return error.SelectorLimitExceeded;
        if (selector_count > output_limits.max_selectors) {
            return error.SelectorLimitExceeded;
        }
        builder.admitOwned(candidate.bytes) catch |err| {
            allocator.free(candidate.bytes);
            candidate.bytes_transferred = true;
            return err;
        };
        candidate.bytes_transferred = true;
    }
    if (builder.items.items.len == 0) return error.UnsupportedSelectorExtension;
    var result = try builder.finish();
    result.selector_count = selector_count;
    return result;
}

fn selectorExtensionLists(
    allocator: std.mem.Allocator,
    selector_complexes: []const RelationComplex,
    extendee_complexes: []const RelationComplex,
    extender_complexes: []const RelationComplex,
    output_limits: Limits,
    mode: ExtensionMode,
    context: *UnifyContext,
) Error!SelectorList {
    var current = ExtensionCandidates{ .allocator = allocator };
    var has_current = false;
    defer if (has_current) current.deinit();

    for (extendee_complexes) |extendee| {
        var pattern = try loadExtensionPattern(
            allocator,
            extendee.components[0].compound,
            context,
        );
        defer pattern.deinit();

        var next = ExtensionCandidates{ .allocator = allocator };
        errdefer next.deinit();
        var stage_applied = false;
        if (has_current) {
            for (current.items.items) |candidate| {
                if (candidate.removed) continue;
                const candidate_applied = try emitExtensionListCandidates(
                    allocator,
                    candidate.complex,
                    candidate.original,
                    &pattern,
                    extender_complexes,
                    mode,
                    output_limits.max_selectors,
                    context,
                    &next,
                );
                stage_applied = stage_applied or candidate_applied;
            }
        } else {
            for (selector_complexes) |complex| {
                const candidate_applied = try emitExtensionListCandidates(
                    allocator,
                    complex,
                    true,
                    &pattern,
                    extender_complexes,
                    mode,
                    output_limits.max_selectors,
                    context,
                    &next,
                );
                stage_applied = stage_applied or candidate_applied;
            }
        }
        if (stage_applied) {
            try pruneExtensionListCandidates(allocator, &next, context);
        }
        if (has_current) current.deinit();
        current = next;
        has_current = true;
    }

    return finishExtensionCandidates(allocator, &current, output_limits);
}

fn emitExtensionListCandidates(
    allocator: std.mem.Allocator,
    complex: RelationComplex,
    source_original: bool,
    pattern: *const ExtensionPattern,
    extenders: []const RelationComplex,
    mode: ExtensionMode,
    maximum_candidates: usize,
    context: *UnifyContext,
    candidates: *ExtensionCandidates,
) Error!bool {
    if (try relationComplexContainsBogusNth(context, complex)) {
        if (candidates.items.items.len >= maximum_candidates) {
            return error.SelectorLimitExceeded;
        }
        const rendered = try renderUnchangedExtensionComplex(
            allocator,
            complex,
            context,
        );
        try appendExtensionCandidate(
            allocator,
            candidates,
            rendered,
            source_original,
            complex.leading_combinator != null,
            context,
        );
        return false;
    }
    const options_bytes = std.math.mul(
        usize,
        complex.components.len,
        @sizeOf(std.ArrayList([]u8)),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(options_bytes);
    const option_items = try allocator.alloc(
        std.ArrayList([]u8),
        complex.components.len,
    );
    for (option_items) |*options| options.* = .empty;
    var replacement_options = ExtensionListOptions{
        .allocator = allocator,
        .items = option_items,
    };
    defer replacement_options.deinit();

    var baseline_rewrites: ?[]?[]u8 = null;
    defer deinitExtensionBaselines(allocator, baseline_rewrites);
    var extension_applied = false;
    for (complex.components, 0..) |component, component_index| {
        if (try rewriteExtensionFunctionalPseudos(
            allocator,
            component.compound,
            pattern,
            extenders,
            mode,
            context,
        )) |owned| {
            try installExtensionBaseline(
                allocator,
                &baseline_rewrites,
                complex.components.len,
                component_index,
                owned,
                context,
            );
            extension_applied = true;
        }
        const baseline = extensionBaseline(
            complex,
            baseline_rewrites,
            component_index,
        );
        var pattern_matched = false;
        for (extenders) |extender| {
            const result = try extensionCompoundReplacement(
                allocator,
                baseline,
                pattern,
                extender.components[0].compound,
                context,
            );
            switch (result) {
                .no_match => {
                    if (pattern_matched) return error.InvalidSelector;
                    break;
                },
                .replacement => |owned| {
                    pattern_matched = true;
                    extension_applied = true;
                    var retained = false;
                    defer if (!retained) allocator.free(owned);
                    if (mode == .extend and try extensionCompoundsEquivalent(
                        baseline,
                        owned,
                        context,
                    )) {
                        continue;
                    }
                    try appendExtensionListOption(
                        allocator,
                        &replacement_options.items[component_index],
                        owned,
                        context,
                    );
                    retained = true;
                },
            }
        }
    }

    if (extension_applied) {
        try ensureExtensionListPatternExpansionBound(
            pattern.tokens.len,
            extenders.len,
            mode,
            context,
        );
    }

    if (candidates.items.items.len >= maximum_candidates) {
        return error.SelectorLimitExceeded;
    }
    const remaining = maximum_candidates - candidates.items.items.len;
    var expansion_count: usize = 1;
    for (replacement_options.items) |options| {
        const choice_count = extensionListChoiceCount(options.items.len, mode) catch
            return error.SelectorLimitExceeded;
        expansion_count = std.math.mul(
            usize,
            expansion_count,
            choice_count,
        ) catch return error.SelectorLimitExceeded;
        if (expansion_count > remaining) return error.SelectorLimitExceeded;
    }

    for (0..expansion_count) |ordinal| {
        const rendered = try renderExtensionListCandidate(
            allocator,
            complex,
            baseline_rewrites,
            replacement_options.items,
            ordinal,
            mode,
            context,
        );
        try appendExtensionCandidate(
            allocator,
            candidates,
            rendered,
            source_original and ordinal == 0,
            complex.leading_combinator != null,
            context,
        );
    }
    return extension_applied;
}

fn appendExtensionListOption(
    allocator: std.mem.Allocator,
    options: *std.ArrayList([]u8),
    owned: []u8,
    context: *UnifyContext,
) Error!void {
    const next_length = std.math.add(usize, options.items.len, 1) catch
        return error.SelectorLimitExceeded;
    if (next_length > options.capacity) {
        const additional = next_length - options.capacity;
        const additional_bytes = std.math.mul(
            usize,
            additional,
            @sizeOf([]u8),
        ) catch return error.SelectorLimitExceeded;
        try context.reserveTemporary(additional_bytes);
        try options.ensureTotalCapacityPrecise(allocator, next_length);
    }
    options.appendAssumeCapacity(owned);
}

fn extensionListChoiceCount(
    replacement_count: usize,
    mode: ExtensionMode,
) error{SelectorLimitExceeded}!usize {
    if (replacement_count == 0) return 1;
    return if (mode == .extend)
        std.math.add(usize, replacement_count, 1) catch
            error.SelectorLimitExceeded
    else
        replacement_count;
}

fn ensureExtensionListPatternExpansionBound(
    pattern_token_count: usize,
    extender_count: usize,
    mode: ExtensionMode,
    context: *UnifyContext,
) Error!void {
    const choice_count = try extensionListChoiceCount(extender_count, mode);
    var expansion_count: usize = 1;
    for (0..pattern_token_count) |_| {
        try context.consume(1);
        expansion_count = std.math.mul(
            usize,
            expansion_count,
            choice_count,
        ) catch return error.SelectorLimitExceeded;
        if (expansion_count > extension_trim_threshold) {
            return error.SelectorLimitExceeded;
        }
    }
}

fn renderExtensionListCandidate(
    allocator: std.mem.Allocator,
    complex: RelationComplex,
    baseline_rewrites: ?[]const ?[]u8,
    replacement_options: []const std.ArrayList([]u8),
    ordinal: usize,
    mode: ExtensionMode,
    context: *UnifyContext,
) Error![]u8 {
    if (replacement_options.len != complex.components.len) {
        return error.InvalidSelector;
    }
    if (baseline_rewrites) |rewrites| {
        if (rewrites.len != complex.components.len) return error.InvalidSelector;
    }
    try context.reserveComponents(complex.components.len);
    const leading = extensionLeadingCombinatorBytes(complex.leading_combinator);
    var output_length: usize = leading.len;
    var remaining_ordinal = ordinal;
    for (complex.components, replacement_options, 0..) |component, options, index| {
        const compound = try extensionListCandidateCompound(
            extensionBaseline(complex, baseline_rewrites, index),
            options.items,
            mode,
            &remaining_ordinal,
        );
        try context.consume(1);
        output_length = std.math.add(usize, output_length, compound.len) catch
            return error.SelectorLimitExceeded;
        output_length = std.math.add(
            usize,
            output_length,
            unifyCombinatorBytes(component.combinator).len,
        ) catch return error.SelectorLimitExceeded;
    }
    std.debug.assert(remaining_ordinal == 0);
    if (output_length == 0 or output_length > context.limits.max_bytes) {
        return error.SelectorLimitExceeded;
    }
    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);

    std.mem.copyForwards(u8, output[0..leading.len], leading);
    var offset: usize = leading.len;
    remaining_ordinal = ordinal;
    for (complex.components, replacement_options, 0..) |component, options, index| {
        const compound = try extensionListCandidateCompound(
            extensionBaseline(complex, baseline_rewrites, index),
            options.items,
            mode,
            &remaining_ordinal,
        );
        std.mem.copyForwards(u8, output[offset .. offset + compound.len], compound);
        offset += compound.len;
        const combinator = unifyCombinatorBytes(component.combinator);
        std.mem.copyForwards(u8, output[offset .. offset + combinator.len], combinator);
        offset += combinator.len;
    }
    std.debug.assert(remaining_ordinal == 0);
    std.debug.assert(offset == output.len);
    try validateComplex(output, false);
    return output;
}

fn extensionListCandidateCompound(
    original: []const u8,
    replacements: []const []u8,
    mode: ExtensionMode,
    ordinal: *usize,
) error{SelectorLimitExceeded}![]const u8 {
    if (replacements.len == 0) return original;
    const choice_count = try extensionListChoiceCount(replacements.len, mode);
    const choice = ordinal.* % choice_count;
    ordinal.* /= choice_count;
    if (mode == .extend) {
        return if (choice == 0) original else replacements[choice - 1];
    }
    return replacements[choice];
}

fn pruneExtensionListCandidates(
    allocator: std.mem.Allocator,
    candidates: *ExtensionCandidates,
    context: *UnifyContext,
) Error!void {
    const items = candidates.items.items;
    if (items.len > extension_trim_threshold) return;

    const order_bytes = std.math.mul(usize, items.len, @sizeOf(usize)) catch
        return error.SelectorLimitExceeded;
    try context.reserveTemporary(order_bytes);
    const order = try allocator.alloc(usize, items.len);
    defer allocator.free(order);
    var order_length: usize = 0;
    var original_count: usize = 0;

    var index = items.len;
    while (index > 0) {
        index -= 1;
        const candidate = &items[index];
        if (candidate.original) {
            var duplicate_index: ?usize = null;
            for (0..original_count) |original_index| {
                if (std.mem.eql(
                    u8,
                    items[order[original_index]].bytes,
                    candidate.bytes,
                )) {
                    duplicate_index = original_index;
                    break;
                }
            }
            if (duplicate_index) |matched_index| {
                const matched = order[matched_index];
                var rotate_index = matched_index;
                while (rotate_index > 0) : (rotate_index -= 1) {
                    order[rotate_index] = order[rotate_index - 1];
                }
                order[0] = matched;
                continue;
            }
            prependExtensionCandidateIndex(order, &order_length, index);
            original_count += 1;
            continue;
        }

        var covered = false;
        for (order[0..order_length]) |retained_index| {
            if (try extensionComplexIsSuperselector(
                items[retained_index].complex,
                candidate.complex,
                context,
            )) {
                covered = true;
                break;
            }
        }
        if (!covered) {
            for (items[0..index]) |earlier| {
                if (try extensionComplexIsSuperselector(
                    earlier.complex,
                    candidate.complex,
                    context,
                )) {
                    covered = true;
                    break;
                }
            }
        }
        if (!covered) prependExtensionCandidateIndex(order, &order_length, index);
    }

    const reordered_bytes = std.math.mul(
        usize,
        items.len,
        @sizeOf(ExtensionCandidate),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(reordered_bytes);
    const reordered = try allocator.alloc(ExtensionCandidate, items.len);
    defer allocator.free(reordered);
    var reordered_length: usize = 0;
    for (order[0..order_length]) |candidate_index| {
        reordered[reordered_length] = items[candidate_index];
        reordered[reordered_length].removed = false;
        reordered_length += 1;
    }
    for (items, 0..) |candidate, candidate_index| {
        var retained = false;
        for (order[0..order_length]) |retained_index| {
            if (retained_index == candidate_index) {
                retained = true;
                break;
            }
        }
        if (retained) continue;
        reordered[reordered_length] = candidate;
        reordered[reordered_length].removed = true;
        reordered_length += 1;
    }
    std.debug.assert(reordered_length == items.len);
    std.mem.copyForwards(ExtensionCandidate, items, reordered);
}

fn prependExtensionCandidateIndex(
    order: []usize,
    order_length: *usize,
    candidate_index: usize,
) void {
    var index = order_length.*;
    while (index > 0) : (index -= 1) order[index] = order[index - 1];
    order[0] = candidate_index;
    order_length.* += 1;
}

fn buildExtensionComplexList(
    allocator: std.mem.Allocator,
    selectors: *const SelectorList,
    context: *UnifyContext,
) Error!RelationComplexList {
    return buildExtensionComplexListInternal(
        allocator,
        selectors,
        context,
        false,
    );
}

fn buildExtensionComplexListInternal(
    allocator: std.mem.Allocator,
    selectors: *const SelectorList,
    context: *UnifyContext,
    allow_relative: bool,
) Error!RelationComplexList {
    const list_bytes = std.math.mul(
        usize,
        selectors.items.len,
        @sizeOf(RelationComplex),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(list_bytes);
    const items = try allocator.alloc(RelationComplex, selectors.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| allocator.free(item.components);
        allocator.free(items);
    }
    for (selectors.items, 0..) |selector, index| {
        items[index] = try buildExtensionComplexInternal(
            allocator,
            selector,
            context,
            allow_relative,
        );
        initialized += 1;
    }
    return .{ .allocator = allocator, .items = items };
}

fn buildExtensionComplex(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *UnifyContext,
) Error!RelationComplex {
    return buildExtensionComplexInternal(allocator, input, context, false);
}

fn buildExtensionComplexInternal(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *UnifyContext,
    allow_relative: bool,
) Error!RelationComplex {
    const counted = try scanRelationComplex(input, null);
    if (counted.leading_combinator != null and !allow_relative) {
        return error.UnsupportedSelectorExtension;
    }
    try context.reserveComponents(counted.component_count);
    const component_bytes = std.math.mul(
        usize,
        counted.component_count,
        @sizeOf(RelationComponent),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(component_bytes);
    const components = try allocator.alloc(RelationComponent, counted.component_count);
    errdefer allocator.free(components);
    const filled = try scanRelationComplex(input, components);
    std.debug.assert(filled.component_count == counted.component_count);
    std.debug.assert(filled.leading_combinator == counted.leading_combinator);
    if (components[components.len - 1].combinator != .none) {
        return error.UnsupportedSelectorExtension;
    }
    for (components) |component| {
        try validateExtensionCompoundAvailability(component.compound, context);
    }
    return .{
        .leading_combinator = filled.leading_combinator,
        .components = components,
    };
}

fn validateExtensionCompoundAvailability(
    input: []const u8,
    context: *UnifyContext,
) Error!void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        if (token[0] == ':') {
            const opening = findUnescapedByte(token, '(');
            if (relationPseudoElementName(token) != null or
                unsupportedUnifyPseudo(token))
            {
                return error.UnsupportedSelectorExtension;
            }
            if (opening != null and
                try relationSelectorListPseudo(token) == null and
                !try relationFunctionalPseudoIsAdmittedOpaque(token) and
                !try relationFunctionalPseudoIsKnownCaseMismatch(token))
            {
                return error.UnsupportedSelectorExtension;
            }
        }
        if (relationQualifiedName(token) != null and
            (std.mem.eql(u8, token, "*") or
                std.mem.indexOfScalar(u8, token, '|') != null))
        {
            return error.UnsupportedSelectorExtension;
        }
        try context.consume(1);
        try context.reserveComponents(1);
        cursor = end;
    }
    if (cursor == 0) return error.InvalidSelector;
}

const ExtensionFunctionalDisposition = enum {
    preserve,
    flatten,
    discard,
};

fn rewriteExtensionFunctionalPseudos(
    allocator: std.mem.Allocator,
    input: []const u8,
    pattern: *const ExtensionPattern,
    extenders: []const RelationComplex,
    mode: ExtensionMode,
    context: *UnifyContext,
) Error!?[]u8 {
    if (!try extensionCompoundContainsFunctionalPseudo(input)) return null;

    const token_count = try relationSimpleCount(input);
    const pointer_bytes = std.math.mul(
        usize,
        token_count,
        @sizeOf(?[]u8),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(pointer_bytes);
    const rewrites = try allocator.alloc(?[]u8, token_count);
    @memset(rewrites, null);
    defer {
        for (rewrites) |rewrite| {
            if (rewrite) |owned| allocator.free(owned);
        }
        allocator.free(rewrites);
    }

    var changed = false;
    var output_length: usize = 0;
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < input.len) : (index += 1) {
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        if (try relationSelectorListPseudo(token)) |function| {
            if (try rewriteExtensionFunctionalPseudo(
                allocator,
                token,
                function,
                pattern,
                extenders,
                mode,
                context,
            )) |owned| {
                rewrites[index] = owned;
                changed = true;
            }
        }
        const selected = rewrites[index] orelse token;
        output_length = std.math.add(
            usize,
            output_length,
            selected.len,
        ) catch return error.SelectorLimitExceeded;
        if (output_length > context.limits.max_bytes) {
            return error.SelectorLimitExceeded;
        }
        cursor = end;
    }
    std.debug.assert(index == token_count);
    if (!changed) return null;

    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);
    cursor = 0;
    index = 0;
    var offset: usize = 0;
    while (cursor < input.len) : (index += 1) {
        const end = try simpleTokenEnd(input, cursor);
        const selected = rewrites[index] orelse input[cursor..end];
        std.mem.copyForwards(u8, output[offset .. offset + selected.len], selected);
        offset += selected.len;
        cursor = end;
    }
    std.debug.assert(offset == output.len);
    try validateCompound(output, false);
    return output;
}

fn extensionCompoundContainsFunctionalPseudo(input: []const u8) Error!bool {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const end = try simpleTokenEnd(input, cursor);
        if (try relationSelectorListPseudo(input[cursor..end]) != null) {
            return true;
        }
        cursor = end;
    }
    return false;
}

fn rewriteExtensionFunctionalPseudo(
    allocator: std.mem.Allocator,
    input: []const u8,
    function: RelationSelectorListPseudo,
    pattern: *const ExtensionPattern,
    extenders: []const RelationComplex,
    mode: ExtensionMode,
    context: *UnifyContext,
) Error!?[]u8 {
    try context.enterSelectorListPseudo();
    defer context.leaveSelectorListPseudo();
    if (function.arguments.len == 0) return null;
    const argument_operations = std.math.cast(u64, function.arguments.len) orelse
        return error.SelectorLimitExceeded;
    const recursive_operations = std.math.add(
        u64,
        argument_operations,
        1,
    ) catch return error.SelectorLimitExceeded;
    try context.consume(recursive_operations);
    try context.reserveTemporary(function.arguments.len);

    var arguments = try parseInternal(
        allocator,
        function.arguments,
        context.limits,
        false,
    );
    defer arguments.deinit();
    var argument_complexes = try buildExtensionComplexListInternal(
        allocator,
        &arguments,
        context,
        true,
    );
    defer argument_complexes.deinit();

    var candidates = ExtensionCandidates{ .allocator = allocator };
    defer candidates.deinit();
    var applied = false;
    if (extenders.len == 1) {
        for (argument_complexes.items) |complex| {
            applied = try emitExtensionCandidates(
                allocator,
                complex,
                pattern,
                extenders,
                mode,
                context.limits.max_selectors,
                context,
                &candidates,
            ) or applied;
        }
        if (applied) switch (mode) {
            .extend => try pruneExtensionListCandidates(
                allocator,
                &candidates,
                context,
            ),
            .replace => try pruneExtensionCandidates(mode, &candidates, context),
        };
    } else {
        for (argument_complexes.items) |complex| {
            applied = try emitExtensionListCandidates(
                allocator,
                complex,
                true,
                pattern,
                extenders,
                mode,
                context.limits.max_selectors,
                context,
                &candidates,
            ) or applied;
        }
        if (applied) {
            try pruneExtensionListCandidates(allocator, &candidates, context);
        }
    }
    if (!applied) return null;

    var extended = try finishExtensionCandidates(
        allocator,
        &candidates,
        context.limits,
    );
    defer extended.deinit();

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);
    for (extended.items) |item| {
        if (try extensionWholeSelectorListPseudo(item)) |nested| {
            switch (extensionFunctionalDisposition(function, nested)) {
                .preserve => try appendExtensionFunctionalSegment(
                    allocator,
                    &segments,
                    item,
                    context,
                ),
                .flatten => {
                    var iterator = RelationSelectorListIterator{
                        .input = nested.arguments,
                    };
                    while (try iterator.next(context)) |segment| {
                        try appendExtensionFunctionalSegment(
                            allocator,
                            &segments,
                            segment,
                            context,
                        );
                    }
                },
                .discard => {},
            }
        } else {
            try appendExtensionFunctionalSegment(
                allocator,
                &segments,
                item,
                context,
            );
        }
    }
    if (segments.items.len == 0) return error.InvalidSelector;

    const chains_not = try extensionFunctionalChainsNot(function.kind, &arguments);
    const opening = findUnescapedByte(input, '(') orelse
        return error.InvalidSelector;
    var prefix_length = std.math.add(usize, opening, 1) catch
        return error.SelectorLimitExceeded;
    if (function.formula) |formula| {
        prefix_length = std.math.add(
            usize,
            prefix_length,
            formula.len,
        ) catch return error.SelectorLimitExceeded;
        prefix_length = std.math.add(usize, prefix_length, 4) catch
            return error.SelectorLimitExceeded;
    }
    if (prefix_length > input.len - 1) return error.InvalidSelector;
    var output_length: usize = 0;
    if (chains_not) {
        for (segments.items) |segment| {
            const with_prefix = std.math.add(
                usize,
                prefix_length,
                segment.len,
            ) catch return error.SelectorLimitExceeded;
            const candidate_length = std.math.add(
                usize,
                with_prefix,
                1,
            ) catch return error.SelectorLimitExceeded;
            output_length = std.math.add(
                usize,
                output_length,
                candidate_length,
            ) catch return error.SelectorLimitExceeded;
        }
    } else {
        output_length = prefix_length;
        for (segments.items, 0..) |segment, segment_index| {
            if (segment_index != 0) {
                output_length = std.math.add(
                    usize,
                    output_length,
                    2,
                ) catch return error.SelectorLimitExceeded;
            }
            output_length = std.math.add(
                usize,
                output_length,
                segment.len,
            ) catch return error.SelectorLimitExceeded;
        }
        output_length = std.math.add(usize, output_length, 1) catch
            return error.SelectorLimitExceeded;
    }
    if (output_length == 0 or output_length > context.limits.max_bytes) {
        return error.SelectorLimitExceeded;
    }
    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);
    var offset: usize = 0;
    if (chains_not) {
        for (segments.items) |segment| {
            std.mem.copyForwards(u8, output[offset .. offset + opening], input[0..opening]);
            offset += opening;
            output[offset] = '(';
            offset += 1;
            std.mem.copyForwards(u8, output[offset .. offset + segment.len], segment);
            offset += segment.len;
            output[offset] = ')';
            offset += 1;
        }
    } else {
        std.mem.copyForwards(u8, output[0..prefix_length], input[0..prefix_length]);
        offset = prefix_length;
        for (segments.items, 0..) |segment, segment_index| {
            if (segment_index != 0) {
                std.mem.copyForwards(u8, output[offset .. offset + 2], ", ");
                offset += 2;
            }
            std.mem.copyForwards(u8, output[offset .. offset + segment.len], segment);
            offset += segment.len;
        }
        output[offset] = ')';
        offset += 1;
    }
    std.debug.assert(offset == output.len);
    try validateCompound(output, false);
    if (std.mem.eql(u8, output, input)) {
        allocator.free(output);
        return null;
    }
    return output;
}

fn appendExtensionFunctionalSegment(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList([]const u8),
    segment: []const u8,
    context: *UnifyContext,
) Error!void {
    const next_length = std.math.add(usize, segments.items.len, 1) catch
        return error.SelectorLimitExceeded;
    if (next_length > segments.capacity) {
        const additional = next_length - segments.capacity;
        const additional_bytes = std.math.mul(
            usize,
            additional,
            @sizeOf([]const u8),
        ) catch return error.SelectorLimitExceeded;
        try context.reserveTemporary(additional_bytes);
        try segments.ensureTotalCapacityPrecise(allocator, next_length);
    }
    segments.appendAssumeCapacity(segment);
}

fn extensionWholeSelectorListPseudo(
    input: []const u8,
) Error!?RelationSelectorListPseudo {
    if (input.len == 0 or input[0] != ':') return null;
    if (try simpleTokenEnd(input, 0) != input.len) return null;
    return relationSelectorListPseudo(input);
}

fn extensionFunctionalDisposition(
    outer: RelationSelectorListPseudo,
    inner: RelationSelectorListPseudo,
) ExtensionFunctionalDisposition {
    if (selectorListPseudoIsNth(outer.kind)) {
        if (outer.kind != inner.kind or outer.formula == null or
            inner.formula == null)
        {
            return .discard;
        }
        return if (std.mem.eql(u8, outer.formula.?, inner.formula.?))
            .flatten
        else
            .discard;
    }
    if (outer.kind == .has) return .preserve;
    if (outer.kind == .not) return switch (inner.kind) {
        .is, .where, .matches => .flatten,
        else => .discard,
    };
    return if (outer.kind == inner.kind) .flatten else .discard;
}

fn extensionFunctionalChainsNot(
    outer: SelectorListPseudoKind,
    arguments: *const SelectorList,
) Error!bool {
    if (outer != .not or arguments.items.len != 1) return false;
    const nested = try extensionWholeSelectorListPseudo(arguments.items[0]) orelse
        return false;
    return nested.kind == .is or nested.kind == .where or nested.kind == .matches;
}

fn loadExtensionPattern(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *UnifyContext,
) Error!ExtensionPattern {
    const token_count = try relationSimpleCount(input);
    const pointer_bytes = std.math.mul(
        usize,
        token_count,
        @sizeOf([]const u8),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(pointer_bytes);
    const storage = try allocator.alloc([]const u8, token_count);
    errdefer allocator.free(storage);
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < input.len) {
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        var duplicate = false;
        for (storage[0..index]) |candidate| {
            try context.consume(1);
            if (std.mem.eql(u8, token, candidate)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            try context.consume(1);
            storage[index] = token;
            index += 1;
        }
        cursor = end;
    }
    std.debug.assert(index > 0 and index <= token_count);
    return .{
        .allocator = allocator,
        .storage = storage,
        .tokens = storage[0..index],
    };
}

fn emitExtensionCandidates(
    allocator: std.mem.Allocator,
    complex: RelationComplex,
    pattern: *const ExtensionPattern,
    extenders: []const RelationComplex,
    mode: ExtensionMode,
    maximum_candidates: usize,
    context: *UnifyContext,
    candidates: *ExtensionCandidates,
) Error!bool {
    if (extenders.len != 1 or extenders[0].components.len != 1) {
        return error.UnsupportedSelectorExtension;
    }
    if (try relationComplexContainsBogusNth(context, complex)) {
        if (candidates.items.items.len >= maximum_candidates) {
            return error.SelectorLimitExceeded;
        }
        const rendered = try renderUnchangedExtensionComplex(
            allocator,
            complex,
            context,
        );
        try appendExtensionCandidate(
            allocator,
            candidates,
            rendered,
            true,
            complex.leading_combinator != null,
            context,
        );
        return false;
    }
    const extender = extenders[0].components[0].compound;
    const replacement_bytes = std.math.mul(
        usize,
        complex.components.len,
        @sizeOf(?[]u8),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(replacement_bytes);
    const replacements = try allocator.alloc(?[]u8, complex.components.len);
    @memset(replacements, null);
    defer {
        for (replacements) |replacement| {
            if (replacement) |owned| allocator.free(owned);
        }
        allocator.free(replacements);
    }

    var baseline_rewrites: ?[]?[]u8 = null;
    defer deinitExtensionBaselines(allocator, baseline_rewrites);
    var match_count: usize = 0;
    var extension_applied = false;
    for (complex.components, 0..) |component, index| {
        if (try rewriteExtensionFunctionalPseudos(
            allocator,
            component.compound,
            pattern,
            extenders,
            mode,
            context,
        )) |owned| {
            try installExtensionBaseline(
                allocator,
                &baseline_rewrites,
                complex.components.len,
                index,
                owned,
                context,
            );
            extension_applied = true;
        }
        const baseline = extensionBaseline(complex, baseline_rewrites, index);
        const result = try extensionCompoundReplacement(
            allocator,
            baseline,
            pattern,
            extender,
            context,
        );
        switch (result) {
            .no_match => {},
            .replacement => |owned| {
                extension_applied = true;
                var retained = false;
                defer if (!retained) allocator.free(owned);
                if (mode == .extend and try extensionCompoundsEquivalent(
                    baseline,
                    owned,
                    context,
                )) {
                    continue;
                }
                replacements[index] = owned;
                retained = true;
                match_count = std.math.add(usize, match_count, 1) catch
                    return error.SelectorLimitExceeded;
            },
        }
    }

    if (mode == .extend) {
        if (candidates.items.items.len >= maximum_candidates) {
            return error.SelectorLimitExceeded;
        }
        const remaining = maximum_candidates - candidates.items.items.len;
        const expansion_count = try selectorPowerBounded(2, match_count, remaining);
        for (0..expansion_count) |ordinal| {
            const rendered = try renderExtensionCandidate(
                allocator,
                complex,
                baseline_rewrites,
                replacements,
                ordinal,
                false,
                context,
            );
            try appendExtensionCandidate(
                allocator,
                candidates,
                rendered,
                ordinal == 0,
                complex.leading_combinator != null,
                context,
            );
        }
        return extension_applied;
    }

    if (candidates.items.items.len >= maximum_candidates) {
        return error.SelectorLimitExceeded;
    }
    const rendered = try renderExtensionCandidate(
        allocator,
        complex,
        baseline_rewrites,
        replacements,
        0,
        match_count != 0,
        context,
    );
    try appendExtensionCandidate(
        allocator,
        candidates,
        rendered,
        match_count == 0,
        complex.leading_combinator != null,
        context,
    );
    return extension_applied;
}

fn extensionCompoundReplacement(
    allocator: std.mem.Allocator,
    subject: []const u8,
    pattern: *const ExtensionPattern,
    extender: []const u8,
    context: *UnifyContext,
) Error!ExtensionReplacement {
    try context.reserveTemporary(pattern.tokens.len);
    const matched = try allocator.alloc(bool, pattern.tokens.len);
    defer allocator.free(matched);
    @memset(matched, false);

    var remainder_length: usize = 0;
    var cursor: usize = 0;
    while (cursor < subject.len) {
        const end = try simpleTokenEnd(subject, cursor);
        if (!try consumeExtensionPatternMatch(
            pattern,
            matched,
            subject[cursor..end],
            context,
        )) {
            remainder_length = std.math.add(
                usize,
                remainder_length,
                end - cursor,
            ) catch return error.SelectorLimitExceeded;
        }
        cursor = end;
    }
    for (matched) |found| {
        if (!found) return .no_match;
    }
    if (remainder_length == 0) {
        return .{ .replacement = try cloneExtensionCompound(
            allocator,
            extender,
            context,
        ) };
    }

    @memset(matched, false);
    try context.reserveTemporary(remainder_length);
    const remainder = try allocator.alloc(u8, remainder_length);
    defer allocator.free(remainder);
    cursor = 0;
    var offset: usize = 0;
    while (cursor < subject.len) {
        const end = try simpleTokenEnd(subject, cursor);
        if (!try consumeExtensionPatternMatch(
            pattern,
            matched,
            subject[cursor..end],
            context,
        )) {
            std.mem.copyForwards(
                u8,
                remainder[offset .. offset + end - cursor],
                subject[cursor..end],
            );
            offset += end - cursor;
        }
        cursor = end;
    }
    std.debug.assert(offset == remainder.len);
    const replacement = unifyCompound(
        allocator,
        remainder,
        extender,
        context,
    ) catch |err| switch (err) {
        error.UnsupportedSelectorUnification => return error.UnsupportedSelectorExtension,
        else => return err,
    };
    return .{ .replacement = replacement orelse
        return error.UnsupportedSelectorExtension };
}

fn consumeExtensionPatternMatch(
    pattern: *const ExtensionPattern,
    matched: []bool,
    token: []const u8,
    context: *UnifyContext,
) Error!bool {
    var found = false;
    for (pattern.tokens, 0..) |candidate, index| {
        try context.consume(1);
        if (std.mem.eql(u8, candidate, token)) {
            matched[index] = true;
            found = true;
        }
    }
    return found;
}

fn cloneExtensionCompound(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *UnifyContext,
) Error![]u8 {
    const simple_count = try relationSimpleCount(input);
    try context.reserveComponents(simple_count);
    const operation_count = std.math.cast(u64, simple_count) orelse
        return error.SelectorLimitExceeded;
    try context.consume(operation_count);
    try context.reserveTemporary(input.len);
    return allocator.dupe(u8, input);
}

fn renderExtensionCandidate(
    allocator: std.mem.Allocator,
    complex: RelationComplex,
    baseline_rewrites: ?[]const ?[]u8,
    replacements: []const ?[]u8,
    ordinal: usize,
    replace_all: bool,
    context: *UnifyContext,
) Error![]u8 {
    if (replacements.len != complex.components.len) return error.InvalidSelector;
    if (baseline_rewrites) |rewrites| {
        if (rewrites.len != complex.components.len) return error.InvalidSelector;
    }
    try context.reserveComponents(complex.components.len);
    const leading = extensionLeadingCombinatorBytes(complex.leading_combinator);
    var output_length: usize = leading.len;
    var match_index: usize = 0;
    for (complex.components, 0..) |component, index| {
        const compound = extensionCandidateCompound(
            extensionBaseline(complex, baseline_rewrites, index),
            replacements[index],
            ordinal,
            replace_all,
            &match_index,
        );
        try context.consume(1);
        output_length = std.math.add(usize, output_length, compound.len) catch
            return error.SelectorLimitExceeded;
        output_length = std.math.add(
            usize,
            output_length,
            unifyCombinatorBytes(component.combinator).len,
        ) catch return error.SelectorLimitExceeded;
    }
    if (output_length == 0 or output_length > context.limits.max_bytes) {
        return error.SelectorLimitExceeded;
    }
    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);
    std.mem.copyForwards(u8, output[0..leading.len], leading);
    var offset: usize = leading.len;
    match_index = 0;
    for (complex.components, 0..) |component, index| {
        const compound = extensionCandidateCompound(
            extensionBaseline(complex, baseline_rewrites, index),
            replacements[index],
            ordinal,
            replace_all,
            &match_index,
        );
        std.mem.copyForwards(u8, output[offset .. offset + compound.len], compound);
        offset += compound.len;
        const combinator = unifyCombinatorBytes(component.combinator);
        std.mem.copyForwards(u8, output[offset .. offset + combinator.len], combinator);
        offset += combinator.len;
    }
    std.debug.assert(offset == output.len);
    try validateComplex(output, false);
    return output;
}

fn renderUnchangedExtensionComplex(
    allocator: std.mem.Allocator,
    complex: RelationComplex,
    context: *UnifyContext,
) Error![]u8 {
    const pointer_bytes = std.math.mul(
        usize,
        complex.components.len,
        @sizeOf(?[]u8),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(pointer_bytes);
    const replacements = try allocator.alloc(?[]u8, complex.components.len);
    defer allocator.free(replacements);
    @memset(replacements, null);
    return renderExtensionCandidate(
        allocator,
        complex,
        null,
        replacements,
        0,
        false,
        context,
    );
}

fn extensionCandidateCompound(
    original: []const u8,
    replacement: ?[]u8,
    ordinal: usize,
    replace_all: bool,
    match_index: *usize,
) []const u8 {
    const owned = replacement orelse return original;
    const selected = replace_all or ((ordinal >> @intCast(match_index.*)) & 1) == 1;
    match_index.* += 1;
    return if (selected) owned else original;
}

fn appendExtensionCandidate(
    allocator: std.mem.Allocator,
    candidates: *ExtensionCandidates,
    bytes: []u8,
    original: bool,
    allow_relative: bool,
    context: *UnifyContext,
) Error!void {
    errdefer allocator.free(bytes);
    const complex = try buildExtensionComplexInternal(
        allocator,
        bytes,
        context,
        allow_relative,
    );
    errdefer allocator.free(complex.components);
    const next_length = std.math.add(
        usize,
        candidates.items.items.len,
        1,
    ) catch return error.SelectorLimitExceeded;
    if (next_length > candidates.items.capacity) {
        const additional = next_length - candidates.items.capacity;
        const additional_bytes = std.math.mul(
            usize,
            additional,
            @sizeOf(ExtensionCandidate),
        ) catch return error.SelectorLimitExceeded;
        try context.reserveTemporary(additional_bytes);
        try candidates.items.ensureTotalCapacityPrecise(allocator, next_length);
    }
    candidates.items.appendAssumeCapacity(.{
        .bytes = bytes,
        .complex = complex,
        .original = original,
    });
}

fn pruneExtensionCandidates(
    mode: ExtensionMode,
    candidates: *ExtensionCandidates,
    context: *UnifyContext,
) Error!void {
    if (candidates.items.items.len > extension_trim_threshold) return;
    for (candidates.items.items, 0..) |*left, left_index| {
        if (left.removed) continue;
        for (candidates.items.items[left_index + 1 ..]) |*right| {
            if (right.removed) continue;
            const exact_match = left.complex.leading_combinator == null and
                right.complex.leading_combinator == null and
                std.mem.eql(u8, left.bytes, right.bytes);
            const equivalent = exact_match or (mode == .extend and
                try extensionComplexesEquivalent(
                    left.complex,
                    right.complex,
                    context,
                ));
            if (equivalent) {
                if (left.original and right.original) continue;
                if (mode == .extend and !left.original and right.original) {
                    left.removed = true;
                    break;
                }
                right.removed = true;
                continue;
            }
            if (mode != .extend or (left.original and right.original)) continue;
            if (left.original) {
                if (try extensionComplexIsSuperselector(
                    left.complex,
                    right.complex,
                    context,
                )) {
                    right.removed = true;
                }
                continue;
            }
            if (right.original) {
                if (try extensionComplexIsSuperselector(
                    right.complex,
                    left.complex,
                    context,
                )) {
                    left.removed = true;
                    break;
                }
                continue;
            }
            const left_super = extensionComplexIsSuperselector(
                left.complex,
                right.complex,
                context,
            ) catch |err| return err;
            if (left_super) {
                right.removed = true;
                continue;
            }
            const right_super = extensionComplexIsSuperselector(
                right.complex,
                left.complex,
                context,
            ) catch |err| return err;
            if (right_super) {
                left.removed = true;
                break;
            }
        }
    }
    try pruneExactOriginalRuns(candidates, context);
}

fn pruneExactOriginalRuns(
    candidates: *ExtensionCandidates,
    context: *UnifyContext,
) Error!void {
    var run_start: usize = 0;
    for (candidates.items.items, 0..) |*candidate, candidate_index| {
        if (candidate.removed) continue;
        if (!candidate.original) {
            run_start = candidate_index + 1;
            continue;
        }
        for (candidates.items.items[run_start..candidate_index]) |previous| {
            if (previous.removed or !previous.original) continue;
            try context.consume(1);
            if (std.mem.eql(u8, previous.bytes, candidate.bytes)) {
                candidate.removed = true;
                break;
            }
        }
    }
}

fn extensionComplexIsSuperselector(
    super_complex: RelationComplex,
    sub_complex: RelationComplex,
    context: *UnifyContext,
) Error!bool {
    return relationComplexIsSuperselector(
        context,
        super_complex,
        sub_complex,
    ) catch |err| switch (err) {
        error.UnsupportedSelectorRelation => return error.UnsupportedSelectorExtension,
        else => return err,
    };
}

fn extensionComplexesEquivalent(
    left: RelationComplex,
    right: RelationComplex,
    context: *UnifyContext,
) Error!bool {
    try context.consume(1);
    if (left.leading_combinator != right.leading_combinator or
        left.components.len != right.components.len)
    {
        return false;
    }
    for (left.components, right.components) |left_component, right_component| {
        try context.consume(1);
        if (left_component.combinator != right_component.combinator or
            !try extensionCompoundsEquivalent(
                left_component.compound,
                right_component.compound,
                context,
            ))
        {
            return false;
        }
    }
    return true;
}

fn extensionCompoundsEquivalent(
    left: []const u8,
    right: []const u8,
    context: *UnifyContext,
) Error!bool {
    const left_count = try relationSimpleCount(left);
    const right_count = try relationSimpleCount(right);
    try context.consume(1);
    if (left_count != right_count) return false;
    var cursor: usize = 0;
    while (cursor < left.len) {
        const end = try simpleTokenEnd(left, cursor);
        const token = left[cursor..end];
        const left_occurrences = try extensionTokenOccurrences(left, token, context);
        const right_occurrences = try extensionTokenOccurrences(right, token, context);
        if (left_occurrences != right_occurrences) return false;
        cursor = end;
    }
    return true;
}

fn extensionTokenOccurrences(
    compound: []const u8,
    token: []const u8,
    context: *UnifyContext,
) Error!usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < compound.len) {
        const end = try simpleTokenEnd(compound, cursor);
        try context.consume(1);
        if (std.mem.eql(u8, compound[cursor..end], token)) {
            count = std.math.add(usize, count, 1) catch
                return error.SelectorLimitExceeded;
        }
        cursor = end;
    }
    return count;
}

fn admitUnifyResult(builder: *Builder, owned: []u8) Error!void {
    builder.admitOwned(owned) catch |err| {
        builder.allocator.free(owned);
        return err;
    };
}

fn unifySelectorPair(
    allocator: std.mem.Allocator,
    left: RelationComplex,
    right: RelationComplex,
    context: *UnifyContext,
    builder: *Builder,
) Error!void {
    const left_subject = left.components[left.components.len - 1].compound;
    const right_subject = right.components[right.components.len - 1].compound;
    const subject_result = try unifyCompound(
        allocator,
        left_subject,
        right_subject,
        context,
    );
    const subject = subject_result orelse return;
    if (left.components.len == 1 and right.components.len == 1) {
        try admitUnifyResult(builder, subject);
        return;
    }
    defer allocator.free(subject);

    if (left.components.len == 1) {
        try admitUnifyResult(builder, try renderUnifyComplex(
            allocator,
            right,
            null,
            subject,
            context,
        ));
        return;
    }
    if (right.components.len == 1) {
        try admitUnifyResult(builder, try renderUnifyComplex(
            allocator,
            left,
            null,
            subject,
            context,
        ));
        return;
    }
    if (try unifyAncestriesEqual(left, right, context)) {
        try admitUnifyResult(builder, try renderUnifyComplex(
            allocator,
            left,
            null,
            subject,
            context,
        ));
        return;
    }
    if (!try unifyStrictAncestriesCompatible(left, right, context)) {
        if (try planDisjointUnifyWeave(
            left,
            right,
            context,
        )) |plan| {
            const left_ancestry = left.components[0 .. left.components.len - 1];
            const right_ancestry = right.components[0 .. right.components.len - 1];
            switch (plan) {
                .left_then_right => try admitUnifyResult(
                    builder,
                    try renderUnifyWeave(
                        allocator,
                        left_ancestry,
                        right_ancestry,
                        subject,
                        context,
                    ),
                ),
                .right_then_left => try admitUnifyResult(
                    builder,
                    try renderUnifyWeave(
                        allocator,
                        right_ancestry,
                        left_ancestry,
                        subject,
                        context,
                    ),
                ),
                .both => {
                    try admitUnifyResult(
                        builder,
                        try renderUnifyWeave(
                            allocator,
                            left_ancestry,
                            right_ancestry,
                            subject,
                            context,
                        ),
                    );
                    try admitUnifyResult(
                        builder,
                        try renderUnifyWeave(
                            allocator,
                            right_ancestry,
                            left_ancestry,
                            subject,
                            context,
                        ),
                    );
                },
            }
            return;
        }
        if (try emitTerminalSiblingUnifyWeave(
            allocator,
            left,
            right,
            subject,
            context,
            builder,
        )) return;
        if (try emitSharedUnifyWeave(
            allocator,
            left,
            right,
            subject,
            context,
            builder,
        )) return;
        return error.UnsupportedSelectorUnification;
    }

    const ancestor_count = left.components.len - 1;
    const pointer_bytes = std.math.mul(
        usize,
        ancestor_count,
        @sizeOf([]u8),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(pointer_bytes);
    const ancestors = try allocator.alloc([]u8, ancestor_count);
    var initialized: usize = 0;
    defer {
        for (ancestors[0..initialized]) |ancestor| allocator.free(ancestor);
        allocator.free(ancestors);
    }
    for (0..ancestor_count) |index| {
        const unified = (try unifyCompound(
            allocator,
            left.components[index].compound,
            right.components[index].compound,
            context,
        )) orelse return;
        ancestors[index] = unified;
        initialized += 1;
    }
    try admitUnifyResult(
        builder,
        try renderUnifyComplex(
            allocator,
            left,
            ancestors,
            subject,
            context,
        ),
    );
}

fn unifyAncestriesEqual(
    left: RelationComplex,
    right: RelationComplex,
    context: *UnifyContext,
) Error!bool {
    try context.consume(1);
    if (left.components.len != right.components.len) return false;
    for (
        left.components[0 .. left.components.len - 1],
        right.components[0 .. right.components.len - 1],
    ) |left_component, right_component| {
        try context.consume(1);
        if (left_component.combinator != right_component.combinator or
            !std.mem.eql(u8, left_component.compound, right_component.compound))
        {
            return false;
        }
    }
    return true;
}

fn unifyStrictAncestriesCompatible(
    left: RelationComplex,
    right: RelationComplex,
    context: *UnifyContext,
) Error!bool {
    try context.consume(1);
    if (left.components.len != right.components.len) return false;
    for (
        left.components[0 .. left.components.len - 1],
        right.components[0 .. right.components.len - 1],
    ) |left_component, right_component| {
        try context.consume(1);
        if (left_component.combinator != right_component.combinator) return false;
        switch (left_component.combinator) {
            .child, .next_sibling => {},
            .none, .descendant, .following_sibling => return false,
        }
    }
    return true;
}

const UnifyWeavePlan = enum {
    left_then_right,
    right_then_left,
    both,
};

fn planDisjointUnifyWeave(
    left: RelationComplex,
    right: RelationComplex,
    context: *UnifyContext,
) Error!?UnifyWeavePlan {
    try context.consume(1);
    const left_ancestry = left.components[0 .. left.components.len - 1];
    const right_ancestry = right.components[0 .. right.components.len - 1];
    if (left_ancestry.len == 0 or right_ancestry.len == 0) {
        return error.InvalidSelector;
    }

    const ancestries = [_][]const RelationComponent{
        left_ancestry,
        right_ancestry,
    };
    for (ancestries) |ancestry| {
        for (ancestry) |component| {
            try context.consume(1);
            switch (component.combinator) {
                .descendant, .child, .next_sibling => {},
                .none, .following_sibling => return null,
            }
            if (!try unifyWeaveCompoundAvailable(component.compound, context)) {
                return null;
            }
        }
    }
    for (left_ancestry) |left_component| {
        for (right_ancestry) |right_component| {
            try context.consume(1);
            if (try unifyWeaveCompoundsShareAnchor(
                left_component.compound,
                right_component.compound,
                context,
            )) return null;
        }
    }

    const left_terminal = left_ancestry[left_ancestry.len - 1].combinator;
    const right_terminal = right_ancestry[right_ancestry.len - 1].combinator;
    if (left_terminal == .descendant and right_terminal == .descendant) {
        return .both;
    }
    if (left_terminal == .descendant) return .left_then_right;
    if (right_terminal == .descendant) return .right_then_left;
    return null;
}

fn emitTerminalSiblingUnifyWeave(
    allocator: std.mem.Allocator,
    left: RelationComplex,
    right: RelationComplex,
    subject: []const u8,
    context: *UnifyContext,
    builder: *Builder,
) Error!bool {
    if (left.components.len != 2 or right.components.len != 2) return false;
    const left_ancestor = left.components[0];
    const right_ancestor = right.components[0];
    const involves_following = left_ancestor.combinator == .following_sibling or
        right_ancestor.combinator == .following_sibling;
    const rigid_mismatch = (left_ancestor.combinator == .child and
        right_ancestor.combinator == .next_sibling) or
        (left_ancestor.combinator == .next_sibling and
            right_ancestor.combinator == .child);
    if (!involves_following and !rigid_mismatch) return false;

    try context.consume(1);
    if (!try unifyWeaveCompoundAvailable(left_ancestor.compound, context) or
        !try unifyWeaveCompoundAvailable(right_ancestor.compound, context))
    {
        return false;
    }

    if (left_ancestor.combinator == .following_sibling and
        right_ancestor.combinator == .following_sibling)
    {
        const merged_result = try unifyCompound(
            allocator,
            left_ancestor.compound,
            right_ancestor.compound,
            context,
        );
        const merged = merged_result orelse {
            try emitTerminalSiblingOrder(
                allocator,
                left_ancestor,
                right_ancestor,
                subject,
                context,
                builder,
            );
            try emitTerminalSiblingOrder(
                allocator,
                right_ancestor,
                left_ancestor,
                subject,
                context,
                builder,
            );
            return true;
        };
        defer allocator.free(merged);
        if (std.mem.eql(u8, merged, left_ancestor.compound) or
            std.mem.eql(u8, merged, right_ancestor.compound))
        {
            try emitMergedTerminalSibling(
                allocator,
                merged,
                .following_sibling,
                subject,
                context,
                builder,
            );
            return true;
        }
        try emitTerminalSiblingOrder(
            allocator,
            left_ancestor,
            right_ancestor,
            subject,
            context,
            builder,
        );
        try emitTerminalSiblingOrder(
            allocator,
            right_ancestor,
            left_ancestor,
            subject,
            context,
            builder,
        );
        try emitMergedTerminalSibling(
            allocator,
            merged,
            .following_sibling,
            subject,
            context,
            builder,
        );
        return true;
    }

    if (left_ancestor.combinator == .following_sibling and
        right_ancestor.combinator == .next_sibling)
    {
        try emitFollowingAdjacentUnifyWeave(
            allocator,
            left_ancestor,
            right_ancestor,
            subject,
            context,
            builder,
        );
        return true;
    }
    if (left_ancestor.combinator == .next_sibling and
        right_ancestor.combinator == .following_sibling)
    {
        try emitFollowingAdjacentUnifyWeave(
            allocator,
            right_ancestor,
            left_ancestor,
            subject,
            context,
            builder,
        );
        return true;
    }

    const left_rank = terminalSiblingRank(left_ancestor.combinator) orelse
        return false;
    const right_rank = terminalSiblingRank(right_ancestor.combinator) orelse
        return false;
    if (left_rank == right_rank) return false;
    if (left_rank < right_rank) {
        try emitTerminalSiblingOrder(
            allocator,
            left_ancestor,
            right_ancestor,
            subject,
            context,
            builder,
        );
    } else {
        try emitTerminalSiblingOrder(
            allocator,
            right_ancestor,
            left_ancestor,
            subject,
            context,
            builder,
        );
    }
    return true;
}

fn emitFollowingAdjacentUnifyWeave(
    allocator: std.mem.Allocator,
    following: RelationComponent,
    adjacent: RelationComponent,
    subject: []const u8,
    context: *UnifyContext,
    builder: *Builder,
) Error!void {
    const merged_result = try unifyCompound(
        allocator,
        following.compound,
        adjacent.compound,
        context,
    );
    if (merged_result) |merged| {
        defer allocator.free(merged);
        if (std.mem.eql(u8, merged, adjacent.compound)) {
            try emitMergedTerminalSibling(
                allocator,
                merged,
                .next_sibling,
                subject,
                context,
                builder,
            );
            return;
        }
        try emitTerminalSiblingOrder(
            allocator,
            following,
            adjacent,
            subject,
            context,
            builder,
        );
        try emitMergedTerminalSibling(
            allocator,
            merged,
            .next_sibling,
            subject,
            context,
            builder,
        );
        return;
    }
    try emitTerminalSiblingOrder(
        allocator,
        following,
        adjacent,
        subject,
        context,
        builder,
    );
}

fn emitTerminalSiblingOrder(
    allocator: std.mem.Allocator,
    first: RelationComponent,
    second: RelationComponent,
    subject: []const u8,
    context: *UnifyContext,
    builder: *Builder,
) Error!void {
    const first_items = [_]RelationComponent{first};
    const second_items = [_]RelationComponent{second};
    try admitUnifyResult(
        builder,
        try renderUnifyWeave(
            allocator,
            &first_items,
            &second_items,
            subject,
            context,
        ),
    );
}

fn emitMergedTerminalSibling(
    allocator: std.mem.Allocator,
    compound: []const u8,
    combinator: RelationCombinator,
    subject: []const u8,
    context: *UnifyContext,
    builder: *Builder,
) Error!void {
    const ancestry = [_]RelationComponent{.{
        .compound = compound,
        .combinator = combinator,
    }};
    const empty: []const RelationComponent = &.{};
    try admitUnifyResult(
        builder,
        try renderUnifyWeave(
            allocator,
            &ancestry,
            empty,
            subject,
            context,
        ),
    );
}

fn terminalSiblingRank(combinator: RelationCombinator) ?u8 {
    return switch (combinator) {
        .descendant => 0,
        .child => 1,
        .following_sibling => 2,
        .next_sibling => 3,
        .none => null,
    };
}

const UnifyWeaveAnchor = struct {
    left_index: usize,
    right_index: usize,
};

fn emitSharedUnifyWeave(
    allocator: std.mem.Allocator,
    left: RelationComplex,
    right: RelationComplex,
    subject: []const u8,
    context: *UnifyContext,
    builder: *Builder,
) Error!bool {
    const left_ancestry = left.components[0 .. left.components.len - 1];
    const right_ancestry = right.components[0 .. right.components.len - 1];
    if (left_ancestry.len == 0 or right_ancestry.len == 0) {
        return error.InvalidSelector;
    }

    const ancestries = [_][]const RelationComponent{
        left_ancestry,
        right_ancestry,
    };
    var rigid_owner: ?usize = null;
    for (ancestries, 0..) |ancestry, ancestry_index| {
        for (ancestry) |component| {
            try context.consume(1);
            switch (component.combinator) {
                .descendant => {},
                .child, .next_sibling, .following_sibling => {
                    if (rigid_owner) |owner| {
                        if (owner != ancestry_index) return false;
                    } else {
                        rigid_owner = ancestry_index;
                    }
                },
                .none => return false,
            }
            if (!try unifyWeaveCompoundAvailable(component.compound, context)) {
                return false;
            }
        }
    }

    const row_count = std.math.add(usize, left_ancestry.len, 1) catch
        return error.SelectorLimitExceeded;
    const column_count = std.math.add(usize, right_ancestry.len, 1) catch
        return error.SelectorLimitExceeded;
    const cell_count = std.math.mul(usize, row_count, column_count) catch
        return error.SelectorLimitExceeded;
    const cell_bytes = std.math.mul(usize, cell_count, @sizeOf(usize)) catch
        return error.SelectorLimitExceeded;
    try context.reserveTemporary(cell_bytes);
    const lengths = try allocator.alloc(usize, cell_count);
    defer allocator.free(lengths);
    @memset(lengths, 0);

    const comparison_count = std.math.mul(
        usize,
        left_ancestry.len,
        right_ancestry.len,
    ) catch return error.SelectorLimitExceeded;
    if (comparison_count > std.math.maxInt(u64)) {
        return error.SelectorLimitExceeded;
    }
    try context.consume(@intCast(comparison_count));
    for (1..row_count) |left_offset| {
        for (1..column_count) |right_offset| {
            const index = left_offset * column_count + right_offset;
            if (sharedUnifyWeaveAnchorMatches(
                left_ancestry[left_offset - 1],
                right_ancestry[right_offset - 1],
            )) {
                lengths[index] = std.math.add(
                    usize,
                    lengths[(left_offset - 1) * column_count + right_offset - 1],
                    1,
                ) catch return error.SelectorLimitExceeded;
            } else {
                lengths[index] = @max(
                    lengths[(left_offset - 1) * column_count + right_offset],
                    lengths[left_offset * column_count + right_offset - 1],
                );
            }
        }
    }

    const anchor_count = lengths[left_ancestry.len * column_count + right_ancestry.len];
    if (anchor_count == 0) return false;
    const anchor_bytes = std.math.mul(
        usize,
        anchor_count,
        @sizeOf(UnifyWeaveAnchor),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(anchor_bytes);
    const anchors = try allocator.alloc(UnifyWeaveAnchor, anchor_count);
    defer allocator.free(anchors);

    var left_offset = left_ancestry.len;
    var right_offset = right_ancestry.len;
    var anchor_offset = anchor_count;
    // Preserve Dart Sass's observable prefix-LCS tie break: when the two
    // predecessor lengths are equal, move left through the right ancestry.
    while (left_offset > 0 and right_offset > 0) {
        if (sharedUnifyWeaveAnchorMatches(
            left_ancestry[left_offset - 1],
            right_ancestry[right_offset - 1],
        )) {
            if (anchor_offset == 0) return error.InvalidSelector;
            anchor_offset -= 1;
            anchors[anchor_offset] = .{
                .left_index = left_offset - 1,
                .right_index = right_offset - 1,
            };
            left_offset -= 1;
            right_offset -= 1;
            continue;
        }
        const above = lengths[(left_offset - 1) * column_count + right_offset];
        const before = lengths[left_offset * column_count + right_offset - 1];
        if (above > before) {
            left_offset -= 1;
        } else {
            right_offset -= 1;
        }
    }
    if (anchor_offset != 0) return error.InvalidSelector;

    var varying_count: usize = 0;
    var left_start: usize = 0;
    var right_start: usize = 0;
    for (anchors) |anchor| {
        if (anchor.left_index < left_start or
            anchor.left_index >= left_ancestry.len or
            anchor.right_index < right_start or
            anchor.right_index >= right_ancestry.len)
        {
            return error.InvalidSelector;
        }
        const left_segment = left_ancestry[left_start..anchor.left_index];
        const right_segment = right_ancestry[right_start..anchor.right_index];
        if (!try sharedUnifyWeaveSegmentAvailable(
            left_segment,
            right_segment,
            context,
        )) return false;
        if (sharedUnifyWeaveSegmentVaries(left_segment, right_segment)) {
            varying_count = std.math.add(usize, varying_count, 1) catch
                return error.SelectorLimitExceeded;
        }
        left_start = anchor.left_index + 1;
        right_start = anchor.right_index + 1;
    }
    const left_tail = left_ancestry[left_start..];
    const right_tail = right_ancestry[right_start..];
    if (!try sharedUnifyWeaveSegmentAvailable(left_tail, right_tail, context)) {
        return false;
    }
    if (sharedUnifyWeaveSegmentVaries(left_tail, right_tail)) {
        varying_count = std.math.add(usize, varying_count, 1) catch
            return error.SelectorLimitExceeded;
    }

    if (builder.items.items.len >= builder.limits.max_selectors) {
        return error.SelectorLimitExceeded;
    }
    const remaining_selectors = builder.limits.max_selectors - builder.items.items.len;
    const output_count = try selectorPowerBounded(
        2,
        varying_count,
        remaining_selectors,
    );
    for (0..output_count) |ordinal| {
        try admitUnifyResult(
            builder,
            try renderSharedUnifyWeave(
                allocator,
                left_ancestry,
                right_ancestry,
                anchors,
                varying_count,
                ordinal,
                subject,
                context,
            ),
        );
    }
    return true;
}

fn sharedUnifyWeaveAnchorMatches(
    left: RelationComponent,
    right: RelationComponent,
) bool {
    return left.combinator == .descendant and
        right.combinator == .descendant and
        std.mem.eql(u8, left.compound, right.compound);
}

fn sharedUnifyWeaveSegmentAvailable(
    left: []const RelationComponent,
    right: []const RelationComponent,
    context: *UnifyContext,
) Error!bool {
    const left_rigid_start = sharedUnifyWeaveRigidStart(left) orelse return false;
    const right_rigid_start = sharedUnifyWeaveRigidStart(right) orelse return false;
    if (left_rigid_start < left.len and right_rigid_start < right.len) {
        return false;
    }
    for (left) |left_component| {
        for (right) |right_component| {
            if (try unifyWeaveCompoundsShareAnchor(
                left_component.compound,
                right_component.compound,
                context,
            )) return false;
        }
    }
    return true;
}

fn sharedUnifyWeaveRigidStart(
    components: []const RelationComponent,
) ?usize {
    var rigid_start = components.len;
    for (components, 0..) |component, index| {
        switch (component.combinator) {
            .descendant => if (rigid_start != components.len) return null,
            .child, .next_sibling, .following_sibling => if (rigid_start == components.len) {
                rigid_start = index;
            },
            .none => return null,
        }
    }
    return rigid_start;
}

fn sharedUnifyWeaveSegmentVaries(
    left: []const RelationComponent,
    right: []const RelationComponent,
) bool {
    const left_rigid_start = sharedUnifyWeaveRigidStart(left) orelse return false;
    const right_rigid_start = sharedUnifyWeaveRigidStart(right) orelse return false;
    return left_rigid_start > 0 and right_rigid_start > 0;
}

fn unifyWeaveCompoundAvailable(
    input: []const u8,
    context: *UnifyContext,
) Error!bool {
    var cursor: usize = 0;
    while (cursor < input.len) {
        try context.consume(1);
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        if (std.mem.indexOfScalar(u8, token, '\\') != null) return false;
        switch (token[0]) {
            '#', '%', '[', ':', '&' => return false,
            else => {},
        }
        cursor = end;
    }
    return cursor != 0;
}

fn unifyWeaveCompoundsShareAnchor(
    left: []const u8,
    right: []const u8,
    context: *UnifyContext,
) Error!bool {
    var left_cursor: usize = 0;
    while (left_cursor < left.len) {
        const left_end = try simpleTokenEnd(left, left_cursor);
        const left_token = left[left_cursor..left_end];
        var right_cursor: usize = 0;
        while (right_cursor < right.len) {
            try context.consume(1);
            const right_end = try simpleTokenEnd(right, right_cursor);
            const right_token = right[right_cursor..right_end];
            if (std.mem.eql(u8, left_token, right_token) or
                relationSimpleIsSuperselector(left_token, right_token) or
                relationSimpleIsSuperselector(right_token, left_token))
            {
                return true;
            }
            right_cursor = right_end;
        }
        left_cursor = left_end;
    }
    return false;
}

fn renderUnifyComplex(
    allocator: std.mem.Allocator,
    structure: RelationComplex,
    ancestor_replacements: ?[]const []u8,
    subject: []const u8,
    context: *UnifyContext,
) Error![]u8 {
    const ancestor_count = structure.components.len - 1;
    if (ancestor_replacements) |replacements| {
        if (replacements.len != ancestor_count) return error.InvalidSelector;
    }
    try context.reserveComponents(structure.components.len);
    var output_length: usize = 0;
    for (structure.components, 0..) |component, index| {
        try context.consume(1);
        const compound = if (index == ancestor_count)
            subject
        else if (ancestor_replacements) |replacements|
            replacements[index]
        else
            component.compound;
        output_length = std.math.add(usize, output_length, compound.len) catch
            return error.SelectorLimitExceeded;
        output_length = std.math.add(
            usize,
            output_length,
            unifyCombinatorBytes(component.combinator).len,
        ) catch return error.SelectorLimitExceeded;
    }
    if (output_length == 0) return error.InvalidSelector;
    if (output_length > context.limits.max_bytes) return error.SelectorLimitExceeded;
    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);
    var offset: usize = 0;
    for (structure.components, 0..) |component, index| {
        const compound = if (index == ancestor_count)
            subject
        else if (ancestor_replacements) |replacements|
            replacements[index]
        else
            component.compound;
        std.mem.copyForwards(u8, output[offset .. offset + compound.len], compound);
        offset += compound.len;
        const combinator = unifyCombinatorBytes(component.combinator);
        std.mem.copyForwards(u8, output[offset .. offset + combinator.len], combinator);
        offset += combinator.len;
    }
    std.debug.assert(offset == output.len);
    try validateComplex(output, false);
    return output;
}

fn renderUnifyWeave(
    allocator: std.mem.Allocator,
    first_ancestry: []const RelationComponent,
    second_ancestry: []const RelationComponent,
    subject: []const u8,
    context: *UnifyContext,
) Error![]u8 {
    const ancestry_count = std.math.add(
        usize,
        first_ancestry.len,
        second_ancestry.len,
    ) catch return error.SelectorLimitExceeded;
    const component_count = std.math.add(usize, ancestry_count, 1) catch
        return error.SelectorLimitExceeded;
    try context.reserveComponents(component_count);
    if (subject.len == 0) return error.InvalidSelector;
    try context.consume(1);
    var output_length = subject.len;
    const ancestries = [_][]const RelationComponent{
        first_ancestry,
        second_ancestry,
    };
    for (ancestries) |ancestry| {
        for (ancestry) |component| {
            try context.consume(1);
            if (component.combinator == .none) {
                return error.UnsupportedSelectorUnification;
            }
            output_length = std.math.add(
                usize,
                output_length,
                component.compound.len,
            ) catch return error.SelectorLimitExceeded;
            output_length = std.math.add(
                usize,
                output_length,
                unifyCombinatorBytes(component.combinator).len,
            ) catch return error.SelectorLimitExceeded;
        }
    }
    if (output_length > context.limits.max_bytes) {
        return error.SelectorLimitExceeded;
    }
    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);
    var offset: usize = 0;
    for (ancestries) |ancestry| {
        for (ancestry) |component| {
            std.mem.copyForwards(
                u8,
                output[offset .. offset + component.compound.len],
                component.compound,
            );
            offset += component.compound.len;
            const combinator = unifyCombinatorBytes(component.combinator);
            std.mem.copyForwards(
                u8,
                output[offset .. offset + combinator.len],
                combinator,
            );
            offset += combinator.len;
        }
    }
    std.mem.copyForwards(u8, output[offset .. offset + subject.len], subject);
    offset += subject.len;
    std.debug.assert(offset == output.len);
    try validateComplex(output, false);
    return output;
}

fn renderSharedUnifyWeave(
    allocator: std.mem.Allocator,
    left_ancestry: []const RelationComponent,
    right_ancestry: []const RelationComponent,
    anchors: []const UnifyWeaveAnchor,
    varying_count: usize,
    ordinal: usize,
    subject: []const u8,
    context: *UnifyContext,
) Error![]u8 {
    const ancestry_count = std.math.add(
        usize,
        left_ancestry.len,
        right_ancestry.len,
    ) catch return error.SelectorLimitExceeded;
    if (anchors.len > ancestry_count) return error.InvalidSelector;
    const unique_ancestry_count = ancestry_count - anchors.len;
    const component_count = std.math.add(
        usize,
        unique_ancestry_count,
        1,
    ) catch return error.SelectorLimitExceeded;
    try context.reserveComponents(component_count);
    if (subject.len == 0) return error.InvalidSelector;
    try context.consume(1);

    var output_length = subject.len;
    const ancestries = [_][]const RelationComponent{
        left_ancestry,
        right_ancestry,
    };
    for (ancestries) |ancestry| {
        for (ancestry) |component| {
            try context.consume(1);
            const combinator = unifyCombinatorBytes(component.combinator);
            if (combinator.len == 0) return error.InvalidSelector;
            output_length = std.math.add(
                usize,
                output_length,
                component.compound.len,
            ) catch return error.SelectorLimitExceeded;
            output_length = std.math.add(usize, output_length, combinator.len) catch
                return error.SelectorLimitExceeded;
        }
    }
    for (anchors) |anchor| {
        if (anchor.left_index >= left_ancestry.len or
            anchor.right_index >= right_ancestry.len or
            !sharedUnifyWeaveAnchorMatches(
                left_ancestry[anchor.left_index],
                right_ancestry[anchor.right_index],
            ))
        {
            return error.InvalidSelector;
        }
        try context.consume(1);
        const duplicate_length = std.math.add(
            usize,
            left_ancestry[anchor.left_index].compound.len,
            unifyCombinatorBytes(
                left_ancestry[anchor.left_index].combinator,
            ).len,
        ) catch return error.SelectorLimitExceeded;
        if (duplicate_length > output_length) return error.InvalidSelector;
        output_length -= duplicate_length;
    }
    if (output_length > context.limits.max_bytes) {
        return error.SelectorLimitExceeded;
    }
    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);

    var offset: usize = 0;
    var left_start: usize = 0;
    var right_start: usize = 0;
    var choice_divisor: usize = 1;
    var varying_seen: usize = 0;
    for (anchors) |anchor| {
        if (anchor.left_index < left_start or
            anchor.right_index < right_start)
        {
            return error.InvalidSelector;
        }
        try writeSharedUnifyWeaveSegment(
            output,
            &offset,
            left_ancestry[left_start..anchor.left_index],
            right_ancestry[right_start..anchor.right_index],
            ordinal,
            &choice_divisor,
            &varying_seen,
            varying_count,
        );
        try writeSharedUnifyWeaveComponents(
            output,
            &offset,
            left_ancestry[anchor.left_index .. anchor.left_index + 1],
        );
        left_start = anchor.left_index + 1;
        right_start = anchor.right_index + 1;
    }
    try writeSharedUnifyWeaveSegment(
        output,
        &offset,
        left_ancestry[left_start..],
        right_ancestry[right_start..],
        ordinal,
        &choice_divisor,
        &varying_seen,
        varying_count,
    );
    if (varying_seen != varying_count) return error.InvalidSelector;
    if (offset > output.len or subject.len > output.len - offset) {
        return error.InvalidSelector;
    }
    std.mem.copyForwards(u8, output[offset .. offset + subject.len], subject);
    offset += subject.len;
    if (offset != output.len) return error.InvalidSelector;
    try validateComplex(output, false);
    return output;
}

fn writeSharedUnifyWeaveSegment(
    output: []u8,
    offset: *usize,
    left: []const RelationComponent,
    right: []const RelationComponent,
    ordinal: usize,
    choice_divisor: *usize,
    varying_seen: *usize,
    varying_count: usize,
) Error!void {
    const left_rigid_start = sharedUnifyWeaveRigidStart(left) orelse
        return error.InvalidSelector;
    const right_rigid_start = sharedUnifyWeaveRigidStart(right) orelse
        return error.InvalidSelector;
    if (left_rigid_start < left.len and right_rigid_start < right.len) {
        return error.InvalidSelector;
    }
    const left_flexible = left[0..left_rigid_start];
    const right_flexible = right[0..right_rigid_start];
    var right_first = false;
    if (left_flexible.len > 0 and right_flexible.len > 0) {
        // Each segment remains a whole chunk. The earliest varying segment is
        // the least-significant choice so provider result order stays exact.
        right_first = (ordinal / choice_divisor.*) % 2 == 1;
        varying_seen.* = std.math.add(usize, varying_seen.*, 1) catch
            return error.SelectorLimitExceeded;
        if (varying_seen.* < varying_count) {
            choice_divisor.* = std.math.mul(usize, choice_divisor.*, 2) catch
                return error.SelectorLimitExceeded;
        }
    }
    if (right_first) {
        try writeSharedUnifyWeaveComponents(output, offset, right_flexible);
        try writeSharedUnifyWeaveComponents(output, offset, left_flexible);
    } else {
        try writeSharedUnifyWeaveComponents(output, offset, left_flexible);
        try writeSharedUnifyWeaveComponents(output, offset, right_flexible);
    }
    try writeSharedUnifyWeaveComponents(output, offset, left[left_rigid_start..]);
    try writeSharedUnifyWeaveComponents(output, offset, right[right_rigid_start..]);
}

fn writeSharedUnifyWeaveComponents(
    output: []u8,
    offset: *usize,
    components: []const RelationComponent,
) Error!void {
    for (components) |component| {
        const combinator = unifyCombinatorBytes(component.combinator);
        if (combinator.len == 0) return error.InvalidSelector;
        const compound_end = std.math.add(
            usize,
            offset.*,
            component.compound.len,
        ) catch return error.SelectorLimitExceeded;
        const next = std.math.add(usize, compound_end, combinator.len) catch
            return error.SelectorLimitExceeded;
        if (next > output.len) return error.InvalidSelector;
        std.mem.copyForwards(
            u8,
            output[offset.*..compound_end],
            component.compound,
        );
        std.mem.copyForwards(u8, output[compound_end..next], combinator);
        offset.* = next;
    }
}

fn unifyCombinatorBytes(combinator: RelationCombinator) []const u8 {
    return switch (combinator) {
        .none => "",
        .descendant => " ",
        .child => " > ",
        .next_sibling => " + ",
        .following_sibling => " ~ ",
    };
}

fn extensionLeadingCombinatorBytes(
    combinator: ?RelationCombinator,
) []const u8 {
    const active = combinator orelse return "";
    return switch (active) {
        .child => "> ",
        .next_sibling => "+ ",
        .following_sibling => "~ ",
        .none, .descendant => unreachable,
    };
}

fn unifyCompound(
    allocator: std.mem.Allocator,
    left_input: []const u8,
    right_input: []const u8,
    context: *UnifyContext,
) Error!?[]u8 {
    if (try relationCompoundContainsBogusNth(context, left_input, 0) or
        try relationCompoundContainsBogusNth(context, right_input, 0))
    {
        return null;
    }
    var left = try loadUnifyCompound(allocator, left_input, context);
    defer left.deinit();
    var right = try loadUnifyCompound(allocator, right_input, context);
    defer right.deinit();

    for (right.items.items) |right_item| {
        if (!try unifySimple(&left, right_item, context)) return null;
    }

    var output_length: usize = 0;
    for (left.items.items) |item| {
        try context.consume(1);
        output_length = std.math.add(usize, output_length, item.len) catch
            return error.SelectorLimitExceeded;
    }
    if (output_length == 0) return error.InvalidSelector;
    if (output_length > context.limits.max_bytes) return error.SelectorLimitExceeded;
    try context.reserveTemporary(output_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);
    var offset: usize = 0;
    for (left.items.items) |item| {
        std.mem.copyForwards(u8, output[offset .. offset + item.len], item);
        offset += item.len;
    }
    std.debug.assert(offset == output.len);
    try validateCompound(output, false);
    return @as(?[]u8, output);
}

fn loadUnifyCompound(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *UnifyContext,
) Error!UnifyCompound {
    var result = UnifyCompound{ .allocator = allocator };
    errdefer result.deinit();
    var cursor: usize = 0;
    while (cursor < input.len) {
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        if (token[0] == ':' and normalizedPseudoUnavailableForUnify(token)) {
            return error.UnsupportedSelectorUnification;
        }
        try context.consume(1);
        try context.reserveComponents(1);
        const reservation = std.math.add(
            usize,
            token.len,
            @sizeOf([]u8),
        ) catch return error.SelectorLimitExceeded;
        try context.reserveTemporary(reservation);
        const owned = if (token[0] == '[')
            try normalizeAttribute(allocator, token, context.limits.max_bytes)
        else
            try allocator.dupe(u8, token);
        result.items.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
        cursor = end;
    }
    if (result.items.items.len == 0) return error.InvalidSelector;
    return result;
}

fn unsupportedUnifyPseudo(token: []const u8) bool {
    if (token.len == 0 or token[0] != ':') return false;
    const opening = findUnescapedByte(token, '(');
    var name_start: usize = 1;
    if (name_start < token.len and token[name_start] == ':') name_start += 1;
    const name = token[name_start .. opening orelse token.len];
    if (std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "host-context"))
    {
        return true;
    }
    return opening != null and relationPseudoElementName(token) != null;
}

fn normalizedPseudoUnavailableForUnify(token: []const u8) bool {
    if (unsupportedUnifyPseudo(token)) return true;
    return findUnescapedByte(token, '(') != null and
        std.mem.indexOfScalar(u8, token, '\\') != null and
        !functionalPseudoHasAdmittedOpaqueName(token);
}

fn unifySimple(
    compound: *UnifyCompound,
    candidate: []const u8,
    context: *UnifyContext,
) Error!bool {
    if (try unifyExactIndex(compound, candidate, context) != null) return true;
    if (relationQualifiedName(candidate) != null) {
        return unifyQualified(compound, candidate, context);
    }
    if (candidate[0] == '#') return unifyId(compound, candidate, context);
    if (candidate[0] == ':') return unifyPseudo(compound, candidate, context);
    return insertUnifyClone(
        compound,
        try firstPseudoIndex(compound, context),
        candidate,
        context,
    );
}

fn unifyExactIndex(
    compound: *const UnifyCompound,
    candidate: []const u8,
    context: *UnifyContext,
) Error!?usize {
    for (compound.items.items, 0..) |item, index| {
        try context.consume(1);
        if (std.mem.eql(u8, item, candidate)) return index;
    }
    return null;
}

fn unifyQualified(
    compound: *UnifyCompound,
    candidate: []const u8,
    context: *UnifyContext,
) Error!bool {
    const candidate_name = relationQualifiedName(candidate) orelse unreachable;
    var existing_index: ?usize = null;
    for (compound.items.items, 0..) |item, index| {
        try context.consume(1);
        if (relationQualifiedName(item) != null) {
            existing_index = index;
            break;
        }
    }
    const index = existing_index orelse {
        const wildcard_namespace = candidate_name.namespace != null and
            std.mem.eql(u8, candidate_name.namespace.?, "*");
        if (std.mem.eql(u8, candidate_name.name, "*") and
            (candidate_name.namespace == null or wildcard_namespace))
        {
            return true;
        }
        return insertUnifyClone(compound, 0, candidate, context);
    };
    const merged = try unifyQualifiedNames(
        compound.allocator,
        compound.items.items[index],
        candidate,
        context,
    );
    switch (merged) {
        .conflict => return false,
        .keep => return true,
        .replace => |replacement| {
            compound.allocator.free(compound.items.items[index]);
            compound.items.items[index] = replacement;
            return true;
        },
    }
}

fn unifyQualifiedNames(
    allocator: std.mem.Allocator,
    left_bytes: []const u8,
    right_bytes: []const u8,
    context: *UnifyContext,
) Error!QualifiedUnification {
    const left = relationQualifiedName(left_bytes) orelse unreachable;
    const right = relationQualifiedName(right_bytes) orelse unreachable;
    const namespace = intersectNamespaces(left.namespace, right.namespace);
    const result_namespace = switch (namespace) {
        .conflict => return .conflict,
        .value => |value| value,
    };
    const result_name = if (std.mem.eql(u8, left.name, right.name))
        left.name
    else if (std.mem.eql(u8, left.name, "*"))
        right.name
    else if (std.mem.eql(u8, right.name, "*"))
        left.name
    else
        return .conflict;
    if (relationNamespacesEqual(left.namespace, result_namespace) and
        std.mem.eql(u8, left.name, result_name))
    {
        return .keep;
    }
    const length = if (result_namespace) |value| blk: {
        const prefix_length = std.math.add(usize, value.len, 1) catch
            return error.SelectorLimitExceeded;
        break :blk std.math.add(usize, prefix_length, result_name.len) catch
            return error.SelectorLimitExceeded;
    } else result_name.len;
    if (length > context.limits.max_bytes) return error.SelectorLimitExceeded;
    try context.reserveTemporary(length);
    const owned = try allocator.alloc(u8, length);
    if (result_namespace) |value| {
        std.mem.copyForwards(u8, owned[0..value.len], value);
        owned[value.len] = '|';
        std.mem.copyForwards(u8, owned[value.len + 1 ..], result_name);
    } else {
        std.mem.copyForwards(u8, owned, result_name);
    }
    return .{ .replace = owned };
}

fn intersectNamespaces(
    left: ?[]const u8,
    right: ?[]const u8,
) NamespaceIntersection {
    const left_wildcard = left != null and std.mem.eql(u8, left.?, "*");
    const right_wildcard = right != null and std.mem.eql(u8, right.?, "*");
    if (left_wildcard) return .{ .value = right };
    if (right_wildcard) return .{ .value = left };
    if (left == null or right == null) {
        if (left == null and right == null) return .{ .value = null };
        return .conflict;
    }
    if (!std.mem.eql(u8, left.?, right.?)) return .conflict;
    return .{ .value = left };
}

fn unifyId(
    compound: *UnifyCompound,
    candidate: []const u8,
    context: *UnifyContext,
) Error!bool {
    for (compound.items.items) |item| {
        try context.consume(1);
        if (item[0] == '#') return false;
    }
    return insertUnifyClone(
        compound,
        try firstPseudoIndex(compound, context),
        candidate,
        context,
    );
}

fn unifyPseudo(
    compound: *UnifyCompound,
    candidate: []const u8,
    context: *UnifyContext,
) Error!bool {
    if (relationPseudoElementName(candidate) != null) {
        for (compound.items.items) |item| {
            try context.consume(1);
            if (relationPseudoElementName(item) != null) {
                return relationPseudoElementsEquivalent(item, candidate);
            }
        }
        return insertUnifyClone(compound, compound.items.items.len, candidate, context);
    }
    for (compound.items.items, 0..) |item, index| {
        try context.consume(1);
        if (relationPseudoElementName(item) != null) {
            return insertUnifyClone(compound, index, candidate, context);
        }
    }
    return insertUnifyClone(compound, compound.items.items.len, candidate, context);
}

fn firstPseudoIndex(
    compound: *const UnifyCompound,
    context: *UnifyContext,
) Error!usize {
    for (compound.items.items, 0..) |item, index| {
        try context.consume(1);
        if (item[0] == ':') return index;
    }
    return compound.items.items.len;
}

fn insertUnifyClone(
    compound: *UnifyCompound,
    index: usize,
    candidate: []const u8,
    context: *UnifyContext,
) Error!bool {
    const reservation = std.math.add(
        usize,
        candidate.len,
        @sizeOf([]u8),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveComponents(1);
    try context.reserveTemporary(reservation);
    const owned = try compound.allocator.dupe(u8, candidate);
    compound.items.insert(compound.allocator, index, owned) catch |err| {
        compound.allocator.free(owned);
        return err;
    };
    return true;
}

const RelationCombinator = enum {
    none,
    descendant,
    child,
    next_sibling,
    following_sibling,
};

const RelationComponent = struct {
    compound: []const u8,
    combinator: RelationCombinator,
};

const RelationComplex = struct {
    leading_combinator: ?RelationCombinator,
    components: []RelationComponent,
};

const RelationComplexList = struct {
    allocator: std.mem.Allocator,
    items: []RelationComplex,

    fn deinit(self: *RelationComplexList) void {
        for (self.items) |item| self.allocator.free(item.components);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const RelationContext = UnifyContext;

const SelectorUsage = struct {
    selectors: usize,
    bytes: usize,
};

/// Returns whether every selector matched by `sub_input` is also matched by
/// `super_input`. This first native slice owns structural selector lists,
/// compounds, namespaces, and the standard combinators. Relation inference
/// for normalized selector-list functional pseudos is recursive and bounded.
/// Formula-exact nth-child functions expose their optional selector subjects
/// without equating semantically equivalent An+B spellings. Non-selector
/// functions, host semantics, and functional pseudo-elements remain explicitly
/// unavailable rather than guessed. Admitted identifier, simple-pseudo, and
/// attribute escapes are canonical before this stage.
pub fn isSuperselector(
    allocator: std.mem.Allocator,
    super_input: []const u8,
    sub_input: []const u8,
    limits: Limits,
) Error!bool {
    if (limits.max_selectors == 0 or limits.max_bytes == 0 or
        limits.max_complex_components == 0 or limits.max_temporary_bytes == 0 or
        limits.max_relation_operations == 0)
    {
        return error.SelectorLimitExceeded;
    }

    var super_selectors = try parseInternal(allocator, super_input, limits, false);
    defer super_selectors.deinit();
    const super_usage = try selectorUsage(&super_selectors);
    var sub_limits = limits;
    sub_limits.max_selectors -= super_usage.selectors;
    sub_limits.max_bytes -= super_usage.bytes;
    var sub_selectors = try parseInternal(allocator, sub_input, sub_limits, false);
    defer sub_selectors.deinit();

    var context = RelationContext{ .allocator = allocator, .limits = limits };
    const lists_equal = try relationListsEqual(
        &context,
        &super_selectors,
        &sub_selectors,
    );
    var super_complexes = try buildRelationComplexList(
        allocator,
        &super_selectors,
        &context,
    );
    defer super_complexes.deinit();
    var sub_complexes = try buildRelationComplexList(
        allocator,
        &sub_selectors,
        &context,
    );
    defer sub_complexes.deinit();

    if (lists_equal) {
        var requires_coverage_check = false;
        for (super_selectors.items) |selector_item| {
            if (try relationSelectorContainsRelativeFunctionalSelector(
                &context,
                selector_item,
                0,
            )) {
                requires_coverage_check = true;
                break;
            }
        }
        for (super_complexes.items) |complex| {
            if (complex.leading_combinator != null or
                complex.components[complex.components.len - 1].combinator != .none)
            {
                return false;
            }
        }
        if (!requires_coverage_check) return true;
    }

    for (sub_complexes.items) |sub_complex| {
        var matched = false;
        for (super_complexes.items) |super_complex| {
            if (try relationComplexIsSuperselector(
                &context,
                super_complex,
                sub_complex,
            )) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

fn selectorUsage(list: *const SelectorList) Error!SelectorUsage {
    var bytes: usize = 0;
    for (list.items) |item| {
        bytes = std.math.add(usize, bytes, item.len) catch
            return error.SelectorLimitExceeded;
    }
    return .{ .selectors = list.selector_count, .bytes = bytes };
}

fn relationListsEqual(
    context: *RelationContext,
    left: *const SelectorList,
    right: *const SelectorList,
) Error!bool {
    try context.consume(1);
    if (left.items.len != right.items.len) return false;
    for (left.items, right.items) |left_item, right_item| {
        try context.consume(1);
        if (!std.mem.eql(u8, left_item, right_item)) return false;
    }
    return true;
}

fn buildRelationComplexList(
    allocator: std.mem.Allocator,
    selectors: *const SelectorList,
    context: *RelationContext,
) Error!RelationComplexList {
    const list_bytes = std.math.mul(
        usize,
        selectors.items.len,
        @sizeOf(RelationComplex),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(list_bytes);
    const items = try allocator.alloc(RelationComplex, selectors.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| allocator.free(item.components);
        allocator.free(items);
    }
    for (selectors.items, 0..) |selector, index| {
        items[index] = try buildRelationComplex(allocator, selector, context);
        initialized += 1;
    }
    return .{ .allocator = allocator, .items = items };
}

const RelationScan = struct {
    leading_combinator: ?RelationCombinator,
    trailing_combinator: bool,
    component_count: usize,
};

fn buildRelationComplex(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *RelationContext,
) Error!RelationComplex {
    const counted = try scanRelationComplex(input, null);
    try context.reserveComponents(counted.component_count);
    const component_bytes = std.math.mul(
        usize,
        counted.component_count,
        @sizeOf(RelationComponent),
    ) catch return error.SelectorLimitExceeded;
    try context.reserveTemporary(component_bytes);
    const components = try allocator.alloc(RelationComponent, counted.component_count);
    errdefer allocator.free(components);
    const filled = try scanRelationComplex(input, components);
    std.debug.assert(filled.component_count == counted.component_count);
    std.debug.assert(filled.leading_combinator == counted.leading_combinator);
    std.debug.assert(filled.trailing_combinator == counted.trailing_combinator);
    return .{
        .leading_combinator = filled.leading_combinator,
        .components = components,
    };
}

fn scanRelationComplex(
    input: []const u8,
    destination: ?[]RelationComponent,
) Error!RelationScan {
    var index = skipWhitespace(input, 0);
    if (index == input.len) return error.InvalidSelector;
    var leading_combinator: ?RelationCombinator = null;
    const leading_length = explicitCombinatorLength(input, index);
    if (leading_length != 0) {
        leading_combinator = switch (input[index]) {
            '>' => .child,
            '+' => .next_sibling,
            '~' => .following_sibling,
            else => unreachable,
        };
        index = skipWhitespace(input, index + leading_length);
        if (index == input.len) return error.InvalidSelector;
    }

    var count: usize = 0;
    var trailing_combinator = false;
    while (index < input.len) {
        const end = try compoundEnd(input, index);
        if (end == index) return error.InvalidSelector;
        const after_space = skipWhitespace(input, end);
        const saw_space = after_space != end;
        var next = after_space;
        var combinator: RelationCombinator = .none;
        if (next < input.len) {
            const explicit_length = explicitCombinatorLength(input, next);
            if (explicit_length != 0) {
                combinator = switch (input[next]) {
                    '>' => .child,
                    '+' => .next_sibling,
                    '~' => .following_sibling,
                    else => unreachable,
                };
                next = skipWhitespace(input, next + explicit_length);
            } else if (saw_space) {
                combinator = .descendant;
            } else {
                return error.InvalidSelector;
            }
        }
        if (destination) |components| {
            if (count >= components.len) return error.InvalidSelector;
            components[count] = .{
                .compound = input[index..end],
                .combinator = combinator,
            };
        }
        count += 1;
        if (next == input.len) {
            trailing_combinator = combinator != .none;
            break;
        }
        index = next;
    }
    if (count == 0) return error.InvalidSelector;
    if (destination) |components| {
        if (count != components.len) return error.InvalidSelector;
    }
    return .{
        .leading_combinator = leading_combinator,
        .trailing_combinator = trailing_combinator,
        .component_count = count,
    };
}

fn relationComplexIsSuperselector(
    context: *RelationContext,
    super_complex: RelationComplex,
    sub_complex: RelationComplex,
) Error!bool {
    try context.consume(1);
    if (super_complex.leading_combinator != null or
        sub_complex.leading_combinator != null)
    {
        return false;
    }
    if (super_complex.components[super_complex.components.len - 1].combinator != .none or
        sub_complex.components[sub_complex.components.len - 1].combinator != .none)
    {
        return false;
    }

    var super_index: usize = 0;
    var sub_index: usize = 0;
    var previous_combinator: ?RelationCombinator = null;
    while (true) {
        try context.consume(1);
        const remaining_super = super_complex.components.len - super_index;
        const remaining_sub = sub_complex.components.len - sub_index;
        if (remaining_super == 0 or remaining_sub == 0 or remaining_super > remaining_sub) {
            return false;
        }
        const super_component = super_complex.components[super_index];
        if (remaining_super == 1) {
            return relationCompoundIsSuperselector(
                context,
                super_component.compound,
                sub_complex.components[sub_complex.components.len - 1].compound,
            );
        }

        var match_index = sub_index;
        while (match_index < sub_complex.components.len - 1) : (match_index += 1) {
            if (try relationCompoundIsSuperselector(
                context,
                super_component.compound,
                sub_complex.components[match_index].compound,
            )) break;
        }
        if (match_index == sub_complex.components.len - 1) return false;
        if (!relationPreviousCombinatorCompatible(
            previous_combinator,
            sub_complex.components[sub_index..match_index],
        )) return false;
        if (!relationIsSupercombinator(
            super_component.combinator,
            sub_complex.components[match_index].combinator,
        )) return false;

        previous_combinator = super_component.combinator;
        super_index += 1;
        sub_index = match_index + 1;
        if (super_complex.components.len - super_index == 1) {
            if (super_component.combinator == .following_sibling) {
                for (sub_complex.components[sub_index .. sub_complex.components.len - 1]) |component| {
                    if (!relationIsSupercombinator(
                        .following_sibling,
                        component.combinator,
                    )) return false;
                }
            } else if (super_component.combinator != .descendant and
                sub_complex.components.len - sub_index > 1)
            {
                return false;
            }
        }
    }
}

fn relationPreviousCombinatorCompatible(
    previous: ?RelationCombinator,
    parents: []const RelationComponent,
) bool {
    if (parents.len == 0 or previous == null or previous.? == .descendant) {
        return true;
    }
    if (previous.? != .following_sibling) return false;
    for (parents) |parent| {
        if (parent.combinator != .following_sibling and
            parent.combinator != .next_sibling)
        {
            return false;
        }
    }
    return true;
}

fn relationIsSupercombinator(
    super_combinator: RelationCombinator,
    sub_combinator: RelationCombinator,
) bool {
    if (super_combinator == sub_combinator) return true;
    if (super_combinator == .descendant and sub_combinator == .child) return true;
    return super_combinator == .following_sibling and sub_combinator == .next_sibling;
}

fn relationCompoundIsSuperselector(
    context: *RelationContext,
    super_compound: []const u8,
    sub_compound: []const u8,
) Error!bool {
    try context.consume(1);
    const super_pseudo_element = try relationPseudoElement(context, super_compound);
    const sub_pseudo_element = try relationPseudoElement(context, sub_compound);
    if (super_pseudo_element) |super_pseudo| {
        const sub_pseudo = sub_pseudo_element orelse return false;
        if (!relationPseudoElementsEquivalent(super_pseudo, sub_pseudo)) {
            if (relationSimpleRequiresInference(super_pseudo) or
                relationSimpleRequiresInference(sub_pseudo))
            {
                return error.UnsupportedSelectorRelation;
            }
            return false;
        }
    } else if (sub_pseudo_element != null) {
        return false;
    }
    const super_count = try relationSimpleCount(super_compound);
    const sub_count = try relationSimpleCount(sub_compound);
    const sub_contains_subject_function =
        try relationCompoundContainsSubjectSelectorListPseudo(sub_compound);
    if (super_count > sub_count and !sub_contains_subject_function) {
        return false;
    }

    var super_cursor: usize = 0;
    while (super_cursor < super_compound.len) {
        const super_end = try simpleTokenEnd(super_compound, super_cursor);
        const super_simple = super_compound[super_cursor..super_end];
        const super_function = try relationSelectorListPseudo(super_simple);
        const requires_functional_coverage = super_function != null and
            try relationFunctionalPseudoContainsRelativeSelector(
                context,
                super_simple,
                0,
            );
        var exact = false;
        var sub_cursor: usize = 0;
        while (sub_cursor < sub_compound.len) {
            try context.consume(1);
            const sub_end = try simpleTokenEnd(sub_compound, sub_cursor);
            if (!requires_functional_coverage and
                std.mem.eql(u8, super_simple, sub_compound[sub_cursor..sub_end]))
            {
                exact = true;
                break;
            }
            sub_cursor = sub_end;
        }
        if (!exact) {
            var semantic_match = false;
            var ambiguous_sub = false;
            if (super_function) |functional_super| {
                sub_cursor = 0;
                while (sub_cursor < sub_compound.len) {
                    try context.consume(1);
                    const sub_end = try simpleTokenEnd(sub_compound, sub_cursor);
                    if (try relationSelectorListPseudo(
                        sub_compound[sub_cursor..sub_end],
                    )) |functional_sub| {
                        if (try relationSelectorListPseudosAreSuperselector(
                            context,
                            functional_super,
                            functional_sub,
                        )) {
                            semantic_match = true;
                            break;
                        }
                    }
                    sub_cursor = sub_end;
                }
                if (!semantic_match and
                    relationSelectorListPseudoIsPositive(functional_super.kind))
                {
                    try context.enterSelectorListPseudo();
                    defer context.leaveSelectorListPseudo();
                    semantic_match = try relationSelectorListTextIsSuperselector(
                        context,
                        functional_super.arguments,
                        sub_compound,
                        .{ .positive_sub_relative_subject = true },
                    );
                }
            } else if (try relationFunctionalPseudoIsKnownCaseMismatch(super_simple)) {
                return false;
            } else if (relationSimpleRequiresInference(super_simple)) {
                return error.UnsupportedSelectorRelation;
            } else {
                if (super_simple[0] == '[' and
                    !sub_contains_subject_function)
                {
                    return false;
                }
                sub_cursor = 0;
                while (sub_cursor < sub_compound.len) {
                    try context.consume(1);
                    const sub_end = try simpleTokenEnd(sub_compound, sub_cursor);
                    const sub_simple = sub_compound[sub_cursor..sub_end];
                    if (relationSimpleIsSuperselector(super_simple, sub_simple)) {
                        semantic_match = true;
                        break;
                    }
                    if (try relationSelectorListPseudo(sub_simple)) |functional_sub| {
                        if (relationSelectorListPseudoExposesSubject(functional_sub)) {
                            try context.enterSelectorListPseudo();
                            defer context.leaveSelectorListPseudo();
                            if (try relationSelectorListTextIsSuperselector(
                                context,
                                super_simple,
                                functional_sub.arguments,
                                .{ .positive_sub_relative_subject = true },
                            )) {
                                semantic_match = true;
                                break;
                            }
                        }
                    } else if (!try relationFunctionalPseudoIsKnownCaseMismatch(sub_simple)) {
                        ambiguous_sub = ambiguous_sub or
                            relationSimpleRequiresInference(sub_simple);
                    }
                    sub_cursor = sub_end;
                }
            }
            if (!semantic_match and ambiguous_sub) {
                return error.UnsupportedSelectorRelation;
            }
            if (!semantic_match) return false;
        }
        super_cursor = super_end;
    }
    return true;
}

const RelationFunctionalPseudoSyntax = struct {
    name: []const u8,
    arguments: []const u8,
};

const RelationSelectorListPseudo = struct {
    kind: SelectorListPseudoKind,
    arguments: []const u8,
    formula: ?[]const u8 = null,
};

fn relationFunctionalPseudoSyntax(
    input: []const u8,
) Error!?RelationFunctionalPseudoSyntax {
    if (input.len < 4 or input[0] != ':' or input[1] == ':') return null;
    const opening = findUnescapedByte(input, '(') orelse return null;
    if (try matchingParenEnd(input, opening) != input.len) {
        return error.InvalidSelector;
    }
    return .{
        .name = input[1..opening],
        .arguments = input[opening + 1 .. input.len - 1],
    };
}

fn relationSelectorListPseudo(
    input: []const u8,
) Error!?RelationSelectorListPseudo {
    const syntax = try relationFunctionalPseudoSyntax(input) orelse return null;
    const kind = selectorListPseudoKind(syntax.name) orelse return null;
    if (selectorListPseudoIsNth(kind)) {
        const parsed = try parseNthSelectorArguments(syntax.arguments);
        return .{
            .kind = kind,
            .arguments = parsed.selector_arguments orelse "",
            .formula = syntax.arguments[parsed.formula_start..parsed.formula_end],
        };
    }
    return .{ .kind = kind, .arguments = syntax.arguments };
}

fn relationFunctionalPseudoIsKnownCaseMismatch(input: []const u8) Error!bool {
    const syntax = try relationFunctionalPseudoSyntax(input) orelse return false;
    if (selectorListPseudoKind(syntax.name) != null or
        opaqueFunctionalPseudoKind(syntax.name) != null)
    {
        return false;
    }
    return selectorListPseudoKindIgnoreCase(syntax.name) != null or
        opaqueFunctionalPseudoKindIgnoreCase(syntax.name) != null;
}

fn relationFunctionalPseudoIsAdmittedOpaque(input: []const u8) Error!bool {
    const syntax = try relationFunctionalPseudoSyntax(input) orelse return false;
    return opaqueFunctionalPseudoKind(syntax.name) != null;
}

fn relationSelectorListPseudoIsPositive(kind: SelectorListPseudoKind) bool {
    return switch (kind) {
        .is, .where, .matches, .any, .webkit_any, .moz_any => true,
        .not, .has, .nth_child, .nth_last_child => false,
    };
}

fn relationSelectorListPseudoExposesSubject(
    function: RelationSelectorListPseudo,
) bool {
    return relationSelectorListPseudoIsPositive(function.kind) or
        (selectorListPseudoIsNth(function.kind) and function.arguments.len != 0);
}

fn relationSelectorListPseudosAreSuperselector(
    context: *RelationContext,
    super_function: RelationSelectorListPseudo,
    sub_function: RelationSelectorListPseudo,
) Error!bool {
    try context.enterSelectorListPseudo();
    defer context.leaveSelectorListPseudo();
    if (selectorListPseudoIsNth(super_function.kind) or
        selectorListPseudoIsNth(sub_function.kind))
    {
        if (super_function.kind != sub_function.kind or
            super_function.formula == null or sub_function.formula == null or
            !std.mem.eql(
                u8,
                super_function.formula.?,
                sub_function.formula.?,
            ) or
            (super_function.arguments.len == 0) !=
                (sub_function.arguments.len == 0))
        {
            return false;
        }
        if (super_function.arguments.len == 0) return true;
        if (try relationSelectorListPseudoHasBogusCombinator(
            context,
            super_function,
        ) or try relationSelectorListPseudoHasBogusCombinator(
            context,
            sub_function,
        )) {
            return false;
        }
        return relationSelectorListTextIsSuperselector(
            context,
            super_function.arguments,
            sub_function.arguments,
            .{ .positive_sub_relative_subject = true },
        );
    }
    if (relationSelectorListPseudoIsPositive(super_function.kind) and
        relationSelectorListPseudoIsPositive(sub_function.kind))
    {
        return relationSelectorListTextIsSuperselector(
            context,
            super_function.arguments,
            sub_function.arguments,
            .{ .positive_sub_relative_subject = true },
        );
    }
    if (super_function.kind == .has and sub_function.kind == .has) {
        return relationSelectorListTextIsSuperselector(
            context,
            super_function.arguments,
            sub_function.arguments,
            .{},
        );
    }
    if (super_function.kind == .not and sub_function.kind == .not) {
        return relationSelectorListTextIsSuperselector(
            context,
            sub_function.arguments,
            super_function.arguments,
            .{},
        );
    }
    return false;
}

fn relationCompoundContainsSubjectSelectorListPseudo(
    compound: []const u8,
) Error!bool {
    var cursor: usize = 0;
    while (cursor < compound.len) {
        const end = try simpleTokenEnd(compound, cursor);
        if (try relationSelectorListPseudo(compound[cursor..end])) |functional| {
            if (relationSelectorListPseudoExposesSubject(functional)) return true;
        }
        cursor = end;
    }
    return false;
}

const RelationSelectorListIterator = struct {
    input: []const u8,
    cursor: usize = 0,

    fn next(
        self: *RelationSelectorListIterator,
        context: *RelationContext,
    ) Error!?[]const u8 {
        return self.nextInternal(context);
    }

    fn nextUncounted(
        self: *RelationSelectorListIterator,
    ) Error!?[]const u8 {
        return self.nextInternal(null);
    }

    fn nextInternal(
        self: *RelationSelectorListIterator,
        context: ?*RelationContext,
    ) Error!?[]const u8 {
        self.cursor = skipWhitespace(self.input, self.cursor);
        if (self.cursor == self.input.len) return null;
        const segment_start = self.cursor;
        var index = self.cursor;
        var paren_depth: usize = 0;
        var square_depth: usize = 0;
        var quote: ?u8 = null;
        while (index < self.input.len) {
            if (context) |active| try active.consume(1);
            const byte = self.input[index];
            if (quote) |active| {
                if (byte == '\\') {
                    index = escapeEnd(self.input, index) orelse
                        return error.InvalidSelector;
                    continue;
                }
                if (byte == active) quote = null;
                index += 1;
                continue;
            }
            if (byte == '\\') {
                index = escapeEnd(self.input, index) orelse
                    return error.InvalidSelector;
                continue;
            }
            if (byte == '/' and index + 1 < self.input.len and self.input[index + 1] == '*') {
                const end = commentEnd(self.input, index) orelse
                    return error.InvalidSelector;
                if (context) |active| {
                    const skipped = std.math.cast(u64, end - index - 1) orelse
                        return error.SelectorLimitExceeded;
                    try active.consume(skipped);
                }
                index = end;
                continue;
            }
            if (byte == ',' and paren_depth == 0 and square_depth == 0) {
                const segment = trimWhitespace(self.input[segment_start..index]);
                if (segment.len == 0) return error.InvalidSelector;
                self.cursor = index + 1;
                return segment;
            }
            switch (byte) {
                '\'', '"' => quote = byte,
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth == 0) return error.InvalidSelector;
                    paren_depth -= 1;
                },
                '[' => square_depth += 1,
                ']' => {
                    if (square_depth == 0) return error.InvalidSelector;
                    square_depth -= 1;
                },
                else => {},
            }
            index += 1;
        }
        if (quote != null or paren_depth != 0 or square_depth != 0) {
            return error.InvalidSelector;
        }
        self.cursor = self.input.len;
        const segment = trimWhitespace(self.input[segment_start..]);
        if (segment.len == 0) return error.InvalidSelector;
        return segment;
    }
};

fn relationSelectorListPseudoHasBogusCombinator(
    context: *RelationContext,
    function: RelationSelectorListPseudo,
) Error!bool {
    if (!selectorListPseudoIsNth(function.kind) or function.arguments.len == 0) {
        return false;
    }
    var iterator = RelationSelectorListIterator{ .input = function.arguments };
    while (try iterator.next(context)) |selector_text| {
        const operations = std.math.cast(u64, selector_text.len) orelse
            return error.SelectorLimitExceeded;
        try context.consume(operations);
        const scan = try scanRelationComplex(selector_text, null);
        if (scan.leading_combinator != null or scan.trailing_combinator) {
            return true;
        }
    }
    return false;
}

fn relationCompoundContainsBogusNth(
    context: *RelationContext,
    compound: []const u8,
    depth: usize,
) Error!bool {
    var cursor: usize = 0;
    while (cursor < compound.len) {
        const end = try simpleTokenEnd(compound, cursor);
        if (try relationSelectorListPseudo(compound[cursor..end])) |function| {
            if (try relationSelectorListPseudoContainsBogusNth(
                context,
                function,
                depth,
            )) return true;
        }
        cursor = end;
    }
    return false;
}

fn relationComplexContainsBogusNth(
    context: *RelationContext,
    complex: RelationComplex,
) Error!bool {
    for (complex.components) |component| {
        if (try relationCompoundContainsBogusNth(
            context,
            component.compound,
            0,
        )) return true;
    }
    return false;
}

fn relationSelectorListPseudoContainsBogusNth(
    context: *RelationContext,
    function: RelationSelectorListPseudo,
    depth: usize,
) Error!bool {
    if (depth >= maximum_selector_list_pseudo_depth) {
        return error.SelectorLimitExceeded;
    }
    if (try relationSelectorListPseudoHasBogusCombinator(context, function)) {
        return true;
    }
    if (function.arguments.len == 0) return false;
    var iterator = RelationSelectorListIterator{ .input = function.arguments };
    while (try iterator.next(context)) |selector_text| {
        var cursor = skipWhitespace(selector_text, 0);
        const leading = explicitCombinatorLength(selector_text, cursor);
        if (leading != 0) {
            cursor = skipWhitespace(selector_text, cursor + leading);
        }
        while (cursor < selector_text.len) {
            const end = try compoundEnd(selector_text, cursor);
            if (end == cursor) return error.InvalidSelector;
            if (try relationCompoundContainsBogusNth(
                context,
                selector_text[cursor..end],
                depth + 1,
            )) return true;
            const after_space = skipWhitespace(selector_text, end);
            const saw_space = after_space != end;
            cursor = after_space;
            if (cursor == selector_text.len) break;
            const combinator = explicitCombinatorLength(selector_text, cursor);
            if (combinator != 0) {
                cursor = skipWhitespace(selector_text, cursor + combinator);
            } else if (!saw_space) {
                return error.InvalidSelector;
            }
        }
    }
    return false;
}

fn canonicalSelectorListMemberCount(
    input: []const u8,
    depth: usize,
) Error!usize {
    var count: usize = 0;
    var iterator = RelationSelectorListIterator{ .input = input };
    while (try iterator.nextUncounted()) |selector| {
        count = std.math.add(usize, count, 1) catch
            return error.SelectorLimitExceeded;
        const nested = try canonicalSelectorNestedMemberCount(selector, depth);
        count = std.math.add(usize, count, nested) catch
            return error.SelectorLimitExceeded;
    }
    if (count == 0) return error.InvalidSelector;
    return count;
}

fn canonicalSelectorNestedMemberCount(
    input: []const u8,
    depth: usize,
) Error!usize {
    var cursor = skipWhitespace(input, 0);
    const leading_length = explicitCombinatorLength(input, cursor);
    if (leading_length != 0) {
        cursor = skipWhitespace(input, cursor + leading_length);
    }
    var count: usize = 0;
    while (cursor < input.len) {
        const end = try compoundEnd(input, cursor);
        if (end == cursor) return error.InvalidSelector;
        var simple_cursor = cursor;
        while (simple_cursor < end) {
            const simple_end = try simpleTokenEnd(input, simple_cursor);
            if (try relationSelectorListPseudo(
                input[simple_cursor..simple_end],
            )) |function| {
                if (depth >= maximum_selector_list_pseudo_depth) {
                    return error.SelectorLimitExceeded;
                }
                if (function.arguments.len != 0) {
                    const nested = try canonicalSelectorListMemberCount(
                        function.arguments,
                        depth + 1,
                    );
                    count = std.math.add(usize, count, nested) catch
                        return error.SelectorLimitExceeded;
                }
            }
            simple_cursor = simple_end;
        }
        const after_space = skipWhitespace(input, end);
        const saw_space = after_space != end;
        cursor = after_space;
        if (cursor == input.len) break;
        const combinator_length = explicitCombinatorLength(input, cursor);
        if (combinator_length != 0) {
            cursor = skipWhitespace(input, cursor + combinator_length);
        } else if (!saw_space) {
            return error.InvalidSelector;
        }
    }
    return count;
}

const RelationSelectorListOptions = struct {
    positive_sub_relative_subject: bool = false,
};

fn relationSelectorListTextIsSuperselector(
    context: *RelationContext,
    super_input: []const u8,
    sub_input: []const u8,
    options: RelationSelectorListOptions,
) Error!bool {
    var saw_sub = false;
    var sub_iterator = RelationSelectorListIterator{ .input = sub_input };
    while (try sub_iterator.next(context)) |sub_selector| {
        saw_sub = true;
        var matched = false;
        var super_iterator = RelationSelectorListIterator{ .input = super_input };
        while (try super_iterator.next(context)) |super_selector| {
            if (try relationComplexTextIsSuperselector(
                context,
                super_selector,
                sub_selector,
                options,
            )) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    if (!saw_sub) return error.InvalidSelector;
    return true;
}

fn relationComplexTextIsSuperselector(
    context: *RelationContext,
    super_input: []const u8,
    sub_input: []const u8,
    options: RelationSelectorListOptions,
) Error!bool {
    const allocator = context.allocator orelse
        return error.UnsupportedSelectorRelation;
    var super_complex = try buildRelationComplex(allocator, super_input, context);
    defer releaseRelationComplex(context, allocator, &super_complex);
    var normalized_sub = sub_input;
    if (options.positive_sub_relative_subject and
        super_complex.leading_combinator == null and
        super_complex.components.len == 1)
    {
        const start = skipWhitespace(normalized_sub, 0);
        const leading = explicitCombinatorLength(normalized_sub, start);
        if (leading != 0) {
            const subject_start = skipWhitespace(normalized_sub, start + leading);
            if (subject_start == normalized_sub.len) return error.InvalidSelector;
            normalized_sub = normalized_sub[subject_start..];
        }
        const scan = try scanRelationComplex(normalized_sub, null);
        if (scan.trailing_combinator) {
            normalized_sub = trimWhitespace(
                normalized_sub[0 .. normalized_sub.len - 1],
            );
            if (normalized_sub.len == 0) return error.InvalidSelector;
        }
    }
    var sub_complex = try buildRelationComplex(allocator, normalized_sub, context);
    defer releaseRelationComplex(context, allocator, &sub_complex);
    return relationComplexIsSuperselector(context, super_complex, sub_complex);
}

fn releaseRelationComplex(
    context: *RelationContext,
    allocator: std.mem.Allocator,
    complex: *RelationComplex,
) void {
    const component_count = complex.components.len;
    const component_bytes = std.math.mul(
        usize,
        component_count,
        @sizeOf(RelationComponent),
    ) catch unreachable;
    allocator.free(complex.components);
    context.releaseTemporary(component_bytes);
    context.releaseComponents(component_count);
    complex.* = undefined;
}

fn relationPseudoElement(
    context: *RelationContext,
    compound: []const u8,
) Error!?[]const u8 {
    var result: ?[]const u8 = null;
    var cursor: usize = 0;
    while (cursor < compound.len) {
        try context.consume(1);
        const end = try simpleTokenEnd(compound, cursor);
        const token = compound[cursor..end];
        if (relationPseudoElementName(token) != null) {
            if (result != null) return error.UnsupportedSelectorRelation;
            result = token;
        }
        cursor = end;
    }
    return result;
}

fn relationPseudoElementName(input: []const u8) ?[]const u8 {
    if (input.len > 2 and std.mem.startsWith(u8, input, "::")) {
        return input[2..];
    }
    if (input.len <= 1 or input[0] != ':' or
        findUnescapedByte(input, '(') != null)
    {
        return null;
    }
    const name = input[1..];
    const legacy_names = [_][]const u8{
        "after",
        "before",
        "first-letter",
        "first-line",
    };
    for (legacy_names) |legacy_name| {
        if (std.ascii.eqlIgnoreCase(name, legacy_name)) return name;
    }
    return null;
}

fn relationPseudoElementsEquivalent(left: []const u8, right: []const u8) bool {
    const left_name = relationPseudoElementName(left) orelse return false;
    const right_name = relationPseudoElementName(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

fn relationSimpleRequiresInference(input: []const u8) bool {
    return input[0] == ':' and findUnescapedByte(input, '(') != null and
        !functionalPseudoHasAdmittedOpaqueName(input);
}

fn functionalPseudoHasAdmittedOpaqueName(input: []const u8) bool {
    if (input.len < 4 or input[0] != ':' or input[1] == ':') return false;
    const opening = findUnescapedByte(input, '(') orelse return false;
    return opaqueFunctionalPseudoKindIgnoreCase(input[1..opening]) != null;
}

fn relationSelectorContainsRelativeFunctionalSelector(
    context: *RelationContext,
    input: []const u8,
    depth: usize,
) Error!bool {
    if (depth > maximum_selector_list_pseudo_depth) {
        return error.SelectorLimitExceeded;
    }
    var cursor = skipWhitespace(input, 0);
    const leading = explicitCombinatorLength(input, cursor);
    if (leading != 0) cursor = skipWhitespace(input, cursor + leading);
    while (cursor < input.len) {
        try context.consume(1);
        const end = try compoundEnd(input, cursor);
        var simple_cursor: usize = 0;
        while (simple_cursor < end - cursor) {
            const simple_end = try simpleTokenEnd(
                input[cursor..end],
                simple_cursor,
            );
            if (try relationFunctionalPseudoContainsRelativeSelector(
                context,
                input[cursor + simple_cursor .. cursor + simple_end],
                depth,
            )) return true;
            simple_cursor = simple_end;
        }
        cursor = skipWhitespace(input, end);
        const combinator = explicitCombinatorLength(input, cursor);
        if (combinator != 0) cursor = skipWhitespace(input, cursor + combinator);
    }
    return false;
}

fn relationFunctionalPseudoContainsRelativeSelector(
    context: *RelationContext,
    input: []const u8,
    depth: usize,
) Error!bool {
    if (input.len == 0 or input[0] != ':') return false;
    if (depth >= maximum_selector_list_pseudo_depth) {
        return error.SelectorLimitExceeded;
    }
    const function = try relationSelectorListPseudo(input) orelse return false;
    if (try relationSelectorListPseudoHasBogusCombinator(context, function)) {
        return true;
    }
    const arguments = function.arguments;
    if (arguments.len == 0) return false;

    var segment_start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < arguments.len) {
        try context.consume(1);
        const byte = arguments[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(arguments, index) orelse
                    return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(arguments, index) orelse
                return error.InvalidSelector;
            continue;
        }
        if (byte == ',' and paren_depth == 0 and square_depth == 0) {
            if (try relationFunctionalPseudoSegmentContainsRelativeSelector(
                context,
                arguments[segment_start..index],
                depth,
            )) return true;
            segment_start = index + 1;
            index += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => paren_depth -|= 1,
            '[' => square_depth += 1,
            ']' => square_depth -|= 1,
            else => {},
        }
        index += 1;
    }
    return relationFunctionalPseudoSegmentContainsRelativeSelector(
        context,
        arguments[segment_start..],
        depth,
    );
}

fn relationFunctionalPseudoSegmentContainsRelativeSelector(
    context: *RelationContext,
    raw_segment: []const u8,
    depth: usize,
) Error!bool {
    const segment = trimWhitespace(raw_segment);
    if (segment.len == 0) return error.InvalidSelector;
    if (explicitCombinatorLength(segment, 0) != 0) return true;
    return relationSelectorContainsRelativeFunctionalSelector(
        context,
        segment,
        depth + 1,
    );
}

fn relationSimpleCount(input: []const u8) Error!usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < input.len) {
        cursor = try simpleTokenEnd(input, cursor);
        count = std.math.add(usize, count, 1) catch
            return error.SelectorLimitExceeded;
    }
    return count;
}

const RelationQualifiedName = struct {
    namespace: ?[]const u8,
    name: []const u8,
};

fn relationSimpleIsSuperselector(
    super_simple: []const u8,
    sub_simple: []const u8,
) bool {
    const super_pseudo_element = relationPseudoElementName(super_simple);
    const sub_pseudo_element = relationPseudoElementName(sub_simple);
    if (super_pseudo_element != null or sub_pseudo_element != null) {
        return relationPseudoElementsEquivalent(super_simple, sub_simple);
    }
    const super_name = relationQualifiedName(super_simple) orelse return false;
    const super_is_universal = std.mem.eql(u8, super_name.name, "*");
    const sub_name = relationQualifiedName(sub_simple);
    if (super_is_universal) {
        if (super_name.namespace) |namespace| {
            if (std.mem.eql(u8, namespace, "*")) return true;
        }
        if (sub_name) |qualified| {
            return relationNamespacesEqual(super_name.namespace, qualified.namespace);
        }
        return super_name.namespace == null;
    }
    const qualified = sub_name orelse return false;
    if (std.mem.eql(u8, qualified.name, "*")) return false;
    if (!std.mem.eql(u8, super_name.name, qualified.name)) return false;
    if (super_name.namespace) |namespace| {
        if (std.mem.eql(u8, namespace, "*")) return true;
    }
    return relationNamespacesEqual(super_name.namespace, qualified.namespace);
}

fn relationQualifiedName(input: []const u8) ?RelationQualifiedName {
    if (input.len == 0) return null;
    return switch (input[0]) {
        '.', '#', '%', '[', ':', '&' => null,
        else => if (std.mem.indexOfScalar(u8, input, '|')) |pipe|
            .{ .namespace = input[0..pipe], .name = input[pipe + 1 ..] }
        else
            .{ .namespace = null, .name = input },
    };
}

fn relationNamespacesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn nestStep(
    allocator: std.mem.Allocator,
    parents: *const SelectorList,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    var children = try parseInternal(allocator, input, limits, true);
    defer children.deinit();
    var builder = Builder{
        .allocator = allocator,
        .limits = limits,
        .allow_parent = true,
    };
    errdefer builder.deinit();
    for (parents.items) |parent| {
        for (children.items) |child| {
            const parent_count = countParentSelectors(child);
            const expansion_count = if (parent_count == 0)
                1
            else
                try selectorPowerBounded(
                    parents.items.len,
                    parent_count - 1,
                    limits.max_selectors,
                );
            for (0..expansion_count) |ordinal| {
                const combined = try combineNested(
                    allocator,
                    parents,
                    parent,
                    child,
                    parent_count,
                    ordinal,
                    limits,
                );
                builder.admitOwned(combined) catch |err| {
                    allocator.free(combined);
                    return err;
                };
            }
        }
    }
    return builder.finish();
}

fn combineNested(
    allocator: std.mem.Allocator,
    parents: *const SelectorList,
    parent: []const u8,
    child: []const u8,
    parent_count: usize,
    ordinal: usize,
    limits: Limits,
) Error![]u8 {
    const max_bytes = limits.max_bytes;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    if (parent_count == 0) {
        try appendBounded(&raw, allocator, parent, max_bytes);
        try appendBounded(&raw, allocator, " ", max_bytes);
        try appendBounded(&raw, allocator, child, max_bytes);
    } else {
        var start: usize = 0;
        var index: usize = 0;
        var occurrence: usize = 0;
        var square_depth: usize = 0;
        var quote: ?u8 = null;
        while (index < child.len) {
            const byte = child[index];
            if (quote) |active| {
                if (byte == '\\') {
                    index = escapeEnd(child, index) orelse return error.InvalidSelector;
                    continue;
                }
                if (byte == active) quote = null;
                index += 1;
                continue;
            }
            if (byte == '\\') {
                index = escapeEnd(child, index) orelse return error.InvalidSelector;
                continue;
            }
            switch (byte) {
                '\'', '"' => quote = byte,
                '[' => square_depth += 1,
                ']' => {
                    if (square_depth == 0) return error.InvalidSelector;
                    square_depth -= 1;
                },
                '&' => if (square_depth == 0) {
                    try appendBounded(&raw, allocator, child[start..index], max_bytes);
                    const replacement = if (occurrence == 0)
                        parent
                    else
                        parents.items[
                            selectorParentIndex(
                                parents.items.len,
                                parent_count - 1,
                                occurrence - 1,
                                ordinal,
                            )
                        ];
                    try appendBounded(&raw, allocator, replacement, max_bytes);
                    start = index + 1;
                    occurrence += 1;
                },
                else => {},
            }
            index += 1;
        }
        if (quote != null or square_depth != 0 or occurrence != parent_count) {
            return error.InvalidSelector;
        }
        try appendBounded(&raw, allocator, child[start..], max_bytes);
    }
    var selector_count: usize = 0;
    var normalization_operations: u64 = 0;
    var normalization_temporary_bytes: usize = 0;
    var context = NormalizationContext{
        .limits = limits,
        .selector_count = &selector_count,
        .operations = &normalization_operations,
        .temporary_bytes = &normalization_temporary_bytes,
    };
    return canonicalize(allocator, raw.items, max_bytes, true, &context);
}

fn countParentSelectors(input: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return count;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return count;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => square_depth += 1,
            ']' => square_depth -|= 1,
            '&' => if (square_depth == 0) {
                count += 1;
            },
            else => {},
        }
        index += 1;
    }
    return count;
}

fn selectorPowerBounded(base: usize, exponent: usize, maximum: usize) Error!usize {
    var result: usize = 1;
    for (0..exponent) |_| {
        result = std.math.mul(usize, result, base) catch
            return error.SelectorLimitExceeded;
        if (result > maximum) return error.SelectorLimitExceeded;
    }
    return result;
}

fn selectorParentIndex(
    parent_count: usize,
    varying_parents: usize,
    occurrence: usize,
    ordinal: usize,
) usize {
    var divisor: usize = 1;
    const following = varying_parents - occurrence - 1;
    for (0..following) |_| divisor *= parent_count;
    return (ordinal / divisor) % parent_count;
}

fn canonicalize(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_bytes: usize,
    allow_parent: bool,
    context: *NormalizationContext,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    var pending_space = false;
    while (index < input.len) {
        try context.consume(1);
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                const end = escapeEnd(input, index) orelse return error.InvalidSelector;
                try appendBounded(&output, allocator, input[index..end], max_bytes);
                index = end;
                continue;
            }
            try appendBounded(&output, allocator, input[index .. index + 1], max_bytes);
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            if (pending_space) {
                try appendBounded(&output, allocator, " ", max_bytes);
                pending_space = false;
            }
            const end = escapeEnd(input, index) orelse return error.InvalidSelector;
            try appendBounded(&output, allocator, input[index..end], max_bytes);
            index = end;
            continue;
        }
        const top_level = paren_depth == 0 and square_depth == 0;
        if (byte == '&' and !allow_parent) return error.InvalidSelector;
        if (top_level and isWhitespace(byte)) {
            pending_space = output.items.len > 0;
            index += 1;
            continue;
        }
        const combinator_length = if (top_level) explicitCombinatorLength(input, index) else 0;
        if (combinator_length != 0) {
            while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
                output.items.len -= 1;
            }
            if (endsWithCombinator(output.items)) {
                return error.InvalidSelector;
            }
            if (output.items.len > 0) try appendBounded(&output, allocator, " ", max_bytes);
            try appendBounded(
                &output,
                allocator,
                input[index .. index + combinator_length],
                max_bytes,
            );
            pending_space = true;
            index += combinator_length;
            continue;
        }
        if (top_level and (byte == '{' or byte == '}' or byte == ';' or byte == '@')) {
            return error.InvalidSelector;
        }
        if (pending_space) {
            try appendBounded(&output, allocator, " ", max_bytes);
            pending_space = false;
        }
        if (byte == '[') {
            const end = try matchingSquareEnd(input, index);
            const attribute = try normalizeAttribute(
                allocator,
                input[index..end],
                max_bytes,
            );
            defer allocator.free(attribute);
            try appendBounded(&output, allocator, attribute, max_bytes);
            index = end;
            continue;
        }
        if (byte == ':') {
            const compound_end = try compoundEnd(input, index);
            const end = index + try simpleTokenEnd(
                input[index..compound_end],
                0,
            );
            try appendNormalizedSimplePseudoEscapes(
                &output,
                allocator,
                input[index..end],
                max_bytes,
                context,
                allow_parent,
            );
            index = end;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return error.InvalidSelector;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            else => {},
        }
        try appendBounded(&output, allocator, input[index .. index + 1], max_bytes);
        index += 1;
    }
    if (quote != null or paren_depth != 0 or square_depth != 0) {
        return error.InvalidSelector;
    }
    while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        output.items.len -= 1;
    }
    if (output.items.len == 0) return error.InvalidSelector;
    if (allow_parent) try validateParentPositions(allocator, output.items);
    try validateComplex(output.items, allow_parent);
    if (std.mem.indexOfScalar(u8, output.items, '\\') != null) {
        const normalized = try normalizeOuterSelectorEscapesAlloc(
            allocator,
            output.items,
            max_bytes,
            context,
            allow_parent,
        );
        output.deinit(allocator);
        output = .empty;
        errdefer allocator.free(normalized);
        if (allow_parent) try validateParentPositions(allocator, normalized);
        try validateComplex(normalized, allow_parent);
        return normalized;
    }
    return output.toOwnedSlice(allocator);
}

fn normalizeOuterSelectorEscapesAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
    allow_parent: bool,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < input.len) {
        try context.consume(1);
        if (isWhitespace(input[cursor])) {
            try appendByteBounded(
                &output,
                allocator,
                input[cursor],
                maximum_bytes,
            );
            cursor += 1;
            continue;
        }
        const combinator_length = explicitCombinatorLength(input, cursor);
        if (combinator_length != 0) {
            try appendBounded(
                &output,
                allocator,
                input[cursor .. cursor + combinator_length],
                maximum_bytes,
            );
            cursor += combinator_length;
            continue;
        }
        const end = try compoundEnd(input, cursor);
        if (end == cursor) return error.InvalidSelector;
        try appendNormalizedCompoundEscapes(
            &output,
            allocator,
            input[cursor..end],
            maximum_bytes,
            context,
            allow_parent,
        );
        cursor = end;
    }
    if (output.items.len > maximum_bytes) return error.SelectorLimitExceeded;
    return output.toOwnedSlice(allocator);
}

fn appendNormalizedCompoundEscapes(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
    allow_parent: bool,
) Error!void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        try context.consume(1);
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        const functional_pseudo = token[0] == ':' and
            findUnescapedByte(token, '(') != null;
        if (functional_pseudo or std.mem.indexOfScalar(u8, token, '\\') == null or
            token[0] == '[' or token[0] == '&')
        {
            try appendBounded(output, allocator, token, maximum_bytes);
        } else switch (token[0]) {
            '.', '#', '%' => {
                try appendByteBounded(output, allocator, token[0], maximum_bytes);
                try appendNormalizedIdentifier(
                    output,
                    allocator,
                    token[1..],
                    maximum_bytes,
                );
            },
            ':' => try appendNormalizedSimplePseudoEscapes(
                output,
                allocator,
                token,
                maximum_bytes,
                context,
                allow_parent,
            ),
            else => try appendNormalizedTypeSelector(
                output,
                allocator,
                token,
                maximum_bytes,
            ),
        }
        cursor = end;
    }
}

fn appendNormalizedSimplePseudoEscapes(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
    allow_parent: bool,
) Error!void {
    const opening = findUnescapedByte(input, '(');
    var name_start: usize = 1;
    if (name_start < input.len and input[name_start] == ':') name_start += 1;
    if (name_start >= input.len) return error.InvalidSelector;
    if (opening == null) {
        try appendBounded(output, allocator, input[0..name_start], maximum_bytes);
        return appendNormalizedIdentifier(
            output,
            allocator,
            input[name_start..],
            maximum_bytes,
        );
    }

    const opening_index = opening.?;
    if (opening_index <= name_start or
        try matchingParenEnd(input, opening_index) != input.len)
    {
        return error.InvalidSelector;
    }
    var normalized_name: std.ArrayList(u8) = .empty;
    defer normalized_name.deinit(allocator);
    try appendNormalizedIdentifier(
        &normalized_name,
        allocator,
        input[name_start..opening_index],
        maximum_bytes,
    );
    try appendBounded(output, allocator, input[0..name_start], maximum_bytes);
    try appendBounded(output, allocator, normalized_name.items, maximum_bytes);
    try appendByteBounded(output, allocator, '(', maximum_bytes);

    const kind = if (name_start == 1)
        selectorListPseudoKind(normalized_name.items)
    else
        null;
    const opaque_kind = if (name_start == 1)
        opaqueFunctionalPseudoKind(normalized_name.items)
    else
        null;
    if (kind == null and opaque_kind == null) {
        try appendPreservedFunctionalPseudoArguments(
            output,
            allocator,
            input[opening_index + 1 .. input.len - 1],
            maximum_bytes,
            context,
            allow_parent,
        );
    } else if (opaque_kind != null) {
        try context.enterSelectorListPseudo();
        defer context.leaveSelectorListPseudo();
        try appendNormalizedOpaqueFunctionalPseudoArguments(
            output,
            allocator,
            input[opening_index + 1 .. input.len - 1],
            maximum_bytes,
            context,
        );
    } else if (selectorListPseudoIsNth(kind.?)) {
        try context.enterSelectorListPseudo();
        defer context.leaveSelectorListPseudo();
        try appendNormalizedNthSelectorArguments(
            output,
            allocator,
            input[opening_index + 1 .. input.len - 1],
            maximum_bytes,
            context,
            allow_parent,
        );
    } else {
        try context.enterSelectorListPseudo();
        defer context.leaveSelectorListPseudo();
        try appendNormalizedFunctionalSelectorList(
            output,
            allocator,
            input[opening_index + 1 .. input.len - 1],
            maximum_bytes,
            context,
            allow_parent,
        );
    }
    try appendByteBounded(output, allocator, ')', maximum_bytes);
}

fn appendPreservedFunctionalPseudoArguments(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
    allow_parent: bool,
) Error!void {
    var index: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        try context.consume(1);
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                const end = escapeEnd(input, index) orelse
                    return error.InvalidSelector;
                try appendBounded(
                    output,
                    allocator,
                    input[index..end],
                    maximum_bytes,
                );
                index = end;
                continue;
            }
            try appendByteBounded(output, allocator, byte, maximum_bytes);
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            const end = escapeEnd(input, index) orelse return error.InvalidSelector;
            try appendBounded(
                output,
                allocator,
                input[index..end],
                maximum_bytes,
            );
            index = end;
            continue;
        }
        if (byte == '[') {
            const end = try matchingSquareEnd(input, index);
            const attribute = try normalizeAttribute(
                allocator,
                input[index..end],
                maximum_bytes,
            );
            defer allocator.free(attribute);
            try appendBounded(output, allocator, attribute, maximum_bytes);
            index = end;
            continue;
        }
        if (byte == '&' and !allow_parent) return error.InvalidSelector;
        try appendByteBounded(output, allocator, byte, maximum_bytes);
        if (byte == '\'' or byte == '"') quote = byte;
        index += 1;
    }
    if (quote != null) return error.InvalidSelector;
}

fn appendNormalizedOpaqueFunctionalPseudoArguments(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
) Error!void {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidSelector;
    var index: usize = 0;
    try appendNormalizedOpaqueComponentSequence(
        output,
        allocator,
        input,
        &index,
        null,
        true,
        maximum_bytes,
        context,
    );
    std.debug.assert(index == input.len);
}

fn appendNormalizedOpaqueComponentSequence(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    index: *usize,
    closing: ?u8,
    trim_edges: bool,
    maximum_bytes: usize,
    context: *NormalizationContext,
) Error!void {
    var pending_space = false;
    var has_content = false;
    while (index.* < input.len) {
        try context.consume(1);
        const byte = input[index.*];
        if (isWhitespace(byte)) {
            pending_space = true;
            index.* += 1;
            continue;
        }
        if (byte == '/' and index.* + 1 < input.len and input[index.* + 1] == '*') {
            const end = commentEnd(input, index.*) orelse return error.InvalidSelector;
            const operations = std.math.cast(u64, end - index.*) orelse
                return error.SelectorLimitExceeded;
            try context.consume(operations);
            if (trim_edges and !has_content) {
                pending_space = false;
                index.* = end;
                continue;
            }
            if (pending_space and (has_content or !trim_edges)) {
                try appendByteBounded(output, allocator, ' ', maximum_bytes);
            }
            pending_space = false;
            try appendBounded(
                output,
                allocator,
                input[index.*..end],
                maximum_bytes,
            );
            has_content = true;
            index.* = end;
            continue;
        }
        if (closing) |expected| {
            if (byte == expected) {
                if (pending_space and !trim_edges) {
                    try appendByteBounded(output, allocator, ' ', maximum_bytes);
                }
                try appendByteBounded(output, allocator, byte, maximum_bytes);
                index.* += 1;
                return;
            }
        }
        if (byte == ')' or byte == ']' or byte == '}') return error.InvalidSelector;
        if (closing == null and byte == ';') return error.InvalidSelector;
        if (pending_space and (has_content or !trim_edges)) {
            try appendByteBounded(output, allocator, ' ', maximum_bytes);
        }
        pending_space = false;

        if (byte == '\'' or byte == '"') {
            try appendNormalizedOpaqueQuoted(
                output,
                allocator,
                input,
                index,
                byte,
                maximum_bytes,
                context,
            );
            has_content = true;
            continue;
        }
        if (byte == '(' or byte == '[' or byte == '{') {
            const expected: u8 = switch (byte) {
                '(' => ')',
                '[' => ']',
                '{' => '}',
                else => unreachable,
            };
            try appendByteBounded(output, allocator, byte, maximum_bytes);
            index.* += 1;
            try context.enterSelectorListPseudo();
            appendNormalizedOpaqueComponentSequence(
                output,
                allocator,
                input,
                index,
                expected,
                false,
                maximum_bytes,
                context,
            ) catch |err| {
                context.leaveSelectorListPseudo();
                return err;
            };
            context.leaveSelectorListPseudo();
            has_content = true;
            continue;
        }
        if (opaqueComponentNameByte(byte)) {
            const end = try opaqueComponentNameEnd(input, index.*);
            try appendNormalizedOpaqueComponentName(
                output,
                allocator,
                input[index.*..end],
                maximum_bytes,
                context,
            );
            index.* = end;
            has_content = true;
            continue;
        }
        if (byte == 0 or byte < 0x20 or byte == 0x7f) {
            return error.InvalidSelector;
        }
        try appendByteBounded(output, allocator, byte, maximum_bytes);
        index.* += 1;
        has_content = true;
    }
    if (closing != null) return error.InvalidSelector;
}

fn appendNormalizedOpaqueQuoted(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    index: *usize,
    quote: u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
) Error!void {
    try appendByteBounded(output, allocator, quote, maximum_bytes);
    index.* += 1;
    while (index.* < input.len) {
        try context.consume(1);
        const byte = input[index.*];
        if (byte == '\\') {
            const end = escapeEnd(input, index.*) orelse return error.InvalidSelector;
            const operations = std.math.cast(u64, end - index.*) orelse
                return error.SelectorLimitExceeded;
            try context.consume(operations);
            try appendBounded(
                output,
                allocator,
                input[index.*..end],
                maximum_bytes,
            );
            index.* = end;
            continue;
        }
        if (byte == 0 or byte == '\n' or byte == '\r' or byte == '\x0c') {
            return error.InvalidSelector;
        }
        try appendByteBounded(output, allocator, byte, maximum_bytes);
        index.* += 1;
        if (byte == quote) return;
    }
    return error.InvalidSelector;
}

fn opaqueComponentNameByte(byte: u8) bool {
    return byte == '\\' or byte == '-' or byte == '_' or byte >= 0x80 or
        std.ascii.isAlphanumeric(byte);
}

fn opaqueComponentNameEnd(input: []const u8, start: usize) Error!usize {
    var cursor = start;
    while (cursor < input.len and opaqueComponentNameByte(input[cursor])) {
        if (input[cursor] == '\\') {
            cursor = (try decodeSelectorEscape(input, cursor)).end;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch
            return error.InvalidSelector;
        const end = std.math.add(usize, cursor, length) catch
            return error.InvalidSelector;
        if (end > input.len) return error.InvalidSelector;
        _ = std.unicode.utf8Decode(input[cursor..end]) catch
            return error.InvalidSelector;
        cursor = end;
    }
    if (cursor == start) return error.InvalidSelector;
    return cursor;
}

fn appendNormalizedOpaqueComponentName(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
) Error!void {
    const operations = std.math.cast(u64, input.len) orelse
        return error.SelectorLimitExceeded;
    try context.consume(operations);
    const starts_with_number = std.ascii.isDigit(input[0]);
    var cursor: usize = 0;
    var position: usize = 0;
    var first_scalar: ?u21 = null;
    var trailing_hex_terminator = false;
    while (cursor < input.len) {
        var escaped = false;
        const scalar: u21 = if (input[cursor] == '\\') blk: {
            escaped = true;
            const decoded = try decodeSelectorEscape(input, cursor);
            cursor = decoded.end;
            if (decoded.scalar == 0 or decoded.scalar > 0x10ffff or
                (decoded.scalar >= 0xd800 and decoded.scalar <= 0xdfff))
            {
                return error.InvalidSelector;
            }
            break :blk @intCast(decoded.scalar);
        } else blk: {
            const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch
                return error.InvalidSelector;
            const end = std.math.add(usize, cursor, length) catch
                return error.InvalidSelector;
            if (end > input.len) return error.InvalidSelector;
            const decoded = std.unicode.utf8Decode(input[cursor..end]) catch
                return error.InvalidSelector;
            cursor = end;
            break :blk decoded;
        };

        const leading_digit = scalar >= '0' and scalar <= '9' and
            !starts_with_number and
            (position == 0 or (position == 1 and first_scalar == '-'));
        if (!escaped) {
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(scalar, &encoded) catch
                return error.InvalidSelector;
            try appendBounded(output, allocator, encoded[0..length], maximum_bytes);
            trailing_hex_terminator = false;
        } else if (scalar < 0x20 or scalar == 0x7f or leading_digit) {
            try appendSelectorHexEscape(
                output,
                allocator,
                scalar,
                true,
                maximum_bytes,
            );
            trailing_hex_terminator = true;
        } else if (scalar >= 0x80) {
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(scalar, &encoded) catch
                return error.InvalidSelector;
            try appendBounded(output, allocator, encoded[0..length], maximum_bytes);
            trailing_hex_terminator = false;
        } else {
            const normalized: u8 = @intCast(scalar);
            if (std.ascii.isAlphanumeric(normalized) or
                normalized == '_' or normalized == '-')
            {
                try appendByteBounded(output, allocator, normalized, maximum_bytes);
            } else {
                try appendByteBounded(output, allocator, '\\', maximum_bytes);
                try appendByteBounded(output, allocator, normalized, maximum_bytes);
            }
            trailing_hex_terminator = false;
        }
        if (first_scalar == null) first_scalar = scalar;
        position = std.math.add(usize, position, 1) catch
            return error.SelectorLimitExceeded;
    }
    if (trailing_hex_terminator) {
        std.debug.assert(output.items.len > 0 and output.items[output.items.len - 1] == ' ');
        output.items.len -= 1;
    }
}

const OpaqueFunctionalPseudoKind = enum {
    lang,
};

fn opaqueFunctionalPseudoKind(name: []const u8) ?OpaqueFunctionalPseudoKind {
    if (std.mem.eql(u8, name, "lang")) return .lang;
    return null;
}

fn opaqueFunctionalPseudoKindIgnoreCase(
    name: []const u8,
) ?OpaqueFunctionalPseudoKind {
    if (std.ascii.eqlIgnoreCase(name, "lang")) return .lang;
    return null;
}

const SelectorListPseudoKind = enum {
    not,
    is,
    where,
    has,
    matches,
    any,
    webkit_any,
    moz_any,
    nth_child,
    nth_last_child,
};

fn selectorListPseudoIsNth(kind: SelectorListPseudoKind) bool {
    return kind == .nth_child or kind == .nth_last_child;
}

fn selectorListPseudoKind(name: []const u8) ?SelectorListPseudoKind {
    const names = [_]struct {
        name: []const u8,
        kind: SelectorListPseudoKind,
    }{
        .{ .name = "not", .kind = .not },
        .{ .name = "is", .kind = .is },
        .{ .name = "where", .kind = .where },
        .{ .name = "has", .kind = .has },
        .{ .name = "matches", .kind = .matches },
        .{ .name = "any", .kind = .any },
        .{ .name = "-webkit-any", .kind = .webkit_any },
        .{ .name = "-moz-any", .kind = .moz_any },
        .{ .name = "nth-child", .kind = .nth_child },
        .{ .name = "nth-last-child", .kind = .nth_last_child },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.kind;
    }
    return null;
}

fn selectorListPseudoKindIgnoreCase(name: []const u8) ?SelectorListPseudoKind {
    const names = [_]struct {
        name: []const u8,
        kind: SelectorListPseudoKind,
    }{
        .{ .name = "not", .kind = .not },
        .{ .name = "is", .kind = .is },
        .{ .name = "where", .kind = .where },
        .{ .name = "has", .kind = .has },
        .{ .name = "matches", .kind = .matches },
        .{ .name = "any", .kind = .any },
        .{ .name = "-webkit-any", .kind = .webkit_any },
        .{ .name = "-moz-any", .kind = .moz_any },
        .{ .name = "nth-child", .kind = .nth_child },
        .{ .name = "nth-last-child", .kind = .nth_last_child },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.kind;
    }
    return null;
}

const NthFormulaKind = enum {
    odd,
    even,
    integer,
    an_plus_b,
};

const ParsedNthSelectorArguments = struct {
    formula_kind: NthFormulaKind,
    formula_start: usize,
    formula_end: usize,
    leading_sign: ?u8 = null,
    coefficient_digits: []const u8 = "",
    offset_sign: ?u8 = null,
    offset_digits: []const u8 = "",
    selector_arguments: ?[]const u8 = null,
};

fn parseNthSelectorArguments(input: []const u8) Error!ParsedNthSelectorArguments {
    const formula_start = try skipNthWhitespace(input, 0);
    if (formula_start == input.len) return error.InvalidSelector;

    if (input[formula_start] == 'o' or input[formula_start] == 'O') {
        if (try nthAsciiWordEnd(input, formula_start, "odd")) |word_end| {
            return finishParsedNthSelectorArguments(
                input,
                .{
                    .formula_kind = .odd,
                    .formula_start = formula_start,
                    .formula_end = word_end,
                },
            );
        }
    }
    if (input[formula_start] == 'e' or input[formula_start] == 'E') {
        if (try nthAsciiWordEnd(input, formula_start, "even")) |word_end| {
            return finishParsedNthSelectorArguments(
                input,
                .{
                    .formula_kind = .even,
                    .formula_start = formula_start,
                    .formula_end = word_end,
                },
            );
        }
    }

    var cursor = formula_start;
    var leading_sign: ?u8 = null;
    if (input[cursor] == '+' or input[cursor] == '-') {
        leading_sign = input[cursor];
        cursor += 1;
        if (cursor == input.len or isWhitespace(input[cursor])) {
            return error.InvalidSelector;
        }
    }

    const digits_start = cursor;
    while (cursor < input.len and std.ascii.isDigit(input[cursor])) cursor += 1;
    const digits_end = cursor;
    const digits = input[digits_start..digits_end];

    var n_start = cursor;
    if (digits.len != 0) n_start = try skipNthWhitespace(input, cursor);
    const n_end = try nthAsciiLetterEnd(input, n_start, 'n');
    if (n_end == null) {
        if (digits.len == 0) return error.InvalidSelector;
        return finishParsedNthSelectorArguments(
            input,
            .{
                .formula_kind = .integer,
                .formula_start = formula_start,
                .formula_end = digits_end,
                .leading_sign = leading_sign,
                .coefficient_digits = digits,
            },
        );
    }

    cursor = n_end.?;
    var formula_end = cursor;
    var offset_sign: ?u8 = null;
    var offset_digits: []const u8 = "";
    const after_n = try skipNthWhitespace(input, cursor);
    if (after_n < input.len and
        (input[after_n] == '+' or input[after_n] == '-'))
    {
        offset_sign = input[after_n];
        cursor = try skipNthWhitespace(input, after_n + 1);
        const offset_start = cursor;
        while (cursor < input.len and std.ascii.isDigit(input[cursor])) cursor += 1;
        if (cursor == offset_start) return error.InvalidSelector;
        offset_digits = input[offset_start..cursor];
        formula_end = cursor;
    }
    return finishParsedNthSelectorArguments(
        input,
        .{
            .formula_kind = .an_plus_b,
            .formula_start = formula_start,
            .formula_end = formula_end,
            .leading_sign = leading_sign,
            .coefficient_digits = digits,
            .offset_sign = offset_sign,
            .offset_digits = offset_digits,
        },
    );
}

fn finishParsedNthSelectorArguments(
    input: []const u8,
    parsed: ParsedNthSelectorArguments,
) Error!ParsedNthSelectorArguments {
    const keyword_start = try skipNthWhitespace(input, parsed.formula_end);
    if (keyword_start == input.len) return parsed;
    if (keyword_start == parsed.formula_end or
        !isWhitespace(input[keyword_start - 1]))
    {
        return error.InvalidSelector;
    }
    const keyword_end = try nthAsciiWordEnd(input, keyword_start, "of") orelse
        return error.InvalidSelector;
    if (keyword_end < input.len and
        nthIdentifierContinuationStart(input, keyword_end))
    {
        return error.InvalidSelector;
    }
    const selector_start = try skipNthWhitespace(input, keyword_end);
    if (selector_start == input.len) return error.InvalidSelector;
    var result = parsed;
    result.selector_arguments = input[selector_start..];
    return result;
}

fn skipNthWhitespace(input: []const u8, start: usize) Error!usize {
    var cursor = start;
    while (cursor < input.len) {
        if (isWhitespace(input[cursor])) {
            cursor += 1;
            continue;
        }
        if (input[cursor] == '/' and cursor + 1 < input.len and
            input[cursor + 1] == '*')
        {
            cursor = commentEnd(input, cursor) orelse return error.InvalidSelector;
            continue;
        }
        break;
    }
    return cursor;
}

fn nthAsciiWordEnd(
    input: []const u8,
    start: usize,
    expected: []const u8,
) Error!?usize {
    var cursor = start;
    for (expected) |letter| {
        const end = try nthAsciiLetterEnd(input, cursor, letter) orelse return null;
        cursor = end;
    }
    return cursor;
}

fn nthAsciiLetterEnd(
    input: []const u8,
    start: usize,
    expected: u8,
) Error!?usize {
    if (start >= input.len) return null;
    if (input[start] == '\\') {
        const decoded = try decodeSelectorEscape(input, start);
        if (decoded.scalar > 0x7f or
            std.ascii.toLower(@as(u8, @intCast(decoded.scalar))) !=
                std.ascii.toLower(expected))
        {
            return null;
        }
        return decoded.end;
    }
    if (!std.ascii.isAlphabetic(input[start]) or
        std.ascii.toLower(input[start]) != std.ascii.toLower(expected))
    {
        return null;
    }
    return start + 1;
}

fn nthIdentifierContinuationStart(input: []const u8, start: usize) bool {
    if (start >= input.len) return false;
    const byte = input[start];
    return byte == '\\' or byte == '-' or byte == '_' or byte >= 0x80 or
        std.ascii.isAlphanumeric(byte);
}

fn appendNormalizedNthSelectorArguments(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
    allow_parent: bool,
) Error!void {
    const operations = std.math.cast(u64, input.len) orelse
        return error.SelectorLimitExceeded;
    try context.consume(operations);
    const parsed = try parseNthSelectorArguments(input);
    switch (parsed.formula_kind) {
        .odd => try appendBounded(output, allocator, "odd", maximum_bytes),
        .even => try appendBounded(output, allocator, "even", maximum_bytes),
        .integer, .an_plus_b => {
            if (parsed.leading_sign) |sign| {
                try appendByteBounded(output, allocator, sign, maximum_bytes);
            }
            try appendBounded(
                output,
                allocator,
                parsed.coefficient_digits,
                maximum_bytes,
            );
            if (parsed.formula_kind == .an_plus_b) {
                try appendByteBounded(output, allocator, 'n', maximum_bytes);
                if (parsed.offset_sign) |sign| {
                    try appendByteBounded(output, allocator, sign, maximum_bytes);
                    try appendBounded(
                        output,
                        allocator,
                        parsed.offset_digits,
                        maximum_bytes,
                    );
                }
            }
        },
    }
    if (parsed.selector_arguments) |arguments| {
        try appendBounded(output, allocator, " of ", maximum_bytes);
        try appendNormalizedFunctionalSelectorList(
            output,
            allocator,
            arguments,
            maximum_bytes,
            context,
            allow_parent,
        );
    }
}

fn appendNormalizedFunctionalSelectorList(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
    allow_parent: bool,
) Error!void {
    if (trimWhitespace(input).len == 0) return error.InvalidSelector;
    try context.reserveTemporary(input.len);
    defer context.releaseTemporary(input.len);

    var segment_start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    var emitted: usize = 0;
    while (index < input.len) {
        try context.consume(1);
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (byte == '/' and index + 1 < input.len and input[index + 1] == '*') {
            index = commentEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return error.InvalidSelector;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            ',' => if (paren_depth == 0 and square_depth == 0) {
                const segment = trimWhitespace(input[segment_start..index]);
                if (segment.len == 0) {
                    if (emitted == 0) return error.InvalidSelector;
                } else {
                    try appendNormalizedFunctionalSelector(
                        output,
                        allocator,
                        segment,
                        maximum_bytes,
                        context,
                        emitted != 0,
                        allow_parent,
                    );
                    emitted += 1;
                }
                segment_start = index + 1;
            },
            else => {},
        }
        index += 1;
    }
    if (quote != null or paren_depth != 0 or square_depth != 0) {
        return error.InvalidSelector;
    }
    const final_segment = trimWhitespace(input[segment_start..]);
    if (final_segment.len == 0) return error.InvalidSelector;
    try appendNormalizedFunctionalSelector(
        output,
        allocator,
        final_segment,
        maximum_bytes,
        context,
        emitted != 0,
        allow_parent,
    );
}

fn appendNormalizedFunctionalSelector(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
    context: *NormalizationContext,
    prepend_separator: bool,
    allow_parent: bool,
) Error!void {
    try context.reserveSelector();
    const normalized = try canonicalize(
        allocator,
        input,
        maximum_bytes,
        allow_parent,
        context,
    );
    defer allocator.free(normalized);
    if (prepend_separator) {
        try appendBounded(output, allocator, ", ", maximum_bytes);
    }
    try appendBounded(output, allocator, normalized, maximum_bytes);
}

fn appendNormalizedTypeSelector(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
) Error!void {
    if (findUnescapedPipe(input)) |pipe| {
        const namespace = input[0..pipe];
        if (namespace.len > 0) {
            if (std.mem.eql(u8, namespace, "*")) {
                try appendBounded(output, allocator, "*", maximum_bytes);
            } else {
                try appendNormalizedIdentifier(
                    output,
                    allocator,
                    namespace,
                    maximum_bytes,
                );
            }
        }
        try appendBounded(output, allocator, "|", maximum_bytes);
        const name = input[pipe + 1 ..];
        if (std.mem.eql(u8, name, "*")) {
            try appendBounded(output, allocator, "*", maximum_bytes);
        } else {
            try appendNormalizedIdentifier(
                output,
                allocator,
                name,
                maximum_bytes,
            );
        }
        return;
    }
    if (std.mem.eql(u8, input, "*")) {
        return appendBounded(output, allocator, "*", maximum_bytes);
    }
    return appendNormalizedIdentifier(output, allocator, input, maximum_bytes);
}

fn validateParentPositions(allocator: std.mem.Allocator, input: []const u8) Error!void {
    var index: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    var compound_start = true;
    var parent_contexts: std.ArrayList(bool) = .empty;
    defer parent_contexts.deinit(allocator);
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            compound_start = false;
            continue;
        }
        if (square_depth != 0) {
            switch (byte) {
                '\'', '"' => quote = byte,
                '[' => square_depth += 1,
                ']' => square_depth -= 1,
                '&' => return error.InvalidSelector,
                else => {},
            }
            index += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => {
                quote = byte;
                compound_start = false;
            },
            '[' => {
                square_depth = 1;
                compound_start = false;
            },
            '(' => {
                const outer_allows_parent = parent_contexts.items.len == 0 or
                    parent_contexts.items[parent_contexts.items.len - 1];
                try parent_contexts.append(
                    allocator,
                    outer_allows_parent and selectorFunctionAllowsParent(input, index),
                );
                compound_start = true;
            },
            ',' => compound_start = true,
            ')' => {
                if (parent_contexts.items.len == 0) return error.InvalidSelector;
                _ = parent_contexts.pop();
                compound_start = false;
            },
            '&' => {
                const context_allows_parent = parent_contexts.items.len == 0 or
                    parent_contexts.items[parent_contexts.items.len - 1];
                if (!context_allows_parent or !compound_start) return error.InvalidSelector;
                compound_start = false;
            },
            '>', '+', '~' => compound_start = true,
            else => if (isWhitespace(byte)) {
                compound_start = true;
            } else {
                compound_start = false;
            },
        }
        index += 1;
    }
    if (quote != null or square_depth != 0 or parent_contexts.items.len != 0) {
        return error.InvalidSelector;
    }
}

fn selectorFunctionAllowsParent(input: []const u8, opening: usize) bool {
    var start = opening;
    while (start > 0 and isNameContinue(input[start - 1])) start -= 1;
    if (start == opening or start == 0 or input[start - 1] != ':') return false;
    const name = input[start..opening];
    const functions = [_][]const u8{
        "not",
        "is",
        "where",
        "has",
        "matches",
        "any",
        "-webkit-any",
        "-moz-any",
        "host",
        "host-context",
        "slotted",
    };
    for (functions) |function| {
        if (std.ascii.eqlIgnoreCase(name, function)) return true;
    }
    return false;
}

fn validateComplex(input: []const u8, allow_parent: bool) Error!void {
    var cursor = skipWhitespace(input, 0);
    if (cursor == input.len) return error.InvalidSelector;
    const leading_combinator_length = explicitCombinatorLength(input, cursor);
    if (leading_combinator_length != 0) {
        cursor = skipWhitespace(input, cursor + leading_combinator_length);
        if (cursor == input.len or explicitCombinatorLength(input, cursor) != 0) {
            return error.InvalidSelector;
        }
    }
    while (cursor < input.len) {
        const end = try compoundEnd(input, cursor);
        if (end == cursor) return error.InvalidSelector;
        try validateCompound(input[cursor..end], allow_parent);
        cursor = end;
        const after_space = skipWhitespace(input, cursor);
        const saw_space = after_space != cursor;
        cursor = after_space;
        if (cursor == input.len) return;
        const combinator_length = explicitCombinatorLength(input, cursor);
        if (combinator_length != 0) {
            cursor = skipWhitespace(input, cursor + combinator_length);
            if (cursor == input.len) return;
            if (explicitCombinatorLength(input, cursor) != 0) return error.InvalidSelector;
            continue;
        }
        if (!saw_space) return error.InvalidSelector;
    }
}

fn compoundEnd(input: []const u8, start: usize) Error!usize {
    var index = start;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (byte == '/' and index + 1 < input.len and input[index + 1] == '*') {
            index = commentEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        const top_level = paren_depth == 0 and square_depth == 0;
        if (top_level and (isWhitespace(byte) or explicitCombinatorLength(input, index) != 0)) {
            break;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return error.InvalidSelector;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    if (quote != null or paren_depth != 0 or square_depth != 0) {
        return error.InvalidSelector;
    }
    return index;
}

fn validateCompound(input: []const u8, allow_parent: bool) Error!void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const byte = input[cursor];
        const end = try simpleTokenEnd(input, cursor);
        if (end <= cursor) return error.InvalidSelector;
        switch (byte) {
            '&' => if (!allow_parent or cursor != 0) return error.InvalidSelector,
            '.' => if (!validName(input[cursor + 1 .. end], false)) return error.InvalidSelector,
            '#' => if (!validName(input[cursor + 1 .. end], true)) return error.InvalidSelector,
            '%' => if (!validName(input[cursor + 1 .. end], false)) return error.InvalidSelector,
            '[' => if (end - cursor <= 2) return error.InvalidSelector,
            ':' => {},
            else => {
                if (cursor != 0 or !validTypeSelector(input[cursor..end])) {
                    return error.InvalidSelector;
                }
            },
        }
        cursor = end;
    }
    if (cursor == 0) return error.InvalidSelector;
}

fn simpleTokenEnd(input: []const u8, start: usize) Error!usize {
    if (start >= input.len) return error.InvalidSelector;
    return switch (input[start]) {
        '[' => matchingSquareEnd(input, start),
        ':' => pseudoEnd(input, start),
        '&' => parentTokenEnd(input, start),
        '.', '#', '%' => namedTokenEnd(input, start + 1),
        else => namedTokenEnd(input, start),
    };
}

fn parentTokenEnd(input: []const u8, start: usize) Error!usize {
    var index = start + 1;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (isWhitespace(input[index]) or isSimpleMarker(input[index]) or
            explicitCombinatorLength(input, index) != 0)
        {
            break;
        }
        index += 1;
    }
    return index;
}

fn namedTokenEnd(input: []const u8, start: usize) Error!usize {
    var index = start;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (isSimpleMarker(input[index])) break;
        index += 1;
    }
    if (index == start) return error.InvalidSelector;
    return index;
}

fn pseudoEnd(input: []const u8, start: usize) Error!usize {
    var name_start = start + 1;
    if (name_start < input.len and input[name_start] == ':') name_start += 1;
    var index = name_start;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (input[index] == '(' or isSimpleMarker(input[index])) break;
        index += 1;
    }
    if (!validName(input[name_start..index], false)) return error.InvalidSelector;
    if (index < input.len and input[index] == '(') return matchingParenEnd(input, index);
    return index;
}

fn matchingSquareEnd(input: []const u8, start: usize) Error!usize {
    var index = start + 1;
    var depth: usize = 1;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (byte == '/' and index + 1 < input.len and input[index + 1] == '*') {
            index = commentEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }
        index += 1;
    }
    return error.InvalidSelector;
}

fn matchingParenEnd(input: []const u8, start: usize) Error!usize {
    var index = start + 1;
    var depth: usize = 1;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (byte == '/' and index + 1 < input.len and input[index + 1] == '*') {
            index = commentEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            '{' => if (square_depth == 0) {
                curly_depth += 1;
            },
            '}' => if (square_depth == 0) {
                if (curly_depth == 0) return error.InvalidSelector;
                curly_depth -= 1;
            },
            '(' => if (square_depth == 0 and curly_depth == 0) {
                depth += 1;
            },
            ')' => if (square_depth == 0 and curly_depth == 0) {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }
        index += 1;
    }
    return error.InvalidSelector;
}

fn isSingleCompound(input: []const u8) bool {
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return false;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return false;
            continue;
        }
        if (byte == '/' and index + 1 < input.len and input[index + 1] == '*') {
            index = commentEnd(input, index) orelse return false;
            continue;
        }
        const top_level = paren_depth == 0 and square_depth == 0;
        if (top_level and (isWhitespace(byte) or explicitCombinatorLength(input, index) != 0)) {
            return false;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return false;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return false;
                square_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    return quote == null and paren_depth == 0 and square_depth == 0;
}

const ParsedAttribute = struct {
    name: []const u8,
    operator: ?[]const u8,
    value: ?[]const u8,
    value_quoted: bool = false,
    modifier: ?u8,
};

fn normalizeAttribute(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
) Error![]u8 {
    if (input.len < 3 or input[0] != '[' or input[input.len - 1] != ']') {
        return error.InvalidSelector;
    }
    const parsed = try parseAttribute(input);
    const name = try normalizeAttributeQualifiedNameAlloc(
        allocator,
        parsed.name,
        maximum_bytes,
    );
    defer allocator.free(name);
    const value = if (parsed.value) |raw|
        try normalizeAttributeValueAlloc(
            allocator,
            raw,
            parsed.value_quoted,
            maximum_bytes,
        )
    else
        null;
    defer if (value) |owned| allocator.free(owned);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendBounded(&output, allocator, "[", maximum_bytes);
    try appendBounded(&output, allocator, name, maximum_bytes);
    if (parsed.operator) |operator| {
        try appendBounded(&output, allocator, operator, maximum_bytes);
        try appendBounded(
            &output,
            allocator,
            value orelse return error.InvalidSelector,
            maximum_bytes,
        );
    }
    if (parsed.modifier) |modifier| {
        try appendBounded(&output, allocator, " ", maximum_bytes);
        try appendByteBounded(&output, allocator, modifier, maximum_bytes);
    }
    try appendBounded(&output, allocator, "]", maximum_bytes);
    return output.toOwnedSlice(allocator);
}

fn parseAttribute(input: []const u8) Error!ParsedAttribute {
    const closing = input.len - 1;
    var cursor = try skipAttributeWhitespace(input, 1, closing);
    const name_start = cursor;
    cursor = try attributeQualifiedNameEnd(input, cursor, closing);
    const name = input[name_start..cursor];
    cursor = try skipAttributeWhitespace(input, cursor, closing);
    if (cursor == closing) {
        return .{ .name = name, .operator = null, .value = null, .modifier = null };
    }

    const operator_start = cursor;
    const operator_length: usize = switch (input[cursor]) {
        '=' => 1,
        '~', '|', '^', '$', '*' => if (cursor + 1 < closing and
            input[cursor + 1] == '=')
            2
        else
            return error.InvalidSelector,
        else => return error.InvalidSelector,
    };
    cursor += operator_length;
    const operator = input[operator_start..cursor];
    cursor = try skipAttributeWhitespace(input, cursor, closing);
    if (cursor == closing) return error.InvalidSelector;

    var value_quoted = false;
    const value: []const u8 = if (input[cursor] == '\'' or input[cursor] == '"') blk: {
        value_quoted = true;
        const quote = input[cursor];
        const start = cursor + 1;
        cursor = start;
        while (cursor < closing and input[cursor] != quote) {
            if (input[cursor] == '\\') {
                cursor = escapeEnd(input, cursor) orelse return error.InvalidSelector;
                continue;
            }
            if (input[cursor] == 0 or input[cursor] == '\n' or
                input[cursor] == '\r' or input[cursor] == '\x0c')
            {
                return error.InvalidSelector;
            }
            cursor += 1;
        }
        if (cursor == closing) return error.InvalidSelector;
        const result = input[start..cursor];
        cursor += 1;
        break :blk result;
    } else blk: {
        const start = cursor;
        cursor = attributeIdentifierEnd(input, cursor, closing) orelse
            return error.InvalidSelector;
        break :blk input[start..cursor];
    };

    cursor = try skipAttributeWhitespace(input, cursor, closing);
    var modifier: ?u8 = null;
    if (cursor < closing) {
        if (!std.ascii.isAlphabetic(input[cursor]) or cursor + 1 != closing) {
            return error.InvalidSelector;
        }
        modifier = input[cursor];
        cursor += 1;
    }
    if (cursor != closing) return error.InvalidSelector;
    return .{
        .name = name,
        .operator = operator,
        .value = value,
        .value_quoted = value_quoted,
        .modifier = modifier,
    };
}

fn skipAttributeWhitespace(
    input: []const u8,
    start: usize,
    limit: usize,
) Error!usize {
    var cursor = start;
    while (cursor < limit) {
        if (isWhitespace(input[cursor])) {
            cursor += 1;
            continue;
        }
        if (input[cursor] != '/' or cursor + 1 >= limit or
            input[cursor + 1] != '*')
        {
            break;
        }
        cursor += 2;
        while (cursor + 1 < limit and
            (input[cursor] != '*' or input[cursor + 1] != '/'))
        {
            cursor += 1;
        }
        if (cursor + 1 >= limit) return error.InvalidSelector;
        cursor += 2;
    }
    return cursor;
}

fn attributeQualifiedNameEnd(
    input: []const u8,
    start: usize,
    closing: usize,
) Error!usize {
    if (start >= closing) return error.InvalidSelector;
    if (input[start] == '*') {
        if (start + 1 >= closing or input[start + 1] != '|') {
            return error.InvalidSelector;
        }
        return attributeIdentifierEnd(input, start + 2, closing) orelse
            error.InvalidSelector;
    }
    if (input[start] == '|') {
        return attributeIdentifierEnd(input, start + 1, closing) orelse
            error.InvalidSelector;
    }
    var cursor = attributeIdentifierEnd(input, start, closing) orelse
        return error.InvalidSelector;
    if (cursor < closing and input[cursor] == '|' and
        (cursor + 1 >= closing or input[cursor + 1] != '='))
    {
        cursor = attributeIdentifierEnd(input, cursor + 1, closing) orelse
            return error.InvalidSelector;
    }
    return cursor;
}

fn attributeIdentifierEnd(
    input: []const u8,
    start: usize,
    limit: usize,
) ?usize {
    if (start >= limit) return null;
    var cursor = start;
    if (input[cursor] == '\\') {
        cursor = escapeEnd(input, cursor) orelse return null;
    } else if (input[cursor] == '-') {
        if (cursor + 1 >= limit or
            (input[cursor + 1] != '-' and
                input[cursor + 1] != '\\' and
                !isNameStart(input[cursor + 1])))
        {
            return null;
        }
        cursor += 1;
        if (input[cursor] == '\\') {
            cursor = escapeEnd(input, cursor) orelse return null;
        } else {
            cursor += 1;
        }
    } else {
        if (!isNameStart(input[cursor])) return null;
        cursor += 1;
    }
    while (cursor < limit) {
        if (input[cursor] == '\\') {
            cursor = escapeEnd(input, cursor) orelse return null;
            continue;
        }
        if (!isNameContinue(input[cursor])) break;
        cursor += 1;
    }
    return cursor;
}

fn normalizeAttributeQualifiedNameAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (findUnescapedPipe(input)) |pipe| {
        const namespace = input[0..pipe];
        if (namespace.len > 0) {
            if (std.mem.eql(u8, namespace, "*")) {
                try appendBounded(&output, allocator, "*", maximum_bytes);
            } else {
                try appendNormalizedIdentifier(
                    &output,
                    allocator,
                    namespace,
                    maximum_bytes,
                );
            }
        }
        try appendBounded(&output, allocator, "|", maximum_bytes);
        try appendNormalizedIdentifier(
            &output,
            allocator,
            input[pipe + 1 ..],
            maximum_bytes,
        );
    } else {
        try appendNormalizedIdentifier(
            &output,
            allocator,
            input,
            maximum_bytes,
        );
    }
    return output.toOwnedSlice(allocator);
}

fn normalizeAttributeValueAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    quoted: bool,
    maximum_bytes: usize,
) Error![]u8 {
    if (!quoted) {
        const normalized = try normalizeIdentifierAlloc(
            allocator,
            input,
            maximum_bytes,
        );
        if (!std.mem.startsWith(u8, input, "--")) return normalized;
        allocator.free(normalized);
        const decoded = try decodeAttributeStringAlloc(
            allocator,
            input,
            maximum_bytes,
        );
        defer allocator.free(decoded);
        return quoteAttributeStringAlloc(allocator, decoded, maximum_bytes);
    }

    const decoded = try decodeAttributeStringAlloc(
        allocator,
        input,
        maximum_bytes,
    );
    defer allocator.free(decoded);
    if (attributeValueIsLiteralIdentifier(decoded) and
        !std.mem.startsWith(u8, decoded, "--"))
    {
        return allocator.dupe(u8, decoded);
    }
    return quoteAttributeStringAlloc(allocator, decoded, maximum_bytes);
}

fn normalizeIdentifierAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendNormalizedIdentifier(&output, allocator, input, maximum_bytes);
    return output.toOwnedSlice(allocator);
}

const DecodedSelectorEscape = struct {
    scalar: u32,
    end: usize,
};

fn appendNormalizedIdentifier(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
) Error!void {
    if (input.len == 0 or !std.unicode.utf8ValidateSlice(input)) {
        return error.InvalidSelector;
    }
    var cursor: usize = 0;
    var position: usize = 0;
    var first_scalar: ?u21 = null;
    while (cursor < input.len) {
        var escaped = false;
        const scalar: u21 = if (input[cursor] == '\\') blk: {
            escaped = true;
            const decoded = try decodeSelectorEscape(input, cursor);
            cursor = decoded.end;
            if (decoded.scalar > 0x10ffff or
                (decoded.scalar >= 0xd800 and decoded.scalar <= 0xdfff))
            {
                return error.InvalidSelector;
            }
            break :blk @intCast(decoded.scalar);
        } else blk: {
            const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch
                return error.InvalidSelector;
            const end = std.math.add(usize, cursor, length) catch
                return error.InvalidSelector;
            if (end > input.len) return error.InvalidSelector;
            const decoded = std.unicode.utf8Decode(input[cursor..end]) catch
                return error.InvalidSelector;
            cursor = end;
            break :blk decoded;
        };
        try appendNormalizedIdentifierScalar(
            output,
            allocator,
            scalar,
            escaped,
            position,
            first_scalar,
            maximum_bytes,
        );
        if (first_scalar == null) first_scalar = scalar;
        position = std.math.add(usize, position, 1) catch
            return error.SelectorLimitExceeded;
    }
    if (position == 0) return error.InvalidSelector;
}

fn appendNormalizedIdentifierScalar(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    scalar: u21,
    escaped: bool,
    position: usize,
    first_scalar: ?u21,
    maximum_bytes: usize,
) Error!void {
    const leading_digit = scalar >= '0' and scalar <= '9' and
        (position == 0 or (position == 1 and first_scalar == '-'));
    if (scalar == 0 or scalar < 0x20 or scalar == 0x7f or leading_digit) {
        return appendSelectorHexEscape(
            output,
            allocator,
            scalar,
            true,
            maximum_bytes,
        );
    }
    if (scalar >= 0x80) {
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(scalar, &encoded) catch
            return error.InvalidSelector;
        return appendBounded(output, allocator, encoded[0..length], maximum_bytes);
    }
    const byte: u8 = @intCast(scalar);
    if (std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_') {
        return appendByteBounded(output, allocator, byte, maximum_bytes);
    }
    if (byte == '-' and !escaped) {
        return appendByteBounded(output, allocator, byte, maximum_bytes);
    }
    try appendBounded(output, allocator, "\\", maximum_bytes);
    try appendByteBounded(output, allocator, byte, maximum_bytes);
}

fn decodeSelectorEscape(input: []const u8, start: usize) Error!DecodedSelectorEscape {
    if (start + 1 >= input.len or input[start] != '\\') {
        return error.InvalidSelector;
    }
    var cursor = start + 1;
    if (input[cursor] == '\n' or input[cursor] == '\r' or
        input[cursor] == '\x0c' or input[cursor] == 0)
    {
        return error.InvalidSelector;
    }
    if (std.ascii.isHex(input[cursor])) {
        var scalar: u32 = 0;
        var digits: usize = 0;
        while (cursor < input.len and digits < 6 and std.ascii.isHex(input[cursor])) {
            scalar = scalar * 16 + selectorHexValue(input[cursor]);
            cursor += 1;
            digits += 1;
        }
        if (cursor < input.len and isWhitespace(input[cursor])) {
            cursor = normalizeEscapeWhitespace(input, cursor);
        }
        return .{ .scalar = scalar, .end = cursor };
    }
    const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch
        return error.InvalidSelector;
    const end = std.math.add(usize, cursor, length) catch
        return error.InvalidSelector;
    if (end > input.len) return error.InvalidSelector;
    return .{
        .scalar = std.unicode.utf8Decode(input[cursor..end]) catch
            return error.InvalidSelector,
        .end = end,
    };
}

fn selectorHexValue(byte: u8) u32 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return byte - 'A' + 10;
}

fn appendSelectorHexEscape(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    scalar: u32,
    terminate: bool,
    maximum_bytes: usize,
) Error!void {
    var reversed: [6]u8 = undefined;
    var length: usize = 0;
    var remaining = scalar;
    while (remaining != 0) {
        const digit: u8 = @intCast(remaining & 0xf);
        reversed[length] = if (digit < 10) '0' + digit else 'a' + digit - 10;
        length += 1;
        remaining >>= 4;
    }
    if (length == 0) {
        reversed[0] = '0';
        length = 1;
    }
    try appendBounded(output, allocator, "\\", maximum_bytes);
    var index = length;
    while (index > 0) {
        index -= 1;
        try appendByteBounded(output, allocator, reversed[index], maximum_bytes);
    }
    if (terminate) try appendByteBounded(output, allocator, ' ', maximum_bytes);
}

fn decodeAttributeStringAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidSelector;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < input.len) {
        if (input[cursor] == '\\') {
            const decoded = try decodeSelectorEscape(input, cursor);
            cursor = decoded.end;
            const scalar: u21 = if (decoded.scalar == 0 or
                decoded.scalar > 0x10ffff or
                (decoded.scalar >= 0xd800 and decoded.scalar <= 0xdfff))
                0xfffd
            else
                @intCast(decoded.scalar);
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(scalar, &encoded) catch unreachable;
            try appendBounded(
                &output,
                allocator,
                encoded[0..length],
                maximum_bytes,
            );
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch
            return error.InvalidSelector;
        const end = std.math.add(usize, cursor, length) catch
            return error.InvalidSelector;
        if (end > input.len) return error.InvalidSelector;
        const scalar = std.unicode.utf8Decode(input[cursor..end]) catch
            return error.InvalidSelector;
        if (scalar == 0 or scalar == '\n' or scalar == '\r' or scalar == '\x0c') {
            return error.InvalidSelector;
        }
        try appendBounded(&output, allocator, input[cursor..end], maximum_bytes);
        cursor = end;
    }
    return output.toOwnedSlice(allocator);
}

fn quoteAttributeStringAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_bytes: usize,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidSelector;
    const contains_double = std.mem.indexOfScalar(u8, input, '"') != null;
    const contains_single = std.mem.indexOfScalar(u8, input, '\'') != null;
    const quote: u8 = if (contains_double and !contains_single) '\'' else '"';
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendByteBounded(&output, allocator, quote, maximum_bytes);
    var cursor: usize = 0;
    while (cursor < input.len) {
        const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch
            return error.InvalidSelector;
        const end = std.math.add(usize, cursor, length) catch
            return error.InvalidSelector;
        if (end > input.len) return error.InvalidSelector;
        const scalar = std.unicode.utf8Decode(input[cursor..end]) catch
            return error.InvalidSelector;
        if (scalar == quote or scalar == '\\') {
            try appendBounded(&output, allocator, "\\", maximum_bytes);
            try appendBounded(&output, allocator, input[cursor..end], maximum_bytes);
        } else if ((scalar < 0x20 and scalar != '\t') or scalar == 0x7f) {
            const next_is_hex_or_space = if (end < input.len) blk: {
                const next = input[end];
                break :blk std.ascii.isHex(next) or isWhitespace(next);
            } else false;
            try appendSelectorHexEscape(
                &output,
                allocator,
                scalar,
                next_is_hex_or_space,
                maximum_bytes,
            );
        } else {
            try appendBounded(&output, allocator, input[cursor..end], maximum_bytes);
        }
        cursor = end;
    }
    try appendByteBounded(&output, allocator, quote, maximum_bytes);
    return output.toOwnedSlice(allocator);
}

fn attributeValueIsLiteralIdentifier(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value) or value.len == 0) return false;
    var cursor: usize = 0;
    if (value[cursor] == '-') {
        if (cursor + 1 >= value.len or
            (value[cursor + 1] != '-' and !isNameStart(value[cursor + 1])))
        {
            return false;
        }
        cursor += 2;
    } else {
        if (!isNameStart(value[cursor])) return false;
        cursor += 1;
    }
    while (cursor < value.len and isNameContinue(value[cursor])) cursor += 1;
    return cursor == value.len;
}

fn findUnescapedPipe(input: []const u8) ?usize {
    return findUnescapedByte(input, '|');
}

fn findUnescapedByte(input: []const u8, needle: u8) ?usize {
    var cursor: usize = 0;
    while (cursor < input.len) {
        if (input[cursor] == '\\') {
            cursor = escapeEnd(input, cursor) orelse return null;
            continue;
        }
        if (input[cursor] == needle) return cursor;
        cursor += 1;
    }
    return null;
}

fn validTypeSelector(input: []const u8) bool {
    var pipe: ?usize = null;
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return false;
            continue;
        }
        if (input[index] == '|') {
            if (pipe != null) return false;
            pipe = index;
        }
        index += 1;
    }
    if (pipe) |position| {
        const left = input[0..position];
        const right = input[position + 1 ..];
        const left_valid = left.len == 0 or std.mem.eql(u8, left, "*") or
            validName(left, false);
        const right_valid = std.mem.eql(u8, right, "*") or validName(right, false);
        return left_valid and right_valid;
    }
    return std.mem.eql(u8, input, "*") or validName(input, false);
}

fn validName(input: []const u8, allow_digit_start: bool) bool {
    if (input.len == 0 or (input.len == 1 and input[0] == '-')) return false;
    var index: usize = 0;
    var first = true;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return false;
            first = false;
            continue;
        }
        if (first) {
            if (!isNameStart(byte) and !(allow_digit_start and std.ascii.isDigit(byte))) {
                return false;
            }
            first = false;
        } else if (!isNameContinue(byte)) {
            return false;
        }
        index += 1;
    }
    return !first;
}

fn normalizeEscapeWhitespace(input: []const u8, index: usize) usize {
    if (input[index] == '\r' and index + 1 < input.len and input[index + 1] == '\n') {
        return index + 2;
    }
    return index + 1;
}

fn escapeEnd(input: []const u8, start: usize) ?usize {
    if (start + 1 >= input.len) return null;
    var index = start + 1;
    if (input[index] == 0 or input[index] == '\n' or input[index] == '\r' or
        input[index] == '\x0c')
    {
        return null;
    }
    if (std.ascii.isHex(input[index])) {
        var digits: usize = 0;
        while (index < input.len and digits < 6 and std.ascii.isHex(input[index])) {
            index += 1;
            digits += 1;
        }
        if (index < input.len and isWhitespace(input[index])) {
            index = normalizeEscapeWhitespace(input, index);
        }
        return index;
    }
    return index + 1;
}

fn commentEnd(input: []const u8, start: usize) ?usize {
    if (start + 1 >= input.len or input[start] != '/' or input[start + 1] != '*') {
        return null;
    }
    var cursor = start + 2;
    while (cursor + 1 < input.len) : (cursor += 1) {
        if (input[cursor] == '*' and input[cursor + 1] == '/') return cursor + 2;
    }
    return null;
}

fn explicitCombinatorLength(input: []const u8, index: usize) usize {
    if (index >= input.len) return 0;
    return switch (input[index]) {
        '>', '+', '~' => 1,
        else => 0,
    };
}

fn endsWithCombinator(input: []const u8) bool {
    if (input.len == 0) return false;
    return input[input.len - 1] == '>' or input[input.len - 1] == '+' or
        input[input.len - 1] == '~';
}

fn startsWithCombinator(input: []const u8) bool {
    const index = skipWhitespace(input, 0);
    return explicitCombinatorLength(input, index) != 0;
}

fn appendBounded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_bytes: usize,
) Error!void {
    const next = std.math.add(usize, output.items.len, bytes.len) catch
        return error.SelectorLimitExceeded;
    if (next > max_bytes) return error.SelectorLimitExceeded;
    try output.appendSlice(allocator, bytes);
}

fn appendByteBounded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    byte: u8,
    max_bytes: usize,
) Error!void {
    const next = std.math.add(usize, output.items.len, 1) catch
        return error.SelectorLimitExceeded;
    if (next > max_bytes) return error.SelectorLimitExceeded;
    try output.append(allocator, byte);
}

fn skipWhitespace(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len and isWhitespace(input[index])) index += 1;
    return index;
}

fn trimWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n\x0c");
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn isSimpleMarker(byte: u8) bool {
    return byte == '&' or byte == '.' or byte == '#' or byte == '%' or byte == '[' or byte == ':';
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte);
}
