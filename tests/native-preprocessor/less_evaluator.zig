const std = @import("std");
const preprocessor = @import("native_preprocessor");
const diagnostics = preprocessor.diagnostics;
const evaluator = preprocessor.evaluator;
const less = preprocessor.less;
const less_evaluator = preprocessor.less_evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;

// Closed Less 4.6.7 references for the admitted evaluator slices:
// less-lazy-eval-lazy-eval, less-scope-scope, less-variables-variables,
// less-mixins-guards-mixins-guards, less-detached-rulesets-detached-rulesets,
// less-extend-extend, less-operations-operations,
// less-color-functions-basic, less-error-eval-add-mixed-units,
// less-error-eval-recursive-variable, and
// less-error-eval-at-rules-undefined-var. The terminal import foundation is
// anchored to less-import-import-once, less-import-import-interpolation,
// less-import-import-reference-issues, less-charsets-charsets, and
// less-layer-layer without claiming their complete NLESS-012 corpus surface.

const ImportFile = struct {
    name: []const u8,
    contents: []const u8,
};

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

fn compileImportFixture(
    allocator: std.mem.Allocator,
    root_input: []const u8,
    files: []const ImportFile,
    options: less_evaluator.Options,
    semantic_limits: less_evaluator.Limits,
    resolver_limits: resolver.Limits,
    resolver_cancellation: resolver.Cancellation,
) !evaluator.ValidatedCss {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    for (files) |file| {
        const relative = try std.fs.path.join(allocator, &.{ "root", file.name });
        defer allocator.free(relative);
        if (std.fs.path.dirname(relative)) |directory| try temporary.dir.makePath(directory);
        try temporary.dir.writeFile(.{ .sub_path = relative, .data = file.contents });
    }
    try temporary.dir.writeFile(.{ .sub_path = "root/input.less", .data = root_input });

    const base = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const root_path = try std.fs.path.join(allocator, &.{ root, "input.less" });
    defer allocator.free(root_path);
    const root_url = try resolver.pathToFileUrl(allocator, root_path);
    defer allocator.free(root_url);

    var authority = try resolver.Resolver.init(allocator, &.{root}, resolver_limits);
    defer authority.deinit();
    var session = authority.createSession(allocator, resolver_cancellation);
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(root_url, root_input);
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
    try less_evaluator.evaluateWithOptions(
        &sources,
        &document,
        &transaction,
        options,
        semantic_limits,
    );
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

const ExpectedImportDiagnostic = struct {
    code: diagnostics.Code,
    message: []const u8,
    source_suffix: []const u8,
};

fn expectImportFailure(
    root_input: []const u8,
    files: []const ImportFile,
    resolver_limits: resolver.Limits,
    resolver_cancellation: resolver.Cancellation,
    expected_error: anyerror,
    expected_diagnostic: ?ExpectedImportDiagnostic,
    expected_dependencies: usize,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    for (files) |file| {
        const relative = try std.fs.path.join(
            std.testing.allocator,
            &.{ "root", file.name },
        );
        defer std.testing.allocator.free(relative);
        if (std.fs.path.dirname(relative)) |directory| try temporary.dir.makePath(directory);
        try temporary.dir.writeFile(.{ .sub_path = relative, .data = file.contents });
    }
    try temporary.dir.writeFile(.{ .sub_path = "root/input.less", .data = root_input });

    const base = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const root_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "input.less" },
    );
    defer std.testing.allocator.free(root_path);
    const root_url = try resolver.pathToFileUrl(std.testing.allocator, root_path);
    defer std.testing.allocator.free(root_url);

    var authority = try resolver.Resolver.init(
        std.testing.allocator,
        &.{root},
        resolver_limits,
    );
    defer authority.deinit();
    var session = authority.createSession(std.testing.allocator, resolver_cancellation);
    defer session.deinit();
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(root_url, root_input);
    var parser = try less.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .{},
        .{},
    );
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
        less_evaluator.evaluateWithOptions(&sources, &document, &transaction, .{}, .{}),
    );
    try std.testing.expectEqual(
        evaluator.GeneratedPosition{ .line = 0, .column = 0 },
        transaction.position(),
    );
    try std.testing.expectEqual(expected_dependencies, session.dependencies().len);
    if (expected_diagnostic) |expected| {
        try std.testing.expectEqual(@as(usize, 1), transaction.diagnostics().len);
        const diagnostic = transaction.diagnostics()[0];
        try std.testing.expectEqual(diagnostics.Severity.err, diagnostic.severity);
        try std.testing.expectEqual(expected.code, diagnostic.code);
        try std.testing.expectEqualStrings(expected.message, diagnostic.message);
        const diagnostic_source = try sources.get(diagnostic.span.source);
        try std.testing.expect(std.mem.endsWith(
            u8,
            diagnostic_source.name,
            expected.source_suffix,
        ));
    } else {
        try std.testing.expectEqual(@as(usize, 0), transaction.diagnostics().len);
    }
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified, .source_map = true }),
    );
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
    try std.testing.expect(result.map().?.segments().len >= 1);
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

test "native Less evaluates the fixed ruleset operation and builtin matrix" {
    const input =
        \\@base: 2px;
        \\.rounded(@r; @tone: red) when (@r > 0px) {
        \\  border-radius: @r;
        \\  color: @tone;
        \\}
        \\@panel: { padding: @base * 3; };
        \\.seed { &:extend(.target); }
        \\.target {
        \\  width: (@base + 4px);
        \\  background: darken(#336699, 10%);
        \\  opacity: percentage(0.5);
        \\  image: url("../img/a b.png");
        \\  .rounded(4px; blue);
        \\  @panel();
        \\}
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".target,.seed{width:6px;background:#264c73;opacity:50%;" ++
            "image:url(\"../img/a b.png\");border-radius:4px;color:blue;padding:6px}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len >= 1);
}

test "native Less closes the confined import option dependency and map foundation" {
    const input =
        \\@import (multiple) "sub/dep";
        \\@import (once) "sub/dep.less";
        \\@import (multiple) "sub/dep";
        \\@import (optional) "missing";
        \\@import "plain.css" layer(foo) screen;
        \\@import (less) "forced.css";
        \\.root { color: @tone; border-color: @leaf; width: @size; }
    ;
    const files = [_]ImportFile{
        .{
            .name = "sub/dep.less",
            .contents =
            \\@import "../leaf";
            \\@tone: blue;
            \\.dep { image: url("../img/a b.png"); color: @leaf; }
            ,
        },
        .{ .name = "leaf.less", .contents = "@leaf: green;" },
        .{ .name = "plain.css", .contents = ".plain { ignored: by-css-import; }" },
        .{
            .name = "forced.css",
            .contents = "@size: 3px; .forced { width: @size * 2; }",
        },
    };
    var first = try compileImportFixture(
        std.testing.allocator,
        input,
        &files,
        .{},
        .{},
        .{},
        .{},
    );
    defer first.deinit();
    var second = try compileImportFixture(
        std.testing.allocator,
        input,
        &files,
        .{},
        .{},
        .{},
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".dep{image:url(\"./img/a b.png\");color:green}" ++
            ".dep{image:url(\"./img/a b.png\");color:green}" ++
            "@import \"plain.css\" layer(foo) screen;.forced{width:6px}" ++
            ".root{color:blue;border-color:green;width:3px}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 3), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 3), first.edges().len);
    try std.testing.expectEqual(resolver.DependencyKind.import, first.dependencies()[0].kind);
    try std.testing.expect(std.mem.endsWith(u8, first.dependencies()[0].url, "/sub/dep.less"));
    try std.testing.expect(std.mem.endsWith(u8, first.dependencies()[1].url, "/leaf.less"));
    try std.testing.expect(std.mem.endsWith(u8, first.dependencies()[2].url, "/forced.css"));
    try std.testing.expect(first.edges()[0].parent_url != null);
    try std.testing.expect(std.mem.endsWith(u8, first.edges()[1].parent_url.?, "/sub/dep.less"));
    try std.testing.expectEqual(@as(u64, 7), first.stats().attempts);
    try std.testing.expect(first.map() != null);
    var mapped_import = false;
    var mapped_root = false;
    var mapped_forced = false;
    for (first.map().?.segments()) |segment| {
        const source_id = segment.source_id orelse continue;
        mapped_import = mapped_import or source_id.value == 1;
        mapped_root = mapped_root or source_id.value == 0;
        mapped_forced = mapped_forced or source_id.value == 3;
    }
    try std.testing.expect(mapped_import and mapped_root and mapped_forced);
}

test "native Less binds the pinned render options to exact arithmetic" {
    var result = try compileImportFixture(
        std.testing.allocator,
        ".a { loose: 1px + 1s; division: 6px / 2; grouped: (6px / 2); }",
        &.{},
        .{},
        .{},
        .{},
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{loose:2px;division:6px / 2;grouped:3px}",
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
    return expectSemanticRejectionWithOptions(
        input,
        expected_error,
        expected_code,
        expected_message,
        expected_start,
        .{},
    );
}

fn expectSemanticRejectionWithOptions(
    input: []const u8,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_start: u32,
    options: less_evaluator.Options,
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
        less_evaluator.evaluateWithOptions(&sources, &document, &transaction, options, .{}),
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

test "native Less evaluates the admitted operation boundary" {
    var result = try compile(
        std.testing.allocator,
        "@size: 1 + 2; .card { width: @size; }",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".card{width:3}", result.css());
}

test "native Less ruleset matrix failures own exact diagnostics without partial CSS" {
    try expectSemanticRejection(
        ".card { .missing(); }",
        error.UndefinedMixin,
        .undefined_variable,
        "native Less mixin .missing is undefined",
        8,
    );
    try expectSemanticRejectionWithOptions(
        ".card { width: 1px + 1s; }",
        error.IncompatibleUnits,
        .invalid_operation,
        "native Less operation uses incompatible units",
        15,
        .{ .strict_units = true },
    );
}

test "native Less import failures own source-aware diagnostics without partial CSS" {
    try expectImportFailure(
        ".safe { color: red; } @import \"missing\";",
        &.{},
        .{},
        .{},
        error.InvalidImport,
        .{
            .code = .invalid_import,
            .message = "native Less import was not found",
            .source_suffix = "/input.less",
        },
        0,
    );
    try expectImportFailure(
        "@import (reference) \"dep\";",
        &.{.{ .name = "dep.less", .contents = ".dep { color: red; }" }},
        .{},
        .{},
        error.InvalidImport,
        .{
            .code = .invalid_import,
            .message = "native Less import syntax is unsupported",
            .source_suffix = "/input.less",
        },
        0,
    );
    try expectImportFailure(
        "@import (less) \"../escaped.less\";",
        &.{},
        .{},
        .{},
        error.InvalidImport,
        .{
            .code = .invalid_import,
            .message = "native Less import load was rejected",
            .source_suffix = "/input.less",
        },
        0,
    );
    try expectImportFailure(
        "@import \"broken\";",
        &.{.{ .name = "broken.less", .contents = ".broken { color: red;" }},
        .{},
        .{},
        error.InvalidSyntax,
        .{
            .code = .syntax,
            .message = "expected a closing delimiter before EOF",
            .source_suffix = "/broken.less",
        },
        1,
    );
    try expectImportFailure(
        "@import \"loop\";",
        &.{.{ .name = "loop.less", .contents = "@import \"input.less\";" }},
        .{},
        .{},
        error.InvalidImport,
        .{
            .code = .invalid_import,
            .message = "native Less import cycle detected",
            .source_suffix = "/loop.less",
        },
        1,
    );
    try expectImportFailure(
        "@import \"script\";",
        &.{.{ .name = "script.less", .contents = "@value: `1 + 1`;" }},
        .{},
        .{},
        error.JavaScriptDisabled,
        .{
            .code = .unsupported_feature,
            .message = "native Less JavaScript evaluation is permanently disabled",
            .source_suffix = "/script.less",
        },
        1,
    );
    try expectImportFailure(
        "@import \"plugin\";",
        &.{.{ .name = "plugin.less", .contents = "@plugin \"unsafe.js\";" }},
        .{},
        .{},
        error.PluginDisabled,
        .{
            .code = .unsupported_feature,
            .message = "native Less plugins are permanently disabled",
            .source_suffix = "/plugin.less",
        },
        1,
    );
}

test "native Less imports own terminal depth and cancellation boundaries" {
    const files = [_]ImportFile{
        .{ .name = "first.less", .contents = "@import \"second\"; .first { a: b; }" },
        .{ .name = "second.less", .contents = ".second { c: d; }" },
    };
    var terminal = try compileImportFixture(
        std.testing.allocator,
        "@import \"first\";",
        &files,
        .{},
        .{},
        .{ .max_depth = 3 },
        .{},
    );
    defer terminal.deinit();
    try std.testing.expectEqualStrings(".second{c:d}.first{a:b}", terminal.css());
    try expectImportFailure(
        "@import \"first\";",
        &files,
        .{ .max_depth = 2 },
        .{},
        error.DepthLimitExceeded,
        .{
            .code = .resource_limit,
            .message = "native Less import resource limit exceeded",
            .source_suffix = "/first.less",
        },
        1,
    );

    const CancelImport = struct {
        fn check(_: *anyopaque, checkpoint: resolver.Checkpoint) bool {
            return checkpoint == .resolve;
        }
    };
    var context: u8 = 0;
    try expectImportFailure(
        "@import \"first\";",
        &files,
        .{},
        .{ .context = &context, .check_fn = CancelImport.check },
        error.Cancelled,
        null,
        0,
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

    limited = .{};
    limited.max_calls = 2;
    var terminal_calls = try compile(
        std.testing.allocator,
        ".copy() { color: red; } .a { .copy(); .copy(); }",
        limited,
    );
    defer terminal_calls.deinit();
    try std.testing.expectEqualStrings(".a{color:red;color:red}", terminal_calls.css());
    limited.max_calls = 1;
    try std.testing.expectError(
        error.CallLimitExceeded,
        compile(
            std.testing.allocator,
            ".copy() { color: red; } .a { .copy(); .copy(); }",
            limited,
        ),
    );

    limited = .{};
    limited.max_expression_depth = 2;
    var terminal_expression = try compile(
        std.testing.allocator,
        ".a { width: (1px + 2px); }",
        limited,
    );
    defer terminal_expression.deinit();
    try std.testing.expectEqualStrings(".a{width:3px}", terminal_expression.css());
    try std.testing.expectError(
        error.ExpressionDepthExceeded,
        compile(
            std.testing.allocator,
            ".a { width: (1px + (2px * 3)); }",
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
        "@base: 2px; .copy(@x) when (@x > 0px) { width: @x + @base; } " ++
            "@rules: { color: darken(#336699, 10%); }; " ++
            ".safe { .copy(4px); @rules(); opacity: percentage(.5); }",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".safe{width:6px;color:#264c73;opacity:50%}",
        result.css(),
    );
}

test "native Less ruleset transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

fn exerciseImportAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compileImportFixture(
        allocator,
        "@import \"dep\"; .root { color: @tone; }",
        &.{.{
            .name = "dep.less",
            .contents = "@tone: blue; .dep { color: @tone; }",
        }},
        .{},
        .{},
        .{},
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".dep{color:blue}.root{color:blue}", result.css());
    try std.testing.expectEqual(@as(usize, 1), result.dependencies().len);
}

test "native Less import transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseImportAllocationFailures,
        .{},
    );
}
