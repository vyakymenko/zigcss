const std = @import("std");
const builtin = @import("builtin");
const cli_options = @import("cli_options");

const Child = std.process.Child;
const allocator = std.testing.allocator;
const native_parallel_worker_cap = 8;
const native_parallel_queued_case_count = native_parallel_worker_cap + 1;
const watch_atomic_attempt_limit: usize = 100;
const watch_poll_delay_ns: u64 = 50 * std.time.ns_per_ms;
const watch_atomic_rename_retry_delay_ns: u64 = 10 * std.time.ns_per_ms;

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

const WatchAtomicOperation = enum {
    observe,
    rename,
};

const WatchAtomicDisposition = enum {
    retry,
    exhausted,
    fail,
};

fn watchAtomicDisposition(
    operation: WatchAtomicOperation,
    os_tag: std.Target.Os.Tag,
    err: anyerror,
    attempt: usize,
) WatchAtomicDisposition {
    // Zig's AtomicFile.renameIntoPlace contract documents a Windows-only
    // AccessDenied window while the destination is being replaced.
    const transient = switch (operation) {
        .observe => err == error.FileNotFound or
            (os_tag == .windows and err == error.AccessDenied),
        .rename => os_tag == .windows and err == error.AccessDenied,
    };
    if (!transient) return .fail;
    return if (attempt < watch_atomic_attempt_limit - 1) .retry else .exhausted;
}

fn handleWatchAtomicFailure(
    operation: WatchAtomicOperation,
    os_tag: std.Target.Os.Tag,
    err: anyerror,
    attempt: usize,
    retry_delay_ns: u64,
) !void {
    switch (watchAtomicDisposition(operation, os_tag, err, attempt)) {
        .retry => if (retry_delay_ns > 0) std.Thread.sleep(retry_delay_ns),
        .exhausted => switch (operation) {
            .observe => return error.WatchTimeout,
            .rename => return err,
        },
        .fail => return err,
    }
}

test "watch atomic retries retain lower terminal and over-limit boundaries" {
    const cases = [_]struct {
        operation: WatchAtomicOperation,
        os_tag: std.Target.Os.Tag,
        err: anyerror,
        attempt: usize,
        expected: WatchAtomicDisposition,
    }{
        .{ .operation = .observe, .os_tag = .linux, .err = error.FileNotFound, .attempt = 0, .expected = .retry },
        .{ .operation = .observe, .os_tag = .windows, .err = error.AccessDenied, .attempt = 0, .expected = .retry },
        .{ .operation = .rename, .os_tag = .windows, .err = error.AccessDenied, .attempt = watch_atomic_attempt_limit - 2, .expected = .retry },
        .{ .operation = .rename, .os_tag = .windows, .err = error.AccessDenied, .attempt = watch_atomic_attempt_limit - 1, .expected = .exhausted },
        .{ .operation = .rename, .os_tag = .windows, .err = error.AccessDenied, .attempt = watch_atomic_attempt_limit, .expected = .exhausted },
        .{ .operation = .rename, .os_tag = .windows, .err = error.FileNotFound, .attempt = 0, .expected = .fail },
        .{ .operation = .rename, .os_tag = .linux, .err = error.AccessDenied, .attempt = 0, .expected = .fail },
        .{ .operation = .observe, .os_tag = .windows, .err = error.OutOfMemory, .attempt = 0, .expected = .fail },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            watchAtomicDisposition(
                case.operation,
                case.os_tag,
                case.err,
                case.attempt,
            ),
        );
    }
    try handleWatchAtomicFailure(
        .observe,
        .windows,
        error.AccessDenied,
        watch_atomic_attempt_limit - 2,
        0,
    );
    try std.testing.expectError(
        error.WatchTimeout,
        handleWatchAtomicFailure(
            .observe,
            .windows,
            error.AccessDenied,
            watch_atomic_attempt_limit - 1,
            0,
        ),
    );
    try std.testing.expectError(
        error.AccessDenied,
        handleWatchAtomicFailure(
            .rename,
            .windows,
            error.AccessDenied,
            watch_atomic_attempt_limit - 1,
            0,
        ),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        handleWatchAtomicFailure(.observe, .windows, error.OutOfMemory, 0, 0),
    );
}

fn waitForOutputContents(
    dir: std.fs.Dir,
    path: []const u8,
    expected: []const u8,
) !OutputStamp {
    poll: for (0..watch_atomic_attempt_limit) |attempt| {
        const contents = dir.readFileAlloc(allocator, path, 1024) catch |err| {
            try handleWatchAtomicFailure(.observe, builtin.os.tag, err, attempt, watch_poll_delay_ns);
            continue :poll;
        };
        defer allocator.free(contents);
        if (std.mem.eql(u8, expected, contents)) {
            const stamp = outputStamp(dir, path) catch |err| {
                try handleWatchAtomicFailure(.observe, builtin.os.tag, err, attempt, watch_poll_delay_ns);
                continue :poll;
            };
            return stamp;
        }
        std.Thread.sleep(watch_poll_delay_ns);
    }
    return error.WatchTimeout;
}

fn replaceFileAtomically(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var atomic_file = try dir.atomicFile(path, .{ .write_buffer = &buffer });
    defer atomic_file.deinit();
    try atomic_file.file_writer.interface.writeAll(bytes);
    try atomic_file.flush();
    for (0..watch_atomic_attempt_limit) |attempt| {
        atomic_file.renameIntoPlace() catch |err| {
            try handleWatchAtomicFailure(.rename, builtin.os.tag, err, attempt, watch_atomic_rename_retry_delay_ns);
            continue;
        };
        return;
    }
    unreachable;
}

fn waitForOutputStamp(dir: std.fs.Dir, path: []const u8) !OutputStamp {
    for (0..watch_atomic_attempt_limit) |attempt| {
        return outputStamp(dir, path) catch |err| {
            try handleWatchAtomicFailure(.observe, builtin.os.tag, err, attempt, watch_poll_delay_ns);
            continue;
        };
    }
    unreachable;
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

const inline_source_map_prefix =
    "/*# sourceMappingURL=data:application/json;charset=utf-8;base64,";

fn decodeInlineSourceMap(output: []const u8, expected_css: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, output, expected_css)) return error.InvalidSourceMap;
    const marker = std.mem.indexOf(u8, output, inline_source_map_prefix) orelse
        return error.MissingSourceMap;
    if (marker != expected_css.len + 1 or output[expected_css.len] != '\n' or
        !std.mem.endsWith(u8, output, " */"))
    {
        return error.InvalidSourceMap;
    }
    const encoded_start = marker + inline_source_map_prefix.len;
    const encoded_end = output.len - " */".len;
    const encoded = output[encoded_start..encoded_end];
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn expectInlineSourceMap(
    output: []const u8,
    expected_css: []const u8,
    source_suffix: []const u8,
    source_content: []const u8,
) !void {
    const source_map = try decodeInlineSourceMap(output, expected_css);
    defer allocator.free(source_map);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source_map,
        "zigcss-native:///intermediate.css",
    ) == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source_map, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 3), object.get("version").?.integer);
    const sources = object.get("sources").?.array.items;
    const contents = object.get("sourcesContent").?.array.items;
    try std.testing.expectEqual(sources.len, contents.len);
    try std.testing.expect(sources.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, sources[0].string, source_suffix));
    try std.testing.expectEqualStrings(source_content, contents[0].string);
    try std.testing.expect(object.get("mappings").?.string.len > 0);
}

fn waitForMappedOutputContents(
    dir: std.fs.Dir,
    path: []const u8,
    expected_css: []const u8,
    expected_dependency_content: []const u8,
) !OutputStamp {
    poll: for (0..watch_atomic_attempt_limit) |attempt| {
        const contents = dir.readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            try handleWatchAtomicFailure(.observe, builtin.os.tag, err, attempt, watch_poll_delay_ns);
            continue :poll;
        };
        defer allocator.free(contents);
        if (!std.mem.startsWith(u8, contents, expected_css)) {
            std.Thread.sleep(watch_poll_delay_ns);
            continue :poll;
        }
        const source_map = try decodeInlineSourceMap(contents, expected_css);
        defer allocator.free(source_map);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source_map, .{});
        defer parsed.deinit();
        const source_contents = parsed.value.object.get("sourcesContent").?.array.items;
        for (source_contents) |item| {
            if (std.mem.eql(u8, item.string, expected_dependency_content)) {
                const stamp = outputStamp(dir, path) catch |err| {
                    try handleWatchAtomicFailure(.observe, builtin.os.tag, err, attempt, watch_poll_delay_ns);
                    continue :poll;
                };
                return stamp;
            }
        }
        std.Thread.sleep(watch_poll_delay_ns);
    }
    return error.WatchTimeout;
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

test "binary CLI routes composed native source maps through files stdin and parallel batches" {
    inline for (route_cases) |case| {
        var file_result = try runCompilerNamed(case.filename, case.input, &.{
            "--experimental-native",
            "--syntax",
            case.syntax,
            "--minify",
            "--source-map",
        });
        defer deinitRun(&file_result);
        try expectExitCode(file_result, 0);
        try expectInlineSourceMap(
            file_result.stdout,
            case.expected,
            case.filename,
            case.input,
        );

        var stdin_result = try runWithStdin(&.{
            "-",
            "--experimental-native",
            "--syntax",
            case.syntax,
            "--minify",
            "--source-map",
        }, case.input);
        defer deinitRun(&stdin_result);
        try expectExitCode(stdin_result, 0);
        const stdin_name = if (std.mem.eql(u8, case.syntax, "stylus"))
            ".zigcss-stdin.styl"
        else
            try std.fmt.allocPrint(allocator, ".zigcss-stdin.{s}", .{case.syntax});
        defer if (!std.mem.eql(u8, case.syntax, "stylus")) allocator.free(stdin_name);
        try expectInlineSourceMap(
            stdin_result.stdout,
            case.expected,
            stdin_name,
            case.input,
        );
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "first.scss", .data = ".first { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "second.scss", .data = ".second { color: blue; }" });
    try tmp.dir.makeDir("out");
    var batch = try runInDir(tmp.dir, &.{
        "first.scss",
        "second.scss",
        "-o",
        "out",
        "--output-dir",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
        "--source-map",
    });
    defer deinitRun(&batch);
    try expectExitCode(batch, 0);
    const first_output = try tmp.dir.readFileAlloc(allocator, "out/first.css", 1024 * 1024);
    defer allocator.free(first_output);
    const second_output = try tmp.dir.readFileAlloc(allocator, "out/second.css", 1024 * 1024);
    defer allocator.free(second_output);
    try expectInlineSourceMap(
        first_output,
        ".first{color:red}",
        "first.scss",
        ".first { color: red; }",
    );
    try expectInlineSourceMap(
        second_output,
        ".second{color:blue}",
        "second.scss",
        ".second { color: blue; }",
    );
}

test "binary CLI native watch atomically replaces CSS and its composed source map" {
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
        "--source-map",
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

    _ = try waitForMappedOutputContents(
        tmp.dir,
        "output.css",
        case.watch_expected_before,
        case.watch_dependency_before,
    );
    try replaceFileAtomically(
        tmp.dir,
        case.watch_dependency,
        case.watch_dependency_after,
    );
    const changed = try waitForMappedOutputContents(
        tmp.dir,
        "output.css",
        case.watch_expected_after,
        case.watch_dependency_after,
    );
    std.Thread.sleep(1200 * std.time.ns_per_ms);
    try std.testing.expect(changed.eql(try waitForOutputStamp(tmp.dir, "output.css")));
    _ = try child.kill();
    running = false;
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

    var duplicate_map = try runCompilerNamed("input.scss", input, &.{
        "--experimental-native",
        "--syntax",
        "scss",
        "--source-map",
        "--source-map",
    });
    defer deinitRun(&duplicate_map);
    try expectExitCode(duplicate_map, 2);
    try std.testing.expectEqual(@as(usize, 0), duplicate_map.stdout.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        duplicate_map.stderr,
        "--source-map may only be specified once",
    ) != null);
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
        try std.testing.expect(changed.eql(try waitForOutputStamp(tmp.dir, "output.css")));

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
        countOccurrences(stderr, "error NATIVE0009:"),
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
    try std.testing.expect(std.mem.indexOf(u8, escaped.stderr, "error NATIVE0009:") != null);

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

test "binary CLI routes the finite native syntax set through the bounded parallel queue" {
    inline for (route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var input_names: [native_parallel_queued_case_count][]u8 = undefined;
        var initialized_names: usize = 0;
        defer for (input_names[0..initialized_names]) |name| allocator.free(name);

        const extension = std.fs.path.extension(case.filename);
        for (&input_names, 0..) |*name, index| {
            name.* = try std.fmt.allocPrint(allocator, "parallel-{d}{s}", .{ index, extension });
            initialized_names += 1;
            try tmp.dir.writeFile(.{ .sub_path = name.*, .data = case.input });
        }

        var argv: [native_parallel_queued_case_count + 7][]const u8 = undefined;
        for (input_names, 0..) |name, index| argv[index] = name;
        argv[native_parallel_queued_case_count..].* = .{
            "-o",
            "out",
            "--output-dir",
            "--experimental-native",
            "--syntax",
            case.syntax,
            "--minify",
        };

        var first = try runInDir(tmp.dir, &argv);
        defer deinitRun(&first);
        var second = try runInDir(tmp.dir, &argv);
        defer deinitRun(&second);
        try expectExitCode(first, 0);
        try expectExitCode(second, 0);
        try std.testing.expectEqual(@as(usize, 0), first.stdout.len);
        try std.testing.expectEqualStrings(first.stdout, second.stdout);
        try std.testing.expectEqualStrings(first.stderr, second.stderr);

        var previous_status: ?usize = null;
        for (input_names) |name| {
            const output_path = try std.fmt.allocPrint(
                allocator,
                "out/{s}.css",
                .{std.fs.path.stem(name)},
            );
            defer allocator.free(output_path);
            const output = try tmp.dir.readFileAlloc(allocator, output_path, 1024);
            defer allocator.free(output);
            try std.testing.expectEqualStrings(case.expected, output);

            const status = try std.fmt.allocPrint(allocator, "Compiled: {s} ->", .{name});
            defer allocator.free(status);
            const status_index = std.mem.indexOf(u8, first.stderr, status) orelse
                return error.MissingParallelBatchStatus;
            if (previous_status) |prior| try std.testing.expect(prior < status_index);
            previous_status = status_index;
        }
    }
}

test "binary CLI native parallel failure cancels queued work without partial output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("out");

    var input_names: [native_parallel_queued_case_count][]u8 = undefined;
    var output_names: [native_parallel_queued_case_count][]u8 = undefined;
    var sentinels: [native_parallel_queued_case_count][]u8 = undefined;
    var initialized: usize = 0;
    defer {
        for (input_names[0..initialized]) |name| allocator.free(name);
        for (output_names[0..initialized]) |name| allocator.free(name);
        for (sentinels[0..initialized]) |sentinel| allocator.free(sentinel);
    }

    for (0..native_parallel_queued_case_count) |index| {
        input_names[index] = try std.fmt.allocPrint(allocator, "input-{d}.scss", .{index});
        output_names[index] = try std.fmt.allocPrint(allocator, "out/input-{d}.css", .{index});
        sentinels[index] = try std.fmt.allocPrint(allocator, "sentinel-{d}", .{index});
        initialized += 1;
        try tmp.dir.writeFile(.{
            .sub_path = input_names[index],
            .data = if (index == 0) ".bad { color: $missing; }" else ".good { color: green; }",
        });
        try tmp.dir.writeFile(.{ .sub_path = output_names[index], .data = sentinels[index] });
    }

    var argv: [native_parallel_queued_case_count + 7][]const u8 = undefined;
    for (input_names, 0..) |name, index| argv[index] = name;
    argv[native_parallel_queued_case_count..].* = .{
        "-o",
        "out",
        "--output-dir",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    };

    var result = try runInDir(tmp.dir, &argv);
    defer deinitRun(&result);
    try expectExitCode(result, 1);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "error NATIVE0002:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Compiled:") == null);

    for (output_names, sentinels) |output_name, sentinel| {
        const output = try tmp.dir.readFileAlloc(allocator, output_name, 1024);
        defer allocator.free(output);
        try std.testing.expectEqualStrings(sentinel, output);
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
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "error NATIVE0002:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Compiled:") == null);

    const good_output = try tmp.dir.readFileAlloc(allocator, "out/good.css", 1024);
    defer allocator.free(good_output);
    const bad_output = try tmp.dir.readFileAlloc(allocator, "out/bad.css", 1024);
    defer allocator.free(bad_output);
    try std.testing.expectEqualStrings("good-sentinel", good_output);
    try std.testing.expectEqualStrings("bad-sentinel", bad_output);
}

test "binary CLI renders structured native diagnostics without partial output" {
    var warning = try runCompilerNamed(
        "warning.scss",
        ".a { $new: blue !global; color: $new; } .b { color: $new; }",
        &.{ "--experimental-native", "--syntax", "scss", "--minify" },
    );
    defer deinitRun(&warning);
    try expectExitCode(warning, 0);
    try std.testing.expectEqualStrings(".a{color:blue}.b{color:blue}", warning.stdout);
    try std.testing.expect(std.mem.indexOf(
        u8,
        warning.stderr,
        "warning NATIVE0001: !global assignment declares a new variable; Sass 2.0 will reject it",
    ) != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "failure.scss", .data = ".a { color: $missing; }" });
    try tmp.dir.writeFile(.{ .sub_path = "failure.css", .data = "sentinel" });
    var failure = try runInDir(tmp.dir, &.{
        "failure.scss",
        "-o",
        "failure.css",
        "--experimental-native",
        "--syntax",
        "scss",
        "--minify",
    });
    defer deinitRun(&failure);
    try expectExitCode(failure, 1);
    try std.testing.expectEqual(@as(usize, 0), failure.stdout.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        failure.stderr,
        "failure.scss:0:12: error NATIVE0002: undefined Sass variable",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        failure.stderr,
        "native SCSS compilation failed: CompilationFailed",
    ) == null);
    const retained = try tmp.dir.readFileAlloc(allocator, "failure.css", 1024);
    defer allocator.free(retained);
    try std.testing.expectEqualStrings("sentinel", retained);
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
        "--source-map",
    });
    defer deinitRun(&result);
    try expectExitCode(result, 1);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "error NATIVE0002:") != null);

    const output = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("sentinel", output);
}
