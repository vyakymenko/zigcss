const std = @import("std");
const ast = @import("../css/ast.zig");
const emitter = @import("../css/emitter.zig");
const shorthand = @import("../css/shorthand.zig");
const duplicate_declarations = @import("duplicate_declarations.zig");
const pass_manager = @import("pass_manager.zig");
const value_rewrite = @import("value_rewrite.zig");

pub const id = "margin-shorthand-synthesis";

const dependencies = [_][]const u8{duplicate_declarations.id};

pub fn definition() pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .declarations,
            .safety = .semantic_rewrite,
            .maturity = .verified,
            .dependencies = &dependencies,
            .precondition = "duplicate-declaration analysis has run and the source-matched AST is valid, diagnostic-free, and emittable",
            .postcondition = "only adjacent canonical margin physical longhands with identical importance and one exact safe value are annotated for one-value margin emission; authored declarations remain available as proof",
            .no_op_conditions = "mixed values, importance, ordering, grammar, spelling, functions, substitutions, CSS-wide keywords, generated inputs, page and page-margin descriptor contexts, other descriptors, and unsupported values retain the exact input root",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "one shorthand expands in place to the same four adjacent physical longhands; no declaration, rule, fallback, layer, or logical-property boundary is crossed",
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
    return (try value_rewrite.rewriteDeclarations(context, input, generate, null, .{})).value;
}

fn generate(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    declaration_context: value_rewrite.DeclarationContext,
    declarations: ast.DeclarationList,
) pass_manager.Error!?[]const ast.GeneratedDeclaration {
    if (user_data != null) return error.PassFailed;
    // Page margin at-rules can occur between PageRule declarations, and margin
    // at-rule bodies are descriptor contexts whose shorthand equivalence is
    // not established by the current independent oracle.
    if (declaration_context == .page or declaration_context == .page_margin or
        declarations.declarations.len < 4)
    {
        return null;
    }

    const scratch = context.scratchAllocator();
    var candidates = try std.ArrayList(ast.GeneratedDeclaration).initCapacity(scratch, 0);
    defer candidates.deinit(scratch);
    var index: usize = 0;
    while (index + 4 <= declarations.declarations.len) {
        const proof = shorthand.analyzeMargin(
            scratch,
            context.file(),
            declarations.declarations[index .. index + 4],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst, error.InvalidSpan, error.SourceMismatch => return error.InvalidAst,
        };
        if (proof) |value| {
            try candidates.append(scratch, .{
                .kind = .margin,
                .first_declaration = index,
                .source_span = value.source_span,
            });
            index += 4;
        } else {
            index += 1;
        }
    }
    if (candidates.items.len == 0) return null;
    const owned = try context.arenaAllocator().dupe(ast.GeneratedDeclaration, candidates.items);
    return @as([]const ast.GeneratedDeclaration, owned);
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
    const expected = try value_rewrite.rewriteDeclarations(context, before, generate, null, .{});
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
const test_registry = [_]pass_manager.Pass{
    duplicate_declarations.definition(),
    definition(),
};

fn testPlan(allocator: std.mem.Allocator) !pass_manager.Plan {
    return pass_manager.buildPlan(
        allocator,
        &test_registry,
        &.{id},
        .{ .allow_semantic_rewrite = true },
    );
}

fn rejectValueGeneration(
    _: ?*anyopaque,
    _: *pass_manager.Context,
    _: ast.Declaration,
) pass_manager.Error!?ast.GeneratedValue {
    return error.PassFailed;
}

test "margin shorthand synthesis preserves fallbacks logical boundaries and importance" {
    const css = ".a{" ++
        "margin-top:2vh;" ++
        "margin-inline-start:9px;" ++
        "margin-top:1px;margin-right:1px;margin-bottom:1px;margin-left:1px;" ++
        "margin-inline-end:8px;" ++
        "margin-top:a\\75to!important;margin-right:a\\75to!important;" ++
        "margin-bottom:a\\75to!important;margin-left:a\\75to!important}";
    var parsed = try pipeline.parse(std.testing.allocator, "margin-synthesis.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.orderedPasses().len);
    try std.testing.expectEqualStrings(
        duplicate_declarations.id,
        plan.orderedPasses()[0].metadata.id,
    );
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules != original);

    const transformed = parsed.rules.rules[0].style_rule.block.declarations;
    try std.testing.expectEqual(@as(usize, 11), transformed.declarations.len);
    try std.testing.expectEqual(@as(usize, 2), transformed.generated_declarations.len);
    var boundary_context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    const protected = try value_rewrite.rewrite(
        &boundary_context,
        parsed.rules,
        rejectValueGeneration,
        null,
        .{},
    );
    try std.testing.expect(!protected.changed);
    try std.testing.expect(protected.value == parsed.rules);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{margin-top:2vh;margin-inline-start:9px;margin:1px;" ++
            "margin-inline-end:8px;margin:a\\75to!important}",
        result.css,
    );
    try std.testing.expect(result.css.len < css.len);

    var report = try duplicate_declarations.analyze(
        std.testing.allocator,
        parsed.rules,
        .{},
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.groups.len);

    var reparsed = try pipeline.parse(std.testing.allocator, "margin-synthesis-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        parsed.rules,
        reparsed.file(),
        reparsed.rules,
    ));
}

test "margin shorthand synthesis anchors one generated mapping and retains siblings" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "mapped-margin-pass.css",
        ".a{x:0;margin-top:1rem;margin-right:1rem;margin-bottom:1rem;margin-left:1rem;y:2}",
    );
    defer parsed.deinit();
    const declarations = parsed.rules.rules[0].style_rule.block.declarations.declarations;
    const causal_start = declarations[1].span.start;
    const sibling_start = declarations[5].span.start;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{
        .mode = .minified,
        .source_map = .{ .generated_file = "mapped-margin-pass.out.css" },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{x:0;margin:1rem;y:2}", result.css);
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
    const generated_start: u32 = @intCast(std.mem.indexOf(u8, result.css, "margin").?);
    const generated_sibling: u32 = @intCast(std.mem.indexOf(u8, result.css, "y:2").?);
    var found_generated = false;
    var found_sibling = false;
    for (mappings) |mapping| {
        if (mapping.generated_line == 0 and mapping.generated_column == generated_start and
            mapping.original_line == 0 and mapping.original_column == causal_start)
        {
            found_generated = true;
        }
        if (mapping.generated_line == 0 and mapping.generated_column == generated_sibling and
            mapping.original_line == 0 and mapping.original_column == sibling_start)
        {
            found_sibling = true;
        }
        try std.testing.expect(mapping.generated_column <= generated_start or
            mapping.generated_column >= generated_sibling);
    }
    try std.testing.expect(found_generated);
    try std.testing.expect(found_sibling);
}

test "margin shorthand synthesis declines unsafe or incomplete groups with an exact no-op" {
    const css = ".a{" ++
        "margin-right:1px;margin-top:1px;margin-bottom:1px;margin-left:1px;" ++
        "margin-top:1px;margin-right:2px;margin-bottom:1px;margin-left:1px;" ++
        "margin-top:calc(1px);margin-right:calc(1px);margin-bottom:calc(1px);margin-left:calc(1px);" ++
        "margin-top:inherit;margin-right:inherit;margin-bottom:inherit;margin-left:inherit;" ++
        "margin-top:1px!important;margin-right:1px;margin-bottom:1px;margin-left:1px}";
    var parsed = try pipeline.parse(std.testing.allocator, "margin-no-op.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == original);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(css, result.css);
}

test "margin shorthand synthesis traverses nested layers and keyframes but skips descriptors" {
    const group = "margin-top:0;margin-right:0;margin-bottom:0;margin-left:0";
    const css = try std.fmt.allocPrint(
        std.testing.allocator,
        "@layer theme{{.host{{{s};.child{{{s}}}}}}}" ++
            "@media all{{.wide{{{s}}}}}" ++
            "@keyframes move{{to{{{s}}}}}" ++
            "@page{{{s};@top-left{{{s}}}}}" ++
            "@font-face{{{s}}}",
        .{ group, group, group, group, group, group, group },
    );
    defer std.testing.allocator.free(css);
    var parsed = try pipeline.parse(std.testing.allocator, "nested-margin.css", css);
    defer parsed.deinit();
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@layer theme{.host{margin:0;.child{margin:0}}}" ++
            "@media all{.wide{margin:0}}" ++
            "@keyframes move{to{margin:0}}" ++
            "@page{" ++ group ++ ";@top-left{" ++ group ++ "}}" ++
            "@font-face{" ++ group ++ "}",
        result.css,
    );
}

test "margin shorthand synthesis validator rejects incomplete proof output and default policy" {
    try std.testing.expectError(
        error.DisallowedSafetyClass,
        pass_manager.buildPlan(std.testing.allocator, &test_registry, &.{id}, .{}),
    );

    const group = "margin-top:1px;margin-right:1px;margin-bottom:1px;margin-left:1px";
    const css = try std.fmt.allocPrint(std.testing.allocator, ".a{{{s};{s}}}", .{ group, group });
    defer std.testing.allocator.free(css);
    var parsed = try pipeline.parse(std.testing.allocator, "forged-margin-pass.css", css);
    defer parsed.deinit();
    var run_context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    const original = parsed.rules;
    const old_style = original.rules[0].style_rule;
    const old_list = old_style.block.declarations;
    const first_only = [_]ast.GeneratedDeclaration{.{
        .kind = .margin,
        .first_declaration = 0,
        .source_span = .{
            .source = parsed.source_id,
            .start = old_list.declarations[0].span.start,
            .end = old_list.declarations[3].span.end,
        },
    }};
    const arena = parsed.compilation.arenaAllocator();
    const style = try arena.create(ast.StyleRule);
    style.* = try ast.StyleRule.init(.{
        .selectors = old_style.selectors,
        .block = try ast.StyleBlock.init(
            old_style.block.envelope,
            try ast.DeclarationList.initWithGenerated(
                old_list.span,
                old_list.declarations,
                &first_only,
            ),
            old_style.block.rules,
        ),
        .span = old_style.span,
    });
    const rules = try arena.dupe(ast.Rule, original.rules);
    rules[0] = .{ .style_rule = style };
    const forged = try arena.create(ast.RuleList);
    forged.* = try ast.RuleList.initWithOmissions(original.span, rules, original.omitted_rules);
    try std.testing.expectError(
        error.ValidationFailed,
        validate(null, .postcondition, &run_context, original, forged),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const group = "margin-top:a\\75to;margin-right:a\\75to;margin-bottom:a\\75to;margin-left:a\\75to";
    const css = try std.fmt.allocPrint(
        allocator,
        ".a{{{s};.nested{{{s}}}}}@keyframes f{{to{{{s}}}}}",
        .{ group, group, group },
    );
    defer allocator.free(css);
    var parsed = try pipeline.parse(allocator, "margin-pass-oom.css", css);
    defer parsed.deinit();
    var plan = try testPlan(allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{margin:a\\75to;.nested{margin:a\\75to}}@keyframes f{to{margin:a\\75to}}",
        result.css,
    );
}

test "margin shorthand synthesis handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "margin shorthand synthesis enforces traversal declaration budgets" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "margin-pass-budget.css",
        ".a{margin-top:0;margin-right:0;margin-bottom:0;margin-left:0}",
    );
    defer parsed.deinit();
    var context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    try std.testing.expectError(
        error.PassFailed,
        value_rewrite.rewriteDeclarations(
            &context,
            parsed.rules,
            generate,
            null,
            .{ .max_declarations = 3 },
        ),
    );
}
