const std = @import("std");
const cli_options = @import("cli_options");

const Child = std.process.Child;
const allocator = std.testing.allocator;

const RouteCase = struct {
    syntax: []const u8,
    filename: []const u8,
    input: []const u8,
    expected: []const u8,
};

const route_cases = [_]RouteCase{
    .{ .syntax = "scss", .filename = "input.scss", .input = ".a { color: red; }", .expected = ".a{color:red}" },
    .{ .syntax = "sass", .filename = "input.sass", .input = ".a\n  color: red\n", .expected = ".a{color:red}" },
    .{ .syntax = "less", .filename = "input.less", .input = ".a { color: red; }", .expected = ".a{color:red}" },
    .{ .syntax = "stylus", .filename = "input.styl", .input = ".a\n  color red\n", .expected = ".a{color:#f00}" },
};

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

fn runWithStdin(argv_tail: []const []const u8, input: []const u8) !Child.RunResult {
    const argv = try allocator.alloc([]const u8, argv_tail.len + 1);
    defer allocator.free(argv);
    argv[0] = cli_options.compiler_path;
    @memcpy(argv[1..], argv_tail);

    var child = Child.init(argv, allocator);
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

    const pending_modes = [_][]const u8{ "--watch", "--optimize", "--profile" };
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

    var stdin = try runWithStdin(&.{
        "-",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    }, input);
    defer deinitRun(&stdin);
    try expectExitCode(stdin, 2);
    try std.testing.expectEqual(@as(usize, 0), stdin.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, stdin.stderr, "requires exactly one file input") != null);
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
