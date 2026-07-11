const std = @import("std");
const compilation = @import("../compilation.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");

pub const SelectorError = error{
    EmptyCompoundSelector,
    EmptySelectorList,
    InvalidAttributeSelector,
    InvalidSpan,
    InvalidTypeSelectorPosition,
    SourceMismatch,
    SpanOutsideParent,
};

pub const Identifier = struct {
    /// Decoded identifier value owned by the compilation arena.
    value: []const u8,
    /// Original spelling, excluding selector punctuation such as `.` or `#`.
    span: source.Span,
};

pub const Namespace = union(enum) {
    /// No namespace prefix was written.
    implicit,
    /// `*|`
    any: source.Span,
    /// `|`
    empty: source.Span,
    /// `<ident>|`
    named: Identifier,

    pub fn span(self: Namespace) ?source.Span {
        return switch (self) {
            .implicit => null,
            .any => |value| value,
            .empty => |value| value,
            .named => |value| value.span,
        };
    }
};

pub const CombinatorKind = enum {
    descendant,
    child,
    next_sibling,
    subsequent_sibling,
    column,
};

pub const Combinator = struct {
    kind: CombinatorKind,
    /// Includes the significant delimiter and any trivia assigned to it.
    span: source.Span,
};

pub const TypeSelector = struct {
    namespace: Namespace = .implicit,
    name: Identifier,
    span: source.Span,
};

pub const UniversalSelector = struct {
    namespace: Namespace = .implicit,
    span: source.Span,
};

pub const NamedSelector = struct {
    name: Identifier,
    /// Includes `.` or `#`.
    span: source.Span,
};

pub const AttributeMatcherKind = enum {
    exact,
    includes,
    dash,
    prefix,
    suffix,
    substring,
};

pub const AttributeMatcher = struct {
    kind: AttributeMatcherKind,
    span: source.Span,
};

pub const QuoteStyle = enum {
    single,
    double,
};

pub const StringValue = struct {
    value: []const u8,
    quote: QuoteStyle,
    span: source.Span,
    value_span: source.Span,
};

pub const AttributeValue = union(enum) {
    identifier: Identifier,
    string: StringValue,

    pub fn span(self: AttributeValue) source.Span {
        return switch (self) {
            .identifier => |value| value.span,
            .string => |value| value.span,
        };
    }
};

pub const AttributeModifier = union(enum) {
    insensitive: source.Span,
    sensitive: source.Span,
    unknown: Identifier,

    pub fn span(self: AttributeModifier) source.Span {
        return switch (self) {
            .insensitive => |value| value,
            .sensitive => |value| value,
            .unknown => |value| value.span,
        };
    }
};

pub const AttributeSelector = struct {
    namespace: Namespace = .implicit,
    name: Identifier,
    matcher: ?AttributeMatcher = null,
    value: ?AttributeValue = null,
    modifier: ?AttributeModifier = null,
    span: source.Span,

    pub fn init(candidate: AttributeSelector) SelectorError!AttributeSelector {
        try validateSpan(candidate.span);
        try validateChild(candidate.span, candidate.name.span);
        if (candidate.namespace.span()) |namespace_span| {
            try validateChild(candidate.span, namespace_span);
            if (namespace_span.end > candidate.name.span.start) return error.InvalidAttributeSelector;
        }

        if ((candidate.matcher == null) != (candidate.value == null)) {
            return error.InvalidAttributeSelector;
        }
        if (candidate.modifier != null and candidate.matcher == null) {
            return error.InvalidAttributeSelector;
        }
        if (candidate.matcher) |matcher| {
            try validateChild(candidate.span, matcher.span);
            if (matcher.span.start < candidate.name.span.end) return error.InvalidAttributeSelector;
        }
        if (candidate.value) |value| {
            try validateChild(candidate.span, value.span());
            if (value == .string) try validateChild(value.string.span, value.string.value_span);
            if (candidate.matcher) |matcher| {
                if (value.span().start < matcher.span.end) return error.InvalidAttributeSelector;
            }
        }
        if (candidate.modifier) |modifier| {
            try validateChild(candidate.span, modifier.span());
            if (candidate.value) |value| {
                if (modifier.span().start < value.span().end) return error.InvalidAttributeSelector;
            }
        }
        return candidate;
    }
};

pub const ParsedPseudoArguments = union(enum) {
    selector_list: *const SelectorList,
};

pub const PseudoArguments = struct {
    /// Span between the function's parentheses.
    span: source.Span,
    /// Always retained, even when a typed interpretation is available.
    values: []const syntax.ComponentValue,
    parsed: ?ParsedPseudoArguments = null,
};

pub const PseudoClass = struct {
    name: Identifier,
    arguments: ?PseudoArguments = null,
    span: source.Span,
};

pub const PseudoElement = struct {
    name: Identifier,
    arguments: ?PseudoArguments = null,
    span: source.Span,
};

pub const SimpleSelector = union(enum) {
    type_selector: TypeSelector,
    universal: UniversalSelector,
    id: NamedSelector,
    class: NamedSelector,
    attribute: *const AttributeSelector,
    pseudo_class: *const PseudoClass,
    pseudo_element: *const PseudoElement,
    nesting: source.Span,

    pub fn span(self: SimpleSelector) source.Span {
        return switch (self) {
            .type_selector => |value| value.span,
            .universal => |value| value.span,
            .id => |value| value.span,
            .class => |value| value.span,
            .attribute => |value| value.span,
            .pseudo_class => |value| value.span,
            .pseudo_element => |value| value.span,
            .nesting => |value| value,
        };
    }
};

pub const CompoundSelector = struct {
    simple_selectors: []const SimpleSelector,
    span: source.Span,

    pub fn init(span: source.Span, simple_selectors: []const SimpleSelector) SelectorError!CompoundSelector {
        try validateSpan(span);
        if (simple_selectors.len == 0) return error.EmptyCompoundSelector;

        var previous_end = span.start;
        for (simple_selectors, 0..) |simple, index| {
            try validateChild(span, simple.span());
            try validateSimpleSelector(simple);
            if (simple.span().start < previous_end) return error.SpanOutsideParent;
            switch (simple) {
                .type_selector, .universal => if (index != 0) {
                    return error.InvalidTypeSelectorPosition;
                },
                else => {},
            }
            previous_end = simple.span().end;
        }
        return .{ .simple_selectors = simple_selectors, .span = span };
    }
};

pub const ComplexSelectorTail = struct {
    combinator: Combinator,
    compound: CompoundSelector,
    span: source.Span,
};

pub const ComplexSelector = struct {
    /// Present for relative selectors such as `> .item`.
    leading_combinator: ?Combinator,
    head: CompoundSelector,
    tails: []const ComplexSelectorTail,
    span: source.Span,

    pub fn init(
        span: source.Span,
        leading_combinator: ?Combinator,
        head: CompoundSelector,
        tails: []const ComplexSelectorTail,
    ) SelectorError!ComplexSelector {
        try validateSpan(span);
        try validateChild(span, head.span);
        if (leading_combinator) |combinator| {
            try validateChild(span, combinator.span);
            if (combinator.span.end > head.span.start) return error.SpanOutsideParent;
        }
        var previous_end = head.span.end;
        for (tails) |tail| {
            try validateChild(span, tail.span);
            try validateChild(tail.span, tail.combinator.span);
            try validateChild(tail.span, tail.compound.span);
            if (tail.span.start < previous_end or
                tail.combinator.span.end > tail.compound.span.start)
            {
                return error.SpanOutsideParent;
            }
            previous_end = tail.span.end;
        }
        return .{
            .leading_combinator = leading_combinator,
            .head = head,
            .tails = tails,
            .span = span,
        };
    }
};

pub const SelectorList = struct {
    selectors: []const ComplexSelector,
    span: source.Span,

    pub fn init(span: source.Span, selectors: []const ComplexSelector) SelectorError!SelectorList {
        try validateSpan(span);
        if (selectors.len == 0) return error.EmptySelectorList;
        var previous_end = span.start;
        for (selectors) |selector| {
            try validateChild(span, selector.span);
            if (selector.span.start < previous_end) return error.SpanOutsideParent;
            previous_end = selector.span.end;
        }
        return .{ .selectors = selectors, .span = span };
    }
};

fn validateSpan(span: source.Span) SelectorError!void {
    if (span.start > span.end) return error.InvalidSpan;
}

fn validateChild(parent: source.Span, child: source.Span) SelectorError!void {
    try validateSpan(parent);
    try validateSpan(child);
    if (!parent.source.eql(child.source)) return error.SourceMismatch;
    if (child.start < parent.start or child.end > parent.end) return error.SpanOutsideParent;
}

fn validateSimpleSelector(simple: SimpleSelector) SelectorError!void {
    const parent = simple.span();
    switch (simple) {
        .type_selector => |value| {
            try validateChild(parent, value.name.span);
            if (value.namespace.span()) |namespace_span| {
                try validateChild(parent, namespace_span);
                if (namespace_span.end > value.name.span.start) return error.SpanOutsideParent;
            }
        },
        .universal => |value| if (value.namespace.span()) |namespace_span| {
            try validateChild(parent, namespace_span);
        },
        .id, .class => |value| try validateChild(parent, value.name.span),
        .attribute => |value| _ = try AttributeSelector.init(value.*),
        .pseudo_class => |value| try validatePseudo(parent, value.name, value.arguments),
        .pseudo_element => |value| try validatePseudo(parent, value.name, value.arguments),
        .nesting => {},
    }
}

fn validatePseudo(
    parent: source.Span,
    name: Identifier,
    arguments: ?PseudoArguments,
) SelectorError!void {
    try validateChild(parent, name.span);
    if (arguments) |value| {
        try validateChild(parent, value.span);
        for (value.values) |component_value| try validateChild(value.span, component_value.span());
        if (value.parsed) |parsed| switch (parsed) {
            .selector_list => |selector_list| try validateChild(value.span, selector_list.span),
        };
    }
}

fn testSpan(id: source.SourceId, start: usize, end: usize) source.Span {
    return .{ .source = id, .start = start, .end = end };
}

fn classSelector(id: source.SourceId, start: usize, name: []const u8) SimpleSelector {
    return .{ .class = .{
        .name = .{ .value = name, .span = testSpan(id, start + 1, start + 1 + name.len) },
        .span = testSpan(id, start, start + 1 + name.len),
    } };
}

test "compound adjacency and descendant combinators are structurally distinct" {
    const id = source.SourceId{ .value = 1 };
    const adjacent_simples = [_]SimpleSelector{
        classSelector(id, 0, "a"),
        classSelector(id, 2, "b"),
    };
    const adjacent_compound = try CompoundSelector.init(testSpan(id, 0, 4), &adjacent_simples);
    const adjacent = try ComplexSelector.init(testSpan(id, 0, 4), null, adjacent_compound, &.{});

    const left_simples = [_]SimpleSelector{classSelector(id, 0, "a")};
    const right_simples = [_]SimpleSelector{classSelector(id, 3, "b")};
    const left = try CompoundSelector.init(testSpan(id, 0, 2), &left_simples);
    const right = try CompoundSelector.init(testSpan(id, 3, 5), &right_simples);
    const tails = [_]ComplexSelectorTail{.{
        .combinator = .{ .kind = .descendant, .span = testSpan(id, 2, 3) },
        .compound = right,
        .span = testSpan(id, 2, 5),
    }};
    const descendant = try ComplexSelector.init(testSpan(id, 0, 5), null, left, &tails);

    try std.testing.expectEqual(@as(usize, 2), adjacent.head.simple_selectors.len);
    try std.testing.expectEqual(@as(usize, 0), adjacent.tails.len);
    try std.testing.expectEqual(@as(usize, 1), descendant.head.simple_selectors.len);
    try std.testing.expectEqual(@as(usize, 1), descendant.tails.len);
    try std.testing.expectEqual(CombinatorKind.descendant, descendant.tails[0].combinator.kind);
}

test "selector constructors reject impossible compound and list shapes" {
    const first = source.SourceId{ .value = 1 };
    const second = source.SourceId{ .value = 2 };
    try std.testing.expectError(
        error.EmptyCompoundSelector,
        CompoundSelector.init(testSpan(first, 0, 0), &.{}),
    );

    const invalid_order = [_]SimpleSelector{
        classSelector(first, 0, "a"),
        .{ .type_selector = .{
            .namespace = .implicit,
            .name = .{ .value = "div", .span = testSpan(first, 2, 5) },
            .span = testSpan(first, 2, 5),
        } },
    };
    try std.testing.expectError(
        error.InvalidTypeSelectorPosition,
        CompoundSelector.init(testSpan(first, 0, 5), &invalid_order),
    );

    const wrong_source = [_]SimpleSelector{classSelector(second, 0, "x")};
    try std.testing.expectError(
        error.SourceMismatch,
        CompoundSelector.init(testSpan(first, 0, 2), &wrong_source),
    );
    try std.testing.expectError(
        error.EmptySelectorList,
        SelectorList.init(testSpan(first, 0, 0), &.{}),
    );
}

test "attributes retain namespaces operators quoting and case flags" {
    const id = source.SourceId{ .value = 3 };
    const attribute = try AttributeSelector.init(.{
        .namespace = .{ .named = .{
            .value = "ns",
            .span = testSpan(id, 1, 3),
        } },
        .name = .{ .value = "data-x", .span = testSpan(id, 4, 10) },
        .matcher = .{ .kind = .prefix, .span = testSpan(id, 10, 12) },
        .value = .{ .string = .{
            .value = "Foo",
            .quote = .double,
            .span = testSpan(id, 12, 17),
            .value_span = testSpan(id, 13, 16),
        } },
        .modifier = .{ .insensitive = testSpan(id, 18, 19) },
        .span = testSpan(id, 0, 20),
    });

    try std.testing.expectEqual(AttributeMatcherKind.prefix, attribute.matcher.?.kind);
    try std.testing.expectEqual(QuoteStyle.double, attribute.value.?.string.quote);
    try std.testing.expectEqualStrings("Foo", attribute.value.?.string.value);
    try std.testing.expect(attribute.modifier.? == .insensitive);
    try std.testing.expect(attribute.namespace == .named);

    try std.testing.expectError(error.InvalidAttributeSelector, AttributeSelector.init(.{
        .namespace = .implicit,
        .name = .{ .value = "x", .span = testSpan(id, 1, 2) },
        .matcher = null,
        .value = .{ .identifier = .{ .value = "y", .span = testSpan(id, 3, 4) } },
        .modifier = null,
        .span = testSpan(id, 0, 5),
    }));
}

test "functional pseudos retain raw component values and typed selector arguments" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("pseudo.css", ":not(.a, [x])");
    const document = try syntax.parse(&context, id);
    const function = document.values[1].function;

    const class_simples = [_]SimpleSelector{classSelector(id, 5, "a")};
    const compound = try CompoundSelector.init(testSpan(id, 5, 7), &class_simples);
    const complex = try ComplexSelector.init(testSpan(id, 5, 7), null, compound, &.{});
    const complexes = [_]ComplexSelector{complex};
    const selector_list = try SelectorList.init(testSpan(id, 5, 7), &complexes);
    const arguments = PseudoArguments{
        .span = testSpan(id, 5, 12),
        .values = function.values,
        .parsed = .{ .selector_list = &selector_list },
    };
    const pseudo = PseudoClass{
        .name = .{ .value = "not", .span = testSpan(id, 1, 4) },
        .arguments = arguments,
        .span = testSpan(id, 0, 13),
    };
    const simple = SimpleSelector{ .pseudo_class = &pseudo };

    try std.testing.expectEqualStrings(":not(.a, [x])", try (try context.sources.get(id)).slice(simple.span()));
    try std.testing.expectEqual(@as(usize, 5), pseudo.arguments.?.values.len);
    try std.testing.expect(pseudo.arguments.?.parsed.? == .selector_list);
    try std.testing.expectEqual(@as(usize, 1), pseudo.arguments.?.parsed.?.selector_list.selectors.len);
}

test "relative selectors namespaces and every combinator remain explicit" {
    const id = source.SourceId{ .value = 8 };
    const universal_simple = [_]SimpleSelector{.{ .universal = .{
        .namespace = .{ .any = testSpan(id, 2, 4) },
        .span = testSpan(id, 2, 5),
    } }};
    const universal = try CompoundSelector.init(testSpan(id, 2, 5), &universal_simple);
    const relative = try ComplexSelector.init(
        testSpan(id, 0, 5),
        .{ .kind = .child, .span = testSpan(id, 0, 1) },
        universal,
        &.{},
    );
    try std.testing.expectEqual(CombinatorKind.child, relative.leading_combinator.?.kind);
    try std.testing.expect(relative.head.simple_selectors[0].universal.namespace == .any);

    const kinds = [_]CombinatorKind{
        .descendant,
        .child,
        .next_sibling,
        .subsequent_sibling,
        .column,
    };
    try std.testing.expectEqual(@as(usize, 5), kinds.len);
    const namespaces = [_]Namespace{
        .implicit,
        .{ .any = testSpan(id, 0, 2) },
        .{ .empty = testSpan(id, 0, 1) },
        .{ .named = .{ .value = "svg", .span = testSpan(id, 0, 3) } },
    };
    try std.testing.expect(namespaces[0].span() == null);
    try std.testing.expect(namespaces[1] == .any);
    try std.testing.expect(namespaces[2] == .empty);
    try std.testing.expect(namespaces[3] == .named);
}
