const std = @import("std");
const ast = @import("../css/ast.zig");
const emitter = @import("../css/emitter.zig");
const equivalence = @import("../css/equivalence.zig");
const pipeline = @import("../css/pipeline.zig");
const pass_manager = @import("../transform/pass_manager.zig");
const compatibility = @import("compatibility.zig");
const compatibility_types = @import("compatibility_types.zig");
const rewrite_analysis = @import("rewrite_analysis.zig");
const target_query = @import("target_query.zig");

pub const id = "target-prefix-rewrite";
pub const max_forms = std.meta.fields(ast.CompatibilityForm).len;

pub const ConfigError = std.mem.Allocator.Error || error{
    InvalidCompatibilityData,
    InvalidQuery,
};

pub const FeatureDecision = struct {
    values: [max_forms]ast.CompatibilityForm = undefined,
    length: u8 = 0,
    partial: bool = false,
    annotated: bool = false,
    unsupported: ?compatibility.UnsupportedTarget = null,

    pub fn forms(self: *const FeatureDecision) []const ast.CompatibilityForm {
        return self.values[0..self.length];
    }

    pub fn actionable(self: *const FeatureDecision) bool {
        return self.length != 0;
    }

    fn append(self: *FeatureDecision, form: ast.CompatibilityForm) ConfigError!void {
        for (self.forms()) |existing| if (existing == form) return;
        if (self.length == max_forms) return error.InvalidCompatibilityData;
        self.values[self.length] = form;
        self.length += 1;
    }
};

const declaration_feature_count = std.meta.fields(ast.CompatibilityDeclarationFeature).len;
const rule_feature_count = std.meta.fields(ast.CompatibilityRuleFeature).len;

pub const Configuration = struct {
    declarations: [declaration_feature_count]FeatureDecision,
    rules: [rule_feature_count]FeatureDecision,

    pub fn init(
        allocator: std.mem.Allocator,
        query: *const target_query.Query,
    ) ConfigError!Configuration {
        if (!query.validate()) return error.InvalidQuery;
        var result = Configuration{
            .declarations = .{FeatureDecision{}} ** declaration_feature_count,
            .rules = .{FeatureDecision{}} ** rule_feature_count,
        };
        for (declaration_descriptors) |descriptor| {
            result.declarations[@intFromEnum(descriptor.feature)] = try resolveFeature(
                allocator,
                query,
                descriptor.id,
                .{ .declaration = descriptor.feature },
            );
        }
        for (rule_descriptors) |descriptor| {
            result.rules[@intFromEnum(descriptor.feature)] = try resolveFeature(
                allocator,
                query,
                descriptor.id,
                .{ .rule = descriptor.feature },
            );
        }
        return result;
    }

    pub fn declaration(
        self: *const Configuration,
        feature: ast.CompatibilityDeclarationFeature,
    ) *const FeatureDecision {
        return &self.declarations[@intFromEnum(feature)];
    }

    pub fn rule(
        self: *const Configuration,
        feature: ast.CompatibilityRuleFeature,
    ) *const FeatureDecision {
        return &self.rules[@intFromEnum(feature)];
    }
};

const declaration_descriptors = [_]struct {
    feature: ast.CompatibilityDeclarationFeature,
    id: []const u8,
}{
    .{ .feature = .appearance, .id = "property.appearance" },
    .{ .feature = .user_select, .id = "property.user-select" },
    .{ .feature = .backdrop_filter, .id = "property.backdrop-filter" },
    .{ .feature = .position_sticky, .id = "value.position.sticky" },
    .{ .feature = .display_flex, .id = "value.display.flex" },
};

const rule_descriptors = [_]struct {
    feature: ast.CompatibilityRuleFeature,
    id: []const u8,
}{
    .{ .feature = .placeholder, .id = "selector.placeholder" },
    .{ .feature = .fullscreen, .id = "selector.fullscreen" },
    .{ .feature = .keyframes, .id = "at-rule.keyframes" },
};

const Feature = union(enum) {
    declaration: ast.CompatibilityDeclarationFeature,
    rule: ast.CompatibilityRuleFeature,
};

fn resolveFeature(
    allocator: std.mem.Allocator,
    query: *const target_query.Query,
    feature_id: []const u8,
    feature: Feature,
) ConfigError!FeatureDecision {
    var result = FeatureDecision{};
    for (query.targets) |target| {
        var target_storage = [_]target_query.Target{target};
        const single = target_query.Query{
            .allocator = allocator,
            .targets = &target_storage,
        };
        var resolution = compatibility.resolve(allocator, feature_id, &single) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCompatibilityData,
        };
        switch (resolution) {
            .unsupported => |unsupported| if (result.unsupported == null) {
                result.unsupported = unsupported;
            },
            .supported => |*requirement| {
                defer requirement.deinit();
                result.partial = result.partial or requirement.partial;
                result.annotated = result.annotated or requirement.annotated;
                if (requirement.partial or requirement.annotated) continue;
                for (requirement.alternatives) |alternative| {
                    const form = mapForm(alternative) orelse return error.InvalidCompatibilityData;
                    const allowed = switch (feature) {
                        .declaration => |value| ast.compatibilityDeclarationFormAllowed(value, form),
                        .rule => |value| ast.compatibilityRuleFormAllowed(value, form),
                    };
                    if (!allowed) return error.InvalidCompatibilityData;
                    try result.append(form);
                }
            },
        }
    }
    return result;
}

fn mapForm(form: compatibility_types.Form) ?ast.CompatibilityForm {
    return switch (form.kind) {
        .standard => null,
        .prefix => if (std.mem.eql(u8, form.value, "-khtml-"))
            .khtml
        else if (std.mem.eql(u8, form.value, "-webkit-") or
            std.mem.eql(u8, form.value, "-webkit-input-"))
            .webkit
        else if (std.mem.eql(u8, form.value, "-moz-"))
            .moz
        else if (std.mem.eql(u8, form.value, "-ms-") or
            std.mem.eql(u8, form.value, "-ms-input-"))
            .ms
        else
            null,
        .alternative_name => if (std.mem.eql(u8, form.value, "-ms-flexbox"))
            .ms
        else if (std.mem.eql(u8, form.value, ":-webkit-full-screen"))
            .webkit
        else if (std.mem.eql(u8, form.value, ":-moz-full-screen"))
            .moz
        else
            null,
    };
}

pub const Options = struct {
    max_depth: usize = 256,
    max_rules: usize = 100_000,
    max_declarations: usize = 100_000,
};

pub const Result = struct {
    value: *const ast.RuleList,
    changed: bool,
};

const Budget = struct {
    options: Options,
    rules: usize = 0,
    declarations: usize = 0,

    fn visitRule(self: *Budget) pass_manager.Error!void {
        self.rules = std.math.add(usize, self.rules, 1) catch return error.PassFailed;
        if (self.rules > self.options.max_rules) return error.PassFailed;
    }

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

pub fn rewrite(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    config: *const Configuration,
    options: Options,
) pass_manager.Error!Result {
    var budget = Budget{ .options = options };
    return rewriteRuleList(context, input, config, &budget, 0);
}

fn rewriteRuleList(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    config: *const Configuration,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!Result {
    try budget.checkDepth(depth);
    input.validate() catch return error.InvalidAst;
    if (input.rules.len == 0) return .{ .value = input, .changed = false };

    const scratch = context.scratchAllocator();
    const protected = try scratch.alloc(bool, input.rules.len);
    defer scratch.free(protected);
    @memset(protected, false);
    for (input.generated_rules) |proof| {
        try validateExistingRuleProof(config, proof);
        const end = std.math.add(usize, proof.first_rule, proof.kind.inputCount()) catch {
            return error.InvalidAst;
        };
        if (end > protected.len) return error.InvalidAst;
        @memset(protected[proof.first_rule..end], true);
    }

    const candidates = try scratch.alloc(ast.Rule, input.rules.len);
    defer scratch.free(candidates);
    var child_changed = false;
    for (input.rules, 0..) |rule, index| {
        try budget.visitRule();
        if (protected[index]) {
            candidates[index] = rule;
            continue;
        }
        const candidate = try rewriteRule(context, rule, config, budget, depth);
        candidates[index] = candidate.value;
        child_changed = child_changed or candidate.changed;
    }

    const candidate_list = ast.RuleList.initWithGeneratedRules(
        input.span,
        candidates,
        input.omitted_rules,
        input.generated_rules,
    ) catch return error.InvalidAst;
    const proofs = try generateRuleProofs(context, &candidate_list, config);
    const proofs_changed = proofs != null;
    if (!child_changed and !proofs_changed) return .{ .value = input, .changed = false };

    const arena = context.arenaAllocator();
    const rules = try arena.dupe(ast.Rule, candidates);
    const output = try arena.create(ast.RuleList);
    output.* = ast.RuleList.initWithGeneratedRules(
        input.span,
        rules,
        input.omitted_rules,
        proofs orelse input.generated_rules,
    ) catch return error.InvalidAst;
    return .{ .value = output, .changed = true };
}

fn rewriteRule(
    context: *pass_manager.Context,
    input: ast.Rule,
    config: *const Configuration,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!RewrittenRule {
    return switch (input) {
        .style_rule => |style| blk: {
            _ = ast.StyleRule.init(style.*) catch return error.InvalidAst;
            const declarations = try rewriteDeclarationList(
                context,
                style.block.declarations,
                config,
                budget,
            );
            const rules = try rewriteRuleList(
                context,
                &style.block.rules,
                config,
                budget,
                try nextDepth(depth),
            );
            if (!declarations.changed and !rules.changed) {
                break :blk .{ .value = input, .changed = false };
            }
            const output = try context.arenaAllocator().create(ast.StyleRule);
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
        .at_rule => |at_rule| try rewriteAtRule(context, at_rule, input, config, budget, depth),
        .nested_declarations => |nested| blk: {
            _ = ast.NestedDeclarationsRule.init(nested.*) catch return error.InvalidAst;
            const declarations = try rewriteDeclarationList(
                context,
                nested.declarations,
                config,
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
    config: *const Configuration,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!RewrittenRule {
    _ = ast.AtRule.init(input.*) catch return error.InvalidAst;
    return switch (input.block) {
        .none, .declarations, .raw => .{ .value = original, .changed = false },
        .rules => |old_block| blk: {
            const child = try rewriteRuleList(
                context,
                &old_block.rules,
                config,
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
                config,
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
    };
}

fn rewriteKeyframes(
    context: *pass_manager.Context,
    input: *const ast.KeyframesBlock,
    config: *const Configuration,
    budget: *Budget,
    depth: usize,
) pass_manager.Error!RewrittenKeyframes {
    try budget.checkDepth(depth);
    if (input.frames.len == 0) return .{ .value = input, .changed = false };
    const scratch = context.scratchAllocator();
    const frames = try scratch.alloc(ast.KeyframeRule, input.frames.len);
    defer scratch.free(frames);
    var changed = false;
    for (input.frames, 0..) |frame, index| {
        _ = ast.KeyframeRule.init(frame) catch return error.InvalidAst;
        const declarations = try rewriteDeclarationList(
            context,
            frame.block.declarations,
            config,
            budget,
        );
        frames[index] = if (declarations.changed)
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
    const owned = try arena.dupe(ast.KeyframeRule, frames);
    const output = try arena.create(ast.KeyframesBlock);
    output.* = (if (input.raw_values) |raw|
        ast.KeyframesBlock.initWithRaw(input.envelope, raw, owned)
    else
        ast.KeyframesBlock.init(input.envelope, owned)) catch return error.InvalidAst;
    return .{ .value = output, .changed = true };
}

fn rewriteDeclarationList(
    context: *pass_manager.Context,
    input: ast.DeclarationList,
    config: *const Configuration,
    budget: *Budget,
) pass_manager.Error!RewrittenDeclarationList {
    input.validate() catch return error.InvalidAst;
    if (input.declarations.len == 0) return .{ .value = input, .changed = false };
    for (input.declarations) |declaration| {
        try budget.visitDeclaration();
        _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
    }
    for (input.generated_declarations) |proof| try validateExistingDeclarationProof(config, proof);
    const proofs = try generateDeclarationProofs(context, &input, config);
    if (proofs == null) return .{ .value = input, .changed = false };
    return .{
        .value = ast.DeclarationList.initWithGenerated(
            input.span,
            input.declarations,
            proofs.?,
        ) catch return error.InvalidAst,
        .changed = true,
    };
}

fn generateDeclarationProofs(
    context: *pass_manager.Context,
    input: *const ast.DeclarationList,
    config: *const Configuration,
) pass_manager.Error!?[]const ast.GeneratedDeclaration {
    const scratch = context.scratchAllocator();
    var output = try std.ArrayList(ast.GeneratedDeclaration).initCapacity(scratch, 0);
    defer output.deinit(scratch);
    var authored: [declaration_feature_count]?bool = .{null} ** declaration_feature_count;
    var existing_index: usize = 0;
    var index: usize = 0;
    var added = false;
    while (index < input.declarations.len) {
        if (existing_index < input.generated_declarations.len and
            input.generated_declarations[existing_index].first_declaration == index)
        {
            const proof = input.generated_declarations[existing_index];
            try output.append(scratch, proof);
            index += proof.kind.inputCount();
            existing_index += 1;
            continue;
        }
        if (existing_index < input.generated_declarations.len and
            input.generated_declarations[existing_index].first_declaration < index)
        {
            return error.InvalidAst;
        }
        const feature = try matchingDeclarationFeature(
            context,
            input.declarations[index],
            config,
        );
        if (feature) |value| {
            const feature_index = @intFromEnum(value);
            if (authored[feature_index] == null) {
                authored[feature_index] = rewrite_analysis.declarationListHasAuthoredForm(
                    scratch,
                    context.file(),
                    input,
                    value,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidAst,
                };
            }
            if (!authored[feature_index].?) {
                const forms = try context.arenaAllocator().dupe(
                    ast.CompatibilityForm,
                    config.declaration(value).forms(),
                );
                try output.append(scratch, .{
                    .kind = .compatibility,
                    .first_declaration = index,
                    .source_span = input.declarations[index].span,
                    .compatibility = .{ .feature = value, .forms = forms },
                });
                added = true;
            }
        }
        index += 1;
    }
    if (existing_index != input.generated_declarations.len) return error.InvalidAst;
    if (!added) return null;
    return @as([]const ast.GeneratedDeclaration, try context.arenaAllocator().dupe(
        ast.GeneratedDeclaration,
        output.items,
    ));
}

fn matchingDeclarationFeature(
    context: *pass_manager.Context,
    declaration: ast.Declaration,
    config: *const Configuration,
) pass_manager.Error!?ast.CompatibilityDeclarationFeature {
    for (declaration_descriptors) |descriptor| {
        const feature = descriptor.feature;
        if (!config.declaration(feature).actionable()) continue;
        const matches = rewrite_analysis.declarationMatchesFeature(
            context.scratchAllocator(),
            context.file(),
            declaration,
            feature,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAst,
        };
        if (matches) return feature;
    }
    return null;
}

fn generateRuleProofs(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    config: *const Configuration,
) pass_manager.Error!?[]const ast.GeneratedRule {
    const scratch = context.scratchAllocator();
    var output = try std.ArrayList(ast.GeneratedRule).initCapacity(scratch, 0);
    defer output.deinit(scratch);
    var authored: [rule_feature_count]?bool = .{null} ** rule_feature_count;
    var existing_index: usize = 0;
    var index: usize = 0;
    var added = false;
    while (index < input.rules.len) {
        if (existing_index < input.generated_rules.len and
            input.generated_rules[existing_index].first_rule == index)
        {
            const proof = input.generated_rules[existing_index];
            try output.append(scratch, proof);
            index += proof.kind.inputCount();
            existing_index += 1;
            continue;
        }
        if (existing_index < input.generated_rules.len and
            input.generated_rules[existing_index].first_rule < index)
        {
            return error.InvalidAst;
        }
        const feature = matchingRuleFeature(input.rules[index], config);
        if (feature) |value| {
            const feature_index = @intFromEnum(value);
            if (authored[feature_index] == null) {
                authored[feature_index] = rewrite_analysis.ruleListHasAuthoredForm(input, value);
            }
            if (!authored[feature_index].?) {
                const forms = try context.arenaAllocator().dupe(
                    ast.CompatibilityForm,
                    config.rule(value).forms(),
                );
                try output.append(scratch, .{
                    .kind = .compatibility,
                    .first_rule = index,
                    .source_span = input.rules[index].span(),
                    .compatibility = .{ .feature = value, .forms = forms },
                });
                added = true;
            }
        }
        index += 1;
    }
    if (existing_index != input.generated_rules.len) return error.InvalidAst;
    if (!added) return null;
    return @as([]const ast.GeneratedRule, try context.arenaAllocator().dupe(
        ast.GeneratedRule,
        output.items,
    ));
}

fn matchingRuleFeature(
    rule: ast.Rule,
    config: *const Configuration,
) ?ast.CompatibilityRuleFeature {
    for (rule_descriptors) |descriptor| {
        const feature = descriptor.feature;
        if (config.rule(feature).actionable() and rewrite_analysis.ruleMatchesFeature(rule, feature)) {
            return feature;
        }
    }
    return null;
}

fn validateExistingDeclarationProof(
    config: *const Configuration,
    proof: ast.GeneratedDeclaration,
) pass_manager.Error!void {
    if (proof.kind != .compatibility) return;
    const value = proof.compatibility orelse return error.InvalidAst;
    if (!std.mem.eql(
        ast.CompatibilityForm,
        value.forms,
        config.declaration(value.feature).forms(),
    )) return error.PassFailed;
}

fn validateExistingRuleProof(
    config: *const Configuration,
    proof: ast.GeneratedRule,
) pass_manager.Error!void {
    if (proof.kind != .compatibility) return;
    const value = proof.compatibility orelse return error.InvalidAst;
    if (!std.mem.eql(
        ast.CompatibilityForm,
        value.forms,
        config.rule(value.feature).forms(),
    )) return error.PassFailed;
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

fn nextDepth(depth: usize) pass_manager.Error!usize {
    return std.math.add(usize, depth, 1) catch error.PassFailed;
}

pub fn definition(config: *const Configuration) pass_manager.Pass {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .compatibility,
            .safety = .compatibility_rewrite,
            .maturity = .verified,
            .precondition = "the target configuration is parsed and pinned, and the source-matched AST is valid, diagnostic-free, emittable, and free of conflicting authored vendor forms at an eligible list",
            .postcondition = "only exact reviewed property, value, selector, and keyframes forms receive target-required closed vendor fallbacks immediately before the retained authored standard syntax",
            .no_op_conditions = "modern-only, unsupported, partial, annotated, manually prefixed, mixed selector-list, functional-pseudo, descriptor, recovered, omitted, conflicting, already-generated, and unsupported-value inputs retain their authored compatibility boundary",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "each expansion stays at its authored declaration or rule position, retains all authored relative order, emits vendor fallbacks in deterministic target order, and leaves the standard form last",
            .acceptance = .{
                .postcondition = true,
                .idempotence = true,
                .allocation_failures = true,
                .nested_rules = true,
                .semantic_validation = true,
                .differential_validation = true,
                .order_validation = true,
            },
        },
        .run = run,
        .validate = validate,
        .user_data = @ptrCast(@constCast(config)),
    };
}

/// Applies only the closed verified target-prefix pass under its exact
/// compatibility-rewrite authority. Callers retain ownership of both the
/// parsed stylesheet and the canonical borrowed target query.
pub fn applyToStylesheet(
    allocator: std.mem.Allocator,
    parsed: *pipeline.ParsedStylesheet,
    query: *const target_query.Query,
) !void {
    if (parsed.hasErrors()) return error.InputHasErrors;
    const config = try Configuration.init(allocator, query);
    const registry = [_]pass_manager.Pass{definition(&config)};
    var plan = try pass_manager.buildPlan(
        allocator,
        &registry,
        &.{id},
        .{ .allow_compatibility_rewrite = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{});
}

fn configFromUserData(user_data: ?*anyopaque) pass_manager.Error!*const Configuration {
    const pointer = user_data orelse return error.PassFailed;
    return @ptrCast(@alignCast(pointer));
}

fn run(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    const config = try configFromUserData(user_data);
    return (try rewrite(context, input, config, .{})).value;
}

fn validate(
    user_data: ?*anyopaque,
    phase: pass_manager.ValidationPhase,
    context: *pass_manager.Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) pass_manager.Error!void {
    const config = configFromUserData(user_data) catch return error.ValidationFailed;
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
        .postcondition => {
            const expected = try rewrite(context, before, config, .{});
            if (expected.changed != (before != after)) return error.ValidationFailed;
            const same = equivalence.equivalent(
                context.scratchAllocator(),
                context.file(),
                before,
                context.file(),
                after,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ValidationFailed,
            };
            if (!same) return error.ValidationFailed;
            try validateSameEmission(context, expected.value, after);
        },
        .idempotence => {
            if (before != after) return error.ValidationFailed;
            try validateEmittable(context, before);
        },
    }
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

fn parseTestQuery(allocator: std.mem.Allocator, input: []const u8) !target_query.Query {
    const parsed = try target_query.parse(allocator, input, .{});
    return switch (parsed) {
        .query => |query| query,
        .invalid => error.TestUnexpectedResult,
    };
}

test "target prefix configuration preserves safe per-target forms and conservative qualifiers" {
    var query = try parseTestQuery(
        std.testing.allocator,
        "chrome >= 22, edge >= 17, firefox >= 10, safari >= 7, ie >= 11",
    );
    defer query.deinit();
    const config = try Configuration.init(std.testing.allocator, &query);

    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{ .webkit, .moz },
        config.declaration(.appearance).forms(),
    );
    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{ .webkit, .moz, .ms },
        config.declaration(.user_select).forms(),
    );
    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{.webkit},
        config.declaration(.backdrop_filter).forms(),
    );
    try std.testing.expect(config.declaration(.display_flex).partial);
    try std.testing.expect(config.declaration(.display_flex).annotated);
    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{.webkit},
        config.declaration(.display_flex).forms(),
    );
    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{ .webkit, .moz, .ms },
        config.rule(.fullscreen).forms(),
    );
    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{ .webkit, .moz },
        config.rule(.keyframes).forms(),
    );

    var qualified_query = try parseTestQuery(
        std.testing.allocator,
        "safari >= 15, ios_safari >= 15",
    );
    defer qualified_query.deinit();
    const qualified = try Configuration.init(std.testing.allocator, &qualified_query);
    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{.webkit},
        qualified.rule(.fullscreen).forms(),
    );
    try std.testing.expect(qualified.rule(.fullscreen).partial);
    try std.testing.expect(qualified.rule(.fullscreen).annotated);

    var historical_query = try parseTestQuery(std.testing.allocator, "safari >= 2");
    defer historical_query.deinit();
    const historical = try Configuration.init(std.testing.allocator, &historical_query);
    try std.testing.expectEqualSlices(
        ast.CompatibilityForm,
        &.{ .khtml, .webkit },
        historical.declaration(.user_select).forms(),
    );

    var modern_query = try parseTestQuery(
        std.testing.allocator,
        "chrome >= 120, edge >= 120, firefox >= 120",
    );
    defer modern_query.deinit();
    const modern = try Configuration.init(std.testing.allocator, &modern_query);
    for (modern.declarations) |decision| try std.testing.expect(!decision.actionable());
    for (modern.rules) |decision| try std.testing.expect(!decision.actionable());
}

test "modern target configuration leaves the exact root unchanged" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "target-prefix-modern.css",
        ".a::placeholder{appearance:none;backdrop-filter:blur(1px);position:sticky;display:flex}" ++
            "@keyframes f{from{user-select:none}}",
    );
    defer parsed.deinit();
    var query = try parseTestQuery(
        std.testing.allocator,
        "chrome >= 120, edge >= 120, firefox >= 120",
    );
    defer query.deinit();
    const config = try Configuration.init(std.testing.allocator, &query);
    var context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    const result = try rewrite(&context, parsed.rules, &config, .{});
    try std.testing.expect(!result.changed);
    try std.testing.expect(result.value == parsed.rules);

    const registry = [_]pass_manager.Pass{definition(&config)};
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{id},
        .{ .allow_compatibility_rewrite = true },
    );
    defer plan.deinit();
    const validated = try plan.run(&context, parsed.rules, .{ .verify_idempotence = true });
    try std.testing.expect(validated == parsed.rules);
    try std.testing.expectEqual(@as(usize, 1), context.structuralProofEmitCount());
}

test "target prefix pass expands every reviewed category in place and is idempotent" {
    const css = ".a{appearance:none;user-select:none!important;backdrop-filter:blur(1px);" ++
        "position:sticky;display:flex;--keep:var(--x)}" ++
        "input::placeholder{appearance:auto}" ++
        ":fullscreen{user-select:text}" ++
        "@media all{textarea::placeholder{position:sticky}}" ++
        "@keyframes spin{from{user-select:none;position:sticky}to{display:flex}}" ++
        "@font-face{appearance:none}";
    var parsed = try pipeline.parse(std.testing.allocator, "target-prefix-all.css", css);
    defer parsed.deinit();
    var query = try parseTestQuery(
        std.testing.allocator,
        "chrome >= 22, edge >= 17, firefox >= 10, safari >= 7, ie >= 11",
    );
    defer query.deinit();
    const config = try Configuration.init(std.testing.allocator, &query);
    const registry = [_]pass_manager.Pass{definition(&config)};
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{id},
        .{ .allow_compatibility_rewrite = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    const root = parsed.rules;
    try std.testing.expectEqual(@as(usize, 3), root.generated_rules.len);
    const declarations = root.rules[0].style_rule.block.declarations;
    try std.testing.expectEqual(@as(usize, 5), declarations.generated_declarations.len);
    const font_face = root.rules[5].at_rule.block.declarations;
    try std.testing.expectEqual(@as(usize, 0), font_face.declarations.generated_declarations.len);

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try expectOrdered(result.css, &.{
        "-webkit-appearance:none",
        "-moz-appearance:none",
        "appearance:none",
    });
    try expectOrdered(result.css, &.{
        "-webkit-user-select:none!important",
        "-moz-user-select:none!important",
        "-ms-user-select:none!important",
        "user-select:none!important",
    });
    try expectOrdered(result.css, &.{
        "position:-webkit-sticky",
        "position:sticky",
        "display:-webkit-flex",
        "display:flex",
    });
    try expectOrdered(result.css, &.{
        "input::-webkit-input-placeholder",
        "input::placeholder",
        ":-webkit-full-screen",
        ":-moz-full-screen",
        ":-ms-fullscreen",
        ":fullscreen",
    });
    try expectOrdered(result.css, &.{
        "@-webkit-keyframes spin",
        "@-moz-keyframes spin",
        "@keyframes spin",
    });
    try std.testing.expect(std.mem.indexOf(u8, result.css, "-webkit-backdrop-filter:blur(1px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "-ms-flexbox") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "--keep:var(--x)") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.css, "@font-face{appearance:none}"));

    var reparsed = try pipeline.parse(std.testing.allocator, "target-prefix-all-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), reparsed.compilation.diagnostics.items().len);
}

test "target prefix pass declines manual mixed functional qualified and unsupported boundaries" {
    const css = ".a{-webkit-appearance:none;appearance:none;display:block;" ++
        "position:var(--position);--x:sticky}" ++
        ".plain,input::placeholder{color:red}" ++
        "input::-webkit-input-placeholder{color:red}" ++
        "input::placeholder{color:red}" ++
        ":is(input::placeholder){color:red}" ++
        "@-webkit-keyframes spin{from{opacity:0}}" ++
        "@keyframes spin{from{opacity:0}}";
    var parsed = try pipeline.parse(std.testing.allocator, "target-prefix-noop.css", css);
    defer parsed.deinit();
    const original = parsed.rules;
    var query = try parseTestQuery(
        std.testing.allocator,
        "chrome >= 22, edge >= 17, firefox >= 10, safari >= 7, ie >= 11",
    );
    defer query.deinit();
    const config = try Configuration.init(std.testing.allocator, &query);
    const registry = [_]pass_manager.Pass{definition(&config)};
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{id},
        .{ .allow_compatibility_rewrite = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    try std.testing.expect(parsed.rules == original);
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(css, result.css);
}

test "target prefix rewrite enforces depth rule and declaration budgets" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "target-prefix-limits.css",
        "@media all{.a{appearance:none}.b{user-select:none}}",
    );
    defer parsed.deinit();
    var query = try parseTestQuery(std.testing.allocator, "chrome >= 22");
    defer query.deinit();
    const config = try Configuration.init(std.testing.allocator, &query);
    var context = try pass_manager.Context.init(
        &parsed.compilation,
        parsed.source_id,
        std.testing.allocator,
    );
    try std.testing.expectError(
        error.PassFailed,
        rewrite(&context, parsed.rules, &config, .{ .max_depth = 0 }),
    );
    try std.testing.expectError(
        error.PassFailed,
        rewrite(&context, parsed.rules, &config, .{ .max_rules = 1 }),
    );
    try std.testing.expectError(
        error.PassFailed,
        rewrite(&context, parsed.rules, &config, .{ .max_declarations = 1 }),
    );
}

test "target prefix proofs compose with shorthand rule merges and omissions" {
    const duplicate_declarations = @import("../transform/duplicate_declarations.zig");
    const empty_cleanup = @import("../transform/empty_cleanup.zig");
    const selector_rule_merge = @import("../transform/selector_rule_merge.zig");
    const at_rule_merge = @import("../transform/at_rule_merge.zig");
    const shorthand_synthesis = @import("../transform/shorthand_synthesis.zig");

    var query = try parseTestQuery(
        std.testing.allocator,
        "chrome >= 22, edge >= 17, firefox >= 10, safari >= 7, ie >= 11",
    );
    defer query.deinit();
    const config = try Configuration.init(std.testing.allocator, &query);

    var declarations = try pipeline.parse(
        std.testing.allocator,
        "target-prefix-compose-declarations.css",
        ".a{margin-top:1px;margin-right:1px;margin-bottom:1px;margin-left:1px;" ++
            "appearance:var(--appearance)}",
    );
    defer declarations.deinit();
    const declaration_registry = [_]pass_manager.Pass{
        duplicate_declarations.definition(),
        shorthand_synthesis.definition(),
        definition(&config),
    };
    var declaration_plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &declaration_registry,
        &.{ shorthand_synthesis.id, id },
        .{
            .allow_semantic_rewrite = true,
            .allow_compatibility_rewrite = true,
        },
    );
    defer declaration_plan.deinit();
    try declarations.applyPassPlan(
        std.testing.allocator,
        &declaration_plan,
        .{ .verify_idempotence = true },
    );
    const declaration_proofs = declarations.rules.rules[0].style_rule.block.declarations.generated_declarations;
    try std.testing.expectEqual(@as(usize, 2), declaration_proofs.len);
    try std.testing.expectEqual(ast.GeneratedDeclarationKind.margin, declaration_proofs[0].kind);
    try std.testing.expectEqual(ast.GeneratedDeclarationKind.compatibility, declaration_proofs[1].kind);
    var declaration_output = try declarations.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer declaration_output.deinit();
    try std.testing.expectEqualStrings(
        ".a{margin:1px;-webkit-appearance:var(--appearance);" ++
            "-moz-appearance:var(--appearance);appearance:var(--appearance)}",
        declaration_output.css,
    );

    var rules = try pipeline.parse(
        std.testing.allocator,
        "target-prefix-compose-rules.css",
        ".m1{x:1}.m2{x:1}.host{@media all{.a{x:1}}@media all{.b{y:2}}}" ++
            "input::placeholder{appearance:none}",
    );
    defer rules.deinit();
    const rule_registry = [_]pass_manager.Pass{
        at_rule_merge.definition(),
        selector_rule_merge.definition(),
        definition(&config),
    };
    var rule_plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &rule_registry,
        &.{ selector_rule_merge.id, at_rule_merge.id, id },
        .{
            .allow_semantic_rewrite = true,
            .allow_compatibility_rewrite = true,
        },
    );
    defer rule_plan.deinit();
    try rules.applyPassPlan(std.testing.allocator, &rule_plan, .{ .verify_idempotence = true });
    try std.testing.expectEqual(@as(usize, 2), rules.rules.generated_rules.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        rules.rules.rules[2].style_rule.block.rules.generated_rules.len,
    );
    var rule_output = try rules.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer rule_output.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rule_output.css, ".m1,.m2{x:1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rule_output.css, "@media all{.a{x:1}.b{y:2}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rule_output.css, "input::-webkit-input-placeholder") != null);

    var omissions = try pipeline.parse(
        std.testing.allocator,
        "target-prefix-compose-omissions.css",
        ".empty{}input::placeholder{appearance:none}",
    );
    defer omissions.deinit();
    const omission_registry = [_]pass_manager.Pass{
        empty_cleanup.definition(),
        definition(&config),
    };
    var omission_plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &omission_registry,
        &.{ empty_cleanup.id, id },
        .{
            .allow_lossless_cleanup = true,
            .allow_compatibility_rewrite = true,
        },
    );
    defer omission_plan.deinit();
    try omissions.applyPassPlan(std.testing.allocator, &omission_plan, .{ .verify_idempotence = true });
    try std.testing.expectEqual(@as(usize, 1), omissions.rules.omitted_rules.len);
    try std.testing.expectEqual(@as(usize, 1), omissions.rules.generated_rules.len);
    var omission_output = try omissions.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer omission_output.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        omission_output.css,
        "input::-webkit-input-placeholder",
    ));
}

fn exerciseConfigurationAllocationFailures(allocator: std.mem.Allocator) !void {
    var query = try parseTestQuery(
        allocator,
        "chrome >= 22, edge >= 17, firefox >= 10, safari >= 7, ie >= 11",
    );
    defer query.deinit();
    const config = try Configuration.init(allocator, &query);
    try std.testing.expect(config.declaration(.appearance).actionable());
}

test "target prefix configuration handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseConfigurationAllocationFailures,
        .{},
    );
}

fn exerciseRewriteAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "target-prefix-oom.css",
        ".a::placeholder{appearance:none;position:sticky}" ++
            "@media all{.b{user-select:none}}@keyframes f{from{display:flex}}",
    );
    defer parsed.deinit();
    var query = try parseTestQuery(allocator, "chrome >= 22, firefox >= 10");
    defer query.deinit();
    const config = try Configuration.init(allocator, &query);
    const registry = [_]pass_manager.Pass{definition(&config)};
    var plan = try pass_manager.buildPlan(
        allocator,
        &registry,
        &.{id},
        .{ .allow_compatibility_rewrite = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    var output = try parsed.emitResult(allocator, .{ .mode = .minified });
    defer output.deinit();
    try std.testing.expect(std.mem.indexOf(u8, output.css, "-webkit-appearance") != null);
}

test "target prefix pass handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRewriteAllocationFailures,
        .{},
    );
}

fn expectOrdered(haystack: []const u8, needles: []const []const u8) !void {
    var offset: usize = 0;
    for (needles) |needle| {
        const relative = std.mem.indexOf(u8, haystack[offset..], needle) orelse {
            return error.TestExpectedEqual;
        };
        offset += relative + needle.len;
    }
}
