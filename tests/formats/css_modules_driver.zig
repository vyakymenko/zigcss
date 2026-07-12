const std = @import("std");
const zigcss = @import("zigcss");

const Error = error{
    CompileFailed,
    InvalidArguments,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3 or args.len > 4) return usage();
    const minified = if (args.len == 4) blk: {
        if (!std.mem.eql(u8, args[3], "--minify")) return usage();
        break :blk true;
    } else false;

    const input = try std.fs.cwd().readFileAlloc(allocator, args[1], 8 * 1024 * 1024);
    defer allocator.free(input);
    var result = try zigcss.compile(
        allocator,
        args[2],
        input,
        .{
            .syntax = .css_modules,
            .format = if (minified) .minified else .pretty,
        },
    );
    defer result.deinit();

    if (hasErrors(result.diagnostics)) {
        for (result.diagnostics) |diagnostic| {
            std.debug.print(
                "{s}:{d}:{d}: {s}: {s}\n",
                .{
                    diagnostic.source_name,
                    diagnostic.start.line,
                    diagnostic.start.column,
                    diagnostic.code.label(),
                    diagnostic.message,
                },
            );
        }
        return error.CompileFailed;
    }
    const module_exports = result.module_exports orelse return error.CompileFailed;

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.print(
        "{f}\n",
        .{std.json.fmt(.{
            .css = result.css,
            .exports = module_exports.entries,
            .dependencies = result.dependencies,
        }, .{})},
    );
    try writer.interface.flush();
}

fn hasErrors(diagnostics: []const zigcss.Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

fn usage() Error {
    std.debug.print(
        "usage: zigcss-css-modules-test-driver <input.css> <source-identity> [--minify]\n",
        .{},
    );
    return error.InvalidArguments;
}
