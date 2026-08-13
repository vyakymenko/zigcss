const std = @import("std");
const zigcss = @import("zigcss");

const native = zigcss.experimental_native;

const Example = struct {
    syntax: native.Syntax,
    filename: []const u8,
    source: []const u8,
    expected: []const u8,
};

const examples = [_]Example{
    .{ .syntax = .scss, .filename = "example.scss", .source = "$color: red; .card { color: $color; }", .expected = ".card{color:red}" },
    .{ .syntax = .sass, .filename = "example.sass", .source = "$color: red\n.card\n  color: $color\n", .expected = ".card{color:red}" },
    .{ .syntax = .less, .filename = "example.less", .source = "@color: red; .card { color: @color; }", .expected = ".card{color:red}" },
    .{ .syntax = .stylus, .filename = "example.styl", .source = "color = red\n.card\n  color color\n", .expected = ".card{color:#f00}" },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    inline for (examples) |example| {
        const entry = try std.fs.path.join(allocator, &.{ root, example.filename });
        defer allocator.free(entry);
        var result = try native.compile(allocator, entry, example.source, .{
            .syntax = example.syntax,
            .root_paths = &.{root},
            .format = .minified,
        });
        defer result.deinit();
        if (result.diagnostics.len != 0 or !std.mem.eql(u8, result.css, example.expected)) {
            return error.UnexpectedNativeResult;
        }
        try writer.interface.print("{s}\n", .{result.css});
    }
    try writer.interface.flush();
}
