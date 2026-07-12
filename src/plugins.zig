const std = @import("std");
const ast = @import("css/ast.zig");
const pass_manager = @import("transform/pass_manager.zig");

/// Native plugins are a trusted, in-process, Zig-only experimental surface.
/// This value is intentionally not a compatibility promise or ABI version.
pub const Stability = enum {
    experimental,
};

pub const stability: Stability = .experimental;
pub const id_namespace = "plugin.";

pub const Definition = pass_manager.Pass;
pub const Policy = pass_manager.Policy;
pub const Plan = pass_manager.Plan;

pub const Error = pass_manager.Error || error{
    InvalidPluginNamespace,
};

/// Every slice, metadata string, callback, and `user_data` pointer is borrowed
/// for the duration of synchronous plan construction and execution. The plan
/// owns only its ordered pointer slice and must not outlive the referenced
/// definitions, metadata, callbacks, or user data.
pub const ExperimentalOptions = struct {
    definitions: []const Definition = &.{},
    requested: []const []const u8 = &.{},
    policy: Policy = .{},
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    options: ExperimentalOptions,
) Error!Plan {
    try validateNamespace(options);
    return pass_manager.buildPlan(
        allocator,
        options.definitions,
        options.requested,
        options.policy,
    );
}

pub fn isNamespaced(id: []const u8) bool {
    return id.len > id_namespace.len and std.mem.startsWith(u8, id, id_namespace);
}

fn validateNamespace(options: ExperimentalOptions) Error!void {
    if (options.definitions.len > pass_manager.max_passes or
        options.requested.len > pass_manager.max_passes)
    {
        return error.TooManyPasses;
    }
    for (options.definitions) |definition| {
        if (definition.metadata.dependencies.len > pass_manager.max_passes) {
            return error.TooManyPasses;
        }
        if (!isNamespaced(definition.metadata.id)) return error.InvalidPluginNamespace;
        for (definition.metadata.dependencies) |dependency| {
            if (!isNamespaced(dependency)) return error.InvalidPluginNamespace;
        }
    }
    for (options.requested) |id| {
        if (!isNamespaced(id)) return error.InvalidPluginNamespace;
    }
}

fn testRun(
    _: ?*anyopaque,
    _: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    return input;
}

fn testValidate(
    _: ?*anyopaque,
    _: pass_manager.ValidationPhase,
    _: *pass_manager.Context,
    _: *const ast.RuleList,
    _: *const ast.RuleList,
) pass_manager.Error!void {}

fn testDefinition(id: []const u8, priority: u16) Definition {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .analysis,
            .priority = priority,
            .safety = .analysis,
            .maturity = .experimental,
            .precondition = "the input AST is valid",
            .postcondition = "the plugin records analysis without replacing the AST",
            .no_op_conditions = "analysis never changes CSS output",
            .supports_nested_rules = true,
        },
        .run = testRun,
        .validate = testValidate,
    };
}

test "plugin IDs dependencies and requests stay in an isolated namespace" {
    try std.testing.expectEqual(Stability.experimental, stability);
    try std.testing.expect(isNamespaced("plugin.example"));
    try std.testing.expect(!isNamespaced("plugin."));
    try std.testing.expect(!isNamespaced("target-prefix-rewrite"));

    const invalid_definition = [_]Definition{testDefinition("outside", 0)};
    try std.testing.expectError(
        error.InvalidPluginNamespace,
        buildPlan(std.testing.allocator, .{
            .definitions = &invalid_definition,
            .requested = &.{"outside"},
        }),
    );

    var dependency = testDefinition("plugin.dependent", 0);
    dependency.metadata.dependencies = &.{"empty-rule-cleanup"};
    const invalid_dependency = [_]Definition{dependency};
    try std.testing.expectError(
        error.InvalidPluginNamespace,
        buildPlan(std.testing.allocator, .{
            .definitions = &invalid_dependency,
            .requested = &.{"plugin.dependent"},
        }),
    );

    const valid = [_]Definition{testDefinition("plugin.valid", 0)};
    try std.testing.expectError(
        error.InvalidPluginNamespace,
        buildPlan(std.testing.allocator, .{
            .definitions = &valid,
            .requested = &.{"outside"},
        }),
    );

    var too_many_requests: [pass_manager.max_passes + 1][]const u8 = undefined;
    @memset(&too_many_requests, "plugin.valid");
    try std.testing.expectError(
        error.TooManyPasses,
        buildPlan(std.testing.allocator, .{
            .definitions = &valid,
            .requested = &too_many_requests,
        }),
    );

    var too_many_dependencies: [pass_manager.max_passes + 1][]const u8 = undefined;
    @memset(&too_many_dependencies, "plugin.valid");
    var dependency_limit = testDefinition("plugin.dependency-limit", 0);
    dependency_limit.metadata.dependencies = &too_many_dependencies;
    const dependency_limit_definitions = [_]Definition{dependency_limit};
    try std.testing.expectError(
        error.TooManyPasses,
        buildPlan(std.testing.allocator, .{
            .definitions = &dependency_limit_definitions,
            .requested = &.{"plugin.dependency-limit"},
        }),
    );
}

test "plugin plans require explicit maturity authority and order deterministically" {
    const definitions = [_]Definition{
        testDefinition("plugin.zeta", 10),
        testDefinition("plugin.alpha", 10),
        testDefinition("plugin.first", 1),
    };
    try std.testing.expectError(
        error.UnverifiedPass,
        buildPlan(std.testing.allocator, .{
            .definitions = &definitions,
            .requested = &.{"plugin.alpha"},
        }),
    );

    var plan = try buildPlan(std.testing.allocator, .{
        .definitions = &definitions,
        .requested = &.{ "plugin.zeta", "plugin.alpha", "plugin.first" },
        .policy = .{ .allow_experimental = true },
    });
    defer plan.deinit();
    const expected = [_][]const u8{ "plugin.first", "plugin.alpha", "plugin.zeta" };
    try std.testing.expectEqual(expected.len, plan.orderedPasses().len);
    for (expected, plan.orderedPasses()) |id, definition| {
        try std.testing.expectEqualStrings(id, definition.metadata.id);
    }
}

fn exercisePlanAllocationFailures(allocator: std.mem.Allocator) !void {
    const definitions = [_]Definition{
        testDefinition("plugin.alpha", 0),
        testDefinition("plugin.beta", 0),
    };
    var plan = try buildPlan(allocator, .{
        .definitions = &definitions,
        .requested = &.{ "plugin.beta", "plugin.alpha" },
        .policy = .{ .allow_experimental = true },
    });
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.orderedPasses().len);
}

test "plugin planning handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePlanAllocationFailures,
        .{},
    );
}
