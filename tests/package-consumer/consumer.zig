const std = @import("std");
const zigcss = @import("zigcss");

test "path package exposes the owned compile API" {
    var result = try zigcss.compile(
        std.testing.allocator,
        "package-consumer.css",
        "@import \"theme.css\";.package{color:red}",
        .{ .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "@import \"theme.css\";.package{color:red}",
        result.css,
    );
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expectEqualStrings("theme.css", result.dependencies[0].specifier);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
