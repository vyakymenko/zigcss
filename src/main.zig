const std = @import("std");
const formats = @import("formats.zig");
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const error_module = @import("error.zig");
const parser = @import("parser.zig");
const autoprefixer = @import("autoprefixer.zig");

const CompileConfig = struct {
    input_file: []const u8,
    output_file: ?[]const u8,
    optimize: bool,
    minify: bool,
    source_map: bool,
    autoprefix: ?autoprefixer.AutoprefixOptions = null,
};

fn compileFile(allocator: std.mem.Allocator, config: CompileConfig) !void {
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

    const options = codegen.CodegenOptions{
        .minify = config.minify,
        .optimize = config.optimize,
        .autoprefix = config.autoprefix,
    };

    const result = try codegen.generate(allocator, &stylesheet, options);
    defer allocator.free(result);

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
}

const ParseError = error{ParseError};

fn watchFile(allocator: std.mem.Allocator, config: CompileConfig) !void {
    std.debug.print("Watching {s} for changes... (Press Ctrl+C to stop)\n", .{config.input_file});
    
    const cwd = std.fs.cwd();
    const input_file_handle = try cwd.openFile(config.input_file, .{});
    defer input_file_handle.close();
    
    var last_modified: i128 = 0;
    
    try compileFile(allocator, config);
    
    const stat = try input_file_handle.stat();
    last_modified = stat.mtime;
    
    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        
        const current_stat = input_file_handle.stat() catch |err| {
            std.debug.print("Error checking file: {}\n", .{err});
            continue;
        };
        
        if (current_stat.mtime != last_modified) {
            last_modified = current_stat.mtime;
            std.debug.print("File changed, recompiling...\n", .{});
            compileFile(allocator, config) catch {
                continue;
            };
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zcss <input.css> [-o output.css] [options]\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  -o, --output <file>      Output file\n", .{});
        std.debug.print("  --optimize               Enable optimizations\n", .{});
        std.debug.print("  --minify                 Minify output\n", .{});
        std.debug.print("  --source-map             Generate source map\n", .{});
        std.debug.print("  --autoprefix             Add vendor prefixes\n", .{});
        std.debug.print("  --browsers <list>        Browser support (comma-separated)\n", .{});
        std.debug.print("  --watch                  Watch mode\n", .{});
        std.debug.print("  -h, --help               Show this help\n", .{});
        return;
    }

    const input_file = args[1];
    var output_file: ?[]const u8 = null;
    var optimize_flag = false;
    var minify_flag = false;
    var source_map_flag = false;
    var watch_flag = false;
    var autoprefix_flag = false;
    var browsers: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);
    defer browsers.deinit();

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (i + 1 < args.len) {
                output_file = args[i + 1];
                i += 1;
            }
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
        } else if (std.mem.eql(u8, args[i], "--browsers")) {
            if (i + 1 < args.len) {
                const browsers_str = args[i + 1];
                var iter = std.mem.splitSequence(u8, browsers_str, ",");
                while (iter.next()) |browser| {
                    const trimmed = std.mem.trim(u8, browser, " \t");
                    if (trimmed.len > 0) {
                        try browsers.append(trimmed);
                    }
                }
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            std.debug.print("Usage: zcss <input.css> [-o output.css] [options]\n", .{});
            return;
        }
    }

    const autoprefix_opts: ?autoprefixer.AutoprefixOptions = if (autoprefix_flag) blk: {
        const browsers_slice = try browsers.toOwnedSlice();
        break :blk autoprefixer.AutoprefixOptions{
            .browsers = browsers_slice,
        };
    } else null;

    const config = CompileConfig{
        .input_file = input_file,
        .output_file = output_file,
        .optimize = optimize_flag,
        .minify = minify_flag,
        .source_map = source_map_flag,
        .autoprefix = autoprefix_opts,
    };

    if (watch_flag) {
        try watchFile(allocator, config);
    } else {
        compileFile(allocator, config) catch {
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
