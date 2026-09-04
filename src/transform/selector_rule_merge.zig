const std = @import("std");
const ast = @import("../css/ast.zig");
const emitter = @import("../css/emitter.zig");
const rule_merge = @import("../css/rule_merge.zig");
const empty_cleanup = @import("empty_cleanup.zig");
const pass_manager = @import("pass_manager.zig");
const rule_rewrite = @import("rule_rewrite.zig");

pub const id = "adjacent-selector-rule-merge";

pub fn definition() pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .rules,
            .safety = .semantic_rewrite,
            .maturity = .verified,
            .precondition = "the source-matched AST is valid, diagnostic-free, emittable, and carries no pre-existing generated-rule proof at an inspected list",
            .postcondition = "only pairs of authored-adjacent style rules with nonempty structurally equivalent declaration-only blocks are annotated for ordered selector-list merge emission",
            .no_op_conditions = "non-style, non-adjacent, omitted, empty, nested-content, recovered, semantically different, generated-value, generated-declaration, or already-generated rule inputs retain the exact logical rule sequence",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "each proof replaces exactly two adjacent rules in place, retains selector order, reuses the first identical declaration block, and never crosses a rule-list, layer, query, nesting, omission, or recovery boundary",
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
        const proof = rule_merge.analyzeSelectorMerge(
            scratch,
            context.file(),
            rules.rules[index .. index + 2],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst, error.InvalidSpan, error.InvalidToken, error.SourceMismatch => return error.InvalidAst,
        };
        if (proof) |value| {
            try candidates.append(scratch, .{
                .kind = .selector_list_merge,
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
    if (context.hasExactMinifiedMappedEmissionProof(rules)) return;
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
    context.commitExactMinifiedMappedEmissionProof(rules, 1);
}

fn validateSameEmission(
    context: *pass_manager.Context,
    expected: *const ast.RuleList,
    actual: *const ast.RuleList,
) pass_manager.Error!void {
    if (expected == actual) return validateEmittable(context, actual);
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
    context.commitExactMinifiedMappedEmissionProof(actual, 2);
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

test "selector rule merge preserves selector declaration and sibling order" {
    const css = ".a{x:1;color:red!important}.b,.c{x:1;color:red!important}" ++
        ".keep{z:0}.d{--x:a/**/b}.e{--x:a/**/b}";
    var parsed = try pipeline.parse(std.testing.allocator, "selector-rule-merge.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules != original);
    try std.testing.expectEqual(@as(usize, 5), parsed.rules.rules.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.rules.generated_rules.len);

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a,.b,.c{x:1;color:red!important}.keep{z:0}.d,.e{--x:a/**/b}",
        result.css,
    );
    try std.testing.expect(result.css.len < css.len);
    var reparsed = try pipeline.parse(std.testing.allocator, "selector-rule-merge-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        parsed.rules,
        reparsed.file(),
        reparsed.rules,
    ));
}

test "selector rule merge returns the exact root for unsafe and non-equivalent pairs" {
    const css = ".a{x:1}.b{x:2}.c{--x:a/**/b}.d{--x:ab}.empty{}.also-empty{}" ++
        ".nested{x:1;.child{y:2}}.other{x:1;.child{y:2}}" ++
        ".last{x:1}@media all{.inside{x:1}}";
    var parsed = try pipeline.parse(std.testing.allocator, "selector-rule-no-op.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == original);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{x:1}.b{x:2}.c{--x:a/**/b}.d{--x:ab}.empty{}.also-empty{}" ++
            ".nested{x:1;.child{y:2}}.other{x:1;.child{y:2}}" ++
            ".last{x:1}@media all{.inside{x:1}}",
        result.css,
    );
}

test "selector rule merge traverses layers media and native nesting boundaries" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "nested-selector-rule-merge.css",
        "@layer theme{.a{x:1}.b{x:1}}" ++
            "@media all{.c{y:2}.d{y:2}}" ++
            ".host{.first{z:3}.second{z:3}}",
    );
    defer parsed.deinit();
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@layer theme{.a,.b{x:1}}@media all{.c,.d{y:2}}.host{.first,.second{z:3}}",
        result.css,
    );
}

test "selector rule merge source maps retain both selectors and skip duplicate declarations" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "mapped-selector-rule-merge.css",
        ".a{x:1}.b{x:1}.keep{y:2}",
    );
    defer parsed.deinit();
    const first = parsed.rules.rules[0].style_rule;
    const second = parsed.rules.rules[1].style_rule;
    const sibling = parsed.rules.rules[2].style_rule;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    const modes = [_]emitter.Mode{ .pretty, .minified };
    for (modes) |mode| {
        var result = try parsed.emitResult(std.testing.allocator, .{
            .mode = mode,
            .source_map = .{ .generated_file = "mapped-selector-rule-merge.out.css" },
        });
        defer result.deinit();
        var repeated = try parsed.emitResult(std.testing.allocator, .{
            .mode = mode,
            .source_map = .{ .generated_file = "mapped-selector-rule-merge.out.css" },
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
        const first_output = asciiGeneratedPosition(result.css, ".a").?;
        const separator_output = asciiGeneratedPosition(result.css, if (mode == .pretty) ", " else ",").?;
        const second_output = asciiGeneratedPosition(result.css, ".b").?;
        const declaration_output = asciiGeneratedPosition(result.css, if (mode == .pretty) "x: 1" else "x:1").?;
        const sibling_output = asciiGeneratedPosition(result.css, ".keep").?;
        var found_first = false;
        var found_second = false;
        var found_declaration = false;
        var found_sibling = false;
        for (mappings) |mapping| {
            if (sameGeneratedPosition(mapping, first_output) and
                mapping.original_column == first.selectors.selectors[0].span.start)
            {
                found_first = true;
            }
            if (sameGeneratedPosition(mapping, second_output) and
                mapping.original_column == second.selectors.selectors[0].span.start)
            {
                found_second = true;
            }
            if (sameGeneratedPosition(mapping, declaration_output) and
                mapping.original_column == first.block.declarations.declarations[0].span.start)
            {
                found_declaration = true;
            }
            if (sameGeneratedPosition(mapping, sibling_output) and
                mapping.original_column == sibling.selectors.selectors[0].span.start)
            {
                found_sibling = true;
            }
            try std.testing.expect(!sameGeneratedPosition(mapping, separator_output));
            try std.testing.expect(mapping.original_column !=
                second.block.declarations.declarations[0].span.start);
        }
        try std.testing.expect(found_first);
        try std.testing.expect(found_second);
        try std.testing.expect(found_declaration);
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

test "selector rule merge does not cross a cleanup omission" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "selector-rule-omission.css",
        ".a{x:1}.empty{}.b{x:1}",
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
    try std.testing.expectEqualStrings(".a{x:1}.b{x:1}", result.css);
}

test "selector rule merge validator rejects incomplete output and default policy" {
    try std.testing.expectError(
        error.DisallowedSafetyClass,
        pass_manager.buildPlan(std.testing.allocator, &test_registry, &.{id}, .{}),
    );
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "forged-selector-rule-pass.css",
        ".a{x:1}.b{x:1}.c{y:2}.d{y:2}",
    );
    defer parsed.deinit();
    var context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    const original = parsed.rules;
    const first_only = [_]ast.GeneratedRule{.{
        .kind = .selector_list_merge,
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
        "selector-rule-merge-oom.css",
        ".a{content:'x';color:red;width:1px}" ++
            ".b{content:\"x\";color:red;width:1px}" ++
            "@media all{.c{y:2}.d{y:2}}.host{.e{z:3}.f{z:3}}",
    );
    defer parsed.deinit();
    var plan = try testPlan(allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a,.b{content:'x';color:red;width:1px}" ++
            "@media all{.c,.d{y:2}}.host{.e,.f{z:3}}",
        result.css,
    );
}

test "selector rule merge handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "selector rule merge enforces traversal rule budgets" {
    var parsed = try pipeline.parse(std.testing.allocator, "selector-rule-budget.css", ".a{x:1}.b{x:1}");
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
