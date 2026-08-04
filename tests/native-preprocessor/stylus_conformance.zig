const std = @import("std");
const preprocessor = @import("native_preprocessor");

const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;
const stylus = preprocessor.stylus;
const stylus_evaluator = preprocessor.stylus_evaluator;

const corpus_files_root = "tests/preprocessors/stylus/corpus/files";
const max_fixture_bytes = 10 * 1024 * 1024;

const ManifestCase = struct {
    id: []const u8,
    feature: []const u8,
    outcome: []const u8,
    entry: []const u8,
    expected: std.json.Value,
};

const Manifest = struct {
    schemaVersion: u8,
    caseCount: usize,
    officialSuccessCount: usize,
    integrationErrorCount: usize,
    cases: []const ManifestCase,
};

fn findCase(cases: []const ManifestCase, id: []const u8) !ManifestCase {
    for (cases) |case| {
        if (std.mem.eql(u8, case.id, id)) return case;
    }
    return error.MissingConformanceCase;
}

fn expectedPath(case: ManifestCase) ![]const u8 {
    return switch (case.expected) {
        .string => |path| path,
        else => error.InvalidConformanceCase,
    };
}

fn fixturePath(
    allocator: std.mem.Allocator,
    relative: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &.{ corpus_files_root, relative });
}

fn compileNative(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
) !evaluator.ValidatedCss {
    const corpus_root = try std.fs.cwd().realpathAlloc(allocator, corpus_files_root);
    defer allocator.free(corpus_root);
    const entry_path = try std.fs.path.join(allocator, &.{ corpus_root, case.entry });
    defer allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(allocator, entry_path);
    defer allocator.free(entry_url);

    var authority = try resolver.Resolver.init(allocator, &.{corpus_root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(entry_url, input);

    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    var transaction = try evaluator.Transaction.init(allocator, &sources, &session, .{}, .{});
    defer transaction.deinit();
    try stylus_evaluator.evaluate(&sources, &document, &transaction, .{});
    return transaction.finish(.{ .format = .pretty, .source_map = true });
}

fn compileExpectedCss(
    allocator: std.mem.Allocator,
    expected: []const u8,
) !evaluator.ValidatedCss {
    const corpus_root = try std.fs.cwd().realpathAlloc(allocator, corpus_files_root);
    defer allocator.free(corpus_root);

    var authority = try resolver.Resolver.init(allocator, &.{corpus_root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    var transaction = try evaluator.Transaction.init(allocator, &sources, &session, .{}, .{});
    defer transaction.deinit();
    try transaction.emit(expected);
    return transaction.finish(.{ .format = .pretty });
}

test "native Stylus matches the pinned variable conformance cohort deterministically" {
    const allocator = std.testing.allocator;
    const manifest_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        "tests/preprocessors/stylus/corpus/manifest.json",
        2 * 1024 * 1024,
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
    try std.testing.expectEqual(@as(usize, 346), parsed.value.caseCount);
    try std.testing.expectEqual(parsed.value.caseCount, parsed.value.cases.len);
    try std.testing.expectEqual(@as(usize, 326), parsed.value.officialSuccessCount);
    try std.testing.expectEqual(@as(usize, 20), parsed.value.integrationErrorCount);

    const case = try findCase(parsed.value.cases, "stylus-official-variable");
    try std.testing.expectEqualStrings("variable", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);

    const input_path = try fixturePath(allocator, case.entry);
    defer allocator.free(input_path);
    const expected_path = try fixturePath(allocator, try expectedPath(case));
    defer allocator.free(expected_path);
    const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
    defer allocator.free(input);
    const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
    defer allocator.free(expected);

    try std.testing.expectEqualStrings("body {\n  font: 12px;\n}", expected);

    var expected_css = try compileExpectedCss(allocator, expected);
    defer expected_css.deinit();
    var first = try compileNative(allocator, case, input);
    defer first.deinit();
    var second = try compileNative(allocator, case, input);
    defer second.deinit();

    try std.testing.expectEqualStrings(expected_css.css(), first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}
