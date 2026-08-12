const std = @import("std");
const preprocessor = @import("native_preprocessor");
const diagnostics = preprocessor.diagnostics;
const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;
const test_path = @import("test_path.zig");

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    base: []u8,
    root: []u8,
    authority: *resolver.Resolver,
    session: *resolver.Session,
    sources: *source.Table,
    transaction: *evaluator.Transaction,

    fn init(limits: evaluator.Limits, cancellation: evaluator.Cancellation) !Harness {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.makeDir("root");
        const base = try test_path.absoluteTmpDirPath(allocator, &tmp);
        errdefer allocator.free(base);
        const root = try std.fs.path.join(allocator, &.{ base, "root" });
        errdefer allocator.free(root);

        const authority = try allocator.create(resolver.Resolver);
        errdefer allocator.destroy(authority);
        authority.* = try resolver.Resolver.init(allocator, &.{root}, .{});
        errdefer authority.deinit();

        const session = try allocator.create(resolver.Session);
        errdefer allocator.destroy(session);
        session.* = authority.createSession(allocator, .{});
        errdefer session.deinit();

        const sources = try allocator.create(source.Table);
        errdefer allocator.destroy(sources);
        sources.* = source.Table.init(allocator, .{});
        errdefer sources.deinit();

        const transaction = try allocator.create(evaluator.Transaction);
        errdefer allocator.destroy(transaction);
        transaction.* = try evaluator.Transaction.init(
            allocator,
            sources,
            session,
            limits,
            cancellation,
        );
        errdefer transaction.deinit();

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .base = base,
            .root = root,
            .authority = authority,
            .session = session,
            .sources = sources,
            .transaction = transaction,
        };
    }

    fn deinit(self: *Harness) void {
        self.transaction.deinit();
        self.allocator.destroy(self.transaction);
        self.sources.deinit();
        self.allocator.destroy(self.sources);
        self.session.deinit();
        self.allocator.destroy(self.session);
        self.authority.deinit();
        self.allocator.destroy(self.authority);
        self.allocator.free(self.root);
        self.allocator.free(self.base);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn addSource(self: *Harness, name: []const u8, bytes: []const u8) !source.Span {
        const source_id = try self.sources.add(name, bytes);
        return self.sources.span(source_id, 0, @intCast(bytes.len));
    }
};

test "commits complete CSS with owned diagnostics dependencies and maps" {
    var harness = try Harness.init(.{}, .{});
    const span = try harness.addSource("input.scss", "$color: red; .card {}\n");
    try harness.tmp.dir.writeFile(.{ .sub_path = "root/_theme.scss", .data = "$gap: 1rem" });
    const dependency_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ harness.root, "_theme.scss" },
    );
    defer std.testing.allocator.free(dependency_path);
    const dependency_url = try resolver.pathToFileUrl(std.testing.allocator, dependency_path);
    defer std.testing.allocator.free(dependency_url);
    var loaded = try harness.session.load(dependency_url, .{
        .kind = .use,
        .ancestry = &.{},
    });
    defer loaded.deinit();

    var warning = [_]u8{ 'd', 'e', 'p', 'r', 'e', 'c', 'a', 't', 'e', 'd' };
    var related_label = [_]u8{ 'o', 'r', 'i', 'g', 'i', 'n' };
    try harness.transaction.report(.warning, .syntax, span, &warning, &.{.{
        .span = span,
        .label = &related_label,
    }});
    var map_name = [_]u8{ 'c', 'a', 'r', 'd' };
    var first_chunk = [_]u8{ '.', 'c', 'a', 'r', 'd', ' ', '{' };
    try harness.transaction.emitMapped(span, &map_name, &first_chunk);
    try harness.transaction.emit(" color: red; }\n");
    warning[0] = 'X';
    related_label[0] = 'X';
    map_name[0] = 'X';
    first_chunk[1] = 'X';

    var result = try harness.transaction.finish(.{ .format = .minified, .source_map = true });
    harness.deinit();
    defer result.deinit();

    try std.testing.expectEqualStrings(".card{color:red}", result.css());
    try std.testing.expect(result.sourceMap() != null);
    try std.testing.expectEqual(@as(usize, 0), result.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 1), result.nativeDiagnostics().len);
    try std.testing.expectEqualStrings("deprecated", result.nativeDiagnostics()[0].message);
    try std.testing.expectEqualStrings("origin", result.nativeDiagnostics()[0].related[0].label);
    try std.testing.expectEqual(@as(usize, 1), result.dependencies().len);
    try std.testing.expectEqual(resolver.DependencyKind.use, result.dependencies()[0].kind);
    try std.testing.expectEqualStrings(dependency_url, result.dependencies()[0].url);
    try std.testing.expectEqual(@as(usize, 1), result.edges().len);
    try std.testing.expectEqualStrings(dependency_url, result.edges()[0].child_url);
    try std.testing.expectEqual(
        resolver.Stats{ .attempts = 1, .files = 1, .bytes = 10 },
        result.stats(),
    );
    const frontend_map = result.map().?;
    try std.testing.expectEqual(@as(usize, 1), frontend_map.segments().len);
    try std.testing.expectEqual(@as(usize, 1), frontend_map.names().len);
    try std.testing.expectEqualStrings("card", frontend_map.names()[0]);
}

test "deterministic replay produces identical core and frontend output" {
    var first = try Harness.init(.{}, .{});
    defer first.deinit();
    var second = try Harness.init(.{}, .{});
    defer second.deinit();
    const first_span = try first.addSource("input.less", "@x: red;");
    const second_span = try second.addSource("input.less", "@x: red;");
    try first.transaction.consumeOperations(7);
    try second.transaction.consumeOperations(7);
    try first.transaction.emitMapped(first_span, "rule", ".a { color: red; }\n");
    try second.transaction.emitMapped(second_span, "rule", ".a { color: red; }\n");

    var first_result = try first.transaction.finish(.{ .format = .pretty, .source_map = true });
    defer first_result.deinit();
    var second_result = try second.transaction.finish(.{ .format = .pretty, .source_map = true });
    defer second_result.deinit();
    try std.testing.expectEqualStrings(first_result.css(), second_result.css());
    try std.testing.expectEqualStrings(first_result.sourceMap().?, second_result.sourceMap().?);
    try std.testing.expectEqualSlices(
        preprocessor.sourcemap.Segment,
        first_result.map().?.segments(),
        second_result.map().?.segments(),
    );
    try std.testing.expectEqualStrings(
        first_result.map().?.names()[0],
        second_result.map().?.names()[0],
    );
}

test "staging restoration removes speculative CSS and source-map ownership" {
    var harness = try Harness.init(.{}, .{});
    defer harness.deinit();
    const span = try harness.addSource("input.styl", ".kept\n  color red\n");

    try harness.transaction.markMapped(span, "kept-anchor");
    const checkpoint = try harness.transaction.stagingCheckpoint();
    try harness.transaction.emitMapped(span, "discarded", "@media screen{");
    try harness.transaction.emitMapped(span, "discarded-rule", ".discarded{color:red}");
    try harness.transaction.emit("}");
    try harness.transaction.restoreStaging(checkpoint);
    try std.testing.expectEqual(
        evaluator.GeneratedPosition{ .line = 0, .column = 0 },
        harness.transaction.position(),
    );

    try harness.transaction.emit(".kept{color:red}");
    var result = try harness.transaction.finish(.{ .format = .pretty, .source_map = true });
    defer result.deinit();
    try std.testing.expectEqualStrings(".kept {\n  color: red;\n}\n", result.css());
    try std.testing.expectEqual(@as(usize, 1), result.map().?.segments().len);
    try std.testing.expectEqual(@as(usize, 1), result.map().?.names().len);
    try std.testing.expectEqualStrings("kept-anchor", result.map().?.names()[0]);
}

test "generated CSS rejection retains diagnostics but exposes no result" {
    var harness = try Harness.init(.{}, .{});
    defer harness.deinit();
    _ = try harness.addSource("input.scss", ".a{}");
    try harness.transaction.emit(".a { broken; color: red; }");
    try std.testing.expectError(
        error.GeneratedCssRejected,
        harness.transaction.finish(.{ .format = .pretty }),
    );
    try std.testing.expect(harness.transaction.validationDiagnostics().len > 0);
    try std.testing.expectEqualStrings(
        "CSS0007",
        harness.transaction.validationDiagnostics()[0].code.label(),
    );
    try std.testing.expectError(error.SessionFailed, harness.transaction.emit(".b{}"));
    try std.testing.expectError(error.SessionFailed, harness.transaction.resolverSession());
    try std.testing.expectError(
        error.SessionClosed,
        harness.session.load("file:///missing.scss", .{ .kind = .import, .ancestry = &.{} }),
    );
}

test "native errors and explicit abort are terminal and never validate staged CSS" {
    var failed = try Harness.init(.{}, .{});
    defer failed.deinit();
    const span = try failed.addSource("input.styl", "bad");
    try failed.transaction.emit(".valid { color: red; }");
    try failed.transaction.report(.err, .syntax, span, "invalid expression", &.{});
    try std.testing.expectError(
        error.EvaluationFailed,
        failed.transaction.finish(.{ .format = .minified }),
    );
    try std.testing.expectEqual(@as(usize, 0), failed.transaction.validationDiagnostics().len);
    try std.testing.expectEqualStrings("invalid expression", failed.transaction.diagnostics()[0].message);

    var aborted = try Harness.init(.{}, .{});
    defer aborted.deinit();
    _ = try aborted.addSource("input.sass", ".a\n  color: red\n");
    try aborted.transaction.emit(".a { color: red; }");
    aborted.transaction.abort();
    try std.testing.expectError(
        error.SessionFailed,
        aborted.transaction.finish(.{ .format = .minified }),
    );
    try std.testing.expectError(error.SessionFailed, aborted.transaction.emit(".b{}"));
}

test "successful commit closes the transaction and its resolver session" {
    var harness = try Harness.init(.{}, .{});
    defer harness.deinit();
    _ = try harness.addSource("input.scss", "");
    try harness.transaction.emit(".a { color: red; }");
    var result = try harness.transaction.finish(.{ .format = .minified });
    defer result.deinit();
    try std.testing.expectError(
        error.SessionClosed,
        harness.transaction.finish(.{ .format = .minified }),
    );
    try std.testing.expectError(error.SessionClosed, harness.transaction.emit(".b{}"));
    try std.testing.expectError(
        error.SessionClosed,
        harness.session.load("file:///missing.scss", .{ .kind = .import, .ancestry = &.{} }),
    );
}

test "expected candidate misses do not poison language-owned import search" {
    var harness = try Harness.init(.{}, .{});
    defer harness.deinit();
    _ = try harness.addSource("input.less", "");
    const missing_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ harness.root, "missing.less" },
    );
    defer std.testing.allocator.free(missing_path);
    const missing_url = try resolver.pathToFileUrl(std.testing.allocator, missing_path);
    defer std.testing.allocator.free(missing_url);
    const resolver_session = try harness.transaction.resolverSession();
    try std.testing.expectError(
        error.Missing,
        resolver_session.load(missing_url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try harness.transaction.emit(".fallback { color: red; }");
    var result = try harness.transaction.finish(.{ .format = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(".fallback{color:red}", result.css());
    try std.testing.expectEqual(@as(u64, 1), result.stats().attempts);
}

test "UTF-16 positions are deterministic and malformed output is terminal" {
    var unicode = try Harness.init(.{}, .{});
    defer unicode.deinit();
    _ = try unicode.addSource("input.scss", "");
    try unicode.transaction.emit("a😀\nβ");
    try std.testing.expectEqual(
        evaluator.GeneratedPosition{ .line = 1, .column = 1 },
        unicode.transaction.position(),
    );
    try std.testing.expectError(error.InvalidOutput, unicode.transaction.emit("\r"));
    try std.testing.expectError(error.SessionFailed, unicode.transaction.emit("x"));

    for ([_][]const u8{ "\x00", "\xff" }) |invalid| {
        var harness = try Harness.init(.{}, .{});
        defer harness.deinit();
        _ = try harness.addSource("input.scss", "");
        try std.testing.expectError(error.InvalidOutput, harness.transaction.emit(invalid));
        try std.testing.expectError(
            error.SessionFailed,
            harness.transaction.finish(.{ .format = .minified }),
        );
    }
}

const CancelContext = struct {
    target: evaluator.Checkpoint,
    cancel_on_match: usize = 1,
    seen: usize = 0,
    matched: usize = 0,

    fn check(context: *anyopaque, checkpoint: evaluator.Checkpoint) bool {
        const self: *CancelContext = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (checkpoint != self.target) return false;
        self.matched += 1;
        return self.matched == self.cancel_on_match;
    }
};

test "cooperative cancellation is terminal before emission and validation" {
    var emit_context = CancelContext{ .target = .emit };
    var emit_cancelled = try Harness.init(.{}, .{
        .context = &emit_context,
        .check_fn = CancelContext.check,
    });
    defer emit_cancelled.deinit();
    _ = try emit_cancelled.addSource("input.scss", "");
    try std.testing.expectError(error.Cancelled, emit_cancelled.transaction.emit(".a{}"));
    try std.testing.expect(emit_context.seen > 0);
    try std.testing.expectError(
        error.SessionFailed,
        emit_cancelled.transaction.finish(.{ .format = .minified }),
    );

    var validate_context = CancelContext{ .target = .validate };
    var validate_cancelled = try Harness.init(.{}, .{
        .context = &validate_context,
        .check_fn = CancelContext.check,
    });
    defer validate_cancelled.deinit();
    _ = try validate_cancelled.addSource("input.less", "");
    try validate_cancelled.transaction.emit(".a { color: red; }");
    try std.testing.expectError(
        error.Cancelled,
        validate_cancelled.transaction.finish(.{ .format = .minified }),
    );
    try std.testing.expectEqual(@as(usize, 0), validate_cancelled.transaction.validationDiagnostics().len);

    var emitted_context = CancelContext{ .target = .validate, .cancel_on_match = 3 };
    var emitted_cancelled = try Harness.init(.{}, .{
        .context = &emitted_context,
        .check_fn = CancelContext.check,
    });
    defer emitted_cancelled.deinit();
    _ = try emitted_cancelled.addSource("input.scss", "");
    try emitted_cancelled.transaction.emit(".a { color: red; }");
    try std.testing.expectError(
        error.Cancelled,
        emitted_cancelled.transaction.finish(.{ .format = .minified }),
    );
    try std.testing.expectEqual(@as(usize, 3), emitted_context.matched);

    var commit_context = CancelContext{ .target = .commit };
    var commit_cancelled = try Harness.init(.{}, .{
        .context = &commit_context,
        .check_fn = CancelContext.check,
    });
    defer commit_cancelled.deinit();
    const span = try commit_cancelled.addSource("input.styl", ".a{}");
    try commit_cancelled.transaction.emitMapped(span, "rule", ".a { color: red; }");
    try std.testing.expectError(
        error.Cancelled,
        commit_cancelled.transaction.finish(.{ .format = .minified, .source_map = true }),
    );
    try std.testing.expectEqual(@as(usize, 1), commit_context.matched);
    try std.testing.expectError(
        error.SessionFailed,
        commit_cancelled.transaction.finish(.{ .format = .minified }),
    );
}

test "evaluation output diagnostics maps and execution budgets fail closed" {
    {
        var limits = evaluator.Limits{};
        limits.budget.max_operations = 1;
        var harness = try Harness.init(limits, .{});
        defer harness.deinit();
        try std.testing.expectError(
            error.OperationLimitExceeded,
            harness.transaction.consumeOperations(2),
        );
        try std.testing.expectError(error.SessionFailed, harness.transaction.consumeOperations(1));
    }
    {
        var limits = evaluator.Limits{};
        limits.budget.max_loop_iterations = 1;
        var harness = try Harness.init(limits, .{});
        defer harness.deinit();
        try std.testing.expectError(
            error.LoopLimitExceeded,
            harness.transaction.consumeLoopIterations(2),
        );
    }
    {
        var limits = evaluator.Limits{};
        limits.budget.max_call_depth = 1;
        var harness = try Harness.init(limits, .{});
        defer harness.deinit();
        try harness.transaction.enterCall();
        try std.testing.expectError(error.CallDepthExceeded, harness.transaction.enterCall());
    }
    {
        var limits = evaluator.Limits{};
        limits.budget.max_calls = 1;
        var harness = try Harness.init(limits, .{});
        defer harness.deinit();
        try harness.transaction.enterCall();
        try harness.transaction.leaveCall();
        try std.testing.expectError(error.CallCountExceeded, harness.transaction.enterCall());
    }
    {
        var limits = evaluator.Limits{};
        limits.budget.max_output_bytes = 3;
        var harness = try Harness.init(limits, .{});
        defer harness.deinit();
        try std.testing.expectError(error.OutputLimitExceeded, harness.transaction.emit("abcd"));
    }
    {
        var limits = evaluator.Limits{};
        limits.budget.max_diagnostics = 1;
        limits.diagnostics.max_diagnostics = 1;
        var harness = try Harness.init(limits, .{});
        defer harness.deinit();
        const span = try harness.addSource("input.scss", "x");
        try harness.transaction.report(.warning, .syntax, span, "one", &.{});
        try std.testing.expectError(
            error.DiagnosticLimitExceeded,
            harness.transaction.report(.warning, .syntax, span, "two", &.{}),
        );
    }
    {
        var harness = try Harness.init(.{ .source_map = .{ .max_segments = 1 } }, .{});
        defer harness.deinit();
        const span = try harness.addSource("input.scss", "x");
        try harness.transaction.markMapped(span, null);
        try harness.transaction.emit("a");
        try std.testing.expectError(error.MappingLimitExceeded, harness.transaction.markUnmapped());
    }
    {
        var harness = try Harness.init(.{}, .{});
        defer harness.deinit();
        _ = try harness.addSource("input.scss", "");
        try harness.transaction.enterCall();
        try harness.transaction.emit(".a{}");
        try std.testing.expectError(
            error.UnbalancedCalls,
            harness.transaction.finish(.{ .format = .minified }),
        );
    }
}

test "validated CSS and core source maps have independent hard result ceilings" {
    {
        var harness = try Harness.init(.{ .max_validated_css_bytes = 1 }, .{});
        defer harness.deinit();
        _ = try harness.addSource("input.scss", "");
        try harness.transaction.emit(".a { color: red; }");
        try std.testing.expectError(
            error.ValidatedOutputLimitExceeded,
            harness.transaction.finish(.{ .format = .minified }),
        );
    }
    {
        var harness = try Harness.init(.{ .max_core_source_map_bytes = 1 }, .{});
        defer harness.deinit();
        const span = try harness.addSource("input.scss", ".a{}");
        try harness.transaction.emitMapped(span, null, ".a { color: red; }");
        try std.testing.expectError(
            error.ValidatedOutputLimitExceeded,
            harness.transaction.finish(.{ .format = .minified, .source_map = true }),
        );
    }
}

test "invalid evaluator limits are rejected before session mutation" {
    var harness = try Harness.init(.{}, .{});
    defer harness.deinit();
    const invalid_limits = [_]evaluator.Limits{
        .{ .budget = .{ .max_output_bytes = 0 } },
        .{ .budget = .{ .max_call_depth = 257 } },
        .{ .diagnostics = .{ .max_diagnostics = 0 } },
        .{ .source_map = .{ .max_segments = 0 } },
        .{ .max_validated_css_bytes = 0 },
        .{ .max_core_source_map_bytes = 0 },
        .{ .max_core_diagnostics = 0 },
    };
    for (invalid_limits) |limits| {
        try std.testing.expectError(
            error.InvalidLimits,
            evaluator.Transaction.init(
                std.testing.allocator,
                harness.sources,
                harness.session,
                limits,
                .{},
            ),
        );
    }
    try harness.transaction.emit(".still-open { color: red; }");
    var result = try harness.transaction.finish(.{ .format = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(".still-open{color:red}", result.css());
}

const AllocationContext = struct {
    root: []const u8,
    dependency_url: []const u8,
};

fn exerciseAllocationFailures(
    allocator: std.mem.Allocator,
    context: *const AllocationContext,
) !void {
    var authority = try resolver.Resolver.init(allocator, &.{context.root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "$x: 1; .a {}");
    const span = try sources.span(source_id, 0, 5);
    var transaction = try evaluator.Transaction.init(allocator, &sources, &session, .{}, .{});
    defer transaction.deinit();

    var loaded = try session.load(context.dependency_url, .{
        .kind = .use,
        .ancestry = &.{},
    });
    defer loaded.deinit();
    try transaction.consumeOperations(3);
    try transaction.enterCall();
    try transaction.leaveCall();
    try transaction.report(.warning, .syntax, span, "warning", &.{.{
        .span = span,
        .label = "related",
    }});
    try transaction.emitMapped(span, "rule", ".a { color: red; }\n");
    var result = try transaction.finish(.{ .format = .minified, .source_map = true });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{color:red}", result.css());
    try std.testing.expectEqual(@as(usize, 1), result.dependencies().len);
}

test "evaluator handles every initialization staging validation and result allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    try tmp.dir.writeFile(.{ .sub_path = "root/_dep.scss", .data = "$dep: 1" });
    const base = try test_path.absoluteTmpDirPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const dependency_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "_dep.scss" },
    );
    defer std.testing.allocator.free(dependency_path);
    const dependency_url = try resolver.pathToFileUrl(std.testing.allocator, dependency_path);
    defer std.testing.allocator.free(dependency_url);
    const context = AllocationContext{ .root = root, .dependency_url = dependency_url };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{&context},
    );
}
