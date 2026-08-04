const std = @import("std");
const preprocessor = @import("native_preprocessor");

const evaluator = preprocessor.evaluator;
const less = preprocessor.less;
const less_evaluator = preprocessor.less_evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;

const corpus_files_root = "tests/preprocessors/less/corpus/files";
const max_fixture_bytes = 10 * 1024 * 1024;

const SelectionCase = struct {
    id: []const u8,
    feature: []const u8,
    suite: []const u8,
    outcome: []const u8,
    entry: []const u8,
    expected: []const u8,
};

const Selection = struct {
    schemaVersion: u8,
    cases: []const SelectionCase,
};

fn findCase(cases: []const SelectionCase, id: []const u8) !SelectionCase {
    for (cases) |case| {
        if (std.mem.eql(u8, case.id, id)) return case;
    }
    return error.MissingConformanceCase;
}

fn suitePath(allocator: std.mem.Allocator, case: SelectionCase) ![]u8 {
    return std.fs.path.join(allocator, &.{ corpus_files_root, case.suite });
}

fn fixturePath(
    allocator: std.mem.Allocator,
    case: SelectionCase,
    relative: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &.{ corpus_files_root, case.suite, relative });
}

fn compileNative(
    allocator: std.mem.Allocator,
    case: SelectionCase,
    input: []const u8,
) !evaluator.ValidatedCss {
    const suite_path = try suitePath(allocator, case);
    defer allocator.free(suite_path);
    const suite_root = try std.fs.cwd().realpathAlloc(allocator, suite_path);
    defer allocator.free(suite_root);
    const entry_path = try std.fs.path.join(allocator, &.{ suite_root, case.entry });
    defer allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(allocator, entry_path);
    defer allocator.free(entry_url);

    var authority = try resolver.Resolver.init(allocator, &.{suite_root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(entry_url, input);

    var parser = try less.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    var transaction = try evaluator.Transaction.init(allocator, &sources, &session, .{}, .{});
    defer transaction.deinit();
    try less_evaluator.evaluateWithOptions(
        &sources,
        &document,
        &transaction,
        .{},
        .{},
    );
    return transaction.finish(.{ .format = .pretty, .source_map = true });
}

fn compileExpectedCss(
    allocator: std.mem.Allocator,
    case: SelectionCase,
    expected: []const u8,
) !evaluator.ValidatedCss {
    const suite_path = try suitePath(allocator, case);
    defer allocator.free(suite_path);
    const suite_root = try std.fs.cwd().realpathAlloc(allocator, suite_path);
    defer allocator.free(suite_root);

    var authority = try resolver.Resolver.init(allocator, &.{suite_root}, .{});
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

fn expectSuccessCase(
    allocator: std.mem.Allocator,
    case_id: []const u8,
    feature: []const u8,
) !void {
    const selection_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        "tests/preprocessors/less/corpus/selection.json",
        1024 * 1024,
    );
    defer allocator.free(selection_bytes);
    var parsed = try std.json.parseFromSlice(
        Selection,
        allocator,
        selection_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u8, 1), parsed.value.schemaVersion);
    try std.testing.expectEqual(@as(usize, 88), parsed.value.cases.len);
    const case = try findCase(parsed.value.cases, case_id);
    try std.testing.expectEqualStrings(feature, case.feature);
    try std.testing.expectEqualStrings("tests-unit", case.suite);
    try std.testing.expectEqualStrings("success", case.outcome);

    const input_path = try fixturePath(allocator, case, case.entry);
    defer allocator.free(input_path);
    const expected_path = try fixturePath(allocator, case, case.expected);
    defer allocator.free(expected_path);
    const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
    defer allocator.free(input);
    const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
    defer allocator.free(expected);

    var expected_css = try compileExpectedCss(allocator, case, expected);
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

test "native Less matches the pinned at-rules declarations conformance cohort deterministically" {
    try expectSuccessCase(
        std.testing.allocator,
        "less-at-rules-declarations-at-rules-declarations",
        "at-rules-declarations",
    );
}

test "native Less matches the pinned at-rules empty block conformance cohort deterministically" {
    try expectSuccessCase(
        std.testing.allocator,
        "less-at-rules-empty-block-at-rules-empty-block",
        "at-rules-empty-block",
    );
}

test "native Less matches the pinned blockless at-rules conformance cohort deterministically" {
    try expectSuccessCase(
        std.testing.allocator,
        "less-at-rules-empty-at-rules-empty",
        "at-rules-empty",
    );
}
