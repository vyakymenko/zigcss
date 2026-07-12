const std = @import("std");
const zigcss = @import("zigcss");

comptime {
    _ = zigcss.source;
    _ = zigcss.diagnostics;
    _ = zigcss.compilation;
    _ = zigcss.tokenizer;
    _ = zigcss.syntax;
    _ = zigcss.css;
    _ = zigcss.sourcemap;
    _ = zigcss.transform;
    _ = zigcss.prefixing;
    _ = zigcss.plugins;

    _ = zigcss.SourceId;
    _ = zigcss.Span;
    _ = zigcss.SourceLocation;
    _ = zigcss.SourceFile;
    _ = zigcss.SourceManager;
    _ = zigcss.Diagnostic;
    _ = zigcss.DiagnosticCode;
    _ = zigcss.DiagnosticList;
    _ = zigcss.DiagnosticSeverity;
    _ = zigcss.Compilation;
    _ = zigcss.CompileResult;
    _ = zigcss.CompileOptions;
    _ = zigcss.CompileError;
    _ = zigcss.OutputFormat;
    _ = zigcss.SourceMapOptions;
    _ = zigcss.TransformOptions;
    _ = zigcss.PluginOptions;
    _ = zigcss.ExperimentalPluginOptions;
    _ = zigcss.PluginDefinition;
    _ = zigcss.PluginPolicy;
    _ = zigcss.PluginStability;
    _ = zigcss.Syntax;
    _ = zigcss.TargetQuery;
    _ = zigcss.Dependency;
    _ = zigcss.DependencyKind;
    _ = zigcss.DependencyLimits;
    _ = zigcss.CssModuleLimits;
    _ = zigcss.CompileMetrics;
    _ = zigcss.CompileStageTimings;
    _ = zigcss.CompileMemoryMetrics;
    _ = zigcss.ModuleExport;
    _ = zigcss.ModuleExports;
    _ = zigcss.ModuleReference;
    _ = zigcss.ModuleDependencyReference;
    _ = zigcss.Token;
    _ = zigcss.TokenKind;
    _ = zigcss.Tokenizer;
    _ = zigcss.ComponentValue;
    _ = zigcss.ComponentValueDocument;
}

fn externalPluginRun(
    user_data: ?*anyopaque,
    _: *zigcss.transform.pass_manager.Context,
    input: *const zigcss.css.ast.RuleList,
) zigcss.transform.pass_manager.Error!*const zigcss.css.ast.RuleList {
    const ran: *bool = @ptrCast(@alignCast(user_data orelse return error.PassFailed));
    ran.* = true;
    return input;
}

fn externalPluginValidate(
    _: ?*anyopaque,
    _: zigcss.transform.pass_manager.ValidationPhase,
    _: *zigcss.transform.pass_manager.Context,
    _: *const zigcss.css.ast.RuleList,
    _: *const zigcss.css.ast.RuleList,
) zigcss.transform.pass_manager.Error!void {}

test "external consumer imports the public root and owns CSS maps and diagnostics" {
    var result: zigcss.CompileResult = try zigcss.compile(
        std.testing.allocator,
        "consumer.css",
        "@import \"theme.css\";.consumer { color: red; }",
        .{
            .format = .minified,
            .source_map = .{ .external = .{ .generated_file = "consumer.out.css" } },
            .profile = true,
        },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("@import \"theme.css\";.consumer{color:red}", result.css);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expectEqualStrings("theme.css", result.dependencies[0].specifier);
    try std.testing.expect(result.module_exports == null);
    const metrics = result.metrics orelse return error.MissingMetrics;
    try std.testing.expect(metrics.total_time_ns >= metrics.stages.total());
    try std.testing.expect(metrics.memory.peak_live_bytes >= metrics.memory.retained_result_bytes);
    try std.testing.expect(metrics.memory.retained_result_bytes > 0);
    const source_map = result.source_map orelse return error.MissingSourceMap;
    var parsed_map = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        source_map,
        .{},
    );
    defer parsed_map.deinit();
    try std.testing.expectEqualStrings(
        "consumer.css",
        parsed_map.value.object.get("sources").?.array.items[0].string,
    );
}

test "external consumer reaches only explicit transform and target modules" {
    var parsed = try zigcss.css.pipeline.parse(
        std.testing.allocator,
        "consumer-transform.css",
        ".empty{}.a{width:calc(1px + 2px)}",
    );
    defer parsed.deinit();
    try zigcss.transform.verified_optimizer.applyToFixedPoint(
        std.testing.allocator,
        &parsed,
        .minified,
    );
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{width:3px}", result.css);

    const parsed_query = try zigcss.prefixing.target_query.parse(
        std.testing.allocator,
        "chrome >= 120, firefox >= 115",
        .{},
    );
    var query = switch (parsed_query) {
        .query => |value| value,
        .invalid => return error.UnexpectedInvalidTargetQuery,
    };
    defer query.deinit();
    try std.testing.expect(query.validate());
    try std.testing.expectEqual(
        @as(u16, 120),
        query.minimum(.chrome).?.major,
    );
}

test "external consumer owns experimental CSS Modules exports" {
    var result = try zigcss.compile(
        std.testing.allocator,
        "components/external.module.css",
        ".icon{color:blue}.card{composes:icon;composes:global-card from global;" ++
            "composes:external from \"./external.module.css\";color:red}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const exports = result.module_exports orelse return error.MissingModuleExports;
    try std.testing.expectEqual(@as(usize, 2), exports.entries.len);
    try std.testing.expectEqualStrings("icon", exports.entries[0].name);
    try std.testing.expectEqualStrings("card", exports.entries[1].name);
    try std.testing.expect(std.mem.indexOf(u8, result.css, exports.entries[0].value) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, exports.entries[1].value) != null);
    try std.testing.expectEqual(@as(usize, 3), exports.entries[1].composes.len);
    try std.testing.expectEqual(zigcss.DependencyKind.css_module, result.dependencies[0].kind);
}

test "external consumer opts into the borrowed experimental plugin contract" {
    var ran = false;
    const definitions = [_]zigcss.PluginDefinition{.{
        .metadata = .{
            .id = "plugin.external-analysis",
            .revision = 1,
            .phase = .analysis,
            .safety = .analysis,
            .maturity = .experimental,
            .precondition = "the parsed CSS is valid",
            .postcondition = "the callback observes the AST without changing it",
            .no_op_conditions = "analysis always retains the input root",
            .supports_nested_rules = true,
        },
        .run = externalPluginRun,
        .validate = externalPluginValidate,
        .user_data = &ran,
    }};
    var result = try zigcss.compile(
        std.testing.allocator,
        "consumer-plugin.css",
        ".consumer{x:1}",
        .{ .plugins = .{ .experimental = .{
            .definitions = &definitions,
            .requested = &.{"plugin.external-analysis"},
            .policy = .{ .allow_experimental = true },
        } } },
    );
    defer result.deinit();

    try std.testing.expect(ran);
    try std.testing.expectEqualStrings(".consumer {\n  x: 1;\n}\n", result.css);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(zigcss.PluginStability.experimental, zigcss.plugins.stability);
}
