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

    // Zig 0.15.2 does not implement Child.cwd_dir on Windows. Resolve the
    // already-confined test directory so every host exercises the same cwd.
    const cwd = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    return Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
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
    const cwd = if (cwd_dir) |dir| try dir.realpathAlloc(allocator, ".") else null;
    defer if (cwd) |path| allocator.free(path);
    child.cwd = cwd;
    try child.spawn();
    errdefer _ = child.kill() catch {};

    child.stdin.?.writeAll(input) catch |err| switch (err) {
        // Argument-validation failures may close stdin before the parent
        // finishes its fixture write. The child result owns that contract.
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
    if (succeeded(result.term) or std.mem.indexOf(u8, result.stderr, expected) == null) {
        std.debug.print(
            "unexpected child result while requiring stderr fragment '{s}'\nstdout: {s}\nstderr: {s}\n",
            .{ expected, result.stdout, result.stderr },
        );
    }
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

fn appendLspFrame(output: *std.ArrayList(u8), body: []const u8) !void {
    try output.writer(allocator).print("Content-Length: {d}\r\n\r\n", .{body.len});
    try output.appendSlice(allocator, body);
}

fn nextLspFrame(bytes: []const u8, offset: *usize) ![]const u8 {
    const header_end = std.mem.indexOfPos(u8, bytes, offset.*, "\r\n\r\n") orelse
        return error.MissingLspHeaderTerminator;
    const prefix = "Content-Length: ";
    const header = bytes[offset.*..header_end];
    if (!std.mem.startsWith(u8, header, prefix)) return error.MissingLspContentLength;
    const content_length = try std.fmt.parseInt(usize, header[prefix.len..], 10);
    const body_start = header_end + "\r\n\r\n".len;
    const body_end = std.math.add(usize, body_start, content_length) catch
        return error.InvalidLspContentLength;
    if (body_end > bytes.len) return error.TruncatedLspFrame;
    offset.* = body_end;
    return bytes[body_start..body_end];
}

fn stringifyJson(value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.write(value);
    return try output.toOwnedSlice();
}

fn profileMetric(report: []const u8, label: []const u8) !u64 {
    const label_start = std.mem.indexOf(u8, report, label) orelse return error.MissingProfileMetric;
    const value_start = label_start + label.len;
    const relative_end = std.mem.indexOfScalar(u8, report[value_start..], '\n') orelse
        return error.UnterminatedProfileMetric;
    return std.fmt.parseInt(u64, report[value_start .. value_start + relative_end], 10);
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

test "LSP transport accepts sequential frames and bodies above 8 KiB (LSP-001)" {
    var initialize = std.ArrayList(u8).empty;
    defer initialize.deinit(allocator);
    try initialize.appendSlice(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file:///",
    );
    try initialize.appendNTimes(allocator, 'a', 9 * 1024);
    try initialize.appendSlice(allocator, "\",\"capabilities\":{}}}");
    try std.testing.expect(initialize.items.len > 8192);

    const second = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"unknown/method\",\"params\":{}}";
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    try appendLspFrame(&transcript, initialize.items);
    try appendLspFrame(&transcript, second);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectSuccess(result);

    var offset: usize = 0;
    const initialize_response = try nextLspFrame(result.stdout, &offset);
    const second_response = try nextLspFrame(result.stdout, &offset);
    try std.testing.expectEqual(result.stdout.len, offset);
    try std.testing.expect(std.mem.indexOf(u8, initialize_response, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, initialize_response, "\"capabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_response, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_response, "\"code\":-32601") != null);
}

test "LSP returns parse errors and continues with the next frame (LSP-002)" {
    const initialize =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}";
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    try appendLspFrame(&transcript, "{not-json");
    try appendLspFrame(&transcript, initialize);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectSuccess(result);

    var offset: usize = 0;
    const parse_error_body = try nextLspFrame(result.stdout, &offset);
    const initialize_body = try nextLspFrame(result.stdout, &offset);
    try std.testing.expectEqual(result.stdout.len, offset);

    var parse_error = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        parse_error_body,
        .{},
    );
    defer parse_error.deinit();
    try std.testing.expect(parse_error.value.object.get("id").? == .null);
    try std.testing.expectEqual(
        @as(i64, -32700),
        parse_error.value.object.get("error").?.object.get("code").?.integer,
    );

    var initialized = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        initialize_body,
        .{},
    );
    defer initialized.deinit();
    try std.testing.expectEqual(@as(i64, 1), initialized.value.object.get("id").?.integer);
    try std.testing.expect(initialized.value.object.get("result") != null);
}

test "LSP serializes hostile IDs and returns invalid-params errors (LSP-002)" {
    const escaped_id = "line\n\"\\id";
    const initialize =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}";
    const unknown =
        "{\"jsonrpc\":\"2.0\",\"id\":\"line\\n\\\"\\\\id\",\"method\":\"unknown/method\",\"params\":{}}";
    const invalid_params =
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":[]}";
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    try appendLspFrame(&transcript, initialize);
    try appendLspFrame(&transcript, unknown);
    try appendLspFrame(&transcript, invalid_params);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectSuccess(result);

    var offset: usize = 0;
    const initialize_body = try nextLspFrame(result.stdout, &offset);
    const unknown_body = try nextLspFrame(result.stdout, &offset);
    const invalid_params_body = try nextLspFrame(result.stdout, &offset);
    try std.testing.expectEqual(result.stdout.len, offset);

    var initialized = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        initialize_body,
        .{},
    );
    defer initialized.deinit();
    try std.testing.expectEqual(@as(i64, 1), initialized.value.object.get("id").?.integer);
    try std.testing.expect(initialized.value.object.get("result") != null);

    var unknown_response = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        unknown_body,
        .{},
    );
    defer unknown_response.deinit();
    try std.testing.expectEqualStrings(
        escaped_id,
        unknown_response.value.object.get("id").?.string,
    );
    try std.testing.expectEqual(
        @as(i64, -32601),
        unknown_response.value.object.get("error").?.object.get("code").?.integer,
    );

    var invalid_response = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        invalid_params_body,
        .{},
    );
    defer invalid_response.deinit();
    try std.testing.expectEqual(@as(i64, 3), invalid_response.value.object.get("id").?.integer);
    try std.testing.expectEqual(
        @as(i64, -32602),
        invalid_response.value.object.get("error").?.object.get("code").?.integer,
    );
}

test "LSP notifications and lifecycle follow the shutdown protocol (LSP-003)" {
    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"unknown/beforeInitialize\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///lifecycle.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".a{}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///lifecycle.css\",\"version\":2},\"contentChanges\":[{\"text\":\".b{}\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":99}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///lifecycle.css\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    };
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    for (messages) |message| try appendLspFrame(&transcript, message);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectExitCode(result, 0);

    const expected_ids = [_]i64{ 0, 1, 11, 2, 3 };
    const expected_errors = [_]?i64{ -32002, null, -32600, null, -32600 };
    var offset: usize = 0;
    for (expected_ids, expected_errors) |expected_id, expected_error| {
        const body = try nextLspFrame(result.stdout, &offset);
        var response = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer response.deinit();
        const response_id = response.value.object.get("id").?;
        try std.testing.expect(response_id == .integer);
        try std.testing.expectEqual(expected_id, response_id.integer);
        if (expected_error) |code| {
            try std.testing.expectEqual(
                code,
                response.value.object.get("error").?.object.get("code").?.integer,
            );
            try std.testing.expect(response.value.object.get("result") == null);
        } else if (expected_id == 2) {
            try std.testing.expect(response.value.object.get("result").? == .null);
            try std.testing.expect(response.value.object.get("error") == null);
        } else {
            try std.testing.expect(response.value.object.get("result") != null);
            try std.testing.expect(response.value.object.get("error") == null);
        }
    }
    try std.testing.expectEqual(result.stdout.len, offset);
}

test "LSP exit without shutdown returns failure without a response (LSP-003)" {
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    try appendLspFrame(&transcript, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectExitCode(result, 1);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "LSP executable converts non-BMP byte spans to UTF-16 positions (LSP-004)" {
    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\",\"languageId\":\"css\",\"version\":1,\"text\":\"😀:root{--foo:red}\\r\\nα .x{color:var(--foo)}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":1,\"character\":17}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    };
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    for (messages) |message| try appendLspFrame(&transcript, message);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectExitCode(result, 0);

    var offset: usize = 0;
    const initialize_body = try nextLspFrame(result.stdout, &offset);
    const definition_body = try nextLspFrame(result.stdout, &offset);
    const shutdown_body = try nextLspFrame(result.stdout, &offset);
    try std.testing.expectEqual(result.stdout.len, offset);

    var initialized = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        initialize_body,
        .{},
    );
    defer initialized.deinit();
    try std.testing.expectEqualStrings(
        "utf-16",
        initialized.value.object
            .get("result").?.object
            .get("capabilities").?.object
            .get("positionEncoding").?.string,
    );

    var definition = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        definition_body,
        .{},
    );
    defer definition.deinit();
    const range = definition.value.object
        .get("result").?.array.items[0].object
        .get("range").?.object;
    const start = range.get("start").?.object;
    const end = range.get("end").?.object;
    try std.testing.expectEqual(@as(i64, 0), start.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 8), start.get("character").?.integer);
    try std.testing.expectEqual(@as(i64, 0), end.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 13), end.get("character").?.integer);

    var shutdown = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        shutdown_body,
        .{},
    );
    defer shutdown.deinit();
    try std.testing.expect(shutdown.value.object.get("result").? == .null);
}

test "LSP executable returns full recoverable compiler diagnostics (LSP-005)" {
    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///recover.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".a{broken; color:\\\"oops\\n} .b{also}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///recover.css\"},\"identifier\":\"zigcss\",\"previousResultId\":\"old\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    };
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    for (messages) |message| try appendLspFrame(&transcript, message);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectExitCode(result, 0);

    var offset: usize = 0;
    const initialize_body = try nextLspFrame(result.stdout, &offset);
    const diagnostic_body = try nextLspFrame(result.stdout, &offset);
    const shutdown_body = try nextLspFrame(result.stdout, &offset);
    try std.testing.expectEqual(result.stdout.len, offset);

    var initialized = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        initialize_body,
        .{},
    );
    defer initialized.deinit();
    const provider = initialized.value.object
        .get("result").?.object
        .get("capabilities").?.object
        .get("diagnosticProvider").?.object;
    try std.testing.expectEqualStrings("zigcss", provider.get("identifier").?.string);
    try std.testing.expect(!provider.get("interFileDependencies").?.bool);
    try std.testing.expect(!provider.get("workspaceDiagnostics").?.bool);

    var diagnostics = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        diagnostic_body,
        .{},
    );
    defer diagnostics.deinit();
    const report = diagnostics.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("full", report.get("kind").?.string);
    const items = report.get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    const expected_codes = [_][]const u8{ "CSS0005", "CSS0007", "CSS0007" };
    for (items, expected_codes) |item_value, expected_code| {
        const item = item_value.object;
        try std.testing.expectEqualStrings(expected_code, item.get("code").?.string);
        try std.testing.expectEqualStrings("zigcss", item.get("source").?.string);
        try std.testing.expectEqual(@as(i64, 1), item.get("severity").?.integer);
    }
    const first_range = items[0].object.get("range").?.object;
    const first_start = first_range.get("start").?.object;
    const first_end = first_range.get("end").?.object;
    try std.testing.expectEqual(@as(i64, 0), first_start.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 17), first_start.get("character").?.integer);
    try std.testing.expectEqual(@as(i64, 0), first_end.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 22), first_end.get("character").?.integer);

    var shutdown = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        shutdown_body,
        .{},
    );
    defer shutdown.deinit();
    try std.testing.expect(shutdown.value.object.get("result").? == .null);
}

test "LSP executable serves syntax-aware deterministic workspace features (LSP-006)" {
    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///","capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.css","languageId":"css","version":1,"text":".hero { color: var(--theme); animation-name: pulse; }\n.card { color: blue; }\n/* --theme pulse */"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.css","languageId":"css","version":1,"text":":root { --theme: red; }\n.card { color: var(--theme); content: \"--theme\"; }\n@keyframes pulse { from { opacity: 0; } to { opacity: 1; } }\n.new { ba }\n/* --theme */"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":10}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":3,"character":9}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///a.css"}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"workspace/symbol","params":{"query":"CaRd"}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"context":{"includeDeclaration":false}}}
        ,
        \\{"jsonrpc":"2.0","id":8,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"newName":"--next"}}
        ,
        \\{"jsonrpc":"2.0","id":9,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    for (messages) |message| try appendLspFrame(&transcript, message);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectExitCode(result, 0);

    var offset: usize = 0;
    const initialize_body = try nextLspFrame(result.stdout, &offset);
    const hover_body = try nextLspFrame(result.stdout, &offset);
    const completion_body = try nextLspFrame(result.stdout, &offset);
    const document_symbols_body = try nextLspFrame(result.stdout, &offset);
    const workspace_symbols_body = try nextLspFrame(result.stdout, &offset);
    const definition_body = try nextLspFrame(result.stdout, &offset);
    const references_body = try nextLspFrame(result.stdout, &offset);
    const rename_body = try nextLspFrame(result.stdout, &offset);
    const shutdown_body = try nextLspFrame(result.stdout, &offset);
    try std.testing.expectEqual(result.stdout.len, offset);

    var initialized = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        initialize_body,
        .{},
    );
    defer initialized.deinit();
    const capabilities = initialized.value.object
        .get("result").?.object
        .get("capabilities").?.object;
    try std.testing.expect(capabilities.get("hoverProvider").?.bool);
    try std.testing.expect(capabilities.get("completionProvider").? == .object);
    try std.testing.expect(capabilities.get("documentSymbolProvider").?.bool);
    try std.testing.expect(capabilities.get("workspaceSymbolProvider").?.bool);
    try std.testing.expect(capabilities.get("definitionProvider").?.bool);
    try std.testing.expect(capabilities.get("referencesProvider").?.bool);
    try std.testing.expect(capabilities.get("renameProvider").?.bool);

    var hover = try std.json.parseFromSlice(std.json.Value, allocator, hover_body, .{});
    defer hover.deinit();
    const hover_result = hover.value.object.get("result").?.object;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            hover_result.get("contents").?.object.get("value").?.string,
            "Sets the text color",
        ) != null,
    );

    var completion = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        completion_body,
        .{},
    );
    defer completion.deinit();
    const completion_items = completion.value.object
        .get("result").?.object
        .get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), completion_items.len);
    try std.testing.expectEqualStrings(
        "background-color",
        completion_items[0].object.get("label").?.string,
    );

    var document_symbols = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        document_symbols_body,
        .{},
    );
    defer document_symbols.deinit();
    const document_items = document_symbols.value.object.get("result").?.array.items;
    const expected_names = [_][]const u8{ "--theme", "card", "pulse", "new" };
    try std.testing.expectEqual(expected_names.len, document_items.len);
    for (document_items, expected_names) |item, expected_name| {
        try std.testing.expectEqualStrings(expected_name, item.object.get("name").?.string);
    }

    var workspace_symbols = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        workspace_symbols_body,
        .{},
    );
    defer workspace_symbols.deinit();
    const workspace_items = workspace_symbols.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), workspace_items.len);
    try std.testing.expectEqualStrings(
        "file:///a.css",
        workspace_items[0].object.get("location").?.object.get("uri").?.string,
    );
    try std.testing.expectEqualStrings(
        "file:///b.css",
        workspace_items[1].object.get("location").?.object.get("uri").?.string,
    );

    var definition = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        definition_body,
        .{},
    );
    defer definition.deinit();
    const definitions = definition.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings(
        "file:///a.css",
        definitions[0].object.get("uri").?.string,
    );

    var references = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        references_body,
        .{},
    );
    defer references.deinit();
    const reference_items = references.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), reference_items.len);
    try std.testing.expectEqualStrings(
        "file:///a.css",
        reference_items[0].object.get("uri").?.string,
    );
    try std.testing.expectEqualStrings(
        "file:///b.css",
        reference_items[1].object.get("uri").?.string,
    );

    var rename = try std.json.parseFromSlice(std.json.Value, allocator, rename_body, .{});
    defer rename.deinit();
    const changes = rename.value.object.get("result").?.object.get("changes").?.object;
    const a_edits = changes.get("file:///a.css").?.array.items;
    const b_edits = changes.get("file:///b.css").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), a_edits.len);
    try std.testing.expectEqual(@as(usize, 1), b_edits.len);
    for (a_edits) |edit| {
        try std.testing.expectEqualStrings("--next", edit.object.get("newText").?.string);
    }
    try std.testing.expectEqualStrings(
        "--next",
        b_edits[0].object.get("newText").?.string,
    );

    var shutdown = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        shutdown_body,
        .{},
    );
    defer shutdown.deinit();
    try std.testing.expect(shutdown.value.object.get("result").? == .null);
}

test "LSP executable survives large Unicode and malformed protocol transcript (LSP-007)" {
    var large_text = std.ArrayList(u8).empty;
    defer large_text.deinit(allocator);
    try large_text.appendSlice(allocator, "/*");
    try large_text.appendNTimes(allocator, 'x', 1024 * 1024);
    try large_text.appendSlice(
        allocator,
        "*/\n😀:root{--色:red}\r\n.使用{color:var(--色)}",
    );

    const open_body = try stringifyJson(.{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = .{ .textDocument = .{
            .uri = "file:///large-unicode.css",
            .languageId = "css",
            .version = @as(i32, 1),
            .text = large_text.items,
        } },
    });
    defer allocator.free(open_body);
    try std.testing.expect(open_body.len > 1024 * 1024);

    const messages = [_][]const u8{
        "{not-json",
        "[]",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
        open_body,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///large-unicode.css\"},\"position\":{\"line\":2,\"character\":15}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///large-unicode.css\"},\"position\":{\"line\":2,\"character\":5}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///large-unicode.css\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///large-unicode.css\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///large-unicode.css\"},\"position\":{\"line\":2,\"character\":15}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    };
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    for (messages) |message| try appendLspFrame(&transcript, message);

    var result = try runWithStdin(&.{"--lsp"}, transcript.items);
    defer deinitRun(&result);
    try expectExitCode(result, 0);

    var offset: usize = 0;
    const parse_error_body = try nextLspFrame(result.stdout, &offset);
    const invalid_request_body = try nextLspFrame(result.stdout, &offset);
    const initialize_body = try nextLspFrame(result.stdout, &offset);
    const definition_body = try nextLspFrame(result.stdout, &offset);
    const hover_body = try nextLspFrame(result.stdout, &offset);
    const diagnostic_body = try nextLspFrame(result.stdout, &offset);
    const closed_body = try nextLspFrame(result.stdout, &offset);
    const shutdown_body = try nextLspFrame(result.stdout, &offset);
    try std.testing.expectEqual(result.stdout.len, offset);
    try std.testing.expect(result.stdout.len < 64 * 1024);

    var parse_error = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        parse_error_body,
        .{},
    );
    defer parse_error.deinit();
    try std.testing.expect(parse_error.value.object.get("id").? == .null);
    try std.testing.expectEqual(
        @as(i64, -32700),
        parse_error.value.object.get("error").?.object.get("code").?.integer,
    );

    var invalid_request = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        invalid_request_body,
        .{},
    );
    defer invalid_request.deinit();
    try std.testing.expectEqual(
        @as(i64, -32600),
        invalid_request.value.object.get("error").?.object.get("code").?.integer,
    );

    var initialized = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        initialize_body,
        .{},
    );
    defer initialized.deinit();
    try std.testing.expectEqual(@as(i64, 1), initialized.value.object.get("id").?.integer);

    var definition = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        definition_body,
        .{},
    );
    defer definition.deinit();
    const definitions = definition.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings(
        "file:///large-unicode.css",
        definitions[0].object.get("uri").?.string,
    );
    const definition_range = definitions[0].object.get("range").?.object;
    try std.testing.expectEqual(
        @as(i64, 1),
        definition_range.get("start").?.object.get("line").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 8),
        definition_range.get("start").?.object.get("character").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 11),
        definition_range.get("end").?.object.get("character").?.integer,
    );

    var hover = try std.json.parseFromSlice(std.json.Value, allocator, hover_body, .{});
    defer hover.deinit();
    const hover_range = hover.value.object.get("result").?.object.get("range").?.object;
    try std.testing.expectEqual(
        @as(i64, 2),
        hover_range.get("start").?.object.get("line").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 4),
        hover_range.get("start").?.object.get("character").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 9),
        hover_range.get("end").?.object.get("character").?.integer,
    );

    var diagnostic = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        diagnostic_body,
        .{},
    );
    defer diagnostic.deinit();
    const report = diagnostic.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("full", report.get("kind").?.string);
    try std.testing.expectEqual(
        @as(usize, 0),
        report.get("items").?.array.items.len,
    );

    var closed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        closed_body,
        .{},
    );
    defer closed.deinit();
    try std.testing.expectEqual(
        @as(i64, -32602),
        closed.value.object.get("error").?.object.get("code").?.integer,
    );

    var shutdown = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        shutdown_body,
        .{},
    );
    defer shutdown.deinit();
    try std.testing.expect(shutdown.value.object.get("result").? == .null);
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

test "profiling lifecycle reports measured API stages and allocator bytes once (PROF-010)" {
    var result = try runCompiler(@embedFile("fixtures/simple.css"), &.{ "--profile", "--optimize", "--minify" });
    defer deinitRun(&result);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(".simple{color:red}", result.stdout);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result.stderr, "=== Performance Profile ==="));
    const total = try profileMetric(result.stderr, "  total_time_ns: ");
    const parse = try profileMetric(result.stderr, "  parse_time_ns: ");
    const validation = try profileMetric(result.stderr, "  validation_time_ns: ");
    const dependencies = try profileMetric(result.stderr, "  dependency_time_ns: ");
    const optimize = try profileMetric(result.stderr, "  optimize_time_ns: ");
    const transform = try profileMetric(result.stderr, "  transform_time_ns: ");
    const emit = try profileMetric(result.stderr, "  emit_time_ns: ");
    const promoted = try profileMetric(result.stderr, "  result_time_ns: ");
    const cleanup = try profileMetric(result.stderr, "  cleanup_time_ns: ");
    try std.testing.expect(parse > 0);
    try std.testing.expect(optimize > 0);
    try std.testing.expectEqual(@as(u64, 0), transform);
    try std.testing.expect(total >= parse + validation + dependencies + optimize + transform + emit + promoted + cleanup);

    const allocated = try profileMetric(result.stderr, "  total_allocated_bytes: ");
    const freed = try profileMetric(result.stderr, "  total_freed_bytes: ");
    const peak = try profileMetric(result.stderr, "  peak_live_bytes: ");
    const retained = try profileMetric(result.stderr, "  retained_result_bytes: ");
    const allocations = try profileMetric(result.stderr, "  allocation_count: ");
    const deallocations = try profileMetric(result.stderr, "  deallocation_count: ");
    _ = try profileMetric(result.stderr, "  resize_count: ");
    try std.testing.expect(allocated > freed);
    try std.testing.expectEqual(retained, allocated - freed);
    try std.testing.expect(peak >= retained);
    try std.testing.expect(retained >= result.stdout.len);
    try std.testing.expect(allocations > deallocations);

    var invalid = try runCompiler(".a{broken}", &.{ "--profile", "--minify" });
    defer deinitRun(&invalid);
    try expectFailureContaining(invalid, "error CSS0007");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(invalid.stderr, "=== Performance Profile ==="));
    try std.testing.expect((try profileMetric(invalid.stderr, "  retained_result_bytes: ")) > 0);
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
    try std.testing.expectEqualStrings("zigcss 0.6.0-rc.2\n", version.stdout);
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
    try expectFailureContaining(write_failure, "failed to write blocked-output atomically");
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

    var unsupported = try runCompiler(input, &.{ "--syntax", "scss-next" });
    defer deinitRun(&unsupported);
    try expectExitCode(unsupported, 2);
    try std.testing.expect(std.mem.indexOf(u8, unsupported.stderr, "unsupported syntax: scss-next") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, stream.stderr, "experimental release candidate") != null);

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
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    child.cwd = cwd;
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
    try std.testing.expect(std.mem.indexOf(u8, compile.stderr, "experimental release candidate") != null);
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
