const std = @import("std");
const preprocessor = @import("native_preprocessor");
const sass = preprocessor.sass;
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

fn expectText(
    sources: *const source.Table,
    node: *const syntax.Node,
    expected: []const u8,
) !void {
    try std.testing.expectEqualStrings(expected, try sources.slice(node.text.?));
}

test "native SCSS parser returns one complete immutable document" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    var input = [_]u8{
        '$', 'c', 'o', 'l', 'o', 'r', ':', ' ', 'r', 'e', 'd', ';', ' ',
        '.', 'c', 'a', 'r', 'd', ' ', '{', ' ', 'c', 'o', 'l', 'o', 'r',
        ':', ' ', '$', 'c', 'o', 'l', 'o', 'r', ';', ' ', '}',
    };
    const source_id = try sources.add("input.scss", &input);
    input[1] = 'X';
    var parser = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .scss,
        .{},
        .{},
    );
    var document = try parser.parse();
    parser.deinit();
    defer document.deinit();

    try std.testing.expectEqual(
        syntax.Kind.stylesheet,
        (try document.get(document.root)).kind,
    );
    try std.testing.expectEqual(@as(usize, 2), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .declaration));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .rule));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .variable));
    try expectText(&sources, firstKind(&document, .selector).?, ".card");
}

test "SCSS retains comments strings interpolation nesting and nested properties" {
    const input =
        \\$mode: dark;
        \\$theme: "theme-#{$mode}";
        \\/* loud */
        \\// silent
        \\.card, .panel {
        \\  color: $theme;
        \\  &:hover { border-color: #{$theme}; }
        \\  font: { size: 1rem }
        \\}
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("features.scss", input);
    var parser = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .scss,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 5), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .comment));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .string));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .interpolation));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .rule));
    try std.testing.expectEqual(@as(usize, 6), countKind(&document, .declaration));
    try std.testing.expectEqual(@as(usize, 0), parser.diagnostics().len);
}

test "indented Sass uses physical indentation and preserves nested interpolation" {
    const input =
        \\$theme: dark
        \\// hidden
        \\.card
        \\  color: $theme
        \\  &:hover
        \\    content: "x-#{$theme}"
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("features.sass", input);
    var parser = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .sass,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 3), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .comment));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .rule));
    try std.testing.expectEqual(@as(usize, 3), countKind(&document, .declaration));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .string));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .interpolation));
    var saw_card = false;
    for (document.nodes()) |node| {
        if (node.kind == .selector and
            std.mem.eql(u8, try sources.slice(node.text.?), ".card"))
        {
            saw_card = true;
        }
    }
    try std.testing.expect(saw_card);
}

test "indented Sass continuations do not become false blocks" {
    const input =
        \\@each $a,
        \\  $b in (c: d)
        \\  .#{$a}
        \\    e: $b
        \\a
        \\  b: (
        \\    c,
        \\    d
        \\)
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("continuation.sass", input);
    var parser = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .sass,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .loop));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .rule));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .declaration));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .interpolation));
}

test "Sass directives retain closed semantic classifications" {
    const input =
        \\@mixin paint($x) { @content; }
        \\@function twice($x) { @return $x * 2; }
        \\@if true { a { b: c; } } @else { d { e: f; } }
        \\@for $i from 1 through 2 { .n-#{$i} { x: $i; } }
        \\@use "sass:math";
        \\@forward "tokens";
        \\@import "legacy";
        \\@media all { a { b: c; } }
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("directives.scss", input);
    var parser = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .scss,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .mixin));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .content));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .function));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .return_statement));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .conditional));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .loop));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .module));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .import));
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .at_rule));
}

test "SCSS declaration and selector ambiguity remains structural" {
    const input =
        \\a {
        \\  color:red;
        \\  a:hover { color: blue; }
        \\  font: { size: 1rem }
        \\}
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("ambiguity.scss", input);
    var parser = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .scss,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .rule));
    try std.testing.expectEqual(@as(usize, 4), countKind(&document, .declaration));
    var saw_hover = false;
    for (document.nodes()) |node| {
        if (node.kind == .selector and
            std.mem.eql(u8, try sources.slice(node.text.?), "a:hover"))
        {
            saw_hover = true;
        }
    }
    try std.testing.expect(saw_hover);
}

test "deterministic replay produces identical Sass syntax documents" {
    const input = "$x: 1; .a { width: #{$x + 1}; }";
    var first_sources = source.Table.init(std.testing.allocator, .{});
    defer first_sources.deinit();
    var second_sources = source.Table.init(std.testing.allocator, .{});
    defer second_sources.deinit();
    const first_id = try first_sources.add("input.scss", input);
    const second_id = try second_sources.add("input.scss", input);
    var first = try sass.Parser.init(
        std.testing.allocator,
        &first_sources,
        first_id,
        .scss,
        .{},
        .{},
    );
    defer first.deinit();
    var second = try sass.Parser.init(
        std.testing.allocator,
        &second_sources,
        second_id,
        .scss,
        .{},
        .{},
    );
    defer second.deinit();
    var first_document = try first.parse();
    defer first_document.deinit();
    var second_document = try second.parse();
    defer second_document.deinit();

    try std.testing.expectEqualSlices(syntax.Node, first_document.nodes(), second_document.nodes());
    try std.testing.expectEqualSlices(
        syntax.NodeId,
        first_document.child_items,
        second_document.child_items,
    );
}

test "native parser accepts every pinned Sass success entry" {
    const ManifestCase = struct {
        id: []const u8,
        syntax: []const u8,
        outcome: []const u8,
        entry: []const u8,
    };
    const Manifest = struct {
        cases: []const ManifestCase,
    };
    const manifest_bytes = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/sass/corpus/manifest.json",
        1024 * 1024,
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
            "tests/preprocessors/sass/corpus/cases",
            case.id,
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
        var parser = sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            if (std.mem.eql(u8, case.syntax, "sass")) .sass else .scss,
            .{},
            .{},
        ) catch |err| {
            std.debug.print("native parser init rejected {s}: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer parser.deinit();
        var document = parser.parse() catch |err| {
            std.debug.print("native parser rejected {s}: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer document.deinit();
        parsed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 60), parsed_count);
}

test "native parser rejects pinned lexical and delimiter failures" {
    const cases = [_]struct {
        id: []const u8,
        entry: []const u8,
        mode: sass.Mode,
    }{
        .{ .id = "scss-error-interpolation-bracket", .entry = "input.scss", .mode = .scss },
        .{ .id = "scss-error-raw-newline", .entry = "input.scss", .mode = .scss },
        .{ .id = "scss-error-comment-unterminated", .entry = "input.scss", .mode = .scss },
        .{ .id = "sass-error-interpolation-bracket", .entry = "input.sass", .mode = .sass },
        .{ .id = "sass-error-selector-paren", .entry = "input.sass", .mode = .sass },
        .{ .id = "sass-error-string-raw-newline", .entry = "input.sass", .mode = .sass },
        .{ .id = "sass-error-comment-unterminated", .entry = "input.sass", .mode = .sass },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(std.testing.allocator, &.{
            "tests/preprocessors/sass/corpus/cases",
            case.id,
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
        var parser = try sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            case.mode,
            .{},
            .{},
        );
        defer parser.deinit();
        try std.testing.expectError(error.InvalidSyntax, parser.parse());
        try std.testing.expectEqual(@as(usize, 1), parser.diagnostics().len);
        try std.testing.expectError(error.SessionFailed, parser.parse());
    }
}

test "malformed Sass is diagnostic terminal and produces no document" {
    const cases = [_]struct {
        mode: sass.Mode,
        input: []const u8,
    }{
        .{ .mode = .scss, .input = "a { color red; }" },
        .{ .mode = .scss, .input = "a { color: \"oops\n; }" },
        .{ .mode = .scss, .input = "a { color: #{$x; }" },
        .{ .mode = .scss, .input = "a { /* nope" },
        .{ .mode = .scss, .input = "a { color: red; ] }" },
        .{ .mode = .sass, .input = "a\nb: c\n" },
        .{ .mode = .sass, .input = "$missing_colon\n" },
    };
    for (cases, 0..) |case, index| {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const name = if (case.mode == .scss) "invalid.scss" else "invalid.sass";
        const source_id = try sources.add(name, case.input);
        var parser = try sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            case.mode,
            .{},
            .{},
        );
        defer parser.deinit();
        try std.testing.expectError(error.InvalidSyntax, parser.parse());
        try std.testing.expectEqual(@as(usize, 1), parser.diagnostics().len);
        try std.testing.expectEqual(preprocessor.diagnostics.Code.syntax, parser.diagnostics()[0].code);
        try std.testing.expectError(error.SessionFailed, parser.parse());
        _ = index;
    }
}

test "invalid UTF-8 and inconsistent indentation fail closed" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const invalid_id = try sources.add("invalid.scss", &[_]u8{ '.', 'a', '{', 0xff, '}' });
    var invalid = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        invalid_id,
        .scss,
        .{},
        .{},
    );
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidSyntax, invalid.parse());
    try std.testing.expectEqualStrings("source is not valid UTF-8", invalid.diagnostics()[0].message);

    const indent_id = try sources.add("indent.sass", "a\n    b: c\n  d: e\n");
    try std.testing.expectError(
        error.InconsistentIndentation,
        sass.Parser.init(
            std.testing.allocator,
            &sources,
            indent_id,
            .sass,
            .{},
            .{},
        ),
    );
}

test "parser resource ceilings are independent and terminal" {
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("tokens.scss", "$x: 1;");
        var limits = sass.Limits{};
        limits.lexer.max_tokens = 2;
        try std.testing.expectError(
            error.TokenLimitExceeded,
            sass.Parser.init(
                std.testing.allocator,
                &sources,
                source_id,
                .scss,
                limits,
                .{},
            ),
        );
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("statements.scss", "$a: 1; $b: 2;");
        var limits = sass.Limits{};
        limits.max_statements = 1;
        var parser = try sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .scss,
            limits,
            .{},
        );
        defer parser.deinit();
        try std.testing.expectError(error.StatementLimitExceeded, parser.parse());
        try std.testing.expectError(error.SessionFailed, parser.parse());
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("nodes.scss", "$a: 1;");
        var limits = sass.Limits{};
        limits.syntax.max_nodes = 1;
        var parser = try sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .scss,
            limits,
            .{},
        );
        defer parser.deinit();
        try std.testing.expectError(error.SyntaxNodeLimitExceeded, parser.parse());
    }
    {
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("depth.scss", ".a { .b { x: y; } }");
        var limits = sass.Limits{};
        limits.syntax.max_depth = 2;
        var parser = try sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .scss,
            limits,
            .{},
        );
        defer parser.deinit();
        try std.testing.expectError(error.SyntaxDepthExceeded, parser.parse());
    }
}

test "invalid parser limits are rejected before tokenization" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "");
    var invalid = sass.Limits{};
    invalid.max_statements = 0;
    try std.testing.expectError(
        error.InvalidLimits,
        sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .scss,
            invalid,
            .{},
        ),
    );
    invalid = .{};
    invalid.lexer.max_input_bytes = 10 * 1024 * 1024 + 1;
    try std.testing.expectError(
        error.InvalidLimits,
        sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .scss,
            invalid,
            .{},
        ),
    );
}

const CancelContext = struct {
    target: sass.Checkpoint,
    calls: usize = 0,

    fn check(context: *anyopaque, checkpoint: sass.Checkpoint) bool {
        const self: *CancelContext = @ptrCast(@alignCast(context));
        self.calls += 1;
        return checkpoint == self.target;
    }
};

test "tokenization and parsing cancellation never expose a partial document" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "$a: 1; $b: 2;");
    var tokenize_context = CancelContext{ .target = .tokenize };
    try std.testing.expectError(
        error.Cancelled,
        sass.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .scss,
            .{},
            .{ .context = &tokenize_context, .check_fn = CancelContext.check },
        ),
    );
    try std.testing.expect(tokenize_context.calls > 0);

    var statement_context = CancelContext{ .target = .statement };
    var parser = try sass.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .scss,
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
    const scss_id = try sources.add(
        "input.scss",
        "$mode: dark; .a { color: \"x-#{$mode}\"; &:hover { width: 1px; } }",
    );
    const sass_id = try sources.add(
        "input.sass",
        "$mode: dark\n.a\n  color: \"x-#{$mode}\"\n  &:hover\n    width: 1px\n",
    );
    var scss = try sass.Parser.init(allocator, &sources, scss_id, .scss, .{}, .{});
    defer scss.deinit();
    var scss_document = try scss.parse();
    defer scss_document.deinit();
    var indented = try sass.Parser.init(allocator, &sources, sass_id, .sass, .{}, .{});
    defer indented.deinit();
    var sass_document = try indented.parse();
    defer sass_document.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try scss_document.children(scss_document.root)).len);
    try std.testing.expectEqual(@as(usize, 2), (try sass_document.children(sass_document.root)).len);
}

test "native Sass parser handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
