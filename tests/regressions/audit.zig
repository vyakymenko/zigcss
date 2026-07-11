const std = @import("std");
const audit_options = @import("audit_options");

const Child = std.process.Child;
const allocator = std.testing.allocator;

fn runInDir(dir: std.fs.Dir, argv_tail: []const []const u8) !Child.RunResult {
    const argv = try allocator.alloc([]const u8, argv_tail.len + 1);
    defer allocator.free(argv);
    argv[0] = audit_options.compiler_path;
    @memcpy(argv[1..], argv_tail);

    return Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd_dir = dir,
        .max_output_bytes = 1024 * 1024,
    });
}

fn runCompiler(input: []const u8, extra_args: []const []const u8) !Child.RunResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = input });

    const argv_tail = try allocator.alloc([]const u8, extra_args.len + 1);
    defer allocator.free(argv_tail);
    argv_tail[0] = "input.css";
    @memcpy(argv_tail[1..], extra_args);
    return runInDir(tmp.dir, argv_tail);
}

fn deinitRun(result: *Child.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn succeeded(term: Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn expectSuccess(result: Child.RunResult) !void {
    if (!succeeded(result.term)) {
        std.debug.print("unexpected child failure\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    }
    try std.testing.expect(succeeded(result.term));
}

fn expectFailureContaining(result: Child.RunResult, expected: []const u8) !void {
    try std.testing.expect(!succeeded(result.term));
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
}

fn expectUnsafeTransformsDisabled(result: Child.RunResult) !void {
    try std.testing.expect(!succeeded(result.term));
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsafe optimizer and transform passes are disabled") != null);
}

test "legacy quarantine: compound selectors collapse into descendants (AST-001, PAR-001)" {
    var compound = try runCompiler(@embedFile("fixtures/compound.css"), &.{"--minify"});
    defer deinitRun(&compound);
    var descendant = try runCompiler(@embedFile("fixtures/descendant.css"), &.{"--minify"});
    defer deinitRun(&descendant);

    try expectSuccess(compound);
    try expectSuccess(descendant);
    try std.testing.expectEqualStrings(".a .b{color:red}", compound.stdout);
    try std.testing.expectEqualStrings(compound.stdout, descendant.stdout);
}

test "legacy quarantine: functional and attribute selectors are rejected (AST-001, PAR-001)" {
    var result = try runCompiler(@embedFile("fixtures/functional-attribute.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectFailureContaining(result, "expected opening brace");
}

test "legacy quarantine: delimiters inside strings and functions corrupt parsing (TOK-002, SYN-001, PAR-002)" {
    var result = try runCompiler(@embedFile("fixtures/nested-delimiters.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectFailureContaining(result, "invalid identifier");
}

test "legacy quarantine: declaration-bearing at-rules are rejected (AST-003, PAR-003)" {
    var result = try runCompiler(@embedFile("fixtures/font-face.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectFailureContaining(result, "invalid identifier");
}

test "legacy quarantine: percentage keyframes are rejected (AST-003, PAR-004)" {
    var result = try runCompiler(@embedFile("fixtures/keyframes.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectFailureContaining(result, "invalid identifier");
}

test "legacy quarantine: minified at-rules omit mandatory whitespace (EMIT-002)" {
    var result = try runCompiler(@embedFile("fixtures/media.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("@mediascreen{.a{color:red}}", result.stdout);
}

test "optimizer containment: importance and fallback input cannot reach unsafe passes (OPT-001)" {
    var result = try runCompiler(@embedFile("fixtures/important.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectUnsafeTransformsDisabled(result);
}

test "optimizer containment: empty-rule input cannot reach unsafe passes (OPT-001)" {
    var result = try runCompiler(@embedFile("fixtures/empty-leading.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectUnsafeTransformsDisabled(result);
}

test "optimizer containment: non-adjacent merge input cannot reach unsafe passes (OPT-001)" {
    var result = try runCompiler(@embedFile("fixtures/nonadjacent.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectUnsafeTransformsDisabled(result);
}

test "optimizer containment: cascade-sensitive input cannot reach unsafe passes (OPT-001)" {
    var result = try runCompiler(@embedFile("fixtures/custom-logical-reset.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectUnsafeTransformsDisabled(result);
}

test "optimizer containment: typed math input cannot reach unsafe folding (OPT-001)" {
    var result = try runCompiler(@embedFile("fixtures/math.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectUnsafeTransformsDisabled(result);
}

test "optimizer containment: selector crash input is rejected before optimization (OPT-001)" {
    var result = try runCompiler(@embedFile("fixtures/selector-crash.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectUnsafeTransformsDisabled(result);
}

test "profiling lifecycle: each timing ends once and compilation succeeds (PROF-001)" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{ "--profile", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(".simple{color:red}", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Performance Profile") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stderr, "parse"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stderr, "optimize"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stderr, "codegen"));
}

test "legacy quarantine: source-map flag succeeds without a map (CLI-002, MAP-001)" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{ "--source-map", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(".simple{color:red}", result.stdout);
}

test "optimizer containment: unverified prefix transforms are unavailable (OPT-001)" {
    const input = @embedFile("fixtures/prefix.css");
    var modern = try runCompiler(input, &.{ "--autoprefix", "--browsers", "chrome120", "--minify" });
    defer deinitRun(&modern);
    var legacy = try runCompiler(input, &.{ "--autoprefix", "--browsers", "ie11", "--minify" });
    defer deinitRun(&legacy);

    try expectUnsafeTransformsDisabled(modern);
    try expectUnsafeTransformsDisabled(legacy);
}

test "legacy quarantine: input and output identity overwrites the source (CLI-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = @embedFile("fixtures/simple.css");
    try tmp.dir.writeFile(.{ .sub_path = "identity.css", .data = original });

    var result = try runInDir(tmp.dir, &.{ "identity.css", "-o", "identity.css", "--minify" });
    defer deinitRun(&result);
    try expectSuccess(result);

    const overwritten = try tmp.dir.readFileAlloc(allocator, "identity.css", 1024);
    defer allocator.free(overwritten);
    try std.testing.expect(!std.mem.eql(u8, original, overwritten));
    try std.testing.expectEqualStrings(".simple{color:red}", overwritten);
}

test "legacy quarantine: batch basename collisions silently overwrite (CLI-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("one");
    try tmp.dir.makePath("two");
    try tmp.dir.makePath("out");
    try tmp.dir.writeFile(.{ .sub_path = "one/shared.css", .data = ".one { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "two/shared.css", .data = ".two { color: blue; }" });

    var result = try runInDir(tmp.dir, &.{ "one/shared.css", "two/shared.css", "-o", "out", "--output-dir", "--minify" });
    defer deinitRun(&result);
    try expectSuccess(result);

    const output = try tmp.dir.readFileAlloc(allocator, "out/shared.css", 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(".two{color:blue}", output);
}

test "legacy quarantine: unknown flags and missing values are silently accepted (CLI-002)" {
    const input = @embedFile("fixtures/simple.css");
    var unknown = try runCompiler(input, &.{"--definitely-unknown"});
    defer deinitRun(&unknown);
    var missing = try runCompiler(input, &.{"-o"});
    defer deinitRun(&missing);

    try expectSuccess(unknown);
    try expectSuccess(missing);
    try std.testing.expectEqualStrings(unknown.stdout, missing.stdout);
}
