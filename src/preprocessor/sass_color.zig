//! Allocation-free legacy Sass color semantics for the private native
//! evaluator. The table and conversion math are compiled into ZigCSS; no
//! runtime stylesheet provider or package is consulted.

const std = @import("std");
const native_numeric = @import("sass_numeric.zig");
const native_value = @import("value.zig");

pub const max_serialized_bytes = 512;

pub const Error = native_numeric.Error || error{
    InvalidColor,
    SerializationLimitExceeded,
};

pub const TransformKind = enum {
    adjust,
    change,
    scale,
};

pub const RgbTransform = struct {
    red: ?f64 = null,
    green: ?f64 = null,
    blue: ?f64 = null,
    alpha: ?f64 = null,
};

pub const HslTransform = struct {
    hue: ?f64 = null,
    saturation: ?f64 = null,
    lightness: ?f64 = null,
    alpha: ?f64 = null,
};

pub const HwbTransform = struct {
    hue: ?f64 = null,
    whiteness: ?f64 = null,
    blackness: ?f64 = null,
    alpha: ?f64 = null,
};

const NamedColor = struct {
    name: []const u8,
    red: u8,
    green: u8,
    blue: u8,
};

// CSS's closed named-color set. Ordering is intentional: when aliases have
// equal length, Sass's canonical spelling (aqua, fuchsia, gray) comes first.
const named_colors = [_]NamedColor{
    .{ .name = "aliceblue", .red = 240, .green = 248, .blue = 255 },
    .{ .name = "antiquewhite", .red = 250, .green = 235, .blue = 215 },
    .{ .name = "aqua", .red = 0, .green = 255, .blue = 255 },
    .{ .name = "aquamarine", .red = 127, .green = 255, .blue = 212 },
    .{ .name = "azure", .red = 240, .green = 255, .blue = 255 },
    .{ .name = "beige", .red = 245, .green = 245, .blue = 220 },
    .{ .name = "bisque", .red = 255, .green = 228, .blue = 196 },
    .{ .name = "black", .red = 0, .green = 0, .blue = 0 },
    .{ .name = "blanchedalmond", .red = 255, .green = 235, .blue = 205 },
    .{ .name = "blue", .red = 0, .green = 0, .blue = 255 },
    .{ .name = "blueviolet", .red = 138, .green = 43, .blue = 226 },
    .{ .name = "brown", .red = 165, .green = 42, .blue = 42 },
    .{ .name = "burlywood", .red = 222, .green = 184, .blue = 135 },
    .{ .name = "cadetblue", .red = 95, .green = 158, .blue = 160 },
    .{ .name = "chartreuse", .red = 127, .green = 255, .blue = 0 },
    .{ .name = "chocolate", .red = 210, .green = 105, .blue = 30 },
    .{ .name = "coral", .red = 255, .green = 127, .blue = 80 },
    .{ .name = "cornflowerblue", .red = 100, .green = 149, .blue = 237 },
    .{ .name = "cornsilk", .red = 255, .green = 248, .blue = 220 },
    .{ .name = "crimson", .red = 220, .green = 20, .blue = 60 },
    .{ .name = "cyan", .red = 0, .green = 255, .blue = 255 },
    .{ .name = "darkblue", .red = 0, .green = 0, .blue = 139 },
    .{ .name = "darkcyan", .red = 0, .green = 139, .blue = 139 },
    .{ .name = "darkgoldenrod", .red = 184, .green = 134, .blue = 11 },
    .{ .name = "darkgray", .red = 169, .green = 169, .blue = 169 },
    .{ .name = "darkgreen", .red = 0, .green = 100, .blue = 0 },
    .{ .name = "darkgrey", .red = 169, .green = 169, .blue = 169 },
    .{ .name = "darkkhaki", .red = 189, .green = 183, .blue = 107 },
    .{ .name = "darkmagenta", .red = 139, .green = 0, .blue = 139 },
    .{ .name = "darkolivegreen", .red = 85, .green = 107, .blue = 47 },
    .{ .name = "darkorange", .red = 255, .green = 140, .blue = 0 },
    .{ .name = "darkorchid", .red = 153, .green = 50, .blue = 204 },
    .{ .name = "darkred", .red = 139, .green = 0, .blue = 0 },
    .{ .name = "darksalmon", .red = 233, .green = 150, .blue = 122 },
    .{ .name = "darkseagreen", .red = 143, .green = 188, .blue = 143 },
    .{ .name = "darkslateblue", .red = 72, .green = 61, .blue = 139 },
    .{ .name = "darkslategray", .red = 47, .green = 79, .blue = 79 },
    .{ .name = "darkslategrey", .red = 47, .green = 79, .blue = 79 },
    .{ .name = "darkturquoise", .red = 0, .green = 206, .blue = 209 },
    .{ .name = "darkviolet", .red = 148, .green = 0, .blue = 211 },
    .{ .name = "deeppink", .red = 255, .green = 20, .blue = 147 },
    .{ .name = "deepskyblue", .red = 0, .green = 191, .blue = 255 },
    .{ .name = "dimgray", .red = 105, .green = 105, .blue = 105 },
    .{ .name = "dimgrey", .red = 105, .green = 105, .blue = 105 },
    .{ .name = "dodgerblue", .red = 30, .green = 144, .blue = 255 },
    .{ .name = "firebrick", .red = 178, .green = 34, .blue = 34 },
    .{ .name = "floralwhite", .red = 255, .green = 250, .blue = 240 },
    .{ .name = "forestgreen", .red = 34, .green = 139, .blue = 34 },
    .{ .name = "fuchsia", .red = 255, .green = 0, .blue = 255 },
    .{ .name = "gainsboro", .red = 220, .green = 220, .blue = 220 },
    .{ .name = "ghostwhite", .red = 248, .green = 248, .blue = 255 },
    .{ .name = "gold", .red = 255, .green = 215, .blue = 0 },
    .{ .name = "goldenrod", .red = 218, .green = 165, .blue = 32 },
    .{ .name = "gray", .red = 128, .green = 128, .blue = 128 },
    .{ .name = "green", .red = 0, .green = 128, .blue = 0 },
    .{ .name = "greenyellow", .red = 173, .green = 255, .blue = 47 },
    .{ .name = "grey", .red = 128, .green = 128, .blue = 128 },
    .{ .name = "honeydew", .red = 240, .green = 255, .blue = 240 },
    .{ .name = "hotpink", .red = 255, .green = 105, .blue = 180 },
    .{ .name = "indianred", .red = 205, .green = 92, .blue = 92 },
    .{ .name = "indigo", .red = 75, .green = 0, .blue = 130 },
    .{ .name = "ivory", .red = 255, .green = 255, .blue = 240 },
    .{ .name = "khaki", .red = 240, .green = 230, .blue = 140 },
    .{ .name = "lavender", .red = 230, .green = 230, .blue = 250 },
    .{ .name = "lavenderblush", .red = 255, .green = 240, .blue = 245 },
    .{ .name = "lawngreen", .red = 124, .green = 252, .blue = 0 },
    .{ .name = "lemonchiffon", .red = 255, .green = 250, .blue = 205 },
    .{ .name = "lightblue", .red = 173, .green = 216, .blue = 230 },
    .{ .name = "lightcoral", .red = 240, .green = 128, .blue = 128 },
    .{ .name = "lightcyan", .red = 224, .green = 255, .blue = 255 },
    .{ .name = "lightgoldenrodyellow", .red = 250, .green = 250, .blue = 210 },
    .{ .name = "lightgray", .red = 211, .green = 211, .blue = 211 },
    .{ .name = "lightgreen", .red = 144, .green = 238, .blue = 144 },
    .{ .name = "lightgrey", .red = 211, .green = 211, .blue = 211 },
    .{ .name = "lightpink", .red = 255, .green = 182, .blue = 193 },
    .{ .name = "lightsalmon", .red = 255, .green = 160, .blue = 122 },
    .{ .name = "lightseagreen", .red = 32, .green = 178, .blue = 170 },
    .{ .name = "lightskyblue", .red = 135, .green = 206, .blue = 250 },
    .{ .name = "lightslategray", .red = 119, .green = 136, .blue = 153 },
    .{ .name = "lightslategrey", .red = 119, .green = 136, .blue = 153 },
    .{ .name = "lightsteelblue", .red = 176, .green = 196, .blue = 222 },
    .{ .name = "lightyellow", .red = 255, .green = 255, .blue = 224 },
    .{ .name = "lime", .red = 0, .green = 255, .blue = 0 },
    .{ .name = "limegreen", .red = 50, .green = 205, .blue = 50 },
    .{ .name = "linen", .red = 250, .green = 240, .blue = 230 },
    .{ .name = "magenta", .red = 255, .green = 0, .blue = 255 },
    .{ .name = "maroon", .red = 128, .green = 0, .blue = 0 },
    .{ .name = "mediumaquamarine", .red = 102, .green = 205, .blue = 170 },
    .{ .name = "mediumblue", .red = 0, .green = 0, .blue = 205 },
    .{ .name = "mediumorchid", .red = 186, .green = 85, .blue = 211 },
    .{ .name = "mediumpurple", .red = 147, .green = 112, .blue = 219 },
    .{ .name = "mediumseagreen", .red = 60, .green = 179, .blue = 113 },
    .{ .name = "mediumslateblue", .red = 123, .green = 104, .blue = 238 },
    .{ .name = "mediumspringgreen", .red = 0, .green = 250, .blue = 154 },
    .{ .name = "mediumturquoise", .red = 72, .green = 209, .blue = 204 },
    .{ .name = "mediumvioletred", .red = 199, .green = 21, .blue = 133 },
    .{ .name = "midnightblue", .red = 25, .green = 25, .blue = 112 },
    .{ .name = "mintcream", .red = 245, .green = 255, .blue = 250 },
    .{ .name = "mistyrose", .red = 255, .green = 228, .blue = 225 },
    .{ .name = "moccasin", .red = 255, .green = 228, .blue = 181 },
    .{ .name = "navajowhite", .red = 255, .green = 222, .blue = 173 },
    .{ .name = "navy", .red = 0, .green = 0, .blue = 128 },
    .{ .name = "oldlace", .red = 253, .green = 245, .blue = 230 },
    .{ .name = "olive", .red = 128, .green = 128, .blue = 0 },
    .{ .name = "olivedrab", .red = 107, .green = 142, .blue = 35 },
    .{ .name = "orange", .red = 255, .green = 165, .blue = 0 },
    .{ .name = "orangered", .red = 255, .green = 69, .blue = 0 },
    .{ .name = "orchid", .red = 218, .green = 112, .blue = 214 },
    .{ .name = "palegoldenrod", .red = 238, .green = 232, .blue = 170 },
    .{ .name = "palegreen", .red = 152, .green = 251, .blue = 152 },
    .{ .name = "paleturquoise", .red = 175, .green = 238, .blue = 238 },
    .{ .name = "palevioletred", .red = 219, .green = 112, .blue = 147 },
    .{ .name = "papayawhip", .red = 255, .green = 239, .blue = 213 },
    .{ .name = "peachpuff", .red = 255, .green = 218, .blue = 185 },
    .{ .name = "peru", .red = 205, .green = 133, .blue = 63 },
    .{ .name = "pink", .red = 255, .green = 192, .blue = 203 },
    .{ .name = "plum", .red = 221, .green = 160, .blue = 221 },
    .{ .name = "powderblue", .red = 176, .green = 224, .blue = 230 },
    .{ .name = "purple", .red = 128, .green = 0, .blue = 128 },
    .{ .name = "rebeccapurple", .red = 102, .green = 51, .blue = 153 },
    .{ .name = "red", .red = 255, .green = 0, .blue = 0 },
    .{ .name = "rosybrown", .red = 188, .green = 143, .blue = 143 },
    .{ .name = "royalblue", .red = 65, .green = 105, .blue = 225 },
    .{ .name = "saddlebrown", .red = 139, .green = 69, .blue = 19 },
    .{ .name = "salmon", .red = 250, .green = 128, .blue = 114 },
    .{ .name = "sandybrown", .red = 244, .green = 164, .blue = 96 },
    .{ .name = "seagreen", .red = 46, .green = 139, .blue = 87 },
    .{ .name = "seashell", .red = 255, .green = 245, .blue = 238 },
    .{ .name = "sienna", .red = 160, .green = 82, .blue = 45 },
    .{ .name = "silver", .red = 192, .green = 192, .blue = 192 },
    .{ .name = "skyblue", .red = 135, .green = 206, .blue = 235 },
    .{ .name = "slateblue", .red = 106, .green = 90, .blue = 205 },
    .{ .name = "slategray", .red = 112, .green = 128, .blue = 144 },
    .{ .name = "slategrey", .red = 112, .green = 128, .blue = 144 },
    .{ .name = "snow", .red = 255, .green = 250, .blue = 250 },
    .{ .name = "springgreen", .red = 0, .green = 255, .blue = 127 },
    .{ .name = "steelblue", .red = 70, .green = 130, .blue = 180 },
    .{ .name = "tan", .red = 210, .green = 180, .blue = 140 },
    .{ .name = "teal", .red = 0, .green = 128, .blue = 128 },
    .{ .name = "thistle", .red = 216, .green = 191, .blue = 216 },
    .{ .name = "tomato", .red = 255, .green = 99, .blue = 71 },
    .{ .name = "turquoise", .red = 64, .green = 224, .blue = 208 },
    .{ .name = "violet", .red = 238, .green = 130, .blue = 238 },
    .{ .name = "wheat", .red = 245, .green = 222, .blue = 179 },
    .{ .name = "white", .red = 255, .green = 255, .blue = 255 },
    .{ .name = "whitesmoke", .red = 245, .green = 245, .blue = 245 },
    .{ .name = "yellow", .red = 255, .green = 255, .blue = 0 },
    .{ .name = "yellowgreen", .red = 154, .green = 205, .blue = 50 },
};

pub fn parseLiteral(input: []const u8) ?native_value.Color {
    if (input.len == 0) return null;
    if (input[0] == '#') return parseHex(input[1..]);
    if (std.ascii.eqlIgnoreCase(input, "transparent")) {
        return rgbUnchecked(0, 0, 0, 0);
    }
    for (named_colors) |entry| {
        if (std.ascii.eqlIgnoreCase(input, entry.name)) {
            return rgbUnchecked(
                @floatFromInt(entry.red),
                @floatFromInt(entry.green),
                @floatFromInt(entry.blue),
                1,
            );
        }
    }
    return null;
}

pub fn rgb(red: f64, green: f64, blue: f64, alpha: f64) Error!native_value.Color {
    if (!allFinite(.{ red, green, blue, alpha })) return error.InvalidColor;
    return rgbUnchecked(
        clamp(red, 0, 255),
        clamp(green, 0, 255),
        clamp(blue, 0, 255),
        clamp(alpha, 0, 1),
    );
}

pub fn hsl(hue: f64, saturation: f64, lightness: f64, alpha: f64) Error!native_value.Color {
    if (!allFinite(.{ hue, saturation, lightness, alpha })) return error.InvalidColor;
    return .{
        .space = .hsl,
        .channels = .{ normalizeHue(hue), saturation, lightness, clamp(alpha, 0, 1) },
    };
}

pub fn hwb(hue: f64, whiteness: f64, blackness: f64, alpha: f64) Error!native_value.Color {
    if (!allFinite(.{ hue, whiteness, blackness, alpha })) return error.InvalidColor;
    var white = clamp(whiteness, 0, 100);
    var black = clamp(blackness, 0, 100);
    const total = white + black;
    if (total > 100) {
        white = white / total * 100;
        black = black / total * 100;
    }
    return .{
        .space = .hwb,
        .channels = .{ normalizeHue(hue), white, black, clamp(alpha, 0, 1) },
    };
}

pub fn modern(
    space: native_value.ColorSpace,
    input_channels: [4]f64,
    missing_mask: u4,
) Error!native_value.Color {
    if (!isLabSpace(space)) return error.InvalidColor;
    var channels = input_channels;
    for (&channels, 0..) |*channel, index| {
        if (channelMissing(missing_mask, index)) {
            channel.* = 0;
        } else if (!std.math.isFinite(channel.*)) {
            return error.InvalidColor;
        }
    }

    if (!channelMissing(missing_mask, 0)) {
        channels[0] = switch (space) {
            .lab, .lch => clamp(channels[0], 0, 100),
            .oklab, .oklch => clamp(channels[0], 0, 1),
            else => unreachable,
        };
    }
    if ((space == .lch or space == .oklch) and !channelMissing(missing_mask, 1)) {
        channels[1] = @max(0, channels[1]);
    }
    if ((space == .lch or space == .oklch) and !channelMissing(missing_mask, 2)) {
        channels[2] = normalizeHue(channels[2]);
    }
    if (!channelMissing(missing_mask, 3)) channels[3] = clamp(channels[3], 0, 1);
    return .{ .space = space, .channels = channels, .missing_mask = missing_mask };
}

pub fn predefined(
    space: native_value.ColorSpace,
    input_channels: [4]f64,
    missing_mask: u4,
) Error!native_value.Color {
    if (!isPredefinedSpace(space)) return error.InvalidColor;
    var channels = input_channels;
    for (&channels, 0..) |*channel, index| {
        if (channelMissing(missing_mask, index)) {
            channel.* = 0;
        } else if (!std.math.isFinite(channel.*)) {
            return error.InvalidColor;
        }
    }
    if (!channelMissing(missing_mask, 3)) channels[3] = clamp(channels[3], 0, 1);
    return .{ .space = space, .channels = channels, .missing_mask = missing_mask };
}

pub fn toRgb(input: native_value.Color) Error![4]f64 {
    return switch (input.space) {
        .rgb => input.channels,
        .hsl => hslToRgb(input.channels),
        .hwb => hwbToRgb(input.channels),
        else => error.InvalidColor,
    };
}

pub fn toHsl(input: native_value.Color) Error![4]f64 {
    if (input.space == .hsl) return input.channels;
    const channels = try toRgb(input);
    const red = channels[0] / 255;
    const green = channels[1] / 255;
    const blue = channels[2] / 255;
    const maximum = @max(red, @max(green, blue));
    const minimum = @min(red, @min(green, blue));
    const delta = maximum - minimum;
    const lightness = (maximum + minimum) / 2;
    var hue: f64 = 0;
    var saturation: f64 = 0;
    if (!approximatelyEqual(delta, 0)) {
        saturation = delta / (1 - @abs(2 * lightness - 1));
        hue = if (approximatelyEqual(maximum, red))
            60 * @mod((green - blue) / delta, 6)
        else if (approximatelyEqual(maximum, green))
            60 * ((blue - red) / delta + 2)
        else
            60 * ((red - green) / delta + 4);
    }
    return .{ normalizeHue(hue), saturation * 100, lightness * 100, channels[3] };
}

pub fn toHwb(input: native_value.Color) Error![4]f64 {
    if (input.space == .hwb) return input.channels;
    const channels = try toRgb(input);
    const red = channels[0] / 255;
    const green = channels[1] / 255;
    const blue = channels[2] / 255;
    const hsl_channels = try toHsl(input);
    return .{
        hsl_channels[0],
        @min(red, @min(green, blue)) * 100,
        (1 - @max(red, @max(green, blue))) * 100,
        channels[3],
    };
}

pub fn equal(left: native_value.Color, right: native_value.Color) bool {
    if (isTypedColorSpace(left.space) or isTypedColorSpace(right.space)) {
        if (left.space != right.space or left.missing_mask != right.missing_mask) return false;
        for (left.channels, right.channels, 0..) |left_channel, right_channel, index| {
            if (channelMissing(left.missing_mask, index)) continue;
            if (!approximatelyEqual(left_channel, right_channel)) return false;
        }
        return true;
    }
    const left_rgb = toRgb(left) catch return false;
    const right_rgb = toRgb(right) catch return false;
    for (left_rgb, right_rgb) |left_channel, right_channel| {
        if (!approximatelyEqual(left_channel, right_channel)) return false;
    }
    return true;
}

pub fn mix(
    first: native_value.Color,
    second: native_value.Color,
    weight: f64,
) Error!native_value.Color {
    if (!std.math.isFinite(weight) or weight < 0 or weight > 100) return error.InvalidColor;
    const first_rgb = try toRgb(first);
    const second_rgb = try toRgb(second);
    const proportion = weight / 100;
    const balance = proportion * 2 - 1;
    const alpha_delta = first_rgb[3] - second_rgb[3];
    const denominator = 1 + balance * alpha_delta;
    const combined = if (approximatelyEqual(denominator, 0))
        balance
    else
        (balance + alpha_delta) / denominator;
    const first_weight = (combined + 1) / 2;
    const second_weight = 1 - first_weight;
    return rgb(
        first_rgb[0] * first_weight + second_rgb[0] * second_weight,
        first_rgb[1] * first_weight + second_rgb[1] * second_weight,
        first_rgb[2] * first_weight + second_rgb[2] * second_weight,
        first_rgb[3] * proportion + second_rgb[3] * (1 - proportion),
    );
}

pub fn adjustLightness(input: native_value.Color, amount: f64) Error!native_value.Color {
    if (!std.math.isFinite(amount)) return error.InvalidColor;
    var channels = try toHsl(input);
    channels[2] = clamp(channels[2] + amount, 0, 100);
    return rgbFromChannels(hslToRgb(channels));
}

pub fn adjustSaturation(input: native_value.Color, amount: f64) Error!native_value.Color {
    if (!std.math.isFinite(amount)) return error.InvalidColor;
    var channels = try toHsl(input);
    channels[1] = clamp(channels[1] + amount, 0, 100);
    return rgbFromChannels(hslToRgb(channels));
}

pub fn adjustHue(input: native_value.Color, amount: f64) Error!native_value.Color {
    if (!std.math.isFinite(amount)) return error.InvalidColor;
    var channels = try toHsl(input);
    channels[0] = normalizeHue(channels[0] + amount);
    return rgbFromChannels(hslToRgb(channels));
}

pub fn grayscale(input: native_value.Color) Error!native_value.Color {
    var channels = try toHsl(input);
    channels[1] = 0;
    return rgbFromChannels(hslToRgb(channels));
}

pub fn invert(input: native_value.Color, weight: f64) Error!native_value.Color {
    const channels = try toRgb(input);
    const inverted = try rgb(
        255 - channels[0],
        255 - channels[1],
        255 - channels[2],
        channels[3],
    );
    return mix(inverted, input, weight);
}

pub fn adjustAlpha(input: native_value.Color, amount: f64) Error!native_value.Color {
    if (!std.math.isFinite(amount)) return error.InvalidColor;
    var result = input;
    result.channels[3] = clamp(result.channels[3] + amount, 0, 1);
    return result;
}

pub fn transformRgb(
    input: native_value.Color,
    kind: TransformKind,
    transform: RgbTransform,
) Error!native_value.Color {
    try validateOptionalChannels(.{
        transform.red,
        transform.green,
        transform.blue,
        transform.alpha,
    });
    const has_color_channel = transform.red != null or
        transform.green != null or transform.blue != null;
    if (!has_color_channel and transform.alpha == null) return input;

    var result = input;
    if (has_color_channel) {
        var channels = try toRgb(input);
        channels[0] = try transformBoundedChannel(channels[0], transform.red, kind, 255);
        channels[1] = try transformBoundedChannel(channels[1], transform.green, kind, 255);
        channels[2] = try transformBoundedChannel(channels[2], transform.blue, kind, 255);
        result = .{ .space = .rgb, .channels = channels };
    }
    result.channels[3] = try transformAlpha(result.channels[3], transform.alpha, kind);
    return result;
}

pub fn transformHsl(
    input: native_value.Color,
    kind: TransformKind,
    transform: HslTransform,
) Error!native_value.Color {
    try validateOptionalChannels(.{
        transform.hue,
        transform.saturation,
        transform.lightness,
        transform.alpha,
    });
    if (kind == .scale and transform.hue != null) return error.InvalidColor;
    const has_color_channel = transform.hue != null or
        transform.saturation != null or transform.lightness != null;
    if (!has_color_channel and transform.alpha == null) return input;

    var result = input;
    if (has_color_channel) {
        var channels = try toHsl(input);
        if (transform.hue) |value| {
            channels[0] = normalizeHue(switch (kind) {
                .adjust => channels[0] + value,
                .change => value,
                .scale => unreachable,
            });
        }
        channels[1] = try transformUnboundedChannel(
            channels[1],
            transform.saturation,
            kind,
            100,
        );
        channels[2] = try transformUnboundedChannel(
            channels[2],
            transform.lightness,
            kind,
            100,
        );
        result = .{ .space = .hsl, .channels = channels };
    }
    result.channels[3] = try transformAlpha(result.channels[3], transform.alpha, kind);
    return result;
}

pub fn transformHwb(
    input: native_value.Color,
    kind: TransformKind,
    transform: HwbTransform,
) Error!native_value.Color {
    try validateOptionalChannels(.{
        transform.hue,
        transform.whiteness,
        transform.blackness,
        transform.alpha,
    });
    if (kind == .scale and transform.hue != null) return error.InvalidColor;
    const has_color_channel = transform.hue != null or
        transform.whiteness != null or transform.blackness != null;
    if (!has_color_channel and transform.alpha == null) return input;

    var result = input;
    if (has_color_channel) {
        var channels = try toHwb(input);
        if (transform.hue) |value| {
            channels[0] = normalizeHue(switch (kind) {
                .adjust => channels[0] + value,
                .change => value,
                .scale => unreachable,
            });
        }
        channels[1] = try transformUnboundedChannel(
            channels[1],
            transform.whiteness,
            kind,
            100,
        );
        channels[2] = try transformUnboundedChannel(
            channels[2],
            transform.blackness,
            kind,
            100,
        );
        result = .{ .space = .hwb, .channels = channels };
    }
    result.channels[3] = try transformAlpha(result.channels[3], transform.alpha, kind);
    return result;
}

pub fn serialize(
    input: native_value.Color,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    if (isLabSpace(input.space)) return serializeModern(input, buffer, minified);
    if (isPredefinedSpace(input.space)) return serializePredefined(input, buffer, minified);
    if (input.space == .rgb and
        (input.channels[0] < 0 or input.channels[0] > 255 or
            input.channels[1] < 0 or input.channels[1] > 255 or
            input.channels[2] < 0 or input.channels[2] > 255))
    {
        return serializeFunctional(
            try toHsl(input),
            "hsl",
            "hsla",
            buffer,
            minified,
            true,
        );
    }
    if (input.space == .hsl and
        (input.channels[1] < 0 or input.channels[1] > 100 or
            input.channels[2] < 0 or input.channels[2] > 100))
    {
        return serializeFunctional(input.channels, "hsl", "hsla", buffer, minified, true);
    }
    const channels = try toRgb(input);
    if (!allFinite(channels)) return error.InvalidColor;
    if (approximatelyEqual(channels[3], 1)) {
        if (exactRgb(channels)) |exact| return serializeExact(exact, buffer);
    }
    if (input.space == .hwb and approximatelyEqual(input.channels[1] + input.channels[2], 100)) {
        const grayscale_channels = [4]f64{
            input.channels[0],
            0,
            input.channels[1],
            input.channels[3],
        };
        return serializeFunctional(grayscale_channels, "hsl", "hsla", buffer, minified, true);
    }

    var rgb_buffer: [max_serialized_bytes]u8 = undefined;
    const rgb_candidate = try serializeFunctional(
        channels,
        "rgb",
        "rgba",
        &rgb_buffer,
        minified,
        false,
    );
    const hsl_channels = if (input.space == .hsl) input.channels else try toHsl(input);
    var hsl_buffer: [max_serialized_bytes]u8 = undefined;
    const hsl_candidate = try serializeFunctional(
        hsl_channels,
        "hsl",
        "hsla",
        &hsl_buffer,
        minified,
        true,
    );
    const may_use_hsl = input.space == .hsl or input.space == .hwb or
        (input.space == .rgb and simpleHsl(hsl_channels));
    const selected = if (may_use_hsl and hsl_candidate.len < rgb_candidate.len)
        hsl_candidate
    else
        rgb_candidate;
    var cursor: usize = 0;
    try append(buffer, &cursor, selected);
    return buffer[0..cursor];
}

fn serializeModern(
    input: native_value.Color,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    const normalized = try modern(input.space, input.channels, input.missing_mask);
    const name: []const u8 = switch (normalized.space) {
        .lab => "lab",
        .lch => "lch",
        .oklab => "oklab",
        .oklch => "oklch",
        else => unreachable,
    };
    var cursor: usize = 0;
    try append(buffer, &cursor, name);
    try append(buffer, &cursor, "(");
    for (normalized.channels[0..3], 0..) |channel, index| {
        if (index > 0) try append(buffer, &cursor, " ");
        if (channelMissing(normalized.missing_mask, index)) {
            try append(buffer, &cursor, "none");
            continue;
        }
        var number_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        try appendModernNumber(buffer, &cursor, channel, &number_buffer, minified);
    }
    if (channelMissing(normalized.missing_mask, 3) or
        !approximatelyEqual(normalized.channels[3], 1))
    {
        try append(buffer, &cursor, if (minified) "/" else " / ");
        if (channelMissing(normalized.missing_mask, 3)) {
            try append(buffer, &cursor, "none");
        } else {
            var alpha_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
            try appendModernNumber(
                buffer,
                &cursor,
                normalized.channels[3],
                &alpha_buffer,
                minified,
            );
        }
    }
    try append(buffer, &cursor, ")");
    return buffer[0..cursor];
}

fn serializePredefined(
    input: native_value.Color,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    const normalized = try predefined(input.space, input.channels, input.missing_mask);
    const space_name: []const u8 = switch (normalized.space) {
        .srgb => "srgb",
        .srgb_linear => "srgb-linear",
        .display_p3 => "display-p3",
        .a98_rgb => "a98-rgb",
        .prophoto_rgb => "prophoto-rgb",
        .rec2020 => "rec2020",
        .xyz_d50 => "xyz-d50",
        .xyz => "xyz",
        else => unreachable,
    };
    var cursor: usize = 0;
    try append(buffer, &cursor, "color(");
    try append(buffer, &cursor, space_name);
    for (normalized.channels[0..3], 0..) |channel, index| {
        try append(buffer, &cursor, " ");
        if (channelMissing(normalized.missing_mask, index)) {
            try append(buffer, &cursor, "none");
            continue;
        }
        var number_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        try appendModernNumber(buffer, &cursor, channel, &number_buffer, minified);
    }
    if (channelMissing(normalized.missing_mask, 3) or
        !approximatelyEqual(normalized.channels[3], 1))
    {
        try append(buffer, &cursor, if (minified) "/" else " / ");
        if (channelMissing(normalized.missing_mask, 3)) {
            try append(buffer, &cursor, "none");
        } else {
            var alpha_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
            try appendModernNumber(
                buffer,
                &cursor,
                normalized.channels[3],
                &alpha_buffer,
                minified,
            );
        }
    }
    try append(buffer, &cursor, ")");
    return buffer[0..cursor];
}

pub fn serializeIeHex(input: native_value.Color, buffer: *[9]u8) Error![]const u8 {
    const channels = try toRgb(input);
    if (!allFinite(channels)) return error.InvalidColor;
    const bytes = [4]u8{
        @intFromFloat(@round(clamp(channels[3], 0, 1) * 255)),
        @intFromFloat(@round(clamp(channels[0], 0, 255))),
        @intFromFloat(@round(clamp(channels[1], 0, 255))),
        @intFromFloat(@round(clamp(channels[2], 0, 255))),
    };
    buffer[0] = '#';
    for (bytes, 0..) |byte, index| writeUpperHexByte(buffer[1 + index * 2 ..], byte);
    return buffer;
}

fn parseHex(input: []const u8) ?native_value.Color {
    if (input.len != 3 and input.len != 4 and input.len != 6 and input.len != 8) return null;
    for (input) |byte| _ = hexNibble(byte) orelse return null;
    const red: u8 = if (input.len <= 4)
        hexNibble(input[0]).? * 17
    else
        hexByte(input[0], input[1]);
    const green: u8 = if (input.len <= 4)
        hexNibble(input[1]).? * 17
    else
        hexByte(input[2], input[3]);
    const blue: u8 = if (input.len <= 4)
        hexNibble(input[2]).? * 17
    else
        hexByte(input[4], input[5]);
    const alpha: u8 = if (input.len == 4)
        hexNibble(input[3]).? * 17
    else if (input.len == 8)
        hexByte(input[6], input[7])
    else
        255;
    return rgbUnchecked(
        @floatFromInt(red),
        @floatFromInt(green),
        @floatFromInt(blue),
        @as(f64, @floatFromInt(alpha)) / 255,
    );
}

fn rgbUnchecked(red: f64, green: f64, blue: f64, alpha: f64) native_value.Color {
    return .{ .space = .rgb, .channels = .{ red, green, blue, alpha } };
}

fn rgbFromChannels(channels: [4]f64) Error!native_value.Color {
    return rgb(channels[0], channels[1], channels[2], channels[3]);
}

fn hslToRgb(channels: [4]f64) [4]f64 {
    const hue = normalizeHue(channels[0]);
    const saturation = channels[1] / 100;
    const lightness = channels[2] / 100;
    const chroma = (1 - @abs(2 * lightness - 1)) * saturation;
    const section = hue / 60;
    const secondary = chroma * (1 - @abs(@mod(section, 2) - 1));
    const partial: [3]f64 = if (section < 1)
        .{ chroma, secondary, 0 }
    else if (section < 2)
        .{ secondary, chroma, 0 }
    else if (section < 3)
        .{ 0, chroma, secondary }
    else if (section < 4)
        .{ 0, secondary, chroma }
    else if (section < 5)
        .{ secondary, 0, chroma }
    else
        .{ chroma, 0, secondary };
    const match = lightness - chroma / 2;
    return .{
        (partial[0] + match) * 255,
        (partial[1] + match) * 255,
        (partial[2] + match) * 255,
        channels[3],
    };
}

fn hwbToRgb(channels: [4]f64) [4]f64 {
    const base = hslToRgb(.{ channels[0], 100, 50, channels[3] });
    var white = channels[1] / 100;
    var black = channels[2] / 100;
    const total = white + black;
    if (total > 1) {
        white /= total;
        black /= total;
    }
    const factor = 1 - white - black;
    return .{
        (base[0] / 255 * factor + white) * 255,
        (base[1] / 255 * factor + white) * 255,
        (base[2] / 255 * factor + white) * 255,
        channels[3],
    };
}

fn serializeFunctional(
    channels: [4]f64,
    opaque_name: []const u8,
    alpha_name: []const u8,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
    hsl_units: bool,
) Error![]const u8 {
    const has_alpha = !approximatelyEqual(channels[3], 1);
    const name = if (has_alpha) alpha_name else opaque_name;
    var cursor: usize = 0;
    try append(buffer, &cursor, name);
    try append(buffer, &cursor, "(");
    const channel_count: usize = if (has_alpha) 4 else 3;
    for (channels[0..channel_count], 0..) |channel, index| {
        if (index > 0) try append(buffer, &cursor, ",");
        var number_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        const serialized = try native_numeric.serialize(channel, &number_buffer, minified);
        try append(buffer, &cursor, serialized);
        if (hsl_units and (index == 1 or index == 2)) try append(buffer, &cursor, "%");
    }
    try append(buffer, &cursor, ")");
    return buffer[0..cursor];
}

fn serializeExact(channels: [3]u8, buffer: *[max_serialized_bytes]u8) Error![]const u8 {
    const compressed = compressible(channels[0]) and
        compressible(channels[1]) and compressible(channels[2]);
    const hex_length: usize = if (compressed) 4 else 7;
    if (shortestName(channels, hex_length)) |name| return name;
    buffer[0] = '#';
    if (compressed) {
        buffer[1] = hexDigit(channels[0] & 0x0f);
        buffer[2] = hexDigit(channels[1] & 0x0f);
        buffer[3] = hexDigit(channels[2] & 0x0f);
        return buffer[0..4];
    }
    writeHexByte(buffer[1..], channels[0]);
    writeHexByte(buffer[3..], channels[1]);
    writeHexByte(buffer[5..], channels[2]);
    return buffer[0..7];
}

fn exactRgb(channels: [4]f64) ?[3]u8 {
    var result: [3]u8 = undefined;
    for (channels[0..3], 0..) |channel, index| {
        const rounded = @round(channel);
        if (rounded < 0 or rounded > 255 or !approximatelyEqual(channel, rounded)) return null;
        result[index] = @intFromFloat(rounded);
    }
    return result;
}

fn simpleHsl(channels: [4]f64) bool {
    for (channels[0..3]) |channel| {
        const scaled = channel * 10_000;
        if (!std.math.isFinite(scaled) or @abs(scaled - @round(scaled)) > 1e-7) return false;
    }
    return true;
}

fn shortestName(channels: [3]u8, hex_length: usize) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (named_colors) |entry| {
        if (entry.red != channels[0] or entry.green != channels[1] or entry.blue != channels[2]) {
            continue;
        }
        if (entry.name.len > hex_length) continue;
        if (result == null or entry.name.len < result.?.len) result = entry.name;
    }
    return result;
}

fn append(buffer: *[max_serialized_bytes]u8, cursor: *usize, bytes: []const u8) Error!void {
    if (cursor.* + bytes.len > buffer.len) return error.SerializationLimitExceeded;
    @memcpy(buffer[cursor.* .. cursor.* + bytes.len], bytes);
    cursor.* += bytes.len;
}

fn appendModernNumber(
    buffer: *[max_serialized_bytes]u8,
    cursor: *usize,
    value: f64,
    number_buffer: *[native_numeric.max_serialized_bytes]u8,
    minified: bool,
) Error!void {
    const serialized = try native_numeric.serialize(value, number_buffer, minified);
    if (serialized.len >= 2 and serialized[0] == '-' and serialized[1] == '.') {
        try append(buffer, cursor, "-0");
        return append(buffer, cursor, serialized[1..]);
    }
    return append(buffer, cursor, serialized);
}

fn isLabSpace(space: native_value.ColorSpace) bool {
    return switch (space) {
        .lab, .lch, .oklab, .oklch => true,
        else => false,
    };
}

fn isPredefinedSpace(space: native_value.ColorSpace) bool {
    return switch (space) {
        .srgb,
        .srgb_linear,
        .display_p3,
        .a98_rgb,
        .prophoto_rgb,
        .rec2020,
        .xyz_d50,
        .xyz,
        => true,
        else => false,
    };
}

fn isTypedColorSpace(space: native_value.ColorSpace) bool {
    return isLabSpace(space) or isPredefinedSpace(space);
}

fn channelMissing(mask: u4, index: usize) bool {
    return (mask & (@as(u4, 1) << @intCast(index))) != 0;
}

fn normalizeHue(value: f64) f64 {
    const result = value - @floor(value / 360) * 360;
    return if (approximatelyEqual(result, 360) or approximatelyEqual(result, 0)) 0 else result;
}

fn clamp(value: f64, minimum: f64, maximum: f64) f64 {
    return @max(minimum, @min(maximum, value));
}

fn transformBoundedChannel(
    current: f64,
    change: ?f64,
    kind: TransformKind,
    maximum: f64,
) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => clamp(current + value, 0, maximum),
        .change => value,
        .scale => try scaleChannel(current, value, maximum),
    };
}

fn transformUnboundedChannel(
    current: f64,
    change: ?f64,
    kind: TransformKind,
    maximum: f64,
) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => current + value,
        .change => value,
        .scale => try scaleChannel(current, value, maximum),
    };
}

fn transformAlpha(current: f64, change: ?f64, kind: TransformKind) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => clamp(current + value, 0, 1),
        .change => if (value >= 0 and value <= 1) value else error.InvalidColor,
        .scale => try scaleChannel(current, value, 1),
    };
}

fn scaleChannel(current: f64, percentage: f64, maximum: f64) Error!f64 {
    if (!std.math.isFinite(percentage) or percentage < -100 or percentage > 100) {
        return error.InvalidColor;
    }
    const proportion = percentage / 100;
    return if (proportion > 0)
        current + (maximum - current) * proportion
    else
        current + current * proportion;
}

fn validateOptionalChannels(channels: [4]?f64) Error!void {
    for (channels) |channel| {
        if (channel) |value| {
            if (!std.math.isFinite(value)) return error.InvalidColor;
        }
    }
}

fn allFinite(channels: [4]f64) bool {
    for (channels) |channel| if (!std.math.isFinite(channel)) return false;
    return true;
}

fn approximatelyEqual(left: f64, right: f64) bool {
    if (left == right) return true;
    const scale = @max(1, @max(@abs(left), @abs(right)));
    return @abs(left - right) <= 1e-10 * scale;
}

fn compressible(value: u8) bool {
    return value >> 4 == value & 0x0f;
}

fn writeHexByte(buffer: []u8, value: u8) void {
    buffer[0] = hexDigit(value >> 4);
    buffer[1] = hexDigit(value & 0x0f);
}

fn writeUpperHexByte(buffer: []u8, value: u8) void {
    buffer[0] = "0123456789ABCDEF"[value >> 4];
    buffer[1] = "0123456789ABCDEF"[value & 0x0f];
}

fn hexByte(high: u8, low: u8) u8 {
    return (hexNibble(high).? << 4) | hexNibble(low).?;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn hexDigit(value: u8) u8 {
    return "0123456789abcdef"[value];
}
