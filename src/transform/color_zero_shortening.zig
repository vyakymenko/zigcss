const std = @import("std");
const ast = @import("../css/ast.zig");
const color_value = @import("../css/color_value.zig");
const emitter = @import("../css/emitter.zig");
const numeric_value = @import("../css/numeric_value.zig");
const pass_manager = @import("pass_manager.zig");
const value_rewrite = @import("value_rewrite.zig");

pub const id = "typed-color-zero-shortening";

pub fn definition() pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .values,
            .safety = .semantic_rewrite,
            .maturity = .verified,
            .precondition = "the source-matched AST is valid, diagnostic-free, and generated values satisfy ADR-007",
            .postcondition = "only complete policy-matched exact sRGB colors and positive zero lengths are replaced by strictly shorter structured values; importance, declarations, rules, and order are preserved",
            .no_op_conditions = "custom properties, descriptors, contextual or wider colors, unsupported properties, comments, fractional or clamped channels, non-endpoint alpha, non-length and signed zeros, and non-shorter output retain the exact input root",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "the shared whole-value traversal reconstructs changed declaration paths in source order and never inserts, removes, sorts, or merges declarations or rules",
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
    return (try value_rewrite.rewrite(context, input, generate, null, .{})).value;
}

fn generate(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    declaration: ast.Declaration,
) pass_manager.Error!?ast.GeneratedValue {
    if (user_data != null) return error.PassFailed;
    if (declaration.generated_value != null or declaration.name.isCustomProperty()) return null;
    const values = declaration.valueWithoutImportance();
    const root = singleSignificantValue(values) orelse return null;

    if (isColorProperty(declaration.name.value)) {
        const parsed = color_value.parse(
            context.scratchAllocator(),
            context.file(),
            values,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourceMismatch, error.InvalidSpan => return error.InvalidAst,
            else => return null,
        } orelse return null;
        if (!sameSpan(parsed.span, root.span())) return null;
        // Generating alpha-hex from rgba()/transparent would silently raise
        // the target-browser requirement. Alpha hex may only shorten authored
        // alpha-hex until target-aware compatibility policy exists.
        if (parsed.color.alpha != 255 and parsed.syntax != .hex) return null;
        const generated = ast.GeneratedValue{ .color = .{
            .value = parsed.color,
            .source_span = parsed.span,
        } };
        return if (isStrictlyShorter(generated, parsed.span)) generated else null;
    }

    if (!isZeroLengthProperty(declaration.name.value)) return null;
    const token = switch (root) {
        .token => |value| value,
        else => return null,
    };
    if (token.kind != .dimension) return null;
    var expression = numeric_value.parse(
        context.scratchAllocator(),
        context.file(),
        values,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch, error.InvalidSpan => return error.InvalidAst,
        else => return null,
    };
    defer expression.deinit();
    if (!sameSpan(expression.span, root.span()) or expression.instructions.len != 1) return null;
    const literal = switch (expression.instructions[0]) {
        .literal => |value| value,
        else => return null,
    };
    if (literal.kind != .numeric or
        literal.value != 0 or
        std.math.signbit(literal.value) or
        literal.unit.baseDimension() != .length)
    {
        return null;
    }
    const generated = ast.GeneratedValue{ .numeric = .{
        .value = 0,
        .unit = .number,
        .source_span = expression.span,
    } };
    return if (isStrictlyShorter(generated, expression.span)) generated else null;
}

fn singleSignificantValue(values: []const @import("../syntax.zig").ComponentValue) ?@import("../syntax.zig").ComponentValue {
    var first: usize = 0;
    while (first < values.len and isWhitespace(values[first])) : (first += 1) {}
    var end = values.len;
    while (end > first and isWhitespace(values[end - 1])) : (end -= 1) {}
    if (end - first != 1 or containsComment(values[first])) return null;
    return values[first];
}

fn isWhitespace(value: @import("../syntax.zig").ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
}

fn containsComment(value: @import("../syntax.zig").ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .comment,
        .simple_block => |block| blk: {
            for (block.values) |child| if (containsComment(child)) break :blk true;
            break :blk false;
        },
        .function => |function| blk: {
            for (function.values) |child| if (containsComment(child)) break :blk true;
            break :blk false;
        },
    };
}

fn isStrictlyShorter(generated: ast.GeneratedValue, span: @import("../source.zig").Span) bool {
    var buffer: [ast.generated_value_buffer_size]u8 = undefined;
    const serialized = generated.serialize(&buffer) catch return false;
    return serialized.len < span.len();
}

fn isColorProperty(name: []const u8) bool {
    const properties = [_][]const u8{
        "color",
        "background-color",
        "border-color",
        "border-top-color",
        "border-right-color",
        "border-bottom-color",
        "border-left-color",
        "border-block-color",
        "border-block-start-color",
        "border-block-end-color",
        "border-inline-color",
        "border-inline-start-color",
        "border-inline-end-color",
        "outline-color",
        "text-decoration-color",
        "text-emphasis-color",
        "column-rule-color",
        "caret-color",
        "accent-color",
        "fill",
        "stroke",
        "flood-color",
        "lighting-color",
        "stop-color",
    };
    return matchesAny(name, &properties);
}

fn isZeroLengthProperty(name: []const u8) bool {
    const properties = [_][]const u8{
        "width",
        "height",
        "min-width",
        "min-height",
        "max-width",
        "max-height",
        "inline-size",
        "block-size",
        "min-inline-size",
        "min-block-size",
        "max-inline-size",
        "max-block-size",
        "top",
        "right",
        "bottom",
        "left",
        "inset",
        "inset-block",
        "inset-block-start",
        "inset-block-end",
        "inset-inline",
        "inset-inline-start",
        "inset-inline-end",
        "margin",
        "margin-top",
        "margin-right",
        "margin-bottom",
        "margin-left",
        "margin-block",
        "margin-block-start",
        "margin-block-end",
        "margin-inline",
        "margin-inline-start",
        "margin-inline-end",
        "padding",
        "padding-top",
        "padding-right",
        "padding-bottom",
        "padding-left",
        "padding-block",
        "padding-block-start",
        "padding-block-end",
        "padding-inline",
        "padding-inline-start",
        "padding-inline-end",
        "gap",
        "row-gap",
        "column-gap",
        "font-size",
        "border-width",
        "border-top-width",
        "border-right-width",
        "border-bottom-width",
        "border-left-width",
        "border-block-width",
        "border-block-start-width",
        "border-block-end-width",
        "border-inline-width",
        "border-inline-start-width",
        "border-inline-end-width",
        "border-radius",
        "border-top-left-radius",
        "border-top-right-radius",
        "border-bottom-right-radius",
        "border-bottom-left-radius",
        "border-start-start-radius",
        "border-start-end-radius",
        "border-end-start-radius",
        "border-end-end-radius",
        "outline-width",
        "outline-offset",
        "letter-spacing",
        "word-spacing",
        "text-indent",
    };
    return matchesAny(name, &properties);
}

fn matchesAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn sameSpan(left: @import("../source.zig").Span, right: @import("../source.zig").Span) bool {
    return left.source.eql(right.source) and left.start == right.start and left.end == right.end;
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
    const expected = try value_rewrite.rewrite(context, before, generate, null, .{});
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

test "color and zero shortening rewrites only shorter whole policy-matched values" {
    const css = ".a{" ++
        "color:#ff0000;background-color:rgb(255,0,0)!important;" ++
        "border-top-color:white;outline-color:currentColor;" ++
        "width:0px;margin-left:0em;rotate:0deg;opacity:0%;line-height:0px;" ++
        "--x:#ffffff;color:color(display-p3 1 0 0);color:rgba(0,0,0,.5);" ++
        "color:#12345678;color:#aabbcc;color:#aabbccdd;color:#000000ff}";
    var parsed = try pipeline.parse(std.testing.allocator, "shorten.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules != original);

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{color:red;background-color:red!important;border-top-color:#fff;" ++
            "outline-color:currentColor;width:0;margin-left:0;rotate:0deg;opacity:0%;" ++
            "line-height:0px;--x:#ffffff;color:color(display-p3 1 0 0);" ++
            "color:rgba(0,0,0,.5);color:#12345678;color:#abc;color:#abcd;color:#000}",
        result.css,
    );
    try std.testing.expect(result.css.len < css.len);

    var reparsed = try pipeline.parse(std.testing.allocator, "shorten-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        parsed.rules,
        reparsed.file(),
        reparsed.rules,
    ));
}

test "color and zero shortening traverses nested layers keyframes pages and skips descriptors" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "nested-shorten.css",
        "@layer theme{.host{color:#808080;padding-inline-start:0rem;" ++
            ".child{background-color:#ffffff}@media all{margin-block-end:0vh}}}" ++
            "@keyframes fade{from{color:#000080}to{width:0px}}" ++
            "@page{color:#800080;margin-left:0cm;@top-left{background-color:#ffffff}}" ++
            "@font-face{color:#ffffff}" ++
            "@property --c{syntax:\"<color>\";inherits:false;initial-value:#ffffff}",
    );
    defer parsed.deinit();
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@layer theme{.host{color:gray;padding-inline-start:0;.child{background-color:#fff}" ++
            "@media all{margin-block-end:0}}}" ++
            "@keyframes fade{from{color:navy}to{width:0}}" ++
            "@page{color:purple;margin-left:0;@top-left{background-color:#fff}}" ++
            "@font-face{color:#ffffff}" ++
            "@property --c{syntax:\"<color>\";inherits:false;initial-value:#ffffff}",
        result.css,
    );
}

test "color and zero shortening returns the exact root for conservative no-ops" {
    const css = ".a{color:red;color:#abc;color:currentColor;color:transparent;" ++
        "color:rgba(18,52,86,0);color:rgba(0,0,0,.5);" ++
        "color:hsl(0 100% 50%);foo:#ffffff;--x:#ffffff;width:-0px;" ++
        "rotate:0deg;animation-delay:0s;opacity:0%;line-height:0px}";
    var parsed = try pipeline.parse(std.testing.allocator, "shorten-no-op.css", css);
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

test "color and zero shortening source maps anchor each generated value and retain siblings" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "mapped-shorten.css",
        ".a{color:#ff0000;width:0px;height:4px}",
    );
    defer parsed.deinit();
    const declarations = parsed.rules.rules[0].style_rule.block.declarations.declarations;
    const color_span = declarations[0].valueWithoutImportance()[0].span();
    const zero_span = declarations[1].valueWithoutImportance()[0].span();
    const sibling = declarations[2];
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{
        .mode = .minified,
        .source_map = .{ .generated_file = "mapped-shorten.out.css" },
    });
    defer result.deinit();
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
    const generated_color: u32 = @intCast(std.mem.indexOf(u8, result.css, "red").?);
    const generated_zero: u32 = @intCast(std.mem.indexOf(u8, result.css, "0").?);
    const generated_sibling: u32 = @intCast(std.mem.indexOf(u8, result.css, "height").?);
    var found_color = false;
    var found_zero = false;
    var found_sibling = false;
    for (mappings) |mapping| {
        if (mapping.generated_line == 0 and mapping.generated_column == generated_color and
            mapping.original_line == 0 and mapping.original_column == color_span.start)
        {
            found_color = true;
        }
        if (mapping.generated_line == 0 and mapping.generated_column == generated_zero and
            mapping.original_line == 0 and mapping.original_column == zero_span.start)
        {
            found_zero = true;
        }
        if (mapping.generated_line == 0 and mapping.generated_column == generated_sibling and
            mapping.original_line == 0 and mapping.original_column == sibling.span.start)
        {
            found_sibling = true;
        }
        try std.testing.expect(mapping.generated_column != generated_color + 1);
        try std.testing.expect(mapping.generated_column != generated_color + 2);
    }
    try std.testing.expect(found_color);
    try std.testing.expect(found_zero);
    try std.testing.expect(found_sibling);
}

test "color and zero shortening validator rejects forged output and default policy denies the pass" {
    try std.testing.expectError(
        error.DisallowedSafetyClass,
        pass_manager.buildPlan(std.testing.allocator, &test_registry, &.{id}, .{}),
    );

    var parsed = try pipeline.parse(std.testing.allocator, "forged-shorten.css", ".a{color:#ffffff;width:0px}");
    defer parsed.deinit();
    var run_context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    const original = parsed.rules;
    const transformed = try run(null, &run_context, original);
    const old_style = transformed.rules[0].style_rule;
    const arena = parsed.compilation.arenaAllocator();
    const declarations = try arena.dupe(ast.Declaration, old_style.block.declarations.declarations);
    declarations[0].generated_value.?.color.value.red = 0;
    declarations[0] = try ast.Declaration.init(declarations[0]);
    const style = try arena.create(ast.StyleRule);
    style.* = try ast.StyleRule.init(.{
        .selectors = old_style.selectors,
        .block = try ast.StyleBlock.init(
            old_style.block.envelope,
            try ast.DeclarationList.init(old_style.block.declarations.span, declarations),
            old_style.block.rules,
        ),
        .span = old_style.span,
    });
    const rules = try arena.dupe(ast.Rule, transformed.rules);
    rules[0] = .{ .style_rule = style };
    const forged = try arena.create(ast.RuleList);
    forged.* = try ast.RuleList.initWithOmissions(
        transformed.span,
        rules,
        transformed.omitted_rules,
    );
    try std.testing.expectError(
        error.ValidationFailed,
        validate(null, .postcondition, &run_context, original, forged),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "shorten-oom.css",
        ".a{color:rgb(255,0,0);width:0rem;.nested{background-color:#ffffff}}" ++
            "@keyframes f{to{border-inline-start-color:#808080}}",
    );
    defer parsed.deinit();
    var plan = try testPlan(allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{color:red;width:0;.nested{background-color:#fff}}" ++
            "@keyframes f{to{border-inline-start-color:gray}}",
        result.css,
    );
}

test "color and zero shortening handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
