const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const diagnostics = @import("../diagnostics.zig");
const emitter = @import("emitter.zig");
const rule_parser = @import("rule_parser.zig");
const source = @import("../source.zig");
const sourcemap = @import("../sourcemap.zig");
const syntax = @import("../syntax.zig");
const pass_manager = @import("../transform/pass_manager.zig");

pub const CompileResult = compilation.CompileResult;

pub const Options = struct {
    mode: emitter.Mode = .pretty,
    source_map: ?sourcemap.Options = null,
};

/// Owns compilation-lifetime syntax and typed AST data. Emitted results are
/// independently owned and remain valid after this value is deinitialized.
pub const ParsedStylesheet = struct {
    compilation: compilation.Compilation,
    source_id: source.SourceId,
    rules: *const ast.RuleList,

    pub fn deinit(self: *ParsedStylesheet) void {
        self.compilation.deinit();
        self.* = undefined;
    }

    pub fn file(self: *const ParsedStylesheet) *const source.SourceFile {
        return self.compilation.sources.get(self.source_id) catch unreachable;
    }

    pub fn hasErrors(self: *const ParsedStylesheet) bool {
        for (self.compilation.diagnostics.items()) |diagnostic| {
            if (diagnostic.severity == .err) return true;
        }
        return false;
    }

    pub fn emitResult(
        self: *const ParsedStylesheet,
        result_allocator: std.mem.Allocator,
        options: Options,
    ) !CompileResult {
        const diagnostic_items = self.compilation.diagnostics.items();
        if (self.hasErrors()) {
            return CompileResult.init(result_allocator, "", null, diagnostic_items);
        }

        if (options.source_map) |source_map_options| {
            var output = try emitter.emitWithSourceMap(
                result_allocator,
                self.file(),
                self.rules,
                .{ .mode = options.mode },
                source_map_options,
            );
            defer output.deinit();
            return CompileResult.init(
                result_allocator,
                output.css,
                output.source_map,
                diagnostic_items,
            );
        }

        const css = try emitter.emit(
            result_allocator,
            self.file(),
            self.rules,
            .{ .mode = options.mode },
        );
        defer if (css.len > 0) result_allocator.free(css);
        return CompileResult.init(result_allocator, css, null, diagnostic_items);
    }

    pub fn formatDiagnostics(
        self: *const ParsedStylesheet,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var output = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer output.deinit(allocator);
        const writer = output.writer(allocator);
        const source_file = self.file();
        for (self.compilation.diagnostics.items()) |diagnostic| {
            const location: ?source.Location = source_file.location(diagnostic.span.start) catch null;
            if (location) |value| {
                try writer.print(
                    "{s}:{d}:{d}: {s} {s}: {s}\n",
                    .{
                        source_file.name,
                        value.line,
                        value.column,
                        severityLabel(diagnostic.severity),
                        diagnostic.code.label(),
                        diagnostic.message,
                    },
                );
            } else {
                try writer.print(
                    "{s}:byte {d}: {s} {s}: {s}\n",
                    .{
                        source_file.name,
                        diagnostic.span.start,
                        severityLabel(diagnostic.severity),
                        diagnostic.code.label(),
                        diagnostic.message,
                    },
                );
            }
        }
        return output.toOwnedSlice(allocator);
    }

    /// Installs a transformed root only after the complete pass plan and every
    /// validator succeed. Failed arena candidates remain unreachable and are
    /// reclaimed with the compilation.
    pub fn applyPassPlan(
        self: *ParsedStylesheet,
        scratch_allocator: std.mem.Allocator,
        plan: *const pass_manager.Plan,
        options: pass_manager.RunOptions,
    ) pass_manager.Error!void {
        var context = try pass_manager.Context.init(
            &self.compilation,
            self.source_id,
            scratch_allocator,
        );
        const candidate = try plan.run(&context, self.rules, options);
        self.rules = candidate;
    }
};

pub fn parse(
    backing_allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
) !ParsedStylesheet {
    var context = try compilation.Compilation.init(backing_allocator);
    errdefer context.deinit();
    const source_id = try context.addSource(name, input);
    const document = try syntax.parse(&context, source_id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    const rules = try rule_parser.parse(&context, source_id, values);
    return .{
        .compilation = context,
        .source_id = source_id,
        .rules = rules,
    };
}

pub fn compile(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    options: Options,
) !CompileResult {
    var parsed = try parse(allocator, name, input);
    defer parsed.deinit();
    return parsed.emitResult(allocator, options);
}

fn severityLabel(severity: diagnostics.Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

test "safe CSS pipeline emits nesting and independently owned results" {
    var parsed = try parse(
        std.testing.allocator,
        "pipeline.css",
        ".card{color:red;.title{font-weight:bold}@media all{display:grid;> .icon{opacity:1}}background:blue}",
    );
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    parsed.deinit();
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".card{color:red;.title{font-weight:bold}@media all{display:grid;>.icon{opacity:1}}background:blue}",
        result.css,
    );
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.source_map == null);
}

test "safe CSS pipeline returns structured diagnostics without partial CSS" {
    var parsed = try parse(std.testing.allocator, "invalid.css", ".a{broken;color:red}");
    defer parsed.deinit();
    try std.testing.expect(parsed.hasErrors());

    const formatted = try parsed.formatDiagnostics(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "invalid.css:1:4: error CSS0007") != null);

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.css.len);
    try std.testing.expect(result.diagnostics.len > 0);

    var empty_plan = try pass_manager.buildPlan(std.testing.allocator, &.{}, &.{}, .{});
    defer empty_plan.deinit();
    try std.testing.expectError(
        error.InputHasErrors,
        parsed.applyPassPlan(std.testing.allocator, &empty_plan, .{}),
    );
}

test "safe CSS pipeline optionally returns deterministic source maps" {
    var result = try compile(
        std.testing.allocator,
        "mapped.css",
        ".a{color:red}",
        .{
            .mode = .minified,
            .source_map = .{ .generated_file = "mapped.out.css" },
        },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{color:red}", result.css);
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.source_map.?, .{});
    defer json.deinit();
    try std.testing.expectEqualStrings("mapped.out.css", json.value.object.get("file").?.string);
    try std.testing.expectEqualStrings("mapped.css", json.value.object.get("sources").?.array.items[0].string);
}

fn exercisePipelineAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try parse(
        allocator,
        "oom-pipeline.css",
        ".a{color:red;.b{color:blue}@media all{display:grid;> .c{x:1}}background:black}",
    );
    defer parsed.deinit();
    var result = try parsed.emitResult(allocator, .{
        .mode = .minified,
        .source_map = .{ .generated_file = "out.css" },
    });
    defer result.deinit();
    try std.testing.expect(result.css.len > 0);
}

test "safe CSS pipeline handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePipelineAllocationFailures,
        .{},
    );
}

const PipelineTestPassState = struct {
    reject: bool,
};

fn pipelineTestPassRun(
    user_data: ?*anyopaque,
    context: *pass_manager.Context,
    input: *const ast.RuleList,
) pass_manager.Error!*const ast.RuleList {
    _ = user_data;
    const cloned = context.arenaAllocator().create(ast.RuleList) catch return error.OutOfMemory;
    cloned.* = input.*;
    return cloned;
}

fn pipelineTestPassValidate(
    user_data: ?*anyopaque,
    phase: pass_manager.ValidationPhase,
    context: *pass_manager.Context,
    before: *const ast.RuleList,
    after: *const ast.RuleList,
) pass_manager.Error!void {
    _ = context;
    _ = before;
    _ = after;
    const state: *PipelineTestPassState = @ptrCast(@alignCast(user_data.?));
    if (state.reject and phase == .postcondition) return error.ValidationFailed;
}

fn pipelineTestPass(state: *PipelineTestPassState) pass_manager.Pass {
    return .{
        .metadata = .{
            .id = "pipeline-test",
            .revision = 1,
            .phase = .cleanup,
            .safety = .lossless_cleanup,
            .maturity = .verified,
            .precondition = "the parsed stylesheet is valid",
            .postcondition = "the candidate is validated before installation",
            .no_op_conditions = "test pass always clones its root",
            .supports_nested_rules = true,
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
        .run = pipelineTestPassRun,
        .validate = pipelineTestPassValidate,
        .user_data = state,
    };
}

test "safe CSS pipeline installs only fully validated pass plans" {
    var parsed = try parse(std.testing.allocator, "passes.css", ".a{x:1;.b{y:2}}");
    defer parsed.deinit();
    const original = parsed.rules;

    var state = PipelineTestPassState{ .reject = true };
    const registry = [_]pass_manager.Pass{pipelineTestPass(&state)};
    var plan = try pass_manager.buildPlan(
        std.testing.allocator,
        &registry,
        &.{"pipeline-test"},
        .{ .allow_lossless_cleanup = true },
    );
    defer plan.deinit();

    try std.testing.expectError(
        error.ValidationFailed,
        parsed.applyPassPlan(std.testing.allocator, &plan, .{}),
    );
    try std.testing.expect(parsed.rules == original);

    state.reject = false;
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{});
    try std.testing.expect(parsed.rules != original);
}

fn exercisePassPlanAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try parse(allocator, "pass-oom.css", ".a{x:1;.b{y:2}}");
    defer parsed.deinit();
    var state = PipelineTestPassState{ .reject = false };
    const registry = [_]pass_manager.Pass{pipelineTestPass(&state)};
    var plan = try pass_manager.buildPlan(
        allocator,
        &registry,
        &.{"pipeline-test"},
        .{ .allow_lossless_cleanup = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
}

test "safe CSS pass-plan installation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePassPlanAllocationFailures,
        .{},
    );
}
