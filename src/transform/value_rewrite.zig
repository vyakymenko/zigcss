const std = @import("std");
const ast = @import("../css/ast.zig");
const pass_manager = @import("pass_manager.zig");

pub const Options = struct {
    max_depth: usize = 256,
    max_declarations: usize = 100_000,
};

pub const GenerateFn = *const fn (
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    declaration: ast.Declaration,
) pass_manager.Error!?ast.GeneratedValue;

pub const DeclarationContext = enum {
    style,
    nested,
    keyframe,
    page,
    page_margin,
};

pub const GenerateDeclarationsFn = *const fn (
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    declaration_context: DeclarationContext,
    declarations: ast.DeclarationList,
) pass_manager.Error!?[]const ast.GeneratedDeclaration;

pub const Result = struct {
    value: *const ast.RuleList,
    changed: bool,
};

const Budget = struct {
    options: Options,
    declarations: usize = 0,

    fn visitDeclaration(self: *Budget) pass_manager.Error!void {
        self.declarations = std.math.add(usize, self.declarations, 1) catch return error.PassFailed;
        if (self.declarations > self.options.max_declarations) return error.PassFailed;
    }

    fn checkDepth(self: *const Budget, depth: usize) pass_manager.Error!void {
        if (depth > self.options.max_depth) return error.PassFailed;
    }
};

const RewrittenRule = struct {
    value: ast.Rule,
    changed: bool,
};

const RewrittenDeclarationList = struct {
    value: ast.DeclarationList,
    changed: bool,
};

const RewrittenKeyframes = struct {
    value: *const ast.KeyframesBlock,
    changed: bool,
};

const RewrittenPage = struct {
    value: *const ast.PageRule,
    changed: bool,
};

const Strategy = union(enum) {
    values: struct {
        generate: GenerateFn,
        user_data: ?*anyopaque,
    },
    declarations: struct {
        generate: GenerateDeclarationsFn,
        user_data: ?*anyopaque,
    },
};

/// Applies a whole-declaration-value generator while reconstructing only
/// changed AST paths. Declaration-backed descriptor at-rules are deliberately
/// excluded because their grammars are not ordinary property grammars.
pub fn rewrite(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    generate: GenerateFn,
    user_data: ?*anyopaque,
    options: Options,
) pass_manager.Error!Result {
    var budget = Budget{ .options = options };
    return rewriteRuleList(
        context,
        input,
        .{ .values = .{ .generate = generate, .user_data = user_data } },
        &budget,
        0,
    );
}

/// Adds proof-carrying generated declarations while preserving the complete
/// authored declaration array. The callback can annotate a list only once;
/// already-annotated lists are exact no-ops, which makes later value passes
/// unable to invalidate or silently discard a declaration-level proof.
pub fn rewriteDeclarations(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    generate: GenerateDeclarationsFn,
    user_data: ?*anyopaque,
    options: Options,
) pass_manager.Error!Result {
    var budget = Budget{ .options = options };
    return rewriteRuleList(
        context,
        input,
        .{ .declarations = .{ .generate = generate, .user_data = user_data } },
        &budget,
        0,
    );
}

fn rewriteRuleList(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    strategy: Strategy,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!Result {
    try budget.checkDepth(depth);
    input.validate() catch return error.InvalidAst;
    if (input.rules.len == 0) return .{ .value = input, .changed = false };

    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.Rule, input.rules.len);
    defer scratch.free(candidates);
    var changed = false;
    for (input.rules, 0..) |rule, index| {
        const candidate = try rewriteRule(context, rule, strategy, budget, depth);
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

fn rewriteRule(
    context: *pass_manager.Context,
    input: ast.Rule,
    strategy: Strategy,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!RewrittenRule {
    return switch (input) {
        .style_rule => |style| blk: {
            _ = ast.StyleRule.init(style.*) catch return error.InvalidAst;
            const declarations = try rewriteDeclarationList(
                context,
                style.block.declarations,
                strategy,
                .style,
                budget,
            );
            const rules = try rewriteRuleList(
                context,
                &style.block.rules,
                strategy,
                budget,
                try nextDepth(depth),
            );
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
        .at_rule => |at_rule| try rewriteAtRule(
            context,
            at_rule,
            input,
            strategy,
            budget,
            depth,
        ),
        .nested_declarations => |nested| blk: {
            _ = ast.NestedDeclarationsRule.init(nested.*) catch return error.InvalidAst;
            const declarations = try rewriteDeclarationList(
                context,
                nested.declarations,
                strategy,
                .nested,
                budget,
            );
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

fn rewriteAtRule(
    context: *pass_manager.Context,
    input: *const ast.AtRule,
    original: ast.Rule,
    strategy: Strategy,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!RewrittenRule {
    _ = ast.AtRule.init(input.*) catch return error.InvalidAst;
    return switch (input.block) {
        .none, .declarations => .{ .value = original, .changed = false },
        .rules => |old_block| blk: {
            const child = try rewriteRuleList(
                context,
                &old_block.rules,
                strategy,
                budget,
                try nextDepth(depth),
            );
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
            const block = try rewriteKeyframes(
                context,
                old_block,
                strategy,
                budget,
                try nextDepth(depth),
            );
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
            const page = try rewritePage(context, old_page, strategy, budget);
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

fn nextDepth(depth: usize) pass_manager.Error!usize {
    return std.math.add(usize, depth, 1) catch error.PassFailed;
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

fn rewriteKeyframes(
    context: *pass_manager.Context,
    input: *const ast.KeyframesBlock,
    strategy: Strategy,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!RewrittenKeyframes {
    try budget.checkDepth(depth);
    if (input.frames.len == 0) return .{ .value = input, .changed = false };
    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.KeyframeRule, input.frames.len);
    defer scratch.free(candidates);
    var changed = false;
    for (input.frames, 0..) |frame, index| {
        _ = ast.KeyframeRule.init(frame) catch return error.InvalidAst;
        const declarations = try rewriteDeclarationList(
            context,
            frame.block.declarations,
            strategy,
            .keyframe,
            budget,
        );
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

fn rewritePage(
    context: *pass_manager.Context,
    input: *const ast.PageRule,
    strategy: Strategy,
    budget: *Budget,
) pass_manager.Error!RewrittenPage {
    const declarations = try rewriteDeclarationList(
        context,
        input.declarations.*,
        strategy,
        .page,
        budget,
    );
    const scratch = context.scratchAllocator();
    const margins = try scratch.alloc(ast.PageMarginRule, input.margins.len);
    defer scratch.free(margins);
    var changed = declarations.changed;
    for (input.margins, 0..) |margin, index| {
        const child = try rewriteDeclarationList(
            context,
            margin.declarations.*,
            strategy,
            .page_margin,
            budget,
        );
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

fn rewriteDeclarationList(
    context: *pass_manager.Context,
    input: ast.DeclarationList,
    strategy: Strategy,
    declaration_context: DeclarationContext,
    budget: *Budget,
) pass_manager.Error!RewrittenDeclarationList {
    input.validate() catch return error.InvalidAst;
    if (input.declarations.len == 0) return .{ .value = input, .changed = false };

    for (input.declarations) |declaration| {
        try budget.visitDeclaration();
        _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
    }
    if (input.generated_declarations.len != 0) return .{ .value = input, .changed = false };

    return switch (strategy) {
        .values => |value_strategy| rewriteDeclarationValues(
            context,
            input,
            value_strategy.generate,
            value_strategy.user_data,
        ),
        .declarations => |declaration_strategy| blk: {
            const generated = try declaration_strategy.generate(
                declaration_strategy.user_data,
                context,
                declaration_context,
                input,
            ) orelse break :blk .{ .value = input, .changed = false };
            if (generated.len == 0) return error.InvalidAst;
            break :blk .{
                .value = ast.DeclarationList.initWithGenerated(
                    input.span,
                    input.declarations,
                    generated,
                ) catch return error.InvalidAst,
                .changed = true,
            };
        },
    };
}

fn rewriteDeclarationValues(
    context: *pass_manager.Context,
    input: ast.DeclarationList,
    generate: GenerateFn,
    user_data: ?*anyopaque,
) pass_manager.Error!RewrittenDeclarationList {
    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.Declaration, input.declarations.len);
    defer scratch.free(candidates);
    var changed = false;
    for (input.declarations, 0..) |declaration, index| {
        const generated = try generate(user_data, context, declaration);
        candidates[index] = declaration;
        if (generated) |value| {
            candidates[index].generated_value = value;
            candidates[index] = ast.Declaration.init(candidates[index]) catch return error.InvalidAst;
            changed = true;
        }
    }
    if (!changed) return .{ .value = input, .changed = false };

    const declarations = try context.arenaAllocator().dupe(ast.Declaration, candidates);
    return .{
        .value = ast.DeclarationList.init(input.span, declarations) catch return error.InvalidAst,
        .changed = true,
    };
}

test "whole-value rewrite traversal rejects work beyond its explicit budgets" {
    var budget = Budget{ .options = .{ .max_depth = 2, .max_declarations = 1 } };
    try budget.checkDepth(2);
    try std.testing.expectError(error.PassFailed, budget.checkDepth(3));
    try budget.visitDeclaration();
    try std.testing.expectError(error.PassFailed, budget.visitDeclaration());
}
