//! Allocation-free Sass color semantics for the private native evaluator.
//! The tables, transfer functions, and conversion matrices are compiled into
//! ZigCSS; no runtime stylesheet provider or package is consulted.

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

pub const GamutMapMethod = enum {
    clip,
    local_minde,
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

pub const ModernTransform = struct {
    channels: [3]?f64 = .{ null, null, null },
    alpha: ?f64 = null,
};

const Vec3 = [3]f64;
const Matrix3 = [3][3]f64;

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
    var white = whiteness;
    var black = blackness;
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
    return rgbToHsl(try toRgb(input));
}

pub fn toHwb(input: native_value.Color) Error![4]f64 {
    if (input.space == .hwb) return input.channels;
    return rgbToHwb(try toRgb(input));
}

/// Converts between every color space represented by the native value model.
/// The conversion pipeline is allocation-free and preserves extended-gamut
/// channel values. Missing components are currently accepted only for an
/// identity conversion so unsupported propagation cannot silently change CSS.
pub fn convert(
    input: native_value.Color,
    target: native_value.ColorSpace,
) Error!native_value.Color {
    if (input.space == target) return input;
    if (input.missing_mask != 0 or !allFinite(input.channels)) {
        return error.InvalidColor;
    }

    const xyz_d65 = colorToXyzD65(input);
    var result = xyzD65ToColor(xyz_d65, target, input.channels[3]);
    if (!allFinite(result.channels)) return error.InvalidColor;
    result.channels[3] = input.channels[3];
    return result;
}

/// Reports whether a color is within the bounded channels of its stored or
/// requested color space. Per Sass, alpha and hue are excluded from gamut
/// checks, missing channels are treated as zero, and perceptual/XYZ spaces are
/// unbounded. Cross-space conversion remains fail-closed for missing channels.
pub fn isInGamut(
    input: native_value.Color,
    target: ?native_value.ColorSpace,
) Error!bool {
    const color = if (target) |space| try convert(input, space) else input;
    return switch (color.space) {
        .rgb => gamutChannelsWithin(color, 0, 3, 0, 255),
        .hsl, .hwb => gamutChannelsWithin(color, 1, 3, 0, 100),
        .srgb,
        .srgb_linear,
        .display_p3,
        .a98_rgb,
        .prophoto_rgb,
        .rec2020,
        => gamutChannelsWithin(color, 0, 3, 0, 1),
        .lab, .lch, .oklab, .oklch, .xyz_d50, .xyz => true,
    };
}

/// Maps a complete color into a bounded stored or requested space and converts
/// it back to its original space. Missing-channel propagation remains
/// deliberately unavailable until the native value model can preserve Sass's
/// analogous-channel rules across conversions.
pub fn toGamut(
    input: native_value.Color,
    target: ?native_value.ColorSpace,
    method: GamutMapMethod,
) Error!native_value.Color {
    if (input.missing_mask != 0 or !allFinite(input.channels)) {
        return error.InvalidColor;
    }
    const target_space = target orelse input.space;
    if (!isBoundedSpace(target_space)) return input;

    var working = try convert(input, target_space);
    var mapped = false;
    if (!(try isInGamut(working, null))) {
        working = switch (method) {
            .clip => clipGamut(working),
            .local_minde => try localMindeGamut(working),
        };
        mapped = true;
    }

    var result = if (working.space == input.space)
        working
    else
        try convert(working, input.space);
    if (mapped and method == .local_minde and legacyPolarHuePowerless(result)) {
        return error.InvalidColor;
    }
    result.computed = input.computed or mapped or target_space != input.space;
    return result;
}

fn clipGamut(input: native_value.Color) native_value.Color {
    var result = input;
    switch (result.space) {
        .rgb => clampGamutChannels(&result, 0, 3, 0, 255),
        .hsl, .hwb => clampGamutChannels(&result, 1, 3, 0, 100),
        .srgb,
        .srgb_linear,
        .display_p3,
        .a98_rgb,
        .prophoto_rgb,
        .rec2020,
        => clampGamutChannels(&result, 0, 3, 0, 1),
        .lab, .lch, .oklab, .oklch, .xyz_d50, .xyz => {},
    }
    return result;
}

fn clampGamutChannels(
    color: *native_value.Color,
    start: usize,
    end: usize,
    minimum: f64,
    maximum: f64,
) void {
    for (start..end) |index| {
        if (channelMissing(color.missing_mask, index)) continue;
        color.channels[index] = clamp(color.channels[index], minimum, maximum);
    }
}

fn localMindeGamut(input: native_value.Color) Error!native_value.Color {
    const origin_oklch = try convert(input, .oklch);
    const lightness = origin_oklch.channels[0];
    const hue = origin_oklch.channels[2];
    const alpha = origin_oklch.channels[3];
    if (lightness > 1 or fuzzyEqual(lightness, 1)) {
        return whiteInSpace(input.space, alpha);
    }
    if (lightness < 0 or fuzzyEqual(lightness, 0)) {
        return try convert(rgbUnchecked(0, 0, 0, alpha), input.space);
    }

    var clipped = clipGamut(input);
    if (try deltaEOk(clipped, input) < 0.02) return clipped;

    var maximum = origin_oklch.channels[1];
    var minimum: f64 = 0;
    var minimum_in_gamut = true;
    var iteration: usize = 0;
    while (maximum - minimum > 0.0001) : (iteration += 1) {
        if (iteration >= 2048) return error.InvalidColor;
        const chroma = (minimum + maximum) / 2;
        const oklch = native_value.Color{
            .space = .oklch,
            .channels = .{ lightness, chroma, hue, alpha },
        };
        const current = try convert(oklch, input.space);
        const current_in_gamut = try isInGamut(current, null);
        if (minimum_in_gamut and current_in_gamut) {
            minimum = chroma;
            continue;
        }
        clipped = if (current_in_gamut) current else clipGamut(current);
        const difference = try deltaEOk(clipped, current);
        if (difference < 0.02) {
            if (0.02 - difference < 0.0001) return clipped;
            minimum = chroma;
            minimum_in_gamut = false;
        } else {
            maximum = chroma;
        }
    }
    return clipped;
}

fn whiteInSpace(
    space: native_value.ColorSpace,
    alpha: f64,
) Error!native_value.Color {
    return switch (space) {
        .rgb, .hsl, .hwb => try convert(rgbUnchecked(255, 255, 255, alpha), space),
        .srgb,
        .srgb_linear,
        .display_p3,
        .a98_rgb,
        .prophoto_rgb,
        .rec2020,
        => colorFromChannels(space, .{ 1, 1, 1 }, alpha, 0),
        .lab, .lch, .oklab, .oklch, .xyz_d50, .xyz => error.InvalidColor,
    };
}

fn deltaEOk(
    left: native_value.Color,
    right: native_value.Color,
) Error!f64 {
    const left_oklab = try convert(left, .oklab);
    const right_oklab = try convert(right, .oklab);
    var sum: f64 = 0;
    for (left_oklab.channels[0..3], right_oklab.channels[0..3]) |a, b| {
        const difference = a - b;
        sum += difference * difference;
    }
    return @sqrt(sum);
}

fn gamutChannelsWithin(
    color: native_value.Color,
    start: usize,
    end: usize,
    minimum: f64,
    maximum: f64,
) bool {
    for (start..end) |index| {
        const channel = if (channelMissing(color.missing_mask, index))
            0
        else
            color.channels[index];
        if ((channel < minimum and !fuzzyEqual(channel, minimum)) or
            (channel > maximum and !fuzzyEqual(channel, maximum)))
        {
            return false;
        }
    }
    return true;
}

fn rgbToHsl(channels: [4]f64) [4]f64 {
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

fn rgbToHwb(channels: [4]f64) [4]f64 {
    const red = channels[0] / 255;
    const green = channels[1] / 255;
    const blue = channels[2] / 255;
    const hsl_channels = rgbToHsl(channels);
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

/// Implements sass:color.same() without changing the broader Sass equality
/// operator. Missing components are replaced with zero before comparison.
/// Colors in different spaces are compared after conversion to XYZ D65.
pub fn same(left: native_value.Color, right: native_value.Color) bool {
    const complete_left = replaceMissingWithZero(left);
    const complete_right = replaceMissingWithZero(right);
    if (left.space == right.space) {
        return fuzzyChannelsEqual(complete_left.channels, complete_right.channels);
    }
    const xyz_left = convert(complete_left, .xyz) catch return false;
    const xyz_right = convert(complete_right, .xyz) catch return false;
    return fuzzyChannelsEqual(xyz_left.channels, xyz_right.channels);
}

/// Implements sass:color.is-powerless() for a validated stored-space channel.
/// Missing dependencies are already represented as zero in owned colors.
pub fn isPowerless(input: native_value.Color, channel_index: usize) bool {
    return switch (input.space) {
        .hsl => channel_index == 0 and powerlessEqual(input.channels[1], 0),
        .hwb => channel_index == 0 and
            (input.channels[1] + input.channels[2] > 100 or
                powerlessEqual(input.channels[1] + input.channels[2], 100)),
        .lch, .oklch => channel_index == 2 and powerlessEqual(input.channels[1], 0),
        else => false,
    };
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
    return switch (input.space) {
        .rgb => rgbFromChannels(hslToRgb(channels)),
        .hsl, .hwb => hsl(channels[0], channels[1], channels[2], channels[3]),
        else => error.InvalidColor,
    };
}

pub fn adjustSaturation(input: native_value.Color, amount: f64) Error!native_value.Color {
    if (!std.math.isFinite(amount)) return error.InvalidColor;
    var channels = try toHsl(input);
    channels[1] = clamp(channels[1] + amount, 0, 100);
    return switch (input.space) {
        .rgb => rgbFromChannels(hslToRgb(channels)),
        .hsl, .hwb => hsl(channels[0], channels[1], channels[2], channels[3]),
        else => error.InvalidColor,
    };
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
    return switch (input.space) {
        .rgb, .hwb => rgbFromChannels(hslToRgb(channels)),
        .hsl => hsl(channels[0], channels[1], channels[2], channels[3]),
        else => error.InvalidColor,
    };
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

pub fn adjustLegacyAlpha(input: native_value.Color, amount: f64) Error!native_value.Color {
    if (!std.math.isFinite(amount)) return error.InvalidColor;
    var result = if (input.missing_mask != 0)
        replaceMissingWithZero(input)
    else switch (input.space) {
        .rgb => input,
        .hsl, .hwb => try rgbFromChannels(try toRgb(input)),
        else => return error.InvalidColor,
    };
    switch (result.space) {
        .rgb, .hsl, .hwb => {},
        else => return error.InvalidColor,
    }
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
        const preserve_typed_space = isTypedColorSpace(input.space);
        var channels = if (preserve_typed_space)
            (try convert(input, .rgb)).channels
        else
            try toRgb(input);
        channels[0] = try transformBoundedChannel(channels[0], transform.red, kind, 255);
        channels[1] = try transformBoundedChannel(channels[1], transform.green, kind, 255);
        channels[2] = try transformBoundedChannel(channels[2], transform.blue, kind, 255);
        const working = native_value.Color{ .space = .rgb, .channels = channels };
        result = if (preserve_typed_space) try convert(working, input.space) else working;
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
        const preserve_typed_space = isTypedColorSpace(input.space);
        var channels = if (preserve_typed_space)
            (try convert(input, .hsl)).channels
        else
            try toHsl(input);
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
        const working = native_value.Color{ .space = .hsl, .channels = channels };
        result = if (preserve_typed_space) try convert(working, input.space) else working;
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
        const preserve_typed_space = isTypedColorSpace(input.space);
        var channels = if (preserve_typed_space)
            (try convert(input, .hwb)).channels
        else
            try toHwb(input);
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
        const working = native_value.Color{ .space = .hwb, .channels = channels };
        result = if (preserve_typed_space) try convert(working, input.space) else working;
    }
    result.channels[3] = try transformAlpha(result.channels[3], transform.alpha, kind);
    return result;
}

pub fn transformModern(
    input: native_value.Color,
    selected_space: native_value.ColorSpace,
    kind: TransformKind,
    transform: ModernTransform,
) Error!native_value.Color {
    if (!isTypedColorSpace(selected_space)) return error.InvalidColor;
    try validateOptionalChannels(.{
        transform.channels[0],
        transform.channels[1],
        transform.channels[2],
        transform.alpha,
    });
    const has_color_channel = transform.channels[0] != null or
        transform.channels[1] != null or transform.channels[2] != null;
    if (!has_color_channel and transform.alpha == null) return input;

    var result = input;
    if (has_color_channel) {
        if (input.missing_mask != 0) return error.InvalidColor;
        var working = try convert(input, selected_space);
        if (working.missing_mask != 0) return error.InvalidColor;
        switch (selected_space) {
            .lab => {
                working.channels[0] = try transformLightness(
                    working.channels[0],
                    transform.channels[0],
                    kind,
                    100,
                );
                working.channels[1] = try transformSignedChannel(
                    working.channels[1],
                    transform.channels[1],
                    kind,
                    -125,
                    125,
                );
                working.channels[2] = try transformSignedChannel(
                    working.channels[2],
                    transform.channels[2],
                    kind,
                    -125,
                    125,
                );
            },
            .lch => {
                working.channels[0] = try transformLightness(
                    working.channels[0],
                    transform.channels[0],
                    kind,
                    100,
                );
                working.channels[1] = try transformChroma(
                    working.channels[1],
                    transform.channels[1],
                    kind,
                    150,
                );
                working.channels[2] = try transformHueChannel(
                    working.channels[2],
                    transform.channels[2],
                    kind,
                );
                normalizeNegativePolarChroma(&working.channels);
            },
            .oklab => {
                working.channels[0] = try transformLightness(
                    working.channels[0],
                    transform.channels[0],
                    kind,
                    1,
                );
                working.channels[1] = try transformSignedChannel(
                    working.channels[1],
                    transform.channels[1],
                    kind,
                    -0.4,
                    0.4,
                );
                working.channels[2] = try transformSignedChannel(
                    working.channels[2],
                    transform.channels[2],
                    kind,
                    -0.4,
                    0.4,
                );
            },
            .oklch => {
                working.channels[0] = try transformLightness(
                    working.channels[0],
                    transform.channels[0],
                    kind,
                    1,
                );
                working.channels[1] = try transformChroma(
                    working.channels[1],
                    transform.channels[1],
                    kind,
                    0.4,
                );
                working.channels[2] = try transformHueChannel(
                    working.channels[2],
                    transform.channels[2],
                    kind,
                );
                normalizeNegativePolarChroma(&working.channels);
            },
            .srgb,
            .srgb_linear,
            .display_p3,
            .a98_rgb,
            .prophoto_rgb,
            .rec2020,
            .xyz_d50,
            .xyz,
            => for (transform.channels, 0..) |change, index| {
                working.channels[index] = try transformUnboundedOrScale(
                    working.channels[index],
                    change,
                    kind,
                    0,
                    1,
                );
            },
            .rgb, .hsl, .hwb => unreachable,
        }
        result = if (input.space == selected_space)
            working
        else
            try convert(working, input.space);
    }
    result.channels[3] = try transformAlpha(input.channels[3], transform.alpha, kind);
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
            0,
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

pub fn serializePreferHex(
    input: native_value.Color,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    const channels = switch (input.space) {
        .rgb, .hsl, .hwb => try toRgb(input),
        else => return serialize(input, buffer, minified),
    };
    if (allFinite(channels) and approximatelyEqual(channels[3], 1)) {
        if (exactRgb(channels)) |exact| return serializeExactHex(exact, buffer);
    }
    return serialize(input, buffer, minified);
}

fn serializeModern(
    input: native_value.Color,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    if (!channelMissing(input.missing_mask, 0)) {
        const maximum: f64 = switch (input.space) {
            .lab, .lch => 100,
            .oklab, .oklch => 1,
            else => unreachable,
        };
        if (input.channels[0] < 0 or input.channels[0] > maximum) {
            return serializeOutOfRangeModern(input, buffer, minified);
        }
    }
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
        try appendModernNumber(
            buffer,
            &cursor,
            channel,
            &number_buffer,
            minified,
            input.computed,
        );
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
                input.computed,
            );
        }
    }
    try append(buffer, &cursor, ")");
    return buffer[0..cursor];
}

fn serializeOutOfRangeModern(
    input: native_value.Color,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    if (input.missing_mask != 0 or !allFinite(input.channels)) return error.InvalidColor;
    const space_name: []const u8 = switch (input.space) {
        .lab => "lab",
        .lch => "lch",
        .oklab => "oklab",
        .oklch => "oklch",
        else => unreachable,
    };
    const xyz = colorToXyzD65(input);
    var xyz_buffer: [max_serialized_bytes]u8 = undefined;
    const serialized_xyz = try serializeColorMixXyz(
        xyz,
        input.channels[3],
        &xyz_buffer,
        minified,
    );

    var cursor: usize = 0;
    try append(buffer, &cursor, "color-mix(in ");
    try append(buffer, &cursor, space_name);
    try append(buffer, &cursor, if (minified) "," else ", ");
    try append(buffer, &cursor, serialized_xyz);
    try append(buffer, &cursor, if (minified) "100%,red)" else " 100%, black)");
    return buffer[0..cursor];
}

fn serializeColorMixXyz(
    xyz: Vec3,
    alpha: f64,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    var cursor: usize = 0;
    try append(buffer, &cursor, "color(xyz");
    for (xyz) |channel| {
        var number_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        try append(buffer, &cursor, " ");
        try append(
            buffer,
            &cursor,
            try native_numeric.serialize(channel, &number_buffer, minified),
        );
    }
    if (!approximatelyEqual(alpha, 1)) {
        var alpha_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        try append(buffer, &cursor, if (minified) "/" else " / ");
        try append(
            buffer,
            &cursor,
            try native_numeric.serialize(alpha, &alpha_buffer, minified),
        );
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
        try appendModernNumber(
            buffer,
            &cursor,
            channel,
            &number_buffer,
            minified,
            input.computed,
        );
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
                input.computed,
            );
        }
    }
    try append(buffer, &cursor, ")");
    return buffer[0..cursor];
}

pub fn serializeIeHex(input: native_value.Color, buffer: *[9]u8) Error![]const u8 {
    const legacy = switch (input.space) {
        .rgb, .hsl, .hwb => true,
        else => false,
    };
    const channels = if (legacy)
        try toRgb(input)
    else
        (try convert(input, .rgb)).channels;
    // Dart Sass gamut-maps typed colors before producing its legacy IE form.
    // That function's exact implicit method and missing-channel behavior remain
    // a separate slice, so accept only exact in-gamut conversions here.
    if (!legacy) {
        for (channels[0..3]) |channel| {
            if (channel < 0 or channel > 255) return error.InvalidColor;
        }
    }
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

fn colorToXyzD65(input: native_value.Color) Vec3 {
    return switch (input.space) {
        .rgb => srgbToXyz(.{
            input.channels[0] / 255,
            input.channels[1] / 255,
            input.channels[2] / 255,
        }),
        .hsl => blk: {
            const rgb_channels = hslToRgb(input.channels);
            break :blk srgbToXyz(.{
                rgb_channels[0] / 255,
                rgb_channels[1] / 255,
                rgb_channels[2] / 255,
            });
        },
        .hwb => blk: {
            const rgb_channels = hwbToRgb(input.channels);
            break :blk srgbToXyz(.{
                rgb_channels[0] / 255,
                rgb_channels[1] / 255,
                rgb_channels[2] / 255,
            });
        },
        .lab => d50ToD65(labToXyz(input.channels[0..3].*)),
        .lch => d50ToD65(labToXyz(polarToRectangular(input.channels[0..3].*))),
        .oklab => oklabToXyz(input.channels[0..3].*),
        .oklch => oklabToXyz(polarToRectangular(input.channels[0..3].*)),
        .srgb => srgbToXyz(input.channels[0..3].*),
        .srgb_linear => linearSrgbToXyz(input.channels[0..3].*),
        .display_p3 => linearP3ToXyz(linearizeSrgb(input.channels[0..3].*)),
        .a98_rgb => linearA98ToXyz(linearizeA98(input.channels[0..3].*)),
        .prophoto_rgb => d50ToD65(linearProphotoToXyz(
            linearizeProphoto(input.channels[0..3].*),
        )),
        .rec2020 => linearRec2020ToXyz(linearizeRec2020(input.channels[0..3].*)),
        .xyz_d50 => d50ToD65(input.channels[0..3].*),
        .xyz => input.channels[0..3].*,
    };
}

fn xyzD65ToColor(
    xyz: Vec3,
    target: native_value.ColorSpace,
    alpha: f64,
) native_value.Color {
    return switch (target) {
        .rgb => blk: {
            const srgb = xyzToSrgb(xyz);
            break :blk colorFromChannels(.rgb, .{
                srgb[0] * 255,
                srgb[1] * 255,
                srgb[2] * 255,
            }, alpha, 0);
        },
        .hsl => blk: {
            const srgb = xyzToSrgb(xyz);
            const channels = rgbToHsl(.{
                srgb[0] * 255,
                srgb[1] * 255,
                srgb[2] * 255,
                alpha,
            });
            break :blk .{ .space = .hsl, .channels = channels };
        },
        .hwb => blk: {
            const srgb = xyzToSrgb(xyz);
            const channels = rgbToHwb(.{
                srgb[0] * 255,
                srgb[1] * 255,
                srgb[2] * 255,
                alpha,
            });
            break :blk .{ .space = .hwb, .channels = channels };
        },
        .lab => colorFromChannels(.lab, xyzToLab(d65ToD50(xyz)), alpha, 0),
        .lch => blk: {
            const channels = rectangularToPolar(xyzToLab(d65ToD50(xyz)), 0.0015);
            break :blk colorFromChannels(
                .lch,
                channels,
                alpha,
                if (channels[1] <= 0.0015) 0b0100 else 0,
            );
        },
        .oklab => colorFromChannels(.oklab, xyzToOklab(xyz), alpha, 0),
        .oklch => blk: {
            const channels = rectangularToPolar(xyzToOklab(xyz), 0.000004);
            break :blk colorFromChannels(
                .oklch,
                channels,
                alpha,
                if (channels[1] <= 0.000004) 0b0100 else 0,
            );
        },
        .srgb => colorFromChannels(.srgb, xyzToSrgb(xyz), alpha, 0),
        .srgb_linear => colorFromChannels(.srgb_linear, xyzToLinearSrgb(xyz), alpha, 0),
        .display_p3 => colorFromChannels(
            .display_p3,
            gammaSrgb(xyzToLinearP3(xyz)),
            alpha,
            0,
        ),
        .a98_rgb => colorFromChannels(.a98_rgb, gammaA98(xyzToLinearA98(xyz)), alpha, 0),
        .prophoto_rgb => colorFromChannels(
            .prophoto_rgb,
            gammaProphoto(xyzToLinearProphoto(d65ToD50(xyz))),
            alpha,
            0,
        ),
        .rec2020 => colorFromChannels(
            .rec2020,
            gammaRec2020(xyzToLinearRec2020(xyz)),
            alpha,
            0,
        ),
        .xyz_d50 => colorFromChannels(.xyz_d50, d65ToD50(xyz), alpha, 0),
        .xyz => colorFromChannels(.xyz, xyz, alpha, 0),
    };
}

fn colorFromChannels(
    space: native_value.ColorSpace,
    channels: Vec3,
    alpha: f64,
    missing_mask: u4,
) native_value.Color {
    return .{
        .space = space,
        .channels = .{ channels[0], channels[1], channels[2], alpha },
        .missing_mask = missing_mask,
    };
}

fn srgbToXyz(channels: Vec3) Vec3 {
    return linearSrgbToXyz(linearizeSrgb(channels));
}

fn xyzToSrgb(xyz: Vec3) Vec3 {
    return gammaSrgb(xyzToLinearSrgb(xyz));
}

fn linearizeSrgb(channels: Vec3) Vec3 {
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        const magnitude = @abs(channel);
        result[index] = if (magnitude <= 0.04045)
            channel / 12.92
        else
            signedPow((magnitude + 0.055) / 1.055, 2.4, channel);
    }
    return result;
}

fn gammaSrgb(channels: Vec3) Vec3 {
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        const magnitude = @abs(channel);
        result[index] = if (magnitude > 0.0031308)
            signOf(channel) * (1.055 * std.math.pow(f64, magnitude, 1.0 / 2.4) - 0.055)
        else
            12.92 * channel;
    }
    return result;
}

fn linearSrgbToXyz(channels: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 506752.0 / 1228815.0, 87881.0 / 245763.0, 12673.0 / 70218.0 },
        .{ 87098.0 / 409605.0, 175762.0 / 245763.0, 12673.0 / 175545.0 },
        .{ 7918.0 / 409605.0, 87881.0 / 737289.0, 1001167.0 / 1053270.0 },
    };
    return multiplyMatrix(matrix, channels);
}

fn xyzToLinearSrgb(xyz: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 12831.0 / 3959.0, -329.0 / 214.0, -1974.0 / 3959.0 },
        .{ -851781.0 / 878810.0, 1648619.0 / 878810.0, 36519.0 / 878810.0 },
        .{ 705.0 / 12673.0, -2585.0 / 12673.0, 705.0 / 667.0 },
    };
    return multiplyMatrix(matrix, xyz);
}

fn linearP3ToXyz(channels: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 608311.0 / 1250200.0, 189793.0 / 714400.0, 198249.0 / 1000160.0 },
        .{ 35783.0 / 156275.0, 247089.0 / 357200.0, 198249.0 / 2500400.0 },
        .{ 0, 32229.0 / 714400.0, 5220557.0 / 5000800.0 },
    };
    return multiplyMatrix(matrix, channels);
}

fn xyzToLinearP3(xyz: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 446124.0 / 178915.0, -333277.0 / 357830.0, -72051.0 / 178915.0 },
        .{ -14852.0 / 17905.0, 63121.0 / 35810.0, 423.0 / 17905.0 },
        .{ 11844.0 / 330415.0, -50337.0 / 660830.0, 316169.0 / 330415.0 },
    };
    return multiplyMatrix(matrix, xyz);
}

fn linearizeProphoto(channels: Vec3) Vec3 {
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        result[index] = if (@abs(channel) <= 16.0 / 512.0)
            channel / 16
        else
            signedPow(@abs(channel), 1.8, channel);
    }
    return result;
}

fn gammaProphoto(channels: Vec3) Vec3 {
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        result[index] = if (@abs(channel) >= 1.0 / 512.0)
            signedPow(@abs(channel), 1.0 / 1.8, channel)
        else
            16 * channel;
    }
    return result;
}

fn linearProphotoToXyz(channels: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 0.79776664490064230, 0.13518129740053308, 0.03134773412839220 },
        .{ 0.28807482881940130, 0.71183523424187300, 0.00008993693872564 },
        .{ 0, 0, 0.82510460251046020 },
    };
    return multiplyMatrix(matrix, channels);
}

fn xyzToLinearProphoto(xyz: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 1.34578688164715830, -0.25557208737979464, -0.05110186497554526 },
        .{ -0.54463070512490190, 1.50824774284514680, 0.02052744743642139 },
        .{ 0, 0, 1.21196754563894520 },
    };
    return multiplyMatrix(matrix, xyz);
}

fn linearizeA98(channels: Vec3) Vec3 {
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        result[index] = signedPow(@abs(channel), 563.0 / 256.0, channel);
    }
    return result;
}

fn gammaA98(channels: Vec3) Vec3 {
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        result[index] = signedPow(@abs(channel), 256.0 / 563.0, channel);
    }
    return result;
}

fn linearA98ToXyz(channels: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 573536.0 / 994567.0, 263643.0 / 1420810.0, 187206.0 / 994567.0 },
        .{ 591459.0 / 1989134.0, 6239551.0 / 9945670.0, 374412.0 / 4972835.0 },
        .{ 53769.0 / 1989134.0, 351524.0 / 4972835.0, 4929758.0 / 4972835.0 },
    };
    return multiplyMatrix(matrix, channels);
}

fn xyzToLinearA98(xyz: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 1829569.0 / 896150.0, -506331.0 / 896150.0, -308931.0 / 896150.0 },
        .{ -851781.0 / 878810.0, 1648619.0 / 878810.0, 36519.0 / 878810.0 },
        .{ 16779.0 / 1248040.0, -147721.0 / 1248040.0, 1266979.0 / 1248040.0 },
    };
    return multiplyMatrix(matrix, xyz);
}

fn linearizeRec2020(channels: Vec3) Vec3 {
    // Dart Sass 1.101.0 follows the CSS Color 4 2025 CRD's piecewise
    // BT.2020 transfer curve. These constants are intentionally pinned to
    // that compatibility target rather than silently tracking draft changes.
    const alpha = 1.09929682680944;
    const beta = 0.018053968510807;
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        const magnitude = @abs(channel);
        result[index] = if (magnitude < beta * 4.5)
            channel / 4.5
        else
            signedPow((magnitude + alpha - 1) / alpha, 1.0 / 0.45, channel);
    }
    return result;
}

fn gammaRec2020(channels: Vec3) Vec3 {
    const alpha = 1.09929682680944;
    const beta = 0.018053968510807;
    var result: Vec3 = undefined;
    for (channels, 0..) |channel, index| {
        result[index] = if (@abs(channel) >= beta)
            signOf(channel) * (alpha * std.math.pow(f64, @abs(channel), 0.45) - (alpha - 1))
        else
            4.5 * channel;
    }
    return result;
}

fn linearRec2020ToXyz(channels: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 63426534.0 / 99577255.0, 20160776.0 / 139408157.0, 47086771.0 / 278816314.0 },
        .{ 26158966.0 / 99577255.0, 472592308.0 / 697040785.0, 8267143.0 / 139408157.0 },
        .{ 0, 19567812.0 / 697040785.0, 295819943.0 / 278816314.0 },
    };
    return multiplyMatrix(matrix, channels);
}

fn xyzToLinearRec2020(xyz: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 30757411.0 / 17917100.0, -6372589.0 / 17917100.0, -4539589.0 / 17917100.0 },
        .{ -19765991.0 / 29648200.0, 47925759.0 / 29648200.0, 467509.0 / 29648200.0 },
        .{ 792561.0 / 44930125.0, -1921689.0 / 44930125.0, 42328811.0 / 44930125.0 },
    };
    return multiplyMatrix(matrix, xyz);
}

fn d65ToD50(xyz: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 1.0479297925449969, 0.022946870601609652, -0.05019226628920524 },
        .{ 0.02962780877005599, 0.9904344267538799, -0.017073799063418826 },
        .{ -0.009243040646204504, 0.015055191490298152, 0.7518742814281371 },
    };
    return multiplyMatrix(matrix, xyz);
}

fn d50ToD65(xyz: Vec3) Vec3 {
    const matrix: Matrix3 = .{
        .{ 0.955473421488075, -0.02309845494876471, 0.06325924320057072 },
        .{ -0.0283697093338637, 1.0099953980813041, 0.021041441191917323 },
        .{ 0.012314014864481998, -0.020507649298898964, 1.330365926242124 },
    };
    return multiplyMatrix(matrix, xyz);
}

fn xyzToLab(xyz: Vec3) Vec3 {
    const epsilon = 216.0 / 24389.0;
    const kappa = 24389.0 / 27.0;
    const d50: Vec3 = .{
        0.3457 / 0.3585,
        1,
        (1.0 - 0.3457 - 0.3585) / 0.3585,
    };
    var f: Vec3 = undefined;
    for (xyz, d50, 0..) |channel, white, index| {
        const scaled = channel / white;
        f[index] = if (scaled > epsilon)
            std.math.cbrt(scaled)
        else
            (kappa * scaled + 16) / 116;
    }
    return .{
        116 * f[1] - 16,
        500 * (f[0] - f[1]),
        200 * (f[1] - f[2]),
    };
}

fn labToXyz(lab_channels: Vec3) Vec3 {
    const epsilon = 216.0 / 24389.0;
    const kappa = 24389.0 / 27.0;
    const d50: Vec3 = .{
        0.3457 / 0.3585,
        1,
        (1.0 - 0.3457 - 0.3585) / 0.3585,
    };
    const fy = (lab_channels[0] + 16) / 116;
    const f: Vec3 = .{
        lab_channels[1] / 500 + fy,
        fy,
        fy - lab_channels[2] / 200,
    };
    const f0_cubed = f[0] * f[0] * f[0];
    const f2_cubed = f[2] * f[2] * f[2];
    const scaled: Vec3 = .{
        if (f0_cubed > epsilon) f0_cubed else (116 * f[0] - 16) / kappa,
        if (lab_channels[0] > kappa * epsilon)
            fy * fy * fy
        else
            lab_channels[0] / kappa,
        if (f2_cubed > epsilon) f2_cubed else (116 * f[2] - 16) / kappa,
    };
    return .{
        scaled[0] * d50[0],
        scaled[1] * d50[1],
        scaled[2] * d50[2],
    };
}

fn xyzToOklab(xyz: Vec3) Vec3 {
    const xyz_to_lms: Matrix3 = .{
        .{ 0.8190224379967030, 0.3619062600528904, -0.1288737815209879 },
        .{ 0.0329836539323885, 0.9292868615863434, 0.0361446663506424 },
        .{ 0.0481771893596242, 0.2642395317527308, 0.6335478284694309 },
    };
    const lms_to_oklab: Matrix3 = .{
        .{ 0.2104542683093140, 0.7936177747023054, -0.0040720430116193 },
        .{ 1.9779985324311684, -2.4285922420485799, 0.4505937096174110 },
        .{ 0.0259040424655478, 0.7827717124575296, -0.8086757549230774 },
    };
    var lms = multiplyMatrix(xyz_to_lms, xyz);
    for (&lms) |*channel| channel.* = std.math.cbrt(channel.*);
    return multiplyMatrix(lms_to_oklab, lms);
}

fn oklabToXyz(oklab_channels: Vec3) Vec3 {
    const oklab_to_lms: Matrix3 = .{
        .{ 1, 0.3963377773761749, 0.2158037573099136 },
        .{ 1, -0.1055613458156586, -0.0638541728258133 },
        .{ 1, -0.0894841775298119, -1.2914855480194092 },
    };
    const lms_to_xyz: Matrix3 = .{
        .{ 1.2268798758459243, -0.5578149944602171, 0.2813910456659647 },
        .{ -0.0405757452148008, 1.1122868032803170, -0.0717110580655164 },
        .{ -0.0763729366746601, -0.4214933324022432, 1.5869240198367816 },
    };
    var lms = multiplyMatrix(oklab_to_lms, oklab_channels);
    for (&lms) |*channel| channel.* = channel.* * channel.* * channel.*;
    return multiplyMatrix(lms_to_xyz, lms);
}

fn rectangularToPolar(channels: Vec3, epsilon: f64) Vec3 {
    const chroma = @sqrt(channels[1] * channels[1] + channels[2] * channels[2]);
    var hue = std.math.atan2(channels[2], channels[1]) * 180 / std.math.pi;
    if (hue < 0) hue += 360;
    if (chroma <= epsilon) hue = 0;
    return .{ channels[0], chroma, hue };
}

fn polarToRectangular(channels: Vec3) Vec3 {
    const radians = channels[2] * std.math.pi / 180;
    return .{
        channels[0],
        channels[1] * @cos(radians),
        channels[1] * @sin(radians),
    };
}

fn multiplyMatrix(matrix: Matrix3, vector: Vec3) Vec3 {
    return .{
        matrix[0][0] * vector[0] + matrix[0][1] * vector[1] + matrix[0][2] * vector[2],
        matrix[1][0] * vector[0] + matrix[1][1] * vector[1] + matrix[1][2] * vector[2],
        matrix[2][0] * vector[0] + matrix[2][1] * vector[1] + matrix[2][2] * vector[2],
    };
}

fn signedPow(magnitude: f64, exponent: f64, source: f64) f64 {
    return signOf(source) * std.math.pow(f64, magnitude, exponent);
}

fn signOf(value: f64) f64 {
    return if (value < 0) -1 else 1;
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
    return serializeExactHex(channels, buffer);
}

fn serializeExactHex(channels: [3]u8, buffer: *[max_serialized_bytes]u8) []const u8 {
    const compressed = compressible(channels[0]) and
        compressible(channels[1]) and compressible(channels[2]);
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
    computed: bool,
) Error!void {
    const serialized = try native_numeric.serialize(value, number_buffer, minified);
    if (!computed and serialized.len >= 2 and serialized[0] == '-' and serialized[1] == '.') {
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

fn isBoundedSpace(space: native_value.ColorSpace) bool {
    return switch (space) {
        .rgb,
        .hsl,
        .hwb,
        .srgb,
        .srgb_linear,
        .display_p3,
        .a98_rgb,
        .prophoto_rgb,
        .rec2020,
        => true,
        .lab, .lch, .oklab, .oklch, .xyz_d50, .xyz => false,
    };
}

fn legacyPolarHuePowerless(color: native_value.Color) bool {
    return switch (color.space) {
        .hsl => fuzzyEqual(color.channels[1], 0),
        .hwb => color.channels[1] + color.channels[2] > 100 or
            fuzzyEqual(color.channels[1] + color.channels[2], 100),
        else => false,
    };
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

fn transformLightness(
    current: f64,
    change: ?f64,
    kind: TransformKind,
    maximum: f64,
) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => clamp(current + value, 0, maximum),
        .change => value,
        .scale => try scaleChannelBetween(current, value, 0, maximum),
    };
}

fn transformSignedChannel(
    current: f64,
    change: ?f64,
    kind: TransformKind,
    minimum: f64,
    maximum: f64,
) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => current + value,
        .change => value,
        .scale => try scaleChannelBetween(current, value, minimum, maximum),
    };
}

fn transformChroma(
    current: f64,
    change: ?f64,
    kind: TransformKind,
    maximum: f64,
) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => @max(0, current + value),
        .change => value,
        .scale => try scaleChannelBetween(current, value, 0, maximum),
    };
}

fn normalizeNegativePolarChroma(channels: *[4]f64) void {
    if (channels[1] >= 0) return;
    channels[1] = -channels[1];
    channels[2] = normalizeHue(channels[2] + 180);
}

fn transformHueChannel(current: f64, change: ?f64, kind: TransformKind) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => normalizeHue(current + value),
        .change => normalizeHue(value),
        .scale => error.InvalidColor,
    };
}

fn transformUnboundedOrScale(
    current: f64,
    change: ?f64,
    kind: TransformKind,
    minimum: f64,
    maximum: f64,
) Error!f64 {
    const value = change orelse return current;
    return switch (kind) {
        .adjust => current + value,
        .change => value,
        .scale => try scaleChannelBetween(current, value, minimum, maximum),
    };
}

fn scaleChannel(current: f64, percentage: f64, maximum: f64) Error!f64 {
    return scaleChannelBetween(current, percentage, 0, maximum);
}

fn scaleChannelBetween(
    current: f64,
    percentage: f64,
    minimum: f64,
    maximum: f64,
) Error!f64 {
    if (!std.math.isFinite(percentage) or percentage < -100 or percentage > 100) {
        return error.InvalidColor;
    }
    const proportion = percentage / 100;
    return if (proportion > 0 and current < maximum)
        current + (maximum - current) * proportion
    else if (proportion < 0 and current > minimum)
        current + (current - minimum) * proportion
    else
        current;
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

fn fuzzyEqual(left: f64, right: f64) bool {
    if (@abs(left - right) > 1e-11) return false;
    return @round(left * 1e11) == @round(right * 1e11);
}

fn powerlessEqual(left: f64, right: f64) bool {
    return @abs(left - right) <= 5e-12;
}

fn fuzzyChannelsEqual(left: [4]f64, right: [4]f64) bool {
    for (left, right) |left_channel, right_channel| {
        if (!fuzzyEqual(left_channel, right_channel)) return false;
    }
    return true;
}

fn replaceMissingWithZero(input: native_value.Color) native_value.Color {
    var result = input;
    for (&result.channels, 0..) |*channel, index| {
        if (channelMissing(input.missing_mask, index)) channel.* = 0;
    }
    result.missing_mask = 0;
    return result;
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
