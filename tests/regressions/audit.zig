const std = @import("std");
const builtin = @import("builtin");
const audit_options = @import("audit_options");
const zigcss = @import("zigcss");

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

fn runWithStdinInDir(
    cwd_dir: ?std.fs.Dir,
    argv_tail: []const []const u8,
    input: []const u8,
) !Child.RunResult {
    const argv = try allocator.alloc([]const u8, argv_tail.len + 1);
    defer allocator.free(argv);
    argv[0] = audit_options.compiler_path;
    @memcpy(argv[1..], argv_tail);

    var child = Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd_dir = cwd_dir;
    try child.spawn();
    errdefer _ = child.kill() catch {};

    try child.stdin.?.writeAll(input);
    child.stdin.?.close();
    child.stdin = null;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    return .{
        .term = term,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

fn runWithStdin(argv_tail: []const []const u8, input: []const u8) !Child.RunResult {
    return runWithStdinInDir(null, argv_tail, input);
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

fn expectExitCode(result: Child.RunResult, expected: u8) !void {
    switch (result.term) {
        .Exited => |actual| try std.testing.expectEqual(expected, actual),
        else => try std.testing.expect(false),
    }
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

const OutputStamp = struct {
    inode: std.fs.File.INode,
    mtime: i128,
    ctime: i128,

    fn eql(left: OutputStamp, right: OutputStamp) bool {
        return left.inode == right.inode and left.mtime == right.mtime and left.ctime == right.ctime;
    }
};

fn waitForOutputStamp(
    dir: std.fs.Dir,
    path: []const u8,
    previous: ?OutputStamp,
) !OutputStamp {
    for (0..100) |_| {
        const stat = dir.statFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        const current = OutputStamp{
            .inode = stat.inode,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
        };
        if (previous == null or !previous.?.eql(current)) return current;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return error.WatchTimeout;
}

fn replaceFileAtomically(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var atomic_file = try dir.atomicFile(path, .{ .write_buffer = &buffer });
    defer atomic_file.deinit();
    try atomic_file.file_writer.interface.writeAll(bytes);
    try atomic_file.finish();
}

fn expectNonVerifiedTransformsDisabled(result: Child.RunResult) !void {
    try std.testing.expect(!succeeded(result.term));
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "legacy and non-verified transform paths are disabled") != null);
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

test "CLI output is the public compile result in every stable transform mode (CLI-010)" {
    const input = ".empty{}.a{width:calc(1px + 2px);color:#ffffff}";
    const cases = [_]struct {
        args: []const []const u8,
        options: zigcss.CompileOptions,
    }{
        .{ .args = &.{}, .options = .{} },
        .{
            .args = &.{"--minify"},
            .options = .{ .format = .minified },
        },
        .{
            .args = &.{ "--optimize", "--minify" },
            .options = .{
                .format = .minified,
                .transforms = .{ .optimize = true },
            },
        },
    };

    for (cases) |case| {
        var expected = try zigcss.compile(allocator, "input.css", input, case.options);
        defer expected.deinit();
        try std.testing.expectEqual(@as(usize, 0), expected.diagnostics.len);

        var actual = try runCompiler(input, case.args);
        defer deinitRun(&actual);
        try expectSuccess(actual);
        try std.testing.expectEqualStrings(expected.css, actual.stdout);
    }
}

test "stable CLI reports structured parser diagnostics without partial CSS" {
    var result = try runCompilerNamed("broken.css", ".a{broken;color:red}", &.{"--minify"});
    defer deinitRun(&result);

    try expectFailureContaining(result, "broken.css:1:4: error CSS0007");
    try expectExitCode(result, 1);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "stable batch CLI compiles each input through the safe pipeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "one.css", .data = ".a.b { color: #ffffff; }" });
    try tmp.dir.writeFile(.{ .sub_path = "two.css", .data = ".card { > .icon { opacity: 1; } }" });

    var result = try runInDir(tmp.dir, &.{ "one.css", "two.css", "-o", "out", "--output-dir", "--optimize", "--minify" });
    defer deinitRun(&result);
    try expectSuccess(result);

    const first = try tmp.dir.readFileAlloc(allocator, "out/one.css", 1024);
    defer allocator.free(first);
    const second = try tmp.dir.readFileAlloc(allocator, "out/two.css", 1024);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(".a.b{color:#fff}", first);
    try std.testing.expectEqualStrings(".card{>.icon{opacity:1}}", second);
}

test "stable batch CLI writes no outputs when one input has parser errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "valid.css", .data = ".valid { color: green; }" });
    try tmp.dir.writeFile(.{ .sub_path = "broken.css", .data = ".broken { missing; color: red; }" });

    var result = try runInDir(tmp.dir, &.{ "valid.css", "broken.css", "-o", "out", "--output-dir", "--optimize", "--minify" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "broken.css:1:11: error CSS0007");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out/valid.css", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out/broken.css", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out", .{}));
}

test "parallel batch commits outputs and status lines in argument order (PARALLEL-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{
        "seven.css",
        "two.css",
        "nine.css",
        "zero.css",
        "five.css",
        "one.css",
        "eight.css",
        "three.css",
        "six.css",
        "four.css",
    };
    for (names, 0..) |name, index| {
        const css = try std.fmt.allocPrint(allocator, ".item-{d} {{ z-index: {d}; }}", .{ index, index });
        defer allocator.free(css);
        try tmp.dir.writeFile(.{ .sub_path = name, .data = css });
    }

    var argv: [names.len + 4][]const u8 = undefined;
    @memcpy(argv[0..names.len], names[0..]);
    argv[names.len] = "-o";
    argv[names.len + 1] = "out";
    argv[names.len + 2] = "--output-dir";
    argv[names.len + 3] = "--minify";
    var result = try runInDir(tmp.dir, &argv);
    defer deinitRun(&result);
    try expectSuccess(result);
    try std.testing.expectEqual(names.len, countOccurrences(result.stderr, "Compiled: "));

    var cursor: usize = 0;
    for (names, 0..) |name, index| {
        const output_path = try std.fs.path.join(allocator, &.{ "out", name });
        defer allocator.free(output_path);
        const line = try std.fmt.allocPrint(allocator, "Compiled: {s} -> {s}\n", .{ name, output_path });
        defer allocator.free(line);
        const position = std.mem.indexOfPos(u8, result.stderr, cursor, line) orelse return error.MissingOrderedCommit;
        cursor = position + line.len;

        const css = try tmp.dir.readFileAlloc(allocator, output_path, 1024);
        defer allocator.free(css);
        const expected = try std.fmt.allocPrint(allocator, ".item-{d}{{z-index:{d}}}", .{ index, index });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, css);
    }
}

test "parallel batch cancels queued reads after the first compile failure (PARALLEL-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "broken.css", .data = ".broken { missing; color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "late.css", .data = ".late { color: green; }" });

    var slow = try std.ArrayList(u8).initCapacity(allocator, 16 * 8192);
    defer slow.deinit(allocator);
    for (0..8192) |_| try slow.appendSlice(allocator, ".slow{color:red}");
    const slow_names = [_][]const u8{
        "slow-one.css",
        "slow-two.css",
        "slow-three.css",
        "slow-four.css",
        "slow-five.css",
        "slow-six.css",
        "slow-seven.css",
    };
    for (slow_names) |name| {
        try tmp.dir.writeFile(.{ .sub_path = name, .data = slow.items });
    }

    var result = try runInDir(tmp.dir, &.{
        "broken.css",
        "slow-one.css",
        "slow-two.css",
        "slow-three.css",
        "slow-four.css",
        "slow-five.css",
        "slow-six.css",
        "slow-seven.css",
        "missing.css",
        "late.css",
        "-o",
        "out",
        "--output-dir",
        "--minify",
    });
    defer deinitRun(&result);
    try expectFailureContaining(result, "broken.css:1:11: error CSS0007");
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing.css") == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out", .{}));
}

test "verified optimizer CLI reaches the reviewed byte-stable fixed point" {
    const input = ".empty{}.a{color:#ffffff}.b{color:#fff}" ++
        ".c{width:calc(0px);margin-top:calc(1px + 0px);" ++
        "margin-right:calc(1px + 0px);margin-bottom:calc(1px + 0px);" ++
        "margin-left:calc(1px + 0px)}" ++
        "@media all{.x{z:1}}@media all{.y{z:1}}";
    var minified = try runCompiler(input, &.{ "--optimize", "--minify" });
    defer deinitRun(&minified);

    try expectSuccess(minified);
    try std.testing.expectEqualStrings(
        ".a,.b{color:#fff}.c{width:0;margin:1px}@media all{.x,.y{z:1}}",
        minified.stdout,
    );

    var repeated = try runCompiler(minified.stdout, &.{ "--optimize", "--minify" });
    defer deinitRun(&repeated);
    try expectSuccess(repeated);
    try std.testing.expectEqualStrings(minified.stdout, repeated.stdout);
}

test "verified optimizer preserves importance and fallback order" {
    var result = try runCompiler(@embedFile("fixtures/important.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".a{color:red!important;color:blue;color:green!important}",
        result.stdout,
    );
}

test "verified optimizer removes empty rules without reordering survivors" {
    var result = try runCompiler(@embedFile("fixtures/empty-leading.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".first{color:red}.second{color:blue}",
        result.stdout,
    );
}

test "verified optimizer never merges across intervening rules" {
    var result = try runCompiler(@embedFile("fixtures/nonadjacent.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".keep{color:red}.keep-between{color:green}.keep{background:blue}" ++
            "@media screen{.a{color:red}}.media-between{color:green}" ++
            "@media screen{.b{color:blue}}",
        result.stdout,
    );
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

test "verified optimizer does not statically resolve custom properties" {
    var result = try runCompiler(@embedFile("fixtures/custom-logical-reset.css"), &.{ "--optimize", "--minify" });
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

test "stable CLI preserves logical properties across RTL and vertical modes (LOGICAL-001)" {
    var result = try runCompiler(@embedFile("fixtures/logical-directions.css"), &.{"--minify"});
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".rtl{direction:rtl;margin-inline-start:1px;inset-inline-end:2px;" ++
            "text-align:start}.vertical{writing-mode:vertical-rl;text-orientation:upright;" ++
            "margin-block-start:3px;padding-inline-end:4px;float:inline-end}",
        result.stdout,
    );
}

test "verified optimizer does not convert logical properties" {
    var result = try runCompiler(@embedFile("fixtures/logical-directions.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".rtl{direction:rtl;margin-inline-start:1px;inset-inline-end:2px;" ++
            "text-align:start}.vertical{writing-mode:vertical-rl;text-orientation:upright;" ++
            "margin-block-start:3px;padding-inline-end:4px;float:inline-end}",
        result.stdout,
    );
}

test "verified optimizer folds only dimensionally compatible math" {
    var result = try runCompiler(@embedFile("fixtures/math.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        ".a{width:7px;height:calc(1px + 2em)}",
        result.stdout,
    );
}

test "verified optimizer preserves unsupported selector rewrites without crashing" {
    var result = try runCompiler(@embedFile("fixtures/selector-crash.css"), &.{ "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("*>.a{color:red}", result.stdout);
}

test "profiling lifecycle: the public compile call ends once and succeeds (PROF-001)" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{ "--profile", "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(".simple{color:red}", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Performance Profile") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stderr, "compile"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, result.stderr, "parse"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, result.stderr, "codegen"));
}

test "CLI strictness: unavailable source maps are rejected explicitly (CLI-002)" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{ "--source-map", "--minify" });
    defer deinitRun(&result);

    try expectFailureContaining(result, "--source-map is unavailable");
    try expectExitCode(result, 2);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "CLI informational and failure modes have stable streams and exit codes (CLI-011)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var help = try runInDir(tmp.dir, &.{"--help"});
    defer deinitRun(&help);
    try expectExitCode(help, 0);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "Usage: zigcss") != null);
    try std.testing.expectEqual(@as(usize, 0), help.stderr.len);

    var version = try runInDir(tmp.dir, &.{"--version"});
    defer deinitRun(&version);
    try expectExitCode(version, 0);
    try std.testing.expectEqualStrings("zigcss 0.3.0\n", version.stdout);
    try std.testing.expectEqual(@as(usize, 0), version.stderr.len);

    var no_input = try runInDir(tmp.dir, &.{});
    defer deinitRun(&no_input);
    try expectExitCode(no_input, 2);
    try std.testing.expectEqual(@as(usize, 0), no_input.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, no_input.stderr, "no input") != null);

    var mixed_version = try runInDir(tmp.dir, &.{ "--version", "input.css" });
    defer deinitRun(&mixed_version);
    try expectExitCode(mixed_version, 2);
    try std.testing.expectEqual(@as(usize, 0), mixed_version.stdout.len);

    var missing_file = try runInDir(tmp.dir, &.{"missing.css"});
    defer deinitRun(&missing_file);
    try expectExitCode(missing_file, 1);
    try std.testing.expect(std.mem.indexOf(u8, missing_file.stderr, "failed to read missing.css") != null);

    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".a{x:1}" });
    try tmp.dir.makeDir("blocked-output");
    var write_failure = try runInDir(tmp.dir, &.{ "input.css", "-o", "blocked-output" });
    defer deinitRun(&write_failure);
    try expectExitCode(write_failure, 1);
    try std.testing.expect(std.mem.indexOf(u8, write_failure.stderr, "failed to write blocked-output") != null);
}

test "CLI syntax selection is explicit bounded and non-repeatable (CLI-011)" {
    const input = @embedFile("fixtures/simple.css");
    var css = try runCompiler(input, &.{ "--syntax", "css", "--minify" });
    defer deinitRun(&css);
    try expectSuccess(css);
    try std.testing.expectEqualStrings(".simple{color:red}", css.stdout);

    var missing = try runCompiler(input, &.{"--syntax"});
    defer deinitRun(&missing);
    try expectExitCode(missing, 2);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "--syntax requires a value") != null);

    var unsupported = try runCompiler(input, &.{ "--syntax", "scss" });
    defer deinitRun(&unsupported);
    try expectExitCode(unsupported, 2);
    try std.testing.expect(std.mem.indexOf(u8, unsupported.stderr, "unsupported syntax: scss") != null);
    try std.testing.expectEqual(@as(usize, 0), unsupported.stdout.len);

    var duplicate = try runCompiler(input, &.{ "--syntax", "css", "--syntax", "css" });
    defer deinitRun(&duplicate);
    try expectExitCode(duplicate, 2);
    try std.testing.expect(std.mem.indexOf(u8, duplicate.stderr, "--syntax may only be specified once") != null);

    var duplicate_minify = try runCompiler(input, &.{ "--minify", "--minify" });
    defer deinitRun(&duplicate_minify);
    try expectExitCode(duplicate_minify, 2);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_minify.stderr, "--minify may only be specified once") != null);

    var duplicate_watch = try runCompiler(input, &.{ "--watch", "--watch" });
    defer deinitRun(&duplicate_watch);
    try expectExitCode(duplicate_watch, 2);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_watch.stderr, "--watch may only be specified once") != null);

    var duplicate_profile = try runCompiler(input, &.{ "--profile", "--profile" });
    defer deinitRun(&duplicate_profile);
    try expectExitCode(duplicate_profile, 2);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_profile.stderr, "--profile may only be specified once") != null);
}

test "CLI stdin and explicit stdout share the public compile contract (CLI-011)" {
    const input = ".stream { width: calc(1px + 2px); color: #ffffff; }";
    var stream = try runWithStdin(&.{ "-", "--syntax", "css", "--optimize", "--minify" }, input);
    defer deinitRun(&stream);
    try expectExitCode(stream, 0);
    try std.testing.expectEqualStrings(".stream{width:3px;color:#fff}", stream.stdout);
    try std.testing.expect(std.mem.indexOf(u8, stream.stderr, "experimental recovery build") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = input });
    var explicit_stdout = try runInDir(tmp.dir, &.{ "input.css", "-o", "-", "--minify" });
    defer deinitRun(&explicit_stdout);
    try expectExitCode(explicit_stdout, 0);
    try std.testing.expectEqualStrings(".stream{width:calc(1px + 2px);color:#ffffff}", explicit_stdout.stdout);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("-", .{}));

    var to_file = try runWithStdinInDir(tmp.dir, &.{ "-", "-o", "stream.css", "--minify" }, input);
    defer deinitRun(&to_file);
    try expectExitCode(to_file, 0);
    try std.testing.expectEqual(@as(usize, 0), to_file.stdout.len);
    const written = try tmp.dir.readFileAlloc(allocator, "stream.css", 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings(".stream{width:calc(1px + 2px);color:#ffffff}", written);
}

test "CLI stream diagnostics and incompatible modes fail without output (CLI-011)" {
    var broken = try runWithStdin(&.{ "-", "--minify" }, ".a{broken;color:red}");
    defer deinitRun(&broken);
    try expectExitCode(broken, 1);
    try std.testing.expectEqual(@as(usize, 0), broken.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, broken.stderr, "<stdin>:1:4: error CSS0007") != null);

    var mixed = try runWithStdin(&.{ "-", "input.css", "-o", "out", "--output-dir" }, ".a{x:1}");
    defer deinitRun(&mixed);
    try expectExitCode(mixed, 2);
    try std.testing.expectEqual(@as(usize, 0), mixed.stdout.len);

    var watched = try runWithStdin(&.{ "-", "--watch" }, ".a{x:1}");
    defer deinitRun(&watched);
    try expectExitCode(watched, 2);
    try std.testing.expectEqual(@as(usize, 0), watched.stdout.len);

    var duplicate_stdin = try runWithStdin(&.{ "-", "-", "-o", "out", "--output-dir" }, ".a{x:1}");
    defer deinitRun(&duplicate_stdin);
    try expectExitCode(duplicate_stdin, 2);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_stdin.stderr, "stdin may only be specified once") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "one.css", .data = ".one{x:1}" });
    try tmp.dir.writeFile(.{ .sub_path = "two.css", .data = ".two{x:2}" });
    var batch_stdout = try runInDir(tmp.dir, &.{ "one.css", "two.css", "-o", "-", "--output-dir" });
    defer deinitRun(&batch_stdout);
    try expectExitCode(batch_stdout, 2);
    try std.testing.expect(std.mem.indexOf(u8, batch_stdout.stderr, "--output-dir cannot write to stdout") != null);
    try std.testing.expectEqual(@as(usize, 0), batch_stdout.stdout.len);

    var batch_profile = try runInDir(tmp.dir, &.{ "one.css", "two.css", "-o", "out", "--output-dir", "--profile" });
    defer deinitRun(&batch_profile);
    try expectExitCode(batch_profile, 2);
    try std.testing.expect(std.mem.indexOf(u8, batch_profile.stderr, "--profile supports exactly one input") != null);
}

test "CLI watch recompiles once when a local imported dependency changes (WATCH-001)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "input.css",
        .data = "@import \"dependency.css?version=1\";.watched { color: red; }",
    });
    try tmp.dir.writeFile(.{ .sub_path = "dependency.css", .data = ".one{}" });

    const argv = [_][]const u8{
        audit_options.compiler_path,
        "input.css",
        "-o",
        "output.css",
        "--watch",
        "--minify",
    };
    var child = Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd_dir = tmp.dir;
    try child.spawn();
    var running = true;
    defer if (running) {
        _ = child.kill() catch {};
    };

    const initial = try waitForOutputStamp(tmp.dir, "output.css", null);
    std.Thread.sleep(250 * std.time.ns_per_ms);
    try replaceFileAtomically(tmp.dir, "dependency.css", ".two{}");
    const recompiled = try waitForOutputStamp(tmp.dir, "output.css", initial);
    std.Thread.sleep(1200 * std.time.ns_per_ms);
    const stable_stat = try tmp.dir.statFile("output.css");
    const stable = OutputStamp{
        .inode = stable_stat.inode,
        .mtime = stable_stat.mtime,
        .ctime = stable_stat.ctime,
    };
    try std.testing.expect(recompiled.eql(stable));
    const output = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "@import \"dependency.css?version=1\";.watched{color:red}",
        output,
    );

    _ = try child.kill();
    running = false;
}

test "CLI watch reports unchanged invalid CSS once instead of looping (WATCH-001)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "invalid.css", .data = ".broken { color }" });

    const argv = [_][]const u8{
        audit_options.compiler_path,
        "invalid.css",
        "-o",
        "output.css",
        "--watch",
        "--minify",
    };
    var child = Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.cwd_dir = tmp.dir;
    try child.spawn();
    var running = true;
    defer if (running) {
        _ = child.kill() catch {};
    };

    const captured_handle = try std.posix.dup(child.stderr.?.handle);
    var captured = std.fs.File{ .handle = captured_handle };
    defer captured.close();
    std.Thread.sleep(1600 * std.time.ns_per_ms);
    try replaceFileAtomically(tmp.dir, "invalid.css", ".fixed { color: red; }");
    _ = try waitForOutputStamp(tmp.dir, "output.css", null);
    _ = try child.kill();
    running = false;

    const stderr = try captured.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(stderr, "error CSS0007"));
    try std.testing.expect(std.mem.indexOf(u8, stderr, "Compilation error:") == null);
    const output = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(".fixed{color:red}", output);
}

test "target prefix CLI remains separate from the verified optimizer preset" {
    const input = @embedFile("fixtures/prefix.css");
    var modern = try runCompiler(input, &.{ "--autoprefix", "--browsers", "chrome120", "--minify" });
    defer deinitRun(&modern);
    var legacy = try runCompiler(input, &.{ "--autoprefix", "--browsers", "ie11", "--minify" });
    defer deinitRun(&legacy);

    try expectNonVerifiedTransformsDisabled(modern);
    try expectNonVerifiedTransformsDisabled(legacy);
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

test "CLI batch naming disambiguates collisions independently of input order (CLI-012)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("one");
    try tmp.dir.makePath("two");
    try tmp.dir.writeFile(.{ .sub_path = "one/shared.css", .data = ".one { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "two/shared.css", .data = ".two { color: blue; }" });

    var forward = try runInDir(tmp.dir, &.{ "one/shared.css", "two/shared.css", "-o", "forward", "--output-dir", "--minify" });
    defer deinitRun(&forward);
    try expectSuccess(forward);
    var reverse = try runInDir(tmp.dir, &.{ "two/shared.css", "one/shared.css", "-o", "reverse", "--output-dir", "--minify" });
    defer deinitRun(&reverse);
    try expectSuccess(reverse);

    var forward_dir = try tmp.dir.openDir("forward", .{ .iterate = true });
    defer forward_dir.close();
    var reverse_dir = try tmp.dir.openDir("reverse", .{});
    defer reverse_dir.close();
    var iterator = forward_dir.iterate();
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        try std.testing.expect(entry.kind == .file);
        try std.testing.expect(std.mem.startsWith(u8, entry.name, "shared-"));
        try std.testing.expect(std.mem.endsWith(u8, entry.name, ".css"));
        const forward_css = try forward_dir.readFileAlloc(allocator, entry.name, 1024);
        defer allocator.free(forward_css);
        const reverse_css = try reverse_dir.readFileAlloc(allocator, entry.name, 1024);
        defer allocator.free(reverse_css);
        try std.testing.expectEqualStrings(forward_css, reverse_css);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectError(error.FileNotFound, forward_dir.access("shared.css", .{}));
    try std.testing.expectError(error.FileNotFound, reverse_dir.access("shared.css", .{}));
}

test "CLI atomic output creates parents and replaces one destination completely (CLI-012)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".fresh { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "existing.css", .data = "old-output" });
    if (builtin.os.tag != .windows) {
        const existing = try tmp.dir.openFile("existing.css", .{ .mode = .read_write });
        defer existing.close();
        try std.posix.fchmod(existing.handle, 0o600);
    }

    var nested = try runInDir(tmp.dir, &.{ "input.css", "-o", "new/deep/output.css", "--minify" });
    defer deinitRun(&nested);
    try expectSuccess(nested);
    const nested_css = try tmp.dir.readFileAlloc(allocator, "new/deep/output.css", 1024);
    defer allocator.free(nested_css);
    try std.testing.expectEqualStrings(".fresh{color:red}", nested_css);

    var replaced = try runInDir(tmp.dir, &.{ "input.css", "-o", "existing.css", "--minify" });
    defer deinitRun(&replaced);
    try expectSuccess(replaced);
    const replaced_css = try tmp.dir.readFileAlloc(allocator, "existing.css", 1024);
    defer allocator.free(replaced_css);
    try std.testing.expectEqualStrings(".fresh{color:red}", replaced_css);
    if (builtin.os.tag != .windows) {
        const replaced_stat = try tmp.dir.statFile("existing.css");
        try std.testing.expectEqual(@as(u32, 0o600), replaced_stat.mode & 0o777);
    }

    var output_dir = try tmp.dir.openDir("new/deep", .{ .iterate = true });
    defer output_dir.close();
    var iterator = output_dir.iterate();
    var entries: usize = 0;
    while (try iterator.next()) |entry| {
        try std.testing.expectEqualStrings("output.css", entry.name);
        entries += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

test "CLI atomic replacement never follows unrelated output links (CLI-012)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".fresh { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "symlink-target.txt", .data = "preserve-symlink-target" });
    try tmp.dir.symLink("symlink-target.txt", "symlink-output.css", .{});

    var symlink_result = try runInDir(tmp.dir, &.{ "input.css", "-o", "symlink-output.css", "--minify" });
    defer deinitRun(&symlink_result);
    try expectSuccess(symlink_result);
    const symlink_target = try tmp.dir.readFileAlloc(allocator, "symlink-target.txt", 1024);
    defer allocator.free(symlink_target);
    const symlink_output = try tmp.dir.readFileAlloc(allocator, "symlink-output.css", 1024);
    defer allocator.free(symlink_output);
    try std.testing.expectEqualStrings("preserve-symlink-target", symlink_target);
    try std.testing.expectEqualStrings(".fresh{color:red}", symlink_output);

    try tmp.dir.writeFile(.{ .sub_path = "hard-target.txt", .data = "preserve-hard-target" });
    try std.posix.linkat(tmp.dir.fd, "hard-target.txt", tmp.dir.fd, "hard-output.css", 0);
    var hard_result = try runInDir(tmp.dir, &.{ "input.css", "-o", "hard-output.css", "--minify" });
    defer deinitRun(&hard_result);
    try expectSuccess(hard_result);
    const hard_target = try tmp.dir.readFileAlloc(allocator, "hard-target.txt", 1024);
    defer allocator.free(hard_target);
    const hard_output = try tmp.dir.readFileAlloc(allocator, "hard-output.css", 1024);
    defer allocator.free(hard_output);
    try std.testing.expectEqualStrings("preserve-hard-target", hard_target);
    try std.testing.expectEqualStrings(".fresh{color:red}", hard_output);
}

test "CLI atomic failure preserves old bytes and removes temporary files (CLI-012)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".fresh { color: red; }" });
    try tmp.dir.makeDir("locked");
    var locked = try tmp.dir.openDir("locked", .{ .iterate = true });
    defer locked.close();
    try locked.writeFile(.{ .sub_path = "output.css", .data = "old-output" });
    try std.posix.fchmod(locked.fd, 0o555);
    defer std.posix.fchmod(locked.fd, 0o755) catch {};

    var result = try runInDir(tmp.dir, &.{ "input.css", "-o", "locked/output.css", "--minify" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "failed to write locked/output.css atomically");
    const preserved = try locked.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("old-output", preserved);

    var iterator = locked.iterate();
    var entries: usize = 0;
    while (try iterator.next()) |entry| {
        try std.testing.expectEqualStrings("output.css", entry.name);
        entries += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

test "CLI atomic rename failure removes its temporary file (CLI-012)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".fresh { color: red; }" });
    try tmp.dir.makeDir("destination.css");

    var result = try runInDir(tmp.dir, &.{ "input.css", "-o", "destination.css", "--minify" });
    defer deinitRun(&result);
    try expectFailureContaining(result, "failed to write destination.css atomically");

    var root = try tmp.dir.openDir(".", .{ .iterate = true });
    defer root.close();
    var iterator = root.iterate();
    var entries: usize = 0;
    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "input.css")) {
            try std.testing.expectEqual(std.fs.File.Kind.file, entry.kind);
        } else if (std.mem.eql(u8, entry.name, "destination.css")) {
            try std.testing.expectEqual(std.fs.File.Kind.directory, entry.kind);
        } else {
            return error.UnexpectedOutputEntry;
        }
        entries += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), entries);
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
    var duplicate_optimize = try runCompiler(input, &.{ "--optimize", "--optimize" });
    defer deinitRun(&duplicate_optimize);

    try expectFailureContaining(unknown, "unknown option: --definitely-unknown");
    try expectFailureContaining(missing, "-o requires a value");
    try expectFailureContaining(duplicate_optimize, "--optimize may only be specified once");
    try expectExitCode(unknown, 2);
    try expectExitCode(missing, 2);
    try expectExitCode(duplicate_optimize, 2);
    try std.testing.expectEqual(@as(usize, 0), unknown.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), missing.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), duplicate_optimize.stdout.len);
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
    try std.testing.expect(std.mem.indexOf(u8, critical.stderr, "library/test-driver only") != null);
    try std.testing.expectEqual(@as(usize, 0), critical.stdout.len);
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
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "EXPERIMENTAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "--optimize               Run the closed verified optimizer preset") != null);
    try std.testing.expectEqual(@as(usize, 0), help.stderr.len);

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
