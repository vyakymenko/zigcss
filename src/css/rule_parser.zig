const std = @import("std");
const ast = @import("ast.zig");
const at_rule_parser = @import("at_rule_parser.zig");
const compilation = @import("../compilation.zig");
const declaration_parser = @import("declaration_parser.zig");
const diagnostics = @import("../diagnostics.zig");
const recovery = @import("recovery.zig");
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
        const boundary = recovery.scanRuleBoundary(values, start + 1);
        const index = boundary.index;

        const prelude = try componentList(values, start + 1, index, at_token.span.end);
        const at_sign = makeSpan(self.source_id, at_token.span.start, name.span.start);
        if (boundary.kind != .curly_block) {
            const terminator = if (boundary.kind == .semicolon) tokenAt(values[index]).?.span else null;
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
            try at_rule_parser.specialize(self.context, self.file, at_rule);
            return .{ .rule = .{ .at_rule = at_rule }, .next = boundary.next };
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
        try at_rule_parser.specialize(self.context, self.file, at_rule);
        return .{ .rule = .{ .at_rule = at_rule }, .next = boundary.next };
    }

    fn parseQualifiedRule(
        self: *Parser,
        values: []const syntax.ComponentValue,
        start: usize,
        depth: usize,
    ) Error!ParsedRule {
        _ = depth;
        const boundary = recovery.scanRuleBoundary(values, start);
        const index = boundary.index;
        if (boundary.kind != .curly_block) {
            const end = if (boundary.kind == .semicolon) values[index].span().end else values[values.len - 1].span().end;
            try self.report(
                .unexpected_token,
                makeSpan(self.source_id, values[start].span().start, end),
                "qualified rule is missing a block",
            );
            return .{ .rule = null, .next = boundary.next };
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
        return .{ .rule = .{ .style_rule = style_rule }, .next = boundary.next };
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

fn isIgnorable(value: syntax.ComponentValue, top_level: bool) bool {
    const token = tokenAt(value) orelse return false;
    return token.isTrivia() or recovery.isStrayClosing(value) or
        (top_level and (token.kind == .cdo or token.kind == .cdc));
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
        "<!-- .a{} --> @\\6d edia all{.b{color:red}}",
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

test "media supports container and layer preludes receive typed structure" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "conditional-at-rules.css",
        "@media screen,(width>10px){.a{x:1}}@supports (display:grid) and selector(.a){.b{x:2}}@container card (width>1px){.c{x:3}}@layer base.components,theme;@layer utilities{.d{x:4}}",
    );
    const rules = parsed[1].rules;

    try std.testing.expectEqual(@as(usize, 5), rules.len);
    const media = rules[0].at_rule.details.?.media;
    try std.testing.expectEqual(@as(usize, 2), media.query_list.queries.len);
    const supports = rules[1].at_rule.details.?.supports;
    try std.testing.expectEqual(ast.SupportsOperator.@"and", supports.operator);
    try std.testing.expectEqual(@as(usize, 2), supports.terms.len);
    const container = rules[2].at_rule.details.?.container;
    try std.testing.expectEqualStrings("card", container.name.?.value);
    try std.testing.expect(container.query.values.len > 0);
    const layer_statement = rules[3].at_rule.details.?.layer;
    try std.testing.expect(layer_statement.statement);
    try std.testing.expectEqual(@as(usize, 2), layer_statement.names.len);
    try std.testing.expectEqual(@as(usize, 2), layer_statement.names[0].parts.len);
    const layer_block = rules[4].at_rule.details.?.layer;
    try std.testing.expect(!layer_block.statement);
    try std.testing.expectEqualStrings("utilities", layer_block.names[0].parts[0].value);
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

test "property and font-face rules expose declaration-backed details" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "descriptor-at-rules.css",
        "@property --theme{syntax:\"<color>\";inherits:false;initial-value:red}@font-face{font-family:x;src:url(x)}",
    );
    const property = parsed[1].rules[0].at_rule.details.?.property;
    const font_face = parsed[1].rules[1].at_rule.details.?.font_face;

    try std.testing.expectEqualStrings("--theme", property.name.value);
    try std.testing.expectEqual(@as(usize, 3), property.declarations.declarations.len);
    try std.testing.expectEqual(@as(usize, 2), font_face.declarations.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

test "keyframes parse names frame selectors percentages and declarations" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "typed-keyframes.css",
        "@keyframes fade{from,50%{opacity:0}100%{opacity:1}bad{opacity:2}}",
    );
    const keyframes = parsed[1].rules[0].at_rule.details.?.keyframes;

    try std.testing.expectEqualStrings("fade", keyframes.name.value);
    try std.testing.expectEqual(@as(usize, 2), keyframes.block.frames.len);
    try std.testing.expectEqual(@as(usize, 2), keyframes.block.frames[0].selectors.len);
    try std.testing.expect(keyframes.block.frames[0].selectors[0] == .from);
    try std.testing.expectEqual(@as(f64, 50), keyframes.block.frames[0].selectors[1].percentage.value);
    try std.testing.expectEqual(@as(f64, 100), keyframes.block.frames[1].selectors[0].percentage.value);
    try std.testing.expectEqual(@as(usize, 1), keyframes.block.frames[0].block.declarations.declarations.len);
    try std.testing.expect(context.diagnostics.items().len > 0);
}

test "page rules retain page selectors declarations and margin boxes" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "page.css",
        "@page invoice:first,:left{margin:1cm;@top-left{content:\"Invoice\"}size:A4;@bottom-center{content:counter(page)}}",
    );
    const page = parsed[1].rules[0].at_rule.details.?.page;

    try std.testing.expectEqual(@as(usize, 2), page.selectors.len);
    try std.testing.expectEqualStrings("invoice", page.selectors[0].name.?.value);
    try std.testing.expectEqualStrings("first", page.selectors[0].pseudos[0].value);
    try std.testing.expect(page.selectors[1].name == null);
    try std.testing.expectEqualStrings("left", page.selectors[1].pseudos[0].value);
    try std.testing.expectEqual(@as(usize, 2), page.declarations.declarations.len);
    try std.testing.expectEqualStrings("margin", page.declarations.declarations[0].name.value);
    try std.testing.expectEqualStrings("size", page.declarations.declarations[1].name.value);
    try std.testing.expectEqual(@as(usize, 2), page.margins.len);
    try std.testing.expectEqualStrings("top-left", page.margins[0].name.value);
    try std.testing.expectEqualStrings("bottom-center", page.margins[1].name.value);
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

test "invalid structured at-rules keep their raw AST and append diagnostics" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "invalid-structured-at-rules.css",
        "@media{}@supports{}@container{}@layer foo,bar{}@property color{}@font-face x{}@keyframes none{}",
    );

    for (parsed[1].rules) |rule| try std.testing.expect(rule.at_rule.details == null);
    try std.testing.expect(context.diagnostics.items().len >= parsed[1].rules.len);
}

test "structured at-rules reject mixed conditions empty media terms and invalid frames" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "structured-recovery.css",
        "@media screen,{}@supports (a:b) and (c:d) or (e:f){}@keyframes f{-1%{x:1}101%{x:2}50%{x:3}}",
    );

    try std.testing.expect(parsed[1].rules[0].at_rule.details == null);
    try std.testing.expect(parsed[1].rules[0].at_rule.block == .rules);
    try std.testing.expect(parsed[1].rules[1].at_rule.details == null);
    const keyframes = parsed[1].rules[2].at_rule.details.?.keyframes;
    try std.testing.expectEqual(@as(usize, 1), keyframes.block.frames.len);
    try std.testing.expectEqual(@as(f64, 50), keyframes.block.frames[0].selectors[0].percentage.value);
    try std.testing.expect(keyframes.block.raw_values != null);
    try std.testing.expect(context.diagnostics.items().len >= 4);
}

test "page margin scanning does not consume at-keywords in declaration values" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "page-at-keywords.css",
        "@page{--marker:@foo;margin:1cm;@top-left{content:@bar}}",
    );
    const page = parsed[1].rules[0].at_rule.details.?.page;

    try std.testing.expectEqual(@as(usize, 2), page.declarations.declarations.len);
    try std.testing.expectEqualStrings("--marker", page.declarations.declarations[0].name.value);
    try std.testing.expectEqual(@as(usize, 1), page.margins.len);
    try std.testing.expectEqual(@as(usize, 1), page.margins[0].declarations.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

test "anonymous layer blocks and empty page selectors receive typed details" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "anonymous-structures.css", "@layer{.a{x:1}}@page{size:A4}");

    const layer = parsed[1].rules[0].at_rule.details.?.layer;
    try std.testing.expect(!layer.statement);
    try std.testing.expectEqual(@as(usize, 0), layer.names.len);
    const page = parsed[1].rules[1].at_rule.details.?.page;
    try std.testing.expectEqual(@as(usize, 0), page.selectors.len);
    try std.testing.expectEqual(@as(usize, 1), page.declarations.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

fn exerciseStructuredAtRuleAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "oom-structured-at-rules.css",
        "@media screen,(width>1px){.a{x:1}}@keyframes f{from{opacity:0}to{opacity:1}}@page:left{margin:1cm;@top-left{content:\"x\"}}",
    );
    try std.testing.expectEqual(@as(usize, 3), parsed[1].rules.len);
    try std.testing.expect(parsed[1].rules[0].at_rule.details != null);
    try std.testing.expect(parsed[1].rules[1].at_rule.details != null);
    try std.testing.expect(parsed[1].rules[2].at_rule.details != null);
}

test "structured at-rule lowering handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseStructuredAtRuleAllocationFailures,
        .{},
    );
}

const synchronized_recovery_css =
    "???;.before{a:1;broken;b:2}" ++
    ":not(.a,){ignored:1}.after{c:3}" ++
    "@media all{???;.nested{bad;d:4}:has(.x,){x:1}.tail{e:5}}" ++
    "@keyframes f{bad{x:0}25%{broken;y:1}50%{z:2}}" ++
    "@page{bad;size:A4;@top-left{broken;content:\"x\"}}";

test "synchronized recovery preserves valid siblings nested rules frames and descriptors" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "synchronized-recovery.css", synchronized_recovery_css);
    const rules = parsed[1].rules;

    try std.testing.expectEqual(@as(usize, 5), rules.len);
    try std.testing.expectEqualStrings("before", rules[0].style_rule.selectors.selectors[0].head.simple_selectors[0].class.name.value);
    try std.testing.expectEqual(@as(usize, 2), rules[0].style_rule.block.declarations.declarations.len);
    try std.testing.expectEqualStrings("after", rules[1].style_rule.selectors.selectors[0].head.simple_selectors[0].class.name.value);

    const media = rules[2].at_rule.details.?.media;
    try std.testing.expectEqual(@as(usize, 2), media.block.rules.rules.len);
    try std.testing.expectEqualStrings("nested", media.block.rules.rules[0].style_rule.selectors.selectors[0].head.simple_selectors[0].class.name.value);
    try std.testing.expectEqualStrings("d", media.block.rules.rules[0].style_rule.block.declarations.declarations[0].name.value);
    try std.testing.expectEqualStrings("tail", media.block.rules.rules[1].style_rule.selectors.selectors[0].head.simple_selectors[0].class.name.value);

    const keyframes = rules[3].at_rule.details.?.keyframes;
    try std.testing.expectEqual(@as(usize, 2), keyframes.block.frames.len);
    try std.testing.expectEqual(@as(f64, 25), keyframes.block.frames[0].selectors[0].percentage.value);
    try std.testing.expectEqualStrings("y", keyframes.block.frames[0].block.declarations.declarations[0].name.value);

    const page = rules[4].at_rule.details.?.page;
    try std.testing.expectEqual(@as(usize, 1), page.declarations.declarations.len);
    try std.testing.expectEqualStrings("size", page.declarations.declarations[0].name.value);
    try std.testing.expectEqual(@as(usize, 1), page.margins.len);
    try std.testing.expectEqualStrings("content", page.margins[0].declarations.declarations[0].name.value);

    const diagnostic_items = context.diagnostics.items();
    try std.testing.expectEqual(@as(usize, 10), diagnostic_items.len);
    const file = try context.sources.get(parsed[0]);
    var previous_start: usize = 0;
    for (diagnostic_items) |diagnostic| {
        _ = try file.slice(diagnostic.span);
        try std.testing.expect(diagnostic.span.start >= previous_start);
        previous_start = diagnostic.span.start;
    }
}

test "syntax-diagnosed stray closers do not consume the following valid rule" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "stray-closers.css",
        "}].before{x:1}@media all{).nested{y:2}}.after{z:3}",
    );
    const rules = parsed[1].rules;

    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqualStrings("before", rules[0].style_rule.selectors.selectors[0].head.simple_selectors[0].class.name.value);
    const media = rules[1].at_rule.details.?.media;
    try std.testing.expectEqual(@as(usize, 1), media.block.rules.rules.len);
    try std.testing.expectEqualStrings("nested", media.block.rules.rules[0].style_rule.selectors.selectors[0].head.simple_selectors[0].class.name.value);
    try std.testing.expectEqualStrings("after", rules[2].style_rule.selectors.selectors[0].head.simple_selectors[0].class.name.value);
    try std.testing.expectEqual(@as(usize, 3), context.diagnostics.items().len);
}

test "every typed parser truncation boundary remains recoverable with valid diagnostic spans" {
    const css = "@media all{.café:not(.x,.y){color:fn(1;[x]);broken}@supports (display:grid){.b{x:1}}}@keyframes f{from{opacity:0}50%{opacity:1}}@page:left{size:A4;@top-left{content:\"x\"}}";
    var cut: usize = 0;
    while (cut <= css.len) : (cut += 1) {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const parsed = try parseSource(&context, "typed-prefix.css", css[0..cut]);
        const file = try context.sources.get(parsed[0]);
        _ = try ast.RuleList.init(parsed[1].span, parsed[1].rules);
        for (context.diagnostics.items()) |diagnostic| {
            try std.testing.expect(diagnostic.span.source.eql(parsed[0]));
            _ = try file.slice(diagnostic.span);
        }
    }
}

test "every single byte survives typed rule recovery" {
    var raw: [1]u8 = undefined;
    var value: usize = 0;
    while (value <= std.math.maxInt(u8)) : (value += 1) {
        raw[0] = @intCast(value);
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const parsed = try parseSource(&context, "typed-byte.css", &raw);
        const file = try context.sources.get(parsed[0]);
        _ = try ast.RuleList.init(parsed[1].span, parsed[1].rules);
        for (context.diagnostics.items()) |diagnostic| {
            _ = try file.slice(diagnostic.span);
        }
    }
}

fn exerciseSynchronizedRecoveryAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "oom-synchronized-recovery.css", synchronized_recovery_css);
    try std.testing.expectEqual(@as(usize, 5), parsed[1].rules.len);
    try std.testing.expectEqual(@as(usize, 10), context.diagnostics.items().len);
}

test "synchronized recovery handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSynchronizedRecoveryAllocationFailures,
        .{},
    );
}
