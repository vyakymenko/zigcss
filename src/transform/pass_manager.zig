const std = @import("std");
const compilation = @import("../compilation.zig");
const ast = @import("../css/ast.zig");
const source = @import("../source.zig");

pub const max_passes: usize = 256;

pub const Error = std.mem.Allocator.Error || error{
    AnalysisMutatedOutput,
    DependencyCycle,
    DependencyPhaseViolation,
    DisallowedSafetyClass,
    DuplicateDependency,
    DuplicatePass,
    DuplicateRequest,
    InvalidAst,
    InvalidMetadata,
    InvalidPassId,
    InvalidSource,
    InputHasErrors,
    MissingAcceptanceEvidence,
    MissingValidator,
    NestedRulesUnsupported,
    OrderChangeDisallowed,
    PassFailed,
    PassReportedErrors,
    StaticCustomPropertyResolutionDisallowed,
    TooManyPasses,
    UnknownDependency,
    UnknownRequestedPass,
    UnverifiedPass,
    ValidationFailed,
};

pub const SafetyClass = enum {
    analysis,
    lossless_cleanup,
    semantic_rewrite,
    compatibility_rewrite,
    extraction,
};

pub const Maturity = enum {
    experimental,
    verified,
};

pub const Phase = enum {
    analysis,
    cleanup,
    values,
    declarations,
    rules,
    compatibility,
    extraction,
};

pub const OrderEffect = enum {
    preserves,
    proven_reorder,
};

pub const CustomPropertyEffect = enum {
    preserves,
    static_resolution,
};

pub const AcceptanceEvidence = struct {
    postcondition: bool = false,
    idempotence: bool = false,
    allocation_failures: bool = false,
    nested_rules: bool = false,
    semantic_validation: bool = false,
    differential_validation: bool = false,
    order_validation: bool = false,
    size_validation: bool = false,
};

pub const Metadata = struct {
    id: []const u8,
    revision: u32,
    phase: Phase,
    priority: u16 = 0,
    safety: SafetyClass,
    maturity: Maturity = .experimental,
    dependencies: []const []const u8 = &.{},
    precondition: []const u8,
    postcondition: []const u8,
    no_op_conditions: []const u8,
    supports_nested_rules: bool = false,
    custom_property_effect: CustomPropertyEffect = .preserves,
    order_effect: OrderEffect = .preserves,
    order_rationale: []const u8 = "",
    claims_size_reduction: bool = false,
    acceptance: AcceptanceEvidence = .{},
};

pub const ValidationPhase = enum {
    precondition,
    postcondition,
    idempotence,
};

pub const Context = struct {
    compilation: *compilation.Compilation,
    source_id: source.SourceId,
    scratch_allocator: std.mem.Allocator,

    pub fn init(
        compilation_context: *compilation.Compilation,
        source_id: source.SourceId,
        scratch_allocator: std.mem.Allocator,
    ) Error!Context {
        _ = compilation_context.sources.get(source_id) catch return error.InvalidSource;
        return .{
            .compilation = compilation_context,
            .source_id = source_id,
            .scratch_allocator = scratch_allocator,
        };
    }

    pub fn arenaAllocator(self: *Context) std.mem.Allocator {
        return self.compilation.arenaAllocator();
    }

    pub fn scratchAllocator(self: *Context) std.mem.Allocator {
        return self.scratch_allocator;
    }

    pub fn file(self: *Context) *const source.SourceFile {
        return self.compilation.sources.get(self.source_id) catch unreachable;
    }
};

pub const RunFn = *const fn (
    user_data: ?*anyopaque,
    context: *Context,
    input: *const ast.RuleList,
) Error!*const ast.RuleList;

pub const ValidateFn = *const fn (
    user_data: ?*anyopaque,
    phase: ValidationPhase,
    context: *Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) Error!void;

pub const Pass = struct {
    metadata: Metadata,
    run: RunFn,
    validate: ?ValidateFn = null,
    user_data: ?*anyopaque = null,
};

/// Defaults deny every output-changing class. Callers opt into exact classes;
/// enum ordering never broadens authority implicitly.
pub const Policy = struct {
    allow_analysis: bool = true,
    allow_lossless_cleanup: bool = false,
    allow_semantic_rewrite: bool = false,
    allow_compatibility_rewrite: bool = false,
    allow_extraction: bool = false,
    allow_experimental: bool = false,
    require_validator: bool = true,
    require_nested_rules: bool = true,
    allow_proven_reorder: bool = false,
    allow_static_custom_property_resolution: bool = false,

    fn allows(self: Policy, safety: SafetyClass) bool {
        return switch (safety) {
            .analysis => self.allow_analysis,
            .lossless_cleanup => self.allow_lossless_cleanup,
            .semantic_rewrite => self.allow_semantic_rewrite,
            .compatibility_rewrite => self.allow_compatibility_rewrite,
            .extraction => self.allow_extraction,
        };
    }
};

pub const RunOptions = struct {
    /// Intended for tests/nightly validation. The second result is validated
    /// against the first but is not committed as the plan output.
    verify_idempotence: bool = false,
};

/// Owns only its ordered pointer slice. Pass definitions and user data remain
/// borrowed from the registry used to build the plan.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    passes: []const *const Pass,

    pub fn deinit(self: *Plan) void {
        if (self.passes.len > 0) self.allocator.free(self.passes);
        self.passes = &.{};
    }

    pub fn orderedPasses(self: *const Plan) []const *const Pass {
        return self.passes;
    }

    pub fn run(
        self: *const Plan,
        context: *Context,
        input: *const ast.RuleList,
        options: RunOptions,
    ) Error!*const ast.RuleList {
        if (hasErrors(context)) return error.InputHasErrors;
        const diagnostic_checkpoint = context.compilation.diagnostics.items().len;
        errdefer context.compilation.diagnostics.truncate(diagnostic_checkpoint);
        try validateRoot(context, input);
        var current = input;

        for (self.passes) |pass| {
            if (pass.validate) |validate| {
                try validate(pass.user_data, .precondition, context, current, current);
            } else if (options.verify_idempotence) {
                return error.MissingValidator;
            }
            if (hasErrors(context)) return error.PassReportedErrors;

            const candidate = try pass.run(pass.user_data, context, current);
            if (hasErrors(context)) return error.PassReportedErrors;
            try validateRoot(context, candidate);
            if (pass.metadata.safety == .analysis and candidate != current) {
                return error.AnalysisMutatedOutput;
            }
            if (pass.validate) |validate| {
                try validate(pass.user_data, .postcondition, context, current, candidate);
            }
            if (hasErrors(context)) return error.PassReportedErrors;

            if (options.verify_idempotence) {
                const repeated = try pass.run(pass.user_data, context, candidate);
                try validateRoot(context, repeated);
                if (pass.metadata.safety == .analysis and repeated != candidate) {
                    return error.AnalysisMutatedOutput;
                }
                try pass.validate.?(pass.user_data, .idempotence, context, candidate, repeated);
                if (hasErrors(context)) return error.PassReportedErrors;
            }

            current = candidate;
        }
        return current;
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    registry: []const Pass,
    requested: []const []const u8,
    policy: Policy,
) Error!Plan {
    try validateRegistry(allocator, registry);

    for (requested, 0..) |id, index| {
        if (findPassIndex(registry, id) == null) return error.UnknownRequestedPass;
        for (requested[0..index]) |previous| {
            if (std.mem.eql(u8, previous, id)) return error.DuplicateRequest;
        }
    }

    if (registry.len == 0) {
        return .{ .allocator = allocator, .passes = &.{} };
    }

    const selected = try allocator.alloc(bool, registry.len);
    defer allocator.free(selected);
    @memset(selected, false);
    for (requested) |id| selected[findPassIndex(registry, id).?] = true;

    var changed = true;
    while (changed) {
        changed = false;
        for (registry, 0..) |pass, index| {
            if (!selected[index]) continue;
            for (pass.metadata.dependencies) |dependency| {
                const dependency_index = findPassIndex(registry, dependency).?;
                if (!selected[dependency_index]) {
                    selected[dependency_index] = true;
                    changed = true;
                }
            }
        }
    }

    var selected_count: usize = 0;
    for (registry, 0..) |*pass, index| {
        if (!selected[index]) continue;
        selected_count += 1;
        try enforcePolicy(pass, policy);
    }
    if (selected_count == 0) {
        return .{ .allocator = allocator, .passes = &.{} };
    }

    const ordered = try allocator.alloc(*const Pass, selected_count);
    errdefer allocator.free(ordered);
    const emitted = try allocator.alloc(bool, registry.len);
    defer allocator.free(emitted);
    @memset(emitted, false);

    for (ordered) |*slot| {
        var best: ?usize = null;
        for (registry, 0..) |*candidate, index| {
            if (!selected[index] or emitted[index] or !dependenciesEmitted(registry, candidate, emitted)) continue;
            if (best == null or precedes(candidate, &registry[best.?])) best = index;
        }
        const index = best orelse return error.DependencyCycle;
        slot.* = &registry[index];
        emitted[index] = true;
    }

    return .{ .allocator = allocator, .passes = ordered };
}

fn validateRegistry(allocator: std.mem.Allocator, registry: []const Pass) Error!void {
    if (registry.len > max_passes) return error.TooManyPasses;
    for (registry, 0..) |*pass, index| {
        try validateMetadata(pass);
        for (registry[0..index]) |previous| {
            if (std.mem.eql(u8, previous.metadata.id, pass.metadata.id)) return error.DuplicatePass;
        }
        for (pass.metadata.dependencies, 0..) |dependency, dependency_index| {
            if (!validId(dependency)) return error.InvalidPassId;
            for (pass.metadata.dependencies[0..dependency_index]) |previous| {
                if (std.mem.eql(u8, previous, dependency)) return error.DuplicateDependency;
            }
            const required_index = findPassIndex(registry, dependency) orelse return error.UnknownDependency;
            if (@intFromEnum(registry[required_index].metadata.phase) > @intFromEnum(pass.metadata.phase)) {
                return error.DependencyPhaseViolation;
            }
        }
    }
    try ensureAcyclic(allocator, registry);
}

fn validateMetadata(pass: *const Pass) Error!void {
    const metadata = pass.metadata;
    if (!validId(metadata.id)) return error.InvalidPassId;
    if (metadata.revision == 0 or
        emptyDocumentation(metadata.precondition) or
        emptyDocumentation(metadata.postcondition) or
        emptyDocumentation(metadata.no_op_conditions) or
        !phaseMatchesSafety(metadata.phase, metadata.safety))
    {
        return error.InvalidMetadata;
    }
    if (metadata.order_effect == .proven_reorder and emptyDocumentation(metadata.order_rationale)) {
        return error.InvalidMetadata;
    }
    if (metadata.custom_property_effect == .static_resolution and
        (metadata.maturity != .experimental or
            metadata.safety != .semantic_rewrite or
            metadata.phase != .values))
    {
        return error.InvalidMetadata;
    }
    if (metadata.order_effect == .proven_reorder and !metadata.acceptance.order_validation) {
        return error.MissingAcceptanceEvidence;
    }
    if (metadata.claims_size_reduction and !metadata.acceptance.size_validation) {
        return error.MissingAcceptanceEvidence;
    }

    if (metadata.maturity == .verified) {
        if (pass.validate == null) return error.MissingValidator;
        const evidence = metadata.acceptance;
        if (!metadata.supports_nested_rules or
            !evidence.postcondition or
            !evidence.idempotence or
            !evidence.allocation_failures or
            !evidence.nested_rules)
        {
            return error.MissingAcceptanceEvidence;
        }
        if (metadata.safety != .analysis and
            (!evidence.semantic_validation or !evidence.differential_validation))
        {
            return error.MissingAcceptanceEvidence;
        }
    }
}

fn enforcePolicy(pass: *const Pass, policy: Policy) Error!void {
    if (pass.metadata.maturity != .verified and !policy.allow_experimental) return error.UnverifiedPass;
    if (!policy.allows(pass.metadata.safety)) return error.DisallowedSafetyClass;
    if (policy.require_validator and pass.validate == null) return error.MissingValidator;
    if (policy.require_nested_rules and !pass.metadata.supports_nested_rules) return error.NestedRulesUnsupported;
    if (!policy.allow_proven_reorder and pass.metadata.order_effect == .proven_reorder) {
        return error.OrderChangeDisallowed;
    }
    if (!policy.allow_static_custom_property_resolution and
        pass.metadata.custom_property_effect == .static_resolution)
    {
        return error.StaticCustomPropertyResolutionDisallowed;
    }
}

fn ensureAcyclic(allocator: std.mem.Allocator, registry: []const Pass) Error!void {
    if (registry.len == 0) return;
    const emitted = try allocator.alloc(bool, registry.len);
    defer allocator.free(emitted);
    @memset(emitted, false);

    var count: usize = 0;
    while (count < registry.len) : (count += 1) {
        var ready: ?usize = null;
        for (registry, 0..) |*candidate, index| {
            if (emitted[index] or !dependenciesEmitted(registry, candidate, emitted)) continue;
            ready = index;
            break;
        }
        const index = ready orelse return error.DependencyCycle;
        emitted[index] = true;
    }
}

fn dependenciesEmitted(registry: []const Pass, pass: *const Pass, emitted: []const bool) bool {
    for (pass.metadata.dependencies) |dependency| {
        const index = findPassIndex(registry, dependency) orelse return false;
        if (!emitted[index]) return false;
    }
    return true;
}

fn precedes(left: *const Pass, right: *const Pass) bool {
    const left_phase = @intFromEnum(left.metadata.phase);
    const right_phase = @intFromEnum(right.metadata.phase);
    if (left_phase != right_phase) return left_phase < right_phase;
    if (left.metadata.priority != right.metadata.priority) return left.metadata.priority < right.metadata.priority;
    return std.mem.lessThan(u8, left.metadata.id, right.metadata.id);
}

fn findPassIndex(registry: []const Pass, id: []const u8) ?usize {
    for (registry, 0..) |pass, index| {
        if (std.mem.eql(u8, pass.metadata.id, id)) return index;
    }
    return null;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id, 0..) |byte, index| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or
            (index > 0 and (byte == '-' or byte == '_' or byte == '.'));
        if (!valid) return false;
    }
    return true;
}

fn phaseMatchesSafety(phase: Phase, safety: SafetyClass) bool {
    return switch (safety) {
        .analysis => phase == .analysis,
        .lossless_cleanup => phase == .cleanup,
        .semantic_rewrite => phase == .values or phase == .declarations or phase == .rules,
        .compatibility_rewrite => phase == .compatibility,
        .extraction => phase == .extraction,
    };
}

fn emptyDocumentation(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

fn validateRoot(context: *Context, rules: *const ast.RuleList) Error!void {
    if (!rules.span.source.eql(context.source_id)) return error.InvalidAst;
    rules.validate() catch return error.InvalidAst;
}

fn hasErrors(context: *Context) bool {
    for (context.compilation.diagnostics.items()) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

const equivalence = @import("../css/equivalence.zig");
const rule_parser = @import("../css/rule_parser.zig");
const syntax = @import("../syntax.zig");

const TestLog = struct {
    bytes: [16]u8 = undefined,
    len: usize = 0,

    fn append(self: *TestLog, byte: u8) Error!void {
        if (self.len == self.bytes.len) return error.PassFailed;
        self.bytes[self.len] = byte;
        self.len += 1;
    }
};

const TestState = struct {
    log: ?*TestLog = null,
    marker: u8 = 0,
    clone_output: bool = false,
    semantic_validation: bool = false,
    report_error: bool = false,
    runs: usize = 0,
    validations: [3]usize = .{0} ** 3,
    fail_phase: ?ValidationPhase = null,
};

fn testRun(user_data: ?*anyopaque, context: *Context, input: *const ast.RuleList) Error!*const ast.RuleList {
    const state: *TestState = @ptrCast(@alignCast(user_data.?));
    state.runs += 1;
    if (state.log) |log| try log.append(state.marker);
    if (state.report_error) {
        context.compilation.report(.err, .internal, input.span, "pass introduced an error") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PassFailed,
        };
    }
    if (!state.clone_output) return input;
    const cloned = context.arenaAllocator().create(ast.RuleList) catch return error.OutOfMemory;
    cloned.* = input.*;
    return cloned;
}

fn testValidate(
    user_data: ?*anyopaque,
    phase: ValidationPhase,
    context: *Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) Error!void {
    const state: *TestState = @ptrCast(@alignCast(user_data.?));
    state.validations[@intFromEnum(phase)] += 1;
    if (state.fail_phase == phase) return error.ValidationFailed;
    if (state.semantic_validation and phase != .precondition) {
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
    }
}

fn acceptedMetadata(id: []const u8, phase: Phase, safety: SafetyClass) Metadata {
    return .{
        .id = id,
        .revision = 1,
        .phase = phase,
        .safety = safety,
        .maturity = .verified,
        .precondition = "input AST is structurally valid",
        .postcondition = "output AST satisfies the pass contract",
        .no_op_conditions = "the pass returns the input when no candidate is eligible",
        .supports_nested_rules = true,
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
    };
}

fn testPass(metadata: Metadata, state: *TestState) Pass {
    return .{
        .metadata = metadata,
        .run = testRun,
        .validate = testValidate,
        .user_data = state,
    };
}

const ParsedTestStylesheet = struct {
    source_id: source.SourceId,
    rules: *const ast.RuleList,
};

fn parseTestStylesheet(context: *compilation.Compilation, css: []const u8) !ParsedTestStylesheet {
    const source_id = try context.addSource("passes.css", css);
    const document = try syntax.parse(context, source_id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    return .{ .source_id = source_id, .rules = try rule_parser.parse(context, source_id, values) };
}

test "pass plans include dependencies and order independently of registration order" {
    var analysis_state = TestState{};
    var cleanup_fast_state = TestState{};
    var cleanup_alpha_state = TestState{};
    var cleanup_zeta_state = TestState{};
    var rule_state = TestState{};
    var rule_metadata = acceptedMetadata("rule", .rules, .semantic_rewrite);
    rule_metadata.dependencies = &.{ "cleanup-zeta", "cleanup-alpha", "cleanup-fast" };

    var cleanup_fast_metadata = acceptedMetadata("cleanup-fast", .cleanup, .lossless_cleanup);
    cleanup_fast_metadata.priority = 1;
    var cleanup_alpha_metadata = acceptedMetadata("cleanup-alpha", .cleanup, .lossless_cleanup);
    cleanup_alpha_metadata.priority = 10;
    var cleanup_zeta_metadata = acceptedMetadata("cleanup-zeta", .cleanup, .lossless_cleanup);
    cleanup_zeta_metadata.priority = 10;

    const analysis = testPass(acceptedMetadata("analysis", .analysis, .analysis), &analysis_state);
    const cleanup_fast = testPass(cleanup_fast_metadata, &cleanup_fast_state);
    const cleanup_alpha = testPass(cleanup_alpha_metadata, &cleanup_alpha_state);
    const cleanup_zeta = testPass(cleanup_zeta_metadata, &cleanup_zeta_state);
    const rule = testPass(rule_metadata, &rule_state);
    const first_registry = [_]Pass{ rule, cleanup_zeta, analysis, cleanup_alpha, cleanup_fast };
    const second_registry = [_]Pass{ cleanup_fast, cleanup_alpha, rule, cleanup_zeta, analysis };
    const policy = Policy{ .allow_lossless_cleanup = true, .allow_semantic_rewrite = true };

    var first = try buildPlan(std.testing.allocator, &first_registry, &.{ "rule", "analysis" }, policy);
    defer first.deinit();
    var second = try buildPlan(std.testing.allocator, &second_registry, &.{ "analysis", "rule" }, policy);
    defer second.deinit();

    const expected = [_][]const u8{ "analysis", "cleanup-fast", "cleanup-alpha", "cleanup-zeta", "rule" };
    try std.testing.expectEqual(expected.len, first.orderedPasses().len);
    try std.testing.expectEqual(expected.len, second.orderedPasses().len);
    for (expected, first.orderedPasses(), second.orderedPasses()) |id, first_pass, second_pass| {
        try std.testing.expectEqualStrings(id, first_pass.metadata.id);
        try std.testing.expectEqualStrings(id, second_pass.metadata.id);
    }
}

test "registry validation rejects ambiguous invalid and cyclic pass graphs" {
    var state = TestState{};
    const pass = testPass(acceptedMetadata("same", .cleanup, .lossless_cleanup), &state);
    const duplicate = [_]Pass{ pass, pass };
    try std.testing.expectError(error.DuplicatePass, buildPlan(std.testing.allocator, &duplicate, &.{}, .{}));

    var unknown_metadata = acceptedMetadata("unknown", .cleanup, .lossless_cleanup);
    unknown_metadata.dependencies = &.{"missing"};
    const unknown = [_]Pass{testPass(unknown_metadata, &state)};
    try std.testing.expectError(error.UnknownDependency, buildPlan(std.testing.allocator, &unknown, &.{}, .{}));

    var first_metadata = acceptedMetadata("first", .cleanup, .lossless_cleanup);
    first_metadata.dependencies = &.{"second"};
    var second_metadata = acceptedMetadata("second", .cleanup, .lossless_cleanup);
    second_metadata.dependencies = &.{"first"};
    const cycle = [_]Pass{ testPass(first_metadata, &state), testPass(second_metadata, &state) };
    try std.testing.expectError(error.DependencyCycle, buildPlan(std.testing.allocator, &cycle, &.{}, .{}));

    var early_metadata = acceptedMetadata("early", .cleanup, .lossless_cleanup);
    early_metadata.dependencies = &.{"late"};
    const phase_inversion = [_]Pass{
        testPass(early_metadata, &state),
        testPass(acceptedMetadata("late", .rules, .semantic_rewrite), &state),
    };
    try std.testing.expectError(
        error.DependencyPhaseViolation,
        buildPlan(std.testing.allocator, &phase_inversion, &.{}, .{}),
    );

    const valid = [_]Pass{testPass(acceptedMetadata("valid", .analysis, .analysis), &state)};
    try std.testing.expectError(
        error.UnknownRequestedPass,
        buildPlan(std.testing.allocator, &valid, &.{"missing"}, .{}),
    );
    try std.testing.expectError(
        error.DuplicateRequest,
        buildPlan(std.testing.allocator, &valid, &.{ "valid", "valid" }, .{}),
    );
}

test "verified metadata requires documented acceptance evidence" {
    var state = TestState{};
    var invalid_id = acceptedMetadata("Invalid ID", .analysis, .analysis);
    const invalid_id_registry = [_]Pass{testPass(invalid_id, &state)};
    try std.testing.expectError(error.InvalidPassId, buildPlan(std.testing.allocator, &invalid_id_registry, &.{}, .{}));

    invalid_id = acceptedMetadata("missing-evidence", .cleanup, .lossless_cleanup);
    invalid_id.acceptance.idempotence = false;
    const missing_evidence = [_]Pass{testPass(invalid_id, &state)};
    try std.testing.expectError(
        error.MissingAcceptanceEvidence,
        buildPlan(std.testing.allocator, &missing_evidence, &.{}, .{}),
    );

    var size_claim = acceptedMetadata("size-claim", .cleanup, .lossless_cleanup);
    size_claim.claims_size_reduction = true;
    size_claim.acceptance.size_validation = false;
    const missing_size_evidence = [_]Pass{testPass(size_claim, &state)};
    try std.testing.expectError(
        error.MissingAcceptanceEvidence,
        buildPlan(std.testing.allocator, &missing_size_evidence, &.{}, .{}),
    );

    var without_validator = testPass(acceptedMetadata("without-validator", .analysis, .analysis), &state);
    without_validator.validate = null;
    const verified_without_validator = [_]Pass{without_validator};
    try std.testing.expectError(
        error.MissingValidator,
        buildPlan(std.testing.allocator, &verified_without_validator, &.{}, .{}),
    );

    const mismatched_phase = [_]Pass{
        testPass(acceptedMetadata("mismatched-phase", .rules, .analysis), &state),
    };
    try std.testing.expectError(
        error.InvalidMetadata,
        buildPlan(std.testing.allocator, &mismatched_phase, &.{}, .{}),
    );

    var verified_static_metadata = acceptedMetadata(
        "verified-static-custom-properties",
        .values,
        .semantic_rewrite,
    );
    verified_static_metadata.custom_property_effect = .static_resolution;
    const verified_static = [_]Pass{testPass(verified_static_metadata, &state)};
    try std.testing.expectError(
        error.InvalidMetadata,
        buildPlan(std.testing.allocator, &verified_static, &.{}, .{}),
    );
}

test "default policy denies unverified and output-changing passes" {
    var state = TestState{};
    const cleanup = [_]Pass{testPass(acceptedMetadata("cleanup", .cleanup, .lossless_cleanup), &state)};
    try std.testing.expectError(
        error.DisallowedSafetyClass,
        buildPlan(std.testing.allocator, &cleanup, &.{"cleanup"}, .{}),
    );

    var experimental_metadata = acceptedMetadata("experimental", .analysis, .analysis);
    experimental_metadata.maturity = .experimental;
    const experimental = [_]Pass{testPass(experimental_metadata, &state)};
    try std.testing.expectError(
        error.UnverifiedPass,
        buildPlan(std.testing.allocator, &experimental, &.{"experimental"}, .{}),
    );

    var without_validator = testPass(experimental_metadata, &state);
    without_validator.validate = null;
    const missing_validator = [_]Pass{without_validator};
    try std.testing.expectError(
        error.MissingValidator,
        buildPlan(
            std.testing.allocator,
            &missing_validator,
            &.{"experimental"},
            .{ .allow_experimental = true },
        ),
    );

    var no_nesting_metadata = experimental_metadata;
    no_nesting_metadata.id = "no-nesting";
    no_nesting_metadata.supports_nested_rules = false;
    const no_nesting = [_]Pass{testPass(no_nesting_metadata, &state)};
    try std.testing.expectError(
        error.NestedRulesUnsupported,
        buildPlan(
            std.testing.allocator,
            &no_nesting,
            &.{"no-nesting"},
            .{ .allow_experimental = true },
        ),
    );

    var reorder_metadata = experimental_metadata;
    reorder_metadata.id = "reorder";
    reorder_metadata.order_effect = .proven_reorder;
    reorder_metadata.order_rationale = "a dedicated proof is attached";
    const reorder = [_]Pass{testPass(reorder_metadata, &state)};
    try std.testing.expectError(
        error.OrderChangeDisallowed,
        buildPlan(
            std.testing.allocator,
            &reorder,
            &.{"reorder"},
            .{ .allow_experimental = true },
        ),
    );

    var static_resolution_metadata = acceptedMetadata(
        "static-custom-properties",
        .values,
        .semantic_rewrite,
    );
    static_resolution_metadata.maturity = .experimental;
    static_resolution_metadata.custom_property_effect = .static_resolution;
    const static_resolution = [_]Pass{testPass(static_resolution_metadata, &state)};
    try std.testing.expectError(
        error.StaticCustomPropertyResolutionDisallowed,
        buildPlan(
            std.testing.allocator,
            &static_resolution,
            &.{"static-custom-properties"},
            .{
                .allow_semantic_rewrite = true,
                .allow_experimental = true,
            },
        ),
    );
    var explicit_static_plan = try buildPlan(
        std.testing.allocator,
        &static_resolution,
        &.{"static-custom-properties"},
        .{
            .allow_semantic_rewrite = true,
            .allow_experimental = true,
            .allow_static_custom_property_resolution = true,
        },
    );
    defer explicit_static_plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), explicit_static_plan.orderedPasses().len);
}

test "pass execution invokes semantic hooks and optional idempotence checks in order" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseTestStylesheet(&context, ".a{x:1;.b{y:2}}@media all{.c{z:3}}");
    var run_context = try Context.init(&context, parsed.source_id, std.testing.allocator);

    var log = TestLog{};
    var analysis_state = TestState{ .log = &log, .marker = 'a', .semantic_validation = true };
    var cleanup_state = TestState{
        .log = &log,
        .marker = 'c',
        .clone_output = true,
        .semantic_validation = true,
    };
    var cleanup_metadata = acceptedMetadata("cleanup", .cleanup, .lossless_cleanup);
    cleanup_metadata.dependencies = &.{"analysis"};
    const registry = [_]Pass{
        testPass(cleanup_metadata, &cleanup_state),
        testPass(acceptedMetadata("analysis", .analysis, .analysis), &analysis_state),
    };
    var plan = try buildPlan(
        std.testing.allocator,
        &registry,
        &.{"cleanup"},
        .{ .allow_lossless_cleanup = true },
    );
    defer plan.deinit();

    const output = try plan.run(&run_context, parsed.rules, .{ .verify_idempotence = true });
    try std.testing.expect(output != parsed.rules);
    try std.testing.expectEqualStrings("aacc", log.bytes[0..log.len]);
    try std.testing.expectEqual(@as(usize, 2), analysis_state.runs);
    try std.testing.expectEqual(@as(usize, 2), cleanup_state.runs);
    try std.testing.expectEqual([_]usize{ 1, 1, 1 }, analysis_state.validations);
    try std.testing.expectEqual([_]usize{ 1, 1, 1 }, cleanup_state.validations);
}

test "validation failure does not publish a candidate and analyses cannot replace roots" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseTestStylesheet(&context, ".a{x:1}");
    var run_context = try Context.init(&context, parsed.source_id, std.testing.allocator);

    var failing_state = TestState{ .clone_output = true, .fail_phase = .postcondition };
    const failing_registry = [_]Pass{
        testPass(acceptedMetadata("cleanup", .cleanup, .lossless_cleanup), &failing_state),
    };
    var failing_plan = try buildPlan(
        std.testing.allocator,
        &failing_registry,
        &.{"cleanup"},
        .{ .allow_lossless_cleanup = true },
    );
    defer failing_plan.deinit();
    try std.testing.expectError(error.ValidationFailed, failing_plan.run(&run_context, parsed.rules, .{}));
    try std.testing.expectEqual(@as(usize, 1), failing_state.runs);
    try std.testing.expectEqual(@as(usize, 1), parsed.rules.rules.len);

    var analysis_state = TestState{ .clone_output = true };
    const analysis_registry = [_]Pass{
        testPass(acceptedMetadata("analysis", .analysis, .analysis), &analysis_state),
    };
    var analysis_plan = try buildPlan(std.testing.allocator, &analysis_registry, &.{"analysis"}, .{});
    defer analysis_plan.deinit();
    try std.testing.expectError(
        error.AnalysisMutatedOutput,
        analysis_plan.run(&run_context, parsed.rules, .{}),
    );

    const other = try parseTestStylesheet(&context, ".other{y:2}");
    try std.testing.expectError(error.InvalidAst, analysis_plan.run(&run_context, other.rules, .{}));

    var reporting_state = TestState{ .report_error = true };
    const reporting_registry = [_]Pass{
        testPass(acceptedMetadata("reporting", .analysis, .analysis), &reporting_state),
    };
    var reporting_plan = try buildPlan(std.testing.allocator, &reporting_registry, &.{"reporting"}, .{});
    defer reporting_plan.deinit();
    try std.testing.expectError(
        error.PassReportedErrors,
        reporting_plan.run(&run_context, parsed.rules, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

fn exercisePlanAllocationFailures(allocator: std.mem.Allocator) !void {
    var state = TestState{};
    var cleanup_metadata = acceptedMetadata("cleanup", .cleanup, .lossless_cleanup);
    cleanup_metadata.dependencies = &.{"analysis"};
    const registry = [_]Pass{
        testPass(cleanup_metadata, &state),
        testPass(acceptedMetadata("analysis", .analysis, .analysis), &state),
    };
    var plan = try buildPlan(
        allocator,
        &registry,
        &.{"cleanup"},
        .{ .allow_lossless_cleanup = true },
    );
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.orderedPasses().len);
}

test "pass planning handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePlanAllocationFailures,
        .{},
    );
}
