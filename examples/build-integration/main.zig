const std = @import("std");
const zigcss = @import("zigcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var result = try compile(gpa.allocator());
    defer result.deinit();
    if (result.diagnostics.len != 0) return error.InvalidCss;

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.writeAll(result.css);
    try writer.interface.flush();
}

fn compile(allocator: std.mem.Allocator) !zigcss.CompileResult {
    return zigcss.compile(
        allocator,
        "embedded.css",
        ".embedded { color: red; }",
        .{ .format = .minified },
    );
}

test "build example consumes the owned Zig API" {
    var result = try compile(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqualStrings(".embedded{color:red}", result.css);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
