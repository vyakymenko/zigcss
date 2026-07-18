//! Native bounded Sass string primitives.
//!
//! Values enter this module in the representation retained by the native Sass
//! evaluator: quoted contents exclude their delimiters, while unquoted strings
//! retain their source spelling. CSS hexadecimal escapes are decoded in both
//! forms. Simple escapes lose the backslash in quoted strings, but remain two
//! logical code points in unquoted strings, matching Sass string semantics.

const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    InvalidString,
    OutputLimitExceeded,
};

pub const Case = enum {
    upper,
    lower,
};

pub fn length(
    allocator: std.mem.Allocator,
    raw: []const u8,
    quoted: bool,
    maximum_bytes: usize,
) Error!usize {
    const decoded = try decodeAlloc(allocator, raw, quoted, maximum_bytes);
    defer allocator.free(decoded);
    return codepointLength(decoded) catch error.InvalidString;
}

pub fn indexOf(
    allocator: std.mem.Allocator,
    raw: []const u8,
    quoted: bool,
    needle_raw: []const u8,
    needle_quoted: bool,
    maximum_bytes: usize,
) Error!?usize {
    const decoded = try decodeAlloc(allocator, raw, quoted, maximum_bytes);
    defer allocator.free(decoded);
    const needle = try decodeAlloc(allocator, needle_raw, needle_quoted, maximum_bytes);
    defer allocator.free(needle);

    const byte_index = std.mem.indexOf(u8, decoded, needle) orelse return null;
    const prefix_length = codepointLength(decoded[0..byte_index]) catch
        return error.InvalidString;
    return prefix_length + 1;
}

pub fn reencodeAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    source_quoted: bool,
    target_quoted: bool,
    maximum_bytes: usize,
) Error![]u8 {
    const decoded = try decodeAlloc(allocator, raw, source_quoted, maximum_bytes);
    defer allocator.free(decoded);
    return encodeAlloc(allocator, decoded, target_quoted, maximum_bytes);
}

pub fn sliceAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    quoted: bool,
    start: i64,
    end: ?i64,
    maximum_bytes: usize,
) Error![]u8 {
    const decoded = try decodeAlloc(allocator, raw, quoted, maximum_bytes);
    defer allocator.free(decoded);
    const count = codepointLength(decoded) catch return error.InvalidString;
    const first = normalizeStart(count, start);
    const last = normalizeEnd(count, end orelse -1);
    if (last <= first) return encodeAlloc(allocator, "", quoted, maximum_bytes);
    const byte_start = byteOffset(decoded, first) catch return error.InvalidString;
    const byte_end = byteOffset(decoded, last) catch return error.InvalidString;
    return encodeAlloc(allocator, decoded[byte_start..byte_end], quoted, maximum_bytes);
}

pub fn insertAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    quoted: bool,
    inserted_raw: []const u8,
    inserted_quoted: bool,
    index: i64,
    maximum_bytes: usize,
) Error![]u8 {
    const decoded = try decodeAlloc(allocator, raw, quoted, maximum_bytes);
    defer allocator.free(decoded);
    const inserted = try decodeAlloc(
        allocator,
        inserted_raw,
        inserted_quoted,
        maximum_bytes,
    );
    defer allocator.free(inserted);
    const count = codepointLength(decoded) catch return error.InvalidString;
    const insertion = normalizeInsertion(count, index);
    const byte_index = byteOffset(decoded, insertion) catch return error.InvalidString;

    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);
    try appendBounded(&combined, allocator, decoded[0..byte_index], maximum_bytes);
    try appendBounded(&combined, allocator, inserted, maximum_bytes);
    try appendBounded(&combined, allocator, decoded[byte_index..], maximum_bytes);
    return encodeAlloc(allocator, combined.items, quoted, maximum_bytes);
}

pub fn changeCaseAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    quoted: bool,
    operation: Case,
    maximum_bytes: usize,
) Error![]u8 {
    const decoded = try decodeAlloc(allocator, raw, quoted, maximum_bytes);
    defer allocator.free(decoded);
    for (decoded) |*byte| {
        byte.* = switch (operation) {
            .upper => std.ascii.toUpper(byte.*),
            .lower => std.ascii.toLower(byte.*),
        };
    }
    return encodeAlloc(allocator, decoded, quoted, maximum_bytes);
}

pub fn decodeAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    quoted: bool,
    maximum_bytes: usize,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidString;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] != '\\') {
            const scalar_length = std.unicode.utf8ByteSequenceLength(raw[index]) catch
                return error.InvalidString;
            const end = std.math.add(usize, index, scalar_length) catch
                return error.InvalidString;
            if (end > raw.len) return error.InvalidString;
            const scalar = std.unicode.utf8Decode(raw[index..end]) catch
                return error.InvalidString;
            if (scalar == 0 or scalar == '\r' or scalar == '\n' or scalar == '\x0c') {
                return error.InvalidString;
            }
            try appendBounded(&output, allocator, raw[index..end], maximum_bytes);
            index = end;
            continue;
        }

        index += 1;
        if (index == raw.len) {
            if (quoted) return error.InvalidString;
            try appendBounded(&output, allocator, "\\", maximum_bytes);
            break;
        }
        if (raw[index] == '\n' or raw[index] == '\x0c') {
            index += 1;
            continue;
        }
        if (raw[index] == '\r') {
            index += 1;
            if (index < raw.len and raw[index] == '\n') index += 1;
            continue;
        }
        if (isHex(raw[index])) {
            var scalar: u32 = 0;
            var digits: u8 = 0;
            while (index < raw.len and digits < 6 and isHex(raw[index])) : (digits += 1) {
                scalar = scalar * 16 + hexValue(raw[index]);
                index += 1;
            }
            if (index < raw.len and isEscapeWhitespace(raw[index])) {
                if (raw[index] == '\r' and index + 1 < raw.len and raw[index + 1] == '\n') {
                    index += 2;
                } else {
                    index += 1;
                }
            }
            const normalized: u21 = if (scalar == 0 or scalar > 0x10ffff or
                (scalar >= 0xd800 and scalar <= 0xdfff))
                0xfffd
            else
                @intCast(scalar);
            var encoded: [4]u8 = undefined;
            const encoded_length = std.unicode.utf8Encode(normalized, &encoded) catch
                unreachable;
            try appendBounded(
                &output,
                allocator,
                encoded[0..encoded_length],
                maximum_bytes,
            );
            continue;
        }

        const scalar_length = std.unicode.utf8ByteSequenceLength(raw[index]) catch
            return error.InvalidString;
        const end = std.math.add(usize, index, scalar_length) catch
            return error.InvalidString;
        if (end > raw.len) return error.InvalidString;
        const scalar = std.unicode.utf8Decode(raw[index..end]) catch return error.InvalidString;
        if (scalar == 0) return error.InvalidString;
        if (!quoted) try appendBounded(&output, allocator, "\\", maximum_bytes);
        try appendBounded(&output, allocator, raw[index..end], maximum_bytes);
        index = end;
    }
    return output.toOwnedSlice(allocator);
}

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    decoded: []const u8,
    quoted: bool,
    maximum_bytes: usize,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidString;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < decoded.len) {
        const scalar_length = std.unicode.utf8ByteSequenceLength(decoded[index]) catch
            return error.InvalidString;
        const end = std.math.add(usize, index, scalar_length) catch
            return error.InvalidString;
        if (end > decoded.len) return error.InvalidString;
        const scalar = std.unicode.utf8Decode(decoded[index..end]) catch
            return error.InvalidString;
        if (scalar == 0) return error.InvalidString;
        if (scalar < 0x20 or scalar == 0x7f) {
            try appendHexEscape(&output, allocator, scalar, maximum_bytes);
        } else if (quoted and scalar == '\\') {
            try appendBounded(&output, allocator, "\\\\", maximum_bytes);
        } else {
            try appendBounded(&output, allocator, decoded[index..end], maximum_bytes);
        }
        index = end;
    }
    return output.toOwnedSlice(allocator);
}

fn normalizeStart(length_value: usize, index: i64) usize {
    if (index == 0) return 0;
    const total: i128 = @intCast(length_value);
    const requested: i128 = index;
    return clampIndex(if (requested > 0) requested - 1 else total + requested, total);
}

fn normalizeEnd(length_value: usize, index: i64) usize {
    if (index == 0) return 0;
    const total: i128 = @intCast(length_value);
    const requested: i128 = index;
    return clampIndex(if (requested > 0) requested else total + requested + 1, total);
}

fn normalizeInsertion(length_value: usize, index: i64) usize {
    if (index == 0) return 0;
    const total: i128 = @intCast(length_value);
    const requested: i128 = index;
    return clampIndex(if (requested > 0) requested - 1 else total + requested + 1, total);
}

fn clampIndex(index: i128, total: i128) usize {
    if (index <= 0) return 0;
    if (index >= total) return @intCast(total);
    return @intCast(index);
}

fn codepointLength(bytes: []const u8) error{InvalidString}!usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const scalar_length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch
            return error.InvalidString;
        const end = std.math.add(usize, index, scalar_length) catch
            return error.InvalidString;
        if (end > bytes.len) return error.InvalidString;
        _ = std.unicode.utf8Decode(bytes[index..end]) catch return error.InvalidString;
        count = std.math.add(usize, count, 1) catch return error.InvalidString;
        index = end;
    }
    return count;
}

fn byteOffset(bytes: []const u8, target: usize) error{InvalidString}!usize {
    var count: usize = 0;
    var index: usize = 0;
    while (count < target) : (count += 1) {
        if (index >= bytes.len) return error.InvalidString;
        const scalar_length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch
            return error.InvalidString;
        index = std.math.add(usize, index, scalar_length) catch
            return error.InvalidString;
        if (index > bytes.len) return error.InvalidString;
    }
    return index;
}

fn appendHexEscape(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    scalar: u21,
    maximum_bytes: usize,
) Error!void {
    var buffer: [10]u8 = undefined;
    const escaped = std.fmt.bufPrint(&buffer, "\\{x} ", .{scalar}) catch unreachable;
    try appendBounded(output, allocator, escaped, maximum_bytes);
}

fn appendBounded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    maximum_bytes: usize,
) Error!void {
    const next = std.math.add(usize, output.items.len, bytes.len) catch
        return error.OutputLimitExceeded;
    if (next > maximum_bytes) return error.OutputLimitExceeded;
    try output.appendSlice(allocator, bytes);
}

fn isEscapeWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn isHex(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

fn hexValue(byte: u8) u32 {
    return if (byte >= '0' and byte <= '9')
        byte - '0'
    else if (byte >= 'a' and byte <= 'f')
        byte - 'a' + 10
    else
        byte - 'A' + 10;
}
