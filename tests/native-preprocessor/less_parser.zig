const std = @import("std");
const preprocessor = @import("native_preprocessor");
const less = preprocessor.less;
const source = preprocessor.source;
const syntax = preprocessor.syntax;

fn countKind(document: *const syntax.Document, kind: syntax.Kind) usize {
    var count: usize = 0;
    for (document.nodes()) |node| {
        if (node.kind == kind) count += 1;
    }
    return count;
}

fn firstKind(document: *const syntax.Document, kind: syntax.Kind) ?*const syntax.Node {
    for (document.nodes()) |*node| {
        if (node.kind == kind) return node;
    }
    return null;
}

test "native Less parser returns one complete immutable document" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    var input = [_]u8{
        '@', 'c', ':', ' ', 'r', 'e', 'd', ';', ' ', '.', 'c', 'a', 'r', 'd',
        ' ', '{', ' ', 'c', 'o', 'l', 'o', 'r', ':', ' ', '@', 'c', ';', ' ',
        '}',
    };
    const source_id = try sources.add("input.less", &input);
    input[1] = 'X';
    var parser = try less.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .{},
        .{},
    );
    var document = try parser.parse();
    parser.deinit();
    defer document.deinit();

    try std.testing.expectEqual(syntax.Kind.stylesheet, (try document.get(document.root)).kind);
    try std.testing.expectEqual(@as(usize, 2), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .declaration));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .variable));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .rule));
    const selector = firstKind(&document, .selector).?;
    try std.testing.expectEqualStrings(".card", try sources.slice(selector.text.?));
}

test "Less parser preserves the finite parser feature surface" {
    const input =
        \\@base: 4px;
        \\@name: card;
        \\@rules: { color: red; };
        \\.paint(@x; @tone: red) when (@x > 0) { width: @x + @base; color: @tone; }
        \\.@{name} {
        \\  .paint(2px);
        \\  @rules();
        \\  &:extend(.shared all);
        \\  & + & { content: "@{name}"; }
        \\}
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("features.less", input);
    var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 5), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .detached_ruleset));
    try std.testing.expect(countKind(&document, .mixin) >= 3);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .guard));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .extend));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .interpolation));
    try std.testing.expect(countKind(&document, .expression) >= 5);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .string));
}

test "Less imports at-rules comments and CSS syntax remain structural" {
    const input =
        \\@charset "UTF-8";
        \\@import (reference) "tokens.less" screen;
        \\// quiet
        \\/* loud */
        \\@media (min-width: 1px) { a { --raw: calc(1px + 2%); } }
        \\@plugin "unsafe.js";
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("directives.less", input);
    var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .import));
    try std.testing.expectEqual(@as(usize, 3), countKind(&document, .at_rule));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .comment));
    try std.testing.expectEqual(@as(usize, 3), countKind(&document, .string));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .rule));
    try std.testing.expectEqual(@as(usize, 0), parser.diagnostics().len);
}

test "native parser accepts every pinned Less success entry" {
    const SelectionCase = struct {
        id: []const u8,
        suite: []const u8,
        outcome: []const u8,
        entry: []const u8,
    };
    const Selection = struct { cases: []const SelectionCase };
    const selection_bytes = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/less/corpus/selection.json",
        1024 * 1024,
    );
    defer std.testing.allocator.free(selection_bytes);
    var selection = try std.json.parseFromSlice(
        Selection,
        std.testing.allocator,
        selection_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer selection.deinit();

    var parsed_count: usize = 0;
    for (selection.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "success")) continue;
        const path = try std.fs.path.join(std.testing.allocator, &.{
            "tests/preprocessors/less/corpus/files",
            case.suite,
            case.entry,
        });
        defer std.testing.allocator.free(path);
        const input = try std.fs.cwd().readFileAlloc(
            std.testing.allocator,
            path,
            10 * 1024 * 1024,
        );
        defer std.testing.allocator.free(input);
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add(path, input);
        var parser = less.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .{},
            .{},
        ) catch |err| {
            std.debug.print("native Less parser init rejected {s}: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer parser.deinit();
        var document = parser.parse() catch |err| {
            std.debug.print("native Less parser rejected {s}: {s}\n", .{ case.id, @errorName(err) });
            if (parser.diagnostics().len > 0) {
                std.debug.print("diagnostic: {s} at {d}\n", .{
                    parser.diagnostics()[0].message,
                    parser.diagnostics()[0].span.start,
                });
            }
            return err;
        };
        defer document.deinit();
        parsed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 68), parsed_count);
}

test "native parser rejects every pinned Less parse error" {
    const SelectionCase = struct {
        id: []const u8,
        suite: []const u8,
        outcome: []const u8,
        entry: []const u8,
    };
    const Selection = struct { cases: []const SelectionCase };
    const selection_bytes = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/less/corpus/selection.json",
        1024 * 1024,
    );
    defer std.testing.allocator.free(selection_bytes);
    var selection = try std.json.parseFromSlice(
        Selection,
        std.testing.allocator,
        selection_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer selection.deinit();

    var rejected_count: usize = 0;
    for (selection.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "error") or
            !std.mem.eql(u8, case.suite, "tests-error/parse")) continue;
        const path = try std.fs.path.join(std.testing.allocator, &.{
            "tests/preprocessors/less/corpus/files",
            case.suite,
            case.entry,
        });
        defer std.testing.allocator.free(path);
        const input = try std.fs.cwd().readFileAlloc(
            std.testing.allocator,
            path,
            10 * 1024 * 1024,
        );
        defer std.testing.allocator.free(input);
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add(path, input);
        var parser = try less.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .{},
            .{},
        );
        defer parser.deinit();
        if (parser.parse()) |document_value| {
            var document = document_value;
            document.deinit();
            std.debug.print("native Less parser accepted parse error {s}\n", .{case.id});
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(error.InvalidSyntax, err);
            try std.testing.expectEqual(@as(usize, 1), parser.diagnostics().len);
            try std.testing.expectError(error.SessionFailed, parser.parse());
        }
        rejected_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), rejected_count);
}

test "malformed Less is diagnostic terminal and produces no document" {
    const cases = [_][]const u8{
        "@x:;",
        "a { color red; }",
        "a { color: \"oops\n; }",
        "a { color: @{x; }",
        "a { /* nope",
        "a { color: red; ] }",
        "@import;",
    };
    for (cases) |input| {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("invalid.less", input);
        var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
        defer parser.deinit();
        try std.testing.expectError(error.InvalidSyntax, parser.parse());
        try std.testing.expectEqual(@as(usize, 1), parser.diagnostics().len);
        try std.testing.expectEqual(preprocessor.diagnostics.Code.syntax, parser.diagnostics()[0].code);
        try std.testing.expectError(error.SessionFailed, parser.parse());
    }
}

test "deterministic replay produces identical Less syntax documents" {
    const input = "@x: 1; .a { width: (@x + 1); &:extend(.b all); }";
    var first_sources = source.Table.init(std.testing.allocator, .{});
    defer first_sources.deinit();
    var second_sources = source.Table.init(std.testing.allocator, .{});
    defer second_sources.deinit();
    const first_id = try first_sources.add("input.less", input);
    const second_id = try second_sources.add("input.less", input);
    var first = try less.Parser.init(std.testing.allocator, &first_sources, first_id, .{}, .{});
    defer first.deinit();
    var second = try less.Parser.init(std.testing.allocator, &second_sources, second_id, .{}, .{});
    defer second.deinit();
    var first_document = try first.parse();
    defer first_document.deinit();
    var second_document = try second.parse();
    defer second_document.deinit();

    try std.testing.expectEqualSlices(syntax.Node, first_document.nodes(), second_document.nodes());
    try std.testing.expectEqualSlices(syntax.NodeId, first_document.child_items, second_document.child_items);
}

test "invalid UTF-8 and parser resource ceilings fail closed" {
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("invalid.less", &[_]u8{ '.', 'a', '{', 0xff, '}' });
        var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
        defer parser.deinit();
        try std.testing.expectError(error.InvalidSyntax, parser.parse());
        try std.testing.expectEqualStrings("source is not valid UTF-8", parser.diagnostics()[0].message);
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("tokens.less", "@x: 1;");
        var limits = less.Limits{};
        limits.lexer.max_tokens = 2;
        try std.testing.expectError(
            error.TokenLimitExceeded,
            less.Parser.init(std.testing.allocator, &sources, source_id, limits, .{}),
        );
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("statements.less", "@a: 1; @b: 2;");
        var limits = less.Limits{};
        limits.max_statements = 1;
        var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, limits, .{});
        defer parser.deinit();
        try std.testing.expectError(error.StatementLimitExceeded, parser.parse());
        try std.testing.expectError(error.SessionFailed, parser.parse());
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("nodes.less", "@a: 1;");
        var limits = less.Limits{};
        limits.syntax.max_nodes = 1;
        var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, limits, .{});
        defer parser.deinit();
        try std.testing.expectError(error.SyntaxNodeLimitExceeded, parser.parse());
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("depth.less", ".a { .b { x: y; } }");
        var limits = less.Limits{};
        limits.syntax.max_depth = 2;
        var parser = try less.Parser.init(std.testing.allocator, &sources, source_id, limits, .{});
        defer parser.deinit();
        try std.testing.expectError(error.SyntaxDepthExceeded, parser.parse());
    }
}

test "invalid Less parser limits are rejected before tokenization" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.less", "");
    var invalid = less.Limits{};
    invalid.max_statements = 0;
    try std.testing.expectError(
        error.InvalidLimits,
        less.Parser.init(std.testing.allocator, &sources, source_id, invalid, .{}),
    );
    invalid = .{};
    invalid.lexer.max_input_bytes = 10 * 1024 * 1024 + 1;
    try std.testing.expectError(
        error.InvalidLimits,
        less.Parser.init(std.testing.allocator, &sources, source_id, invalid, .{}),
    );
}

const CancelContext = struct {
    target: less.Checkpoint,
    calls: usize = 0,

    fn check(context: *anyopaque, checkpoint: less.Checkpoint) bool {
        const self: *CancelContext = @ptrCast(@alignCast(context));
        self.calls += 1;
        return checkpoint == self.target;
    }
};

test "Less tokenization and parsing cancellation expose no partial document" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.less", "@a: 1; @b: 2;");
    var tokenize_context = CancelContext{ .target = .tokenize };
    try std.testing.expectError(
        error.Cancelled,
        less.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .{},
            .{ .context = &tokenize_context, .check_fn = CancelContext.check },
        ),
    );
    try std.testing.expect(tokenize_context.calls > 0);

    var statement_context = CancelContext{ .target = .statement };
    var parser = try less.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .{},
        .{ .context = &statement_context, .check_fn = CancelContext.check },
    );
    defer parser.deinit();
    try std.testing.expectError(error.Cancelled, parser.parse());
    try std.testing.expectError(error.SessionFailed, parser.parse());
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "input.less",
        "@name: card; @rules: { color: red; }; .@{name} { @rules(); width: (1px + 2px); }",
    );
    var parser = try less.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 3), (try document.children(document.root)).len);
}

test "native Less parser handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
