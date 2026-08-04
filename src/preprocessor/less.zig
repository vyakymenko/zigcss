//! Private native parser for Less stylesheets.
//!
//! This module produces only an immutable internal syntax document. It does not
//! evaluate Less, emit CSS, admit a public syntax, execute JavaScript/plugins,
//! or invoke the reference provider.

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

const Range = struct {
    start: usize,
    end: usize,

    fn empty(self: Range) bool {
        return self.start >= self.end;
    }
};

const BoundaryKind = enum {
    semicolon,
    open_curly,
    close_curly,
    eof,
};

const Boundary = struct {
    kind: BoundaryKind,
    index: usize,
    colon: ?usize,
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
    cursor: usize = 0,
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
                return self.rejectToken(token, "unterminated Less syntax");
            }
            if (token.kind == .invalid) {
                return self.rejectToken(token, "invalid control byte in Less source");
            }
            const closing: ?native_lexer.Kind = switch (token.kind) {
                .string_start => .string_end,
                .interpolation_start => .interpolation_end,
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
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try self.parseStatements(false, &children);
        if (self.current().kind != .eof) {
            return self.rejectToken(self.current(), "unexpected token after Less stylesheet");
        }
        const root_span = try self.sources.span(
            self.source_id,
            0,
            @intCast(self.source_bytes.len),
        );
        const root = try self.builder.add(.stylesheet, root_span, null, children.items);
        return self.builder.finish(root);
    }

    fn parseStatements(
        self: *Parser,
        in_block: bool,
        children: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        while (true) {
            self.skipWhitespace();
            const token = self.current();
            switch (token.kind) {
                .eof => {
                    if (in_block) return self.rejectToken(token, "expected '}' before EOF");
                    return;
                },
                .close_curly => {
                    if (!in_block) return self.rejectToken(token, "unexpected '}'");
                    return;
                },
                .semicolon => {
                    self.cursor += 1;
                    continue;
                },
                .comment => {
                    try self.consumeStatement();
                    const span = try self.tokenSpan(token);
                    const node = try self.builder.add(.comment, span, span, &.{});
                    try children.append(self.allocator, node);
                    self.cursor += 1;
                },
                else => {
                    try self.consumeStatement();
                    const built = try self.parseStatement(in_block);
                    try children.append(self.allocator, built.id);
                },
            }
        }
    }

    fn parseStatement(self: *Parser, in_block: bool) Error!Built {
        const start = self.cursor;
        const boundary = self.scanBoundary(start);
        if (boundary.index == start) {
            return self.rejectToken(self.tokens[start], "empty Less statement");
        }

        if (self.tokens[start].kind == .at_identifier) {
            const raw = self.tokens[start].raw(self.source_bytes);
            if (isDirective(raw)) return self.parseAtRule(start, boundary);
            if (boundary.colon) |colon| {
                return self.parseVariable(start, colon, boundary);
            }
            if (boundary.kind == .open_curly) return self.parseAtRule(start, boundary);
            if (looksLikeCall(self.tokens, self.source_bytes, .{ .start = start, .end = boundary.index })) {
                return self.buildMixinCall(start, boundary);
            }
            return self.parseAtRule(start, boundary);
        }

        if (boundary.kind == .open_curly) {
            if (in_block) {
                if (boundary.colon) |colon| {
                    const after_colon = trim(
                        self.tokens,
                        .{ .start = colon + 1, .end = boundary.index },
                    );
                    if (after_colon.empty()) {
                        return self.rejectToken(
                            self.tokens[colon],
                            "Less declaration cannot own a detached block",
                        );
                    }
                }
            }
            return self.parseRuleOrMixin(start, boundary);
        }

        const header = trim(self.tokens, .{ .start = start, .end = boundary.index });
        if (isExtend(self.tokens, self.source_bytes, header)) {
            return self.buildTerminal(.extend, start, boundary);
        }
        if (in_block) {
            if (boundary.colon) |colon| {
                return self.buildDeclaration(start, colon, boundary.index);
            }
        }
        if (looksLikeCall(self.tokens, self.source_bytes, header) or
            containsKind(self.tokens, header, .open_paren) or
            looksLikeMixinReference(self.tokens, self.source_bytes, header))
        {
            return self.buildMixinCall(start, boundary);
        }
        if (!in_block) {
            return self.rejectToken(self.tokens[start], "top-level Less statement requires a block");
        }
        return self.rejectToken(self.tokens[start], "declaration is missing ':'");
    }

    fn parseVariable(
        self: *Parser,
        start: usize,
        colon: usize,
        boundary: Boundary,
    ) Error!Built {
        if (colon != start + 1 and !onlyIgnorable(self.tokens[start + 1 .. colon])) {
            return self.rejectToken(self.tokens[colon], "invalid Less variable declaration name");
        }
        const variable_span = try self.tokenSpan(self.tokens[start]);
        const variable = try self.builder.add(.variable, variable_span, variable_span, &.{});

        if (boundary.kind == .open_curly) {
            const before_block = trim(self.tokens, .{ .start = colon + 1, .end = boundary.index });
            if (!before_block.empty()) {
                return self.rejectToken(self.tokens[before_block.start], "detached ruleset requires a direct block value");
            }
            const block = try self.parseBlock(boundary.index);
            var end = block.span.end;
            self.skipWhitespace();
            if (self.current().kind == .semicolon) {
                end = self.current().span.end;
                self.cursor += 1;
            }
            const children = [_]native_syntax.NodeId{ variable, block.id };
            const span = try self.sources.span(self.source_id, variable_span.start, end);
            const node = try self.builder.add(.detached_ruleset, span, null, &children);
            return .{ .id = node, .span = span };
        }

        const value_range = trim(self.tokens, .{ .start = colon + 1, .end = boundary.index });
        if (value_range.empty()) {
            return self.rejectToken(self.tokens[colon], "Less variable declaration is missing a value");
        }
        if (invalidAdjacentValueGroup(self.tokens, value_range)) {
            return self.rejectToken(self.tokens[value_range.start], "invalid adjacent Less value group");
        }
        const expression = try self.buildComposite(.expression, value_range);
        const children = [_]native_syntax.NodeId{ variable, expression.id };
        const end = if (boundary.kind == .semicolon)
            self.tokens[boundary.index].span.end
        else
            expression.span.end;
        const span = try self.sources.span(self.source_id, variable_span.start, end);
        const node = try self.builder.add(.declaration, span, null, &children);
        self.finishBoundary(boundary);
        return .{ .id = node, .span = span };
    }

    fn parseAtRule(self: *Parser, start: usize, boundary: Boundary) Error!Built {
        const keyword = self.tokens[start];
        const raw = keyword.raw(self.source_bytes);
        const prelude = trim(self.tokens, .{ .start = start + 1, .end = boundary.index });
        if (isImport(raw) and prelude.empty()) {
            return self.rejectToken(keyword, "Less import is missing a target");
        }
        if (isImport(raw) and !validImportPrelude(self.tokens, self.source_bytes, prelude)) {
            return self.rejectToken(keyword, "malformed Less import statement");
        }

        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        if (!prelude.empty()) {
            const expression = try self.buildComposite(.expression, prelude);
            try children.append(self.allocator, expression.id);
        }
        var end = if (boundary.kind == .close_curly or boundary.kind == .eof)
            (try self.rangeSpan(.{ .start = start, .end = boundary.index })).end
        else
            self.tokens[boundary.index].span.end;
        if (boundary.kind == .open_curly) {
            const block = try self.parseBlock(boundary.index);
            try children.append(self.allocator, block.id);
            end = block.span.end;
        } else {
            self.finishBoundary(boundary);
        }
        const keyword_span = try self.tokenSpan(keyword);
        const span = try self.sources.span(self.source_id, keyword_span.start, end);
        const node = try self.builder.add(
            if (isImport(raw)) .import else .at_rule,
            span,
            keyword_span,
            children.items,
        );
        return .{ .id = node, .span = span };
    }

    fn parseRuleOrMixin(self: *Parser, start: usize, boundary: Boundary) Error!Built {
        const header = trim(self.tokens, .{ .start = start, .end = boundary.index });
        if (header.empty()) {
            return self.rejectToken(self.tokens[boundary.index], "Less block is missing a selector or mixin signature");
        }
        if (invalidExtendPlacement(self.tokens, self.source_bytes, header)) {
            return self.rejectToken(self.tokens[header.start], "Less extend must end its selector");
        }
        const block = try self.parseBlock(boundary.index);
        const when_index = findTopLevelWhen(self.tokens, self.source_bytes, header);
        const signature_end = when_index orelse header.end;
        const signature = try self.buildComposite(
            .selector,
            trim(self.tokens, .{ .start = header.start, .end = signature_end }),
        );
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try children.append(self.allocator, signature.id);
        if (when_index) |guard_start| {
            const guard_range = trim(self.tokens, .{ .start = guard_start, .end = header.end });
            const guard = try self.buildComposite(.guard, guard_range);
            try children.append(self.allocator, guard.id);
        }
        try children.append(self.allocator, block.id);
        const span = try self.sources.span(self.source_id, signature.span.start, block.span.end);
        const kind: native_syntax.Kind = if (looksLikeMixinDefinition(
            self.tokens,
            self.source_bytes,
            header,
        )) .mixin else .rule;
        const node = try self.builder.add(kind, span, null, children.items);
        return .{ .id = node, .span = span };
    }

    fn parseBlock(self: *Parser, opening_index: usize) Error!Built {
        const opening = self.tokens[opening_index];
        self.cursor = opening_index + 1;
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try self.parseStatements(true, &children);
        const closing = self.current();
        if (closing.kind != .close_curly) {
            return self.rejectToken(closing, "expected '}' after Less block");
        }
        self.cursor += 1;
        const span = try self.sources.span(self.source_id, opening.span.start, closing.span.end);
        const node = try self.builder.add(.block, span, null, children.items);
        return .{ .id = node, .span = span };
    }

    fn buildDeclaration(
        self: *Parser,
        start: usize,
        colon: usize,
        boundary_index: usize,
    ) Error!Built {
        const property_range = trim(self.tokens, .{ .start = start, .end = colon });
        const value_range = trim(self.tokens, .{ .start = colon + 1, .end = boundary_index });
        if (property_range.empty()) {
            return self.rejectToken(self.tokens[colon], "declaration is missing a property name");
        }
        if (value_range.empty() and
            !isCustomProperty(self.tokens, self.source_bytes, property_range))
        {
            return self.rejectToken(self.tokens[colon], "declaration is missing a value");
        }
        if (!value_range.empty() and invalidAdjacentValueGroup(self.tokens, value_range)) {
            return self.rejectToken(self.tokens[value_range.start], "invalid adjacent Less value group");
        }
        const property = try self.buildComposite(.identifier, property_range);
        var children: [2]native_syntax.NodeId = undefined;
        children[0] = property.id;
        var child_count: usize = 1;
        var value_end = property.span.end;
        if (!value_range.empty()) {
            const expression = try self.buildComposite(.expression, value_range);
            children[1] = expression.id;
            child_count = 2;
            value_end = expression.span.end;
        }
        const boundary = self.tokens[boundary_index];
        const end = if (boundary.kind == .semicolon) boundary.span.end else value_end;
        const span = try self.sources.span(self.source_id, property.span.start, end);
        const node = try self.builder.add(.declaration, span, null, children[0..child_count]);
        if (boundary.kind == .semicolon) self.cursor = boundary_index + 1 else self.cursor = boundary_index;
        return .{ .id = node, .span = span };
    }

    fn buildMixinCall(self: *Parser, start: usize, boundary: Boundary) Error!Built {
        const header = trim(self.tokens, .{ .start = start, .end = boundary.index });
        if (invalidMixedNamedArguments(self.tokens, header)) {
            return self.rejectToken(
                self.tokens[header.start],
                "Less mixin arguments cannot mix delimiter types",
            );
        }
        const expression = try self.buildComposite(.expression, header);
        const end = if (boundary.kind == .semicolon)
            self.tokens[boundary.index].span.end
        else
            expression.span.end;
        const span = try self.sources.span(self.source_id, expression.span.start, end);
        const node = try self.builder.add(.mixin, span, null, &.{expression.id});
        self.finishBoundary(boundary);
        return .{ .id = node, .span = span };
    }

    fn buildTerminal(
        self: *Parser,
        kind: native_syntax.Kind,
        start: usize,
        boundary: Boundary,
    ) Error!Built {
        const header = trim(self.tokens, .{ .start = start, .end = boundary.index });
        if (kind == .extend and invalidExtendPlacement(self.tokens, self.source_bytes, header)) {
            return self.rejectToken(self.tokens[header.start], "Less extend must end its selector");
        }
        const expression = try self.buildComposite(.expression, header);
        const end = if (boundary.kind == .semicolon)
            self.tokens[boundary.index].span.end
        else
            expression.span.end;
        const span = try self.sources.span(self.source_id, expression.span.start, end);
        const node = try self.builder.add(kind, span, span, &.{expression.id});
        self.finishBoundary(boundary);
        return .{ .id = node, .span = span };
    }

    fn finishBoundary(self: *Parser, boundary: Boundary) void {
        if (boundary.kind == .semicolon) {
            self.cursor = boundary.index + 1;
        } else {
            self.cursor = boundary.index;
        }
    }

    fn scanBoundary(self: *const Parser, start: usize) Boundary {
        var depth: usize = 0;
        var colon: ?usize = null;
        var index = start;
        while (index < self.tokens.len) : (index += 1) {
            const kind = self.tokens[index].kind;
            switch (kind) {
                .open_paren, .open_square, .interpolation_start => depth += 1,
                .open_curly => {
                    if (depth == 0) return .{ .kind = .open_curly, .index = index, .colon = colon };
                    depth += 1;
                },
                .close_paren, .close_square, .interpolation_end => depth -|= 1,
                .close_curly => {
                    if (depth == 0) return .{ .kind = .close_curly, .index = index, .colon = colon };
                    depth -= 1;
                },
                .colon => if (depth == 0 and colon == null) {
                    colon = index;
                },
                .semicolon => if (depth == 0) {
                    return .{ .kind = .semicolon, .index = index, .colon = colon };
                },
                .eof => return .{ .kind = .eof, .index = index, .colon = colon },
                else => {},
            }
        }
        return .{ .kind = .eof, .index = self.tokens.len - 1, .colon = colon };
    }

    fn buildComposite(
        self: *Parser,
        kind: native_syntax.Kind,
        input_range: Range,
    ) Error!Built {
        const value_range = trim(self.tokens, input_range);
        if (value_range.empty()) return error.InvalidSyntax;
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try self.collectFragments(value_range, &children);
        const span = try self.rangeSpan(value_range);
        const node = try self.builder.add(kind, span, span, children.items);
        return .{ .id = node, .span = span };
    }

    fn collectFragments(
        self: *Parser,
        input_range: Range,
        children: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        var index = input_range.start;
        while (index < input_range.end) {
            const token = self.tokens[index];
            switch (token.kind) {
                .at_identifier => {
                    const span = try self.tokenSpan(token);
                    const node = try self.builder.add(.variable, span, span, &.{});
                    try children.append(self.allocator, node);
                    index += 1;
                },
                .comment => {
                    const span = try self.tokenSpan(token);
                    const node = try self.builder.add(.comment, span, span, &.{});
                    try children.append(self.allocator, node);
                    index += 1;
                },
                .string_start => {
                    const closing = findMatching(
                        self.tokens,
                        index,
                        input_range.end,
                        .string_start,
                        .string_end,
                    ) orelse return self.rejectToken(token, "unterminated string");
                    var nested: std.ArrayList(native_syntax.NodeId) = .empty;
                    defer nested.deinit(self.allocator);
                    try self.collectFragments(.{ .start = index + 1, .end = closing }, &nested);
                    const span = try self.sources.span(
                        self.source_id,
                        token.span.start,
                        self.tokens[closing].span.end,
                    );
                    const node = try self.builder.add(.string, span, span, nested.items);
                    try children.append(self.allocator, node);
                    index = closing + 1;
                },
                .interpolation_start => {
                    const closing = findMatching(
                        self.tokens,
                        index,
                        input_range.end,
                        .interpolation_start,
                        .interpolation_end,
                    ) orelse return self.rejectToken(token, "unterminated interpolation");
                    var interpolation_children: [1]native_syntax.NodeId = undefined;
                    const inner = trim(self.tokens, .{ .start = index + 1, .end = closing });
                    const child_slice = if (!inner.empty()) blk: {
                        const expression = try self.buildComposite(.expression, inner);
                        interpolation_children[0] = expression.id;
                        break :blk interpolation_children[0..1];
                    } else interpolation_children[0..0];
                    const span = try self.sources.span(
                        self.source_id,
                        token.span.start,
                        self.tokens[closing].span.end,
                    );
                    const node = try self.builder.add(.interpolation, span, span, child_slice);
                    try children.append(self.allocator, node);
                    index = closing + 1;
                },
                .open_curly => {
                    const closing = findMatching(
                        self.tokens,
                        index,
                        input_range.end,
                        .open_curly,
                        .close_curly,
                    ) orelse return self.rejectToken(token, "unterminated detached ruleset");
                    const saved_cursor = self.cursor;
                    const block = try self.parseBlock(index);
                    self.cursor = saved_cursor;
                    try children.append(self.allocator, block.id);
                    index = closing + 1;
                },
                else => index += 1,
            }
        }
    }

    fn consumeStatement(self: *Parser) Error!void {
        try self.cancellation.check(.statement);
        if (self.statement_count >= self.limits.max_statements) {
            return error.StatementLimitExceeded;
        }
        self.statement_count += 1;
    }

    fn skipWhitespace(self: *Parser) void {
        while (isIgnorable(self.current().kind)) self.cursor += 1;
    }

    fn current(self: *const Parser) native_lexer.Token {
        return self.tokens[@min(self.cursor, self.tokens.len - 1)];
    }

    fn tokenSpan(self: *const Parser, token: native_lexer.Token) Error!native_source.Span {
        return self.sources.span(self.source_id, token.span.start, token.span.end);
    }

    fn rangeSpan(self: *const Parser, value: Range) Error!native_source.Span {
        const bounded = trim(self.tokens, value);
        if (bounded.empty()) return error.InvalidSyntax;
        return self.sources.span(
            self.source_id,
            self.tokens[bounded.start].span.start,
            self.tokens[bounded.end - 1].span.end,
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
    var stream = try native_lexer.Lexer.init(bytes, .less, options);
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
        .string_end, .interpolation_end, .close_paren, .close_square, .close_curly => true,
        else => false,
    };
}

fn isIgnorable(kind: native_lexer.Kind) bool {
    return switch (kind) {
        .whitespace, .newline, .indent, .dedent => true,
        else => false,
    };
}

fn onlyIgnorable(tokens: []const native_lexer.Token) bool {
    for (tokens) |token| if (!isIgnorable(token.kind)) return false;
    return true;
}

fn trim(tokens: []const native_lexer.Token, input_range: Range) Range {
    var start = @min(input_range.start, tokens.len);
    var end = @min(input_range.end, tokens.len);
    while (start < end and isIgnorable(tokens[start].kind)) start += 1;
    while (end > start and isIgnorable(tokens[end - 1].kind)) end -= 1;
    return .{ .start = start, .end = end };
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

fn isDirective(raw: []const u8) bool {
    const directives = [_][]const u8{
        "@charset",             "@container", "@counter-style", "@document", "@font-face",
        "@font-feature-values", "@import",    "@keyframes",     "@layer",    "@media",
        "@namespace",           "@page",      "@plugin",        "@property", "@scope",
        "@starting-style",      "@supports",  "@viewport",
    };
    for (directives) |directive| {
        if (native_lexer.identifierEqlIgnoreCaseAscii(raw, directive)) return true;
    }
    return false;
}

fn isImport(raw: []const u8) bool {
    return native_lexer.identifierEqlIgnoreCaseAscii(raw, "@import");
}

fn validImportPrelude(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) bool {
    var target = firstSignificant(tokens, input_range) orelse return false;
    if (tokens[target].kind == .open_paren) {
        const options_end = findMatching(
            tokens,
            target,
            input_range.end,
            .open_paren,
            .close_paren,
        ) orelse return false;
        target = firstSignificant(tokens, .{ .start = options_end + 1, .end = input_range.end }) orelse
            return false;
    }
    if (tokens[target].kind == .string_start or
        tokens[target].kind == .interpolation_start) return true;
    if (tokens[target].kind == .identifier and tokenRawEql(tokens[target], bytes, "url")) {
        return containsKind(tokens, .{ .start = target + 1, .end = input_range.end }, .open_paren);
    }
    return !containsKind(tokens, .{ .start = target + 1, .end = input_range.end }, .string_start);
}

fn tokenRawEql(
    token: native_lexer.Token,
    bytes: []const u8,
    expected: []const u8,
) bool {
    return native_lexer.identifierEqlIgnoreCaseAscii(token.raw(bytes), expected);
}

fn findTopLevelWhen(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) ?usize {
    var depth: usize = 0;
    var index = input_range.start;
    while (index < input_range.end) : (index += 1) {
        switch (tokens[index].kind) {
            .open_paren, .open_square, .interpolation_start => depth += 1,
            .close_paren, .close_square, .interpolation_end => depth -|= 1,
            .identifier => if (depth == 0 and tokenRawEql(tokens[index], bytes, "when")) return index,
            else => {},
        }
    }
    return null;
}

fn looksLikeMixinDefinition(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) bool {
    if (findTopLevelWhen(tokens, bytes, input_range) != null) return true;
    const first = firstSignificant(tokens, input_range) orelse return false;
    if (!startsMixinName(tokens[first], bytes)) {
        var saw_open = false;
        var last: ?native_lexer.Kind = null;
        for (tokens[first..input_range.end]) |token| {
            if (token.kind == .open_paren) saw_open = true;
            if (!isIgnorable(token.kind)) last = token.kind;
        }
        return saw_open and last == .close_paren;
    }
    var index = first + 1;
    while (index < input_range.end and isIgnorable(tokens[index].kind)) : (index += 1) {}
    if (tokens[first].kind == .delimiter and index < input_range.end and
        tokens[index].kind == .identifier)
    {
        index += 1;
    }
    while (index < input_range.end and isIgnorable(tokens[index].kind)) : (index += 1) {}
    return index < input_range.end and tokens[index].kind == .open_paren;
}

fn looksLikeCall(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) bool {
    const first = firstSignificant(tokens, input_range) orelse return false;
    if (tokens[first].kind == .at_identifier) {
        var next = first + 1;
        while (next < input_range.end and isIgnorable(tokens[next].kind)) : (next += 1) {}
        return next < input_range.end and tokens[next].kind == .open_paren;
    }
    if (tokens[first].kind == .identifier) {
        var next = first + 1;
        while (next < input_range.end and isIgnorable(tokens[next].kind)) : (next += 1) {}
        return next < input_range.end and tokens[next].kind == .open_paren;
    }
    if (!startsMixinName(tokens[first], bytes)) return false;
    for (tokens[first + 1 .. input_range.end]) |token| {
        if (token.kind == .open_paren) return true;
        if (!isIgnorable(token.kind) and token.kind != .identifier and token.kind != .delimiter and
            token.kind != .interpolation_start and token.kind != .interpolation_end)
        {
            return false;
        }
    }
    return true;
}

fn startsMixinName(token: native_lexer.Token, bytes: []const u8) bool {
    if (token.kind == .hash_identifier) return true;
    return token.kind == .delimiter and std.mem.eql(u8, token.raw(bytes), ".");
}

fn firstSignificant(tokens: []const native_lexer.Token, input_range: Range) ?usize {
    var index = input_range.start;
    while (index < input_range.end) : (index += 1) {
        if (!isIgnorable(tokens[index].kind)) return index;
    }
    return null;
}

fn containsKind(
    tokens: []const native_lexer.Token,
    input_range: Range,
    kind: native_lexer.Kind,
) bool {
    for (tokens[input_range.start..input_range.end]) |token| {
        if (token.kind == kind) return true;
    }
    return false;
}

fn looksLikeMixinReference(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) bool {
    for (tokens[input_range.start..input_range.end]) |token| {
        if (startsMixinName(token, bytes)) return true;
    }
    return false;
}

fn isExtend(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) bool {
    var index = input_range.start;
    while (index + 1 < input_range.end) : (index += 1) {
        if (tokens[index].kind != .colon or tokens[index + 1].kind != .identifier) continue;
        if (tokenRawEql(tokens[index + 1], bytes, "extend")) return true;
    }
    return false;
}

fn invalidExtendPlacement(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) bool {
    var index = input_range.start;
    while (index + 2 < input_range.end) : (index += 1) {
        if (tokens[index].kind != .colon or tokens[index + 1].kind != .identifier or
            !tokenRawEql(tokens[index + 1], bytes, "extend")) continue;
        var opening = index + 2;
        while (opening < input_range.end and isIgnorable(tokens[opening].kind)) : (opening += 1) {}
        if (opening >= input_range.end or tokens[opening].kind != .open_paren) return true;
        const closing = findMatching(
            tokens,
            opening,
            input_range.end,
            .open_paren,
            .close_paren,
        ) orelse return true;
        const trailing = trim(tokens, .{ .start = closing + 1, .end = input_range.end });
        if (!trailing.empty() and tokens[trailing.start].kind != .comma) return true;
        index = closing;
    }
    return false;
}

fn isCustomProperty(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    input_range: Range,
) bool {
    const first = firstSignificant(tokens, input_range) orelse return false;
    return std.mem.startsWith(u8, tokens[first].raw(bytes), "--");
}

fn invalidMixedNamedArguments(tokens: []const native_lexer.Token, input_range: Range) bool {
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var saw_semicolon = false;
    var saw_named_after_semicolon = false;
    for (tokens[input_range.start..input_range.end]) |token| {
        switch (token.kind) {
            .open_paren => paren_depth += 1,
            .close_paren => paren_depth -= 1,
            .open_square => square_depth += 1,
            .close_square => square_depth -= 1,
            .open_curly => curly_depth += 1,
            .close_curly => curly_depth -= 1,
            .semicolon => if (paren_depth == 1 and square_depth == 0 and curly_depth == 0) {
                saw_semicolon = true;
                saw_named_after_semicolon = false;
            },
            .colon => if (saw_semicolon and paren_depth == 1 and
                square_depth == 0 and curly_depth == 0)
            {
                saw_named_after_semicolon = true;
            },
            .comma => if (saw_named_after_semicolon and paren_depth == 1 and
                square_depth == 0 and curly_depth == 0)
            {
                return true;
            },
            else => {},
        }
    }
    return false;
}

fn invalidAdjacentValueGroup(tokens: []const native_lexer.Token, input_range: Range) bool {
    var index = input_range.start;
    while (index < input_range.end) : (index += 1) {
        if (tokens[index].kind != .number) continue;
        var next = index + 1;
        while (next < input_range.end and
            (isIgnorable(tokens[next].kind) or tokens[next].kind == .comment)) : (next += 1)
        {}
        if (next < input_range.end and tokens[next].kind == .open_paren) return true;
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
