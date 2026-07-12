const std = @import("std");
const ast = @import("../css/ast.zig");
const emitter = @import("../css/emitter.zig");
const numeric_value = @import("../css/numeric_value.zig");
const pass_manager = @import("pass_manager.zig");

pub const id = "numeric-math-folding";

const max_depth: usize = 256;
const max_declarations: usize = 100_000;

pub fn definition() pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .values,
            .safety = .semantic_rewrite,
            .maturity = .verified,
            .precondition = "the source-matched AST is valid, diagnostic-free, and generated values satisfy ADR-007",
            .postcondition = "only complete supported math-function values with finite same-unit results are replaced by shorter structured numerics; syntax, importance, declarations, rules, and order are preserved",
            .no_op_conditions = "custom properties, descriptors, unsupported properties/functions, mixed units, substitutions, comments, non-finite or out-of-range results, and non-shorter output retain the exact input root",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "the pass reconstructs changed declaration paths in source order and never inserts, removes, sorts, or merges declarations or rules",
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

const Budget = struct {
    declarations: usize = 0,

    fn visitDeclaration(self: *Budget) pass_manager.Error!void {
        self.declarations = std.math.add(usize, self.declarations, 1) catch return error.PassFailed;
        if (self.declarations > max_declarations) return error.PassFailed;
    }

    fn checkDepth(_: *Budget, depth: usize) pass_manager.Error!void {
        if (depth > max_depth) return error.PassFailed;
    }
};

const FoldedRuleList = struct {
    value: *const ast.RuleList,
    changed: bool,
};

const FoldedRule = struct {
    value: ast.Rule,
    changed: bool,
};

const FoldedDeclarationList = struct {
    value: ast.DeclarationList,
    changed: bool,
};

const FoldedDeclaration = struct {
    value: ast.Declaration,
    changed: bool,
};

const FoldedKeyframes = struct {
    value: *const ast.KeyframesBlock,
    changed: bool,
};

const FoldedPage = struct {
    value: *const ast.PageRule,
    changed: bool,
};

fn run(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    if (user_data != null) return error.PassFailed;
    var budget = Budget{};
    return (try foldRuleList(context, input, &budget, 0)).value;
}

fn foldRuleList(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!FoldedRuleList {
    try budget.checkDepth(depth);
    input.validate() catch return error.InvalidAst;
    if (input.rules.len == 0) return .{ .value = input, .changed = false };
    if (input.generated_rules.len != 0) return .{ .value = input, .changed = false };

    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.Rule, input.rules.len);
    defer scratch.free(candidates);
    var changed = false;
    for (input.rules, 0..) |rule, index| {
        const candidate = try foldRule(context, rule, budget, depth);
        candidates[index] = candidate.value;
        changed = changed or candidate.changed;
    }
    if (!changed) return .{ .value = input, .changed = false };

    const arena = context.arenaAllocator();
    const rules = try arena.dupe(ast.Rule, candidates);
    const output = try arena.create(ast.RuleList);
    output.* = ast.RuleList.initWithOmissions(input.span, rules, input.omitted_rules) catch {
        return error.InvalidAst;
    };
    return .{ .value = output, .changed = true };
}

fn foldRule(
    context: *pass_manager.Context,
    input: ast.Rule,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!FoldedRule {
    return switch (input) {
        .style_rule => |style| blk: {
            _ = ast.StyleRule.init(style.*) catch return error.InvalidAst;
            const declarations = try foldDeclarationList(context, style.block.declarations, budget);
            const rules = try foldRuleList(context, &style.block.rules, budget, depth + 1);
            if (!declarations.changed and !rules.changed) {
                break :blk .{ .value = input, .changed = false };
            }

            const arena = context.arenaAllocator();
            const output = try arena.create(ast.StyleRule);
            output.* = ast.StyleRule.init(.{
                .selectors = style.selectors,
                .block = ast.StyleBlock.init(
                    style.block.envelope,
                    declarations.value,
                    rules.value.*,
                ) catch return error.InvalidAst,
                .span = style.span,
            }) catch return error.InvalidAst;
            break :blk .{ .value = .{ .style_rule = output }, .changed = true };
        },
        .at_rule => |at_rule| try foldAtRule(context, at_rule, input, budget, depth),
        .nested_declarations => |nested| blk: {
            _ = ast.NestedDeclarationsRule.init(nested.*) catch return error.InvalidAst;
            const declarations = try foldDeclarationList(context, nested.declarations, budget);
            if (!declarations.changed) break :blk .{ .value = input, .changed = false };

            const output = try context.arenaAllocator().create(ast.NestedDeclarationsRule);
            output.* = ast.NestedDeclarationsRule.init(.{
                .declarations = declarations.value,
                .span = nested.span,
            }) catch return error.InvalidAst;
            break :blk .{ .value = .{ .nested_declarations = output }, .changed = true };
        },
    };
}

fn foldAtRule(
    context: *pass_manager.Context,
    input: *const ast.AtRule,
    original: ast.Rule,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!FoldedRule {
    _ = ast.AtRule.init(input.*) catch return error.InvalidAst;
    return switch (input.block) {
        .none, .declarations => .{ .value = original, .changed = false },
        .rules => |old_block| blk: {
            const child = try foldRuleList(context, &old_block.rules, budget, depth + 1);
            if (!child.changed) break :blk .{ .value = original, .changed = false };

            const arena = context.arenaAllocator();
            const block = try arena.create(ast.RulesBlock);
            block.* = (if (old_block.nested)
                ast.RulesBlock.initNested(old_block.envelope, child.value.*)
            else
                ast.RulesBlock.init(old_block.envelope, child.value.*)) catch return error.InvalidAst;
            const output = try arena.create(ast.AtRule);
            output.* = ast.AtRule.init(.{
                .at_sign = input.at_sign,
                .name = input.name,
                .prelude = input.prelude,
                .block = .{ .rules = block },
                .details = try cloneRuleDetails(arena, input.details, block),
                .span = input.span,
            }) catch return error.InvalidAst;
            break :blk .{ .value = .{ .at_rule = output }, .changed = true };
        },
        .keyframes => |old_block| blk: {
            const block = try foldKeyframes(context, old_block, budget, depth + 1);
            if (!block.changed) break :blk .{ .value = original, .changed = false };
            const details = switch (input.details orelse return error.InvalidAst) {
                .keyframes => |old| details: {
                    const replacement = try context.arenaAllocator().create(ast.KeyframesRule);
                    replacement.* = old.*;
                    replacement.block = block.value;
                    break :details ast.AtRuleDetails{ .keyframes = replacement };
                },
                else => return error.InvalidAst,
            };
            const output = try context.arenaAllocator().create(ast.AtRule);
            output.* = ast.AtRule.init(.{
                .at_sign = input.at_sign,
                .name = input.name,
                .prelude = input.prelude,
                .block = .{ .keyframes = block.value },
                .details = details,
                .span = input.span,
            }) catch return error.InvalidAst;
            break :blk .{ .value = .{ .at_rule = output }, .changed = true };
        },
        .raw => |raw_block| blk: {
            const old_page = switch (input.details orelse break :blk .{
                .value = original,
                .changed = false,
            }) {
                .page => |page| page,
                else => break :blk .{ .value = original, .changed = false },
            };
            const page = try foldPage(context, old_page, budget);
            if (!page.changed) break :blk .{ .value = original, .changed = false };
            const output = try context.arenaAllocator().create(ast.AtRule);
            output.* = ast.AtRule.init(.{
                .at_sign = input.at_sign,
                .name = input.name,
                .prelude = input.prelude,
                .block = .{ .raw = raw_block },
                .details = .{ .page = page.value },
                .span = input.span,
            }) catch return error.InvalidAst;
            break :blk .{ .value = .{ .at_rule = output }, .changed = true };
        },
    };
}

fn cloneRuleDetails(
    arena: std.mem.Allocator,
    details: ?ast.AtRuleDetails,
    block: *const ast.RulesBlock,
) std.mem.Allocator.Error!?ast.AtRuleDetails {
    const value = details orelse return null;
    return switch (value) {
        .media => |old| blk: {
            const replacement = try arena.create(ast.MediaRule);
            replacement.* = old.*;
            replacement.block = block;
            break :blk .{ .media = replacement };
        },
        .supports => |old| blk: {
            const replacement = try arena.create(ast.SupportsRule);
            replacement.* = old.*;
            replacement.block = block;
            break :blk .{ .supports = replacement };
        },
        .container => |old| blk: {
            const replacement = try arena.create(ast.ContainerRule);
            replacement.* = old.*;
            replacement.block = block;
            break :blk .{ .container = replacement };
        },
        else => value,
    };
}

fn foldKeyframes(
    context: *pass_manager.Context,
    input: *const ast.KeyframesBlock,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!FoldedKeyframes {
    try budget.checkDepth(depth);
    if (input.frames.len == 0) return .{ .value = input, .changed = false };
    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.KeyframeRule, input.frames.len);
    defer scratch.free(candidates);
    var changed = false;
    for (input.frames, 0..) |frame, index| {
        _ = ast.KeyframeRule.init(frame) catch return error.InvalidAst;
        const declarations = try foldDeclarationList(context, frame.block.declarations, budget);
        candidates[index] = if (declarations.changed)
            ast.KeyframeRule.init(.{
                .prelude = frame.prelude,
                .selectors = frame.selectors,
                .block = ast.DeclarationBlock.init(
                    frame.block.envelope,
                    declarations.value,
                ) catch return error.InvalidAst,
                .span = frame.span,
            }) catch return error.InvalidAst
        else
            frame;
        changed = changed or declarations.changed;
    }
    if (!changed) return .{ .value = input, .changed = false };

    const arena = context.arenaAllocator();
    const frames = try arena.dupe(ast.KeyframeRule, candidates);
    const output = try arena.create(ast.KeyframesBlock);
    output.* = (if (input.raw_values) |raw|
        ast.KeyframesBlock.initWithRaw(input.envelope, raw, frames)
    else
        ast.KeyframesBlock.init(input.envelope, frames)) catch return error.InvalidAst;
    return .{ .value = output, .changed = true };
}

fn foldPage(
    context: *pass_manager.Context,
    input: *const ast.PageRule,
    budget: *Budget,
) pass_manager.Error!FoldedPage {
    const declarations = try foldDeclarationList(context, input.declarations.*, budget);
    const scratch = context.scratchAllocator();
    const margins = try scratch.alloc(ast.PageMarginRule, input.margins.len);
    defer scratch.free(margins);
    var changed = declarations.changed;
    for (input.margins, 0..) |margin, index| {
        const child = try foldDeclarationList(context, margin.declarations.*, budget);
        margins[index] = margin;
        if (child.changed) {
            const declaration_list = try context.arenaAllocator().create(ast.DeclarationList);
            declaration_list.* = child.value;
            margins[index].declarations = declaration_list;
            changed = true;
        }
    }
    if (!changed) return .{ .value = input, .changed = false };

    const arena = context.arenaAllocator();
    const declaration_list = if (declarations.changed) blk: {
        const value = try arena.create(ast.DeclarationList);
        value.* = declarations.value;
        break :blk value;
    } else input.declarations;
    const output = try arena.create(ast.PageRule);
    output.* = .{
        .selectors = input.selectors,
        .declarations = declaration_list,
        .margins = try arena.dupe(ast.PageMarginRule, margins),
        .span = input.span,
    };
    return .{ .value = output, .changed = true };
}

fn foldDeclarationList(
    context: *pass_manager.Context,
    input: ast.DeclarationList,
    budget: *Budget,
) pass_manager.Error!FoldedDeclarationList {
    input.validate() catch return error.InvalidAst;
    if (input.declarations.len == 0) return .{ .value = input, .changed = false };

    if (input.generated_declarations.len != 0) {
        for (input.declarations) |_| try budget.visitDeclaration();
        return .{ .value = input, .changed = false };
    }

    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.Declaration, input.declarations.len);
    defer scratch.free(candidates);
    var changed = false;
    for (input.declarations, 0..) |declaration, index| {
        try budget.visitDeclaration();
        const candidate = try foldDeclaration(context, declaration);
        candidates[index] = candidate.value;
        changed = changed or candidate.changed;
    }
    if (!changed) return .{ .value = input, .changed = false };

    const declarations = try context.arenaAllocator().dupe(ast.Declaration, candidates);
    return .{
        .value = ast.DeclarationList.init(input.span, declarations) catch return error.InvalidAst,
        .changed = true,
    };
}

fn foldDeclaration(
    context: *pass_manager.Context,
    input: ast.Declaration,
) pass_manager.Error!FoldedDeclaration {
    _ = ast.Declaration.init(input) catch return error.InvalidAst;
    const generated = try expectedGenerated(context, input) orelse {
        return .{ .value = input, .changed = false };
    };
    var output = input;
    output.generated_value = .{ .numeric = generated };
    output = ast.Declaration.init(output) catch return error.InvalidAst;
    return .{ .value = output, .changed = true };
}

const ValueCategory = enum {
    length,
    length_percentage,
    number_percentage,
    number,
    angle,
    time,
};

const ValueRange = enum { any, nonnegative };

const PropertyPolicy = struct {
    category: ValueCategory,
    range: ValueRange,
};

fn expectedGenerated(
    context: *pass_manager.Context,
    declaration: ast.Declaration,
) pass_manager.Error!?ast.GeneratedNumericValue {
    if (declaration.generated_value != null or declaration.name.isCustomProperty()) return null;
    const policy = propertyPolicy(declaration.name.value) orelse return null;
    const values = declaration.valueWithoutImportance();
    const root = singleMathFunction(values) orelse return null;

    var expression = numeric_value.parse(
        context.scratchAllocator(),
        context.file(),
        values,
        .{ .percentage_hint = if (policy.category == .length_percentage) .length else null },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch, error.InvalidSpan => return error.InvalidAst,
        else => return null,
    };
    defer expression.deinit();
    if (!sameSpan(expression.span, root.span())) return null;
    const evaluated = (try numeric_value.evaluate(context.scratchAllocator(), &expression)) orelse return null;
    if (!policyAccepts(policy, evaluated)) return null;

    const generated = ast.GeneratedNumericValue.init(.{
        .value = evaluated.value,
        .unit = evaluated.unit,
        .source_span = expression.span,
    }) catch return error.InvalidAst;
    var buffer: [ast.generated_numeric_buffer_size]u8 = undefined;
    const serialized = generated.serialize(&buffer) catch return error.InvalidAst;
    if (serialized.len >= expression.span.len()) return null;
    return generated;
}

fn singleMathFunction(values: []const @import("../syntax.zig").ComponentValue) ?@import("../syntax.zig").ComponentValue {
    var first: usize = 0;
    while (first < values.len and isWhitespace(values[first])) : (first += 1) {}
    var end = values.len;
    while (end > first and isWhitespace(values[end - 1])) : (end -= 1) {}
    if (end - first != 1 or values[first] != .function or containsComment(values[first])) return null;
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

fn policyAccepts(policy: PropertyPolicy, value: numeric_value.Evaluated) bool {
    if (policy.range == .nonnegative and (value.value < 0 or std.math.signbit(value.value))) {
        return false;
    }
    return switch (policy.category) {
        .length => value.unit.baseDimension() == .length,
        .length_percentage => value.unit == .percent or value.unit.baseDimension() == .length,
        .number_percentage => value.unit == .number or value.unit == .percent,
        .number => value.unit == .number,
        .angle => value.unit.baseDimension() == .angle,
        .time => value.unit.baseDimension() == .time,
    };
}

fn propertyPolicy(name: []const u8) ?PropertyPolicy {
    const nonnegative_lengths = [_][]const u8{
        "width",                "height",             "min-width",       "min-height",     "max-width",           "max-height",
        "inline-size",          "block-size",         "min-inline-size", "min-block-size", "max-inline-size",     "max-block-size",
        "padding-top",          "padding-right",      "padding-bottom",  "padding-left",   "padding-block-start", "padding-block-end",
        "padding-inline-start", "padding-inline-end", "row-gap",         "column-gap",     "font-size",
    };
    if (matchesAny(name, &nonnegative_lengths)) {
        return .{ .category = .length_percentage, .range = .nonnegative };
    }
    const nonnegative_length_only = [_][]const u8{
        "border-top-width",          "border-right-width",       "border-bottom-width",
        "border-left-width",         "border-block-start-width", "border-block-end-width",
        "border-inline-start-width", "border-inline-end-width",  "outline-width",
    };
    if (matchesAny(name, &nonnegative_length_only)) {
        return .{ .category = .length, .range = .nonnegative };
    }
    const unrestricted_lengths = [_][]const u8{
        "top",                "right",            "bottom",              "left",              "inset-block-start", "inset-block-end",
        "inset-inline-start", "inset-inline-end", "margin-top",          "margin-right",      "margin-bottom",     "margin-left",
        "margin-block-start", "margin-block-end", "margin-inline-start", "margin-inline-end",
    };
    if (matchesAny(name, &unrestricted_lengths)) {
        return .{ .category = .length_percentage, .range = .any };
    }
    const opacities = [_][]const u8{
        "opacity", "fill-opacity", "flood-opacity", "stop-opacity", "stroke-opacity",
    };
    if (matchesAny(name, &opacities)) {
        return .{ .category = .number_percentage, .range = .any };
    }
    const nonnegative_numbers = [_][]const u8{ "flex-grow", "flex-shrink" };
    if (matchesAny(name, &nonnegative_numbers)) {
        return .{ .category = .number, .range = .nonnegative };
    }
    if (std.ascii.eqlIgnoreCase(name, "rotate")) {
        return .{ .category = .angle, .range = .any };
    }
    if (std.ascii.eqlIgnoreCase(name, "animation-duration") or
        std.ascii.eqlIgnoreCase(name, "transition-duration"))
    {
        return .{ .category = .time, .range = .nonnegative };
    }
    if (std.ascii.eqlIgnoreCase(name, "animation-delay") or
        std.ascii.eqlIgnoreCase(name, "transition-delay"))
    {
        return .{ .category = .time, .range = .any };
    }
    return null;
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
    var budget = Budget{};
    const expected = try foldRuleList(context, before, &budget, 0);
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

test "math folding rewrites only shorter finite policy-matched whole values" {
    const css = ".a{" ++
        "width:calc(1px + 2px);opacity:max(10%,20%)!important;" ++
        "rotate:clamp(10deg,5deg,3deg);animation-delay:calc(1s - 2s);" ++
        "color:calc(1 + 2);--x:calc(1px + 2px);width:calc(1in + 96px);" ++
        "margin-left:calc(1px - 2px);height:calc(1px - 2px);" ++
        "width:calc(var(--size) + 1px);width:calc(1px/**/ + 2px)}";
    var parsed = try pipeline.parse(std.testing.allocator, "math-fold.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();

    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules != original);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{width:3px;opacity:20%!important;rotate:10deg;animation-delay:-1s;" ++
            "color:calc(1 + 2);--x:calc(1px + 2px);width:calc(1in + 96px);" ++
            "margin-left:-1px;height:calc(1px - 2px);width:calc(var(--size) + 1px);" ++
            "width:calc(1px/**/ + 2px)}",
        result.css,
    );
    try std.testing.expect(result.css.len < css.len);

    var reparsed = try pipeline.parse(std.testing.allocator, "math-fold-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        parsed.rules,
        reparsed.file(),
        reparsed.rules,
    ));

    const once = parsed.rules;
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == once);
}

test "math folding traverses nested rules keyframes pages and margin boxes" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "nested-math.css",
        ".host{width:calc(1px + 2px);.child{height:min(4px,2px)}" ++
            "@media all{opacity:max(10%,20%)}margin-left:calc(4em - 1em)}" ++
            "@keyframes fade{from{opacity:calc(1 - 0)}to{rotate:max(1deg,2deg)}}" ++
            "@page{margin-left:calc(3cm - 1cm);@top-left{width:calc(2px + 3px)}}" ++
            "@font-face{size-adjust:calc(1% + 2%)}" ++
            "@property --len{syntax:\"<length>\";inherits:false;initial-value:calc(1px + 2px)}",
    );
    defer parsed.deinit();
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".host{width:3px;.child{height:2px}@media all{opacity:20%}margin-left:3em}" ++
            "@keyframes fade{from{opacity:1}to{rotate:2deg}}" ++
            "@page{margin-left:2cm;@top-left{width:5px}}" ++
            "@font-face{size-adjust:calc(1% + 2%)}" ++
            "@property --len{syntax:\"<length>\";inherits:false;initial-value:calc(1px + 2px)}",
        result.css,
    );
}

test "math folding preserves layered fallback order importance and logical properties" {
    const css = "@layer theme{.a{" ++
        "padding-inline-start:calc(1px + 2px);" ++
        "margin-block-end:calc(2px - 3px);" ++
        "width:calc(1px + 2px);width:calc(1in + 96px);" ++
        "width:calc(2px + 3px)!important;" ++
        "border-inline-start-width:calc(4px / 2);" ++
        "border-inline-end-width:calc(10% + 5%)}}";
    var parsed = try pipeline.parse(std.testing.allocator, "layered-math.css", css);
    defer parsed.deinit();
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@layer theme{.a{padding-inline-start:3px;margin-block-end:-1px;" ++
            "width:3px;width:calc(1in + 96px);width:5px!important;" ++
            "border-inline-start-width:2px;" ++
            "border-inline-end-width:calc(10% + 5%)}}",
        result.css,
    );
}

test "math folding returns the exact root when every value is conservatively ineligible" {
    const css = ".a{color:calc(1 + 2);--x:min(1px,2px);width:calc(1in + 96px);" ++
        "width:calc(1px/**/ + 2px);height:calc(1px - 2px);opacity:min(-0,0)}";
    var parsed = try pipeline.parse(std.testing.allocator, "math-no-op.css", css);
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

test "math folding preserves an existing declaration-level proof boundary" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "math-proof-boundary.css",
        ".a{margin-top:0;margin-right:0;margin-bottom:0;margin-left:0}",
    );
    defer parsed.deinit();
    const original = parsed.rules.rules[0].style_rule.block.declarations;
    const generated = [_]ast.GeneratedDeclaration{.{
        .kind = .margin,
        .first_declaration = 0,
        .source_span = .{
            .source = parsed.source_id,
            .start = original.declarations[0].span.start,
            .end = original.declarations[3].span.end,
        },
    }};
    const protected = try ast.DeclarationList.initWithGenerated(
        original.span,
        original.declarations,
        &generated,
    );
    var context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    var budget = Budget{};
    const result = try foldDeclarationList(&context, protected, &budget);
    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(@as(usize, 1), result.value.generated_declarations.len);
    try std.testing.expectEqual(@as(usize, 4), budget.declarations);
}

test "math folding source maps anchor generated values and retain siblings" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "mapped-math.css",
        ".a{width:calc(1px + 2px);height:4px}",
    );
    defer parsed.deinit();
    const causal = parsed.rules.rules[0].style_rule.block.declarations.declarations[0]
        .valueWithoutImportance()[0].span();
    const sibling = parsed.rules.rules[0].style_rule.block.declarations.declarations[1];
    var plan = try testPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{
        .mode = .minified,
        .source_map = .{ .generated_file = "mapped-math.out.css" },
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
    const generated_value: u32 = @intCast(std.mem.indexOf(u8, result.css, "3px").?);
    const generated_sibling: u32 = @intCast(std.mem.indexOf(u8, result.css, "height").?);
    var found_value = false;
    var found_sibling = false;
    for (mappings) |mapping| {
        if (mapping.generated_line == 0 and mapping.generated_column == generated_value and
            mapping.original_line == 0 and mapping.original_column == causal.start)
        {
            found_value = true;
        }
        if (mapping.generated_line == 0 and mapping.generated_column == generated_sibling and
            mapping.original_line == 0 and mapping.original_column == sibling.span.start)
        {
            found_sibling = true;
        }
        try std.testing.expect(mapping.generated_column != generated_value + 1);
        try std.testing.expect(mapping.generated_column != generated_value + 2);
    }
    try std.testing.expect(found_value);
    try std.testing.expect(found_sibling);
}

test "math folding validator rejects a forged result and default policy denies the pass" {
    try std.testing.expectError(
        error.DisallowedSafetyClass,
        pass_manager.buildPlan(
            std.testing.allocator,
            &test_registry,
            &.{id},
            .{},
        ),
    );

    var parsed = try pipeline.parse(
        std.testing.allocator,
        "forged-math.css",
        ".a{width:calc(1px + 2px);height:4px}",
    );
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
    declarations[0].generated_value.?.numeric.value = 4;
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

test "math folding rejects work beyond its traversal budgets" {
    var budget = Budget{};
    try budget.checkDepth(max_depth);
    try std.testing.expectError(error.PassFailed, budget.checkDepth(max_depth + 1));
    budget.declarations = max_declarations;
    try std.testing.expectError(error.PassFailed, budget.visitDeclaration());
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "math-fold-oom.css",
        ".a{width:calc((1px + 2px) * 3);opacity:max(10%,20%)!important;" ++
            ".nested{height:min(4em,2em)}}@keyframes f{to{rotate:max(1deg,2deg)}}",
    );
    defer parsed.deinit();
    var plan = try testPlan(allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{width:9px;opacity:20%!important;.nested{height:2em}}" ++
            "@keyframes f{to{rotate:2deg}}",
        result.css,
    );
}

test "math folding handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
