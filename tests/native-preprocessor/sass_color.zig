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

test "native Sass legacy color manipulation matches closed conversion rules" {
    const base = color.parseLiteral("#123456").?;
    const cases = [_]struct {
        value: preprocessor.value.Color,
        expected: []const u8,
    }{
        .{
            .value = try color.adjustLightness(base, 10),
            .expected = "rgb(26.8269230769,77.5,128.1730769231)",
        },
        .{
            .value = try color.adjustLightness(base, -10),
            .expected = "rgb(9.1730769231,26.5,43.8269230769)",
        },
        .{ .value = try color.adjustHue(base, 30), .expected = "#121256" },
        .{ .value = try color.adjustHue(base, 180), .expected = "#563412" },
        .{ .value = try color.grayscale(base), .expected = "#343434" },
        .{ .value = try color.invert(base, 100), .expected = "#edcba9" },
        .{ .value = try color.invert(base, 25), .expected = "rgb(72.75,89.75,106.75)" },
        .{
            .value = try color.invert(color.parseLiteral("red").?, 0.25),
            .expected = "hsl(0,99.5%,50%)",
        },
        .{
            .value = try color.mix(color.parseLiteral("red").?, color.parseLiteral("blue").?, 50),
            .expected = "hsl(300,100%,25%)",
        },
        .{
            .value = try color.mix(color.parseLiteral("red").?, color.parseLiteral("blue").?, 25),
            .expected = "rgb(63.75,0,191.25)",
        },
        .{
            .value = try color.adjustAlpha(try color.rgb(1, 2, 3, 0.4), 0.2),
            .expected = "rgba(1,2,3,.6)",
        },
    };
    for (cases) |case| {
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try color.serialize(case.value, &buffer, true));
    }
    try std.testing.expectError(
        error.InvalidColor,
        color.mix(color.parseLiteral("red").?, color.parseLiteral("blue").?, 101),
    );
    var ie_buffer: [9]u8 = undefined;
    try std.testing.expectEqualStrings(
        "#66123456",
        try color.serializeIeHex(try color.rgb(18, 52, 86, 0.4), &ie_buffer),
    );
}

test "native Sass keyword color transforms own bounded RGB and HSL semantics" {
    const base = color.parseLiteral("#123456").?;
    const alpha_base = try color.rgb(18, 52, 86, 0.4);
    const cases = [_]struct {
        value: preprocessor.value.Color,
        expected: []const u8,
    }{
        .{
            .value = try color.transformRgb(base, .adjust, .{ .red = 10 }),
            .expected = "#1c3456",
        },
        .{
            .value = try color.transformRgb(base, .change, .{ .red = 256 }),
            .expected = "hsl(350,100.9900990099%,60.3921568627%)",
        },
        .{
            .value = try color.transformRgb(base, .scale, .{ .red = 50 }),
            .expected = "rgb(136.5,52,86)",
        },
        .{
            .value = try color.transformHsl(base, .adjust, .{ .hue = 30 }),
            .expected = "#121256",
        },
        .{
            .value = try color.transformHsl(base, .adjust, .{ .saturation = 20 }),
            .expected = "rgb(7.6,52,96.4)",
        },
        .{
            .value = try color.transformHsl(base, .change, .{ .saturation = 101 }),
            .expected = "hsl(210,101%,20.3921568627%)",
        },
        .{
            .value = try color.transformHsl(base, .scale, .{ .lightness = 50 }),
            .expected = "hsl(210,65.3846153846%,60.1960784314%)",
        },
        .{
            .value = try color.transformRgb(alpha_base, .adjust, .{ .alpha = 0.2 }),
            .expected = "rgba(18,52,86,.6)",
        },
    };
    for (cases) |case| {
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try color.serialize(case.value, &buffer, true));
    }
    try std.testing.expectError(
        error.InvalidColor,
        color.transformRgb(base, .scale, .{ .red = 101 }),
    );
    try std.testing.expectError(
        error.InvalidColor,
        color.transformHsl(base, .scale, .{ .saturation = -101 }),
    );
}

test "native Sass keyword color transforms own bounded HWB semantics" {
    const base = color.parseLiteral("#123456").?;
    const channels = try color.toHwb(base);
    try std.testing.expectApproxEqAbs(@as(f64, 210), channels[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0588235294117645), channels[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 66.27450980392157), channels[2], 1e-10);

    const hwb_base = try color.hwb(210, 10, 20, 1);
    const cases = [_]struct {
        value: preprocessor.value.Color,
        expected: []const u8,
    }{
        .{
            .value = try color.transformHwb(base, .adjust, .{ .whiteness = 10 }),
            .expected = "rgb(43.5,64.75,86)",
        },
        .{
            .value = try color.transformHwb(base, .change, .{ .blackness = 20 }),
            .expected = "#126fcc",
        },
        .{
            .value = try color.transformHwb(base, .change, .{ .hue = 180 }),
            .expected = "#125656",
        },
        .{
            .value = try color.transformHwb(base, .scale, .{ .whiteness = 50 }),
            .expected = "hsl(0,0%,44.6808510638%)",
        },
        .{
            .value = try color.transformHwb(base, .scale, .{ .blackness = -50 }),
            .expected = "rgb(18,94.25,170.5)",
        },
        .{
            .value = try color.transformHwb(hwb_base, .scale, .{ .whiteness = 100 }),
            .expected = "rgb(212.5,212.5,212.5)",
        },
        .{
            .value = try color.transformHwb(hwb_base, .adjust, .{ .blackness = -101 }),
            .expected = "hsl(210,1900%,95.5%)",
        },
    };
    for (cases) |case| {
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try color.serialize(case.value, &buffer, true));
    }
    try std.testing.expectError(
        error.InvalidColor,
        color.transformHwb(base, .scale, .{ .blackness = 101 }),
    );
}
