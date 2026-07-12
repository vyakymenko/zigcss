const std = @import("std");
const builtin = @import("builtin");
const zigcss = @import("zigcss");
const profiler = @import("profiler.zig");
const lsp = @import("lsp.zig");

const version = "0.3.0";
const experimental_notice = "Warning: ZigCSS 0.3 is an experimental recovery build; do not use it for production CSS.\n";
const unsafe_transforms_message = "legacy and non-verified transform paths are disabled pending safety validation";
const max_input_bytes = 10 * 1024 * 1024;
const stdin_source_name = "<stdin>";
const stdio_path = "-";
const exit_compile_failure: u8 = 1;
const exit_usage: u8 = 2;

const CompileConfig = struct {
    input_file: []const u8,
    output_file: ?[]const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
    profile: bool = false,
};

const CompileTask = struct {
    input_file: []const u8,
    output_file: []const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
    result: ?zigcss.CompileResult = null,
    err: ?[]const u8 = null,
    err_owned: bool = false,
};

fn setTaskError(
    task: *CompileTask,
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
    fallback: []const u8,
) void {
    task.err = std.fmt.allocPrint(allocator, format, args) catch {
        task.err = fallback;
        task.err_owned = false;
        return;
    };
    task.err_owned = true;
}

fn compileCss(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    input: []const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
) zigcss.CompileError!zigcss.CompileResult {
    return zigcss.compile(
        allocator,
        source_name,
        input,
        .{
            .syntax = syntax,
            .format = if (minify) .minified else .pretty,
            .transforms = .{ .optimize = optimize },
        },
    );
}

fn hasErrorDiagnostics(diagnostics: []const zigcss.Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

fn severityLabel(severity: zigcss.DiagnosticSeverity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

fn printDiagnostics(diagnostics: []const zigcss.Diagnostic) void {
    for (diagnostics) |diagnostic| {
        std.debug.print(
            "{s}:{d}:{d}: {s} {s}: {s}\n",
            .{
                diagnostic.source_name,
                diagnostic.start.line,
                diagnostic.start.column,
                severityLabel(diagnostic.severity),
                diagnostic.code.label(),
                diagnostic.message,
            },
        );
    }
}

fn isStdioPath(path: []const u8) bool {
    return std.mem.eql(u8, path, stdio_path);
}

fn inputDisplayName(path: []const u8) []const u8 {
    return if (isStdioPath(path)) stdin_source_name else path;
}

fn readInput(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (isStdioPath(path)) {
        return std.fs.File.stdin().readToEndAlloc(allocator, max_input_bytes);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, max_input_bytes);
}

fn writeStdout(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeOutputFile(path: []const u8, bytes: []const u8) !void {
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes }) catch |err| {
        std.debug.print("Error: failed to write {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

fn compileFile(allocator: std.mem.Allocator, config: CompileConfig) !void {
    var perf_profiler = try profiler.Profiler.init(allocator, config.profile);
    defer perf_profiler.deinit();

    const input = readInput(allocator, config.input_file) catch |err| {
        std.debug.print("Error: failed to read {s}: {s}\n", .{ inputDisplayName(config.input_file), @errorName(err) });
        return err;
    };
    defer allocator.free(input);

    var compile_timing = try perf_profiler.startTiming("compile");
    defer compile_timing.end() catch {};
    var result = compileCss(
        allocator,
        inputDisplayName(config.input_file),
        input,
        config.syntax,
        config.optimize,
        config.minify,
    ) catch |err| {
        std.debug.print("Error: CSS compilation failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer result.deinit();
    try compile_timing.end();

    if (hasErrorDiagnostics(result.diagnostics)) {
        printDiagnostics(result.diagnostics);
        return error.CompileError;
    }

    if (config.output_file) |out| {
        if (isStdioPath(out)) {
            writeStdout(result.css) catch |err| {
                std.debug.print("Error: failed to write stdout: {s}\n", .{@errorName(err)});
                return err;
            };
        } else {
            try writeOutputFile(out, result.css);
            std.debug.print("Compiled: {s} -> {s}\n", .{ config.input_file, out });
        }
    } else {
        writeStdout(result.css) catch |err| {
            std.debug.print("Error: failed to write stdout: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    if (config.profile) {
        perf_profiler.printReport();
    }
}

fn computeFileHash(content: []const u8) u64 {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(content);
    return hasher.final();
}

fn watchFile(allocator: std.mem.Allocator, config: CompileConfig) !void {
    std.debug.print("Watching {s} for changes... (Press Ctrl+C to stop)\n", .{config.input_file});
    
    const cwd = std.fs.cwd();
    
    var last_hash: ?u64 = null;
    var first_compile = true;
    
    while (true) {
        const input = cwd.readFileAlloc(allocator, config.input_file, max_input_bytes) catch |err| {
            std.debug.print("Error reading file: {}\n", .{err});
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(input);
        
        const current_hash = computeFileHash(input);
        
        if (first_compile or last_hash == null or current_hash != last_hash.?) {
            if (!first_compile) {
                std.debug.print("File changed, recompiling...\n", .{});
            }
            
            const temp_config = CompileConfig{
                .input_file = config.input_file,
                .output_file = config.output_file,
                .syntax = config.syntax,
                .optimize = config.optimize,
                .minify = config.minify,
                .profile = config.profile,
            };
            
            compileFile(allocator, temp_config) catch |err| {
                std.debug.print("Compilation error: {}\n", .{err});
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            };
            
            last_hash = current_hash;
            first_compile = false;
        }
        
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn compileTask(task: *CompileTask, allocator: std.mem.Allocator) void {
    const input = std.fs.cwd().readFileAlloc(allocator, task.input_file, max_input_bytes) catch |err| {
        setTaskError(task, allocator, "Failed to read {s}: {s}", .{ task.input_file, @errorName(err) }, "Read error");
        return;
    };
    defer allocator.free(input);

    var result = compileCss(
        allocator,
        task.input_file,
        input,
        task.syntax,
        task.optimize,
        task.minify,
    ) catch |err| {
        setTaskError(task, allocator, "Compilation error: {s}", .{@errorName(err)}, "Compilation error");
        return;
    };
    task.result = result.take();
    result.deinit();
}

fn taskFailed(task: *const CompileTask) bool {
    if (task.err != null or task.result == null) return true;
    return hasErrorDiagnostics(task.result.?.diagnostics);
}

fn printTaskFailure(task: *const CompileTask) void {
    if (task.err) |err| {
        std.debug.print("Error compiling {s}: {s}\n", .{ task.input_file, err });
        return;
    }
    if (task.result != null and hasErrorDiagnostics(task.result.?.diagnostics)) {
        printDiagnostics(task.result.?.diagnostics);
    }
}

fn compileFilesParallel(allocator: std.mem.Allocator, tasks: []CompileTask) !void {
    const num_threads = @min(tasks.len, std.Thread.getCpuCount() catch 4);
    
    if (tasks.len == 1) {
        compileTask(&tasks[0], allocator);
        if (taskFailed(&tasks[0])) {
            printTaskFailure(&tasks[0]);
            return error.CompileError;
        }
        try writeOutputFile(tasks[0].output_file, tasks[0].result.?.css);
        std.debug.print("Compiled: {s} -> {s}\n", .{ tasks[0].input_file, tasks[0].output_file });
        return;
    }

    var threads = try std.ArrayList(std.Thread).initCapacity(allocator, num_threads);
    defer threads.deinit(allocator);
    
    var mutex = std.Thread.Mutex{};
    var completed: usize = 0;
    var has_error = false;

    const batch_size = (tasks.len + num_threads - 1) / num_threads;
    var thread_idx: usize = 0;
    
    while (thread_idx < num_threads) : (thread_idx += 1) {
        const start = thread_idx * batch_size;
        const end = @min(start + batch_size, tasks.len);
        
        if (start >= tasks.len) break;
        
        const thread = try std.Thread.spawn(.{}, struct {
            fn worker(tasks_slice: []CompileTask, alloc: std.mem.Allocator, mtx: *std.Thread.Mutex, done: *usize, err: *bool) void {
                for (tasks_slice) |*task| {
                    compileTask(task, alloc);
                    
                    mtx.lock();
                    done.* += 1;
                    if (taskFailed(task)) err.* = true;
                    mtx.unlock();
                }
            }
        }.worker, .{ tasks[start..end], allocator, &mutex, &completed, &has_error });
        
        try threads.append(allocator, thread);
    }

    for (threads.items) |thread| {
        thread.join();
    }

    if (has_error) {
        for (tasks) |*task| {
            if (taskFailed(task)) printTaskFailure(task);
        }
        return error.CompileError;
    }

    for (tasks) |*task| {
        try writeOutputFile(task.output_file, task.result.?.css);
        std.debug.print("Compiled: {s} -> {s}\n", .{ task.input_file, task.output_file });
    }
}

const CompileError = error{CompileError};

fn runLspServer(allocator: std.mem.Allocator) !void {
    var server = lsp.LspServer.init(allocator);
    defer server.deinit();
    
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    
    var buffer: [8192]u8 = undefined;
    
    while (true) {
        const content_length_line = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        
        if (content_length_line.len == 0) {
            continue;
        }
        
        if (!std.mem.startsWith(u8, content_length_line, "Content-Length: ")) {
            continue;
        }
        
        const length_str = content_length_line["Content-Length: ".len..];
        const content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, length_str, " \r"), 10);
        
        _ = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        
        if (content_length > buffer.len) {
            return error.BufferTooSmall;
        }
        
        var total_read: usize = 0;
        while (total_read < content_length) {
            const bytes_read = try stdin_reader.interface.readSliceShort(buffer[total_read..content_length]);
            total_read += bytes_read;
        }
        const request = buffer[0..total_read];
        const response = try server.handleRequest(request);
        defer allocator.free(response);
        
        try stdout_writer.interface.print("Content-Length: {}\r\n\r\n{s}", .{ response.len, response });
        try stdout_writer.interface.flush();
    }
}

fn expandGlob(allocator: std.mem.Allocator, pattern: []const u8) !std.ArrayList([]const u8) {
    var files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    
    if (std.mem.indexOf(u8, pattern, "*") == null) {
        const pattern_copy = try allocator.dupe(u8, pattern);
        try files.append(allocator, pattern_copy);
        return files;
    }

    const cwd = std.fs.cwd();
    const dir_path = std.fs.path.dirname(pattern) orelse ".";
    const basename_pattern = std.fs.path.basename(pattern);
    
    var dir = try cwd.openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (matchPattern(basename_pattern, entry.name)) {
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try files.append(allocator, full_path);
        }
    }
    
    return files;
}

fn matchPattern(pattern: []const u8, name: []const u8) bool {
    var pattern_idx: usize = 0;
    var name_idx: usize = 0;
    
    while (pattern_idx < pattern.len and name_idx < name.len) {
        if (pattern[pattern_idx] == '*') {
            pattern_idx += 1;
            if (pattern_idx >= pattern.len) return true;
            while (name_idx < name.len) {
                if (matchPattern(pattern[pattern_idx..], name[name_idx..])) {
                    return true;
                }
                name_idx += 1;
            }
            return false;
        } else if (pattern[pattern_idx] == name[name_idx]) {
            pattern_idx += 1;
            name_idx += 1;
        } else {
            return false;
        }
    }
    
    return pattern_idx >= pattern.len and name_idx >= name.len;
}

const PathIdentity = struct {
    normalized: []u8,
    inode: ?std.fs.File.INode,

    fn deinit(self: *PathIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized);
    }
};

const OutputCollision = struct {
    kind: enum {
        output_is_input,
        duplicate_output,
    },
    path: []const u8,
};

fn canonicalizeAbsolutePath(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, absolute_path) catch |err| {
        if (err != error.FileNotFound and err != error.NotDir) return err;

        const parent = std.fs.path.dirname(absolute_path) orelse return allocator.dupe(u8, absolute_path);
        if (std.mem.eql(u8, parent, absolute_path)) return allocator.dupe(u8, absolute_path);

        const canonical_parent = try canonicalizeAbsolutePath(allocator, parent);
        defer allocator.free(canonical_parent);
        return std.fs.path.join(allocator, &.{ canonical_parent, std.fs.path.basename(absolute_path) });
    };
}

fn identifyPath(allocator: std.mem.Allocator, raw_path: []const u8) !PathIdentity {
    const absolute_path = try std.fs.path.resolve(allocator, &.{raw_path});
    defer allocator.free(absolute_path);

    const inode: ?std.fs.File.INode = blk: {
        const stat = std.fs.cwd().statFile(raw_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => break :blk null,
            else => return err,
        };
        break :blk stat.inode;
    };

    return .{
        .normalized = try canonicalizeAbsolutePath(allocator, absolute_path),
        .inode = inode,
    };
}

fn pathsEquivalent(a: *const PathIdentity, b: *const PathIdentity) bool {
    const normalized_equal = switch (builtin.os.tag) {
        .windows, .macos, .ios, .tvos, .watchos => std.ascii.eqlIgnoreCase(a.normalized, b.normalized),
        else => std.mem.eql(u8, a.normalized, b.normalized),
    };
    if (normalized_equal) return true;

    if (a.inode) |a_inode| {
        if (b.inode) |b_inode| {
            return a_inode != 0 and a_inode == b_inode;
        }
    }
    return false;
}

fn findOutputCollision(allocator: std.mem.Allocator, input_paths: []const []const u8, output_paths: []const []const u8) !?OutputCollision {
    const input_identities = try allocator.alloc(PathIdentity, input_paths.len);
    defer allocator.free(input_identities);
    var initialized_inputs: usize = 0;
    defer for (input_identities[0..initialized_inputs]) |*identity| identity.deinit(allocator);

    for (input_paths, 0..) |input_path, i| {
        input_identities[i] = try identifyPath(allocator, input_path);
        initialized_inputs += 1;
    }

    var output_identities = try std.ArrayList(PathIdentity).initCapacity(allocator, output_paths.len);
    defer {
        for (output_identities.items) |*identity| identity.deinit(allocator);
        output_identities.deinit(allocator);
    }

    for (output_paths) |output_path| {
        var output_identity = try identifyPath(allocator, output_path);
        errdefer output_identity.deinit(allocator);

        for (input_identities) |*input_identity| {
            if (pathsEquivalent(input_identity, &output_identity)) {
                output_identity.deinit(allocator);
                return .{ .kind = .output_is_input, .path = output_path };
            }
        }
        for (output_identities.items) |*prior_output| {
            if (pathsEquivalent(prior_output, &output_identity)) {
                output_identity.deinit(allocator);
                return .{ .kind = .duplicate_output, .path = output_path };
            }
        }

        try output_identities.append(allocator, output_identity);
    }

    return null;
}

fn rejectOutputCollision(collision: OutputCollision) noreturn {
    switch (collision.kind) {
        .output_is_input => std.debug.print("Error: output path resolves to an input: {s}\n", .{collision.path}),
        .duplicate_output => std.debug.print("Error: multiple inputs resolve to the same output: {s}\n", .{collision.path}),
    }
    std.process.exit(exit_usage);
}

fn exitWithCliError(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print("Error: " ++ format ++ "\n", values);
    std.process.exit(exit_usage);
}

fn requireOptionValue(args: []const []const u8, index: usize, option: []const u8) []const u8 {
    if (index + 1 >= args.len) exitWithCliError("{s} requires a value", .{option});
    const value = args[index + 1];
    if (value.len == 0 or (value[0] == '-' and !isStdioPath(value))) {
        exitWithCliError("{s} requires a value", .{option});
    }
    return value;
}

fn printUsage() !void {
    try writeStdout(
        "ZigCSS 0.3 recovery CLI — EXPERIMENTAL, not production-ready\n\n" ++
            "Usage: zigcss <input.css|-> [-o <output.css|->] [options]\n" ++
            "       zigcss <input1.css> <input2.css> ... -o <output-dir> --output-dir [options]\n" ++
            "       zigcss --lsp          Start experimental Language Server Protocol server\n" ++
            "\nAvailable options:\n" ++
            "  -o, --output <path|->    Output file/stdout, or directory with --output-dir\n" ++
            "  --output-dir             Require batch output under the -o directory\n" ++
            "  --syntax <css>           Select CSS input syntax (default: css)\n" ++
            "  --minify                 Emit compact whitespace (independent of --optimize)\n" ++
            "  --optimize               Run the closed verified optimizer preset\n" ++
            "  --watch                  Watch one input file\n" ++
            "  --profile                Time the end-to-end public compile call\n" ++
            "  --lsp                    Start the experimental LSP server\n" ++
            "  -V, --version            Show the package version\n" ++
            "  -h, --help               Show this help\n" ++
            "\nExit status: 0 success/info, 1 compilation or I/O failure, 2 usage error.\n" ++
            "\nUnavailable and rejected during recovery:\n" ++
            "  --source-map, --autoprefix, --browsers, --critical-*\n",
    );
}

fn printVersion() !void {
    var buffer: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "zigcss {s}\n", .{version});
    try writeStdout(rendered);
}

fn determineOutputFile(allocator: std.mem.Allocator, input_file: []const u8, output_dir: ?[]const u8, output_file: ?[]const u8) ![]const u8 {
    if (output_file) |out| {
        return try allocator.dupe(u8, out);
    }
    
    if (output_dir) |dir| {
        const basename = std.fs.path.basename(input_file);
        const ext = std.fs.path.extension(basename);
        const name_without_ext = basename[0..basename.len - ext.len];
        const output_ext = if (std.mem.eql(u8, ext, ".scss") or std.mem.eql(u8, ext, ".sass")) ".css"
            else if (std.mem.eql(u8, ext, ".less")) ".css"
            else if (std.mem.eql(u8, ext, ".styl")) ".css"
            else if (std.mem.eql(u8, ext, ".postcss")) ".css"
            else ext;
        return try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ dir, name_without_ext, output_ext });
    }
    
    const ext = std.fs.path.extension(input_file);
    const name_without_ext = input_file[0..input_file.len - ext.len];
    const output_ext = if (std.mem.eql(u8, ext, ".scss") or std.mem.eql(u8, ext, ".sass")) ".css"
        else if (std.mem.eql(u8, ext, ".less")) ".css"
        else if (std.mem.eql(u8, ext, ".styl")) ".css"
        else if (std.mem.eql(u8, ext, ".postcss")) ".css"
        else ext;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ name_without_ext, output_ext });
}

fn experimentalFormatName(filename: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, filename, ".scss")) return "SCSS";
    if (std.mem.endsWith(u8, filename, ".sass")) return "SASS";
    if (std.mem.endsWith(u8, filename, ".less")) return "LESS";
    if (std.mem.endsWith(u8, filename, ".module.css")) return "CSS Modules";
    if (std.mem.endsWith(u8, filename, ".css.js") or
        std.mem.endsWith(u8, filename, ".css.ts")) return "CSS-in-JS";
    if (std.mem.endsWith(u8, filename, ".postcss")) return "PostCSS";
    if (std.mem.endsWith(u8, filename, ".styl")) return "Stylus";
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) exitWithCliError("no input files specified; use --help for usage", .{});

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        if (args.len != 2) exitWithCliError("--help does not accept additional arguments", .{});
        try printUsage();
        return;
    }
    if (std.mem.eql(u8, args[1], "-V") or std.mem.eql(u8, args[1], "--version")) {
        if (args.len != 2) exitWithCliError("--version does not accept additional arguments", .{});
        try printVersion();
        return;
    }
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--lsp") or std.mem.eql(u8, args[1], "-lsp"))) {
        if (args.len != 2) exitWithCliError("--lsp does not accept additional arguments", .{});
        std.debug.print("{s}", .{experimental_notice});
        try runLspServer(allocator);
        return;
    }

    var input_files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (input_files.items) |path| {
            allocator.free(path);
        }
        input_files.deinit(allocator);
    }
    
    var output_file: ?[]const u8 = null;
    var output_dir_flag = false;
    var syntax: zigcss.Syntax = .css;
    var syntax_flag_set = false;
    var optimize_flag = false;
    var minify_flag = false;
    var watch_flag = false;
    var profile_flag = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (output_file != null) exitWithCliError("{s} may only be specified once", .{args[i]});
            output_file = requireOptionValue(args, i, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir")) {
            if (output_dir_flag) exitWithCliError("--output-dir may only be specified once", .{});
            output_dir_flag = true;
        } else if (std.mem.eql(u8, args[i], "--syntax")) {
            if (syntax_flag_set) exitWithCliError("--syntax may only be specified once", .{});
            const value = requireOptionValue(args, i, args[i]);
            if (!std.mem.eql(u8, value, "css")) exitWithCliError("unsupported syntax: {s}", .{value});
            syntax = .css;
            syntax_flag_set = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--optimize")) {
            if (optimize_flag) exitWithCliError("--optimize may only be specified once", .{});
            optimize_flag = true;
        } else if (std.mem.eql(u8, args[i], "--minify")) {
            if (minify_flag) exitWithCliError("--minify may only be specified once", .{});
            minify_flag = true;
        } else if (std.mem.eql(u8, args[i], "--source-map")) {
            exitWithCliError("--source-map is unavailable until the CLI output policy is defined", .{});
        } else if (std.mem.eql(u8, args[i], "--watch")) {
            if (watch_flag) exitWithCliError("--watch may only be specified once", .{});
            watch_flag = true;
        } else if (std.mem.eql(u8, args[i], "--autoprefix")) {
            exitWithCliError("--autoprefix is unavailable: {s}", .{unsafe_transforms_message});
        } else if (std.mem.eql(u8, args[i], "--profile")) {
            if (profile_flag) exitWithCliError("--profile may only be specified once", .{});
            profile_flag = true;
        } else if (std.mem.eql(u8, args[i], "--browsers")) {
            _ = requireOptionValue(args, i, args[i]);
            exitWithCliError("--browsers is unavailable until target queries and prefix rules are validated", .{});
        } else if (std.mem.eql(u8, args[i], "--critical-classes") or
            std.mem.eql(u8, args[i], "--critical-ids") or
            std.mem.eql(u8, args[i], "--critical-elements"))
        {
            _ = requireOptionValue(args, i, args[i]);
            exitWithCliError("{s} is unavailable in the recovery CLI; conservative extraction remains library/test-driver only", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            exitWithCliError("--help must be used alone", .{});
        } else if (std.mem.eql(u8, args[i], "-V") or std.mem.eql(u8, args[i], "--version")) {
            exitWithCliError("--version must be used alone", .{});
        } else if (isStdioPath(args[i])) {
            const path_copy = try allocator.dupe(u8, args[i]);
            try input_files.append(allocator, path_copy);
        } else if (args[i].len == 0) {
            exitWithCliError("empty arguments are not valid input paths", .{});
        } else if (args[i][0] != '-') {
            var expanded = try expandGlob(allocator, args[i]);
            defer {
                for (expanded.items) |path| {
                    allocator.free(path);
                }
                expanded.deinit(allocator);
            }
            for (expanded.items) |path| {
                const path_copy = try allocator.dupe(u8, path);
                try input_files.append(allocator, path_copy);
            }
        } else {
            exitWithCliError("unknown option: {s}", .{args[i]});
        }
    }

    if (input_files.items.len == 0) exitWithCliError("no input files specified", .{});

    var stdin_inputs: usize = 0;
    for (input_files.items) |input_file| {
        if (isStdioPath(input_file)) stdin_inputs += 1;
    }
    if (stdin_inputs > 1) exitWithCliError("stdin may only be specified once", .{});
    if (stdin_inputs == 1 and input_files.items.len != 1) {
        exitWithCliError("stdin cannot be combined with file or batch inputs", .{});
    }
    if (stdin_inputs == 1 and watch_flag) exitWithCliError("--watch requires a file input", .{});
    if (watch_flag and input_files.items.len != 1) {
        exitWithCliError("--watch supports exactly one file", .{});
    }
    if (profile_flag and input_files.items.len > 1) {
        exitWithCliError("--profile supports exactly one input", .{});
    }

    if (output_dir_flag and input_files.items.len < 2) {
        exitWithCliError("--output-dir requires multiple inputs", .{});
    }
    if (input_files.items.len > 1 and !output_dir_flag) {
        exitWithCliError("multiple inputs require --output-dir", .{});
    }
    if (output_dir_flag and output_file == null) {
        exitWithCliError("--output-dir requires -o or --output", .{});
    }
    if (output_dir_flag and isStdioPath(output_file.?)) {
        exitWithCliError("--output-dir cannot write to stdout", .{});
    }

    for (input_files.items) |input_file| {
        if (isStdioPath(input_file)) continue;
        if (experimentalFormatName(input_file)) |format_name| {
            exitWithCliError(
                "{s} format adapter is experimental and unavailable in the recovery CLI",
                .{format_name},
            );
        }
    }

    std.debug.print("{s}", .{experimental_notice});

    if (input_files.items.len == 1) {
        if (output_file) |out| {
            if (!isStdioPath(input_files.items[0]) and !isStdioPath(out)) {
                const planned_outputs = [_][]const u8{out};
                if (try findOutputCollision(allocator, input_files.items, &planned_outputs)) |collision| {
                    rejectOutputCollision(collision);
                }
            }
        }
    }

    if (watch_flag) {
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .syntax = syntax,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .profile = profile_flag,
        };
        try watchFile(allocator, config);
    } else if (input_files.items.len == 1) {
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .syntax = syntax,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .profile = profile_flag,
        };
        compileFile(allocator, config) catch {
            std.process.exit(exit_compile_failure);
        };
    } else {
        const output_dir: ?[]const u8 = if (output_dir_flag or output_file != null) output_file else null;

        var tasks = try std.ArrayList(CompileTask).initCapacity(allocator, input_files.items.len);
        defer {
            for (tasks.items) |*task| {
                allocator.free(task.output_file);
                if (task.err_owned) allocator.free(task.err.?);
                if (task.result) |*result| result.deinit();
            }
            tasks.deinit(allocator);
        }
        
        for (input_files.items) |input| {
            const out_file = try determineOutputFile(allocator, input, output_dir, null);
            try tasks.append(allocator, CompileTask{
                .input_file = input,
                .output_file = out_file,
                .syntax = syntax,
                .optimize = optimize_flag,
                .minify = minify_flag,
            });
        }

        const planned_outputs = try allocator.alloc([]const u8, tasks.items.len);
        defer allocator.free(planned_outputs);
        for (tasks.items, 0..) |task, task_index| {
            planned_outputs[task_index] = task.output_file;
        }
        if (try findOutputCollision(allocator, input_files.items, planned_outputs)) |collision| {
            rejectOutputCollision(collision);
        }

        if (output_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }
        
        compileFilesParallel(allocator, tasks.items) catch {
            std.process.exit(exit_compile_failure);
        };
    }
}

test "CLI format boundary rejects every experimental extension without importing adapters" {
    const cases = [_]struct { filename: []const u8, name: []const u8 }{
        .{ .filename = "input.scss", .name = "SCSS" },
        .{ .filename = "input.sass", .name = "SASS" },
        .{ .filename = "input.less", .name = "LESS" },
        .{ .filename = "input.module.css", .name = "CSS Modules" },
        .{ .filename = "input.css.js", .name = "CSS-in-JS" },
        .{ .filename = "input.css.ts", .name = "CSS-in-JS" },
        .{ .filename = "input.postcss", .name = "PostCSS" },
        .{ .filename = "input.styl", .name = "Stylus" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.name, experimentalFormatName(case.filename).?);
    }
    try std.testing.expect(experimentalFormatName("input.css") == null);
    try std.testing.expect(experimentalFormatName("input.unknown") == null);
}

test "legacy compiler imports remain test-only" {
    _ = formats;
    _ = codegen;
    _ = optimizer;
}

const formats = @import("formats.zig");
const codegen = @import("codegen.zig");
const optimizer = @import("optimizer.zig");

test "legacy codegen rejects transform requests without mutating its AST" {
    const css = ".stable { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .optimize = true }),
    );
    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .autoprefix = .{} }),
    );
    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .dead_code = .{} }),
    );
    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .critical_css = .{} }),
    );

    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.items.len);
    try std.testing.expectEqualStrings("color", stylesheet.rules.items[0].style.declarations.items[0].property);
    try std.testing.expectEqualStrings("red", stylesheet.rules.items[0].style.declarations.items[0].value);
}

test "profiler timing handles can be ended more than once safely" {
    var perf_profiler = try profiler.Profiler.init(std.testing.allocator, true);
    defer perf_profiler.deinit();

    var timing = try perf_profiler.startTiming("parse");
    try timing.end();
    try timing.end();

    const metrics = perf_profiler.getMetrics();
    try std.testing.expect(metrics.parse_time_ns <= metrics.total_time_ns);
}

test "basic compilation" {
    const css = ".container { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".container"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "color"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "red"));
}

test "minify output" {
    const css = ".container { color: red; background: white; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const result = try codegen.generate(allocator, &stylesheet, .{ .minify = true });
    defer allocator.free(result);

    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".container"));
}

test "important flag" {
    const css = ".test { color: red !important; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 1);
    try std.testing.expect(rule.style.declarations.items[0].important == true);
}

test "multiple selectors" {
    const css = ".a, .b, .c { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.selectors.items.len == 3);
}

test "at-rule parsing" {
    const css = "@media (min-width: 768px) { .container { width: 100%; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "media"));
}

test "container query parsing" {
    const css = "@container (min-width: 400px) { .card { padding: 1rem; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "container"));
}

test "cascade layer parsing" {
    const css = "@layer utilities { .button { color: red; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "layer"));
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.prelude, "utilities"));
}

test "legacy optimizer internal: cascade layer merging" {
    const css = "@layer theme { .button { color: red; } } @layer theme { .link { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    var layer_count: usize = 0;
    var i: usize = 0;
    while (i < result.len) {
        if (i + 6 <= result.len and std.mem.eql(u8, result[i..i+6], "@layer")) {
            layer_count += 1;
            i += 6;
        } else {
            i += 1;
        }
    }
    try std.testing.expect(layer_count == 1);
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".button"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".link"));
}

test "legacy optimizer internal: cascade layer anonymous merging" {
    const css = "@layer { .a { color: red; } } @layer { .b { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    var layer_count: usize = 0;
    var i: usize = 0;
    while (i < result.len) {
        if (i + 6 <= result.len and std.mem.eql(u8, result[i..i+6], "@layer")) {
            layer_count += 1;
            i += 6;
        } else {
            i += 1;
        }
    }
    try std.testing.expect(layer_count == 1);
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".a"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".b"));
}

test "legacy optimizer internal: flexbox shorthand optimization" {
    const css = ".flex { flex-grow: 1; flex-shrink: 1; flex-basis: 0%; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "flex:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-grow"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-shrink"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-basis"));
}

test "legacy optimizer internal: grid template shorthand optimization" {
    const css = ".grid { grid-template-rows: 1fr 1fr; grid-template-columns: repeat(2, 1fr); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "grid-template:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "grid-template-rows"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "grid-template-columns"));
}

test "legacy optimizer internal: gap shorthand optimization" {
    const css = ".container { row-gap: 20px; column-gap: 20px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "gap:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "row-gap"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "column-gap"));
}

test "legacy optimizer internal: gap shorthand optimization different values" {
    const css = ".container { row-gap: 10px; column-gap: 20px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "gap:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "10px"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "20px"));
}

test "legacy optimizer internal: logical properties optimization" {
    const css = ".box { margin-inline-start: 10px; margin-inline-end: 20px; padding-block-start: 5px; padding-block-end: 15px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "margin-left"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "margin-right"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "padding-top"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "padding-bottom"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "margin-inline-start"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "margin-inline-end"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "padding-block-start"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "padding-block-end"));
}

test "legacy optimizer internal: logical border properties optimization" {
    const css = ".border { border-inline-start-width: 2px; border-inline-end-color: red; border-block-start-style: solid; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-left-width"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-right-color"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-top-style"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-inline-start-width"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-inline-end-color"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-block-start-style"));
}

test "legacy optimizer internal: dead code elimination" {
    const css = ".used-class { color: red; } .unused-class { color: blue; } #used-id { color: green; } #unused-id { color: yellow; } div { color: black; } span { color: white; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const used_classes = [_][]const u8{"used-class"};
    const used_ids = [_][]const u8{"used-id"};
    const used_elements = [_][]const u8{"div"};

    const dead_code_opts = optimizer.DeadCodeOptions{
        .used_classes = &used_classes,
        .used_ids = &used_ids,
        .used_elements = &used_elements,
    };

    var opt = optimizer.Optimizer.initWithDeadCode(allocator, dead_code_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".used-class"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "#used-id"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "div"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".unused-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "#unused-id"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "span"));
}

test "legacy optimizer internal: dead code elimination with media queries" {
    const css = "@media (min-width: 768px) { .used-class { color: red; } .unused-class { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const used_classes = [_][]const u8{"used-class"};

    const dead_code_opts = optimizer.DeadCodeOptions{
        .used_classes = &used_classes,
    };

    var opt = optimizer.Optimizer.initWithDeadCode(allocator, dead_code_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".used-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".unused-class"));
}

test "legacy optimizer internal: critical CSS extraction" {
    const css = ".critical-class { color: red; } .non-critical-class { color: blue; } #critical-id { color: green; } #non-critical-id { color: yellow; } div { color: black; } span { color: white; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const critical_classes = [_][]const u8{"critical-class"};
    const critical_ids = [_][]const u8{"critical-id"};
    const critical_elements = [_][]const u8{"div"};

    const critical_css_opts = optimizer.CriticalCssOptions{
        .critical_classes = &critical_classes,
        .critical_ids = &critical_ids,
        .critical_elements = &critical_elements,
    };

    var opt = optimizer.Optimizer.initWithCriticalCss(allocator, critical_css_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".critical-class"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "#critical-id"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "div"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".non-critical-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "#non-critical-id"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "span"));
}

test "legacy optimizer internal: critical CSS extraction with media queries" {
    const css = "@media (min-width: 768px) { .critical-class { color: red; } .non-critical-class { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const critical_classes = [_][]const u8{"critical-class"};

    const critical_css_opts = optimizer.CriticalCssOptions{
        .critical_classes = &critical_classes,
    };

    var opt = optimizer.Optimizer.initWithCriticalCss(allocator, critical_css_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".critical-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".non-critical-class"));
}
