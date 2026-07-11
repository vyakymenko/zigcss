const std = @import("std");
const compilation = @import("compilation.zig");
const diagnostics = @import("diagnostics.zig");
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
    try diagnoseInvalidUtf8(context, file);
    var parser = Parser{
        .allocator = context.arenaAllocator(),
        .context = context,
        .file = file,
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
    context: *compilation.Compilation,
    file: *const source.SourceFile,
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
                if (expected_closing) |closing| {
                    try self.reportUnexpectedEof(token.span, closing);
                }
                return .{
                    .values = try values.toOwnedSlice(self.allocator),
                    .closing = null,
                    .end_offset = token.span.end,
                };
            }
            try self.diagnoseToken(token);
            if (expected_closing != null and token.kind == expected_closing.?) {
                return .{
                    .values = try values.toOwnedSlice(self.allocator),
                    .closing = token,
                    .end_offset = token.span.end,
                };
            }
            if (isClosing(token.kind)) {
                try reportDiagnostic(
                    self.context,
                    .err,
                    .unexpected_token,
                    token.span,
                    if (expected_closing == null)
                        "unexpected closing token at the top level"
                    else
                        "closing token does not match the current block",
                );
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
        try self.requireNestingCapacity(depth, opening);
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
        try self.requireNestingCapacity(depth, opening);
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

    fn requireNestingCapacity(
        self: *Parser,
        depth: usize,
        opening: tokenizer.Token,
    ) BuildError!void {
        if (depth < self.options.max_nesting) return;
        try reportDiagnostic(
            self.context,
            .err,
            .resource_limit,
            opening.span,
            "component-value nesting limit exceeded",
        );
        return error.NestingLimitExceeded;
    }

    fn diagnoseToken(self: *Parser, token: tokenizer.Token) std.mem.Allocator.Error!void {
        if (token.issue) |issue| {
            switch (issue.kind) {
                .invalid_escape => try reportDiagnostic(
                    self.context,
                    .err,
                    .invalid_escape,
                    issue.span,
                    "invalid CSS escape replaced with U+FFFD",
                ),
            }
        }

        switch (token.kind) {
            .comment => if (!token.isTerminated()) {
                try reportDiagnostic(
                    self.context,
                    .err,
                    .unterminated_comment,
                    token.span,
                    "unterminated CSS comment",
                );
            },
            .bad_string => try reportDiagnostic(
                self.context,
                .err,
                .unterminated_string,
                token.span,
                "unescaped newline terminated the CSS string",
            ),
            .string => if (!token.isTerminated()) {
                try reportDiagnostic(
                    self.context,
                    .err,
                    .unterminated_string,
                    token.span,
                    "CSS string reached EOF before its closing quote",
                );
            },
            .bad_url => try reportDiagnostic(
                self.context,
                .err,
                .bad_url,
                token.span,
                "invalid unquoted CSS URL",
            ),
            .url => if (!token.isTerminated()) {
                try reportDiagnostic(
                    self.context,
                    .err,
                    .unexpected_eof,
                    token.span,
                    "CSS URL reached EOF before its closing parenthesis",
                );
            },
            else => {},
        }
    }

    fn reportUnexpectedEof(
        self: *Parser,
        eof_span: source.Span,
        expected_closing: tokenizer.TokenKind,
    ) std.mem.Allocator.Error!void {
        try reportDiagnostic(
            self.context,
            .err,
            .unexpected_eof,
            eof_span,
            switch (expected_closing) {
                .close_curly => "expected '}' before EOF",
                .close_square => "expected ']' before EOF",
                .close_paren => "expected ')' before EOF",
                else => unreachable,
            },
        );
    }
};

fn diagnoseInvalidUtf8(
    context: *compilation.Compilation,
    file: *const source.SourceFile,
) std.mem.Allocator.Error!void {
    var index: usize = 0;
    while (index < file.bytes.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(file.bytes[index]) catch {
            try reportInvalidUtf8Byte(context, file, index);
            index += 1;
            continue;
        };
        const length: usize = sequence_length;
        if (index + length <= file.bytes.len) {
            if (std.unicode.utf8Decode(file.bytes[index .. index + length])) |_| {
                index += length;
                continue;
            } else |_| {}
        }
        try reportInvalidUtf8Byte(context, file, index);
        index += 1;
    }
}

fn reportInvalidUtf8Byte(
    context: *compilation.Compilation,
    file: *const source.SourceFile,
    index: usize,
) std.mem.Allocator.Error!void {
    try reportDiagnostic(
        context,
        .err,
        .invalid_utf8,
        .{ .source = file.id, .start = index, .end = index + 1 },
        "invalid UTF-8 byte replaced with U+FFFD",
    );
}

fn reportDiagnostic(
    context: *compilation.Compilation,
    severity: diagnostics.Severity,
    code: diagnostics.Code,
    span: source.Span,
    message: []const u8,
) std.mem.Allocator.Error!void {
    context.report(severity, code, span, message) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
    };
}

fn expectedClosing(opening: tokenizer.TokenKind) tokenizer.TokenKind {
    return switch (opening) {
        .open_curly => .close_curly,
        .open_square => .close_square,
        .open_paren => .close_paren,
        else => unreachable,
    };
}

fn isClosing(kind: tokenizer.TokenKind) bool {
    return kind == .close_curly or kind == .close_square or kind == .close_paren;
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
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
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
    try std.testing.expectEqual(@as(usize, 1), context.diagnostics.items().len);
    try std.testing.expectEqual(diagnostics.Code.unexpected_token, context.diagnostics.items()[0].code);
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
    try std.testing.expectEqual(@as(usize, 3), context.diagnostics.items().len);
    for (context.diagnostics.items()) |diagnostic| {
        try std.testing.expectEqual(diagnostics.Code.unexpected_eof, diagnostic.code);
        try std.testing.expect(diagnostic.span.isEmpty());
    }
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
    try std.testing.expectEqual(@as(usize, 3), context.diagnostics.items().len);
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
    try std.testing.expectEqual(@as(usize, 1), context.diagnostics.items().len);
    try std.testing.expectEqual(diagnostics.Code.resource_limit, context.diagnostics.items()[0].code);
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

test "malformed token and syntax recovery produces ordered structured diagnostics" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const input = "\xff \\110000  \"bad\nurl(foo bar) ){ /*";
    const id = try context.addSource("diagnostics.css", input);
    const file = try context.sources.get(id);

    const document = try parse(&context, id);
    try expectRoundTrip(document, file);
    const expected = [_]diagnostics.Code{
        .invalid_utf8,
        .invalid_escape,
        .unterminated_string,
        .bad_url,
        .unexpected_token,
        .unterminated_comment,
        .unexpected_eof,
    };
    const actual = context.diagnostics.items();
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |code, diagnostic| {
        try std.testing.expectEqual(code, diagnostic.code);
        try std.testing.expectEqual(diagnostics.Severity.err, diagnostic.severity);
        try std.testing.expect(diagnostic.span.source.eql(id));
        _ = try file.slice(diagnostic.span);
        try std.testing.expect(diagnostic.message.len > 0);
    }
    try std.testing.expectEqual(@as(usize, 0), actual[0].span.start);
    try std.testing.expectEqual(@as(usize, 1), actual[0].span.end);
    try std.testing.expect(actual[actual.len - 1].span.isEmpty());
    try std.testing.expectEqual(file.bytes.len, actual[actual.len - 1].span.start);
}

test "strings and URLs ending at EOF remain usable tokens with diagnostics" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const string_id = try context.addSource("string-eof.css", "\"value");
    const url_id = try context.addSource("url-eof.css", "url(value");

    const string_document = try parse(&context, string_id);
    try std.testing.expectEqual(tokenizer.TokenKind.string, string_document.values[0].token.kind);
    try std.testing.expect(!string_document.values[0].token.isTerminated());
    const url_document = try parse(&context, url_id);
    try std.testing.expectEqual(tokenizer.TokenKind.url, url_document.values[0].token.kind);
    try std.testing.expect(!url_document.values[0].token.isTerminated());

    const items = context.diagnostics.items();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(diagnostics.Code.unterminated_string, items[0].code);
    try std.testing.expectEqual(diagnostics.Code.unexpected_eof, items[1].code);
}

fn exerciseDiagnosticAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("oom-diagnostics.css", "\\110000  \"bad\n) {x");
    const document = try parse(&context, id);
    try std.testing.expectEqual(@as(usize, 4), context.diagnostics.items().len);
    try std.testing.expectEqual(@as(usize, 7), document.values.len);
}

test "diagnostic recovery handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDiagnosticAllocationFailures,
        .{},
    );
}

test "milestone corpus round trips representative modern CSS losslessly" {
    const cases = [_]struct {
        name: []const u8,
        css: []const u8,
    }{
        .{
            .name = "custom-properties.css",
            .css = "@charset \"UTF-8\";\n:root { --theme: color(display-p3 1 0 0); }\n",
        },
        .{
            .name = "selectors.css",
            .css = "@media (width >= 40rem) { .a:is(.b, [data-x=\"}\"]) > .c { color: rgb(1 2 3 / 50%); } }",
        },
        .{
            .name = "keyframes.css",
            .css = "@keyframes fade { from { opacity: 0 } 50% { opacity: .5 } to { opacity: 1 } }",
        },
        .{
            .name = "nesting.css",
            .css = "@supports selector(:has(> img)) { @layer components { .x { container-type: inline-size; } } }",
        },
        .{
            .name = "escapes.css",
            .css = "/* α */ .\\31 23, café { background: url(data:image/svg+xml,%3Csvg%3E); content: \"a\\\r\nb\"; }",
        },
        .{
            .name = "unknown.css",
            .css = "@vendor token(foo; [bar:baz]) { custom???: calc(1 + var(--x, 2)); }",
        },
    };

    for (cases) |case| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const id = try context.addSource(case.name, case.css);
        const file = try context.sources.get(id);
        const document = try parse(&context, id);
        try expectRoundTrip(document, file);
        try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
    }
}

test "every truncation boundary round trips and keeps diagnostic spans valid" {
    const input = "/* α */ @media (width > 1px) { .a\\31  { content: \"x\\\r\ny\"; background: url(foo\\ bar); } }";
    var end: usize = 0;
    while (end <= input.len) : (end += 1) {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const id = try context.addSource("prefix.css", input[0..end]);
        const file = try context.sources.get(id);
        const document = try parse(&context, id);
        try expectRoundTrip(document, file);
        for (context.diagnostics.items()) |diagnostic| {
            try std.testing.expect(diagnostic.span.source.eql(id));
            _ = try file.slice(diagnostic.span);
        }
    }
}

test "every single byte survives the lossless syntax boundary" {
    var byte_value: u16 = 0;
    while (byte_value <= 255) : (byte_value += 1) {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const input = [_]u8{@intCast(byte_value)};
        const id = try context.addSource("byte.css", &input);
        const file = try context.sources.get(id);
        const document = try parse(&context, id);
        try expectRoundTrip(document, file);
        for (context.diagnostics.items()) |diagnostic| {
            _ = try file.slice(diagnostic.span);
        }
    }
}
