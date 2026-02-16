const std = @import("std");
const formats = @import("formats.zig");
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const error_module = @import("error.zig");
const parser = @import("parser.zig");
const autoprefixer = @import("autoprefixer.zig");
const profiler = @import("profiler.zig");
const optimizer = @import("optimizer.zig");
const lsp = @import("lsp.zig");

const CompileConfig = struct {
    input_file: []const u8,
    output_file: ?[]const u8,
    optimize: bool,
    minify: bool,
    source_map: bool,
    autoprefix: ?autoprefixer.AutoprefixOptions = null,
    profile: bool = false,
};

const CompileTask = struct {
    input_file: []const u8,
    output_file: []const u8,
    optimize: bool,
    minify: bool,
    source_map: bool,
    autoprefix: ?autoprefixer.AutoprefixOptions,
    profile: bool,
    result: ?[]const u8 = null,
    err: ?[]const u8 = null,
};

fn compileFile(allocator: std.mem.Allocator, config: CompileConfig) !void {
    var perf_profiler = try profiler.Profiler.init(allocator, config.profile);
    defer perf_profiler.deinit();
    
    var parse_timing = try perf_profiler.startTiming("parse");
    defer parse_timing.end() catch {};
    
    const input = try std.fs.cwd().readFileAlloc(allocator, config.input_file, 10 * 1024 * 1024);
    defer allocator.free(input);

    const format = formats.detectFormat(config.input_file);
    
    var stylesheet: ast.Stylesheet = undefined;
    var stylesheet_initialized = false;
    
    if (format == .css) {
        var css_parser = parser.Parser.init(allocator, input);
        defer if (css_parser.owns_pool) {
            css_parser.string_pool.deinit();
            allocator.destroy(css_parser.string_pool);
        };
        
        const result = css_parser.parseWithErrorInfo();
        switch (result) {
            .success => |s| {
                stylesheet = s;
                stylesheet_initialized = true;
            },
            .parse_error => |parse_error| {
                const error_msg = try error_module.formatErrorWithContext(allocator, input, config.input_file, parse_error);
                defer allocator.free(error_msg);
                std.debug.print("{s}\n", .{error_msg});
                return error.ParseError;
            },
        }
    } else {
        const parser_trait = formats.getParser(format);
        stylesheet = try parser_trait.parseFn(allocator, input);
        stylesheet_initialized = true;
    }
    
    defer if (stylesheet_initialized) stylesheet.deinit();
    
    try parse_timing.end();

    var optimize_timing = try perf_profiler.startTiming("optimize");
    defer optimize_timing.end() catch {};
    
    const options = codegen.CodegenOptions{
        .minify = config.minify,
        .optimize = config.optimize,
        .autoprefix = config.autoprefix,
    };
    
    try optimize_timing.end();
    
    var codegen_timing = try perf_profiler.startTiming("codegen");
    defer codegen_timing.end() catch {};

    const result = try codegen.generate(allocator, &stylesheet, options);
    defer allocator.free(result);
    
    try codegen_timing.end();

    if (config.output_file) |out| {
        try std.fs.cwd().writeFile(.{ .sub_path = out, .data = result });
        std.debug.print("Compiled: {s} -> {s}\n", .{ config.input_file, out });
    } else {
        const stdout_file = std.fs.File.stdout();
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = stdout_file.writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(result);
        try stdout.flush();
    }
    
    if (config.profile) {
        perf_profiler.printReport();
    }
}

const ParseError = error{ParseError};

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
        const input = cwd.readFileAlloc(allocator, config.input_file, 10 * 1024 * 1024) catch |err| {
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
                .optimize = config.optimize,
                .minify = config.minify,
                .source_map = config.source_map,
                .autoprefix = config.autoprefix,
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
    const input = std.fs.cwd().readFileAlloc(allocator, task.input_file, 10 * 1024 * 1024) catch |err| {
        task.err = std.fmt.allocPrint(allocator, "Failed to read {s}: {s}", .{ task.input_file, @errorName(err) }) catch "Read error";
        return;
    };
    defer allocator.free(input);

    const format = formats.detectFormat(task.input_file);
    
    var stylesheet: ast.Stylesheet = undefined;
    var stylesheet_initialized = false;
    
    if (format == .css) {
        var css_parser = parser.Parser.init(allocator, input);
        defer if (css_parser.owns_pool) {
            css_parser.string_pool.deinit();
            allocator.destroy(css_parser.string_pool);
        };
        
        const result = css_parser.parseWithErrorInfo();
        switch (result) {
            .success => |s| {
                stylesheet = s;
                stylesheet_initialized = true;
            },
            .parse_error => |parse_error| {
                const error_msg = error_module.formatErrorWithContext(allocator, input, task.input_file, parse_error) catch |err| {
                    task.err = std.fmt.allocPrint(allocator, "Parse error: {s}", .{@errorName(err)}) catch "Parse error";
                    return;
                };
                task.err = error_msg;
                return;
            },
        }
    } else {
        const parser_trait = formats.getParser(format);
        stylesheet = parser_trait.parseFn(allocator, input) catch |err| {
            task.err = std.fmt.allocPrint(allocator, "Parse error: {s}", .{@errorName(err)}) catch "Parse error";
            return;
        };
        stylesheet_initialized = true;
    }
    
    defer if (stylesheet_initialized) stylesheet.deinit();

    const options = codegen.CodegenOptions{
        .minify = task.minify,
        .optimize = task.optimize,
        .autoprefix = task.autoprefix,
    };

    const result = codegen.generate(allocator, &stylesheet, options) catch |err| {
        task.err = std.fmt.allocPrint(allocator, "Codegen error: {s}", .{@errorName(err)}) catch "Codegen error";
        return;
    };
    
    task.result = result;
}

fn compileFilesParallel(allocator: std.mem.Allocator, tasks: []CompileTask) !void {
    const num_threads = @min(tasks.len, std.Thread.getCpuCount() catch 4);
    
    if (tasks.len == 1) {
        compileTask(&tasks[0], allocator);
        if (tasks[0].err) |err| {
            std.debug.print("Error: {s}\n", .{err});
            return error.CompileError;
        }
        if (tasks[0].result) |result| {
            try std.fs.cwd().writeFile(.{ .sub_path = tasks[0].output_file, .data = result });
            std.debug.print("Compiled: {s} -> {s}\n", .{ tasks[0].input_file, tasks[0].output_file });
        }
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
                    if (task.err) |_| {
                        err.* = true;
                    }
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
            if (task.err) |err| {
                std.debug.print("Error compiling {s}: {s}\n", .{ task.input_file, err });
            }
        }
        return error.CompileError;
    }

    for (tasks) |*task| {
        if (task.result) |result| {
            try std.fs.cwd().writeFile(.{ .sub_path = task.output_file, .data = result });
            std.debug.print("Compiled: {s} -> {s}\n", .{ task.input_file, task.output_file });
            allocator.free(result);
        }
    }
}

const CompileError = error{CompileError};

fn runLspServer(allocator: std.mem.Allocator) !void {
    var server = lsp.LspServer.init(allocator);
    defer server.deinit();
    
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    
    var buffer: [8192]u8 = undefined;
    
    while (true) {
        const content_length_line = stdin.readUntilDelimiterOrEof(buffer[0..], '\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        } orelse break;
        
        if (!std.mem.startsWith(u8, content_length_line, "Content-Length: ")) {
            continue;
        }
        
        const length_str = content_length_line["Content-Length: ".len..];
        const content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, length_str, " \r"), 10);
        
        _ = try stdin.readUntilDelimiterOrEof(buffer[0..], '\n');
        
        if (content_length > buffer.len) {
            return error.BufferTooSmall;
        }
        
        var total_read: usize = 0;
        while (total_read < content_length) {
            const bytes_read = try stdin.read(buffer[total_read..content_length]);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }
        const request = buffer[0..total_read];
        const response = try server.handleRequest(request);
        defer allocator.free(response);
        
        try stdout.print("Content-Length: {}\r\n\r\n{s}", .{ response.len, response });
        try stdout.flush();
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--lsp") or std.mem.eql(u8, args[1], "-lsp"))) {
        try runLspServer(allocator);
        return;
    }

    if (args.len < 2) {
        std.debug.print("Usage: zcss <input.css> [-o output.css] [options]\n", .{});
        std.debug.print("       zcss <input1.css> <input2.css> ... [-o output-dir/] [--output-dir] [options]\n", .{});
        std.debug.print("       zcss --lsp          Start Language Server Protocol server\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  -o, --output <file>      Output file or directory\n", .{});
        std.debug.print("  --output-dir             Treat output as directory (for multiple files)\n", .{});
        std.debug.print("  --optimize               Enable optimizations\n", .{});
        std.debug.print("  --minify                 Minify output\n", .{});
        std.debug.print("  --source-map             Generate source map\n", .{});
        std.debug.print("  --autoprefix             Add vendor prefixes\n", .{});
        std.debug.print("  --browsers <list>        Browser support (comma-separated)\n", .{});
        std.debug.print("  --watch                  Watch mode\n", .{});
        std.debug.print("  --profile                Enable performance profiling\n", .{});
        std.debug.print("  --lsp                    Start Language Server Protocol server\n", .{});
        std.debug.print("  -h, --help               Show this help\n", .{});
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
    var optimize_flag = false;
    var minify_flag = false;
    var source_map_flag = false;
    var watch_flag = false;
    var autoprefix_flag = false;
    var profile_flag = false;
    var browsers = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer browsers.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (i + 1 < args.len) {
                output_file = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--output-dir")) {
            output_dir_flag = true;
        } else if (std.mem.eql(u8, args[i], "--optimize")) {
            optimize_flag = true;
        } else if (std.mem.eql(u8, args[i], "--minify")) {
            minify_flag = true;
        } else if (std.mem.eql(u8, args[i], "--source-map")) {
            source_map_flag = true;
        } else if (std.mem.eql(u8, args[i], "--watch")) {
            watch_flag = true;
        } else if (std.mem.eql(u8, args[i], "--autoprefix")) {
            autoprefix_flag = true;
        } else if (std.mem.eql(u8, args[i], "--profile")) {
            profile_flag = true;
        } else if (std.mem.eql(u8, args[i], "--browsers")) {
            if (i + 1 < args.len) {
                const browsers_str = args[i + 1];
                var iter = std.mem.splitSequence(u8, browsers_str, ",");
                while (iter.next()) |browser| {
                    const trimmed = std.mem.trim(u8, browser, " \t");
                    if (trimmed.len > 0) {
                        try browsers.append(allocator, trimmed);
                    }
                }
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            std.debug.print("Usage: zcss <input.css> [-o output.css] [options]\n", .{});
            return;
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
        }
    }

    if (input_files.items.len == 0) {
        std.debug.print("Error: No input files specified\n", .{});
        std.process.exit(1);
    }

    const autoprefix_opts: ?autoprefixer.AutoprefixOptions = if (autoprefix_flag) blk: {
        const browsers_slice = try browsers.toOwnedSlice(allocator);
        break :blk autoprefixer.AutoprefixOptions{
            .browsers = browsers_slice,
        };
    } else null;

    if (watch_flag) {
        if (input_files.items.len > 1) {
            std.debug.print("Error: Watch mode only supports single file\n", .{});
            std.process.exit(1);
        }
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .source_map = source_map_flag,
            .autoprefix = autoprefix_opts,
            .profile = profile_flag,
        };
        try watchFile(allocator, config);
    } else if (input_files.items.len == 1) {
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .source_map = source_map_flag,
            .autoprefix = autoprefix_opts,
            .profile = profile_flag,
        };
        compileFile(allocator, config) catch {
            std.process.exit(1);
        };
    } else {
        const output_dir: ?[]const u8 = if (output_dir_flag or output_file != null) output_file else null;
        
        if (output_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }
        
        var tasks = try std.ArrayList(CompileTask).initCapacity(allocator, input_files.items.len);
        defer {
            for (tasks.items) |*task| {
                allocator.free(task.output_file);
                if (task.err) |err| allocator.free(err);
            }
            tasks.deinit(allocator);
        }
        
        for (input_files.items) |input| {
            const out_file = try determineOutputFile(allocator, input, output_dir, null);
            try tasks.append(allocator, CompileTask{
                .input_file = input,
                .output_file = out_file,
                .optimize = optimize_flag,
                .minify = minify_flag,
                .source_map = source_map_flag,
                .autoprefix = autoprefix_opts,
                .profile = profile_flag,
            });
        }
        
        compileFilesParallel(allocator, tasks.items) catch {
            std.process.exit(1);
        };
    }
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

test "cascade layer merging" {
    const css = "@layer theme { .button { color: red; } } @layer theme { .link { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
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

test "cascade layer anonymous merging" {
    const css = "@layer { .a { color: red; } } @layer { .b { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
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

test "flexbox shorthand optimization" {
    const css = ".flex { flex-grow: 1; flex-shrink: 1; flex-basis: 0%; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "flex:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-grow"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-shrink"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-basis"));
}

test "grid template shorthand optimization" {
    const css = ".grid { grid-template-rows: 1fr 1fr; grid-template-columns: repeat(2, 1fr); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "grid-template:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "grid-template-rows"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "grid-template-columns"));
}

test "gap shorthand optimization" {
    const css = ".container { row-gap: 20px; column-gap: 20px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "gap:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "row-gap"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "column-gap"));
}

test "gap shorthand optimization different values" {
    const css = ".container { row-gap: 10px; column-gap: 20px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "gap:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "10px"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "20px"));
}

test "logical properties optimization" {
    const css = ".box { margin-inline-start: 10px; margin-inline-end: 20px; padding-block-start: 5px; padding-block-end: 15px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
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

test "logical border properties optimization" {
    const css = ".border { border-inline-start-width: 2px; border-inline-end-color: red; border-block-start-style: solid; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{ .optimize = true });
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-left-width"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-right-color"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-top-style"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-inline-start-width"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-inline-end-color"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-block-start-style"));
}

test "dead code elimination" {
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

    const result = try codegen.generate(allocator, &stylesheet, .{
        .optimize = true,
        .dead_code = dead_code_opts,
    });
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".used-class"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "#used-id"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "div"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".unused-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "#unused-id"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "span"));
}

test "dead code elimination with media queries" {
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

    const result = try codegen.generate(allocator, &stylesheet, .{
        .optimize = true,
        .dead_code = dead_code_opts,
    });
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".used-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".unused-class"));
}
