const std = @import("std");
const ast = @import("css/ast.zig");
const compilation = @import("compilation.zig");
const css_modules = @import("css_modules.zig");
const dependencies = @import("dependencies.zig");
const diagnostics = @import("diagnostics.zig");
const emitter = @import("css/emitter.zig");
const empty_cleanup = @import("transform/empty_cleanup.zig");
const pass_manager = @import("transform/pass_manager.zig");
const pipeline = @import("css/pipeline.zig");
const plugins = @import("plugins.zig");
const prefix_rewrite = @import("prefixing/rewrite.zig");
const profiling = @import("profiling.zig");
const sourcemap = @import("sourcemap.zig");
const source = @import("source.zig");
const target_query = @import("prefixing/target_query.zig");
const verified_optimizer = @import("transform/verified_optimizer.zig");

pub const Syntax = enum {
    css,
    /// Explicit library-only native subset; the CLI does not expose CSS Modules.
    css_modules,
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

/// Native plugins are trusted Zig callbacks and remain explicitly
/// experimental. Selecting this union tag does not create a stable ABI.
pub const PluginOptions = union(enum) {
    none,
    experimental: plugins.ExperimentalOptions,
};

pub const CompileOptions = struct {
    syntax: Syntax = .css,
    format: OutputFormat = .pretty,
    source_map: SourceMapOptions = .none,
    transforms: TransformOptions = .{},
    /// Borrowed for the duration of `compile`; ownership stays with the caller.
    targets: ?*const target_query.Query = null,
    plugins: PluginOptions = .none,
    dependency_limits: dependencies.Options = .{},
    /// Bounds result-owned CSS Modules metadata and source identity work.
    module_limits: css_modules.Limits = .{},
    /// Adds measured stage timings and allocator-requested memory statistics
    /// to the owned result. Disabled calls do not install the tracking wrapper.
    profile: bool = false,
};

pub const Error = std.mem.Allocator.Error || error{
    SourceTooLarge,
    CompilationFailed,
    ProfilingUnavailable,
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

pub const CssModuleLimits = css_modules.Limits;
/// Result-owned decoded export name plus generated class or local value.
pub const ModuleExport = css_modules.Export;
pub const ModuleReference = css_modules.Reference;
pub const ModuleDependencyReference = css_modules.DependencyReference;

pub const ModuleExports = struct {
    /// Unique entries in first authored occurrence order.
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
    metrics: ?profiling.Metrics,

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
            .metrics = null,
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
        error.TimerUnsupported => error.ProfilingUnavailable,
        else => error.CompilationFailed,
    };
}

fn compileInternal(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    options: CompileOptions,
) !CompileResult {
    var profile = try profiling.Session.init(allocator, options.profile);
    const work_allocator = profile.workAllocator();
    var cleanup_started_ns: u64 = 0;
    var result = compile_work: {
        const parse_started_ns = profile.startStage();
        var parsed = try pipeline.parse(work_allocator, name, input);
        profile.endStage(.parse, parse_started_ns);
        defer parsed.deinit();
        var prepared_modules = css_modules.Prepared.init(work_allocator);
        defer prepared_modules.deinit();

        const validation_started_ns = profile.startStage();
        try validateOptions(&parsed, options);
        if (!parsed.hasErrors() and options.syntax == .css_modules) {
            prepared_modules = try css_modules.prepare(
                work_allocator,
                &parsed,
                options.module_limits,
            );
        }
        var plugin_plan: ?pass_manager.Plan = null;
        defer if (plugin_plan) |*plan| plan.deinit();
        if (!parsed.hasErrors()) {
            if (experimentalPlugins(options.plugins)) |plugin_options| {
                plugin_plan = plugins.buildPlan(work_allocator, plugin_options) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => invalid: {
                        try reportAtStart(
                            &parsed,
                            .invalid_plugin,
                            @errorName(err),
                        );
                        break :invalid null;
                    },
                };
            }
        }
        profile.endStage(.validation, validation_started_ns);

        var dependency_list = dependencies.OwnedList.init(work_allocator);
        defer dependency_list.deinit();
        if (!parsed.hasErrors()) {
            const dependency_started_ns = profile.startStage();
            dependency_list = try dependencies.collectWithExtra(
                work_allocator,
                &parsed,
                options.dependency_limits,
                prepared_modules.dependencyCandidates(),
            );
            profile.endStage(.dependencies, dependency_started_ns);
        }

        if (!parsed.hasErrors() and options.transforms.optimize) {
            const optimize_started_ns = profile.startStage();
            verified_optimizer.applyToFixedPoint(
                work_allocator,
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
            profile.endStage(.optimize, optimize_started_ns);
        }

        if (!parsed.hasErrors()) {
            const selected_plugins = requestedPluginCount(options.plugins) != 0;
            if (selected_plugins or options.transforms.prefix) {
                const transform_started_ns = profile.startStage();
                if (selected_plugins) {
                    if (options.transforms.prefix) {
                        const plugin_options = experimentalPlugins(options.plugins).?;
                        applyPluginsAndPrefix(
                            work_allocator,
                            &parsed,
                            plugin_options,
                            options.targets.?,
                        ) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.InvalidCompatibilityData, error.InvalidQuery => try reportAtStart(
                                &parsed,
                                .internal,
                                "target prefix validation failed",
                            ),
                            else => try reportAtStart(
                                &parsed,
                                .plugin_failed,
                                @errorName(err),
                            ),
                        };
                    } else {
                        parsed.applyPassPlan(work_allocator, &plugin_plan.?, .{}) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => try reportAtStart(
                                &parsed,
                                .plugin_failed,
                                @errorName(err),
                            ),
                        };
                    }
                } else {
                    applyPrefix(work_allocator, &parsed, options.targets.?) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => try reportAtStart(
                            &parsed,
                            .internal,
                            "target prefix validation failed",
                        ),
                    };
                }
                profile.endStage(.transform, transform_started_ns);
            }
        }

        const emit_started_ns = profile.startStage();
        var pipeline_result = try parsed.emitResult(
            work_allocator,
            pipelineOptions(options, &prepared_modules),
        );
        profile.endStage(.emit, emit_started_ns);
        defer pipeline_result.deinit();

        const result_started_ns = profile.startStage();
        const promoted = try promoteResult(
            work_allocator,
            allocator,
            parsed.file(),
            &pipeline_result,
            &dependency_list,
            &prepared_modules,
            options.syntax == .css_modules and !parsed.hasErrors(),
        );
        profile.endStage(.result, result_started_ns);
        cleanup_started_ns = profile.startStage();
        break :compile_work promoted;
    };
    profile.endStage(.cleanup, cleanup_started_ns);
    errdefer result.deinit();
    result.metrics = profile.finish();
    return result.take();
}

fn validateOptions(parsed: *pipeline.ParsedStylesheet, options: CompileOptions) !void {
    if (options.syntax == .css_modules and
        (options.transforms.optimize or options.transforms.prefix))
    {
        try reportAtStart(
            parsed,
            .invalid_option,
            "CSS Modules cannot yet be combined with optimizer or prefix transforms",
        );
    }
    if (options.syntax == .css_modules and pluginOptionsSelected(options.plugins)) {
        try reportAtStart(
            parsed,
            .invalid_option,
            "CSS Modules cannot yet be combined with experimental native plugins",
        );
    }
    if (options.transforms.optimize and options.source_map != .none) {
        try reportAtStart(
            parsed,
            .invalid_option,
            "source maps are unavailable with fixed-point optimization",
        );
    }
    if (requestedPluginCount(options.plugins) != 0 and options.source_map != .none) {
        try reportAtStart(
            parsed,
            .invalid_option,
            "source maps are unavailable with experimental native plugins",
        );
    }
    if (options.transforms.prefix and
        requestedPluginCount(options.plugins) != 0 and
        experimentalPlugins(options.plugins).?.definitions.len >= pass_manager.max_passes)
    {
        try reportAtStart(
            parsed,
            .invalid_plugin,
            "plugin registry leaves no bounded slot for target prefixing",
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

fn experimentalPlugins(options: PluginOptions) ?plugins.ExperimentalOptions {
    return switch (options) {
        .none => null,
        .experimental => |value| value,
    };
}

fn requestedPluginCount(options: PluginOptions) usize {
    const plugin_options = experimentalPlugins(options) orelse return 0;
    return plugin_options.requested.len;
}

fn pluginOptionsSelected(options: PluginOptions) bool {
    return switch (options) {
        .none => false,
        .experimental => true,
    };
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
    return prefix_rewrite.applyToStylesheet(allocator, parsed, query);
}

fn applyPluginsAndPrefix(
    allocator: std.mem.Allocator,
    parsed: *pipeline.ParsedStylesheet,
    plugin_options: plugins.ExperimentalOptions,
    query: *const target_query.Query,
) !void {
    const prefix_config = try prefix_rewrite.Configuration.init(allocator, query);
    const registry_len = std.math.add(
        usize,
        plugin_options.definitions.len,
        1,
    ) catch return error.TooManyPasses;
    const registry = try allocator.alloc(pass_manager.Pass, registry_len);
    defer allocator.free(registry);
    @memcpy(
        registry[0..plugin_options.definitions.len],
        plugin_options.definitions,
    );
    registry[plugin_options.definitions.len] = prefix_rewrite.definition(&prefix_config);

    const requested_len = std.math.add(
        usize,
        plugin_options.requested.len,
        1,
    ) catch return error.TooManyPasses;
    const requested = try allocator.alloc([]const u8, requested_len);
    defer allocator.free(requested);
    @memcpy(requested[0..plugin_options.requested.len], plugin_options.requested);
    requested[plugin_options.requested.len] = prefix_rewrite.id;

    var policy = plugin_options.policy;
    // The plugin-only plan was already validated against the caller's exact
    // policy. This additional authority selects only the non-namespaced
    // built-in prefix pass because plugin dependencies cannot cross namespaces.
    policy.allow_compatibility_rewrite = true;
    var plan = try pass_manager.buildPlan(allocator, registry, requested, policy);
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{});
}

fn emitMode(format: OutputFormat) emitter.Mode {
    return switch (format) {
        .pretty => .pretty,
        .minified => .minified,
    };
}

fn pipelineOptions(
    options: CompileOptions,
    prepared_modules: *const css_modules.Prepared,
) pipeline.Options {
    return .{
        .mode = emitMode(options.format),
        .source_map = switch (options.source_map) {
            .none => null,
            .external => |map| sourcemap.Options{
                .generated_file = map.generated_file,
                .include_sources_content = map.include_sources_content,
            },
        },
        .class_rewrites = switch (options.syntax) {
            .css => null,
            .css_modules => prepared_modules.classes(),
        },
        .scope_rewrites = switch (options.syntax) {
            .css => null,
            .css_modules => prepared_modules.scopes(),
        },
        .omit_declarations = switch (options.syntax) {
            .css => null,
            .css_modules => prepared_modules.declarationsToOmit(),
        },
        .value_rewrites = switch (options.syntax) {
            .css => null,
            .css_modules => prepared_modules.values(),
        },
        .omit_rules = switch (options.syntax) {
            .css => null,
            .css_modules => prepared_modules.rulesToOmit(),
        },
    };
}

fn promoteResult(
    work_allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    pipeline_result: *compilation.CompileResult,
    dependency_list: *dependencies.OwnedList,
    prepared_modules: *css_modules.Prepared,
    publish_module_exports: bool,
) !CompileResult {
    const owned_diagnostics = try cloneDiagnostics(
        work_allocator,
        file,
        pipeline_result.diagnostics,
    );
    errdefer releaseDiagnostics(work_allocator, owned_diagnostics);

    var moved = pipeline_result.take();
    const css = moved.css;
    const source_map = moved.source_map;
    moved.css = &.{};
    moved.source_map = null;
    moved.deinit();

    return .{
        .result_allocator = result_allocator,
        .css = css,
        .source_map = source_map,
        .diagnostics = owned_diagnostics,
        .dependencies = dependency_list.take(),
        .module_exports = if (publish_module_exports)
            .{ .entries = prepared_modules.takeExports() }
        else
            null,
        .metrics = null,
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
    css_modules.release(allocator, module_exports.entries);
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
    try std.testing.expect(result.metrics == null);
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
    var original = try compile(
        std.testing.allocator,
        "move-api.css",
        ".a{x:1}",
        .{ .profile = true },
    );
    var moved = original.take();
    original.deinit();
    original.deinit();
    try std.testing.expectEqualStrings(".a {\n  x: 1;\n}\n", moved.css);
    try std.testing.expectEqual(@as(usize, 0), original.css.len);
    try std.testing.expect(original.metrics == null);
    try std.testing.expect(moved.metrics != null);
    moved.deinit();
    moved.deinit();
    try std.testing.expect(moved.metrics == null);
}

test "public compile profiling measures actual stages and requested memory" {
    var result = try compile(
        std.testing.allocator,
        "profiled-api.css",
        "@import \"theme.css\";.empty{}.a{width:calc(1px + 2px);color:#ffffff}",
        .{
            .format = .minified,
            .transforms = .{ .optimize = true },
            .profile = true,
        },
    );
    defer result.deinit();

    const metrics = result.metrics orelse return error.MissingMetrics;
    try std.testing.expectEqualStrings("@import \"theme.css\";.a{width:3px;color:#fff}", result.css);
    try std.testing.expect(metrics.total_time_ns >= metrics.stages.total());
    try std.testing.expect(metrics.stages.parse_time_ns > 0);
    try std.testing.expect(metrics.stages.optimize_time_ns > 0);
    try std.testing.expectEqual(@as(u64, 0), metrics.stages.transform_time_ns);
    try std.testing.expect(metrics.memory.total_allocated_bytes > 0);
    try std.testing.expect(metrics.memory.total_freed_bytes > 0);
    try std.testing.expect(metrics.memory.peak_live_bytes >= metrics.memory.retained_result_bytes);
    try std.testing.expect(metrics.memory.retained_result_bytes > result.css.len);
    try std.testing.expectEqual(
        metrics.memory.retained_result_bytes,
        metrics.memory.total_allocated_bytes - metrics.memory.total_freed_bytes,
    );
    try std.testing.expect(metrics.memory.allocation_count > 0);
    try std.testing.expect(metrics.memory.deallocation_count > 0);
}

test "public compile profiling returns metrics with structured diagnostics" {
    var result = try compile(
        std.testing.allocator,
        "profiled-invalid.css",
        ".a{broken}",
        .{ .format = .minified, .profile = true },
    );
    defer result.deinit();

    const metrics = result.metrics orelse return error.MissingMetrics;
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 0), result.css.len);
    try std.testing.expect(metrics.total_time_ns >= metrics.stages.total());
    try std.testing.expect(metrics.stages.parse_time_ns > 0);
    try std.testing.expectEqual(@as(u64, 0), metrics.stages.optimize_time_ns);
    try std.testing.expectEqual(@as(u64, 0), metrics.stages.transform_time_ns);
    try std.testing.expect(metrics.memory.retained_result_bytes > 0);
}

fn exercisePublicCompileAllocationFailures(allocator: std.mem.Allocator) !void {
    const query_result = try target_query.parse(allocator, "safari >= 7", .{});
    var query = switch (query_result) {
        .query => |value| value,
        .invalid => return error.UnexpectedInvalidQuery,
    };
    defer query.deinit();
    var log = PluginTestLog{};
    var plugin_state = PluginTestState{ .log = &log, .marker = 'o', .action = .success };
    const definitions = [_]plugins.Definition{
        pluginTestDefinition("plugin.oom", 0, &plugin_state),
    };
    var result = try compile(
        allocator,
        "oom-api.css",
        "@import \"theme.css\";.empty{}.a{appearance:none;width:calc(1px + 2px)}",
        .{
            .format = .minified,
            .transforms = .{ .optimize = true, .prefix = true },
            .targets = &query,
            .plugins = .{ .experimental = .{
                .definitions = &definitions,
                .requested = &.{"plugin.oom"},
                .policy = .{ .allow_experimental = true },
            } },
            .profile = true,
        },
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expect(result.css.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "-webkit-appearance:none") != null);
    try std.testing.expectEqualStrings("o", log.bytes[0..log.len]);
}

fn exerciseDiagnosticResultAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, "oom-diagnostic-api.css", ".a{broken}", .{ .profile = true });
    defer result.deinit();
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expect(result.metrics != null);
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
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePluginDiagnosticAllocationFailures,
        .{},
    );
}

const PluginTestLog = struct {
    bytes: [16]u8 = undefined,
    len: usize = 0,

    fn append(self: *PluginTestLog, byte: u8) pass_manager.Error!void {
        if (self.len == self.bytes.len) return error.PassFailed;
        self.bytes[self.len] = byte;
        self.len += 1;
    }
};

const PluginTestAction = enum {
    success,
    warning,
    fail,
    oom,
};

const PluginTestState = struct {
    log: *PluginTestLog,
    marker: u8,
    action: PluginTestAction,
};

fn pluginTestRun(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    const state: *PluginTestState = @ptrCast(@alignCast(user_data orelse return error.PassFailed));
    try state.log.append(state.marker);
    switch (state.action) {
        .success => {},
        .warning => context.compilation.report(
            .warning,
            .unexpected_token,
            input.span,
            "experimental plugin warning",
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PassFailed,
        },
        .fail => return error.PassFailed,
        .oom => return error.OutOfMemory,
    }
    return input;
}

fn pluginTestValidate(
    _: ?*anyopaque,
    _: pass_manager.ValidationPhase,
    _: *pass_manager.Context,
    _: *const ast.RuleList,
    _: *const ast.RuleList,
) pass_manager.Error!void {}

fn pluginTestDefinition(
    id: []const u8,
    priority: u16,
    state: *PluginTestState,
) plugins.Definition {
    return .{
        .metadata = .{
            .id = id,
            .revision = 1,
            .phase = .analysis,
            .priority = priority,
            .safety = .analysis,
            .maturity = .experimental,
            .precondition = "the parsed CSS is valid",
            .postcondition = "the plugin records analysis without changing CSS",
            .no_op_conditions = "analysis plugins never replace the root",
            .supports_nested_rules = true,
        },
        .run = pluginTestRun,
        .validate = pluginTestValidate,
        .user_data = state,
    };
}

fn exercisePluginDiagnosticAllocationFailures(allocator: std.mem.Allocator) !void {
    var cleanup = empty_cleanup.definition();
    cleanup.metadata.id = "plugin.denied-oom-cleanup";
    cleanup.metadata.maturity = .experimental;
    const denied_definitions = [_]plugins.Definition{cleanup};
    {
        var denied = try compile(
            allocator,
            "denied-plugin-oom.css",
            ".empty{}",
            .{ .plugins = .{ .experimental = .{
                .definitions = &denied_definitions,
                .requested = &.{"plugin.denied-oom-cleanup"},
                .policy = .{ .allow_experimental = true },
            } } },
        );
        defer denied.deinit();
        try std.testing.expectEqual(diagnostics.Code.invalid_plugin, denied.diagnostics[0].code);
    }

    var log = PluginTestLog{};
    var failing_state = PluginTestState{ .log = &log, .marker = 'f', .action = .fail };
    const failing_definitions = [_]plugins.Definition{
        pluginTestDefinition("plugin.failure-oom", 0, &failing_state),
    };
    var failed = try compile(
        allocator,
        "failed-plugin-oom.css",
        ".a{x:1}",
        .{ .plugins = .{ .experimental = .{
            .definitions = &failing_definitions,
            .requested = &.{"plugin.failure-oom"},
            .policy = .{ .allow_experimental = true },
        } } },
    );
    defer failed.deinit();
    try std.testing.expectEqual(diagnostics.Code.plugin_failed, failed.diagnostics[0].code);
}

test "experimental native plugins run in deterministic metadata order" {
    var log = PluginTestLog{};
    var states = [_]PluginTestState{
        .{ .log = &log, .marker = 'z', .action = .success },
        .{ .log = &log, .marker = 'a', .action = .success },
        .{ .log = &log, .marker = 'f', .action = .success },
    };
    const definitions = [_]plugins.Definition{
        pluginTestDefinition("plugin.zeta", 10, &states[0]),
        pluginTestDefinition("plugin.alpha", 10, &states[1]),
        pluginTestDefinition("plugin.first", 1, &states[2]),
    };
    var result = try compile(
        std.testing.allocator,
        "plugins.css",
        ".a{x:1}",
        .{ .plugins = .{ .experimental = .{
            .definitions = &definitions,
            .requested = &.{ "plugin.zeta", "plugin.alpha", "plugin.first" },
            .policy = .{ .allow_experimental = true },
        } } },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("faz", log.bytes[0..log.len]);
    try std.testing.expectEqualStrings(".a {\n  x: 1;\n}\n", result.css);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "output-changing plugins require exact policy and publish arena output transactionally" {
    var cleanup = empty_cleanup.definition();
    cleanup.metadata.id = "plugin.empty-rule-cleanup";
    cleanup.metadata.maturity = .experimental;
    const definitions = [_]plugins.Definition{cleanup};

    var denied = try compile(
        std.testing.allocator,
        "denied-cleanup-plugin.css",
        ".empty{}.keep{x:1}",
        .{ .plugins = .{ .experimental = .{
            .definitions = &definitions,
            .requested = &.{"plugin.empty-rule-cleanup"},
            .policy = .{ .allow_experimental = true },
        } } },
    );
    defer denied.deinit();
    try std.testing.expectEqual(@as(usize, 0), denied.css.len);
    try std.testing.expectEqual(diagnostics.Code.invalid_plugin, denied.diagnostics[0].code);
    try std.testing.expectEqualStrings("DisallowedSafetyClass", denied.diagnostics[0].message);

    var accepted = try compile(
        std.testing.allocator,
        "accepted-cleanup-plugin.css",
        ".empty{}.keep{x:1}",
        .{
            .format = .minified,
            .plugins = .{ .experimental = .{
                .definitions = &definitions,
                .requested = &.{"plugin.empty-rule-cleanup"},
                .policy = .{
                    .allow_experimental = true,
                    .allow_lossless_cleanup = true,
                },
            } },
        },
    );
    defer accepted.deinit();
    try std.testing.expectEqualStrings(".keep{x:1}", accepted.css);
    try std.testing.expectEqual(@as(usize, 0), accepted.diagnostics.len);
}

test "plugin configuration and execution failures return owned diagnostics without CSS" {
    var log = PluginTestLog{};
    var invalid_state = PluginTestState{ .log = &log, .marker = 'n', .action = .success };
    const invalid = [_]plugins.Definition{
        pluginTestDefinition("not-namespaced", 0, &invalid_state),
    };
    var invalid_result = try compile(
        std.testing.allocator,
        "invalid-plugin.css",
        ".a{x:1}",
        .{ .plugins = .{ .experimental = .{
            .definitions = &invalid,
            .requested = &.{"not-namespaced"},
            .policy = .{ .allow_experimental = true },
        } } },
    );
    defer invalid_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), invalid_result.css.len);
    try std.testing.expectEqual(@as(usize, 1), invalid_result.diagnostics.len);
    try std.testing.expectEqual(diagnostics.Code.invalid_plugin, invalid_result.diagnostics[0].code);
    try std.testing.expectEqualStrings("API0002", invalid_result.diagnostics[0].code.label());
    try std.testing.expectEqualStrings("InvalidPluginNamespace", invalid_result.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 0), log.len);

    var failing_states = [_]PluginTestState{
        .{ .log = &log, .marker = 'b', .action = .warning },
        .{ .log = &log, .marker = 'x', .action = .fail },
    };
    const failing = [_]plugins.Definition{
        pluginTestDefinition("plugin.before", 0, &failing_states[0]),
        pluginTestDefinition("plugin.failure", 1, &failing_states[1]),
    };
    const query_result = try target_query.parse(std.testing.allocator, "safari >= 7", .{});
    var query = switch (query_result) {
        .query => |value| value,
        .invalid => return error.UnexpectedInvalidQuery,
    };
    defer query.deinit();
    var failed_result = try compile(
        std.testing.allocator,
        "failed-plugin.css",
        "@import \"theme.css\";.a{x:1}",
        .{
            .transforms = .{ .prefix = true },
            .targets = &query,
            .plugins = .{ .experimental = .{
                .definitions = &failing,
                .requested = &.{ "plugin.failure", "plugin.before" },
                .policy = .{ .allow_experimental = true },
            } },
        },
    );
    defer failed_result.deinit();
    try std.testing.expectEqualStrings("bx", log.bytes[0..log.len]);
    try std.testing.expectEqual(@as(usize, 0), failed_result.css.len);
    try std.testing.expectEqual(@as(usize, 1), failed_result.diagnostics.len);
    try std.testing.expectEqual(diagnostics.Code.plugin_failed, failed_result.diagnostics[0].code);
    try std.testing.expectEqualStrings("API0003", failed_result.diagnostics[0].code.label());
    try std.testing.expectEqualStrings("PassFailed", failed_result.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 1), failed_result.dependencies.len);

    var oom_state = PluginTestState{ .log = &log, .marker = 'o', .action = .oom };
    const oom = [_]plugins.Definition{
        pluginTestDefinition("plugin.oom-error", 0, &oom_state),
    };
    try std.testing.expectError(
        error.OutOfMemory,
        compile(
            std.testing.allocator,
            "oom-plugin.css",
            ".a{x:1}",
            .{ .plugins = .{ .experimental = .{
                .definitions = &oom,
                .requested = &.{"plugin.oom-error"},
                .policy = .{ .allow_experimental = true },
            } } },
        ),
    );
}

test "successful plugin warnings are retained and plugin source maps are rejected" {
    var log = PluginTestLog{};
    var warning_state = PluginTestState{ .log = &log, .marker = 'w', .action = .warning };
    const warning = [_]plugins.Definition{
        pluginTestDefinition("plugin.warning", 0, &warning_state),
    };
    const plugin_options = PluginOptions{ .experimental = .{
        .definitions = &warning,
        .requested = &.{"plugin.warning"},
        .policy = .{ .allow_experimental = true },
    } };
    var warning_result = try compile(
        std.testing.allocator,
        "warning-plugin.css",
        ".a{x:1}",
        .{ .plugins = plugin_options },
    );
    defer warning_result.deinit();
    try std.testing.expectEqualStrings("w", log.bytes[0..log.len]);
    try std.testing.expect(warning_result.css.len > 0);
    try std.testing.expectEqual(@as(usize, 1), warning_result.diagnostics.len);
    try std.testing.expectEqual(diagnostics.Severity.warning, warning_result.diagnostics[0].severity);

    var map_result = try compile(
        std.testing.allocator,
        "mapped-plugin.css",
        ".a{x:1}",
        .{
            .source_map = .{ .external = .{} },
            .plugins = plugin_options,
        },
    );
    defer map_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), map_result.css.len);
    try std.testing.expectEqual(diagnostics.Code.invalid_option, map_result.diagnostics[0].code);
    try std.testing.expectEqualStrings("API0001", map_result.diagnostics[0].code.label());
    try std.testing.expectEqualStrings("w", log.bytes[0..log.len]);
}

test "experimental CSS Modules returns deterministic owned exports and mapped CSS" {
    var input = [_]u8{
        '@', 'i', 'm', 'p', 'o', 'r', 't', ' ', '"', 't', 'h', 'e', 'm', 'e', '.', 'c', 's', 's', '"', ';',
        '.', 'c', 'a', 'r', 'd', ',', '.', 'c', 'a', 'r', 'd', ':', 'h', 'o', 'v', 'e', 'r', '{', 'c', 'o',
        'l', 'o', 'r', ':', 'r', 'e', 'd', '}', '@', 'm', 'e', 'd', 'i', 'a', ' ', 'a', 'l', 'l', '{', '.',
        'i', 'c', 'o', 'n', ':', 'i', 's', '(', '.', 'c', 'a', 'r', 'd', ',', '.', 'b', 'a', 'd', 'g', 'e',
        ')', '{', 'd', 'i', 's', 'p', 'l', 'a', 'y', ':', 'b', 'l', 'o', 'c', 'k', '}', '}',
    };
    var result = try compile(
        std.testing.allocator,
        "src/components/card.module.css",
        &input,
        .{
            .syntax = .css_modules,
            .format = .minified,
            .source_map = .{ .external = .{ .generated_file = "card.css" } },
            .profile = true,
        },
    );
    input[22] = 'x';
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expectEqualStrings("theme.css", result.dependencies[0].specifier);
    const module_exports = result.module_exports orelse return error.MissingModuleExports;
    try std.testing.expectEqual(@as(usize, 3), module_exports.entries.len);
    const expected_names = [_][]const u8{ "card", "icon", "badge" };
    for (module_exports.entries, expected_names) |entry, expected_name| {
        try std.testing.expectEqualStrings(expected_name, entry.name);
        try std.testing.expect(std.mem.startsWith(u8, entry.value, "_zigcss_"));
        try std.testing.expect(std.mem.indexOf(u8, result.css, entry.value) != null);
    }
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, result.css, module_exports.entries[0].value),
    );
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".card") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".icon") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".badge") == null);
    try std.testing.expect(result.source_map != null);
    try std.testing.expect(result.metrics != null);
    var map_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.source_map.?,
        .{},
    );
    defer map_json.deinit();
    try std.testing.expectEqualStrings(
        "card.css",
        map_json.value.object.get("file").?.string,
    );
    try std.testing.expectEqualStrings(
        "src/components/card.module.css",
        map_json.value.object.get("sources").?.array.items[0].string,
    );
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        map_json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    var found_card_mapping = false;
    for (mappings) |mapping| {
        if (mapping.generated_line == 0 and
            mapping.generated_column == 20 and
            mapping.original_line == 0 and
            mapping.original_column == 20)
        {
            found_card_mapping = true;
        }
    }
    try std.testing.expect(found_card_mapping);

    var reparsed = try pipeline.parse(std.testing.allocator, "generated.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(!reparsed.hasErrors());
}

test "CSS Modules names normalize separators and vary with source identity" {
    var slash = try compile(
        std.testing.allocator,
        "src/components/card.module.css",
        ".card{x:1}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer slash.deinit();
    var backslash = try compile(
        std.testing.allocator,
        "src\\components\\card.module.css",
        ".card{x:1}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer backslash.deinit();
    var other = try compile(
        std.testing.allocator,
        "src/components/other.module.css",
        ".card{x:1}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer other.deinit();

    const slash_export = slash.module_exports.?.entries[0];
    const backslash_export = backslash.module_exports.?.entries[0];
    const other_export = other.module_exports.?.entries[0];
    try std.testing.expectEqualStrings(slash_export.value, backslash_export.value);
    try std.testing.expectEqualStrings(slash.css, backslash.css);
    try std.testing.expect(!std.mem.eql(u8, slash_export.value, other_export.value));
    try std.testing.expect(!std.mem.eql(u8, slash.css, other.css));
}

test "CSS Modules scopes decoded classes through the closed nested grammar" {
    const input =
        "@layer base;@layer components{.\\31 23{x:1}}" ++
        "@container layout (width>1px){.🔥{x:2}}" ++
        "@starting-style{.enter{x:3}}" ++
        "@font-face{font-family:x;src:url(x)}" ++
        "@property --x{syntax:\"<length>\";inherits:false;initial-value:1px}" ++
        "@keyframes fade{from{opacity:0}to{opacity:1}}";
    var result = try compile(
        std.testing.allocator,
        "nested.module.css",
        input,
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const entries = result.module_exports.?.entries;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("123", entries[0].name);
    try std.testing.expectEqualStrings("🔥", entries[1].name);
    try std.testing.expectEqualStrings("enter", entries[2].name);
    for (entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, result.css, entry.value) != null);
    }
    var reparsed = try pipeline.parse(std.testing.allocator, "nested-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(!reparsed.hasErrors());
}

test "CSS Modules functional scope is occurrence-sensitive and strips wrappers" {
    const input =
        ":local(.card).shell :global(.reset)," ++
        ":global(.shared) .shared:is(:local(.icon),:global(.legacy)){color:red}";
    var result = try compile(
        std.testing.allocator,
        "scopes.module.css",
        input,
        .{
            .syntax = .css_modules,
            .format = .minified,
            .source_map = .{ .external = .{} },
        },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const entries = result.module_exports.?.entries;
    const expected = [_][]const u8{ "card", "shell", "shared", "icon" };
    try std.testing.expectEqual(expected.len, entries.len);
    for (entries, expected) |entry, name| {
        try std.testing.expectEqualStrings(name, entry.name);
        try std.testing.expect(std.mem.indexOf(u8, result.css, entry.value) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.css, ":local") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ":global") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".reset") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".legacy") != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, result.css, entries[2].value),
    );
    var map_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.source_map.?,
        .{},
    );
    defer map_json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        map_json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const card_start = std.mem.indexOf(u8, input, ".card").?;
    var found_inner_class_mapping = false;
    for (mappings) |mapping| {
        if (mapping.original_line == 0 and mapping.original_column == card_start) {
            found_inner_class_mapping = true;
        }
    }
    try std.testing.expect(found_inner_class_mapping);

    var reparsed = try pipeline.parse(std.testing.allocator, "scopes-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(!reparsed.hasErrors());
}

test "CSS Modules global-only scope publishes an owned empty export set" {
    var result = try compile(
        std.testing.allocator,
        "global.module.css",
        ":global(.shared){color:red}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), result.module_exports.?.entries.len);
    try std.testing.expectEqualStrings(".shared{color:red}", result.css);
}

test "CSS Modules composition owns ordered local global and dependency references" {
    const input =
        "@import \"base.css\";.base{color:red}" ++
        ".item{composes:base;composes:reset from global;" ++
        "composes:button icon from \"./theme.module.css\";background:blue}";
    var result = try compile(
        std.testing.allocator,
        "composition.module.css",
        input,
        .{
            .syntax = .css_modules,
            .format = .minified,
            .source_map = .{ .external = .{} },
        },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "composes") == null);
    const entries = result.module_exports.?.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("base", entries[0].name);
    try std.testing.expectEqualStrings("item", entries[1].name);
    try std.testing.expectEqual(@as(usize, 4), entries[1].composes.len);
    switch (entries[1].composes[0]) {
        .local => |name| try std.testing.expectEqualStrings(entries[0].value, name),
        else => return error.UnexpectedModuleReference,
    }
    switch (entries[1].composes[1]) {
        .global => |name| try std.testing.expectEqualStrings("reset", name),
        else => return error.UnexpectedModuleReference,
    }
    const expected_dependency_names = [_][]const u8{ "button", "icon" };
    for (entries[1].composes[2..], expected_dependency_names) |reference, expected_name| {
        switch (reference) {
            .dependency => |dependency| {
                try std.testing.expectEqualStrings(expected_name, dependency.name);
                try std.testing.expectEqualStrings("./theme.module.css", dependency.specifier);
            },
            else => return error.UnexpectedModuleReference,
        }
    }

    try std.testing.expectEqual(@as(usize, 2), result.dependencies.len);
    try std.testing.expectEqual(dependencies.Kind.import, result.dependencies[0].kind);
    try std.testing.expectEqual(dependencies.Kind.css_module, result.dependencies[1].kind);
    try std.testing.expectEqualStrings("./theme.module.css", result.dependencies[1].specifier);
    try std.testing.expectEqualStrings(
        "composition.module.css",
        result.dependencies[1].source_name,
    );
    try std.testing.expect(result.dependencies[1].span.start < result.dependencies[1].span.end);

    var map_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.source_map.?,
        .{},
    );
    defer map_json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        map_json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const composes_start = std.mem.indexOf(u8, input, "composes").?;
    const background_start = std.mem.indexOf(u8, input, "background").?;
    var found_composes_mapping = false;
    var found_background_mapping = false;
    for (mappings) |mapping| {
        if (mapping.original_line != 0) continue;
        found_composes_mapping = found_composes_mapping or
            mapping.original_column == composes_start;
        found_background_mapping = found_background_mapping or
            mapping.original_column == background_start;
    }
    try std.testing.expect(!found_composes_mapping);
    try std.testing.expect(found_background_mapping);

    var reparsed = try pipeline.parse(std.testing.allocator, "composition-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(!reparsed.hasErrors());
}

test "CSS Modules rejects malformed unsafe and cyclic composition" {
    const cases = [_][]const u8{
        ".base{}.item.active{composes:base}",
        ".base{}.item:hover{composes:base}",
        ".item{composes:missing}",
        ".a{composes:b}.b{composes:a}",
        ".base{}.item{color:red;composes:base}",
        ".base{}.item{composes:base!important}",
        ".item{composes:}",
        ".item{composes:from global}",
        ".item{composes:base from}",
        ".item{composes:base from other}",
        ".item{composes:base from \"\"}",
        ".base{}.item{composes:base from global extra}",
        ".base{}.item{composes:(base)}",
        ".base{}.item{composes-with:base}",
        "@font-face{composes:base}",
        ".base{}:local(.item){composes:base}",
    };
    for (cases) |input| {
        var result = try compile(
            std.testing.allocator,
            "bad-composition.module.css",
            input,
            .{ .syntax = .css_modules, .format = .minified },
        );
        defer result.deinit();
        if (result.css.len != 0) {
            std.debug.print("unexpected CSS Modules composition success for {s}: {s}\n", .{
                input,
                result.css,
            });
            return error.UnexpectedModuleSuccess;
        }
        try std.testing.expectEqual(@as(usize, 0), result.dependencies.len);
        try std.testing.expect(result.module_exports == null);
        try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try std.testing.expectEqual(
            diagnostics.Code.unsupported_syntax,
            result.diagnostics[0].code,
        );
    }
}

test "CSS Modules local values export and replace token-aware contexts" {
    const input =
        "@value primary: #bf4040;" ++
        "@value spacing: calc(2px + 2px);" ++
        "@value alias: primary;" ++
        "@value selector: card;" ++
        "@value breakpoint: (min-width: 30em);" ++
        ".selector{color:alias;margin:spacing}" ++
        "@media breakpoint{.selector{border-color:primary}}";
    var result = try compile(
        std.testing.allocator,
        "values.module.css",
        input,
        .{
            .syntax = .css_modules,
            .format = .minified,
            .source_map = .{ .external = .{} },
        },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const entries = result.module_exports.?.entries;
    const expected_names = [_][]const u8{
        "primary",
        "spacing",
        "alias",
        "selector",
        "breakpoint",
        "card",
    };
    const expected_values = [_][]const u8{
        "#bf4040",
        "calc(2px + 2px)",
        "#bf4040",
        "card",
        "(min-width: 30em)",
    };
    try std.testing.expectEqual(expected_names.len, entries.len);
    for (entries, expected_names) |entry, name| try std.testing.expectEqualStrings(name, entry.name);
    for (entries[0..expected_values.len], expected_values) |entry, value| {
        try std.testing.expectEqualStrings(value, entry.value);
        try std.testing.expectEqual(@as(usize, 0), entry.composes.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.css, entries[5].value) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "@value") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, ".selector") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "color:#bf4040") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "margin:calc(2px + 2px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "@media (min-width: 30em)") != null);

    var map_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.source_map.?,
        .{},
    );
    defer map_json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        map_json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const alias_use = std.mem.indexOf(u8, input, "color:alias").? + "color:".len;
    var mapped_alias_use = false;
    var mapped_omitted_value_rule = false;
    for (mappings) |mapping| {
        if (mapping.original_line != 0) continue;
        mapped_alias_use = mapped_alias_use or mapping.original_column == alias_use;
        mapped_omitted_value_rule = mapped_omitted_value_rule or mapping.original_column == 0;
    }
    try std.testing.expect(mapped_alias_use);
    try std.testing.expect(!mapped_omitted_value_rule);

    var reparsed = try pipeline.parse(std.testing.allocator, "values-output.css", result.css);
    defer reparsed.deinit();
    try std.testing.expect(!reparsed.hasErrors());
}

test "CSS Modules values preserve strings normalize comments and feed composition aliases" {
    const input =
        ".before{color:later;content:\"later\";background:url(\"later\")}" ++
        "@value later: red;" ++
        "@value gap: calc(1px/**/+/**/2px);" ++
        "@value path: \"./theme.module.css\";" ++
        "@value classAlias: target;" ++
        ".classAlias{color:later}" ++
        ".item{composes:classAlias;composes:external from path;margin:gap}";
    var result = try compile(
        std.testing.allocator,
        "value-integration.module.css",
        input,
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const entries = result.module_exports.?.entries;
    const expected_names = [_][]const u8{
        "before",
        "later",
        "gap",
        "path",
        "classAlias",
        "target",
        "item",
    };
    try std.testing.expectEqual(expected_names.len, entries.len);
    for (entries, expected_names) |entry, name| try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expectEqualStrings("red", entries[1].value);
    try std.testing.expectEqualStrings("calc(1px + 2px)", entries[2].value);
    try std.testing.expectEqualStrings("\"./theme.module.css\"", entries[3].value);
    try std.testing.expectEqualStrings("target", entries[4].value);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "content:\"later\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "url(\"later\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "color:red") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "margin:calc(1px + 2px)") != null);
    try std.testing.expectEqual(@as(usize, 2), entries[6].composes.len);
    switch (entries[6].composes[0]) {
        .local => |name| try std.testing.expectEqualStrings(entries[5].value, name),
        else => return error.UnexpectedModuleReference,
    }
    switch (entries[6].composes[1]) {
        .dependency => |reference| {
            try std.testing.expectEqualStrings("external", reference.name);
            try std.testing.expectEqualStrings("./theme.module.css", reference.specifier);
        },
        else => return error.UnexpectedModuleReference,
    }
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expectEqualStrings("./theme.module.css", result.dependencies[0].specifier);
}

test "CSS Modules value definitions resolve sequentially while uses see the full table" {
    var result = try compile(
        std.testing.allocator,
        "value-order.module.css",
        ".before{color:later}@value first:later;@value later:red;.after{color:first}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const entries = result.module_exports.?.entries;
    const expected = [_][]const u8{ "before", "first", "later", "after" };
    try std.testing.expectEqual(expected.len, entries.len);
    for (entries, expected) |entry, name| try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expectEqualStrings("later", entries[1].value);
    try std.testing.expectEqualStrings("red", entries[2].value);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "color:red") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "color:later") != null);
}

test "CSS Modules value names and uses share decoded CSS identifier identity" {
    var result = try compile(
        std.testing.allocator,
        "escaped-values.module.css",
        "@value t\\6f ne:red;.x{color:\\74 one}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqualStrings("tone", result.module_exports.?.entries[0].name);
    try std.testing.expectEqualStrings("red", result.module_exports.?.entries[0].value);
    try std.testing.expect(std.mem.indexOf(u8, result.css, "color:red") != null);
}

test "CSS Modules rejects unsupported and ambiguous local value behavior" {
    const cases = [_][]const u8{
        "@value primary from \"./tokens.css\";.x{color:primary}",
        "@value x:;.x{color:red}",
        "@value x:/**/;.x{color:red}",
        "@value x:red",
        "@value x:red;@value x:blue;.x{color:red}",
        "@media all{@value x:red;}.x{color:red}",
        "@value selector:a b;.selector{color:red}",
        "@value token:card;#token{color:red}",
        "@value token:card;token{color:red}",
        "@value token:card;.x[token=token]{color:red}",
        "@value x:!important;.a{color:x}",
        "@value alias:card;@value card:#fff;.alias{color:red}",
        "@value path:red;.item{composes:external from path}",
    };
    for (cases) |input| {
        var result = try compile(
            std.testing.allocator,
            "bad-values.module.css",
            input,
            .{ .syntax = .css_modules, .format = .minified },
        );
        defer result.deinit();
        if (result.css.len != 0) {
            std.debug.print("unexpected CSS Modules value success for {s}: {s}\n", .{
                input,
                result.css,
            });
            return error.UnexpectedModuleSuccess;
        }
        try std.testing.expectEqual(@as(usize, 0), result.dependencies.len);
        try std.testing.expect(result.module_exports == null);
        try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try std.testing.expectEqual(
            diagnostics.Code.unsupported_syntax,
            result.diagnostics[0].code,
        );
    }
}

test "CSS Modules exports survive explicit moves and repeated cleanup" {
    var original = try compile(
        std.testing.allocator,
        "move.module.css",
        ".base{x:0}.card{composes:base;composes:reset from global;" ++
            "composes:button from \"./buttons.module.css\";x:1}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    var moved = original.take();
    original.deinit();
    original.deinit();
    try std.testing.expect(original.module_exports == null);
    try std.testing.expectEqualStrings("card", moved.module_exports.?.entries[1].name);
    try std.testing.expect(std.mem.indexOf(
        u8,
        moved.css,
        moved.module_exports.?.entries[1].value,
    ) != null);
    try std.testing.expectEqual(@as(usize, 3), moved.module_exports.?.entries[1].composes.len);
    try std.testing.expectEqual(dependencies.Kind.css_module, moved.dependencies[0].kind);
    moved.deinit();
    moved.deinit();
    try std.testing.expect(moved.module_exports == null);
}

test "CSS Modules rejects deferred semantics and unsafe scope containers" {
    const cases = [_][]const u8{
        ":local .card{x:1}",
        ":global .card{x:1}",
        ":local(.card,.icon){x:1}",
        ":global(.card .icon){x:1}",
        ":local(:global(.card)){x:1}",
        ":local(#card){x:1}",
        ":local(:hover){x:1}",
        "::global(.card){x:1}",
        ":export{token:red}",
        ".card{composes:base}",
        "@value color from \"./tokens.css\";.card{x:1}",
        ".card:nth-child(2n of .item){x:1}",
        "@supports selector(.card){.card{x:1}}",
        "@unknown{.card{x:1}}",
        "@import \"theme.css\";:local .card{x:1}",
    };
    for (cases) |input| {
        var result = try compile(
            std.testing.allocator,
            "unsupported.module.css",
            input,
            .{ .syntax = .css_modules, .format = .minified },
        );
        defer result.deinit();
        if (result.css.len != 0) {
            std.debug.print("unexpected CSS Modules success for {s}: {s}\n", .{ input, result.css });
            return error.UnexpectedModuleSuccess;
        }
        try std.testing.expectEqual(@as(usize, 0), result.dependencies.len);
        try std.testing.expect(result.module_exports == null);
        try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try std.testing.expectEqual(diagnostics.Code.unsupported_syntax, result.diagnostics[0].code);
    }
}

test "CSS Modules validates identity limits and incompatible transforms" {
    const cases = [_]CompileOptions{
        .{ .syntax = .css_modules, .transforms = .{ .optimize = true } },
        .{ .syntax = .css_modules, .plugins = .{ .experimental = .{} } },
    };
    for (cases) |options| {
        var result = try compile(std.testing.allocator, "options.module.css", ".a{x:1}", options);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.css.len);
        try std.testing.expect(result.module_exports == null);
        try std.testing.expectEqual(diagnostics.Code.invalid_option, result.diagnostics[0].code);
    }

    var unnamed = try compile(
        std.testing.allocator,
        "",
        ".a{x:1}",
        .{ .syntax = .css_modules },
    );
    defer unnamed.deinit();
    try std.testing.expectEqual(diagnostics.Code.invalid_option, unnamed.diagnostics[0].code);
    try std.testing.expect(unnamed.module_exports == null);

    var limited = try compile(
        std.testing.allocator,
        "limited.module.css",
        ".a,.b{x:1}",
        .{
            .syntax = .css_modules,
            .module_limits = .{ .max_exports = 1 },
        },
    );
    defer limited.deinit();
    try std.testing.expectEqual(@as(usize, 0), limited.css.len);
    try std.testing.expect(limited.module_exports == null);
    try std.testing.expectEqual(diagnostics.Code.resource_limit, limited.diagnostics[0].code);

    var byte_limited = try compile(
        std.testing.allocator,
        "byte-limited.module.css",
        ".a{x:1}",
        .{
            .syntax = .css_modules,
            .module_limits = .{ .max_owned_bytes = 1 },
        },
    );
    defer byte_limited.deinit();
    try std.testing.expectEqual(diagnostics.Code.resource_limit, byte_limited.diagnostics[0].code);
    try std.testing.expect(byte_limited.module_exports == null);

    var identity_limited = try compile(
        std.testing.allocator,
        "long.module.css",
        ".a{x:1}",
        .{
            .syntax = .css_modules,
            .module_limits = .{ .max_source_name_bytes = 4 },
        },
    );
    defer identity_limited.deinit();
    try std.testing.expectEqual(diagnostics.Code.resource_limit, identity_limited.diagnostics[0].code);
    try std.testing.expect(identity_limited.module_exports == null);

    var rewrite_limited = try compile(
        std.testing.allocator,
        "rewrite-limited.module.css",
        ".a,.b{x:1}",
        .{
            .syntax = .css_modules,
            .module_limits = .{ .max_rewrites = 1 },
        },
    );
    defer rewrite_limited.deinit();
    try std.testing.expectEqual(@as(usize, 0), rewrite_limited.css.len);
    try std.testing.expect(rewrite_limited.module_exports == null);
    try std.testing.expectEqual(
        diagnostics.Code.resource_limit,
        rewrite_limited.diagnostics[0].code,
    );

    var reference_limited = try compile(
        std.testing.allocator,
        "reference-limited.module.css",
        ".item{composes:one two from \"./dependency.module.css\"}",
        .{
            .syntax = .css_modules,
            .module_limits = .{ .max_references = 1 },
        },
    );
    defer reference_limited.deinit();
    try std.testing.expectEqual(@as(usize, 0), reference_limited.css.len);
    try std.testing.expect(reference_limited.module_exports == null);
    try std.testing.expectEqual(
        diagnostics.Code.resource_limit,
        reference_limited.diagnostics[0].code,
    );

    var value_rewrite_limited = try compile(
        std.testing.allocator,
        "value-rewrite-limited.module.css",
        "@value tone:red;.a{color:tone}",
        .{
            .syntax = .css_modules,
            .module_limits = .{ .max_rewrites = 2 },
        },
    );
    defer value_rewrite_limited.deinit();
    try std.testing.expectEqual(@as(usize, 0), value_rewrite_limited.css.len);
    try std.testing.expect(value_rewrite_limited.module_exports == null);
    try std.testing.expectEqual(
        diagnostics.Code.resource_limit,
        value_rewrite_limited.diagnostics[0].code,
    );

    var combined_export_limited = try compile(
        std.testing.allocator,
        "combined-export-limited.module.css",
        "@value tone:red;.a{color:tone}",
        .{
            .syntax = .css_modules,
            .module_limits = .{ .max_exports = 1 },
        },
    );
    defer combined_export_limited.deinit();
    try std.testing.expectEqual(@as(usize, 0), combined_export_limited.css.len);
    try std.testing.expect(combined_export_limited.module_exports == null);
    try std.testing.expectEqual(
        diagnostics.Code.resource_limit,
        combined_export_limited.diagnostics[0].code,
    );

    var dependency_limited = try compile(
        std.testing.allocator,
        "dependency-limited.module.css",
        "@import \"one.css\";@import \"two.css\";.a{x:1}",
        .{
            .syntax = .css_modules,
            .dependency_limits = .{ .max_dependencies = 1 },
        },
    );
    defer dependency_limited.deinit();
    try std.testing.expectEqual(@as(usize, 0), dependency_limited.css.len);
    try std.testing.expectEqual(@as(usize, 0), dependency_limited.dependencies.len);
    try std.testing.expect(dependency_limited.module_exports == null);
    try std.testing.expectEqual(
        diagnostics.Code.resource_limit,
        dependency_limited.diagnostics[0].code,
    );

    var combined_dependency_limited = try compile(
        std.testing.allocator,
        "combined-dependency-limited.module.css",
        "@import \"one.css\";.item{composes:external from \"./module.css\"}",
        .{
            .syntax = .css_modules,
            .dependency_limits = .{ .max_dependencies = 1 },
        },
    );
    defer combined_dependency_limited.deinit();
    try std.testing.expectEqual(@as(usize, 0), combined_dependency_limited.css.len);
    try std.testing.expectEqual(@as(usize, 0), combined_dependency_limited.dependencies.len);
    try std.testing.expect(combined_dependency_limited.module_exports == null);
    try std.testing.expectEqual(
        diagnostics.Code.resource_limit,
        combined_dependency_limited.diagnostics[0].code,
    );

    var empty = try compile(
        std.testing.allocator,
        "empty.module.css",
        "@import \"theme.css\";",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.module_exports.?.entries.len);
    try std.testing.expectEqual(@as(usize, 1), empty.dependencies.len);
}

fn exerciseCssModulesAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "oom/components.module.css",
        "@value tone:red;@value alias:tone;@value local-scope:scope;" ++
            "@value external-path:\"./external.module.css\";@import \"theme.css\";" ++
            ".base{x:0}.card{composes:base;composes:reset from global;" ++
            "composes:external from external-path;color:alias}" ++
            ".local-scope:is(:local(.icon),:global(.reset)){x:1}",
        .{
            .syntax = .css_modules,
            .format = .minified,
            .source_map = .{ .external = .{} },
            .profile = true,
        },
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 8), result.module_exports.?.entries.len);
    try std.testing.expectEqual(@as(usize, 3), result.module_exports.?.entries[5].composes.len);
    try std.testing.expectEqual(@as(usize, 2), result.dependencies.len);
    try std.testing.expect(result.source_map != null);
    try std.testing.expect(result.metrics != null);
}

test "CSS Modules result construction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCssModulesAllocationFailures,
        .{},
    );
}
