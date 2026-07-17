const std = @import("std");

pub const SourceId = struct {
    value: u32,

    pub fn eql(left: SourceId, right: SourceId) bool {
        return left.value == right.value;
    }
};

pub const Span = struct {
    source: SourceId,
    start: u32,
    end: u32,

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    pub fn isEmpty(self: Span) bool {
        return self.start == self.end;
    }

    pub fn merge(left: Span, right: Span) error{ SourceMismatch, InvalidSpan }!Span {
        if (!left.source.eql(right.source)) return error.SourceMismatch;
        if (left.start > left.end or right.start > right.end) return error.InvalidSpan;
        return .{
            .source = left.source,
            .start = @min(left.start, right.start),
            .end = @max(left.end, right.end),
        };
    }
};

pub const Position = struct {
    /// Zero-based source line.
    line: u32,
    /// Zero-based UTF-16 code-unit column, as required by Source Map v3.
    column: u32,
};

pub const File = struct {
    id: SourceId,
    name: []const u8,
    bytes: []const u8,
    line_starts: []const u32,
};

pub const Limits = struct {
    max_sources: usize = 4_096,
    max_owned_bytes: usize = 64 * 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    DuplicateSource,
    InvalidPosition,
    InvalidSource,
    InvalidSpan,
    OffsetInsideCodepoint,
    SourceLimitExceeded,
    SourceTooLarge,
    UnknownSource,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    files: std.ArrayList(File) = .empty,
    owned_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Table {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Table) void {
        for (self.files.items) |file| {
            if (file.name.len > 0) self.allocator.free(file.name);
            if (file.bytes.len > 0) self.allocator.free(file.bytes);
            if (file.line_starts.len > 0) self.allocator.free(file.line_starts);
        }
        self.files.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Table, name: []const u8, bytes: []const u8) Error!SourceId {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) {
            return error.InvalidSource;
        }
        if (bytes.len > std.math.maxInt(u32)) return error.SourceTooLarge;
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.name, name)) return error.DuplicateSource;
        }

        const contribution = std.math.add(usize, name.len, bytes.len) catch
            return error.SourceLimitExceeded;
        const next_owned = std.math.add(usize, self.owned_bytes, contribution) catch
            return error.SourceLimitExceeded;
        if (self.files.items.len >= self.limits.max_sources or
            next_owned > self.limits.max_owned_bytes or
            self.files.items.len >= std.math.maxInt(u32))
        {
            return error.SourceLimitExceeded;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer if (owned_name.len > 0) self.allocator.free(owned_name);
        const owned_source = try self.allocator.dupe(u8, bytes);
        errdefer if (owned_source.len > 0) self.allocator.free(owned_source);
        const line_starts = try buildLineStarts(self.allocator, owned_source);
        errdefer if (line_starts.len > 0) self.allocator.free(line_starts);

        const id = SourceId{ .value = @intCast(self.files.items.len) };
        try self.files.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .bytes = owned_source,
            .line_starts = line_starts,
        });
        self.owned_bytes = next_owned;
        return id;
    }

    pub fn count(self: *const Table) usize {
        return self.files.items.len;
    }

    pub fn get(self: *const Table, id: SourceId) Error!*const File {
        const index: usize = @intCast(id.value);
        if (index >= self.files.items.len) return error.UnknownSource;
        return &self.files.items[index];
    }

    pub fn span(self: *const Table, id: SourceId, start: u32, end: u32) Error!Span {
        const result = Span{ .source = id, .start = start, .end = end };
        try self.validateSpan(result);
        return result;
    }

    pub fn validateSpan(self: *const Table, value: Span) Error!void {
        const file = self.get(value.source) catch return error.InvalidSpan;
        if (value.start > value.end or value.end > file.bytes.len) return error.InvalidSpan;
    }

    pub fn slice(self: *const Table, value: Span) Error![]const u8 {
        try self.validateSpan(value);
        const file = try self.get(value.source);
        return file.bytes[value.start..value.end];
    }

    pub fn position(self: *const Table, id: SourceId, offset: u32) Error!Position {
        const file = try self.get(id);
        if (offset > file.bytes.len) return error.InvalidPosition;

        var low: usize = 0;
        var high = file.line_starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (file.line_starts[middle] <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == 0) return error.InvalidPosition;
        const line_index = low - 1;
        const line_start = file.line_starts[line_index];
        const column = try utf16LengthTo(file.bytes, line_start, offset);
        return .{ .line = @intCast(line_index), .column = column };
    }
};

fn buildLineStarts(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(allocator);
    try starts.append(allocator, 0);

    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == '\r') {
            index += 1;
            if (index < bytes.len and bytes[index] == '\n') index += 1;
            try starts.append(allocator, @intCast(index));
        } else if (bytes[index] == '\n' or bytes[index] == '\x0c') {
            index += 1;
            try starts.append(allocator, @intCast(index));
        } else {
            index += 1;
        }
    }
    return try starts.toOwnedSlice(allocator);
}

fn utf16LengthTo(bytes: []const u8, start: u32, end: u32) Error!u32 {
    var index: usize = start;
    var units: u64 = 0;
    while (index < end) {
        const decoded = decodeScalar(bytes, index);
        if (index + decoded.len > end) return error.OffsetInsideCodepoint;
        index += decoded.len;
        units += if (decoded.value > 0xffff) 2 else 1;
        if (units > std.math.maxInt(u32)) return error.InvalidPosition;
    }
    return @intCast(units);
}

const DecodedScalar = struct {
    value: u21,
    len: usize,
};

fn decodeScalar(bytes: []const u8, index: usize) DecodedScalar {
    const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch
        return .{ .value = 0xfffd, .len = 1 };
    const scalar = std.unicode.utf8Decode(bytes[index..@min(index + length, bytes.len)]) catch
        return .{ .value = 0xfffd, .len = 1 };
    return .{ .value = scalar, .len = length };
}
