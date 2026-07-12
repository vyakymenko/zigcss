const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const declaration_parser = @import("declaration_parser.zig");
const diagnostics = @import("../diagnostics.zig");
const recovery = @import("recovery.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = declaration_parser.Error;

/// Adds standards-oriented typed views to at-rules whose generic, lossless AST
/// has already been built. Invalid typed syntax is diagnosed and deliberately
/// leaves `details` null; the raw prelude and block always remain available.
pub fn specialize(
    context: *compilation.Compilation,
    file: *const source.SourceFile,
    at_rule: *ast.AtRule,
) Error!void {
    if (!at_rule.span.source.eql(file.id)) return error.InvalidInput;
    var parser = Parser{
        .allocator = context.arenaAllocator(),
        .context = context,
        .file = file,
    };

    if (std.ascii.eqlIgnoreCase(at_rule.name.value, "media")) {
        at_rule.details = if (try parser.parseMedia(at_rule)) |details| .{ .media = details } else null;
    } else if (std.ascii.eqlIgnoreCase(at_rule.name.value, "supports")) {
        at_rule.details = if (try parser.parseSupports(at_rule)) |details| .{ .supports = details } else null;
    } else if (std.ascii.eqlIgnoreCase(at_rule.name.value, "container")) {
        at_rule.details = if (try parser.parseContainer(at_rule)) |details| .{ .container = details } else null;
    } else if (std.ascii.eqlIgnoreCase(at_rule.name.value, "layer")) {
        at_rule.details = if (try parser.parseLayer(at_rule)) |details| .{ .layer = details } else null;
    } else if (std.ascii.eqlIgnoreCase(at_rule.name.value, "property")) {
        at_rule.details = if (try parser.parseProperty(at_rule)) |details| .{ .property = details } else null;
    } else if (std.ascii.eqlIgnoreCase(at_rule.name.value, "font-face")) {
        at_rule.details = if (try parser.parseFontFace(at_rule)) |details| .{ .font_face = details } else null;
    } else if (std.ascii.eqlIgnoreCase(at_rule.name.value, "keyframes") or
        std.ascii.eqlIgnoreCase(at_rule.name.value, "-webkit-keyframes") or
        std.ascii.eqlIgnoreCase(at_rule.name.value, "-moz-keyframes"))
    {
        at_rule.details = if (try parser.parseKeyframes(at_rule)) |details| .{ .keyframes = details } else null;
    } else if (std.ascii.eqlIgnoreCase(at_rule.name.value, "page")) {
        at_rule.details = if (try parser.parsePage(at_rule)) |details| .{ .page = details } else null;
    }
}

const Range = struct {
    start: usize,
    end: usize,

    fn empty(self: Range) bool {
        return self.start == self.end;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    context: *compilation.Compilation,
    file: *const source.SourceFile,

    fn parseMedia(self: *Parser, at_rule: *const ast.AtRule) Error!?*const ast.MediaRule {
        const block = switch (at_rule.block) {
            .rules => |value| value,
            else => {
                try self.invalid(at_rule.span, "@media requires a rule block");
                return null;
            },
        };
        const significant = trim(at_rule.prelude.values, 0, at_rule.prelude.values.len);
        if (significant.empty()) {
            try self.invalid(at_rule.prelude.span, "@media requires a non-empty query list");
            return null;
        }

        var queries = try std.ArrayList(ast.ComponentValueList).initCapacity(self.allocator, 0);
        errdefer queries.deinit(self.allocator);
        var segment_start = significant.start;
        var index = significant.start;
        while (index <= significant.end) : (index += 1) {
            if (index != significant.end and !isTokenKind(at_rule.prelude.values[index], .comma)) continue;
            const query_range = trim(at_rule.prelude.values, segment_start, index);
            if (query_range.empty()) {
                try self.invalid(at_rule.prelude.span, "@media query lists cannot contain an empty query");
                return null;
            }
            try queries.append(self.allocator, try self.componentList(at_rule.prelude.values, query_range));
            segment_start = index + 1;
        }

        const query_list = ast.MediaQueryList{
            .queries = try queries.toOwnedSlice(self.allocator),
            .span = spanOf(at_rule.prelude.values, significant, at_rule.prelude.span),
        };
        const details = try self.allocator.create(ast.MediaRule);
        details.* = .{ .query_list = query_list, .block = block };
        return details;
    }

    fn parseSupports(self: *Parser, at_rule: *const ast.AtRule) Error!?*const ast.SupportsRule {
        const block = switch (at_rule.block) {
            .rules => |value| value,
            else => {
                try self.invalid(at_rule.span, "@supports requires a rule block");
                return null;
            },
        };
        const values = at_rule.prelude.values;
        const full_significant = trim(values, 0, values.len);
        var significant = full_significant;
        if (full_significant.empty()) {
            try self.invalid(at_rule.prelude.span, "@supports requires a condition");
            return null;
        }

        var negated = false;
        if (try self.isKeyword(values[significant.start], "not")) {
            negated = true;
            significant.start = skipTrivia(values, significant.start + 1, significant.end);
            if (significant.empty()) {
                try self.invalid(at_rule.prelude.span, "@supports 'not' requires a condition");
                return null;
            }
        }

        var terms = try std.ArrayList(ast.ComponentValueList).initCapacity(self.allocator, 0);
        errdefer terms.deinit(self.allocator);
        var operator: ast.SupportsOperator = .none;
        var segment_start = significant.start;
        var index = significant.start;
        while (index < significant.end) : (index += 1) {
            const candidate: ?ast.SupportsOperator = if (try self.isKeyword(values[index], "and"))
                .@"and"
            else if (try self.isKeyword(values[index], "or"))
                .@"or"
            else
                null;
            const found = candidate orelse continue;
            if (negated or (operator != .none and operator != found)) {
                try self.invalid(values[index].span(), "@supports cannot mix or combine condition operators at one level");
                return null;
            }
            const term_range = trim(values, segment_start, index);
            if (term_range.empty()) {
                try self.invalid(values[index].span(), "@supports condition operator is missing a left operand");
                return null;
            }
            try terms.append(self.allocator, try self.componentList(values, term_range));
            operator = found;
            segment_start = index + 1;
        }
        const final_range = trim(values, segment_start, significant.end);
        if (final_range.empty()) {
            try self.invalid(at_rule.prelude.span, "@supports condition operator is missing a right operand");
            return null;
        }
        try terms.append(self.allocator, try self.componentList(values, final_range));

        const details = try self.allocator.create(ast.SupportsRule);
        details.* = .{
            .negated = negated,
            .operator = operator,
            .terms = try terms.toOwnedSlice(self.allocator),
            .span = spanOf(values, full_significant, at_rule.prelude.span),
            .block = block,
        };
        return details;
    }

    fn parseContainer(self: *Parser, at_rule: *const ast.AtRule) Error!?*const ast.ContainerRule {
        const block = switch (at_rule.block) {
            .rules => |value| value,
            else => {
                try self.invalid(at_rule.span, "@container requires a rule block");
                return null;
            },
        };
        const values = at_rule.prelude.values;
        const significant = trim(values, 0, values.len);
        if (significant.empty()) {
            try self.invalid(at_rule.prelude.span, "@container requires a query");
            return null;
        }

        var name: ?ast.Identifier = null;
        var query_range = significant;
        if (tokenAt(values[significant.start])) |token| {
            if (token.kind == .ident and !try self.isReservedContainerName(token)) {
                const after_name = skipTrivia(values, significant.start + 1, significant.end);
                if (after_name < significant.end) {
                    name = try self.identifier(token);
                    query_range.start = after_name;
                }
            }
        }
        query_range = trim(values, query_range.start, query_range.end);
        if (query_range.empty()) {
            try self.invalid(at_rule.prelude.span, "@container requires a query after its name");
            return null;
        }

        const details = try self.allocator.create(ast.ContainerRule);
        details.* = .{
            .name = name,
            .query = try self.componentList(values, query_range),
            .span = spanOf(values, significant, at_rule.prelude.span),
            .block = block,
        };
        return details;
    }

    fn parseLayer(self: *Parser, at_rule: *const ast.AtRule) Error!?*const ast.LayerRule {
        const statement = switch (at_rule.block) {
            .none => true,
            .rules => false,
            else => {
                try self.invalid(at_rule.span, "@layer accepts only a statement or a rule block");
                return null;
            },
        };
        const values = at_rule.prelude.values;
        const significant = trim(values, 0, values.len);
        if (significant.empty()) {
            if (statement) {
                try self.invalid(at_rule.prelude.span, "an @layer statement requires at least one layer name");
                return null;
            }
            const details = try self.allocator.create(ast.LayerRule);
            details.* = .{ .names = &.{}, .statement = false, .span = at_rule.prelude.span };
            return details;
        }

        var names = try std.ArrayList(ast.LayerName).initCapacity(self.allocator, 0);
        errdefer names.deinit(self.allocator);
        var segment_start = significant.start;
        var index = significant.start;
        while (index <= significant.end) : (index += 1) {
            if (index != significant.end and !isTokenKind(values[index], .comma)) continue;
            const name_range = trim(values, segment_start, index);
            const name = (try self.parseLayerName(values, name_range)) orelse {
                try self.invalid(spanOf(values, name_range, at_rule.prelude.span), "invalid @layer name");
                return null;
            };
            try names.append(self.allocator, name);
            segment_start = index + 1;
        }
        if (!statement and names.items.len != 1) {
            try self.invalid(at_rule.prelude.span, "an @layer block accepts at most one layer name");
            return null;
        }

        const details = try self.allocator.create(ast.LayerRule);
        details.* = .{
            .names = try names.toOwnedSlice(self.allocator),
            .statement = statement,
            .span = spanOf(values, significant, at_rule.prelude.span),
        };
        return details;
    }

    fn parseProperty(self: *Parser, at_rule: *const ast.AtRule) Error!?*const ast.PropertyRule {
        const block = switch (at_rule.block) {
            .declarations => |value| value,
            else => {
                try self.invalid(at_rule.span, "@property requires a declaration block");
                return null;
            },
        };
        const values = at_rule.prelude.values;
        const significant = trim(values, 0, values.len);
        if (countSignificant(values, significant) != 1) {
            try self.invalid(at_rule.prelude.span, "@property requires exactly one custom property name");
            return null;
        }
        const token = tokenAt(values[significant.start]) orelse {
            try self.invalid(values[significant.start].span(), "@property name must be an identifier");
            return null;
        };
        if (token.kind != .ident) {
            try self.invalid(token.span, "@property name must be an identifier");
            return null;
        }
        const name = try self.identifier(token);
        if (!name.isCustomProperty()) {
            try self.invalid(name.span, "@property name must begin with '--'");
            return null;
        }

        const details = try self.allocator.create(ast.PropertyRule);
        details.* = .{ .name = name, .declarations = &block.declarations, .span = at_rule.span };
        return details;
    }

    fn parseFontFace(self: *Parser, at_rule: *const ast.AtRule) Error!?*const ast.FontFaceRule {
        const block = switch (at_rule.block) {
            .declarations => |value| value,
            else => {
                try self.invalid(at_rule.span, "@font-face requires a declaration block");
                return null;
            },
        };
        if (!trim(at_rule.prelude.values, 0, at_rule.prelude.values.len).empty()) {
            try self.invalid(at_rule.prelude.span, "@font-face does not accept a prelude");
            return null;
        }

        const details = try self.allocator.create(ast.FontFaceRule);
        details.* = .{ .declarations = &block.declarations, .span = at_rule.span };
        return details;
    }

    fn parseKeyframes(self: *Parser, at_rule: *ast.AtRule) Error!?*const ast.KeyframesRule {
        const old_block = switch (at_rule.block) {
            .keyframes => |value| value,
            else => {
                try self.invalid(at_rule.span, "@keyframes requires a keyframe block");
                return null;
            },
        };
        const raw_values = old_block.raw_values orelse {
            try self.internal(old_block.envelope.span, "keyframes raw values were not retained");
            return error.InternalInvariant;
        };
        const name_range = trim(at_rule.prelude.values, 0, at_rule.prelude.values.len);
        if (countSignificant(at_rule.prelude.values, name_range) != 1) {
            try self.invalid(at_rule.prelude.span, "@keyframes requires exactly one animation name");
            return null;
        }
        const name_token = tokenAt(at_rule.prelude.values[name_range.start]) orelse {
            try self.invalid(at_rule.prelude.values[name_range.start].span(), "keyframes name must be an identifier or string");
            return null;
        };
        if (name_token.kind != .ident and name_token.kind != .string) {
            try self.invalid(name_token.span, "keyframes name must be an identifier or string");
            return null;
        }
        const name = try self.identifier(name_token);
        if (std.ascii.eqlIgnoreCase(name.value, "none")) {
            try self.invalid(name.span, "'none' is not a valid keyframes name");
            return null;
        }

        var frames = try std.ArrayList(ast.KeyframeRule).initCapacity(self.allocator, 0);
        errdefer frames.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < raw_values.values.len) {
            const boundary = recovery.scanRuleBoundary(raw_values.values, cursor);
            if (boundary.kind == .semicolon) {
                const end = boundary.next;
                const rejected = trim(raw_values.values, cursor, end);
                if (!rejected.empty()) {
                    try self.invalid(spanOf(raw_values.values, rejected, old_block.envelope.content), "invalid keyframe rule before ';'");
                }
                cursor = end;
                continue;
            }
            if (boundary.kind == .end) {
                const trailing = trim(raw_values.values, cursor, raw_values.values.len);
                if (!trailing.empty()) {
                    try self.invalid(spanOf(raw_values.values, trailing, old_block.envelope.content), "keyframe selector is missing a declaration block");
                }
                break;
            }

            const block_index = boundary.index;

            const prelude_range = Range{ .start = cursor, .end = block_index };
            const selector_range = trim(raw_values.values, cursor, block_index);
            const selectors = try self.parseKeyframeSelectors(raw_values.values, selector_range);
            if (selectors == null) {
                const invalid_span = if (selector_range.empty())
                    raw_values.values[block_index].span()
                else
                    spanOf(raw_values.values, selector_range, old_block.envelope.content);
                try self.invalid(invalid_span, "invalid keyframe selector list");
                cursor = block_index + 1;
                continue;
            }

            const syntax_block = raw_values.values[block_index].simple_block;
            const envelope = try self.blockSpan(syntax_block);
            if (prelude_range.empty()) {
                try self.invalid(envelope.opening, "keyframe selector list cannot be empty");
                cursor = block_index + 1;
                continue;
            }
            const prelude = try self.componentList(raw_values.values, prelude_range);
            const content = ast.ComponentValueList.init(envelope.content, syntax_block.values) catch {
                try self.internal(envelope.span, "keyframe content is not contiguous");
                return error.InternalInvariant;
            };
            const declarations = try declaration_parser.parse(self.context, self.file.id, content);
            const declaration_block = ast.DeclarationBlock.init(envelope, declarations.*) catch {
                try self.internal(envelope.span, "keyframe declaration block invariant failed");
                return error.InternalInvariant;
            };
            const frame = ast.KeyframeRule.init(.{
                .prelude = prelude,
                .selectors = selectors.?,
                .block = declaration_block,
                .span = .{
                    .source = self.file.id,
                    .start = prelude.span.start,
                    .end = envelope.span.end,
                },
            }) catch {
                try self.internal(envelope.span, "keyframe rule invariant failed");
                return error.InternalInvariant;
            };
            try frames.append(self.allocator, frame);
            cursor = block_index + 1;
        }

        const block = try self.allocator.create(ast.KeyframesBlock);
        block.* = ast.KeyframesBlock.initWithRaw(
            old_block.envelope,
            raw_values,
            try frames.toOwnedSlice(self.allocator),
        ) catch {
            try self.internal(old_block.envelope.span, "keyframes block invariant failed");
            return error.InternalInvariant;
        };
        at_rule.block = .{ .keyframes = block };

        const details = try self.allocator.create(ast.KeyframesRule);
        details.* = .{ .name = name, .block = block, .span = at_rule.span };
        return details;
    }

    fn parsePage(self: *Parser, at_rule: *const ast.AtRule) Error!?*const ast.PageRule {
        const raw_block = switch (at_rule.block) {
            .raw => |value| value,
            else => {
                try self.invalid(at_rule.span, "@page requires a page declaration block");
                return null;
            },
        };
        const selectors = (try self.parsePageSelectors(at_rule.prelude)) orelse return null;
        const values = raw_block.values.values;
        var declarations = try std.ArrayList(ast.Declaration).initCapacity(self.allocator, 0);
        errdefer declarations.deinit(self.allocator);
        var margins = try std.ArrayList(ast.PageMarginRule).initCapacity(self.allocator, 0);
        errdefer margins.deinit(self.allocator);

        var chunk_start: usize = 0;
        var index: usize = 0;
        while (index < values.len) {
            if (!isAtKeyword(values[index]) or !isAtRuleBoundary(values, chunk_start, index)) {
                index += 1;
                continue;
            }

            try self.appendDeclarationChunk(values, chunk_start, index, &declarations);
            const at_token = tokenAt(values[index]).?;
            const margin_name = try self.identifier(at_token);
            const block_index = skipTrivia(values, index + 1, values.len);
            if (isPageMarginName(margin_name.value) and
                block_index < values.len and
                isCurlyBlock(values[block_index]))
            {
                const syntax_block = values[block_index].simple_block;
                const envelope = try self.blockSpan(syntax_block);
                const content = ast.ComponentValueList.init(envelope.content, syntax_block.values) catch {
                    try self.internal(envelope.span, "page-margin content is not contiguous");
                    return error.InternalInvariant;
                };
                const margin_declarations = try declaration_parser.parse(self.context, self.file.id, content);
                try margins.append(self.allocator, .{
                    .name = margin_name,
                    .envelope = envelope,
                    .declarations = margin_declarations,
                    .span = .{
                        .source = self.file.id,
                        .start = at_token.span.start,
                        .end = envelope.span.end,
                    },
                });
                index = block_index + 1;
                chunk_start = index;
                continue;
            }

            const invalid_end = recovery.scanRuleBoundary(values, index + 1).next;
            const invalid_span: source.Span = .{
                .source = self.file.id,
                .start = at_token.span.start,
                .end = if (invalid_end > index) values[invalid_end - 1].span().end else at_token.span.end,
            };
            try self.invalid(invalid_span, "invalid or unsupported at-rule inside @page");
            index = invalid_end;
            chunk_start = index;
        }
        try self.appendDeclarationChunk(values, chunk_start, values.len, &declarations);

        const declaration_list = try self.allocator.create(ast.DeclarationList);
        declaration_list.* = ast.DeclarationList.init(
            raw_block.envelope.content,
            try declarations.toOwnedSlice(self.allocator),
        ) catch {
            try self.internal(raw_block.envelope.span, "page declaration-list invariant failed");
            return error.InternalInvariant;
        };
        const details = try self.allocator.create(ast.PageRule);
        details.* = .{
            .selectors = selectors,
            .declarations = declaration_list,
            .margins = try margins.toOwnedSlice(self.allocator),
            .span = at_rule.span,
        };
        return details;
    }

    fn parseKeyframeSelectors(
        self: *Parser,
        values: []const syntax.ComponentValue,
        range: Range,
    ) Error!?[]const ast.KeyframeSelector {
        if (range.empty()) return null;
        var selectors = try std.ArrayList(ast.KeyframeSelector).initCapacity(self.allocator, 0);
        errdefer selectors.deinit(self.allocator);
        var segment_start = range.start;
        var index = range.start;
        while (index <= range.end) : (index += 1) {
            if (index != range.end and !isTokenKind(values[index], .comma)) continue;
            const segment = trim(values, segment_start, index);
            if (countSignificant(values, segment) != 1) return null;
            const token = tokenAt(values[segment.start]) orelse return null;
            const selector: ast.KeyframeSelector = switch (token.kind) {
                .ident => blk: {
                    if (try self.tokenEquals(token, "from")) break :blk .{ .from = token.span };
                    if (try self.tokenEquals(token, "to")) break :blk .{ .to = token.span };
                    return null;
                },
                .percentage => blk: {
                    const numeric = switch (token.data) {
                        .numeric => |value| value,
                        else => return error.InvalidInput,
                    };
                    if (!std.math.isFinite(numeric.value) or numeric.value < 0 or numeric.value > 100) return null;
                    break :blk .{ .percentage = .{ .value = numeric.value, .span = token.span } };
                },
                else => return null,
            };
            try selectors.append(self.allocator, selector);
            segment_start = index + 1;
        }
        return try selectors.toOwnedSlice(self.allocator);
    }

    fn parsePageSelectors(
        self: *Parser,
        prelude: ast.ComponentValueList,
    ) Error!?[]const ast.PageSelector {
        const values = prelude.values;
        const significant = trim(values, 0, values.len);
        if (significant.empty()) return &.{};

        var selectors = try std.ArrayList(ast.PageSelector).initCapacity(self.allocator, 0);
        errdefer selectors.deinit(self.allocator);
        var segment_start = significant.start;
        var index = significant.start;
        while (index <= significant.end) : (index += 1) {
            if (index != significant.end and !isTokenKind(values[index], .comma)) continue;
            const selector_range = trim(values, segment_start, index);
            const selector = (try self.parsePageSelector(values, selector_range)) orelse {
                try self.invalid(spanOf(values, selector_range, prelude.span), "invalid @page selector");
                return null;
            };
            try selectors.append(self.allocator, selector);
            segment_start = index + 1;
        }
        return try selectors.toOwnedSlice(self.allocator);
    }

    fn parsePageSelector(
        self: *Parser,
        values: []const syntax.ComponentValue,
        range: Range,
    ) Error!?ast.PageSelector {
        if (range.empty()) return null;
        var index = range.start;
        var name: ?ast.Identifier = null;
        if (tokenAt(values[index])) |token| {
            if (token.kind == .ident) {
                name = try self.identifier(token);
                index += 1;
            }
        }

        var pseudos = try std.ArrayList(ast.Identifier).initCapacity(self.allocator, 0);
        errdefer pseudos.deinit(self.allocator);
        while (true) {
            index = skipTrivia(values, index, range.end);
            if (index == range.end) break;
            if (!isTokenKind(values[index], .colon)) return null;
            index = skipTrivia(values, index + 1, range.end);
            if (index == range.end) return null;
            const pseudo = tokenAt(values[index]) orelse return null;
            if (pseudo.kind != .ident) return null;
            try pseudos.append(self.allocator, try self.identifier(pseudo));
            index += 1;
        }
        if (name == null and pseudos.items.len == 0) return null;
        return .{
            .name = name,
            .pseudos = try pseudos.toOwnedSlice(self.allocator),
            .span = spanOf(values, range, self.file.fullSpan()),
        };
    }

    fn appendDeclarationChunk(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        end: usize,
        declarations: *std.ArrayList(ast.Declaration),
    ) Error!void {
        if (trim(values, start, end).empty()) return;
        const input = try self.componentList(values, .{ .start = start, .end = end });
        const parsed = try declaration_parser.parse(self.context, self.file.id, input);
        try declarations.appendSlice(self.allocator, parsed.declarations);
    }

    fn blockSpan(self: *Parser, block: *const syntax.SimpleBlock) Error!ast.BlockSpan {
        const content_end = if (block.closing) |closing| closing.span.start else block.span.end;
        return ast.BlockSpan.init(.{
            .opening = block.opening.span,
            .content = .{
                .source = self.file.id,
                .start = block.opening.span.end,
                .end = content_end,
            },
            .closing = if (block.closing) |closing| closing.span else null,
            .span = block.span,
        }) catch {
            try self.internal(block.span, "at-rule block span invariant failed");
            return error.InternalInvariant;
        };
    }

    fn parseLayerName(
        self: *Parser,
        values: []const syntax.ComponentValue,
        range: Range,
    ) Error!?ast.LayerName {
        if (range.empty()) return null;
        var parts = try std.ArrayList(ast.Identifier).initCapacity(self.allocator, 0);
        errdefer parts.deinit(self.allocator);
        var index = range.start;
        var expect_identifier = true;
        while (index < range.end) {
            index = skipTrivia(values, index, range.end);
            if (index == range.end) break;
            if (expect_identifier) {
                const token = tokenAt(values[index]) orelse return null;
                if (token.kind != .ident) return null;
                try parts.append(self.allocator, try self.identifier(token));
                expect_identifier = false;
            } else if (!isDelimiter(values[index], '.')) {
                return null;
            } else {
                expect_identifier = true;
            }
            index += 1;
        }
        if (expect_identifier or parts.items.len == 0) return null;
        return .{
            .parts = try parts.toOwnedSlice(self.allocator),
            .span = spanOf(values, range, self.file.fullSpan()),
        };
    }

    fn isReservedContainerName(self: *Parser, token: tokenizer.Token) Error!bool {
        return try self.tokenEquals(token, "none") or
            try self.tokenEquals(token, "and") or
            try self.tokenEquals(token, "or") or
            try self.tokenEquals(token, "not");
    }

    fn isKeyword(self: *Parser, value: syntax.ComponentValue, expected: []const u8) Error!bool {
        const token = tokenAt(value) orelse return false;
        if (token.kind != .ident) return false;
        return self.tokenEquals(token, expected);
    }

    fn tokenEquals(self: *Parser, token: tokenizer.Token, expected: []const u8) Error!bool {
        const decoded = try self.decode(token);
        return std.ascii.eqlIgnoreCase(decoded, expected);
    }

    fn identifier(self: *Parser, token: tokenizer.Token) Error!ast.Identifier {
        const value_span = token.valueSpan() orelse return error.InvalidInput;
        return .{ .value = try self.decode(token), .span = value_span };
    }

    fn decode(self: *Parser, token: tokenizer.Token) Error![]const u8 {
        return token.decodedTextAlloc(self.allocator, self.file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInput,
        };
    }

    fn componentList(
        self: *Parser,
        values: []const syntax.ComponentValue,
        range: Range,
    ) Error!ast.ComponentValueList {
        if (range.empty()) return error.InvalidInput;
        return ast.ComponentValueList.init(
            spanOf(values, range, self.file.fullSpan()),
            values[range.start..range.end],
        ) catch return error.InternalInvariant;
    }

    fn invalid(self: *Parser, span: source.Span, message: []const u8) std.mem.Allocator.Error!void {
        self.context.report(.err, .unexpected_token, span, message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
    }

    fn internal(self: *Parser, span: source.Span, message: []const u8) std.mem.Allocator.Error!void {
        self.context.report(.err, .internal, span, message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
    }
};

fn tokenAt(value: syntax.ComponentValue) ?tokenizer.Token {
    return switch (value) {
        .token => |token| token,
        else => null,
    };
}

fn isTokenKind(value: syntax.ComponentValue, kind: tokenizer.TokenKind) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == kind;
}

fn isTrivia(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.isTrivia();
}

fn isDelimiter(value: syntax.ComponentValue, expected: u21) bool {
    const token = tokenAt(value) orelse return false;
    if (token.kind != .delim) return false;
    return switch (token.data) {
        .delim => |delimiter| delimiter == expected,
        else => false,
    };
}

fn isCurlyBlock(value: syntax.ComponentValue) bool {
    return switch (value) {
        .simple_block => |block| block.opening.kind == .open_curly,
        else => false,
    };
}

fn isAtKeyword(value: syntax.ComponentValue) bool {
    return isTokenKind(value, .at_keyword);
}

fn isAtRuleBoundary(
    values: []const syntax.ComponentValue,
    chunk_start: usize,
    at_index: usize,
) bool {
    const before = trim(values, chunk_start, at_index);
    return before.empty() or isTokenKind(values[before.end - 1], .semicolon);
}

fn isPageMarginName(name: []const u8) bool {
    const names = [_][]const u8{
        "top-left-corner",
        "top-left",
        "top-center",
        "top-right",
        "top-right-corner",
        "right-top",
        "right-middle",
        "right-bottom",
        "bottom-right-corner",
        "bottom-right",
        "bottom-center",
        "bottom-left",
        "bottom-left-corner",
        "left-bottom",
        "left-middle",
        "left-top",
    };
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn skipTrivia(values: []const syntax.ComponentValue, start: usize, end: usize) usize {
    var index = start;
    while (index < end and isTrivia(values[index])) index += 1;
    return index;
}

fn trim(values: []const syntax.ComponentValue, start: usize, end: usize) Range {
    const trimmed_start = skipTrivia(values, start, end);
    var trimmed_end = end;
    while (trimmed_end > trimmed_start and isTrivia(values[trimmed_end - 1])) trimmed_end -= 1;
    return .{ .start = trimmed_start, .end = trimmed_end };
}

fn countSignificant(values: []const syntax.ComponentValue, range: Range) usize {
    var count: usize = 0;
    for (values[range.start..range.end]) |value| {
        if (!isTrivia(value)) count += 1;
    }
    return count;
}

fn spanOf(
    values: []const syntax.ComponentValue,
    range: Range,
    fallback: source.Span,
) source.Span {
    if (range.empty()) return .{
        .source = fallback.source,
        .start = fallback.start,
        .end = fallback.start,
    };
    return .{
        .source = values[range.start].span().source,
        .start = values[range.start].span().start,
        .end = values[range.end - 1].span().end,
    };
}
