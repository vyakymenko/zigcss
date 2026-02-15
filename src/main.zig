const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zcss <input.css> [-o output.css] [options]\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  -o, --output <file>     Output file\n", .{});
        std.debug.print("  --optimize               Enable optimizations\n", .{});
        std.debug.print("  --minify                 Minify output\n", .{});
        std.debug.print("  --source-map             Generate source map\n", .{});
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
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            std.debug.print("Usage: zcss <input.css> [-o output.css] [options]\n", .{});
            return;
        }
    }

    const input = try std.fs.cwd().readFileAlloc(allocator, input_file, 10 * 1024 * 1024);
    defer allocator.free(input);

    var p = parser.Parser.init(allocator, input);
    const stylesheet = try p.parse();
    defer stylesheet.deinit();

    var options = codegen.CodegenOptions{
        .minify = minify_flag,
        .optimize = optimize_flag,
    };

    const result = try codegen.generate(allocator, stylesheet, options);
    defer allocator.free(result);

    if (output_file) |out| {
        try std.fs.cwd().writeFileAlloc(allocator, out, result);
        std.debug.print("Compiled: {s} -> {s}\n", .{ input_file, out });
    } else {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(result);
    }
}

test "basic compilation" {
    const css = ".container { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = parser.Parser.init(allocator, css);
    const stylesheet = try p.parse();
    defer stylesheet.deinit();

    const result = try codegen.generate(allocator, stylesheet, .{});
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

    var p = parser.Parser.init(allocator, css);
    const stylesheet = try p.parse();
    defer stylesheet.deinit();

    const result = try codegen.generate(allocator, stylesheet, .{ .minify = true });
    defer allocator.free(result);

    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".container"));
}

test "important flag" {
    const css = ".test { color: red !important; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = parser.Parser.init(allocator, css);
    const stylesheet = try p.parse();
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

    var p = parser.Parser.init(allocator, css);
    const stylesheet = try p.parse();
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

    var p = parser.Parser.init(allocator, css);
    const stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "media"));
}
