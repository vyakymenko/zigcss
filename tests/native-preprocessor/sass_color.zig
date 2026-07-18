const std = @import("std");
const preprocessor = @import("native_preprocessor");
const color = preprocessor.sass_color;

test "native Sass color literals cover the closed CSS named and hex sets" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "red", .expected = "red" },
        .{ .input = "CYAN", .expected = "aqua" },
        .{ .input = "rebeccapurple", .expected = "#639" },
        .{ .input = "#ff0000", .expected = "red" },
        .{ .input = "#abcdef", .expected = "#abcdef" },
        .{ .input = "#abcd", .expected = "rgba(170,187,204,.8666666667)" },
        .{ .input = "transparent", .expected = "rgba(0,0,0,0)" },
    };
    for (cases) |case| {
        const parsed = color.parseLiteral(case.input) orelse return error.TestUnexpectedResult;
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected,
            try color.serialize(parsed, &buffer, true),
        );
    }
    try std.testing.expect(color.parseLiteral("currentColor") == null);
    try std.testing.expect(color.parseLiteral("#12") == null);
    try std.testing.expect(color.parseLiteral("#xyz") == null);
}

test "native Sass legacy color constructors clamp normalize and serialize deterministically" {
    const cases = [_]struct {
        value: preprocessor.value.Color,
        expected: []const u8,
    }{
        .{ .value = try color.rgb(300, -10, 20, 1), .expected = "#ff0014" },
        .{ .value = try color.rgb(255, 0, 0, 0.5), .expected = "rgba(255,0,0,.5)" },
        .{ .value = try color.hsl(360, 100, 50, 1), .expected = "red" },
        .{ .value = try color.hsl(400, 120, -10, 1), .expected = "hsl(40,120%,-10%)" },
        .{ .value = try color.hwb(0, 80, 80, 1), .expected = "hsl(0,0%,50%)" },
    };
    for (cases) |case| {
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected,
            try color.serialize(case.value, &buffer, true),
        );
    }
    try std.testing.expectError(error.InvalidColor, color.rgb(std.math.nan(f64), 0, 0, 1));
}

test "native Sass legacy colors compare and expose channels across spaces" {
    const purple = color.parseLiteral("purple").?;
    const equivalent = try color.hsl(300, 100, 25.098039215686, 1);
    try std.testing.expect(color.equal(purple, equivalent));
    try std.testing.expect(color.equal(
        color.parseLiteral("transparent").?,
        try color.rgb(0, 0, 0, 0),
    ));
    try std.testing.expect(!color.equal(purple, color.parseLiteral("red").?));

    const channels = try color.toHsl(try color.rgb(51, 153, 102, 0.4));
    try std.testing.expectApproxEqAbs(@as(f64, 150), channels[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 50), channels[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 40), channels[2], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), channels[3], 1e-10);
}
