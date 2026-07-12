const std = @import("std");
const ast = @import("ast.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidAst,
    InvalidSpan,
    InvalidToken,
    SourceMismatch,
};

pub const SelectorMergeProof = struct {
    source_span: source.Span,
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
            !try componentListsEqual(
                allocator,
                file,
                left.valueWithoutImportance(),
                right.valueWithoutImportance(),
                true,
            ))
        {
            return false;
        }
    }
    return true;
}

fn componentListsEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
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
                .component => |right_component| if (!try componentsEqual(
                    allocator,
                    file,
                    left_component,
                    right_component,
                )) return false,
                else => return false,
            },
        }
    }
}

fn componentsEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: syntax.ComponentValue,
    right: syntax.ComponentValue,
) Error!bool {
    return switch (left) {
        .token => |left_token| switch (right) {
            .token => |right_token| try tokensEqual(allocator, file, left_token, right_token),
            else => false,
        },
        .simple_block => |left_block| switch (right) {
            .simple_block => |right_block| left_block.opening.kind == right_block.opening.kind and
                left_block.terminated() == right_block.terminated() and
                try componentListsEqual(allocator, file, left_block.values, right_block.values, false),
            else => false,
        },
        .function => |left_function| switch (right) {
            .function => |right_function| left_function.terminated() == right_function.terminated() and
                try tokenTextEqual(allocator, file, left_function.opening, right_function.opening) and
                try componentListsEqual(allocator, file, left_function.values, right_function.values, false),
            else => false,
        },
    };
}

fn tokensEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: tokenizer.Token,
    right: tokenizer.Token,
) Error!bool {
    if (left.kind != right.kind or left.isTerminated() != right.isTerminated()) return false;
    return switch (left.kind) {
        .ident, .function, .at_keyword, .string, .bad_string, .url, .bad_url => try tokenTextEqual(allocator, file, left, right),
        .hash => left.data.hash.hash_type == right.data.hash.hash_type and
            try tokenTextEqual(allocator, file, left, right),
        .delim => left.data.delim == right.data.delim,
        .number, .percentage => numericEqual(left.data.numeric, right.data.numeric),
        .dimension => numericEqual(left.data.dimension.numeric, right.data.dimension.numeric) and
            try tokenTextEqual(allocator, file, left, right),
        .comment => try tokenRawEqual(file, left, right),
        .unicode_range => left.data.unicode_range.start == right.data.unicode_range.start and
            left.data.unicode_range.end == right.data.unicode_range.end,
        else => true,
    };
}

fn tokenRawEqual(
    file: *const source.SourceFile,
    left: tokenizer.Token,
    right: tokenizer.Token,
) Error!bool {
    const left_bytes = file.slice(left.span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    const right_bytes = file.slice(right.span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn tokenTextEqual(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    left: tokenizer.Token,
    right: tokenizer.Token,
) Error!bool {
    const left_text = left.decodedTextAlloc(allocator, file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch => return error.SourceMismatch,
        else => return error.InvalidToken,
    };
    defer allocator.free(left_text);
    const right_text = right.decodedTextAlloc(allocator, file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch => return error.SourceMismatch,
        else => return error.InvalidToken,
    };
    defer allocator.free(right_text);
    return std.mem.eql(u8, left_text, right_text);
}

fn numericEqual(left: tokenizer.Numeric, right: tokenizer.Numeric) bool {
    return left.value == right.value and left.number_type == right.number_type and left.sign == right.sign;
}

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
            if (self.index == self.values.len) return null;
            if (isWhitespace(self.values[self.index])) {
                var next_index = self.index;
                while (next_index < self.values.len and isWhitespace(self.values[next_index])) next_index += 1;
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

fn isWhitespace(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
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
