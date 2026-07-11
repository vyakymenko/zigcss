const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const rule_parser = @import("rule_parser.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Options = struct {
    indent_width: u8 = 2,
    final_newline: bool = true,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidAst,
    InvalidSpan,
    SourceMismatch,
    UnterminatedSyntax,
    UnrepresentableRecovery,
};

pub fn emit(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    rules: *const ast.RuleList,
    options: Options,
) Error![]u8 {
    _ = ast.RuleList.init(rules.span, rules.rules) catch return error.InvalidAst;
    if (!rules.span.source.eql(file.id)) return error.SourceMismatch;

    var emitter = Emitter{
        .allocator = allocator,
        .file = file,
        .options = options,
        .output = try std.ArrayList(u8).initCapacity(allocator, 0),
    };
    errdefer emitter.output.deinit(allocator);
    try emitter.writeRuleList(rules, 0, true);
    if (options.final_newline and emitter.output.items.len > 0) {
        try emitter.appendByte('\n');
    }
    return emitter.output.toOwnedSlice(allocator);
}

pub fn serializeIdentifierAlloc(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer output.deinit(allocator);
    try appendIdentifier(&output, allocator, value);
    return output.toOwnedSlice(allocator);
}

pub fn serializeStringAlloc(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer output.deinit(allocator);
    try appendString(&output, allocator, value);
    return output.toOwnedSlice(allocator);
}

const Emitter = struct {
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    options: Options,
    output: std.ArrayList(u8),

    fn writeRuleList(self: *Emitter, rules: *const ast.RuleList, depth: usize, top_level: bool) Error!void {
        try self.validateRuleCoverage(rules, top_level);
        for (rules.rules, 0..) |rule, index| {
            if (index > 0) try self.appendByte('\n');
            try self.writeIndent(depth);
            try self.writeRule(rule, depth);
        }
    }

    fn writeRule(self: *Emitter, rule: ast.Rule, depth: usize) Error!void {
        switch (rule) {
            .style_rule => |style_rule| try self.writeStyleRule(style_rule, depth),
            .at_rule => |at_rule| try self.writeAtRule(at_rule, depth),
        }
    }

    fn writeStyleRule(self: *Emitter, rule: *const ast.StyleRule, depth: usize) Error!void {
        _ = ast.StyleRule.init(rule.*) catch return error.InvalidAst;
        try self.writeSelectorList(&rule.selectors);
        try self.appendSlice(" ");
        try self.writeDeclarationBlock(&rule.block, depth);
    }

    fn writeSelectorList(self: *Emitter, list: *const ast.SelectorList) Error!void {
        _ = ast.SelectorList.init(list.span, list.selectors) catch return error.InvalidAst;
        for (list.selectors, 0..) |selector, index| {
            if (index > 0) try self.appendSlice(", ");
            try self.writeComplexSelector(selector);
        }
    }

    fn writeComplexSelector(self: *Emitter, selector: ast.ComplexSelector) Error!void {
        if (selector.leading_combinator) |combinator| {
            try self.writeCombinator(combinator.kind, true);
        }
        try self.writeCompoundSelector(selector.head);
        for (selector.tails) |tail| {
            try self.writeCombinator(tail.combinator.kind, false);
            try self.writeCompoundSelector(tail.compound);
        }
    }

    fn writeCombinator(self: *Emitter, kind: ast.CombinatorKind, leading: bool) Error!void {
        if (leading and kind == .descendant) return error.InvalidAst;
        switch (kind) {
            .descendant => try self.appendByte(' '),
            .child => try self.appendSlice(if (leading) "> " else " > "),
            .next_sibling => try self.appendSlice(if (leading) "+ " else " + "),
            .subsequent_sibling => try self.appendSlice(if (leading) "~ " else " ~ "),
            .column => try self.appendSlice(if (leading) "|| " else " || "),
        }
    }

    fn writeCompoundSelector(self: *Emitter, compound: ast.CompoundSelector) Error!void {
        _ = ast.CompoundSelector.init(compound.span, compound.simple_selectors) catch return error.InvalidAst;
        for (compound.simple_selectors) |simple| try self.writeSimpleSelector(simple);
    }

    fn writeSimpleSelector(self: *Emitter, simple: ast.SimpleSelector) Error!void {
        switch (simple) {
            .type_selector => |selector| {
                try self.writeNamespace(selector.namespace);
                try self.writeIdentifier(selector.name.value);
            },
            .universal => |selector| {
                try self.writeNamespace(selector.namespace);
                try self.appendByte('*');
            },
            .id => |selector| {
                try self.appendByte('#');
                try self.writeIdentifier(selector.name.value);
            },
            .class => |selector| {
                try self.appendByte('.');
                try self.writeIdentifier(selector.name.value);
            },
            .attribute => |selector| try self.writeAttributeSelector(selector),
            .pseudo_class => |selector| try self.writePseudo(selector.name, selector.arguments, false),
            .pseudo_element => |selector| try self.writePseudo(selector.name, selector.arguments, true),
            .nesting => try self.appendByte('&'),
        }
    }

    fn writeNamespace(self: *Emitter, namespace: ast.Namespace) Error!void {
        switch (namespace) {
            .implicit => {},
            .any => try self.appendSlice("*|"),
            .empty => try self.appendByte('|'),
            .named => |name| {
                try self.writeIdentifier(name.value);
                try self.appendByte('|');
            },
        }
    }

    fn writeAttributeSelector(self: *Emitter, selector: *const ast.AttributeSelector) Error!void {
        _ = ast.AttributeSelector.init(selector.*) catch return error.InvalidAst;
        try self.appendByte('[');
        try self.writeNamespace(selector.namespace);
        try self.writeIdentifier(selector.name.value);
        if (selector.matcher) |matcher| {
            try self.appendSlice(switch (matcher.kind) {
                .exact => "=",
                .includes => "~=",
                .dash => "|=",
                .prefix => "^=",
                .suffix => "$=",
                .substring => "*=",
            });
            const value = selector.value orelse return error.InvalidAst;
            switch (value) {
                .identifier => |identifier| try self.writeIdentifier(identifier.value),
                .string => |string| try appendString(&self.output, self.allocator, string.value),
            }
        } else if (selector.value != null) return error.InvalidAst;
        if (selector.modifier) |modifier| {
            try self.appendByte(' ');
            switch (modifier) {
                .insensitive => try self.appendByte('i'),
                .sensitive => try self.appendByte('s'),
                .unknown => |identifier| try self.writeIdentifier(identifier.value),
            }
        }
        try self.appendByte(']');
    }

    fn writePseudo(
        self: *Emitter,
        name: ast.Identifier,
        arguments: ?ast.PseudoArguments,
        element: bool,
    ) Error!void {
        try self.appendSlice(if (element) "::" else ":");
        try self.writeIdentifier(name.value);
        if (arguments) |value| {
            try self.appendByte('(');
            try self.writeComponentValues(value.values);
            try self.appendByte(')');
        }
    }

    fn writeAtRule(self: *Emitter, rule: *const ast.AtRule, depth: usize) Error!void {
        _ = ast.AtRule.init(rule.*) catch return error.InvalidAst;
        if (!structuredDetailsMatch(rule)) return error.UnrepresentableRecovery;
        try self.appendByte('@');
        try self.writeIdentifier(rule.name.value);

        const page = pageDetails(rule.details);
        if (page) |details| {
            if (details.selectors.len > 0) {
                try self.appendByte(' ');
                try self.writePageSelectors(details.selectors);
            }
        } else if (hasNonWhitespace(rule.prelude.values)) {
            try self.appendByte(' ');
            try self.writeComponentValues(rule.prelude.values);
        }

        switch (rule.block) {
            .none => try self.appendByte(';'),
            .declarations => |block| {
                try self.appendByte(' ');
                try self.writeDeclarationBlock(block, depth);
            },
            .rules => |block| {
                try self.appendByte(' ');
                try self.writeRulesBlock(block, depth);
            },
            .keyframes => |block| {
                try self.appendByte(' ');
                try self.writeKeyframesBlock(block, depth);
            },
            .raw => |block| {
                try self.appendByte(' ');
                if (page) |details| {
                    try self.writePageBlock(details, block, depth);
                } else {
                    try self.writeRawBlock(block);
                }
            },
        }
    }

    fn writeRulesBlock(self: *Emitter, block: *const ast.RulesBlock, depth: usize) Error!void {
        if (!block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.appendByte('{');
        if (block.rules.rules.len == 0) {
            try self.validateRuleCoverage(&block.rules, false);
            try self.appendByte('}');
            return;
        }
        try self.appendByte('\n');
        try self.writeRuleList(&block.rules, depth + 1, false);
        try self.appendByte('\n');
        try self.writeIndent(depth);
        try self.appendByte('}');
    }

    fn writeDeclarationBlock(self: *Emitter, block: *const ast.DeclarationBlock, depth: usize) Error!void {
        try self.writeDeclarationListBlock(&block.declarations, block.envelope, depth);
    }

    fn writeDeclarationListBlock(
        self: *Emitter,
        declarations: *const ast.DeclarationList,
        envelope: ast.BlockSpan,
        depth: usize,
    ) Error!void {
        if (!envelope.terminated()) return error.UnterminatedSyntax;
        if (!spansEqual(declarations.span, envelope.content)) return error.InvalidAst;
        try self.validateDeclarationCoverage(declarations);
        try self.appendByte('{');
        if (declarations.declarations.len == 0) {
            try self.appendByte('}');
            return;
        }
        try self.appendByte('\n');
        for (declarations.declarations, 0..) |declaration, index| {
            if (index > 0) try self.appendByte('\n');
            try self.writeIndent(depth + 1);
            try self.writeDeclaration(declaration);
        }
        try self.appendByte('\n');
        try self.writeIndent(depth);
        try self.appendByte('}');
    }

    fn writeDeclaration(self: *Emitter, declaration: ast.Declaration) Error!void {
        _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
        try self.writeIdentifier(declaration.name.value);
        try self.appendSlice(": ");
        const value = declaration.valueWithoutImportance();
        try self.writeComponentValues(value);
        if (declaration.important != null) {
            if (hasNonWhitespace(value)) try self.appendByte(' ');
            try self.appendSlice("!important");
        }
        try self.appendByte(';');
    }

    fn writeKeyframesBlock(self: *Emitter, block: *const ast.KeyframesBlock, depth: usize) Error!void {
        if (!block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.validateKeyframesCoverage(block);
        try self.appendByte('{');
        if (block.frames.len == 0) {
            try self.appendByte('}');
            return;
        }
        try self.appendByte('\n');
        for (block.frames, 0..) |frame, index| {
            if (index > 0) try self.appendByte('\n');
            try self.writeIndent(depth + 1);
            try self.writeKeyframeRule(frame, depth + 1);
        }
        try self.appendByte('\n');
        try self.writeIndent(depth);
        try self.appendByte('}');
    }

    fn writeKeyframeRule(self: *Emitter, frame: ast.KeyframeRule, depth: usize) Error!void {
        _ = ast.KeyframeRule.init(frame) catch return error.InvalidAst;
        if (frame.selectors.len == 0) return error.UnrepresentableRecovery;
        for (frame.selectors, 0..) |selector, index| {
            if (index > 0) try self.appendSlice(", ");
            switch (selector) {
                .from => try self.appendSlice("from"),
                .to => try self.appendSlice("to"),
                .percentage => |percentage| try self.appendSlice(try self.raw(percentage.span)),
            }
        }
        try self.appendByte(' ');
        try self.writeDeclarationBlock(&frame.block, depth);
    }

    fn writePageSelectors(self: *Emitter, selectors: []const ast.PageSelector) Error!void {
        for (selectors, 0..) |selector, index| {
            if (index > 0) try self.appendSlice(", ");
            if (selector.name) |name| try self.writeIdentifier(name.value);
            for (selector.pseudos) |pseudo| {
                try self.appendByte(':');
                try self.writeIdentifier(pseudo.value);
            }
        }
    }

    fn writePageBlock(
        self: *Emitter,
        page: *const ast.PageRule,
        raw_block: *const ast.RawBlock,
        depth: usize,
    ) Error!void {
        if (!raw_block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.validatePageCoverage(page, raw_block.envelope.content);
        const total = page.declarations.declarations.len + page.margins.len;
        try self.appendByte('{');
        if (total == 0) {
            try self.appendByte('}');
            return;
        }
        try self.appendByte('\n');
        var declaration_index: usize = 0;
        var margin_index: usize = 0;
        var emitted: usize = 0;
        while (emitted < total) : (emitted += 1) {
            if (emitted > 0) try self.appendByte('\n');
            try self.writeIndent(depth + 1);
            if (nextPageItemIsDeclaration(page, declaration_index, margin_index)) {
                try self.writeDeclaration(page.declarations.declarations[declaration_index]);
                declaration_index += 1;
            } else {
                try self.writePageMargin(page.margins[margin_index], depth + 1);
                margin_index += 1;
            }
        }
        try self.appendByte('\n');
        try self.writeIndent(depth);
        try self.appendByte('}');
    }

    fn writePageMargin(self: *Emitter, margin: ast.PageMarginRule, depth: usize) Error!void {
        try self.appendByte('@');
        try self.writeIdentifier(margin.name.value);
        try self.appendByte(' ');
        try self.writeDeclarationListBlock(margin.declarations, margin.envelope, depth);
    }

    fn writeRawBlock(self: *Emitter, block: *const ast.RawBlock) Error!void {
        if (!block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.appendByte('{');
        try self.writeComponentValues(block.values.values);
        try self.appendByte('}');
    }

    fn writeComponentValues(self: *Emitter, values: []const syntax.ComponentValue) Error!void {
        var wrote_value = false;
        var pending_space = false;
        for (values) |value| {
            try self.validateComponent(value);
            if (isWhitespace(value)) {
                pending_space = wrote_value;
                continue;
            }
            if (pending_space) try self.appendByte(' ');
            try self.appendSlice(try self.raw(value.span()));
            wrote_value = true;
            pending_space = false;
        }
    }

    fn validateComponent(self: *Emitter, value: syntax.ComponentValue) Error!void {
        _ = try self.raw(value.span());
        switch (value) {
            .token => |token| switch (token.kind) {
                .bad_string, .bad_url, .close_curly, .close_square, .close_paren => return error.UnrepresentableRecovery,
                .comment, .string, .url => if (!token.isTerminated()) return error.UnterminatedSyntax,
                else => {},
            },
            .simple_block => |block| {
                if (!block.terminated()) return error.UnterminatedSyntax;
                for (block.values) |child| try self.validateComponent(child);
            },
            .function => |function| {
                if (!function.terminated()) return error.UnterminatedSyntax;
                for (function.values) |child| try self.validateComponent(child);
            },
        }
    }

    fn validateRuleCoverage(self: *Emitter, rules: *const ast.RuleList, top_level: bool) Error!void {
        _ = try self.raw(rules.span);
        var cursor = rules.span.start;
        for (rules.rules) |rule| {
            const span = rule.span();
            try validateChildSpan(rules.span, span);
            if (span.start < cursor) return error.InvalidAst;
            if (!try self.gapAllowed(cursor, span.start, false, top_level)) return error.UnrepresentableRecovery;
            cursor = span.end;
        }
        if (!try self.gapAllowed(cursor, rules.span.end, false, top_level)) return error.UnrepresentableRecovery;
    }

    fn validateDeclarationCoverage(self: *Emitter, declarations: *const ast.DeclarationList) Error!void {
        _ = ast.DeclarationList.init(declarations.span, declarations.declarations) catch return error.InvalidAst;
        var cursor = declarations.span.start;
        for (declarations.declarations) |declaration| {
            if (declaration.span.start < cursor) return error.InvalidAst;
            if (!try self.gapAllowed(cursor, declaration.span.start, true, false)) return error.UnrepresentableRecovery;
            cursor = declaration.span.end;
        }
        if (!try self.gapAllowed(cursor, declarations.span.end, true, false)) return error.UnrepresentableRecovery;
    }

    fn validateKeyframesCoverage(self: *Emitter, block: *const ast.KeyframesBlock) Error!void {
        var cursor = block.envelope.content.start;
        for (block.frames) |frame| {
            try validateChildSpan(block.envelope.content, frame.span);
            if (frame.span.start < cursor) return error.InvalidAst;
            if (!try self.gapAllowed(cursor, frame.span.start, false, false)) return error.UnrepresentableRecovery;
            cursor = frame.span.end;
        }
        if (!try self.gapAllowed(cursor, block.envelope.content.end, false, false)) return error.UnrepresentableRecovery;
    }

    fn validatePageCoverage(self: *Emitter, page: *const ast.PageRule, content: source.Span) Error!void {
        var declaration_index: usize = 0;
        var margin_index: usize = 0;
        var cursor = content.start;
        const total = page.declarations.declarations.len + page.margins.len;
        var visited: usize = 0;
        while (visited < total) : (visited += 1) {
            const span = if (nextPageItemIsDeclaration(page, declaration_index, margin_index)) blk: {
                const declaration = page.declarations.declarations[declaration_index];
                declaration_index += 1;
                break :blk declaration.span;
            } else blk: {
                const margin = page.margins[margin_index];
                margin_index += 1;
                break :blk margin.span;
            };
            try validateChildSpan(content, span);
            if (span.start < cursor) return error.InvalidAst;
            if (!try self.gapAllowed(cursor, span.start, true, false)) return error.UnrepresentableRecovery;
            cursor = span.end;
        }
        if (!try self.gapAllowed(cursor, content.end, true, false)) return error.UnrepresentableRecovery;
    }

    fn gapAllowed(
        self: *Emitter,
        start: usize,
        end: usize,
        allow_semicolon: bool,
        allow_cdo_cdc: bool,
    ) Error!bool {
        const bytes = try self.raw(.{ .source = self.file.id, .start = start, .end = end });
        var index: usize = 0;
        while (index < bytes.len) {
            if (isCssWhitespace(bytes[index]) or (allow_semicolon and bytes[index] == ';')) {
                index += 1;
                continue;
            }
            if (index + 1 < bytes.len and bytes[index] == '/' and bytes[index + 1] == '*') {
                var closing = index + 2;
                while (closing + 1 < bytes.len and !(bytes[closing] == '*' and bytes[closing + 1] == '/')) {
                    closing += 1;
                }
                if (closing + 1 >= bytes.len) return false;
                index = closing + 2;
                continue;
            }
            if (allow_cdo_cdc and startsWithAt(bytes, index, "<!--")) {
                index += 4;
                continue;
            }
            if (allow_cdo_cdc and startsWithAt(bytes, index, "-->")) {
                index += 3;
                continue;
            }
            return false;
        }
        return true;
    }

    fn raw(self: *Emitter, span: source.Span) Error![]const u8 {
        return self.file.slice(span) catch |err| switch (err) {
            error.SourceMismatch => return error.SourceMismatch,
            error.InvalidSpan => return error.InvalidSpan,
        };
    }

    fn writeIdentifier(self: *Emitter, value: []const u8) Error!void {
        try appendIdentifier(&self.output, self.allocator, value);
    }

    fn writeIndent(self: *Emitter, depth: usize) Error!void {
        var level: usize = 0;
        while (level < depth) : (level += 1) {
            var column: u8 = 0;
            while (column < self.options.indent_width) : (column += 1) try self.appendByte(' ');
        }
    }

    fn appendSlice(self: *Emitter, bytes: []const u8) Error!void {
        try self.output.appendSlice(self.allocator, bytes);
    }

    fn appendByte(self: *Emitter, byte: u8) Error!void {
        try self.output.append(self.allocator, byte);
    }
};

fn pageDetails(details: ?ast.AtRuleDetails) ?*const ast.PageRule {
    const value = details orelse return null;
    return switch (value) {
        .page => |page| page,
        else => null,
    };
}

fn structuredDetailsMatch(rule: *const ast.AtRule) bool {
    const details = rule.details;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "media")) return details != null and details.? == .media;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "supports")) return details != null and details.? == .supports;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "container")) return details != null and details.? == .container;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "layer")) return details != null and details.? == .layer;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "property")) return details != null and details.? == .property;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "page")) return details != null and details.? == .page;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "font-face")) return details != null and details.? == .font_face;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "keyframes") or
        std.ascii.eqlIgnoreCase(rule.name.value, "-webkit-keyframes"))
    {
        return details != null and details.? == .keyframes;
    }
    return true;
}

fn nextPageItemIsDeclaration(
    page: *const ast.PageRule,
    declaration_index: usize,
    margin_index: usize,
) bool {
    if (declaration_index == page.declarations.declarations.len) return false;
    if (margin_index == page.margins.len) return true;
    return page.declarations.declarations[declaration_index].span.start <= page.margins[margin_index].span.start;
}

fn appendIdentifier(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!void {
    var byte_index: usize = 0;
    var position: usize = 0;
    var first_was_hyphen = false;
    while (byte_index < value.len) : (position += 1) {
        const scalar = decodeScalar(value, byte_index);
        const codepoint = scalar.value;
        if (position == 0) first_was_hyphen = codepoint == '-';
        if (codepoint == 0) {
            try output.appendSlice(allocator, "�");
        } else if (isControl(codepoint) or
            (position == 0 and isAsciiDigit(codepoint)) or
            (position == 1 and first_was_hyphen and isAsciiDigit(codepoint)))
        {
            try appendCodepointEscape(output, allocator, codepoint);
        } else if (position == 0 and codepoint == '-' and scalar.len == value.len) {
            try output.appendSlice(allocator, "\\-");
        } else if (codepoint >= 0x80 or codepoint == '-' or codepoint == '_' or
            isAsciiDigit(codepoint) or isAsciiLetter(codepoint))
        {
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        } else {
            try output.append(allocator, '\\');
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        }
        byte_index += scalar.len;
    }
}

fn appendString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!void {
    try output.append(allocator, '"');
    var byte_index: usize = 0;
    while (byte_index < value.len) {
        const scalar = decodeScalar(value, byte_index);
        if (scalar.value == 0) {
            try output.appendSlice(allocator, "�");
        } else if (isControl(scalar.value)) {
            try appendCodepointEscape(output, allocator, scalar.value);
        } else if (scalar.value == '"' or scalar.value == '\\') {
            try output.append(allocator, '\\');
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        } else {
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        }
        byte_index += scalar.len;
    }
    try output.append(allocator, '"');
}

const DecodedScalar = struct {
    value: u21,
    len: usize,
    valid: bool,
};

fn decodeScalar(value: []const u8, index: usize) DecodedScalar {
    const sequence_length: usize = std.unicode.utf8ByteSequenceLength(value[index]) catch {
        return .{ .value = 0xfffd, .len = 1, .valid = false };
    };
    if (index + sequence_length > value.len) return .{ .value = 0xfffd, .len = 1, .valid = false };
    const codepoint = std.unicode.utf8Decode(value[index .. index + sequence_length]) catch {
        return .{ .value = 0xfffd, .len = 1, .valid = false };
    };
    return .{ .value = codepoint, .len = sequence_length, .valid = true };
}

fn appendScalar(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    original: []const u8,
    valid: bool,
) std.mem.Allocator.Error!void {
    try output.appendSlice(allocator, if (valid) original else "�");
}

fn appendCodepointEscape(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    codepoint: u21,
) std.mem.Allocator.Error!void {
    try output.append(allocator, '\\');
    var digits: [6]u8 = undefined;
    var start = digits.len;
    var remaining: u32 = codepoint;
    while (remaining > 0) {
        start -= 1;
        const digit: u8 = @intCast(remaining & 0xf);
        digits[start] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        remaining >>= 4;
    }
    if (start == digits.len) {
        start -= 1;
        digits[start] = '0';
    }
    try output.appendSlice(allocator, digits[start..]);
    try output.append(allocator, ' ');
}

fn isControl(codepoint: u21) bool {
    return (codepoint >= 1 and codepoint <= 0x1f) or codepoint == 0x7f;
}

fn isAsciiDigit(codepoint: u21) bool {
    return codepoint >= '0' and codepoint <= '9';
}

fn isAsciiLetter(codepoint: u21) bool {
    return (codepoint >= 'a' and codepoint <= 'z') or (codepoint >= 'A' and codepoint <= 'Z');
}

fn hasNonWhitespace(values: []const syntax.ComponentValue) bool {
    for (values) |value| if (!isWhitespace(value)) return true;
    return false;
}

fn isWhitespace(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
}

fn isCssWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

fn startsWithAt(bytes: []const u8, index: usize, expected: []const u8) bool {
    return index + expected.len <= bytes.len and std.mem.eql(u8, bytes[index .. index + expected.len], expected);
}

fn validateChildSpan(parent: source.Span, child: source.Span) Error!void {
    if (!parent.source.eql(child.source)) return error.SourceMismatch;
    if (child.start > child.end or child.start < parent.start or child.end > parent.end) return error.InvalidAst;
}

fn spansEqual(a: source.Span, b: source.Span) bool {
    return a.source.eql(b.source) and a.start == b.start and a.end == b.end;
}

fn parseSource(
    context: *compilation.Compilation,
    name: []const u8,
    css: []const u8,
) !struct { source.SourceId, *const ast.RuleList } {
    const id = try context.addSource(name, css);
    const document = try syntax.parse(context, id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    return .{ id, try rule_parser.parse(context, id, values) };
}

test "pretty emission deterministically formats typed rules without reordering" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "pretty.css",
        ".a.b,svg|button:hover > #\\31 id[data-x='a\"b' i]{color : red ;color:blue!important;--x:fn(a ; b)}" ++
            "@media  screen and (width > 1px){.c{display:grid}}" ++
            "@font-face{font-family:'A';src:url(x)}" ++
            "@unknown foo{a(b;c)}",
    );
    const file = try context.sources.get(parsed[0]);

    const first = try emit(std.testing.allocator, file, parsed[1], .{});
    defer std.testing.allocator.free(first);
    const second = try emit(std.testing.allocator, file, parsed[1], .{});
    defer std.testing.allocator.free(second);
    const expected =
        ".a.b, svg|button:hover > #\\31 id[data-x=\"a\\\"b\" i] {\n" ++
        "  color: red;\n" ++
        "  color: blue !important;\n" ++
        "  --x: fn(a ; b);\n" ++
        "}\n" ++
        "@media screen and (width > 1px) {\n" ++
        "  .c {\n" ++
        "    display: grid;\n" ++
        "  }\n" ++
        "}\n" ++
        "@font-face {\n" ++
        "  font-family: 'A';\n" ++
        "  src: url(x);\n" ++
        "}\n" ++
        "@unknown foo {a(b;c)}\n";
    try std.testing.expectEqualStrings(expected, first);
    try std.testing.expectEqualStrings(first, second);

    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "pretty-output.css", first);
    try std.testing.expectEqual(@as(usize, 4), reparsed[1].rules.len);
    const emitted_selectors = reparsed[1].rules[0].style_rule.selectors.selectors;
    try std.testing.expectEqualStrings("1id", emitted_selectors[1].tails[0].compound.simple_selectors[0].id.name.value);
    try std.testing.expectEqual(@as(usize, 3), reparsed[1].rules[0].style_rule.block.declarations.declarations.len);
    try std.testing.expectEqualStrings("color", reparsed[1].rules[0].style_rule.block.declarations.declarations[0].name.value);
    try std.testing.expectEqualStrings("color", reparsed[1].rules[0].style_rule.block.declarations.declarations[1].name.value);
    try std.testing.expect(reparsed[1].rules[0].style_rule.block.declarations.declarations[1].important != null);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "keyframes and page structures receive ordered nested pretty formatting" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "structured-pretty.css",
        "@keyframes fade{from,50%{opacity:0}100%{opacity:1}}" ++
            "@page invoice:first,:left{margin:1cm;@top-left{content:\"Invoice\"}size:A4}",
    );
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    const expected =
        "@keyframes fade {\n" ++
        "  from, 50% {\n" ++
        "    opacity: 0;\n" ++
        "  }\n" ++
        "  100% {\n" ++
        "    opacity: 1;\n" ++
        "  }\n" ++
        "}\n" ++
        "@page invoice:first, :left {\n" ++
        "  margin: 1cm;\n" ++
        "  @top-left {\n" ++
        "    content: \"Invoice\";\n" ++
        "  }\n" ++
        "  size: A4;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "conditional layer and property at-rules share deterministic block formatting" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "at-rule-pretty.css",
        "@supports (display:grid) and selector(.x){.a{x:1}}" ++
            "@container card (width>1px){.b{x:2}}" ++
            "@layer base.components, theme;" ++
            "@layer utilities{.c{x:3}}" ++
            "@property --theme{syntax:\"<color>\";inherits:false;initial-value:red}",
    );
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    const expected =
        "@supports (display:grid) and selector(.x) {\n" ++
        "  .a {\n" ++
        "    x: 1;\n" ++
        "  }\n" ++
        "}\n" ++
        "@container card (width>1px) {\n" ++
        "  .b {\n" ++
        "    x: 2;\n" ++
        "  }\n" ++
        "}\n" ++
        "@layer base.components, theme;\n" ++
        "@layer utilities {\n" ++
        "  .c {\n" ++
        "    x: 3;\n" ++
        "  }\n" ++
        "}\n" ++
        "@property --theme {\n" ++
        "  syntax: \"<color>\";\n" ++
        "  inherits: false;\n" ++
        "  initial-value: red;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "identifier and string escaping follows CSSOM serialization rules" {
    const identifier_cases = [_]struct { []const u8, []const u8 }{
        .{ "simple", "simple" },
        .{ "0start", "\\30 start" },
        .{ "-1start", "-\\31 start" },
        .{ "-", "\\-" },
        .{ "a b", "a\\ b" },
        .{ "éclair", "éclair" },
        .{ "\x00x", "�x" },
        .{ "a\x1fb", "a\\1f b" },
    };
    for (identifier_cases) |case| {
        const serialized = try serializeIdentifierAlloc(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(serialized);
        try std.testing.expectEqualStrings(case[1], serialized);
    }

    const string = try serializeStringAlloc(std.testing.allocator, "a\"b\\c\n\x00");
    defer std.testing.allocator.free(string);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\a �\"", string);
}

test "every byte serializes into one valid identifier and terminated string token" {
    var raw: [1]u8 = undefined;
    var value: usize = 0;
    while (value <= std.math.maxInt(u8)) : (value += 1) {
        raw[0] = @intCast(value);
        const identifier = try serializeIdentifierAlloc(std.testing.allocator, &raw);
        defer std.testing.allocator.free(identifier);
        const string = try serializeStringAlloc(std.testing.allocator, &raw);
        defer std.testing.allocator.free(string);

        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const identifier_id = try context.addSource("escaped-identifier.css", identifier);
        var identifier_tokenizer = tokenizer.Tokenizer.init(try context.sources.get(identifier_id));
        try std.testing.expectEqual(tokenizer.TokenKind.ident, identifier_tokenizer.next().kind);
        try std.testing.expectEqual(tokenizer.TokenKind.eof, identifier_tokenizer.next().kind);

        const string_id = try context.addSource("escaped-string.css", string);
        var string_tokenizer = tokenizer.Tokenizer.init(try context.sources.get(string_id));
        const string_token = string_tokenizer.next();
        try std.testing.expectEqual(tokenizer.TokenKind.string, string_token.kind);
        try std.testing.expect(string_token.isTerminated());
        try std.testing.expectEqual(tokenizer.TokenKind.eof, string_tokenizer.next().kind);
    }
}

test "raw component values retain comments required for token boundaries" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "token-boundaries.css", ".x{--a:a/**/b;--b:1/**/%}");
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(
        ".x {\n  --a: a/**/b;\n  --b: 1/**/%;\n}\n",
        output,
    );
    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "token-boundaries-output.css", output);
    try std.testing.expectEqual(@as(usize, 2), reparsed[1].rules[0].style_rule.block.declarations.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "forgiving pseudo arguments retain their raw invalid alternatives" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "forgiving-output.css", ":is(.a, ., .b){x:1}");
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(":is(.a, ., .b) {\n  x: 1;\n}\n", output);
    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "forgiving-reparse.css", output);
    const typed = reparsed[1].rules[0].style_rule.selectors.selectors[0].head.simple_selectors[0].pseudo_class.arguments.?.parsed.?.selector_list;
    try std.testing.expectEqual(@as(usize, 2), typed.selectors.len);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "statements empty blocks and formatting options remain deterministic" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "empty-pretty.css",
        "@import url(x);@layer base;.empty{}.filled{x:1}@media all{}@unknown x{}",
    );
    const output = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .indent_width = 4, .final_newline = false },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "@import url(x);\n@layer base;\n.empty {}\n.filled {\n    x: 1;\n}\n@media all {}\n@unknown x {}",
        output,
    );

    var empty_context = try compilation.Compilation.init(std.testing.allocator);
    defer empty_context.deinit();
    const empty = try parseSource(&empty_context, "empty.css", "");
    const empty_output = try emit(
        std.testing.allocator,
        try empty_context.sources.get(empty[0]),
        empty[1],
        .{},
    );
    defer std.testing.allocator.free(empty_output);
    try std.testing.expectEqual(@as(usize, 0), empty_output.len);
}

test "emission is bound to the AST source file" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "first.css", ".a{x:1}");
    const other_id = try context.addSource("other.css", ".b{y:2}");

    try std.testing.expectError(
        error.SourceMismatch,
        emit(std.testing.allocator, try context.sources.get(other_id), parsed[1], .{}),
    );
}

test "emission refuses recovery gaps and missing closing syntax" {
    const cases = [_]struct { []const u8, Error }{
        .{ ".a{broken;color:red}", error.UnrepresentableRecovery },
        .{ ":not(.a,){x:1}.b{x:2}", error.UnrepresentableRecovery },
        .{ "@media{.a{x:1}}", error.UnrepresentableRecovery },
        .{ "@keyframes f{bad{x:1}50%{x:2}}", error.UnrepresentableRecovery },
        .{ ".a{color:red", error.UnterminatedSyntax },
    };
    for (cases) |case| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const parsed = try parseSource(&context, "recovered-emission.css", case[0]);
        try std.testing.expectError(
            case[1],
            emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{}),
        );
    }
}

fn exerciseEmitterAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "oom-emitter.css",
        ".a,.b > c{color:red;color:blue!important;--x:fn(a/**/b)}@media all{.c{display:grid}}@keyframes f{from{opacity:0}to{opacity:1}}",
    );
    const output = try emit(allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer allocator.free(output);
    try std.testing.expect(output.len > 0);
}

test "pretty emission handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEmitterAllocationFailures,
        .{},
    );
}
