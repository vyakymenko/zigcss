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

fn nativeFailureName(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
) ?[]const u8 {
    var compiled = compileNative(allocator, case, input) catch |err| return @errorName(err);
    compiled.deinit();
    return null;
}

fn expectDependencyDeterminism(
    first: *const evaluator.ValidatedCss,
    second: *const evaluator.ValidatedCss,
) !void {
    try std.testing.expectEqual(first.dependencies().len, second.dependencies().len);
    for (first.dependencies(), second.dependencies()) |left, right| {
        try std.testing.expectEqual(left.kind, right.kind);
        try std.testing.expectEqualStrings(left.url, right.url);
    }
    try std.testing.expectEqual(first.edges().len, second.edges().len);
    for (first.edges(), second.edges()) |left, right| {
        try std.testing.expectEqual(left.kind, right.kind);
        if (left.parent_url) |left_parent| {
            try std.testing.expect(right.parent_url != null);
            try std.testing.expectEqualStrings(left_parent, right.parent_url.?);
        } else {
            try std.testing.expect(right.parent_url == null);
        }
        try std.testing.expectEqualStrings(left.child_url, right.child_url);
    }
}

const ConcurrentCompilation = struct {
    case: ManifestCase,
    input: []const u8,
    css_hash: u64 = 0,
    map_hash: u64 = 0,
    dependency_hash: u64 = 0,
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
    var dependency_hash = std.hash.Wyhash.init(0);
    for (compiled.dependencies()) |dependency| {
        dependency_hash.update(@tagName(dependency.kind));
        dependency_hash.update(dependency.url);
    }
    for (compiled.edges()) |edge| {
        dependency_hash.update(@tagName(edge.kind));
        if (edge.parent_url) |parent_url| dependency_hash.update(parent_url);
        dependency_hash.update(edge.child_url);
    }
    context.dependency_hash = dependency_hash.final();
}

fn exerciseNativeCompilationAllocationFailures(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
) !void {
    var compiled = try compileNative(allocator, case, input);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), compiled.coreDiagnostics().len);
}

fn cancellationRequested(_: *anyopaque, _: stylus.Checkpoint) bool {
    return true;
}

test "native Stylus measures the finite pinned success corpus without ordinal expansion" {
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

    var success_count: usize = 0;
    var exact_success_count: usize = 0;
    var nonconforming_count: usize = 0;
    var nondeterministic_count: usize = 0;
    var exact_case_id_hash = std.hash.Wyhash.init(0);
    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "success")) continue;
        success_count += 1;

        const input_path = try fixturePath(allocator, case.entry);
        defer allocator.free(input_path);
        const expected_path = try fixturePath(allocator, try expectedPath(case));
        defer allocator.free(expected_path);
        const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
        defer allocator.free(input);
        const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
        defer allocator.free(expected);

        var expected_css = try compileExpectedCss(allocator, expected);
        defer expected_css.deinit();
        var first = compileNative(allocator, case, input) catch |err| {
            const repeated = nativeFailureName(allocator, case, input);
            if (repeated == null or !std.mem.eql(u8, @errorName(err), repeated.?)) {
                nondeterministic_count += 1;
            } else {
                nonconforming_count += 1;
            }
            continue;
        };
        defer first.deinit();
        var second = compileNative(allocator, case, input) catch {
            nondeterministic_count += 1;
            continue;
        };
        defer second.deinit();

        const equivalent = try evaluator.equivalentCss(allocator, expected_css.css(), first.css());
        const deterministic = std.mem.eql(u8, first.css(), second.css()) and
            std.mem.eql(u8, first.sourceMap().?, second.sourceMap().?) and
            first.nativeDiagnostics().len == 0 and
            first.coreDiagnostics().len == 0;
        if (!deterministic) {
            nondeterministic_count += 1;
            continue;
        }
        expectDependencyDeterminism(&first, &second) catch {
            nondeterministic_count += 1;
            continue;
        };
        if (equivalent and std.mem.eql(u8, expected_css.css(), first.css())) {
            exact_success_count += 1;
            exact_case_id_hash.update(case.id);
            exact_case_id_hash.update("\x00");
        } else {
            nonconforming_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 326), success_count);
    try std.testing.expectEqual(@as(usize, 0), nondeterministic_count);
    try std.testing.expectEqual(@as(usize, 164), exact_success_count);
    try std.testing.expectEqual(@as(usize, 162), nonconforming_count);
    try std.testing.expectEqual(@as(u64, 0xf0d3f1294f4f10df), exact_case_id_hash.final());
}

test "native Stylus closes the finite arithmetic conformance family" {
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

    const case_ids = [_][]const u8{
        "stylus-official-arithmetic",
        "stylus-official-arithmetic-color",
        "stylus-official-arithmetic-unary",
    };
    var mismatch_count: usize = 0;
    for (case_ids) |case_id| {
        const case = try findCase(parsed.value.cases, case_id);
        try std.testing.expectEqualStrings("arithmetic", case.feature);
        try std.testing.expectEqualStrings("success", case.outcome);

        const input_path = try fixturePath(allocator, case.entry);
        defer allocator.free(input_path);
        const expected_path = try fixturePath(allocator, try expectedPath(case));
        defer allocator.free(expected_path);
        const input = try std.fs.cwd().readFileAlloc(allocator, input_path, max_fixture_bytes);
        defer allocator.free(input);
        const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_bytes);
        defer allocator.free(expected);

        var expected_css = try compileExpectedCss(allocator, expected);
        defer expected_css.deinit();
        var first = try compileNative(allocator, case, input);
        defer first.deinit();
        var second = try compileNative(allocator, case, input);
        defer second.deinit();

        std.testing.expectEqualStrings(expected_css.css(), first.css()) catch {
            std.debug.print("\nnative Stylus arithmetic mismatch: {s}\n", .{case.id});
            mismatch_count += 1;
        };
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try expectDependencyDeterminism(&first, &second);
    }
    try std.testing.expectEqual(@as(usize, 0), mismatch_count);

    const allocation_case_ids = [_][]const u8{
        "stylus-official-arithmetic-color",
        "stylus-official-arithmetic-unary",
    };
    for (allocation_case_ids) |case_id| {
        const case = try findCase(parsed.value.cases, case_id);
        const input_path = try fixturePath(allocator, case.entry);
        defer allocator.free(input_path);
        const input = try std.fs.cwd().readFileAlloc(
            allocator,
            input_path,
            max_fixture_bytes,
        );
        defer allocator.free(input);
        try std.testing.checkAllAllocationFailures(
            allocator,
            exerciseNativeCompilationAllocationFailures,
            .{ case, input },
        );
    }
}

test "native Stylus rejects the finite pinned error corpus deterministically" {
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

    var error_count: usize = 0;
    var acceptance_count: usize = 0;
    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "error")) continue;
        error_count += 1;
        const input_path = try fixturePath(allocator, case.entry);
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

test "native Stylus parser owns finite resource and cancellation boundaries" {
    const allocator = std.testing.allocator;
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();

    const lower_id = try sources.add("memory:///lower.styl", "a = 1\n");
    var lower = try stylus.Parser.init(
        allocator,
        &sources,
        lower_id,
        .{ .max_statements = 2 },
        .{},
    );
    defer lower.deinit();
    var lower_document = try lower.parse();
    defer lower_document.deinit();

    const terminal_id = try sources.add("memory:///terminal.styl", "a = 1\nb = 2\n");
    var terminal = try stylus.Parser.init(
        allocator,
        &sources,
        terminal_id,
        .{ .max_statements = 2 },
        .{},
    );
    defer terminal.deinit();
    var terminal_document = try terminal.parse();
    defer terminal_document.deinit();

    const over_id = try sources.add("memory:///over.styl", "a = 1\nb = 2\nc = 3\n");
    var over = try stylus.Parser.init(
        allocator,
        &sources,
        over_id,
        .{ .max_statements = 2 },
        .{},
    );
    defer over.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, over.parse());

    var cancellation_flag: u8 = 0;
    const cancelled_id = try sources.add("memory:///cancelled.styl", "a = 1\n");
    try std.testing.expectError(
        error.Cancelled,
        stylus.Parser.init(
            allocator,
            &sources,
            cancelled_id,
            .{},
            .{ .context = &cancellation_flag, .check_fn = cancellationRequested },
        ),
    );
}

test "native Stylus compilation is deterministic under bounded concurrency" {
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

    const first_case = try findCase(parsed.value.cases, "stylus-official-variable");
    const second_case = try findCase(parsed.value.cases, "stylus-official-self-assignment");
    const first_path = try fixturePath(allocator, first_case.entry);
    defer allocator.free(first_path);
    const second_path = try fixturePath(allocator, second_case.entry);
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
    spawned = 0;
    for (contexts) |context| try std.testing.expect(context.failure == null);
    try std.testing.expectEqual(contexts[0].css_hash, contexts[2].css_hash);
    try std.testing.expectEqual(contexts[0].map_hash, contexts[2].map_hash);
    try std.testing.expectEqual(contexts[0].dependency_hash, contexts[2].dependency_hash);
    try std.testing.expectEqual(contexts[1].css_hash, contexts[3].css_hash);
    try std.testing.expectEqual(contexts[1].map_hash, contexts[3].map_hash);
    try std.testing.expectEqual(contexts[1].dependency_hash, contexts[3].dependency_hash);
}

test "native Stylus finite corpus seeds bounded parser and evaluator fuzzing" {
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

    var mutation_count: usize = 0;
    for (parsed.value.cases) |case| {
        const input_path = try fixturePath(allocator, case.entry);
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
    try std.testing.expectEqual(@as(usize, 1_038), mutation_count);
}

test "native Stylus successful transaction handles every allocation failure" {
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
    const case = try findCase(parsed.value.cases, "stylus-official-variable");
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, "size = 12px\nbody\n  font size\n" },
    );
}
