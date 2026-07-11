const std = @import("std");
const compilation = @import("compilation.zig");
const source = @import("source.zig");
const tokenizer = @import("tokenizer.zig");

pub const Options = struct {
    max_nesting: usize = 256,
};

const BuildError = std.mem.Allocator.Error || error{NestingLimitExceeded};
pub const Error = BuildError || error{UnknownSource};

pub const Document = struct {
    source_id: source.SourceId,
    span: source.Span,
    values: []const ComponentValue,

    pub fn raw(self: Document, file: *const source.SourceFile) ![]const u8 {
        return file.slice(self.span);
    }
};

pub const ComponentValue = union(enum) {
    token: tokenizer.Token,
    simple_block: *const SimpleBlock,
    function: *const Function,

    pub fn span(self: ComponentValue) source.Span {
        return switch (self) {
            .token => |token| token.span,
            .simple_block => |block| block.span,
            .function => |function| function.span,
        };
    }

    pub fn raw(self: ComponentValue, file: *const source.SourceFile) ![]const u8 {
        return file.slice(self.span());
    }
};

pub const SimpleBlock = struct {
    opening: tokenizer.Token,
    values: []const ComponentValue,
    closing: ?tokenizer.Token,
    span: source.Span,

    pub fn expectedClosing(self: SimpleBlock) tokenizer.TokenKind {
        return switch (self.opening.kind) {
            .open_curly => .close_curly,
            .open_square => .close_square,
            .open_paren => .close_paren,
            else => unreachable,
        };
    }

    pub fn terminated(self: SimpleBlock) bool {
        return self.closing != null;
    }
};

pub const Function = struct {
    opening: tokenizer.Token,
    values: []const ComponentValue,
    closing: ?tokenizer.Token,
    span: source.Span,

    pub fn terminated(self: Function) bool {
        return self.closing != null;
    }
};

pub fn parse(context: *compilation.Compilation, source_id: source.SourceId) Error!Document {
    return parseWithOptions(context, source_id, .{});
}

pub fn parseWithOptions(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    options: Options,
) Error!Document {
    const file = try context.sources.get(source_id);
    var parser = Parser{
        .allocator = context.arenaAllocator(),
        .tokenizer = tokenizer.Tokenizer.init(file),
        .options = options,
    };
    const root = try parser.consumeList(null, 0);
    return .{
        .source_id = source_id,
        .span = file.fullSpan(),
        .values = root.values,
    };
}

const ConsumedList = struct {
    values: []const ComponentValue,
    closing: ?tokenizer.Token,
    end_offset: usize,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: tokenizer.Tokenizer,
    options: Options,

    fn consumeList(
        self: *Parser,
        expected_closing: ?tokenizer.TokenKind,
        depth: usize,
    ) BuildError!ConsumedList {
        var values = try std.ArrayList(ComponentValue).initCapacity(self.allocator, 0);
        errdefer values.deinit(self.allocator);

        while (true) {
            const token = self.tokenizer.next();
            if (token.kind == .eof) {
                return .{
                    .values = try values.toOwnedSlice(self.allocator),
                    .closing = null,
                    .end_offset = token.span.end,
                };
            }
            if (expected_closing != null and token.kind == expected_closing.?) {
                return .{
                    .values = try values.toOwnedSlice(self.allocator),
                    .closing = token,
                    .end_offset = token.span.end,
                };
            }

            try values.append(self.allocator, try self.consumeValue(token, depth));
        }
    }

    fn consumeValue(self: *Parser, token: tokenizer.Token, depth: usize) BuildError!ComponentValue {
        return switch (token.kind) {
            .open_curly, .open_square, .open_paren => try self.consumeSimpleBlock(token, depth),
            .function => try self.consumeFunction(token, depth),
            else => .{ .token = token },
        };
    }

    fn consumeSimpleBlock(self: *Parser, opening: tokenizer.Token, depth: usize) BuildError!ComponentValue {
        try self.requireNestingCapacity(depth);
        const contents = try self.consumeList(expectedClosing(opening.kind), depth + 1);
        const block = try self.allocator.create(SimpleBlock);
        block.* = .{
            .opening = opening,
            .values = contents.values,
            .closing = contents.closing,
            .span = .{
                .source = opening.span.source,
                .start = opening.span.start,
                .end = contents.end_offset,
            },
        };
        return .{ .simple_block = block };
    }

    fn consumeFunction(self: *Parser, opening: tokenizer.Token, depth: usize) BuildError!ComponentValue {
        try self.requireNestingCapacity(depth);
        const contents = try self.consumeList(.close_paren, depth + 1);
        const function = try self.allocator.create(Function);
        function.* = .{
            .opening = opening,
            .values = contents.values,
            .closing = contents.closing,
            .span = .{
                .source = opening.span.source,
                .start = opening.span.start,
                .end = contents.end_offset,
            },
        };
        return .{ .function = function };
    }

    fn requireNestingCapacity(self: *const Parser, depth: usize) error{NestingLimitExceeded}!void {
        if (depth >= self.options.max_nesting) return error.NestingLimitExceeded;
    }
};

fn expectedClosing(opening: tokenizer.TokenKind) tokenizer.TokenKind {
    return switch (opening) {
        .open_curly => .close_curly,
        .open_square => .close_square,
        .open_paren => .close_paren,
        else => unreachable,
    };
}

fn expectRoundTrip(document: Document, file: *const source.SourceFile) !void {
    var output = try std.ArrayList(u8).initCapacity(std.testing.allocator, file.bytes.len);
    defer output.deinit(std.testing.allocator);
    for (document.values) |value| {
        try output.appendSlice(std.testing.allocator, try value.raw(file));
    }
    try std.testing.expectEqualStrings(file.bytes, output.items);
}

test "nested blocks and functions remain structured and lossless" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("nested.css", "a{b:fn([x],g(y));}");
    const file = try context.sources.get(id);

    const document = try parse(&context, id);
    try expectRoundTrip(document, file);
    try std.testing.expectEqual(@as(usize, 2), document.values.len);
    const block = document.values[1].simple_block;
    try std.testing.expect(block.terminated());
    try std.testing.expectEqual(tokenizer.TokenKind.close_curly, block.closing.?.kind);
    try std.testing.expectEqual(@as(usize, 4), block.values.len);

    const function = block.values[2].function;
    try std.testing.expect(function.terminated());
    try std.testing.expectEqualStrings("fn(", try function.opening.raw(file));
    try std.testing.expectEqual(@as(usize, 3), function.values.len);
    const square = function.values[0].simple_block;
    try std.testing.expectEqual(tokenizer.TokenKind.close_square, square.closing.?.kind);
    try std.testing.expectEqualStrings("[x]", try file.slice(square.span));
    const nested_function = function.values[2].function;
    try std.testing.expectEqualStrings("g(y)", try file.slice(nested_function.span));
}

test "mismatched closers are preserved inside their containing block" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("mismatch.css", "{x]y}");
    const file = try context.sources.get(id);

    const document = try parse(&context, id);
    try expectRoundTrip(document, file);
    const block = document.values[0].simple_block;
    try std.testing.expect(block.terminated());
    try std.testing.expectEqual(@as(usize, 3), block.values.len);
    try std.testing.expectEqual(tokenizer.TokenKind.close_square, block.values[1].token.kind);
}

test "truncated nested input returns unterminated nodes through EOF" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("truncated.css", "a{fn([x");
    const file = try context.sources.get(id);

    const document = try parse(&context, id);
    try expectRoundTrip(document, file);
    const block = document.values[1].simple_block;
    const function = block.values[0].function;
    const square = function.values[0].simple_block;
    try std.testing.expect(!block.terminated());
    try std.testing.expect(!function.terminated());
    try std.testing.expect(!square.terminated());
    try std.testing.expectEqual(file.bytes.len, block.span.end);
    try std.testing.expectEqual(file.bytes.len, function.span.end);
    try std.testing.expectEqual(file.bytes.len, square.span.end);
}

test "strings URLs and retained trivia do not corrupt nesting" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("opaque.css", "{/*x*/a:'}';b:url(x)} tail");
    const file = try context.sources.get(id);

    const document = try parse(&context, id);
    try expectRoundTrip(document, file);
    const block = document.values[0].simple_block;
    try std.testing.expect(block.terminated());
    try std.testing.expect(block.values[0].token.isTrivia());
    try std.testing.expectEqual(tokenizer.TokenKind.string, block.values[3].token.kind);
    try std.testing.expectEqual(tokenizer.TokenKind.url, block.values[7].token.kind);
}

test "all block kinds close independently and quoted URLs remain functions" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("blocks.css", "([{x}]) url(\"x\")");
    const file = try context.sources.get(id);

    const document = try parse(&context, id);
    try expectRoundTrip(document, file);
    const paren = document.values[0].simple_block;
    const square = paren.values[0].simple_block;
    const curly = square.values[0].simple_block;
    try std.testing.expectEqual(tokenizer.TokenKind.close_paren, paren.closing.?.kind);
    try std.testing.expectEqual(tokenizer.TokenKind.close_square, square.closing.?.kind);
    try std.testing.expectEqual(tokenizer.TokenKind.close_curly, curly.closing.?.kind);

    const quoted_url = document.values[2].function;
    try std.testing.expectEqualStrings("url(", try quoted_url.opening.raw(file));
    try std.testing.expectEqual(tokenizer.TokenKind.string, quoted_url.values[0].token.kind);
    try std.testing.expect(quoted_url.terminated());
}

test "empty input and top-level closing tokens remain representable" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const empty_id = try context.addSource("empty.css", "");
    const closers_id = try context.addSource("closers.css", ")]}");

    const empty = try parse(&context, empty_id);
    try std.testing.expectEqual(@as(usize, 0), empty.values.len);
    try std.testing.expect(empty.span.isEmpty());

    const closers_file = try context.sources.get(closers_id);
    const closers = try parse(&context, closers_id);
    try expectRoundTrip(closers, closers_file);
    try std.testing.expectEqual(@as(usize, 3), closers.values.len);
    try std.testing.expectEqual(tokenizer.TokenKind.close_paren, closers.values[0].token.kind);
    try std.testing.expectEqual(tokenizer.TokenKind.close_square, closers.values[1].token.kind);
    try std.testing.expectEqual(tokenizer.TokenKind.close_curly, closers.values[2].token.kind);
}

test "unknown source IDs fail before syntax allocation" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    try std.testing.expectError(error.UnknownSource, parse(&context, .{ .value = 42 }));
}

test "nesting limit rejects adversarial depth before stack exhaustion" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 32);
    defer allocator.free(input);
    @memset(input, '(');
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("deep.css", input);

    try std.testing.expectError(
        error.NestingLimitExceeded,
        parseWithOptions(&context, id, .{ .max_nesting = 8 }),
    );
}

fn exerciseSyntaxAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("oom-syntax.css", "a{b:fn([x],g(y));/*c*/}");
    const document = try parse(&context, id);
    try std.testing.expectEqual(@as(usize, 2), document.values.len);
}

test "syntax construction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSyntaxAllocationFailures,
        .{},
    );
}
