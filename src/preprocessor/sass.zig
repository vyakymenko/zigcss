//! Private native parser for SCSS and indented Sass.
//!
//! This module produces only an immutable internal syntax document. It does not
//! evaluate Sass, emit CSS, admit a public syntax, or invoke a reference engine.

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

pub const Mode = enum {
    scss,
    sass,
};

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
    mode: Mode,
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
        mode: Mode,
        limits: Limits,
        cancellation: Cancellation,
    ) Error!Parser {
        try validateLimits(limits);
        const file = try sources.get(source_id);
        const tokens = try tokenize(
            allocator,
            file.bytes,
            mode,
            limits.lexer,
            cancellation,
        );
        return .{
            .allocator = allocator,
            .sources = sources,
            .source_id = source_id,
            .source_bytes = file.bytes,
            .mode = mode,
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
        const document = switch (self.mode) {
            .scss => self.parseScssRoot(),
            .sass => self.parseSassRoot(),
        } catch |err| {
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
                return self.rejectToken(token, "unterminated Sass syntax");
            }
            if (token.kind == .invalid) {
                return self.rejectToken(token, "invalid control byte in Sass source");
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

    fn parseScssRoot(self: *Parser) Error!native_syntax.Document {
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try self.parseScssStatements(false, &children);
        if (self.current().kind != .eof) {
            return self.rejectToken(self.current(), "unexpected token after SCSS stylesheet");
        }
        const root_span = try self.sources.span(
            self.source_id,
            0,
            @intCast(self.source_bytes.len),
        );
        const root = try self.builder.add(.stylesheet, root_span, null, children.items);
        return self.builder.finish(root);
    }

    fn parseScssStatements(
        self: *Parser,
        in_block: bool,
        children: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        while (true) {
            self.skipScssWhitespace();
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
                    const node = try self.builder.add(
                        .comment,
                        try self.tokenSpan(token),
                        try self.tokenSpan(token),
                        &.{},
                    );
                    try children.append(self.allocator, node);
                    self.cursor += 1;
                },
                .variable => {
                    try self.consumeStatement();
                    const built = try self.parseScssVariable(in_block);
                    try children.append(self.allocator, built.id);
                },
                .at_identifier => {
                    try self.consumeStatement();
                    const built = try self.parseScssAtRule(in_block);
                    try children.append(self.allocator, built.id);
                },
                else => {
                    try self.consumeStatement();
                    const built = try self.parseScssRuleOrDeclaration(in_block);
                    try children.append(self.allocator, built.id);
                },
            }
        }
    }

    fn parseScssVariable(self: *Parser, in_block: bool) Error!Built {
        const start = self.cursor;
        const boundary = self.scanScssBoundary(start);
        const colon = boundary.colon orelse
            return self.rejectToken(self.tokens[start], "variable declaration is missing ':'");
        if (colon != start + 1 and !onlyIgnorable(self.tokens[start + 1 .. colon])) {
            return self.rejectToken(self.tokens[colon], "invalid variable declaration name");
        }
        if (boundary.kind == .open_curly) {
            return self.rejectToken(self.tokens[boundary.index], "variable declaration cannot own a block");
        }
        const value_range = trim(self.tokens, .{ .start = colon + 1, .end = boundary.index });
        if (value_range.empty()) {
            return self.rejectToken(self.tokens[colon], "variable declaration is missing a value");
        }
        if (!in_block and boundary.kind != .semicolon and boundary.kind != .eof) {
            return self.rejectToken(self.tokens[boundary.index], "top-level variable declaration requires ';'");
        }

        const variable_span = try self.tokenSpan(self.tokens[start]);
        const variable = try self.builder.add(.variable, variable_span, variable_span, &.{});
        const expression = try self.buildComposite(.expression, value_range);
        var child_ids = [_]native_syntax.NodeId{ variable, expression.id };
        const end = if (boundary.kind == .semicolon)
            self.tokens[boundary.index].span.end
        else
            expression.span.end;
        const span = try self.sources.span(self.source_id, self.tokens[start].span.start, end);
        const node = try self.builder.add(.declaration, span, null, &child_ids);
        if (boundary.kind == .semicolon) self.cursor = boundary.index + 1 else self.cursor = boundary.index;
        return .{ .id = node, .span = span };
    }

    fn parseScssAtRule(self: *Parser, in_block: bool) Error!Built {
        const start = self.cursor;
        const boundary = self.scanScssBoundary(start + 1);
        if (boundary.kind == .close_curly and !in_block) {
            return self.rejectToken(self.tokens[boundary.index], "SCSS at-rule requires ';' or a block");
        }

        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        const prelude = trim(self.tokens, .{ .start = start + 1, .end = boundary.index });
        if (!prelude.empty()) {
            const expression = try self.buildComposite(.expression, prelude);
            try children.append(self.allocator, expression.id);
        }

        var end = if (boundary.kind == .close_curly or boundary.kind == .eof)
            (try self.rangeSpan(.{ .start = start, .end = boundary.index })).end
        else
            self.tokens[boundary.index].span.end;
        if (boundary.kind == .open_curly) {
            const block = try self.parseScssBlock(boundary.index);
            try children.append(self.allocator, block.id);
            end = block.span.end;
        } else if (boundary.kind == .close_curly or boundary.kind == .eof) {
            self.cursor = boundary.index;
        } else {
            self.cursor = boundary.index + 1;
        }
        const keyword_span = try self.tokenSpan(self.tokens[start]);
        const span = try self.sources.span(self.source_id, keyword_span.start, end);
        const node = try self.builder.add(
            directiveKind(self.tokens[start].raw(self.source_bytes)),
            span,
            keyword_span,
            children.items,
        );
        return .{ .id = node, .span = span };
    }

    fn parseScssRuleOrDeclaration(self: *Parser, in_block: bool) Error!Built {
        const start = self.cursor;
        const boundary = self.scanScssBoundary(start);
        if (boundary.index == start) {
            return self.rejectToken(self.tokens[start], "empty SCSS statement");
        }
        if (boundary.kind == .open_curly) {
            const block = try self.parseScssBlock(boundary.index);
            if (in_block and boundary.colon != null and
                self.isNestedProperty(start, boundary.colon.?, boundary.index))
            {
                return self.buildDeclaration(start, boundary.colon.?, boundary.index, block);
            }
            const selector_range = trim(self.tokens, .{ .start = start, .end = boundary.index });
            if (selector_range.empty()) {
                return self.rejectToken(self.tokens[boundary.index], "style rule is missing a selector");
            }
            const selector = try self.buildComposite(.selector, selector_range);
            const child_ids = [_]native_syntax.NodeId{ selector.id, block.id };
            const span = try self.sources.span(self.source_id, selector.span.start, block.span.end);
            const node = try self.builder.add(.rule, span, null, &child_ids);
            return .{ .id = node, .span = span };
        }
        if (!in_block) {
            return self.rejectToken(self.tokens[start], "top-level SCSS statement requires a block");
        }
        const colon = boundary.colon orelse
            return self.rejectToken(self.tokens[start], "declaration is missing ':'");
        return self.buildDeclaration(start, colon, boundary.index, null);
    }

    fn parseScssBlock(self: *Parser, opening_index: usize) Error!Built {
        const opening = self.tokens[opening_index];
        self.cursor = opening_index + 1;
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try self.parseScssStatements(true, &children);
        const closing = self.current();
        if (closing.kind != .close_curly) {
            return self.rejectToken(closing, "expected '}' after SCSS block");
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
        block: ?Built,
    ) Error!Built {
        const property_range = trim(self.tokens, .{ .start = start, .end = colon });
        if (property_range.empty()) {
            return self.rejectToken(self.tokens[colon], "declaration is missing a property name");
        }
        const value_range = trim(self.tokens, .{ .start = colon + 1, .end = boundary_index });
        if (value_range.empty() and block == null) {
            return self.rejectToken(self.tokens[colon], "declaration is missing a value");
        }

        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        const property = try self.buildComposite(.identifier, property_range);
        try children.append(self.allocator, property.id);
        var value_end = property.span.end;
        if (!value_range.empty()) {
            const expression = try self.buildComposite(.expression, value_range);
            try children.append(self.allocator, expression.id);
            value_end = expression.span.end;
        }
        if (block) |child_block| {
            try children.append(self.allocator, child_block.id);
            value_end = child_block.span.end;
        }

        const boundary = self.tokens[boundary_index];
        const end = if (block != null)
            value_end
        else if (boundary.kind == .semicolon)
            boundary.span.end
        else
            value_end;
        const span = try self.sources.span(self.source_id, property.span.start, end);
        const node = try self.builder.add(.declaration, span, null, children.items);
        if (block == null) {
            if (boundary.kind == .semicolon) self.cursor = boundary_index + 1 else self.cursor = boundary_index;
        }
        return .{ .id = node, .span = span };
    }

    fn scanScssBoundary(self: *const Parser, start: usize) Boundary {
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
                .close_paren, .close_square, .interpolation_end => depth -= 1,
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

    fn isNestedProperty(self: *const Parser, start: usize, colon: usize, opening: usize) bool {
        if (trim(self.tokens, .{ .start = start, .end = colon }).empty()) return false;
        const after = trim(self.tokens, .{ .start = colon + 1, .end = opening });
        if (after.empty()) return true;
        return hasWhitespaceBetween(self.source_bytes, self.tokens[colon], self.tokens[after.start]);
    }

    fn parseSassRoot(self: *Parser) Error!native_syntax.Document {
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        var first: ?u32 = null;
        var last: u32 = 0;
        try self.parseSassChildren(0, &children, &first, &last);
        self.prepareSassCursor();
        if (self.current().kind != .eof) {
            return self.rejectToken(self.current(), "unexpected token after indented Sass stylesheet");
        }
        const root_span = try self.sources.span(
            self.source_id,
            0,
            @intCast(self.source_bytes.len),
        );
        const root = try self.builder.add(.stylesheet, root_span, null, children.items);
        return self.builder.finish(root);
    }

    fn parseSassChildren(
        self: *Parser,
        expected_indent: u32,
        children: *std.ArrayList(native_syntax.NodeId),
        first: *?u32,
        last: *u32,
    ) Error!void {
        while (true) {
            self.prepareSassCursor();
            const token = self.current();
            if (token.kind == .eof) return;
            const indentation = self.indentationAt(token.span.start);
            if (indentation < expected_indent) return;
            if (indentation > expected_indent) {
                return self.rejectToken(token, "unexpected indentation in Sass source");
            }
            try self.consumeStatement();
            const built = try self.parseSassStatement(indentation);
            if (first.* == null) first.* = built.span.start;
            last.* = built.span.end;
            try children.append(self.allocator, built.id);
        }
    }

    fn parseSassStatement(self: *Parser, indentation: u32) Error!Built {
        const header = try self.scanSassHeader();
        if (header.empty()) return self.rejectToken(self.current(), "empty Sass statement");
        const first_token = self.tokens[header.start];

        self.prepareSassCursor();
        var child_block: ?Built = null;
        if (self.current().kind != .eof) {
            const next_indent = self.indentationAt(self.current().span.start);
            if (next_indent > indentation) {
                child_block = try self.parseSassBlock(next_indent);
            }
        }

        if (onlyComment(self.tokens, header)) {
            var child_ids: [1]native_syntax.NodeId = undefined;
            const children = if (child_block) |block| blk: {
                child_ids[0] = block.id;
                break :blk child_ids[0..1];
            } else child_ids[0..0];
            const text = try self.tokenSpan(first_token);
            const end = if (child_block) |block| block.span.end else text.end;
            const span = try self.sources.span(self.source_id, text.start, end);
            const node = try self.builder.add(.comment, span, text, children);
            return .{ .id = node, .span = span };
        }
        if (first_token.kind == .variable) {
            if (child_block != null) {
                return self.rejectToken(first_token, "variable declaration cannot own an indented block");
            }
            return self.buildSassVariable(header);
        }
        if (first_token.kind == .at_identifier) {
            return self.buildSassAtRule(header, child_block);
        }

        const colon = findTopLevelColon(self.tokens, header);
        if (child_block) |block| {
            if (colon) |colon_index| {
                const after = trim(self.tokens, .{ .start = colon_index + 1, .end = header.end });
                if (after.empty() or
                    hasWhitespaceBetween(self.source_bytes, self.tokens[colon_index], self.tokens[after.start]))
                {
                    return self.buildSassDeclaration(header, colon_index, block);
                }
            }
            const selector = try self.buildComposite(.selector, header);
            const child_ids = [_]native_syntax.NodeId{ selector.id, block.id };
            const span = try self.sources.span(self.source_id, selector.span.start, block.span.end);
            const node = try self.builder.add(.rule, span, null, &child_ids);
            return .{ .id = node, .span = span };
        }
        if (colon) |colon_index| return self.buildSassDeclaration(header, colon_index, null);
        return self.rejectToken(first_token, "indented Sass style rule requires an indented block");
    }

    fn parseSassBlock(self: *Parser, indentation: u32) Error!Built {
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        var first: ?u32 = null;
        var last: u32 = 0;
        try self.parseSassChildren(indentation, &children, &first, &last);
        if (children.items.len == 0 or first == null) {
            return self.rejectToken(self.current(), "indented Sass block is empty");
        }
        const span = try self.sources.span(self.source_id, first.?, last);
        const node = try self.builder.add(.block, span, null, children.items);
        return .{ .id = node, .span = span };
    }

    fn buildSassVariable(self: *Parser, header: Range) Error!Built {
        const colon = findTopLevelColon(self.tokens, header) orelse
            return self.rejectToken(self.tokens[header.start], "variable declaration is missing ':'");
        const value_range = trim(self.tokens, .{ .start = colon + 1, .end = header.end });
        if (value_range.empty()) {
            return self.rejectToken(self.tokens[colon], "variable declaration is missing a value");
        }
        const variable_span = try self.tokenSpan(self.tokens[header.start]);
        const variable = try self.builder.add(.variable, variable_span, variable_span, &.{});
        const expression = try self.buildComposite(.expression, value_range);
        const child_ids = [_]native_syntax.NodeId{ variable, expression.id };
        const span = try self.rangeSpan(header);
        const node = try self.builder.add(.declaration, span, null, &child_ids);
        return .{ .id = node, .span = span };
    }

    fn buildSassAtRule(self: *Parser, header: Range, block: ?Built) Error!Built {
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        const prelude = trim(self.tokens, .{ .start = header.start + 1, .end = header.end });
        if (!prelude.empty()) {
            const expression = try self.buildComposite(.expression, prelude);
            try children.append(self.allocator, expression.id);
        }
        if (block) |child_block| try children.append(self.allocator, child_block.id);
        const keyword = try self.tokenSpan(self.tokens[header.start]);
        const end = if (block) |child_block| child_block.span.end else (try self.rangeSpan(header)).end;
        const span = try self.sources.span(self.source_id, keyword.start, end);
        const node = try self.builder.add(
            directiveKind(self.tokens[header.start].raw(self.source_bytes)),
            span,
            keyword,
            children.items,
        );
        return .{ .id = node, .span = span };
    }

    fn buildSassDeclaration(
        self: *Parser,
        header: Range,
        colon: usize,
        block: ?Built,
    ) Error!Built {
        const property_range = trim(self.tokens, .{ .start = header.start, .end = colon });
        const value_range = trim(self.tokens, .{ .start = colon + 1, .end = header.end });
        if (property_range.empty()) {
            return self.rejectToken(self.tokens[colon], "declaration is missing a property name");
        }
        if (value_range.empty() and block == null) {
            return self.rejectToken(self.tokens[colon], "declaration is missing a value");
        }
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        const property = try self.buildComposite(.identifier, property_range);
        try children.append(self.allocator, property.id);
        if (!value_range.empty()) {
            const expression = try self.buildComposite(.expression, value_range);
            try children.append(self.allocator, expression.id);
        }
        if (block) |child_block| try children.append(self.allocator, child_block.id);
        const header_span = try self.rangeSpan(header);
        const end = if (block) |child_block| child_block.span.end else header_span.end;
        const span = try self.sources.span(self.source_id, property.span.start, end);
        const node = try self.builder.add(.declaration, span, null, children.items);
        return .{ .id = node, .span = span };
    }

    fn scanSassHeader(self: *Parser) Error!Range {
        const start = self.cursor;
        var index = start;
        var depth: usize = 0;
        var last_significant: ?usize = null;
        while (index < self.tokens.len) : (index += 1) {
            const token = self.tokens[index];
            switch (token.kind) {
                .indent, .dedent, .whitespace => continue,
                .open_paren, .open_square, .open_curly, .interpolation_start => depth += 1,
                .close_paren, .close_square, .close_curly, .interpolation_end => depth -= 1,
                .newline => {
                    if (depth != 0 or
                        continuesLine(self.tokens, last_significant) or
                        continuesDirectivePrelude(
                            self.tokens,
                            self.source_bytes,
                            start,
                            last_significant,
                        )) continue;
                    self.cursor = index + 1;
                    return trim(self.tokens, .{ .start = start, .end = index });
                },
                .eof => {
                    self.cursor = index;
                    return trim(self.tokens, .{ .start = start, .end = index });
                },
                else => {},
            }
            if (!isIgnorable(token.kind)) last_significant = index;
        }
        return error.InvalidSyntax;
    }

    fn prepareSassCursor(self: *Parser) void {
        while (self.cursor < self.tokens.len) {
            switch (self.tokens[self.cursor].kind) {
                .whitespace, .newline, .indent, .dedent => self.cursor += 1,
                else => return,
            }
        }
    }

    fn indentationAt(self: *const Parser, offset_u32: u32) u32 {
        const offset: usize = @intCast(offset_u32);
        var line_start = offset;
        while (line_start > 0 and self.source_bytes[line_start - 1] != '\n' and
            self.source_bytes[line_start - 1] != '\r')
        {
            line_start -= 1;
        }
        var cursor = line_start;
        var column: u32 = 0;
        while (cursor < offset) : (cursor += 1) {
            switch (self.source_bytes[cursor]) {
                ' ' => column += 1,
                '\t' => {
                    const width: u32 = self.limits.lexer.tab_width;
                    column += width - (column % width);
                },
                '\x0c' => column = 0,
                else => return column,
            }
        }
        return column;
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
                .variable => {
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
                    const closing = findMatching(self.tokens, index, input_range.end, .string_start, .string_end) orelse
                        return self.rejectToken(token, "unterminated string");
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
                    var child_ids: [1]native_syntax.NodeId = undefined;
                    const inner = trim(self.tokens, .{ .start = index + 1, .end = closing });
                    const interpolation_children = if (!inner.empty()) blk: {
                        const expression = try self.buildComposite(.expression, inner);
                        child_ids[0] = expression.id;
                        break :blk child_ids[0..1];
                    } else child_ids[0..0];
                    const span = try self.sources.span(
                        self.source_id,
                        token.span.start,
                        self.tokens[closing].span.end,
                    );
                    const node = try self.builder.add(
                        .interpolation,
                        span,
                        span,
                        interpolation_children,
                    );
                    try children.append(self.allocator, node);
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

    fn skipScssWhitespace(self: *Parser) void {
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
        return self.rejectSpan(self.tokenSpan(token) catch unreachable, message);
    }

    fn rejectSpan(self: *Parser, span: native_source.Span, message: []const u8) Error {
        self.diagnostic_list.append(.err, .syntax, span, message, &.{}) catch |err| return err;
        return error.InvalidSyntax;
    }
};

fn tokenize(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    mode: Mode,
    options: native_lexer.Options,
    cancellation: Cancellation,
) Error![]native_lexer.Token {
    var stream = try native_lexer.Lexer.init(
        bytes,
        switch (mode) {
            .scss => .scss,
            .sass => .sass,
        },
        options,
    );
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

fn findTopLevelColon(tokens: []const native_lexer.Token, input_range: Range) ?usize {
    var depth: usize = 0;
    var index = input_range.start;
    while (index < input_range.end) : (index += 1) {
        switch (tokens[index].kind) {
            .open_paren, .open_square, .open_curly, .interpolation_start => depth += 1,
            .close_paren, .close_square, .close_curly, .interpolation_end => depth -= 1,
            .colon => if (depth == 0) return index,
            else => {},
        }
    }
    return null;
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

fn continuesLine(tokens: []const native_lexer.Token, last: ?usize) bool {
    const index = last orelse return false;
    return tokens[index].kind == .comma or tokens[index].kind == .operator;
}

fn continuesDirectivePrelude(
    tokens: []const native_lexer.Token,
    bytes: []const u8,
    start: usize,
    last: ?usize,
) bool {
    if (start >= tokens.len or last != start or tokens[start].kind != .at_identifier) return false;
    const raw = tokens[start].raw(bytes);
    const requiring_prelude = [_][]const u8{
        "@at-root", "@debug",    "@each",     "@error",  "@extend",  "@for",
        "@forward", "@function", "@if",       "@import", "@include", "@media",
        "@mixin",   "@return",   "@supports", "@use",    "@warn",    "@while",
    };
    for (requiring_prelude) |directive| {
        if (std.ascii.eqlIgnoreCase(raw, directive)) return true;
    }
    return false;
}

fn onlyComment(tokens: []const native_lexer.Token, input_range: Range) bool {
    var comments: usize = 0;
    for (tokens[input_range.start..input_range.end]) |token| {
        if (isIgnorable(token.kind)) continue;
        if (token.kind != .comment) return false;
        comments += 1;
    }
    return comments == 1;
}

fn hasWhitespaceBetween(
    bytes: []const u8,
    left: native_lexer.Token,
    right: native_lexer.Token,
) bool {
    const start: usize = @intCast(left.span.end);
    const end: usize = @intCast(right.span.start);
    if (start >= end or end > bytes.len) return false;
    for (bytes[start..end]) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c') {
            return true;
        }
    }
    return false;
}

fn directiveKind(raw: []const u8) native_syntax.Kind {
    if (std.ascii.eqlIgnoreCase(raw, "@if") or std.ascii.eqlIgnoreCase(raw, "@else")) {
        return .conditional;
    }
    if (std.ascii.eqlIgnoreCase(raw, "@for") or
        std.ascii.eqlIgnoreCase(raw, "@each") or
        std.ascii.eqlIgnoreCase(raw, "@while"))
    {
        return .loop;
    }
    if (std.ascii.eqlIgnoreCase(raw, "@mixin") or std.ascii.eqlIgnoreCase(raw, "@include")) {
        return .mixin;
    }
    if (std.ascii.eqlIgnoreCase(raw, "@function")) return .function;
    if (std.ascii.eqlIgnoreCase(raw, "@return")) return .return_statement;
    if (std.ascii.eqlIgnoreCase(raw, "@content")) return .content;
    if (std.ascii.eqlIgnoreCase(raw, "@import")) return .import;
    if (std.ascii.eqlIgnoreCase(raw, "@use") or std.ascii.eqlIgnoreCase(raw, "@forward")) {
        return .module;
    }
    return .at_rule;
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
