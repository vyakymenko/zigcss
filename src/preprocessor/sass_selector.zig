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
    UnsupportedSelectorUnification,
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

const UnifyContext = struct {
    limits: Limits,
    component_count: usize = 0,
    temporary_bytes: usize = 0,
    operations: u64 = 0,

    fn reserveComponents(self: *UnifyContext, count: usize) Error!void {
        const next = std.math.add(usize, self.component_count, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_complex_components) {
            return error.SelectorLimitExceeded;
        }
        self.component_count = next;
    }

    fn reserveTemporary(self: *UnifyContext, count: usize) Error!void {
        const next = std.math.add(usize, self.temporary_bytes, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_temporary_bytes) {
            return error.SelectorLimitExceeded;
        }
        self.temporary_bytes = next;
    }

    fn consume(self: *UnifyContext, count: u64) Error!void {
        const next = std.math.add(u64, self.operations, count) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_relation_operations) {
            return error.SelectorLimitExceeded;
        }
        self.operations = next;
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
    if (counted.leading_combinator) return error.UnsupportedSelectorUnification;
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
    std.debug.assert(!filled.leading_combinator);
    if (components[components.len - 1].combinator != .none) {
        return error.UnsupportedSelectorUnification;
    }
    for (components) |component| {
        try validateUnifyCompoundAvailability(component.compound, context);
    }
    return .{ .leading_combinator = false, .components = components };
}

fn validateUnifyCompoundAvailability(
    input: []const u8,
    context: *UnifyContext,
) Error!void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const end = try simpleTokenEnd(input, cursor);
        const token = input[cursor..end];
        if (std.mem.indexOfScalar(u8, token, '\\') != null or
            unsupportedUnifyPseudo(token))
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
/// shared descendant anchors. Partial shared anchors, following-sibling weaving,
/// escaped identifier equivalence, and host-selector semantics remain unavailable.
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
    for (ancestries) |ancestry| {
        for (ancestry) |component| {
            try context.consume(1);
            if (component.combinator != .descendant or
                !try unifyWeaveCompoundAvailable(component.compound, context))
            {
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
            if (std.mem.eql(
                u8,
                left_ancestry[left_offset - 1].compound,
                right_ancestry[right_offset - 1].compound,
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
        if (std.mem.eql(
            u8,
            left_ancestry[left_offset - 1].compound,
            right_ancestry[right_offset - 1].compound,
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
        if (left_segment.len > 0 and right_segment.len > 0) {
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
    if (left_tail.len > 0 and right_tail.len > 0) {
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

fn sharedUnifyWeaveSegmentAvailable(
    left: []const RelationComponent,
    right: []const RelationComponent,
    context: *UnifyContext,
) Error!bool {
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
            if (component.combinator == .none or
                component.combinator == .following_sibling)
            {
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
            output_length = std.math.add(
                usize,
                output_length,
                component.compound.len,
            ) catch return error.SelectorLimitExceeded;
            output_length = std.math.add(usize, output_length, 1) catch
                return error.SelectorLimitExceeded;
        }
    }
    for (anchors) |anchor| {
        if (anchor.left_index >= left_ancestry.len or
            anchor.right_index >= right_ancestry.len or
            !std.mem.eql(
                u8,
                left_ancestry[anchor.left_index].compound,
                right_ancestry[anchor.right_index].compound,
            ))
        {
            return error.InvalidSelector;
        }
        try context.consume(1);
        const duplicate_length = std.math.add(
            usize,
            left_ancestry[anchor.left_index].compound.len,
            1,
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
    var right_first = false;
    if (left.len > 0 and right.len > 0) {
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
        try writeSharedUnifyWeaveComponents(output, offset, right);
        try writeSharedUnifyWeaveComponents(output, offset, left);
    } else {
        try writeSharedUnifyWeaveComponents(output, offset, left);
        try writeSharedUnifyWeaveComponents(output, offset, right);
    }
}

fn writeSharedUnifyWeaveComponents(
    output: []u8,
    offset: *usize,
    components: []const RelationComponent,
) Error!void {
    for (components) |component| {
        const compound_end = std.math.add(
            usize,
            offset.*,
            component.compound.len,
        ) catch return error.SelectorLimitExceeded;
        const next = std.math.add(usize, compound_end, 1) catch
            return error.SelectorLimitExceeded;
        if (next > output.len) return error.InvalidSelector;
        std.mem.copyForwards(
            u8,
            output[offset.*..compound_end],
            component.compound,
        );
        output[compound_end] = ' ';
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

fn unifyCompound(
    allocator: std.mem.Allocator,
    left_input: []const u8,
    right_input: []const u8,
    context: *UnifyContext,
) Error!?[]u8 {
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
        if (std.mem.indexOfScalar(u8, token, '\\') != null or
            unsupportedUnifyPseudo(token))
        {
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
            try normalizeAttribute(allocator, token)
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
    const opening = std.mem.indexOfScalar(u8, token, '(');
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
