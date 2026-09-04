//! Transactional evaluation and CSS emission for the self-contained native
//! stylesheet frontends.
//!
//! Language-specific parsers and evaluators write only into `Transaction`.
//! Staged bytes are intentionally not observable. A result becomes available
//! only after the complete stylesheet is accepted without recovery diagnostics
//! by the existing CSS parser and emitter.

const std = @import("std");
const evaluation_budget = @import("budget.zig");
const native_diagnostics = @import("diagnostics.zig");
const native_resolver = @import("resolver.zig");
const native_source = @import("source.zig");
const native_sourcemap = @import("sourcemap.zig");
const core_diagnostics = @import("../diagnostics.zig");
const core_equivalence = @import("../css/equivalence.zig");
const core_pipeline = @import("../css/pipeline.zig");
const prefix_rewrite = @import("../prefixing/rewrite.zig");
const target_query = @import("../prefixing/target_query.zig");
const verified_optimizer = @import("../transform/verified_optimizer.zig");

pub const intermediate_source_name = "zigcss-native:///intermediate.css";

const hard_staged_css_bytes = 20 * 1024 * 1024;
const hard_validated_css_bytes = 40 * 1024 * 1024;
const hard_core_source_map_bytes = 40 * 1024 * 1024;
const hard_core_diagnostics = 1_000;

pub const Limits = struct {
    budget: evaluation_budget.Limits = .{ .max_output_bytes = hard_staged_css_bytes },
    diagnostics: native_diagnostics.Limits = .{},
    source_map: native_sourcemap.Limits = .{},
    max_validated_css_bytes: usize = hard_validated_css_bytes,
    max_core_source_map_bytes: usize = hard_core_source_map_bytes,
    max_core_diagnostics: usize = hard_core_diagnostics,
};

pub const Format = enum {
    pretty,
    minified,
};

pub const TargetQuery = target_query.Query;

pub const Options = struct {
    format: Format = .pretty,
    source_map: bool = false,
    optimize: bool = false,
    prefix: bool = false,
    targets: ?*const TargetQuery = null,
};

pub const Checkpoint = enum {
    operation,
    emit,
    diagnostic,
    mapping,
    validate,
    commit,
    finish,
};

pub const Cancellation = struct {
    context: ?*anyopaque = null,
    check_fn: ?*const fn (*anyopaque, Checkpoint) bool = null,

    fn check(self: Cancellation, checkpoint: Checkpoint) Error!void {
        const check_fn = self.check_fn orelse return;
        const context = self.context orelse return error.Cancelled;
        if (check_fn(context, checkpoint)) return error.Cancelled;
    }
};

pub const Error = std.mem.Allocator.Error ||
    evaluation_budget.Error ||
    native_diagnostics.Error ||
    native_sourcemap.Error || error{
    Cancelled,
    CoreDiagnosticLimitExceeded,
    CoreValidationFailed,
    EvaluationFailed,
    GeneratedCssRejected,
    InvalidLimits,
    InvalidOptions,
    InvalidOutput,
    SessionClosed,
    SessionFailed,
    UnbalancedCalls,
    ValidatedOutputLimitExceeded,
};

pub const GeneratedPosition = native_sourcemap.GeneratedPosition;

pub const StagingCheckpoint = struct {
    output_len: usize,
    generated: GeneratedPosition,
    map: native_sourcemap.Builder.Checkpoint,
};

/// Compares two complete generated stylesheets through the stable typed CSS
/// pipeline. This is internal conformance support, not a public stylesheet
/// frontend API.
pub fn equivalentCss(
    allocator: std.mem.Allocator,
    left: []const u8,
    right: []const u8,
) !bool {
    var left_parsed = try core_pipeline.parse(allocator, "native-conformance-left.css", left);
    defer left_parsed.deinit();
    var right_parsed = try core_pipeline.parse(allocator, "native-conformance-right.css", right);
    defer right_parsed.deinit();
    if (left_parsed.hasErrors() or right_parsed.hasErrors()) return false;
    return core_equivalence.equivalent(
        allocator,
        left_parsed.file(),
        left_parsed.rules,
        right_parsed.file(),
        right_parsed.rules,
    );
}

const State = enum {
    open,
    committed,
    failed,
};

/// Owns post-core CSS, the optional core and frontend maps, native diagnostics,
/// and deterministic resolver facts. The caller's source table must remain
/// available while interpreting frontend map source IDs.
pub const ValidatedCss = struct {
    allocator: std.mem.Allocator,
    core: core_pipeline.CompileResult,
    native_diagnostic_items: []const native_diagnostics.Diagnostic,
    dependency_items: []const native_resolver.Dependency,
    edge_items: []const native_resolver.Edge,
    frontend_map: ?native_sourcemap.Map,
    resolver_stats: native_resolver.Stats,

    pub fn deinit(self: *ValidatedCss) void {
        if (self.frontend_map) |*owned_map| owned_map.deinit();
        releaseEdges(self.allocator, self.edge_items);
        releaseDependencies(self.allocator, self.dependency_items);
        releaseNativeDiagnostics(self.allocator, self.native_diagnostic_items);
        self.core.deinit();
        self.* = undefined;
    }

    pub fn css(self: *const ValidatedCss) []const u8 {
        return self.core.css;
    }

    /// Transfers the already-owned core emitter buffer out of this result.
    /// The moved-from value remains safe to deinitialize exactly once.
    pub fn takeCss(self: *ValidatedCss) []const u8 {
        const moved = self.core.css;
        self.core.css = &.{};
        return moved;
    }

    pub fn sourceMap(self: *const ValidatedCss) ?[]const u8 {
        return self.core.source_map;
    }

    pub fn coreDiagnostics(self: *const ValidatedCss) []const core_diagnostics.Diagnostic {
        return self.core.diagnostics;
    }

    pub fn nativeDiagnostics(self: *const ValidatedCss) []const native_diagnostics.Diagnostic {
        return self.native_diagnostic_items;
    }

    pub fn dependencies(self: *const ValidatedCss) []const native_resolver.Dependency {
        return self.dependency_items;
    }

    pub fn edges(self: *const ValidatedCss) []const native_resolver.Edge {
        return self.edge_items;
    }

    pub fn map(self: *const ValidatedCss) ?*const native_sourcemap.Map {
        if (self.frontend_map) |*value| return value;
        return null;
    }

    pub fn stats(self: *const ValidatedCss) native_resolver.Stats {
        return self.resolver_stats;
    }
};

/// One single-owner staging transaction. Every mutating error is terminal so
/// callers cannot retry against partially advanced budgets, maps, or bytes.
pub const Transaction = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    resolver_session: *native_resolver.Session,
    limits: Limits,
    cancellation: Cancellation,
    meter: evaluation_budget.Budget,
    diagnostic_list: native_diagnostics.List,
    map_builder: native_sourcemap.Builder,
    output: std.ArrayList(u8) = .empty,
    generated: GeneratedPosition = .{ .line = 0, .column = 0 },
    transaction_state: State = .open,
    validation_failure: ?core_pipeline.CompileResult = null,

    pub fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        resolver_session: *native_resolver.Session,
        limits: Limits,
        cancellation: Cancellation,
    ) Error!Transaction {
        try validateLimits(limits);
        return .{
            .allocator = allocator,
            .sources = sources,
            .resolver_session = resolver_session,
            .limits = limits,
            .cancellation = cancellation,
            .meter = evaluation_budget.Budget.init(limits.budget),
            .diagnostic_list = native_diagnostics.List.init(
                allocator,
                sources,
                limits.diagnostics,
            ),
            .map_builder = native_sourcemap.Builder.init(
                allocator,
                sources,
                limits.source_map,
            ),
        };
    }

    pub fn deinit(self: *Transaction) void {
        if (self.transaction_state == .open) self.resolver_session.close();
        if (self.validation_failure) |*failure| failure.deinit();
        self.output.deinit(self.allocator);
        self.map_builder.deinit();
        self.diagnostic_list.deinit();
        self.* = undefined;
    }

    /// Candidate probing remains language-owned because a missing candidate can
    /// be an expected branch in Sass/Less/Stylus import search.
    pub fn resolverSession(self: *Transaction) Error!*native_resolver.Session {
        try self.requireOpen();
        return self.resolver_session;
    }

    pub fn diagnostics(self: *const Transaction) []const native_diagnostics.Diagnostic {
        return self.diagnostic_list.items();
    }

    pub fn validationDiagnostics(self: *const Transaction) []const core_diagnostics.Diagnostic {
        if (self.validation_failure) |failure| return failure.diagnostics;
        return &.{};
    }

    pub fn position(self: *const Transaction) GeneratedPosition {
        return self.generated;
    }

    pub fn stats(self: *const Transaction) native_resolver.Stats {
        return self.resolver_session.stats();
    }

    pub fn consumeOperations(self: *Transaction, count: u64) Error!void {
        try self.requireOpen();
        self.checkpoint(.operation) catch |err| return err;
        self.meter.consumeOperations(count) catch |err| {
            self.poison();
            return err;
        };
    }

    pub fn consumeLoopIterations(self: *Transaction, count: u64) Error!void {
        try self.requireOpen();
        self.checkpoint(.operation) catch |err| return err;
        self.meter.consumeLoopIterations(count) catch |err| {
            self.poison();
            return err;
        };
    }

    pub fn enterCall(self: *Transaction) Error!void {
        try self.requireOpen();
        self.checkpoint(.operation) catch |err| return err;
        self.meter.enterCall() catch |err| {
            self.poison();
            return err;
        };
    }

    pub fn leaveCall(self: *Transaction) Error!void {
        try self.requireOpen();
        if (self.meter.call_depth == 0) {
            self.poison();
            return error.UnbalancedCalls;
        }
        self.meter.leaveCall();
    }

    pub fn report(
        self: *Transaction,
        severity: native_diagnostics.Severity,
        code: native_diagnostics.Code,
        span: native_source.Span,
        message: []const u8,
        related: []const native_diagnostics.RelatedInput,
    ) Error!void {
        try self.requireOpen();
        self.checkpoint(.diagnostic) catch |err| return err;
        self.meter.reserveDiagnostic() catch |err| {
            self.poison();
            return err;
        };
        self.diagnostic_list.append(severity, code, span, message, related) catch |err| {
            self.poison();
            return err;
        };
    }

    /// Appends normalized-LF, valid UTF-8 generated CSS to private staging.
    pub fn emit(self: *Transaction, bytes: []const u8) Error!void {
        try self.requireOpen();
        self.checkpoint(.emit) catch |err| return err;
        self.meter.reserveOutput(bytes.len) catch |err| {
            self.poison();
            return err;
        };
        const next_position = advancePosition(self.generated, bytes) catch |err| {
            self.poison();
            return err;
        };
        self.output.ensureUnusedCapacity(self.allocator, bytes.len) catch |err| {
            self.poison();
            return err;
        };
        self.output.appendSliceAssumeCapacity(bytes);
        self.generated = next_position;
    }

    pub fn markMapped(
        self: *Transaction,
        original: native_source.Span,
        name: ?[]const u8,
    ) Error!void {
        try self.requireOpen();
        self.checkpoint(.mapping) catch |err| return err;
        self.map_builder.addMapped(self.generated, original, name) catch |err| {
            self.poison();
            return err;
        };
    }

    pub fn markUnmapped(self: *Transaction) Error!void {
        try self.requireOpen();
        self.checkpoint(.mapping) catch |err| return err;
        self.map_builder.addUnmapped(self.generated) catch |err| {
            self.poison();
            return err;
        };
    }

    pub fn emitMapped(
        self: *Transaction,
        original: native_source.Span,
        name: ?[]const u8,
        bytes: []const u8,
    ) Error!void {
        try self.markMapped(original, name);
        try self.emit(bytes);
    }

    /// Captures reversible private staging state for a language-owned construct
    /// that may normalize to no CSS. Resource budget already consumed while
    /// probing the construct remains charged after restoration.
    pub fn stagingCheckpoint(self: *Transaction) Error!StagingCheckpoint {
        try self.requireOpen();
        return .{
            .output_len = self.output.items.len,
            .generated = self.generated,
            .map = self.map_builder.checkpoint(),
        };
    }

    pub fn restoreStaging(
        self: *Transaction,
        checkpoint_value: StagingCheckpoint,
    ) Error!void {
        try self.requireOpen();
        if (checkpoint_value.output_len > self.output.items.len) {
            self.poison();
            return error.InvalidOutput;
        }
        self.map_builder.restore(checkpoint_value.map) catch |failure| {
            self.poison();
            return failure;
        };
        self.output.shrinkRetainingCapacity(checkpoint_value.output_len);
        self.generated = checkpoint_value.generated;
    }

    /// Explicitly terminates a language evaluator after a fatal language-owned
    /// error. No staged byte or map can subsequently be committed.
    pub fn abort(self: *Transaction) void {
        if (self.transaction_state == .open) self.poison();
    }

    pub fn finish(self: *Transaction, options: Options) Error!ValidatedCss {
        try self.requireOpen();
        if ((options.source_map and options.optimize) or
            (options.prefix and options.targets == null) or
            (!options.prefix and options.targets != null) or
            (options.targets != null and !options.targets.?.validate()))
        {
            self.poison();
            return error.InvalidOptions;
        }
        self.checkpoint(.finish) catch |err| return err;
        if (self.meter.call_depth != 0) {
            self.poison();
            return error.UnbalancedCalls;
        }
        if (hasNativeErrors(self.diagnostic_list.items())) {
            self.poison();
            return error.EvaluationFailed;
        }
        self.checkpoint(.validate) catch |err| return err;

        var parsed = core_pipeline.parse(
            self.allocator,
            intermediate_source_name,
            self.output.items,
        ) catch |err| {
            self.poison();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CoreValidationFailed,
            };
        };
        defer parsed.deinit();
        self.checkpoint(.validate) catch |err| return err;

        if (parsed.hasErrors()) {
            var failure = parsed.emitResult(self.allocator, .{
                .mode = coreMode(options.format),
            }) catch |err| {
                self.poison();
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.CoreValidationFailed,
                };
            };
            self.checkpoint(.validate) catch |err| {
                failure.deinit();
                return err;
            };
            if (failure.css.len != 0 or failure.diagnostics.len == 0) {
                failure.deinit();
                self.poison();
                return error.CoreValidationFailed;
            }
            if (failure.diagnostics.len > self.limits.max_core_diagnostics) {
                failure.deinit();
                self.poison();
                return error.CoreDiagnosticLimitExceeded;
            }
            self.validation_failure = failure;
            self.poison();
            return error.GeneratedCssRejected;
        }

        if (options.optimize) {
            verified_optimizer.applyToFixedPoint(
                self.allocator,
                &parsed,
                coreMode(options.format),
            ) catch |err| {
                self.poison();
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.OptimizationDidNotConverge => error.ValidatedOutputLimitExceeded,
                    else => error.CoreValidationFailed,
                };
            };
            self.checkpoint(.validate) catch |err| return err;
        }

        if (options.prefix) {
            prefix_rewrite.applyToStylesheet(
                self.allocator,
                &parsed,
                options.targets.?,
            ) catch |err| {
                self.poison();
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.CoreValidationFailed,
                };
            };
            self.checkpoint(.validate) catch |err| return err;
        }

        var core_result = parsed.emitResult(self.allocator, .{
            .mode = coreMode(options.format),
            .source_map = if (options.source_map) .{
                .generated_file = null,
                .include_sources_content = true,
            } else null,
        }) catch |err| {
            self.poison();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CoreValidationFailed,
            };
        };
        errdefer core_result.deinit();
        self.checkpoint(.validate) catch |err| return err;
        if (hasCoreErrors(core_result.diagnostics)) {
            self.poison();
            return error.CoreValidationFailed;
        }
        if (core_result.diagnostics.len > self.limits.max_core_diagnostics) {
            self.poison();
            return error.CoreDiagnosticLimitExceeded;
        }
        if (core_result.css.len > self.limits.max_validated_css_bytes or
            (core_result.source_map != null and
                core_result.source_map.?.len > self.limits.max_core_source_map_bytes))
        {
            self.poison();
            return error.ValidatedOutputLimitExceeded;
        }

        const owned_diagnostics = cloneNativeDiagnostics(
            self.allocator,
            self.diagnostic_list.items(),
        ) catch |err| {
            self.poison();
            return err;
        };
        errdefer releaseNativeDiagnostics(self.allocator, owned_diagnostics);
        const owned_dependencies = cloneDependencies(
            self.allocator,
            self.resolver_session.dependencies(),
        ) catch |err| {
            self.poison();
            return err;
        };
        errdefer releaseDependencies(self.allocator, owned_dependencies);
        const owned_edges = cloneEdges(
            self.allocator,
            self.resolver_session.edges(),
        ) catch |err| {
            self.poison();
            return err;
        };
        errdefer releaseEdges(self.allocator, owned_edges);
        var frontend_map: ?native_sourcemap.Map = null;
        if (options.source_map) {
            frontend_map = self.map_builder.finish() catch |err| {
                self.poison();
                return err;
            };
        }
        errdefer if (frontend_map) |*owned_map| owned_map.deinit();

        self.checkpoint(.commit) catch |err| return err;
        const resolver_stats = self.resolver_session.stats();
        self.output.clearAndFree(self.allocator);
        self.resolver_session.close();
        self.transaction_state = .committed;
        return .{
            .allocator = self.allocator,
            .core = core_result,
            .native_diagnostic_items = owned_diagnostics,
            .dependency_items = owned_dependencies,
            .edge_items = owned_edges,
            .frontend_map = frontend_map,
            .resolver_stats = resolver_stats,
        };
    }

    fn requireOpen(self: *const Transaction) Error!void {
        return switch (self.transaction_state) {
            .open => {},
            .committed => error.SessionClosed,
            .failed => error.SessionFailed,
        };
    }

    fn checkpoint(self: *Transaction, value: Checkpoint) Error!void {
        self.cancellation.check(value) catch |err| {
            self.poison();
            return err;
        };
    }

    fn poison(self: *Transaction) void {
        if (self.transaction_state != .open) return;
        self.output.clearAndFree(self.allocator);
        self.resolver_session.close();
        self.transaction_state = .failed;
    }
};

fn coreMode(format: Format) @import("../css/emitter.zig").Mode {
    return switch (format) {
        .pretty => .pretty,
        .minified => .minified,
    };
}

fn validateLimits(limits: Limits) Error!void {
    const meter = limits.budget;
    const diagnostic_limits = limits.diagnostics;
    const map_limits = limits.source_map;
    if (meter.max_call_depth == 0 or meter.max_call_depth > 256 or
        meter.max_calls == 0 or meter.max_calls > 1_000_000 or
        meter.max_operations == 0 or meter.max_operations > 100_000_000 or
        meter.max_loop_iterations == 0 or meter.max_loop_iterations > 10_000_000 or
        meter.max_output_bytes == 0 or meter.max_output_bytes > hard_staged_css_bytes or
        meter.max_diagnostics == 0 or meter.max_diagnostics > hard_core_diagnostics or
        diagnostic_limits.max_diagnostics == 0 or
        diagnostic_limits.max_diagnostics > hard_core_diagnostics or
        diagnostic_limits.max_related_per_diagnostic == 0 or
        diagnostic_limits.max_related_per_diagnostic > 32 or
        diagnostic_limits.max_message_bytes == 0 or
        diagnostic_limits.max_message_bytes > 16 * 1024 or
        diagnostic_limits.max_owned_bytes == 0 or
        diagnostic_limits.max_owned_bytes > 4 * 1024 * 1024 or
        map_limits.max_segments == 0 or map_limits.max_segments > 1_000_000 or
        map_limits.max_names == 0 or map_limits.max_names > 100_000 or
        map_limits.max_name_bytes == 0 or map_limits.max_name_bytes > 16 * 1024 * 1024 or
        limits.max_validated_css_bytes == 0 or
        limits.max_validated_css_bytes > hard_validated_css_bytes or
        limits.max_core_source_map_bytes == 0 or
        limits.max_core_source_map_bytes > hard_core_source_map_bytes or
        limits.max_core_diagnostics == 0 or
        limits.max_core_diagnostics > hard_core_diagnostics)
    {
        return error.InvalidLimits;
    }
}

fn advancePosition(start: GeneratedPosition, bytes: []const u8) Error!GeneratedPosition {
    if (std.mem.indexOfAny(u8, bytes, "\x00\r") != null or
        !std.unicode.utf8ValidateSlice(bytes))
    {
        return error.InvalidOutput;
    }
    var result = start;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == '\n') {
            result.line = std.math.add(u32, result.line, 1) catch return error.InvalidOutput;
            result.column = 0;
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch
            return error.InvalidOutput;
        const scalar = std.unicode.utf8Decode(bytes[index .. index + length]) catch
            return error.InvalidOutput;
        const units: u32 = if (scalar > 0xffff) 2 else 1;
        result.column = std.math.add(u32, result.column, units) catch
            return error.InvalidOutput;
        index += length;
    }
    return result;
}

fn hasNativeErrors(items: []const native_diagnostics.Diagnostic) bool {
    for (items) |item| {
        if (item.severity == .err) return true;
    }
    return false;
}

fn hasCoreErrors(items: []const core_diagnostics.Diagnostic) bool {
    for (items) |item| {
        if (item.severity == .err) return true;
    }
    return false;
}

fn cloneNativeDiagnostic(
    allocator: std.mem.Allocator,
    item: native_diagnostics.Diagnostic,
) std.mem.Allocator.Error!native_diagnostics.Diagnostic {
    const message = try allocator.dupe(u8, item.message);
    errdefer if (message.len > 0) allocator.free(message);
    const related = try allocator.alloc(native_diagnostics.Related, item.related.len);
    var initialized: usize = 0;
    errdefer {
        for (related[0..initialized]) |entry| {
            if (entry.label.len > 0) allocator.free(entry.label);
        }
        if (related.len > 0) allocator.free(related);
    }
    for (item.related, 0..) |entry, index| {
        related[index] = .{
            .span = entry.span,
            .label = try allocator.dupe(u8, entry.label),
        };
        initialized += 1;
    }
    return .{
        .severity = item.severity,
        .code = item.code,
        .span = item.span,
        .message = message,
        .related = related,
    };
}

pub fn cloneNativeDiagnostics(
    allocator: std.mem.Allocator,
    items: []const native_diagnostics.Diagnostic,
) std.mem.Allocator.Error![]const native_diagnostics.Diagnostic {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(native_diagnostics.Diagnostic, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| releaseNativeDiagnostic(allocator, item);
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        cloned[index] = try cloneNativeDiagnostic(allocator, item);
        initialized += 1;
    }
    return cloned;
}

fn releaseNativeDiagnostic(
    allocator: std.mem.Allocator,
    item: native_diagnostics.Diagnostic,
) void {
    if (item.message.len > 0) allocator.free(item.message);
    for (item.related) |entry| {
        if (entry.label.len > 0) allocator.free(entry.label);
    }
    if (item.related.len > 0) allocator.free(item.related);
}

pub fn releaseNativeDiagnostics(
    allocator: std.mem.Allocator,
    items: []const native_diagnostics.Diagnostic,
) void {
    if (items.len == 0) return;
    for (items) |item| releaseNativeDiagnostic(allocator, item);
    allocator.free(items);
}

fn cloneDependencies(
    allocator: std.mem.Allocator,
    items: []const native_resolver.Dependency,
) std.mem.Allocator.Error![]const native_resolver.Dependency {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(native_resolver.Dependency, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item.url);
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        cloned[index] = .{
            .url = try allocator.dupe(u8, item.url),
            .kind = item.kind,
        };
        initialized += 1;
    }
    return cloned;
}

fn releaseDependencies(
    allocator: std.mem.Allocator,
    items: []const native_resolver.Dependency,
) void {
    if (items.len == 0) return;
    for (items) |item| allocator.free(item.url);
    allocator.free(items);
}

fn cloneEdges(
    allocator: std.mem.Allocator,
    items: []const native_resolver.Edge,
) std.mem.Allocator.Error![]const native_resolver.Edge {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(native_resolver.Edge, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| {
            if (item.parent_url) |value| allocator.free(value);
            allocator.free(item.child_url);
        }
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        const parent = if (item.parent_url) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (parent) |value| allocator.free(value);
        cloned[index] = .{
            .parent_url = parent,
            .child_url = try allocator.dupe(u8, item.child_url),
            .kind = item.kind,
        };
        initialized += 1;
    }
    return cloned;
}

fn releaseEdges(
    allocator: std.mem.Allocator,
    items: []const native_resolver.Edge,
) void {
    if (items.len == 0) return;
    for (items) |item| {
        if (item.parent_url) |value| allocator.free(value);
        allocator.free(item.child_url);
    }
    allocator.free(items);
}
