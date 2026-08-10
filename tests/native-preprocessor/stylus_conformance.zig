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
    style: []const u8,
    providerOptions: struct {
        includeCss: bool = false,
    } = .{},
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
    return compileNativeWithLimits(allocator, case, input, .{});
}

fn compileNativeWithLimits(
    allocator: std.mem.Allocator,
    case: ManifestCase,
    input: []const u8,
    limits: stylus_evaluator.Limits,
) !evaluator.ValidatedCss {
    const corpus_root = try std.fs.cwd().realpathAlloc(allocator, corpus_files_root);
    defer allocator.free(corpus_root);
    const images_root = try std.fs.path.join(allocator, &.{ corpus_root, "upstream/images" });
    defer allocator.free(images_root);
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
    const output_style: stylus_evaluator.OutputStyle = if (std.mem.eql(
        u8,
        case.style,
        "expanded",
    ))
        .expanded
    else if (std.mem.eql(u8, case.style, "compressed"))
        .compressed
    else
        return error.InvalidConformanceCase;
    try stylus_evaluator.evaluateWithOptions(
        &sources,
        &document,
        &transaction,
        .{
            .output_style = output_style,
            .include_css = case.providerOptions.includeCss,
        },
        blk: {
            var configured = limits;
            configured.asset_load_paths = &.{images_root};
            break :blk configured;
        },
    );
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
    var include_css_success_count: usize = 0;
    var include_css_exact_count: usize = 0;
    var first_nonconforming_id: ?[]const u8 = null;
    var exact_case_id_hash = std.hash.Wyhash.init(0);
    var prior_exact_case_id_hash = std.hash.Wyhash.init(0);
    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "success")) continue;
        success_count += 1;
        include_css_success_count += @intFromBool(case.providerOptions.includeCss);

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
                if (first_nonconforming_id == null) first_nonconforming_id = case.id;
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
            include_css_exact_count += @intFromBool(case.providerOptions.includeCss);
            exact_case_id_hash.update(case.id);
            exact_case_id_hash.update("\x00");
            const became_exact_with_kwargs = std.mem.eql(
                u8,
                case.id,
                "stylus-official-kwargs",
            );
            if (!became_exact_with_kwargs) {
                prior_exact_case_id_hash.update(case.id);
                prior_exact_case_id_hash.update("\x00");
            }
        } else {
            nonconforming_count += 1;
            if (first_nonconforming_id == null) first_nonconforming_id = case.id;
        }
    }

    const exact_hash = exact_case_id_hash.final();
    if (exact_success_count != 269 or nonconforming_count != 57 or
        exact_hash != 0x3f7cdb770d00b680)
    {
        std.debug.print(
            "\nnative Stylus exact inventory: {d} exact, {d} nonconforming, {x:0>16}\n",
            .{ exact_success_count, nonconforming_count, exact_hash },
        );
    }
    try std.testing.expectEqual(@as(usize, 326), success_count);
    try std.testing.expectEqual(@as(usize, 7), include_css_success_count);
    try std.testing.expectEqual(@as(usize, 7), include_css_exact_count);
    try std.testing.expectEqual(@as(usize, 0), nondeterministic_count);
    try std.testing.expectEqual(@as(usize, 269), exact_success_count);
    try std.testing.expectEqual(@as(usize, 57), nonconforming_count);
    try std.testing.expectEqual(@as(u64, 0x3f7cdb770d00b680), exact_hash);
    try std.testing.expectEqual(
        @as(u64, 0xc463f9900345eb3c),
        prior_exact_case_id_hash.final(),
    );
    try std.testing.expectEqualStrings(
        "stylus-official-literal",
        first_nonconforming_id.?,
    );
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

test "native Stylus closes the finite coercion conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-coercion");
    try std.testing.expectEqualStrings("coercion", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |err| {
        std.debug.print("\nnative Stylus coercion mismatch\n", .{});
        return err;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite atblock conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-atblock");
    try std.testing.expectEqualStrings("at-rules", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |err| {
        std.debug.print("\nnative Stylus @block mismatch\n", .{});
        return err;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite add-property conformance family" {
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
        "stylus-official-bifs-add-property",
        "stylus-official-mixins-return",
        "stylus-official-regression-472",
        "stylus-official-regression-814",
    };
    var mismatch_count: usize = 0;
    for (case_ids) |case_id| {
        const case = try findCase(parsed.value.cases, case_id);
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
        var first = compileNative(allocator, case, input) catch |failure| {
            std.debug.print("\nnative Stylus add-property compile failure: {s}: {s}\n", .{
                case.id,
                @errorName(failure),
            });
            mismatch_count += 1;
            continue;
        };
        defer first.deinit();
        var second = try compileNative(allocator, case, input);
        defer second.deinit();

        std.testing.expectEqualStrings(expected_css.css(), first.css()) catch {
            std.debug.print("\nnative Stylus add-property mismatch: {s}\n", .{case.id});
            mismatch_count += 1;
        };
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try expectDependencyDeterminism(&first, &second);
    }
    try std.testing.expectEqual(@as(usize, 0), mismatch_count);

    for (case_ids) |case_id| {
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

test "native Stylus closes the finite cache conformance family" {
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
        "stylus-official-bifs-cache",
        "stylus-official-bifs-cache-at-media",
        "stylus-official-bifs-cache-samename",
        "stylus-official-bifs-cache-size",
    };
    var mismatch_count: usize = 0;
    for (case_ids) |case_id| {
        const case = try findCase(parsed.value.cases, case_id);
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
        var first = compileNative(allocator, case, input) catch |failure| {
            std.debug.print("\nnative Stylus cache compile failure: {s}: {s}\n", .{
                case.id,
                @errorName(failure),
            });
            mismatch_count += 1;
            continue;
        };
        defer first.deinit();
        var second = try compileNative(allocator, case, input);
        defer second.deinit();

        std.testing.expectEqualStrings(expected_css.css(), first.css()) catch {
            std.debug.print("\nnative Stylus cache mismatch: {s}\n", .{case.id});
            mismatch_count += 1;
        };
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try expectDependencyDeterminism(&first, &second);
    }
    try std.testing.expectEqual(@as(usize, 0), mismatch_count);

    for (case_ids) |case_id| {
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

test "native Stylus closes the finite contrast conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-contrast");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus contrast mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite convert conformance family" {
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
        "stylus-official-bifs-convert",
        "stylus-official-bifs-match",
    };
    var mismatch_count: usize = 0;
    for (case_ids) |case_id| {
        const case = try findCase(parsed.value.cases, case_id);
        try std.testing.expectEqualStrings("built-ins", case.feature);
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
        var first = compileNative(allocator, case, input) catch |failure| {
            std.debug.print("\nnative Stylus convert compile failure: {s}: {s}\n", .{
                case.id,
                @errorName(failure),
            });
            mismatch_count += 1;
            continue;
        };
        defer first.deinit();
        var second = try compileNative(allocator, case, input);
        defer second.deinit();

        std.testing.expectEqualStrings(expected_css.css(), first.css()) catch {
            std.debug.print("\nnative Stylus convert mismatch: {s}\n", .{case.id});
            mismatch_count += 1;
        };
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try expectDependencyDeterminism(&first, &second);
    }
    try std.testing.expectEqual(@as(usize, 0), mismatch_count);

    for (case_ids) |case_id| {
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

test "native Stylus closes the finite current-property conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-current-property");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus current-property mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite define conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-define");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus define mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite image-size conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-image-size");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus image-size mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite join conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-join");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus join mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite JSON conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-json");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus JSON mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite length conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-length");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus length mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite merge conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-merge");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus merge mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite prefix classes conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-prefix-classes");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus prefix-classes mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite push conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-push");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus push mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite saturate desaturate conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-saturate-desaturate");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus saturate-desaturate mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite selector conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-selector");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus selector mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite selector exists conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-selector-exitsts");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus selector-exists mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite transparentify conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-transparentify");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus transparentify mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite URL conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-bifs-url");
    try std.testing.expectEqualStrings("built-ins", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus URL mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite comments conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-comments");
    try std.testing.expectEqualStrings("comments", case.feature);
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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus comments mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite compressed units conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-compress-units");
    try std.testing.expectEqualStrings("compress", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("compressed", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus compressed units mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseNativeCompilationAllocationFailures,
        .{ case, input },
    );
}

test "native Stylus closes the finite control blueprint screen conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-control-blueprint-screen",
    );
    try std.testing.expectEqualStrings("control", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus control blueprint screen mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite CSS functions single-line conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-css-functions-single-line",
    );
    try std.testing.expectEqualStrings("css", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus CSS functions single-line mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite CSS keyframes conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-css-keyframes",
    );
    try std.testing.expectEqualStrings("css", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus CSS keyframes mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite CSS large conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-css-large",
    );
    try std.testing.expectEqualStrings("css", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus CSS large mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite CSS mixins root wonky conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-css-mixins-root-wonky",
    );
    try std.testing.expectEqualStrings("css", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus CSS mixins root wonky mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite CSS selector interpolation conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-css-selector-interpolation",
    );
    try std.testing.expectEqualStrings("css", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus CSS selector interpolation mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite interpolated property conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-interpolation-properties",
    );
    try std.testing.expectEqualStrings("interpolation", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compileNativeWithLimits(allocator, case, input, terminal);
    defer first.deinit();
    var second = try compileNativeWithLimits(allocator, case, input, terminal);
    defer second.deinit();

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus interpolated property mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), first.edges().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite introspection conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-introspection",
    );
    try std.testing.expectEqualStrings("introspection", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var first = try compileNativeWithLimits(allocator, case, input, terminal);
    defer first.deinit();
    var second = try compileNativeWithLimits(allocator, case, input, terminal);
    defer second.deinit();

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus introspection mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), first.edges().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite keyframes conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-keyframes",
    );
    try std.testing.expectEqualStrings("keyframes", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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
    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 59;
    terminal.max_call_depth = 1;
    var first = try compileNativeWithLimits(allocator, case, input, terminal);
    defer first.deinit();
    var second = try compileNativeWithLimits(allocator, case, input, terminal);
    defer second.deinit();

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus keyframes mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), first.edges().len);
    try expectDependencyDeterminism(&first, &second);

    var over_limit = terminal;
    over_limit.max_loop_iterations = 58;
    try std.testing.expectError(
        error.LoopLimitExceeded,
        compileNativeWithLimits(allocator, case, input, over_limit),
    );
}

test "native Stylus closes the finite keyframes fabrication defaults conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-keyframes-fabrication-defaults",
    );
    try std.testing.expectEqualStrings("keyframes", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus keyframes fabrication defaults mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), first.edges().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite keyframes newlines conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-keyframes-newlines",
    );
    try std.testing.expectEqualStrings("keyframes", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus keyframes newlines mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), first.edges().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite kwargs conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-kwargs");
    try std.testing.expectEqualStrings("kwargs", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus kwargs mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), first.edges().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite CSS selectors conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-css-selectors",
    );
    try std.testing.expectEqualStrings("css", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print("\nnative Stylus CSS selectors mismatch\n", .{});
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite CSS whitespace conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-css-whitespace",
    );
    try std.testing.expectEqualStrings("css", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus CSS whitespace mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite dumb conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-dumb");
    try std.testing.expectEqualStrings("dumb", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus dumb mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite eol escape conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-eol-escape");
    try std.testing.expectEqualStrings("eol-escape", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus eol escape mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite complex extension conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-extend-complex");
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus complex extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite loop extension conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-extend-in-loop");
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus loop extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite loop context extension conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-extend-in-loop-context");
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus loop context extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite media query extension conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-extend-in-media-query");
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus media query extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite mixin extension conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-extend-in-mixin");
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus mixin extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite nested mixin extension conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-extend-in-mixin-nested",
    );
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus nested mixin extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite multiple definition extension conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-extend-multiple-definitions",
    );
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus multiple definition extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite multiple selector extension conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-extend-multiple-selectors",
    );
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus multiple selector extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite variable extension target conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-extend-using-variable",
    );
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus variable extension target mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite optional extension target conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-extend-with-optional",
    );
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus optional extension target mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite placeholder extension conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-extend-with-placeholders",
    );
    try std.testing.expectEqualStrings("extend", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus placeholder extension mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite font face conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-fontface");
    try std.testing.expectEqualStrings("fontface", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus font face mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite complex for-loop conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-for-complex");
    try std.testing.expectEqualStrings("control", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus complex for-loop mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite function arguments conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-function-arguments");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus function arguments mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite anonymous functions conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-anonymous");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus anonymous functions mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite call mixin conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-call-mixin");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compileNativeWithLimits(allocator, case, input, terminal);
    defer first.deinit();
    var second = try compileNativeWithLimits(allocator, case, input, terminal);
    defer second.deinit();

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus call mixin mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite call to string conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-call-to-string");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus call to string mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite multiline function conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-multi-line");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus multiline function mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite multiple call conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-multiple-calls");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compileNativeWithLimits(allocator, case, input, terminal);
    defer first.deinit();
    var second = try compileNativeWithLimits(allocator, case, input, terminal);
    defer second.deinit();

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus multiple call mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite nested function conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-nested");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compileNativeWithLimits(allocator, case, input, terminal);
    defer first.deinit();
    var second = try compileNativeWithLimits(allocator, case, input, terminal);
    defer second.deinit();

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus nested function mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite function property conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-property");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var first = try compileNativeWithLimits(allocator, case, input, terminal);
    defer first.deinit();
    var second = try compileNativeWithLimits(allocator, case, input, terminal);
    defer second.deinit();

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus function property mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite function URL conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-functions-url");
    try std.testing.expectEqualStrings("functions", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus function URL mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 1), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 1), first.edges().len);
    try std.testing.expectEqual(resolver.DependencyKind.reference, first.dependencies()[0].kind);
    try std.testing.expectEqualStrings("circle.svg", std.fs.path.basename(first.dependencies()[0].url));
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite if conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-if");
    try std.testing.expectEqualStrings("control", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus if mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite if else conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-if-else");
    try std.testing.expectEqualStrings("control", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus if else mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite if mixin conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-if-mixin");
    try std.testing.expectEqualStrings("control", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus if mixin mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
}

test "native Stylus closes the finite import clone conformance family" {
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

    const case = try findCase(parsed.value.cases, "stylus-official-import-clone");
    try std.testing.expectEqualStrings("imports", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus import clone mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.expectEqual(@as(usize, 3), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 4), first.edges().len);
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 5);
}

test "native Stylus closes the finite import include complex conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-import-include-complex",
    );
    try std.testing.expectEqualStrings("imports", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);
    try std.testing.expect(case.providerOptions.includeCss);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus import include complex mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.expectEqual(@as(usize, 3), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 3), first.edges().len);
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 2);
}

test "native Stylus closes the finite import include function call conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-import-include-function-call",
    );
    try std.testing.expectEqualStrings("imports", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);
    try std.testing.expect(case.providerOptions.includeCss);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus import include function call mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.expectEqual(@as(usize, 2), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 2), first.edges().len);
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 2);
}

test "native Stylus closes the finite import lookup conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-import-lookup",
    );
    try std.testing.expectEqualStrings("imports", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);
    try std.testing.expect(!case.providerOptions.includeCss);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus import lookup mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.expectEqual(@as(usize, 5), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 5), first.edges().len);
    try std.testing.expectEqual(resolver.DependencyKind.reference, first.dependencies()[2].kind);
    try std.testing.expect(std.mem.endsWith(
        u8,
        first.dependencies()[2].url,
        "/node_modules/lookup-b/package.json",
    ));
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 3);
}

test "native Stylus closes the finite import ordering conformance family" {
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

    const case = try findCase(
        parsed.value.cases,
        "stylus-official-import-ordering",
    );
    try std.testing.expectEqualStrings("imports", case.feature);
    try std.testing.expectEqualStrings("success", case.outcome);
    try std.testing.expectEqualStrings("expanded", case.style);
    try std.testing.expect(!case.providerOptions.includeCss);

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

    std.testing.expectEqualStrings(expected_css.css(), first.css()) catch |failure| {
        std.debug.print(
            "\nnative Stylus import ordering mismatch\nexpected: {s}\nactual:   {s}\n",
            .{ expected_css.css(), first.css() },
        );
        return failure;
    };
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try expectDependencyDeterminism(&first, &second);
    try std.testing.expectEqual(@as(usize, 3), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 3), first.edges().len);
    for ([_][]const u8{ "two.styl", "four.styl", "five.styl" }, 0..) |basename, index| {
        try std.testing.expectEqual(resolver.DependencyKind.import, first.dependencies()[index].kind);
        try std.testing.expectEqualStrings(basename, std.fs.path.basename(first.dependencies()[index].url));
    }
    try std.testing.expect(std.mem.endsWith(
        u8,
        first.edges()[0].parent_url.?,
        "/upstream/cases/import.ordering.styl",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        first.edges()[1].parent_url.?,
        "/upstream/cases/import.ordering.styl",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        first.edges()[2].parent_url.?,
        "/upstream/cases/import.ordering/four.styl",
    ));
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 3);
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
