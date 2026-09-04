const std = @import("std");
const source = @import("source.zig");

pub const Options = struct {
    generated_file: ?[]const u8 = null,
    include_sources_content: bool = true,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidMappings,
    InvalidPosition,
    ValueOverflow,
};

pub const Mapping = struct {
    generated_line: u32,
    generated_column: u32,
    original_line: u32,
    original_column: u32,
};

pub const Builder = struct {
    const position_checkpoint_stride = 256;

    const PositionCheckpoint = struct {
        offset: u32,
        utf16_column: u32,
    };

    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    options: Options,
    mappings: std.ArrayList(Mapping),
    position_checkpoints: std.ArrayList(PositionCheckpoint),
    position_index_ready: bool = false,
    /// Structural test evidence: source bytes inspected by position queries,
    /// excluding the one-time sparse-index construction.
    position_bytes_scanned: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        file: *const source.SourceFile,
        options: Options,
    ) std.mem.Allocator.Error!Builder {
        var mappings = try std.ArrayList(Mapping).initCapacity(allocator, 0);
        errdefer mappings.deinit(allocator);
        return .{
            .allocator = allocator,
            .file = file,
            .options = options,
            .mappings = mappings,
            .position_checkpoints = try std.ArrayList(PositionCheckpoint).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.position_checkpoints.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addMapping(
        self: *Builder,
        generated_line: u32,
        generated_column: u32,
        original_offset: usize,
    ) Error!void {
        const original = self.originalPosition(original_offset) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueOverflow => return error.ValueOverflow,
            else => return error.InvalidPosition,
        };
        if (self.mappings.items.len > 0) {
            const previous = &self.mappings.items[self.mappings.items.len - 1];
            if (generated_line < previous.generated_line or
                (generated_line == previous.generated_line and generated_column < previous.generated_column))
            {
                return error.InvalidPosition;
            }
            if (generated_line == previous.generated_line and generated_column == previous.generated_column) {
                previous.original_line = original.line;
                previous.original_column = original.column;
                return;
            }
        }
        try self.mappings.append(self.allocator, .{
            .generated_line = generated_line,
            .generated_column = generated_column,
            .original_line = original.line,
            .original_column = original.column,
        });
    }

    fn ensurePositionIndex(self: *Builder) std.mem.Allocator.Error!void {
        if (self.position_index_ready) return;

        var checkpoints = try std.ArrayList(PositionCheckpoint).initCapacity(self.allocator, 0);
        errdefer checkpoints.deinit(self.allocator);
        const bytes = self.file.bytes;
        try checkpoints.append(self.allocator, .{
            .offset = 0,
            .utf16_column = 0,
        });
        var checkpoint_offset: usize = 0;
        for (self.file.line_starts, 0..) |line_start_u32, line_index| {
            const line_start: usize = line_start_u32;
            const line_end: usize = if (line_index + 1 < self.file.line_starts.len)
                self.file.line_starts[line_index + 1]
            else
                bytes.len;

            var offset = line_start;
            var column: usize = 0;
            while (offset < line_end) {
                const scalar = decodeScalar(bytes, offset);
                offset += scalar.len;
                column += if (scalar.value > 0xffff) 2 else 1;
                // A checkpoint at the next line's start would carry the
                // previous line's column. Skip that boundary and let lookups
                // fall back to the already indexed line start instead.
                if (offset - checkpoint_offset >= position_checkpoint_stride and
                    (offset < line_end or line_index + 1 == self.file.line_starts.len))
                {
                    try checkpoints.append(self.allocator, .{
                        .offset = @intCast(offset),
                        .utf16_column = @intCast(column),
                    });
                    checkpoint_offset = offset;
                }
            }
        }

        self.position_checkpoints.deinit(self.allocator);
        self.position_checkpoints = checkpoints;
        self.position_index_ready = true;
    }

    fn originalPosition(self: *Builder, offset: usize) Error!Position {
        if (offset > self.file.bytes.len or self.file.line_starts.len == 0 or
            self.file.line_starts[0] != 0)
        {
            return error.InvalidPosition;
        }
        try self.ensurePositionIndex();

        var line_low: usize = 0;
        var line_high = self.file.line_starts.len;
        while (line_low < line_high) {
            const middle = line_low + (line_high - line_low) / 2;
            if (@as(usize, self.file.line_starts[middle]) <= offset) {
                line_low = middle + 1;
            } else {
                line_high = middle;
            }
        }
        if (line_low == 0) return error.InvalidPosition;
        const line_index = line_low - 1;

        var checkpoint_low: usize = 0;
        var checkpoint_high = self.position_checkpoints.items.len;
        while (checkpoint_low < checkpoint_high) {
            const middle = checkpoint_low + (checkpoint_high - checkpoint_low) / 2;
            if (@as(usize, self.position_checkpoints.items[middle].offset) <= offset) {
                checkpoint_low = middle + 1;
            } else {
                checkpoint_high = middle;
            }
        }
        if (checkpoint_low == 0) return error.InvalidPosition;
        const checkpoint = self.position_checkpoints.items[checkpoint_low - 1];

        const line_start: usize = self.file.line_starts[line_index];
        const checkpoint_is_on_line = @as(usize, checkpoint.offset) >= line_start;
        var cursor: usize = if (checkpoint_is_on_line) checkpoint.offset else line_start;
        var column: usize = if (checkpoint_is_on_line) checkpoint.utf16_column else 0;
        while (cursor < offset) {
            const scalar = decodeScalar(self.file.bytes, cursor);
            if (cursor + scalar.len > offset) return error.InvalidPosition;
            cursor += scalar.len;
            column = std.math.add(
                usize,
                column,
                if (scalar.value > 0xffff) 2 else 1,
            ) catch return error.ValueOverflow;
            self.position_bytes_scanned +|= scalar.len;
        }
        if (column > std.math.maxInt(u32)) return error.ValueOverflow;
        return .{ .line = @intCast(line_index), .column = @intCast(column) };
    }

    pub fn encodeMappings(self: *const Builder, allocator: std.mem.Allocator) Error![]u8 {
        var output = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer output.deinit(allocator);
        var generated_line: u32 = 0;
        var previous_generated_column: i64 = 0;
        var previous_original_line: i64 = 0;
        var previous_original_column: i64 = 0;
        var first_on_line = true;
        for (self.mappings.items) |mapping| {
            while (generated_line < mapping.generated_line) : (generated_line += 1) {
                try output.append(allocator, ';');
                previous_generated_column = 0;
                first_on_line = true;
            }
            if (!first_on_line) try output.append(allocator, ',');
            try appendVlq(&output, allocator, @as(i64, mapping.generated_column) - previous_generated_column);
            try appendVlq(&output, allocator, 0);
            try appendVlq(&output, allocator, @as(i64, mapping.original_line) - previous_original_line);
            try appendVlq(&output, allocator, @as(i64, mapping.original_column) - previous_original_column);
            previous_generated_column = mapping.generated_column;
            previous_original_line = mapping.original_line;
            previous_original_column = mapping.original_column;
            first_on_line = false;
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn toJson(self: *const Builder, allocator: std.mem.Allocator) Error![]u8 {
        const mappings = try self.encodeMappings(allocator);
        defer if (mappings.len > 0) allocator.free(mappings);
        var output = try std.ArrayList(u8).initCapacity(allocator, mappings.len + self.file.name.len + 96);
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, "{\"version\":3");
        if (self.options.generated_file) |generated_file| {
            try output.appendSlice(allocator, ",\"file\":");
            try appendJsonString(&output, allocator, generated_file);
        }
        try output.appendSlice(allocator, ",\"sources\":[");
        try appendJsonString(&output, allocator, self.file.name);
        try output.append(allocator, ']');
        if (self.options.include_sources_content) {
            try output.appendSlice(allocator, ",\"sourcesContent\":[");
            try appendJsonString(&output, allocator, self.file.bytes);
            try output.append(allocator, ']');
        }
        try output.appendSlice(allocator, ",\"names\":[],\"mappings\":");
        try appendJsonString(&output, allocator, mappings);
        try output.append(allocator, '}');
        return output.toOwnedSlice(allocator);
    }
};

/// Strictly decodes the four-field mapped segments emitted by ZigCSS.
pub fn decodeMappings(allocator: std.mem.Allocator, encoded: []const u8) Error![]Mapping {
    var mappings = try std.ArrayList(Mapping).initCapacity(allocator, 0);
    errdefer mappings.deinit(allocator);
    var generated_line: i64 = 0;
    var source_index: i64 = 0;
    var original_line: i64 = 0;
    var original_column: i64 = 0;
    var group_start: usize = 0;
    while (group_start <= encoded.len) {
        const group_end = std.mem.indexOfScalarPos(u8, encoded, group_start, ';') orelse encoded.len;
        var generated_column: i64 = 0;
        if (group_start < group_end) {
            var segment_start = group_start;
            while (segment_start <= group_end) {
                const segment_end = if (std.mem.indexOfScalar(u8, encoded[segment_start..group_end], ',')) |relative|
                    segment_start + relative
                else
                    group_end;
                if (segment_start == segment_end) return error.InvalidMappings;
                var cursor = segment_start;
                var fields: [4]i64 = undefined;
                for (&fields) |*field| field.* = try decodeVlq(encoded, &cursor, segment_end);
                if (cursor != segment_end) return error.InvalidMappings;

                generated_column += fields[0];
                source_index += fields[1];
                original_line += fields[2];
                original_column += fields[3];
                if (generated_line < 0 or generated_column < 0 or source_index != 0 or
                    original_line < 0 or original_column < 0 or
                    generated_line > std.math.maxInt(u32) or generated_column > std.math.maxInt(u32) or
                    original_line > std.math.maxInt(u32) or original_column > std.math.maxInt(u32))
                {
                    return error.InvalidMappings;
                }
                if (mappings.items.len > 0) {
                    const previous = mappings.items[mappings.items.len - 1];
                    if (@as(u32, @intCast(generated_line)) == previous.generated_line and
                        @as(u32, @intCast(generated_column)) <= previous.generated_column)
                    {
                        return error.InvalidMappings;
                    }
                }
                try mappings.append(allocator, .{
                    .generated_line = @intCast(generated_line),
                    .generated_column = @intCast(generated_column),
                    .original_line = @intCast(original_line),
                    .original_column = @intCast(original_column),
                });
                if (segment_end == group_end) break;
                segment_start = segment_end + 1;
            }
        }
        if (group_end == encoded.len) break;
        generated_line += 1;
        group_start = group_end + 1;
    }
    return mappings.toOwnedSlice(allocator);
}

const Position = struct {
    line: u32,
    column: u32,
};

fn appendVlq(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) Error!void {
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.ValueOverflow;
    const magnitude: u64 = @intCast(if (value < 0) -value else value);
    var remaining = (magnitude << 1) | @intFromBool(value < 0);
    while (true) {
        var digit: u8 = @intCast(remaining & 0x1f);
        remaining >>= 5;
        if (remaining != 0) digit |= 0x20;
        try output.append(allocator, base64_alphabet[digit]);
        if (remaining == 0) break;
    }
}

fn decodeVlq(encoded: []const u8, cursor: *usize, end: usize) Error!i64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (cursor.* < end) {
        const digit = base64Value(encoded[cursor.*]) orelse return error.InvalidMappings;
        cursor.* += 1;
        const payload: u64 = digit & 0x1f;
        if (shift >= 32 and payload != 0) return error.InvalidMappings;
        value |= payload << shift;
        if ((digit & 0x20) == 0) {
            const magnitude = value >> 1;
            if (magnitude > std.math.maxInt(i32)) return error.InvalidMappings;
            const signed: i64 = @intCast(magnitude);
            return if ((value & 1) != 0) -signed else signed;
        }
        if (shift > 26) return error.InvalidMappings;
        shift += 5;
    }
    return error.InvalidMappings;
}

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Value(byte: u8) ?u8 {
    if (byte >= 'A' and byte <= 'Z') return byte - 'A';
    if (byte >= 'a' and byte <= 'z') return byte - 'a' + 26;
    if (byte >= '0' and byte <= '9') return byte - '0' + 52;
    if (byte == '+') return 62;
    if (byte == '/') return 63;
    return null;
}

fn appendJsonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try output.append(allocator, '"');
    var index: usize = 0;
    while (index < bytes.len) {
        const scalar = decodeScalar(bytes, index);
        index += scalar.len;
        switch (scalar.value) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\x08' => try output.appendSlice(allocator, "\\b"),
            '\x0c' => try output.appendSlice(allocator, "\\f"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            0...7, 0x0b, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try output.appendSlice(allocator, "\\u00");
                try output.append(allocator, hex[@as(u8, @intCast(scalar.value)) >> 4]);
                try output.append(allocator, hex[@as(u8, @intCast(scalar.value)) & 0xf]);
            },
            else => try output.appendSlice(allocator, if (scalar.valid) bytes[index - scalar.len .. index] else "�"),
        }
    }
    try output.append(allocator, '"');
}

const DecodedScalar = struct {
    value: u21,
    len: usize,
    valid: bool,
};

fn decodeScalar(bytes: []const u8, index: usize) DecodedScalar {
    const sequence_length: usize = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
        return .{ .value = 0xfffd, .len = 1, .valid = false };
    };
    if (index + sequence_length > bytes.len) return .{ .value = 0xfffd, .len = 1, .valid = false };
    const value = std.unicode.utf8Decode(bytes[index .. index + sequence_length]) catch {
        return .{ .value = 0xfffd, .len = 1, .valid = false };
    };
    return .{ .value = value, .len = sequence_length, .valid = true };
}

test "builder encodes UTF-16 positions as deterministic four-field VLQ mappings" {
    var context = try @import("compilation.zig").Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("src/α.css", "α{\r\n  color:red;\n}");
    const file = try context.sources.get(id);
    var builder = try Builder.init(std.testing.allocator, file, .{ .generated_file = "out.css" });
    defer builder.deinit();

    try builder.addMapping(0, 0, 0);
    try builder.addMapping(0, 2, 2);
    try builder.addMapping(1, 2, 7);
    try builder.addMapping(2, 0, 18);
    const mappings = try builder.encodeMappings(std.testing.allocator);
    defer std.testing.allocator.free(mappings);
    try std.testing.expectEqualStrings("AAAA,EAAC;EACC;AACF", mappings);

    const decoded = try decodeMappings(std.testing.allocator, mappings);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(Mapping, &.{
        .{ .generated_line = 0, .generated_column = 0, .original_line = 0, .original_column = 0 },
        .{ .generated_line = 0, .generated_column = 2, .original_line = 0, .original_column = 1 },
        .{ .generated_line = 1, .generated_column = 2, .original_line = 1, .original_column = 2 },
        .{ .generated_line = 2, .generated_column = 0, .original_line = 2, .original_column = 0 },
    }, decoded);

    const json = try builder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"version\":3,\"file\":\"out.css\",\"sources\":[\"src/α.css\"],\"sourcesContent\":[\"α{\\r\\n  color:red;\\n}\"],\"names\":[],\"mappings\":\"AAAA,EAAC;EACC;AACF\"}",
        json,
    );
}

test "builder rejects unsorted and invalid positions and deduplicates generated starts" {
    var context = try @import("compilation.zig").Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("positions.css", "🔥x");
    const file = try context.sources.get(id);
    var builder = try Builder.init(std.testing.allocator, file, .{});
    defer builder.deinit();

    try builder.addMapping(0, 2, 0);
    try builder.addMapping(0, 2, 4);
    try std.testing.expectEqual(@as(usize, 1), builder.mappings.items.len);
    try std.testing.expectEqual(@as(u32, 2), builder.mappings.items[0].original_column);
    try std.testing.expectError(error.InvalidPosition, builder.addMapping(0, 1, 4));
    try std.testing.expectError(error.InvalidPosition, builder.addMapping(1, 0, 1));
    try std.testing.expectError(error.InvalidPosition, builder.addMapping(1, 0, file.bytes.len + 1));
}

test "sparse UTF-16 position index bounds adversarial mapping lookup work" {
    const source_len = 64 * 1024;
    const bytes = try std.testing.allocator.alloc(u8, source_len);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'a');

    var context = try @import("compilation.zig").Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("wide-minified.css", bytes);
    const file = try context.sources.get(id);
    var builder = try Builder.init(std.testing.allocator, file, .{});
    defer builder.deinit();

    const mapping_count = 2_048;
    for (0..mapping_count) |index| {
        // Deliberately walk the original source backwards so a cache of only
        // the previous position cannot make this case linear.
        const original_offset = source_len - 1 - index * 31;
        try builder.addMapping(0, @intCast(index), original_offset);
        try std.testing.expectEqual(
            @as(u32, @intCast(original_offset)),
            builder.mappings.items[index].original_column,
        );
    }
    try std.testing.expect(builder.position_index_ready);
    try std.testing.expect(builder.position_checkpoints.items.len < source_len / 2);
    try std.testing.expect(
        builder.position_bytes_scanned <= mapping_count * Builder.position_checkpoint_stride,
    );
}

test "sparse UTF-16 position index does not duplicate newline-dense line starts" {
    const source_len = 1024 * 1024;
    const bytes = try std.testing.allocator.alloc(u8, source_len);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, '\n');

    var context = try @import("compilation.zig").Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("newline-dense.css", bytes);
    const file = try context.sources.get(id);
    var builder = try Builder.init(std.testing.allocator, file, .{});
    defer builder.deinit();

    try builder.addMapping(0, 0, source_len);
    try std.testing.expectEqual(@as(u32, source_len), builder.mappings.items[0].original_line);
    try std.testing.expectEqual(@as(u32, 0), builder.mappings.items[0].original_column);
    try std.testing.expect(
        builder.position_checkpoints.items.len <=
            source_len / Builder.position_checkpoint_stride + 2,
    );
}

test "sparse UTF-16 position index preserves checkpoint codepoint boundaries" {
    var bytes: [261]u8 = undefined;
    @memset(&bytes, 'a');
    @memcpy(bytes[255..259], "🔥");
    bytes[259] = 'b';

    var context = try @import("compilation.zig").Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("checkpoint-unicode.css", &bytes);
    const file = try context.sources.get(id);
    var builder = try Builder.init(std.testing.allocator, file, .{});
    defer builder.deinit();

    try builder.addMapping(0, 0, 255);
    try builder.addMapping(0, 1, 259);
    try builder.addMapping(0, 2, 260);
    try std.testing.expectEqual(@as(u32, 255), builder.mappings.items[0].original_column);
    try std.testing.expectEqual(@as(u32, 257), builder.mappings.items[1].original_column);
    try std.testing.expectEqual(@as(u32, 258), builder.mappings.items[2].original_column);
    try std.testing.expectError(error.InvalidPosition, builder.addMapping(0, 3, 256));
    try std.testing.expectError(error.InvalidPosition, builder.addMapping(0, 3, 257));
    try std.testing.expectError(error.InvalidPosition, builder.addMapping(0, 3, 258));
}

fn exerciseSparsePositionIndexAllocationFailures(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
) !void {
    var builder = try Builder.init(allocator, file, .{});
    defer builder.deinit();
    try builder.addMapping(0, 0, file.bytes.len);
}

test "sparse UTF-16 position index unwinds every allocation failure" {
    var context = try @import("compilation.zig").Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("position-oom.css", "a" ** 1024);
    const file = try context.sources.get(id);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSparsePositionIndexAllocationFailures,
        .{file},
    );
}

test "empty maps escape source metadata and may omit embedded content" {
    var context = try @import("compilation.zig").Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("quoted\"\\\n.css", "");
    var builder = try Builder.init(
        std.testing.allocator,
        try context.sources.get(id),
        .{ .include_sources_content = false },
    );
    defer builder.deinit();
    const json_bytes = try builder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json_bytes);
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_bytes, .{});
    defer json.deinit();

    try std.testing.expectEqualStrings("quoted\"\\\n.css", json.value.object.get("sources").?.array.items[0].string);
    try std.testing.expect(json.value.object.get("sourcesContent") == null);
    try std.testing.expectEqualStrings("", json.value.object.get("mappings").?.string);
    const decoded = try decodeMappings(std.testing.allocator, "");
    defer if (decoded.len > 0) std.testing.allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "mapping decoder rejects malformed VLQ and segment shapes" {
    const cases = [_][]const u8{ "!", "A", "AA", "AAA", "AAAAA", "g", "AAAA,,AAAA", ";,AAAA" };
    for (cases) |encoded| {
        try std.testing.expectError(error.InvalidMappings, decodeMappings(std.testing.allocator, encoded));
    }
}
