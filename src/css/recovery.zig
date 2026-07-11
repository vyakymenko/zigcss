const std = @import("std");
const compilation = @import("../compilation.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

/// Synchronization points are top-level component values. Delimiters inside a
/// function or simple block are already nested and therefore cannot terminate
/// the surrounding rule.
pub const BoundaryKind = enum {
    end,
    semicolon,
    curly_block,
};

pub const Boundary = struct {
    kind: BoundaryKind,
    index: usize,
    /// First component after the boundary. At EOF, equals `index`.
    next: usize,
};

pub fn scanRuleBoundary(values: []const syntax.ComponentValue, start: usize) Boundary {
    var index = @min(start, values.len);
    while (index < values.len) : (index += 1) {
        if (isSemicolon(values[index])) {
            return .{ .kind = .semicolon, .index = index, .next = index + 1 };
        }
        if (isCurlyBlock(values[index])) {
            return .{ .kind = .curly_block, .index = index, .next = index + 1 };
        }
    }
    return .{ .kind = .end, .index = values.len, .next = values.len };
}

/// Matching closers are consumed by the syntax container and never appear in
/// its `values`. Any closing token visible to a lowering parser is therefore a
/// syntax-diagnosed stray/mismatch and is safe to isolate from the next rule.
pub fn isStrayClosing(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .close_curly or token.kind == .close_square or token.kind == .close_paren;
}

/// Allows a caller to add a generic context diagnostic only when a nested
/// parser did not already emit a more precise diagnostic for the same failure.
pub const DiagnosticCheckpoint = struct {
    count: usize,

    pub fn capture(context: *const compilation.Compilation) DiagnosticCheckpoint {
        return .{ .count = context.diagnostics.items().len };
    }

    pub fn unchanged(self: DiagnosticCheckpoint, context: *const compilation.Compilation) bool {
        return context.diagnostics.items().len == self.count;
    }
};

fn tokenAt(value: syntax.ComponentValue) ?tokenizer.Token {
    return switch (value) {
        .token => |token| token,
        else => null,
    };
}

fn isSemicolon(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .semicolon;
}

fn isCurlyBlock(value: syntax.ComponentValue) bool {
    return switch (value) {
        .simple_block => |block| block.opening.kind == .open_curly,
        else => false,
    };
}

test "rule boundaries ignore nested delimiters and always make progress" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("boundaries.css", "head(fn(;{}));next{a:b}tail");
    const document = try syntax.parse(&context, id);

    const first = scanRuleBoundary(document.values, 0);
    try std.testing.expectEqual(BoundaryKind.semicolon, first.kind);
    try std.testing.expect(first.next > first.index);
    const second = scanRuleBoundary(document.values, first.next);
    try std.testing.expectEqual(BoundaryKind.curly_block, second.kind);
    try std.testing.expect(second.next > second.index);
    const eof = scanRuleBoundary(document.values, second.next);
    try std.testing.expectEqual(BoundaryKind.end, eof.kind);
    try std.testing.expectEqual(document.values.len, eof.index);
    try std.testing.expectEqual(eof.index, eof.next);
    try std.testing.expectEqual(eof, scanRuleBoundary(document.values, document.values.len + 10));
}

test "diagnostic checkpoints detect precise nested reports" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("checkpoint.css", ".bad");
    const checkpoint = DiagnosticCheckpoint.capture(&context);
    try std.testing.expect(checkpoint.unchanged(&context));
    try context.report(.err, .unexpected_token, (try context.sources.get(id)).fullSpan(), "precise error");
    try std.testing.expect(!checkpoint.unchanged(&context));
}
