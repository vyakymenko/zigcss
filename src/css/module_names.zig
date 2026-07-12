const std = @import("std");

/// One decoded authored class name and its generated replacement. Collections
/// used for lookup must be strictly byte-sorted by `name`.
pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Error = error{InvalidMappings};

pub fn validate(entries: []const Entry) Error!void {
    var previous: ?[]const u8 = null;
    for (entries) |entry| {
        if (entry.name.len == 0 or entry.value.len == 0) return error.InvalidMappings;
        if (previous) |name| {
            if (std.mem.order(u8, name, entry.name) != .lt) return error.InvalidMappings;
        }
        previous = entry.name;
    }
}

pub fn find(entries: []const Entry, name: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, name, entries[middle].name)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return entries[middle].value,
        }
    }
    return null;
}

test "module-name mappings require strict order and use bounded binary lookup" {
    const valid = [_]Entry{
        .{ .name = "badge", .value = "_badge" },
        .{ .name = "card", .value = "_card" },
        .{ .name = "icon", .value = "_icon" },
    };
    try validate(&valid);
    try std.testing.expectEqualStrings("_card", find(&valid, "card").?);
    try std.testing.expect(find(&valid, "missing") == null);

    const duplicate = [_]Entry{
        .{ .name = "card", .value = "_one" },
        .{ .name = "card", .value = "_two" },
    };
    try std.testing.expectError(error.InvalidMappings, validate(&duplicate));
    const reversed = [_]Entry{
        .{ .name = "icon", .value = "_icon" },
        .{ .name = "card", .value = "_card" },
    };
    try std.testing.expectError(error.InvalidMappings, validate(&reversed));
}
