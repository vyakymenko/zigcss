const std = @import("std");
const zigcss = @import("zigcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var result = try zigcss.compile(
        gpa.allocator(),
        "input.css",
        ".notice { color: red; }",
        .{ .format = .minified },
    );
    defer result.deinit();
    if (result.diagnostics.len != 0) return error.InvalidCss;

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.writeAll(result.css);
    try writer.interface.flush();
}
