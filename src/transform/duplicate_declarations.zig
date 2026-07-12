const std = @import("std");
const ast = @import("../css/ast.zig");
const pass_manager = @import("pass_manager.zig");
const source = @import("../source.zig");

pub const id = "duplicate-declaration-analysis";

pub const Error = std.mem.Allocator.Error || error{
    AnalysisLimit,
    InvalidAst,
};

pub const Options = struct {
    max_groups: usize = 1_000_000,
    max_occurrences: usize = 2_000_000,
    max_property_bytes: usize = 64 * 1024 * 1024,
    max_rule_depth: usize = 256,
};

pub const Importance = enum {
    normal,
    important,
};

/// The transition is relative to the previous declaration of the same
/// property in the same declaration list. It is descriptive only: no state is
/// classified as safe to delete without typed property/value compatibility.
pub const Transition = enum {
    first,
    normal_after_normal,
    important_after_normal,
    normal_after_important,
    important_after_important,
};

pub const ChainKind = enum {
    potential_fallback_chain,
    mixed_importance_chain,
};

pub const ContextKind = enum {
    style,
    nested_declarations,
    at_rule_declarations,
    keyframe,
    page,
    page_margin,
};

pub const Occurrence = struct {
    index: usize,
    importance: Importance,
    transition: Transition,
    declaration_span: source.Span,
    name_span: source.Span,
    value_span: source.Span,
};

pub const Group = struct {
    /// First authored spelling. Standard property matching is ASCII
    /// case-insensitive; custom-property matching is case-sensitive.
    property: []const u8,
    custom_property: bool,
    context: ContextKind,
    owner_span: source.Span,
    list_span: source.Span,
    chain: ChainKind,
    normal_count: usize,
    important_count: usize,
    same_importance_links: usize,
    importance_transition_links: usize,
    occurrences: []const Occurrence,
};

/// Fully owns its groups, occurrences, and copied property names. Source IDs
/// and spans remain useful after the parsed compilation has been released.
pub const Report = struct {
    allocator: std.mem.Allocator,
    groups: []const Group,
    occurrence_storage: []Occurrence,
    property_storage: []u8,

    pub fn deinit(self: *Report) void {
        const allocator = self.allocator;
        if (self.property_storage.len > 0) allocator.free(self.property_storage);
        if (self.occurrence_storage.len > 0) allocator.free(self.occurrence_storage);
        if (self.groups.len > 0) allocator.free(self.groups);
        self.* = .{
            .allocator = allocator,
            .groups = &.{},
            .occurrence_storage = &.{},
            .property_storage = &.{},
        };
    }

    pub fn equivalent(self: *const Report, other: *const Report) bool {
        if (self.groups.len != other.groups.len) return false;
        for (self.groups, other.groups) |left, right| {
            if (!std.mem.eql(u8, left.property, right.property) or
                left.custom_property != right.custom_property or
                left.context != right.context or
                !sameSpan(left.owner_span, right.owner_span) or
                !sameSpan(left.list_span, right.list_span) or
                left.chain != right.chain or
                left.normal_count != right.normal_count or
                left.important_count != right.important_count or
                left.same_importance_links != right.same_importance_links or
                left.importance_transition_links != right.importance_transition_links or
                left.occurrences.len != right.occurrences.len)
            {
                return false;
            }
            for (left.occurrences, right.occurrences) |left_occurrence, right_occurrence| {
                if (left_occurrence.index != right_occurrence.index or
                    left_occurrence.importance != right_occurrence.importance or
                    left_occurrence.transition != right_occurrence.transition or
                    !sameSpan(left_occurrence.declaration_span, right_occurrence.declaration_span) or
                    !sameSpan(left_occurrence.name_span, right_occurrence.name_span) or
                    !sameSpan(left_occurrence.value_span, right_occurrence.value_span))
                {
                    return false;
                }
            }
        }
        return true;
    }
};

pub fn analyze(
    allocator: std.mem.Allocator,
    rules: *const ast.RuleList,
    options: Options,
) Error!Report {
    var count_state = CountState{
        .allocator = allocator,
        .options = options,
    };
    try walkRuleList(&count_state, rules, 0, options.max_rule_depth);

    const groups = try allocator.alloc(Group, count_state.group_count);
    errdefer if (groups.len > 0) allocator.free(groups);
    const occurrences = try allocator.alloc(Occurrence, count_state.occurrence_count);
    errdefer if (occurrences.len > 0) allocator.free(occurrences);
    const properties = try allocator.alloc(u8, count_state.property_bytes);
    errdefer if (properties.len > 0) allocator.free(properties);

    var fill_state = FillState{
        .allocator = allocator,
        .groups = groups,
        .occurrences = occurrences,
        .properties = properties,
    };
    try walkRuleList(&fill_state, rules, 0, options.max_rule_depth);
    if (fill_state.group_index != groups.len or
        fill_state.occurrence_index != occurrences.len or
        fill_state.property_index != properties.len)
    {
        return error.InvalidAst;
    }

    return .{
        .allocator = allocator,
        .groups = groups,
        .occurrence_storage = occurrences,
        .property_storage = properties,
    };
}

pub fn definition() pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .analysis,
            .safety = .analysis,
            .maturity = .verified,
            .precondition = "the source-matched AST is valid and contains no error diagnostics",
            .postcondition = "duplicate groups are computed per declaration list without changing the AST",
            .no_op_conditions = "analysis always returns the exact input root and reports no group for a unique property",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "analysis visits source-ordered lists and never reconstructs or reorders syntax",
            .acceptance = .{
                .postcondition = true,
                .idempotence = true,
                .allocation_failures = true,
                .nested_rules = true,
                .order_validation = true,
            },
        },
        .run = run,
        .validate = validate,
    };
}

const PropertyContext = struct {
    pub fn hash(_: PropertyContext, property: []const u8) u64 {
        const custom = isCustomProperty(property);
        if (custom) return std.hash.Wyhash.hash(1, property);

        var hasher = std.hash.Wyhash.init(0);
        var normalized: [128]u8 = undefined;
        var start: usize = 0;
        while (start < property.len) {
            const end = @min(start + normalized.len, property.len);
            for (property[start..end], 0..) |byte, index| {
                normalized[index] = std.ascii.toLower(byte);
            }
            hasher.update(normalized[0 .. end - start]);
            start = end;
        }
        return hasher.final();
    }

    pub fn eql(_: PropertyContext, left: []const u8, right: []const u8) bool {
        const left_custom = isCustomProperty(left);
        if (left_custom != isCustomProperty(right)) return false;
        return if (left_custom)
            std.mem.eql(u8, left, right)
        else
            std.ascii.eqlIgnoreCase(left, right);
    }
};

const PropertyStats = struct {
    count: usize,
    first_index: usize,
    normal_count: usize,
    important_count: usize,
    group_index: usize = std.math.maxInt(usize),
    occurrence_start: usize = 0,
    next_occurrence: usize = 0,
    previous_importance: ?Importance = null,
};

const PropertyMap = std.HashMapUnmanaged(
    []const u8,
    PropertyStats,
    PropertyContext,
    80,
);

fn buildPropertyMap(
    allocator: std.mem.Allocator,
    list: *const ast.DeclarationList,
) Error!PropertyMap {
    list.validate() catch return error.InvalidAst;
    if (list.declarations.len > std.math.maxInt(u32)) return error.AnalysisLimit;

    var map = PropertyMap.empty;
    errdefer map.deinit(allocator);
    // Authored declarations covered by a generated-declaration proof are no
    // longer the logical emitted declaration sequence. Decline analysis until
    // the report API can expose that logical view without misleading callers.
    if (list.generated_declarations.len != 0) return map;
    for (list.declarations, 0..) |declaration, index| {
        const importance: Importance = if (declaration.important == null) .normal else .important;
        const entry = try map.getOrPutContext(allocator, declaration.name.value, .{});
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .count = 1,
                .first_index = index,
                .normal_count = @intFromBool(importance == .normal),
                .important_count = @intFromBool(importance == .important),
            };
        } else {
            entry.value_ptr.count = try addBounded(entry.value_ptr.count, 1);
            if (importance == .normal) {
                entry.value_ptr.normal_count = try addBounded(entry.value_ptr.normal_count, 1);
            } else {
                entry.value_ptr.important_count = try addBounded(entry.value_ptr.important_count, 1);
            }
        }
    }
    return map;
}

const CountState = struct {
    allocator: std.mem.Allocator,
    options: Options,
    group_count: usize = 0,
    occurrence_count: usize = 0,
    property_bytes: usize = 0,

    fn declarationList(
        self: *CountState,
        context: ContextKind,
        owner_span: source.Span,
        list: *const ast.DeclarationList,
    ) Error!void {
        _ = context;
        if (!contains(owner_span, list.span)) return error.InvalidAst;
        list.validate() catch return error.InvalidAst;
        if (list.generated_declarations.len != 0) return;
        if (list.declarations.len < 2) {
            return;
        }

        var map = try buildPropertyMap(self.allocator, list);
        defer map.deinit(self.allocator);
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            const stats = entry.value_ptr.*;
            if (stats.count < 2) continue;
            self.group_count = try addBounded(self.group_count, 1);
            self.occurrence_count = try addBounded(self.occurrence_count, stats.count);
            self.property_bytes = try addBounded(self.property_bytes, entry.key_ptr.*.len);
            if (self.group_count > self.options.max_groups or
                self.occurrence_count > self.options.max_occurrences or
                self.property_bytes > self.options.max_property_bytes)
            {
                return error.AnalysisLimit;
            }
        }
    }
};

const FillState = struct {
    allocator: std.mem.Allocator,
    groups: []Group,
    occurrences: []Occurrence,
    properties: []u8,
    group_index: usize = 0,
    occurrence_index: usize = 0,
    property_index: usize = 0,

    fn declarationList(
        self: *FillState,
        context: ContextKind,
        owner_span: source.Span,
        list: *const ast.DeclarationList,
    ) Error!void {
        if (!contains(owner_span, list.span)) return error.InvalidAst;
        list.validate() catch return error.InvalidAst;
        if (list.generated_declarations.len != 0) return;
        if (list.declarations.len < 2) {
            return;
        }

        var map = try buildPropertyMap(self.allocator, list);
        defer map.deinit(self.allocator);
        for (list.declarations, 0..) |declaration, index| {
            const stats = map.getPtrContext(declaration.name.value, .{}) orelse return error.InvalidAst;
            if (stats.count < 2) continue;

            if (stats.group_index == std.math.maxInt(usize)) {
                if (index != stats.first_index or self.group_index >= self.groups.len) {
                    return error.InvalidAst;
                }
                const occurrence_end = try addBounded(self.occurrence_index, stats.count);
                const property_end = try addBounded(self.property_index, declaration.name.value.len);
                if (occurrence_end > self.occurrences.len or property_end > self.properties.len) {
                    return error.InvalidAst;
                }
                const property = self.properties[self.property_index..property_end];
                @memcpy(property, declaration.name.value);
                self.groups[self.group_index] = .{
                    .property = property,
                    .custom_property = isCustomProperty(declaration.name.value),
                    .context = context,
                    .owner_span = owner_span,
                    .list_span = list.span,
                    .chain = if (stats.normal_count == 0 or stats.important_count == 0)
                        .potential_fallback_chain
                    else
                        .mixed_importance_chain,
                    .normal_count = stats.normal_count,
                    .important_count = stats.important_count,
                    .same_importance_links = 0,
                    .importance_transition_links = 0,
                    .occurrences = self.occurrences[self.occurrence_index..occurrence_end],
                };
                stats.group_index = self.group_index;
                stats.occurrence_start = self.occurrence_index;
                self.group_index += 1;
                self.occurrence_index = occurrence_end;
                self.property_index = property_end;
            }

            const importance: Importance = if (declaration.important == null) .normal else .important;
            const transition = transitionFrom(stats.previous_importance, importance);
            const occurrence_index = try addBounded(stats.occurrence_start, stats.next_occurrence);
            if (occurrence_index >= self.occurrences.len or stats.group_index >= self.groups.len) {
                return error.InvalidAst;
            }
            self.occurrences[occurrence_index] = .{
                .index = index,
                .importance = importance,
                .transition = transition,
                .declaration_span = declaration.span,
                .name_span = declaration.name.span,
                .value_span = declaration.value.span,
            };
            if (stats.previous_importance) |previous| {
                if (previous == importance) {
                    self.groups[stats.group_index].same_importance_links = try addBounded(
                        self.groups[stats.group_index].same_importance_links,
                        1,
                    );
                } else {
                    self.groups[stats.group_index].importance_transition_links = try addBounded(
                        self.groups[stats.group_index].importance_transition_links,
                        1,
                    );
                }
            }
            stats.previous_importance = importance;
            stats.next_occurrence = try addBounded(stats.next_occurrence, 1);
        }

        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            const stats = entry.value_ptr.*;
            if (stats.count > 1 and stats.next_occurrence != stats.count) return error.InvalidAst;
        }
    }
};

fn walkRuleList(
    state: anytype,
    rules: *const ast.RuleList,
    depth: usize,
    max_depth: usize,
) Error!void {
    if (depth >= max_depth) return error.AnalysisLimit;
    rules.validate() catch return error.InvalidAst;
    for (rules.rules) |rule| switch (rule) {
        .style_rule => |style| {
            _ = ast.StyleRule.init(style.*) catch return error.InvalidAst;
            try state.declarationList(.style, style.span, &style.block.declarations);
            try walkRuleList(state, &style.block.rules, try addBounded(depth, 1), max_depth);
        },
        .nested_declarations => |nested| {
            _ = ast.NestedDeclarationsRule.init(nested.*) catch return error.InvalidAst;
            try state.declarationList(
                .nested_declarations,
                nested.span,
                &nested.declarations,
            );
        },
        .at_rule => |at_rule| {
            _ = ast.AtRule.init(at_rule.*) catch return error.InvalidAst;
            switch (at_rule.block) {
                .none => {},
                .declarations => |block| try state.declarationList(
                    .at_rule_declarations,
                    at_rule.span,
                    &block.declarations,
                ),
                .rules => |block| try walkRuleList(
                    state,
                    &block.rules,
                    try addBounded(depth, 1),
                    max_depth,
                ),
                .keyframes => |block| for (block.frames) |*frame| {
                    _ = ast.KeyframeRule.init(frame.*) catch return error.InvalidAst;
                    try state.declarationList(
                        .keyframe,
                        frame.span,
                        &frame.block.declarations,
                    );
                },
                .raw => if (at_rule.details) |details| switch (details) {
                    .page => |page| {
                        try state.declarationList(.page, page.span, page.declarations);
                        for (page.margins) |*margin| try state.declarationList(
                            .page_margin,
                            margin.span,
                            margin.declarations,
                        );
                    },
                    else => {},
                },
            }
        },
    };
}

fn transitionFrom(previous: ?Importance, current: Importance) Transition {
    const old = previous orelse return .first;
    return switch (old) {
        .normal => if (current == .normal) .normal_after_normal else .important_after_normal,
        .important => if (current == .normal) .normal_after_important else .important_after_important,
    };
}

fn isCustomProperty(property: []const u8) bool {
    return std.mem.startsWith(u8, property, "--");
}

fn addBounded(left: usize, right: usize) Error!usize {
    return std.math.add(usize, left, right) catch return error.AnalysisLimit;
}

fn sameSpan(left: source.Span, right: source.Span) bool {
    return left.source.eql(right.source) and left.start == right.start and left.end == right.end;
}

fn contains(parent: source.Span, child: source.Span) bool {
    return parent.source.eql(child.source) and
        parent.start <= child.start and child.end <= parent.end;
}

fn run(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    if (user_data != null) return error.PassFailed;
    var report = analyze(context.scratchAllocator(), input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => return error.InvalidAst,
        error.AnalysisLimit => return error.PassFailed,
    };
    report.deinit();
    return input;
}

fn validate(
    user_data: ?*anyopaque,
    phase: pass_manager.ValidationPhase,
    context: *pass_manager.Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) pass_manager.Error!void {
    _ = phase;
    if (user_data != null or before != after) return error.ValidationFailed;
    var report = analyze(context.scratchAllocator(), after, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ValidationFailed,
    };
    report.deinit();
}

const pipeline = @import("../css/pipeline.zig");

fn findGroup(report: *const Report, property: []const u8) ?*const Group {
    for (report.groups) |*group| {
        if (std.mem.eql(u8, group.property, property)) return group;
    }
    return null;
}

test "duplicate analysis respects standard casing custom-property casing and importance" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "duplicates.css",
        ".a{COLOR:red;c\\6flor:blue;--Theme:one;--theme:two;--Theme:three;" ++
            "display:-webkit-box;display:flex;color:green!important;color:black;color:white!important}",
    );
    var report = try analyze(std.testing.allocator, parsed.rules, .{});
    parsed.deinit();
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 3), report.groups.len);
    const color = findGroup(&report, "COLOR").?;
    try std.testing.expect(!color.custom_property);
    try std.testing.expectEqual(ChainKind.mixed_importance_chain, color.chain);
    try std.testing.expectEqual(@as(usize, 3), color.normal_count);
    try std.testing.expectEqual(@as(usize, 2), color.important_count);
    try std.testing.expectEqual(@as(usize, 1), color.same_importance_links);
    try std.testing.expectEqual(@as(usize, 3), color.importance_transition_links);
    try std.testing.expectEqualSlices(
        Transition,
        &.{
            .first,
            .normal_after_normal,
            .important_after_normal,
            .normal_after_important,
            .important_after_normal,
        },
        &.{
            color.occurrences[0].transition,
            color.occurrences[1].transition,
            color.occurrences[2].transition,
            color.occurrences[3].transition,
            color.occurrences[4].transition,
        },
    );

    const custom = findGroup(&report, "--Theme").?;
    try std.testing.expect(custom.custom_property);
    try std.testing.expectEqual(@as(usize, 2), custom.occurrences.len);
    try std.testing.expect(findGroup(&report, "--theme") == null);
    const display = findGroup(&report, "display").?;
    try std.testing.expectEqual(ChainKind.potential_fallback_chain, display.chain);
    try std.testing.expectEqual(@as(usize, 2), display.normal_count);
}

test "duplicate analysis traverses nested typed contexts without crossing list boundaries" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "duplicate-contexts.css",
        "@layer base{.a{x:1;x:2}@media all{.b{y:1;y:2}}}" ++
            ".host{z:1;.nested{q:1;q:2}z:2}" ++
            "@font-face{src:url(a);src:url(b)}" ++
            "@keyframes k{from{opacity:0;opacity:1}}" ++
            "@page{margin:1cm;margin:2cm;@top-left{content:\"a\";content:\"b\"}}",
    );
    defer parsed.deinit();
    var report = try analyze(std.testing.allocator, parsed.rules, .{});
    defer report.deinit();

    const expected = [_]struct { []const u8, ContextKind }{
        .{ "x", .style },
        .{ "y", .style },
        .{ "q", .style },
        .{ "src", .at_rule_declarations },
        .{ "opacity", .keyframe },
        .{ "margin", .page },
        .{ "content", .page_margin },
    };
    try std.testing.expectEqual(expected.len, report.groups.len);
    for (expected, report.groups) |item, group| {
        try std.testing.expectEqualStrings(item[0], group.property);
        try std.testing.expectEqual(item[1], group.context);
    }
    try std.testing.expect(findGroup(&report, "z") == null);
}

test "duplicate analysis is deterministic bounded and never mutates a pass root" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "duplicate-pass.css",
        ".a{margin-inline-start:1px;margin-inline-start:2px;" ++
            "unsupported-value:alpha;unsupported-value:beta}",
    );
    defer parsed.deinit();
    var first = try analyze(std.testing.allocator, parsed.rules, .{});
    defer first.deinit();
    var second = try analyze(std.testing.allocator, parsed.rules, .{});
    defer second.deinit();
    try std.testing.expect(first.equivalent(&second));
    try std.testing.expectError(
        error.AnalysisLimit,
        analyze(std.testing.allocator, parsed.rules, .{ .max_groups = 1 }),
    );
    try std.testing.expectError(
        error.AnalysisLimit,
        analyze(std.testing.allocator, parsed.rules, .{ .max_rule_depth = 0 }),
    );

    const original = parsed.rules;
    const registry = [_]pass_manager.Pass{definition()};
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{id},
        .{},
    );
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == original);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{margin-inline-start:1px;margin-inline-start:2px;" ++
            "unsupported-value:alpha;unsupported-value:beta}",
        result.css,
    );
}

test "duplicate analysis returns an owned empty report with idempotent cleanup" {
    var parsed = try pipeline.parse(std.testing.allocator, "unique.css", ".a{x:1;y:2}");
    var report = try analyze(std.testing.allocator, parsed.rules, .{});
    parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.groups.len);
    report.deinit();
    report.deinit();
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "duplicate-oom.css",
        ".a{color:red;color:blue!important;color:green;--x:a;--x:b}" ++
            "@media all{.b{display:block;display:flex}}",
    );
    defer parsed.deinit();
    var report = try analyze(allocator, parsed.rules, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 3), report.groups.len);

    const registry = [_]pass_manager.Pass{definition()};
    var plan = try pass_manager.buildPlan(allocator, &registry, &.{id}, .{});
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
}

test "duplicate analysis handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
