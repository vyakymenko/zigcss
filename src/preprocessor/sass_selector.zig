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
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidSelector,
    SelectorLimitExceeded,
    UnsupportedSelectorRelation,
};

pub const SelectorList = struct {
    allocator: std.mem.Allocator,
    items: [][]u8,

    pub fn deinit(self: *SelectorList) void {
        for (self.items) |item| self.allocator.free(item);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    allow_parent: bool = false,
    items: std.ArrayList([]u8) = .empty,
    byte_count: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendSegment(self: *Builder, raw: []const u8) Error!void {
        const trimmed = trimWhitespace(raw);
        if (trimmed.len == 0) return;
        const owned = try canonicalize(
            self.allocator,
            trimmed,
            self.limits.max_bytes,
            self.allow_parent,
        );
        self.admitOwned(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn appendToken(self: *Builder, raw: []const u8) Error!void {
        const owned = if (raw.len > 0 and raw[0] == '[')
            try normalizeAttribute(self.allocator, raw)
        else
            try self.allocator.dupe(u8, raw);
        self.admitOwned(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn admitOwned(self: *Builder, owned: []u8) Error!void {
        if (self.items.items.len >= self.limits.max_selectors) {
            return error.SelectorLimitExceeded;
        }
        const next = std.math.add(usize, self.byte_count, owned.len) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_bytes) return error.SelectorLimitExceeded;
        try self.items.append(self.allocator, owned);
        self.byte_count = next;
    }

    fn finish(self: *Builder) Error!SelectorList {
        return .{
            .allocator = self.allocator,
            .items = try self.items.toOwnedSlice(self.allocator),
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
    if (limits.max_selectors == 0 or limits.max_bytes == 0) {
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
    leading_combinator: bool,
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

const RelationContext = struct {
    limits: Limits,
    component_count: usize = 0,
    temporary_bytes: usize = 0,
    operations: u64 = 0,

    fn reserveComponents(self: *RelationContext, count: usize) Error!void {
        const next = std.math.add(usize, self.component_count, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_complex_components) {
            return error.SelectorLimitExceeded;
        }
        self.component_count = next;
    }

    fn reserveTemporary(self: *RelationContext, count: usize) Error!void {
        const next = std.math.add(usize, self.temporary_bytes, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_temporary_bytes) {
            return error.SelectorLimitExceeded;
        }
        self.temporary_bytes = next;
    }

    fn consume(self: *RelationContext, count: u64) Error!void {
        const next = std.math.add(u64, self.operations, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_relation_operations) {
            return error.SelectorLimitExceeded;
        }
        self.operations = next;
    }
};

const SelectorUsage = struct {
    selectors: usize,
    bytes: usize,
};

/// Returns whether every selector matched by `sub_input` is also matched by
/// `super_input`. This first native slice owns structural selector lists,
/// compounds, namespaces, and the standard combinators. Relation inference
/// for non-identical functional pseudos, escaped identifiers, and normalized
/// attribute spellings remains explicitly unavailable rather than guessed.
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

    var context = RelationContext{ .limits = limits };
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
        for (super_complexes.items) |complex| {
            if (complex.leading_combinator or
                complex.components[complex.components.len - 1].combinator != .none)
            {
                return false;
            }
        }
        return true;
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
    return .{ .selectors = list.items.len, .bytes = bytes };
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
    leading_combinator: bool,
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
    var leading_combinator = false;
    const leading_length = explicitCombinatorLength(input, index);
    if (leading_length != 0) {
        leading_combinator = true;
        index = skipWhitespace(input, index + leading_length);
        if (index == input.len) return error.InvalidSelector;
    }

    var count: usize = 0;
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
        if (next == input.len) break;
        index = next;
    }
    if (count == 0) return error.InvalidSelector;
    if (destination) |components| {
        if (count != components.len) return error.InvalidSelector;
    }
    return .{
        .leading_combinator = leading_combinator,
        .component_count = count,
    };
}

fn relationComplexIsSuperselector(
    context: *RelationContext,
    super_complex: RelationComplex,
    sub_complex: RelationComplex,
) Error!bool {
    try context.consume(1);
    if (super_complex.leading_combinator or sub_complex.leading_combinator) {
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
    if (super_count > sub_count) return false;

    var super_cursor: usize = 0;
    while (super_cursor < super_compound.len) {
        const super_end = try simpleTokenEnd(super_compound, super_cursor);
        const super_simple = super_compound[super_cursor..super_end];
        var exact = false;
        var sub_cursor: usize = 0;
        while (sub_cursor < sub_compound.len) {
            try context.consume(1);
            const sub_end = try simpleTokenEnd(sub_compound, sub_cursor);
            if (std.mem.eql(u8, super_simple, sub_compound[sub_cursor..sub_end])) {
                exact = true;
                break;
            }
            sub_cursor = sub_end;
        }
        if (!exact) {
            if (super_simple[0] == '[') {
                sub_cursor = 0;
                while (sub_cursor < sub_compound.len) {
                    const sub_end = try simpleTokenEnd(sub_compound, sub_cursor);
                    if (sub_compound[sub_cursor] == '[') {
                        return error.UnsupportedSelectorRelation;
                    }
                    sub_cursor = sub_end;
                }
                return false;
            }
            if (relationSimpleRequiresInference(super_simple)) {
                return error.UnsupportedSelectorRelation;
            }
            var semantic_match = false;
            var ambiguous_sub = false;
            sub_cursor = 0;
            while (sub_cursor < sub_compound.len) {
                try context.consume(1);
                const sub_end = try simpleTokenEnd(sub_compound, sub_cursor);
                ambiguous_sub = ambiguous_sub or
                    relationSimpleRequiresInference(sub_compound[sub_cursor..sub_end]);
                if (relationSimpleIsSuperselector(
                    super_simple,
                    sub_compound[sub_cursor..sub_end],
                )) {
                    semantic_match = true;
                    break;
                }
                sub_cursor = sub_end;
            }
            if (!semantic_match) {
                if (ambiguous_sub) return error.UnsupportedSelectorRelation;
                return false;
            }
        }
        super_cursor = super_end;
    }
    return true;
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
        std.mem.indexOfScalar(u8, input, '(') != null)
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
    return std.mem.indexOfScalar(u8, input, '\\') != null or
        (input[0] == ':' and std.mem.indexOfScalar(u8, input, '(') != null);
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
                    limits.max_bytes,
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
    max_bytes: usize,
) Error![]u8 {
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
    return canonicalize(allocator, raw.items, max_bytes, true);
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
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    var pending_space = false;
    while (index < input.len) {
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
    return output.toOwnedSlice(allocator);
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
        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            '(' => if (square_depth == 0) {
                depth += 1;
            },
            ')' => if (square_depth == 0) {
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

fn normalizeAttribute(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    const equals = std.mem.indexOfScalar(u8, input, '=') orelse
        return allocator.dupe(u8, input);
    var opening = equals + 1;
    while (opening + 1 < input.len and isWhitespace(input[opening])) opening += 1;
    if (opening + 1 >= input.len or (input[opening] != '\'' and input[opening] != '"')) {
        return allocator.dupe(u8, input);
    }
    const quote = input[opening];
    var closing = opening + 1;
    while (closing < input.len - 1) {
        if (input[closing] == '\\') {
            closing = escapeEnd(input, closing) orelse return error.InvalidSelector;
            continue;
        }
        if (input[closing] == quote) break;
        closing += 1;
    }
    if (closing >= input.len - 1 or input[closing] != quote) return error.InvalidSelector;
    if (!validName(input[opening + 1 .. closing], false)) return allocator.dupe(u8, input);
    const tail = trimWhitespace(input[closing + 1 .. input.len - 1]);
    if (tail.len > 1 or (tail.len == 1 and
        std.ascii.toLower(tail[0]) != 'i' and std.ascii.toLower(tail[0]) != 's'))
    {
        return allocator.dupe(u8, input);
    }
    const owned = try allocator.alloc(u8, input.len - 2);
    std.mem.copyForwards(u8, owned[0..opening], input[0..opening]);
    std.mem.copyForwards(
        u8,
        owned[opening .. opening + closing - opening - 1],
        input[opening + 1 .. closing],
    );
    std.mem.copyForwards(
        u8,
        owned[opening + closing - opening - 1 ..],
        input[closing + 1 ..],
    );
    return owned;
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
