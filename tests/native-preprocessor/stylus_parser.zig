const std = @import("std");
const preprocessor = @import("native_preprocessor");
const source = preprocessor.source;
const stylus = preprocessor.stylus;
const syntax = preprocessor.syntax;

const parser_negative_ids = [_][]const u8{
    "unclosed-expression",
    "unexpected-brace",
    "unclosed-media",
    "unclosed-function",
    "dangling-selector",
    "empty-import",
    "root-break",
    "bad-charset",
    "unclosed-object",
    "unterminated-string",
    "bad-ternary",
    "bad-atblock",
    "bad-property",
};

fn countKind(document: *const syntax.Document, kind: syntax.Kind) usize {
    var count: usize = 0;
    for (document.nodes()) |node| {
        if (node.kind == kind) count += 1;
    }
    return count;
}

fn isParserNegative(id: []const u8) bool {
    for (parser_negative_ids) |expected| {
        if (std.mem.eql(u8, id, expected)) return true;
    }
    return false;
}

test "native Stylus parser preserves indentation optional punctuation and syntax kinds" {
    var input = try std.testing.allocator.dupe(u8,
        \\tone = red
        \\button,
        \\.button
        \\  color tone;
        \\  &:hover
        \\    content "hi {tone}"
        \\size(value = 1px)
        \\  return value * 2
        \\@media screen
        \\  .item
        \\    width size(2px)
    );
    defer std.testing.allocator.free(input);
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.styl", input);
    input[0] = 'X';
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(syntax.Kind.stylesheet, (try document.get(document.root)).kind);
    try std.testing.expect(countKind(&document, .variable) >= 1);
    try std.testing.expect(countKind(&document, .rule) >= 3);
    try std.testing.expect(countKind(&document, .selector) >= 3);
    try std.testing.expect(countKind(&document, .declaration) >= 3);
    try std.testing.expect(countKind(&document, .expression) >= 4);
    try std.testing.expect(countKind(&document, .function) >= 1);
    try std.testing.expect(countKind(&document, .return_statement) >= 1);
    try std.testing.expect(countKind(&document, .at_rule) >= 1);
    try std.testing.expect(countKind(&document, .string) >= 1);
    try std.testing.expect(countKind(&document, .call) >= 1);
}

test "native parser accepts every pinned Stylus success entry" {
    const CorpusCase = struct {
        id: []const u8,
        outcome: []const u8,
        entry: []const u8,
    };
    const Manifest = struct {
        officialSuccessCount: usize,
        cases: []const CorpusCase,
    };
    const manifest_bytes = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/stylus/corpus/manifest.json",
        2 * 1024 * 1024,
    );
    defer std.testing.allocator.free(manifest_bytes);
    var manifest = try std.json.parseFromSlice(
        Manifest,
        std.testing.allocator,
        manifest_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer manifest.deinit();

    var parsed_count: usize = 0;
    for (manifest.value.cases) |case| {
        if (!std.mem.eql(u8, case.outcome, "success")) continue;
        const path = try std.fs.path.join(std.testing.allocator, &.{
            "tests/preprocessors/stylus/corpus/files",
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
        var parser = stylus.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .{},
            .{},
        ) catch |err| {
            std.debug.print("native Stylus parser init rejected {s}: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer parser.deinit();
        var document = parser.parse() catch |err| {
            std.debug.print("native Stylus parser rejected {s}: {s}\n", .{ case.id, @errorName(err) });
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
    try std.testing.expectEqual(manifest.value.officialSuccessCount, parsed_count);
    try std.testing.expectEqual(@as(usize, 326), parsed_count);
}

test "native Stylus parser excludes an initial UTF-8 BOM from exact syntax spans" {
    const input = "\xEF\xBB\xBFbody\n  color red\n";
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("utf8-bom.styl", input);
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 1), root_children.len);
    const rule = try document.get(root_children[0]);
    try std.testing.expectEqual(syntax.Kind.rule, rule.kind);
    try std.testing.expectEqual(@as(u32, 3), rule.text.?.start);
    try std.testing.expectEqualStrings("body", try sources.slice(rule.text.?));
    const rule_children = try document.children(root_children[0]);
    const selector = try document.get(rule_children[0]);
    try std.testing.expectEqualStrings("body", try sources.slice(selector.text.?));
}

test "native parser rejects every pinned Stylus parser error" {
    const NegativeCase = struct {
        id: []const u8,
        source: []const u8,
    };
    const Selection = struct { negativeCases: []const NegativeCase };
    const selection_bytes = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/stylus/corpus/selection.json",
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
    for (selection.value.negativeCases) |case| {
        if (!isParserNegative(case.id)) continue;
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("invalid.styl", case.source);
        var parser = try stylus.Parser.init(
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
            std.debug.print("native Stylus parser accepted parser error {s}\n", .{case.id});
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(error.InvalidSyntax, err);
            try std.testing.expectEqual(@as(usize, 1), parser.diagnostics().len);
            try std.testing.expectError(error.SessionFailed, parser.parse());
        }
        rejected_count += 1;
    }
    try std.testing.expectEqual(parser_negative_ids.len, rejected_count);
}

test "invalid UTF-8 and Stylus parser resource ceilings fail closed" {
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("invalid.styl", &[_]u8{ '.', 'a', '\n', ' ', ' ', 0xff });
        var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
        defer parser.deinit();
        try std.testing.expectError(error.InvalidSyntax, parser.parse());
        try std.testing.expectEqualStrings("source is not valid UTF-8", parser.diagnostics()[0].message);
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("tokens.styl", ".a\n  color red\n");
        var limits = stylus.Limits{};
        limits.lexer.max_tokens = 2;
        try std.testing.expectError(
            error.TokenLimitExceeded,
            stylus.Parser.init(std.testing.allocator, &sources, source_id, limits, .{}),
        );
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("statements.styl", "a = 1\nb = 2\n");
        var limits = stylus.Limits{};
        limits.max_statements = 1;
        var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, limits, .{});
        defer parser.deinit();
        try std.testing.expectError(error.StatementLimitExceeded, parser.parse());
        try std.testing.expectError(error.SessionFailed, parser.parse());
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("punctuation.styl", "body { color: red; width: 1px; }\n");
        var limits = stylus.Limits{};
        limits.max_statements = 1;
        var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, limits, .{});
        defer parser.deinit();
        try std.testing.expectError(error.StatementLimitExceeded, parser.parse());
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("nodes.styl", "a = 1\n");
        var limits = stylus.Limits{};
        limits.syntax.max_nodes = 1;
        var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, limits, .{});
        defer parser.deinit();
        try std.testing.expectError(error.SyntaxNodeLimitExceeded, parser.parse());
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("depth.styl", ".a\n  .b\n    color red\n");
        var limits = stylus.Limits{};
        limits.syntax.max_depth = 2;
        var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, limits, .{});
        defer parser.deinit();
        try std.testing.expectError(error.SyntaxDepthExceeded, parser.parse());
    }
}

test "invalid Stylus parser limits are rejected before tokenization" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.styl", "");
    var invalid = stylus.Limits{};
    invalid.max_statements = 0;
    try std.testing.expectError(
        error.InvalidLimits,
        stylus.Parser.init(std.testing.allocator, &sources, source_id, invalid, .{}),
    );
    invalid = .{};
    invalid.lexer.max_input_bytes = 10 * 1024 * 1024 + 1;
    try std.testing.expectError(
        error.InvalidLimits,
        stylus.Parser.init(std.testing.allocator, &sources, source_id, invalid, .{}),
    );
}

const CancelContext = struct {
    target: stylus.Checkpoint,
    calls: usize = 0,

    fn check(context: *anyopaque, checkpoint: stylus.Checkpoint) bool {
        const self: *CancelContext = @ptrCast(@alignCast(context));
        self.calls += 1;
        return checkpoint == self.target;
    }
};

test "Stylus tokenization and parsing cancellation expose no partial document" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.styl", ".a\n  color red\n");
    var tokenize_context = CancelContext{ .target = .tokenize };
    try std.testing.expectError(
        error.Cancelled,
        stylus.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .{},
            .{ .context = &tokenize_context, .check_fn = CancelContext.check },
        ),
    );
    try std.testing.expect(tokenize_context.calls > 0);

    var statement_context = CancelContext{ .target = .statement };
    var parser = try stylus.Parser.init(
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
        "input.styl",
        "name = card\n.{name}\n  color rgba(1, 2, 3, .5)\n  &:hover\n    width 1px + 2px\n",
    );
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try document.children(document.root)).len);
}

test "native Stylus parser handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "deterministic replay produces identical Stylus syntax documents" {
    const input = ".a\n  color red\n  &:hover\n    width 1px + 2px\n";
    var first_sources = source.Table.init(std.testing.allocator, .{});
    defer first_sources.deinit();
    var second_sources = source.Table.init(std.testing.allocator, .{});
    defer second_sources.deinit();
    const first_id = try first_sources.add("input.styl", input);
    const second_id = try second_sources.add("input.styl", input);
    var first = try stylus.Parser.init(std.testing.allocator, &first_sources, first_id, .{}, .{});
    defer first.deinit();
    var second = try stylus.Parser.init(std.testing.allocator, &second_sources, second_id, .{}, .{});
    defer second.deinit();
    var first_document = try first.parse();
    defer first_document.deinit();
    var second_document = try second.parse();
    defer second_document.deinit();

    try std.testing.expectEqualSlices(syntax.Node, first_document.nodes(), second_document.nodes());
    try std.testing.expectEqualSlices(syntax.NodeId, first_document.child_items, second_document.child_items);
}
