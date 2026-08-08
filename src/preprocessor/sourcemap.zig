const std = @import("std");
const source = @import("source.zig");

pub const GeneratedPosition = struct {
    line: u32,
    column: u32,
};

pub const Segment = struct {
    generated: GeneratedPosition,
    source_id: ?source.SourceId = null,
    original_line: u32 = 0,
    original_column: u32 = 0,
    name_id: ?u32 = null,

    pub fn isMapped(self: Segment) bool {
        return self.source_id != null;
    }
};

pub const Limits = struct {
    max_segments: usize = 1_000_000,
    max_names: usize = 100_000,
    max_name_bytes: usize = 16 * 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidGeneratedPosition,
    InvalidName,
    InvalidSpan,
    MappingLimitExceeded,
    NameLimitExceeded,
    ValueOverflow,
};

pub const Map = struct {
    allocator: std.mem.Allocator,
    segment_items: []const Segment,
    name_items: []const []const u8,

    pub fn deinit(self: *Map) void {
        for (self.name_items) |name| {
            if (name.len > 0) self.allocator.free(name);
        }
        if (self.name_items.len > 0) self.allocator.free(self.name_items);
        if (self.segment_items.len > 0) self.allocator.free(self.segment_items);
        self.* = undefined;
    }

    pub fn segments(self: *const Map) []const Segment {
        return self.segment_items;
    }

    pub fn names(self: *const Map) []const []const u8 {
        return self.name_items;
    }

    pub fn lookup(self: *const Map, generated: GeneratedPosition) ?Segment {
        var low: usize = 0;
        var high = self.segment_items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = self.segment_items[middle].generated;
            if (positionLessOrEqual(candidate, generated)) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == 0) return null;
        const candidate = self.segment_items[low - 1];
        if (candidate.generated.line != generated.line) return null;
        return candidate;
    }

    pub fn encodeMappings(self: *const Map, allocator: std.mem.Allocator) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var generated_line: u32 = 0;
        var previous_generated_column: i64 = 0;
        var previous_source: i64 = 0;
        var previous_original_line: i64 = 0;
        var previous_original_column: i64 = 0;
        var previous_name: i64 = 0;
        var first_on_line = true;
        for (self.segment_items) |segment| {
            while (generated_line < segment.generated.line) : (generated_line += 1) {
                try output.append(allocator, ';');
                previous_generated_column = 0;
                first_on_line = true;
            }
            if (!first_on_line) try output.append(allocator, ',');
            try appendVlq(
                &output,
                allocator,
                @as(i64, segment.generated.column) - previous_generated_column,
            );
            previous_generated_column = segment.generated.column;
            if (segment.source_id) |source_id| {
                try appendVlq(&output, allocator, @as(i64, source_id.value) - previous_source);
                try appendVlq(
                    &output,
                    allocator,
                    @as(i64, segment.original_line) - previous_original_line,
                );
                try appendVlq(
                    &output,
                    allocator,
                    @as(i64, segment.original_column) - previous_original_column,
                );
                previous_source = source_id.value;
                previous_original_line = segment.original_line;
                previous_original_column = segment.original_column;
                if (segment.name_id) |name_id| {
                    try appendVlq(&output, allocator, @as(i64, name_id) - previous_name);
                    previous_name = name_id;
                }
            }
            first_on_line = false;
        }
        return try output.toOwnedSlice(allocator);
    }
};

pub const Builder = struct {
    pub const Checkpoint = struct {
        segment_count: usize,
        last_segment: ?Segment,
        name_count: usize,
        name_bytes: usize,
    };

    allocator: std.mem.Allocator,
    sources: *const source.Table,
    limits: Limits,
    segment_items: std.ArrayList(Segment) = .empty,
    name_items: std.ArrayList([]const u8) = .empty,
    name_bytes: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        sources: *const source.Table,
        limits: Limits,
    ) Builder {
        return .{ .allocator = allocator, .sources = sources, .limits = limits };
    }

    pub fn deinit(self: *Builder) void {
        for (self.name_items.items) |name| {
            if (name.len > 0) self.allocator.free(name);
        }
        self.name_items.deinit(self.allocator);
        self.segment_items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addUnmapped(self: *Builder, generated: GeneratedPosition) Error!void {
        try self.appendSegment(.{ .generated = generated });
    }

    pub fn addMapped(
        self: *Builder,
        generated: GeneratedPosition,
        original: source.Span,
        name: ?[]const u8,
    ) Error!void {
        self.sources.validateSpan(original) catch return error.InvalidSpan;
        const original_position = self.sources.position(original.source, original.start) catch
            return error.InvalidSpan;
        try self.validateGenerated(generated);
        const replacing = self.isReplacing(generated);
        if (!replacing and self.segment_items.items.len >= self.limits.max_segments) {
            return error.MappingLimitExceeded;
        }
        const name_id = if (name) |value| try self.internName(value) else null;
        const segment = Segment{
            .generated = generated,
            .source_id = original.source,
            .original_line = original_position.line,
            .original_column = original_position.column,
            .name_id = name_id,
        };
        if (replacing) {
            self.segment_items.items[self.segment_items.items.len - 1] = segment;
        } else {
            try self.segment_items.append(self.allocator, segment);
        }
    }

    pub fn checkpoint(self: *const Builder) Checkpoint {
        return .{
            .segment_count = self.segment_items.items.len,
            .last_segment = if (self.segment_items.items.len > 0)
                self.segment_items.items[self.segment_items.items.len - 1]
            else
                null,
            .name_count = self.name_items.items.len,
            .name_bytes = self.name_bytes,
        };
    }

    pub fn restore(self: *Builder, checkpoint_value: Checkpoint) Error!void {
        if (checkpoint_value.segment_count > self.segment_items.items.len or
            (checkpoint_value.segment_count == 0) != (checkpoint_value.last_segment == null) or
            checkpoint_value.name_count > self.name_items.items.len or
            checkpoint_value.name_bytes > self.name_bytes)
        {
            return error.InvalidGeneratedPosition;
        }
        for (self.name_items.items[checkpoint_value.name_count..]) |name| {
            if (name.len > 0) self.allocator.free(name);
        }
        self.segment_items.shrinkRetainingCapacity(checkpoint_value.segment_count);
        if (checkpoint_value.last_segment) |last_segment| {
            self.segment_items.items[self.segment_items.items.len - 1] = last_segment;
        }
        self.name_items.shrinkRetainingCapacity(checkpoint_value.name_count);
        self.name_bytes = checkpoint_value.name_bytes;
    }

    pub fn finish(self: *Builder) Error!Map {
        const segments = try self.segment_items.toOwnedSlice(self.allocator);
        errdefer if (segments.len > 0) self.allocator.free(segments);
        const names = try self.name_items.toOwnedSlice(self.allocator);
        return .{
            .allocator = self.allocator,
            .segment_items = segments,
            .name_items = names,
        };
    }

    fn appendSegment(self: *Builder, segment: Segment) Error!void {
        try self.validateGenerated(segment.generated);
        if (self.isReplacing(segment.generated)) {
            self.segment_items.items[self.segment_items.items.len - 1] = segment;
            return;
        }
        if (self.segment_items.items.len >= self.limits.max_segments) {
            return error.MappingLimitExceeded;
        }
        try self.segment_items.append(self.allocator, segment);
    }

    fn validateGenerated(self: *const Builder, generated: GeneratedPosition) Error!void {
        if (self.segment_items.items.len == 0) return;
        const previous = self.segment_items.items[self.segment_items.items.len - 1].generated;
        if (positionLess(generated, previous)) return error.InvalidGeneratedPosition;
    }

    fn isReplacing(self: *const Builder, generated: GeneratedPosition) bool {
        if (self.segment_items.items.len == 0) return false;
        return std.meta.eql(
            self.segment_items.items[self.segment_items.items.len - 1].generated,
            generated,
        );
    }

    fn internName(self: *Builder, name: []const u8) Error!u32 {
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
        for (name) |byte| {
            if (byte < 0x20 or byte == 0x7f) return error.InvalidName;
        }
        for (self.name_items.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, name)) return @intCast(index);
        }
        const next_bytes = std.math.add(usize, self.name_bytes, name.len) catch
            return error.NameLimitExceeded;
        if (self.name_items.items.len >= self.limits.max_names or
            self.name_items.items.len >= std.math.maxInt(u32) or
            next_bytes > self.limits.max_name_bytes)
        {
            return error.NameLimitExceeded;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer if (owned.len > 0) self.allocator.free(owned);
        try self.name_items.append(self.allocator, owned);
        self.name_bytes = next_bytes;
        return @intCast(self.name_items.items.len - 1);
    }
};

fn positionLess(left: GeneratedPosition, right: GeneratedPosition) bool {
    return left.line < right.line or (left.line == right.line and left.column < right.column);
}

fn positionLessOrEqual(left: GeneratedPosition, right: GeneratedPosition) bool {
    return !positionLess(right, left);
}

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn appendVlq(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: i64,
) Error!void {
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
        return error.ValueOverflow;
    }
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
