const std = @import("std");
const preprocessor = @import("native_preprocessor");
const diagnostics = preprocessor.diagnostics;
const evaluator = preprocessor.evaluator;
const less = preprocessor.less;
const less_evaluator = preprocessor.less_evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;

// Closed Less 4.6.7 references for this slice: less-lazy-eval-lazy-eval,
// less-scope-scope, less-variables-variables,
// less-error-eval-recursive-variable, and
// less-error-eval-at-rules-undefined-var.

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

test "native Less lazily resolves the pinned variable foundation" {
    const input =
        \\@var: @a;
        \\@a: 100%;
        \\.lazy-eval { width: @var; }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(".lazy-eval{width:100%}", first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len > 0);
    try std.testing.expectEqual(@as(u32, 2), first.map().?.segments()[0].original_line);
}

test "native Less evaluates the pinned lexical scope and nested selector foundation" {
    const input =
        \\@x: red;
        \\@x: blue;
        \\@z: transparent;
        \\.scope1 {
        \\  @y: orange;
        \\  @z: black;
        \\  color: @x;
        \\  border-color: @z;
        \\  .hidden { @x: #131313; }
        \\  .scope2 {
        \\    @y: red;
        \\    color: @x;
        \\    .scope3 {
        \\      @local: white;
        \\      color: @y;
        \\      border-color: @z;
        \\      background-color: @local;
        \\    }
        \\  }
        \\}
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".scope1{color:blue;border-color:black}" ++
            ".scope1 .scope2{color:blue}" ++
            ".scope1 .scope2 .scope3{color:red;border-color:black;background-color:white}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), result.dependencies().len);
    try std.testing.expect(result.map().?.segments().len >= 3);
}

test "native Less resolves pinned redefinition indirection and selector interpolation" {
    const input =
        \\@var: -1;
        \\@fonts: "Trebuchet MS", Verdana, sans-serif;
        \\@f: @fonts;
        \\@name: var;
        \\@type: 5_large;
        \\.variable-redefinition { @var: 0; zero: @var; }
        \\.variable-scope { @var: 4; @var: 2; three: @var; @var: 3; }
        \\.variable-list { font-family: @f; indirect: @@name; }
        \\.icon-@{type} { width: 1px; }
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".variable-redefinition{zero:0}" ++
            ".variable-scope{three:3}" ++
            ".variable-list{font-family:\"Trebuchet MS\",Verdana,sans-serif;indirect:-1}" ++
            ".icon-5_large{width:1px}",
        result.css(),
    );
}

fn expectSemanticRejection(
    input: []const u8,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_start: u32,
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
    const source_id = try sources.add("semantic-error.less", input);
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
    try std.testing.expectEqual(expected_code, transaction.diagnostics()[0].code);
    try std.testing.expectEqualStrings(expected_message, transaction.diagnostics()[0].message);
    try std.testing.expectEqual(expected_start, transaction.diagnostics()[0].span.start);
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified }),
    );
}

test "native Less variable failures own exact diagnostics without partial CSS" {
    try expectSemanticRejection(
        "@bodyColor: darken(@bodyColor, 30%);",
        error.RecursiveVariable,
        .undefined_variable,
        "recursive native Less variable definition for @bodyColor",
        19,
    );
    try expectSemanticRejection(
        "\n@keyframes @name {\n    50% {width: 20px;}\n}",
        error.UndefinedVariable,
        .undefined_variable,
        "native Less variable @name is undefined",
        12,
    );
}

test "native Less lazy foundation retains later semantic boundaries" {
    try expectSemanticRejection(
        "@size: 1 + 2; .card { width: @size; }",
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Less operations and functions are not implemented in this evaluator slice",
        7,
    );
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

    limited = .{};
    limited.environment.max_bindings = 1;
    try std.testing.expectError(
        error.BindingLimitExceeded,
        compile(std.testing.allocator, "@a: 1; @b: 2; .safe { value: @a; }", limited),
    );

    limited = .{};
    limited.environment.max_scope_depth = 1;
    try std.testing.expectError(
        error.ScopeLimitExceeded,
        compile(std.testing.allocator, ".a { .b { color: red; } } @x: 1;", limited),
    );

    limited = .{};
    limited.max_variable_depth = 2;
    var terminal = try compile(
        std.testing.allocator,
        "@first: @second; @second: red; .safe { color: @first; }",
        limited,
    );
    defer terminal.deinit();
    try std.testing.expectEqualStrings(".safe{color:red}", terminal.css());
    try std.testing.expectError(
        error.VariableDepthExceeded,
        compile(
            std.testing.allocator,
            "@first: @second; @second: @third; @third: red; .safe { color: @first; }",
            limited,
        ),
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
    var result = try compile(
        allocator,
        "@late: @value; @value: red; .safe { color: @late; }",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".safe{color:red}", result.css());
}

test "native Less lazy transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
