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
        .{ .value = try color.hwb(400, 120, -10, 1.1), .expected = "hsl(0,0%,109.0909090909%)" },
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

test "native Sass modern color constructors normalize missing channels and serialize deterministically" {
    const cases = [_]struct {
        value: preprocessor.value.Color,
        expected: []const u8,
    }{
        .{
            .value = try color.modern(.lab, .{ 120, 12.5, -12.5, 2 }, 0),
            .expected = "lab(100 12.5 -12.5)",
        },
        .{
            .value = try color.modern(.lch, .{ 50, 30, 540, 0.5 }, 0),
            .expected = "lch(50 30 180/.5)",
        },
        .{
            .value = try color.modern(.oklab, .{ 0.5, 0.04, -0.04, 0.5 }, 0),
            .expected = "oklab(.5 .04 -0.04/.5)",
        },
        .{
            .value = try color.modern(.oklch, .{ 2, -0.04, -240, -1 }, 0),
            .expected = "oklch(1 0 120/0)",
        },
        .{
            .value = try color.modern(.lab, .{ 99, 99, 99, 99 }, 0b1111),
            .expected = "lab(none none none/none)",
        },
    };
    for (cases) |case| {
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected,
            try color.serialize(case.value, &buffer, true),
        );
    }

    const missing = try color.modern(.oklch, .{ 0.5, 0.2, 120, 1 }, 0b0110);
    var pretty_buffer: [color.max_serialized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "oklch(0.5 none none)",
        try color.serialize(missing, &pretty_buffer, false),
    );
    try std.testing.expectError(
        error.InvalidColor,
        color.modern(.rgb, .{ 0, 0, 0, 1 }, 0),
    );
    try std.testing.expectError(
        error.InvalidColor,
        color.modern(.lab, .{ std.math.nan(f64), 0, 0, 1 }, 0),
    );
}

test "native Sass predefined color spaces serialize canonical CSS Color 4 functions" {
    const cases = [_]struct {
        space: preprocessor.value.ColorSpace,
        expected: []const u8,
    }{
        .{ .space = .srgb, .expected = "color(srgb 1 0 -0.1/.5)" },
        .{ .space = .srgb_linear, .expected = "color(srgb-linear 1 0 -0.1/.5)" },
        .{ .space = .display_p3, .expected = "color(display-p3 1 0 -0.1/.5)" },
        .{ .space = .a98_rgb, .expected = "color(a98-rgb 1 0 -0.1/.5)" },
        .{ .space = .prophoto_rgb, .expected = "color(prophoto-rgb 1 0 -0.1/.5)" },
        .{ .space = .rec2020, .expected = "color(rec2020 1 0 -0.1/.5)" },
        .{ .space = .xyz_d50, .expected = "color(xyz-d50 1 0 -0.1/.5)" },
        .{ .space = .xyz, .expected = "color(xyz 1 0 -0.1/.5)" },
    };
    for (cases) |case| {
        const value = try color.predefined(case.space, .{ 1, 0, -0.1, 0.5 }, 0);
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected,
            try color.serialize(value, &buffer, true),
        );
    }

    const missing = try color.predefined(.display_p3, .{ 1, 2, 3, 4 }, 0b1111);
    var missing_buffer: [color.max_serialized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "color(display-p3 none none none/none)",
        try color.serialize(missing, &missing_buffer, true),
    );
    var pretty_buffer: [color.max_serialized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "color(display-p3 1 0 -0.1 / 0.5)",
        try color.serialize(
            try color.predefined(.display_p3, .{ 1, 0, -0.1, 0.5 }, 0),
            &pretty_buffer,
            false,
        ),
    );
    try std.testing.expectError(
        error.InvalidColor,
        color.predefined(.lab, .{ 0, 0, 0, 1 }, 0),
    );
    try std.testing.expectError(
        error.InvalidColor,
        color.predefined(.srgb, .{ std.math.nan(f64), 0, 0, 1 }, 0),
    );
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

test "native Sass modern colors compare exactly within a normalized space" {
    const lab_percent = try color.modern(.lab, .{ 50, 10, 20, 1 }, 0);
    const lab_unitless = try color.modern(.lab, .{ 50, 10, 20, 1 }, 0);
    const different_lab = try color.modern(.lab, .{ 50, 10, 21, 1 }, 0);
    const oklab = try color.modern(.oklab, .{ 0.5, 0.1, 0.2, 1 }, 0);
    try std.testing.expect(color.equal(lab_percent, lab_unitless));
    try std.testing.expect(!color.equal(lab_percent, different_lab));
    try std.testing.expect(!color.equal(lab_percent, oklab));

    const missing_left = try color.modern(.lab, .{ 50, 0, 20, 1 }, 0b0010);
    const missing_right = try color.modern(.lab, .{ 50, 99, 20, 1 }, 0b0010);
    try std.testing.expect(color.equal(missing_left, missing_right));
    try std.testing.expect(!color.equal(
        missing_left,
        try color.modern(.lab, .{ 50, 0, 20, 1 }, 0),
    ));
}

test "native Sass predefined colors compare within canonical space identity" {
    const display_p3 = try color.predefined(.display_p3, .{ 1, 0, 0, 1 }, 0);
    try std.testing.expect(color.equal(
        display_p3,
        try color.predefined(.display_p3, .{ 1, 0, 0, 1 }, 0),
    ));
    try std.testing.expect(!color.equal(
        display_p3,
        try color.predefined(.srgb, .{ 1, 0, 0, 1 }, 0),
    ));
    try std.testing.expect(!color.equal(display_p3, color.parseLiteral("red").?));
    try std.testing.expect(color.equal(
        try color.predefined(.xyz, .{ 0.4, 0.3, 0.2, 1 }, 0),
        try color.predefined(.xyz, .{ 0.4, 0.3, 0.2, 1 }, 0),
    ));
}

test "native Sass color conversion spans every owned CSS Color 4 family" {
    const source = try color.rgb(51, 102, 153, 0.7);
    const cases = [_]struct {
        space: preprocessor.value.ColorSpace,
        expected: [3]f64,
    }{
        .{ .space = .srgb, .expected = .{ 0.2, 0.4, 0.6 } },
        .{ .space = .srgb_linear, .expected = .{ 0.0331047666, 0.1328683216, 0.3185467781 } },
        .{ .space = .display_p3, .expected = .{ 0.2498513331, 0.3952400722, 0.5840337708 } },
        .{ .space = .a98_rgb, .expected = .{ 0.2814316253, 0.3994051501, 0.5878866513 } },
        .{ .space = .prophoto_rgb, .expected = .{ 0.2876613559, 0.3195515327, 0.5045379079 } },
        .{ .space = .rec2020, .expected = .{ 0.2501283074, 0.3367053823, 0.5377935675 } },
        .{ .space = .xyz_d50, .expected = .{ 0.1111874591, 0.1219274040, 0.2408340301 } },
        .{ .space = .xyz, .expected = .{ 0.1186553058, 0.1250592561, 0.3192661072 } },
        .{ .space = .lab, .expected = .{ 41.5208239274, -4.5730899326, -33.4941945924 } },
        .{ .space = .lch, .expected = .{ 41.5208239274, 33.8049437646, 262.2252620788 } },
        .{ .space = .oklab, .expected = .{ 0.4993144558, -0.0330434876, -0.0929665921 } },
        .{ .space = .oklch, .expected = .{ 0.4993144558, 0.0986643771, 250.4330574202 } },
    };
    for (cases) |case| {
        const converted = try color.convert(source, case.space);
        try std.testing.expectEqual(case.space, converted.space);
        for (case.expected, converted.channels[0..3]) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 1e-9);
        }
        try std.testing.expectApproxEqAbs(@as(f64, 0.7), converted.channels[3], 1e-12);

        const round_trip = try color.convert(converted, .rgb);
        for (source.channels, round_trip.channels) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 1e-8);
        }
    }
}

test "native Sass color conversion fails closed for missing cross-space channels" {
    const missing = try color.modern(.oklch, .{ 0.5, 0.2, 120, 1 }, 0b0010);
    try std.testing.expectEqual(missing, try color.convert(missing, .oklch));
    try std.testing.expectError(error.InvalidColor, color.convert(missing, .lab));

    const modern = try color.modern(.lab, .{ 50, 10, 20, 1 }, 0);
    try std.testing.expectError(error.InvalidColor, color.adjustLightness(modern, 10));
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
        .{
            .value = try color.adjustLightness(try color.hsl(120, 50, 25, 1), -10),
            .expected = "hsl(120,50%,15%)",
        },
        .{
            .value = try color.adjustLightness(try color.hwb(240, 10, 20, 1), 1),
            .expected = "hsl(240,77.7777777778%,46%)",
        },
        .{
            .value = try color.adjustLightness(try color.hwb(240, 10, 20, 1), -25),
            .expected = "hsl(240,77.7777777778%,20%)",
        },
        .{
            .value = try color.adjustSaturation(try color.hsl(120, 20, 25, 1), 10),
            .expected = "hsl(120,30%,25%)",
        },
        .{
            .value = try color.adjustSaturation(try color.hwb(240, 10, 20, 1), 25),
            .expected = "rgb(0,0,229.5)",
        },
        .{
            .value = try color.adjustSaturation(try color.hsl(120, 20, 25, 1), -10),
            .expected = "hsl(120,10%,25%)",
        },
        .{
            .value = try color.adjustSaturation(try color.hwb(240, 10, 20, 1), -25),
            .expected = "hsl(240,52.7777777778%,45%)",
        },
        .{ .value = try color.adjustHue(base, 30), .expected = "#121256" },
        .{ .value = try color.adjustHue(base, 180), .expected = "#563412" },
        .{
            .value = try color.adjustHue(try color.hsl(120, 20, 25, 1), 30),
            .expected = "hsl(150,20%,25%)",
        },
        .{
            .value = try color.adjustHue(try color.hwb(240, 10, 20, 1), 30),
            .expected = "rgb(114.75,25.5,204)",
        },
        .{ .value = try color.grayscale(base), .expected = "#343434" },
        .{
            .value = try color.grayscale(try color.hsl(120, 20, 25, 1)),
            .expected = "hsl(120,0%,25%)",
        },
        .{
            .value = try color.grayscale(try color.hwb(240, 10, 20, 1)),
            .expected = "hsl(0,0%,45%)",
        },
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

test "native Sass modern color transforms operate in a selected native space" {
    const cases = [_]struct {
        value: preprocessor.value.Color,
        expected: []const u8,
    }{
        .{
            .value = try color.transformModern(
                try color.modern(.lab, .{ 50, 10, 20, 1 }, 0),
                .lab,
                .adjust,
                .{ .channels = .{ 10, 5, null } },
            ),
            .expected = "lab(60 15 20)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.oklab, .{ 0.5, 0.1, 0.2, 1 }, 0),
                .oklab,
                .scale,
                .{ .channels = .{ null, 50, null } },
            ),
            .expected = "oklab(.5 .25 .2)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.lab, .{ 50, 10, 20, 1 }, 0),
                .lab,
                .scale,
                .{ .channels = .{ null, -50, null } },
            ),
            .expected = "lab(50 -57.5 20)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.lch, .{ 50, 20, 350, 1 }, 0),
                .lch,
                .adjust,
                .{ .channels = .{ null, null, 20 } },
            ),
            .expected = "lch(50 20 10)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.lch, .{ 50, 5, 30, 1 }, 0),
                .lch,
                .change,
                .{ .channels = .{ null, -10, null } },
            ),
            .expected = "lch(50 10 210)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.lab, .{ 50, 200, 20, 1 }, 0),
                .lab,
                .scale,
                .{ .channels = .{ null, 50, null } },
            ),
            .expected = "lab(50 200 20)",
        },
        .{
            .value = try color.transformModern(
                try color.predefined(.display_p3, .{ -0.5, 0.3, 0.4, 1 }, 0),
                .display_p3,
                .scale,
                .{ .channels = .{ -50, null, null } },
            ),
            .expected = "color(display-p3 -0.5 .3 .4)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.lab, .{ 50, 10, 20, 1 }, 0),
                .lab,
                .change,
                .{ .channels = .{ 120, null, null } },
            ),
            .expected = "color-mix(in lab,color(xyz 1.5892547003 1.6026853084 1.3409230175)100%,red)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.lch, .{ 50, 20, 30, 1 }, 0),
                .lch,
                .change,
                .{ .channels = .{ 120, null, null } },
            ),
            .expected = "color-mix(in lch,color(xyz 1.6569354424 1.6040925936 1.5400032443)100%,red)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.oklab, .{ 0.5, 0.1, 0.2, 1 }, 0),
                .oklab,
                .change,
                .{ .channels = .{ -0.1, null, null } },
            ),
            .expected = "color-mix(in oklab,color(xyz -.0128972668 .0014656971 -.0778095634)100%,red)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.oklch, .{ 0.5, 0.1, 30, 1 }, 0),
                .oklch,
                .change,
                .{ .channels = .{ 1.2, null, null } },
            ),
            .expected = "color-mix(in oklch,color(xyz 1.8372934791 1.6822116005 1.4221356295)100%,red)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.oklch, .{ 0.5, 0.1, 30, 1 }, 0),
                .oklch,
                .change,
                .{ .channels = .{ null, -0.2, null } },
            ),
            .expected = "oklch(.5 .2 210)",
        },
        .{
            .value = try color.transformRgb(
                try color.predefined(.display_p3, .{ 0.2, 0.3, 0.4, 1 }, 0),
                .adjust,
                .{ .red = 10 },
            ),
            .expected = "color(display-p3 .227974604 .3007646632 .400278314)",
        },
        .{
            .value = try color.transformModern(
                color.parseLiteral("red").?,
                .lab,
                .adjust,
                .{ .channels = .{ 10, null, null } },
            ),
            .expected = "hsl(7.3040012065,135.5651909831%,62.7601597049%)",
        },
        .{
            .value = try color.transformModern(
                try color.predefined(.display_p3, .{ 1, 0, 0, 1 }, 0),
                .lab,
                .adjust,
                .{ .channels = .{ 10, null, null } },
            ),
            .expected = "color(display-p3 1.1297177442 .2553231029 .0951073704)",
        },
        .{
            .value = try color.transformModern(
                try color.modern(.oklab, .{ 0.5, 0.1, 0.2, 0.4 }, 0),
                .oklab,
                .scale,
                .{ .alpha = 50 },
            ),
            .expected = "oklab(.5 .1 .2/.7)",
        },
    };
    for (cases) |case| {
        var buffer: [color.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try color.serialize(case.value, &buffer, true));
    }

    try std.testing.expectError(
        error.InvalidColor,
        color.transformModern(
            try color.modern(.lab, .{ 50, 10, 20, 1 }, 0b0001),
            .lab,
            .adjust,
            .{ .channels = .{ null, 1, null } },
        ),
    );
    try std.testing.expectError(
        error.InvalidColor,
        color.transformModern(
            try color.modern(.lch, .{ 50, 20, 30, 1 }, 0),
            .lch,
            .scale,
            .{ .channels = .{ null, null, 10 } },
        ),
    );

    const out_of_range_alpha = try color.transformModern(
        try color.modern(.lab, .{ 50, 10, 20, 0.4 }, 0),
        .lab,
        .change,
        .{ .channels = .{ 120, null, null } },
    );
    var pretty_buffer: [color.max_serialized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "color-mix(in lab, color(xyz 1.5892547003 1.6026853084 1.3409230175 / 0.4) 100%, black)",
        try color.serialize(out_of_range_alpha, &pretty_buffer, false),
    );
}
