const std = @import("std");

pub const Position = struct {
    line: usize,
    character: usize,
};

pub const Error = error{
    InvalidUtf8,
    LineOutOfRange,
    InvalidUtf16Boundary,
    InvalidByteOffset,
    PositionOverflow,
};

const LineBounds = struct {
    start: usize,
    end: usize,
};

/// Converts a zero-based UTF-16 LSP position to a UTF-8 byte offset. Character
/// offsets beyond the line length clamp to the line end as required by LSP.
pub fn byteOffsetAtUtf16Position(
    text: []const u8,
    line: usize,
    character: usize,
) Error!usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const bounds = try lineBounds(text, line);
    var index = bounds.start;
    var units: usize = 0;
    while (index < bounds.end) {
        if (units == character) return index;
        const scalar = try decodeScalar(text, index);
        const width: usize = if (scalar.value > 0xffff) 2 else 1;
        const next_units = std.math.add(usize, units, width) catch
            return error.PositionOverflow;
        if (character < next_units) return error.InvalidUtf16Boundary;
        units = next_units;
        index += scalar.len;
    }
    return bounds.end;
}

/// Converts a zero-based UTF-8 byte column on an LSP line to an absolute byte
/// offset. This is the compatibility bridge for byte-oriented source spans.
pub fn byteOffsetAtUtf8Position(
    text: []const u8,
    line: usize,
    character: usize,
) Error!usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const bounds = try lineBounds(text, line);
    if (character >= bounds.end - bounds.start) return bounds.end;
    const offset = bounds.start + character;
    _ = try utf16PositionAtByteOffset(text, offset);
    return offset;
}

/// Converts a UTF-8 byte boundary to a zero-based UTF-16 LSP position. The
/// byte between CR and LF in a CRLF sequence is not a protocol position.
pub fn utf16PositionAtByteOffset(text: []const u8, offset: usize) Error!Position {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (offset > text.len) return error.InvalidByteOffset;

    var index: usize = 0;
    var line: usize = 0;
    var character: usize = 0;
    while (true) {
        if (index == offset) return .{ .line = line, .character = character };
        if (index == text.len) return error.InvalidByteOffset;

        if (text[index] == '\r') {
            if (index + 1 < text.len and text[index + 1] == '\n') {
                if (offset == index + 1) return error.InvalidByteOffset;
                index += 2;
            } else {
                index += 1;
            }
            line = std.math.add(usize, line, 1) catch return error.PositionOverflow;
            character = 0;
            continue;
        }
        if (text[index] == '\n') {
            index += 1;
            line = std.math.add(usize, line, 1) catch return error.PositionOverflow;
            character = 0;
            continue;
        }

        const scalar = try decodeScalar(text, index);
        if (offset < index + scalar.len) return error.InvalidByteOffset;
        index += scalar.len;
        character = std.math.add(
            usize,
            character,
            if (scalar.value > 0xffff) 2 else 1,
        ) catch return error.PositionOverflow;
    }
}

fn lineBounds(text: []const u8, target_line: usize) Error!LineBounds {
    var line: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\r' or text[index] == '\n') {
            if (line == target_line) return .{ .start = start, .end = index };
            if (text[index] == '\r' and index + 1 < text.len and text[index + 1] == '\n') {
                index += 2;
            } else {
                index += 1;
            }
            line = std.math.add(usize, line, 1) catch return error.PositionOverflow;
            start = index;
            continue;
        }
        const scalar = try decodeScalar(text, index);
        index += scalar.len;
    }
    if (line == target_line) return .{ .start = start, .end = text.len };
    return error.LineOutOfRange;
}

const Scalar = struct {
    value: u21,
    len: usize,
};

fn decodeScalar(text: []const u8, index: usize) Error!Scalar {
    const len: usize = std.unicode.utf8ByteSequenceLength(text[index]) catch
        return error.InvalidUtf8;
    if (index + len > text.len) return error.InvalidUtf8;
    const value = std.unicode.utf8Decode(text[index .. index + len]) catch
        return error.InvalidUtf8;
    return .{ .value = value, .len = len };
}

test "UTF-16 positions convert across every LSP line ending" {
    const text = "a\r\n😀b\rc\n";

    try std.testing.expectEqual(@as(usize, 0), try byteOffsetAtUtf16Position(text, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), try byteOffsetAtUtf16Position(text, 0, 99));
    try std.testing.expectEqual(@as(usize, 3), try byteOffsetAtUtf16Position(text, 1, 0));
    try std.testing.expectError(
        error.InvalidUtf16Boundary,
        byteOffsetAtUtf16Position(text, 1, 1),
    );
    try std.testing.expectEqual(@as(usize, 7), try byteOffsetAtUtf16Position(text, 1, 2));
    try std.testing.expectEqual(@as(usize, 8), try byteOffsetAtUtf16Position(text, 1, 99));
    try std.testing.expectEqual(@as(usize, 9), try byteOffsetAtUtf16Position(text, 2, 0));
    try std.testing.expectEqual(@as(usize, 11), try byteOffsetAtUtf16Position(text, 3, 0));
    try std.testing.expectError(error.LineOutOfRange, byteOffsetAtUtf16Position(text, 4, 0));

    const cases = [_]struct {
        offset: usize,
        position: Position,
    }{
        .{ .offset = 0, .position = .{ .line = 0, .character = 0 } },
        .{ .offset = 1, .position = .{ .line = 0, .character = 1 } },
        .{ .offset = 3, .position = .{ .line = 1, .character = 0 } },
        .{ .offset = 7, .position = .{ .line = 1, .character = 2 } },
        .{ .offset = 8, .position = .{ .line = 1, .character = 3 } },
        .{ .offset = 9, .position = .{ .line = 2, .character = 0 } },
        .{ .offset = 10, .position = .{ .line = 2, .character = 1 } },
        .{ .offset = 11, .position = .{ .line = 3, .character = 0 } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.position,
            try utf16PositionAtByteOffset(text, case.offset),
        );
    }
    try std.testing.expectError(error.InvalidByteOffset, utf16PositionAtByteOffset(text, 2));
    try std.testing.expectError(error.InvalidByteOffset, utf16PositionAtByteOffset(text, 4));
    try std.testing.expectError(error.InvalidByteOffset, utf16PositionAtByteOffset(text, 12));

    try std.testing.expectEqual(@as(usize, 3), try byteOffsetAtUtf8Position(text, 1, 0));
    try std.testing.expectError(error.InvalidByteOffset, byteOffsetAtUtf8Position(text, 1, 1));
    try std.testing.expectEqual(@as(usize, 7), try byteOffsetAtUtf8Position(text, 1, 4));
    try std.testing.expectEqual(@as(usize, 8), try byteOffsetAtUtf8Position(text, 1, 99));
}

test "position conversion rejects invalid UTF-8 deterministically" {
    const invalid = [_]u8{ 0xf0, 0x28, 0x8c, 0x28 };
    try std.testing.expectError(
        error.InvalidUtf8,
        byteOffsetAtUtf16Position(&invalid, 0, 0),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        utf16PositionAtByteOffset(&invalid, 0),
    );
}
