const std = @import("std");
const ast = @import("../css/ast.zig");
const pass_manager = @import("pass_manager.zig");
const source = @import("../source.zig");

pub const id = "empty-rule-cleanup";

pub fn definition() pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .cleanup,
            .safety = .lossless_cleanup,
            .maturity = .verified,
            .precondition = "the source-matched AST is valid and contains no error diagnostics",
            .postcondition = "only empty style rules and proven-empty conditional groups are omitted recursively; every survivor and its relative order are preserved",
            .no_op_conditions = "the exact input root is returned when no removable rule exists at any depth",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "survivors are copied in source order without sorting or merging",
            .claims_size_reduction = true,
            .acceptance = .{
                .postcondition = true,
                .idempotence = true,
                .allocation_failures = true,
                .nested_rules = true,
                .semantic_validation = true,
                .differential_validation = true,
                .order_validation = true,
                .size_validation = true,
            },
        },
        .run = run,
        .validate = validate,
    };
}

const CleanRule = struct {
    rule: ast.Rule,
    changed: bool,
};

const CleanList = struct {
    rules: *const ast.RuleList,
    changed: bool,
};

fn run(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    if (user_data != null) return error.PassFailed;
    return (try cleanRuleList(context, input)).rules;
}

fn cleanRuleList(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!CleanList {
    if (!listNeedsCleanup(input)) return .{ .rules = input, .changed = false };

    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(?ast.Rule, input.rules.len);
    defer scratch.free(candidates);
    const removed = try scratch.alloc(ast.Rule, input.rules.len);
    defer scratch.free(removed);

    var survivor_count: usize = 0;
    var removed_count: usize = 0;
    var changed = false;
    for (input.rules, 0..) |rule, index| {
        const candidate = try cleanRule(context, rule);
        if (ast.isOmittableRule(candidate.rule)) {
            candidates[index] = null;
            removed[removed_count] = candidate.rule;
            removed_count += 1;
            changed = true;
            continue;
        }

        candidates[index] = candidate.rule;
        survivor_count += 1;
        changed = changed or candidate.changed;
    }

    if (!changed) return .{ .rules = input, .changed = false };

    const arena = context.arenaAllocator();
    const survivors: []ast.Rule = if (survivor_count == 0)
        &.{}
    else
        try arena.alloc(ast.Rule, survivor_count);
    var survivor_index: usize = 0;
    for (candidates) |candidate| {
        if (candidate) |rule| {
            survivors[survivor_index] = rule;
            survivor_index += 1;
        }
    }

    const omissions = if (removed_count == 0)
        input.omitted_rules
    else
        try mergeOmissions(arena, input.omitted_rules, removed[0..removed_count]);
    const output = try arena.create(ast.RuleList);
    output.* = ast.RuleList.initWithOmissions(input.span, survivors, omissions) catch {
        return error.InvalidAst;
    };
    return .{ .rules = output, .changed = true };
}

fn cleanRule(context: *pass_manager.Context, input: ast.Rule) pass_manager.Error!CleanRule {
    return switch (input) {
        .style_rule => |style| blk: {
            const child = try cleanRuleList(context, &style.block.rules);
            if (!child.changed) break :blk .{ .rule = input, .changed = false };

            const arena = context.arenaAllocator();
            const output = try arena.create(ast.StyleRule);
            const block = ast.StyleBlock.init(
                style.block.envelope,
                style.block.declarations,
                child.rules.*,
            ) catch return error.InvalidAst;
            output.* = ast.StyleRule.init(.{
                .selectors = style.selectors,
                .block = block,
                .span = style.span,
            }) catch return error.InvalidAst;
            break :blk .{ .rule = .{ .style_rule = output }, .changed = true };
        },
        .at_rule => |at_rule| blk: {
            const old_block = switch (at_rule.block) {
                .rules => |block| block,
                else => break :blk .{ .rule = input, .changed = false },
            };
            const child = try cleanRuleList(context, &old_block.rules);
            if (!child.changed) break :blk .{ .rule = input, .changed = false };

            const arena = context.arenaAllocator();
            const new_block = try arena.create(ast.RulesBlock);
            new_block.* = (if (old_block.nested)
                ast.RulesBlock.initNested(old_block.envelope, child.rules.*)
            else
                ast.RulesBlock.init(old_block.envelope, child.rules.*)) catch return error.InvalidAst;

            const output = try arena.create(ast.AtRule);
            output.* = ast.AtRule.init(.{
                .at_sign = at_rule.at_sign,
                .name = at_rule.name,
                .prelude = at_rule.prelude,
                .block = .{ .rules = new_block },
                .details = try cloneDetails(arena, at_rule.details, new_block),
                .span = at_rule.span,
            }) catch return error.InvalidAst;
            break :blk .{ .rule = .{ .at_rule = output }, .changed = true };
        },
        .nested_declarations => .{ .rule = input, .changed = false },
    };
}

fn mergeOmissions(
    arena: std.mem.Allocator,
    existing: []const ast.Rule,
    removed: []const ast.Rule,
) std.mem.Allocator.Error![]const ast.Rule {
    const merged = try arena.alloc(ast.Rule, existing.len + removed.len);
    var existing_index: usize = 0;
    var removed_index: usize = 0;
    for (merged) |*slot| {
        const take_existing = removed_index == removed.len or
            (existing_index < existing.len and
                existing[existing_index].span().start <= removed[removed_index].span().start);
        if (take_existing) {
            slot.* = existing[existing_index];
            existing_index += 1;
        } else {
            slot.* = removed[removed_index];
            removed_index += 1;
        }
    }
    return merged;
}

fn cloneDetails(
    arena: std.mem.Allocator,
    details: ?ast.AtRuleDetails,
    block: *const ast.RulesBlock,
) std.mem.Allocator.Error!?ast.AtRuleDetails {
    const value = details orelse return null;
    return switch (value) {
        .media => |old| blk: {
            const new = try arena.create(ast.MediaRule);
            new.* = old.*;
            new.block = block;
            break :blk .{ .media = new };
        },
        .supports => |old| blk: {
            const new = try arena.create(ast.SupportsRule);
            new.* = old.*;
            new.block = block;
            break :blk .{ .supports = new };
        },
        .container => |old| blk: {
            const new = try arena.create(ast.ContainerRule);
            new.* = old.*;
            new.block = block;
            break :blk .{ .container = new };
        },
        else => value,
    };
}

fn isEffectivelyRemovable(rule: ast.Rule) bool {
    if (ast.isOmittableRule(rule)) return true;
    return switch (rule) {
        .style_rule => |style| style.block.declarations.declarations.len == 0 and
            allRulesRemovable(&style.block.rules),
        .at_rule => |at_rule| ast.isOmittableConditionalName(at_rule.name.value) and switch (at_rule.block) {
            .rules => |block| allRulesRemovable(&block.rules),
            else => false,
        },
        .nested_declarations => false,
    };
}

fn allRulesRemovable(rules: *const ast.RuleList) bool {
    for (rules.rules) |rule| {
        if (!isEffectivelyRemovable(rule)) return false;
    }
    return true;
}

fn validate(
    user_data: ?*anyopaque,
    phase: pass_manager.ValidationPhase,
    context: *pass_manager.Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) pass_manager.Error!void {
    if (user_data != null) return error.ValidationFailed;
    try validateInputList(context.source_id, before);
    try validateInputList(context.source_id, after);

    switch (phase) {
        .precondition => if (before != after) return error.ValidationFailed,
        .postcondition => if (!cleanupMatches(before, after)) return error.ValidationFailed,
        .idempotence => {
            if (before != after or listNeedsCleanup(after)) return error.ValidationFailed;
        },
    }
}

fn validateInputList(source_id: source.SourceId, rules: *const ast.RuleList) pass_manager.Error!void {
    if (!rules.span.source.eql(source_id)) return error.ValidationFailed;
    rules.validate() catch return error.ValidationFailed;
    for (rules.rules) |rule| {
        if (!rule.span().source.eql(source_id)) return error.ValidationFailed;
        switch (rule) {
            .style_rule => |style| {
                _ = ast.StyleRule.init(style.*) catch return error.ValidationFailed;
                try validateInputList(source_id, &style.block.rules);
            },
            .at_rule => |at_rule| {
                _ = ast.AtRule.init(at_rule.*) catch return error.ValidationFailed;
                switch (at_rule.block) {
                    .rules => |block| {
                        if (!detailsBlockMatches(at_rule.details, block)) return error.ValidationFailed;
                        try validateInputList(source_id, &block.rules);
                    },
                    else => {},
                }
            },
            .nested_declarations => |declarations| {
                _ = ast.NestedDeclarationsRule.init(declarations.*) catch return error.ValidationFailed;
            },
        }
    }
}

fn detailsBlockMatches(details: ?ast.AtRuleDetails, block: *const ast.RulesBlock) bool {
    const value = details orelse return true;
    return switch (value) {
        .media => |item| item.block == block,
        .supports => |item| item.block == block,
        .container => |item| item.block == block,
        .layer => true,
        else => false,
    };
}

fn listNeedsCleanup(rules: *const ast.RuleList) bool {
    for (rules.rules) |rule| {
        if (isEffectivelyRemovable(rule)) return true;
        switch (rule) {
            .style_rule => |style| if (listNeedsCleanup(&style.block.rules)) return true,
            .at_rule => |at_rule| switch (at_rule.block) {
                .rules => |block| if (listNeedsCleanup(&block.rules)) return true,
                else => {},
            },
            .nested_declarations => {},
        }
    }
    return false;
}

fn cleanupMatches(before: *const ast.RuleList, after: *const ast.RuleList) bool {
    if (!sameSpan(before.span, after.span)) return false;
    const needs_cleanup = listNeedsCleanup(before);
    if ((!needs_cleanup and before != after) or (needs_cleanup and before == after)) return false;

    var removed_count: usize = 0;
    for (before.rules) |rule| {
        if (isEffectivelyRemovable(rule)) removed_count += 1;
    }
    if (after.rules.len != before.rules.len - removed_count) return false;
    if (!omissionsMatch(before, after, removed_count)) return false;

    var after_index: usize = 0;
    for (before.rules) |rule| {
        if (isEffectivelyRemovable(rule)) continue;
        if (after_index == after.rules.len or !survivorMatches(rule, after.rules[after_index])) return false;
        if (isEffectivelyRemovable(after.rules[after_index])) return false;
        after_index += 1;
    }
    return after_index == after.rules.len;
}

fn omissionsMatch(before: *const ast.RuleList, after: *const ast.RuleList, removed_count: usize) bool {
    if (after.omitted_rules.len != before.omitted_rules.len + removed_count) return false;

    var existing_index: usize = 0;
    var rule_index = nextRemovedRule(before.rules, 0);
    var output_index: usize = 0;
    while (existing_index < before.omitted_rules.len or rule_index != null) {
        const take_existing = rule_index == null or
            (existing_index < before.omitted_rules.len and
                before.omitted_rules[existing_index].span().start <= before.rules[rule_index.?].span().start);
        if (output_index == after.omitted_rules.len) return false;
        const actual = after.omitted_rules[output_index];
        const expected_span = if (take_existing) blk: {
            const existing = before.omitted_rules[existing_index];
            existing_index += 1;
            if (!sameRuleIdentity(existing, actual)) return false;
            break :blk existing.span();
        } else blk: {
            const removed_rule = before.rules[rule_index.?];
            rule_index = nextRemovedRule(before.rules, rule_index.? + 1);
            if (!ast.isOmittableRule(actual) or !survivorMatches(removed_rule, actual)) return false;
            break :blk removed_rule.span();
        };
        if (!sameSpan(expected_span, actual.span())) return false;
        output_index += 1;
    }
    return output_index == after.omitted_rules.len;
}

fn sameRuleIdentity(before: ast.Rule, after: ast.Rule) bool {
    return switch (before) {
        .style_rule => |old| switch (after) {
            .style_rule => |new| old == new,
            else => false,
        },
        .at_rule => |old| switch (after) {
            .at_rule => |new| old == new,
            else => false,
        },
        .nested_declarations => |old| switch (after) {
            .nested_declarations => |new| old == new,
            else => false,
        },
    };
}

fn nextRemovedRule(rules: []const ast.Rule, start: usize) ?usize {
    var index = start;
    while (index < rules.len) : (index += 1) {
        if (isEffectivelyRemovable(rules[index])) return index;
    }
    return null;
}

fn survivorMatches(before: ast.Rule, after: ast.Rule) bool {
    return switch (before) {
        .style_rule => |old| switch (after) {
            .style_rule => |new| sameStyleRule(old, new),
            else => false,
        },
        .at_rule => |old| switch (after) {
            .at_rule => |new| sameAtRule(old, new),
            else => false,
        },
        .nested_declarations => |old| switch (after) {
            .nested_declarations => |new| old == new,
            else => false,
        },
    };
}

fn sameStyleRule(before: *const ast.StyleRule, after: *const ast.StyleRule) bool {
    if (!sameSpan(before.span, after.span) or
        !sameSpan(before.selectors.span, after.selectors.span) or
        !sameSlice(ast.ComplexSelector, before.selectors.selectors, after.selectors.selectors) or
        !sameBlockSpan(before.block.envelope, after.block.envelope) or
        !sameSpan(before.block.declarations.span, after.block.declarations.span) or
        !sameSlice(ast.Declaration, before.block.declarations.declarations, after.block.declarations.declarations))
    {
        return false;
    }
    return cleanupMatches(&before.block.rules, &after.block.rules);
}

fn sameAtRule(before: *const ast.AtRule, after: *const ast.AtRule) bool {
    if (!sameSpan(before.span, after.span) or
        !sameSpan(before.at_sign, after.at_sign) or
        !sameIdentifier(before.name, after.name) or
        !sameComponentList(before.prelude, after.prelude))
    {
        return false;
    }

    const old_block = switch (before.block) {
        .rules => |block| block,
        else => return before == after,
    };
    const new_block = switch (after.block) {
        .rules => |block| block,
        else => return false,
    };
    if (old_block.nested != new_block.nested or
        !sameBlockSpan(old_block.envelope, new_block.envelope) or
        !sameDetails(before.details, after.details, old_block, new_block))
    {
        return false;
    }
    return cleanupMatches(&old_block.rules, &new_block.rules);
}

fn sameDetails(
    before: ?ast.AtRuleDetails,
    after: ?ast.AtRuleDetails,
    old_block: *const ast.RulesBlock,
    new_block: *const ast.RulesBlock,
) bool {
    if (before == null or after == null) return before == null and after == null;
    return switch (before.?) {
        .media => |old| switch (after.?) {
            .media => |new| old.block == old_block and new.block == new_block and
                sameSpan(old.query_list.span, new.query_list.span) and
                sameSlice(ast.ComponentValueList, old.query_list.queries, new.query_list.queries),
            else => false,
        },
        .supports => |old| switch (after.?) {
            .supports => |new| old.block == old_block and new.block == new_block and
                old.negated == new.negated and old.operator == new.operator and
                sameSpan(old.span, new.span) and
                sameSlice(ast.ComponentValueList, old.terms, new.terms),
            else => false,
        },
        .container => |old| switch (after.?) {
            .container => |new| old.block == old_block and new.block == new_block and
                sameOptionalIdentifier(old.name, new.name) and
                sameSpan(old.span, new.span) and sameComponentList(old.query, new.query),
            else => false,
        },
        .layer => |old| switch (after.?) {
            .layer => |new| old == new,
            else => false,
        },
        else => false,
    };
}

fn sameOptionalIdentifier(before: ?ast.Identifier, after: ?ast.Identifier) bool {
    if (before == null or after == null) return before == null and after == null;
    return sameIdentifier(before.?, after.?);
}

fn sameIdentifier(before: ast.Identifier, after: ast.Identifier) bool {
    return sameSpan(before.span, after.span) and sameSlice(u8, before.value, after.value);
}

fn sameComponentList(before: ast.ComponentValueList, after: ast.ComponentValueList) bool {
    return sameSpan(before.span, after.span) and
        sameSlice(@import("../syntax.zig").ComponentValue, before.values, after.values);
}

fn sameBlockSpan(before: ast.BlockSpan, after: ast.BlockSpan) bool {
    if (!sameSpan(before.opening, after.opening) or
        !sameSpan(before.content, after.content) or
        !sameSpan(before.span, after.span) or
        (before.closing == null) != (after.closing == null))
    {
        return false;
    }
    return before.closing == null or sameSpan(before.closing.?, after.closing.?);
}

fn sameSpan(before: source.Span, after: source.Span) bool {
    return before.source.eql(after.source) and before.start == after.start and before.end == after.end;
}

fn sameSlice(comptime T: type, before: []const T, after: []const T) bool {
    return before.len == after.len and (before.len == 0 or before.ptr == after.ptr);
}

const pipeline = @import("../css/pipeline.zig");
const sourcemap = @import("../sourcemap.zig");

fn testPlan(
    allocator: std.mem.Allocator,
    registry: []const pass_manager.Pass,
) !pass_manager.Plan {
    return pass_manager.buildPlan(
        allocator,
        registry,
        &.{id},
        .{ .allow_lossless_cleanup = true },
    );
}

test "empty cleanup recursively removes only proven empty rules in source order" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "empty-cleanup.css",
        ".first{x:1}.drop{}/*between*/.outer{.nested{}}" ++
            "@media all{.gone{}}@supports (display:grid){.gone{}}" ++
            "@container card (width>1px){.gone{}}@starting-style{.gone{}}" ++
            "@layer named{}@scope (.root){.gone{}}@keyframes pulse{}" ++
            "@font-face{}@page{}@unknown foo{a/**/b}.last{y:2}",
    );
    defer parsed.deinit();
    const original = parsed.rules;
    const registry = [_]pass_manager.Pass{definition()};
    var plan = try testPlan(std.testing.allocator, &registry);
    defer plan.deinit();

    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules != original);
    try std.testing.expectEqual(@as(usize, 6), parsed.rules.omitted_rules.len);

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".first{x:1}@layer named{}@scope (.root){}@keyframes pulse{}" ++
            "@font-face{}@page{}@unknown foo{a/**/b}.last{y:2}",
        result.css,
    );
    try std.testing.expect(result.css.len < parsed.file().bytes.len);

    const once = parsed.rules;
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == once);
}

test "empty cleanup preserves declaration fallbacks token comments and semantic empty at-rules" {
    const css = ".a{--joined:a/**/b;color:red;color:blue!important}" ++
        "@layer named{}@scope (.root){}@keyframes pulse{}" ++
        "@font-face{}@page{}@document url-prefix(){}@unknown foo{a/**/b}";
    var parsed = try pipeline.parse(std.testing.allocator, "no-op.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var run_context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        failing.allocator(),
    );
    try std.testing.expect((try run(null, &run_context, original)) == original);
    try std.testing.expect(!failing.has_induced_failure);

    const registry = [_]pass_manager.Pass{definition()};
    var plan = try testPlan(std.testing.allocator, &registry);
    defer plan.deinit();

    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == original);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(css, result.css);
}

test "empty cleanup retains nested declaration runs and removes their empty siblings" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "nested-declarations.css",
        ".host{@media all{display:grid;.drop{}gap:1rem}.drop{}}",
    );
    defer parsed.deinit();
    const registry = [_]pass_manager.Pass{definition()};
    var plan = try testPlan(std.testing.allocator, &registry);
    defer plan.deinit();

    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".host{@media all{display:grid;gap:1rem}}",
        result.css,
    );
}

test "empty cleanup source maps reference only surviving source positions" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "mapped-cleanup.css",
        ".drop{}\n.keep{x:1}",
    );
    defer parsed.deinit();
    const registry = [_]pass_manager.Pass{definition()};
    var plan = try testPlan(std.testing.allocator, &registry);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{
        .mode = .minified,
        .source_map = .{ .generated_file = "mapped-cleanup.out.css" },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(".keep{x:1}", result.css);
    var json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.source_map.?,
        .{},
    );
    defer json.deinit();
    const encoded = json.value.object.get("mappings").?.string;
    const mappings = try sourcemap.decodeMappings(std.testing.allocator, encoded);
    defer if (mappings.len > 0) std.testing.allocator.free(mappings);
    try std.testing.expect(mappings.len > 0);
    for (mappings) |mapping| try std.testing.expectEqual(@as(u32, 1), mapping.original_line);
}

test "empty cleanup omission proof rejects a nonempty rule" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "invalid-candidate.css",
        ".keep{x:1}.drop{}",
    );
    defer parsed.deinit();
    const omissions = [_]ast.Rule{
        parsed.rules.rules[0],
        parsed.rules.rules[1],
    };
    try std.testing.expectError(
        error.InvalidRule,
        ast.RuleList.initWithOmissions(parsed.rules.span, &.{}, &omissions),
    );
}

test "empty cleanup can safely emit an entirely omitted stylesheet" {
    var parsed = try pipeline.parse(std.testing.allocator, "all-empty.css", ".only{}/*trivia*/");
    defer parsed.deinit();
    const registry = [_]pass_manager.Pass{definition()};
    var plan = try testPlan(std.testing.allocator, &registry);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    try std.testing.expectEqual(@as(usize, 0), parsed.rules.rules.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.rules.omitted_rules.len);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .pretty });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.css.len);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "empty-cleanup-oom.css",
        ".drop{}.keep{--x:a/**/b;color:red;color:blue!important;.nested{}}" ++
            "@media all{.drop{}}@scope (.root){.drop{}}@layer named{}",
    );
    defer parsed.deinit();
    const registry = [_]pass_manager.Pass{definition()};
    var plan = try testPlan(allocator, &registry);
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".keep{--x:a/**/b;color:red;color:blue!important}@scope (.root){}@layer named{}",
        result.css,
    );
}

test "empty cleanup handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
