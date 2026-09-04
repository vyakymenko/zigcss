const std = @import("std");
const ast = @import("../css/ast.zig");
const emitter = @import("../css/emitter.zig");
const pass_manager = @import("pass_manager.zig");
const extraction_analysis = @import("selector_extraction_analysis.zig");

pub const dead_code_id = "conservative-dead-code-extraction";
pub const critical_css_id = "conservative-critical-css-extraction";

pub const ConfigError = std.mem.Allocator.Error || error{
    DuplicateEntry,
    InvalidInventory,
    InvalidLimits,
    InventoryLimitExceeded,
};

pub const Inventory = struct {
    /// Non-null means this is the exhaustive decoded class-token inventory for
    /// the document or closed critical selector-matching tree. Null means
    /// unknown, not empty.
    classes: ?[]const []const u8 = null,
    /// Non-null means this is the exhaustive decoded ID-value inventory for
    /// the document or closed critical selector-matching tree. Null means
    /// unknown, not empty.
    ids: ?[]const []const u8 = null,
};

pub const Options = struct {
    max_inventory_entries: usize = ast.max_extraction_inventory_entries,
    max_inventory_entry_bytes: usize = ast.max_extraction_inventory_entry_bytes,
    max_inventory_bytes: usize = ast.max_extraction_inventory_bytes,
    max_depth: usize = 256,
    max_rules: usize = 100_000,
    max_proofs: usize = 100_000,
};

pub const Configuration = struct {
    allocator: std.mem.Allocator,
    mode: ast.ExtractionMode,
    inventory: ast.CompleteSelectorInventory,
    options: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: ast.ExtractionMode,
        input: Inventory,
        options: Options,
    ) ConfigError!Configuration {
        if (input.classes == null and input.ids == null) return error.InvalidInventory;
        if (options.max_inventory_entries == 0 or
            options.max_inventory_entry_bytes == 0 or
            options.max_inventory_bytes == 0 or
            options.max_depth == 0 or
            options.max_rules == 0 or
            options.max_proofs == 0 or
            options.max_inventory_entries > ast.max_extraction_inventory_entries or
            options.max_inventory_entry_bytes > ast.max_extraction_inventory_entry_bytes or
            options.max_inventory_bytes > ast.max_extraction_inventory_bytes)
        {
            return error.InvalidLimits;
        }

        var result = Configuration{
            .allocator = allocator,
            .mode = mode,
            .inventory = .{},
            .options = options,
        };
        errdefer result.deinit();
        var budget = InventoryBudget{};
        if (input.classes) |classes| {
            result.inventory.classes = try cloneCategory(
                allocator,
                classes,
                options,
                &budget,
            );
        }
        if (input.ids) |ids| {
            result.inventory.ids = try cloneCategory(
                allocator,
                ids,
                options,
                &budget,
            );
        }
        ast.validateCompleteSelectorInventory(result.inventory) catch {
            return error.InvalidInventory;
        };
        return result;
    }

    pub fn deinit(self: *Configuration) void {
        freeCategory(self.allocator, self.inventory.classes);
        freeCategory(self.allocator, self.inventory.ids);
        self.inventory = .{};
    }

    pub fn passId(self: *const Configuration) []const u8 {
        return switch (self.mode) {
            .dead_code => dead_code_id,
            .critical_css => critical_css_id,
        };
    }
};

const InventoryBudget = struct {
    entries: usize = 0,
    bytes: usize = 0,
};

fn cloneCategory(
    allocator: std.mem.Allocator,
    input: []const []const u8,
    options: Options,
    budget: *InventoryBudget,
) ConfigError![]const []const u8 {
    budget.entries = std.math.add(usize, budget.entries, input.len) catch {
        return error.InventoryLimitExceeded;
    };
    if (budget.entries > options.max_inventory_entries) return error.InventoryLimitExceeded;

    const output = try allocator.alloc([]const u8, input.len);
    var initialized: usize = 0;
    errdefer {
        for (output[0..initialized]) |entry| allocator.free(entry);
        allocator.free(output);
    }
    for (input, 0..) |entry, index| {
        if (entry.len == 0) return error.InvalidInventory;
        if (entry.len > options.max_inventory_entry_bytes) return error.InventoryLimitExceeded;
        budget.bytes = std.math.add(usize, budget.bytes, entry.len) catch {
            return error.InventoryLimitExceeded;
        };
        if (budget.bytes > options.max_inventory_bytes) return error.InventoryLimitExceeded;
        output[index] = try allocator.dupe(u8, entry);
        initialized += 1;
    }
    std.mem.sort([]const u8, output, {}, lessThanSelectorName);
    var index: usize = 1;
    while (index < output.len) : (index += 1) {
        if (ast.conservativeSelectorNameEqual(output[index - 1], output[index])) {
            return error.DuplicateEntry;
        }
    }
    return output;
}

fn lessThanSelectorName(_: void, left: []const u8, right: []const u8) bool {
    return ast.conservativeSelectorNameOrder(left, right) == .lt;
}

fn freeCategory(allocator: std.mem.Allocator, category: ?[]const []const u8) void {
    const entries = category orelse return;
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

pub fn definition(config: *const Configuration) pass_manager.Pass {
    return .{
        .metadata = .{
            .id = config.passId(),
            .revision = 1,
            .phase = .extraction,
            .safety = .extraction,
            .maturity = .experimental,
            .precondition = "the source-matched AST is valid and diagnostic-free, and each non-null class or ID category is an exhaustive decoded inventory for the declared document or closed critical selector-matching tree, including every node that combinators may inspect",
            .postcondition = "only style rules whose every selector alternative contains a direct required class or ID proven absent from a complete inventory produce zero output; all retained rules and dependency-bearing at-rules remain in source order",
            .no_op_conditions = "unknown inventory categories, any selector alternative not proven impossible, type/attribute-only selectors, functional-pseudo-only evidence, manually generated rule ranges, non-style rules, recovered syntax, and unsupported selector semantics remain authored",
            .supports_nested_rules = true,
            .order_effect = .preserves,
            .order_rationale = "the pass emits a source-ordered subset without sorting, merging, or moving any survivor",
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
        .user_data = @ptrCast(@constCast(config)),
    };
}

pub const Result = struct {
    value: *const ast.RuleList,
    changed: bool,
};

const Budget = struct {
    options: Options,
    rules: usize = 0,
    proofs: usize = 0,

    fn checkDepth(self: *const Budget, depth: usize) pass_manager.Error!void {
        if (depth > self.options.max_depth) return error.PassFailed;
    }

    fn visitRule(self: *Budget) pass_manager.Error!void {
        self.rules = std.math.add(usize, self.rules, 1) catch return error.PassFailed;
        if (self.rules > self.options.max_rules) return error.PassFailed;
    }

    fn addProof(self: *Budget) pass_manager.Error!void {
        self.proofs = std.math.add(usize, self.proofs, 1) catch return error.PassFailed;
        if (self.proofs > self.options.max_proofs) return error.PassFailed;
    }
};

const ProofCache = struct {
    value: ?ast.GeneratedExtractionRule = null,
};

const RewrittenRule = struct {
    value: ast.Rule,
    changed: bool,
};

pub fn extract(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    config: *const Configuration,
) pass_manager.Error!Result {
    ast.validateCompleteSelectorInventory(config.inventory) catch return error.PassFailed;
    var budget = Budget{ .options = config.options };
    var proof_cache = ProofCache{};
    return rewriteRuleList(context, input, config, &budget, &proof_cache, 0);
}

fn rewriteRuleList(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    config: *const Configuration,
    budget: *Budget,
    proof_cache: *ProofCache,
    depth: usize,
) pass_manager.Error!Result {
    try budget.checkDepth(depth);
    input.validate() catch return error.InvalidAst;
    if (input.rules.len == 0) return .{ .value = input, .changed = false };
    for (input.generated_rules) |proof| {
        try validateExistingProof(context, input, config, proof);
        try budget.addProof();
    }

    const scratch = context.scratchAllocator();
    const candidates = try scratch.alloc(ast.Rule, input.rules.len);
    defer scratch.free(candidates);
    var child_changed = false;
    for (input.rules, 0..) |rule, index| {
        try budget.visitRule();
        const candidate = try rewriteRule(
            context,
            rule,
            config,
            budget,
            proof_cache,
            depth,
        );
        candidates[index] = candidate.value;
        child_changed = child_changed or candidate.changed;
    }

    const candidate_list = ast.RuleList.initWithGeneratedRules(
        input.span,
        candidates,
        input.omitted_rules,
        input.generated_rules,
    ) catch return error.InvalidAst;
    const proofs = try generateProofs(
        context,
        &candidate_list,
        config,
        budget,
        proof_cache,
    );
    if (!child_changed and proofs == null) return .{ .value = input, .changed = false };

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
    proof_cache: *ProofCache,
    depth: usize,
) pass_manager.Error!RewrittenRule {
    return switch (input) {
        .style_rule => |style| blk: {
            _ = ast.StyleRule.init(style.*) catch return error.InvalidAst;
            if (extraction_analysis.ruleImpossibleAssumeValid(input, config.inventory)) {
                break :blk .{ .value = input, .changed = false };
            }
            const child = try rewriteRuleList(
                context,
                &style.block.rules,
                config,
                budget,
                proof_cache,
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
                .rules => |value| value,
                else => break :blk .{ .value = input, .changed = false },
            };
            const child = try rewriteRuleList(
                context,
                &old_block.rules,
                config,
                budget,
                proof_cache,
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
        .nested_declarations => .{ .value = input, .changed = false },
    };
}

fn generateProofs(
    context: *pass_manager.Context,
    input: *const ast.RuleList,
    config: *const Configuration,
    budget: *Budget,
    proof_cache: *ProofCache,
) pass_manager.Error!?[]const ast.GeneratedRule {
    const scratch = context.scratchAllocator();
    var output = try std.ArrayList(ast.GeneratedRule).initCapacity(scratch, input.generated_rules.len);
    defer output.deinit(scratch);
    var existing_index: usize = 0;
    var rule_index: usize = 0;
    var added = false;
    while (rule_index < input.rules.len) {
        if (existing_index < input.generated_rules.len and
            input.generated_rules[existing_index].first_rule == rule_index)
        {
            const existing = input.generated_rules[existing_index];
            try output.append(scratch, existing);
            rule_index += existing.kind.inputCount();
            existing_index += 1;
            continue;
        }
        if (existing_index < input.generated_rules.len and
            input.generated_rules[existing_index].first_rule < rule_index)
        {
            return error.InvalidAst;
        }
        const rule = input.rules[rule_index];
        if (extraction_analysis.ruleImpossibleAssumeValid(rule, config.inventory)) {
            try budget.addProof();
            try output.append(scratch, .{
                .kind = .extraction,
                .first_rule = rule_index,
                .source_span = rule.span(),
                .extraction = try proofFor(context, config, proof_cache),
            });
            added = true;
        }
        rule_index += 1;
    }
    if (existing_index != input.generated_rules.len) return error.InvalidAst;
    if (!added) return null;
    return try context.arenaAllocator().dupe(ast.GeneratedRule, output.items);
}

fn proofFor(
    context: *pass_manager.Context,
    config: *const Configuration,
    cache: *ProofCache,
) std.mem.Allocator.Error!ast.GeneratedExtractionRule {
    if (cache.value) |value| return value;
    const arena = context.arenaAllocator();
    const value = ast.GeneratedExtractionRule{
        .mode = config.mode,
        .inventory = .{
            .classes = if (config.inventory.classes) |entries|
                try cloneCategoryIntoArena(arena, entries)
            else
                null,
            .ids = if (config.inventory.ids) |entries|
                try cloneCategoryIntoArena(arena, entries)
            else
                null,
        },
    };
    cache.value = value;
    return value;
}

fn cloneCategoryIntoArena(
    arena: std.mem.Allocator,
    input: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const output = try arena.alloc([]const u8, input.len);
    for (input, 0..) |entry, index| output[index] = try arena.dupe(u8, entry);
    return output;
}

fn validateExistingProof(
    context: *pass_manager.Context,
    list: *const ast.RuleList,
    config: *const Configuration,
    proof: ast.GeneratedRule,
) pass_manager.Error!void {
    if (proof.kind != .extraction) return;
    extraction_analysis.validateRuleExpansionAssumeListValid(context.file(), list, proof) catch |err| switch (err) {
        error.SourceMismatch, error.InvalidSpan, error.InvalidAst => return error.InvalidAst,
    };
    const extraction = proof.extraction orelse return error.InvalidAst;
    const expected = ast.GeneratedExtractionRule{
        .mode = config.mode,
        .inventory = config.inventory,
    };
    if (!extraction_analysis.extractionEqual(extraction, expected)) return error.PassFailed;
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
    return (try extract(context, input, config)).value;
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
            const expected = try extract(context, before, config);
            if (expected.changed != (before != after)) return error.ValidationFailed;
            try validateSameEmission(context, expected.value, after);
        },
        .idempotence => {
            if (before != after) return error.ValidationFailed;
            const expected = try extract(context, before, config);
            if (expected.changed or expected.value != before) return error.ValidationFailed;
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

const pipeline = @import("../css/pipeline.zig");
const sourcemap = @import("../sourcemap.zig");

fn applyConfiguration(
    allocator: std.mem.Allocator,
    parsed: *pipeline.ParsedStylesheet,
    config: *const Configuration,
) !void {
    const registry = [_]pass_manager.Pass{definition(config)};
    var plan = try pass_manager.buildPlan(
        allocator,
        &registry,
        &.{config.passId()},
        .{
            .allow_extraction = true,
            .allow_experimental = true,
        },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
}

test "configuration owns bounded complete class and ID inventories" {
    var class_name = [_]u8{ 'u', 's', 'e', 'd' };
    var id_name = [_]u8{ 'h', 'e', 'r', 'o' };
    const classes = [_][]const u8{class_name[0..]};
    const ids = [_][]const u8{id_name[0..]};
    var config = try Configuration.init(
        std.testing.allocator,
        .dead_code,
        .{ .classes = &classes, .ids = &ids },
        .{},
    );
    defer config.deinit();
    class_name[0] = 'x';
    id_name[0] = 'x';

    try std.testing.expectEqualStrings("used", config.inventory.classes.?[0]);
    try std.testing.expectEqualStrings("hero", config.inventory.ids.?[0]);
    try std.testing.expectEqualStrings(dead_code_id, config.passId());
    try ast.validateCompleteSelectorInventory(config.inventory);

    var empty = try Configuration.init(
        std.testing.allocator,
        .critical_css,
        .{ .classes = &.{}, .ids = &.{} },
        .{},
    );
    defer empty.deinit();
    try std.testing.expectEqualStrings(critical_css_id, empty.passId());

    var canonical = try Configuration.init(
        std.testing.allocator,
        .dead_code,
        .{ .classes = &.{ "zeta", "Alpha", "beta" } },
        .{},
    );
    defer canonical.deinit();
    try std.testing.expectEqualStrings("Alpha", canonical.inventory.classes.?[0]);
    try std.testing.expectEqualStrings("beta", canonical.inventory.classes.?[1]);
    try std.testing.expectEqualStrings("zeta", canonical.inventory.classes.?[2]);
    try std.testing.expectError(
        error.InvalidRule,
        ast.validateCompleteSelectorInventory(.{ .classes = &.{ "zeta", "alpha" } }),
    );

    try std.testing.expectError(
        error.InvalidInventory,
        Configuration.init(std.testing.allocator, .dead_code, .{}, .{}),
    );
    try std.testing.expectError(
        error.DuplicateEntry,
        Configuration.init(
            std.testing.allocator,
            .dead_code,
            .{ .classes = &.{ "Used", "used" } },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InventoryLimitExceeded,
        Configuration.init(
            std.testing.allocator,
            .dead_code,
            .{ .classes = &.{ "one", "two" } },
            .{ .max_inventory_entries = 1 },
        ),
    );
    try std.testing.expectError(
        error.InvalidLimits,
        Configuration.init(
            std.testing.allocator,
            .dead_code,
            .{ .classes = &.{} },
            .{ .max_depth = 0 },
        ),
    );
}

test "experimental extraction requires both explicit policy grants" {
    var config = try Configuration.init(
        std.testing.allocator,
        .critical_css,
        .{ .classes = &.{"critical"} },
        .{},
    );
    defer config.deinit();
    const pass = definition(&config);
    try std.testing.expectEqual(pass_manager.Maturity.experimental, pass.metadata.maturity);
    try std.testing.expectEqual(pass_manager.SafetyClass.extraction, pass.metadata.safety);
    try std.testing.expect(pass.metadata.claims_size_reduction);
    const registry = [_]pass_manager.Pass{pass};

    try std.testing.expectError(
        error.UnverifiedPass,
        pass_manager.buildPlan(
            std.testing.allocator,
            &registry,
            &.{critical_css_id},
            .{ .allow_extraction = true },
        ),
    );
    try std.testing.expectError(
        error.DisallowedSafetyClass,
        pass_manager.buildPlan(
            std.testing.allocator,
            &registry,
            &.{critical_css_id},
            .{ .allow_experimental = true },
        ),
    );
}

test "conservative extraction removes only all-impossible selector lists recursively" {
    const css = ".keep{x:1}.drop{x:2}.keep.drop{x:3}.drop,.keep{x:4}" ++
        ":not(.drop){x:5}:is(.drop){x:6}" ++
        "@media all{.drop{x:7}.keep{x:8}}" ++
        "@layer base{#gone{x:9}#hero{x:10}}" ++
        ".parent{color:red;.drop{y:1}.keep{y:2}}" ++
        "@font-face{font-family:x;src:url(x)}" ++
        "@keyframes f{from{opacity:0}}";
    var parsed = try pipeline.parse(std.testing.allocator, "selector-extraction.css", css);
    defer parsed.deinit();
    var config = try Configuration.init(
        std.testing.allocator,
        .dead_code,
        .{
            .classes = &.{ "keep", "parent" },
            .ids = &.{"hero"},
        },
        .{},
    );
    defer config.deinit();
    try applyConfiguration(std.testing.allocator, &parsed, &config);

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".keep{x:1}.drop,.keep{x:4}:not(.drop){x:5}:is(.drop){x:6}" ++
            "@media all{.keep{x:8}}@layer base{#hero{x:10}}" ++
            ".parent{color:red;.keep{y:2}}" ++
            "@font-face{font-family:x;src:url(x)}@keyframes f{from{opacity:0}}",
        result.css,
    );
    try std.testing.expect(result.css.len < css.len);

    var reparsed = try pipeline.parse(std.testing.allocator, "selector-extraction-output.css", result.css);
    defer reparsed.deinit();
    var repeated = try Configuration.init(
        std.testing.allocator,
        .dead_code,
        .{
            .classes = &.{ "keep", "parent" },
            .ids = &.{"hero"},
        },
        .{},
    );
    defer repeated.deinit();
    const root = reparsed.rules;
    try applyConfiguration(std.testing.allocator, &reparsed, &repeated);
    try std.testing.expect(reparsed.rules == root);
}

test "complete empty inventories can produce empty mapped output without whitespace" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "empty-extraction.css",
        ".gone{x:1}#also-gone{x:2}",
    );
    defer parsed.deinit();
    var config = try Configuration.init(
        std.testing.allocator,
        .critical_css,
        .{ .classes = &.{}, .ids = &.{} },
        .{},
    );
    defer config.deinit();
    try applyConfiguration(std.testing.allocator, &parsed, &config);

    var result = try parsed.emitResult(std.testing.allocator, .{
        .mode = .pretty,
        .source_map = .{
            .generated_file = "empty-extraction.out.css",
            .include_sources_content = true,
        },
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.css.len);
    try std.testing.expect(result.source_map != null);
    try std.testing.expect(std.mem.indexOf(u8, result.source_map.?, "empty-extraction.css") != null);
}

test "extraction source maps expose only surviving authored positions" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "mapped-extraction.css",
        ".drop{x:1}\n.keep{x:2}\n.gone{x:3}",
    );
    defer parsed.deinit();
    var config = try Configuration.init(
        std.testing.allocator,
        .dead_code,
        .{ .classes = &.{"keep"} },
        .{},
    );
    defer config.deinit();
    try applyConfiguration(std.testing.allocator, &parsed, &config);
    var result = try parsed.emitResult(std.testing.allocator, .{
        .mode = .minified,
        .source_map = .{ .generated_file = "mapped-extraction.out.css" },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(".keep{x:2}", result.css);
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
    defer if (mappings.len > 0) std.testing.allocator.free(mappings);
    try std.testing.expect(mappings.len > 0);
    for (mappings) |mapping| try std.testing.expectEqual(@as(u32, 1), mapping.original_line);
}

test "forged extraction omissions are rejected by emission and equivalence" {
    var parsed = try pipeline.parse(std.testing.allocator, "forged-extraction.css", ".keep{x:1}");
    defer parsed.deinit();
    const classes = [_][]const u8{"keep"};
    const proof = [_]ast.GeneratedRule{.{
        .kind = .extraction,
        .first_rule = 0,
        .source_span = parsed.rules.rules[0].span(),
        .extraction = .{
            .mode = .dead_code,
            .inventory = .{ .classes = &classes },
        },
    }};
    const forged = try ast.RuleList.initWithGeneratedRules(
        parsed.rules.span,
        parsed.rules.rules,
        parsed.rules.omitted_rules,
        &proof,
    );
    try std.testing.expectError(
        error.InvalidAst,
        emitter.emit(std.testing.allocator, parsed.file(), &forged, .{ .mode = .minified }),
    );
    const equivalence = @import("../css/equivalence.zig");
    try std.testing.expect(!try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        &forged,
        parsed.file(),
        parsed.rules,
    ));
}

test "extraction enforces traversal and proof budgets" {
    const cases = [_]struct {
        css: []const u8,
        options: Options,
    }{
        .{ .css = ".keep{.keep{.drop{x:1}}}", .options = .{ .max_depth = 1 } },
        .{ .css = ".keep{x:1}.drop{x:2}", .options = .{ .max_rules = 1 } },
        .{ .css = ".drop{x:1}.gone{x:2}", .options = .{ .max_proofs = 1 } },
    };
    for (cases) |case| {
        var parsed = try pipeline.parse(std.testing.allocator, "bounded-extraction.css", case.css);
        defer parsed.deinit();
        var config = try Configuration.init(
            std.testing.allocator,
            .dead_code,
            .{ .classes = &.{"keep"} },
            case.options,
        );
        defer config.deinit();
        const registry = [_]pass_manager.Pass{definition(&config)};
        var plan = try pass_manager.buildPlan(
            std.testing.allocator,
            &registry,
            &.{dead_code_id},
            .{ .allow_extraction = true, .allow_experimental = true },
        );
        defer plan.deinit();
        try std.testing.expectError(
            error.PassFailed,
            parsed.applyPassPlan(std.testing.allocator, &plan, .{}),
        );
    }
}

test "extraction composes with cleanup omissions and protects generated rule ranges" {
    const empty_cleanup = @import("empty_cleanup.zig");
    const selector_merge = @import("selector_rule_merge.zig");
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "composed-extraction.css",
        ".drop{x:1}.drop{x:1}.gone{y:2}.host{color:red;.empty{}}",
    );
    defer parsed.deinit();
    var config = try Configuration.init(
        std.testing.allocator,
        .dead_code,
        .{ .classes = &.{"host"} },
        .{},
    );
    defer config.deinit();
    const registry = [_]pass_manager.Pass{
        definition(&config),
        selector_merge.definition(),
        empty_cleanup.definition(),
    };
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{ empty_cleanup.id, selector_merge.id, dead_code_id },
        .{
            .allow_lossless_cleanup = true,
            .allow_semantic_rewrite = true,
            .allow_extraction = true,
            .allow_experimental = true,
        },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(".drop,.drop{x:1}.host{color:red}", result.css);
    try std.testing.expectEqual(@as(usize, 0), parsed.rules.omitted_rules.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.rules.generated_rules.len);
    try std.testing.expectEqual(ast.GeneratedRuleKind.selector_list_merge, parsed.rules.generated_rules[0].kind);
    try std.testing.expectEqual(ast.GeneratedRuleKind.extraction, parsed.rules.generated_rules[1].kind);
    try std.testing.expectEqual(
        @as(usize, 1),
        parsed.rules.rules[3].style_rule.block.rules.omitted_rules.len,
    );
}

fn exerciseExtractionAllocationFailures(allocator: std.mem.Allocator) !void {
    var config = try Configuration.init(
        allocator,
        .critical_css,
        .{ .classes = &.{ "keep", "parent" }, .ids = &.{"hero"} },
        .{},
    );
    defer config.deinit();
    var parsed = try pipeline.parse(
        allocator,
        "oom-selector-extraction.css",
        ".drop{x:1}.keep{x:2}@media all{.drop{x:3}.keep{x:4}}" ++
            ".parent{.drop{x:5}.keep{x:6}}#gone{x:7}#hero{x:8}",
    );
    defer parsed.deinit();
    try applyConfiguration(allocator, &parsed, &config);
    var result = try parsed.emitResult(allocator, .{
        .mode = .minified,
        .source_map = .{ .generated_file = "oom-selector-extraction.out.css" },
    });
    defer result.deinit();
    try std.testing.expect(result.css.len > 0);
}

test "configuration pass validation and emission handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExtractionAllocationFailures,
        .{},
    );
}
