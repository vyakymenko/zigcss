const std = @import("std");

pub const serialized_buffer_size: usize = 9;

/// An exact 8-bit sRGB color. This deliberately excludes currentColor,
/// system colors, extended ranges, missing channels, and non-sRGB spaces.
pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8 = 255,

    pub fn eql(self: Color, other: Color) bool {
        return self.red == other.red and
            self.green == other.green and
            self.blue == other.blue and
            self.alpha == other.alpha;
    }

    /// Returns the shortest closed spelling among hexadecimal notation and a
    /// small set of universally supported basic named colors.
    pub fn serialize(self: Color, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        const is_opaque = self.alpha == 255;
        const compressed = compressible(self.red) and
            compressible(self.green) and
            compressible(self.blue) and
            (is_opaque or compressible(self.alpha));
        const hex_length: usize = if (is_opaque)
            (if (compressed) 4 else 7)
        else
            (if (compressed) 5 else 9);
        if (shortName(self)) |name| {
            if (name.len < hex_length) return name;
        }
        if (buffer.len < hex_length) return error.NoSpaceLeft;

        buffer[0] = '#';
        var cursor: usize = 1;
        if (compressed) {
            buffer[cursor] = hexDigit(self.red & 0x0f);
            buffer[cursor + 1] = hexDigit(self.green & 0x0f);
            buffer[cursor + 2] = hexDigit(self.blue & 0x0f);
            cursor += 3;
            if (!is_opaque) {
                buffer[cursor] = hexDigit(self.alpha & 0x0f);
                cursor += 1;
            }
        } else {
            writeHexByte(buffer[cursor..], self.red);
            writeHexByte(buffer[cursor + 2 ..], self.green);
            writeHexByte(buffer[cursor + 4 ..], self.blue);
            cursor += 6;
            if (!is_opaque) {
                writeHexByte(buffer[cursor..], self.alpha);
                cursor += 2;
            }
        }
        return buffer[0..cursor];
    }
};

fn compressible(value: u8) bool {
    return value >> 4 == value & 0x0f;
}

fn writeHexByte(buffer: []u8, value: u8) void {
    buffer[0] = hexDigit(value >> 4);
    buffer[1] = hexDigit(value & 0x0f);
}

fn hexDigit(value: u8) u8 {
    return "0123456789abcdef"[value];
}

fn shortName(value: Color) ?[]const u8 {
    if (value.alpha != 255) return null;
    const rgb_key = (@as(u24, value.red) << 16) |
        (@as(u24, value.green) << 8) |
        @as(u24, value.blue);
    return switch (rgb_key) {
        0xff0000 => "red",
        0x808080 => "gray",
        0x000080 => "navy",
        0x008080 => "teal",
        0x008000 => "green",
        0x808000 => "olive",
        0xc0c0c0 => "silver",
        0x800000 => "maroon",
        0x800080 => "purple",
        else => null,
    };
}

test "exact sRGB colors use deterministic shortest closed spellings" {
    const cases = [_]struct { color: Color, expected: []const u8 }{
        .{ .color = .{ .red = 255, .green = 0, .blue = 0 }, .expected = "red" },
        .{ .color = .{ .red = 128, .green = 128, .blue = 128 }, .expected = "gray" },
        .{ .color = .{ .red = 255, .green = 255, .blue = 255 }, .expected = "#fff" },
        .{ .color = .{ .red = 170, .green = 187, .blue = 204 }, .expected = "#abc" },
        .{ .color = .{ .red = 18, .green = 52, .blue = 86 }, .expected = "#123456" },
        .{ .color = .{ .red = 170, .green = 187, .blue = 204, .alpha = 221 }, .expected = "#abcd" },
        .{ .color = .{ .red = 18, .green = 52, .blue = 86, .alpha = 120 }, .expected = "#12345678" },
    };
    for (cases) |case| {
        var buffer: [serialized_buffer_size]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try case.color.serialize(&buffer));
    }

    var undersized: [3]u8 = undefined;
    try std.testing.expectError(
        error.NoSpaceLeft,
        (Color{ .red = 255, .green = 255, .blue = 255 }).serialize(&undersized),
    );
    try std.testing.expect((Color{ .red = 1, .green = 2, .blue = 3 }).eql(.{
        .red = 1,
        .green = 2,
        .blue = 3,
    }));
}
