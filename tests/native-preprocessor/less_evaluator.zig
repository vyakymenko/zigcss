const std = @import("std");
const preprocessor = @import("native_preprocessor");
const diagnostics = preprocessor.diagnostics;
const evaluator = preprocessor.evaluator;
const less = preprocessor.less;
const less_evaluator = preprocessor.less_evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;

fn compile(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: less_evaluator.Limits,
) !evaluator.ValidatedCss {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    const base = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);

    var authority = try resolver.Resolver.init(allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.less", input);
    var parser = try less.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var transaction = try evaluator.Transaction.init(
        allocator,
        &sources,
        &session,
        .{},
        .{},
    );
    defer transaction.deinit();
    try less_evaluator.evaluate(&sources, &document, &transaction, limits);
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

test "native Less transaction preserves the finite plain CSS foundation" {
    const input =
        \\.card { color: red; margin: calc(1px + 2%); content: "`"; }
        \\@media print { .x { --raw: a b; } }
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".card{color:red;margin:calc(1px + 2%);content:\"`\"}@media print{.x{--raw:a b}}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), result.dependencies().len);
    try std.testing.expect(result.map() != null);
    try std.testing.expectEqual(@as(usize, 1), result.map().?.segments().len);
}

fn expectPermanentRejection(
    input: []const u8,
    expected_error: anyerror,
    expected_message: []const u8,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    const base = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);

    var authority = try resolver.Resolver.init(std.testing.allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("rejected.less", input);
    var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var transaction = try evaluator.Transaction.init(
        std.testing.allocator,
        &sources,
        &session,
        .{},
        .{},
    );
    defer transaction.deinit();

    try std.testing.expectError(
        expected_error,
        less_evaluator.evaluate(&sources, &document, &transaction, .{}),
    );
    try std.testing.expectEqual(@as(u32, 0), transaction.position().line);
    try std.testing.expectEqual(@as(u32, 0), transaction.position().column);
    try std.testing.expectEqual(@as(usize, 1), transaction.diagnostics().len);
    try std.testing.expectEqual(diagnostics.Severity.err, transaction.diagnostics()[0].severity);
    try std.testing.expectEqual(
        diagnostics.Code.unsupported_feature,
        transaction.diagnostics()[0].code,
    );
    try std.testing.expectEqualStrings(expected_message, transaction.diagnostics()[0].message);
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified }),
    );
}

test "native Less permanently rejects JavaScript and plugins without partial CSS" {
    for ([_][]const u8{
        ".safe { color: red; } @plugin \"unsafe.js\";",
        ".safe { color: red; } @PLUGIN \"unsafe.js\";",
        ".safe { color: red; } @\\70 lugin \"unsafe.js\";",
    }) |input| {
        try expectPermanentRejection(
            input,
            error.PluginDisabled,
            "native Less plugins are permanently disabled",
        );
    }
    try expectPermanentRejection(
        \\@value: `1 + 1`;
        \\.safe { value: @value; }
    , error.JavaScriptDisabled, "native Less JavaScript evaluation is permanently disabled");
}

const CancelContext = struct {
    fn check(_: *anyopaque, checkpoint: evaluator.Checkpoint) bool {
        return checkpoint == .operation;
    }
};

test "native Less plain CSS foundation owns resource and cancellation boundaries" {
    const input = ".safe { color: red; }";
    var limited = less_evaluator.Limits{};
    limited.max_nodes = 1;
    try std.testing.expectError(
        error.NodeLimitExceeded,
        compile(std.testing.allocator, input, limited),
    );

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    const base = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    var authority = try resolver.Resolver.init(std.testing.allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("cancelled.less", input);
    var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var context: u8 = 0;
    var transaction = try evaluator.Transaction.init(
        std.testing.allocator,
        &sources,
        &session,
        .{},
        .{ .context = &context, .check_fn = CancelContext.check },
    );
    defer transaction.deinit();
    try std.testing.expectError(
        error.Cancelled,
        less_evaluator.evaluate(&sources, &document, &transaction, .{}),
    );
    try std.testing.expectEqual(@as(u32, 0), transaction.position().column);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, ".safe { color: red; }", .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(".safe{color:red}", result.css());
}

test "native Less plain CSS transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
