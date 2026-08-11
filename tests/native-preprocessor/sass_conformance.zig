const std = @import("std");
const preprocessor = @import("native_preprocessor");

const compiler = preprocessor.compiler;
const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const sass = preprocessor.sass;
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

fn caseRoot(allocator: std.mem.Allocator, case: ManifestCase) ![]u8 {
    const repository_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(repository_root);
    return std.fs.path.join(allocator, &.{ repository_root, corpus_cases_root, case.id });
}

fn compileNative(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
) !compiler.Result {
    return compileNativeWithOptions(
        allocator,
        case,
        input,
        .{ .format = .minified, .source_map = true },
    );
}

fn compileNativeWithOptions(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
    options: evaluator.Options,
) !compiler.Result {
    const case_root = try caseRoot(allocator, case);
    defer allocator.free(case_root);
    const entry_path = try std.fs.path.join(allocator, &.{ case_root, case.entry });
    defer allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(allocator, entry_path);
    defer allocator.free(entry_url);

    return compiler.compile(allocator, entry_url, input, .{
        .syntax = if (std.mem.eql(u8, case.syntax, "sass")) .sass else .scss,
        .root_paths = &.{case_root},
        .format = options.format,
        .source_map = options.source_map,
    });
}

fn compileExpectedCss(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    expected: []const u8,
) !evaluator.ValidatedCss {
    const case_root = try caseRoot(allocator, case);
    defer allocator.free(case_root);

    var authority = try resolver.Resolver.init(allocator, &.{case_root}, .{});
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

fn withoutUtf8Charset(css: []const u8) []const u8 {
    const prefix = "@charset \"UTF-8\";";
    if (!std.mem.startsWith(u8, css, prefix)) return css;
    return std.mem.trimLeft(u8, css[prefix.len..], "\r\n");
}

fn normalizeCommaWhitespace(allocator: std.mem.Allocator, css: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    var quote: ?u8 = null;
    while (index < css.len) {
        const byte = css[index];
        if (quote) |active| {
            try output.append(allocator, byte);
            index += 1;
            if (byte == '\\' and index < css.len) {
                try output.append(allocator, css[index]);
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            try output.append(allocator, byte);
            index += 1;
            continue;
        }
        if (byte == '/' and index + 1 < css.len and css[index + 1] == '*') {
            const end = if (std.mem.indexOf(u8, css[index + 2 ..], "*/")) |relative|
                index + 2 + relative + 2
            else
                css.len;
            try output.appendSlice(allocator, css[index..end]);
            index = end;
            continue;
        }
        if (byte == ',') {
            while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) {
                output.items.len -= 1;
            }
            try output.append(allocator, ',');
            index += 1;
            while (index < css.len and std.ascii.isWhitespace(css[index])) index += 1;
            continue;
        }
        try output.append(allocator, byte);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn nativeFailureName(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
) ?[]const u8 {
    var compiled = compileNative(allocator, case, input) catch |err| return @errorName(err);
    compiled.deinit();
    return null;
}

const ConcurrentCompilation = struct {
    case: ManifestCase,
    input: []const u8,
    css_hash: u64 = 0,
    map_hash: u64 = 0,
    failure: ?anyerror = null,
};

fn compileConcurrently(context: *ConcurrentCompilation) void {
    var allocator_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (allocator_state.deinit() == .leak and context.failure == null) {
        context.failure = error.MemoryLeak;
    };
    const allocator = allocator_state.allocator();
    var compiled = compileNative(allocator, context.case, context.input) catch |err| {
        context.failure = err;
        return;
    };
    defer compiled.deinit();
    context.css_hash = std.hash.Wyhash.hash(0, compiled.css());
    context.map_hash = std.hash.Wyhash.hash(0, compiled.sourceMap().?);
}

fn exerciseNativeCompilationAllocationFailures(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
) !void {
    var compiled = try compileNative(allocator, case, input);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.coreDiagnostics().len);
}

fn cancellationRequested(_: *anyopaque, _: sass.Checkpoint) bool {
    return true;
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

test "native Sass closes the finite pinned success corpus deterministically" {
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
    try std.testing.expectEqual(parsed.value.caseCount, parsed.value.cases.len);

    var success_count: usize = 0;
    var failure_count: usize = 0;
    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "success")) continue;
        success_count += 1;

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
        var first = compileNativeWithOptions(
            allocator,
            case,
            input,
            .{ .format = .pretty, .source_map = true },
        ) catch |err| {
            std.debug.print("\n{s}: native compilation failed with {s}\n", .{ case.id, @errorName(err) });
            failure_count += 1;
            continue;
        };
        defer first.deinit();
        var second = compileNativeWithOptions(
            allocator,
            case,
            input,
            .{ .format = .pretty, .source_map = true },
        ) catch |err| {
            std.debug.print("\n{s}: repeated native compilation failed with {s}\n", .{ case.id, @errorName(err) });
            failure_count += 1;
            continue;
        };
        defer second.deinit();

        const expected_warning_count: usize = if (case.warning == null) 0 else 1;
        const normalized_expected = try normalizeCommaWhitespace(
            allocator,
            withoutUtf8Charset(expected_css.css()),
        );
        defer allocator.free(normalized_expected);
        const normalized_actual = try normalizeCommaWhitespace(allocator, first.css());
        defer allocator.free(normalized_actual);
        const equivalent = try evaluator.equivalentCss(
            allocator,
            normalized_expected,
            normalized_actual,
        );
        const matches = equivalent and
            std.mem.eql(u8, normalized_expected, normalized_actual) and
            std.mem.eql(u8, first.css(), second.css()) and
            std.mem.eql(u8, first.sourceMap().?, second.sourceMap().?) and
            first.nativeDiagnostics().len == expected_warning_count and
            first.coreDiagnostics().len == 0 and
            first.dependencies().len == second.dependencies().len;
        if (!matches) {
            std.debug.print(
                "\n{s}: conformance mismatch\nexpected: {s}\nactual:   {s}\nnative diagnostics: {d}\ncore diagnostics: {d}\ndependencies: {d}/{d}\n",
                .{
                    case.id,
                    expected_css.css(),
                    first.css(),
                    first.nativeDiagnostics().len,
                    first.coreDiagnostics().len,
                    first.dependencies().len,
                    second.dependencies().len,
                },
            );
            failure_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 60), success_count);
    try std.testing.expectEqual(@as(usize, 0), failure_count);
}

test "native Sass rejects the finite pinned error corpus deterministically" {
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

    var error_count: usize = 0;
    var acceptance_count: usize = 0;
    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "error")) continue;
        error_count += 1;
        const input_path = try fixturePath(allocator, case, case.entry);
        defer allocator.free(input_path);
        const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
        defer allocator.free(input);
        const first = nativeFailureName(allocator, case, input);
        const second = nativeFailureName(allocator, case, input);
        if (first == null or second == null) {
            std.debug.print("\n{s}: expected native rejection but compilation succeeded\n", .{case.id});
            acceptance_count += 1;
            continue;
        }
        try std.testing.expectEqualStrings(first.?, second.?);
    }
    try std.testing.expectEqual(@as(usize, 20), error_count);
    try std.testing.expectEqual(@as(usize, 0), acceptance_count);
}

test "native Sass parser owns finite resource and cancellation boundaries" {
    const allocator = std.testing.allocator;
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();

    const lower_id = try sources.add("memory:///lower.scss", "$a: 1;");
    var lower = try sass.Parser.init(
        allocator,
        &sources,
        lower_id,
        .scss,
        .{ .max_statements = 1 },
        .{},
    );
    defer lower.deinit();
    var lower_document = try lower.parse();
    defer lower_document.deinit();

    const over_id = try sources.add("memory:///over.scss", "$a: 1; $b: 2;");
    var over = try sass.Parser.init(
        allocator,
        &sources,
        over_id,
        .scss,
        .{ .max_statements = 1 },
        .{},
    );
    defer over.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, over.parse());

    var cancellation_flag: u8 = 0;
    const cancelled_id = try sources.add("memory:///cancelled.scss", "$a: 1;");
    try std.testing.expectError(
        error.Cancelled,
        sass.Parser.init(
            allocator,
            &sources,
            cancelled_id,
            .scss,
            .{},
            .{ .context = &cancellation_flag, .check_fn = cancellationRequested },
        ),
    );
}

test "native Sass compilation is deterministic under bounded concurrency" {
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

    const first_case = try findCase(parsed.value.cases, "scss-extend-pseudo");
    const second_case = try findCase(parsed.value.cases, "sass-css-function-nested");
    const first_path = try fixturePath(allocator, first_case, first_case.entry);
    defer allocator.free(first_path);
    const second_path = try fixturePath(allocator, second_case, second_case.entry);
    defer allocator.free(second_path);
    const first_input = try std.fs.cwd().readFileAlloc(allocator, first_path, max_fixture_bytes);
    defer allocator.free(first_input);
    const second_input = try std.fs.cwd().readFileAlloc(allocator, second_path, max_fixture_bytes);
    defer allocator.free(second_input);

    var contexts = [_]ConcurrentCompilation{
        .{ .case = first_case, .input = first_input },
        .{ .case = second_case, .input = second_input },
        .{ .case = first_case, .input = first_input },
        .{ .case = second_case, .input = second_input },
    };
    var threads: [contexts.len]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();
    for (&contexts, 0..) |*context, index| {
        threads[index] = try std.Thread.spawn(.{}, compileConcurrently, .{context});
        spawned += 1;
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expect(context.failure == null);
    try std.testing.expectEqual(contexts[0].css_hash, contexts[2].css_hash);
    try std.testing.expectEqual(contexts[0].map_hash, contexts[2].map_hash);
    try std.testing.expectEqual(contexts[1].css_hash, contexts[3].css_hash);
    try std.testing.expectEqual(contexts[1].map_hash, contexts[3].map_hash);
}

test "native Sass finite corpus seeds bounded parser and evaluator fuzzing" {
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

    var mutation_count: usize = 0;
    for (parsed.value.cases) |case| {
        const input_path = try fixturePath(allocator, case, case.entry);
        defer allocator.free(input_path);
        const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
        defer allocator.free(input);
        const cuts = [_]usize{ 0, input.len / 2, input.len -| 1 };
        for (cuts) |cut| {
            mutation_count += 1;
            var compiled = compileNative(allocator, case, input[0..cut]) catch continue;
            defer compiled.deinit();
            try std.testing.expectEqual(@as(usize, 0), compiled.coreDiagnostics().len);
        }
    }
    try std.testing.expectEqual(@as(usize, 240), mutation_count);
}

test "native Sass successful transaction handles every allocation failure" {
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
    const case = try findCase(parsed.value.cases, "scss-variable-scope");
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, "a { b: c; }" },
    );
}
