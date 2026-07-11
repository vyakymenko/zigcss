const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const emitter = @import("emitter.zig");
const rule_parser = @import("rule_parser.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidSpan,
    InvalidToken,
    SourceMismatch,
};

pub fn equivalent(
    allocator: std.mem.Allocator,
    left_file: *const source.SourceFile,
    left: *const ast.RuleList,
    right_file: *const source.SourceFile,
    right: *const ast.RuleList,
) Error!bool {
    if (!left.span.source.eql(left_file.id) or !right.span.source.eql(right_file.id)) {
        return error.SourceMismatch;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var comparator = Comparator{
        .allocator = arena.allocator(),
        .left_file = left_file,
        .right_file = right_file,
    };
    return comparator.ruleLists(left, right);
}

const Comparator = struct {
    allocator: std.mem.Allocator,
    left_file: *const source.SourceFile,
    right_file: *const source.SourceFile,

    fn ruleLists(self: *Comparator, left: *const ast.RuleList, right: *const ast.RuleList) Error!bool {
        if (left.rules.len != right.rules.len) return false;
        for (left.rules, right.rules) |left_rule, right_rule| {
            if (!try self.rules(left_rule, right_rule)) return false;
        }
        return true;
    }

    fn rules(self: *Comparator, left: ast.Rule, right: ast.Rule) Error!bool {
        return switch (left) {
            .style_rule => |left_rule| switch (right) {
                .style_rule => |right_rule| try self.styleRules(left_rule, right_rule),
                else => false,
            },
            .at_rule => |left_rule| switch (right) {
                .at_rule => |right_rule| try self.atRules(left_rule, right_rule),
                else => false,
            },
            .nested_declarations => |left_rule| switch (right) {
                .nested_declarations => |right_rule| try self.declarationLists(
                    &left_rule.declarations,
                    &right_rule.declarations,
                ),
                else => false,
            },
        };
    }

    fn styleRules(self: *Comparator, left: *const ast.StyleRule, right: *const ast.StyleRule) Error!bool {
        return try self.selectorLists(&left.selectors, &right.selectors) and
            try self.declarationLists(&left.block.declarations, &right.block.declarations) and
            try self.ruleLists(&left.block.rules, &right.block.rules);
    }

    fn selectorLists(self: *Comparator, left: *const ast.SelectorList, right: *const ast.SelectorList) Error!bool {
        if (left.selectors.len != right.selectors.len) return false;
        for (left.selectors, right.selectors) |left_selector, right_selector| {
            if (!try self.complexSelectors(left_selector, right_selector)) return false;
        }
        return true;
    }

    fn complexSelectors(self: *Comparator, left: ast.ComplexSelector, right: ast.ComplexSelector) Error!bool {
        if (left.implicit_nesting != right.implicit_nesting or
            !optionalCombinatorsEqual(left.leading_combinator, right.leading_combinator)) return false;
        if (!try self.compoundSelectors(left.head, right.head)) return false;
        if (left.tails.len != right.tails.len) return false;
        for (left.tails, right.tails) |left_tail, right_tail| {
            if (left_tail.combinator.kind != right_tail.combinator.kind or
                !try self.compoundSelectors(left_tail.compound, right_tail.compound))
            {
                return false;
            }
        }
        return true;
    }

    fn compoundSelectors(self: *Comparator, left: ast.CompoundSelector, right: ast.CompoundSelector) Error!bool {
        if (left.simple_selectors.len != right.simple_selectors.len) return false;
        for (left.simple_selectors, right.simple_selectors) |left_simple, right_simple| {
            if (!try self.simpleSelectors(left_simple, right_simple)) return false;
        }
        return true;
    }

    fn simpleSelectors(self: *Comparator, left: ast.SimpleSelector, right: ast.SimpleSelector) Error!bool {
        return switch (left) {
            .type_selector => |left_selector| switch (right) {
                .type_selector => |right_selector| namespacesEqual(left_selector.namespace, right_selector.namespace) and
                    identifiersEqual(left_selector.name, right_selector.name),
                else => false,
            },
            .universal => |left_selector| switch (right) {
                .universal => |right_selector| namespacesEqual(left_selector.namespace, right_selector.namespace),
                else => false,
            },
            .id => |left_selector| switch (right) {
                .id => |right_selector| identifiersEqual(left_selector.name, right_selector.name),
                else => false,
            },
            .class => |left_selector| switch (right) {
                .class => |right_selector| identifiersEqual(left_selector.name, right_selector.name),
                else => false,
            },
            .attribute => |left_selector| switch (right) {
                .attribute => |right_selector| try self.attributeSelectors(left_selector, right_selector),
                else => false,
            },
            .pseudo_class => |left_selector| switch (right) {
                .pseudo_class => |right_selector| try self.pseudos(
                    left_selector.name,
                    left_selector.arguments,
                    right_selector.name,
                    right_selector.arguments,
                ),
                else => false,
            },
            .pseudo_element => |left_selector| switch (right) {
                .pseudo_element => |right_selector| try self.pseudos(
                    left_selector.name,
                    left_selector.arguments,
                    right_selector.name,
                    right_selector.arguments,
                ),
                else => false,
            },
            .nesting => switch (right) {
                .nesting => true,
                else => false,
            },
        };
    }

    fn attributeSelectors(
        self: *Comparator,
        left: *const ast.AttributeSelector,
        right: *const ast.AttributeSelector,
    ) Error!bool {
        _ = self;
        if (!namespacesEqual(left.namespace, right.namespace) or
            !identifiersEqual(left.name, right.name) or
            !optionalMatchersEqual(left.matcher, right.matcher) or
            !attributeValuesEqual(left.value, right.value) or
            !attributeModifiersEqual(left.modifier, right.modifier))
        {
            return false;
        }
        return true;
    }

    fn pseudos(
        self: *Comparator,
        left_name: ast.Identifier,
        left_arguments: ?ast.PseudoArguments,
        right_name: ast.Identifier,
        right_arguments: ?ast.PseudoArguments,
    ) Error!bool {
        if (!identifiersEqual(left_name, right_name)) return false;
        if ((left_arguments == null) != (right_arguments == null)) return false;
        if (left_arguments == null) return true;
        const left_value = left_arguments.?;
        const right_value = right_arguments.?;
        if (!try self.rawComponentLists(left_value.values, right_value.values)) return false;
        if ((left_value.parsed == null) != (right_value.parsed == null)) return false;
        if (left_value.parsed) |left_parsed| {
            return switch (left_parsed) {
                .selector_list => |left_list| switch (right_value.parsed.?) {
                    .selector_list => |right_list| try self.selectorLists(left_list, right_list),
                },
            };
        }
        return true;
    }

    fn declarationLists(
        self: *Comparator,
        left: *const ast.DeclarationList,
        right: *const ast.DeclarationList,
    ) Error!bool {
        if (left.declarations.len != right.declarations.len) return false;
        for (left.declarations, right.declarations) |left_declaration, right_declaration| {
            if (!identifiersEqual(left_declaration.name, right_declaration.name) or
                (left_declaration.important == null) != (right_declaration.important == null) or
                !try self.componentLists(
                    left_declaration.valueWithoutImportance(),
                    right_declaration.valueWithoutImportance(),
                ))
            {
                return false;
            }
        }
        return true;
    }

    fn atRules(self: *Comparator, left: *const ast.AtRule, right: *const ast.AtRule) Error!bool {
        if (!identifiersEqual(left.name, right.name) or !detailsTagsEqual(left.details, right.details)) {
            return false;
        }
        const left_page = pageDetails(left.details);
        const right_page = pageDetails(right.details);
        if (left_page == null) {
            const same_prelude = if (left.details == null)
                try self.rawComponentLists(left.prelude.values, right.prelude.values)
            else
                try self.componentLists(left.prelude.values, right.prelude.values);
            if (!same_prelude) return false;
        }
        return switch (left.block) {
            .none => switch (right.block) {
                .none => true,
                else => false,
            },
            .declarations => |left_block| switch (right.block) {
                .declarations => |right_block| try self.declarationLists(
                    &left_block.declarations,
                    &right_block.declarations,
                ),
                else => false,
            },
            .rules => |left_block| switch (right.block) {
                .rules => |right_block| left_block.nested == right_block.nested and
                    try self.ruleLists(&left_block.rules, &right_block.rules),
                else => false,
            },
            .keyframes => |left_block| switch (right.block) {
                .keyframes => |right_block| try self.keyframes(left_block, right_block),
                else => false,
            },
            .raw => |left_block| switch (right.block) {
                .raw => |right_block| if (left_page) |left_page_value|
                    if (right_page) |right_page_value|
                        try self.pages(left_page_value, right_page_value)
                    else
                        false
                else
                    try self.rawComponentLists(left_block.values.values, right_block.values.values),
                else => false,
            },
        };
    }

    fn keyframes(
        self: *Comparator,
        left: *const ast.KeyframesBlock,
        right: *const ast.KeyframesBlock,
    ) Error!bool {
        if (left.frames.len != right.frames.len) return false;
        for (left.frames, right.frames) |left_frame, right_frame| {
            if (left_frame.selectors.len != right_frame.selectors.len) return false;
            for (left_frame.selectors, right_frame.selectors) |left_selector, right_selector| {
                if (!keyframeSelectorsEqual(left_selector, right_selector)) return false;
            }
            if (!try self.declarationLists(
                &left_frame.block.declarations,
                &right_frame.block.declarations,
            )) return false;
        }
        return true;
    }

    fn pages(self: *Comparator, left: *const ast.PageRule, right: *const ast.PageRule) Error!bool {
        if (left.selectors.len != right.selectors.len or left.margins.len != right.margins.len) return false;
        for (left.selectors, right.selectors) |left_selector, right_selector| {
            if (!pageSelectorsEqual(left_selector, right_selector)) return false;
        }
        if (!try self.declarationLists(left.declarations, right.declarations)) return false;
        for (left.margins, right.margins) |left_margin, right_margin| {
            if (!identifiersEqual(left_margin.name, right_margin.name) or
                !try self.declarationLists(left_margin.declarations, right_margin.declarations))
            {
                return false;
            }
        }
        return pageItemOrderEqual(left, right);
    }

    fn componentLists(
        self: *Comparator,
        left: []const syntax.ComponentValue,
        right: []const syntax.ComponentValue,
    ) Error!bool {
        return self.componentListsWithEdges(left, right, true);
    }

    fn rawComponentLists(
        self: *Comparator,
        left: []const syntax.ComponentValue,
        right: []const syntax.ComponentValue,
    ) Error!bool {
        return self.componentListsWithEdges(left, right, false);
    }

    fn componentListsWithEdges(
        self: *Comparator,
        left: []const syntax.ComponentValue,
        right: []const syntax.ComponentValue,
        trim_edges: bool,
    ) Error!bool {
        var left_iterator = SemanticIterator{ .values = left, .trim_edges = trim_edges };
        var right_iterator = SemanticIterator{ .values = right, .trim_edges = trim_edges };
        while (true) {
            const left_item = left_iterator.next();
            const right_item = right_iterator.next();
            if (left_item == null or right_item == null) return left_item == null and right_item == null;
            switch (left_item.?) {
                .whitespace => if (right_item.? != .whitespace) return false,
                .component => |left_component| switch (right_item.?) {
                    .component => |right_component| if (!try self.components(left_component, right_component)) return false,
                    else => return false,
                },
            }
        }
    }

    fn components(self: *Comparator, left: syntax.ComponentValue, right: syntax.ComponentValue) Error!bool {
        return switch (left) {
            .token => |left_token| switch (right) {
                .token => |right_token| try self.tokens(left_token, right_token),
                else => false,
            },
            .simple_block => |left_block| switch (right) {
                .simple_block => |right_block| left_block.opening.kind == right_block.opening.kind and
                    left_block.terminated() == right_block.terminated() and
                    try self.rawComponentLists(left_block.values, right_block.values),
                else => false,
            },
            .function => |left_function| switch (right) {
                .function => |right_function| left_function.terminated() == right_function.terminated() and
                    try self.tokenTextEqual(left_function.opening, right_function.opening) and
                    try self.rawComponentLists(left_function.values, right_function.values),
                else => false,
            },
        };
    }

    fn tokens(self: *Comparator, left: tokenizer.Token, right: tokenizer.Token) Error!bool {
        if (left.kind != right.kind or left.isTerminated() != right.isTerminated()) return false;
        return switch (left.kind) {
            .ident, .function, .at_keyword, .string, .bad_string, .url, .bad_url => try self.tokenTextEqual(left, right),
            .hash => left.data.hash.hash_type == right.data.hash.hash_type and try self.tokenTextEqual(left, right),
            .delim => left.data.delim == right.data.delim,
            .number, .percentage => numericEqual(left.data.numeric, right.data.numeric),
            .dimension => numericEqual(left.data.dimension.numeric, right.data.dimension.numeric) and
                try self.tokenTextEqual(left, right),
            .comment => true,
            .unicode_range => left.data.unicode_range.start == right.data.unicode_range.start and
                left.data.unicode_range.end == right.data.unicode_range.end,
            else => true,
        };
    }

    fn tokenTextEqual(self: *Comparator, left: tokenizer.Token, right: tokenizer.Token) Error!bool {
        const left_text = left.decodedTextAlloc(self.allocator, self.left_file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourceMismatch => return error.SourceMismatch,
            else => return error.InvalidToken,
        };
        const right_text = right.decodedTextAlloc(self.allocator, self.right_file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourceMismatch => return error.SourceMismatch,
            else => return error.InvalidToken,
        };
        return std.mem.eql(u8, left_text, right_text);
    }
};

const SemanticItem = union(enum) {
    whitespace,
    component: syntax.ComponentValue,
};

const SemanticIterator = struct {
    values: []const syntax.ComponentValue,
    index: usize = 0,
    saw_component: bool = false,
    trim_edges: bool,

    fn next(self: *SemanticIterator) ?SemanticItem {
        while (true) {
            while (self.index < self.values.len and isComment(self.values[self.index])) self.index += 1;
            if (self.index == self.values.len) return null;
            if (isWhitespace(self.values[self.index])) {
                var next_index = self.index;
                while (next_index < self.values.len and isTrivia(self.values[next_index])) next_index += 1;
                self.index = next_index;
                if (self.trim_edges and (!self.saw_component or self.index == self.values.len)) {
                    if (self.index == self.values.len) return null;
                    continue;
                }
                return .whitespace;
            }
            const value = self.values[self.index];
            self.index += 1;
            self.saw_component = true;
            return .{ .component = value };
        }
    }
};

fn optionalCombinatorsEqual(left: ?ast.Combinator, right: ?ast.Combinator) bool {
    if ((left == null) != (right == null)) return false;
    return left == null or left.?.kind == right.?.kind;
}

fn identifiersEqual(left: ast.Identifier, right: ast.Identifier) bool {
    return std.mem.eql(u8, left.value, right.value);
}

fn namespacesEqual(left: ast.Namespace, right: ast.Namespace) bool {
    return switch (left) {
        .implicit => right == .implicit,
        .any => right == .any,
        .empty => right == .empty,
        .named => |left_name| switch (right) {
            .named => |right_name| identifiersEqual(left_name, right_name),
            else => false,
        },
    };
}

fn optionalMatchersEqual(left: ?ast.AttributeMatcher, right: ?ast.AttributeMatcher) bool {
    if ((left == null) != (right == null)) return false;
    return left == null or left.?.kind == right.?.kind;
}

fn attributeValuesEqual(left: ?ast.AttributeValue, right: ?ast.AttributeValue) bool {
    if ((left == null) != (right == null)) return false;
    if (left == null) return true;
    return switch (left.?) {
        .identifier => |left_value| switch (right.?) {
            .identifier => |right_value| identifiersEqual(left_value, right_value),
            else => false,
        },
        .string => |left_value| switch (right.?) {
            .string => |right_value| std.mem.eql(u8, left_value.value, right_value.value),
            else => false,
        },
    };
}

fn attributeModifiersEqual(left: ?ast.AttributeModifier, right: ?ast.AttributeModifier) bool {
    if ((left == null) != (right == null)) return false;
    if (left == null) return true;
    return switch (left.?) {
        .insensitive => right.? == .insensitive,
        .sensitive => right.? == .sensitive,
        .unknown => |left_value| switch (right.?) {
            .unknown => |right_value| identifiersEqual(left_value, right_value),
            else => false,
        },
    };
}

fn detailsTagsEqual(left: ?ast.AtRuleDetails, right: ?ast.AtRuleDetails) bool {
    if ((left == null) != (right == null)) return false;
    return left == null or std.meta.activeTag(left.?) == std.meta.activeTag(right.?);
}

fn pageDetails(details: ?ast.AtRuleDetails) ?*const ast.PageRule {
    const value = details orelse return null;
    return switch (value) {
        .page => |page| page,
        else => null,
    };
}

fn keyframeSelectorsEqual(left: ast.KeyframeSelector, right: ast.KeyframeSelector) bool {
    return switch (left) {
        .from => right == .from,
        .to => right == .to,
        .percentage => |left_value| switch (right) {
            .percentage => |right_value| left_value.value == right_value.value,
            else => false,
        },
    };
}

fn pageSelectorsEqual(left: ast.PageSelector, right: ast.PageSelector) bool {
    if ((left.name == null) != (right.name == null) or left.pseudos.len != right.pseudos.len) return false;
    if (left.name) |left_name| if (!identifiersEqual(left_name, right.name.?)) return false;
    for (left.pseudos, right.pseudos) |left_pseudo, right_pseudo| {
        if (!identifiersEqual(left_pseudo, right_pseudo)) return false;
    }
    return true;
}

const PageItemKind = enum { declaration, margin };

fn pageItemOrderEqual(left: *const ast.PageRule, right: *const ast.PageRule) bool {
    var left_declaration: usize = 0;
    var left_margin: usize = 0;
    var right_declaration: usize = 0;
    var right_margin: usize = 0;
    const total = left.declarations.declarations.len + left.margins.len;
    var index: usize = 0;
    while (index < total) : (index += 1) {
        const left_kind = nextPageItemKind(left, &left_declaration, &left_margin);
        const right_kind = nextPageItemKind(right, &right_declaration, &right_margin);
        if (left_kind != right_kind) return false;
    }
    return true;
}

fn nextPageItemKind(page: *const ast.PageRule, declaration: *usize, margin: *usize) PageItemKind {
    if (declaration.* == page.declarations.declarations.len) {
        margin.* += 1;
        return .margin;
    }
    if (margin.* == page.margins.len or
        page.declarations.declarations[declaration.*].span.start <= page.margins[margin.*].span.start)
    {
        declaration.* += 1;
        return .declaration;
    }
    margin.* += 1;
    return .margin;
}

fn numericEqual(left: tokenizer.Numeric, right: tokenizer.Numeric) bool {
    return left.value == right.value and left.number_type == right.number_type and left.sign == right.sign;
}

fn isTrivia(value: syntax.ComponentValue) bool {
    return isWhitespace(value) or isComment(value);
}

fn isWhitespace(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
}

fn isComment(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .comment,
        else => false,
    };
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

test "pretty and minified parse emit parse pipelines are structurally equivalent and idempotent" {
    const corpus = [_][]const u8{
        ".a.b,svg|button:hover>#\\31 id[data-x='a\"b'i]{color:red;color:blue!important;--x:fn(a/**/b)}",
        "@media screen and (width>1px){.a{x:1}}@supports (display:grid) and selector(.b){.b{x:2}}@container card (width>2px){.c{x:3}}",
        "@layer base.components,theme;@property --theme{syntax:\"<color>\";inherits:false;initial-value:red}@font-face{font-family:'A';src:url(x)}@keyframes fade{from,50%{opacity:0}100%{opacity:1}}@page invoice:first,:left{margin:1cm;@top-left{content:\"Invoice\"}size:A4}",
        "@unknown(foo){a(1;[x])}",
        ":is(.a, ., .b) .child{--value:calc(1 + 2);content:\"x\"}",
        ".card{color:red;.title{font-weight:bold}@media (width>40rem){display:grid;> .icon{opacity:1}gap:1rem}background:blue;&.active{color:green}}",
    };
    const modes = [_]emitter.Mode{ .pretty, .minified };
    for (corpus) |css| {
        var original_context = try compilation.Compilation.init(std.testing.allocator);
        defer original_context.deinit();
        const original = try parseSource(&original_context, "round-original.css", css);
        try std.testing.expectEqual(@as(usize, 0), original_context.diagnostics.items().len);

        for (modes) |mode| {
            const first_output = try emitter.emit(
                std.testing.allocator,
                try original_context.sources.get(original[0]),
                original[1],
                .{ .mode = mode },
            );
            defer std.testing.allocator.free(first_output);

            var emitted_context = try compilation.Compilation.init(std.testing.allocator);
            defer emitted_context.deinit();
            const emitted = try parseSource(&emitted_context, "round-emitted.css", first_output);
            try std.testing.expectEqual(@as(usize, 0), emitted_context.diagnostics.items().len);
            const same = try equivalent(
                std.testing.allocator,
                try original_context.sources.get(original[0]),
                original[1],
                try emitted_context.sources.get(emitted[0]),
                emitted[1],
            );
            try std.testing.expect(same);

            const second_output = try emitter.emit(
                std.testing.allocator,
                try emitted_context.sources.get(emitted[0]),
                emitted[1],
                .{ .mode = mode },
            );
            defer std.testing.allocator.free(second_output);
            try std.testing.expectEqualStrings(first_output, second_output);
        }
    }
}

test "semantic equivalence detects selector cascade and at-rule changes" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ ".a.b{x:1}", ".a .b{x:1}" },
        .{ ".a{color:red;color:blue}", ".a{color:blue;color:red}" },
        .{ ".a{color:red!important}", ".a{color:red}" },
        .{ "@media all{.a{x:1}}.b{x:2}", ".b{x:2}@media all{.a{x:1}}" },
        .{ "@keyframes f{from{x:1}to{x:2}}", "@keyframes f{from{x:1}50%{x:2}}" },
        .{ ".a{--x:a b}", ".a{--x:ab}" },
        .{ "@unknown(foo){ a( b ) }", "@unknown (foo){ a( b ) }" },
        .{ "@unknown(foo){ a( b ) }", "@unknown(foo){a(b)}" },
        .{ "@page{a:1;@top-left{x:1}b:2}", "@page{a:1;b:2;@top-left{x:1}}" },
        .{ ".a{x:1;.b{z:0}y:2}", ".a{x:1;y:2;.b{z:0}}" },
    };
    for (cases) |case| {
        var left_context = try compilation.Compilation.init(std.testing.allocator);
        defer left_context.deinit();
        const left = try parseSource(&left_context, "left.css", case[0]);
        var right_context = try compilation.Compilation.init(std.testing.allocator);
        defer right_context.deinit();
        const right = try parseSource(&right_context, "right.css", case[1]);

        try std.testing.expect(!try equivalent(
            std.testing.allocator,
            try left_context.sources.get(left[0]),
            left[1],
            try right_context.sources.get(right[0]),
            right[1],
        ));
    }
}

test "semantic equivalence ignores spans escape spelling quote style and trivia width" {
    var left_context = try compilation.Compilation.init(std.testing.allocator);
    defer left_context.deinit();
    const left = try parseSource(
        &left_context,
        "representation-left.css",
        ".\\61/**/.b[data='x']{color :   red}",
    );
    var right_context = try compilation.Compilation.init(std.testing.allocator);
    defer right_context.deinit();
    const right = try parseSource(
        &right_context,
        "representation-right.css",
        ".a.b[data=\"x\"]{color:red;}",
    );

    try std.testing.expect(try equivalent(
        std.testing.allocator,
        try left_context.sources.get(left[0]),
        left[1],
        try right_context.sources.get(right[0]),
        right[1],
    ));
}

test "semantic equivalence validates each AST source binding" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const first = try parseSource(&context, "binding-first.css", ".a{x:1}");
    const second = try parseSource(&context, "binding-second.css", ".a{x:1}");

    try std.testing.expectError(
        error.SourceMismatch,
        equivalent(
            std.testing.allocator,
            try context.sources.get(second[0]),
            first[1],
            try context.sources.get(second[0]),
            second[1],
        ),
    );
}

fn exerciseRoundTripAllocationFailures(allocator: std.mem.Allocator) !void {
    var original_context = try compilation.Compilation.init(allocator);
    defer original_context.deinit();
    const original = try parseSource(
        &original_context,
        "oom-round-original.css",
        ".a,.b>.c{color:red;.nested{color:blue!important}@media all{display:grid;> .d{x:1}}--x:fn(a/**/b)}@keyframes f{from{opacity:0}to{opacity:1}}",
    );
    const output = try emitter.emit(
        allocator,
        try original_context.sources.get(original[0]),
        original[1],
        .{ .mode = .minified },
    );
    defer allocator.free(output);

    var emitted_context = try compilation.Compilation.init(allocator);
    defer emitted_context.deinit();
    const emitted = try parseSource(&emitted_context, "oom-round-emitted.css", output);
    try std.testing.expect(try equivalent(
        allocator,
        try original_context.sources.get(original[0]),
        original[1],
        try emitted_context.sources.get(emitted[0]),
        emitted[1],
    ));
}

test "structural round trips handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRoundTripAllocationFailures,
        .{},
    );
}
