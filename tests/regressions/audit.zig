const std = @import("std");
const builtin = @import("builtin");
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

fn runCompilerNamed(filename: []const u8, input: []const u8, extra_args: []const []const u8) !Child.RunResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = filename, .data = input });

    const argv_tail = try allocator.alloc([]const u8, extra_args.len + 1);
    defer allocator.free(argv_tail);
    argv_tail[0] = filename;
    @memcpy(argv_tail[1..], extra_args);
    return runInDir(tmp.dir, argv_tail);
}

fn runCompiler(input: []const u8, extra_args: []const []const u8) !Child.RunResult {
    return runCompilerNamed("input.css", input, extra_args);
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

test "stable CLI preserves compound selectors separately from descendants" {
    var compound = try runCompiler(@embedFile("fixtures/compound.css"), &.{"--minify"});
    defer deinitRun(&compound);
    var descendant = try runCompiler(@embedFile("fixtures/descendant.css"), &.{"--minify"});
    defer deinitRun(&descendant);

    try expectSuccess(compound);
    try expectSuccess(descendant);
    try std.testing.expectEqualStrings(".a.b{color:red}", compound.stdout);
    try std.testing.expectEqualStrings(".a .b{color:red}", descendant.stdout);
    try std.testing.expect(!std.mem.eql(u8, compound.stdout, descendant.stdout));
}

test "stable CLI emits functional and attribute selectors" {
    var result = try runCompiler(@embedFile("fixtures/functional-attribute.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".a:not(.b, .c)>[data-x=\"a;b}\" i]{color:red}",
        result.stdout,
    );
}

test "stable CLI keeps delimiters inside strings and functions nested" {
    var result = try runCompiler(@embedFile("fixtures/nested-delimiters.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".a{content:\";}\";background:url(\"a;}\");color:red}",
        result.stdout,
    );
}

test "stable CLI emits declaration-bearing at-rules" {
    var result = try runCompiler(@embedFile("fixtures/font-face.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        "@font-face{font-family:Demo;src:url(\"demo.woff2\")}",
        result.stdout,
    );
}

test "stable CLI emits percentage keyframes" {
    var result = try runCompiler(@embedFile("fixtures/keyframes.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("@keyframes fade{50%{opacity:.5}}", result.stdout);
}

test "stable CLI retains mandatory at-rule whitespace" {
    var result = try runCompiler(@embedFile("fixtures/media.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("@media screen{.a{color:red}}", result.stdout);
}

test "stable CLI preserves fallback and importance order" {
    var result = try runCompiler(@embedFile("fixtures/important.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".a{color:red!important;color:blue;color:green!important}",
        result.stdout,
    );
}

test "stable CLI parses and emits native CSS nesting" {
    const input = ".card{color:red;.title{font-weight:bold}@media all{display:grid;> .icon{opacity:1}}background:blue}";
    const expected = ".card{color:red;.title{font-weight:bold}@media all{display:grid;>.icon{opacity:1}}background:blue}";
    var result = try runCompiler(input, &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(expected, result.stdout);
}

test "stable CLI uses deterministic pretty emission by default" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".simple {\n" ++
            "  color: red;\n" ++
            "}\n",
        result.stdout,
    );
}

test "stable CLI reports structured parser diagnostics without partial CSS" {
    var result = try runCompilerNamed("broken.css", ".a{broken;color:red}", &.{"--minify"});
    defer deinitRun(&result);

    try expectFailureContaining(result, "broken.css:1:4: error CSS0007");
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "stable batch CLI compiles each input through the safe pipeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "one.css", .data = ".a.b { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "two.css", .data = ".card { > .icon { opacity: 1; } }" });

    var result = try runInDir(tmp.dir, &.{ "one.css", "two.css", "-o", "out", "--output-dir", "--minify" });
    defer deinitRun(&result);
    try expectSuccess(result);

    const first = try tmp.dir.readFileAlloc(allocator, "out/one.css", 1024);
    defer allocator.free(first);
    const second = try tmp.dir.readFileAlloc(allocator, "out/two.css", 1024);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(".a.b{color:red}", first);
    try std.testing.expectEqualStrings(".card{>.icon{opacity:1}}", second);
}

test "stable batch CLI writes no outputs when one input has parser errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "valid.css", .data = ".valid { color: green; }" });
    try tmp.dir.writeFile(.{ .sub_path = "broken.css", .data = ".broken { missing; color: red; }" });

    var result = try runInDir(tmp.dir, &.{ "valid.css", "broken.css", "-o", "out", "--output-dir", "--minify" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "broken.css:1:11: error CSS0007");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out/valid.css", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out/broken.css", .{}));
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

test "stable CLI preserves custom-property cascade without static substitution (CUSTOM-001)" {
    var result = try runCompiler(@embedFile("fixtures/custom-logical-reset.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ":root{--theme:red}.scope{--theme:blue;color:var(--theme)}" ++
            ".box{margin-inline-start:1px;writing-mode:vertical-rl;direction:rtl;" ++
            "background-color:red;background-image:url(\"x.png\");font-style:italic;" ++
            "font-size:16px;font-family:serif}",
        result.stdout,
    );
}

test "stable CLI exposes no custom-property static-resolution mode (CUSTOM-001)" {
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

test "CLI strictness: unavailable source maps are rejected explicitly (CLI-002)" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{ "--source-map", "--minify" });
    defer deinitRun(&result);

    try expectFailureContaining(result, "--source-map is unavailable");
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
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

test "CLI path safety: input and output identity is rejected without changing the source (CLI-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = @embedFile("fixtures/simple.css");
    try tmp.dir.writeFile(.{ .sub_path = "identity.css", .data = original });

    var result = try runInDir(tmp.dir, &.{ "identity.css", "-o", "./identity.css", "--minify" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "output path resolves to an input");

    const preserved = try tmp.dir.readFileAlloc(allocator, "identity.css", 1024);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(original, preserved);
}

test "CLI path safety: symlink and hard-link output aliases are rejected (CLI-001)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = @embedFile("fixtures/simple.css");
    try tmp.dir.writeFile(.{ .sub_path = "source.css", .data = original });
    try tmp.dir.symLink("source.css", "symlink.css", .{});
    try std.posix.linkat(tmp.dir.fd, "source.css", tmp.dir.fd, "hard-link.css", 0);

    var symlink_result = try runInDir(tmp.dir, &.{ "source.css", "-o", "symlink.css", "--minify" });
    defer deinitRun(&symlink_result);
    try expectFailureContaining(symlink_result, "output path resolves to an input");

    var hard_link_result = try runInDir(tmp.dir, &.{ "source.css", "-o", "hard-link.css", "--minify" });
    defer deinitRun(&hard_link_result);
    try expectFailureContaining(hard_link_result, "output path resolves to an input");

    const preserved = try tmp.dir.readFileAlloc(allocator, "source.css", 1024);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(original, preserved);
}

test "CLI path safety: batch basename collisions are rejected before writing (CLI-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("one");
    try tmp.dir.makePath("two");
    try tmp.dir.makePath("out");
    try tmp.dir.writeFile(.{ .sub_path = "one/shared.css", .data = ".one { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "two/shared.css", .data = ".two { color: blue; }" });

    var result = try runInDir(tmp.dir, &.{ "one/shared.css", "two/shared.css", "-o", "out", "--output-dir", "--minify" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "multiple inputs resolve to the same output");

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out/shared.css", .{}));
}

test "CLI path safety: default batch naming cannot overwrite CSS inputs (CLI-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = ".first { color: red; }";
    const second = ".second { color: blue; }";
    try tmp.dir.writeFile(.{ .sub_path = "first.css", .data = first });
    try tmp.dir.writeFile(.{ .sub_path = "second.css", .data = second });

    var result = try runInDir(tmp.dir, &.{ "first.css", "second.css", "--minify" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "multiple inputs require --output-dir");

    const preserved_first = try tmp.dir.readFileAlloc(allocator, "first.css", 1024);
    defer allocator.free(preserved_first);
    const preserved_second = try tmp.dir.readFileAlloc(allocator, "second.css", 1024);
    defer allocator.free(preserved_second);
    try std.testing.expectEqualStrings(first, preserved_first);
    try std.testing.expectEqualStrings(second, preserved_second);
}

test "CLI strictness: unknown flags and missing values are rejected (CLI-002)" {
    const input = @embedFile("fixtures/simple.css");
    var unknown = try runCompiler(input, &.{"--definitely-unknown"});
    defer deinitRun(&unknown);
    var missing = try runCompiler(input, &.{"-o"});
    defer deinitRun(&missing);

    try expectFailureContaining(unknown, "unknown option: --definitely-unknown");
    try expectFailureContaining(missing, "-o requires a value");
    try std.testing.expectEqual(@as(usize, 0), unknown.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), missing.stdout.len);
}

test "CLI strictness: valued options diagnose missing values before availability (CLI-002)" {
    const input = @embedFile("fixtures/simple.css");
    var browsers = try runCompiler(input, &.{"--browsers"});
    defer deinitRun(&browsers);
    var critical = try runCompiler(input, &.{"--critical-classes"});
    defer deinitRun(&critical);

    try expectFailureContaining(browsers, "--browsers requires a value");
    try expectFailureContaining(critical, "--critical-classes requires a value");
}

test "CLI strictness: unavailable target and extraction features are rejected (CLI-002)" {
    const input = @embedFile("fixtures/simple.css");
    var browsers = try runCompiler(input, &.{ "--browsers", "ie11" });
    defer deinitRun(&browsers);
    var critical = try runCompiler(input, &.{ "--critical-classes", "critical" });
    defer deinitRun(&critical);

    try expectFailureContaining(browsers, "--browsers is unavailable");
    try expectFailureContaining(critical, "--critical-classes is unavailable");
}

test "CLI strictness: output-dir is rejected outside explicit batch mode (CLI-002)" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{ "-o", "out", "--output-dir" });
    defer deinitRun(&result);

    try expectFailureContaining(result, "--output-dir requires multiple inputs");
}

test "recovery CLI identifies the current compiler as experimental (SAFE-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var help = try runInDir(tmp.dir, &.{"--help"});
    defer deinitRun(&help);
    try expectSuccess(help);
    try std.testing.expect(std.mem.indexOf(u8, help.stderr, "EXPERIMENTAL") != null);

    var compile = try runCompiler(@embedFile("fixtures/simple.css"), &.{"--minify"});
    defer deinitRun(&compile);
    try expectSuccess(compile);
    try std.testing.expect(std.mem.indexOf(u8, compile.stderr, "experimental recovery build") != null);
}

test "recovery CLI rejects experimental format adapters before writing (SAFE-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.scss", .data = "$color: red; .a { color: $color; }" });

    var result = try runInDir(tmp.dir, &.{ "input.scss", "-o", "output.css" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "SCSS format adapter is experimental and unavailable");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("output.css", .{}));
}
