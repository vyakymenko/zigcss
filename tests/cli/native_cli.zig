const std = @import("std");
const builtin = @import("builtin");
const cli_options = @import("cli_options");

const Child = std.process.Child;
const allocator = std.testing.allocator;

const RouteCase = struct {
    syntax: []const u8,
    filename: []const u8,
    input: []const u8,
    expected: []const u8,
    second_filename: []const u8,
    second_input: []const u8,
    second_expected: []const u8,
    watch_input: []const u8,
    watch_dependency: []const u8,
    watch_dependency_before: []const u8,
    watch_dependency_after: []const u8,
    watch_expected_before: []const u8,
    watch_expected_after: []const u8,
};

const route_cases = [_]RouteCase{
    .{
        .syntax = "scss",
        .filename = "input.scss",
        .input = ".a { color: red; }",
        .expected = ".a{color:red}",
        .second_filename = "second.scss",
        .second_input = ".b { color: red; }",
        .second_expected = ".b{color:red}",
        .watch_input = "@use \"tokens\"; .card { color: tokens.$color; }",
        .watch_dependency = "_tokens.scss",
        .watch_dependency_before = "$color: red;",
        .watch_dependency_after = "$color: blue;",
        .watch_expected_before = ".card{color:red}",
        .watch_expected_after = ".card{color:blue}",
    },
    .{
        .syntax = "sass",
        .filename = "input.sass",
        .input = ".a\n  color: red\n",
        .expected = ".a{color:red}",
        .second_filename = "second.sass",
        .second_input = ".b\n  color: red\n",
        .second_expected = ".b{color:red}",
        .watch_input = "@use \"tokens\"\n.card\n  color: tokens.$color\n",
        .watch_dependency = "_tokens.sass",
        .watch_dependency_before = "$color: red\n",
        .watch_dependency_after = "$color: blue\n",
        .watch_expected_before = ".card{color:red}",
        .watch_expected_after = ".card{color:blue}",
    },
    .{
        .syntax = "less",
        .filename = "input.less",
        .input = ".a { color: red; }",
        .expected = ".a{color:red}",
        .second_filename = "second.less",
        .second_input = ".b { color: red; }",
        .second_expected = ".b{color:red}",
        .watch_input = "@import \"tokens\"; .card { color: @color; }",
        .watch_dependency = "tokens.less",
        .watch_dependency_before = "@color: red;",
        .watch_dependency_after = "@color: blue;",
        .watch_expected_before = ".card{color:red}",
        .watch_expected_after = ".card{color:blue}",
    },
    .{
        .syntax = "stylus",
        .filename = "input.styl",
        .input = ".a\n  color red\n",
        .expected = ".a{color:#f00}",
        .second_filename = "second.styl",
        .second_input = ".b\n  color red\n",
        .second_expected = ".b{color:#f00}",
        .watch_input = "@import \"tokens\"\n.card\n  color color\n",
        .watch_dependency = "tokens.styl",
        .watch_dependency_before = "color = red\n",
        .watch_dependency_after = "color = blue\n",
        .watch_expected_before = ".card{color:#f00}",
        .watch_expected_after = ".card{color:#00f}",
    },
};

const OutputStamp = struct {
    inode: std.fs.File.INode,
    mtime: i128,
    ctime: i128,

    fn eql(left: OutputStamp, right: OutputStamp) bool {
        return left.inode == right.inode and left.mtime == right.mtime and left.ctime == right.ctime;
    }
};

fn outputStamp(dir: std.fs.Dir, path: []const u8) !OutputStamp {
    const stat = try dir.statFile(path);
    return .{ .inode = stat.inode, .mtime = stat.mtime, .ctime = stat.ctime };
}

fn waitForOutputContents(
    dir: std.fs.Dir,
    path: []const u8,
    expected: []const u8,
) !OutputStamp {
    for (0..100) |_| {
        const contents = dir.readFileAlloc(allocator, path, 1024) catch |err| switch (err) {
            error.FileNotFound => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer allocator.free(contents);
        if (std.mem.eql(u8, expected, contents)) return outputStamp(dir, path);
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

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

fn runInDir(dir: std.fs.Dir, argv_tail: []const []const u8) !Child.RunResult {
    const argv = try allocator.alloc([]const u8, argv_tail.len + 1);
    defer allocator.free(argv);
    argv[0] = cli_options.compiler_path;
    @memcpy(argv[1..], argv_tail);

    const cwd = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });
}

fn runCompilerNamed(
    filename: []const u8,
    input: []const u8,
    extra_args: []const []const u8,
) !Child.RunResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = filename, .data = input });

    const argv_tail = try allocator.alloc([]const u8, extra_args.len + 1);
    defer allocator.free(argv_tail);
    argv_tail[0] = filename;
    @memcpy(argv_tail[1..], extra_args);
    return runInDir(tmp.dir, argv_tail);
}

fn runWithStdinInDir(
    dir: ?std.fs.Dir,
    argv_tail: []const []const u8,
    input: []const u8,
) !Child.RunResult {
    const argv = try allocator.alloc([]const u8, argv_tail.len + 1);
    defer allocator.free(argv);
    argv[0] = cli_options.compiler_path;
    @memcpy(argv[1..], argv_tail);

    const cwd = if (dir) |value| try value.realpathAlloc(allocator, ".") else null;
    defer if (cwd) |path| allocator.free(path);

    var child = Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer _ = child.kill() catch {};

    child.stdin.?.writeAll(input) catch |err| switch (err) {
        error.BrokenPipe => {},
        else => return err,
    };
    child.stdin.?.close();
    child.stdin = null;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();
    const owned_stdout = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(owned_stdout);
    const owned_stderr = try stderr.toOwnedSlice(allocator);
    return .{
        .term = term,
        .stdout = owned_stdout,
        .stderr = owned_stderr,
    };
}

fn runWithStdin(argv_tail: []const []const u8, input: []const u8) !Child.RunResult {
    return runWithStdinInDir(null, argv_tail, input);
}

fn deinitRun(result: *Child.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn expectExitCode(result: Child.RunResult, expected: u8) !void {
    switch (result.term) {
        .Exited => |actual| try std.testing.expectEqual(expected, actual),
        else => try std.testing.expect(false),
    }
}

test "binary CLI routes the finite native syntax set through the pre-graduation bridge" {
    inline for (route_cases) |case| {
        var first = try runCompilerNamed(case.filename, case.input, &.{
            "--experimental-native",
            "--syntax",
            case.syntax,
            "--minify",
        });
        defer deinitRun(&first);
        var second = try runCompilerNamed(case.filename, case.input, &.{
            "--experimental-native",
            "--syntax",
            case.syntax,
            "--minify",
        });
        defer deinitRun(&second);

        try expectExitCode(first, 0);
        try expectExitCode(second, 0);
        try std.testing.expectEqualStrings(case.expected, first.stdout);
        try std.testing.expectEqualStrings(first.stdout, second.stdout);
        try std.testing.expect(std.mem.indexOf(u8, first.stderr, "experimental release candidate") != null);
    }
}

test "binary CLI keeps native routing explicit and pending execution modes fail closed" {
    const input = route_cases[0].input;
    var css = try runCompilerNamed("input.css", ".a { color: red; }", &.{ "--syntax", "css", "--minify" });
    defer deinitRun(&css);
    try expectExitCode(css, 0);
    try std.testing.expectEqualStrings(".a{color:red}", css.stdout);

    var extension_only = try runCompilerNamed("input.scss", input, &.{"--minify"});
    defer deinitRun(&extension_only);
    try expectExitCode(extension_only, 2);
    try std.testing.expectEqual(@as(usize, 0), extension_only.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, extension_only.stderr, "SCSS format adapter is experimental and unavailable") != null);

    var implicit = try runCompilerNamed("input.scss", input, &.{ "--syntax", "scss", "--minify" });
    defer deinitRun(&implicit);
    try expectExitCode(implicit, 2);
    try std.testing.expectEqual(@as(usize, 0), implicit.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, implicit.stderr, "unsupported syntax: scss") != null);

    var css_gate = try runCompilerNamed("input.css", ".a { color: red; }", &.{
        "--experimental-native",
        "--syntax",
        "css",
    });
    defer deinitRun(&css_gate);
    try expectExitCode(css_gate, 2);
    try std.testing.expectEqual(@as(usize, 0), css_gate.stdout.len);

    var unknown = try runCompilerNamed("input.scss", input, &.{
        "--experimental-native",
        "--syntax",
        "scss-next",
    });
    defer deinitRun(&unknown);
    try expectExitCode(unknown, 2);
    try std.testing.expectEqual(@as(usize, 0), unknown.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, unknown.stderr, "unsupported syntax: scss-next") != null);

    const pending_modes = [_][]const u8{ "--optimize", "--profile" };
    inline for (pending_modes) |mode| {
        var result = try runCompilerNamed("input.scss", input, &.{
            "--experimental-native",
            "--syntax",
            "scss",
            mode,
        });
        defer deinitRun(&result);
        try expectExitCode(result, 2);
        try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unavailable for the pre-graduation native CLI") != null);
    }
}

test "binary CLI native watch invalidates the finite syntax dependency set" {
    inline for (route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.watch_input });
        try tmp.dir.writeFile(.{
            .sub_path = case.watch_dependency,
            .data = case.watch_dependency_before,
        });

        const argv = [_][]const u8{
            cli_options.compiler_path,
            case.filename,
            "-o",
            "output.css",
            "--experimental-native",
            "--syntax",
            case.syntax,
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
        defer {
            if (running) _ = child.kill() catch {};
        }

        _ = try waitForOutputContents(tmp.dir, "output.css", case.watch_expected_before);
        try replaceFileAtomically(
            tmp.dir,
            case.watch_dependency,
            case.watch_dependency_after,
        );
        const changed = try waitForOutputContents(
            tmp.dir,
            "output.css",
            case.watch_expected_after,
        );
        std.Thread.sleep(1200 * std.time.ns_per_ms);
        try std.testing.expect(changed.eql(try outputStamp(tmp.dir, "output.css")));

        _ = try child.kill();
        running = false;
    }
}

test "binary CLI native watch failures retain output and recover once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const case = route_cases[0];
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.watch_input });
    try tmp.dir.writeFile(.{
        .sub_path = case.watch_dependency,
        .data = case.watch_dependency_before,
    });

    const argv = [_][]const u8{
        cli_options.compiler_path,
        case.filename,
        "-o",
        "output.css",
        "--experimental-native",
        "--syntax",
        case.syntax,
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
    defer {
        if (running) _ = child.kill() catch {};
    }

    const captured_handle = try std.posix.dup(child.stderr.?.handle);
    var captured = std.fs.File{ .handle = captured_handle };
    defer captured.close();

    _ = try waitForOutputContents(tmp.dir, "output.css", case.watch_expected_before);
    try tmp.dir.deleteFile(case.watch_dependency);
    std.Thread.sleep(1300 * std.time.ns_per_ms);
    const retained = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(retained);
    try std.testing.expectEqualStrings(case.watch_expected_before, retained);

    try replaceFileAtomically(
        tmp.dir,
        case.watch_dependency,
        case.watch_dependency_after,
    );
    _ = try waitForOutputContents(tmp.dir, "output.css", case.watch_expected_after);
    _ = try child.kill();
    running = false;

    const stderr = try captured.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(stderr, "native SCSS compilation failed"),
    );
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(stderr, "Compiled:"));
}

test "binary CLI native watch rejects entry link substitution and recovers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const case = route_cases[0];
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    var root = try tmp.dir.openDir("root", .{});
    defer root.close();
    try root.writeFile(.{ .sub_path = case.filename, .data = case.watch_input });
    try root.writeFile(.{
        .sub_path = case.watch_dependency,
        .data = case.watch_dependency_before,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "escaped.scss",
        .data = ".card { color: blue; }",
    });

    const argv = [_][]const u8{
        cli_options.compiler_path,
        "root/input.scss",
        "-o",
        "root/output.css",
        "--experimental-native",
        "--syntax",
        case.syntax,
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
    defer {
        if (running) _ = child.kill() catch {};
    }

    const captured_handle = try std.posix.dup(child.stderr.?.handle);
    var captured = std.fs.File{ .handle = captured_handle };
    defer captured.close();

    _ = try waitForOutputContents(root, "output.css", case.watch_expected_before);
    try root.deleteFile(case.filename);
    try root.symLink("../escaped.scss", case.filename, .{});
    std.Thread.sleep(1300 * std.time.ns_per_ms);
    const retained = try root.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(retained);
    try std.testing.expectEqualStrings(case.watch_expected_before, retained);

    try replaceFileAtomically(
        root,
        case.filename,
        ".card { color: green; }",
    );
    _ = try waitForOutputContents(root, "output.css", ".card{color:green}");
    _ = try child.kill();
    running = false;

    const stderr = try captured.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(stderr, "failed to read root/input.scss"),
    );
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(stderr, "Compiled:"));
}

test "binary CLI routes the finite native syntax set from stdin" {
    inline for (route_cases) |case| {
        const argv = &.{
            "-",
            "--experimental-native",
            "--syntax",
            case.syntax,
            "--minify",
        };
        var first = try runWithStdin(argv, case.input);
        defer deinitRun(&first);
        var second = try runWithStdin(argv, case.input);
        defer deinitRun(&second);

        try expectExitCode(first, 0);
        try expectExitCode(second, 0);
        try std.testing.expectEqualStrings(case.expected, first.stdout);
        try std.testing.expectEqualStrings(first.stdout, second.stdout);
        try std.testing.expect(std.mem.indexOf(u8, first.stderr, "experimental release candidate") != null);
    }
}

test "binary CLI native stdin confines imports and commits no partial output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    try tmp.dir.writeFile(.{ .sub_path = "outside.scss", .data = "$color: blue;" });
    var root = try tmp.dir.openDir("root", .{});
    defer root.close();
    try root.writeFile(.{ .sub_path = "_tokens.scss", .data = "$color: red;" });

    var confined = try runWithStdinInDir(root, &.{
        "-",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    }, "@use \"tokens\"; .card { color: tokens.$color; }");
    defer deinitRun(&confined);
    try expectExitCode(confined, 0);
    try std.testing.expectEqualStrings(".card{color:red}", confined.stdout);

    try root.writeFile(.{ .sub_path = "output.css", .data = "sentinel" });
    var escaped = try runWithStdinInDir(root, &.{
        "-",
        "-o",
        "output.css",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    }, "@use \"../outside\"; .card { color: outside.$color; }");
    defer deinitRun(&escaped);
    try expectExitCode(escaped, 1);
    try std.testing.expectEqual(@as(usize, 0), escaped.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, escaped.stderr, "native SCSS compilation failed") != null);

    const output = try root.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("sentinel", output);
}

test "binary CLI native stdin enforces the exact input byte terminal" {
    const max_native_input_bytes = 10 * 1024 * 1024;
    const terminal = try allocator.alloc(u8, max_native_input_bytes);
    defer allocator.free(terminal);
    @memset(terminal, 'x');
    terminal[0] = '/';
    terminal[1] = '*';
    terminal[terminal.len - 2] = '*';
    terminal[terminal.len - 1] = '/';

    var admitted = try runWithStdin(&.{
        "-",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    }, terminal);
    defer deinitRun(&admitted);
    try expectExitCode(admitted, 0);
    try std.testing.expectEqual(@as(usize, 0), admitted.stdout.len);

    const over_limit = try allocator.alloc(u8, max_native_input_bytes + 1);
    defer allocator.free(over_limit);
    @memcpy(over_limit[0..terminal.len], terminal);
    over_limit[over_limit.len - 1] = 'x';
    var rejected = try runWithStdin(&.{
        "-",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    }, over_limit);
    defer deinitRun(&rejected);
    try expectExitCode(rejected, 1);
    try std.testing.expectEqual(@as(usize, 0), rejected.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, rejected.stderr, "failed to read <stdin>: FileTooBig") != null);
}

test "binary CLI routes the finite native syntax set through deterministic batches" {
    inline for (route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.input });
        try tmp.dir.writeFile(.{ .sub_path = case.second_filename, .data = case.second_input });

        const argv = &.{
            case.filename,
            case.second_filename,
            "-o",
            "out",
            "--output-dir",
            "--experimental-native",
            "--syntax",
            case.syntax,
            "--minify",
        };
        var first = try runInDir(tmp.dir, argv);
        defer deinitRun(&first);
        var second = try runInDir(tmp.dir, argv);
        defer deinitRun(&second);

        try expectExitCode(first, 0);
        try expectExitCode(second, 0);
        try std.testing.expectEqual(@as(usize, 0), first.stdout.len);
        try std.testing.expectEqualStrings(first.stdout, second.stdout);
        try std.testing.expectEqualStrings(first.stderr, second.stderr);

        const first_output_path = try std.fmt.allocPrint(
            allocator,
            "out/{s}.css",
            .{std.fs.path.stem(case.filename)},
        );
        defer allocator.free(first_output_path);
        const second_output_path = try std.fmt.allocPrint(
            allocator,
            "out/{s}.css",
            .{std.fs.path.stem(case.second_filename)},
        );
        defer allocator.free(second_output_path);
        const first_output = try tmp.dir.readFileAlloc(allocator, first_output_path, 1024);
        defer allocator.free(first_output);
        const second_output = try tmp.dir.readFileAlloc(allocator, second_output_path, 1024);
        defer allocator.free(second_output);
        try std.testing.expectEqualStrings(case.expected, first_output);
        try std.testing.expectEqualStrings(case.second_expected, second_output);

        const first_status = std.mem.indexOf(u8, first.stderr, "Compiled: " ++ case.filename) orelse
            return error.MissingFirstBatchStatus;
        const second_status = std.mem.indexOf(u8, first.stderr, "Compiled: " ++ case.second_filename) orelse
            return error.MissingSecondBatchStatus;
        try std.testing.expect(first_status < second_status);
    }
}

test "binary CLI native batch failures commit no partial output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "good.scss", .data = ".good { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "bad.scss", .data = ".bad { color: $missing; }" });
    try tmp.dir.makeDir("out");
    try tmp.dir.writeFile(.{ .sub_path = "out/good.css", .data = "good-sentinel" });
    try tmp.dir.writeFile(.{ .sub_path = "out/bad.css", .data = "bad-sentinel" });

    var result = try runInDir(tmp.dir, &.{
        "good.scss",
        "bad.scss",
        "-o",
        "out",
        "--output-dir",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    });
    defer deinitRun(&result);
    try expectExitCode(result, 1);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "native SCSS compilation failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Compiled:") == null);

    const good_output = try tmp.dir.readFileAlloc(allocator, "out/good.css", 1024);
    defer allocator.free(good_output);
    const bad_output = try tmp.dir.readFileAlloc(allocator, "out/bad.css", 1024);
    defer allocator.free(bad_output);
    try std.testing.expectEqualStrings("good-sentinel", good_output);
    try std.testing.expectEqualStrings("bad-sentinel", bad_output);
}

test "binary CLI native failures commit no partial output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.scss", .data = ".a { color: $missing; }" });
    try tmp.dir.writeFile(.{ .sub_path = "output.css", .data = "sentinel" });

    var result = try runInDir(tmp.dir, &.{
        "input.scss",
        "-o",
        "output.css",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    });
    defer deinitRun(&result);
    try expectExitCode(result, 1);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "native SCSS compilation failed") != null);

    const output = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("sentinel", output);
}
