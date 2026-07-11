const std = @import("std");

pub const SourceId = struct {
    value: u32,

    pub fn eql(a: SourceId, b: SourceId) bool {
        return a.value == b.value;
    }
};

pub const Span = struct {
    source: SourceId,
    start: usize,
    end: usize,

    pub fn init(source: SourceId, start: usize, end: usize) error{InvalidSpan}!Span {
        if (start > end) return error.InvalidSpan;
        return .{ .source = source, .start = start, .end = end };
    }

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: Span) bool {
        return self.start == self.end;
    }

    pub fn merge(a: Span, b: Span) error{SourceMismatch}!Span {
        if (!a.source.eql(b.source)) return error.SourceMismatch;
        return .{
            .source = a.source,
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
        };
    }
};

pub const Location = struct {
    /// One-based line number.
    line: u32,
    /// One-based Unicode scalar column. Invalid UTF-8 bytes count as one scalar.
    column: u32,
    byte_offset: usize,
};

pub const SourceFile = struct {
    id: SourceId,
    name: []const u8,
    bytes: []const u8,
    line_starts: []const u32,

    pub fn fullSpan(self: *const SourceFile) Span {
        return .{ .source = self.id, .start = 0, .end = self.bytes.len };
    }

    pub fn slice(self: *const SourceFile, span: Span) error{ SourceMismatch, InvalidSpan }![]const u8 {
        if (!self.id.eql(span.source)) return error.SourceMismatch;
        if (span.start > span.end or span.end > self.bytes.len) return error.InvalidSpan;
        return self.bytes[span.start..span.end];
    }

    pub fn location(self: *const SourceFile, offset: usize) error{ InvalidLineIndex, InvalidOffset, OffsetInsideCodepoint }!Location {
        if (offset > self.bytes.len) return error.InvalidOffset;
        if (self.line_starts.len == 0 or self.line_starts[0] != 0) return error.InvalidLineIndex;

        var low: usize = 0;
        var high: usize = self.line_starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (@as(usize, self.line_starts[middle]) <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        const line_index = low - 1;
        const line_start: usize = self.line_starts[line_index];
        const scalar_count = try countScalarsToOffset(self.bytes, line_start, offset);
        return .{
            .line = @intCast(line_index + 1),
            .column = @intCast(scalar_count + 1),
            .byte_offset = offset,
        };
    }
};

pub const SourceManager = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(SourceFile),

    pub fn init(allocator: std.mem.Allocator) !SourceManager {
        return .{
            .allocator = allocator,
            .files = try std.ArrayList(SourceFile).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *SourceManager) void {
        for (self.files.items) |file| {
            self.allocator.free(file.name);
            self.allocator.free(file.bytes);
            self.allocator.free(file.line_starts);
        }
        self.files.deinit(self.allocator);
    }

    pub fn add(self: *SourceManager, name: []const u8, bytes: []const u8) !SourceId {
        if (bytes.len >= std.math.maxInt(u32)) return error.SourceTooLarge;
        if (self.files.items.len >= std.math.maxInt(u32)) return error.TooManySources;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);
        const line_starts = try buildLineIndex(self.allocator, owned_bytes);
        errdefer self.allocator.free(line_starts);

        const id = SourceId{ .value = @intCast(self.files.items.len) };
        try self.files.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .bytes = owned_bytes,
            .line_starts = line_starts,
        });
        return id;
    }

    pub fn get(self: *const SourceManager, id: SourceId) error{UnknownSource}!*const SourceFile {
        const index: usize = @intCast(id.value);
        if (index >= self.files.items.len) return error.UnknownSource;
        return &self.files.items[index];
    }

    pub fn count(self: *const SourceManager) usize {
        return self.files.items.len;
    }
};

fn buildLineIndex(allocator: std.mem.Allocator, bytes: []const u8) ![]u32 {
    var starts = try std.ArrayList(u32).initCapacity(allocator, 1);
    errdefer starts.deinit(allocator);
    try starts.append(allocator, 0);

    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte == '\r') {
            index += 1;
            if (index < bytes.len and bytes[index] == '\n') index += 1;
            try starts.append(allocator, @intCast(index));
        } else if (byte == '\n' or byte == '\x0c') {
            index += 1;
            try starts.append(allocator, @intCast(index));
        } else {
            index += 1;
        }
    }

    return try starts.toOwnedSlice(allocator);
}

fn countScalarsToOffset(bytes: []const u8, start: usize, offset: usize) error{OffsetInsideCodepoint}!usize {
    var index = start;
    var count: usize = 0;
    while (index < offset) {
        var step: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(bytes[index])) |sequence_length| {
            const candidate: usize = sequence_length;
            if (index + candidate <= bytes.len) {
                if (std.unicode.utf8Decode(bytes[index .. index + candidate])) |_| {
                    step = candidate;
                } else |_| {}
            }
        } else |_| {}

        if (index + step > offset) return error.OffsetInsideCodepoint;
        index += step;
        count += 1;
    }
    return count;
}

test "source manager owns names, bytes, and deterministic IDs" {
    const allocator = std.testing.allocator;
    var manager = try SourceManager.init(allocator);
    defer manager.deinit();

    var name = [_]u8{ 'a', '.', 'c', 's', 's' };
    var bytes = [_]u8{ '.', 'a', '{', '}' };
    const first = try manager.add(&name, &bytes);
    const second = try manager.add("b.css", ".b{}");
    name[0] = 'x';
    bytes[1] = 'x';

    try std.testing.expectEqual(@as(u32, 0), first.value);
    try std.testing.expectEqual(@as(u32, 1), second.value);
    try std.testing.expectEqual(@as(usize, 2), manager.count());
    const stored = try manager.get(first);
    try std.testing.expectEqualStrings("a.css", stored.name);
    try std.testing.expectEqualStrings(".a{}", stored.bytes);
    try std.testing.expectError(error.UnknownSource, manager.get(.{ .value = 99 }));
}

test "spans are half-open, source-bound, and merge safely" {
    const first = SourceId{ .value = 1 };
    const second = SourceId{ .value = 2 };
    const left = try Span.init(first, 2, 5);
    const right = try Span.init(first, 5, 9);
    const merged = try Span.merge(left, right);

    try std.testing.expectEqual(@as(usize, 7), merged.len());
    try std.testing.expect(!merged.isEmpty());
    try std.testing.expectError(error.InvalidSpan, Span.init(first, 3, 2));
    try std.testing.expectError(error.SourceMismatch, Span.merge(left, .{ .source = second, .start = 0, .end = 1 }));
}

test "source slices validate source identity and bounds" {
    const allocator = std.testing.allocator;
    var manager = try SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("input.css", ".card{}");
    const file = try manager.get(id);

    try std.testing.expectEqualStrings("card", try file.slice(.{ .source = id, .start = 1, .end = 5 }));
    try std.testing.expectError(error.InvalidSpan, file.slice(.{ .source = id, .start = 0, .end = 99 }));
    try std.testing.expectError(error.SourceMismatch, file.slice(.{ .source = .{ .value = 9 }, .start = 0, .end = 0 }));
}

test "line locations handle CRLF, Unicode scalars, and codepoint boundaries" {
    const allocator = std.testing.allocator;
    var manager = try SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("unicode.css", "a\r\né\nz");
    const file = try manager.get(id);

    try std.testing.expectEqual(Location{ .line = 1, .column = 1, .byte_offset = 0 }, try file.location(0));
    try std.testing.expectEqual(Location{ .line = 1, .column = 2, .byte_offset = 1 }, try file.location(1));
    try std.testing.expectEqual(Location{ .line = 2, .column = 1, .byte_offset = 3 }, try file.location(3));
    try std.testing.expectEqual(Location{ .line = 2, .column = 2, .byte_offset = 5 }, try file.location(5));
    try std.testing.expectEqual(Location{ .line = 3, .column = 1, .byte_offset = 6 }, try file.location(6));
    try std.testing.expectError(error.OffsetInsideCodepoint, file.location(4));
    try std.testing.expectError(error.InvalidOffset, file.location(file.bytes.len + 1));
}

test "line index recognizes lone CR and form feed" {
    const allocator = std.testing.allocator;
    var manager = try SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("lines.css", "a\rb\x0cc");
    const file = try manager.get(id);

    try std.testing.expectEqual(@as(u32, 2), (try file.location(2)).line);
    try std.testing.expectEqual(@as(u32, 3), (try file.location(4)).line);
}
