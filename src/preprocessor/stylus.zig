//! Private native parser for Stylus stylesheets.
//!
//! This module produces only an immutable internal syntax document. It does not
//! evaluate Stylus, emit CSS, admit a public syntax, execute project plugins or
//! evaluator hooks, resolve imports, or invoke the reference provider.

const std = @import("std");
const native_diagnostics = @import("diagnostics.zig");
const native_lexer = @import("lexer.zig");
const native_source = @import("source.zig");
const native_syntax = @import("syntax.zig");

const hard_input_bytes = 10 * 1024 * 1024;
const hard_tokens = 1_000_000;
const hard_statements = 200_000;
const hard_diagnostics = 64;
const delimiter_capacity = 1_024;

pub const Limits = struct {
    lexer: native_lexer.Options = .{},
    syntax: native_syntax.Limits = .{},
    diagnostics: native_diagnostics.Limits = .{ .max_diagnostics = hard_diagnostics },
    max_statements: usize = hard_statements,
};

pub const Checkpoint = enum {
    tokenize,
    statement,
};

pub const Cancellation = struct {
    context: ?*anyopaque = null,
    check_fn: ?*const fn (*anyopaque, Checkpoint) bool = null,

    fn check(self: Cancellation, checkpoint: Checkpoint) Error!void {
        const check_fn = self.check_fn orelse return;
        const context = self.context orelse return error.Cancelled;
        if (check_fn(context, checkpoint)) return error.Cancelled;
    }
};

pub const Error = native_lexer.Error ||
    native_syntax.Error ||
    native_diagnostics.Error ||
    native_source.Error || error{
    Cancelled,
    InvalidLimits,
    InvalidSyntax,
    SessionClosed,
    SessionFailed,
    StatementLimitExceeded,
};

const State = enum {
    open,
    completed,
    failed,
};

const Line = struct {
    start: u32,
    end: u32,
    content_start: u32,
    content_end: u32,
    indent: u32,
    token_start: usize,
    token_end: usize,
};

const Built = struct {
    id: native_syntax.NodeId,
    span: native_source.Span,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    source_id: native_source.SourceId,
    source_bytes: []const u8,
    limits: Limits,
    cancellation: Cancellation,
    tokens: []native_lexer.Token,
    statement_count: usize = 0,
    builder: native_syntax.Builder,
    diagnostic_list: native_diagnostics.List,
    parser_state: State = .open,

    pub fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        source_id: native_source.SourceId,
        limits: Limits,
        cancellation: Cancellation,
    ) Error!Parser {
        try validateLimits(limits);
        const file = try sources.get(source_id);
        const tokens = try tokenize(allocator, file.bytes, limits.lexer, cancellation);
        return .{
            .allocator = allocator,
            .sources = sources,
            .source_id = source_id,
            .source_bytes = file.bytes,
            .limits = limits,
            .cancellation = cancellation,
            .tokens = tokens,
            .builder = native_syntax.Builder.init(allocator, sources, limits.syntax),
            .diagnostic_list = native_diagnostics.List.init(
                allocator,
                sources,
                limits.diagnostics,
            ),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.diagnostic_list.deinit();
        self.builder.deinit();
        if (self.tokens.len > 0) self.allocator.free(self.tokens);
        self.* = undefined;
    }

    pub fn diagnostics(self: *const Parser) []const native_diagnostics.Diagnostic {
        return self.diagnostic_list.items();
    }

    pub fn parse(self: *Parser) Error!native_syntax.Document {
        try self.requireOpen();
        self.validateTokenStream() catch |err| {
            self.parser_state = .failed;
            return err;
        };
        const document = self.parseRoot() catch |err| {
            self.parser_state = .failed;
            return err;
        };
        self.parser_state = .completed;
        return document;
    }

    fn requireOpen(self: *const Parser) Error!void {
        return switch (self.parser_state) {
            .open => {},
            .completed => error.SessionClosed,
            .failed => error.SessionFailed,
        };
    }

    fn validateTokenStream(self: *Parser) Error!void {
        if (!std.unicode.utf8ValidateSlice(self.source_bytes)) {
            const offset = firstInvalidUtf8(self.source_bytes);
            return self.rejectSpan(
                try self.sources.span(
                    self.source_id,
                    @intCast(offset),
                    @intCast(@min(offset + 1, self.source_bytes.len)),
                ),
                "source is not valid UTF-8",
            );
        }

        var expected: [delimiter_capacity]native_lexer.Kind = undefined;
        var expected_len: usize = 0;
        for (self.tokens) |token| {
            if (!token.terminated) {
                return self.rejectToken(token, "unterminated Stylus syntax");
            }
            if (token.kind == .invalid) {
                return self.rejectToken(token, "invalid control byte in Stylus source");
            }
            const closing: ?native_lexer.Kind = switch (token.kind) {
                .string_start => .string_end,
                .open_paren => .close_paren,
                .open_square => .close_square,
                .open_curly => .close_curly,
                else => null,
            };
            if (closing) |kind| {
                if (expected_len >= expected.len) {
                    return self.rejectToken(token, "delimiter nesting limit exceeded");
                }
                expected[expected_len] = kind;
                expected_len += 1;
                continue;
            }
            if (isClosing(token.kind)) {
                if (expected_len == 0 or expected[expected_len - 1] != token.kind) {
                    return self.rejectToken(token, "mismatched closing delimiter");
                }
                expected_len -= 1;
                continue;
            }
            if (token.kind == .eof and expected_len != 0) {
                return self.rejectToken(token, "expected a closing delimiter before EOF");
            }
        }
    }

    fn parseRoot(self: *Parser) Error!native_syntax.Document {
        var lines: std.ArrayList(Line) = .empty;
        defer lines.deinit(self.allocator);
        try self.collectLines(&lines);
        try self.validateLines(lines.items);

        var children: std.ArrayList(Built) = .empty;
        defer children.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < lines.items.len) {
            try self.parseLevel(lines.items, &cursor, lines.items[cursor].indent, &children);
        }

        var child_ids: std.ArrayList(native_syntax.NodeId) = .empty;
        defer child_ids.deinit(self.allocator);
        try child_ids.ensureTotalCapacity(self.allocator, children.items.len);
        for (children.items) |child| child_ids.appendAssumeCapacity(child.id);
        const root_span = try self.sources.span(
            self.source_id,
            0,
            @intCast(self.source_bytes.len),
        );
        const root = try self.builder.add(.stylesheet, root_span, null, child_ids.items);
        return self.builder.finish(root);
    }

    fn collectLines(self: *Parser, lines: *std.ArrayList(Line)) Error!void {
        var line_start: usize = 0;
        var token_cursor: usize = 0;
        while (line_start < self.source_bytes.len) {
            var line_end = line_start;
            while (line_end < self.source_bytes.len and
                self.source_bytes[line_end] != '\n' and self.source_bytes[line_end] != '\r')
            {
                line_end += 1;
            }

            var content_start = line_start;
            var indent: u32 = 0;
            while (content_start < line_end and
                isHorizontalWhitespace(self.source_bytes[content_start]))
            {
                switch (self.source_bytes[content_start]) {
                    ' ' => indent += 1,
                    '\t' => {
                        const width: u32 = self.limits.lexer.tab_width;
                        indent += width - (indent % width);
                    },
                    '\x0c' => indent = 0,
                    else => unreachable,
                }
                content_start += 1;
            }
            var content_end = line_end;
            while (content_end > content_start and
                isHorizontalWhitespace(self.source_bytes[content_end - 1]))
            {
                content_end -= 1;
            }

            if (content_start < content_end) {
                while (token_cursor < self.tokens.len and
                    self.tokens[token_cursor].span.end <= content_start)
                {
                    token_cursor += 1;
                }
                const token_start = token_cursor;
                var token_end = token_start;
                while (token_end < self.tokens.len and
                    self.tokens[token_end].span.start < content_end)
                {
                    token_end += 1;
                }
                try lines.append(self.allocator, .{
                    .start = @intCast(line_start),
                    .end = @intCast(line_end),
                    .content_start = @intCast(content_start),
                    .content_end = @intCast(content_end),
                    .indent = indent,
                    .token_start = token_start,
                    .token_end = token_end,
                });
                token_cursor = token_end;
            }

            if (line_end >= self.source_bytes.len) break;
            if (self.source_bytes[line_end] == '\r' and
                line_end + 1 < self.source_bytes.len and self.source_bytes[line_end + 1] == '\n')
            {
                line_start = line_end + 2;
            } else {
                line_start = line_end + 1;
            }
        }
    }

    fn validateLines(self: *Parser, lines: []const Line) Error!void {
        for (lines, 0..) |line, index| {
            const raw = self.lineBytes(line);
            if (startsDirective(raw, "@import") or startsDirective(raw, "@require")) {
                const rest = trimAscii(raw[directiveLength(raw)..]);
                if (rest.len == 0 or std.mem.eql(u8, rest, ";")) {
                    return self.rejectLine(line, "Stylus import target is required");
                }
            }
            if (startsDirective(raw, "@charset")) {
                const rest = trimAscii(raw[directiveLength(raw)..]);
                if (rest.len == 0 or (rest[0] != '\'' and rest[0] != '"')) {
                    return self.rejectLine(line, "Stylus charset must be a string");
                }
            }
            if (raw[0] == ':' and raw.len > 1 and isHorizontalWhitespace(raw[1])) {
                return self.rejectLine(line, "Stylus property name is required");
            }
            if (containsUnclosedTernary(raw)) {
                return self.rejectLine(line, "Stylus ternary expression requires ':'");
            }
            if (line.indent == 0 and wordEql(raw, "break")) {
                return self.rejectLine(line, "Stylus break is not valid at stylesheet scope");
            }
            if (endsWithSignificant(raw, ',') and startsSelectorPunctuation(raw) and
                index + 1 < lines.len and lines[index + 1].indent > line.indent and
                looksLikeDeclaration(self.lineBytes(lines[index + 1]), false))
            {
                return self.rejectLine(line, "Stylus selector list is incomplete");
            }
        }
    }

    fn parseLevel(
        self: *Parser,
        lines: []const Line,
        cursor: *usize,
        indent: u32,
        output: *std.ArrayList(Built),
    ) Error!void {
        while (cursor.* < lines.len and lines[cursor.*].indent == indent) {
            const line = lines[cursor.*];
            try self.consumeStatement(line);
            cursor.* += 1;

            var nested: std.ArrayList(Built) = .empty;
            defer nested.deinit(self.allocator);
            if (cursor.* < lines.len and lines[cursor.*].indent > indent) {
                try self.parseLevel(lines, cursor, lines[cursor.*].indent, &nested);
            }
            const built = try self.buildLine(line, nested.items);
            try output.append(self.allocator, built);
        }
    }

    fn buildLine(self: *Parser, line: Line, nested: []const Built) Error!Built {
        const text_span = try self.sources.span(
            self.source_id,
            line.content_start,
            line.content_end,
        );
        var span = text_span;
        var block: ?Built = null;
        if (nested.len > 0) {
            var nested_ids: std.ArrayList(native_syntax.NodeId) = .empty;
            defer nested_ids.deinit(self.allocator);
            try nested_ids.ensureTotalCapacity(self.allocator, nested.len);
            for (nested) |child| nested_ids.appendAssumeCapacity(child.id);
            const block_span = try self.sources.span(
                self.source_id,
                nested[0].span.start,
                nested[nested.len - 1].span.end,
            );
            block = .{
                .id = try self.builder.add(.block, block_span, null, nested_ids.items),
                .span = block_span,
            };
            span.end = block_span.end;
        }

        var fragments: std.ArrayList(native_syntax.NodeId) = .empty;
        defer fragments.deinit(self.allocator);
        try self.collectFragments(line, &fragments);
        const kind = self.classifyLine(line, nested.len > 0);

        if (kind == .comment) {
            var child_ids: [1]native_syntax.NodeId = undefined;
            const children = if (block) |value| blk: {
                child_ids[0] = value.id;
                break :blk child_ids[0..1];
            } else child_ids[0..0];
            const id = try self.builder.add(.comment, span, text_span, children);
            return .{ .id = id, .span = span };
        }

        var semantic_children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer semantic_children.deinit(self.allocator);
        switch (kind) {
            .rule => {
                const selector = try self.builder.add(.selector, text_span, text_span, fragments.items);
                try semantic_children.append(self.allocator, selector);
            },
            .variable,
            .declaration,
            .function,
            .return_statement,
            .conditional,
            .loop,
            .at_rule,
            .import,
            .expression,
            .mixin,
            => {
                const expression = try self.builder.add(
                    .expression,
                    text_span,
                    text_span,
                    fragments.items,
                );
                try semantic_children.append(self.allocator, expression);
            },
            else => {},
        }
        if (block) |value| try semantic_children.append(self.allocator, value.id);
        const id = try self.builder.add(kind, span, text_span, semantic_children.items);
        return .{ .id = id, .span = span };
    }

    fn classifyLine(self: *const Parser, line: Line, has_children: bool) native_syntax.Kind {
        const raw = self.lineBytes(line);
        if (isComment(raw)) return .comment;
        if (startsDirective(raw, "@import") or startsDirective(raw, "@require")) return .import;
        if (raw[0] == '@') return .at_rule;
        if (startsWord(raw, "return")) return .return_statement;
        if (startsWord(raw, "if") or startsWord(raw, "unless") or
            startsWord(raw, "else") or startsWord(raw, "unless"))
        {
            return .conditional;
        }
        if (startsWord(raw, "for") or startsWord(raw, "while") or startsWord(raw, "each")) {
            return .loop;
        }
        if (self.findAssignment(line) != null) return .variable;
        if (has_children and looksLikeFunctionDefinition(self.tokens[line.token_start..line.token_end])) {
            return .function;
        }
        if (looksLikeDeclaration(raw, has_children)) return .declaration;
        if (has_children or looksLikeSelector(raw)) return .rule;
        return .expression;
    }

    fn findAssignment(self: *const Parser, line: Line) ?usize {
        var paren_depth: usize = 0;
        var square_depth: usize = 0;
        var curly_depth: usize = 0;
        for (self.tokens[line.token_start..line.token_end], line.token_start..) |token, index| {
            switch (token.kind) {
                .open_paren => paren_depth += 1,
                .close_paren => paren_depth -|= 1,
                .open_square => square_depth += 1,
                .close_square => square_depth -|= 1,
                .open_curly => curly_depth += 1,
                .close_curly => curly_depth -|= 1,
                .operator => if (paren_depth == 0 and square_depth == 0 and curly_depth == 0 and
                    isAssignmentOperator(token.raw(self.source_bytes)))
                {
                    return index;
                },
                else => {},
            }
        }
        return null;
    }

    fn collectFragments(
        self: *Parser,
        line: Line,
        output: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        var index = line.token_start;
        while (index < line.token_end) {
            const token = self.tokens[index];
            switch (token.kind) {
                .comment => {
                    const span = try self.tokenSpan(token);
                    try output.append(
                        self.allocator,
                        try self.builder.add(.comment, span, span, &.{}),
                    );
                    index += 1;
                },
                .string_start => {
                    const closing = findMatching(
                        self.tokens,
                        index,
                        line.token_end,
                        .string_start,
                        .string_end,
                    ) orelse return self.rejectToken(token, "unterminated Stylus string");
                    const span = try self.sources.span(
                        self.source_id,
                        token.span.start,
                        self.tokens[closing].span.end,
                    );
                    try output.append(
                        self.allocator,
                        try self.builder.add(.string, span, span, &.{}),
                    );
                    index = closing + 1;
                },
                .identifier, .at_identifier => {
                    var opening = index + 1;
                    while (opening < line.token_end and
                        isHorizontalToken(self.tokens[opening].kind))
                    {
                        opening += 1;
                    }
                    if (opening < line.token_end and self.tokens[opening].kind == .open_paren) {
                        if (findMatching(
                            self.tokens,
                            opening,
                            line.token_end,
                            .open_paren,
                            .close_paren,
                        )) |closing| {
                            const span = try self.sources.span(
                                self.source_id,
                                token.span.start,
                                self.tokens[closing].span.end,
                            );
                            try output.append(
                                self.allocator,
                                try self.builder.add(.call, span, span, &.{}),
                            );
                        }
                    }
                    index += 1;
                },
                .open_curly => {
                    if (findMatching(
                        self.tokens,
                        index,
                        line.token_end,
                        .open_curly,
                        .close_curly,
                    )) |closing| {
                        const span = try self.sources.span(
                            self.source_id,
                            token.span.start,
                            self.tokens[closing].span.end,
                        );
                        try output.append(
                            self.allocator,
                            try self.builder.add(.interpolation, span, span, &.{}),
                        );
                        index = closing + 1;
                    } else {
                        index += 1;
                    }
                },
                else => index += 1,
            }
        }
    }

    fn consumeStatement(self: *Parser, line: Line) Error!void {
        try self.cancellation.check(.statement);
        var units: usize = 1;
        for (self.tokens[line.token_start..line.token_end], line.token_start..) |token, index| {
            if (token.kind != .semicolon) continue;
            var next = index + 1;
            while (next < line.token_end and isHorizontalToken(self.tokens[next].kind)) : (next += 1) {}
            if (next < line.token_end) units += 1;
        }
        if (units > self.limits.max_statements -| self.statement_count) {
            return error.StatementLimitExceeded;
        }
        self.statement_count += units;
    }

    fn lineBytes(self: *const Parser, line: Line) []const u8 {
        return self.source_bytes[line.content_start..line.content_end];
    }

    fn tokenSpan(self: *const Parser, token: native_lexer.Token) Error!native_source.Span {
        return self.sources.span(self.source_id, token.span.start, token.span.end);
    }

    fn rejectLine(self: *Parser, line: Line, message: []const u8) Error {
        return self.rejectSpan(
            self.sources.span(self.source_id, line.content_start, line.content_end) catch |err|
                return err,
            message,
        );
    }

    fn rejectToken(self: *Parser, token: native_lexer.Token, message: []const u8) Error {
        const span = self.tokenSpan(token) catch |err| return err;
        return self.rejectSpan(span, message);
    }

    fn rejectSpan(self: *Parser, span: native_source.Span, message: []const u8) Error {
        self.diagnostic_list.append(.err, .syntax, span, message, &.{}) catch |err| return err;
        return error.InvalidSyntax;
    }
};

fn tokenize(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: native_lexer.Options,
    cancellation: Cancellation,
) Error![]native_lexer.Token {
    var stream = try native_lexer.Lexer.init(bytes, .stylus, options);
    var tokens: std.ArrayList(native_lexer.Token) = .empty;
    errdefer tokens.deinit(allocator);
    var count: usize = 0;
    while (true) {
        if (count % 1_024 == 0) try cancellation.check(.tokenize);
        const token = try stream.next();
        try tokens.append(allocator, token);
        count += 1;
        if (token.kind == .eof) break;
    }
    return tokens.toOwnedSlice(allocator);
}

fn validateLimits(limits: Limits) Error!void {
    const lexer_limits = limits.lexer;
    const syntax_limits = limits.syntax;
    const diagnostic_limits = limits.diagnostics;
    if (lexer_limits.max_input_bytes == 0 or lexer_limits.max_input_bytes > hard_input_bytes or
        lexer_limits.max_tokens == 0 or lexer_limits.max_tokens > hard_tokens or
        lexer_limits.max_indentation_depth > 64 or
        lexer_limits.max_interpolation_depth > 64 or
        lexer_limits.max_nesting_depth == 0 or lexer_limits.max_nesting_depth > 256 or
        lexer_limits.tab_width == 0 or lexer_limits.tab_width > 16 or
        syntax_limits.max_nodes == 0 or syntax_limits.max_nodes > 1_000_000 or
        syntax_limits.max_edges == 0 or syntax_limits.max_edges > 4_000_000 or
        syntax_limits.max_depth == 0 or syntax_limits.max_depth > 512 or
        diagnostic_limits.max_diagnostics == 0 or
        diagnostic_limits.max_diagnostics > hard_diagnostics or
        diagnostic_limits.max_related_per_diagnostic == 0 or
        diagnostic_limits.max_related_per_diagnostic > 32 or
        diagnostic_limits.max_message_bytes == 0 or
        diagnostic_limits.max_message_bytes > 16 * 1024 or
        diagnostic_limits.max_owned_bytes == 0 or
        diagnostic_limits.max_owned_bytes > 4 * 1024 * 1024 or
        limits.max_statements == 0 or limits.max_statements > hard_statements)
    {
        return error.InvalidLimits;
    }
}

fn isClosing(kind: native_lexer.Kind) bool {
    return switch (kind) {
        .string_end, .close_paren, .close_square, .close_curly => true,
        else => false,
    };
}

fn findMatching(
    tokens: []const native_lexer.Token,
    opening_index: usize,
    end: usize,
    opening: native_lexer.Kind,
    closing: native_lexer.Kind,
) ?usize {
    var depth: usize = 0;
    var index = opening_index;
    while (index < end) : (index += 1) {
        if (tokens[index].kind == opening) depth += 1;
        if (tokens[index].kind == closing) {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn isHorizontalWhitespace(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\x0c';
}

fn isHorizontalToken(kind: native_lexer.Kind) bool {
    return kind == .whitespace or kind == .comment;
}

fn trimAscii(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n\x0c");
}

fn isComment(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, "//") or
        std.mem.startsWith(u8, raw, "/*") or raw[0] == '*';
}

fn startsDirective(raw: []const u8, expected: []const u8) bool {
    if (raw.len < expected.len or !std.ascii.eqlIgnoreCase(raw[0..expected.len], expected)) {
        return false;
    }
    return raw.len == expected.len or
        isHorizontalWhitespace(raw[expected.len]) or raw[expected.len] == ';';
}

fn directiveLength(raw: []const u8) usize {
    var end: usize = 0;
    while (end < raw.len and !isHorizontalWhitespace(raw[end]) and raw[end] != ';') : (end += 1) {}
    return end;
}

fn startsWord(raw: []const u8, expected: []const u8) bool {
    if (raw.len < expected.len or !std.ascii.eqlIgnoreCase(raw[0..expected.len], expected)) {
        return false;
    }
    return raw.len == expected.len or isHorizontalWhitespace(raw[expected.len]) or
        raw[expected.len] == '(' or raw[expected.len] == ';';
}

fn wordEql(raw: []const u8, expected: []const u8) bool {
    var end = raw.len;
    while (end > 0 and (isHorizontalWhitespace(raw[end - 1]) or raw[end - 1] == ';')) end -= 1;
    return std.ascii.eqlIgnoreCase(raw[0..end], expected);
}

fn containsUnclosedTernary(raw: []const u8) bool {
    const question = std.mem.indexOf(u8, raw, " ? ") orelse return false;
    return std.mem.indexOfPos(u8, raw, question + 3, " : ") == null;
}

fn endsWithSignificant(raw: []const u8, byte: u8) bool {
    var end = raw.len;
    while (end > 0 and (isHorizontalWhitespace(raw[end - 1]) or raw[end - 1] == ';')) end -= 1;
    return end > 0 and raw[end - 1] == byte;
}

fn startsSelectorPunctuation(raw: []const u8) bool {
    return switch (raw[0]) {
        '.', '#', '&', '[', '/', '>', '+', '~' => true,
        else => false,
    };
}

fn looksLikeDeclaration(raw: []const u8, has_children: bool) bool {
    if (raw.len == 0 or isComment(raw) or raw[0] == '@' or
        startsSelectorPunctuation(raw) or startsWord(raw, "return") or
        startsWord(raw, "if") or startsWord(raw, "unless") or
        startsWord(raw, "for") or startsWord(raw, "while"))
    {
        return false;
    }

    var colon = std.mem.indexOfScalar(u8, raw, ':');
    while (colon) |index| {
        if (index > 0 and index + 1 < raw.len and isHorizontalWhitespace(raw[index + 1]) and
            !isHorizontalWhitespace(raw[index - 1]))
        {
            return true;
        }
        colon = std.mem.indexOfScalarPos(u8, raw, index + 1, ':');
    }
    if (has_children) return false;
    const whitespace = std.mem.indexOfAny(u8, raw, " \t") orelse return false;
    return whitespace > 0 and raw[whitespace - 1] != ',';
}

fn looksLikeSelector(raw: []const u8) bool {
    if (startsSelectorPunctuation(raw) or endsWithSignificant(raw, ',')) return true;
    return std.mem.indexOfAny(u8, raw, "[]&>~") != null;
}

fn looksLikeFunctionDefinition(tokens: []const native_lexer.Token) bool {
    var first: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.kind == .whitespace or token.kind == .comment) continue;
        first = index;
        break;
    }
    const name = first orelse return false;
    if (tokens[name].kind != .identifier) return false;
    var opening = name + 1;
    while (opening < tokens.len and tokens[opening].kind == .whitespace) : (opening += 1) {}
    return opening < tokens.len and tokens[opening].kind == .open_paren;
}

fn isAssignmentOperator(raw: []const u8) bool {
    const operators = [_][]const u8{ "=", "?=", ":=", "+=", "-=", "*=", "/=", "%=" };
    for (operators) |operator| {
        if (std.mem.eql(u8, raw, operator)) return true;
    }
    return false;
}

fn firstInvalidUtf8(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return index;
        if (index + length > bytes.len) return index;
        _ = std.unicode.utf8Decode(bytes[index .. index + length]) catch return index;
        index += length;
    }
    return bytes.len;
}
