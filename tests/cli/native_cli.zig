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

const OptimizeRouteCase = struct {
    syntax: []const u8,
    filename: []const u8,
    input: []const u8,
    second_filename: []const u8,
    second_input: []const u8,
    second_expected: []const u8,
    watch_before: []const u8,
    watch_after: []const u8,
};

const optimize_route_cases = [_]OptimizeRouteCase{
    .{
        .syntax = "scss",
        .filename = "optimize.scss",
        .input = ".empty{}.a{color:#ffffff}.b{color:#fff}",
        .second_filename = "optimize-second.scss",
        .second_input = ".empty{}.c{color:#ffffff}.d{color:#fff}",
        .second_expected = ".c,.d{color:#fff}",
        .watch_before = ".a{width:calc(1px + 2px)}",
        .watch_after = ".a{width:calc(2px + 3px)}",
    },
    .{
        .syntax = "sass",
        .filename = "optimize.sass",
        .input = ".a\n  color: #ffffff\n.b\n  color: #fff\n",
        .second_filename = "optimize-second.sass",
        .second_input = ".c\n  color: #ffffff\n.d\n  color: #fff\n",
        .second_expected = ".c,.d{color:#fff}",
        .watch_before = ".a\n  width: calc(1px + 2px)\n",
        .watch_after = ".a\n  width: calc(2px + 3px)\n",
    },
    .{
        .syntax = "less",
        .filename = "optimize.less",
        .input = ".empty{}.a{color:#ffffff}.b{color:#fff}",
        .second_filename = "optimize-second.less",
        .second_input = ".empty{}.c{color:#ffffff}.d{color:#fff}",
        .second_expected = ".c,.d{color:#fff}",
        .watch_before = ".a{width:calc(1px + 2px)}",
        .watch_after = ".a{width:calc(2px + 3px)}",
    },
    .{
        .syntax = "stylus",
        .filename = "optimize.styl",
        .input = ".a\n  color #ffffff\n.b\n  color #fff\n",
        .second_filename = "optimize-second.styl",
        .second_input = ".c\n  color #ffffff\n.d\n  color #fff\n",
        .second_expected = ".c,.d{color:#fff}",
        .watch_before = ".a\n  width calc(1px + 2px)\n",
        .watch_after = ".a\n  width calc(2px + 3px)\n",
    },
};

const optimized_css = ".a,.b{color:#fff}";
const optimized_pretty_css = ".a, .b {\n  color: #fff;\n}\n";

const PrefixRouteCase = struct {
    syntax: []const u8,
    filename: []const u8,
    input: []const u8,
    second_filename: []const u8,
    second_input: []const u8,
    watch_after: []const u8,
    optimize_input: []const u8,
};

const prefix_route_cases = [_]PrefixRouteCase{
    .{
        .syntax = "scss",
        .filename = "prefix.scss",
        .input = ".a{user-select:none;display:flex}",
        .second_filename = "prefix-second.scss",
        .second_input = ".b{user-select:text;display:flex}",
        .watch_after = ".a{user-select:text;display:flex}",
        .optimize_input = ".empty{}.a{user-select:none;color:#ffffff}.b{user-select:none;color:#fff}",
    },
    .{
        .syntax = "sass",
        .filename = "prefix.sass",
        .input = ".a\n  user-select: none\n  display: flex\n",
        .second_filename = "prefix-second.sass",
        .second_input = ".b\n  user-select: text\n  display: flex\n",
        .watch_after = ".a\n  user-select: text\n  display: flex\n",
        .optimize_input = ".a\n  user-select: none\n  color: #ffffff\n.b\n  user-select: none\n  color: #fff\n",
    },
    .{
        .syntax = "less",
        .filename = "prefix.less",
        .input = ".a{user-select:none;display:flex}",
        .second_filename = "prefix-second.less",
        .second_input = ".b{user-select:text;display:flex}",
        .watch_after = ".a{user-select:text;display:flex}",
        .optimize_input = ".empty{}.a{user-select:none;color:#ffffff}.b{user-select:none;color:#fff}",
    },
    .{
        .syntax = "stylus",
        .filename = "prefix.styl",
        .input = ".a\n  user-select none\n  display flex\n",
        .second_filename = "prefix-second.styl",
        .second_input = ".b\n  user-select text\n  display flex\n",
        .watch_after = ".a\n  user-select text\n  display flex\n",
        .optimize_input = ".a\n  user-select none\n  color #ffffff\n.b\n  user-select none\n  color #fff\n",
    },
};

const legacy_browsers = "safari >= 7, ie >= 11";
const modern_browsers = "chrome >= 120, edge >= 120, firefox >= 120";
const prefixed_css = ".a{-webkit-user-select:none;-ms-user-select:none;user-select:none;display:-webkit-flex;display:flex}";
const second_prefixed_css = ".b{-webkit-user-select:text;-ms-user-select:text;user-select:text;display:-webkit-flex;display:flex}";
const watch_prefixed_css = ".a{-webkit-user-select:text;-ms-user-select:text;user-select:text;display:-webkit-flex;display:flex}";
const optimized_prefixed_css = ".a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}";

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

fn configurePortableWatchChildCwd(
    child: *Child,
    temporary: *const std.testing.TmpDir,
) ![]u8 {
    // Zig 0.15.2 does not implement Child.cwd_dir on Windows. std.testing
    // creates this resource-derived path beneath the process cwd on every host.
    const process_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(process_cwd);
    const cwd = try std.fs.path.join(allocator, &.{
        process_cwd,
        ".zig-cache",
        "tmp",
        temporary.sub_path[0..],
    });
    child.cwd = cwd;
    child.cwd_dir = null;
    return cwd;
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

const NativeWatchCaseStage = enum {
    @"initial-output",
    @"dependency-replace",
    @"changed-output",
    @"stability-observation",
    @"child-termination",
};

const WatchChildTermination = enum {
    killed,
    @"already-terminated",
    @"termination-failed",
};

fn nativeWatchFailureDiagnostic(
    buffer: []u8,
    syntax: []const u8,
    stage: NativeWatchCaseStage,
    err: anyerror,
    termination: WatchChildTermination,
) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "native watch regression syntax={s} stage={s} error={s} child={s}",
        .{
            syntax,
            @tagName(stage),
            @errorName(err),
            @tagName(termination),
        },
    );
}

fn watchChildTerminationAfterKill(
    os_tag: std.Target.Os.Tag,
    term: Child.Term,
) WatchChildTermination {
    if (os_tag == .windows) return .killed;
    return switch (term) {
        .Exited => .@"already-terminated",
        else => .killed,
    };
}

fn terminateWatchChild(child: *Child) !WatchChildTermination {
    const term = child.kill() catch |err| switch (err) {
        error.AlreadyTerminated => {
            _ = try child.wait();
            return .@"already-terminated";
        },
        else => return err,
    };
    return watchChildTerminationAfterKill(builtin.os.tag, term);
}

fn reportNativeWatchFailure(
    captured: *std.fs.File,
    syntax: []const u8,
    stage: NativeWatchCaseStage,
    err: anyerror,
    termination: WatchChildTermination,
) void {
    var diagnostic_buffer: [256]u8 = undefined;
    const diagnostic = nativeWatchFailureDiagnostic(
        &diagnostic_buffer,
        syntax,
        stage,
        err,
        termination,
    ) catch "native watch regression diagnostic overflow";
    if (termination == .@"termination-failed") {
        std.debug.print("{s}\n", .{diagnostic});
        return;
    }

    const stderr = captured.readToEndAlloc(allocator, 1024 * 1024) catch |capture_err| {
        std.debug.print("{s} stderr-capture={s}\n", .{ diagnostic, @errorName(capture_err) });
        return;
    };
    defer allocator.free(stderr);
    std.debug.print("{s}\nchild stderr:\n{s}{s}", .{
        diagnostic,
        stderr,
        if (stderr.len == 0 or stderr[stderr.len - 1] == '\n') "" else "\n",
    });
}

fn settleNativeWatchFailure(
    child: *Child,
    running: *bool,
    captured: *std.fs.File,
    syntax: []const u8,
    stage: NativeWatchCaseStage,
    err: anyerror,
    observed_termination: ?WatchChildTermination,
) void {
    const termination = observed_termination orelse terminateWatchChild(child) catch |termination_err| {
        reportNativeWatchFailure(captured, syntax, stage, err, .@"termination-failed");
        std.debug.print("native watch child termination error={s}\n", .{@errorName(termination_err)});
        return;
    };
    running.* = false;
    reportNativeWatchFailure(captured, syntax, stage, err, termination);
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

    var diagnostic_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "native watch regression syntax=less stage=changed-output error=WatchTimeout child=already-terminated",
        try nativeWatchFailureDiagnostic(
            &diagnostic_buffer,
            "less",
            .@"changed-output",
            error.WatchTimeout,
            .@"already-terminated",
        ),
    );
    try std.testing.expectEqual(
        WatchChildTermination.@"already-terminated",
        watchChildTerminationAfterKill(.linux, .{ .Exited = 1 }),
    );
    try std.testing.expectEqual(
        WatchChildTermination.killed,
        watchChildTerminationAfterKill(.linux, .{ .Signal = 15 }),
    );
    try std.testing.expectEqual(
        WatchChildTermination.killed,
        watchChildTerminationAfterKill(.windows, .{ .Exited = 1 }),
    );
}

test "native watch child cwd is an absolute portable fixture path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const argv = [_][]const u8{"zigcss"};
    var child = Child.init(&argv, allocator);
    const cwd = try configurePortableWatchChildCwd(&child, &tmp);
    defer allocator.free(cwd);

    try std.testing.expect(child.cwd_dir == null);
    try std.testing.expectEqualStrings(cwd, child.cwd.?);
    try std.testing.expect(std.fs.path.isAbsolute(cwd));
    var opened = try std.fs.openDirAbsolute(cwd, .{});
    defer opened.close();
    try opened.writeFile(.{ .sub_path = "portable-cwd.txt", .data = "owned" });
    const contents = try tmp.dir.readFileAlloc(allocator, "portable-cwd.txt", 16);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("owned", contents);
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

fn escapeDepfilePathAlloc(path_value: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    for (path_value) |byte| {
        switch (byte) {
            ' ', '#', ':', '\\' => {
                try escaped.append(allocator, '\\');
                try escaped.append(allocator, byte);
            },
            '$' => try escaped.appendSlice(allocator, "$$"),
            else => try escaped.append(allocator, byte),
        }
    }
    return escaped.toOwnedSlice(allocator);
}

fn expectedDepfileAlloc(
    target: []const u8,
    prerequisites: []const []const u8,
) ![]u8 {
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    const escaped_target = try escapeDepfilePathAlloc(target);
    defer allocator.free(escaped_target);
    try rendered.appendSlice(allocator, escaped_target);
    try rendered.append(allocator, ':');
    for (prerequisites) |path_value| {
        const escaped = try escapeDepfilePathAlloc(path_value);
        defer allocator.free(escaped);
        try rendered.append(allocator, ' ');
        try rendered.appendSlice(allocator, escaped);
    }
    try rendered.append(allocator, '\n');
    return rendered.toOwnedSlice(allocator);
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

const node_protocol_test_frame_limit: usize = 1024 * 1024;

fn encodeNodeProtocolTestFrame(value: anytype) ![]u8 {
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    var json: std.json.Stringify = .{ .writer = &body_writer.writer };
    try json.write(value);
    const body = try body_writer.toOwnedSlice();
    defer allocator.free(body);
    if (body.len == 0 or body.len > node_protocol_test_frame_limit) {
        return error.NodeProtocolFrameLimit;
    }

    const frame = try allocator.alloc(u8, body.len + 4);
    std.mem.writeInt(u32, frame[0..4], @intCast(body.len), .big);
    @memcpy(frame[4..], body);
    return frame;
}

fn decodeNodeProtocolTestFrame(
    frame: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (frame.len < 4) return error.NodeProtocolFrameTruncated;
    const declared: usize = std.mem.readInt(u32, frame[0..4], .big);
    if (declared == 0 or declared > node_protocol_test_frame_limit) {
        return error.NodeProtocolFrameLimit;
    }
    if (frame.len != declared + 4) return error.NodeProtocolFrameTruncated;
    return std.json.parseFromSlice(std.json.Value, allocator, frame[4..], .{});
}

test "binary hidden Node route dispatches one typed bounded frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const source_path = try std.fs.path.join(allocator, &.{ root, "input.scss" });
    defer allocator.free(source_path);
    const roots = [_][]const u8{root};

    const success_frame = try encodeNodeProtocolTestFrame(.{
        .protocol = "zigcss-node-v1",
        .requestId = "cli-node-success",
        .operation = "compile",
        .source = "$color: red;.a{color:$color}",
        .sourcePath = source_path,
        .rootPaths = &roots,
        .options = .{
            .syntax = "scss",
            .format = "minified",
            .sourceMap = false,
            .optimize = false,
            .browsers = @as(?[]const u8, null),
        },
    });
    defer allocator.free(success_frame);
    var success = try runWithStdinInDir(
        tmp.dir,
        &.{"--internal-node-v1"},
        success_frame,
    );
    defer deinitRun(&success);
    try expectExitCode(success, 0);
    try std.testing.expectEqual(@as(usize, 0), success.stderr.len);
    var success_response = try decodeNodeProtocolTestFrame(success.stdout);
    defer success_response.deinit();
    const success_object = success_response.value.object;
    try std.testing.expectEqualStrings(
        "zigcss-node-v1",
        success_object.get("protocol").?.string,
    );
    try std.testing.expectEqualStrings(
        "cli-node-success",
        success_object.get("requestId").?.string,
    );
    try std.testing.expect(success_object.get("ok").?.bool);
    try std.testing.expect(success_object.get("error") == null);
    const success_result = success_object.get("result").?.object;
    try std.testing.expectEqualStrings(
        ".a{color:red}",
        success_result.get("css").?.string,
    );
    try std.testing.expect(success_result.get("sourceMap").? == .null);
    try std.testing.expectEqual(
        @as(usize, 0),
        success_result.get("diagnostics").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        success_result.get("dependencies").?.array.items.len,
    );

    const invalid_query_frame = try encodeNodeProtocolTestFrame(.{
        .protocol = "zigcss-node-v1",
        .requestId = "cli-node-options",
        .operation = "compile",
        .source = ".a{user-select:none}",
        .sourcePath = source_path,
        .rootPaths = &roots,
        .options = .{
            .syntax = "scss",
            .format = "minified",
            .sourceMap = false,
            .optimize = false,
            .browsers = @as(?[]const u8, "ie 11"),
        },
    });
    defer allocator.free(invalid_query_frame);
    var invalid_query = try runWithStdinInDir(
        tmp.dir,
        &.{"--internal-node-v1"},
        invalid_query_frame,
    );
    defer deinitRun(&invalid_query);
    try expectExitCode(invalid_query, 0);
    try std.testing.expectEqual(@as(usize, 0), invalid_query.stderr.len);
    var invalid_response = try decodeNodeProtocolTestFrame(invalid_query.stdout);
    defer invalid_response.deinit();
    const invalid_object = invalid_response.value.object;
    try std.testing.expectEqualStrings(
        "zigcss-node-v1",
        invalid_object.get("protocol").?.string,
    );
    try std.testing.expectEqualStrings(
        "cli-node-options",
        invalid_object.get("requestId").?.string,
    );
    try std.testing.expect(!invalid_object.get("ok").?.bool);
    try std.testing.expect(invalid_object.get("result") == null);
    const typed_error = invalid_object.get("error").?.object;
    try std.testing.expectEqualStrings(
        "NODE_OPTIONS",
        typed_error.get("code").?.string,
    );
    try std.testing.expectEqualStrings(
        "browser target query is invalid",
        typed_error.get("message").?.string,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        typed_error.get("diagnostics").?.array.items.len,
    );

    var extra_argv = try runInDir(
        tmp.dir,
        &.{ "--internal-node-v1", "unexpected" },
    );
    defer deinitRun(&extra_argv);
    try expectExitCode(extra_argv, 2);
    try std.testing.expectEqual(@as(usize, 0), extra_argv.stdout.len);
}

test "stable native syntax selection and help agree with executable CLI tests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var help = try runInDir(tmp.dir, &.{"--help"});
    defer deinitRun(&help);
    try expectExitCode(help, 0);
    try std.testing.expectEqual(@as(usize, 0), help.stderr.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "--syntax <syntax>        Select css (default), scss, sass, less, or stylus",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "--depfile <path>         Write one bounded Make/Ninja dependency file",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "--source-map             Embed a deterministic inline source map",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "--optimize               Run the closed verified optimizer preset",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "--autoprefix             Run verified eight-feature target prefixing",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "--browsers <query>       Set explicit browser minima (requires --autoprefix)",
    ) != null);
    for ([_][]const u8{ "--experimental-native", "gated native syntax", "pre-graduation" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, help.stdout, forbidden) == null);
    }

    inline for (route_cases) |case| {
        var result = try runCompilerNamed(case.filename, case.input, &.{
            "--syntax",
            case.syntax,
            "--minify",
        });
        defer deinitRun(&result);
        try expectExitCode(result, 0);
        try std.testing.expectEqualStrings(case.expected, result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "experimental release candidate") != null);
    }
}

test "binary CLI emits deterministic depfiles for all five syntaxes and only read inputs" {
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{
            .sub_path = "input.css",
            .data = "@import \"theme.css\";.direct{color:red}",
        });
        try tmp.dir.writeFile(.{ .sub_path = "theme.css", .data = ".theme{color:blue}" });

        var first = try runInDir(tmp.dir, &.{
            "input.css",
            "--syntax",
            "css",
            "--minify",
            "-o",
            "output.css",
            "--depfile",
            "output.css.d",
        });
        defer deinitRun(&first);
        try expectExitCode(first, 0);
        const css = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
        defer allocator.free(css);
        try std.testing.expectEqualStrings(
            "@import \"theme.css\";.direct{color:red}",
            css,
        );
        const entry = try tmp.dir.realpathAlloc(allocator, "input.css");
        defer allocator.free(entry);
        const expected = try expectedDepfileAlloc("output.css", &.{entry});
        defer allocator.free(expected);
        const depfile = try tmp.dir.readFileAlloc(allocator, "output.css.d", 1024 * 1024);
        defer allocator.free(depfile);
        try std.testing.expectEqualStrings(expected, depfile);
        try std.testing.expect(std.mem.indexOf(u8, depfile, "theme.css") == null);

        var repeated = try runInDir(tmp.dir, &.{
            "input.css",
            "--syntax",
            "css",
            "--minify",
            "-o",
            "output.css",
            "--depfile",
            "output.css.d",
        });
        defer deinitRun(&repeated);
        try expectExitCode(repeated, 0);
        const repeated_depfile = try tmp.dir.readFileAlloc(allocator, "output.css.d", 1024 * 1024);
        defer allocator.free(repeated_depfile);
        try std.testing.expectEqualStrings(depfile, repeated_depfile);
    }

    inline for (route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.watch_input });
        try tmp.dir.writeFile(.{
            .sub_path = case.watch_dependency,
            .data = case.watch_dependency_before,
        });

        var first = try runInDir(tmp.dir, &.{
            case.filename,
            "--syntax",
            case.syntax,
            "--minify",
            "-o",
            "output.css",
            "--depfile",
            "output.css.d",
        });
        defer deinitRun(&first);
        try expectExitCode(first, 0);
        const css = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
        defer allocator.free(css);
        try std.testing.expectEqualStrings(case.watch_expected_before, css);

        const entry = try tmp.dir.realpathAlloc(allocator, case.filename);
        defer allocator.free(entry);
        const dependency = try tmp.dir.realpathAlloc(allocator, case.watch_dependency);
        defer allocator.free(dependency);
        const expected = try expectedDepfileAlloc("output.css", &.{ entry, dependency });
        defer allocator.free(expected);
        const depfile = try tmp.dir.readFileAlloc(allocator, "output.css.d", 1024 * 1024);
        defer allocator.free(depfile);
        try std.testing.expectEqualStrings(expected, depfile);

        var repeated = try runInDir(tmp.dir, &.{
            case.filename,
            "--syntax",
            case.syntax,
            "--minify",
            "-o",
            "output.css",
            "--depfile",
            "output.css.d",
        });
        defer deinitRun(&repeated);
        try expectExitCode(repeated, 0);
        const repeated_depfile = try tmp.dir.readFileAlloc(allocator, "output.css.d", 1024 * 1024);
        defer allocator.free(repeated_depfile);
        try std.testing.expectEqualStrings(depfile, repeated_depfile);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{
            .sub_path = "input.less",
            .data = "@import \"z.less\";@import \"a.less\";@import \"z.less\";.x{color:@a;background:@z}",
        });
        try tmp.dir.writeFile(.{ .sub_path = "z.less", .data = "@z:blue;" });
        try tmp.dir.writeFile(.{ .sub_path = "a.less", .data = "@a:red;" });
        var result = try runInDir(tmp.dir, &.{
            "input.less",
            "--syntax",
            "less",
            "--minify",
            "-o",
            "sorted.css",
            "--depfile",
            "sorted.css.d",
        });
        defer deinitRun(&result);
        try expectExitCode(result, 0);
        const entry = try tmp.dir.realpathAlloc(allocator, "input.less");
        defer allocator.free(entry);
        const first_dependency = try tmp.dir.realpathAlloc(allocator, "a.less");
        defer allocator.free(first_dependency);
        const second_dependency = try tmp.dir.realpathAlloc(allocator, "z.less");
        defer allocator.free(second_dependency);
        const expected = try expectedDepfileAlloc(
            "sorted.css",
            &.{ entry, first_dependency, second_dependency },
        );
        defer allocator.free(expected);
        const depfile = try tmp.dir.readFileAlloc(allocator, "sorted.css.d", 1024 * 1024);
        defer allocator.free(depfile);
        try std.testing.expectEqualStrings(expected, depfile);
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(depfile, second_dependency));
    }
}

test "binary CLI depfile preserves authored target spelling and escapes portable paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_name = if (builtin.os.tag == .windows)
        "in put#$name.css"
    else
        "in put#$:slash\\name.css";
    const output_name = if (builtin.os.tag == .windows)
        "out put#$name.css"
    else
        "out put#$:slash\\name.css";
    try tmp.dir.writeFile(.{ .sub_path = input_name, .data = ".escaped{color:red}" });
    var result = try runInDir(tmp.dir, &.{
        input_name,
        "--syntax",
        "css",
        "--minify",
        "-o",
        output_name,
        "--depfile",
        "deps file.d",
    });
    defer deinitRun(&result);
    try expectExitCode(result, 0);

    const entry = try tmp.dir.realpathAlloc(allocator, input_name);
    defer allocator.free(entry);
    const expected = try expectedDepfileAlloc(output_name, &.{entry});
    defer allocator.free(expected);
    const depfile = try tmp.dir.readFileAlloc(allocator, "deps file.d", 1024 * 1024);
    defer allocator.free(depfile);
    try std.testing.expectEqualStrings(expected, depfile);
    const escaped_target = try escapeDepfilePathAlloc(output_name);
    defer allocator.free(escaped_target);
    try std.testing.expect(std.mem.startsWith(
        u8,
        depfile,
        escaped_target,
    ));
}

test "binary CLI depfile invalid combinations and every input alias fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".a{color:red}" });
    try tmp.dir.writeFile(.{ .sub_path = "second.css", .data = ".b{color:blue}" });

    const invalid = [_][]const []const u8{
        &.{ "input.css", "--depfile" },
        &.{ "input.css", "--depfile", "output.css.d" },
        &.{ "input.css", "-o", "-", "--depfile", "output.css.d" },
        &.{ "input.css", "-o", "output.css", "--depfile", "-" },
        &.{ "input.css", "-o", "output.css", "--depfile", "bad\npath.d" },
        &.{ "input.css", "-o", "output.css", "--depfile", "output.css.d", "--depfile", "again.d" },
        &.{ "input.css", "-o", "output.css", "--depfile", "output.css.d", "--watch" },
        &.{ "input.css", "-o", "out", "--output-dir", "--depfile", "output.css.d" },
        &.{ "input.css", "second.css", "-o", "out", "--depfile", "output.css.d" },
        &.{ "input.css", "-o", "output.css", "--depfile", "output.css" },
        &.{ "input.css", "-o", "output.css", "--depfile", "input.css" },
        &.{ "input.css", "-o", "input.css", "--depfile", "output.css.d" },
    };
    for (invalid) |argv| {
        var rejected = try runInDir(tmp.dir, argv);
        defer deinitRun(&rejected);
        try expectExitCode(rejected, 2);
        try std.testing.expectEqual(@as(usize, 0), rejected.stdout.len);
    }

    var stdin_rejected = try runWithStdinInDir(
        tmp.dir,
        &.{ "-", "-o", "output.css", "--depfile", "output.css.d" },
        ".a{}",
    );
    defer deinitRun(&stdin_rejected);
    try expectExitCode(stdin_rejected, 2);

    try tmp.dir.writeFile(.{
        .sub_path = "entry.scss",
        .data = "@use \"tokens\";.card{color:tokens.$color}",
    });
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = "$color:red;" });
    var imported_alias = try runInDir(tmp.dir, &.{
        "entry.scss",
        "--syntax",
        "scss",
        "--minify",
        "-o",
        "_tokens.scss",
        "--depfile",
        "native.css.d",
    });
    defer deinitRun(&imported_alias);
    try expectExitCode(imported_alias, 2);
    const dependency = try tmp.dir.readFileAlloc(allocator, "_tokens.scss", 1024);
    defer allocator.free(dependency);
    try std.testing.expectEqualStrings("$color:red;", dependency);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("native.css.d", .{}));

    var imported_depfile_alias = try runInDir(tmp.dir, &.{
        "entry.scss",
        "--syntax",
        "scss",
        "--minify",
        "-o",
        "native.css",
        "--depfile",
        "_tokens.scss",
    });
    defer deinitRun(&imported_depfile_alias);
    try expectExitCode(imported_depfile_alias, 2);
    const retained_dependency = try tmp.dir.readFileAlloc(allocator, "_tokens.scss", 1024);
    defer allocator.free(retained_dependency);
    try std.testing.expectEqualStrings("$color:red;", retained_dependency);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("native.css", .{}));
}

test "binary CLI stdin may atomically replace an existing literal dash filename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "-", .data = "sentinel" });

    var stable = try runWithStdinInDir(
        tmp.dir,
        &.{ "-", "-o", "./-", "--minify" },
        ".stable { color: red; }",
    );
    defer deinitRun(&stable);
    try expectExitCode(stable, 0);
    const stable_output = try tmp.dir.readFileAlloc(allocator, "-", 1024);
    defer allocator.free(stable_output);
    try std.testing.expectEqualStrings(".stable{color:red}", stable_output);

    var native = try runWithStdinInDir(
        tmp.dir,
        &.{ "-", "-o", "./-", "--syntax", "scss", "--minify" },
        ".native { color: blue; }",
    );
    defer deinitRun(&native);
    try expectExitCode(native, 0);
    const native_output = try tmp.dir.readFileAlloc(allocator, "-", 1024);
    defer allocator.free(native_output);
    try std.testing.expectEqualStrings(".native{color:blue}", native_output);
}

test "binary CLI native output cannot replace an exact dependency in single or watch mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dependency_source = "$color: red; /* dependency-sentinel */";
    try tmp.dir.writeFile(.{
        .sub_path = "entry.scss",
        .data = "@use \"tokens\";.card{color:tokens.$color}",
    });
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = dependency_source });

    var single = try runInDir(tmp.dir, &.{
        "entry.scss",
        "--syntax",
        "scss",
        "--minify",
        "-o",
        "_tokens.scss",
    });
    defer deinitRun(&single);
    try expectExitCode(single, 2);
    try std.testing.expectEqual(@as(usize, 0), single.stdout.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        single.stderr,
        "native output or depfile path resolves to an entry or dependency",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, single.stderr, "Compiled:") == null);
    const after_single = try tmp.dir.readFileAlloc(allocator, "_tokens.scss", 1024);
    defer allocator.free(after_single);
    try std.testing.expectEqualStrings(dependency_source, after_single);

    var watched = try runInDir(tmp.dir, &.{
        "entry.scss",
        "--syntax",
        "scss",
        "--minify",
        "--watch",
        "-o",
        "_tokens.scss",
    });
    defer deinitRun(&watched);
    try expectExitCode(watched, 2);
    try std.testing.expectEqual(@as(usize, 0), watched.stdout.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        watched.stderr,
        "native output or depfile path resolves to an entry or dependency",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, watched.stderr, "Compiled:") == null);
    const after_watch = try tmp.dir.readFileAlloc(allocator, "_tokens.scss", 1024);
    defer allocator.free(after_watch);
    try std.testing.expectEqualStrings(dependency_source, after_watch);
}

test "binary CLI native output and depfile reject dependency symlink and inode aliases" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dependency_source = "$color: red; /* dependency-alias-sentinel */";
    try tmp.dir.writeFile(.{
        .sub_path = "entry.scss",
        .data = "@use \"tokens\";.card{color:tokens.$color}",
    });
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = dependency_source });
    try tmp.dir.symLink("_tokens.scss", "dependency-symlink.css", .{});
    try std.posix.linkat(
        tmp.dir.fd,
        "_tokens.scss",
        tmp.dir.fd,
        "dependency-hard-link.css",
        0,
    );

    for ([_][]const u8{ "dependency-symlink.css", "dependency-hard-link.css" }) |output_path| {
        var rejected = try runInDir(tmp.dir, &.{
            "entry.scss",
            "--syntax",
            "scss",
            "--minify",
            "-o",
            output_path,
        });
        defer deinitRun(&rejected);
        try expectExitCode(rejected, 2);
        try std.testing.expectEqual(@as(usize, 0), rejected.stdout.len);
        try std.testing.expect(std.mem.indexOf(
            u8,
            rejected.stderr,
            "native output or depfile path resolves to an entry or dependency",
        ) != null);
        const retained_alias = try tmp.dir.readFileAlloc(allocator, output_path, 1024);
        defer allocator.free(retained_alias);
        try std.testing.expectEqualStrings(dependency_source, retained_alias);
    }

    var depfile_alias = try runInDir(tmp.dir, &.{
        "entry.scss",
        "--syntax",
        "scss",
        "--minify",
        "-o",
        "safe-output.css",
        "--depfile",
        "dependency-hard-link.css",
    });
    defer deinitRun(&depfile_alias);
    try expectExitCode(depfile_alias, 2);
    try std.testing.expectEqual(@as(usize, 0), depfile_alias.stdout.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        depfile_alias.stderr,
        "native output or depfile path resolves to an entry or dependency",
    ) != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("safe-output.css", .{}));

    const retained_dependency = try tmp.dir.readFileAlloc(allocator, "_tokens.scss", 1024);
    defer allocator.free(retained_dependency);
    try std.testing.expectEqualStrings(dependency_source, retained_dependency);
    const dependency_stat = try tmp.dir.statFile("_tokens.scss");
    const hard_link_stat = try tmp.dir.statFile("dependency-hard-link.css");
    try std.testing.expectEqual(dependency_stat.inode, hard_link_stat.inode);
}

test "binary CLI native batch validates the dependency union before every output commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dependency_source = "$color: red; /* batch-dependency-sentinel */";
    try tmp.dir.writeFile(.{ .sub_path = "first.scss", .data = ".first{color:blue}" });
    try tmp.dir.writeFile(.{
        .sub_path = "second.scss",
        .data = "@use \"tokens\";.second{color:tokens.$color}",
    });
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = dependency_source });
    try tmp.dir.makeDir("out");
    // The first task does not import this file. Only a union across every
    // completed task can detect that its output aliases the second task's
    // dependency before the first write occurs.
    try std.posix.linkat(tmp.dir.fd, "_tokens.scss", tmp.dir.fd, "out/first.css", 0);
    try tmp.dir.writeFile(.{ .sub_path = "out/second.css", .data = "second-output-sentinel" });

    var batch = try runInDir(tmp.dir, &.{
        "first.scss",
        "second.scss",
        "-o",
        "out",
        "--output-dir",
        "--syntax",
        "scss",
        "--minify",
    });
    defer deinitRun(&batch);
    try expectExitCode(batch, 2);
    try std.testing.expectEqual(@as(usize, 0), batch.stdout.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        batch.stderr,
        "native output or depfile path resolves to an entry or dependency",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, batch.stderr, "Compiled:") == null);

    const retained_dependency = try tmp.dir.readFileAlloc(allocator, "_tokens.scss", 1024);
    defer allocator.free(retained_dependency);
    const retained_first = try tmp.dir.readFileAlloc(allocator, "out/first.css", 1024);
    defer allocator.free(retained_first);
    const retained_second = try tmp.dir.readFileAlloc(allocator, "out/second.css", 1024);
    defer allocator.free(retained_second);
    try std.testing.expectEqualStrings(dependency_source, retained_dependency);
    try std.testing.expectEqualStrings(dependency_source, retained_first);
    try std.testing.expectEqualStrings("second-output-sentinel", retained_second);
    const dependency_stat = try tmp.dir.statFile("_tokens.scss");
    const first_output_stat = try tmp.dir.statFile("out/first.css");
    try std.testing.expectEqual(dependency_stat.inode, first_output_stat.inode);
}

test "binary CLI compile failures retain existing CSS and depfile bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "broken.css", .data = ".broken{" });
    try tmp.dir.writeFile(.{ .sub_path = "output.css", .data = "css-sentinel" });
    try tmp.dir.writeFile(.{ .sub_path = "output.css.d", .data = "depfile-sentinel" });
    var css_failure = try runInDir(tmp.dir, &.{
        "broken.css",
        "-o",
        "output.css",
        "--depfile",
        "output.css.d",
    });
    defer deinitRun(&css_failure);
    try expectExitCode(css_failure, 1);
    const retained_css = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(retained_css);
    const retained_depfile = try tmp.dir.readFileAlloc(allocator, "output.css.d", 1024);
    defer allocator.free(retained_depfile);
    try std.testing.expectEqualStrings("css-sentinel", retained_css);
    try std.testing.expectEqualStrings("depfile-sentinel", retained_depfile);

    try tmp.dir.writeFile(.{ .sub_path = "broken.scss", .data = ".a{color:$missing}" });
    var native_failure = try runInDir(tmp.dir, &.{
        "broken.scss",
        "--syntax",
        "scss",
        "-o",
        "output.css",
        "--depfile",
        "output.css.d",
    });
    defer deinitRun(&native_failure);
    try expectExitCode(native_failure, 1);
    const retained_native_css = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(retained_native_css);
    const retained_native_depfile = try tmp.dir.readFileAlloc(allocator, "output.css.d", 1024);
    defer allocator.free(retained_native_depfile);
    try std.testing.expectEqualStrings("css-sentinel", retained_native_css);
    try std.testing.expectEqualStrings("depfile-sentinel", retained_native_depfile);
}

test "binary CLI bounds input admission before filesystem and byte-sorts glob batches" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const oversized_count = 4096 + 1;
    const oversized = try allocator.alloc([]const u8, oversized_count);
    defer allocator.free(oversized);
    @memset(oversized, "x/*");
    var rejected = try runInDir(tmp.dir, oversized);
    defer deinitRun(&rejected);
    try expectExitCode(rejected, 2);
    try std.testing.expectEqual(@as(usize, 0), rejected.stdout.len);
    try std.testing.expectEqualStrings(
        "Error: too many input patterns (maximum 4096)\n",
        rejected.stderr,
    );
    var empty_iterator = tmp.dir.iterate();
    try std.testing.expect(try empty_iterator.next() == null);

    try tmp.dir.writeFile(.{ .sub_path = "z.css", .data = ".z { color: blue; }" });
    try tmp.dir.writeFile(.{ .sub_path = "a.css", .data = ".a { color: red; }" });
    var batch = try runInDir(tmp.dir, &.{ "*.css", "-o", "out", "--output-dir", "--minify" });
    defer deinitRun(&batch);
    try expectExitCode(batch, 0);
    try std.testing.expectEqual(@as(usize, 0), batch.stdout.len);
    const a_status = std.mem.indexOf(u8, batch.stderr, "a.css ->") orelse
        return error.MissingSortedBatchStatus;
    const z_status = std.mem.indexOf(u8, batch.stderr, "z.css ->") orelse
        return error.MissingSortedBatchStatus;
    try std.testing.expect(a_status < z_status);
    const a_output = try tmp.dir.readFileAlloc(allocator, "out/a.css", 1024);
    defer allocator.free(a_output);
    const z_output = try tmp.dir.readFileAlloc(allocator, "out/z.css", 1024);
    defer allocator.free(z_output);
    try std.testing.expectEqualStrings(".a{color:red}", a_output);
    try std.testing.expectEqualStrings(".z{color:blue}", z_output);
}

test "binary CLI batch gives non-ASCII case and normalization variants unique portable names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "one", "two", "three", "four" }) |directory| {
        try tmp.dir.makeDir(directory);
    }
    const input_names = [_][]const u8{
        "one/\xc3\x84.scss",
        "two/\xc3\xa4.scss",
        "three/\xc3\xa9.scss",
        "four/e\xcc\x81.scss",
    };
    const expected_outputs = [_][]const u8{
        ".upper{color:red}",
        ".lower{color:blue}",
        ".composed{color:green}",
        ".decomposed{color:purple}",
    };
    inline for (input_names, expected_outputs) |input_name, input| {
        try tmp.dir.writeFile(.{ .sub_path = input_name, .data = input });
    }

    var batch = try runInDir(tmp.dir, &.{
        input_names[0],
        input_names[1],
        input_names[2],
        input_names[3],
        "-o",
        "out",
        "--output-dir",
        "--syntax",
        "scss",
        "--minify",
    });
    defer deinitRun(&batch);
    try expectExitCode(batch, 0);

    var output_dir = try tmp.dir.openDir("out", .{ .iterate = true });
    defer output_dir.close();
    var seen = [_]bool{false} ** expected_outputs.len;
    var output_count: usize = 0;
    var iterator = output_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        output_count += 1;
        const uses_portable_policy = switch (builtin.os.tag) {
            .windows, .macos, .ios, .tvos, .watchos => true,
            else => false,
        };
        if (uses_portable_policy) {
            try std.testing.expect(std.mem.startsWith(u8, entry.name, "zigcss-"));
            try std.testing.expect(std.mem.endsWith(u8, entry.name, ".css"));
            for (entry.name) |byte| try std.testing.expect(std.ascii.isAscii(byte));
        }
        const output = try output_dir.readFileAlloc(allocator, entry.name, 1024);
        defer allocator.free(output);
        for (expected_outputs, 0..) |expected, index| {
            if (std.mem.eql(u8, output, expected)) seen[index] = true;
        }
    }
    try std.testing.expectEqual(expected_outputs.len, output_count);
    for (seen) |matched| try std.testing.expect(matched);
}

test "binary CLI can commit a direct working-directory output without directory read permission" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // Dir.chmod requires a directory descriptor opened for iteration. Some
    // non-Linux hosts tolerate an O_PATH-style descriptor here, while Linux
    // correctly rejects it with EBADF.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".safe { color: red; }" });
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    try tmp.dir.chmod(0o300);
    var restricted = true;
    defer if (restricted) tmp.dir.chmod(0o700) catch {};

    const argv = [_][]const u8{
        cli_options.compiler_path,
        "input.css",
        "-o",
        "output.css",
        "--minify",
    };
    var result = try Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });
    defer deinitRun(&result);
    try tmp.dir.chmod(0o700);
    restricted = false;

    try expectExitCode(result, 0);
    const output = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(".safe{color:red}", output);
}

test "binary CLI applies the verified optimizer to native files stdin and parallel batches" {
    inline for (optimize_route_cases) |case| {
        const argv = &.{
            "--syntax",
            case.syntax,
            "--optimize",
            "--minify",
        };
        var file_result = try runCompilerNamed(case.filename, case.input, argv);
        defer deinitRun(&file_result);
        try expectExitCode(file_result, 0);
        try std.testing.expectEqualStrings(optimized_css, file_result.stdout);

        var pretty_result = try runCompilerNamed(case.filename, case.input, &.{
            "--syntax",
            case.syntax,
            "--optimize",
        });
        defer deinitRun(&pretty_result);
        try expectExitCode(pretty_result, 0);
        try std.testing.expectEqualStrings(optimized_pretty_css, pretty_result.stdout);

        var stdin_result = try runWithStdin(&.{
            "-",
            "--syntax",
            case.syntax,
            "--optimize",
            "--minify",
        }, case.input);
        defer deinitRun(&stdin_result);
        try expectExitCode(stdin_result, 0);
        try std.testing.expectEqualStrings(optimized_css, stdin_result.stdout);

        var fixed_point = try runCompilerNamed("optimized.css", file_result.stdout, &.{
            "--syntax",
            "css",
            "--optimize",
            "--minify",
        });
        defer deinitRun(&fixed_point);
        try expectExitCode(fixed_point, 0);
        try std.testing.expectEqualStrings(file_result.stdout, fixed_point.stdout);
    }

    inline for (optimize_route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.input });
        try tmp.dir.writeFile(.{ .sub_path = case.second_filename, .data = case.second_input });
        var batch = try runInDir(tmp.dir, &.{
            case.filename,
            case.second_filename,
            "-o",
            "out",
            "--output-dir",
            "--syntax",
            case.syntax,
            "--optimize",
            "--minify",
        });
        defer deinitRun(&batch);
        try expectExitCode(batch, 0);
        const first_path = try std.fmt.allocPrint(allocator, "out/{s}.css", .{std.fs.path.stem(case.filename)});
        defer allocator.free(first_path);
        const second_path = try std.fmt.allocPrint(allocator, "out/{s}.css", .{std.fs.path.stem(case.second_filename)});
        defer allocator.free(second_path);
        const first_output = try tmp.dir.readFileAlloc(allocator, first_path, 1024);
        defer allocator.free(first_output);
        const second_output = try tmp.dir.readFileAlloc(allocator, second_path, 1024);
        defer allocator.free(second_output);
        try std.testing.expectEqualStrings(optimized_css, first_output);
        try std.testing.expectEqualStrings(case.second_expected, second_output);
    }
}

test "binary CLI applies verified target prefixing to native files stdin maps optimize and parallel batches" {
    inline for (prefix_route_cases) |case| {
        const prefix_args = &.{
            "--syntax",
            case.syntax,
            "--autoprefix",
            "--browsers",
            legacy_browsers,
            "--minify",
        };
        var file_result = try runCompilerNamed(case.filename, case.input, prefix_args);
        defer deinitRun(&file_result);
        try expectExitCode(file_result, 0);
        try std.testing.expectEqualStrings(prefixed_css, file_result.stdout);

        var stdin_result = try runWithStdin(&.{
            "-",
            "--syntax",
            case.syntax,
            "--autoprefix",
            "--browsers",
            legacy_browsers,
            "--minify",
        }, case.input);
        defer deinitRun(&stdin_result);
        try expectExitCode(stdin_result, 0);
        try std.testing.expectEqualStrings(prefixed_css, stdin_result.stdout);

        var modern = try runCompilerNamed(case.filename, case.input, &.{
            "--syntax",
            case.syntax,
            "--autoprefix",
            "--browsers",
            modern_browsers,
            "--minify",
        });
        defer deinitRun(&modern);
        try expectExitCode(modern, 0);
        try std.testing.expectEqualStrings(".a{user-select:none;display:flex}", modern.stdout);

        var mapped = try runCompilerNamed(case.filename, case.input, &.{
            "--syntax",
            case.syntax,
            "--autoprefix",
            "--browsers",
            legacy_browsers,
            "--source-map",
            "--minify",
        });
        defer deinitRun(&mapped);
        try expectExitCode(mapped, 0);
        try expectInlineSourceMap(mapped.stdout, prefixed_css, case.filename, case.input);

        var optimized = try runCompilerNamed(case.filename, case.optimize_input, &.{
            "--syntax",
            case.syntax,
            "--autoprefix",
            "--browsers",
            legacy_browsers,
            "--optimize",
            "--minify",
        });
        defer deinitRun(&optimized);
        try expectExitCode(optimized, 0);
        try std.testing.expectEqualStrings(optimized_prefixed_css, optimized.stdout);
    }

    inline for (prefix_route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.input });
        try tmp.dir.writeFile(.{ .sub_path = case.second_filename, .data = case.second_input });
        var batch = try runInDir(tmp.dir, &.{
            case.filename,
            case.second_filename,
            "-o",
            "out",
            "--output-dir",
            "--syntax",
            case.syntax,
            "--autoprefix",
            "--browsers",
            legacy_browsers,
            "--minify",
        });
        defer deinitRun(&batch);
        try expectExitCode(batch, 0);
        const first_path = try std.fmt.allocPrint(allocator, "out/{s}.css", .{std.fs.path.stem(case.filename)});
        defer allocator.free(first_path);
        const second_path = try std.fmt.allocPrint(allocator, "out/{s}.css", .{std.fs.path.stem(case.second_filename)});
        defer allocator.free(second_path);
        const first_output = try tmp.dir.readFileAlloc(allocator, first_path, 1024);
        defer allocator.free(first_output);
        const second_output = try tmp.dir.readFileAlloc(allocator, second_path, 1024);
        defer allocator.free(second_output);
        try std.testing.expectEqualStrings(prefixed_css, first_output);
        try std.testing.expectEqualStrings(second_prefixed_css, second_output);
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

test "binary CLI routes stable CSS source maps through files stdin and parallel batches" {
    const input = ".mapped { color: red; }";
    const expected = ".mapped{color:red}";
    var file_result = try runCompilerNamed("input.css", input, &.{
        "--syntax",
        "css",
        "--minify",
        "--source-map",
    });
    defer deinitRun(&file_result);
    try expectExitCode(file_result, 0);
    try expectInlineSourceMap(file_result.stdout, expected, "input.css", input);

    var stdin_result = try runWithStdin(&.{
        "-",
        "--syntax",
        "css",
        "--minify",
        "--source-map",
    }, input);
    defer deinitRun(&stdin_result);
    try expectExitCode(stdin_result, 0);
    try expectInlineSourceMap(stdin_result.stdout, expected, "<stdin>", input);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "first.css", .data = ".first { color: red; }" });
    try tmp.dir.writeFile(.{ .sub_path = "second.css", .data = ".second { color: blue; }" });
    try tmp.dir.makeDir("out");
    var batch = try runInDir(tmp.dir, &.{
        "first.css",
        "second.css",
        "-o",
        "out",
        "--output-dir",
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
        "first.css",
        ".first { color: red; }",
    );
    try expectInlineSourceMap(
        second_output,
        ".second{color:blue}",
        "second.css",
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

test "binary CLI stable CSS watch atomically replaces CSS and its inline source map" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const before = ".watch { color: red; }";
    const after = ".watch { color: blue; }";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = before });
    const argv = [_][]const u8{
        cli_options.compiler_path,
        "input.css",
        "-o",
        "output.css",
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
        ".watch{color:red}",
        before,
    );
    try replaceFileAtomically(tmp.dir, "input.css", after);
    const changed = try waitForMappedOutputContents(
        tmp.dir,
        "output.css",
        ".watch{color:blue}",
        after,
    );
    std.Thread.sleep(1200 * std.time.ns_per_ms);
    try std.testing.expect(changed.eql(try waitForOutputStamp(tmp.dir, "output.css")));
    _ = try child.kill();
    running = false;
}

test "binary CLI native optimizer watch commits only byte-stable output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    inline for (optimize_route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.watch_before });
        const argv = [_][]const u8{
            cli_options.compiler_path,
            case.filename,
            "-o",
            "output.css",
            "--syntax",
            case.syntax,
            "--watch",
            "--optimize",
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

        _ = try waitForOutputContents(tmp.dir, "output.css", ".a{width:3px}");
        try replaceFileAtomically(tmp.dir, case.filename, case.watch_after);
        const changed = try waitForOutputContents(tmp.dir, "output.css", ".a{width:5px}");
        std.Thread.sleep(1200 * std.time.ns_per_ms);
        try std.testing.expect(changed.eql(try waitForOutputStamp(tmp.dir, "output.css")));
        _ = try child.kill();
        running = false;
    }
}

test "binary CLI native target prefix watch retains output recovers and shares one immutable query" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    inline for (prefix_route_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = case.filename, .data = case.input });
        const argv = [_][]const u8{
            cli_options.compiler_path,
            case.filename,
            "-o",
            "output.css",
            "--syntax",
            case.syntax,
            "--watch",
            "--autoprefix",
            "--browsers",
            legacy_browsers,
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

        const initial = try waitForOutputContents(tmp.dir, "output.css", prefixed_css);
        try tmp.dir.deleteFile(case.filename);
        std.Thread.sleep(1300 * std.time.ns_per_ms);
        try std.testing.expect(initial.eql(try waitForOutputStamp(tmp.dir, "output.css")));
        const retained = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
        defer allocator.free(retained);
        try std.testing.expectEqualStrings(prefixed_css, retained);

        try replaceFileAtomically(tmp.dir, case.filename, case.watch_after);
        const changed = try waitForOutputContents(tmp.dir, "output.css", watch_prefixed_css);
        std.Thread.sleep(1200 * std.time.ns_per_ms);
        try std.testing.expect(changed.eql(try waitForOutputStamp(tmp.dir, "output.css")));
        _ = try child.kill();
        running = false;
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
    try std.testing.expect(std.mem.indexOf(u8, extension_only.stderr, "input.scss input requires --syntax scss") != null);

    var implicit = try runCompilerNamed("input.scss", input, &.{ "--syntax", "scss", "--minify" });
    defer deinitRun(&implicit);
    try expectExitCode(implicit, 0);
    try std.testing.expectEqualStrings(route_cases[0].expected, implicit.stdout);
    try std.testing.expect(std.mem.indexOf(u8, implicit.stderr, "experimental release candidate") != null);

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

    const pending_modes = [_][]const u8{"--profile"};
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
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "--profile is unavailable for native stylesheet syntax") != null);
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

test "binary CLI rejects native maps plus optimizer before reading any syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "output.css", .data = "sentinel" });

    inline for (optimize_route_cases) |case| {
        var result = try runInDir(tmp.dir, &.{
            case.filename,
            "-o",
            "output.css",
            "--syntax",
            case.syntax,
            "--source-map",
            "--optimize",
        });
        defer deinitRun(&result);
        try expectExitCode(result, 2);
        try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
        try std.testing.expect(std.mem.indexOf(
            u8,
            result.stderr,
            "--source-map cannot be combined with --optimize",
        ) != null);
        const retained = try tmp.dir.readFileAlloc(allocator, "output.css", 1024);
        defer allocator.free(retained);
        try std.testing.expectEqualStrings("sentinel", retained);
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
        child.stderr_behavior = .Pipe;
        const cwd = try configurePortableWatchChildCwd(&child, &tmp);
        defer allocator.free(cwd);
        try child.spawn();
        var running = true;
        defer {
            if (running) _ = terminateWatchChild(&child) catch {};
        }

        var captured = child.stderr.?;
        child.stderr = null;
        defer captured.close();
        var stage: NativeWatchCaseStage = .@"initial-output";
        var observed_termination: ?WatchChildTermination = null;
        errdefer |err| settleNativeWatchFailure(
            &child,
            &running,
            &captured,
            case.syntax,
            stage,
            err,
            observed_termination,
        );

        _ = try waitForOutputContents(tmp.dir, "output.css", case.watch_expected_before);
        stage = .@"dependency-replace";
        try replaceFileAtomically(
            tmp.dir,
            case.watch_dependency,
            case.watch_dependency_after,
        );
        stage = .@"changed-output";
        const changed = try waitForOutputContents(
            tmp.dir,
            "output.css",
            case.watch_expected_after,
        );
        std.Thread.sleep(1200 * std.time.ns_per_ms);
        stage = .@"stability-observation";
        try std.testing.expect(changed.eql(try waitForOutputStamp(tmp.dir, "output.css")));

        stage = .@"child-termination";
        const termination = try terminateWatchChild(&child);
        observed_termination = termination;
        running = false;
        if (termination == .@"already-terminated") return error.WatchChildExited;
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
        "--optimize",
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

    var argv: [native_parallel_queued_case_count + 11][]const u8 = undefined;
    for (input_names, 0..) |name, index| argv[index] = name;
    argv[native_parallel_queued_case_count..].* = .{
        "-o",
        "out",
        "--output-dir",
        "--experimental-native",
        "--syntax",
        "scss",
        "--optimize",
        "--autoprefix",
        "--browsers",
        legacy_browsers,
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
        "--optimize",
        "--autoprefix",
        "--browsers",
        legacy_browsers,
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
