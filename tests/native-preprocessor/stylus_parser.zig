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

const anonymous_functions_input =
    \\mixin(add) {
    \\  mul = @(c, d) {
    \\    c * d
    \\  }
    \\  width: add(2, 3) + mul(4, 5)
    \\}
    \\body
    \\  mixin(@(a, b) {
    \\    return a + b;
    \\  })
;

const multiline_functions_input =
    \\pad(
    \\  x = 5
    \\, y = 10
    \\)
    \\  padding y x
    \\body
    \\  pad 1 2
    \\pad(
    \\    x = 5
    \\  , y = 10
    \\)
    \\  padding y x
    \\body
    \\  pad 1 2
    \\body
    \\  pad(x
    \\    , y
    \\  )
    \\    padding y x
    \\  pad 2 3
;

const declaration_assignment_input =
    \\pad-y(y)
    \\  padding-top n = unit(y, 'px')
    \\  padding-bottom n
    \\form
    \\  pad-y(10)
;

const multiline_media_query_input =
    \\@media /* outer */ all and (min-width: 100px),
    \\/* second */ only print and (width: 100px)
    \\, /* third */ (monochrome)
    \\  body
    \\    color green
;

const multiline_declaration_input =
    \\.popup
    \\  box-shadow:
    \\    0 -2px 2px hsl(220, 20%, 40%),
    \\    inset 0 1px 0 hsl(
    \\      219,
    \\      20%,
    \\      0%
    \\    ),
    \\    inset 0 -1px 0 hsl(220, 20%, 20%)
    \\  foo: 'bar'
;

const inline_object_assignment_input =
    \\a = {}
    \\bar(obj)
    \\  obj.params = { foo: 'bar' }
    \\bar(a)
;

const multiline_assignment_input =
    \\families = Helvetica,
    \\  Arial,
    \\  sans-serif
    \\body
    \\  font-families families
;

const parse_fixture_path =
    "tests/preprocessors/stylus/corpus/files/upstream/cases/parse.styl";

const properties_fixture_path =
    "tests/preprocessors/stylus/corpus/files/upstream/cases/properties.styl";

const parse_comment_lower_input =
    \\body
    \\  color red
    \\  // outer
    \\    // nested
    \\   // uneven
    \\  border 1px solid blue
;

const properties_function_lower_input =
    \\body
    \\  background-image:
    \\    linear-gradient(
    \\      red,
    \\      blue
    \\    )
;

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

test "native Stylus parser classifies compact declarations inside explicit CSS blocks" {
    const input =
        \\html {margin:0;padding:0;border:0;}
        \\a:hover {background:url(http://example.test/a:b);}
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("compact-declarations.styl", input);
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
    try std.testing.expectEqual(@as(usize, 2), root_children.len);

    const reset_children = try document.children(root_children[0]);
    try std.testing.expectEqual(@as(usize, 2), reset_children.len);
    try std.testing.expectEqual(syntax.Kind.selector, (try document.get(reset_children[0])).kind);
    const reset_declarations = try document.children(reset_children[1]);
    try std.testing.expectEqual(@as(usize, 3), reset_declarations.len);
    for (reset_declarations) |declaration_id| {
        try std.testing.expectEqual(syntax.Kind.declaration, (try document.get(declaration_id)).kind);
    }

    const link_children = try document.children(root_children[1]);
    try std.testing.expectEqualStrings(
        "a:hover",
        try sources.slice((try document.get(link_children[0])).text.?),
    );
    const link_declarations = try document.children(link_children[1]);
    try std.testing.expectEqual(@as(usize, 1), link_declarations.len);
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try document.get(link_declarations[0])).kind,
    );
}

test "native Stylus parser keeps a nested explicit rule beside compact declarations" {
    const input =
        \\.root { color: red; background: black;
        \\  em {
        \\    color: gray;
        \\  }
        \\}
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("compact-nested-rule.styl", input);
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
    const rule_children = try document.children(root_children[0]);
    const block_children = try document.children(rule_children[rule_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 3), block_children.len);
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try document.get(block_children[0])).kind,
    );
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try document.get(block_children[1])).kind,
    );
    try std.testing.expectEqual(syntax.Kind.rule, (try document.get(block_children[2])).kind);
}

test "native Stylus parser keeps the finite parse fixture structural at the root" {
    const allocator = std.testing.allocator;
    var lower_sources = source.Table.init(allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add(
        "parse-comment-lower.styl",
        parse_comment_lower_input,
    );
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 6;
    var lower_parser = try stylus.Parser.init(
        allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    const lower_root = try lower_document.children(lower_document.root);
    try std.testing.expectEqual(@as(usize, 1), lower_root.len);
    try std.testing.expectEqual(
        @as(usize, 2),
        countKind(&lower_document, .declaration),
    );

    const input = try std.fs.cwd().readFileAlloc(
        allocator,
        parse_fixture_path,
        10 * 1024 * 1024,
    );
    defer allocator.free(input);
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("parse.styl", input);
    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 52;
    var parser = try stylus.Parser.init(
        allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    for (root_children) |child_id| {
        const child = try document.get(child_id);
        std.testing.expect(child.kind != .declaration) catch |failure| {
            std.debug.print(
                "\nroot declaration in parse fixture: {s}\n",
                .{try sources.slice(child.text.?)},
            );
            return failure;
        };
    }

    var over_limit = terminal_limits;
    over_limit.max_statements = 51;
    var limited = try stylus.Parser.init(
        allocator,
        &sources,
        source_id,
        over_limit,
        .{},
    );
    defer limited.deinit();
    if (limited.parse()) |unexpected| {
        var unexpected_document = unexpected;
        unexpected_document.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.StatementLimitExceeded, err);
    }
    try std.testing.expectEqual(@as(usize, 0), limited.diagnostics().len);
}

test "native Stylus parser closes an inline explicit block before cosmetic indentation" {
    const input =
        \\body {color:#666}
        \\    a:hover {color:#333}
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("inline-explicit-close.styl", input);
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
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    for (root_children) |rule_id| {
        try std.testing.expectEqual(syntax.Kind.rule, (try document.get(rule_id)).kind);
    }
    const body_children = try document.children(root_children[0]);
    const link_children = try document.children(root_children[1]);
    try std.testing.expectEqualStrings(
        "body",
        try sources.slice((try document.get(body_children[0])).text.?),
    );
    try std.testing.expectEqualStrings(
        "a:hover",
        try sources.slice((try document.get(link_children[0])).text.?),
    );
}

test "native Stylus parser owns the finite indented function property contract" {
    const allocator = std.testing.allocator;
    var lower_sources = source.Table.init(allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add(
        "properties-function-lower.styl",
        properties_function_lower_input,
    );
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 2;
    var lower_parser = try stylus.Parser.init(
        allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    try std.testing.expectEqual(@as(usize, 1), countKind(&lower_document, .declaration));
    try std.testing.expectEqual(@as(usize, 1), countKind(&lower_document, .expression));

    const input = try std.fs.cwd().readFileAlloc(
        allocator,
        properties_fixture_path,
        10 * 1024 * 1024,
    );
    defer allocator.free(input);
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("properties.styl", input);
    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 9;
    var parser = try stylus.Parser.init(
        allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 4), root_children.len);
    try std.testing.expectEqual(@as(usize, 5), countKind(&document, .declaration));
    try std.testing.expectEqual(@as(usize, 5), countKind(&document, .expression));

    var over_limit = terminal_limits;
    over_limit.max_statements = 8;
    var limited = try stylus.Parser.init(
        allocator,
        &sources,
        source_id,
        over_limit,
        .{},
    );
    defer limited.deinit();
    if (limited.parse()) |unexpected| {
        var unexpected_document = unexpected;
        unexpected_document.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.StatementLimitExceeded, err);
    }
    try std.testing.expectEqual(@as(usize, 0), limited.diagnostics().len);
}

test "native Stylus parser owns single-line callable blocks without consuming interpolation braces" {
    const input =
        \\large(n){ n > 100 }
        \\property(name, value)
        \\  {name} value
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("single-line-callable.styl", input);
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

    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .function));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .block));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .declaration));
}

test "native Stylus parser preserves spaced keyframe name interpolation" {
    const input =
        \\@keyframes {'foo' + 1}
        \\  5%
        \\    left 5
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("keyframe-name-interpolation.styl", input);
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
    const at_rule = try document.get(root_children[0]);
    try std.testing.expectEqual(syntax.Kind.at_rule, at_rule.kind);
    try std.testing.expectEqualStrings(
        "@keyframes {'foo' + 1}",
        try sources.slice(at_rule.text.?),
    );
    const at_rule_children = try document.children(root_children[0]);
    try std.testing.expectEqual(@as(usize, 2), at_rule_children.len);
    try std.testing.expectEqual(syntax.Kind.block, (try document.get(at_rule_children[1])).kind);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .interpolation));
}

test "native Stylus parser owns multiline callable signatures at their closing parenthesis" {
    const lower_input =
        \\pad(
        \\  x
        \\)
        \\  padding x
        \\body
        \\  pad 1
    ;
    var lower_sources = source.Table.init(std.testing.allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add("multiline-function-lower.styl", lower_input);
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 4;
    var lower_parser = try stylus.Parser.init(
        std.testing.allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    const lower_root = try lower_document.children(lower_document.root);
    try std.testing.expectEqual(@as(usize, 2), lower_root.len);
    try std.testing.expectEqual(
        syntax.Kind.function,
        (try lower_document.get(lower_root[0])).kind,
    );
    try std.testing.expectEqualStrings(
        "pad(\n  x\n)",
        try lower_sources.slice((try lower_document.get(lower_root[0])).text.?),
    );

    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("multiline-functions.styl", multiline_functions_input);

    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 12;
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 5), root_children.len);
    try std.testing.expectEqual(syntax.Kind.function, (try document.get(root_children[0])).kind);
    try std.testing.expectEqual(syntax.Kind.rule, (try document.get(root_children[1])).kind);
    try std.testing.expectEqual(syntax.Kind.function, (try document.get(root_children[2])).kind);
    try std.testing.expectEqual(syntax.Kind.rule, (try document.get(root_children[3])).kind);
    try std.testing.expectEqual(syntax.Kind.rule, (try document.get(root_children[4])).kind);
    try std.testing.expectEqual(@as(usize, 3), countKind(&document, .function));
    try std.testing.expectEqualStrings(
        "pad(\n  x = 5\n, y = 10\n)",
        try sources.slice((try document.get(root_children[0])).text.?),
    );
    try std.testing.expectEqualStrings(
        "pad(\n    x = 5\n  , y = 10\n)",
        try sources.slice((try document.get(root_children[2])).text.?),
    );

    const final_rule_children = try document.children(root_children[4]);
    const final_block = final_rule_children[final_rule_children.len - 1];
    const final_statements = try document.children(final_block);
    try std.testing.expectEqual(@as(usize, 2), final_statements.len);
    try std.testing.expectEqual(syntax.Kind.function, (try document.get(final_statements[0])).kind);
    try std.testing.expectEqualStrings(
        "pad(x\n    , y\n  )",
        try sources.slice((try document.get(final_statements[0])).text.?),
    );

    var over_limit = terminal_limits;
    over_limit.max_statements = 11;
    var limited = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        over_limit,
        .{},
    );
    defer limited.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, limited.parse());
    try std.testing.expectEqual(@as(usize, 0), limited.diagnostics().len);
}

test "native Stylus parser owns the finite multiline media query list" {
    const lower_input =
        \\@media screen,
        \\  print
        \\  body
        \\    color red
    ;
    var lower_sources = source.Table.init(std.testing.allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add("multiline-media-lower.styl", lower_input);
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 3;
    var lower_parser = try stylus.Parser.init(
        std.testing.allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    const lower_root = try lower_document.children(lower_document.root);
    try std.testing.expectEqual(@as(usize, 1), lower_root.len);
    try std.testing.expectEqual(syntax.Kind.at_rule, (try lower_document.get(lower_root[0])).kind);
    try std.testing.expectEqualStrings(
        "@media screen,\n  print",
        try lower_sources.slice((try lower_document.get(lower_root[0])).text.?),
    );

    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("multiline-media.styl", multiline_media_query_input);
    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 3;
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 1), root.len);
    const at_rule = try document.get(root[0]);
    try std.testing.expectEqual(syntax.Kind.at_rule, at_rule.kind);
    try std.testing.expectEqualStrings(
        "@media /* outer */ all and (min-width: 100px),\n" ++
            "/* second */ only print and (width: 100px)\n" ++
            ", /* third */ (monochrome)",
        try sources.slice(at_rule.text.?),
    );

    var over_limit = terminal_limits;
    over_limit.max_statements = 2;
    var limited = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        over_limit,
        .{},
    );
    defer limited.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, limited.parse());
    try std.testing.expectEqual(@as(usize, 0), limited.diagnostics().len);
}

test "native Stylus parser owns the finite comma-led multiline declaration value" {
    const lower_input =
        \\.lower
        \\  shadow:
        \\    0 0 red,
        \\    0 1px blue
    ;
    var lower_sources = source.Table.init(std.testing.allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add("multiline-declaration-lower.styl", lower_input);
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 2;
    var lower_parser = try stylus.Parser.init(
        std.testing.allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    const lower_root = try lower_document.children(lower_document.root);
    const lower_rule = try lower_document.children(lower_root[0]);
    const lower_block = try lower_document.children(lower_rule[lower_rule.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), lower_block.len);
    try std.testing.expectEqual(syntax.Kind.declaration, (try lower_document.get(lower_block[0])).kind);
    try std.testing.expectEqualStrings(
        "shadow:\n    0 0 red,\n    0 1px blue",
        try lower_sources.slice((try lower_document.get(lower_block[0])).text.?),
    );

    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "multiline-declaration.styl",
        multiline_declaration_input,
    );
    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 3;
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 1), root.len);
    const rule = try document.children(root[0]);
    const block = try document.children(rule[rule.len - 1]);
    try std.testing.expectEqual(@as(usize, 2), block.len);
    const declaration = try document.get(block[0]);
    try std.testing.expectEqual(syntax.Kind.declaration, declaration.kind);
    try std.testing.expectEqualStrings(
        "box-shadow:\n" ++
            "    0 -2px 2px hsl(220, 20%, 40%),\n" ++
            "    inset 0 1px 0 hsl(\n" ++
            "      219,\n" ++
            "      20%,\n" ++
            "      0%\n" ++
            "    ),\n" ++
            "    inset 0 -1px 0 hsl(220, 20%, 20%)",
        try sources.slice(declaration.text.?),
    );
    try std.testing.expectEqual(syntax.Kind.declaration, (try document.get(block[1])).kind);

    var over_limit = terminal_limits;
    over_limit.max_statements = 2;
    var limited = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        over_limit,
        .{},
    );
    defer limited.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, limited.parse());
    try std.testing.expectEqual(@as(usize, 0), limited.diagnostics().len);
}

test "native Stylus parser owns the finite comma-led multiline assignment value" {
    const lower_input =
        \\pair = first,
        \\  second
    ;
    var lower_sources = source.Table.init(std.testing.allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add("multiline-assignment-lower.styl", lower_input);
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 1;
    var lower_parser = try stylus.Parser.init(
        std.testing.allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    const lower_root = try lower_document.children(lower_document.root);
    try std.testing.expectEqual(@as(usize, 1), lower_root.len);
    try std.testing.expectEqual(syntax.Kind.variable, (try lower_document.get(lower_root[0])).kind);
    try std.testing.expectEqualStrings(
        "pair = first,\n  second",
        try lower_sources.slice((try lower_document.get(lower_root[0])).text.?),
    );

    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("multiline-assignment.styl", multiline_assignment_input);
    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 3;
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 2), root.len);
    const assignment = try document.get(root[0]);
    try std.testing.expectEqual(syntax.Kind.variable, assignment.kind);
    try std.testing.expectEqualStrings(
        "families = Helvetica,\n  Arial,\n  sans-serif",
        try sources.slice(assignment.text.?),
    );

    var over_limit = terminal_limits;
    over_limit.max_statements = 2;
    var limited = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        over_limit,
        .{},
    );
    defer limited.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, limited.parse());
    try std.testing.expectEqual(@as(usize, 0), limited.diagnostics().len);
}

test "native Stylus parser classifies an assignment value as its owning declaration" {
    const lower_input =
        \\value = 1
        \\body
        \\  width current = value
    ;
    var lower_sources = source.Table.init(std.testing.allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add("declaration-assignment-lower.styl", lower_input);
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 3;
    var lower_parser = try stylus.Parser.init(
        std.testing.allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    const lower_root = try lower_document.children(lower_document.root);
    const lower_rule = try lower_document.children(lower_root[1]);
    const lower_block = try lower_document.children(lower_rule[lower_rule.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), lower_block.len);
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try lower_document.get(lower_block[0])).kind,
    );

    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "declaration-assignment.styl",
        declaration_assignment_input,
    );
    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 5;
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    const function_children = try document.children(root[0]);
    const function_block = try document.children(function_children[function_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 2), function_block.len);
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try document.get(function_block[0])).kind,
    );
    try std.testing.expectEqualStrings(
        "padding-top n = unit(y, 'px')",
        try sources.slice((try document.get(function_block[0])).text.?),
    );
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try document.get(function_block[1])).kind,
    );

    var over_limits = terminal_limits;
    over_limits.max_statements = 4;
    var over = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        over_limits,
        .{},
    );
    defer over.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, over.parse());
    try std.testing.expectEqual(@as(usize, 0), over.diagnostics().len);
}

test "native Stylus parser owns anonymous callback blocks without promoting calls to definitions" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("anonymous-functions.styl", anonymous_functions_input);
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
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    try std.testing.expectEqual(syntax.Kind.function, (try document.get(root_children[0])).kind);
    try std.testing.expectEqual(syntax.Kind.rule, (try document.get(root_children[1])).kind);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .function));

    const mixin_children = try document.children(root_children[0]);
    const mixin_block = mixin_children[mixin_children.len - 1];
    const mixin_statements = try document.children(mixin_block);
    try std.testing.expectEqual(@as(usize, 2), mixin_statements.len);
    try std.testing.expectEqual(syntax.Kind.variable, (try document.get(mixin_statements[0])).kind);

    const body_children = try document.children(root_children[1]);
    const body_block = body_children[body_children.len - 1];
    const body_statements = try document.children(body_block);
    try std.testing.expectEqual(@as(usize, 2), body_statements.len);
    try std.testing.expectEqual(syntax.Kind.expression, (try document.get(body_statements[0])).kind);
    try std.testing.expectEqualStrings(
        "mixin(@(a, b)",
        try sources.slice((try document.get(body_statements[0])).text.?),
    );
    try std.testing.expectEqualStrings(
        ")",
        try sources.slice((try document.get(body_statements[1])).text.?),
    );
}

test "native Stylus parser retains finite same-line assignment object literals" {
    const lower_input = "value = { foo: 'bar' }";
    var lower_sources = source.Table.init(std.testing.allocator, .{});
    defer lower_sources.deinit();
    const lower_source_id = try lower_sources.add("inline-object-lower.styl", lower_input);
    var lower_limits = stylus.Limits{};
    lower_limits.max_statements = 1;
    var lower_parser = try stylus.Parser.init(
        std.testing.allocator,
        &lower_sources,
        lower_source_id,
        lower_limits,
        .{},
    );
    defer lower_parser.deinit();
    var lower_document = try lower_parser.parse();
    defer lower_document.deinit();
    const lower_root = try lower_document.children(lower_document.root);
    try std.testing.expectEqual(@as(usize, 1), lower_root.len);
    try std.testing.expectEqual(syntax.Kind.variable, (try lower_document.get(lower_root[0])).kind);
    try std.testing.expectEqualStrings(
        lower_input,
        try lower_sources.slice((try lower_document.get(lower_root[0])).text.?),
    );

    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "inline-object-assignment.styl",
        inline_object_assignment_input,
    );
    var terminal_limits = stylus.Limits{};
    terminal_limits.max_statements = 4;
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        terminal_limits,
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 3), root.len);
    const function_children = try document.children(root[1]);
    const block = try document.children(function_children[function_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), block.len);
    const assignment = try document.get(block[0]);
    try std.testing.expectEqual(syntax.Kind.variable, assignment.kind);
    try std.testing.expectEqualStrings(
        "obj.params = { foo: 'bar' }",
        try sources.slice(assignment.text.?),
    );

    var over_limit = terminal_limits;
    over_limit.max_statements = 3;
    var limited = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        over_limit,
        .{},
    );
    defer limited.deinit();
    try std.testing.expectError(error.StatementLimitExceeded, limited.parse());
    try std.testing.expectEqual(@as(usize, 0), limited.diagnostics().len);
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

test "native Stylus parser keeps root selector scopes separate from following rules" {
    const input =
        \\@scope #sidebar
        \\h2
        \\  color red
        \\a
        \\  color pink
        \\@scope body.signup-page[attr='foo']
        \\& .container
        \\  color red
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("scope.styl", input);
    var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 5), children.len);
    try std.testing.expectEqual(syntax.Kind.at_rule, (try document.get(children[0])).kind);
    try std.testing.expectEqual(@as(usize, 1), (try document.children(children[0])).len);
}

test "native Stylus parser keeps declarations separate from a following nested selector" {
    const input =
        \\.root
        \\  color: red
        \\  &__child
        \\    width: 1px
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("declaration-before-selector.styl", input);
    var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 1), root_children.len);
    const root_rule_children = try document.children(root_children[0]);
    const root_block = root_rule_children[root_rule_children.len - 1];
    const block_children = try document.children(root_block);
    try std.testing.expectEqual(@as(usize, 2), block_children.len);
    const declaration = try document.get(block_children[0]);
    try std.testing.expectEqual(syntax.Kind.declaration, declaration.kind);
    try std.testing.expectEqualStrings("color: red", try sources.slice(declaration.text.?));
    const child_rule = try document.get(block_children[1]);
    try std.testing.expectEqual(syntax.Kind.rule, child_rule.kind);
    try std.testing.expectEqualStrings("&__child", try sources.slice(child_rule.text.?));
}

test "native Stylus parser preserves multiline ancestry selector lists" {
    const input =
        \\.root
        \\  & > .child
        \\    ^[0] ^[1..1],
        \\    ^[1..1]
        \\      value: selector('^[1..1]')
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("ancestry-list.styl", input);
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
    const root_rule_children = try document.children(root_children[0]);
    const root_block = root_rule_children[root_rule_children.len - 1];
    const root_block_children = try document.children(root_block);
    try std.testing.expectEqual(@as(usize, 1), root_block_children.len);
    const child_rule_children = try document.children(root_block_children[0]);
    const child_block = child_rule_children[child_rule_children.len - 1];
    const child_block_children = try document.children(child_block);
    try std.testing.expectEqual(@as(usize, 1), child_block_children.len);
    const ancestry_rule = try document.get(child_block_children[0]);
    try std.testing.expectEqual(syntax.Kind.rule, ancestry_rule.kind);
    try std.testing.expectEqualStrings(
        "^[0] ^[1..1],\n    ^[1..1]",
        try sources.slice(ancestry_rule.text.?),
    );
    const ancestry_children = try document.children(child_block_children[0]);
    const ancestry_block = ancestry_children[ancestry_children.len - 1];
    const declarations = try document.children(ancestry_block);
    try std.testing.expectEqual(@as(usize, 1), declarations.len);
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try document.get(declarations[0])).kind,
    );
}

test "native Stylus parser preserves comma-led multiline descendant selector groups" {
    const input =
        \\h1 a,
        \\h2 a,
        \\h3 a {
        \\  color: red;
        \\}
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("descendant-selector-group.styl", input);
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
    const rule_children = try document.children(root_children[0]);
    try std.testing.expectEqualStrings(
        "h1 a,\nh2 a,\nh3 a",
        try sources.slice((try document.get(rule_children[0])).text.?),
    );
    const declarations = try document.children(rule_children[rule_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), declarations.len);
    try std.testing.expectEqual(
        syntax.Kind.declaration,
        (try document.get(declarations[0])).kind,
    );
}

test "native Stylus parser preserves the pinned explicit CSS selector tree" {
    const input = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/stylus/corpus/files/upstream/cases/css.selectors.styl",
        1024 * 1024,
    );
    defer std.testing.allocator.free(input);
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("css.selectors.styl", input);
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

    const expected = [_][]const u8{
        "body",
        "ul",
        "foo",
        "foo bar baz",
        "foo\nbar\nbaz",
        "input[type=button]",
        "button\ninput[type=button]\ninput[type=submit]\na.button",
        ".foo",
    };
    const root_children = try document.children(document.root);
    try std.testing.expectEqual(expected.len, root_children.len);
    for (root_children, expected) |rule_id, expected_selector| {
        const rule = try document.get(rule_id);
        try std.testing.expectEqual(syntax.Kind.rule, rule.kind);
        const children = try document.children(rule_id);
        try std.testing.expectEqual(@as(usize, 2), children.len);
        const selector = try document.get(children[0]);
        try std.testing.expectEqual(syntax.Kind.selector, selector.kind);
        try std.testing.expectEqualStrings(expected_selector, try sources.slice(selector.text.?));
        try std.testing.expectEqual(syntax.Kind.block, (try document.get(children[1])).kind);
    }
}

test "native Stylus parser preserves the pinned CSS whitespace rule tree" {
    const input = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/stylus/corpus/files/upstream/cases/css.whitespace.styl",
        1024 * 1024,
    );
    defer std.testing.allocator.free(input);
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("css.whitespace.styl", input);
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

    const expected = [_][]const u8{
        "body",
        "body",
        "body",
        "body",
        "body",
        "body",
        "body",
        "ul",
        "body",
        "foo",
    };
    const expected_block_children = [_]usize{ 1, 1, 2, 2, 2, 2, 1, 1, 1, 2 };
    const root_children = try document.children(document.root);
    if (root_children.len != expected.len) {
        std.debug.print(
            "\nnative Stylus CSS whitespace root count: expected {d}, actual {d}\n",
            .{ expected.len, root_children.len },
        );
        for (root_children, 0..) |node_id, index| {
            const node = try document.get(node_id);
            const raw = if (node.text) |text| try sources.slice(text) else "<no text>";
            std.debug.print("root[{d}] {s}: {s}\n", .{ index, @tagName(node.kind), raw });
        }
    }
    try std.testing.expectEqual(expected.len, root_children.len);
    for (root_children, expected, 0..) |rule_id, expected_selector, index| {
        const rule = try document.get(rule_id);
        if (rule.kind != .rule) {
            const raw = if (rule.text) |text| try sources.slice(text) else "<no text>";
            std.debug.print(
                "\nnative Stylus CSS whitespace root[{d}] is {s}: {s}\n",
                .{ index, @tagName(rule.kind), raw },
            );
        }
        try std.testing.expectEqual(syntax.Kind.rule, rule.kind);
        const children = try document.children(rule_id);
        try std.testing.expectEqual(@as(usize, 2), children.len);
        const selector = try document.get(children[0]);
        try std.testing.expectEqual(syntax.Kind.selector, selector.kind);
        try std.testing.expectEqualStrings(expected_selector, try sources.slice(selector.text.?));
        try std.testing.expectEqual(syntax.Kind.block, (try document.get(children[1])).kind);
        const block_children = try document.children(children[1]);
        try std.testing.expectEqual(expected_block_children[index], block_children.len);
        const expected_kind: syntax.Kind = if (index == 7 or index == 9)
            .rule
        else
            .declaration;
        for (block_children) |child_id| {
            try std.testing.expectEqual(expected_kind, (try document.get(child_id)).kind);
        }
    }
}

test "native Stylus parser keeps quoted selector references inside interpolation braces" {
    const input =
        \\{selector('.a', '.b', '^[0]:hover .e, ^[1]:hover .f')}
        \\  color: green
        \\{selector('.a' '.b' '.c')}
        \\  color: blue
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("selector-interpolation.styl", input);
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
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    for (root_children) |rule_id| {
        const rule = try document.get(rule_id);
        try std.testing.expectEqual(syntax.Kind.rule, rule.kind);
        const children = try document.children(rule_id);
        try std.testing.expectEqual(@as(usize, 2), children.len);
        try std.testing.expectEqual(syntax.Kind.selector, (try document.get(children[0])).kind);
        const block_children = try document.children(children[1]);
        try std.testing.expectEqual(@as(usize, 1), block_children.len);
        try std.testing.expectEqual(
            syntax.Kind.declaration,
            (try document.get(block_children[0])).kind,
        );
    }
    const first_children = try document.children(root_children[0]);
    try std.testing.expectEqualStrings(
        "{selector('.a', '.b', '^[0]:hover .e, ^[1]:hover .f')}",
        try sources.slice((try document.get(first_children[0])).text.?),
    );
}

test "native Stylus parser keeps whitespace-separated selector interpolation" {
    const input =
        \\form {'input'}:last-child { display: none; }
        \\body {form} {
        \\  input:{last}-child { display: none; }
        \\}
        \\{foo} {bar} { foo: bar; }
        \\.plain { color red }
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("spaced-selector-interpolation.styl", input);
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

    const expected = [_][]const u8{
        "form {'input'}:last-child",
        "body {form}",
        "{foo} {bar}",
        ".plain",
    };
    const root_children = try document.children(document.root);
    try std.testing.expectEqual(expected.len, root_children.len);
    for (root_children, expected) |rule_id, expected_selector| {
        const rule = try document.get(rule_id);
        try std.testing.expectEqual(syntax.Kind.rule, rule.kind);
        const children = try document.children(rule_id);
        try std.testing.expectEqual(@as(usize, 2), children.len);
        const selector = try document.get(children[0]);
        try std.testing.expectEqual(syntax.Kind.selector, selector.kind);
        try std.testing.expectEqualStrings(
            expected_selector,
            try sources.slice(selector.text.?),
        );
        try std.testing.expectEqual(syntax.Kind.block, (try document.get(children[1])).kind);
    }
}

test "native Stylus parser keeps property assignment expressions as declarations" {
    const input =
        \\values = 1
        \\.root
        \\  foo: ret = push(values, 2)
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("property-assignment.styl", input);
    var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    try std.testing.expectEqual(syntax.Kind.variable, (try document.get(root_children[0])).kind);
    const rule_children = try document.children(root_children[1]);
    const block = rule_children[rule_children.len - 1];
    const block_children = try document.children(block);
    try std.testing.expectEqual(@as(usize, 1), block_children.len);
    const declaration = try document.get(block_children[0]);
    try std.testing.expectEqual(syntax.Kind.declaration, declaration.kind);
    try std.testing.expectEqualStrings(
        "foo: ret = push(values, 2)",
        try sources.slice(declaration.text.?),
    );
}

test "native Stylus parser keeps multiline block comments opaque" {
    const input =
        \\/*
        \\body
        \\  color blue
        \\*/
        \\.actual
        \\  color red
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("multiline-comment.styl", input);
    var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    const comment = try document.get(root_children[0]);
    try std.testing.expectEqual(syntax.Kind.comment, comment.kind);
    try std.testing.expectEqual(@as(usize, 0), (try document.children(root_children[0])).len);
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .rule));
    try std.testing.expectEqual(
        syntax.Kind.rule,
        (try document.get(root_children[1])).kind,
    );
}

test "native Stylus parser owns comment-led declaration continuations" {
    const input =
        \\.root
        \\  background: // ignored,
        \\    url("img.png") 8px 8px no-repeat,
        \\    rgba(0, 0, 0, .41)
    ;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("comment-continuation.styl", input);
    var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    const rule_children = try document.children(root_children[0]);
    const block_children = try document.children(rule_children[rule_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), block_children.len);
    const declaration = try document.get(block_children[0]);
    try std.testing.expectEqual(syntax.Kind.declaration, declaration.kind);
    try std.testing.expectEqualStrings(
        "background: // ignored,\n    url(\"img.png\") 8px 8px no-repeat,\n    rgba(0, 0, 0, .41)",
        try sources.slice(declaration.text.?),
    );
    try std.testing.expectEqual(@as(usize, 1), (try document.children(block_children[0])).len);
    try std.testing.expectEqual(
        syntax.Kind.expression,
        (try document.get((try document.children(block_children[0]))[0])).kind,
    );
}

test "native Stylus parser owns explicit end-of-line escapes" {
    const input =
        "list = foo \\\n" ++
        "       bar \\\n" ++
        "       baz\n" ++
        "foo( \\\n" ++
        "  a, \\\n" ++
        "  b)\n" ++
        "  padding: unit(a, px) \\\n" ++
        "           unit(b, px)\n" ++
        "button\n" ++
        "  foo: 1 2\n" ++
        "  box-shadow: \\\n" ++
        "    0 0 2px red, \\  \n" ++
        "    0 0 5px blue\n";
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("eol-escape.styl", input);
    var parser = try stylus.Parser.init(std.testing.allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();

    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 3), root_children.len);
    const variable = try document.get(root_children[0]);
    try std.testing.expectEqual(syntax.Kind.variable, variable.kind);
    try std.testing.expectEqualStrings(
        "list = foo \\\n       bar \\\n       baz",
        try sources.slice(variable.text.?),
    );

    const function = try document.get(root_children[1]);
    try std.testing.expectEqual(syntax.Kind.function, function.kind);
    try std.testing.expectEqualStrings(
        "foo( \\\n  a, \\\n  b)",
        try sources.slice(function.text.?),
    );
    const function_children = try document.children(root_children[1]);
    const function_block = function_children[function_children.len - 1];
    const function_statements = try document.children(function_block);
    try std.testing.expectEqual(@as(usize, 1), function_statements.len);
    try std.testing.expectEqualStrings(
        "padding: unit(a, px) \\\n           unit(b, px)",
        try sources.slice((try document.get(function_statements[0])).text.?),
    );

    const rule_children = try document.children(root_children[2]);
    const rule_block = rule_children[rule_children.len - 1];
    const rule_statements = try document.children(rule_block);
    try std.testing.expectEqual(@as(usize, 2), rule_statements.len);
    try std.testing.expectEqualStrings(
        "box-shadow: \\\n    0 0 2px red, \\  \n    0 0 5px blue",
        try sources.slice((try document.get(rule_statements[1])).text.?),
    );
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

fn exerciseSelectorGroupAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "selector-group.styl",
        "h1 a,\nh2 a,\nh3 a {\n  color: red;\n}\n",
    );
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try document.children(document.root)).len);
}

fn exerciseCompactNestedRuleAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "compact-nested-rule.styl",
        ".root { color: red; background: black;\n  em {\n    color: gray;\n  }\n}\n",
    );
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root_children = try document.children(document.root);
    const rule_children = try document.children(root_children[0]);
    const block_children = try document.children(rule_children[rule_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 3), block_children.len);
}

fn exerciseParseFixtureAllocationFailures(allocator: std.mem.Allocator) !void {
    const input = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        parse_fixture_path,
        10 * 1024 * 1024,
    );
    defer std.testing.allocator.free(input);
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("parse.styl", input);
    var limits = stylus.Limits{};
    limits.max_statements = 52;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 17), root_children.len);
    for (root_children) |child_id| {
        try std.testing.expect((try document.get(child_id)).kind != .declaration);
    }
}

fn exercisePropertiesFunctionAllocationFailures(allocator: std.mem.Allocator) !void {
    const input = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        properties_fixture_path,
        10 * 1024 * 1024,
    );
    defer std.testing.allocator.free(input);
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("properties.styl", input);
    var limits = stylus.Limits{};
    limits.max_statements = 9;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 4), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 5), countKind(&document, .declaration));
}

fn exerciseSpacedSelectorInterpolationAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "spaced-selector-interpolation.styl",
        "form {'input'}:last-child { display: none; }\n" ++
            "body {form} { input:{last}-child { display: none; } }\n" ++
            ".plain { color red }\n",
    );
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 3), (try document.children(document.root)).len);
}

fn exerciseExplicitCssSelectorTreeAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "explicit-css-selectors.styl",
        "body { margin: 0; ul {\n/* test */\nmargin: 0; li { color: red; } } }\n" ++
            "ul { li { &:first-child, &:last-child { display: none; } } }\n",
    );
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try document.children(document.root)).len);
}

fn exerciseExplicitWhitespaceAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "explicit-whitespace.styl",
        "body {\n     padding: 5px;\n  margin: 0;\n  article\n    color: red;\n}\n",
    );
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 1), root_children.len);
    const rule_children = try document.children(root_children[0]);
    const block_children = try document.children(rule_children[rule_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 3), block_children.len);
    try std.testing.expectEqual(syntax.Kind.declaration, (try document.get(block_children[0])).kind);
    try std.testing.expectEqual(syntax.Kind.declaration, (try document.get(block_children[1])).kind);
    try std.testing.expectEqual(syntax.Kind.rule, (try document.get(block_children[2])).kind);
}

fn exerciseEolEscapeAllocationFailures(allocator: std.mem.Allocator) !void {
    const input = "list = foo \\\n  bar \\\n  baz\n" ++
        "foo( \\\n  a, \\\n  b)\n  padding: unit(a, px) \\\n           unit(b, px)\n";
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("eol-escape.styl", input);
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root_children = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    try std.testing.expectEqual(syntax.Kind.variable, (try document.get(root_children[0])).kind);
    try std.testing.expectEqual(syntax.Kind.function, (try document.get(root_children[1])).kind);
}

fn exerciseAnonymousFunctionAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("anonymous-functions.styl", anonymous_functions_input);
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .function));
}

fn exerciseMultilineFunctionAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("multiline-functions.styl", multiline_functions_input);
    var limits = stylus.Limits{};
    limits.max_statements = 12;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 5), (try document.children(document.root)).len);
    try std.testing.expectEqual(@as(usize, 3), countKind(&document, .function));
}

fn exerciseDeclarationAssignmentAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "declaration-assignment.styl",
        declaration_assignment_input,
    );
    var limits = stylus.Limits{};
    limits.max_statements = 5;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), countKind(&document, .function));
    try std.testing.expectEqual(@as(usize, 2), countKind(&document, .declaration));
}

fn exerciseMultilineMediaQueryAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("multiline-media.styl", multiline_media_query_input);
    var limits = stylus.Limits{};
    limits.max_statements = 3;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 1), root.len);
    try std.testing.expectEqual(syntax.Kind.at_rule, (try document.get(root[0])).kind);
}

fn exerciseMultilineDeclarationAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "multiline-declaration.styl",
        multiline_declaration_input,
    );
    var limits = stylus.Limits{};
    limits.max_statements = 3;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    const rule = try document.children(root[0]);
    const block = try document.children(rule[rule.len - 1]);
    try std.testing.expectEqual(@as(usize, 2), block.len);
    try std.testing.expectEqual(syntax.Kind.declaration, (try document.get(block[0])).kind);
    try std.testing.expectEqual(syntax.Kind.declaration, (try document.get(block[1])).kind);
}

fn exerciseInlineObjectAssignmentAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(
        "inline-object-assignment.styl",
        inline_object_assignment_input,
    );
    var limits = stylus.Limits{};
    limits.max_statements = 4;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    const function_children = try document.children(root[1]);
    const block = try document.children(function_children[function_children.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), block.len);
    try std.testing.expectEqual(syntax.Kind.variable, (try document.get(block[0])).kind);
}

fn exerciseMultilineAssignmentAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("multiline-assignment.styl", multiline_assignment_input);
    var limits = stylus.Limits{};
    limits.max_statements = 3;
    var parser = try stylus.Parser.init(allocator, &sources, source_id, limits, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    const root = try document.children(document.root);
    try std.testing.expectEqual(@as(usize, 2), root.len);
    try std.testing.expectEqual(syntax.Kind.variable, (try document.get(root[0])).kind);
    try std.testing.expectEqual(syntax.Kind.rule, (try document.get(root[1])).kind);
}

test "native Stylus parser handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "native Stylus comma-led selector group handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSelectorGroupAllocationFailures,
        .{},
    );
}

test "native Stylus compact nested rule handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompactNestedRuleAllocationFailures,
        .{},
    );
}

test "native Stylus parse fixture handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseParseFixtureAllocationFailures,
        .{},
    );
}

test "native Stylus indented function property handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePropertiesFunctionAllocationFailures,
        .{},
    );
}

test "native Stylus whitespace-separated selector interpolation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSpacedSelectorInterpolationAllocationFailures,
        .{},
    );
}

test "native Stylus explicit CSS selector tree handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExplicitCssSelectorTreeAllocationFailures,
        .{},
    );
}

test "native Stylus explicit brace whitespace handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExplicitWhitespaceAllocationFailures,
        .{},
    );
}

test "native Stylus end-of-line escapes handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEolEscapeAllocationFailures,
        .{},
    );
}

test "native Stylus anonymous function blocks handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAnonymousFunctionAllocationFailures,
        .{},
    );
}

test "native Stylus multiline callable signatures handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMultilineFunctionAllocationFailures,
        .{},
    );
}

test "native Stylus declaration assignments handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeclarationAssignmentAllocationFailures,
        .{},
    );
}

test "native Stylus multiline media query lists handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMultilineMediaQueryAllocationFailures,
        .{},
    );
}

test "native Stylus multiline declaration values handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMultilineDeclarationAllocationFailures,
        .{},
    );
}

test "native Stylus inline object assignments handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseInlineObjectAssignmentAllocationFailures,
        .{},
    );
}

test "native Stylus multiline assignment values handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMultilineAssignmentAllocationFailures,
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
