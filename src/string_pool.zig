const std = @import("std");

const COMMON_CSS_KEYWORDS = [_][]const u8{
    "color", "background", "padding", "margin", "border", "width", "height",
    "display", "position", "top", "right", "bottom", "left", "flex", "grid",
    "font", "text", "line", "opacity", "transform", "transition", "animation",
    "box-shadow", "z-index", "overflow", "cursor", "user-select", "pointer-events",
    "align", "justify", "gap", "row", "column", "wrap", "direction", "order",
    "grow", "shrink", "basis", "auto", "none", "inherit", "initial", "unset",
    "block", "inline", "flex", "grid", "table", "relative", "absolute", "fixed",
    "sticky", "static", "hidden", "visible", "scroll", "transparent", "important",
};

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMap(void),
    common_keywords: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) StringPool {
        var pool = StringPool{
            .allocator = allocator,
            .strings = std.StringHashMap(void).init(allocator),
            .common_keywords = std.StringHashMap([]const u8).init(allocator),
        };
        pool.preInternCommonKeywords();
        return pool;
    }

    fn preInternCommonKeywords(self: *StringPool) void {
        for (COMMON_CSS_KEYWORDS) |keyword| {
            const owned = self.allocator.dupe(u8, keyword) catch return;
            self.common_keywords.put(keyword, owned) catch return;
        }
    }

    pub fn deinit(self: *StringPool) void {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.strings.deinit();
        
        var common_it = self.common_keywords.iterator();
        while (common_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.common_keywords.deinit();
    }

    pub fn intern(self: *StringPool, str: []const u8) ![]const u8 {
        if (str.len == 0) return "";
        
        if (self.common_keywords.get(str)) |pre_interned| {
            return pre_interned;
        }
        
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
