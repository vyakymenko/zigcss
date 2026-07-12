const std = @import("std");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidSpan,
    InvalidToken,
    SourceMismatch,
};

pub const Options = struct {
    trim_edges: bool = true,
};

/// Compares two component streams from one source after the emitter's
/// whitespace normalization. Decoded token spellings may differ, but token
/// kinds, numeric representation types, structure, and comments must match.
pub fn equivalent(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: []const syntax.ComponentValue,
    right: []const syntax.ComponentValue,
    options: Options,
) Error!bool {
    try validateComponentList(file, left);
    try validateComponentList(file, right);
    return componentListsEqual(
        allocator,
        file,
        left,
        right,
        options.trim_edges,
    );
}

fn validateComponentList(
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
) Error!void {
    for (values) |value| {
        _ = file.slice(value.span()) catch |err| switch (err) {
            error.SourceMismatch => return error.SourceMismatch,
            error.InvalidSpan => return error.InvalidSpan,
        };
        switch (value) {
            .token => {},
            .simple_block => |block| try validateComponentList(file, block.values),
            .function => |function| try validateComponentList(file, function.values),
        }
    }
}

fn componentListsEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: []const syntax.ComponentValue,
    right: []const syntax.ComponentValue,
    trim_edges: bool,
) Error!bool {
    var left_iterator = SemanticIterator{ .values = left, .trim_edges = trim_edges };
    var right_iterator = SemanticIterator{ .values = right, .trim_edges = trim_edges };
    while (true) {
        const left_item = left_iterator.next();
        const right_item = right_iterator.next();
        if (left_item == null or right_item == null) return left_item == null and right_item == null;
        switch (left_item.?) {
            .whitespace => if (right_item.? != .whitespace) return false,
            .component => |left_component| switch (right_item.?) {
                .component => |right_component| if (!try componentsEqual(
                    allocator,
                    file,
                    left_component,
                    right_component,
                )) return false,
                else => return false,
            },
        }
    }
}

fn componentsEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: syntax.ComponentValue,
    right: syntax.ComponentValue,
) Error!bool {
    return switch (left) {
        .token => |left_token| switch (right) {
            .token => |right_token| try tokensEqual(allocator, file, left_token, right_token),
            else => false,
        },
        .simple_block => |left_block| switch (right) {
            .simple_block => |right_block| left_block.opening.kind == right_block.opening.kind and
                left_block.terminated() == right_block.terminated() and
                try componentListsEqual(allocator, file, left_block.values, right_block.values, false),
            else => false,
        },
        .function => |left_function| switch (right) {
            .function => |right_function| left_function.terminated() == right_function.terminated() and
                try tokenTextEqual(allocator, file, left_function.opening, right_function.opening) and
                try componentListsEqual(allocator, file, left_function.values, right_function.values, false),
            else => false,
        },
    };
}

fn tokensEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: tokenizer.Token,
    right: tokenizer.Token,
) Error!bool {
    if (left.kind != right.kind or left.isTerminated() != right.isTerminated()) return false;
    return switch (left.kind) {
        .ident, .function, .at_keyword, .string, .bad_string, .url, .bad_url => try tokenTextEqual(allocator, file, left, right),
        .hash => left.data.hash.hash_type == right.data.hash.hash_type and
            try tokenTextEqual(allocator, file, left, right),
        .delim => left.data.delim == right.data.delim,
        .number, .percentage => numericEqual(left.data.numeric, right.data.numeric),
        .dimension => numericEqual(left.data.dimension.numeric, right.data.dimension.numeric) and
            try tokenTextEqual(allocator, file, left, right),
        .comment => try tokenRawEqual(file, left, right),
        .unicode_range => left.data.unicode_range.start == right.data.unicode_range.start and
            left.data.unicode_range.end == right.data.unicode_range.end,
        else => true,
    };
}

fn tokenTextEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: tokenizer.Token,
    right: tokenizer.Token,
) Error!bool {
    const left_text = left.decodedTextAlloc(allocator, file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch => return error.SourceMismatch,
        else => return error.InvalidToken,
    };
    defer allocator.free(left_text);
    const right_text = right.decodedTextAlloc(allocator, file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch => return error.SourceMismatch,
        else => return error.InvalidToken,
    };
    defer allocator.free(right_text);
    return std.mem.eql(u8, left_text, right_text);
}

fn tokenRawEqual(
    file: *const source.SourceFile,
    left: tokenizer.Token,
    right: tokenizer.Token,
) Error!bool {
    const left_bytes = file.slice(left.span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    const right_bytes = file.slice(right.span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn numericEqual(left: tokenizer.Numeric, right: tokenizer.Numeric) bool {
    return left.value == right.value and left.number_type == right.number_type and left.sign == right.sign;
}

const SemanticItem = union(enum) {
    whitespace,
    component: syntax.ComponentValue,
};

const SemanticIterator = struct {
    values: []const syntax.ComponentValue,
    index: usize = 0,
    saw_component: bool = false,
    trim_edges: bool,

    fn next(self: *SemanticIterator) ?SemanticItem {
        while (true) {
            if (self.index == self.values.len) return null;
            if (isWhitespace(self.values[self.index])) {
                var next_index = self.index;
                while (next_index < self.values.len and isWhitespace(self.values[next_index])) next_index += 1;
                self.index = next_index;
                if (self.trim_edges and (!self.saw_component or self.index == self.values.len)) {
                    if (self.index == self.values.len) return null;
                    continue;
                }
                return .whitespace;
            }
            const value = self.values[self.index];
            self.index += 1;
            self.saw_component = true;
            return .{ .component = value };
        }
    }
};

fn isWhitespace(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
}

const pipeline = @import("pipeline.zig");

test "component comparison normalizes representation but preserves token boundaries and comments" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "component-compare.css",
        ".a{x: fn( 1px, 'x' );--y:a/**/b}.b{x:fn( 1px, \"x\" );--y:a/**/b}" ++
            ".c{--y:ab}.d{--y:a/*! distinct */b}",
    );
    defer parsed.deinit();
    const first = parsed.rules.rules[0].style_rule.block.declarations;
    const second = parsed.rules.rules[1].style_rule.block.declarations;
    const third = parsed.rules.rules[2].style_rule.block.declarations;
    const fourth = parsed.rules.rules[3].style_rule.block.declarations;
    try std.testing.expect(try equivalent(
        std.testing.allocator,
        parsed.file(),
        first.declarations[0].valueWithoutImportance(),
        second.declarations[0].valueWithoutImportance(),
        .{},
    ));
    try std.testing.expect(!(try equivalent(
        std.testing.allocator,
        parsed.file(),
        first.declarations[1].valueWithoutImportance(),
        third.declarations[0].valueWithoutImportance(),
        .{},
    )));
    try std.testing.expect(!(try equivalent(
        std.testing.allocator,
        parsed.file(),
        first.declarations[1].valueWithoutImportance(),
        fourth.declarations[0].valueWithoutImportance(),
        .{},
    )));
}
