const std = @import("std");
const preprocessor = @import("native_preprocessor");

const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const sass = preprocessor.sass;
const sass_evaluator = preprocessor.sass_evaluator;
const source = preprocessor.source;

const corpus_cases_root = "tests/preprocessors/sass/corpus/cases";
const max_fixture_bytes = 10 * 1024 * 1024;

const ManifestCase = struct {
    id: []const u8,
    feature: []const u8,
    syntax: []const u8,
    outcome: []const u8,
    entry: []const u8,
    expected: []const u8,
    warning: ?[]const u8,
};

const Manifest = struct {
    schemaVersion: u8,
    caseCount: usize,
    cases: []const ManifestCase,
};

fn findCase(cases: []const ManifestCase, id: []const u8) !ManifestCase {
    for (cases) |case| {
        if (std.mem.eql(u8, case.id, id)) return case;
    }
    return error.MissingConformanceCase;
}

fn fixturePath(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    relative: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &.{ corpus_cases_root, case.id, relative });
}

fn compileNative(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
) !evaluator.ValidatedCss {
    const case_path = try std.fs.path.join(allocator, &.{ corpus_cases_root, case.id });
    defer allocator.free(case_path);
    const case_root = try std.fs.cwd().realpathAlloc(allocator, case_path);
    defer allocator.free(case_root);
    const entry_path = try std.fs.path.join(allocator, &.{ case_root, case.entry });
    defer allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(allocator, entry_path);
    defer allocator.free(entry_url);

    var authority = try resolver.Resolver.init(allocator, &.{case_root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(entry_url, input);

    var parser = try sass.Parser.init(
        allocator,
        &sources,
        source_id,
        if (std.mem.eql(u8, case.syntax, "sass")) .sass else .scss,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    var transaction = try evaluator.Transaction.init(allocator, &sources, &session, .{}, .{});
    defer transaction.deinit();
    try sass_evaluator.evaluate(allocator, &sources, &document, &transaction, .{});
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

test "native Sass matches the pinned variables conformance cohort deterministically" {
    const allocator = std.testing.allocator;
    const manifest_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        "tests/preprocessors/sass/corpus/manifest.json",
        1024 * 1024,
    );
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(
        Manifest,
        allocator,
        manifest_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u8, 1), parsed.value.schemaVersion);
    try std.testing.expectEqual(@as(usize, 80), parsed.value.caseCount);
    const case = try findCase(parsed.value.cases, "scss-variable-scope");
    try std.testing.expectEqualStrings("variables", case.feature);
    try std.testing.expectEqualStrings("scss", case.syntax);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expect(case.warning == null);

    const input_path = try fixturePath(allocator, case, case.entry);
    defer allocator.free(input_path);
    const expected_path = try fixturePath(allocator, case, case.expected);
    defer allocator.free(expected_path);
    const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
    defer allocator.free(input);
    const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
    defer allocator.free(expected);

    try std.testing.expectEqualStrings("c {\n  d: global;\n}\n", expected);

    var first = try compileNative(allocator, case, input);
    defer first.deinit();
    var second = try compileNative(allocator, case, input);
    defer second.deinit();

    try std.testing.expectEqualStrings("c{d:global}", first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
}

test "native Sass matches the pinned operators conformance cohort deterministically" {
    const allocator = std.testing.allocator;
    const manifest_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        "tests/preprocessors/sass/corpus/manifest.json",
        1024 * 1024,
    );
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(
        Manifest,
        allocator,
        manifest_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u8, 1), parsed.value.schemaVersion);
    try std.testing.expectEqual(@as(usize, 80), parsed.value.caseCount);

    const expectations = [_]struct {
        id: []const u8,
        fixture_css: []const u8,
        native_css: []const u8,
    }{
        .{
            .id = "scss-operator-precedence",
            .fixture_css = "a {\n  b: true;\n}\n",
            .native_css = "a{b:true}",
        },
        .{
            .id = "scss-plus-comments",
            .fixture_css = "a {\n  b: cd;\n}\n",
            .native_css = "a{b:cd}",
        },
        .{
            .id = "scss-minus-whitespace",
            .fixture_css = "a {\n  b: c-d;\n}\n",
            .native_css = "a{b:c-d}",
        },
    };

    for (expectations) |expectation| {
        const case = try findCase(parsed.value.cases, expectation.id);
        try std.testing.expectEqualStrings("operators", case.feature);
        try std.testing.expectEqualStrings("scss", case.syntax);
        try std.testing.expectEqualStrings("success", case.outcome);
        try std.testing.expect(case.warning == null);

        const input_path = try fixturePath(allocator, case, case.entry);
        defer allocator.free(input_path);
        const expected_path = try fixturePath(allocator, case, case.expected);
        defer allocator.free(expected_path);
        const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
        defer allocator.free(input);
        const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
        defer allocator.free(expected);

        try std.testing.expectEqualStrings(expectation.fixture_css, expected);

        var first = try compileNative(allocator, case, input);
        defer first.deinit();
        var second = try compileNative(allocator, case, input);
        defer second.deinit();

        try std.testing.expectEqualStrings(expectation.native_css, first.css());
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
        try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    }
}

test "native Sass matches the pinned control flow conformance cohort deterministically" {
    const allocator = std.testing.allocator;
    const manifest_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        "tests/preprocessors/sass/corpus/manifest.json",
        1024 * 1024,
    );
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(
        Manifest,
        allocator,
        manifest_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u8, 1), parsed.value.schemaVersion);
    try std.testing.expectEqual(@as(usize, 80), parsed.value.caseCount);

    const expectations = [_]struct {
        id: []const u8,
        syntax: []const u8,
        fixture_css: []const u8,
        native_css: []const u8,
    }{
        .{
            .id = "scss-if-escaped",
            .syntax = "scss",
            .fixture_css = "a {\n  b: c;\n}\n\n",
            .native_css = "a{b:c}",
        },
        .{
            .id = "sass-for-inclusive",
            .syntax = "sass",
            .fixture_css = "a {\n  b: 1;\n  b: 2;\n  b: 3;\n  b: 4;\n  b: 5;\n}\n",
            .native_css = "a{b:1;b:2;b:3;b:4;b:5}",
        },
        .{
            .id = "scss-for-compatible-units",
            .syntax = "scss",
            .fixture_css = "a {\n  b: 5mm;\n  b: 6mm;\n  b: 7mm;\n  b: 8mm;\n  b: 9mm;\n  b: 10mm;\n}\n",
            .native_css = "a{b:5mm;b:6mm;b:7mm;b:8mm;b:9mm;b:10mm}",
        },
    };

    for (expectations) |expectation| {
        const case = try findCase(parsed.value.cases, expectation.id);
        try std.testing.expectEqualStrings("control-flow", case.feature);
        try std.testing.expectEqualStrings(expectation.syntax, case.syntax);
        try std.testing.expectEqualStrings("success", case.outcome);
        try std.testing.expect(case.warning == null);

        const input_path = try fixturePath(allocator, case, case.entry);
        defer allocator.free(input_path);
        const expected_path = try fixturePath(allocator, case, case.expected);
        defer allocator.free(expected_path);
        const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
        defer allocator.free(input);
        const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
        defer allocator.free(expected);

        try std.testing.expectEqualStrings(expectation.fixture_css, expected);

        var first = try compileNative(allocator, case, input);
        defer first.deinit();
        var second = try compileNative(allocator, case, input);
        defer second.deinit();

        try std.testing.expectEqualStrings(expectation.native_css, first.css());
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
        try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    }
}

test "native Sass matches the pinned functions conformance cohort deterministically" {
    const allocator = std.testing.allocator;
    const manifest_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        "tests/preprocessors/sass/corpus/manifest.json",
        1024 * 1024,
    );
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(
        Manifest,
        allocator,
        manifest_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u8, 1), parsed.value.schemaVersion);
    try std.testing.expectEqual(@as(usize, 80), parsed.value.caseCount);

    const expectations = [_]struct {
        id: []const u8,
        fixture_css: []const u8,
        native_css: []const u8,
    }{
        .{
            .id = "scss-function-double-underscore",
            .fixture_css = "b {\n  c: 1;\n}\n",
            .native_css = "b{c:1}",
        },
        .{
            .id = "scss-function-escaped",
            .fixture_css = "a {\n  b: 1;\n}\n",
            .native_css = "a{b:1}",
        },
    };

    for (expectations) |expectation| {
        const case = try findCase(parsed.value.cases, expectation.id);
        try std.testing.expectEqualStrings("functions", case.feature);
        try std.testing.expectEqualStrings("scss", case.syntax);
        try std.testing.expectEqualStrings("success", case.outcome);
        try std.testing.expect(case.warning == null);

        const input_path = try fixturePath(allocator, case, case.entry);
        defer allocator.free(input_path);
        const expected_path = try fixturePath(allocator, case, case.expected);
        defer allocator.free(expected_path);
        const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
        defer allocator.free(input);
        const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
        defer allocator.free(expected);

        try std.testing.expectEqualStrings(expectation.fixture_css, expected);

        var first = try compileNative(allocator, case, input);
        defer first.deinit();
        var second = try compileNative(allocator, case, input);
        defer second.deinit();

        try std.testing.expectEqualStrings(expectation.native_css, first.css());
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
        try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    }
}
