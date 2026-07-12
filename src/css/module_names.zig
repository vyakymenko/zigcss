const std = @import("std");
const ast = @import("ast.zig");
const source = @import("../source.zig");

/// One decoded authored class name and its generated replacement. Collections
/// used for lookup must be strictly byte-sorted by `name`.
pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

/// One class-selector occurrence and the exact identifier to emit for it.
/// Occurrence collections must be strictly sorted by source span.
pub const Occurrence = struct {
    span: source.Span,
    value: []const u8,
};

pub const Replacement = Occurrence;

/// One functional `:local(...)` or `:global(...)` wrapper to remove. The
/// replacement compound remains compilation-arena-owned through emission.
pub const Scope = struct {
    span: source.Span,
    compound: *const ast.CompoundSelector,
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

pub fn validateOccurrences(entries: []const Occurrence) Error!void {
    var previous: ?source.Span = null;
    for (entries) |entry| {
        if (entry.value.len == 0 or entry.span.start >= entry.span.end) {
            return error.InvalidMappings;
        }
        if (previous) |span| {
            if (!spanLessThan(span, entry.span)) return error.InvalidMappings;
        }
        previous = entry.span;
    }
}

pub fn findOccurrence(entries: []const Occurrence, span: source.Span) ?[]const u8 {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (orderSpan(span, entries[middle].span)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return entries[middle].value,
        }
    }
    return null;
}

pub fn hasOccurrenceWithin(entries: []const Occurrence, parent: source.Span) bool {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = entries[middle].span;
        if (entry.source.value < parent.source.value or
            (entry.source.value == parent.source.value and entry.start < parent.start))
        {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    while (low < entries.len) : (low += 1) {
        const span = entries[low].span;
        if (!span.source.eql(parent.source) or span.start >= parent.end) return false;
        if (span.end <= parent.end) return true;
    }
    return false;
}

pub fn validateScopes(entries: []const Scope) Error!void {
    var previous: ?source.Span = null;
    for (entries) |entry| {
        if (entry.span.start >= entry.span.end) return error.InvalidMappings;
        _ = ast.CompoundSelector.init(
            entry.compound.span,
            entry.compound.simple_selectors,
        ) catch return error.InvalidMappings;
        if (previous) |span| {
            if (!spanLessThan(span, entry.span)) return error.InvalidMappings;
        }
        previous = entry.span;
    }
}

pub fn findScope(entries: []const Scope, span: source.Span) ?*const ast.CompoundSelector {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (orderSpan(span, entries[middle].span)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return entries[middle].compound,
        }
    }
    return null;
}

pub fn lessThanOccurrence(_: void, left: Occurrence, right: Occurrence) bool {
    return spanLessThan(left.span, right.span);
}

pub fn lessThanScope(_: void, left: Scope, right: Scope) bool {
    return spanLessThan(left.span, right.span);
}

pub fn validateSpans(spans: []const source.Span) Error!void {
    var previous: ?source.Span = null;
    for (spans) |span| {
        if (span.start >= span.end) return error.InvalidMappings;
        if (previous) |value| {
            if (!spanLessThan(value, span)) return error.InvalidMappings;
        }
        previous = span;
    }
}

pub fn containsSpan(spans: []const source.Span, span: source.Span) bool {
    var low: usize = 0;
    var high = spans.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (orderSpan(span, spans[middle])) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return true,
        }
    }
    return false;
}

pub fn lessThanSpan(_: void, left: source.Span, right: source.Span) bool {
    return spanLessThan(left, right);
}

fn spanLessThan(left: source.Span, right: source.Span) bool {
    return orderSpan(left, right) == .lt;
}

fn orderSpan(left: source.Span, right: source.Span) std.math.Order {
    if (left.source.value < right.source.value) return .lt;
    if (left.source.value > right.source.value) return .gt;
    if (left.start < right.start) return .lt;
    if (left.start > right.start) return .gt;
    if (left.end < right.end) return .lt;
    if (left.end > right.end) return .gt;
    return .eq;
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

test "occurrence mappings require strict spans and use bounded binary lookup" {
    const source_id = source.SourceId{ .value = 7 };
    const mappings = [_]Occurrence{
        .{ .span = .{ .source = source_id, .start = 1, .end = 3 }, .value = "_a" },
        .{ .span = .{ .source = source_id, .start = 5, .end = 7 }, .value = "global" },
    };
    try validateOccurrences(&mappings);
    try std.testing.expectEqualStrings("global", findOccurrence(&mappings, mappings[1].span).?);
    try std.testing.expect(findOccurrence(
        &mappings,
        .{ .source = source_id, .start = 8, .end = 10 },
    ) == null);

    const duplicate = [_]Occurrence{ mappings[0], mappings[0] };
    try std.testing.expectError(error.InvalidMappings, validateOccurrences(&duplicate));
    const empty = [_]Occurrence{.{
        .span = .{ .source = source_id, .start = 1, .end = 3 },
        .value = "",
    }};
    try std.testing.expectError(error.InvalidMappings, validateOccurrences(&empty));
}
