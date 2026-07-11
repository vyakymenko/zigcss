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
    representation: source.Span,
};

pub const Hash = struct {
    value: source.Span,
    hash_type: HashType,
};

pub const Dimension = struct {
    numeric: Numeric,
    unit: source.Span,
};

pub const Comment = struct {
    content: source.Span,
    terminated: bool,
};

pub const IssueKind = enum {
    invalid_escape,
};

pub const Issue = struct {
    kind: IssueKind,
    span: source.Span,
};

pub const TokenFlags = struct {
    unterminated: bool = false,
};

pub const UnicodeRange = struct {
    start: u32,
    end: u32,
};

pub const TokenData = union(enum) {
    none,
    /// Raw source span for identifiers, functions, at-keywords, strings, and URLs.
    text: source.Span,
    hash: Hash,
    delim: u21,
    numeric: Numeric,
    dimension: Dimension,
    comment: Comment,
    unicode_range: UnicodeRange,
};

pub const Token = struct {
    kind: TokenKind,
    span: source.Span,
    data: TokenData = .none,
    flags: TokenFlags = .{},
    issue: ?Issue = null,

    pub fn raw(self: Token, file: *const source.SourceFile) ![]const u8 {
        return file.slice(self.span);
    }

    pub fn isTrivia(self: Token) bool {
        return self.kind == .whitespace or self.kind == .comment;
    }

    pub fn isTerminated(self: Token) bool {
        return !self.flags.unterminated;
    }

    pub fn startLocation(self: Token, file: *const source.SourceFile) error{
        SourceMismatch,
        InvalidLineIndex,
        InvalidOffset,
        OffsetInsideCodepoint,
    }!source.Location {
        if (!self.span.source.eql(file.id)) return error.SourceMismatch;
        return file.location(self.span.start);
    }

    pub fn endLocation(self: Token, file: *const source.SourceFile) error{
        SourceMismatch,
        InvalidLineIndex,
        InvalidOffset,
        OffsetInsideCodepoint,
    }!source.Location {
        if (!self.span.source.eql(file.id)) return error.SourceMismatch;
        return file.location(self.span.end);
    }

    pub fn valueSpan(self: Token) ?source.Span {
        return switch (self.data) {
            .text => |span| span,
            .hash => |hash| hash.value,
            .dimension => |dimension| dimension.unit,
            else => null,
        };
    }

    /// Returns a caller-owned UTF-8 value with CSS escapes decoded. The token's
    /// original spelling always remains available through `raw` and its span.
    pub fn decodedTextAlloc(self: Token, allocator: std.mem.Allocator, file: *const source.SourceFile) ![]u8 {
        const value_span = self.valueSpan() orelse return error.TokenHasNoText;
        if (!value_span.source.eql(file.id)) return error.SourceMismatch;
        const mode: DecodeMode = switch (self.kind) {
            .string, .bad_string => .string,
            else => .general,
        };
        return decodeSpanAlloc(allocator, file.bytes, value_span.start, value_span.end, mode);
    }
};

pub const Options = struct {
    /// CSS Syntax only enables unicode-range tokenization for the
    /// `unicode-range` descriptor entry point.
    unicode_ranges: bool = false,
};

const InputCodepoint = struct {
    value: u21,
    len: usize,
};

const EscapedCodepoint = struct {
    value: u21,
    invalid: bool = false,
};

const DecodeMode = enum {
    general,
    string,
};

const State = enum {
    data,
    single_quoted_string,
    double_quoted_string,
    eof,
};

/// An on-demand tokenizer. Every non-EOF call consumes at least one byte.
/// Input preprocessing follows CSS Syntax while all spans continue to address
/// the original source bytes.
pub const Tokenizer = struct {
    file: *const source.SourceFile,
    cursor: usize = 0,
    state: State = .data,
    options: Options = .{},
    current_issue: ?Issue = null,

    pub fn init(file: *const source.SourceFile) Tokenizer {
        return initWithOptions(file, .{});
    }

    pub fn initWithOptions(file: *const source.SourceFile, options: Options) Tokenizer {
        return .{ .file = file, .options = options };
    }

    pub fn next(self: *Tokenizer) Token {
        self.current_issue = null;
        if (self.state == .eof or self.cursor >= self.file.bytes.len) {
            self.state = .eof;
            return self.makeToken(.eof, self.cursor, self.cursor, .none);
        }

        const start = self.cursor;
        if (self.startsWith("/*")) return self.consumeComment(start);
        if (self.startsWith("<!--")) {
            self.cursor += 4;
            return self.makeToken(.cdo, start, self.cursor, .none);
        }
        if (self.startsWith("-->")) {
            self.cursor += 3;
            return self.makeToken(.cdc, start, self.cursor, .none);
        }

        const current = self.peek(self.cursor).?;
        if (isWhitespace(current.value)) {
            self.cursor += current.len;
            while (self.peek(self.cursor)) |next_codepoint| {
                if (!isWhitespace(next_codepoint.value)) break;
                self.cursor += next_codepoint.len;
            }
            return self.makeToken(.whitespace, start, self.cursor, .none);
        }

        if (self.options.unicode_ranges and self.wouldStartUnicodeRange(self.cursor)) {
            return self.consumeUnicodeRange(start);
        }

        switch (current.value) {
            '\'' => {
                self.cursor += current.len;
                self.state = .single_quoted_string;
                return self.consumeString(start, self.cursor);
            },
            '"' => {
                self.cursor += current.len;
                self.state = .double_quoted_string;
                return self.consumeString(start, self.cursor);
            },
            '#' => return self.consumeHash(start),
            '@' => return self.consumeAtKeywordOrDelim(start),
            ':' => return self.consumePunctuation(.colon, start, current.len),
            ';' => return self.consumePunctuation(.semicolon, start, current.len),
            ',' => return self.consumePunctuation(.comma, start, current.len),
            '[' => return self.consumePunctuation(.open_square, start, current.len),
            ']' => return self.consumePunctuation(.close_square, start, current.len),
            '(' => return self.consumePunctuation(.open_paren, start, current.len),
            ')' => return self.consumePunctuation(.close_paren, start, current.len),
            '{' => return self.consumePunctuation(.open_curly, start, current.len),
            '}' => return self.consumePunctuation(.close_curly, start, current.len),
            else => {},
        }

        if (self.wouldStartNumber(self.cursor)) return self.consumeNumericToken(start);
        if (self.wouldStartIdent(self.cursor)) return self.consumeIdentLike(start);

        const value = self.consumeCodepoint();
        return self.makeToken(.delim, start, self.cursor, .{ .delim = value });
    }

    fn consumePunctuation(self: *Tokenizer, kind: TokenKind, start: usize, length: usize) Token {
        self.cursor += length;
        return self.makeToken(kind, start, self.cursor, .none);
    }

    fn consumeComment(self: *Tokenizer, start: usize) Token {
        self.cursor += 2;
        const content_start = self.cursor;
        while (self.cursor < self.file.bytes.len) {
            if (self.cursor + 1 < self.file.bytes.len and
                self.file.bytes[self.cursor] == '*' and self.file.bytes[self.cursor + 1] == '/')
            {
                const content_end = self.cursor;
                self.cursor += 2;
                return self.makeToken(.comment, start, self.cursor, .{
                    .comment = .{
                        .content = self.span(content_start, content_end),
                        .terminated = true,
                    },
                });
            }
            _ = self.consumeCodepoint();
        }

        return self.makeUnterminatedToken(.comment, start, self.cursor, .{
            .comment = .{
                .content = self.span(content_start, self.cursor),
                .terminated = false,
            },
        });
    }

    fn consumeHash(self: *Tokenizer, start: usize) Token {
        self.cursor += 1;
        const value_start = self.cursor;
        const next_codepoint = self.peek(self.cursor);
        if ((next_codepoint != null and isIdent(next_codepoint.?.value)) or self.isValidEscape(self.cursor)) {
            const hash_type: HashType = if (self.wouldStartIdent(self.cursor)) .id else .unrestricted;
            self.consumeName();
            return self.makeToken(.hash, start, self.cursor, .{
                .hash = .{ .value = self.span(value_start, self.cursor), .hash_type = hash_type },
            });
        }
        return self.makeToken(.delim, start, self.cursor, .{ .delim = '#' });
    }

    fn consumeAtKeywordOrDelim(self: *Tokenizer, start: usize) Token {
        self.cursor += 1;
        const value_start = self.cursor;
        if (self.wouldStartIdent(self.cursor)) {
            self.consumeName();
            return self.makeToken(.at_keyword, start, self.cursor, .{
                .text = self.span(value_start, self.cursor),
            });
        }
        return self.makeToken(.delim, start, self.cursor, .{ .delim = '@' });
    }

    fn consumeIdentLike(self: *Tokenizer, start: usize) Token {
        self.consumeName();
        const value_end = self.cursor;
        if (self.peek(self.cursor)) |next_codepoint| {
            if (next_codepoint.value == '(') {
                self.cursor += next_codepoint.len;
                const value_span = self.span(start, value_end);
                if (decodedSpanEqualsAscii(self.file.bytes, value_span.start, value_span.end, "url")) {
                    var lookahead = self.cursor;
                    while (inputCodepointAt(self.file.bytes, lookahead)) |lookahead_codepoint| {
                        if (!isWhitespace(lookahead_codepoint.value)) break;
                        lookahead += lookahead_codepoint.len;
                    }
                    if (inputCodepointAt(self.file.bytes, lookahead)) |after_whitespace| {
                        if (after_whitespace.value == '"' or after_whitespace.value == '\'') {
                            return self.makeToken(.function, start, self.cursor, .{ .text = value_span });
                        }
                    }
                    return self.consumeUrl(start);
                }
                return self.makeToken(.function, start, self.cursor, .{ .text = value_span });
            }
        }
        return self.makeToken(.ident, start, self.cursor, .{
            .text = self.span(start, value_end),
        });
    }

    fn consumeString(self: *Tokenizer, start: usize, value_start: usize) Token {
        const quote: u21 = switch (self.state) {
            .single_quoted_string => '\'',
            .double_quoted_string => '"',
            else => unreachable,
        };

        while (self.peek(self.cursor)) |codepoint| {
            if (codepoint.value == quote) {
                const value_end = self.cursor;
                self.cursor += codepoint.len;
                self.state = .data;
                return self.makeToken(.string, start, self.cursor, .{
                    .text = self.span(value_start, value_end),
                });
            }
            if (codepoint.value == '\n') {
                self.state = .data;
                return self.makeToken(.bad_string, start, self.cursor, .{
                    .text = self.span(value_start, self.cursor),
                });
            }
            if (codepoint.value == '\\') {
                self.cursor += codepoint.len;
                const escaped = self.peek(self.cursor) orelse break;
                if (escaped.value == '\n') {
                    self.cursor += escaped.len;
                } else {
                    _ = self.consumeEscapedCodepoint();
                }
                continue;
            }
            self.cursor += codepoint.len;
        }

        self.state = .data;
        return self.makeUnterminatedToken(.string, start, self.cursor, .{
            .text = self.span(value_start, self.cursor),
        });
    }

    fn consumeNumericToken(self: *Tokenizer, start: usize) Token {
        const numeric = self.consumeNumber();
        if (self.wouldStartIdent(self.cursor)) {
            const unit_start = self.cursor;
            self.consumeName();
            return self.makeToken(.dimension, start, self.cursor, .{
                .dimension = .{ .numeric = numeric, .unit = self.span(unit_start, self.cursor) },
            });
        }
        if (self.peek(self.cursor)) |codepoint| {
            if (codepoint.value == '%') {
                self.cursor += codepoint.len;
                return self.makeToken(.percentage, start, self.cursor, .{ .numeric = numeric });
            }
        }
        return self.makeToken(.number, start, self.cursor, .{ .numeric = numeric });
    }

    fn consumeNumber(self: *Tokenizer) Numeric {
        const start = self.cursor;
        var number_type: NumberType = .integer;
        var sign: Sign = .none;

        if (self.cursor < self.file.bytes.len) {
            if (self.file.bytes[self.cursor] == '+') {
                sign = .plus;
                self.cursor += 1;
            } else if (self.file.bytes[self.cursor] == '-') {
                sign = .minus;
                self.cursor += 1;
            }
        }
        while (self.asciiDigitAt(self.cursor)) self.cursor += 1;

        if (self.cursor + 1 < self.file.bytes.len and
            self.file.bytes[self.cursor] == '.' and self.asciiDigitAt(self.cursor + 1))
        {
            number_type = .number;
            self.cursor += 1;
            while (self.asciiDigitAt(self.cursor)) self.cursor += 1;
        }

        if (self.cursor < self.file.bytes.len and
            (self.file.bytes[self.cursor] == 'e' or self.file.bytes[self.cursor] == 'E'))
        {
            var exponent_cursor = self.cursor + 1;
            if (exponent_cursor < self.file.bytes.len and
                (self.file.bytes[exponent_cursor] == '+' or self.file.bytes[exponent_cursor] == '-'))
            {
                exponent_cursor += 1;
            }
            if (self.asciiDigitAt(exponent_cursor)) {
                number_type = .number;
                self.cursor = exponent_cursor + 1;
                while (self.asciiDigitAt(self.cursor)) self.cursor += 1;
            }
        }

        const representation = self.span(start, self.cursor);
        var parse_bytes = self.file.bytes[start..self.cursor];
        if (parse_bytes.len > 0 and parse_bytes[0] == '+') parse_bytes = parse_bytes[1..];
        const value = std.fmt.parseFloat(f64, parse_bytes) catch std.math.nan(f64);
        return .{
            .value = value,
            .number_type = number_type,
            .sign = sign,
            .representation = representation,
        };
    }

    fn consumeUrl(self: *Tokenizer, start: usize) Token {
        while (self.peek(self.cursor)) |codepoint| {
            if (!isWhitespace(codepoint.value)) break;
            self.cursor += codepoint.len;
        }
        const value_start = self.cursor;

        while (self.peek(self.cursor)) |codepoint| {
            if (codepoint.value == ')') {
                const value_end = self.cursor;
                self.cursor += codepoint.len;
                return self.makeToken(.url, start, self.cursor, .{
                    .text = self.span(value_start, value_end),
                });
            }
            if (isWhitespace(codepoint.value)) {
                const value_end = self.cursor;
                while (self.peek(self.cursor)) |whitespace| {
                    if (!isWhitespace(whitespace.value)) break;
                    self.cursor += whitespace.len;
                }
                if (self.peek(self.cursor)) |after_whitespace| {
                    if (after_whitespace.value == ')') {
                        self.cursor += after_whitespace.len;
                        return self.makeToken(.url, start, self.cursor, .{
                            .text = self.span(value_start, value_end),
                        });
                    }
                    self.consumeBadUrlRemnants();
                    return self.makeToken(.bad_url, start, self.cursor, .{
                        .text = self.span(value_start, value_end),
                    });
                }
                return self.makeUnterminatedToken(.url, start, self.cursor, .{
                    .text = self.span(value_start, value_end),
                });
            }
            if (codepoint.value == '"' or codepoint.value == '\'' or codepoint.value == '(' or
                isNonPrintable(codepoint.value))
            {
                const value_end = self.cursor;
                self.consumeBadUrlRemnants();
                return self.makeToken(.bad_url, start, self.cursor, .{
                    .text = self.span(value_start, value_end),
                });
            }
            if (codepoint.value == '\\') {
                if (!self.isValidEscape(self.cursor)) {
                    const value_end = self.cursor;
                    self.consumeBadUrlRemnants();
                    return self.makeToken(.bad_url, start, self.cursor, .{
                        .text = self.span(value_start, value_end),
                    });
                }
                self.cursor += codepoint.len;
                _ = self.consumeEscapedCodepoint();
                continue;
            }
            self.cursor += codepoint.len;
        }

        return self.makeUnterminatedToken(.url, start, self.cursor, .{
            .text = self.span(value_start, self.cursor),
        });
    }

    fn consumeBadUrlRemnants(self: *Tokenizer) void {
        while (self.peek(self.cursor)) |codepoint| {
            if (codepoint.value == ')') {
                self.cursor += codepoint.len;
                return;
            }
            if (codepoint.value == '\\' and self.isValidEscape(self.cursor)) {
                self.cursor += codepoint.len;
                _ = self.consumeEscapedCodepoint();
            } else {
                self.cursor += codepoint.len;
            }
        }
    }

    fn consumeUnicodeRange(self: *Tokenizer, start: usize) Token {
        self.cursor += 2; // U+
        var range_start: u32 = 0;
        var range_end: u32 = 0;
        var hex_count: usize = 0;
        while (hex_count < 6 and self.cursor < self.file.bytes.len and
            std.ascii.isHex(self.file.bytes[self.cursor]))
        {
            const nibble = hexValue(self.file.bytes[self.cursor]);
            range_start = (range_start << 4) | nibble;
            range_end = (range_end << 4) | nibble;
            self.cursor += 1;
            hex_count += 1;
        }

        var question_count: usize = 0;
        while (hex_count + question_count < 6 and self.cursor < self.file.bytes.len and
            self.file.bytes[self.cursor] == '?')
        {
            range_start <<= 4;
            range_end = (range_end << 4) | 0xf;
            self.cursor += 1;
            question_count += 1;
        }

        if (question_count == 0 and self.cursor + 1 < self.file.bytes.len and
            self.file.bytes[self.cursor] == '-' and std.ascii.isHex(self.file.bytes[self.cursor + 1]))
        {
            self.cursor += 1;
            range_end = 0;
            var end_count: usize = 0;
            while (end_count < 6 and self.cursor < self.file.bytes.len and
                std.ascii.isHex(self.file.bytes[self.cursor]))
            {
                range_end = (range_end << 4) | hexValue(self.file.bytes[self.cursor]);
                self.cursor += 1;
                end_count += 1;
            }
        }

        return self.makeToken(.unicode_range, start, self.cursor, .{
            .unicode_range = .{ .start = range_start, .end = range_end },
        });
    }

    fn consumeName(self: *Tokenizer) void {
        while (self.peek(self.cursor)) |codepoint| {
            if (isIdent(codepoint.value)) {
                self.cursor += codepoint.len;
            } else if (codepoint.value == '\\' and self.isValidEscape(self.cursor)) {
                self.cursor += codepoint.len;
                _ = self.consumeEscapedCodepoint();
            } else {
                return;
            }
        }
    }

    fn consumeEscapedCodepoint(self: *Tokenizer) u21 {
        const escape_start = self.cursor - 1;
        const escaped = consumeEscapedAt(self.file.bytes, &self.cursor, self.file.bytes.len);
        if (escaped.invalid and self.current_issue == null) {
            self.current_issue = .{
                .kind = .invalid_escape,
                .span = self.span(escape_start, self.cursor),
            };
        }
        return escaped.value;
    }

    fn wouldStartIdent(self: *const Tokenizer, at: usize) bool {
        const first = self.peek(at) orelse return false;
        if (first.value == '-') {
            const second_at = at + first.len;
            const second = self.peek(second_at) orelse return false;
            return isIdentStart(second.value) or second.value == '-' or self.isValidEscape(second_at);
        }
        if (isIdentStart(first.value)) return true;
        return first.value == '\\' and self.isValidEscape(at);
    }

    fn wouldStartNumber(self: *const Tokenizer, at: usize) bool {
        const first = self.peek(at) orelse return false;
        const second_at = at + first.len;
        const second = self.peek(second_at);
        if (first.value == '+' or first.value == '-') {
            if (second) |second_codepoint| {
                if (isDigit(second_codepoint.value)) return true;
                if (second_codepoint.value == '.') {
                    const third = self.peek(second_at + second_codepoint.len);
                    return third != null and isDigit(third.?.value);
                }
            }
            return false;
        }
        if (first.value == '.') return second != null and isDigit(second.?.value);
        return isDigit(first.value);
    }

    fn wouldStartUnicodeRange(self: *const Tokenizer, at: usize) bool {
        const first = self.peek(at) orelse return false;
        if (first.value != 'u' and first.value != 'U') return false;
        const second_at = at + first.len;
        const second = self.peek(second_at) orelse return false;
        if (second.value != '+') return false;
        const third = self.peek(second_at + second.len) orelse return false;
        return third.value == '?' or isHexCodepoint(third.value);
    }

    fn isValidEscape(self: *const Tokenizer, at: usize) bool {
        const first = self.peek(at) orelse return false;
        if (first.value != '\\') return false;
        const second = self.peek(at + first.len) orelse return true;
        return second.value != '\n';
    }

    fn consumeCodepoint(self: *Tokenizer) u21 {
        const codepoint = self.peek(self.cursor).?;
        self.cursor += codepoint.len;
        return codepoint.value;
    }

    fn peek(self: *const Tokenizer, at: usize) ?InputCodepoint {
        return inputCodepointAt(self.file.bytes, at);
    }

    fn asciiDigitAt(self: *const Tokenizer, at: usize) bool {
        return at < self.file.bytes.len and std.ascii.isDigit(self.file.bytes[at]);
    }

    fn startsWith(self: *const Tokenizer, expected: []const u8) bool {
        return self.cursor + expected.len <= self.file.bytes.len and
            std.mem.eql(u8, self.file.bytes[self.cursor .. self.cursor + expected.len], expected);
    }

    fn span(self: *const Tokenizer, start: usize, end: usize) source.Span {
        return .{ .source = self.file.id, .start = start, .end = end };
    }

    fn makeToken(self: *const Tokenizer, kind: TokenKind, start: usize, end: usize, data: TokenData) Token {
        return .{
            .kind = kind,
            .span = self.span(start, end),
            .data = data,
            .issue = self.current_issue,
        };
    }

    fn makeUnterminatedToken(
        self: *const Tokenizer,
        kind: TokenKind,
        start: usize,
        end: usize,
        data: TokenData,
    ) Token {
        var token = self.makeToken(kind, start, end, data);
        token.flags.unterminated = true;
        return token;
    }
};

fn inputCodepointAt(bytes: []const u8, at: usize) ?InputCodepoint {
    if (at >= bytes.len) return null;
    const first = bytes[at];
    if (first == 0) return .{ .value = 0xfffd, .len = 1 };
    if (first == '\r') {
        return .{
            .value = '\n',
            .len = if (at + 1 < bytes.len and bytes[at + 1] == '\n') 2 else 1,
        };
    }
    if (first == '\x0c') return .{ .value = '\n', .len = 1 };

    const sequence_length = std.unicode.utf8ByteSequenceLength(first) catch {
        return .{ .value = 0xfffd, .len = 1 };
    };
    const length: usize = sequence_length;
    if (at + length <= bytes.len) {
        if (std.unicode.utf8Decode(bytes[at .. at + length])) |codepoint| {
            return .{ .value = codepoint, .len = length };
        } else |_| {}
    }
    return .{ .value = 0xfffd, .len = 1 };
}

fn consumeEscapedAt(bytes: []const u8, cursor: *usize, limit: usize) EscapedCodepoint {
    const first = if (cursor.* < limit) inputCodepointAt(bytes, cursor.*) else null;
    const codepoint = first orelse return .{ .value = 0xfffd, .invalid = true };
    if (isHexCodepoint(codepoint.value)) {
        var value: u32 = 0;
        var count: usize = 0;
        while (count < 6 and cursor.* < limit) {
            const digit = inputCodepointAt(bytes, cursor.*) orelse break;
            if (!isHexCodepoint(digit.value)) break;
            value = (value << 4) | hexValue(@intCast(digit.value));
            cursor.* += digit.len;
            count += 1;
        }
        if (cursor.* < limit) {
            if (inputCodepointAt(bytes, cursor.*)) |whitespace| {
                if (isWhitespace(whitespace.value)) cursor.* += whitespace.len;
            }
        }
        if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) {
            return .{ .value = 0xfffd, .invalid = true };
        }
        return .{ .value = @intCast(value) };
    }

    cursor.* += codepoint.len;
    return .{ .value = codepoint.value };
}

fn nextDecodedCodepoint(bytes: []const u8, cursor: *usize, end: usize, mode: DecodeMode) ?u21 {
    while (cursor.* < end) {
        const codepoint = inputCodepointAt(bytes, cursor.*) orelse return null;
        cursor.* += codepoint.len;
        if (codepoint.value != '\\') return codepoint.value;
        if (cursor.* == end and mode == .string) return null;
        if (cursor.* < end) {
            const after_slash = inputCodepointAt(bytes, cursor.*) orelse return 0xfffd;
            if (after_slash.value == '\n') {
                cursor.* += after_slash.len;
                continue;
            }
        }
        return consumeEscapedAt(bytes, cursor, end).value;
    }
    return null;
}

fn decodeSpanAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    start: usize,
    end: usize,
    mode: DecodeMode,
) ![]u8 {
    if (start > end or end > bytes.len) return error.InvalidSpan;
    var decoded = try std.ArrayList(u8).initCapacity(allocator, end - start);
    errdefer decoded.deinit(allocator);

    var cursor = start;
    while (nextDecodedCodepoint(bytes, &cursor, end, mode)) |codepoint| {
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &encoded);
        try decoded.appendSlice(allocator, encoded[0..length]);
    }
    return try decoded.toOwnedSlice(allocator);
}

fn decodedSpanEqualsAscii(bytes: []const u8, start: usize, end: usize, expected: []const u8) bool {
    var cursor = start;
    var expected_index: usize = 0;
    while (nextDecodedCodepoint(bytes, &cursor, end, .general)) |codepoint| {
        if (expected_index >= expected.len or codepoint > 0x7f) return false;
        if (std.ascii.toLower(@intCast(codepoint)) != std.ascii.toLower(expected[expected_index])) return false;
        expected_index += 1;
    }
    return expected_index == expected.len;
}

fn isWhitespace(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == '\t' or codepoint == '\n';
}

fn isIdentStart(codepoint: u21) bool {
    return codepoint >= 0x80 or codepoint == '_' or
        (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z');
}

fn isIdent(codepoint: u21) bool {
    return isIdentStart(codepoint) or isDigit(codepoint) or codepoint == '-';
}

fn isDigit(codepoint: u21) bool {
    return codepoint >= '0' and codepoint <= '9';
}

fn isHexCodepoint(codepoint: u21) bool {
    return isDigit(codepoint) or
        (codepoint >= 'A' and codepoint <= 'F') or
        (codepoint >= 'a' and codepoint <= 'f');
}

fn hexValue(byte: u8) u32 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => unreachable,
    };
}

fn isNonPrintable(codepoint: u21) bool {
    return codepoint <= 0x08 or codepoint == 0x0b or
        (codepoint >= 0x0e and codepoint <= 0x1f) or codepoint == 0x7f;
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

test "valid non-ASCII codepoints form identifiers without splitting spans" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("unicode.css", "é");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const token = tokenizer.next();
    try std.testing.expectEqual(TokenKind.ident, token.kind);
    try std.testing.expectEqual(@as(usize, 2), token.span.len());
    try expectDecoded(token, file, "é");
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

fn expectDecoded(token: Token, file: *const source.SourceFile, expected: []const u8) !void {
    const decoded = try token.decodedTextAlloc(std.testing.allocator, file);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(expected, decoded);
}

fn numericData(token: Token) !Numeric {
    return switch (token.data) {
        .numeric => |numeric| numeric,
        else => error.UnexpectedTokenData,
    };
}

fn dimensionData(token: Token) !Dimension {
    return switch (token.data) {
        .dimension => |dimension| dimension,
        else => error.UnexpectedTokenData,
    };
}

test "escapes and Unicode codepoints participate in ident sequences" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("names.css", "café \\66 oo --x #\\31 23 @média");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const unicode = tokenizer.next();
    try std.testing.expectEqual(TokenKind.ident, unicode.kind);
    try expectDecoded(unicode, file, "café");
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);

    const escaped = tokenizer.next();
    try std.testing.expectEqual(TokenKind.ident, escaped.kind);
    try expectDecoded(escaped, file, "foo");
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);

    const custom = tokenizer.next();
    try std.testing.expectEqual(TokenKind.ident, custom.kind);
    try expectDecoded(custom, file, "--x");
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);

    const hash = tokenizer.next();
    try std.testing.expectEqual(TokenKind.hash, hash.kind);
    try expectDecoded(hash, file, "123");
    try std.testing.expectEqual(HashType.id, hash.data.hash.hash_type);
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);

    const at_keyword = tokenizer.next();
    try std.testing.expectEqual(TokenKind.at_keyword, at_keyword.kind);
    try expectDecoded(at_keyword, file, "média");
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "numbers preserve value, representation type, sign, and suffix class" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("numbers.css", "12 -0.5 +.25 1e3 1E-2 10px 50% .75turn");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const integer = try numericData(tokenizer.next());
    try std.testing.expectEqual(@as(f64, 12), integer.value);
    try std.testing.expectEqual(NumberType.integer, integer.number_type);
    try std.testing.expectEqual(Sign.none, integer.sign);
    try std.testing.expectEqualStrings("12", try file.slice(integer.representation));

    _ = tokenizer.next();
    const negative = try numericData(tokenizer.next());
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), negative.value, 0.000001);
    try std.testing.expectEqual(Sign.minus, negative.sign);

    _ = tokenizer.next();
    const positive = try numericData(tokenizer.next());
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), positive.value, 0.000001);
    try std.testing.expectEqual(Sign.plus, positive.sign);

    _ = tokenizer.next();
    try std.testing.expectApproxEqAbs(@as(f64, 1000), (try numericData(tokenizer.next())).value, 0.000001);
    _ = tokenizer.next();
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), (try numericData(tokenizer.next())).value, 0.000001);

    _ = tokenizer.next();
    const pixels_token = tokenizer.next();
    try std.testing.expectEqual(TokenKind.dimension, pixels_token.kind);
    const pixels = try dimensionData(pixels_token);
    try std.testing.expectEqual(@as(f64, 10), pixels.numeric.value);
    try expectDecoded(pixels_token, file, "px");

    _ = tokenizer.next();
    const percentage = tokenizer.next();
    try std.testing.expectEqual(TokenKind.percentage, percentage.kind);
    try std.testing.expectEqual(@as(f64, 50), (try numericData(percentage)).value);

    _ = tokenizer.next();
    const turns = tokenizer.next();
    try std.testing.expectEqual(TokenKind.dimension, turns.kind);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), (try dimensionData(turns)).numeric.value, 0.000001);
    try expectDecoded(turns, file, "turn");
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "URL dispatch distinguishes quoted functions and recovers bad URLs" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add(
        "urls.css",
        "url(foo.png) URL(foo\\ bar) url(\"quoted.png\") url(foo bar) tail",
    );
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const first = tokenizer.next();
    try std.testing.expectEqual(TokenKind.url, first.kind);
    try expectDecoded(first, file, "foo.png");
    _ = tokenizer.next();

    const escaped = tokenizer.next();
    try std.testing.expectEqual(TokenKind.url, escaped.kind);
    try expectDecoded(escaped, file, "foo bar");
    _ = tokenizer.next();

    const quoted = tokenizer.next();
    try std.testing.expectEqual(TokenKind.function, quoted.kind);
    try expectDecoded(quoted, file, "url");
    try std.testing.expectEqual(TokenKind.string, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.close_paren, tokenizer.next().kind);
    _ = tokenizer.next();

    try std.testing.expectEqual(TokenKind.bad_url, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.ident, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "truncated and invalid escapes recover without losing following tokens" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("recovery.css", "url(foo\\\nbar)z \\110000  \\D800  \\0");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    try std.testing.expectEqual(TokenKind.bad_url, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.ident, tokenizer.next().kind);
    _ = tokenizer.next();

    const too_large = tokenizer.next();
    try expectDecoded(too_large, file, "�");
    try std.testing.expectEqual(IssueKind.invalid_escape, too_large.issue.?.kind);
    _ = tokenizer.next();
    const surrogate = tokenizer.next();
    try expectDecoded(surrogate, file, "�");
    try std.testing.expectEqual(IssueKind.invalid_escape, surrogate.issue.?.kind);
    _ = tokenizer.next();
    const zero = tokenizer.next();
    try expectDecoded(zero, file, "�");
    try std.testing.expectEqual(IssueKind.invalid_escape, zero.issue.?.kind);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "string escape decoding removes continuations and decodes hex" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("escaped-string.css", "\"\\41\\\nB\"");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const token = tokenizer.next();
    try std.testing.expectEqual(TokenKind.string, token.kind);
    try expectDecoded(token, file, "AB");
}

test "unicode ranges are emitted only for the explicit descriptor mode" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("ranges.css", "U+00A0-00FF u+4?? U+1234567");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.initWithOptions(file, .{ .unicode_ranges = true });

    const explicit = tokenizer.next();
    try std.testing.expectEqual(TokenKind.unicode_range, explicit.kind);
    try std.testing.expectEqual(UnicodeRange{ .start = 0x00a0, .end = 0x00ff }, explicit.data.unicode_range);
    _ = tokenizer.next();
    const wildcard = tokenizer.next();
    try std.testing.expectEqual(UnicodeRange{ .start = 0x0400, .end = 0x04ff }, wildcard.data.unicode_range);
    _ = tokenizer.next();
    const capped = tokenizer.next();
    try std.testing.expectEqual(UnicodeRange{ .start = 0x123456, .end = 0x123456 }, capped.data.unicode_range);
    const trailing = tokenizer.next();
    try std.testing.expectEqual(TokenKind.number, trailing.kind);
    try std.testing.expectEqual(@as(f64, 7), (try numericData(trailing)).value);
}

test "large exponents stay bounded and do not panic" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("large-number.css", "1e999 -1e999");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    try std.testing.expect(std.math.isInf((try numericData(tokenizer.next())).value));
    _ = tokenizer.next();
    const negative = (try numericData(tokenizer.next())).value;
    try std.testing.expect(std.math.isInf(negative) and negative < 0);
}

test "string and identifier trailing escapes follow distinct EOF rules" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const string_id = try manager.add("string-eof.css", &.{ '"', '\\' });
    const ident_id = try manager.add("ident-eof.css", &.{'\\'});

    const string_file = try manager.get(string_id);
    var string_tokenizer = Tokenizer.init(string_file);
    const string = string_tokenizer.next();
    try std.testing.expectEqual(TokenKind.string, string.kind);
    try std.testing.expect(!string.isTerminated());
    try expectDecoded(string, string_file, "");

    const ident_file = try manager.get(ident_id);
    var ident_tokenizer = Tokenizer.init(ident_file);
    const ident = ident_tokenizer.next();
    try std.testing.expectEqual(TokenKind.ident, ident.kind);
    try std.testing.expectEqual(IssueKind.invalid_escape, ident.issue.?.kind);
    try expectDecoded(ident, ident_file, "�");
}

test "escaped URL names and quoted lookahead follow ident-like dispatch" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("escaped-url.css", "u\\72l(foo) url(  \"x\")");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const escaped_name = tokenizer.next();
    try std.testing.expectEqual(TokenKind.url, escaped_name.kind);
    try expectDecoded(escaped_name, file, "foo");
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.function, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.whitespace, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.string, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.close_paren, tokenizer.next().kind);
}

test "bad URL recovery ignores escaped closing parentheses" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("bad-url-close.css", "url(foo bar\\) baz)tail");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    try std.testing.expectEqual(TokenKind.bad_url, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.ident, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "URL tokens recover at EOF and preserve trailing escapes" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const plain_id = try manager.add("url-eof.css", "url(foo");
    const escaped_id = try manager.add("url-escape-eof.css", "url(foo\\");

    const plain_file = try manager.get(plain_id);
    var plain_tokenizer = Tokenizer.init(plain_file);
    const plain = plain_tokenizer.next();
    try std.testing.expectEqual(TokenKind.url, plain.kind);
    try std.testing.expect(!plain.isTerminated());
    try expectDecoded(plain, plain_file, "foo");
    try std.testing.expectEqualStrings("url(foo", try plain.raw(plain_file));
    try std.testing.expectEqual(TokenKind.eof, plain_tokenizer.next().kind);

    const escaped_file = try manager.get(escaped_id);
    var escaped_tokenizer = Tokenizer.init(escaped_file);
    const escaped = escaped_tokenizer.next();
    try std.testing.expectEqual(TokenKind.url, escaped.kind);
    try std.testing.expect(!escaped.isTerminated());
    try std.testing.expectEqual(IssueKind.invalid_escape, escaped.issue.?.kind);
    try expectDecoded(escaped, escaped_file, "foo�");
    try std.testing.expectEqual(TokenKind.eof, escaped_tokenizer.next().kind);
}

test "invalid newline escapes remain separate tokens" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("invalid-escape.css", "\\\r\nx");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const slash = tokenizer.next();
    try std.testing.expectEqual(TokenKind.delim, slash.kind);
    try std.testing.expectEqual(@as(u21, '\\'), slash.data.delim);
    try std.testing.expectEqualStrings("\\", try slash.raw(file));
    const newline = tokenizer.next();
    try std.testing.expectEqual(TokenKind.whitespace, newline.kind);
    try std.testing.expectEqualStrings("\r\n", try newline.raw(file));
    try std.testing.expectEqual(TokenKind.ident, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "incomplete exponents preserve CSS numeric dispatch boundaries" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("exponents.css", "1e+px 2E- 3e");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const first = tokenizer.next();
    try std.testing.expectEqual(TokenKind.dimension, first.kind);
    try std.testing.expectEqualStrings("1", try file.slice((try dimensionData(first)).numeric.representation));
    try expectDecoded(first, file, "e");
    try std.testing.expectEqual(TokenKind.delim, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.ident, tokenizer.next().kind);
    _ = tokenizer.next();

    const second = tokenizer.next();
    try std.testing.expectEqual(TokenKind.dimension, second.kind);
    try expectDecoded(second, file, "E-");
    _ = tokenizer.next();

    const third = tokenizer.next();
    try std.testing.expectEqual(TokenKind.dimension, third.kind);
    try expectDecoded(third, file, "e");
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "truncated UTF-8 and preprocessed NUL bytes stay bounded" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const bytes = [_]u8{ 0xf0, 0x9f, 0, 'x' };
    const id = try manager.add("invalid-utf8.css", &bytes);
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const token = tokenizer.next();
    try std.testing.expectEqual(TokenKind.ident, token.kind);
    try std.testing.expectEqual(@as(usize, 0), token.span.start);
    try std.testing.expectEqual(bytes.len, token.span.end);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

fn decodeWithAllocator(allocator: std.mem.Allocator) !void {
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("allocation.css", "\\1f642 name");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);
    const token = tokenizer.next();
    const decoded = try token.decodedTextAlloc(allocator, file);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("🙂name", decoded);
}

test "decoded token ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeWithAllocator, .{});
}

test "comments are retained as terminated lossless trivia" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("comments.css", "a/* one */ /**/b");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    try std.testing.expectEqual(TokenKind.ident, tokenizer.next().kind);
    const first = tokenizer.next();
    try std.testing.expectEqual(TokenKind.comment, first.kind);
    try std.testing.expect(first.isTrivia());
    try std.testing.expectEqualStrings("/* one */", try first.raw(file));
    try std.testing.expectEqualStrings(" one ", try file.slice(first.data.comment.content));
    try std.testing.expect(first.data.comment.terminated);

    const whitespace = tokenizer.next();
    try std.testing.expectEqual(TokenKind.whitespace, whitespace.kind);
    try std.testing.expect(whitespace.isTrivia());
    const empty = tokenizer.next();
    try std.testing.expectEqualStrings("", try file.slice(empty.data.comment.content));
    try std.testing.expect(empty.data.comment.terminated);
    try std.testing.expectEqual(TokenKind.ident, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "unterminated comments consume through EOF without indexing past input" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("comment-eof.css", "/* unterminated *");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    const comment = tokenizer.next();
    try std.testing.expectEqual(TokenKind.comment, comment.kind);
    try std.testing.expect(!comment.data.comment.terminated);
    try std.testing.expectEqualStrings(" unterminated *", try file.slice(comment.data.comment.content));
    try std.testing.expectEqual(file.bytes.len, comment.span.end);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
    try std.testing.expectEqual(TokenKind.eof, tokenizer.next().kind);
}

test "token locations derive from original CRLF Unicode and form-feed bytes" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("locations.css", "é/*a\r\nβ*/\x0c x");
    const other_id = try manager.add("other.css", "x");
    const file = try manager.get(id);
    const other = try manager.get(other_id);
    var tokenizer = Tokenizer.init(file);

    const ident = tokenizer.next();
    try std.testing.expectEqual(source.Location{ .line = 1, .column = 1, .byte_offset = 0 }, try ident.startLocation(file));
    try std.testing.expectEqual(source.Location{ .line = 1, .column = 2, .byte_offset = 2 }, try ident.endLocation(file));
    try std.testing.expectError(error.SourceMismatch, ident.startLocation(other));

    const comment = tokenizer.next();
    try std.testing.expectEqual(source.Location{ .line = 1, .column = 2, .byte_offset = 2 }, try comment.startLocation(file));
    try std.testing.expectEqual(source.Location{ .line = 2, .column = 4, .byte_offset = 11 }, try comment.endLocation(file));

    const whitespace = tokenizer.next();
    try std.testing.expectEqualStrings("\x0c ", try whitespace.raw(file));
    try std.testing.expectEqual(source.Location{ .line = 2, .column = 4, .byte_offset = 11 }, try whitespace.startLocation(file));
    try std.testing.expectEqual(source.Location{ .line = 3, .column = 2, .byte_offset = 13 }, try whitespace.endLocation(file));
}

test "retained trivia keeps token spans contiguous over original bytes" {
    const allocator = std.testing.allocator;
    var manager = try source.SourceManager.init(allocator);
    defer manager.deinit();
    const id = try manager.add("contiguous.css", "/*x*/\r\n.a\\62 { color: 'é' }");
    const file = try manager.get(id);
    var tokenizer = Tokenizer.init(file);

    var previous_end: usize = 0;
    while (true) {
        const token = tokenizer.next();
        try std.testing.expectEqual(previous_end, token.span.start);
        if (token.kind == .eof) break;
        try std.testing.expect(token.span.end > token.span.start);
        previous_end = token.span.end;
    }
    try std.testing.expectEqual(file.bytes.len, previous_end);
}
