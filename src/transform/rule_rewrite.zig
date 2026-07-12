const std = @import("std");
const ast = @import("../css/ast.zig");
const pass_manager = @import("pass_manager.zig");

pub const Options = struct {
    max_depth: usize = 256,
    max_rules: usize = 100_000,
};

pub const RuleContext = enum {
    stylesheet,
    style,
    group,
};

pub const GenerateFn = *const fn (
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    rule_context: RuleContext,
    rules: ast.RuleList,
) pass_manager.Error!?[]const ast.GeneratedRule;

pub const Result = struct {
    value: *const ast.RuleList,
    changed: bool,
};

const Budget = struct {
    options: Options,
    rules: usize = 0,

    fn visitRule(self: *Budget) pass_manager.Error!void {
        self.rules = std.math.add(usize, self.rules, 1) catch return error.PassFailed;
        if (self.rules > self.options.max_rules) return error.PassFailed;
    }

    fn checkDepth(self: *const Budget, depth: usize) pass_manager.Error!void {
        if (depth > self.options.max_depth) return error.PassFailed;
    }
};

const RewrittenRule = struct {
    value: ast.Rule,
    changed: bool,
};

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
        .stylesheet,
        generate,
        user_data,
        &budget,
        0,
    );
}

fn rewriteRuleList(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    rule_context: RuleContext,
    generate: GenerateFn,
    user_data: ?*anyopaque,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!Result {
    try budget.checkDepth(depth);
    input.validate() catch return error.InvalidAst;
    if (input.rules.len == 0) return .{ .value = input, .changed = false };
    if (input.generated_rules.len != 0) return .{ .value = input, .changed = false };

    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.Rule, input.rules.len);
    defer scratch.free(candidates);
    var child_changed = false;
    for (input.rules, 0..) |rule, index| {
        try budget.visitRule();
        const candidate = try rewriteRule(
            context,
            rule,
            generate,
            user_data,
            budget,
            depth,
        );
        candidates[index] = candidate.value;
        child_changed = child_changed or candidate.changed;
    }

    const candidate_list = ast.RuleList.initWithGeneratedRules(
        input.span,
        candidates,
        input.omitted_rules,
        &.{},
    ) catch return error.InvalidAst;
    const generated = try generate(user_data, context, rule_context, candidate_list);
    if (!child_changed and generated == null) return .{ .value = input, .changed = false };
    if (generated) |proofs| if (proofs.len == 0) return error.InvalidAst;

    const arena = context.arenaAllocator();
    const rules = try arena.dupe(ast.Rule, candidates);
    const output = try arena.create(ast.RuleList);
    output.* = ast.RuleList.initWithGeneratedRules(
        input.span,
        rules,
        input.omitted_rules,
        generated orelse &.{},
    ) catch return error.InvalidAst;
    return .{ .value = output, .changed = true };
}

fn rewriteRule(
    context: *pass_manager.Context,
    input: ast.Rule,
    generate: GenerateFn,
    user_data: ?*anyopaque,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!RewrittenRule {
    return switch (input) {
        .style_rule => |style| blk: {
            _ = ast.StyleRule.init(style.*) catch return error.InvalidAst;
            const child = try rewriteRuleList(
                context,
                &style.block.rules,
                .style,
                generate,
                user_data,
                budget,
                try nextDepth(depth),
            );
            if (!child.changed) break :blk .{ .value = input, .changed = false };

            const output = try context.arenaAllocator().create(ast.StyleRule);
            output.* = ast.StyleRule.init(.{
                .selectors = style.selectors,
                .block = ast.StyleBlock.init(
                    style.block.envelope,
                    style.block.declarations,
                    child.value.*,
                ) catch return error.InvalidAst,
                .span = style.span,
            }) catch return error.InvalidAst;
            break :blk .{ .value = .{ .style_rule = output }, .changed = true };
        },
        .at_rule => |at_rule| blk: {
            _ = ast.AtRule.init(at_rule.*) catch return error.InvalidAst;
            const old_block = switch (at_rule.block) {
                .rules => |block| block,
                else => break :blk .{ .value = input, .changed = false },
            };
            const child = try rewriteRuleList(
                context,
                &old_block.rules,
                .group,
                generate,
                user_data,
                budget,
                try nextDepth(depth),
            );
            if (!child.changed) break :blk .{ .value = input, .changed = false };

            const arena = context.arenaAllocator();
            const block = try arena.create(ast.RulesBlock);
            block.* = (if (old_block.nested)
                ast.RulesBlock.initNested(old_block.envelope, child.value.*)
            else
                ast.RulesBlock.init(old_block.envelope, child.value.*)) catch return error.InvalidAst;
            const output = try arena.create(ast.AtRule);
            output.* = ast.AtRule.init(.{
                .at_sign = at_rule.at_sign,
                .name = at_rule.name,
                .prelude = at_rule.prelude,
                .block = .{ .rules = block },
                .details = try cloneRuleDetails(arena, at_rule.details, block),
                .span = at_rule.span,
            }) catch return error.InvalidAst;
            break :blk .{ .value = .{ .at_rule = output }, .changed = true };
        },
        .nested_declarations => |nested| blk: {
            _ = ast.NestedDeclarationsRule.init(nested.*) catch return error.InvalidAst;
            break :blk .{ .value = input, .changed = false };
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

test "rule rewrite traversal rejects work beyond explicit depth and rule budgets" {
    var budget = Budget{ .options = .{ .max_depth = 2, .max_rules = 1 } };
    try budget.checkDepth(2);
    try std.testing.expectError(error.PassFailed, budget.checkDepth(3));
    try budget.visitRule();
    try std.testing.expectError(error.PassFailed, budget.visitRule());
}
