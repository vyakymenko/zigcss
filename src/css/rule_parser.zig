const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const declaration_parser = @import("declaration_parser.zig");
const diagnostics = @import("../diagnostics.zig");
const selector_parser = @import("selector_parser.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Options = struct {
    max_nesting: usize = 128,
    max_rules: usize = 100_000,
};

pub const Error = std.mem.Allocator.Error || error{
    DeclarationLimit,
    InternalInvariant,
    InvalidInput,
    RuleLimit,
    RuleNestingLimit,
    SelectorNestingLimit,
    UnknownSource,
};

pub fn parse(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
) Error!*const ast.RuleList {
    return parseWithOptions(context, source_id, input, .{});
}

pub fn parseWithOptions(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
    options: Options,
) Error!*const ast.RuleList {
    const file = try context.sources.get(source_id);
    if (!input.span.source.eql(source_id)) return error.InvalidInput;
    _ = ast.ComponentValueList.init(input.span, input.values) catch return error.InvalidInput;
    var parser = Parser{
        .allocator = context.arenaAllocator(),
        .context = context,
        .file = file,
        .source_id = source_id,
        .options = options,
    };
    return parser.parseList(input, 0, true);
}

const ParsedRule = struct {
    rule: ?ast.Rule,
    next: usize,
};

const AtRuleClass = enum {
    declarations,
    rules,
    keyframes,
    raw,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    context: *compilation.Compilation,
    file: *const source.SourceFile,
    source_id: source.SourceId,
    options: Options,

    fn parseList(
        self: *Parser,
        input: ast.ComponentValueList,
        depth: usize,
        top_level: bool,
    ) Error!*const ast.RuleList {
        if (depth >= self.options.max_nesting) {
            try self.report(.resource_limit, input.span, "rule nesting limit exceeded");
            return error.RuleNestingLimit;
        }

        var rules = try std.ArrayList(ast.Rule).initCapacity(self.allocator, 0);
        errdefer rules.deinit(self.allocator);
        var index: usize = 0;
        while (index < input.values.len) {
            index = skipIgnorable(input.values, index, top_level);
            if (index == input.values.len) break;
            const parsed = if (isAtKeyword(input.values[index]))
                try self.parseAtRule(input.values, index, depth)
            else
                try self.parseQualifiedRule(input.values, index, depth);
            if (parsed.next <= index) {
                try self.report(.internal, input.values[index].span(), "rule parser made no progress");
                return error.InternalInvariant;
            }
            index = parsed.next;
            if (parsed.rule) |rule| {
                if (rules.items.len >= self.options.max_rules) {
                    try self.report(.resource_limit, rule.span(), "rule count limit exceeded");
                    return error.RuleLimit;
                }
                try rules.append(self.allocator, rule);
            }
        }

        const owned = try rules.toOwnedSlice(self.allocator);
        const list = self.allocator.create(ast.RuleList) catch return error.OutOfMemory;
        list.* = ast.RuleList.init(input.span, owned) catch {
            try self.report(.internal, input.span, "rule-list span invariant failed");
            return error.InternalInvariant;
        };
        return list;
    }

    fn parseAtRule(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        depth: usize,
    ) Error!ParsedRule {
        const at_token = tokenAt(values[start]).?;
        const name = try self.identifier(at_token);
        var index = start + 1;
        while (index < values.len and !isSemicolon(values[index]) and !isCurlyBlock(values[index])) {
            index += 1;
        }

        const prelude = try componentList(values, start + 1, index, at_token.span.end);
        const at_sign = makeSpan(self.source_id, at_token.span.start, name.span.start);
        if (index == values.len or isSemicolon(values[index])) {
            const terminator = if (index < values.len) tokenAt(values[index]).?.span else null;
            const rule_end = if (terminator) |span| span.end else prelude.span.end;
            const at_rule = self.allocator.create(ast.AtRule) catch return error.OutOfMemory;
            at_rule.* = ast.AtRule.init(.{
                .at_sign = at_sign,
                .name = name,
                .prelude = prelude,
                .block = .{ .none = .{ .terminator = terminator } },
                .span = makeSpan(self.source_id, at_token.span.start, rule_end),
            }) catch {
                try self.report(.internal, at_token.span, "no-block at-rule invariant failed");
                return error.InternalInvariant;
            };
            return .{ .rule = .{ .at_rule = at_rule }, .next = if (index < values.len) index + 1 else index };
        }

        const syntax_block = values[index].simple_block;
        const envelope = try blockSpan(syntax_block);
        const content = ast.ComponentValueList.init(envelope.content, syntax_block.values) catch {
            return error.InternalInvariant;
        };
        const block: ast.AtRuleBlock = switch (classifyAtRule(name.value)) {
            .declarations => blk: {
                const declarations = try declaration_parser.parse(self.context, self.source_id, content);
                const declaration_block = self.allocator.create(ast.DeclarationBlock) catch return error.OutOfMemory;
                declaration_block.* = ast.DeclarationBlock.init(envelope, declarations.*) catch {
                    try self.report(.internal, envelope.span, "declaration at-rule block invariant failed");
                    return error.InternalInvariant;
                };
                break :blk .{ .declarations = declaration_block };
            },
            .rules => blk: {
                const nested_rules = try self.parseList(content, depth + 1, false);
                const rules_block = self.allocator.create(ast.RulesBlock) catch return error.OutOfMemory;
                rules_block.* = ast.RulesBlock.init(envelope, nested_rules.*) catch {
                    try self.report(.internal, envelope.span, "rule at-rule block invariant failed");
                    return error.InternalInvariant;
                };
                break :blk .{ .rules = rules_block };
            },
            .keyframes => blk: {
                const keyframes = self.allocator.create(ast.KeyframesBlock) catch return error.OutOfMemory;
                keyframes.* = ast.KeyframesBlock.initWithRaw(envelope, content, &.{}) catch {
                    try self.report(.internal, envelope.span, "keyframes block invariant failed");
                    return error.InternalInvariant;
                };
                break :blk .{ .keyframes = keyframes };
            },
            .raw => blk: {
                const raw = self.allocator.create(ast.RawBlock) catch return error.OutOfMemory;
                raw.* = ast.RawBlock.init(envelope, content) catch {
                    try self.report(.internal, envelope.span, "raw at-rule block invariant failed");
                    return error.InternalInvariant;
                };
                break :blk .{ .raw = raw };
            },
        };

        const at_rule = self.allocator.create(ast.AtRule) catch return error.OutOfMemory;
        at_rule.* = ast.AtRule.init(.{
            .at_sign = at_sign,
            .name = name,
            .prelude = prelude,
            .block = block,
            .span = makeSpan(self.source_id, at_token.span.start, envelope.span.end),
        }) catch {
            try self.report(.internal, at_token.span, "block at-rule invariant failed");
            return error.InternalInvariant;
        };
        return .{ .rule = .{ .at_rule = at_rule }, .next = index + 1 };
    }

    fn parseQualifiedRule(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        depth: usize,
    ) Error!ParsedRule {
        _ = depth;
        var index = start;
        while (index < values.len and !isSemicolon(values[index]) and !isCurlyBlock(values[index])) {
            index += 1;
        }
        if (index == values.len or isSemicolon(values[index])) {
            const end = if (index < values.len) values[index].span().end else values[values.len - 1].span().end;
            try self.report(
                .unexpected_token,
                makeSpan(self.source_id, values[start].span().start, end),
                "qualified rule is missing a block",
            );
            return .{ .rule = null, .next = if (index < values.len) index + 1 else index };
        }

        const prelude = try componentList(values, start, index, values[start].span().start);
        const selectors = selector_parser.parse(self.context, self.source_id, prelude) catch |err| switch (err) {
            error.InvalidSelector => return .{ .rule = null, .next = index + 1 },
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownSource => return error.UnknownSource,
            error.SelectorNestingLimit => return error.SelectorNestingLimit,
        };
        const syntax_block = values[index].simple_block;
        const envelope = try blockSpan(syntax_block);
        const content = ast.ComponentValueList.init(envelope.content, syntax_block.values) catch {
            return error.InternalInvariant;
        };
        const declarations = try declaration_parser.parse(self.context, self.source_id, content);
        const declaration_block = ast.DeclarationBlock.init(envelope, declarations.*) catch {
            try self.report(.internal, envelope.span, "style declaration block invariant failed");
            return error.InternalInvariant;
        };
        const style_rule = self.allocator.create(ast.StyleRule) catch return error.OutOfMemory;
        style_rule.* = ast.StyleRule.init(.{
            .selectors = selectors.*,
            .block = declaration_block,
            .span = makeSpan(self.source_id, prelude.span.start, envelope.span.end),
        }) catch {
            try self.report(.internal, envelope.span, "style-rule span invariant failed");
            return error.InternalInvariant;
        };
        return .{ .rule = .{ .style_rule = style_rule }, .next = index + 1 };
    }

    fn identifier(self: *Parser, token: tokenizer.Token) Error!ast.Identifier {
        const value_span = token.valueSpan() orelse return error.InvalidInput;
        const value = token.decodedTextAlloc(self.allocator, self.file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInput,
        };
        return .{ .value = value, .span = value_span };
    }

    fn report(
        self: *Parser,
        code: diagnostics.Code,
        span: source.Span,
        message: []const u8,
    ) std.mem.Allocator.Error!void {
        self.context.report(.err, code, span, message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
    }
};

fn classifyAtRule(name: []const u8) AtRuleClass {
    if (equalsAny(name, &.{
        "media",
        "supports",
        "container",
        "layer",
        "scope",
        "starting-style",
        "document",
    })) return .rules;
    if (equalsAny(name, &.{
        "font-face",
        "property",
        "counter-style",
        "font-palette-values",
        "view-transition",
    })) return .declarations;
    if (std.ascii.eqlIgnoreCase(name, "keyframes") or
        std.ascii.eqlIgnoreCase(name, "-webkit-keyframes")) return .keyframes;
    return .raw;
}

fn equalsAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn componentList(
    values: []const syntax.ComponentValue,
    start: usize,
    end: usize,
    empty_offset: usize,
) Error!ast.ComponentValueList {
    if (start == end) {
        const source_id = if (values.len > 0) values[0].span().source else source.SourceId{ .value = 0 };
        return ast.ComponentValueList.init(makeSpan(source_id, empty_offset, empty_offset), &.{}) catch {
            return error.InvalidInput;
        };
    }
    return ast.ComponentValueList.init(
        makeSpan(values[start].span().source, values[start].span().start, values[end - 1].span().end),
        values[start..end],
    ) catch return error.InvalidInput;
}

fn blockSpan(block: *const syntax.SimpleBlock) Error!ast.BlockSpan {
    const content_end = if (block.closing) |closing| closing.span.start else block.span.end;
    return ast.BlockSpan.init(.{
        .opening = block.opening.span,
        .content = makeSpan(block.span.source, block.opening.span.end, content_end),
        .closing = if (block.closing) |closing| closing.span else null,
        .span = block.span,
    }) catch return error.InternalInvariant;
}

fn tokenAt(value: syntax.ComponentValue) ?tokenizer.Token {
    return switch (value) {
        .token => |token| token,
        else => null,
    };
}

fn isAtKeyword(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .at_keyword;
}

fn isSemicolon(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .semicolon;
}

fn isCurlyBlock(value: syntax.ComponentValue) bool {
    return switch (value) {
        .simple_block => |block| block.opening.kind == .open_curly,
        else => false,
    };
}

fn isIgnorable(value: syntax.ComponentValue, top_level: bool) bool {
    const token = tokenAt(value) orelse return false;
    return token.isTrivia() or (top_level and (token.kind == .cdo or token.kind == .cdc));
}

fn skipIgnorable(values: []const syntax.ComponentValue, start: usize, top_level: bool) usize {
    var index = start;
    while (index < values.len and isIgnorable(values[index], top_level)) index += 1;
    return index;
}

fn makeSpan(source_id: source.SourceId, start: usize, end: usize) source.Span {
    return .{ .source = source_id, .start = start, .end = end };
}

fn parseSource(
    context: *compilation.Compilation,
    name: []const u8,
    css: []const u8,
) !struct { source.SourceId, *const ast.RuleList } {
    const id = try context.addSource(name, css);
    const document = try syntax.parse(context, id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    return .{ id, try parse(context, id, values) };
}

test "stylesheets preserve ordered style rules and nested rule at-rules" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "rules.css",
        "@charset \"UTF-8\";@import url(x);.a,.b > c{color:red;color:blue!important;}@media screen{.c{width:1px}@supports (display:grid){.d{display:grid}}}",
    );
    const rules = parsed[1].rules;

    try std.testing.expectEqual(@as(usize, 4), rules.len);
    try std.testing.expectEqualStrings("charset", rules[0].at_rule.name.value);
    try std.testing.expect(rules[0].at_rule.block == .none);
    try std.testing.expectEqualStrings("import", rules[1].at_rule.name.value);
    try std.testing.expect(rules[2] == .style_rule);
    try std.testing.expectEqual(@as(usize, 2), rules[2].style_rule.selectors.selectors.len);
    try std.testing.expectEqual(@as(usize, 2), rules[2].style_rule.block.declarations.declarations.len);
    try std.testing.expect(rules[2].style_rule.block.declarations.declarations[1].important != null);

    const media = rules[3].at_rule;
    try std.testing.expectEqualStrings("media", media.name.value);
    try std.testing.expect(media.block == .rules);
    try std.testing.expectEqual(@as(usize, 2), media.block.rules.rules.rules.len);
    try std.testing.expect(media.block.rules.rules.rules[0] == .style_rule);
    try std.testing.expect(media.block.rules.rules.rules[1].at_rule.block == .rules);
}

test "at-rule block classifiers retain declarations keyframes raw blocks and no blocks" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "at-rules.css",
        "@font-face{font-family:x;src:url(x)}@property --x{syntax:\"<color>\";inherits:false;initial-value:red}@keyframes fade{from{opacity:0}}@unknown foo{a(b;c)}@layer base;",
    );
    const rules = parsed[1].rules;

    try std.testing.expectEqual(@as(usize, 5), rules.len);
    try std.testing.expect(rules[0].at_rule.block == .declarations);
    try std.testing.expectEqual(@as(usize, 2), rules[0].at_rule.block.declarations.declarations.declarations.len);
    try std.testing.expect(rules[1].at_rule.block == .declarations);
    try std.testing.expectEqual(@as(usize, 3), rules[1].at_rule.block.declarations.declarations.declarations.len);
    try std.testing.expect(rules[2].at_rule.block == .keyframes);
    try std.testing.expect(rules[2].at_rule.block.keyframes.raw_values != null);
    try std.testing.expect(rules[2].at_rule.block.keyframes.raw_values.?.values.len > 0);
    try std.testing.expect(rules[3].at_rule.block == .raw);
    try std.testing.expectEqual(@as(usize, 1), rules[3].at_rule.block.raw.values.values.len);
    try std.testing.expect(rules[4].at_rule.block == .none);
}

test "qualified-rule failures recover without reordering later rules" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "rule-recovery.css",
        "bad;.ok{a:1}{x:y}@media{broken;.nested{b:2}}.last{c:3}",
    );
    const rules = parsed[1].rules;

    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expect(rules[0] == .style_rule);
    try std.testing.expectEqualStrings("media", rules[1].at_rule.name.value);
    try std.testing.expectEqual(@as(usize, 1), rules[1].at_rule.block.rules.rules.rules.len);
    try std.testing.expect(rules[2] == .style_rule);
    try std.testing.expect(context.diagnostics.items().len >= 3);
}

test "at-rules ending at EOF retain an explicit no-block form" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "at-eof.css", "@import url(x)");
    const at_rule = parsed[1].rules[0].at_rule;

    try std.testing.expect(at_rule.block == .none);
    try std.testing.expect(at_rule.block.none.terminator == null);
}

test "top-level CDO CDC and escaped at-rule names follow stylesheet context" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "stylesheet-context.css",
        "<!-- .a{} --> @\\6d edia{.b{color:red}}",
    );
    const file = try context.sources.get(parsed[0]);
    const rules = parsed[1].rules;

    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expect(rules[0] == .style_rule);
    try std.testing.expectEqualStrings("media", rules[1].at_rule.name.value);
    try std.testing.expect(rules[1].at_rule.block == .rules);
    try std.testing.expectEqualStrings("\\6d edia", try file.slice(rules[1].at_rule.name.span));
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

test "unterminated qualified blocks preserve recovered declarations" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "rule-eof.css", ".a{color:red");
    const rule = parsed[1].rules[0].style_rule;

    try std.testing.expect(!rule.block.envelope.terminated());
    try std.testing.expectEqual(@as(usize, 1), rule.block.declarations.declarations.len);
    try std.testing.expectEqualStrings("color", rule.block.declarations.declarations[0].name.value);
    try std.testing.expect(context.diagnostics.items().len > 0);
}

test "rule count and recursion limits are operational failures" {
    var count_context = try compilation.Compilation.init(std.testing.allocator);
    defer count_context.deinit();
    const count_id = try count_context.addSource("rule-limit.css", ".a{}.b{}");
    const count_document = try syntax.parse(&count_context, count_id);
    const count_values = try ast.ComponentValueList.init(count_document.span, count_document.values);
    try std.testing.expectError(
        error.RuleLimit,
        parseWithOptions(&count_context, count_id, count_values, .{ .max_rules = 1 }),
    );

    var depth_context = try compilation.Compilation.init(std.testing.allocator);
    defer depth_context.deinit();
    const depth_id = try depth_context.addSource("rule-depth.css", "@media{@media{@media{.a{}}}}");
    const depth_document = try syntax.parse(&depth_context, depth_id);
    const depth_values = try ast.ComponentValueList.init(depth_document.span, depth_document.values);
    try std.testing.expectError(
        error.RuleNestingLimit,
        parseWithOptions(&depth_context, depth_id, depth_values, .{ .max_nesting = 2 }),
    );
}

fn exerciseRuleAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "oom-rules.css",
        "@media screen{.a,.b:hover{color:red;color:blue!important}@supports(display:grid){.c{display:grid}}}@unknown{x(y;z)}",
    );
    try std.testing.expectEqual(@as(usize, 2), parsed[1].rules.len);
}

test "rule lowering handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRuleAllocationFailures,
        .{},
    );
}

fn exerciseRuleRecoveryAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "oom-rule-recovery.css",
        "bad;.ok{broken;color:red}@media{nope;.nested{width:1px}}",
    );
    try std.testing.expectEqual(@as(usize, 2), parsed[1].rules.len);
    try std.testing.expect(context.diagnostics.items().len >= 3);
}

test "rule recovery handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRuleRecoveryAllocationFailures,
        .{},
    );
}
