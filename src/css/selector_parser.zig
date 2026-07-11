const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const diagnostics = @import("../diagnostics.zig");
const recovery = @import("recovery.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Options = struct {
    max_nesting: usize = 128,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidSelector,
    SelectorNestingLimit,
    UnknownSource,
};

pub fn parse(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
) Error!*const ast.SelectorList {
    return parseWithOptions(context, source_id, input, .{});
}

pub fn parseWithOptions(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
    options: Options,
) Error!*const ast.SelectorList {
    return parseInternal(context, source_id, input, options, .{});
}

pub fn parseNested(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
) Error!*const ast.SelectorList {
    return parseNestedWithOptions(context, source_id, input, .{});
}

pub fn parseNestedWithOptions(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
    options: Options,
) Error!*const ast.SelectorList {
    return parseInternal(context, source_id, input, options, .{
        .allow_relative = true,
        .nested_rule = true,
    });
}

fn parseInternal(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
    options: Options,
    selector_context: SelectorContext,
) Error!*const ast.SelectorList {
    const file = try context.sources.get(source_id);
    if (!input.span.source.eql(source_id)) return error.InvalidSelector;
    _ = ast.ComponentValueList.init(input.span, input.values) catch return error.InvalidSelector;
    var parser = Parser{
        .allocator = context.arenaAllocator(),
        .context = context,
        .file = file,
        .options = options,
        .suppressed_diagnostics = 0,
    };
    return parser.parseList(input.values, input.span, 0, selector_context);
}

const ParsedSimple = struct {
    simple: ast.SimpleSelector,
    next: usize,
};

const ParsedCompound = struct {
    compound: ast.CompoundSelector,
    next: usize,
};

const ExplicitCombinator = struct {
    kind: ast.CombinatorKind,
    next: usize,
};

const TriviaScan = struct {
    next: usize,
    saw_whitespace: bool,
};

const SelectorContext = struct {
    allow_relative: bool = false,
    nested_rule: bool = false,
    forgiving: bool = false,
    disallow_pseudo_elements: bool = false,
    inside_has: bool = false,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    context: *compilation.Compilation,
    file: *const source.SourceFile,
    options: Options,
    suppressed_diagnostics: usize,

    fn parseList(
        self: *Parser,
        values: []const syntax.ComponentValue,
        span: source.Span,
        depth: usize,
        selector_context: SelectorContext,
    ) Error!*const ast.SelectorList {
        if (depth >= self.options.max_nesting) {
            try self.report(.resource_limit, span, "selector nesting limit exceeded");
            return error.SelectorNestingLimit;
        }

        var selectors = try std.ArrayList(ast.ComplexSelector).initCapacity(self.allocator, 0);
        errdefer selectors.deinit(self.allocator);
        var segment_start: usize = 0;
        var index: usize = 0;
        while (index <= values.len) : (index += 1) {
            if (index != values.len and !isComma(values[index])) continue;
            if (segment_start == index) {
                if (selector_context.forgiving) {
                    segment_start = index + 1;
                    continue;
                }
                const error_span = if (index < values.len) values[index].span() else span;
                try self.report(.unexpected_token, error_span, "empty selector in selector list");
                return error.InvalidSelector;
            }
            if (selector_context.forgiving) self.suppressed_diagnostics += 1;
            const selector_result = self.parseComplex(
                values,
                segment_start,
                index,
                depth,
                selector_context,
            );
            if (selector_context.forgiving) self.suppressed_diagnostics -= 1;
            const selector = selector_result catch |err| switch (err) {
                error.InvalidSelector => {
                    if (!selector_context.forgiving) return error.InvalidSelector;
                    segment_start = index + 1;
                    continue;
                },
                else => return err,
            };
            try selectors.append(self.allocator, selector);
            segment_start = index + 1;
        }

        if (selectors.items.len == 0 and !selector_context.forgiving) {
            try self.report(.unexpected_token, span, "selector list is empty");
            return error.InvalidSelector;
        }
        const owned = try selectors.toOwnedSlice(self.allocator);
        const list = self.allocator.create(ast.SelectorList) catch return error.OutOfMemory;
        list.* = (if (selector_context.forgiving)
            ast.SelectorList.initForgiving(span, owned)
        else
            ast.SelectorList.init(span, owned)) catch {
            try self.report(.internal, span, "selector-list span invariant failed");
            return error.InvalidSelector;
        };
        return list;
    }

    fn parseComplex(
        self: *Parser,
        values: []const syntax.ComponentValue,
        raw_start: usize,
        raw_end: usize,
        depth: usize,
        selector_context: SelectorContext,
    ) Error!ast.ComplexSelector {
        const start = trimTriviaStart(values, raw_start, raw_end);
        const end = trimTriviaEnd(values, start, raw_end);
        if (start == end) {
            try self.report(.unexpected_token, values[raw_start].span(), "selector contains only trivia");
            return error.InvalidSelector;
        }

        var index = start;
        var leading: ?ast.Combinator = null;
        if (parseExplicitCombinator(values, index, end)) |explicit| {
            if (!selector_context.allow_relative) {
                try self.report(.unexpected_token, values[index].span(), "leading combinator requires a relative selector");
                return error.InvalidSelector;
            }
            const after = scanTrivia(values, explicit.next, end);
            if (after.next == end) {
                try self.report(.unexpected_token, values[index].span(), "combinator has no following compound selector");
                return error.InvalidSelector;
            }
            leading = .{
                .kind = explicit.kind,
                .span = makeSpan(values[index].span().source, values[index].span().start, values[after.next].span().start),
            };
            index = after.next;
        }

        const head_checkpoint = recovery.DiagnosticCheckpoint.capture(self.context);
        const head = self.parseCompound(values, index, end, depth, selector_context) catch |err| {
            if (err == error.InvalidSelector and head_checkpoint.unchanged(self.context)) {
                try self.report(.unexpected_token, values[index].span(), "expected a compound selector");
            }
            return err;
        };
        index = head.next;
        var last_compound = head.compound;
        var tails = try std.ArrayList(ast.ComplexSelectorTail).initCapacity(self.allocator, 0);
        errdefer tails.deinit(self.allocator);

        while (true) {
            const gap_start = last_compound.span.end;
            const trivia = scanTrivia(values, index, end);
            if (trivia.next == end) break;
            if (compoundHasPseudoElement(last_compound)) {
                try self.report(.unexpected_token, values[trivia.next].span(), "pseudo-element must remain in the final complex-selector unit");
                return error.InvalidSelector;
            }

            var combinator_kind: ast.CombinatorKind = undefined;
            var compound_start: usize = undefined;
            if (parseExplicitCombinator(values, trivia.next, end)) |explicit| {
                combinator_kind = explicit.kind;
                const after = scanTrivia(values, explicit.next, end);
                if (after.next == end) {
                    try self.report(.unexpected_token, values[trivia.next].span(), "combinator has no following compound selector");
                    return error.InvalidSelector;
                }
                compound_start = after.next;
            } else if (trivia.saw_whitespace) {
                combinator_kind = .descendant;
                compound_start = trivia.next;
            } else {
                try self.report(.unexpected_token, values[trivia.next].span(), "unexpected token between compound selectors");
                return error.InvalidSelector;
            }

            const compound_checkpoint = recovery.DiagnosticCheckpoint.capture(self.context);
            const next_compound = self.parseCompound(
                values,
                compound_start,
                end,
                depth,
                selector_context,
            ) catch |err| {
                if (err == error.InvalidSelector and compound_checkpoint.unchanged(self.context)) {
                    try self.report(.unexpected_token, values[compound_start].span(), "expected a compound selector after combinator");
                }
                return err;
            };
            const combinator = ast.Combinator{
                .kind = combinator_kind,
                .span = makeSpan(
                    last_compound.span.source,
                    gap_start,
                    next_compound.compound.span.start,
                ),
            };
            try tails.append(self.allocator, .{
                .combinator = combinator,
                .compound = next_compound.compound,
                .span = makeSpan(
                    combinator.span.source,
                    combinator.span.start,
                    next_compound.compound.span.end,
                ),
            });
            last_compound = next_compound.compound;
            index = next_compound.next;
        }

        const selector_start = if (leading) |combinator| combinator.span.start else head.compound.span.start;
        const owned_tails = try tails.toOwnedSlice(self.allocator);
        var selector = ast.ComplexSelector.init(
            makeSpan(spanSource(values, start), selector_start, last_compound.span.end),
            leading,
            head.compound,
            owned_tails,
        ) catch {
            try self.report(.internal, makeSpan(spanSource(values, start), selector_start, last_compound.span.end), "complex-selector span invariant failed");
            return error.InvalidSelector;
        };
        selector.implicit_nesting = selector_context.nested_rule and
            !containsNestingDelimiter(values[start..end]);
        return selector;
    }

    fn parseCompound(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        end: usize,
        depth: usize,
        selector_context: SelectorContext,
    ) Error!ParsedCompound {
        var simples = try std.ArrayList(ast.SimpleSelector).initCapacity(self.allocator, 0);
        errdefer simples.deinit(self.allocator);
        var index = start;
        var saw_pseudo_element = false;

        if (try self.parseTypeOrUniversal(values, index, end)) |parsed| {
            try simples.append(self.allocator, parsed.simple);
            index = parsed.next;
        }

        while (index < end) {
            const comments_start = index;
            index = skipComments(values, index, end);
            if (index == end or isWhitespace(values[index])) {
                index = comments_start;
                break;
            }
            const parsed = try self.parseSubclass(values, index, end, depth, selector_context) orelse {
                index = comments_start;
                break;
            };
            switch (parsed.simple) {
                .pseudo_element => {
                    if (saw_pseudo_element) return error.InvalidSelector;
                    saw_pseudo_element = true;
                },
                .pseudo_class => if (saw_pseudo_element and !isAllowedAfterPseudoElement(parsed.simple.pseudo_class.name.value)) {
                    return error.InvalidSelector;
                },
                else => if (saw_pseudo_element) return error.InvalidSelector,
            }
            try simples.append(self.allocator, parsed.simple);
            index = parsed.next;
        }

        if (simples.items.len == 0) return error.InvalidSelector;
        const first_span = simples.items[0].span();
        const last_span = simples.items[simples.items.len - 1].span();
        const owned = try simples.toOwnedSlice(self.allocator);
        const compound = ast.CompoundSelector.init(
            makeSpan(first_span.source, first_span.start, last_span.end),
            owned,
        ) catch return error.InvalidSelector;
        return .{ .compound = compound, .next = index };
    }

    fn parseTypeOrUniversal(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        end: usize,
    ) Error!?ParsedSimple {
        if (start >= end) return null;
        const first_token = tokenAt(values[start]) orelse return null;

        if (first_token.kind == .ident) {
            const bar_index = skipComments(values, start + 1, end);
            if (bar_index < end and isDelimiter(values[bar_index], '|')) {
                const name_index = skipComments(values, bar_index + 1, end);
                if (name_index < end and isTypeName(values[name_index])) {
                    const namespace = ast.Namespace{ .named = try self.identifier(first_token) };
                    return try self.finishType(values, start, name_index, namespace);
                }
            }
            const name = try self.identifier(first_token);
            return .{ .simple = .{ .type_selector = .{
                .namespace = .implicit,
                .name = name,
                .span = first_token.span,
            } }, .next = start + 1 };
        }

        if (isDelimiter(values[start], '*')) {
            const bar_index = skipComments(values, start + 1, end);
            if (bar_index < end and isDelimiter(values[bar_index], '|')) {
                const name_index = skipComments(values, bar_index + 1, end);
                if (name_index < end and isTypeName(values[name_index])) {
                    return try self.finishType(values, start, name_index, .{
                        .any = makeSpan(first_token.span.source, first_token.span.start, values[bar_index].span().end),
                    });
                }
            }
            return .{ .simple = .{ .universal = .{
                .namespace = .implicit,
                .span = first_token.span,
            } }, .next = start + 1 };
        }

        if (isDelimiter(values[start], '|')) {
            const possible_second_bar = skipComments(values, start + 1, end);
            if (possible_second_bar < end and isDelimiter(values[possible_second_bar], '|')) return null;
            const name_index = possible_second_bar;
            if (name_index < end and isTypeName(values[name_index])) {
                return try self.finishType(values, start, name_index, .{ .empty = first_token.span });
            }
        }
        return null;
    }

    fn finishType(
        self: *Parser,
        values: []const syntax.ComponentValue,
        first_index: usize,
        name_index: usize,
        namespace: ast.Namespace,
    ) Error!ParsedSimple {
        const name_token = tokenAt(values[name_index]).?;
        const overall = makeSpan(
            values[first_index].span().source,
            values[first_index].span().start,
            name_token.span.end,
        );
        if (name_token.kind == .ident) {
            return .{ .simple = .{ .type_selector = .{
                .namespace = namespace,
                .name = try self.identifier(name_token),
                .span = overall,
            } }, .next = name_index + 1 };
        }
        return .{ .simple = .{ .universal = .{
            .namespace = namespace,
            .span = overall,
        } }, .next = name_index + 1 };
    }

    fn parseSubclass(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        end: usize,
        depth: usize,
        selector_context: SelectorContext,
    ) Error!?ParsedSimple {
        if (start >= end) return null;
        if (tokenAt(values[start])) |token| {
            if (token.kind == .hash and token.data.hash.hash_type == .id) {
                return .{ .simple = .{ .id = .{
                    .name = try self.identifier(token),
                    .span = token.span,
                } }, .next = start + 1 };
            }
            if (isDelimiter(values[start], '.')) {
                const name_index = skipComments(values, start + 1, end);
                if (name_index >= end) return error.InvalidSelector;
                const name_token = tokenAt(values[name_index]) orelse return error.InvalidSelector;
                if (name_token.kind != .ident) return error.InvalidSelector;
                return .{ .simple = .{ .class = .{
                    .name = try self.identifier(name_token),
                    .span = makeSpan(token.span.source, token.span.start, name_token.span.end),
                } }, .next = name_index + 1 };
            }
            if (token.kind == .colon) {
                return try self.parsePseudo(values, start, end, depth, selector_context);
            }
            if (isDelimiter(values[start], '&')) {
                return .{ .simple = .{ .nesting = token.span }, .next = start + 1 };
            }
        }
        return switch (values[start]) {
            .simple_block => |block| if (block.opening.kind == .open_square)
                try self.parseAttribute(block, start)
            else
                null,
            else => null,
        };
    }

    fn parseAttribute(self: *Parser, block: *const syntax.SimpleBlock, outer_index: usize) Error!ParsedSimple {
        if (!block.terminated()) return error.InvalidSelector;
        const values = block.values;
        var index = scanTrivia(values, 0, values.len).next;
        if (index == values.len) return error.InvalidSelector;

        var namespace: ast.Namespace = .implicit;
        var name_token: tokenizer.Token = undefined;
        const first_token = tokenAt(values[index]) orelse return error.InvalidSelector;
        if (first_token.kind == .ident) {
            const bar_index = skipComments(values, index + 1, values.len);
            if (bar_index < values.len and isDelimiter(values[bar_index], '|')) {
                const name_index = skipComments(values, bar_index + 1, values.len);
                if (name_index < values.len and isTokenKind(values[name_index], .ident)) {
                    name_token = tokenAt(values[name_index]).?;
                    namespace = .{ .named = try self.identifier(first_token) };
                    index = name_index + 1;
                } else {
                    name_token = first_token;
                    index += 1;
                }
            } else {
                name_token = first_token;
                index += 1;
            }
        } else if (isDelimiter(values[index], '*')) {
            const bar_index = skipComments(values, index + 1, values.len);
            if (bar_index >= values.len or !isDelimiter(values[bar_index], '|')) return error.InvalidSelector;
            const name_index = skipComments(values, bar_index + 1, values.len);
            if (name_index >= values.len) return error.InvalidSelector;
            name_token = tokenAt(values[name_index]) orelse return error.InvalidSelector;
            if (name_token.kind != .ident) return error.InvalidSelector;
            namespace = .{ .any = makeSpan(first_token.span.source, first_token.span.start, values[bar_index].span().end) };
            index = name_index + 1;
        } else if (isDelimiter(values[index], '|')) {
            const name_index = skipComments(values, index + 1, values.len);
            if (name_index >= values.len) return error.InvalidSelector;
            name_token = tokenAt(values[name_index]) orelse return error.InvalidSelector;
            if (name_token.kind != .ident) return error.InvalidSelector;
            namespace = .{ .empty = first_token.span };
            index = name_index + 1;
        } else return error.InvalidSelector;

        index = scanTrivia(values, index, values.len).next;
        var matcher: ?ast.AttributeMatcher = null;
        var attribute_value: ?ast.AttributeValue = null;
        var modifier: ?ast.AttributeModifier = null;
        if (index < values.len) {
            const operator_start = index;
            var kind: ast.AttributeMatcherKind = undefined;
            var equal_index: usize = undefined;
            if (isDelimiter(values[index], '=')) {
                kind = .exact;
                equal_index = index;
            } else {
                kind = if (isDelimiter(values[index], '~'))
                    .includes
                else if (isDelimiter(values[index], '|'))
                    .dash
                else if (isDelimiter(values[index], '^'))
                    .prefix
                else if (isDelimiter(values[index], '$'))
                    .suffix
                else if (isDelimiter(values[index], '*'))
                    .substring
                else
                    return error.InvalidSelector;
                equal_index = skipComments(values, index + 1, values.len);
                if (equal_index >= values.len or !isDelimiter(values[equal_index], '=')) return error.InvalidSelector;
            }
            matcher = .{
                .kind = kind,
                .span = makeSpan(values[operator_start].span().source, values[operator_start].span().start, values[equal_index].span().end),
            };
            index = scanTrivia(values, equal_index + 1, values.len).next;
            if (index >= values.len) return error.InvalidSelector;
            const value_token = tokenAt(values[index]) orelse return error.InvalidSelector;
            if (value_token.kind == .ident) {
                attribute_value = .{ .identifier = try self.identifier(value_token) };
            } else if (value_token.kind == .string and value_token.isTerminated()) {
                const decoded = try self.decode(value_token);
                const value_span = value_token.valueSpan() orelse return error.InvalidSelector;
                attribute_value = .{ .string = .{
                    .value = decoded,
                    .quote = if (self.file.bytes[value_token.span.start] == '\'') .single else .double,
                    .span = value_token.span,
                    .value_span = value_span,
                } };
            } else return error.InvalidSelector;
            index = scanTrivia(values, index + 1, values.len).next;
            if (index < values.len) {
                const modifier_token = tokenAt(values[index]) orelse return error.InvalidSelector;
                if (modifier_token.kind != .ident) return error.InvalidSelector;
                const modifier_identifier = try self.identifier(modifier_token);
                modifier = if (std.ascii.eqlIgnoreCase(modifier_identifier.value, "i"))
                    .{ .insensitive = modifier_token.span }
                else if (std.ascii.eqlIgnoreCase(modifier_identifier.value, "s"))
                    .{ .sensitive = modifier_token.span }
                else
                    return error.InvalidSelector;
                index = scanTrivia(values, index + 1, values.len).next;
            }
        }
        if (index != values.len) return error.InvalidSelector;

        const attribute = self.allocator.create(ast.AttributeSelector) catch return error.OutOfMemory;
        attribute.* = ast.AttributeSelector.init(.{
            .namespace = namespace,
            .name = try self.identifier(name_token),
            .matcher = matcher,
            .value = attribute_value,
            .modifier = modifier,
            .span = block.span,
        }) catch return error.InvalidSelector;
        return .{ .simple = .{ .attribute = attribute }, .next = outer_index + 1 };
    }

    fn parsePseudo(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        end: usize,
        depth: usize,
        selector_context: SelectorContext,
    ) Error!ParsedSimple {
        const first_colon = tokenAt(values[start]).?;
        var index = skipComments(values, start + 1, end);
        if (index >= end) return error.InvalidSelector;
        var is_element = false;
        if (tokenAt(values[index])) |token| {
            if (token.kind == .colon) {
                is_element = true;
                index = skipComments(values, index + 1, end);
                if (index >= end) return error.InvalidSelector;
            }
        }

        var name: ast.Identifier = undefined;
        var arguments: ?ast.PseudoArguments = null;
        var pseudo_end: usize = undefined;
        switch (values[index]) {
            .token => |token| {
                if (token.kind != .ident) return error.InvalidSelector;
                name = try self.identifier(token);
                if (isTypedSelectorFunction(name.value)) return error.InvalidSelector;
                pseudo_end = token.span.end;
            },
            .function => |function| {
                if (!function.terminated()) return error.InvalidSelector;
                name = try self.identifier(function.opening);
                if (selector_context.inside_has and std.ascii.eqlIgnoreCase(name.value, "has")) {
                    return error.InvalidSelector;
                }
                const closing = function.closing.?;
                const argument_span = makeSpan(
                    function.span.source,
                    function.opening.span.end,
                    closing.span.start,
                );
                var parsed: ?ast.ParsedPseudoArguments = null;
                if (selectorContextForPseudo(name.value, is_element, selector_context)) |nested_context| {
                    const list = try self.parseList(
                        function.values,
                        argument_span,
                        depth + 1,
                        nested_context,
                    );
                    parsed = .{ .selector_list = list };
                }
                arguments = .{
                    .span = argument_span,
                    .values = function.values,
                    .parsed = parsed,
                };
                pseudo_end = function.span.end;
            },
            else => return error.InvalidSelector,
        }

        const pseudo_span = makeSpan(first_colon.span.source, first_colon.span.start, pseudo_end);
        if (!is_element and arguments == null and isLegacyPseudoElement(name.value)) {
            is_element = true;
        }
        if (is_element and selector_context.disallow_pseudo_elements) return error.InvalidSelector;
        if (is_element) {
            const pseudo = self.allocator.create(ast.PseudoElement) catch return error.OutOfMemory;
            pseudo.* = .{ .name = name, .arguments = arguments, .span = pseudo_span };
            return .{ .simple = .{ .pseudo_element = pseudo }, .next = index + 1 };
        }
        const pseudo = self.allocator.create(ast.PseudoClass) catch return error.OutOfMemory;
        pseudo.* = .{ .name = name, .arguments = arguments, .span = pseudo_span };
        return .{ .simple = .{ .pseudo_class = pseudo }, .next = index + 1 };
    }

    fn identifier(self: *Parser, token: tokenizer.Token) Error!ast.Identifier {
        const value_span = token.valueSpan() orelse return error.InvalidSelector;
        return .{ .value = try self.decode(token), .span = value_span };
    }

    fn decode(self: *Parser, token: tokenizer.Token) Error![]const u8 {
        return token.decodedTextAlloc(self.allocator, self.file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSelector,
        };
    }

    fn report(
        self: *Parser,
        code: diagnostics.Code,
        span: source.Span,
        message: []const u8,
    ) std.mem.Allocator.Error!void {
        if (self.suppressed_diagnostics > 0 and code != .resource_limit and code != .internal) return;
        self.context.report(.err, code, span, message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
    }
};

fn selectorContextForPseudo(
    name: []const u8,
    is_element: bool,
    parent: SelectorContext,
) ?SelectorContext {
    if (is_element) return null;
    if (std.ascii.eqlIgnoreCase(name, "is") or std.ascii.eqlIgnoreCase(name, "where")) {
        return .{
            .forgiving = true,
            .disallow_pseudo_elements = true,
            .inside_has = parent.inside_has,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "not")) {
        return .{
            .disallow_pseudo_elements = true,
            .inside_has = parent.inside_has,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "has")) {
        return .{
            .allow_relative = true,
            .disallow_pseudo_elements = true,
            .inside_has = true,
        };
    }
    return null;
}

fn isTypedSelectorFunction(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "is") or
        std.ascii.eqlIgnoreCase(name, "where") or
        std.ascii.eqlIgnoreCase(name, "not") or
        std.ascii.eqlIgnoreCase(name, "has");
}

fn isLegacyPseudoElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "before") or
        std.ascii.eqlIgnoreCase(name, "after") or
        std.ascii.eqlIgnoreCase(name, "first-line") or
        std.ascii.eqlIgnoreCase(name, "first-letter");
}

fn isAllowedAfterPseudoElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "is") or
        std.ascii.eqlIgnoreCase(name, "where") or
        std.ascii.eqlIgnoreCase(name, "not") or
        std.ascii.eqlIgnoreCase(name, "hover") or
        std.ascii.eqlIgnoreCase(name, "active") or
        std.ascii.eqlIgnoreCase(name, "focus") or
        std.ascii.eqlIgnoreCase(name, "focus-visible") or
        std.ascii.eqlIgnoreCase(name, "focus-within");
}

fn tokenAt(value: syntax.ComponentValue) ?tokenizer.Token {
    return switch (value) {
        .token => |token| token,
        else => null,
    };
}

fn isDelimiter(value: syntax.ComponentValue, expected: u21) bool {
    const token = tokenAt(value) orelse return false;
    if (token.kind != .delim) return false;
    return switch (token.data) {
        .delim => |delimiter| delimiter == expected,
        else => false,
    };
}

fn containsNestingDelimiter(values: []const syntax.ComponentValue) bool {
    for (values) |value| switch (value) {
        .token => if (isDelimiter(value, '&')) return true,
        .simple_block => |block| if (containsNestingDelimiter(block.values)) return true,
        .function => |function| if (containsNestingDelimiter(function.values)) return true,
    };
    return false;
}

fn isTypeName(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .ident or isDelimiter(value, '*');
}

fn isTokenKind(value: syntax.ComponentValue, kind: tokenizer.TokenKind) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == kind;
}

fn isComma(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .comma;
}

fn isWhitespace(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .whitespace;
}

fn isComment(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .comment;
}

fn isTrivia(value: syntax.ComponentValue) bool {
    return isWhitespace(value) or isComment(value);
}

fn skipComments(values: []const syntax.ComponentValue, start: usize, end: usize) usize {
    var index = start;
    while (index < end and isComment(values[index])) index += 1;
    return index;
}

fn scanTrivia(values: []const syntax.ComponentValue, start: usize, end: usize) TriviaScan {
    var index = start;
    var saw_whitespace = false;
    while (index < end and isTrivia(values[index])) : (index += 1) {
        saw_whitespace = saw_whitespace or isWhitespace(values[index]);
    }
    return .{ .next = index, .saw_whitespace = saw_whitespace };
}

fn trimTriviaStart(values: []const syntax.ComponentValue, start: usize, end: usize) usize {
    return scanTrivia(values, start, end).next;
}

fn trimTriviaEnd(values: []const syntax.ComponentValue, start: usize, end: usize) usize {
    var index = end;
    while (index > start and isTrivia(values[index - 1])) index -= 1;
    return index;
}

fn parseExplicitCombinator(
    values: []const syntax.ComponentValue,
    start: usize,
    end: usize,
) ?ExplicitCombinator {
    if (start >= end) return null;
    if (isDelimiter(values[start], '>')) return .{ .kind = .child, .next = start + 1 };
    if (isDelimiter(values[start], '+')) return .{ .kind = .next_sibling, .next = start + 1 };
    if (isDelimiter(values[start], '~')) return .{ .kind = .subsequent_sibling, .next = start + 1 };
    return null;
}

fn compoundHasPseudoElement(compound: ast.CompoundSelector) bool {
    for (compound.simple_selectors) |simple| {
        if (simple == .pseudo_element) return true;
    }
    return false;
}

fn makeSpan(source_id: source.SourceId, start: usize, end: usize) source.Span {
    return .{ .source = source_id, .start = start, .end = end };
}

fn spanSource(values: []const syntax.ComponentValue, index: usize) source.SourceId {
    return values[index].span().source;
}

fn parseSource(
    context: *compilation.Compilation,
    name: []const u8,
    css: []const u8,
) !struct { source.SourceId, *const ast.SelectorList } {
    const id = try context.addSource(name, css);
    const document = try syntax.parse(context, id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    return .{ id, try parse(context, id, values) };
}

test "selector lists distinguish adjacency and standard combinators" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "combinators.css",
        ".a.b, .a .b, ul > li + li ~ li",
    );
    const file = try context.sources.get(parsed[0]);
    const list = parsed[1];

    try std.testing.expectEqual(@as(usize, 3), list.selectors.len);
    try std.testing.expectEqual(@as(usize, 2), list.selectors[0].head.simple_selectors.len);
    try std.testing.expectEqual(@as(usize, 0), list.selectors[0].tails.len);
    try std.testing.expectEqual(@as(usize, 1), list.selectors[1].tails.len);
    try std.testing.expectEqual(ast.CombinatorKind.descendant, list.selectors[1].tails[0].combinator.kind);
    try std.testing.expectEqual(ast.CombinatorKind.child, list.selectors[2].tails[0].combinator.kind);
    try std.testing.expectEqual(ast.CombinatorKind.next_sibling, list.selectors[2].tails[1].combinator.kind);
    try std.testing.expectEqual(ast.CombinatorKind.subsequent_sibling, list.selectors[2].tails[2].combinator.kind);
    try std.testing.expectEqualStrings(".a.b", try file.slice(list.selectors[0].span));
    try std.testing.expectEqualStrings(".a .b", try file.slice(list.selectors[1].span));
}

test "type and attribute selectors preserve namespaces values operators and flags" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "attributes.css",
        "svg|a[*|href^=\"https\" i][|lang|=en s][lang|=\"zh\"]",
    );
    const simple = parsed[1].selectors[0].head.simple_selectors;

    try std.testing.expectEqual(@as(usize, 4), simple.len);
    try std.testing.expect(simple[0] == .type_selector);
    try std.testing.expect(simple[0].type_selector.namespace == .named);
    try std.testing.expectEqualStrings("svg", simple[0].type_selector.namespace.named.value);
    try std.testing.expectEqualStrings("a", simple[0].type_selector.name.value);

    const href = simple[1].attribute;
    try std.testing.expect(href.namespace == .any);
    try std.testing.expectEqual(ast.AttributeMatcherKind.prefix, href.matcher.?.kind);
    try std.testing.expectEqualStrings("https", href.value.?.string.value);
    try std.testing.expectEqual(ast.QuoteStyle.double, href.value.?.string.quote);
    try std.testing.expect(href.modifier.? == .insensitive);

    const lang = simple[2].attribute;
    try std.testing.expect(lang.namespace == .empty);
    try std.testing.expectEqual(ast.AttributeMatcherKind.dash, lang.matcher.?.kind);
    try std.testing.expectEqualStrings("en", lang.value.?.identifier.value);
    try std.testing.expect(lang.modifier.? == .sensitive);

    const unprefixed_lang = simple[3].attribute;
    try std.testing.expect(unprefixed_lang.namespace == .implicit);
    try std.testing.expectEqual(ast.AttributeMatcherKind.dash, unprefixed_lang.matcher.?.kind);
    try std.testing.expectEqualStrings("zh", unprefixed_lang.value.?.string.value);
}

test "universal and empty namespace type forms remain distinct" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "namespaces.css", "*|*, |a, ns|*, *");
    const selectors = parsed[1].selectors;

    try std.testing.expect(selectors[0].head.simple_selectors[0] == .universal);
    try std.testing.expect(selectors[0].head.simple_selectors[0].universal.namespace == .any);
    try std.testing.expect(selectors[1].head.simple_selectors[0] == .type_selector);
    try std.testing.expect(selectors[1].head.simple_selectors[0].type_selector.namespace == .empty);
    try std.testing.expect(selectors[2].head.simple_selectors[0] == .universal);
    try std.testing.expect(selectors[2].head.simple_selectors[0].universal.namespace == .named);
    try std.testing.expect(selectors[3].head.simple_selectors[0].universal.namespace == .implicit);
}

test "functional pseudos retain raw arguments and parse selector-taking forms" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "pseudos.css",
        ".card:is(.a, .b > [x]):has(> img, + .icon):not(:where(.x))::before",
    );
    const simple = parsed[1].selectors[0].head.simple_selectors;

    try std.testing.expectEqual(@as(usize, 5), simple.len);
    const is_pseudo = simple[1].pseudo_class;
    try std.testing.expectEqualStrings("is", is_pseudo.name.value);
    try std.testing.expect(is_pseudo.arguments.?.values.len > 0);
    try std.testing.expectEqual(@as(usize, 2), is_pseudo.arguments.?.parsed.?.selector_list.selectors.len);
    try std.testing.expectEqual(
        ast.CombinatorKind.child,
        is_pseudo.arguments.?.parsed.?.selector_list.selectors[1].tails[0].combinator.kind,
    );

    const has = simple[2].pseudo_class.arguments.?.parsed.?.selector_list;
    try std.testing.expectEqual(ast.CombinatorKind.child, has.selectors[0].leading_combinator.?.kind);
    try std.testing.expectEqual(ast.CombinatorKind.next_sibling, has.selectors[1].leading_combinator.?.kind);
    const not = simple[3].pseudo_class.arguments.?.parsed.?.selector_list;
    try std.testing.expect(not.selectors[0].head.simple_selectors[0] == .pseudo_class);
    try std.testing.expect(not.selectors[0].head.simple_selectors[0].pseudo_class.arguments.?.parsed != null);
    try std.testing.expect(simple[4] == .pseudo_element);
    try std.testing.expectEqualStrings("before", simple[4].pseudo_element.name.value);
}

test "comments do not create descendants but whitespace does" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "trivia.css",
        ".a/**/.b .c/*x*/>.d",
    );
    const file = try context.sources.get(parsed[0]);
    const selector = parsed[1].selectors[0];

    try std.testing.expectEqual(@as(usize, 2), selector.head.simple_selectors.len);
    try std.testing.expectEqual(@as(usize, 2), selector.tails.len);
    try std.testing.expectEqual(ast.CombinatorKind.descendant, selector.tails[0].combinator.kind);
    try std.testing.expectEqual(ast.CombinatorKind.child, selector.tails[1].combinator.kind);
    try std.testing.expectEqualStrings(".a/**/.b", try file.slice(selector.head.span));
    try std.testing.expectEqualStrings(" ", try file.slice(selector.tails[0].combinator.span));
    try std.testing.expectEqualStrings("/*x*/>", try file.slice(selector.tails[1].combinator.span));
}

test "escaped selector names are decoded without losing source spelling" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "escapes.css", ".\\31 23#\\66 oo");
    const file = try context.sources.get(parsed[0]);
    const simple = parsed[1].selectors[0].head.simple_selectors;

    try std.testing.expectEqualStrings("123", simple[0].class.name.value);
    try std.testing.expectEqualStrings("foo", simple[1].id.name.value);
    try std.testing.expectEqualStrings(".\\31 23#\\66 oo", try file.slice(parsed[1].selectors[0].span));
}

test "legacy pseudo elements and untyped functional pseudos keep correct categories" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "legacy-pseudos.css",
        "a:before, a:nth-child(2n + 1 of .x)",
    );
    const legacy = parsed[1].selectors[0].head.simple_selectors;
    const functional = parsed[1].selectors[1].head.simple_selectors;

    try std.testing.expect(legacy[1] == .pseudo_element);
    try std.testing.expectEqualStrings("before", legacy[1].pseudo_element.name.value);
    try std.testing.expect(functional[1] == .pseudo_class);
    try std.testing.expectEqualStrings("nth-child", functional[1].pseudo_class.name.value);
    try std.testing.expect(functional[1].pseudo_class.arguments.?.parsed == null);
    try std.testing.expect(functional[1].pseudo_class.arguments.?.values.len > 0);
}

test "is and where use forgiving lists while strict selector pseudos do not" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "forgiving.css",
        ":is(.a, ., ::before, .b):where()",
    );
    const simple = parsed[1].selectors[0].head.simple_selectors;
    const is_list = simple[0].pseudo_class.arguments.?.parsed.?.selector_list;
    const where_list = simple[1].pseudo_class.arguments.?.parsed.?.selector_list;

    try std.testing.expectEqual(@as(usize, 2), is_list.selectors.len);
    try std.testing.expectEqual(@as(usize, 0), where_list.selectors.len);
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

test "Selectors Level 4 grammar examples parse as typed selector lists" {
    const cases = [_][]const u8{
        "*",
        "E",
        "E.warning",
        "E#myid",
        "E[foo]",
        "E[foo=\"bar\"]",
        "E:first-child",
        "E::before",
        "E > F",
        "E + F",
        "E ~ F",
        "E F",
        ":is(ul, ol)",
        ":where()",
        "a::before:hover",
    };
    for (cases) |css| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const parsed = try parseSource(&context, "selectors-4.css", css);
        try std.testing.expect(parsed[1].selectors.len > 0);
        try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
    }
}

test "CSS Nesting selectors distinguish implied and explicit parent references" {
    const cases = [_]struct {
        css: []const u8,
        implicit_nesting: bool,
    }{
        .{ .css = ".child", .implicit_nesting = true },
        .{ .css = "> .child", .implicit_nesting = true },
        .{ .css = "&.active", .implicit_nesting = false },
        .{ .css = ".ancestor &", .implicit_nesting = false },
        .{ .css = ":future(&)", .implicit_nesting = false },
        .{ .css = "div&", .implicit_nesting = false },
        .{ .css = "&&", .implicit_nesting = false },
    };
    for (cases) |case| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const id = try context.addSource("nested-selector.css", case.css);
        const document = try syntax.parse(&context, id);
        const values = try ast.ComponentValueList.init(document.span, document.values);
        const parsed = try parseNested(&context, id, values);

        try std.testing.expectEqual(@as(usize, 1), parsed.selectors.len);
        try std.testing.expectEqual(case.implicit_nesting, parsed.selectors[0].implicit_nesting);
        try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
    }

    var scope_context = try compilation.Compilation.init(std.testing.allocator);
    defer scope_context.deinit();
    const scope_id = try scope_context.addSource("scope-selector.css", "&");
    const scope_document = try syntax.parse(&scope_context, scope_id);
    const scope_values = try ast.ComponentValueList.init(scope_document.span, scope_document.values);
    const scope = try parse(&scope_context, scope_id, scope_values);
    try std.testing.expect(!scope.selectors[0].implicit_nesting);
    try std.testing.expect(scope.selectors[0].head.simple_selectors[0] == .nesting);
}

test "CSS Nesting keeps type selectors first in a compound" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("invalid-nested-type.css", "&div");
    const document = try syntax.parse(&context, id);
    const values = try ast.ComponentValueList.init(document.span, document.values);

    try std.testing.expectError(error.InvalidSelector, parseNested(&context, id, values));
    try std.testing.expectEqual(@as(usize, 1), context.diagnostics.items().len);
}

test "WPT CSS Nesting selector parsing matrix remains accepted" {
    const selectors = [_][]const u8{
        "&",
        "&.bar",
        "& .bar",
        "& > .bar",
        "> .bar",
        "> & .bar",
        "+ .bar &",
        "+ .bar, .foo, > .baz",
        ".foo",
        ".test > & .bar",
        ".foo, .foo &",
        ".foo, .bar",
        ":is(.bar, .baz)",
        "&:is(.bar, .baz)",
        ":is(.bar, &.baz)",
        "&:is(.bar, &.baz)",
        "div&",
        ".class&",
        "&.class",
        "[attr]&",
        "&[attr]",
        "#id&",
        "&#id",
        ":hover&",
        "&:hover",
        ":is(div)&",
        "&:is(div)",
        "& .bar & .baz & .qux",
        "&&",
        "& > section, & > article",
        "& + .baz, &.qux",
    };
    for (selectors) |selector| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const id = try context.addSource("wpt-nesting-selector.css", selector);
        const document = try syntax.parse(&context, id);
        const values = try ast.ComponentValueList.init(document.span, document.values);
        const parsed = try parseNested(&context, id, values);

        try std.testing.expect(parsed.selectors.len > 0);
        try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
    }
}

test "invalid selector boundaries report diagnostics without partial success" {
    const cases = [_][]const u8{
        ".",
        "[x=]",
        ":",
        ".a,,.b",
        "|| .x",
        "[x=y q]",
        ".x||.y",
        ":has(.a, .)",
        ":has(:has(.x))",
        ":not(::before)",
        "a::before > b",
        "a::before:nth-child(2)",
        ":is",
    };
    for (cases) |css| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const id = try context.addSource("invalid.css", css);
        const document = try syntax.parse(&context, id);
        const values = try ast.ComponentValueList.init(document.span, document.values);
        try std.testing.expectError(error.InvalidSelector, parse(&context, id, values));
        try std.testing.expect(context.diagnostics.items().len > 0);
    }
}

test "nested strict selector failures emit one synchronized diagnostic" {
    const cases = [_][]const u8{ ":not(.a,)", ".root > :not(.a,)" };
    for (cases) |css| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const id = try context.addSource("nested-diagnostic.css", css);
        const document = try syntax.parse(&context, id);
        const values = try ast.ComponentValueList.init(document.span, document.values);

        try std.testing.expectError(error.InvalidSelector, parse(&context, id, values));
        try std.testing.expectEqual(@as(usize, 1), context.diagnostics.items().len);
        try std.testing.expectEqualStrings("empty selector in selector list", context.diagnostics.items()[0].message);
    }
}

test "selector recursion is bounded independently of component parsing" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("deep-selector.css", ":is(:is(:is(.x)))");
    const document = try syntax.parse(&context, id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    try std.testing.expectError(
        error.SelectorNestingLimit,
        parseWithOptions(&context, id, values, .{ .max_nesting = 2 }),
    );
}

fn exerciseSelectorAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "oom-selector.css",
        "svg|a.card:is(.x, .y > [data-v^=\"z\" i]):has(+ #id)",
    );
    try std.testing.expectEqual(@as(usize, 1), parsed[1].selectors.len);
}

test "selector lowering handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSelectorAllocationFailures,
        .{},
    );
}
