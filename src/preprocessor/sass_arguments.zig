//! Bounded Sass call-argument parsing and parameter binding.
//!
//! This layer is syntax-only: it retains source ranges for the evaluator and
//! never executes or coerces values. It owns positional-before-keyword order,
//! underscore/hyphen name equivalence, duplicate detection, required/defaulted
//! parameters, and bounded source ranges for argument-list splats. Value
//! expansion remains the evaluator's responsibility.

const std = @import("std");

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Argument = struct {
    name: ?[]const u8,
    value: Range,
    splat: bool = false,
};

pub const Parameter = struct {
    name: []const u8,
    required: bool = true,
};

pub const Error = std.mem.Allocator.Error || error{
    ArgumentLimitExceeded,
    DuplicateArgument,
    InvalidArgument,
    InvalidLimits,
    MissingArgument,
    PositionalAfterKeyword,
    PositionalLimitExceeded,
    SplatUnsupported,
    UnknownArgument,
};

pub const Parsed = struct {
    allocator: std.mem.Allocator,
    items: []Argument,

    pub fn deinit(self: *Parsed) void {
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const Bound = struct {
    allocator: std.mem.Allocator,
    values: []?Range,

    pub fn deinit(self: *Bound) void {
        if (self.values.len > 0) self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn parseAlloc(
    allocator: std.mem.Allocator,
    body: []const u8,
    ranges: []const Range,
    maximum_arguments: usize,
) Error!Parsed {
    if (maximum_arguments == 0) return error.InvalidLimits;
    if (ranges.len > maximum_arguments) return error.ArgumentLimitExceeded;
    if (ranges.len == 0) return .{ .allocator = allocator, .items = &.{} };
    const items = try allocator.alloc(Argument, ranges.len);
    errdefer allocator.free(items);
    var saw_keyword = false;
    for (ranges, 0..) |range, index| {
        const value_range = trimRange(body, range) orelse return error.InvalidArgument;
        const raw = body[value_range.start..value_range.end];
        if (std.mem.endsWith(u8, raw, "...")) {
            const expression_range = trimRange(body, .{
                .start = value_range.start,
                .end = value_range.end - "...".len,
            }) orelse return error.InvalidArgument;
            items[index] = .{
                .name = null,
                .value = expression_range,
                .splat = true,
            };
            continue;
        }
        const colon = findTopLevelColon(raw);
        if (colon) |offset| {
            const left_range = trimRange(raw, .{ .start = 0, .end = offset }) orelse {
                items[index] = .{ .name = null, .value = value_range };
                if (saw_keyword) return error.PositionalAfterKeyword;
                continue;
            };
            const left = raw[left_range.start..left_range.end];
            if (left.len > 1 and left[0] == '$' and validName(left[1..])) {
                const right_range = trimRange(raw, .{
                    .start = offset + 1,
                    .end = raw.len,
                }) orelse return error.InvalidArgument;
                saw_keyword = true;
                items[index] = .{
                    .name = left[1..],
                    .value = .{
                        .start = value_range.start + right_range.start,
                        .end = value_range.start + right_range.end,
                    },
                };
                continue;
            }
        }
        if (saw_keyword) return error.PositionalAfterKeyword;
        items[index] = .{ .name = null, .value = value_range };
    }
    return .{ .allocator = allocator, .items = items };
}

pub fn bindAlloc(
    allocator: std.mem.Allocator,
    arguments: []const Argument,
    parameters: []const Parameter,
    maximum_positional: usize,
) Error!Bound {
    if (maximum_positional > parameters.len) return error.InvalidLimits;
    for (parameters, 0..) |parameter, index| {
        if (!validName(parameter.name)) return error.InvalidLimits;
        for (parameters[0..index]) |previous| {
            if (nameEql(parameter.name, previous.name)) return error.InvalidLimits;
        }
    }
    if (parameters.len == 0 and arguments.len == 0) {
        return .{ .allocator = allocator, .values = &.{} };
    }
    const values = try allocator.alloc(?Range, parameters.len);
    errdefer allocator.free(values);
    @memset(values, null);
    var positional: usize = 0;
    for (arguments) |argument| {
        if (argument.splat) return error.SplatUnsupported;
        const parameter_index = if (argument.name) |name| blk: {
            var found: ?usize = null;
            for (parameters, 0..) |parameter, index| {
                if (nameEql(name, parameter.name)) {
                    found = index;
                    break;
                }
            }
            break :blk found orelse return error.UnknownArgument;
        } else blk: {
            if (positional >= maximum_positional) return error.PositionalLimitExceeded;
            const index = positional;
            positional += 1;
            break :blk index;
        };
        if (values[parameter_index] != null) return error.DuplicateArgument;
        values[parameter_index] = argument.value;
    }
    for (parameters, values) |parameter, value| {
        if (parameter.required and value == null) return error.MissingArgument;
    }
    return .{ .allocator = allocator, .values = values };
}

pub fn nameEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        const normalized_left = if (left_byte == '_') '-' else left_byte;
        const normalized_right = if (right_byte == '_') '-' else right_byte;
        if (normalized_left != normalized_right) return false;
    }
    return true;
}

fn findTopLevelColon(input: []const u8) ?usize {
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        if (paren_depth == 0 and square_depth == 0 and curly_depth == 0 and byte == ':') {
            return index;
        }
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            '{' => curly_depth += 1,
            '}' => if (curly_depth > 0) {
                curly_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    return null;
}

fn commentEnd(input: []const u8, start: usize) ?usize {
    if (start + 1 >= input.len or input[start] != '/') return null;
    if (input[start + 1] == '*') {
        const closing = std.mem.indexOf(u8, input[start + 2 ..], "*/") orelse return input.len;
        return start + 2 + closing + 2;
    }
    if (input[start + 1] == '/') {
        const newline = std.mem.indexOfScalar(u8, input[start + 2 ..], '\n') orelse
            return input.len;
        return start + 2 + newline;
    }
    return null;
}

fn trimRange(input: []const u8, range: Range) ?Range {
    if (range.start > range.end or range.end > input.len) return null;
    var start = range.start;
    var end = range.end;
    while (start < end and isWhitespace(input[start])) start += 1;
    while (end > start and isWhitespace(input[end - 1])) end -= 1;
    if (start == end) return null;
    return .{ .start = start, .end = end };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or !isNameStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isNameContinue(byte)) return false;
    }
    return true;
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte);
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}
