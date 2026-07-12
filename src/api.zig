const std = @import("std");
const compilation = @import("compilation.zig");
const dependencies = @import("dependencies.zig");
const diagnostics = @import("diagnostics.zig");
const emitter = @import("css/emitter.zig");
const pass_manager = @import("transform/pass_manager.zig");
const pipeline = @import("css/pipeline.zig");
const prefix_rewrite = @import("prefixing/rewrite.zig");
const sourcemap = @import("sourcemap.zig");
const source = @import("source.zig");
const target_query = @import("prefixing/target_query.zig");
const verified_optimizer = @import("transform/verified_optimizer.zig");

pub const Syntax = enum {
    css,
};

pub const OutputFormat = enum {
    pretty,
    minified,
};

pub const ExternalSourceMapOptions = struct {
    generated_file: ?[]const u8 = null,
    include_sources_content: bool = true,
};

pub const SourceMapOptions = union(enum) {
    none,
    external: ExternalSourceMapOptions,
};

pub const TransformOptions = struct {
    /// Runs only the closed acceptance-gated optimizer preset.
    optimize: bool = false,
    /// Runs only the verified target-prefix pass and requires `targets`.
    prefix: bool = false,
};

pub const CompileOptions = struct {
    syntax: Syntax = .css,
    format: OutputFormat = .pretty,
    source_map: SourceMapOptions = .none,
    transforms: TransformOptions = .{},
    /// Borrowed for the duration of `compile`; ownership stays with the caller.
    targets: ?*const target_query.Query = null,
    dependency_limits: dependencies.Options = .{},
};

pub const Error = std.mem.Allocator.Error || error{
    SourceTooLarge,
    CompilationFailed,
};

/// Result-owned structured diagnostic. Locations and the source name remain
/// usable after the compilation arena and copied source bytes are released.
pub const Diagnostic = struct {
    severity: diagnostics.Severity,
    code: diagnostics.Code,
    span: source.Span,
    start: source.Location,
    end: source.Location,
    source_name: []const u8,
    message: []const u8,
};

pub const ModuleExport = struct {
    name: []const u8,
    value: []const u8,
};

pub const ModuleExports = struct {
    entries: []const ModuleExport,
};

/// Move-only by convention. Every public slice is owned by this result and is
/// released through `deinit`; no compilation-arena pointer escapes.
pub const CompileResult = struct {
    result_allocator: std.mem.Allocator,
    css: []const u8,
    source_map: ?[]const u8,
    diagnostics: []const Diagnostic,
    dependencies: []const dependencies.Dependency,
    module_exports: ?ModuleExports,

    pub fn take(self: *CompileResult) CompileResult {
        const moved = self.*;
        self.* = empty(self.result_allocator);
        return moved;
    }

    pub fn deinit(self: *CompileResult) void {
        const allocator = self.result_allocator;
        if (self.css.len > 0) allocator.free(self.css);
        if (self.source_map) |bytes| {
            if (bytes.len > 0) allocator.free(bytes);
        }
        releaseDiagnostics(allocator, self.diagnostics);
        dependencies.release(allocator, self.dependencies);
        releaseModuleExports(allocator, self.module_exports);
        self.* = empty(allocator);
    }

    fn empty(allocator: std.mem.Allocator) CompileResult {
        return .{
            .result_allocator = allocator,
            .css = &.{},
            .source_map = null,
            .diagnostics = &.{},
            .dependencies = &.{},
            .module_exports = null,
        };
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    options: CompileOptions,
) Error!CompileResult {
    return compileInternal(allocator, name, input, options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SourceTooLarge => error.SourceTooLarge,
        else => error.CompilationFailed,
    };
}

fn compileInternal(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    options: CompileOptions,
) !CompileResult {
    var parsed = try pipeline.parse(allocator, name, input);
    defer parsed.deinit();
    try validateOptions(&parsed, options);

    var dependency_list = dependencies.OwnedList.init(allocator);
    defer dependency_list.deinit();
    if (!parsed.hasErrors()) {
        dependency_list = try dependencies.collect(
            allocator,
            &parsed,
            options.dependency_limits,
        );
    }

    if (!parsed.hasErrors() and options.transforms.optimize) {
        verified_optimizer.applyToFixedPoint(
            allocator,
            &parsed,
            emitMode(options.format),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OptimizationDidNotConverge => try reportAtStart(
                &parsed,
                .resource_limit,
                "verified optimizer did not reach its bounded fixed point",
            ),
            else => try reportAtStart(
                &parsed,
                .internal,
                "verified optimizer validation failed",
            ),
        };
    }

    if (!parsed.hasErrors() and options.transforms.prefix) {
        applyPrefix(allocator, &parsed, options.targets.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try reportAtStart(
                &parsed,
                .internal,
                "target prefix validation failed",
            ),
        };
    }

    var pipeline_result = try parsed.emitResult(allocator, pipelineOptions(options));
    defer pipeline_result.deinit();
    return try promoteResult(
        allocator,
        parsed.file(),
        &pipeline_result,
        &dependency_list,
    );
}

fn validateOptions(parsed: *pipeline.ParsedStylesheet, options: CompileOptions) !void {
    _ = options.syntax;
    if (options.transforms.optimize and options.source_map != .none) {
        try reportAtStart(
            parsed,
            .invalid_option,
            "source maps are unavailable with fixed-point optimization",
        );
    }
    if (options.transforms.prefix) {
        if (options.targets) |query| {
            if (!query.validate()) {
                try reportAtStart(parsed, .invalid_option, "target query is not canonical");
            }
        } else {
            try reportAtStart(parsed, .invalid_option, "prefix transformation requires targets");
        }
    } else if (options.targets != null) {
        try reportAtStart(parsed, .invalid_option, "targets require the prefix transformation");
    }
}

fn reportAtStart(
    parsed: *pipeline.ParsedStylesheet,
    code: diagnostics.Code,
    message: []const u8,
) !void {
    try parsed.compilation.report(
        .err,
        code,
        .{ .source = parsed.source_id, .start = 0, .end = 0 },
        message,
    );
}

fn applyPrefix(
    allocator: std.mem.Allocator,
    parsed: *pipeline.ParsedStylesheet,
    query: *const target_query.Query,
) !void {
    const config = try prefix_rewrite.Configuration.init(allocator, query);
    const registry = [_]pass_manager.Pass{prefix_rewrite.definition(&config)};
    var plan = try pass_manager.buildPlan(
        allocator,
        &registry,
        &.{prefix_rewrite.id},
        .{ .allow_compatibility_rewrite = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{});
}

fn emitMode(format: OutputFormat) emitter.Mode {
    return switch (format) {
        .pretty => .pretty,
        .minified => .minified,
    };
}

fn pipelineOptions(options: CompileOptions) pipeline.Options {
    return .{
        .mode = emitMode(options.format),
        .source_map = switch (options.source_map) {
            .none => null,
            .external => |map| sourcemap.Options{
                .generated_file = map.generated_file,
                .include_sources_content = map.include_sources_content,
            },
        },
    };
}

fn promoteResult(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    pipeline_result: *compilation.CompileResult,
    dependency_list: *dependencies.OwnedList,
) !CompileResult {
    const owned_diagnostics = try cloneDiagnostics(
        allocator,
        file,
        pipeline_result.diagnostics,
    );
    errdefer releaseDiagnostics(allocator, owned_diagnostics);

    var moved = pipeline_result.take();
    const css = moved.css;
    const source_map = moved.source_map;
    moved.css = &.{};
    moved.source_map = null;
    moved.deinit();

    return .{
        .result_allocator = allocator,
        .css = css,
        .source_map = source_map,
        .diagnostics = owned_diagnostics,
        .dependencies = dependency_list.take(),
        .module_exports = null,
    };
}

fn cloneDiagnostics(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    items: []const diagnostics.Diagnostic,
) ![]Diagnostic {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(Diagnostic, items.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer releaseDiagnosticFields(allocator, cloned[0..initialized]);

    for (items, 0..) |diagnostic, index| {
        _ = try file.slice(diagnostic.span);
        const source_name = try allocator.dupe(u8, file.name);
        errdefer if (source_name.len > 0) allocator.free(source_name);
        const message = try allocator.dupe(u8, diagnostic.message);
        errdefer if (message.len > 0) allocator.free(message);
        cloned[index] = .{
            .severity = diagnostic.severity,
            .code = diagnostic.code,
            .span = diagnostic.span,
            .start = try file.location(diagnostic.span.start),
            .end = try file.location(diagnostic.span.end),
            .source_name = source_name,
            .message = message,
        };
        initialized += 1;
    }
    return cloned;
}

fn releaseDiagnostics(allocator: std.mem.Allocator, items: []const Diagnostic) void {
    if (items.len == 0) return;
    releaseDiagnosticFields(allocator, items);
    allocator.free(items);
}

fn releaseDiagnosticFields(allocator: std.mem.Allocator, items: []const Diagnostic) void {
    for (items) |diagnostic| {
        if (diagnostic.source_name.len > 0) allocator.free(diagnostic.source_name);
        if (diagnostic.message.len > 0) allocator.free(diagnostic.message);
    }
}

fn releaseModuleExports(allocator: std.mem.Allocator, exports: ?ModuleExports) void {
    const module_exports = exports orelse return;
    if (module_exports.entries.len == 0) return;
    for (module_exports.entries) |entry| {
        if (entry.name.len > 0) allocator.free(entry.name);
        if (entry.value.len > 0) allocator.free(entry.value);
    }
    allocator.free(module_exports.entries);
}

test "public compile returns owned CSS maps dependencies and no CSS modules" {
    var result = try compile(
        std.testing.allocator,
        "api.css",
        "@import url(\"theme.css\") layer(base);.api{color:red}",
        .{
            .format = .minified,
            .source_map = .{ .external = .{
                .generated_file = "api.out.css",
                .include_sources_content = false,
            } },
        },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "@import url(\"theme.css\") layer(base);.api{color:red}",
        result.css,
    );
    try std.testing.expect(result.source_map != null);
    var parsed_map = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.source_map.?,
        .{},
    );
    defer parsed_map.deinit();
    try std.testing.expectEqualStrings(
        "api.out.css",
        parsed_map.value.object.get("file").?.string,
    );
    try std.testing.expect(parsed_map.value.object.get("sourcesContent") == null);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expectEqualStrings("theme.css", result.dependencies[0].specifier);
    try std.testing.expectEqualStrings("api.css", result.dependencies[0].source_name);
    try std.testing.expect(result.module_exports == null);
}

test "public compile dependency limits discard partial facts" {
    var result = try compile(
        std.testing.allocator,
        "limited-api.css",
        "@import \"one.css\";@import \"two.css\";.a{x:1}",
        .{ .dependency_limits = .{ .max_dependencies = 1 } },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.css.len);
    try std.testing.expectEqual(@as(usize, 0), result.dependencies.len);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(diagnostics.Code.resource_limit, result.diagnostics[0].code);
    try std.testing.expectEqualStrings("limited-api.css", result.diagnostics[0].source_name);
}

test "public compile diagnostics retain source names spans and locations" {
    var result = try compile(
        std.testing.allocator,
        "broken-api.css",
        ".a{broken;color:red}",
        .{ .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.css.len);
    try std.testing.expect(result.source_map == null);
    try std.testing.expectEqual(@as(usize, 0), result.dependencies.len);
    try std.testing.expect(result.diagnostics.len > 0);
    const diagnostic = result.diagnostics[0];
    try std.testing.expectEqual(diagnostics.Code.unexpected_token, diagnostic.code);
    try std.testing.expectEqualStrings("broken-api.css", diagnostic.source_name);
    try std.testing.expectEqual(@as(u32, 1), diagnostic.start.line);
    try std.testing.expectEqual(@as(u32, 4), diagnostic.start.column);
    try std.testing.expect(diagnostic.span.start < diagnostic.span.end);
    try std.testing.expect(diagnostic.message.len > 0);
}

test "public compile rejects incoherent options with structured diagnostics" {
    var query_storage = [_]target_query.Target{};
    const forged = target_query.Query{
        .allocator = std.testing.allocator,
        .targets = &query_storage,
    };
    const cases = [_]CompileOptions{
        .{ .transforms = .{ .prefix = true } },
        .{ .targets = &forged },
        .{ .transforms = .{ .prefix = true }, .targets = &forged },
        .{
            .transforms = .{ .optimize = true },
            .source_map = .{ .external = .{} },
        },
    };
    for (cases) |options| {
        var result = try compile(std.testing.allocator, "options.css", ".a{x:1}", options);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.css.len);
        try std.testing.expect(result.diagnostics.len > 0);
        try std.testing.expectEqual(diagnostics.Code.invalid_option, result.diagnostics[0].code);
        try std.testing.expectEqualStrings("API0001", result.diagnostics[0].code.label());
    }
}

test "public compile composes explicit optimization and target prefixing" {
    const query_result = try target_query.parse(
        std.testing.allocator,
        "chrome >= 22, edge >= 17, firefox >= 10, safari >= 7, ie >= 11",
        .{},
    );
    var query = switch (query_result) {
        .query => |value| value,
        .invalid => return error.UnexpectedInvalidQuery,
    };
    defer query.deinit();
    var result = try compile(
        std.testing.allocator,
        "transformed-api.css",
        ".empty{}.a{width:calc(0px);appearance:none}",
        .{
            .format = .minified,
            .transforms = .{ .optimize = true, .prefix = true },
            .targets = &query,
        },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".empty") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "width:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "-webkit-appearance:none") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.css, "appearance:none}"));
}

test "public compile results support explicit moves and repeated cleanup" {
    var original = try compile(std.testing.allocator, "move-api.css", ".a{x:1}", .{});
    var moved = original.take();
    defer moved.deinit();
    original.deinit();
    original.deinit();
    try std.testing.expectEqualStrings(".a {\n  x: 1;\n}\n", moved.css);
    try std.testing.expectEqual(@as(usize, 0), original.css.len);
}

fn exercisePublicCompileAllocationFailures(allocator: std.mem.Allocator) !void {
    const query_result = try target_query.parse(allocator, "safari >= 7", .{});
    var query = switch (query_result) {
        .query => |value| value,
        .invalid => return error.UnexpectedInvalidQuery,
    };
    defer query.deinit();
    var result = try compile(
        allocator,
        "oom-api.css",
        "@import \"theme.css\";.empty{}.a{appearance:none;width:calc(1px + 2px)}",
        .{
            .format = .minified,
            .transforms = .{ .optimize = true, .prefix = true },
            .targets = &query,
        },
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expect(result.css.len > 0);
}

fn exerciseDiagnosticResultAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, "oom-diagnostic-api.css", ".a{broken}", .{});
    defer result.deinit();
    try std.testing.expect(result.diagnostics.len > 0);
}

test "public compile handles every result and diagnostic allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePublicCompileAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDiagnosticResultAllocationFailures,
        .{},
    );
}
