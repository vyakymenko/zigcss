const std = @import("std");
const compilation = @import("../compilation.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");

pub const AstError = error{
    EmptyCompoundSelector,
    EmptySelectorList,
    InvalidAttributeSelector,
    InvalidAtRule,
    InvalidBlockSpan,
    InvalidComponentValueList,
    InvalidDeclaration,
    InvalidImportantAnnotation,
    InvalidKeyframes,
    InvalidRule,
    InvalidRuleBlock,
    InvalidSpan,
    InvalidTypeSelectorPosition,
    SourceMismatch,
    SpanOutsideParent,
};

pub const SelectorError = AstError;

pub const Identifier = struct {
    /// Decoded identifier value owned by the compilation arena.
    value: []const u8,
    /// Original spelling, excluding selector punctuation such as `.` or `#`.
    span: source.Span,

    pub fn isCustomProperty(self: Identifier) bool {
        return std.mem.startsWith(u8, self.value, "--");
    }
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
    /// True when a nested selector has an implied parent reference because no
    /// `&` delimiter occurs anywhere in its source selector.
    implicit_nesting: bool = false,
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
            .implicit_nesting = false,
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
        if (selectors.len == 0) return error.EmptySelectorList;
        return initAllowEmpty(span, selectors);
    }

    /// The Selectors specification permits an empty result after invalid items
    /// are removed from `:is()` / `:where()` forgiving selector lists.
    pub fn initForgiving(span: source.Span, selectors: []const ComplexSelector) SelectorError!SelectorList {
        return initAllowEmpty(span, selectors);
    }

    fn initAllowEmpty(span: source.Span, selectors: []const ComplexSelector) SelectorError!SelectorList {
        try validateSpan(span);
        var previous_end = span.start;
        for (selectors) |selector| {
            try validateChild(span, selector.span);
            if (selector.span.start < previous_end) return error.SpanOutsideParent;
            previous_end = selector.span.end;
        }
        return .{ .selectors = selectors, .span = span };
    }
};

/// An exact, contiguous slice of the lossless component-value stream.
pub const ComponentValueList = struct {
    values: []const syntax.ComponentValue,
    span: source.Span,

    pub fn init(span: source.Span, values: []const syntax.ComponentValue) AstError!ComponentValueList {
        try validateSpan(span);
        if (values.len == 0) {
            if (!span.isEmpty()) return error.InvalidComponentValueList;
            return .{ .values = values, .span = span };
        }
        if (values[0].span().start != span.start or values[values.len - 1].span().end != span.end) {
            return error.InvalidComponentValueList;
        }

        var previous_end = span.start;
        for (values) |value| {
            const value_span = value.span();
            try validateChild(span, value_span);
            if (value_span.start != previous_end) return error.InvalidComponentValueList;
            previous_end = value_span.end;
        }
        return .{ .values = values, .span = span };
    }
};

pub const ImportantAnnotation = struct {
    /// End of the semantic value after trailing trivia is removed.
    value_end: usize,
    bang_index: usize,
    keyword_index: usize,
    bang: source.Span,
    keyword: Identifier,
    span: source.Span,

    pub fn init(
        value: ComponentValueList,
        value_end: usize,
        bang_index: usize,
        keyword_index: usize,
        keyword: Identifier,
    ) AstError!ImportantAnnotation {
        if (value_end > bang_index or bang_index >= keyword_index or keyword_index >= value.values.len) {
            return error.InvalidImportantAnnotation;
        }

        const bang_token = switch (value.values[bang_index]) {
            .token => |token| token,
            else => return error.InvalidImportantAnnotation,
        };
        const is_bang = switch (bang_token.data) {
            .delim => |delimiter| delimiter == '!',
            else => false,
        };
        if (bang_token.kind != .delim or !is_bang) return error.InvalidImportantAnnotation;

        const keyword_token = switch (value.values[keyword_index]) {
            .token => |token| token,
            else => return error.InvalidImportantAnnotation,
        };
        if (keyword_token.kind != .ident or
            !std.ascii.eqlIgnoreCase(keyword.value, "important"))
        {
            return error.InvalidImportantAnnotation;
        }
        const keyword_span = keyword_token.valueSpan() orelse return error.InvalidImportantAnnotation;
        if (!spansEqual(keyword.span, keyword_span)) return error.InvalidImportantAnnotation;

        for (value.values[value_end..bang_index]) |component| {
            if (!isTrivia(component)) return error.InvalidImportantAnnotation;
        }
        for (value.values[bang_index + 1 .. keyword_index]) |component| {
            if (!isTrivia(component)) return error.InvalidImportantAnnotation;
        }
        for (value.values[keyword_index + 1 ..]) |component| {
            if (!isTrivia(component)) return error.InvalidImportantAnnotation;
        }

        return .{
            .value_end = value_end,
            .bang_index = bang_index,
            .keyword_index = keyword_index,
            .bang = bang_token.span,
            .keyword = keyword,
            .span = .{
                .source = bang_token.span.source,
                .start = bang_token.span.start,
                .end = keyword_token.span.end,
            },
        };
    }
};

pub const Declaration = struct {
    name: Identifier,
    colon: source.Span,
    /// Includes all raw leading/trailing trivia and the `!important` marker.
    value: ComponentValueList,
    important: ?ImportantAnnotation = null,
    terminator: ?source.Span = null,
    span: source.Span,

    pub fn init(candidate: Declaration) AstError!Declaration {
        try validateSpan(candidate.span);
        try validateChild(candidate.span, candidate.name.span);
        try validateChild(candidate.span, candidate.colon);
        try validateChild(candidate.span, candidate.value.span);
        if (candidate.name.span.end > candidate.colon.start or
            candidate.colon.end > candidate.value.span.start)
        {
            return error.InvalidDeclaration;
        }

        if (candidate.important) |important| {
            const validated = ImportantAnnotation.init(
                candidate.value,
                important.value_end,
                important.bang_index,
                important.keyword_index,
                important.keyword,
            ) catch return error.InvalidDeclaration;
            if (!spansEqual(validated.span, important.span) or
                !spansEqual(validated.bang, important.bang))
            {
                return error.InvalidDeclaration;
            }
        }
        if (candidate.terminator) |terminator| {
            try validateChild(candidate.span, terminator);
            if (terminator.start < candidate.value.span.end) return error.InvalidDeclaration;
        }
        return candidate;
    }

    pub fn valueWithoutImportance(self: Declaration) []const syntax.ComponentValue {
        if (self.important) |important| return self.value.values[0..important.value_end];
        return self.value.values;
    }
};

/// Ordered storage intentionally preserves duplicate/fallback declarations.
pub const DeclarationList = struct {
    declarations: []const Declaration,
    span: source.Span,

    pub fn init(span: source.Span, declarations: []const Declaration) AstError!DeclarationList {
        try validateSpan(span);
        var previous_end = span.start;
        for (declarations) |declaration| {
            try validateChild(span, declaration.span);
            _ = Declaration.init(declaration) catch return error.InvalidDeclaration;
            if (declaration.span.start < previous_end) return error.InvalidDeclaration;
            previous_end = declaration.span.end;
        }
        return .{ .declarations = declarations, .span = span };
    }
};

/// Exact brace and content boundaries for a block. A missing closing span is a
/// recoverable EOF state, never a synthesized source token.
pub const BlockSpan = struct {
    opening: source.Span,
    content: source.Span,
    closing: ?source.Span,
    span: source.Span,

    pub fn init(candidate: BlockSpan) AstError!BlockSpan {
        try validateSpan(candidate.span);
        try validateChild(candidate.span, candidate.opening);
        try validateChild(candidate.span, candidate.content);
        if (candidate.opening.isEmpty() or
            candidate.span.start != candidate.opening.start or
            candidate.opening.end != candidate.content.start)
        {
            return error.InvalidBlockSpan;
        }

        if (candidate.closing) |closing| {
            try validateChild(candidate.span, closing);
            if (closing.isEmpty() or
                candidate.content.end != closing.start or
                candidate.span.end != closing.end)
            {
                return error.InvalidBlockSpan;
            }
        } else if (candidate.span.end != candidate.content.end) {
            return error.InvalidBlockSpan;
        }
        return candidate;
    }

    pub fn terminated(self: BlockSpan) bool {
        return self.closing != null;
    }
};

pub const DeclarationBlock = struct {
    envelope: BlockSpan,
    declarations: DeclarationList,

    pub fn init(envelope: BlockSpan, declarations: DeclarationList) AstError!DeclarationBlock {
        _ = try BlockSpan.init(envelope);
        if (!spansEqual(envelope.content, declarations.span)) return error.InvalidRuleBlock;
        _ = try DeclarationList.init(declarations.span, declarations.declarations);
        return .{ .envelope = envelope, .declarations = declarations };
    }
};

/// A style rule's block keeps its leading declarations separate from ordered
/// child rules. Declaration runs after the first child are represented as
/// `NestedDeclarationsRule` entries in `rules`.
pub const StyleBlock = struct {
    envelope: BlockSpan,
    declarations: DeclarationList,
    rules: RuleList,

    pub fn init(
        envelope: BlockSpan,
        declarations: DeclarationList,
        rules: RuleList,
    ) AstError!StyleBlock {
        _ = try BlockSpan.init(envelope);
        _ = try DeclarationList.init(declarations.span, declarations.declarations);
        _ = try RuleList.init(rules.span, rules.rules);
        if (!envelope.content.source.eql(declarations.span.source) or
            !envelope.content.source.eql(rules.span.source) or
            declarations.span.start != envelope.content.start or
            declarations.span.end != rules.span.start or
            rules.span.end != envelope.content.end)
        {
            return error.InvalidRuleBlock;
        }
        return .{ .envelope = envelope, .declarations = declarations, .rules = rules };
    }
};

pub const StyleRule = struct {
    selectors: SelectorList,
    block: StyleBlock,
    span: source.Span,

    pub fn init(candidate: StyleRule) AstError!StyleRule {
        try validateSpan(candidate.span);
        try validateChild(candidate.span, candidate.selectors.span);
        try validateChild(candidate.span, candidate.block.envelope.span);
        if (candidate.span.start != candidate.selectors.span.start or
            candidate.selectors.span.end > candidate.block.envelope.span.start or
            candidate.span.end != candidate.block.envelope.span.end)
        {
            return error.InvalidRule;
        }
        _ = try StyleBlock.init(candidate.block.envelope, candidate.block.declarations, candidate.block.rules);
        return candidate;
    }
};

pub const NestedDeclarationsRule = struct {
    declarations: DeclarationList,
    span: source.Span,

    pub fn init(candidate: NestedDeclarationsRule) AstError!NestedDeclarationsRule {
        try validateSpan(candidate.span);
        if (!spansEqual(candidate.span, candidate.declarations.span) or
            candidate.declarations.declarations.len == 0)
        {
            return error.InvalidRule;
        }
        _ = try DeclarationList.init(candidate.declarations.span, candidate.declarations.declarations);
        return candidate;
    }
};

pub const Rule = union(enum) {
    style_rule: *const StyleRule,
    at_rule: *const AtRule,
    nested_declarations: *const NestedDeclarationsRule,

    pub fn span(self: Rule) source.Span {
        return switch (self) {
            .style_rule => |rule| rule.span,
            .at_rule => |rule| rule.span,
            .nested_declarations => |rule| rule.span,
        };
    }
};

/// Ordered rule storage prevents non-adjacent rules or at-rules from merging.
pub const RuleList = struct {
    rules: []const Rule,
    span: source.Span,

    pub fn init(span: source.Span, rules: []const Rule) AstError!RuleList {
        try validateSpan(span);
        var previous_end = span.start;
        for (rules) |rule| {
            const rule_span = rule.span();
            try validateChild(span, rule_span);
            if (rule == .nested_declarations) _ = try NestedDeclarationsRule.init(rule.nested_declarations.*);
            if (rule_span.start < previous_end) return error.InvalidRule;
            previous_end = rule_span.end;
        }
        return .{ .rules = rules, .span = span };
    }
};

pub const RulesBlock = struct {
    envelope: BlockSpan,
    rules: RuleList,
    /// Nested group rules parse block contents, so direct declaration runs are
    /// represented among their child rules.
    nested: bool = false,

    pub fn init(envelope: BlockSpan, rules: RuleList) AstError!RulesBlock {
        return initMode(envelope, rules, false);
    }

    pub fn initNested(envelope: BlockSpan, rules: RuleList) AstError!RulesBlock {
        return initMode(envelope, rules, true);
    }

    fn initMode(envelope: BlockSpan, rules: RuleList, nested: bool) AstError!RulesBlock {
        _ = try BlockSpan.init(envelope);
        if (!spansEqual(envelope.content, rules.span)) return error.InvalidRuleBlock;
        _ = try RuleList.init(rules.span, rules.rules);
        if (!nested) for (rules.rules) |rule| {
            if (rule == .nested_declarations) return error.InvalidRuleBlock;
        };
        return .{ .envelope = envelope, .rules = rules, .nested = nested };
    }
};

pub const KeyframeRule = struct {
    prelude: ComponentValueList,
    selectors: []const KeyframeSelector = &.{},
    block: DeclarationBlock,
    span: source.Span,

    pub fn init(candidate: KeyframeRule) AstError!KeyframeRule {
        if (candidate.prelude.values.len == 0) return error.InvalidKeyframes;
        try validateSpan(candidate.span);
        try validateChild(candidate.span, candidate.prelude.span);
        try validateChild(candidate.span, candidate.block.envelope.span);
        if (candidate.span.start != candidate.prelude.span.start or
            candidate.prelude.span.end != candidate.block.envelope.span.start or
            candidate.span.end != candidate.block.envelope.span.end)
        {
            return error.InvalidKeyframes;
        }
        _ = try DeclarationBlock.init(candidate.block.envelope, candidate.block.declarations);
        return candidate;
    }
};

pub const KeyframePercentage = struct {
    value: f64,
    span: source.Span,
};

pub const KeyframeSelector = union(enum) {
    from: source.Span,
    to: source.Span,
    percentage: KeyframePercentage,

    pub fn span(self: KeyframeSelector) source.Span {
        return switch (self) {
            .from => |value| value,
            .to => |value| value,
            .percentage => |value| value.span,
        };
    }
};

pub const KeyframesBlock = struct {
    envelope: BlockSpan,
    /// Retained until/alongside structured frame lowering.
    raw_values: ?ComponentValueList = null,
    frames: []const KeyframeRule,

    pub fn init(envelope: BlockSpan, frames: []const KeyframeRule) AstError!KeyframesBlock {
        _ = try BlockSpan.init(envelope);
        var previous_end = envelope.content.start;
        for (frames) |frame| {
            try validateChild(envelope.content, frame.span);
            _ = try KeyframeRule.init(frame);
            if (frame.span.start < previous_end) return error.InvalidKeyframes;
            previous_end = frame.span.end;
        }
        return .{ .envelope = envelope, .frames = frames };
    }

    pub fn initWithRaw(
        envelope: BlockSpan,
        raw_values: ComponentValueList,
        frames: []const KeyframeRule,
    ) AstError!KeyframesBlock {
        var block = try init(envelope, frames);
        if (!spansEqual(envelope.content, raw_values.span)) return error.InvalidKeyframes;
        _ = try ComponentValueList.init(raw_values.span, raw_values.values);
        block.raw_values = raw_values;
        return block;
    }
};

pub const RawBlock = struct {
    envelope: BlockSpan,
    values: ComponentValueList,

    pub fn init(envelope: BlockSpan, values: ComponentValueList) AstError!RawBlock {
        _ = try BlockSpan.init(envelope);
        if (!spansEqual(envelope.content, values.span)) return error.InvalidRuleBlock;
        _ = try ComponentValueList.init(values.span, values.values);
        return .{ .envelope = envelope, .values = values };
    }
};

pub const NoBlock = struct {
    terminator: ?source.Span = null,
};

pub const AtRuleBlock = union(enum) {
    none: NoBlock,
    declarations: *const DeclarationBlock,
    rules: *const RulesBlock,
    keyframes: *const KeyframesBlock,
    raw: *const RawBlock,

    pub fn envelope(self: AtRuleBlock) ?BlockSpan {
        return switch (self) {
            .none => null,
            .declarations => |block| block.envelope,
            .rules => |block| block.envelope,
            .keyframes => |block| block.envelope,
            .raw => |block| block.envelope,
        };
    }
};

pub const MediaQueryList = struct {
    queries: []const ComponentValueList,
    span: source.Span,
};

pub const MediaRule = struct {
    query_list: MediaQueryList,
    block: *const RulesBlock,
};

pub const SupportsOperator = enum {
    none,
    @"and",
    @"or",
};

pub const SupportsRule = struct {
    negated: bool,
    operator: SupportsOperator,
    terms: []const ComponentValueList,
    span: source.Span,
    block: *const RulesBlock,
};

pub const ContainerRule = struct {
    name: ?Identifier,
    query: ComponentValueList,
    span: source.Span,
    block: *const RulesBlock,
};

pub const LayerName = struct {
    parts: []const Identifier,
    span: source.Span,
};

pub const LayerRule = struct {
    names: []const LayerName,
    statement: bool,
    span: source.Span,
};

pub const PropertyRule = struct {
    name: Identifier,
    declarations: *const DeclarationList,
    span: source.Span,
};

pub const FontFaceRule = struct {
    declarations: *const DeclarationList,
    span: source.Span,
};

pub const KeyframesRule = struct {
    name: Identifier,
    block: *const KeyframesBlock,
    span: source.Span,
};

pub const PageSelector = struct {
    name: ?Identifier,
    pseudos: []const Identifier,
    span: source.Span,
};

pub const PageMarginRule = struct {
    name: Identifier,
    envelope: BlockSpan,
    declarations: *const DeclarationList,
    span: source.Span,
};

pub const PageRule = struct {
    selectors: []const PageSelector,
    declarations: *const DeclarationList,
    margins: []const PageMarginRule,
    span: source.Span,
};

pub const AtRuleDetails = union(enum) {
    media: *const MediaRule,
    supports: *const SupportsRule,
    container: *const ContainerRule,
    layer: *const LayerRule,
    property: *const PropertyRule,
    page: *const PageRule,
    font_face: *const FontFaceRule,
    keyframes: *const KeyframesRule,
};

pub const AtRule = struct {
    at_sign: source.Span,
    name: Identifier,
    /// Includes trivia between the name and block/terminator.
    prelude: ComponentValueList,
    block: AtRuleBlock,
    details: ?AtRuleDetails = null,
    span: source.Span,

    pub fn init(candidate: AtRule) AstError!AtRule {
        try validateSpan(candidate.span);
        try validateChild(candidate.span, candidate.at_sign);
        try validateChild(candidate.span, candidate.name.span);
        try validateChild(candidate.span, candidate.prelude.span);
        if (candidate.at_sign.isEmpty() or
            candidate.span.start != candidate.at_sign.start or
            candidate.at_sign.end != candidate.name.span.start or
            candidate.name.span.end != candidate.prelude.span.start)
        {
            return error.InvalidAtRule;
        }
        _ = try ComponentValueList.init(candidate.prelude.span, candidate.prelude.values);

        switch (candidate.block) {
            .none => |no_block| {
                if (no_block.terminator) |terminator| {
                    try validateChild(candidate.span, terminator);
                    if (terminator.start != candidate.prelude.span.end or
                        candidate.span.end != terminator.end)
                    {
                        return error.InvalidAtRule;
                    }
                } else if (candidate.span.end != candidate.prelude.span.end) {
                    return error.InvalidAtRule;
                }
            },
            .declarations => |block| {
                _ = try DeclarationBlock.init(block.envelope, block.declarations);
                try validateAtRuleBlock(candidate, block.envelope);
            },
            .rules => |block| {
                _ = try RulesBlock.initMode(block.envelope, block.rules, block.nested);
                try validateAtRuleBlock(candidate, block.envelope);
            },
            .keyframes => |block| {
                if (block.raw_values) |raw_values| {
                    _ = try KeyframesBlock.initWithRaw(block.envelope, raw_values, block.frames);
                } else {
                    _ = try KeyframesBlock.init(block.envelope, block.frames);
                }
                try validateAtRuleBlock(candidate, block.envelope);
            },
            .raw => |block| {
                _ = try RawBlock.init(block.envelope, block.values);
                try validateAtRuleBlock(candidate, block.envelope);
            },
        }
        return candidate;
    }
};

fn validateAtRuleBlock(at_rule: AtRule, envelope: BlockSpan) AstError!void {
    try validateChild(at_rule.span, envelope.span);
    if (at_rule.prelude.span.end != envelope.span.start or at_rule.span.end != envelope.span.end) {
        return error.InvalidAtRule;
    }
}

fn validateSpan(span: source.Span) SelectorError!void {
    if (span.start > span.end) return error.InvalidSpan;
}

fn validateChild(parent: source.Span, child: source.Span) SelectorError!void {
    try validateSpan(parent);
    try validateSpan(child);
    if (!parent.source.eql(child.source)) return error.SourceMismatch;
    if (child.start < parent.start or child.end > parent.end) return error.SpanOutsideParent;
}

fn spansEqual(a: source.Span, b: source.Span) bool {
    return a.source.eql(b.source) and a.start == b.start and a.end == b.end;
}

fn isTrivia(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.isTrivia(),
        else => false,
    };
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

fn spanForValues(values: []const syntax.ComponentValue) source.Span {
    return .{
        .source = values[0].span().source,
        .start = values[0].span().start,
        .end = values[values.len - 1].span().end,
    };
}

test "declaration values retain nested components and explicit important metadata" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("declaration.css", "x: fn(a;b, [c:d]) ! /*keep*/ IMPORTANT ;");
    const file = try context.sources.get(id);
    const document = try syntax.parse(&context, id);
    const raw_values = document.values[2..11];
    const value = try ComponentValueList.init(spanForValues(raw_values), raw_values);
    const important = try ImportantAnnotation.init(
        value,
        2,
        3,
        7,
        .{ .value = "IMPORTANT", .span = document.values[9].token.valueSpan().? },
    );
    const declaration = try Declaration.init(.{
        .name = .{ .value = "x", .span = document.values[0].token.valueSpan().? },
        .colon = document.values[1].token.span,
        .value = value,
        .important = important,
        .terminator = document.values[11].token.span,
        .span = file.fullSpan(),
    });

    try std.testing.expectEqual(@as(usize, 9), declaration.value.values.len);
    try std.testing.expectEqual(@as(usize, 2), declaration.valueWithoutImportance().len);
    try std.testing.expectEqual(@as(usize, 6), declaration.value.values[1].function.values.len);
    try std.testing.expectEqualStrings(
        " fn(a;b, [c:d]) ! /*keep*/ IMPORTANT ",
        try file.slice(declaration.value.span),
    );
    try std.testing.expectEqualStrings("IMPORTANT", declaration.important.?.keyword.value);
    try std.testing.expect(declaration.important.?.span.start < declaration.important.?.span.end);
}

test "important markers reject non-trivia gaps and non-important keywords" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("invalid-important.css", "red ! urgent");
    const document = try syntax.parse(&context, id);
    const value = try ComponentValueList.init(document.span, document.values);

    try std.testing.expectError(error.InvalidImportantAnnotation, ImportantAnnotation.init(
        value,
        1,
        2,
        4,
        .{ .value = "urgent", .span = document.values[4].token.valueSpan().? },
    ));
    try std.testing.expectError(error.InvalidImportantAnnotation, ImportantAnnotation.init(
        value,
        1,
        0,
        4,
        .{ .value = "important", .span = document.values[4].token.valueSpan().? },
    ));
}

test "declaration lists preserve fallback order and custom-property identity" {
    const id = source.SourceId{ .value = 11 };
    const first_value = try ComponentValueList.init(testSpan(id, 6, 6), &.{});
    const second_value = try ComponentValueList.init(testSpan(id, 13, 13), &.{});
    const first = try Declaration.init(.{
        .name = .{ .value = "color", .span = testSpan(id, 0, 5) },
        .colon = testSpan(id, 5, 6),
        .value = first_value,
        .terminator = testSpan(id, 6, 7),
        .span = testSpan(id, 0, 7),
    });
    const second = try Declaration.init(.{
        .name = .{ .value = "color", .span = testSpan(id, 7, 12) },
        .colon = testSpan(id, 12, 13),
        .value = second_value,
        .terminator = testSpan(id, 13, 14),
        .span = testSpan(id, 7, 14),
    });
    const declarations = [_]Declaration{ first, second };
    const list = try DeclarationList.init(testSpan(id, 0, 14), &declarations);

    try std.testing.expectEqual(@as(usize, 2), list.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), list.declarations[0].span.start);
    try std.testing.expectEqual(@as(usize, 7), list.declarations[1].span.start);
    try std.testing.expect(!list.declarations[0].name.isCustomProperty());
    try std.testing.expect((Identifier{
        .value = "--theme",
        .span = testSpan(id, 0, 7),
    }).isCustomProperty());
}

test "style and nested group blocks distinguish leading and nested declarations" {
    const id = source.SourceId{ .value = 19 };
    const envelope = try BlockSpan.init(.{
        .opening = testSpan(id, 0, 1),
        .content = testSpan(id, 1, 6),
        .closing = testSpan(id, 6, 7),
        .span = testSpan(id, 0, 7),
    });
    const value = try ComponentValueList.init(testSpan(id, 3, 3), &.{});
    const declaration = try Declaration.init(.{
        .name = .{ .value = "x", .span = testSpan(id, 1, 2) },
        .colon = testSpan(id, 2, 3),
        .value = value,
        .terminator = testSpan(id, 3, 4),
        .span = testSpan(id, 1, 4),
    });
    const declarations = [_]Declaration{declaration};
    const nested_list = try DeclarationList.init(testSpan(id, 1, 4), &declarations);
    const nested = try NestedDeclarationsRule.init(.{
        .declarations = nested_list,
        .span = nested_list.span,
    });
    const children = [_]Rule{.{ .nested_declarations = &nested }};
    const child_rules = try RuleList.init(testSpan(id, 1, 6), &children);
    const leading = try DeclarationList.init(testSpan(id, 1, 1), &.{});

    const style = try StyleBlock.init(envelope, leading, child_rules);
    try std.testing.expectEqual(@as(usize, 0), style.declarations.declarations.len);
    try std.testing.expect(style.rules.rules[0] == .nested_declarations);
    try std.testing.expectError(error.InvalidRuleBlock, RulesBlock.init(envelope, child_rules));
    const nested_group = try RulesBlock.initNested(envelope, child_rules);
    try std.testing.expect(nested_group.nested);
}

fn emptyBlockSpan(id: source.SourceId, opening_start: usize) !BlockSpan {
    return BlockSpan.init(.{
        .opening = testSpan(id, opening_start, opening_start + 1),
        .content = testSpan(id, opening_start + 1, opening_start + 1),
        .closing = testSpan(id, opening_start + 1, opening_start + 2),
        .span = testSpan(id, opening_start, opening_start + 2),
    });
}

test "at-rule block categories are explicit and non-interchangeable" {
    const id = source.SourceId{ .value = 20 };
    const prelude = try ComponentValueList.init(testSpan(id, 2, 2), &.{});
    const envelope = try emptyBlockSpan(id, 2);
    const declarations = try DeclarationList.init(envelope.content, &.{});
    const declaration_block = try DeclarationBlock.init(envelope, declarations);
    const rules = try RuleList.init(envelope.content, &.{});
    const rules_block = try RulesBlock.init(envelope, rules);
    const keyframes_block = try KeyframesBlock.init(envelope, &.{});
    const raw_values = try ComponentValueList.init(envelope.content, &.{});
    const raw_block = try RawBlock.init(envelope, raw_values);

    const common = AtRule{
        .at_sign = testSpan(id, 0, 1),
        .name = .{ .value = "x", .span = testSpan(id, 1, 2) },
        .prelude = prelude,
        .block = .{ .raw = &raw_block },
        .span = testSpan(id, 0, 4),
    };
    const declaration_at_rule = try AtRule.init(.{
        .at_sign = common.at_sign,
        .name = common.name,
        .prelude = prelude,
        .block = .{ .declarations = &declaration_block },
        .span = common.span,
    });
    const rules_at_rule = try AtRule.init(.{
        .at_sign = common.at_sign,
        .name = common.name,
        .prelude = prelude,
        .block = .{ .rules = &rules_block },
        .span = common.span,
    });
    const keyframes_at_rule = try AtRule.init(.{
        .at_sign = common.at_sign,
        .name = common.name,
        .prelude = prelude,
        .block = .{ .keyframes = &keyframes_block },
        .span = common.span,
    });
    const raw_at_rule = try AtRule.init(common);
    const no_block = try AtRule.init(.{
        .at_sign = common.at_sign,
        .name = common.name,
        .prelude = prelude,
        .block = .{ .none = .{ .terminator = testSpan(id, 2, 3) } },
        .span = testSpan(id, 0, 3),
    });

    try std.testing.expect(declaration_at_rule.block == .declarations);
    try std.testing.expect(rules_at_rule.block == .rules);
    try std.testing.expect(keyframes_at_rule.block == .keyframes);
    try std.testing.expect(raw_at_rule.block == .raw);
    try std.testing.expect(no_block.block == .none);
}

test "raw at-rule blocks preserve nested unknown syntax exactly" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("raw-at-rule.css", "@x foo{a(b;c)}");
    const file = try context.sources.get(id);
    const document = try syntax.parse(&context, id);
    const block = document.values[3].simple_block;
    const prelude_values = document.values[1..3];
    const prelude = try ComponentValueList.init(spanForValues(prelude_values), prelude_values);
    const raw_values = try ComponentValueList.init(
        testSpan(id, block.opening.span.end, block.closing.?.span.start),
        block.values,
    );
    const envelope = try BlockSpan.init(.{
        .opening = block.opening.span,
        .content = raw_values.span,
        .closing = block.closing.?.span,
        .span = block.span,
    });
    const raw_block = try RawBlock.init(envelope, raw_values);
    const at_rule = try AtRule.init(.{
        .at_sign = testSpan(id, 0, 1),
        .name = .{ .value = "x", .span = document.values[0].token.valueSpan().? },
        .prelude = prelude,
        .block = .{ .raw = &raw_block },
        .span = file.fullSpan(),
    });

    try std.testing.expectEqualStrings("@x foo{a(b;c)}", try file.slice(at_rule.span));
    try std.testing.expectEqual(@as(usize, 1), raw_block.values.values.len);
    try std.testing.expectEqual(@as(usize, 3), raw_block.values.values[0].function.values.len);
}

test "rule lists retain style and at-rule order" {
    const id = source.SourceId{ .value = 21 };
    const empty_first = try ComponentValueList.init(testSpan(id, 2, 2), &.{});
    const first = try AtRule.init(.{
        .at_sign = testSpan(id, 0, 1),
        .name = .{ .value = "x", .span = testSpan(id, 1, 2) },
        .prelude = empty_first,
        .block = .{ .none = .{ .terminator = testSpan(id, 2, 3) } },
        .span = testSpan(id, 0, 3),
    });
    const empty_second = try ComponentValueList.init(testSpan(id, 5, 5), &.{});
    const second = try AtRule.init(.{
        .at_sign = testSpan(id, 3, 4),
        .name = .{ .value = "y", .span = testSpan(id, 4, 5) },
        .prelude = empty_second,
        .block = .{ .none = .{ .terminator = testSpan(id, 5, 6) } },
        .span = testSpan(id, 3, 6),
    });
    const entries = [_]Rule{
        .{ .at_rule = &first },
        .{ .at_rule = &second },
    };
    const rules = try RuleList.init(testSpan(id, 0, 6), &entries);

    try std.testing.expectEqualStrings("x", rules.rules[0].at_rule.name.value);
    try std.testing.expectEqualStrings("y", rules.rules[1].at_rule.name.value);
}

test "block envelopes support bounded EOF recovery and reject gaps" {
    const id = source.SourceId{ .value = 22 };
    const unterminated = try BlockSpan.init(.{
        .opening = testSpan(id, 0, 1),
        .content = testSpan(id, 1, 3),
        .closing = null,
        .span = testSpan(id, 0, 3),
    });
    try std.testing.expect(!unterminated.terminated());
    try std.testing.expectError(error.InvalidBlockSpan, BlockSpan.init(.{
        .opening = testSpan(id, 0, 1),
        .content = testSpan(id, 1, 2),
        .closing = testSpan(id, 3, 4),
        .span = testSpan(id, 0, 4),
    }));
}

test "keyframe rules retain percentage selector preludes and declaration blocks" {
    const allocator = std.testing.allocator;
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const id = try context.addSource("keyframes.css", "{0%, to{}}");
    const file = try context.sources.get(id);
    const document = try syntax.parse(&context, id);
    const outer = document.values[0].simple_block;
    const inner = outer.values[4].simple_block;

    const frame_prelude_values = outer.values[0..4];
    const frame_prelude = try ComponentValueList.init(
        spanForValues(frame_prelude_values),
        frame_prelude_values,
    );
    const declaration_envelope = try BlockSpan.init(.{
        .opening = inner.opening.span,
        .content = testSpan(id, inner.opening.span.end, inner.closing.?.span.start),
        .closing = inner.closing.?.span,
        .span = inner.span,
    });
    const declarations = try DeclarationList.init(declaration_envelope.content, &.{});
    const declaration_block = try DeclarationBlock.init(declaration_envelope, declarations);
    const frame = try KeyframeRule.init(.{
        .prelude = frame_prelude,
        .block = declaration_block,
        .span = testSpan(id, frame_prelude.span.start, declaration_envelope.span.end),
    });
    const outer_envelope = try BlockSpan.init(.{
        .opening = outer.opening.span,
        .content = testSpan(id, outer.opening.span.end, outer.closing.?.span.start),
        .closing = outer.closing.?.span,
        .span = outer.span,
    });
    const frames = [_]KeyframeRule{frame};
    const keyframes = try KeyframesBlock.init(outer_envelope, &frames);

    try std.testing.expectEqualStrings("0%, to", try file.slice(keyframes.frames[0].prelude.span));
    try std.testing.expectEqual(@as(usize, 4), keyframes.frames[0].prelude.values.len);
}

test "semicolon-free at-rules retain the no-block EOF form" {
    const id = source.SourceId{ .value = 23 };
    const prelude = try ComponentValueList.init(testSpan(id, 2, 2), &.{});
    const at_rule = try AtRule.init(.{
        .at_sign = testSpan(id, 0, 1),
        .name = .{ .value = "x", .span = testSpan(id, 1, 2) },
        .prelude = prelude,
        .block = .{ .none = .{} },
        .span = testSpan(id, 0, 2),
    });
    try std.testing.expect(at_rule.block.none.terminator == null);
}
