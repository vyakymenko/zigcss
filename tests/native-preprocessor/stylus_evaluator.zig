const std = @import("std");
const preprocessor = @import("native_preprocessor");
const diagnostics = preprocessor.diagnostics;
const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;
const stylus = preprocessor.stylus;
const stylus_evaluator = preprocessor.stylus_evaluator;

fn compile(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: stylus_evaluator.Limits,
) !evaluator.ValidatedCss {
    return compileWithOptions(allocator, input, .{}, limits);
}

fn compileWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: stylus_evaluator.Options,
    limits: stylus_evaluator.Limits,
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
    const source_id = try sources.add("input.styl", input);
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
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
    try stylus_evaluator.evaluateWithOptions(
        &sources,
        &document,
        &transaction,
        options,
        limits,
    );
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

const FixtureFile = struct {
    path: []const u8,
    contents: []const u8,
};

fn compileFixture(
    allocator: std.mem.Allocator,
    input: []const u8,
    files: []const FixtureFile,
    resolver_limits: resolver.Limits,
    evaluator_limits: stylus_evaluator.Limits,
) !evaluator.ValidatedCss {
    return compileFixtureWithCancellation(
        allocator,
        input,
        files,
        resolver_limits,
        evaluator_limits,
        .{},
        .{},
    );
}

fn compileFixtureWithCancellation(
    allocator: std.mem.Allocator,
    input: []const u8,
    files: []const FixtureFile,
    resolver_limits: resolver.Limits,
    evaluator_limits: stylus_evaluator.Limits,
    resolver_cancellation: resolver.Cancellation,
    evaluator_cancellation: evaluator.Cancellation,
) !evaluator.ValidatedCss {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    var root_dir = try temporary.dir.openDir("root", .{});
    defer root_dir.close();
    try root_dir.writeFile(.{ .sub_path = "input.styl", .data = input });
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try root_dir.makePath(parent);
        try root_dir.writeFile(.{ .sub_path = file.path, .data = file.contents });
    }

    const base = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const entry_path = try std.fs.path.join(allocator, &.{ root, "input.styl" });
    defer allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(allocator, entry_path);
    defer allocator.free(entry_url);

    var authority = try resolver.Resolver.init(allocator, &.{root}, resolver_limits);
    defer authority.deinit();
    var session = authority.createSession(allocator, resolver_cancellation);
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(entry_url, input);
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var transaction = try evaluator.Transaction.init(
        allocator,
        &sources,
        &session,
        .{},
        evaluator_cancellation,
    );
    defer transaction.deinit();
    try stylus_evaluator.evaluate(&sources, &document, &transaction, evaluator_limits);
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

fn expectFixtureRejection(
    input: []const u8,
    files: []const FixtureFile,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_source: u32,
    expected_dependencies: usize,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    var root_dir = try temporary.dir.openDir("root", .{});
    defer root_dir.close();
    try root_dir.writeFile(.{ .sub_path = "input.styl", .data = input });
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try root_dir.makePath(parent);
        try root_dir.writeFile(.{ .sub_path = file.path, .data = file.contents });
    }

    const base = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "input.styl" },
    );
    defer std.testing.allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(std.testing.allocator, entry_path);
    defer std.testing.allocator.free(entry_url);

    var authority = try resolver.Resolver.init(std.testing.allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(entry_url, input);
    var parser = try stylus.Parser.init(
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
        stylus_evaluator.evaluate(&sources, &document, &transaction, .{}),
    );
    try std.testing.expectEqual(
        evaluator.GeneratedPosition{ .line = 0, .column = 0 },
        transaction.position(),
    );
    try std.testing.expectEqual(expected_dependencies, session.dependencies().len);
    try std.testing.expectEqual(@as(usize, 1), transaction.diagnostics().len);
    try std.testing.expectEqual(expected_code, transaction.diagnostics()[0].code);
    try std.testing.expectEqualStrings(expected_message, transaction.diagnostics()[0].message);
    try std.testing.expectEqual(
        expected_source,
        transaction.diagnostics()[0].span.source.value,
    );
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified, .source_map = true }),
    );
}

fn expectSemanticRejection(
    input: []const u8,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_start: u32,
) !void {
    return expectSemanticRejectionWithLimits(
        input,
        .{},
        expected_error,
        expected_code,
        expected_message,
        expected_start,
    );
}

fn expectSemanticRejectionWithLimits(
    input: []const u8,
    limits: stylus_evaluator.Limits,
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
    const source_id = try sources.add("semantic-error.styl", input);
    var parser = try stylus.Parser.init(
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
        stylus_evaluator.evaluate(&sources, &document, &transaction, limits),
    );
    try std.testing.expectEqual(
        evaluator.GeneratedPosition{ .line = 0, .column = 0 },
        transaction.position(),
    );
    try std.testing.expectEqual(@as(usize, 0), session.dependencies().len);
    try std.testing.expectEqual(@as(usize, 1), transaction.diagnostics().len);
    try std.testing.expectEqual(expected_code, transaction.diagnostics()[0].code);
    try std.testing.expectEqualStrings(expected_message, transaction.diagnostics()[0].message);
    try std.testing.expectEqual(expected_start, transaction.diagnostics()[0].span.start);
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified, .source_map = true }),
    );
}

test "native Stylus transaction preserves the finite plain CSS foundation" {
    const input =
        \\.card { color: red; margin: calc(1px + 2%); content: "use('safe')"; }
        \\@media print { .x { --raw: a b; } }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".card{color:red;margin:calc(1px + 2%);content:\"use('safe')\"}" ++
            "@media print{.x{--raw:a b}}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len >= 1);
}

test "native Stylus evaluates explicit CSS nested selectors deterministically" {
    const input =
        \\body {
        \\  margin: 0;
        \\  ul {
        \\    margin: 0;
        \\    li:first-child { border-top: none; }
        \\  }
        \\}
        \\ul { li { &:first-child, &:last-child { display: none; } } }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{margin:0}body ul{margin:0}body ul li:first-child{border-top:none}" ++
            "ul li:first-child,ul li:last-child{display:none}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus permanently rejects use plugins without partial CSS" {
    const official_use = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/stylus/corpus/files/upstream/cases/bifs.use.styl",
        1024 * 1024,
    );
    defer std.testing.allocator.free(official_use);
    try expectSemanticRejection(
        official_use,
        error.PluginDisabled,
        .unsupported_feature,
        "native Stylus use() plugins are permanently disabled",
        0,
    );
    try expectSemanticRejection(
        \\.safe { color: red; }
        \\u\73 e('plugins/add.js')
    ,
        error.PluginDisabled,
        .unsupported_feature,
        "native Stylus use() plugins are permanently disabled",
        22,
    );
}

test "native Stylus imports require a confined source identity" {
    try expectSemanticRejection(
        "@require 'theme'\n.safe { color: red; }\n",
        error.InvalidImport,
        .invalid_import,
        "native Stylus import load was rejected",
        0,
    );
}

test "native Stylus closes confined import require glob dependency and map semantics" {
    const input =
        \\@import "tokens"
        \\@import "parts/**/*"
        \\@require "once"
        \\@require "once"
        \\@import "bundle"
        \\.card
        \\  width spacing
    ;
    const files = [_]FixtureFile{
        .{ .path = "tokens.styl", .contents = "spacing = 4px\n.tokens\n  order 0\n" },
        .{ .path = "parts/b.styl", .contents = ".glob-b\n  order 2\n" },
        .{ .path = "parts/a.styl", .contents = ".glob-a\n  order 1\n" },
        .{ .path = "parts/nested/c.styl", .contents = ".glob-c\n  order 3\n" },
        .{ .path = "once.styl", .contents = ".once\n  order 4\n" },
        .{ .path = "bundle/index.styl", .contents = ".indexed\n  order 5\n" },
    };
    var first = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        .{},
        .{},
    );
    defer first.deinit();
    var second = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        .{},
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".tokens{order:0}.glob-a{order:1}.glob-b{order:2}.glob-c{order:3}" ++
            ".once{order:4}.indexed{order:5}.card{width:4px}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 6), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 6), first.edges().len);
    for (first.dependencies()) |dependency| {
        try std.testing.expectEqual(resolver.DependencyKind.import, dependency.kind);
        try std.testing.expect(std.mem.endsWith(u8, dependency.url, ".styl"));
    }
    try std.testing.expect(first.map() != null);
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 6);
}

test "native Stylus import failures own source diagnostics without partial CSS" {
    try expectFixtureRejection(
        "@import \"missing\"\n.safe\n  color red\n",
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import was not found",
        0,
        0,
    );
    try expectFixtureRejection(
        "@import \"bad\"\n.safe\n  color red\n",
        &.{.{ .path = "bad.styl", .contents = ".bad\n  width (\n" }},
        error.InvalidSyntax,
        .syntax,
        "expected a closing delimiter before EOF",
        1,
        1,
    );
    try expectFixtureRejection(
        "@import \"a\"\n.safe\n  color red\n",
        &.{.{ .path = "a.styl", .contents = "@import \"input\"\n.a\n  color blue\n" }},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import cycle detected",
        1,
        1,
    );
    try expectFixtureRejection(
        "@require \"https://example.invalid/theme.styl\"\n",
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import syntax is unsupported",
        0,
        0,
    );
    try expectFixtureRejection(
        "@import \"../outside/escape\"\n",
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import load was rejected",
        0,
        0,
    );
}

const ResolverCancelContext = struct {
    target: resolver.Checkpoint,
    calls: usize = 0,

    fn check(context: *anyopaque, checkpoint: resolver.Checkpoint) bool {
        const self: *ResolverCancelContext = @ptrCast(@alignCast(context));
        self.calls += 1;
        return checkpoint == self.target;
    }
};

test "native Stylus imports own terminal depth count byte and cancellation boundaries" {
    const chain_files = [_]FixtureFile{
        .{ .path = "a.styl", .contents = "@import \"b\"\n.a\n  order 1\n" },
        .{ .path = "b.styl", .contents = ".b\n  order 2\n" },
    };
    var terminal_depth = resolver.Limits{};
    terminal_depth.max_depth = 3;
    var depth_result = try compileFixture(
        std.testing.allocator,
        "@import \"a\"\n",
        &chain_files,
        terminal_depth,
        .{},
    );
    defer depth_result.deinit();
    try std.testing.expectEqualStrings(".b{order:2}.a{order:1}", depth_result.css());

    var over_depth = terminal_depth;
    over_depth.max_depth = 2;
    try std.testing.expectError(
        error.DepthLimitExceeded,
        compileFixture(
            std.testing.allocator,
            "@import \"a\"\n",
            &chain_files,
            over_depth,
            .{},
        ),
    );

    const input =
        \\@import "tokens"
        \\@import "parts/**/*"
        \\@require "once"
        \\@require "once"
    ;
    const files = [_]FixtureFile{
        .{ .path = "tokens.styl", .contents = ".tokens\n  order 0\n" },
        .{ .path = "parts/b.styl", .contents = ".b\n  order 2\n" },
        .{ .path = "parts/a.styl", .contents = ".a\n  order 1\n" },
        .{ .path = "parts/nested/c.styl", .contents = ".c\n  order 3\n" },
        .{ .path = "once.styl", .contents = ".once\n  order 4\n" },
    };
    var terminal_count = resolver.Limits{};
    terminal_count.max_files = files.len;
    var count_result = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_count,
        .{},
    );
    defer count_result.deinit();
    try std.testing.expectEqual(files.len, count_result.dependencies().len);

    var over_count = terminal_count;
    over_count.max_files = files.len - 1;
    try std.testing.expectError(
        error.FileCountExceeded,
        compileFixture(std.testing.allocator, input, &files, over_count, .{}),
    );

    var total_bytes: usize = files[files.len - 1].contents.len;
    for (files) |file| total_bytes += file.contents.len;
    var terminal_bytes = resolver.Limits{};
    terminal_bytes.max_total_bytes = total_bytes;
    var byte_result = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_bytes,
        .{},
    );
    defer byte_result.deinit();
    try std.testing.expectEqual(@as(u64, @intCast(total_bytes)), byte_result.stats().bytes);

    var over_bytes = terminal_bytes;
    over_bytes.max_total_bytes -= 1;
    try std.testing.expectError(
        error.TotalLimitExceeded,
        compileFixture(std.testing.allocator, input, &files, over_bytes, .{}),
    );

    var cancel_context = ResolverCancelContext{ .target = .read };
    try std.testing.expectError(
        error.Cancelled,
        compileFixtureWithCancellation(
            std.testing.allocator,
            input,
            &files,
            .{},
            .{},
            .{ .context = &cancel_context, .check_fn = ResolverCancelContext.check },
            .{},
        ),
    );
    try std.testing.expect(cancel_context.calls > 0);
}

test "native Stylus evaluates the fixed variable property selector expression slice" {
    const input =
        \\base = 8px
        \\name = 'card'
        \\tone = #123456
        \\.{name}, .panel
        \\  local = base + 2px
        \\  width local * 2
        \\  margin (base / 2)
        \\  color tone
        \\  border-{name} 1px + 1px
        \\  &:hover
        \\    width local
        \\  > span
        \\    padding base
        \\.other
        \\  width base
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".card,.panel{width:20px;margin:4px;color:#123456;border-card:2px}" ++
            ".card:hover,.panel:hover{width:10px}" ++
            ".card>span,.panel>span{padding:8px}.other{width:8px}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len >= 9);
}

test "native Stylus compressed numbers retain the finite provider unit exclusions" {
    const input =
        \\body
        \\  removable-zero 0px
        \\  percentage-zero 0%
        \\  seconds-zero 0s
        \\  milliseconds-zero 0ms
        \\  degrees-zero 0deg
        \\  fraction-zero 0fr
        \\  positive-fraction 0.1
        \\  negative-fraction -0.1
        \\  positive-boundary 1.1
        \\  negative-boundary -1.1
        \\  joined join(',', 0.1px 0px)
    ;
    var expanded = try compile(std.testing.allocator, input, .{});
    defer expanded.deinit();
    var compressed = try compileWithOptions(
        std.testing.allocator,
        input,
        .{ .output_style = .compressed },
        .{},
    );
    defer compressed.deinit();

    try std.testing.expectEqualStrings(
        "body{removable-zero:0px;percentage-zero:0%;seconds-zero:0s;" ++
            "milliseconds-zero:0ms;degrees-zero:0deg;fraction-zero:0fr;" ++
            "positive-fraction:0.1;negative-fraction:-0.1;" ++
            "positive-boundary:1.1;negative-boundary:-1.1;joined:'0.1px,0px'}",
        expanded.css(),
    );
    try std.testing.expectEqualStrings(
        "body{removable-zero:0;percentage-zero:0%;seconds-zero:0s;" ++
            "milliseconds-zero:0ms;degrees-zero:0deg;fraction-zero:0fr;" ++
            "positive-fraction:.1;negative-fraction:-.1;" ++
            "positive-boundary:1.1;negative-boundary:-1.1;joined:'0.1px,0px'}",
        compressed.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), expanded.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), compressed.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), expanded.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), compressed.dependencies().len);
}

test "native Stylus applies the finite selector scope directive" {
    const input =
        \\@scope #sidebar
        \\h2
        \\  color red
        \\a
        \\  &:hover
        \\    color pink
        \\@scope body.signup-page[attr='foo']
        \\& .container
        \\  color red
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "#sidebar h2{color:#f00}#sidebar a:hover{color:#ffc0cb}" ++
            "body.signup-page[attr=\"foo\"] .container{color:#f00}",
        compiled.css(),
    );
}

test "native Stylus evaluates whitespace-separated selector interpolation deterministically" {
    const input =
        \\pos = last
        \\form {'input'}:nth-child({10 + 5}) { display: none; }
        \\body {form} {
        \\  input:{pos}-child { display: none; }
        \\}
        \\{foo} {bar} { foo: bar; }
        \\.plain { color red }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "form input:nth-child(15){display:none}" ++
            "body form input:last-child{display:none}" ++
            "foo bar{foo:bar}.plain{color:#f00}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus evaluates finite color component getters" {
    const input =
        \\body
        \\  background red(#fc0)
        \\  background green(#fc0)
        \\  background blue(#fc0)
        \\  background alpha(#fff - rgba(0,0,0,.6))
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{background:255;background:204;background:0;background:0.4}",
        compiled.css(),
    );
}

test "native Stylus preserves relative saturation endpoints alpha and CSS fallbacks" {
    const input =
        \\body
        \\  saturate-lower saturate(#ee0, 0%)
        \\  saturate-terminal saturate(#fd0cc7, 100%)
        \\  saturate-alpha saturate(rgba(35,124,46,0.5), 80%)
        \\  desaturate-lower desaturate(#ee0, 0%)
        \\  desaturate-terminal desaturate(#fd0cc7, 100%)
        \\  desaturate-alpha desaturate(rgba(35,124,46,0.5), 80%)
        \\  filter-empty saturate()
        \\  filter-amount saturate(100%)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{saturate-lower:#ee0;saturate-terminal:#f0f;" ++
            "saturate-alpha:rgba(0,160,19,0.5);desaturate-lower:#ee0;" ++
            "desaturate-terminal:#858585;desaturate-alpha:rgba(71,88,73,0.5);" ++
            "filter-empty:saturate();filter-amount:saturate(100%)}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), compiled.dependencies().len);
    try std.testing.expect(compiled.map() != null);
}

test "native Stylus reflects composes and lists selector identity" {
    const input =
        \\.foo
        \\  .bar
        \\    current: selector()
        \\    explicit: selector('&:focus')
        \\    root: selector('^[0]:active')
        \\    parent: selector('../:hover')
        \\.foo,
        \\.bar
        \\  list: selector('&:hover, &:active')
        \\  absolute: selector('li a')
        \\wrap()
        \\  {selector()}
        \\    inside: selector('&__item')
        \\.host
        \\  wrap()
        \\selector-list = '.a', '.b', '.c, .d'
        \\{selector(selector-list)}
        \\  terminal: selector()
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".foo .bar{current:'.foo .bar';explicit:'.foo .bar:focus';" ++
            "root:'.foo:active';parent:'.foo:hover'}" ++
            ".foo,.bar{list:'.foo:hover,.bar:hover,.foo:active,.bar:active';" ++
            "absolute:'li a'}" ++
            ".host .host{inside:'.host .host__item'}" ++
            ".a .b .c,.a .b .d{terminal:'.a .b .c,.a .b .d'}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const invalid =
        \\.probe
        \\  value: selector(1)
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "selector").?),
    );
}

test "native Stylus queries previously evaluated selector identity" {
    const input =
        \\$test
        \\  a
        \\    color red
        \\class
        \\  if selector-exists($test a)
        \\    color #fff
        \\  if selector-exists('$test')
        \\    border #fff
        \\  if selector-exists('$test li')
        \\    font-size 12px
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "class{color:#fff;border:#fff}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const lower =
        \\class
        \\  if selector-exists()
        \\    color red
    ;
    try expectSemanticRejection(
        lower,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, lower, "if selector-exists").?),
    );

    const over =
        \\class
        \\  if selector-exists('class', '$test')
        \\    color red
    ;
    try expectSemanticRejection(
        over,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, over, "if selector-exists").?),
    );
}

test "native Stylus reconstructs transparent colors over bounded backdrops" {
    const input =
        \\body
        \\  default-white transparentify(#fff)
        \\  default-black transparentify(#000)
        \\  inferred transparentify(#808080)
        \\  backdrop transparentify(#808080, #000)
        \\  overload-unitless transparentify(#808080, .7)
        \\  explicit-percent transparentify(#808080, #000, 70%)
        \\  explicit-hsl transparentify(hsla(200,40%,40%,.3), hsla(200,0%,100%,1))
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{default-white:rgba(255,255,255,0);default-black:#000;" ++
            "inferred:rgba(0,0,0,0.5);backdrop:rgba(255,255,255,0.5);" ++
            "overload-unitless:rgba(74,74,74,0.7);" ++
            "explicit-percent:rgba(183,183,183,0.7);" ++
            "explicit-hsl:rgba(0,72,108,0.76)}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const missing_top =
        \\body
        \\  value transparentify()
    ;
    try expectSemanticRejection(
        missing_top,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, missing_top, "transparentify").?),
    );

    const invalid_backdrop =
        \\body
        \\  value transparentify(#fff, nope)
    ;
    try expectSemanticRejection(
        invalid_backdrop,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid_backdrop, "transparentify").?),
    );

    const invalid_alpha =
        \\body
        \\  value transparentify(#fff, #000, nope)
    ;
    try expectSemanticRejection(
        invalid_alpha,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid_alpha, "transparentify").?),
    );
}

test "native Stylus evaluates URL expressions without loading assets" {
    const input =
        \\brown = #462323
        \\body
        \\  empty url()
        \\  tokens url(foo bar)
        \\  commas url(foo, bar)
        \\  background url("/images/foo.png")
        \\  background url(/images/foo.png)
        \\  dir = '/images'
        \\  img = 'foo.png'
        \\  background url(dir/foo.png)
        \\  background url(dir/img)
        \\  background url('/images/' + img)
        \\  background url(dir'/foo.png')
        \\  background url(dir + '/foo.png')
        \\  background url(dir + '/' + img)
        \\  list = foo bar
        \\  background url('/images/' + list[0] + '.png')
        \\  background url(http://foo.com/images/bar.png)
        \\  background url(//foo.com/images/bar.png)
        \\  background url(/some/brown/white/icon.png)
        \\  color brown
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{empty:url(\"\");tokens:url(\"foobar\");commas:url(\"foo,bar\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"http://foo.com/images/bar.png\");" ++
            "background:url(\"//foo.com/images/bar.png\");" ++
            "background:url(\"/some/brown/white/icon.png\");color:#462323}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus evaluates compact declaration values inside explicit CSS blocks" {
    const input =
        \\body {background:white;font-size:.8em;background-image:url(src/grid.png);border-color:#e5eCf9;quotes:"" "";content:'';font-family:"Helvetica Neue",Arial;}
    ;
    var first = try compileWithOptions(
        std.testing.allocator,
        input,
        .{ .output_style = .expanded },
        .{},
    );
    defer first.deinit();
    var second = try compileWithOptions(
        std.testing.allocator,
        input,
        .{ .output_style = .expanded },
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{background:#fff;font-size:0.8em;background-image:url(\"src/grid.png\");" ++
            "border-color:#e5ecf9;quotes:\"\" \"\";content:'';" ++
            "font-family:\"Helvetica Neue\", Arial}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const invalid =
        \\vendors = 1
        \\@keyframes pulse
        \\  from
        \\    color red
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "@keyframes").?),
    );
}

test "native Stylus preserves nested rules beside compact mixin declarations" {
    const input =
        \\hover()
        \\  &:hover { color: white; background: black;
        \\    em {
        \\      color: gray;
        \\    }
        \\  }
        \\  &:active { color: black; background: white; }
        \\button(pad)
        \\  button,
        \\  a.button,
        \\  input[type=submit],
        \\  input[type=button] { padding: pad; hover(); }
        \\button(5px 10px);
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "button,a.button,input[type=submit],input[type=button]{padding:5px 10px}" ++
            "button:hover,a.button:hover,input[type=submit]:hover,input[type=button]:hover{" ++
            "color:#fff;background:#000}" ++
            "button:hover em,a.button:hover em,input[type=submit]:hover em," ++
            "input[type=button]:hover em{color:#808080}" ++
            "button:active,a.button:active,input[type=submit]:active," ++
            "input[type=button]:active{color:#000;background:#fff}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus treats top-level property slashes as CSS separators" {
    const input =
        \\size = 14px
        \\height = 1.4
        \\body { font: size / height "Helvetica Neue", Arial; ratio: ((14px) / (2)); path: url(a/b); tokens: foo / bar; }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{font:14px/1.4 \"Helvetica Neue\", Arial;ratio:7px;" ++
            "path:url(\"a/b\");tokens:foo/bar}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus preserves finite declaration comment boundaries" {
    const input =
        \\/*
        \\.hidden
        \\  color blue
        \\*/
        \\.probe
        \\  font-family: "DIN Alternate"
        \\  background: // ignored,
        \\    url("img.png") 8px 8px no-repeat,
        \\    rgba(0, 0, 0, .41)
        \\  shadow: 1px 0 0 white, /* keep */ 2px 0 0 black
        \\  sources: url("a") format("x"), /* dropped */
        \\           url("b") format("y") /* terminal */
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".probe{font-family:\"DIN Alternate\";" ++
            "background:url(\"img.png\") 8px 8px no-repeat, rgba(0,0,0,0.41);" ++
            "shadow:1px 0 0 #fff, /* keep */ 2px 0 0 #000;" ++
            "sources:url(\"a\") format(\"x\"), url(\"b\") format(\"y\") /* terminal */}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus evaluates the finite contrast result object and CSS fallback" {
    const input =
        \\.probe
        \\  test1: contrast(#000).ratio
        \\  test2: contrast(rgba(#000,.5), #fff).ratio
        \\  test3: contrast(#000, rgba(#fff,.5)).ratio
        \\  test4: contrast(#000, rgba(#fff,.5)).error
        \\  test5: contrast(#000, rgba(#fff,.5)).min
        \\  test6: contrast(#000, rgba(#fff,.5)).max
        \\  test7: contrast(200%, red)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".probe{test1:21;test2:3.9;test3:13.15;test4:7.85;" ++
            "test5:5.3;test6:21;test7:contrast(200%)}",
        compiled.css(),
    );

    const invalid =
        \\.probe
        \\  test1: contrast(#000, 1).ratio
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "contrast").?),
    );
}

test "native Stylus evaluates bounded convert and match builtins" {
    const input =
        \\parsed = match('^(height|width)?([<>=]{1,})(.*)', 'height>=10px')
        \\without-dimension = match('^(height|width)?([<>=]{1,})(.*)', '>400px')
        \\direction = 'min'
        \\.probe
        \\  numeric: convert('1.334em')
        \\  color-type: type(convert('#c00'))
        \\  ident-type: type(convert('something'))
        \\  space-list: convert('10 20 30')
        \\  comma-list: convert('10, 20, 30')
        \\  prefix: match('^pad', 'padding')
        \\  captures: parsed
        \\  operator: parsed[2]
        \\  converted: convert(parsed[3])
        \\  global: match('ain', 'The rain in SPAIN stays mainly in the plain', 'gi')
        \\  invalid-flags: match('ain', 'The rain in SPAIN', 'x')
        \\  fallback: direction + '-' + (without-dimension[1] || 'width')
        \\  operated: operate(direction == 'min' ? '+' : '-', 400px, 1px)
        \\  if match('absent', 'present')
        \\    state: bad
        \\  else
        \\    state: good
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".probe{numeric:1.334em;color-type:'rgba';ident-type:'ident';" ++
            "space-list:10 20 30;comma-list:10, 20, 30;prefix:'pad';" ++
            "captures:'height>=10px' 'height' '>=' '10px';operator:'>=';" ++
            "converted:10px;global:'ain' 'AIN' 'ain' 'ain';" ++
            "invalid-flags:'ain';fallback:'min-width';operated:401px;state:good}",
        compiled.css(),
    );

    const invalid =
        \\.probe
        \\  test: convert(1)
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "convert").?),
    );

    const unsupported_match =
        \\.probe
        \\  test: match('a+', 'aaa')
    ;
    try expectSemanticRejection(
        unsupported_match,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, unsupported_match, "match").?),
    );
}

test "native Stylus join preserves nested lists and HSL string identity" {
    const input =
        \\a = 1 2
        \\b = 3 4
        \\.probe
        \\  nested: join(', ', a b)
        \\  flat: join(',', 1 2 3)
        \\  expression: join(',', 1 + 2)
        \\  colors: join(', ', hsl(0, 0%, 0%), hsla(120, 20%, 80%, 1))
        \\  rgb: join(', ', #fff #000)
        \\  scalar: join(',', 1)
        \\  empty: join(',') == null
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".probe{nested:'1 2, 3 4';flat:'1,2,3';expression:'3';" ++
            "colors:'hsla(0,0%,0%,1), hsla(120,20%,80%,1)';" ++
            "rgb:'#fff, #000';scalar:'1';empty:true}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);

    const invalid =
        \\.probe
        \\  value: join(1, 2)
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "join").?),
    );
}

test "native Stylus length preserves provider scalar list and string semantics" {
    const input =
        \\args(n = null)
        \\  length(n)
        \\
        \\vargs(args...)
        \\  length(args)
        \\
        \\argument-count()
        \\  length(arguments)
        \\
        \\body
        \\  zero length()
        \\  null-value length(null)
        \\  identifier length(foo)
        \\  empty-string length('')
        \\  returned-scalar length(args())
        \\  scalar length(1)
        \\  nested length((1 2) (3 4))
        \\  flat length(1 2 3)
        \\  ascii length("hey")
        \\  bmp length("hé")
        \\  astral length("hé😊")
        \\  rest vargs(1, 2, 3, 4)
        \\  default-list args(1 2 3 4 5)
        \\  implicit argument-count(1, 2, 3, 4, 5, 6)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{zero:0;null-value:1;identifier:1;empty-string:0;" ++
            "returned-scalar:1;scalar:1;nested:2;flat:3;ascii:3;" ++
            "bmp:2;astral:4;rest:4;default-list:5;implicit:6}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);
}

test "native Stylus merge mutates maps with shallow and recursive precedence" {
    const input =
        \\base = {
        \\  first: 1
        \\  shared: 2
        \\  nested: {
        \\    keep: 3
        \\    replace: 4
        \\  }
        \\}
        \\alias = base
        \\merged = merge(base, { shared: 5, nested: { replace: 6, add: 7 } }, { tail: 8 }, true)
        \\shallow = {
        \\  nested: {
        \\    keep: 9
        \\  }
        \\}
        \\extended = extend(shallow, { nested: { replacement: 10 }, added: 11 })
        \\flagged = {
        \\  nested: {
        \\    keep: 12
        \\  }
        \\}
        \\flagged-result = merge(flagged, { nested: { replacement: 13 } }, false)
        \\retained = { value: 14 }
        \\retained-alias = retained
        \\retained-peer = retained
        \\retained = { value: 15 }
        \\merge(retained-alias, { value: 16 })
        \\body
        \\  first merged.first
        \\  shared merged.shared
        \\  nested-keep merged.nested.keep
        \\  nested-replace merged.nested.replace
        \\  nested-add merged.nested.add
        \\  tail merged.tail
        \\  alias alias.shared
        \\  original base.nested.add
        \\  shallow-old shallow.nested.keep == null
        \\  shallow-new shallow.nested.replacement
        \\  added shallow.added
        \\  flag-old flagged.nested.keep == null
        \\  flag-new flagged-result.nested.replacement
        \\  retained-root retained.value
        \\  retained-peer retained-peer.value
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{first:1;shared:5;nested-keep:3;nested-replace:6;" ++
            "nested-add:7;tail:8;alias:5;original:7;shallow-old:true;" ++
            "shallow-new:10;added:11;flag-old:true;flag-new:13;" ++
            "retained-root:15;retained-peer:16}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);

    const invalid =
        \\body
        \\  value merge(1, { a: 1 })
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "merge").?),
    );
}

test "native Stylus invokes a provider-prefixed root block mixin" {
    const input =
        \\wrapper()
        \\  @media print
        \\    {block}
        \\+wrapper()
        \\  body
        \\    color red
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "@media print{body{color:#f00}}",
        compiled.css(),
    );
}

test "native Stylus prefixes class selectors inside a bounded block mixin" {
    const input =
        \\+prefix-classes('pre-')
        \\  .alpha.beta:hover, #identity .gamma
        \\    color red
        \\.host
        \\  +prefix-classes(unquoted-)
        \\    .child
        \\      width 1px
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".pre-alpha.pre-beta:hover,#identity .pre-gamma{color:#f00}" ++
            ".host .unquoted-child{width:1px}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);

    const invalid =
        \\+prefix-classes(1)
        \\  .child
        \\    width 1px
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        0,
    );
    try expectSemanticRejection(
        \\+prefix-classes('bad .')
        \\  .child
        \\    width 1px
    ,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        0,
    );
    try expectSemanticRejection(
        \\prefix-classes('orphan-')
    ,
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus prefix-classes() requires a content block",
        0,
    );
}

test "native Stylus mutates promoted lists across callable aliases and arguments" {
    const input =
        \\nums = 1
        \\append(nums, 2)
        \\append(nums, 3, 4, 5)
        \\mutate(list)
        \\  push(list, 6)
        \\collect()
        \\  list = ()
        \\  for arg in arguments
        \\    push(list, arg)
        \\  return list
        \\mutate(nums)
        \\body
        \\  appended nums
        \\  pushed: ret = push(nums, 7, 8)
        \\  unshifted unshift(nums, -1, 0)
        \\  final nums
        \\  args collect(alpha, beta)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{appended:1 2 3 4 5 6;pushed:8;unshifted:10;" ++
            "final:0 -1 1 2 3 4 5 6 7 8;args:alpha beta}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);
}

test "native Stylus composes match conversion and root media mixins" {
    const input =
        \\unit-intervals = { 'px': 1, 'em': 0.01, 'rem': 0.1 }
        \\media(expression)
        \\  parsed-expression = match('^(height|width)?([<>=]{1,})(.*)', expression)
        \\  operator = parsed-expression[2]
        \\  direction = match('>', operator) ? 'min' : 'max'
        \\  type = direction + '-' + (parsed-expression[1] || 'width')
        \\  value = convert(parsed-expression[3])
        \\  unless match('=', operator)
        \\    value = operate(direction == 'min' ? '+' : '-', value, unit-intervals[unit(value)])
        \\  @media ({type}: value)
        \\    {block}
        \\+media('>400px')
        \\  body
        \\    margin 1px
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "@media (min-width: 401px){body{margin:1px}}",
        compiled.css(),
    );
}

test "native Stylus semantic failures own diagnostics without partial CSS" {
    try expectSemanticRejection(
        \\.a
        \\  width $missing
    ,
        error.UndefinedVariable,
        .undefined_variable,
        "native Stylus variable is undefined",
        11,
    );
    try expectSemanticRejection(
        \\base = 1px
        \\.a
        \\  width push(base)
    ,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        22,
    );
}

test "native Stylus evaluates the fixed callable control operator builtin slice" {
    const input =
        \\factor = 2
        \\bump(value)
        \\  return value * factor
        \\box(value)
        \\  padding value
        \\  if value > 2px
        \\    margin value + 1px
        \\  else
        \\    margin 0
        \\  for side in top right
        \\    border-{side}-width value % 3
        \\.card
        \\  box(bump(2px))
        \\  count length(1 2 3)
        \\  kind type(4px)
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".card{padding:4px;margin:5px;border-top-width:1px;" ++
            "border-right-width:1px;count:3;kind:'unit'}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len >= 7);
}

test "native Stylus evaluates single-line implicit-return functions with postfix guards" {
    const input =
        \\large(n){ n > 100 }
        \\
        \\body
        \\  foo large(5)
        \\  foo large(300)
        \\
        \\large(n){ n > 100 if n is a 'unit' }
        \\
        \\body
        \\  foo large(5)
        \\  foo large(300)
        \\  foo large('test')
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{foo:false;foo:true}body{foo:false;foo:true;foo:}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus keyframe fabrication follows the bounded vendor value" {
    const input =
        \\vendors = webkit ms official
        \\@keyframes pulse
        \\  from
        \\    color red
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "@-webkit-keyframes pulse{from{color:#f00}}" ++
            "@keyframes pulse{from{color:#f00}}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus add-property preserves declaration context and interpolation" {
    const input =
        \\custom(name, value)
        \\  {name} value
        \\replacement()
        \\  add-property(current-property[0], before)
        \\  after
        \\copy()
        \\  add-property(current-property[0], current-property[1])
        \\  done
        \\.direct
        \\  add-property(foo, bar)
        \\.custom
        \\  custom(height, 10px)
        \\.nested
        \\  width replacement()
        \\.copy
        \\  background test copy(), stuff
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".direct{foo:bar}.custom{height:10px}.nested{width:before;width:after}" ++
            ".copy{background:test __CALL__, stuff;background:test done, stuff}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Stylus indexed current-property access retains its callable snapshot" {
    const input =
        \\identity(value)
        \\  add-property('captured', value)
        \\  return 1px
        \\outer()
        \\  temporary: identity(current-property[0])
        \\  return 2px
        \\body
        \\  width: outer()
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "body{captured:'width';width:2px}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Stylus define owns local and explicit global scope" {
    const input =
        \\a = 1
        \\local()
        \\  define('b', 2)
        \\  return b
        \\global()
        \\  define('c', 3, true)
        \\shadow()
        \\  a = 2
        \\  define('a', 3, true)
        \\  return a
        \\body
        \\  local-result: local()
        \\  local-visible: b is defined
        \\  global()
        \\  global-visible: c
        \\  shadow-result: shadow()
        \\  global-a: a
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "body{local-result:2;local-visible:false;global-visible:3;" ++
            "shadow-result:2;global-a:3}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const nested =
        \\value = define('hidden', 1)
        \\body
        \\  test: value
    ;
    try expectSemanticRejection(
        nested,
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus define() is supported only as a statement",
        0,
    );
}

test "native Stylus reads bounded image dimensions through resolver ownership" {
    const allocator = std.testing.allocator;
    const image_root = "tests/preprocessors/stylus/corpus/files/upstream/images";
    const names = [_][]const u8{
        "gif",
        "tux.png",
        "flowers.jpeg",
        "flowers_p.jpg",
        "tiger.svg",
    };
    var contents: [names.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (contents[0..loaded]) |bytes| allocator.free(bytes);
    for (names, 0..) |name, index| {
        const path = try std.fs.path.join(allocator, &.{ image_root, name });
        defer allocator.free(path);
        contents[index] = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
        loaded += 1;
    }

    const files = [_]FixtureFile{
        .{ .path = names[0], .contents = contents[0] },
        .{ .path = names[1], .contents = contents[1] },
        .{ .path = names[2], .contents = contents[2] },
        .{ .path = names[3], .contents = contents[3] },
        .{ .path = names[4], .contents = contents[4] },
    };
    const input =
        \\body
        \\  gif: image-size('gif')
        \\  gif-width: image-size('gif')[0]
        \\  png: image-size('tux.png')
        \\  jpeg: image-size('flowers.jpeg')
        \\  progressive-jpeg: image-size('flowers_p.jpg')
        \\  svg: image-size('tiger.svg')
        \\  missing: image-size('missing.png', true)
        \\.present
        \\  if image-size('tux.png', true)
        \\    found: yes
        \\  else
        \\    found: no
        \\.missing
        \\  if image-size('missing.png', true)
        \\    found: yes
        \\  else
        \\    found: no
    ;
    var result = try compileFixture(allocator, input, &files, .{}, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "body{gif:118px 104px;gif-width:118px;png:510px 640px;" ++
            "jpeg:640px 480px;progressive-jpeg:640px 480px;" ++
            "svg:900px 900px;missing:0 0}.present{found:yes}.missing{found:no}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, names.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, names.len), result.edges().len);
    for (result.dependencies(), names) |dependency, name| {
        try std.testing.expectEqual(resolver.DependencyKind.reference, dependency.kind);
        try std.testing.expectEqualStrings(name, std.fs.path.basename(dependency.url));
    }
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Stylus image dimensions reject invalid assets and unconfined targets" {
    const invalid_assets = [_]FixtureFile{
        .{ .path = "invalid.gif", .contents = "GIF89a\x00\x00\x01\x00" },
        .{ .path = "invalid.png", .contents = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x00\x00\x00\x00\x01" },
        .{ .path = "invalid.jpeg", .contents = "\xff\xd8\xff\xc0\x00\x07\x08\x00\x00\x00\x01" },
        .{ .path = "invalid.svg", .contents = "<svg width='0' height='1'></svg>" },
    };
    for (invalid_assets) |asset| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "body\n  size: image-size('{s}')\n",
            .{asset.path},
        );
        defer std.testing.allocator.free(input);
        try expectFixtureRejection(
            input,
            &.{asset},
            error.InvalidOperation,
            .invalid_operation,
            "native Stylus image asset is invalid",
            0,
            1,
        );
    }

    try expectFixtureRejection(
        "body\n  size: image-size('missing.png')\n",
        &.{},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus image asset was not found",
        0,
        0,
    );
    for ([_][]const u8{ "../escape.png", "https://example.invalid/image.png" }) |target| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "body\n  size: image-size('{s}')\n",
            .{target},
        );
        defer std.testing.allocator.free(input);
        try expectFixtureRejection(
            input,
            &.{},
            error.InvalidOperation,
            .invalid_operation,
            "native Stylus image asset load was rejected",
            0,
            0,
        );
    }
}

test "native Stylus image dimensions preserve resolver byte limits" {
    const input = "body\n  size: image-size('tiny.gif')\n";
    const gif = "GIF89a\x01\x00\x01\x00";
    const files = [_]FixtureFile{.{ .path = "tiny.gif", .contents = gif }};
    var terminal = resolver.Limits{};
    terminal.max_total_bytes = gif.len;
    var result = try compileFixture(std.testing.allocator, input, &files, terminal, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("body{size:1px 1px}", result.css());
    try std.testing.expectEqual(@as(u64, gif.len), result.stats().bytes);

    var over_limit = terminal;
    over_limit.max_total_bytes -= 1;
    try std.testing.expectError(
        error.TotalLimitExceeded,
        compileFixture(std.testing.allocator, input, &files, over_limit, .{}),
    );
}

test "native Stylus JSON owns legacy variables, hashes, and optional assets" {
    const files = [_]FixtureFile{
        .{
            .path = "vars.json",
            .contents =
            \\{
            \\  "nope": "none",
            \\  "color": "#abc",
            \\  "length": "10px",
            \\  "count": 2,
            \\  "nested": { "value": "ready" },
            \\  "enabled": true
            \\}
            ,
        },
        .{
            .path = "local.json",
            .contents = "{\"theme\":{\"color\":\"blue\"},\"size\":5}",
        },
        .{
            .path = "strings.json",
            .contents = "{\"color\":\"#abc\",\"length\":\"10px\"}",
        },
    };
    const input =
        \\json('vars.json')
        \\.global
        \\  ident: nope
        \\  color: color
        \\  length: length
        \\  numeric: count * 2
        \\  nested: nested-value
        \\  truth: enabled
        \\.local
        \\  prefix = '$'
        \\  json('local.json', true, prefix)
        \\  color: $theme-color
        \\  size: $size * 2
        \\.hash
        \\  vars = json('vars.json', { hash: true })
        \\  ident: vars.nope
        \\  color: vars.color
        \\  length: vars.length
        \\  numeric: vars.count * 2
        \\  nested: vars.nested.value
        \\  truth: vars.enabled
        \\.strings
        \\  vars = json('strings.json', { hash: true, leave-strings: true })
        \\  color: vars.color
        \\  length: vars.length
        \\.outside
        \\  color: $theme-color
        \\.optional
        \\  vars = json('missing.json', { hash: true, optional: true })
        \\  missing: typeof(vars)
    ;
    var result = try compileFixture(std.testing.allocator, input, &files, .{}, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".global{ident:none;color:#abc;length:10px;numeric:4;nested:ready;truth:true}" ++
            ".local{color:#00f;size:10}.hash{ident:none;color:#abc;length:10px;" ++
            "numeric:4;nested:ready;truth:true}.strings{color:'#abc';length:'10px'}" ++
            ".outside{color:$theme-color}.optional{missing:'null'}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, files.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), result.edges().len);
    for (result.dependencies()) |dependency| {
        try std.testing.expectEqual(resolver.DependencyKind.reference, dependency.kind);
    }
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
    try std.testing.expect(result.map() != null);
}

test "native Stylus JSON rejects malformed and unconfined assets" {
    try expectFixtureRejection(
        "vars = json('invalid.json', { hash: true })\n",
        &.{.{ .path = "invalid.json", .contents = "{\"value\":" }},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus JSON asset is invalid",
        0,
        1,
    );
    try expectFixtureRejection(
        "vars = json('missing.json', { hash: true })\n",
        &.{},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus JSON asset was not found",
        0,
        0,
    );
    try expectFixtureRejection(
        "vars = json('array.json', { hash: true })\n",
        &.{.{ .path = "array.json", .contents = "{\"values\":[1,2]}" }},
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus JSON arrays are unavailable",
        0,
        1,
    );
    const invalid_options = "vars = json('data.json', { hash: false })\n";
    try expectSemanticRejection(
        invalid_options,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        0,
    );
    for ([_][]const u8{ "../escape.json", "https://example.invalid/data.json" }) |target| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "vars = json('{s}', {{ hash: true }})\n",
            .{target},
        );
        defer std.testing.allocator.free(input);
        try expectFixtureRejection(
            input,
            &.{},
            error.InvalidOperation,
            .invalid_operation,
            "native Stylus JSON asset load was rejected",
            0,
            0,
        );
    }
}

test "native Stylus JSON preserves resolver byte limits" {
    const input = "vars = json('data.json', { hash: true })\nbody\n  value: vars.value\n";
    const json = "{\"value\":1}";
    const files = [_]FixtureFile{.{ .path = "data.json", .contents = json }};
    var terminal = resolver.Limits{};
    terminal.max_total_bytes = json.len;
    var result = try compileFixture(std.testing.allocator, input, &files, terminal, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("body{value:1}", result.css());
    try std.testing.expectEqual(@as(u64, json.len), result.stats().bytes);

    var over_limit = terminal;
    over_limit.max_total_bytes -= 1;
    try std.testing.expectError(
        error.TotalLimitExceeded,
        compileFixture(std.testing.allocator, input, &files, over_limit, .{}),
    );
}

test "native Stylus callable control slice fails closed with exact diagnostics" {
    const missing =
        \\.a
        \\  missing(1)
    ;
    try expectSemanticRejection(
        missing,
        error.UndefinedCallable,
        .invalid_operation,
        "native Stylus callable is undefined",
        @intCast(std.mem.indexOf(u8, missing, "missing").?),
    );

    const recursive =
        \\countdown(value)
        \\  if value > 0
        \\    return countdown(value - 1)
        \\  return 0
        \\.a
        \\  width countdown(2)
    ;
    var terminal_calls = stylus_evaluator.Limits{};
    terminal_calls.max_call_depth = 3;
    var result = try compile(std.testing.allocator, recursive, terminal_calls);
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{width:0}", result.css());

    var over_calls = terminal_calls;
    over_calls.max_call_depth = 2;
    try expectSemanticRejectionWithLimits(
        recursive,
        over_calls,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.indexOf(u8, recursive, "return countdown").?),
    );

    const finite_loop =
        \\box()
        \\  for side in top right
        \\    border-{side}-width 1px
        \\.a
        \\  box()
    ;
    var terminal_loop = stylus_evaluator.Limits{};
    terminal_loop.max_loop_iterations = 2;
    var loop_result = try compile(std.testing.allocator, finite_loop, terminal_loop);
    defer loop_result.deinit();
    try std.testing.expectEqualStrings(
        ".a{border-top-width:1px;border-right-width:1px}",
        loop_result.css(),
    );

    var over_loop = terminal_loop;
    over_loop.max_loop_iterations = 1;
    try expectSemanticRejectionWithLimits(
        finite_loop,
        over_loop,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, finite_loop, "for side").?),
    );
}

test "native Stylus semantic values and bindings retain finite ceilings" {
    const value_input =
        \\base = 1px
        \\.a
        \\  width base
    ;
    var terminal_values = stylus_evaluator.Limits{};
    terminal_values.values.max_values = 2;
    var value_result = try compile(std.testing.allocator, value_input, terminal_values);
    defer value_result.deinit();
    try std.testing.expectEqualStrings(".a{width:1px}", value_result.css());

    var over_values = terminal_values;
    over_values.values.max_values = 1;
    try expectSemanticRejectionWithLimits(
        value_input,
        over_values,
        error.ValueLimitExceeded,
        .resource_limit,
        "native Stylus value limit exceeded",
        @intCast(std.mem.lastIndexOf(u8, value_input, "base").?),
    );

    const binding_input =
        \\base = 1px
        \\.a
        \\  local = base
        \\  width local
    ;
    var over_bindings = stylus_evaluator.Limits{};
    over_bindings.environment.max_bindings = 1;
    try expectSemanticRejectionWithLimits(
        binding_input,
        over_bindings,
        error.BindingLimitExceeded,
        .resource_limit,
        "native Stylus lexical environment limit exceeded",
        @intCast(std.mem.indexOf(u8, binding_input, "local =").?),
    );
}

test "native Stylus scalar conversion and expansion limits fail closed" {
    const bitwise_overflow =
        \\.a
        \\  width ~1e300
    ;
    try expectSemanticRejection(
        bitwise_overflow,
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus expression is invalid",
        @intCast(std.mem.indexOf(u8, bitwise_overflow, "~1e300").?),
    );

    const index_overflow =
        \\.a
        \\  width (1 2)[1e300]
    ;
    try expectSemanticRejection(
        index_overflow,
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus expression is invalid",
        @intCast(std.mem.indexOf(u8, index_overflow, "(1 2)").?),
    );

    const empty_split =
        \\.a
        \\  content split('', 'abc')
    ;
    try expectSemanticRejection(
        empty_split,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, empty_split, "split").?),
    );

    const empty_replace =
        \\.a
        \\  content replace('', 'x', 'abc')
    ;
    try expectSemanticRejection(
        empty_replace,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, empty_replace, "replace").?),
    );

    const repetition =
        \\.a
        \\  content 'ab' * 3
    ;
    var terminal_temporary = stylus_evaluator.Limits{};
    terminal_temporary.max_temporary_bytes = 64;
    var repeated = try compile(std.testing.allocator, repetition, terminal_temporary);
    defer repeated.deinit();
    try std.testing.expectEqualStrings(".a{content:'ababab'}", repeated.css());

    var over_temporary = terminal_temporary;
    over_temporary.max_temporary_bytes = 43;
    try expectSemanticRejectionWithLimits(
        repetition,
        over_temporary,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        @intCast(std.mem.indexOf(u8, repetition, "'ab'").?),
    );

    const extension =
        \\.base
        \\  width 1px
        \\.one
        \\  @extend .base
    ;
    var terminal_selectors = stylus_evaluator.Limits{};
    terminal_selectors.max_selectors = 3;
    var extended = try compile(std.testing.allocator, extension, terminal_selectors);
    defer extended.deinit();
    try std.testing.expectEqualStrings(".base,.one{width:1px}", extended.css());

    var over_selectors = terminal_selectors;
    over_selectors.max_selectors = 1;
    try expectSemanticRejectionWithLimits(
        extension,
        over_selectors,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOf(u8, extension, ".base").?),
    );

    const padded =
        \\.a
        \\  content base-convert(15, 16, 100)
    ;
    try expectSemanticRejectionWithLimits(
        padded,
        terminal_temporary,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        @intCast(std.mem.indexOf(u8, padded, "base-convert").?),
    );

    const replacement_growth =
        \\.a
        \\  content replace('a', '0123456789', 'aaaaaaaaaaaaaaaaaaaa')
    ;
    var bounded_replacement = stylus_evaluator.Limits{};
    bounded_replacement.max_temporary_bytes = 128;
    try expectSemanticRejectionWithLimits(
        replacement_growth,
        bounded_replacement,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        @intCast(std.mem.indexOf(u8, replacement_growth, "replace").?),
    );
}

const CancelContext = struct {
    target: evaluator.Checkpoint,
    calls: usize = 0,

    fn check(context: *anyopaque, checkpoint: evaluator.Checkpoint) bool {
        const self: *CancelContext = @ptrCast(@alignCast(context));
        self.calls += 1;
        return checkpoint == self.target;
    }
};

test "native Stylus plain CSS foundation owns resource and cancellation boundaries" {
    const input = ".a { color: red; }\n";
    {
        var limits = stylus_evaluator.Limits{};
        limits.max_source_bytes = input.len - 1;
        try std.testing.expectError(
            error.SourceLimitExceeded,
            compile(std.testing.allocator, input, limits),
        );
    }
    {
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
        const source_id = try sources.add("input.styl", input);
        var parser = try stylus.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .{},
            .{},
        );
        defer parser.deinit();
        var document = try parser.parse();
        defer document.deinit();

        var node_limits = stylus_evaluator.Limits{};
        node_limits.max_nodes = document.nodes().len - 1;
        var node_transaction = try evaluator.Transaction.init(
            std.testing.allocator,
            &sources,
            &session,
            .{},
            .{},
        );
        defer node_transaction.deinit();
        try std.testing.expectError(
            error.NodeLimitExceeded,
            stylus_evaluator.evaluate(
                &sources,
                &document,
                &node_transaction,
                node_limits,
            ),
        );
        try std.testing.expectEqual(@as(usize, 1), node_transaction.diagnostics().len);
        try std.testing.expectEqual(
            diagnostics.Code.resource_limit,
            node_transaction.diagnostics()[0].code,
        );

        var cancelled_session = authority.createSession(std.testing.allocator, .{});
        defer cancelled_session.deinit();
        var cancel_context = CancelContext{ .target = .operation };
        var cancelled_transaction = try evaluator.Transaction.init(
            std.testing.allocator,
            &sources,
            &cancelled_session,
            .{},
            .{ .context = &cancel_context, .check_fn = CancelContext.check },
        );
        defer cancelled_transaction.deinit();
        try std.testing.expectError(
            error.Cancelled,
            stylus_evaluator.evaluate(
                &sources,
                &document,
                &cancelled_transaction,
                .{},
            ),
        );
        try std.testing.expect(cancel_context.calls > 0);
        try std.testing.expectError(
            error.SessionFailed,
            cancelled_transaction.finish(.{ .format = .minified }),
        );
    }
    {
        var invalid = stylus_evaluator.Limits{};
        invalid.max_nodes = 0;
        try std.testing.expectError(
            error.InvalidLimits,
            compile(std.testing.allocator, input, invalid),
        );
    }
    {
        var invalid = stylus_evaluator.Limits{};
        invalid.asset_load_paths = &.{"relative"};
        try std.testing.expectError(
            error.InvalidLimits,
            compile(std.testing.allocator, input, invalid),
        );
    }
    {
        var terminal = stylus_evaluator.Limits{};
        terminal.max_selectors = 2;
        var result = try compile(
            std.testing.allocator,
            ".a, .b\n  width 1px + 1px\n",
            terminal,
        );
        defer result.deinit();
        try std.testing.expectEqualStrings(".a,.b{width:2px}", result.css());

        var over_limit = terminal;
        over_limit.max_selectors = 1;
        try std.testing.expectError(
            error.SelectorLimitExceeded,
            compile(
                std.testing.allocator,
                ".a, .b\n  width 1px + 1px\n",
                over_limit,
            ),
        );
    }
    {
        var terminal = stylus_evaluator.Limits{};
        terminal.max_expression_depth = 2;
        var result = try compile(
            std.testing.allocator,
            ".a\n  width (1px + 1px)\n",
            terminal,
        );
        defer result.deinit();
        try std.testing.expectEqualStrings(".a{width:2px}", result.css());

        try std.testing.expectError(
            error.ExpressionDepthExceeded,
            compile(
                std.testing.allocator,
                ".a\n  width ((1px + 1px))\n",
                terminal,
            ),
        );
    }
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "base = {\n" ++
            "  a: 1\n" ++
            "}\n" ++
            "alias = base\n" ++
            "merged = merge(base, { b: 2 })\n" ++
            "factor = 2\n" ++
            "bump(value)\n" ++
            "  return value * factor\n" ++
            "box(value)\n" ++
            "  padding value\n" ++
            "  if value > 2px\n" ++
            "    margin value + 1px\n" ++
            "  else\n" ++
            "    margin 0\n" ++
            "  for side in top right\n" ++
            "    border-{side}-width value % 3\n" ++
            ".card\n" ++
            "  box(bump(2px))\n" ++
            "  merged alias.b\n" ++
            "  count length(1 2 3)\n" ++
            "  kind type(4px)\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{padding:4px;margin:5px;border-top-width:1px;" ++
            "border-right-width:1px;merged:2;count:3;kind:'unit'}",
        result.css(),
    );
}

fn exerciseImportAllocationFailures(allocator: std.mem.Allocator) !void {
    const files = [_]FixtureFile{
        .{ .path = "parts/a.styl", .contents = "spacing = 4px\n.a\n  order 1\n" },
        .{ .path = "parts/b.styl", .contents = ".b\n  order 2\n" },
        .{ .path = "once.styl", .contents = ".once\n  order 3\n" },
    };
    var result = try compileFixture(
        allocator,
        "@import \"parts/*\"\n" ++
            "@require \"once\"\n" ++
            "@require \"once\"\n" ++
            ".card\n" ++
            "  width spacing\n",
        &files,
        .{},
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{order:1}.b{order:2}.once{order:3}.card{width:4px}",
        result.css(),
    );
}

fn exerciseCompactDeclarationAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compileWithOptions(
        allocator,
        "body {background:white;font-size:.8em;background-image:url(src/grid.png);" ++
            "border-color:#e5eCf9;quotes:\"\" \"\";content:'';" ++
            "font-family:\"Helvetica Neue\",Arial;}\n",
        .{ .output_style = .expanded },
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{background:#fff;font-size:0.8em;background-image:url(\"src/grid.png\");" ++
            "border-color:#e5ecf9;quotes:\"\" \"\";content:'';" ++
            "font-family:\"Helvetica Neue\", Arial}",
        result.css(),
    );
}

fn exerciseSingleLineCallableAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "large(n){ n > 100 if n is a 'unit' }\nbody\n  foo large(5)\n  foo large('test')\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("body{foo:false;foo:}", result.css());
}

fn exerciseKeyframeVendorAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "vendors = webkit\n@keyframes pulse\n  from\n    opacity 0\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@-webkit-keyframes pulse{from{opacity:0}}",
        result.css(),
    );
}

fn exercisePropertySlashAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "size = 14px\nheight = 1.4\nbody { font: size / height \"Helvetica Neue\", Arial; }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{font:14px/1.4 \"Helvetica Neue\", Arial}",
        result.css(),
    );
}

fn exerciseCompactNestedRuleAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "hover()\n" ++
            "  &:hover { color: white; background: black;\n" ++
            "    em {\n" ++
            "      color: gray;\n" ++
            "    }\n" ++
            "  }\n" ++
            "body { hover(); }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body:hover{color:#fff;background:#000}body:hover em{color:#808080}",
        result.css(),
    );
}

fn exerciseSpacedSelectorInterpolationAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "pos = last\n" ++
            "body {form} { input:{pos}-child { display: none; } }\n" ++
            ".plain { color red }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body form input:last-child{display:none}.plain{color:#f00}",
        result.css(),
    );
}

fn exerciseExplicitCssNestedSelectorAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "body { margin: 0; ul {\n/* test */\nmargin: 0; li { color: red; } } }\n" ++
            "ul { li { &:first-child, &:last-child { display: none; } } }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{margin:0}body ul{margin:0}body ul li{color:#f00}" ++
            "ul li:first-child,ul li:last-child{display:none}",
        result.css(),
    );
}

test "native Stylus transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "native Stylus import transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseImportAllocationFailures,
        .{},
    );
}

test "native Stylus compact declaration transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompactDeclarationAllocationFailures,
        .{},
    );
}

test "native Stylus single-line callable transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSingleLineCallableAllocationFailures,
        .{},
    );
}

test "native Stylus keyframe vendor transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseKeyframeVendorAllocationFailures,
        .{},
    );
}

test "native Stylus property slash transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePropertySlashAllocationFailures,
        .{},
    );
}

test "native Stylus compact nested rule transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompactNestedRuleAllocationFailures,
        .{},
    );
}

test "native Stylus whitespace-separated selector interpolation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSpacedSelectorInterpolationAllocationFailures,
        .{},
    );
}

test "native Stylus explicit CSS nested selector transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExplicitCssNestedSelectorAllocationFailures,
        .{},
    );
}
