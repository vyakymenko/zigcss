const std = @import("std");

pub const Syntax = enum {
    css,
    scss,
    sass,
    less,
    stylus,
};

pub const Kind = enum {
    whitespace,
    newline,
    indent,
    dedent,
    identifier,
    variable,
    at_identifier,
    hash_identifier,
    number,
    string_start,
    string_content,
    string_end,
    comment,
    interpolation_start,
    interpolation_end,
    open_paren,
    close_paren,
    open_square,
    close_square,
    open_curly,
    close_curly,
    colon,
    semicolon,
    comma,
    operator,
    delimiter,
    invalid,
    eof,
};

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Token = struct {
    kind: Kind,
    span: Span,
    terminated: bool = true,

    pub fn raw(self: Token, source: []const u8) []const u8 {
        return source[self.span.start..self.span.end];
    }

    pub fn isVirtual(self: Token) bool {
        return self.kind == .indent or self.kind == .dedent or self.kind == .eof or
            ((self.kind == .string_end or self.kind == .interpolation_end) and
                self.span.start == self.span.end);
    }
};

pub const Options = struct {
    max_input_bytes: usize = 10 * 1024 * 1024,
    max_tokens: usize = 1_000_000,
    max_indentation_depth: u8 = 64,
    max_interpolation_depth: u8 = 64,
    max_nesting_depth: u16 = 256,
    tab_width: u8 = 4,
};

pub const Error = std.mem.Allocator.Error || error{
    InputTooLarge,
    InvalidOptions,
    TokenLimitExceeded,
    IndentationDepthExceeded,
    InconsistentIndentation,
    InterpolationDepthExceeded,
    NestingDepthExceeded,
};

const max_indentation_capacity = 64;
const max_interpolation_capacity = 64;

const State = enum {
    normal,
    string,
};

const InterpolationContext = struct {
    curly_depth: u16 = 0,
    resume_quote: ?u8 = null,
};

pub const Lexer = struct {
    source: []const u8,
    syntax: Syntax,
    options: Options,
    cursor: usize = 0,
    emitted_tokens: usize = 0,
    eof_emitted: bool = false,
    state: State = .normal,
    quote: u8 = 0,
    unterminated_string_pending: bool = false,
    needs_line_preparation: bool = false,
    indentation: [max_indentation_capacity + 1]u32 = [_]u32{0} ** (max_indentation_capacity + 1),
    indentation_len: usize = 1,
    pending_indent: bool = false,
    pending_dedents: u8 = 0,
    pending_structure_offset: usize = 0,
    nesting_depth: u16 = 0,
    interpolations: [max_interpolation_capacity]InterpolationContext =
        [_]InterpolationContext{.{}} ** max_interpolation_capacity,
    interpolation_len: usize = 0,

    pub fn init(source: []const u8, syntax: Syntax, options: Options) Error!Lexer {
        if (source.len > options.max_input_bytes or source.len > std.math.maxInt(u32)) {
            return error.InputTooLarge;
        }
        if (options.max_tokens == 0 or options.tab_width == 0 or
            options.max_indentation_depth > max_indentation_capacity or
            options.max_interpolation_depth > max_interpolation_capacity)
        {
            return error.InvalidOptions;
        }
        return .{
            .source = source,
            .syntax = syntax,
            .options = options,
            .needs_line_preparation = indentationSensitive(syntax),
        };
    }

    pub fn next(self: *Lexer) Error!Token {
        if (self.eof_emitted) return self.makeToken(.eof, self.source.len, self.source.len, true);
        if (self.emitted_tokens >= self.options.max_tokens) return error.TokenLimitExceeded;

        const token = try self.nextInternal();
        self.emitted_tokens += 1;
        if (token.kind == .eof) self.eof_emitted = true;
        return token;
    }

    fn nextInternal(self: *Lexer) Error!Token {
        if (self.unterminated_string_pending) {
            self.unterminated_string_pending = false;
            self.state = .normal;
            return self.makeToken(.string_end, self.cursor, self.cursor, false);
        }
        if (self.state == .string) return self.nextString();

        if (self.takePendingStructure()) |token| return token;
        if (self.needs_line_preparation) {
            if (try self.prepareLine()) |token| return token;
        }

        if (self.cursor >= self.source.len) {
            if (self.interpolation_len > 0) return self.closeUnterminatedInterpolation();
            if (indentationSensitive(self.syntax) and self.indentation_len > 1) {
                self.pending_structure_offset = self.source.len;
                self.pending_dedents = @intCast(self.indentation_len - 1);
                self.indentation_len = 1;
                return self.takePendingStructure().?;
            }
            return self.makeToken(.eof, self.source.len, self.source.len, true);
        }

        const start = self.cursor;
        if (self.startsInterpolation()) return self.startInterpolation(null);
        if (self.startsWith("/*")) return self.consumeBlockComment();
        if (supportsLineComments(self.syntax) and self.startsWith("//")) {
            return self.consumeLineComment();
        }

        const current = self.source[self.cursor];
        if (isNewlineByte(current)) return self.consumeNewline();
        if (isHorizontalWhitespace(current)) return self.consumeWhitespace();
        if (current == '\'' or current == '"') {
            self.cursor += 1;
            self.state = .string;
            self.quote = current;
            return self.makeToken(.string_start, start, self.cursor, true);
        }

        if (self.operatorLength()) |length| return self.consumeSimple(.operator, length);
        if (self.wouldStartNumber()) return self.consumeNumber();

        switch (current) {
            '$' => {
                if (self.identifierStartsAt(self.cursor + 1)) {
                    self.cursor += 1;
                    self.consumeIdentifierBytes();
                    return self.makeToken(.variable, start, self.cursor, true);
                }
            },
            '@' => {
                if (self.identifierStartsAt(self.cursor + 1)) {
                    self.cursor += 1;
                    self.consumeIdentifierBytes();
                    return self.makeToken(.at_identifier, start, self.cursor, true);
                }
            },
            '#' => {
                if (self.identifierStartsAt(self.cursor + 1)) {
                    self.cursor += 1;
                    self.consumeIdentifierBytes();
                    return self.makeToken(.hash_identifier, start, self.cursor, true);
                }
            },
            else => {},
        }

        if (self.identifierStartsAt(self.cursor)) {
            self.consumeIdentifierBytes();
            return self.makeToken(.identifier, start, self.cursor, true);
        }

        return switch (current) {
            '(' => self.consumeOpening(.open_paren),
            ')' => self.consumeClosing(.close_paren),
            '[' => self.consumeOpening(.open_square),
            ']' => self.consumeClosing(.close_square),
            '{' => self.consumeOpeningCurly(),
            '}' => self.consumeClosingCurly(),
            ':' => self.consumeSimple(.colon, 1),
            ';' => self.consumeSimple(.semicolon, 1),
            ',' => self.consumeSimple(.comma, 1),
            '+', '-', '*', '/', '%', '=', '!', '<', '>', '&', '|', '^', '~', '?' => self.consumeSimple(.operator, 1),
            0...8, 11, 14...31, 127 => self.consumeSimple(.invalid, 1),
            else => self.consumeSimple(.delimiter, 1),
        };
    }

    fn prepareLine(self: *Lexer) Error!?Token {
        self.needs_line_preparation = false;
        const start = self.cursor;
        var end = start;
        var column: u32 = 0;
        while (end < self.source.len and isHorizontalWhitespace(self.source[end])) : (end += 1) {
            switch (self.source[end]) {
                ' ' => column += 1,
                '\t' => {
                    const tab_width: u32 = self.options.tab_width;
                    column += tab_width - (column % tab_width);
                },
                '\x0c' => column = 0,
                else => unreachable,
            }
        }

        const blank = end >= self.source.len or isNewlineByte(self.source[end]);
        if (!blank) try self.queueIndentation(column, end);

        if (end > start) {
            self.cursor = end;
            return self.makeToken(.whitespace, start, end, true);
        }
        return self.takePendingStructure();
    }

    fn queueIndentation(self: *Lexer, column: u32, offset: usize) Error!void {
        const current = self.indentation[self.indentation_len - 1];
        self.pending_structure_offset = offset;
        if (column > current) {
            if (self.indentation_len - 1 >= self.options.max_indentation_depth) {
                return error.IndentationDepthExceeded;
            }
            self.indentation[self.indentation_len] = column;
            self.indentation_len += 1;
            self.pending_indent = true;
            return;
        }
        if (column == current) return;

        var target_len = self.indentation_len;
        while (target_len > 1 and self.indentation[target_len - 1] > column) {
            target_len -= 1;
        }
        if (self.indentation[target_len - 1] != column) return error.InconsistentIndentation;
        self.pending_dedents = @intCast(self.indentation_len - target_len);
        self.indentation_len = target_len;
    }

    fn takePendingStructure(self: *Lexer) ?Token {
        if (self.pending_dedents > 0) {
            self.pending_dedents -= 1;
            return self.makeToken(
                .dedent,
                self.pending_structure_offset,
                self.pending_structure_offset,
                true,
            );
        }
        if (self.pending_indent) {
            self.pending_indent = false;
            return self.makeToken(
                .indent,
                self.pending_structure_offset,
                self.pending_structure_offset,
                true,
            );
        }
        return null;
    }

    fn nextString(self: *Lexer) Error!Token {
        const start = self.cursor;
        while (self.cursor < self.source.len) {
            const current = self.source[self.cursor];
            if (current == self.quote) {
                if (self.cursor > start) return self.makeToken(.string_content, start, self.cursor, true);
                self.cursor += 1;
                self.state = .normal;
                return self.makeToken(.string_end, start, self.cursor, true);
            }
            if (isNewlineByte(current)) {
                if (self.cursor > start) {
                    self.unterminated_string_pending = true;
                    return self.makeToken(.string_content, start, self.cursor, true);
                }
                self.state = .normal;
                return self.makeToken(.string_end, start, start, false);
            }
            if (self.startsInterpolation()) {
                if (self.cursor > start) return self.makeToken(.string_content, start, self.cursor, true);
                return self.startInterpolation(self.quote);
            }
            if (current == '\\') {
                self.cursor += 1;
                if (self.cursor >= self.source.len) break;
                if (self.source[self.cursor] == '\r' and
                    self.cursor + 1 < self.source.len and self.source[self.cursor + 1] == '\n')
                {
                    self.cursor += 2;
                } else {
                    self.cursor += 1;
                }
                continue;
            }
            self.cursor += 1;
        }

        if (self.cursor > start) {
            self.unterminated_string_pending = true;
            return self.makeToken(.string_content, start, self.cursor, true);
        }
        self.state = .normal;
        return self.makeToken(.string_end, start, start, false);
    }

    fn startInterpolation(self: *Lexer, resume_quote: ?u8) Error!Token {
        if (self.interpolation_len >= self.options.max_interpolation_depth) {
            return error.InterpolationDepthExceeded;
        }
        try self.increaseNesting();
        const start = self.cursor;
        self.interpolations[self.interpolation_len] = .{ .resume_quote = resume_quote };
        self.interpolation_len += 1;
        self.cursor += 2;
        self.state = .normal;
        return self.makeToken(.interpolation_start, start, self.cursor, true);
    }

    fn closeUnterminatedInterpolation(self: *Lexer) Token {
        self.interpolation_len -= 1;
        const context = self.interpolations[self.interpolation_len];
        self.decreaseNesting();
        if (context.resume_quote) |quote| {
            self.quote = quote;
            self.state = .string;
        } else {
            self.state = .normal;
        }
        return self.makeToken(.interpolation_end, self.cursor, self.cursor, false);
    }

    fn consumeBlockComment(self: *Lexer) Token {
        const start = self.cursor;
        self.cursor += 2;
        while (self.cursor + 1 < self.source.len) {
            if (self.source[self.cursor] == '*' and self.source[self.cursor + 1] == '/') {
                self.cursor += 2;
                return self.makeToken(.comment, start, self.cursor, true);
            }
            self.cursor += 1;
        }
        self.cursor = self.source.len;
        return self.makeToken(.comment, start, self.cursor, false);
    }

    fn consumeLineComment(self: *Lexer) Token {
        const start = self.cursor;
        self.cursor += 2;
        while (self.cursor < self.source.len and !isNewlineByte(self.source[self.cursor])) {
            self.cursor += 1;
        }
        return self.makeToken(.comment, start, self.cursor, true);
    }

    fn consumeNewline(self: *Lexer) Token {
        const start = self.cursor;
        if (self.source[self.cursor] == '\r' and
            self.cursor + 1 < self.source.len and self.source[self.cursor + 1] == '\n')
        {
            self.cursor += 2;
        } else {
            self.cursor += 1;
        }
        if (indentationSensitive(self.syntax)) self.needs_line_preparation = true;
        return self.makeToken(.newline, start, self.cursor, true);
    }

    fn consumeWhitespace(self: *Lexer) Token {
        const start = self.cursor;
        while (self.cursor < self.source.len and isHorizontalWhitespace(self.source[self.cursor])) {
            self.cursor += 1;
        }
        return self.makeToken(.whitespace, start, self.cursor, true);
    }

    fn consumeNumber(self: *Lexer) Token {
        const start = self.cursor;
        if (self.source[self.cursor] == '.') self.cursor += 1;
        while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) {
            self.cursor += 1;
        }
        if (self.cursor + 1 < self.source.len and self.source[self.cursor] == '.' and
            std.ascii.isDigit(self.source[self.cursor + 1]))
        {
            self.cursor += 1;
            while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) {
                self.cursor += 1;
            }
        }

        if (self.cursor < self.source.len and
            (self.source[self.cursor] == 'e' or self.source[self.cursor] == 'E'))
        {
            var exponent_end = self.cursor + 1;
            if (exponent_end < self.source.len and
                (self.source[exponent_end] == '+' or self.source[exponent_end] == '-'))
            {
                exponent_end += 1;
            }
            if (exponent_end < self.source.len and std.ascii.isDigit(self.source[exponent_end])) {
                self.cursor = exponent_end + 1;
                while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) {
                    self.cursor += 1;
                }
            }
        }
        return self.makeToken(.number, start, self.cursor, true);
    }

    fn consumeOpening(self: *Lexer, kind: Kind) Error!Token {
        try self.increaseNesting();
        return self.consumeSimple(kind, 1);
    }

    fn consumeClosing(self: *Lexer, kind: Kind) Token {
        self.decreaseNesting();
        return self.consumeSimple(kind, 1);
    }

    fn consumeOpeningCurly(self: *Lexer) Error!Token {
        try self.increaseNesting();
        if (self.interpolation_len > 0) {
            self.interpolations[self.interpolation_len - 1].curly_depth += 1;
        }
        return self.consumeSimple(.open_curly, 1);
    }

    fn consumeClosingCurly(self: *Lexer) Token {
        if (self.interpolation_len > 0) {
            const context = &self.interpolations[self.interpolation_len - 1];
            if (context.curly_depth == 0) {
                const start = self.cursor;
                self.cursor += 1;
                self.interpolation_len -= 1;
                const resume_quote = context.resume_quote;
                self.decreaseNesting();
                if (resume_quote) |quote| {
                    self.quote = quote;
                    self.state = .string;
                }
                return self.makeToken(.interpolation_end, start, self.cursor, true);
            }
            context.curly_depth -= 1;
        }
        self.decreaseNesting();
        return self.consumeSimple(.close_curly, 1);
    }

    fn consumeSimple(self: *Lexer, kind: Kind, length: usize) Token {
        const start = self.cursor;
        self.cursor += length;
        return self.makeToken(kind, start, self.cursor, true);
    }

    fn increaseNesting(self: *Lexer) Error!void {
        if (self.nesting_depth >= self.options.max_nesting_depth) {
            return error.NestingDepthExceeded;
        }
        self.nesting_depth += 1;
    }

    fn decreaseNesting(self: *Lexer) void {
        if (self.nesting_depth > 0) self.nesting_depth -= 1;
    }

    fn startsInterpolation(self: *const Lexer) bool {
        const prefix: []const u8 = switch (self.syntax) {
            .scss, .sass => "#{",
            .less => "@{",
            .css, .stylus => return false,
        };
        return self.startsWith(prefix);
    }

    fn operatorLength(self: *const Lexer) ?usize {
        const operators = [_][]const u8{
            "...", "==", "!=", "<=", ">=", "&&", "||", "..", "+=", "-=", "*=", "/=", "%=", "=>", ":=", "~=", "|=", "^=", "$=", "?=", "**",
        };
        for (operators) |operator| {
            if (self.startsWith(operator)) return operator.len;
        }
        return null;
    }

    fn wouldStartNumber(self: *const Lexer) bool {
        if (std.ascii.isDigit(self.source[self.cursor])) return true;
        return self.source[self.cursor] == '.' and
            self.cursor + 1 < self.source.len and
            std.ascii.isDigit(self.source[self.cursor + 1]);
    }

    fn identifierStartsAt(self: *const Lexer, index: usize) bool {
        if (index >= self.source.len) return false;
        const current = self.source[index];
        if (isNameStart(current)) return true;
        if (current == '\\') return self.validEscapeAt(index);
        if (current != '-') return false;
        if (index + 1 >= self.source.len) return false;
        const next_byte = self.source[index + 1];
        return next_byte == '-' or isNameStart(next_byte) or
            (next_byte == '\\' and self.validEscapeAt(index + 1));
    }

    fn consumeIdentifierBytes(self: *Lexer) void {
        while (self.cursor < self.source.len) {
            const current = self.source[self.cursor];
            if (isNameContinue(current)) {
                self.cursor += 1;
                continue;
            }
            if (current == '\\' and self.validEscapeAt(self.cursor)) {
                self.consumeEscape();
                continue;
            }
            break;
        }
    }

    fn validEscapeAt(self: *const Lexer, index: usize) bool {
        if (index + 1 >= self.source.len) return false;
        return !isNewlineByte(self.source[index + 1]);
    }

    fn consumeEscape(self: *Lexer) void {
        self.cursor += 1;
        if (self.cursor >= self.source.len) return;
        if (!std.ascii.isHex(self.source[self.cursor])) {
            self.cursor += 1;
            return;
        }
        var digits: u8 = 0;
        while (self.cursor < self.source.len and digits < 6 and
            std.ascii.isHex(self.source[self.cursor]))
        {
            self.cursor += 1;
            digits += 1;
        }
        if (self.cursor < self.source.len and isHorizontalWhitespace(self.source[self.cursor])) {
            self.cursor += 1;
        }
    }

    fn startsWith(self: *const Lexer, value: []const u8) bool {
        return self.cursor <= self.source.len and
            value.len <= self.source.len - self.cursor and
            std.mem.eql(u8, self.source[self.cursor .. self.cursor + value.len], value);
    }

    fn makeToken(
        self: *const Lexer,
        kind: Kind,
        start: usize,
        end: usize,
        terminated: bool,
    ) Token {
        _ = self;
        return .{
            .kind = kind,
            .span = .{ .start = @intCast(start), .end = @intCast(end) },
            .terminated = terminated,
        };
    }
};

fn indentationSensitive(syntax: Syntax) bool {
    return syntax == .sass or syntax == .stylus;
}

fn supportsLineComments(syntax: Syntax) bool {
    return syntax != .css;
}

fn isHorizontalWhitespace(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\x0c';
}

fn isNewlineByte(value: u8) bool {
    return value == '\n' or value == '\r';
}

fn isNameStart(value: u8) bool {
    return std.ascii.isAlphabetic(value) or value == '_' or value >= 0x80;
}

fn isNameContinue(value: u8) bool {
    return isNameStart(value) or std.ascii.isDigit(value) or value == '-';
}

pub fn tokenizeAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    syntax: Syntax,
    options: Options,
) Error![]Token {
    var tokenizer = try Lexer.init(source, syntax, options);
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = try tokenizer.next();
        try tokens.append(allocator, token);
        if (token.kind == .eof) break;
    }
    return try tokens.toOwnedSlice(allocator);
}
