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
    try stylus_evaluator.evaluate(&sources, &document, &transaction, limits);
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
            "  count length(1 2 3)\n" ++
            "  kind type(4px)\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{padding:4px;margin:5px;border-top-width:1px;" ++
            "border-right-width:1px;count:3;kind:'unit'}",
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
