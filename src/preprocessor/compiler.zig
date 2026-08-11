//! Private shared compiler route for the self-contained stylesheet frontends.
//!
//! This private NATIVE-006 boundary is reachable only through the explicit
//! pre-graduation native bridge. It does not itself graduate an adapter or
//! authorize a general-availability product claim.

const std = @import("std");
const core_diagnostics = @import("../diagnostics.zig");
const native_diagnostics = @import("diagnostics.zig");
const native_evaluator = @import("evaluator.zig");
const native_less = @import("less.zig");
const native_less_evaluator = @import("less_evaluator.zig");
const native_resolver = @import("resolver.zig");
const native_sass = @import("sass.zig");
const native_sass_evaluator = @import("sass_evaluator.zig");
const native_source = @import("source.zig");
const native_sourcemap = @import("sourcemap.zig");
const native_stylus = @import("stylus.zig");
const native_stylus_evaluator = @import("stylus_evaluator.zig");

pub const Syntax = enum {
    scss,
    sass,
    less,
    stylus,
};

pub const Limits = struct {
    sources: native_source.Limits = .{},
    resolver: native_resolver.Limits = .{},
    transaction: native_evaluator.Limits = .{},
    sass_parser: native_sass.Limits = .{},
    sass_evaluator: native_sass_evaluator.Limits = .{},
    less_parser: native_less.Limits = .{},
    less_evaluator: native_less_evaluator.Limits = .{},
    stylus_parser: native_stylus.Limits = .{},
    stylus_evaluator: native_stylus_evaluator.Limits = .{},
};

pub const Options = struct {
    syntax: Syntax,
    /// Borrowed canonical directory capabilities for this compilation only.
    root_paths: []const []const u8,
    format: native_evaluator.Format = .pretty,
    source_map: bool = false,
    less: native_less_evaluator.Options = .{},
    /// Null derives Stylus output style from `format`; conformance callers may
    /// supply the provider's explicit style while retaining a separate core
    /// normalization mode.
    stylus: ?native_stylus_evaluator.Options = null,
    limits: Limits = .{},
};

pub const Error = native_evaluator.Error ||
    native_less.Error ||
    native_less_evaluator.Error ||
    native_resolver.Error ||
    native_sass.Error ||
    native_sass_evaluator.Error ||
    native_source.Error ||
    native_stylus.Error ||
    native_stylus_evaluator.Error;

pub const Diagnostic = native_diagnostics.Diagnostic;
pub const Dependency = native_resolver.Dependency;
pub const Related = native_diagnostics.Related;
pub const SourceId = native_source.SourceId;
pub const SourceTable = native_source.Table;

/// Owns the complete source table alongside the committed evaluation result so
/// native diagnostic spans and frontend Source Map source IDs stay meaningful.
pub const Result = struct {
    sources: native_source.Table,
    validated: native_evaluator.ValidatedCss,

    pub fn deinit(self: *Result) void {
        self.validated.deinit();
        self.sources.deinit();
        self.* = undefined;
    }

    pub fn css(self: *const Result) []const u8 {
        return self.validated.css();
    }

    pub fn sourceMap(self: *const Result) ?[]const u8 {
        return self.validated.sourceMap();
    }

    pub fn frontendMap(self: *const Result) ?*const native_sourcemap.Map {
        return self.validated.map();
    }

    pub fn map(self: *const Result) ?*const native_sourcemap.Map {
        return self.frontendMap();
    }

    pub fn nativeDiagnostics(self: *const Result) []const native_diagnostics.Diagnostic {
        return self.validated.nativeDiagnostics();
    }

    pub fn coreDiagnostics(self: *const Result) []const core_diagnostics.Diagnostic {
        return self.validated.coreDiagnostics();
    }

    pub fn dependencies(self: *const Result) []const native_resolver.Dependency {
        return self.validated.dependencies();
    }

    pub fn edges(self: *const Result) []const native_resolver.Edge {
        return self.validated.edges();
    }

    pub fn sourceTable(self: *const Result) *const native_source.Table {
        return &self.sources;
    }
};

/// Owns structured native diagnostics for an expected language failure. It
/// deliberately carries no CSS, dependency, edge, or map fact from the
/// aborted transaction.
pub const ReportedFailure = struct {
    sources: native_source.Table,
    diagnostic_items: []const native_diagnostics.Diagnostic,
    cause: Error,

    pub fn deinit(self: *ReportedFailure) void {
        native_evaluator.releaseNativeDiagnostics(
            self.sources.allocator,
            self.diagnostic_items,
        );
        self.sources.deinit();
        self.* = undefined;
    }

    pub fn diagnostics(self: *const ReportedFailure) []const native_diagnostics.Diagnostic {
        return self.diagnostic_items;
    }

    pub fn sourceTable(self: *const ReportedFailure) *const native_source.Table {
        return &self.sources;
    }
};

pub const CompileOutcome = union(enum) {
    success: Result,
    failure: ReportedFailure,
};

/// Compiles one already-loaded entry source through exactly one native parser,
/// evaluator, transactional core validation, and owned-result path.
pub fn compile(
    allocator: std.mem.Allocator,
    entry_url: []const u8,
    input: []const u8,
    options: Options,
) Error!Result {
    const outcome = try compileReported(allocator, entry_url, input, options);
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure_value| {
            var failure = failure_value;
            const cause = failure.cause;
            failure.deinit();
            return cause;
        },
    };
}

/// Preserves structured, source-aware diagnostics for expected language
/// failures while operational, allocation, confinement, and resource errors
/// retain the ordinary error union.
pub fn compileReported(
    allocator: std.mem.Allocator,
    entry_url: []const u8,
    input: []const u8,
    options: Options,
) Error!CompileOutcome {
    var authority = try native_resolver.Resolver.init(
        allocator,
        options.root_paths,
        options.limits.resolver,
    );
    defer authority.deinit();
    if (!try authority.containsSourceUrl(allocator, entry_url)) return error.PathEscape;

    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = native_source.Table.init(allocator, options.limits.sources);
    errdefer sources.deinit();
    const source_id = try sources.add(entry_url, input);

    var transaction = try native_evaluator.Transaction.init(
        allocator,
        &sources,
        &session,
        options.limits.transaction,
        .{},
    );
    defer transaction.deinit();

    switch (options.syntax) {
        .scss, .sass => {
            var parser = try native_sass.Parser.init(
                allocator,
                &sources,
                source_id,
                if (options.syntax == .scss) .scss else .sass,
                options.limits.sass_parser,
                .{},
            );
            defer parser.deinit();
            var document = parser.parse() catch |err| {
                return reportFailure(
                    allocator,
                    &sources,
                    parser.diagnostics(),
                    err,
                );
            };
            defer document.deinit();
            native_sass_evaluator.evaluate(
                allocator,
                &sources,
                &document,
                &transaction,
                options.limits.sass_evaluator,
            ) catch |err| {
                return reportFailure(
                    allocator,
                    &sources,
                    transaction.diagnostics(),
                    err,
                );
            };
        },
        .less => {
            var parser = try native_less.Parser.init(
                allocator,
                &sources,
                source_id,
                options.limits.less_parser,
                .{},
            );
            defer parser.deinit();
            var document = parser.parse() catch |err| {
                return reportFailure(
                    allocator,
                    &sources,
                    parser.diagnostics(),
                    err,
                );
            };
            defer document.deinit();
            native_less_evaluator.evaluateWithOptions(
                &sources,
                &document,
                &transaction,
                options.less,
                options.limits.less_evaluator,
            ) catch |err| {
                return reportFailure(
                    allocator,
                    &sources,
                    transaction.diagnostics(),
                    err,
                );
            };
        },
        .stylus => {
            var parser = try native_stylus.Parser.init(
                allocator,
                &sources,
                source_id,
                options.limits.stylus_parser,
                .{},
            );
            defer parser.deinit();
            var document = parser.parse() catch |err| {
                return reportFailure(
                    allocator,
                    &sources,
                    parser.diagnostics(),
                    err,
                );
            };
            defer document.deinit();
            const stylus_options = options.stylus orelse native_stylus_evaluator.Options{
                .output_style = switch (options.format) {
                    .pretty => .expanded,
                    .minified => .compressed,
                },
            };
            native_stylus_evaluator.evaluateWithOptions(
                &sources,
                &document,
                &transaction,
                stylus_options,
                options.limits.stylus_evaluator,
            ) catch |err| {
                return reportFailure(
                    allocator,
                    &sources,
                    transaction.diagnostics(),
                    err,
                );
            };
        },
    }

    var validated = transaction.finish(.{
        .format = options.format,
        .source_map = options.source_map,
    }) catch |err| {
        return reportFailure(
            allocator,
            &sources,
            transaction.diagnostics(),
            err,
        );
    };
    errdefer validated.deinit();
    return .{ .success = .{ .sources = sources, .validated = validated } };
}

fn reportFailure(
    allocator: std.mem.Allocator,
    sources: *native_source.Table,
    diagnostics: []const native_diagnostics.Diagnostic,
    cause: Error,
) Error!CompileOutcome {
    var has_error = false;
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) {
            has_error = true;
            break;
        }
    }
    if (!has_error) return cause;
    const owned = try native_evaluator.cloneNativeDiagnostics(allocator, diagnostics);
    return .{ .failure = .{
        .sources = sources.*,
        .diagnostic_items = owned,
        .cause = cause,
    } };
}
