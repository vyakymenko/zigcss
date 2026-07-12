const std = @import("std");
const ast = @import("../css/ast.zig");
const emitter = @import("../css/emitter.zig");
const rule_merge = @import("../css/rule_merge.zig");
const empty_cleanup = @import("empty_cleanup.zig");
const pass_manager = @import("pass_manager.zig");
const rule_rewrite = @import("rule_rewrite.zig");

pub const id = "adjacent-at-rule-merge";

pub fn definition() pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .rules,
            .safety = .semantic_rewrite,
            .maturity = .verified,
            .precondition = "the source-matched AST is valid, diagnostic-free, emittable, and carries no pre-existing generated-rule proof at an inspected list",
            .postcondition = "only authored-adjacent typed media, supports, container, or named-layer rule blocks with equivalent preludes and matching nesting mode are annotated for ordered child-list composition",
            .no_op_conditions = "non-at-rule, non-adjacent, omitted, empty, recovered, untyped, anonymous-layer, direct-nested-declaration, different-kind, different-prelude, different-nesting, non-rule-block, or already-generated inputs retain the exact logical rule sequence",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "each proof replaces exactly two adjacent identical group contexts in place, concatenates their child streams without reordering, retains the first named-layer occurrence, and never crosses a rule-list, omission, recovery, or parent nesting boundary",
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

fn run(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    if (user_data != null) return error.PassFailed;
    return (try rule_rewrite.rewrite(context, input, generate, null, .{})).value;
}

fn generate(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    _: rule_rewrite.RuleContext,
    rules: ast.RuleList,
) pass_manager.Error!?[]const ast.GeneratedRule {
    if (user_data != null) return error.PassFailed;
    if (rules.rules.len < 2 or rules.omitted_rules.len != 0 or rules.generated_rules.len != 0) {
        return null;
    }

    const scratch = context.scratchAllocator();
    var candidates = try std.ArrayList(ast.GeneratedRule).initCapacity(scratch, 0);
    defer candidates.deinit(scratch);
    var index: usize = 0;
    while (index + 1 < rules.rules.len) {
        const proof = rule_merge.analyzeAtRuleMerge(
            scratch,
            context.file(),
            rules.rules[index .. index + 2],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst, error.InvalidSpan, error.InvalidToken, error.SourceMismatch => return error.InvalidAst,
        };
        if (proof) |value| {
            try candidates.append(scratch, .{
                .kind = .group_at_rule_merge,
                .first_rule = index,
                .source_span = value.source_span,
            });
            index += 2;
        } else {
            index += 1;
        }
    }
    if (candidates.items.len == 0) return null;
    const owned = try context.arenaAllocator().dupe(ast.GeneratedRule, candidates.items);
    return @as([]const ast.GeneratedRule, owned);
}

fn validate(
    user_data: ?*anyopaque,
    phase: pass_manager.ValidationPhase,
    context: *pass_manager.Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) pass_manager.Error!void {
    if (user_data != null) return error.ValidationFailed;
    if (!before.span.source.eql(context.source_id) or !after.span.source.eql(context.source_id)) {
        return error.ValidationFailed;
    }
    before.validate() catch return error.ValidationFailed;
    after.validate() catch return error.ValidationFailed;
    switch (phase) {
        .precondition => {
            if (before != after) return error.ValidationFailed;
            try validateEmittable(context, before);
        },
        .postcondition => try validatePostcondition(context, before, after),
        .idempotence => {
            if (before != after) return error.ValidationFailed;
            try validateEmittable(context, before);
        },
    }
}

fn validatePostcondition(
    context: *pass_manager.Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) pass_manager.Error!void {
    if (!sameSpan(before.span, after.span) or before.rules.len != after.rules.len or
        before.omitted_rules.len != after.omitted_rules.len)
    {
        return error.ValidationFailed;
    }
    const expected = try rule_rewrite.rewrite(context, before, generate, null, .{});
    if (expected.changed != (before != after)) return error.ValidationFailed;
    try validateSameEmission(context, expected.value, after);
}

fn validateEmittable(
    context: *pass_manager.Context,
    rules: *const ast.RuleList,
) pass_manager.Error!void {
    var output = emitter.emitWithSourceMap(
        context.scratchAllocator(),
        context.file(),
        rules,
        .{ .mode = .minified },
        .{ .include_sources_content = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ValidationFailed,
    };
    output.deinit();
}

fn validateSameEmission(
    context: *pass_manager.Context,
    expected: *const ast.RuleList,
    actual: *const ast.RuleList,
) pass_manager.Error!void {
    var expected_output = emitter.emitWithSourceMap(
        context.scratchAllocator(),
        context.file(),
        expected,
        .{ .mode = .minified },
        .{ .include_sources_content = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ValidationFailed,
    };
    defer expected_output.deinit();
    var actual_output = emitter.emitWithSourceMap(
        context.scratchAllocator(),
        context.file(),
        actual,
        .{ .mode = .minified },
        .{ .include_sources_content = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ValidationFailed,
    };
    defer actual_output.deinit();
    if (!std.mem.eql(u8, expected_output.css, actual_output.css) or
        !std.mem.eql(u8, expected_output.source_map, actual_output.source_map))
    {
        return error.ValidationFailed;
    }
}

fn sameSpan(left: @import("../source.zig").Span, right: @import("../source.zig").Span) bool {
    return left.source.eql(right.source) and left.start == right.start and left.end == right.end;
}

const pipeline = @import("../css/pipeline.zig");
const equivalence = @import("../css/equivalence.zig");
const sourcemap = @import("../sourcemap.zig");
const test_registry = [_]pass_manager.Pass{definition()};

fn testPlan(allocator: std.mem.Allocator) !pass_manager.Plan {
    return pass_manager.buildPlan(
        allocator,
        &test_registry,
        &.{id},
        .{ .allow_semantic_rewrite = true },
    );
}

test "at-rule merge preserves group child and sibling order" {
    const css = "@media screen{.a{x:1}}@media  screen{.b{y:2}}" ++
        ".keep{z:3}" ++
        "@supports (display:grid){.c{x:4}}@supports (display:grid){.d{y:5}}" ++
        "@container card (width>1px){.e{x:6}}@container card (width>1px){.f{y:7}}" ++
        "@layer theme{.g{x:8}}@layer theme{.h{y:9}}";
    var parsed = try pipeline.parse(std.testing.allocator, "at-rule-merge.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules != original);
    try std.testing.expectEqual(@as(usize, 9), parsed.rules.rules.len);
    try std.testing.expectEqual(@as(usize, 4), parsed.rules.generated_rules.len);

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@media screen{.a{x:1}.b{y:2}}.keep{z:3}" ++
            "@supports (display:grid){.c{x:4}.d{y:5}}" ++
            "@container card (width>1px){.e{x:6}.f{y:7}}" ++
            "@layer theme{.g{x:8}.h{y:9}}",
        result.css,
    );
    try std.testing.expect(result.css.len < css.len);
    var reparsed = try pipeline.parse(std.testing.allocator, "at-rule-merge-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        parsed.rules,
        reparsed.file(),
        reparsed.rules,
    ));
}

test "at-rule merge returns the exact root for unsafe groups" {
    const css = "@media screen{.a{x:1}}@media print{.b{x:1}}" ++
        "@layer{.c{x:1}}@layer{.d{x:1}}" ++
        "@layer first{.e{x:1}}@layer second{.f{x:1}}" ++
        "@supports (display:grid){}@supports (display:grid){.g{x:1}}" ++
        "@scope (.root){.h{x:1}}@scope (.root){.i{x:1}}";
    var parsed = try pipeline.parse(std.testing.allocator, "at-rule-merge-no-op.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == original);
}

test "at-rule merge traverses named layers and declines direct nested declaration streams" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "nested-at-rule-merge.css",
        ".host{@media all{color:red}@media all{color:blue;.child{x:1}}}" ++
            "@layer outer{@supports (display:grid){.a{x:1}}" ++
            "@supports (display:grid){.b{y:2}}}",
    );
    defer parsed.deinit();
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".host{@media all{color:red}@media all{color:blue;.child{x:1}}}" ++
            "@layer outer{@supports (display:grid){.a{x:1}.b{y:2}}}",
        result.css,
    );
}

test "at-rule merge composes independently proven nested group merges" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "composed-at-rule-merge.css",
        "@layer outer{@supports (display:grid){.a{x:1}}" ++
            "@supports (display:grid){.b{y:2}}}" ++
            "@layer outer{@supports (display:flex){.c{x:3}}" ++
            "@supports (display:flex){.d{y:4}}}",
    );
    defer parsed.deinit();
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    try std.testing.expectEqual(@as(usize, 1), parsed.rules.generated_rules.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        parsed.rules.rules[0].at_rule.block.rules.rules.generated_rules.len,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        parsed.rules.rules[1].at_rule.block.rules.rules.generated_rules.len,
    );

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@layer outer{@supports (display:grid){.a{x:1}.b{y:2}}" ++
            "@supports (display:flex){.c{x:3}.d{y:4}}}",
        result.css,
    );
    var reparsed = try pipeline.parse(
        std.testing.allocator,
        "composed-at-rule-merge-output.css",
        result.css,
    );
    defer reparsed.deinit();
    try std.testing.expect(try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        parsed.rules,
        reparsed.file(),
        reparsed.rules,
    ));
}

test "at-rule merge source maps retain both child streams and omit the second header" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "mapped-at-rule-merge.css",
        "@media screen{.a{x:1}}@media screen{.b{y:2}}.keep{z:3}",
    );
    defer parsed.deinit();
    const first = parsed.rules.rules[0].at_rule;
    const second = parsed.rules.rules[1].at_rule;
    const first_child = first.block.rules.rules.rules[0].style_rule;
    const second_child = second.block.rules.rules.rules[0].style_rule;
    const sibling = parsed.rules.rules[2].style_rule;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    const modes = [_]emitter.Mode{ .pretty, .minified };
    for (modes) |mode| {
        var result = try parsed.emitResult(std.testing.allocator, .{
            .mode = mode,
            .source_map = .{ .generated_file = "mapped-at-rule-merge.out.css" },
        });
        defer result.deinit();
        var repeated = try parsed.emitResult(std.testing.allocator, .{
            .mode = mode,
            .source_map = .{ .generated_file = "mapped-at-rule-merge.out.css" },
        });
        defer repeated.deinit();
        try std.testing.expectEqualStrings(result.css, repeated.css);
        try std.testing.expectEqualStrings(result.source_map.?, repeated.source_map.?);
        var json = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            result.source_map.?,
            .{},
        );
        defer json.deinit();
        const mappings = try sourcemap.decodeMappings(
            std.testing.allocator,
            json.value.object.get("mappings").?.string,
        );
        defer std.testing.allocator.free(mappings);
        const group_output = asciiGeneratedPosition(result.css, "@media").?;
        const first_child_output = asciiGeneratedPosition(result.css, ".a").?;
        const second_child_output = asciiGeneratedPosition(result.css, ".b").?;
        const sibling_output = asciiGeneratedPosition(result.css, ".keep").?;
        var found_group = false;
        var found_first_child = false;
        var found_second_child = false;
        var found_sibling = false;
        for (mappings) |mapping| {
            if (sameGeneratedPosition(mapping, group_output) and
                mapping.original_column == first.span.start)
            {
                found_group = true;
            }
            if (sameGeneratedPosition(mapping, first_child_output) and
                mapping.original_column == first_child.selectors.selectors[0].span.start)
            {
                found_first_child = true;
            }
            if (sameGeneratedPosition(mapping, second_child_output) and
                mapping.original_column == second_child.selectors.selectors[0].span.start)
            {
                found_second_child = true;
            }
            if (sameGeneratedPosition(mapping, sibling_output) and
                mapping.original_column == sibling.selectors.selectors[0].span.start)
            {
                found_sibling = true;
            }
            try std.testing.expect(mapping.original_column != second.span.start);
        }
        try std.testing.expect(found_group);
        try std.testing.expect(found_first_child);
        try std.testing.expect(found_second_child);
        try std.testing.expect(found_sibling);
    }
}

const GeneratedPosition = struct {
    line: u32,
    column: u32,
};

fn asciiGeneratedPosition(css: []const u8, needle: []const u8) ?GeneratedPosition {
    const offset = std.mem.indexOf(u8, css, needle) orelse return null;
    var position = GeneratedPosition{ .line = 0, .column = 0 };
    for (css[0..offset]) |byte| {
        if (byte == '\n') {
            position.line += 1;
            position.column = 0;
        } else {
            position.column += 1;
        }
    }
    return position;
}

fn sameGeneratedPosition(mapping: sourcemap.Mapping, position: GeneratedPosition) bool {
    return mapping.generated_line == position.line and mapping.generated_column == position.column;
}

test "at-rule merge preserves an omission inside a merged group" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "at-rule-inner-omission.css",
        "@media all{.empty{}.a{x:1}}@media all{.b{y:2}}",
    );
    defer parsed.deinit();
    const registry = [_]pass_manager.Pass{ empty_cleanup.definition(), definition() };
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{ empty_cleanup.id, id },
        .{ .allow_lossless_cleanup = true, .allow_semantic_rewrite = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.rules.generated_rules.len);
    const first = parsed.rules.rules[0].at_rule.block.rules;
    try std.testing.expectEqual(@as(usize, 1), first.rules.omitted_rules.len);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings("@media all{.a{x:1}.b{y:2}}", result.css);
}

test "at-rule merge does not cross a cleanup omission" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "at-rule-parent-omission.css",
        "@media all{.a{x:1}}.empty{}@media all{.b{y:2}}",
    );
    defer parsed.deinit();
    const registry = [_]pass_manager.Pass{ empty_cleanup.definition(), definition() };
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{ empty_cleanup.id, id },
        .{ .allow_lossless_cleanup = true, .allow_semantic_rewrite = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.rules.omitted_rules.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.rules.generated_rules.len);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@media all{.a{x:1}}@media all{.b{y:2}}",
        result.css,
    );
}

test "at-rule merge validator rejects incomplete output and default policy" {
    try std.testing.expectError(
        error.DisallowedSafetyClass,
        pass_manager.buildPlan(std.testing.allocator, &test_registry, &.{id}, .{}),
    );
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "forged-at-rule-pass.css",
        "@media all{.a{x:1}}@media all{.b{y:2}}" ++
            "@layer theme{.c{x:3}}@layer theme{.d{y:4}}",
    );
    defer parsed.deinit();
    var context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    const original = parsed.rules;
    const first_only = [_]ast.GeneratedRule{.{
        .kind = .group_at_rule_merge,
        .first_rule = 0,
        .source_span = .{
            .source = parsed.source_id,
            .start = original.rules[0].span().start,
            .end = original.rules[1].span().end,
        },
    }};
    const forged = try ast.RuleList.initWithGeneratedRules(
        original.span,
        original.rules,
        original.omitted_rules,
        &first_only,
    );
    try std.testing.expectError(
        error.ValidationFailed,
        validate(null, .postcondition, &context, original, &forged),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "at-rule-merge-oom.css",
        "@media screen{.a{x:1}}@media screen{.b{y:2}}" ++
            "@supports (display:grid){.c{x:3}}@supports (display:grid){.d{y:4}}" ++
            ".host{@container card (width>1px){.first{color:red}}" ++
            "@container card (width>1px){.second{color:blue}}}",
    );
    defer parsed.deinit();
    var plan = try testPlan(allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@media screen{.a{x:1}.b{y:2}}" ++
            "@supports (display:grid){.c{x:3}.d{y:4}}" ++
            ".host{@container card (width>1px){.first{color:red}.second{color:blue}}}",
        result.css,
    );
}

test "at-rule merge handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "at-rule merge enforces traversal rule budgets" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "at-rule-merge-budget.css",
        "@media all{.a{x:1}}@media all{.b{y:2}}",
    );
    defer parsed.deinit();
    var context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    try std.testing.expectError(
        error.PassFailed,
        rule_rewrite.rewrite(
            &context,
            parsed.rules,
            generate,
            null,
            .{ .max_rules = 1 },
        ),
    );
}
