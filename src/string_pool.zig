const std = @import("std");

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *StringPool) void {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.strings.deinit();
    }

    pub fn intern(self: *StringPool, str: []const u8) ![]const u8 {
        if (str.len == 0) return "";
        
        const entry = try self.strings.getOrPut(str);
        if (!entry.found_existing) {
            const owned = try self.allocator.dupe(u8, str);
            entry.key_ptr.* = owned;
        }
        return entry.key_ptr.*;
    }

    pub fn internSlice(self: *StringPool, start: usize, end: usize, input: []const u8) ![]const u8 {
        if (start >= end or start >= input.len) return "";
        const actual_end = @min(end, input.len);
        if (start == actual_end) return "";
        
        const str = input[start..actual_end];
        return self.intern(str);
    }
};
