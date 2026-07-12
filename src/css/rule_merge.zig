const std = @import("std");
const ast = @import("ast.zig");
const component_compare = @import("component_compare.zig");
const source = @import("../source.zig");

pub const Error = component_compare.Error || error{
    InvalidAst,
};

pub const SelectorMergeProof = struct {
    source_span: source.Span,
};

pub const AtRuleMergeProof = struct {
    source_span: source.Span,
};

const MergeableAtRuleKind = enum {
    media,
    supports,
    container,
    named_layer,
};

/// Proves the narrow selector-list merge form:
///
///     A { declarations } B { declarations }
///       -> A, B { declarations }
///
/// Both declaration-only blocks must be structurally equivalent after the
/// emitter's trivia normalization. Unsupported structures return null;
/// malformed source bindings remain hard errors.
pub fn analyzeSelectorMerge(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    rules: []const ast.Rule,
) Error!?SelectorMergeProof {
    if (rules.len != 2 or rules[0] != .style_rule or rules[1] != .style_rule) return null;
    const first = rules[0].style_rule;
    const second = rules[1].style_rule;
    _ = ast.StyleRule.init(first.*) catch return error.InvalidAst;
    _ = ast.StyleRule.init(second.*) catch return error.InvalidAst;
    if (!eligibleBlock(&first.block) or !eligibleBlock(&second.block)) return null;
    if (first.block.declarations.declarations.len != second.block.declarations.declarations.len) {
        return null;
    }
    _ = std.math.add(
        usize,
        first.selectors.selectors.len,
        second.selectors.selectors.len,
    ) catch return error.InvalidAst;

    if (!try declarationListsEqual(
        allocator,
        file,
        &first.block.declarations,
        &second.block.declarations,
    )) return null;
    const gap = source.Span{
        .source = first.span.source,
        .start = first.span.end,
        .end = second.span.start,
    };
    const gap_bytes = file.slice(gap) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    if (!isTriviaOnly(gap_bytes)) return null;

    const causal_span = source.Span{
        .source = first.span.source,
        .start = first.span.start,
        .end = second.span.end,
    };
    _ = file.slice(causal_span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    return .{ .source_span = causal_span };
}

/// Proves the narrow adjacent group-rule merge form:
///
///     @group condition { first rules }
///     @group condition { second rules }
///       -> @group condition { first rules; second rules }
///
/// Only typed media, supports, container, and named layer blocks participate.
/// Anonymous layers and every untyped or non-rule-block at-rule are excluded.
pub fn analyzeAtRuleMerge(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    rules: []const ast.Rule,
) Error!?AtRuleMergeProof {
    if (rules.len != 2 or rules[0] != .at_rule or rules[1] != .at_rule) return null;
    const first = rules[0].at_rule;
    const second = rules[1].at_rule;
    _ = ast.AtRule.init(first.*) catch return error.InvalidAst;
    _ = ast.AtRule.init(second.*) catch return error.InvalidAst;
    const first_group = mergeableGroup(first) orelse return null;
    const second_group = mergeableGroup(second) orelse return null;
    if (first_group.kind != second_group.kind or
        first_group.block.nested != second_group.block.nested or
        first_group.block.rules.rules.len == 0 or
        second_group.block.rules.rules.len == 0 or
        hasDirectNestedDeclarations(&first_group.block.rules) or
        hasDirectNestedDeclarations(&second_group.block.rules) or
        !first_group.block.envelope.terminated() or
        !second_group.block.envelope.terminated())
    {
        return null;
    }
    if (!try component_compare.equivalent(
        allocator,
        file,
        first.prelude.values,
        second.prelude.values,
        .{},
    )) return null;

    const gap = source.Span{
        .source = first.span.source,
        .start = first.span.end,
        .end = second.span.start,
    };
    const gap_bytes = file.slice(gap) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    if (!isTriviaOnly(gap_bytes)) return null;

    const causal_span = source.Span{
        .source = first.span.source,
        .start = first.span.start,
        .end = second.span.end,
    };
    _ = file.slice(causal_span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    return .{ .source_span = causal_span };
}

fn hasDirectNestedDeclarations(rules: *const ast.RuleList) bool {
    for (rules.rules) |rule| if (rule == .nested_declarations) return true;
    return false;
}

const MergeableGroup = struct {
    kind: MergeableAtRuleKind,
    block: *const ast.RulesBlock,
};

fn mergeableGroup(rule: *const ast.AtRule) ?MergeableGroup {
    const block = switch (rule.block) {
        .rules => |value| value,
        else => return null,
    };
    const details = rule.details orelse return null;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "media")) return switch (details) {
        .media => |value| if (value.block == block) .{ .kind = .media, .block = block } else null,
        else => null,
    };
    if (std.ascii.eqlIgnoreCase(rule.name.value, "supports")) return switch (details) {
        .supports => |value| if (value.block == block) .{ .kind = .supports, .block = block } else null,
        else => null,
    };
    if (std.ascii.eqlIgnoreCase(rule.name.value, "container")) return switch (details) {
        .container => |value| if (value.block == block) .{ .kind = .container, .block = block } else null,
        else => null,
    };
    if (std.ascii.eqlIgnoreCase(rule.name.value, "layer")) return switch (details) {
        .layer => |value| if (!value.statement and value.names.len == 1)
            .{ .kind = .named_layer, .block = block }
        else
            null,
        else => null,
    };
    return null;
}

fn declarationListsEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    first: *const ast.DeclarationList,
    second: *const ast.DeclarationList,
) Error!bool {
    if (first.declarations.len != second.declarations.len or
        first.generated_declarations.len != 0 or
        second.generated_declarations.len != 0)
    {
        return false;
    }
    for (first.declarations, second.declarations) |left, right| {
        if (!std.mem.eql(u8, left.name.value, right.name.value) or
            (left.important == null) != (right.important == null) or
            !try component_compare.equivalent(
                allocator,
                file,
                left.valueWithoutImportance(),
                right.valueWithoutImportance(),
                .{},
            ))
        {
            return false;
        }
    }
    return true;
}

fn eligibleBlock(block: *const ast.StyleBlock) bool {
    if (!block.envelope.terminated() or
        !sameSpan(block.envelope.content, block.declarations.span) or
        block.declarations.declarations.len == 0 or
        block.declarations.generated_declarations.len != 0 or
        block.rules.rules.len != 0 or
        block.rules.omitted_rules.len != 0 or
        block.rules.generated_rules.len != 0)
    {
        return false;
    }
    for (block.declarations.declarations) |declaration| {
        if (declaration.generated_value != null) return false;
    }
    return true;
}

fn isTriviaOnly(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        if (isCssWhitespace(bytes[index])) {
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
        return false;
    }
    return true;
}

fn isCssWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

fn sameSpan(left: source.Span, right: source.Span) bool {
    return left.source.eql(right.source) and left.start == right.start and left.end == right.end;
}

const pipeline = @import("pipeline.zig");

test "selector merge proof accepts adjacent semantically identical declaration-only blocks" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "selector-merge-proof.css",
        ".a{x:1;content:'x';color:red!important} /* gap */ " ++
            ".b,.c{ x : 1 ; content : \"x\" ; color : red ! IMPORTANT; }",
    );
    defer parsed.deinit();
    const proof = (try analyzeSelectorMerge(
        std.testing.allocator,
        parsed.file(),
        parsed.rules.rules,
    )).?;
    try std.testing.expectEqual(parsed.rules.rules[0].span().start, proof.source_span.start);
    try std.testing.expectEqual(parsed.rules.rules[1].span().end, proof.source_span.end);
}

test "selector merge proof declines nonidentical transformed nested and non-style inputs" {
    const cases = [_][]const u8{
        ".a{x:1}.b{x:2}",
        ".a{--x:a/**/b}.b{--x:ab}",
        ".a{--x:a/*! first */b}.b{--x:a/*! second */b}",
        ".a{}.b{}",
        ".a{x:1;.child{y:2}}.b{x:1;.child{y:2}}",
        ".a{x:1}@media all{.b{x:1}}",
        ".a{x:1}<!--.b{x:1}",
    };
    for (cases) |css| {
        var parsed = try pipeline.parse(std.testing.allocator, "selector-merge-decline.css", css);
        defer parsed.deinit();
        const rules = parsed.rules.rules;
        if (rules.len != 2) continue;
        try std.testing.expect((try analyzeSelectorMerge(
            std.testing.allocator,
            parsed.file(),
            rules,
        )) == null);
    }
}

test "selector merge proof rejects a foreign source binding" {
    var parsed = try pipeline.parse(std.testing.allocator, "selector-merge-source.css", ".a{x:1}.b{x:1}");
    defer parsed.deinit();
    const foreign_id = try parsed.compilation.addSource("selector-merge-foreign.css", ".a{x:1}.b{x:1}");
    try std.testing.expectError(
        error.SourceMismatch,
        analyzeSelectorMerge(
            std.testing.allocator,
            try parsed.compilation.sources.get(foreign_id),
            parsed.rules.rules,
        ),
    );
}

test "at-rule merge proof accepts typed adjacent query and named layer blocks" {
    const cases = [_][]const u8{
        "@media  screen{.a{x:1}} /* gap */ @media screen{.b{y:2}}",
        "@supports (display:grid){.a{x:1}}@supports (display:grid){.b{y:2}}",
        "@container card (width>1px){.a{x:1}}@container card (width>1px){.b{y:2}}",
        "@layer theme{.a{x:1}}@layer theme{.b{y:2}}",
    };
    for (cases) |css| {
        var parsed = try pipeline.parse(std.testing.allocator, "at-rule-merge-proof.css", css);
        defer parsed.deinit();
        const proof = (try analyzeAtRuleMerge(
            std.testing.allocator,
            parsed.file(),
            parsed.rules.rules,
        )).?;
        try std.testing.expectEqual(parsed.rules.rules[0].span().start, proof.source_span.start);
        try std.testing.expectEqual(parsed.rules.rules[1].span().end, proof.source_span.end);
    }
}

test "at-rule merge proof declines different anonymous empty and unsupported groups" {
    const cases = [_][]const u8{
        "@media screen{.a{x:1}}@media print{.b{y:2}}",
        "@layer{.a{x:1}}@layer{.b{y:2}}",
        "@layer first{.a{x:1}}@layer second{.b{y:2}}",
        "@supports (display:grid){}@supports (display:grid){.b{y:2}}",
        "@scope (.root){.a{x:1}}@scope (.root){.b{y:2}}",
        "@media screen{.a{x:1}}@supports (display:grid){.b{y:2}}",
    };
    for (cases) |css| {
        var parsed = try pipeline.parse(std.testing.allocator, "at-rule-merge-decline.css", css);
        defer parsed.deinit();
        try std.testing.expect((try analyzeAtRuleMerge(
            std.testing.allocator,
            parsed.file(),
            parsed.rules.rules,
        )) == null);
    }
}
