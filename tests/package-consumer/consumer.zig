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

test "path package exposes the native CSS Modules result contract" {
    var result = try zigcss.compile(
        std.testing.allocator,
        "package/card.module.css",
        ".card,.icon{color:red}",
        .{ .syntax = .css_modules, .format = .minified },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const exports = result.module_exports orelse return error.MissingModuleExports;
    try std.testing.expectEqual(@as(usize, 2), exports.entries.len);
    try std.testing.expectEqualStrings("card", exports.entries[0].name);
    try std.testing.expectEqualStrings("icon", exports.entries[1].name);
    try std.testing.expect(std.mem.indexOf(u8, result.css, exports.entries[0].value) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.css, exports.entries[1].value) != null);
}
