const std = @import("std");
const preprocessor = @import("native_preprocessor");
const lexer = preprocessor.lexer;

fn tokenize(source: []const u8, syntax: lexer.Syntax) ![]lexer.Token {
    return lexer.tokenizeAlloc(std.testing.allocator, source, syntax, .{});
}

fn expectKinds(tokens: []const lexer.Token, expected: []const lexer.Kind) !void {
    try std.testing.expectEqual(expected.len, tokens.len);
    for (tokens, expected) |token, kind| try std.testing.expectEqual(kind, token.kind);
}

fn expectLossless(source: []const u8, tokens: []const lexer.Token) !void {
    var reconstructed: std.ArrayList(u8) = .empty;
    defer reconstructed.deinit(std.testing.allocator);

    var offset: u32 = 0;
    for (tokens) |token| {
        try std.testing.expect(token.span.start <= token.span.end);
        try std.testing.expect(token.span.end <= source.len);
        if (token.span.start == token.span.end) {
            try std.testing.expect(token.isVirtual());
            try std.testing.expectEqual(offset, token.span.start);
            continue;
        }
        try std.testing.expectEqual(offset, token.span.start);
        try reconstructed.appendSlice(std.testing.allocator, token.raw(source));
        offset = token.span.end;
    }
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), offset);
    try std.testing.expectEqualStrings(source, reconstructed.items);
}

fn countKind(tokens: []const lexer.Token, kind: lexer.Kind) usize {
    var count: usize = 0;
    for (tokens) |token| {
        if (token.kind == kind) count += 1;
    }
    return count;
}

test "all syntax modes retain every source byte exactly once" {
    const cases = [_]struct {
        syntax: lexer.Syntax,
        source: []const u8,
    }{
        .{ .syntax = .css, .source = ".a { color: red; /* c */ }\r\n" },
        .{ .syntax = .scss, .source = "$gap: 2 * 4px;\n.a-#{$gap} { color: red; }\n" },
        .{ .syntax = .sass, .source = "$gap: 8px\n.card\n  width: $gap\n" },
        .{ .syntax = .less, .source = "@gap: 8px;\n.card-@{gap} { width: @gap; }\n" },
        .{ .syntax = .stylus, .source = "gap = 8px\n.card\n  width gap\n" },
    };

    for (cases) |case| {
        const tokens = try tokenize(case.source, case.syntax);
        defer std.testing.allocator.free(tokens);
        try expectLossless(case.source, tokens);
    }
}

test "newline tokens preserve LF CR and CRLF byte spans" {
    const source = "a\r\nb\rc\nd";
    const tokens = try tokenize(source, .css);
    defer std.testing.allocator.free(tokens);

    try expectKinds(tokens, &.{
        .identifier,
        .newline,
        .identifier,
        .newline,
        .identifier,
        .newline,
        .identifier,
        .eof,
    });
    try std.testing.expectEqual(lexer.Span{ .start = 1, .end = 3 }, tokens[1].span);
    try std.testing.expectEqual(lexer.Span{ .start = 4, .end = 5 }, tokens[3].span);
    try std.testing.expectEqual(lexer.Span{ .start = 6, .end = 7 }, tokens[5].span);
    try expectLossless(source, tokens);
}

test "indented syntaxes emit virtual structure only on significant lines" {
    const source = "root\n  color red\n  child\n    width 1px\n\n  after\nnext";
    const color_offset: u32 = @intCast(std.mem.indexOf(u8, source, "color").?);
    const width_offset: u32 = @intCast(std.mem.indexOf(u8, source, "width").?);
    const after_offset: u32 = @intCast(std.mem.indexOf(u8, source, "after").?);
    const next_offset: u32 = @intCast(std.mem.indexOf(u8, source, "next").?);

    for ([_]lexer.Syntax{ .sass, .stylus }) |syntax| {
        const tokens = try tokenize(source, syntax);
        defer std.testing.allocator.free(tokens);
        var structural: [4]lexer.Token = undefined;
        var index: usize = 0;
        for (tokens) |token| {
            if (token.kind == .indent or token.kind == .dedent) {
                structural[index] = token;
                index += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 4), index);
        try std.testing.expectEqual(lexer.Kind.indent, structural[0].kind);
        try std.testing.expectEqual(lexer.Span{ .start = color_offset, .end = color_offset }, structural[0].span);
        try std.testing.expectEqual(lexer.Kind.indent, structural[1].kind);
        try std.testing.expectEqual(lexer.Span{ .start = width_offset, .end = width_offset }, structural[1].span);
        try std.testing.expectEqual(lexer.Kind.dedent, structural[2].kind);
        try std.testing.expectEqual(lexer.Span{ .start = after_offset, .end = after_offset }, structural[2].span);
        try std.testing.expectEqual(lexer.Kind.dedent, structural[3].kind);
        try std.testing.expectEqual(lexer.Span{ .start = next_offset, .end = next_offset }, structural[3].span);
        try expectLossless(source, tokens);
    }

    const braced = try tokenize(source, .scss);
    defer std.testing.allocator.free(braced);
    try std.testing.expectEqual(@as(usize, 0), countKind(braced, .indent));
    try std.testing.expectEqual(@as(usize, 0), countKind(braced, .dedent));
}

test "inconsistent indentation is rejected instead of guessed" {
    try std.testing.expectError(
        error.InconsistentIndentation,
        lexer.tokenizeAlloc(std.testing.allocator, "a\n  b\n c", .sass, .{}),
    );
}

test "Sass and Less interpolation nest without leaking from comments" {
    const scss = "#{{a: {b: 1}}} \"x #{fn({a: 1})} y\" /* #{ignored} */";
    const scss_tokens = try tokenize(scss, .scss);
    defer std.testing.allocator.free(scss_tokens);
    try std.testing.expectEqual(@as(usize, 2), countKind(scss_tokens, .interpolation_start));
    try std.testing.expectEqual(@as(usize, 2), countKind(scss_tokens, .interpolation_end));
    try std.testing.expectEqual(@as(usize, 1), countKind(scss_tokens, .string_start));
    try std.testing.expectEqual(@as(usize, 1), countKind(scss_tokens, .string_end));
    try expectLossless(scss, scss_tokens);

    const less = "@{name} \"@{value}\" // @{ignored}\n";
    const less_tokens = try tokenize(less, .less);
    defer std.testing.allocator.free(less_tokens);
    try std.testing.expectEqual(@as(usize, 2), countKind(less_tokens, .interpolation_start));
    try std.testing.expectEqual(@as(usize, 2), countKind(less_tokens, .interpolation_end));
    try expectLossless(less, less_tokens);
}

test "strings retain escapes continuations and explicit unterminated state" {
    const source = "\"a\\\"b\" 'c\\\r\nd' \"unterminated\nx";
    const tokens = try tokenize(source, .scss);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), countKind(tokens, .string_start));
    try std.testing.expectEqual(@as(usize, 3), countKind(tokens, .string_end));
    var unterminated: usize = 0;
    for (tokens) |token| {
        if (token.kind == .string_end and !token.terminated) {
            unterminated += 1;
            try std.testing.expectEqual(token.span.start, token.span.end);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), unterminated);
    try expectLossless(source, tokens);
}

test "comment rules are syntax aware and unterminated blocks are explicit" {
    const source = "// one\r\n/* two */x/* open";
    const tokens = try tokenize(source, .scss);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), countKind(tokens, .comment));
    var unterminated: usize = 0;
    for (tokens) |token| {
        if (token.kind == .comment and !token.terminated) unterminated += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), unterminated);
    try expectLossless(source, tokens);

    const css_tokens = try tokenize(source, .css);
    defer std.testing.allocator.free(css_tokens);
    try std.testing.expectEqual(@as(usize, 2), countKind(css_tokens, .comment));
    try expectLossless(source, css_tokens);
}

test "operators use deterministic longest match" {
    const source = "a==b != c <= d >= e && f || g ... h .. i += j -= k *= l /= m %= n => o := p ~= q |= r ^= s $= t ?= u + - /";
    const expected = [_][]const u8{
        "==", "!=", "<=", ">=", "&&", "||", "...", "..", "+=", "-=", "*=", "/=", "%=", "=>", ":=", "~=", "|=", "^=", "$=", "?=", "+", "-", "/",
    };
    const tokens = try tokenize(source, .scss);
    defer std.testing.allocator.free(tokens);

    var index: usize = 0;
    for (tokens) |token| {
        if (token.kind != .operator) continue;
        try std.testing.expectEqualStrings(expected[index], token.raw(source));
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
    try expectLossless(source, tokens);
}

test "identifiers variables hashes and unsigned numbers preserve spelling" {
    const source = "$gap @theme #brand --custom _x café 12.5e-2px .75";
    const tokens = try tokenize(source, .scss);
    defer std.testing.allocator.free(tokens);
    try expectKinds(tokens, &.{
        .variable,
        .whitespace,
        .at_identifier,
        .whitespace,
        .hash_identifier,
        .whitespace,
        .identifier,
        .whitespace,
        .identifier,
        .whitespace,
        .identifier,
        .whitespace,
        .number,
        .identifier,
        .whitespace,
        .number,
        .eof,
    });
    try expectLossless(source, tokens);
}

test "identifier semantic equality decodes bounded CSS escapes" {
    try std.testing.expect(lexer.identifierEqlIgnoreCaseAscii("@else", "@else"));
    try std.testing.expect(lexer.identifierEqlIgnoreCaseAscii("@ELSE", "@else"));
    try std.testing.expect(lexer.identifierEqlIgnoreCaseAscii("@\\-else", "@-else"));
    try std.testing.expect(lexer.identifierEqlIgnoreCaseAscii("@\\65lse", "@else"));
    try std.testing.expect(lexer.identifierEqlIgnoreCaseAscii("@\\000065 lse", "@else"));
    try std.testing.expect(!lexer.identifierEqlIgnoreCaseAscii("@\\0000065lse", "@else"));
    try std.testing.expect(!lexer.identifierEqlIgnoreCaseAscii("@\\0lse", "@else"));
    try std.testing.expect(!lexer.identifierEqlIgnoreCaseAscii("@élse", "@else"));
    try std.testing.expect(!lexer.identifierEqlIgnoreCaseAscii("@else", "@élse"));
}

test "malformed bytes and dangling constructs always make lossless progress" {
    const source = [_]u8{ 0, 0x1f, 0xff, ' ', '"', 'x' };
    const tokens = try tokenize(&source, .scss);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(lexer.Kind.invalid, tokens[0].kind);
    try std.testing.expectEqual(lexer.Kind.invalid, tokens[1].kind);
    try std.testing.expectEqual(@as(usize, 1), countKind(tokens, .string_end));
    try std.testing.expect(!tokens[tokens.len - 2].terminated);
    try expectLossless(&source, tokens);

    const interpolation = "a #{b";
    const interpolation_tokens = try tokenize(interpolation, .scss);
    defer std.testing.allocator.free(interpolation_tokens);
    try std.testing.expectEqual(@as(usize, 1), countKind(interpolation_tokens, .interpolation_end));
    var found_unterminated = false;
    for (interpolation_tokens) |token| {
        if (token.kind == .interpolation_end) {
            found_unterminated = !token.terminated;
            try std.testing.expectEqual(token.span.start, token.span.end);
        }
    }
    try std.testing.expect(found_unterminated);
    try expectLossless(interpolation, interpolation_tokens);
}

test "every byte value is bounded deterministic and lossless" {
    var source: [256]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @intCast(index);

    for ([_]lexer.Syntax{ .css, .scss, .sass, .less, .stylus }) |syntax| {
        const first = try tokenize(&source, syntax);
        defer std.testing.allocator.free(first);
        const second = try tokenize(&source, syntax);
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualSlices(lexer.Token, first, second);
        try expectLossless(&source, first);
    }
}

test "input token nesting interpolation and indentation ceilings fail closed" {
    try std.testing.expectError(
        error.InputTooLarge,
        lexer.Lexer.init("abc", .scss, .{ .max_input_bytes = 2 }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        lexer.Lexer.init("", .scss, .{ .max_tokens = 0 }),
    );
    try std.testing.expectError(
        error.TokenLimitExceeded,
        lexer.tokenizeAlloc(std.testing.allocator, "a b", .scss, .{ .max_tokens = 2 }),
    );
    try std.testing.expectError(
        error.NestingDepthExceeded,
        lexer.tokenizeAlloc(std.testing.allocator, "(((", .scss, .{ .max_nesting_depth = 2 }),
    );
    try std.testing.expectError(
        error.InterpolationDepthExceeded,
        lexer.tokenizeAlloc(std.testing.allocator, "#{#{x}}", .scss, .{ .max_interpolation_depth = 1 }),
    );
    try std.testing.expectError(
        error.IndentationDepthExceeded,
        lexer.tokenizeAlloc(std.testing.allocator, "a\n  b\n    c", .sass, .{ .max_indentation_depth = 1 }),
    );
}

test "tokenization is deterministic and EOF is idempotent" {
    const source = "$a: \"#{1 + 2}\";\n.b { width: $a; }";
    const first = try tokenize(source, .scss);
    defer std.testing.allocator.free(first);
    const second = try tokenize(source, .scss);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(lexer.Token, first, second);

    var stream = try lexer.Lexer.init("x", .css, .{});
    _ = try stream.next();
    const eof = try stream.next();
    try std.testing.expectEqual(lexer.Kind.eof, eof.kind);
    try std.testing.expectEqual(eof, try stream.next());
}

fn exerciseCollectionAllocationFailures(allocator: std.mem.Allocator) !void {
    const source = "$a: \"#{1 + 2}\";\n.root\n  color red\n";
    const tokens = try lexer.tokenizeAlloc(allocator, source, .sass, .{});
    defer allocator.free(tokens);
    try expectLossless(source, tokens);
}

test "materialized token ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCollectionAllocationFailures,
        .{},
    );
}

test "streaming lexer itself performs no allocation" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    _ = failing.allocator();
    var stream = try lexer.Lexer.init("a { b: #{1 + 2}; }", .scss, .{});
    while (true) {
        const token = try stream.next();
        if (token.kind == .eof) break;
    }
    try std.testing.expect(!failing.has_induced_failure);
}
