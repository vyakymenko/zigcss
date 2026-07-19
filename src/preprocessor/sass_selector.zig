//! Bounded selector-value parsing for the private native Sass evaluator.
//! This is deliberately independent of provider runtimes and remains internal
//! until the native Sass adapter passes its complete conformance gate.

const std = @import("std");

pub const Limits = struct {
    max_selectors: usize = 200_000,
    max_bytes: usize = 10 * 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidSelector,
    SelectorLimitExceeded,
};

pub const SelectorList = struct {
    allocator: std.mem.Allocator,
    items: [][]u8,

    pub fn deinit(self: *SelectorList) void {
        for (self.items) |item| self.allocator.free(item);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    allow_parent: bool = false,
    items: std.ArrayList([]u8) = .empty,
    byte_count: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendSegment(self: *Builder, raw: []const u8) Error!void {
        const trimmed = trimWhitespace(raw);
        if (trimmed.len == 0) return;
        const owned = try canonicalize(
            self.allocator,
            trimmed,
            self.limits.max_bytes,
            self.allow_parent,
        );
        self.admitOwned(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn appendToken(self: *Builder, raw: []const u8) Error!void {
        const owned = if (raw.len > 0 and raw[0] == '[')
            try normalizeAttribute(self.allocator, raw)
        else
            try self.allocator.dupe(u8, raw);
        self.admitOwned(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn admitOwned(self: *Builder, owned: []u8) Error!void {
        if (self.items.items.len >= self.limits.max_selectors) {
            return error.SelectorLimitExceeded;
        }
        const next = std.math.add(usize, self.byte_count, owned.len) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_bytes) return error.SelectorLimitExceeded;
        try self.items.append(self.allocator, owned);
        self.byte_count = next;
    }

    fn finish(self: *Builder) Error!SelectorList {
        return .{
            .allocator = self.allocator,
            .items = try self.items.toOwnedSlice(self.allocator),
        };
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    return parseInternal(allocator, input, limits, false);
}

fn parseInternal(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
    allow_parent: bool,
) Error!SelectorList {
    if (limits.max_selectors == 0 or limits.max_bytes == 0) {
        return error.SelectorLimitExceeded;
    }
    var builder = Builder{
        .allocator = allocator,
        .limits = limits,
        .allow_parent = allow_parent,
    };
    errdefer builder.deinit();

    var segment_start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return error.InvalidSelector;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            ',' => if (paren_depth == 0 and square_depth == 0) {
                if (builder.items.items.len == 0 and
                    trimWhitespace(input[segment_start..index]).len == 0)
                {
                    return error.InvalidSelector;
                }
                try builder.appendSegment(input[segment_start..index]);
                segment_start = index + 1;
            },
            else => {},
        }
        index += 1;
    }
    if (quote != null or paren_depth != 0 or square_depth != 0) {
        return error.InvalidSelector;
    }
    try builder.appendSegment(input[segment_start..]);
    if (builder.items.items.len == 0) return error.InvalidSelector;
    return builder.finish();
}

pub fn simpleSelectors(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    var parsed = try parse(allocator, input, limits);
    defer parsed.deinit();
    if (parsed.items.len != 1 or !isSingleCompound(parsed.items[0])) {
        return error.InvalidSelector;
    }

    var builder = Builder{ .allocator = allocator, .limits = limits };
    errdefer builder.deinit();
    var cursor: usize = 0;
    while (cursor < parsed.items[0].len) {
        const end = try simpleTokenEnd(parsed.items[0], cursor);
        if (end <= cursor) return error.InvalidSelector;
        try builder.appendToken(parsed.items[0][cursor..end]);
        cursor = end;
    }
    if (builder.items.items.len == 0) return error.InvalidSelector;
    return builder.finish();
}

pub fn append(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    limits: Limits,
) Error!SelectorList {
    if (inputs.len == 0) return error.InvalidSelector;
    var current = try parseInternal(allocator, inputs[0], limits, false);
    errdefer current.deinit();
    for (inputs[1..]) |input| {
        const replacement = try appendStep(allocator, &current, input, limits);
        current.deinit();
        current = replacement;
    }
    return current;
}

fn appendStep(
    allocator: std.mem.Allocator,
    left: *const SelectorList,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    var right = try parseInternal(allocator, input, limits, false);
    defer right.deinit();
    var builder = Builder{ .allocator = allocator, .limits = limits };
    errdefer builder.deinit();
    for (left.items) |prefix| {
        if (endsWithCombinator(prefix)) return error.InvalidSelector;
        for (right.items) |suffix| {
            if (startsWithCombinator(suffix)) return error.InvalidSelector;
            const length = std.math.add(usize, prefix.len, suffix.len) catch
                return error.SelectorLimitExceeded;
            if (length > limits.max_bytes) return error.SelectorLimitExceeded;
            const combined = try allocator.alloc(u8, length);
            std.mem.copyForwards(u8, combined[0..prefix.len], prefix);
            std.mem.copyForwards(u8, combined[prefix.len..], suffix);
            validateComplex(combined, false) catch |err| {
                allocator.free(combined);
                return err;
            };
            builder.admitOwned(combined) catch |err| {
                allocator.free(combined);
                return err;
            };
        }
    }
    return builder.finish();
}

pub fn nest(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    limits: Limits,
) Error!SelectorList {
    if (inputs.len == 0) return error.InvalidSelector;
    var current = try parseInternal(allocator, inputs[0], limits, true);
    errdefer current.deinit();
    for (inputs[1..]) |input| {
        const replacement = try nestStep(allocator, &current, input, limits);
        current.deinit();
        current = replacement;
    }
    return current;
}

fn nestStep(
    allocator: std.mem.Allocator,
    parents: *const SelectorList,
    input: []const u8,
    limits: Limits,
) Error!SelectorList {
    var children = try parseInternal(allocator, input, limits, true);
    defer children.deinit();
    var builder = Builder{
        .allocator = allocator,
        .limits = limits,
        .allow_parent = true,
    };
    errdefer builder.deinit();
    for (parents.items) |parent| {
        for (children.items) |child| {
            const parent_count = countParentSelectors(child);
            const expansion_count = if (parent_count == 0)
                1
            else
                try selectorPowerBounded(
                    parents.items.len,
                    parent_count - 1,
                    limits.max_selectors,
                );
            for (0..expansion_count) |ordinal| {
                const combined = try combineNested(
                    allocator,
                    parents,
                    parent,
                    child,
                    parent_count,
                    ordinal,
                    limits.max_bytes,
                );
                builder.admitOwned(combined) catch |err| {
                    allocator.free(combined);
                    return err;
                };
            }
        }
    }
    return builder.finish();
}

fn combineNested(
    allocator: std.mem.Allocator,
    parents: *const SelectorList,
    parent: []const u8,
    child: []const u8,
    parent_count: usize,
    ordinal: usize,
    max_bytes: usize,
) Error![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    if (parent_count == 0) {
        try appendBounded(&raw, allocator, parent, max_bytes);
        try appendBounded(&raw, allocator, " ", max_bytes);
        try appendBounded(&raw, allocator, child, max_bytes);
    } else {
        var start: usize = 0;
        var index: usize = 0;
        var occurrence: usize = 0;
        var square_depth: usize = 0;
        var quote: ?u8 = null;
        while (index < child.len) {
            const byte = child[index];
            if (quote) |active| {
                if (byte == '\\') {
                    index = escapeEnd(child, index) orelse return error.InvalidSelector;
                    continue;
                }
                if (byte == active) quote = null;
                index += 1;
                continue;
            }
            if (byte == '\\') {
                index = escapeEnd(child, index) orelse return error.InvalidSelector;
                continue;
            }
            switch (byte) {
                '\'', '"' => quote = byte,
                '[' => square_depth += 1,
                ']' => {
                    if (square_depth == 0) return error.InvalidSelector;
                    square_depth -= 1;
                },
                '&' => if (square_depth == 0) {
                    try appendBounded(&raw, allocator, child[start..index], max_bytes);
                    const replacement = if (occurrence == 0)
                        parent
                    else
                        parents.items[
                            selectorParentIndex(
                                parents.items.len,
                                parent_count - 1,
                                occurrence - 1,
                                ordinal,
                            )
                        ];
                    try appendBounded(&raw, allocator, replacement, max_bytes);
                    start = index + 1;
                    occurrence += 1;
                },
                else => {},
            }
            index += 1;
        }
        if (quote != null or square_depth != 0 or occurrence != parent_count) {
            return error.InvalidSelector;
        }
        try appendBounded(&raw, allocator, child[start..], max_bytes);
    }
    return canonicalize(allocator, raw.items, max_bytes, true);
}

fn countParentSelectors(input: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return count;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return count;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => square_depth += 1,
            ']' => square_depth -|= 1,
            '&' => if (square_depth == 0) {
                count += 1;
            },
            else => {},
        }
        index += 1;
    }
    return count;
}

fn selectorPowerBounded(base: usize, exponent: usize, maximum: usize) Error!usize {
    var result: usize = 1;
    for (0..exponent) |_| {
        result = std.math.mul(usize, result, base) catch
            return error.SelectorLimitExceeded;
        if (result > maximum) return error.SelectorLimitExceeded;
    }
    return result;
}

fn selectorParentIndex(
    parent_count: usize,
    varying_parents: usize,
    occurrence: usize,
    ordinal: usize,
) usize {
    var divisor: usize = 1;
    const following = varying_parents - occurrence - 1;
    for (0..following) |_| divisor *= parent_count;
    return (ordinal / divisor) % parent_count;
}

fn canonicalize(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_bytes: usize,
    allow_parent: bool,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    var pending_space = false;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                const end = escapeEnd(input, index) orelse return error.InvalidSelector;
                try appendBounded(&output, allocator, input[index..end], max_bytes);
                index = end;
                continue;
            }
            try appendBounded(&output, allocator, input[index .. index + 1], max_bytes);
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            if (pending_space) {
                try appendBounded(&output, allocator, " ", max_bytes);
                pending_space = false;
            }
            const end = escapeEnd(input, index) orelse return error.InvalidSelector;
            try appendBounded(&output, allocator, input[index..end], max_bytes);
            index = end;
            continue;
        }
        const top_level = paren_depth == 0 and square_depth == 0;
        if (byte == '&' and !allow_parent) return error.InvalidSelector;
        if (top_level and isWhitespace(byte)) {
            pending_space = output.items.len > 0;
            index += 1;
            continue;
        }
        const combinator_length = if (top_level) explicitCombinatorLength(input, index) else 0;
        if (combinator_length != 0) {
            while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
                output.items.len -= 1;
            }
            if (endsWithCombinator(output.items)) {
                return error.InvalidSelector;
            }
            if (output.items.len > 0) try appendBounded(&output, allocator, " ", max_bytes);
            try appendBounded(
                &output,
                allocator,
                input[index .. index + combinator_length],
                max_bytes,
            );
            pending_space = true;
            index += combinator_length;
            continue;
        }
        if (top_level and (byte == '{' or byte == '}' or byte == ';' or byte == '@')) {
            return error.InvalidSelector;
        }
        if (pending_space) {
            try appendBounded(&output, allocator, " ", max_bytes);
            pending_space = false;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return error.InvalidSelector;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            else => {},
        }
        try appendBounded(&output, allocator, input[index .. index + 1], max_bytes);
        index += 1;
    }
    if (quote != null or paren_depth != 0 or square_depth != 0) {
        return error.InvalidSelector;
    }
    while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        output.items.len -= 1;
    }
    if (output.items.len == 0) return error.InvalidSelector;
    if (allow_parent) try validateParentPositions(allocator, output.items);
    try validateComplex(output.items, allow_parent);
    return output.toOwnedSlice(allocator);
}

fn validateParentPositions(allocator: std.mem.Allocator, input: []const u8) Error!void {
    var index: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    var compound_start = true;
    var parent_contexts: std.ArrayList(bool) = .empty;
    defer parent_contexts.deinit(allocator);
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            compound_start = false;
            continue;
        }
        if (square_depth != 0) {
            switch (byte) {
                '\'', '"' => quote = byte,
                '[' => square_depth += 1,
                ']' => square_depth -= 1,
                '&' => return error.InvalidSelector,
                else => {},
            }
            index += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => {
                quote = byte;
                compound_start = false;
            },
            '[' => {
                square_depth = 1;
                compound_start = false;
            },
            '(' => {
                const outer_allows_parent = parent_contexts.items.len == 0 or
                    parent_contexts.items[parent_contexts.items.len - 1];
                try parent_contexts.append(
                    allocator,
                    outer_allows_parent and selectorFunctionAllowsParent(input, index),
                );
                compound_start = true;
            },
            ',' => compound_start = true,
            ')' => {
                if (parent_contexts.items.len == 0) return error.InvalidSelector;
                _ = parent_contexts.pop();
                compound_start = false;
            },
            '&' => {
                const context_allows_parent = parent_contexts.items.len == 0 or
                    parent_contexts.items[parent_contexts.items.len - 1];
                if (!context_allows_parent or !compound_start) return error.InvalidSelector;
                compound_start = false;
            },
            '>', '+', '~' => compound_start = true,
            else => if (isWhitespace(byte)) {
                compound_start = true;
            } else {
                compound_start = false;
            },
        }
        index += 1;
    }
    if (quote != null or square_depth != 0 or parent_contexts.items.len != 0) {
        return error.InvalidSelector;
    }
}

fn selectorFunctionAllowsParent(input: []const u8, opening: usize) bool {
    var start = opening;
    while (start > 0 and isNameContinue(input[start - 1])) start -= 1;
    if (start == opening or start == 0 or input[start - 1] != ':') return false;
    const name = input[start..opening];
    const functions = [_][]const u8{
        "not",
        "is",
        "where",
        "has",
        "matches",
        "any",
        "-webkit-any",
        "-moz-any",
        "host",
        "host-context",
        "slotted",
    };
    for (functions) |function| {
        if (std.ascii.eqlIgnoreCase(name, function)) return true;
    }
    return false;
}

fn validateComplex(input: []const u8, allow_parent: bool) Error!void {
    var cursor = skipWhitespace(input, 0);
    if (cursor == input.len) return error.InvalidSelector;
    const leading_combinator_length = explicitCombinatorLength(input, cursor);
    if (leading_combinator_length != 0) {
        cursor = skipWhitespace(input, cursor + leading_combinator_length);
        if (cursor == input.len or explicitCombinatorLength(input, cursor) != 0) {
            return error.InvalidSelector;
        }
    }
    while (cursor < input.len) {
        const end = try compoundEnd(input, cursor);
        if (end == cursor) return error.InvalidSelector;
        try validateCompound(input[cursor..end], allow_parent);
        cursor = end;
        const after_space = skipWhitespace(input, cursor);
        const saw_space = after_space != cursor;
        cursor = after_space;
        if (cursor == input.len) return;
        const combinator_length = explicitCombinatorLength(input, cursor);
        if (combinator_length != 0) {
            cursor = skipWhitespace(input, cursor + combinator_length);
            if (cursor == input.len) return;
            if (explicitCombinatorLength(input, cursor) != 0) return error.InvalidSelector;
            continue;
        }
        if (!saw_space) return error.InvalidSelector;
    }
}

fn compoundEnd(input: []const u8, start: usize) Error!usize {
    var index = start;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        const top_level = paren_depth == 0 and square_depth == 0;
        if (top_level and (isWhitespace(byte) or explicitCombinatorLength(input, index) != 0)) {
            break;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return error.InvalidSelector;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    if (quote != null or paren_depth != 0 or square_depth != 0) {
        return error.InvalidSelector;
    }
    return index;
}

fn validateCompound(input: []const u8, allow_parent: bool) Error!void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const byte = input[cursor];
        const end = try simpleTokenEnd(input, cursor);
        if (end <= cursor) return error.InvalidSelector;
        switch (byte) {
            '&' => if (!allow_parent or cursor != 0) return error.InvalidSelector,
            '.' => if (!validName(input[cursor + 1 .. end], false)) return error.InvalidSelector,
            '#' => if (!validName(input[cursor + 1 .. end], true)) return error.InvalidSelector,
            '%' => if (!validName(input[cursor + 1 .. end], false)) return error.InvalidSelector,
            '[' => if (end - cursor <= 2) return error.InvalidSelector,
            ':' => {},
            else => {
                if (cursor != 0 or !validTypeSelector(input[cursor..end])) {
                    return error.InvalidSelector;
                }
            },
        }
        cursor = end;
    }
    if (cursor == 0) return error.InvalidSelector;
}

fn simpleTokenEnd(input: []const u8, start: usize) Error!usize {
    if (start >= input.len) return error.InvalidSelector;
    return switch (input[start]) {
        '[' => matchingSquareEnd(input, start),
        ':' => pseudoEnd(input, start),
        '&' => parentTokenEnd(input, start),
        '.', '#', '%' => namedTokenEnd(input, start + 1),
        else => namedTokenEnd(input, start),
    };
}

fn parentTokenEnd(input: []const u8, start: usize) Error!usize {
    var index = start + 1;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (isWhitespace(input[index]) or isSimpleMarker(input[index]) or
            explicitCombinatorLength(input, index) != 0)
        {
            break;
        }
        index += 1;
    }
    return index;
}

fn namedTokenEnd(input: []const u8, start: usize) Error!usize {
    var index = start;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (isSimpleMarker(input[index])) break;
        index += 1;
    }
    if (index == start) return error.InvalidSelector;
    return index;
}

fn pseudoEnd(input: []const u8, start: usize) Error!usize {
    var name_start = start + 1;
    if (name_start < input.len and input[name_start] == ':') name_start += 1;
    var index = name_start;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        if (input[index] == '(' or isSimpleMarker(input[index])) break;
        index += 1;
    }
    if (!validName(input[name_start..index], false)) return error.InvalidSelector;
    if (index < input.len and input[index] == '(') return matchingParenEnd(input, index);
    return index;
}

fn matchingSquareEnd(input: []const u8, start: usize) Error!usize {
    var index = start + 1;
    var depth: usize = 1;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }
        index += 1;
    }
    return error.InvalidSelector;
}

fn matchingParenEnd(input: []const u8, start: usize) Error!usize {
    var index = start + 1;
    var depth: usize = 1;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return error.InvalidSelector;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return error.InvalidSelector;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return error.InvalidSelector;
                square_depth -= 1;
            },
            '(' => if (square_depth == 0) {
                depth += 1;
            },
            ')' => if (square_depth == 0) {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }
        index += 1;
    }
    return error.InvalidSelector;
}

fn isSingleCompound(input: []const u8) bool {
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\') {
                index = escapeEnd(input, index) orelse return false;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return false;
            continue;
        }
        const top_level = paren_depth == 0 and square_depth == 0;
        if (top_level and (isWhitespace(byte) or explicitCombinatorLength(input, index) != 0)) {
            return false;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return false;
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => {
                if (square_depth == 0) return false;
                square_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    return quote == null and paren_depth == 0 and square_depth == 0;
}

fn normalizeAttribute(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    const equals = std.mem.indexOfScalar(u8, input, '=') orelse
        return allocator.dupe(u8, input);
    var opening = equals + 1;
    while (opening + 1 < input.len and isWhitespace(input[opening])) opening += 1;
    if (opening + 1 >= input.len or (input[opening] != '\'' and input[opening] != '"')) {
        return allocator.dupe(u8, input);
    }
    const quote = input[opening];
    var closing = opening + 1;
    while (closing < input.len - 1) {
        if (input[closing] == '\\') {
            closing = escapeEnd(input, closing) orelse return error.InvalidSelector;
            continue;
        }
        if (input[closing] == quote) break;
        closing += 1;
    }
    if (closing >= input.len - 1 or input[closing] != quote) return error.InvalidSelector;
    if (!validName(input[opening + 1 .. closing], false)) return allocator.dupe(u8, input);
    const tail = trimWhitespace(input[closing + 1 .. input.len - 1]);
    if (tail.len > 1 or (tail.len == 1 and
        std.ascii.toLower(tail[0]) != 'i' and std.ascii.toLower(tail[0]) != 's'))
    {
        return allocator.dupe(u8, input);
    }
    const owned = try allocator.alloc(u8, input.len - 2);
    std.mem.copyForwards(u8, owned[0..opening], input[0..opening]);
    std.mem.copyForwards(
        u8,
        owned[opening .. opening + closing - opening - 1],
        input[opening + 1 .. closing],
    );
    std.mem.copyForwards(
        u8,
        owned[opening + closing - opening - 1 ..],
        input[closing + 1 ..],
    );
    return owned;
}

fn validTypeSelector(input: []const u8) bool {
    var pipe: ?usize = null;
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '\\') {
            index = escapeEnd(input, index) orelse return false;
            continue;
        }
        if (input[index] == '|') {
            if (pipe != null) return false;
            pipe = index;
        }
        index += 1;
    }
    if (pipe) |position| {
        const left = input[0..position];
        const right = input[position + 1 ..];
        const left_valid = left.len == 0 or std.mem.eql(u8, left, "*") or
            validName(left, false);
        const right_valid = std.mem.eql(u8, right, "*") or validName(right, false);
        return left_valid and right_valid;
    }
    return std.mem.eql(u8, input, "*") or validName(input, false);
}

fn validName(input: []const u8, allow_digit_start: bool) bool {
    if (input.len == 0 or (input.len == 1 and input[0] == '-')) return false;
    var index: usize = 0;
    var first = true;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '\\') {
            index = escapeEnd(input, index) orelse return false;
            first = false;
            continue;
        }
        if (first) {
            if (!isNameStart(byte) and !(allow_digit_start and std.ascii.isDigit(byte))) {
                return false;
            }
            first = false;
        } else if (!isNameContinue(byte)) {
            return false;
        }
        index += 1;
    }
    return !first;
}

fn normalizeEscapeWhitespace(input: []const u8, index: usize) usize {
    if (input[index] == '\r' and index + 1 < input.len and input[index + 1] == '\n') {
        return index + 2;
    }
    return index + 1;
}

fn escapeEnd(input: []const u8, start: usize) ?usize {
    if (start + 1 >= input.len) return null;
    var index = start + 1;
    if (std.ascii.isHex(input[index])) {
        var digits: usize = 0;
        while (index < input.len and digits < 6 and std.ascii.isHex(input[index])) {
            index += 1;
            digits += 1;
        }
        if (index < input.len and isWhitespace(input[index])) {
            index = normalizeEscapeWhitespace(input, index);
        }
        return index;
    }
    return index + 1;
}

fn explicitCombinatorLength(input: []const u8, index: usize) usize {
    if (index >= input.len) return 0;
    return switch (input[index]) {
        '>', '+', '~' => 1,
        else => 0,
    };
}

fn endsWithCombinator(input: []const u8) bool {
    if (input.len == 0) return false;
    return input[input.len - 1] == '>' or input[input.len - 1] == '+' or
        input[input.len - 1] == '~';
}

fn startsWithCombinator(input: []const u8) bool {
    const index = skipWhitespace(input, 0);
    return explicitCombinatorLength(input, index) != 0;
}

fn appendBounded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_bytes: usize,
) Error!void {
    const next = std.math.add(usize, output.items.len, bytes.len) catch
        return error.SelectorLimitExceeded;
    if (next > max_bytes) return error.SelectorLimitExceeded;
    try output.appendSlice(allocator, bytes);
}

fn skipWhitespace(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len and isWhitespace(input[index])) index += 1;
    return index;
}

fn trimWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n\x0c");
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn isSimpleMarker(byte: u8) bool {
    return byte == '&' or byte == '.' or byte == '#' or byte == '%' or byte == '[' or byte == ':';
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte);
}
