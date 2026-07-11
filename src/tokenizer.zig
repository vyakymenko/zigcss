const std = @import("std");
const source = @import("source.zig");

/// Token categories from CSS Syntax Level 3 plus retained comment trivia and
/// an explicit EOF sentinel. Complex consumers are implemented incrementally
/// by TOK-002 and TOK-003 without changing this public category set.
pub const TokenKind = enum {
    ident,
    function,
    at_keyword,
    hash,
    string,
    bad_string,
    url,
    bad_url,
    delim,
    number,
    percentage,
    dimension,
    unicode_range,
    whitespace,
    comment,
    cdo,
    cdc,
    colon,
    semicolon,
    comma,
    open_square,
    close_square,
    open_paren,
    close_paren,
    open_curly,
    close_curly,
    eof,
};

pub const HashType = enum {
    id,
    unrestricted,
};

pub const NumberType = enum {
    integer,
    number,
};

pub const Sign = enum {
    none,
    plus,
    minus,
};

pub const Numeric = struct {
    value: f64,
    number_type: NumberType,
    sign: Sign,
};

pub const Hash = struct {
    value: source.Span,
    hash_type: HashType,
};

pub const Dimension = struct {
    numeric: Numeric,
    unit: source.Span,
};

pub const UnicodeRange = struct {
    start: u21,
    end: u21,
};

pub const TokenData = union(enum) {
    none,
    /// Raw source span for identifiers, functions, at-keywords, strings, and URLs.
    text: source.Span,
    hash: Hash,
    delim: u21,
    numeric: Numeric,
    dimension: Dimension,
    unicode_range: UnicodeRange,
};

pub const Token = struct {
    kind: TokenKind,
    span: source.Span,
    data: TokenData = .none,

    pub fn raw(self: Token, file: *const source.SourceFile) ![]const u8 {
        return file.slice(self.span);
    }
};

const State = enum {
    data,
    single_quoted_string,
    double_quoted_string,
    eof,
};

/// An on-demand tokenizer. Every non-EOF call consumes at least one byte.
/// TOK-001 covers the dispatch state machine, punctuation, CDO/CDC, basic
/// ASCII ident-like tokens, raw strings, whitespace, and delimiters. The
/// spec-complete consumers named in TOK-002/TOK-003 extend this boundary.
pub const Tokenizer = struct {
    file: *const source.SourceFile,
    cursor: usize = 0,
    state: State = .data,

    pub fn init(file: *const source.SourceFile) Tokenizer {
        return .{ .file = file };
    }

    pub fn next(self: *Tokenizer) Token {
        if (self.state == .eof or self.cursor >= self.file.bytes.len) {
            self.state = .eof;
            return self.makeToken(.eof, self.cursor, self.cursor, .none);
        }

        const start = self.cursor;

        if (self.startsWith("<!--")) {
            self.cursor += 4;
            return self.makeToken(.cdo, start, self.cursor, .none);
        }
        if (self.startsWith("-->")) {
            self.cursor += 3;
            return self.makeToken(.cdc, start, self.cursor, .none);
        }

        if (isWhitespace(self.file.bytes[self.cursor])) {
            self.cursor += 1;
            while (self.cursor < self.file.bytes.len and isWhitespace(self.file.bytes[self.cursor])) {
                self.cursor += 1;
            }
            return self.makeToken(.whitespace, start, self.cursor, .none);
        }

        switch (self.file.bytes[self.cursor]) {
            '\'' => {
                self.cursor += 1;
                self.state = .single_quoted_string;
                return self.consumeString(start, self.cursor);
            },
            '"' => {
                self.cursor += 1;
                self.state = .double_quoted_string;
                return self.consumeString(start, self.cursor);
            },
            '#' => return self.consumeHash(start),
            '@' => return self.consumeAtKeywordOrDelim(start),
            ':' => return self.consumePunctuation(.colon, start),
            ';' => return self.consumePunctuation(.semicolon, start),
            ',' => return self.consumePunctuation(.comma, start),
            '[' => return self.consumePunctuation(.open_square, start),
            ']' => return self.consumePunctuation(.close_square, start),
            '(' => return self.consumePunctuation(.open_paren, start),
            ')' => return self.consumePunctuation(.close_paren, start),
            '{' => return self.consumePunctuation(.open_curly, start),
            '}' => return self.consumePunctuation(.close_curly, start),
            else => {},
        }

        if (self.wouldStartIdent(self.cursor)) {
            return self.consumeIdentLike(start);
        }

        const value = self.consumeCodepoint();
        return self.makeToken(.delim, start, self.cursor, .{ .delim = value });
    }

    fn consumePunctuation(self: *Tokenizer, kind: TokenKind, start: usize) Token {
        self.cursor += 1;
        return self.makeToken(kind, start, self.cursor, .none);
    }

    fn consumeHash(self: *Tokenizer, start: usize) Token {
        self.cursor += 1;
        const value_start = self.cursor;
        if (self.cursor < self.file.bytes.len and isAsciiName(self.file.bytes[self.cursor])) {
            const hash_type: HashType = if (self.wouldStartIdent(self.cursor)) .id else .unrestricted;
            self.consumeAsciiName();
            const value_span = self.span(value_start, self.cursor);
            return self.makeToken(.hash, start, self.cursor, .{
                .hash = .{ .value = value_span, .hash_type = hash_type },
            });
        }
        return self.makeToken(.delim, start, self.cursor, .{ .delim = '#' });
    }

    fn consumeAtKeywordOrDelim(self: *Tokenizer, start: usize) Token {
        self.cursor += 1;
        const value_start = self.cursor;
        if (self.wouldStartIdent(self.cursor)) {
            self.consumeAsciiName();
            return self.makeToken(.at_keyword, start, self.cursor, .{
                .text = self.span(value_start, self.cursor),
            });
        }
        return self.makeToken(.delim, start, self.cursor, .{ .delim = '@' });
    }

    fn consumeIdentLike(self: *Tokenizer, start: usize) Token {
        self.consumeAsciiName();
        const value_end = self.cursor;
        if (self.cursor < self.file.bytes.len and self.file.bytes[self.cursor] == '(') {
            self.cursor += 1;
            return self.makeToken(.function, start, self.cursor, .{
                .text = self.span(start, value_end),
            });
        }
        return self.makeToken(.ident, start, self.cursor, .{
            .text = self.span(start, value_end),
        });
    }

    fn consumeString(self: *Tokenizer, start: usize, value_start: usize) Token {
        const quote: u8 = switch (self.state) {
            .single_quoted_string => '\'',
            .double_quoted_string => '"',
            else => unreachable,
        };

        while (self.cursor < self.file.bytes.len) {
            const byte = self.file.bytes[self.cursor];
            if (byte == quote) {
                const value_end = self.cursor;
                self.cursor += 1;
                self.state = .data;
                return self.makeToken(.string, start, self.cursor, .{
                    .text = self.span(value_start, value_end),
                });
            }
            if (byte == '\n' or byte == '\r' or byte == '\x0c') {
                self.state = .data;
                return self.makeToken(.bad_string, start, self.cursor, .{
                    .text = self.span(value_start, self.cursor),
                });
            }
            if (byte == '\\') {
                self.cursor += 1;
                if (self.cursor >= self.file.bytes.len) break;
                if (self.file.bytes[self.cursor] == '\r') {
                    self.cursor += 1;
                    if (self.cursor < self.file.bytes.len and self.file.bytes[self.cursor] == '\n') self.cursor += 1;
                    continue;
                }
                if (self.file.bytes[self.cursor] == '\n' or self.file.bytes[self.cursor] == '\x0c') {
                    self.cursor += 1;
                    continue;
                }
            }
            _ = self.consumeCodepoint();
        }

        self.state = .data;
        return self.makeToken(.string, start, self.cursor, .{
            .text = self.span(value_start, self.cursor),
        });
    }

    fn consumeAsciiName(self: *Tokenizer) void {
        while (self.cursor < self.file.bytes.len and isAsciiName(self.file.bytes[self.cursor])) {
            self.cursor += 1;
        }
    }

    fn wouldStartIdent(self: *const Tokenizer, at: usize) bool {
        if (at >= self.file.bytes.len) return false;
        const first = self.file.bytes[at];
        if (isAsciiNameStart(first)) return true;
        if (first != '-') return false;
        if (at + 1 >= self.file.bytes.len) return false;
        const second = self.file.bytes[at + 1];
        return isAsciiNameStart(second) or second == '-';
    }

    fn consumeCodepoint(self: *Tokenizer) u21 {
        const first = self.file.bytes[self.cursor];
        const sequence_length = std.unicode.utf8ByteSequenceLength(first) catch {
            self.cursor += 1;
            return first;
        };
        const length: usize = sequence_length;
        if (self.cursor + length <= self.file.bytes.len) {
            const bytes = self.file.bytes[self.cursor .. self.cursor + length];
            if (std.unicode.utf8Decode(bytes)) |codepoint| {
                self.cursor += length;
                return codepoint;
            } else |_| {}
        }
        self.cursor += 1;
        return first;
    }

    fn startsWith(self: *const Tokenizer, expected: []const u8) bool {
        return self.cursor + expected.len <= self.file.bytes.len and
            std.mem.eql(u8, self.file.bytes[self.cursor .. self.cursor + expected.len], expected);
    }

    fn span(self: *const Tokenizer, start: usize, end: usize) source.Span {
        return .{ .source = self.file.id, .start = start, .end = end };
    }

    fn makeToken(self: *const Tokenizer, kind: TokenKind, start: usize, end: usize, data: TokenData) Token {
        return .{ .kind = kind, .span = self.span(start, end), .data = data };
    }
};

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

fn isAsciiNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isAsciiName(byte: u8) bool {
    return isAsciiNameStart(byte) or std.ascii.isDigit(byte) or byte == '-';
}

fn expectKinds(file: *const source.SourceFile, expected: []const TokenKind) !void {
    var tokenizer = Tokenizer.init(file);
    for (expected) |kind| {
        const token = tokenizer.next();
        if (token.kind != kind) {
            std.debug.print("expected {s}, found {s} at {d}..{d}\n", .{
                @tagName(kind),
                @tagName(token.kind),
                token.span.start,
                token.span.end,
            });
        }
        try std.testing.expectEqual(kind, token.kind);
        if (kind != .eof) try std.testing.expect(token.span.end > token.span.start);
    }
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

fn textSpan(token: Token) !source.Span {
    return switch (token.data) {
        .text => |span| span,
        else => error.UnexpectedTokenData,
    };
}

test "state machine recognizes CSS punctuation, whitespace, CDO, and CDC" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("tokens.css", " \t<!--:;,[ ](){}-->");
    const file = try manager.get(id);

    try expectKinds(file, &.{
        .whitespace,
        .cdo,
        .colon,
        .semicolon,
        .comma,
        .open_square,
        .whitespace,
        .close_square,
        .open_paren,
        .close_paren,
        .open_curly,
        .close_curly,
        .cdc,
        .eof,
    });
}

test "basic ASCII ident-like dispatch preserves raw value spans" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("ident.css", ".card#main:hover{color:red}");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    try std.testing.expectEqual(TokenKind.delim, tokenizer.next().kind);
    const card = tokenizer.next();
    try std.testing.expectEqual(TokenKind.ident, card.kind);
    try std.testing.expectEqualStrings("card", try file.slice(try textSpan(card)));

    const hash = tokenizer.next();
    try std.testing.expectEqual(TokenKind.hash, hash.kind);
    switch (hash.data) {
        .hash => |value| {
            try std.testing.expectEqual(HashType.id, value.hash_type);
            try std.testing.expectEqualStrings("main", try file.slice(value.value));
        },
        else => return error.UnexpectedTokenData,
    }

    try expectKindsFrom(&tokenizer, &.{
        .colon,
        .ident,
        .open_curly,
        .ident,
        .colon,
        .ident,
        .close_curly,
        .eof,
    });
}

fn expectKindsFrom(tokenizer: *Tokenizer, expected: []const TokenKind) !void {
    for (expected) |kind| {
        try std.testing.expectEqual(kind, tokenizer.next().kind);
    }
}

test "at-keywords and functions retain names without consuming nested content" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("functions.css", "@media foo(bar)");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const at_keyword = tokenizer.next();
    try std.testing.expectEqual(TokenKind.at_keyword, at_keyword.kind);
    try std.testing.expectEqualStrings("media", try file.slice(try textSpan(at_keyword)));
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);
    const function = tokenizer.next();
    try std.testing.expectEqual(TokenKind.function, function.kind);
    try std.testing.expectEqualStrings("foo", try file.slice(try textSpan(function)));
    try std.testing.expectEqualStrings("foo(", try function.raw(file));
    try expectKindsFrom(&tokenizer, &.{ .ident, .close_paren, .eof });
}

test "quoted-string states preserve delimiters and escaped quotes" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("strings.css", "'a;{}' \"b\\\"c\"");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const first = tokenizer.next();
    try std.testing.expectEqual(TokenKind.string, first.kind);
    try std.testing.expectEqualStrings("a;{}", try file.slice(try textSpan(first)));
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);
    const second = tokenizer.next();
    try std.testing.expectEqual(TokenKind.string, second.kind);
    try std.testing.expectEqualStrings("b\\\"c", try file.slice(try textSpan(second)));
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "newline ends a bad string without consuming recovery whitespace" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("bad-string.css", "\"bad\nnext");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    try expectKindsFrom(&tokenizer, &.{ .bad_string, .whitespace, .ident, .eof });
}

test "valid UTF-8 delimiters consume whole codepoints" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("unicode.css", "é");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const token = tokenizer.next();
    try std.testing.expectEqual(TokenKind.delim, token.kind);
    try std.testing.expectEqual(@as(usize, 2), token.span.len());
    switch (token.data) {
        .delim => |value| try std.testing.expectEqual(@as(u21, 0xe9), value),
        else => return error.UnexpectedTokenData,
    }
}

test "every byte makes progress and EOF is idempotent" {
    const allocator = std.testing.allocator;
    var byte_value: u16 = 0;
    while (byte_value <= 255) : (byte_value += 1) {
        var manager = try source.SourceManager.init(allocator);
        defer manager.deinit();
        const input = [_]u8{@intCast(byte_value)};
        const id = try manager.add("byte.css", &input);
        const file = try manager.get(id);
        var tokenizer = Tokenizer.init(file);

        const token = tokenizer.next();
        try std.testing.expect(token.kind != .eof);
        try std.testing.expectEqual(@as(usize, 0), token.span.start);
        try std.testing.expectEqual(@as(usize, 1), token.span.end);
        try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
        try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
    }
}
