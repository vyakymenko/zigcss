const std = @import("std");
const preprocessor = @import("native_preprocessor");
const selector = preprocessor.sass_selector;

fn expectItems(expected: []const []const u8, actual: selector.SelectorList) !void {
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |expected_item, actual_item| {
        try std.testing.expectEqualStrings(expected_item, actual_item);
    }
}

test "native Sass selector parser canonicalizes bounded selector lists" {
    var parsed = try selector.parse(
        std.testing.allocator,
        "  .foo   >   .bar , #id:hover  ",
        .{},
    );
    defer parsed.deinit();
    try expectItems(&.{ ".foo > .bar", "#id:hover" }, parsed);

    var functional = try selector.parse(
        std.testing.allocator,
        "[data-x=\"a,b\"]:not(.x, .y)",
        .{},
    );
    defer functional.deinit();
    try expectItems(&.{"[data-x=\"a,b\"]:not(.x, .y)"}, functional);
}

test "native Sass selector parser normalizes escapes and forgiving empty segments" {
    var parsed = try selector.parse(std.testing.allocator, "a,,b,", .{});
    defer parsed.deinit();
    try expectItems(&.{ "a", "b" }, parsed);

    var escaped = try selector.parse(std.testing.allocator, ".\\31 23#\\66 oo", .{});
    defer escaped.deinit();
    try expectItems(&.{".\\31 23#foo"}, escaped);

    var trailing = try selector.parse(std.testing.allocator, "a >", .{});
    defer trailing.deinit();
    try expectItems(&.{"a >"}, trailing);

    var leading = try selector.parse(
        std.testing.allocator,
        "> .foo, + .bar, ~ .baz",
        .{},
    );
    defer leading.deinit();
    try expectItems(&.{ "> .foo", "+ .bar", "~ .baz" }, leading);

    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ",a", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, "a || b", .{}),
    );
}

test "native Sass selector parser decomposes one compound structurally" {
    var parsed = try selector.simpleSelectors(
        std.testing.allocator,
        "a.foo#id:hover::before[title=\"x\"]",
        .{},
    );
    defer parsed.deinit();
    try expectItems(&.{ "a", ".foo", "#id", ":hover", "::before", "[title=x]" }, parsed);

    var functional = try selector.simpleSelectors(
        std.testing.allocator,
        ":not(.a, .b).x",
        .{},
    );
    defer functional.deinit();
    try expectItems(&.{ ":not(.a, .b)", ".x" }, functional);

    var namespaced = try selector.simpleSelectors(std.testing.allocator, "svg|a.foo", .{});
    defer namespaced.deinit();
    try expectItems(&.{ "svg|a", ".foo" }, namespaced);
}

test "native Sass selector parser normalizes bounded attribute selectors" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "[ x ]", .expected = "[x]" },
        .{ .input = "[ x = \"y\" ]", .expected = "[x=y]" },
        .{ .input = "[x='a b']", .expected = "[x=\"a b\"]" },
        .{ .input = "[x='a\"b']", .expected = "[x='a\"b']" },
        .{ .input = "[x=--custom]", .expected = "[x=\"--custom\"]" },
        .{ .input = "[x=\"-item\" i]", .expected = "[x=-item i]" },
        .{ .input = "[svg|data ^= 'wide value' S]", .expected = "[svg|data^=\"wide value\" S]" },
        .{ .input = "[*|data~=token]", .expected = "[*|data~=token]" },
        .{ .input = "[|data$=end]", .expected = "[|data$=end]" },
        .{ .input = "[data|=prefix]", .expected = "[data|=prefix]" },
        .{ .input = "[data*=middle z]", .expected = "[data*=middle z]" },
        .{ .input = "[-data=_item]", .expected = "[-data=_item]" },
        .{ .input = "[/*a*/data/*b*/=/*c*/token/*d*/ i]", .expected = "[data=token i]" },
        .{ .input = "[data=/* ] , */token]", .expected = "[data=token]" },
        .{ .input = "[data/**/]", .expected = "[data]" },
        .{ .input = ":not([ x = \"y\" ])", .expected = ":not([x=y])" },
        .{ .input = ":has(> [data='wide value'])", .expected = ":has(> [data=\"wide value\"])" },
    };
    for (cases) |case| {
        var parsed = try selector.parse(std.testing.allocator, case.input, .{});
        defer parsed.deinit();
        try expectItems(&.{case.expected}, parsed);
    }

    var exactly_bounded = try selector.parse(
        std.testing.allocator,
        "[ x = \"y\" ]",
        .{ .max_bytes = 5 },
    );
    defer exactly_bounded.deinit();
    try expectItems(&.{"[x=y]"}, exactly_bounded);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(
            std.testing.allocator,
            "[ x = \"y\" ]",
            .{ .max_bytes = 4 },
        ),
    );

    const truncated = "[svg|data^=\"wide value\" S]";
    for (0..truncated.len) |end| {
        try std.testing.expectError(
            error.InvalidSelector,
            selector.parse(std.testing.allocator, truncated[0..end], .{}),
        );
    }
}

test "native Sass selector parser and relations normalize bounded escapes" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = ".\\66 oo", .expected = ".foo" },
        .{ .input = ".\\00003123", .expected = ".\\31 23" },
        .{ .input = ".caf\\e9 ", .expected = ".café" },
        .{ .input = ".\\1f49a ", .expected = ".💚" },
        .{ .input = ".foo\\2b bar", .expected = ".foo\\+bar" },
        .{ .input = ".\\2d foo", .expected = ".\\-foo" },
        .{ .input = ".\\0 ", .expected = ".\\0 " },
        .{ .input = "#\\66 oo", .expected = "#foo" },
        .{ .input = "%\\31 23", .expected = "%\\31 23" },
        .{ .input = "\\62 utton", .expected = "button" },
        .{ .input = "\\73 vg|\\61 ", .expected = "svg|a" },
        .{ .input = "\\2a ", .expected = "\\*" },
        .{ .input = "[\\78 =y]", .expected = "[x=y]" },
        .{ .input = "[\\6e s|\\78 =y]", .expected = "[ns|x=y]" },
        .{ .input = "[x=\\79 es]", .expected = "[x=yes]" },
        .{ .input = "[x=\\31 23]", .expected = "[x=\\31 23]" },
        .{ .input = "[x=foo\\2b bar]", .expected = "[x=foo\\+bar]" },
        .{ .input = "[x=\\0 ]", .expected = "[x=\\0 ]" },
        .{ .input = "[x=\"\\79 \"]", .expected = "[x=y]" },
        .{ .input = "[x=\"a\\20 b\"]", .expected = "[x=\"a b\"]" },
        .{ .input = "[x=\"\\110000 \"]", .expected = "[x=�]" },
        .{ .input = "[x=\"\\d800 \"]", .expected = "[x=�]" },
        .{ .input = "[x=\"\\0 \"]", .expected = "[x=�]" },
        .{ .input = "[x=\"a\\\"b\"]", .expected = "[x='a\"b']" },
        .{ .input = "[x=\"a'b\"]", .expected = "[x=\"a'b\"]" },
        .{ .input = "[x=\"a'\\\"b\"]", .expected = "[x=\"a'\\\"b\"]" },
    };
    for (cases) |case| {
        var parsed = try selector.parse(std.testing.allocator, case.input, .{});
        defer parsed.deinit();
        try expectItems(&.{case.expected}, parsed);
    }

    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        ".foo",
        ".\\66 oo",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        "[x=y]",
        "[\\78 =\\79 ]",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ".-foo",
        ".\\2d foo",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        ".\\2d foo",
        ".\\-foo",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ".\\0 ",
        ".�",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        "[x=\\0 ]",
        "[x=�]",
        .{},
    ));

    var unified = (try selector.unify(
        std.testing.allocator,
        ".foo",
        ".\\66 oo",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer unified.deinit();
    try expectItems(&.{".foo"}, unified);

    var extended = try selector.extend(
        std.testing.allocator,
        ".\\66 oo.c",
        ".foo",
        ".bar",
        .{},
    );
    defer extended.deinit();
    try expectItems(&.{ ".foo.c", ".c.bar" }, extended);

    var replaced = try selector.replace(
        std.testing.allocator,
        "[\\78 =\\79 ].c",
        "[x=y]",
        ".bar",
        .{},
    );
    defer replaced.deinit();
    try expectItems(&.{".c.bar"}, replaced);

    var expanded = try selector.parse(
        std.testing.allocator,
        ".\\31z",
        .{ .max_bytes = 6 },
    );
    defer expanded.deinit();
    try expectItems(&.{".\\31 z"}, expanded);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(
            std.testing.allocator,
            ".\\31z",
            .{ .max_bytes = 5 },
        ),
    );

    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ".\\d800 ", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ".\\110000 ", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, "[x=y \\69]", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ".\\\nfoo", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ".\\\x00foo", .{}),
    );
}

test "native Sass selector parser and relations normalize bounded simple pseudos" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = ":\\68 over", .expected = ":hover" },
        .{ .input = ":\\00003123", .expected = ":\\31 23" },
        .{ .input = ":caf\\e9 ", .expected = ":café" },
        .{ .input = ":\\1f49a ", .expected = ":💚" },
        .{ .input = ":foo\\2b bar", .expected = ":foo\\+bar" },
        .{ .input = ":\\2d foo", .expected = ":\\-foo" },
        .{ .input = ":\\0 ", .expected = ":\\0 " },
        .{ .input = "::\\62 efore", .expected = "::before" },
        .{ .input = "::\\1f49a ", .expected = "::💚" },
    };
    for (cases) |case| {
        var parsed = try selector.parse(std.testing.allocator, case.input, .{});
        defer parsed.deinit();
        try expectItems(&.{case.expected}, parsed);
    }

    var simple = try selector.simpleSelectors(
        std.testing.allocator,
        "button:\\68 over::\\62 efore",
        .{},
    );
    defer simple.deinit();
    try expectItems(&.{ "button", ":hover", "::before" }, simple);

    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        ":hover",
        ":\\68 over.foo",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        ":before",
        "::\\62 efore.foo",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        ":foo\\+bar",
        ":foo\\2b bar.x",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ":HOVER",
        ":hover",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ":\\0 ",
        ":�",
        .{},
    ));

    var unified = (try selector.unify(
        std.testing.allocator,
        ":hover",
        ":\\68 over",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer unified.deinit();
    try expectItems(&.{":hover"}, unified);

    var unified_element = (try selector.unify(
        std.testing.allocator,
        ":before",
        "::\\62 efore",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer unified_element.deinit();
    try expectItems(&.{":before"}, unified_element);

    var unified_punctuation = (try selector.unify(
        std.testing.allocator,
        ":foo\\+bar",
        ":foo\\2b bar",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer unified_punctuation.deinit();
    try expectItems(&.{":foo\\+bar"}, unified_punctuation);

    var extended = try selector.extend(
        std.testing.allocator,
        ".x:\\68 over",
        ":hover",
        ".y",
        .{},
    );
    defer extended.deinit();
    try expectItems(&.{ ".x:hover", ".x.y" }, extended);

    var replaced = try selector.replace(
        std.testing.allocator,
        ".x:hover",
        ":\\68 over",
        ".y",
        .{},
    );
    defer replaced.deinit();
    try expectItems(&.{".x.y"}, replaced);

    var context_extended = try selector.extend(
        std.testing.allocator,
        ".x:hover",
        ".x",
        ":focus",
        .{},
    );
    defer context_extended.deinit();
    try expectItems(&.{ ".x:hover", ":hover:focus" }, context_extended);

    var context_replaced = try selector.replace(
        std.testing.allocator,
        ".x:hover",
        ".x",
        ":focus",
        .{},
    );
    defer context_replaced.deinit();
    try expectItems(&.{":hover:focus"}, context_replaced);

    var exactly_bounded = try selector.parse(
        std.testing.allocator,
        ":\\31z",
        .{ .max_bytes = 6 },
    );
    defer exactly_bounded.deinit();
    try expectItems(&.{":\\31 z"}, exactly_bounded);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(
            std.testing.allocator,
            ":\\31z",
            .{ .max_bytes = 5 },
        ),
    );

    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ":\\d800 ", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ":\\110000 ", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ":\\\nfoo", .{}),
    );
    try std.testing.expectError(
        error.InvalidSelector,
        selector.parse(std.testing.allocator, ":\\\x00foo", .{}),
    );
}

test "native Sass selector parser normalizes bounded selector-list functional pseudos" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = ":not( .\\61 , #\\62 )", .expected = ":not(.a, #b)" },
        .{ .input = ":\\69 s(.\\61 ,, .b)", .expected = ":is(.a, .b)" },
        .{
            .input = ":where(.a, :\\6e ot( .b , .c ))",
            .expected = ":where(.a, :not(.b, .c))",
        },
        .{
            .input = ":has(> .\\61 , + #\\62 )",
            .expected = ":has(> .a, + #b)",
        },
        .{
            .input = ":\\6d atches(.\\61 , .b)",
            .expected = ":matches(.a, .b)",
        },
        .{ .input = ":\\61 ny(.\\61 , .b)", .expected = ":any(.a, .b)" },
        .{
            .input = ":-webkit-any(.\\61 , .b)",
            .expected = ":-webkit-any(.a, .b)",
        },
        .{
            .input = ":-moz-any(.\\61 , .b)",
            .expected = ":-moz-any(.a, .b)",
        },
        .{
            .input = ":not(:\\69 s(.\\61 , :where(.b, .c)))",
            .expected = ":not(:is(.a, :where(.b, .c)))",
        },
        .{
            .input = ":is([ \\78 = \\79 ], .a)",
            .expected = ":is([x=y], .a)",
        },
    };
    for (cases) |case| {
        var parsed = try selector.parse(std.testing.allocator, case.input, .{});
        defer parsed.deinit();
        try expectItems(&.{case.expected}, parsed);
    }

    var non_selector_function = try selector.parse(
        std.testing.allocator,
        ":nth-child(2n of [ x = \"y\" ])",
        .{},
    );
    defer non_selector_function.deinit();
    try expectItems(&.{":nth-child(2n of [x=y])"}, non_selector_function);

    var simple = try selector.simpleSelectors(
        std.testing.allocator,
        "button:\\69 s(.\\61 , .b):hover",
        .{},
    );
    defer simple.deinit();
    try expectItems(&.{ "button", ":is(.a, .b)", ":hover" }, simple);

    const relation_cases = [_]struct {
        super_selector: []const u8,
        sub_selector: []const u8,
    }{
        .{
            .super_selector = ":not(.a, .b)",
            .sub_selector = ":\\6e ot(.\\61 , .b).x",
        },
        .{
            .super_selector = ":is(.a, .b)",
            .sub_selector = ":\\69 s(.\\61 , .b).x",
        },
        .{
            .super_selector = ":where(.a, .b)",
            .sub_selector = ":\\77 here(.\\61 , .b).x",
        },
        .{
            .super_selector = ":has(.a, .b)",
            .sub_selector = ":\\68 as(.\\61 , .b).x",
        },
        .{
            .super_selector = ":not(:is(.a, .b))",
            .sub_selector = ":not(:\\69 s(.\\61 , .b)).x",
        },
    };
    for (relation_cases) |case| {
        try std.testing.expect(try selector.isSuperselector(
            std.testing.allocator,
            case.super_selector,
            case.sub_selector,
            .{},
        ));
    }
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ":has(> .a)",
        ":has(> .a)",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ":has(.a, > .b)",
        ":has(.a, > .b)",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ":not(:has(> .a))",
        ":not(:has(> .a))",
        .{},
    ));
    try std.testing.expect(!try selector.isSuperselector(
        std.testing.allocator,
        ":is(:has(.a, + .b))",
        ":is(:has(.a, + .b))",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        "*, :has(> .a)",
        "*, :has(> .a)",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        ".a, .a:has(> .b)",
        ".a, .a:has(> .b)",
        .{},
    ));

    const unify_cases = [_]struct {
        left: []const u8,
        right: []const u8,
        expected: []const u8,
    }{
        .{
            .left = ":not(.a, .b)",
            .right = ":\\6e ot(.\\61 , .b)",
            .expected = ":not(.a, .b)",
        },
        .{
            .left = ":is(.a, .b)",
            .right = ":\\69 s(.\\61 , .b)",
            .expected = ":is(.a, .b)",
        },
        .{
            .left = ":where(.a, .b)",
            .right = ":\\77 here(.\\61 , .b)",
            .expected = ":where(.a, .b)",
        },
        .{
            .left = ":has(> .a, + .b)",
            .right = ":\\68 as(> .\\61 , + .b)",
            .expected = ":has(> .a, + .b)",
        },
        .{
            .left = ":not(:is(.a, .b))",
            .right = ":not(:\\69 s(.\\61 , .b))",
            .expected = ":not(:is(.a, .b))",
        },
    };
    for (unify_cases) |case| {
        var unified = (try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) orelse return error.TestUnexpectedResult;
        defer unified.deinit();
        try expectItems(&.{case.expected}, unified);
    }

    var exactly_bounded = try selector.parse(
        std.testing.allocator,
        ":\\69 s(.\\61 , .b)",
        .{ .max_bytes = 11, .max_selectors = 3 },
    );
    defer exactly_bounded.deinit();
    try expectItems(&.{":is(.a, .b)"}, exactly_bounded);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(
            std.testing.allocator,
            ":\\69 s(.\\61 , .b)",
            .{ .max_bytes = 10, .max_selectors = 3 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(
            std.testing.allocator,
            ":\\69 s(.\\61 , .b)",
            .{ .max_selectors = 2 },
        ),
    );

    const functional_arguments = ".\\61 , .b";
    var exactly_temporary_bounded = try selector.parse(
        std.testing.allocator,
        ":\\69 s(.\\61 , .b)",
        .{
            .max_selectors = 3,
            .max_temporary_bytes = functional_arguments.len,
        },
    );
    defer exactly_temporary_bounded.deinit();
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(
            std.testing.allocator,
            ":\\69 s(.\\61 , .b)",
            .{
                .max_selectors = 3,
                .max_temporary_bytes = functional_arguments.len - 1,
            },
        ),
    );

    var exact_operation_limit: u64 = 1;
    while (exact_operation_limit < 1_000) : (exact_operation_limit += 1) {
        var operation_bounded = selector.parse(
            std.testing.allocator,
            ":\\69 s(.\\61 , .b)",
            .{
                .max_selectors = 3,
                .max_normalization_operations = exact_operation_limit,
            },
        ) catch |err| switch (err) {
            error.SelectorLimitExceeded => continue,
            else => return err,
        };
        operation_bounded.deinit();
        break;
    }
    try std.testing.expect(exact_operation_limit < 1_000);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(
            std.testing.allocator,
            ":\\69 s(.\\61 , .b)",
            .{
                .max_selectors = 3,
                .max_normalization_operations = exact_operation_limit - 1,
            },
        ),
    );

    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(std.testing.allocator);
    var nested_expected: std.ArrayList(u8) = .empty;
    defer nested_expected.deinit(std.testing.allocator);
    for (0..64) |_| {
        try nested.appendSlice(std.testing.allocator, ":not(");
        try nested_expected.appendSlice(std.testing.allocator, ":not(");
    }
    try nested.appendSlice(std.testing.allocator, ".\\61 ");
    try nested_expected.appendSlice(std.testing.allocator, ".a");
    for (0..64) |_| {
        try nested.append(std.testing.allocator, ')');
        try nested_expected.append(std.testing.allocator, ')');
    }
    var bounded_depth = try selector.parse(std.testing.allocator, nested.items, .{});
    defer bounded_depth.deinit();
    try expectItems(&.{nested_expected.items}, bounded_depth);

    try nested.insertSlice(std.testing.allocator, 0, ":not(");
    try nested.append(std.testing.allocator, ')');
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(std.testing.allocator, nested.items, .{}),
    );

    const invalid = [_][]const u8{
        ":not()",
        ":is(.a,)",
        ":has(> .a,)",
        ":\\69 s(&)",
        ":\\d800 (.a)",
        ":is(.\\d800 )",
    };
    for (invalid) |input| {
        try std.testing.expectError(
            error.InvalidSelector,
            selector.parse(std.testing.allocator, input, .{}),
        );
    }
}

test "native Sass selector relations compare bounded selector-list functional pseudos" {
    const cases = [_]struct {
        super_selector: []const u8,
        sub_selector: []const u8,
        expected: bool,
    }{
        .{ .super_selector = ":is(.a, .b)", .sub_selector = ":where(.a)", .expected = true },
        .{ .super_selector = ":is(.a)", .sub_selector = ":where(.a, .b)", .expected = false },
        .{ .super_selector = ":matches(.a, .b)", .sub_selector = ":any(.b.x)", .expected = true },
        .{ .super_selector = ":-webkit-any(.a, .b)", .sub_selector = ":-moz-any(.a)", .expected = true },
        .{ .super_selector = ":is(.a, .b)", .sub_selector = ":is(.b, .a)", .expected = true },
        .{ .super_selector = ":is(.a, .b)", .sub_selector = ".a.x", .expected = true },
        .{ .super_selector = ".a", .sub_selector = ":where(.a)", .expected = true },
        .{ .super_selector = ".a", .sub_selector = ":where(.a, .b)", .expected = false },
        .{ .super_selector = ":where(.a)", .sub_selector = ".a", .expected = true },
        .{ .super_selector = ":is(*)", .sub_selector = ".a", .expected = true },
        .{ .super_selector = ".a.x", .sub_selector = ":is(.a.x)", .expected = true },
        .{ .super_selector = "[x][y]", .sub_selector = ":is([x][y])", .expected = true },
        .{ .super_selector = ":hover.x", .sub_selector = ":is(:hover.x)", .expected = true },
        .{ .super_selector = ":is(.a, .b).x", .sub_selector = ":where(.a).x.y", .expected = true },
        .{ .super_selector = ":is(.a).x", .sub_selector = ":where(.a, .b).x", .expected = false },
        .{ .super_selector = ":is(.a .b, .c)", .sub_selector = ":where(.x .a > .b)", .expected = true },
        .{ .super_selector = ":is(.a > .b)", .sub_selector = ":where(.a .b)", .expected = false },
        .{ .super_selector = ":is(:where(.a, .b), .c)", .sub_selector = ".a", .expected = true },
        .{ .super_selector = ":not(.a)", .sub_selector = ":not(.a, .b)", .expected = true },
        .{ .super_selector = ":not(.a, .b)", .sub_selector = ":not(.a)", .expected = false },
        .{ .super_selector = ":not(.a.b)", .sub_selector = ":not(.a)", .expected = true },
        .{ .super_selector = ":not(.a .b)", .sub_selector = ":not(.a > .b)", .expected = false },
        .{ .super_selector = ":not(.a > .b)", .sub_selector = ":not(.a .b)", .expected = true },
        .{ .super_selector = ":not(.a)", .sub_selector = ":not(:where(.a))", .expected = true },
        .{ .super_selector = ":not(:where(.a))", .sub_selector = ":not(.a)", .expected = true },
        .{ .super_selector = ":not(:is(.a, .b))", .sub_selector = ":not(.a, .b)", .expected = false },
        .{ .super_selector = ":not(.a, .b)", .sub_selector = ":not(:is(.a, .b))", .expected = true },
        .{ .super_selector = ":has(.a, .b)", .sub_selector = ":has(.a.x)", .expected = true },
        .{ .super_selector = ":has(.a.x)", .sub_selector = ":has(.a)", .expected = false },
        .{ .super_selector = ":has(.a .b)", .sub_selector = ":has(.x .a > .b)", .expected = true },
        .{ .super_selector = ":has(.a > .b)", .sub_selector = ":has(.a .b)", .expected = false },
        .{ .super_selector = ":has(:is(.a, .b))", .sub_selector = ":has(.a, .b)", .expected = true },
        .{ .super_selector = ":has(.a, .b)", .sub_selector = ":has(:is(.a, .b))", .expected = false },
        .{ .super_selector = ":is(:has(.a), .b)", .sub_selector = ":has(.a)", .expected = true },
        .{ .super_selector = ":has(.a)", .sub_selector = ":is(:has(.a))", .expected = false },
        .{ .super_selector = ":has(> .a)", .sub_selector = ":has(> .a)", .expected = false },
        .{ .super_selector = ":is(> .a)", .sub_selector = ":is(> .a)", .expected = false },
        .{ .super_selector = ":is(*)", .sub_selector = ":is(> .a)", .expected = true },
        .{ .super_selector = ":is(.a)", .sub_selector = ":where(> .a)", .expected = true },
        .{ .super_selector = ":where(*)", .sub_selector = ":matches(+ .a)", .expected = true },
        .{ .super_selector = ":is(.b.x)", .sub_selector = ":where(+ .a .b.x)", .expected = true },
        .{ .super_selector = ":is(.a .b)", .sub_selector = ":where(> .a .b)", .expected = false },
        .{ .super_selector = "*", .sub_selector = ":any(~ .a)", .expected = true },
        .{ .super_selector = ":has(*)", .sub_selector = ":has(> .a)", .expected = false },
        .{ .super_selector = ":not(*)", .sub_selector = ":not(> .a)", .expected = false },
        .{ .super_selector = ":is(:has(> .a))", .sub_selector = ":is(:has(> .a))", .expected = false },
        .{ .super_selector = ":is(*, :has(> .a))", .sub_selector = ":is(*, :has(> .a))", .expected = true },
        .{ .super_selector = "*, :has(> .a)", .sub_selector = ":has(> .a)", .expected = true },
        .{ .super_selector = ":is(.a), .b", .sub_selector = ":is(.a, .b)", .expected = false },
        .{ .super_selector = ":is(.a, .b)", .sub_selector = ":is(.a), .b", .expected = true },
        .{ .super_selector = ".a, .b", .sub_selector = ":is(.a, .b)", .expected = false },
        .{ .super_selector = ":is(.a)", .sub_selector = ":IS(.a)", .expected = false },
        .{ .super_selector = ":has(.a)", .sub_selector = ":is(.a)", .expected = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            try selector.isSuperselector(
                std.testing.allocator,
                case.super_selector,
                case.sub_selector,
                .{},
            ),
        );
    }

    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        ":is(.a, .b)",
        ":where(.a)",
        .{ .max_selectors = 5 },
    ));
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ":is(.a, .b)",
            ":where(.a)",
            .{ .max_selectors = 4 },
        ),
    );

    var exact_component_limit: usize = 1;
    while (exact_component_limit < 64) : (exact_component_limit += 1) {
        const related = selector.isSuperselector(
            std.testing.allocator,
            ":is(.a .b, .c)",
            ":where(.x .a > .b)",
            .{ .max_complex_components = exact_component_limit },
        ) catch |err| switch (err) {
            error.SelectorLimitExceeded => continue,
            else => return err,
        };
        try std.testing.expect(related);
        break;
    }
    try std.testing.expect(exact_component_limit < 64);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ":is(.a .b, .c)",
            ":where(.x .a > .b)",
            .{ .max_complex_components = exact_component_limit - 1 },
        ),
    );

    var exact_temporary_limit: usize = 1;
    while (exact_temporary_limit < 4_096) : (exact_temporary_limit += 1) {
        const related = selector.isSuperselector(
            std.testing.allocator,
            ":is(.a .b, .c)",
            ":where(.x .a > .b)",
            .{ .max_temporary_bytes = exact_temporary_limit },
        ) catch |err| switch (err) {
            error.SelectorLimitExceeded => continue,
            else => return err,
        };
        try std.testing.expect(related);
        break;
    }
    try std.testing.expect(exact_temporary_limit < 4_096);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ":is(.a .b, .c)",
            ":where(.x .a > .b)",
            .{ .max_temporary_bytes = exact_temporary_limit - 1 },
        ),
    );

    var exact_operation_limit: u64 = 1;
    while (exact_operation_limit < 100_000) : (exact_operation_limit += 1) {
        const related = selector.isSuperselector(
            std.testing.allocator,
            ":is(.a .b, .c)",
            ":where(.x .a > .b)",
            .{ .max_relation_operations = exact_operation_limit },
        ) catch |err| switch (err) {
            error.SelectorLimitExceeded => continue,
            else => return err,
        };
        try std.testing.expect(related);
        break;
    }
    try std.testing.expect(exact_operation_limit < 100_000);
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ":is(.a .b, .c)",
            ":where(.x .a > .b)",
            .{ .max_relation_operations = exact_operation_limit - 1 },
        ),
    );

    var nested_super: std.ArrayList(u8) = .empty;
    defer nested_super.deinit(std.testing.allocator);
    var nested_sub: std.ArrayList(u8) = .empty;
    defer nested_sub.deinit(std.testing.allocator);
    for (0..64) |_| {
        try nested_super.appendSlice(std.testing.allocator, ":is(");
        try nested_sub.appendSlice(std.testing.allocator, ":where(");
    }
    try nested_super.appendSlice(std.testing.allocator, ".a, .b");
    try nested_sub.appendSlice(std.testing.allocator, ".a");
    for (0..64) |_| {
        try nested_super.append(std.testing.allocator, ')');
        try nested_sub.append(std.testing.allocator, ')');
    }
    try std.testing.expect(try selector.isSuperselector(
        std.testing.allocator,
        nested_super.items,
        nested_sub.items,
        .{},
    ));
}

test "native Sass selector composition appends selector lists cartesianly" {
    var basic = try selector.append(
        std.testing.allocator,
        &.{ ".accordion", "__copy", ".open" },
        .{},
    );
    defer basic.deinit();
    try expectItems(&.{".accordion__copy.open"}, basic);

    var cartesian = try selector.append(
        std.testing.allocator,
        &.{ ".a, .b", ".c, .d", ":hover, [x]" },
        .{},
    );
    defer cartesian.deinit();
    try expectItems(
        &.{
            ".a.c:hover",
            ".a.c[x]",
            ".a.d:hover",
            ".a.d[x]",
            ".b.c:hover",
            ".b.c[x]",
            ".b.d:hover",
            ".b.d[x]",
        },
        cartesian,
    );

    var complex = try selector.append(
        std.testing.allocator,
        &.{ ".a > .b", ".c > .d" },
        .{},
    );
    defer complex.deinit();
    try expectItems(&.{".a > .b.c > .d"}, complex);
}

test "native Sass selector composition nests parents deterministically" {
    var cartesian = try selector.nest(
        std.testing.allocator,
        &.{ ".a, .b", ".c, .d" },
        .{},
    );
    defer cartesian.deinit();
    try expectItems(&.{ ".a .c", ".a .d", ".b .c", ".b .d" }, cartesian);

    var repeated = try selector.nest(
        std.testing.allocator,
        &.{ ".foo, .bar", "& + &" },
        .{},
    );
    defer repeated.deinit();
    try expectItems(
        &.{ ".foo + .foo", ".foo + .bar", ".bar + .foo", ".bar + .bar" },
        repeated,
    );

    var parent = try selector.nest(
        std.testing.allocator,
        &.{ "&.root", ":not(&), > .child" },
        .{},
    );
    defer parent.deinit();
    try expectItems(&.{ ":not(&.root)", "&.root > .child" }, parent);

    var functional = try selector.nest(
        std.testing.allocator,
        &.{ ".a", ":not(:is(&)), :where(.x + &)" },
        .{},
    );
    defer functional.deinit();
    try expectItems(&.{ ":not(:is(.a))", ":where(.x + .a)" }, functional);
}

test "native Sass selector composition rejects invalid parents and limits" {
    try std.testing.expectError(
        error.InvalidSelector,
        selector.append(std.testing.allocator, &.{}, .{}),
    );
    const invalid_append = [_][]const []const u8{
        &.{ ".a", "&.b" },
        &.{ ".a", "> .b" },
        &.{ ".a >", ".b" },
    };
    for (invalid_append) |inputs| {
        try std.testing.expectError(
            error.InvalidSelector,
            selector.append(std.testing.allocator, inputs, .{}),
        );
    }

    try std.testing.expectError(
        error.InvalidSelector,
        selector.nest(std.testing.allocator, &.{}, .{}),
    );
    const invalid_nest = [_][]const []const u8{
        &.{ ".a", ".b&" },
        &.{ ".a", "&&" },
        &.{ ".a", "[x=&]" },
        &.{ ".a", ":nth-child(2n+&)" },
        &.{ ".a", ":not(calc(1+&))" },
    };
    for (invalid_nest) |inputs| {
        try std.testing.expectError(
            error.InvalidSelector,
            selector.nest(std.testing.allocator, inputs, .{}),
        );
    }

    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.append(
            std.testing.allocator,
            &.{ ".a, .b", ".c, .d" },
            .{ .max_selectors = 3 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.nest(
            std.testing.allocator,
            &.{ ".a, .b", "& + &" },
            .{ .max_selectors = 3 },
        ),
    );
}

test "native Sass selector relations compare structural superselectors" {
    const cases = [_]struct {
        super_selector: []const u8,
        sub_selector: []const u8,
        expected: bool,
    }{
        .{ .super_selector = ".a", .sub_selector = ".a", .expected = true },
        .{ .super_selector = ".a", .sub_selector = ".a.b", .expected = true },
        .{ .super_selector = ".a.b", .sub_selector = ".a", .expected = false },
        .{ .super_selector = "*", .sub_selector = "button", .expected = true },
        .{ .super_selector = "button", .sub_selector = "*", .expected = false },
        .{ .super_selector = "button", .sub_selector = "button.primary", .expected = true },
        .{ .super_selector = "svg|*", .sub_selector = "svg|a.icon", .expected = true },
        .{ .super_selector = "*|a", .sub_selector = "svg|a", .expected = true },
        .{ .super_selector = "html|*", .sub_selector = "svg|a", .expected = false },
        .{ .super_selector = ".a .b", .sub_selector = ".x .a .y .b", .expected = true },
        .{ .super_selector = ".a .b", .sub_selector = ".a > .b", .expected = true },
        .{ .super_selector = ".a > .b", .sub_selector = ".a .b", .expected = false },
        .{ .super_selector = ".a ~ .b", .sub_selector = ".a + .b", .expected = true },
        .{ .super_selector = ".a + .b", .sub_selector = ".a ~ .b", .expected = false },
        .{ .super_selector = ".a ~ .c", .sub_selector = ".a + .b + .c", .expected = true },
        .{ .super_selector = ".b", .sub_selector = ".a > .b", .expected = true },
        .{ .super_selector = ".a", .sub_selector = ".a > .b", .expected = false },
        .{ .super_selector = ".foo, .bar", .sub_selector = ".foo.baz, .bar.qux", .expected = true },
        .{ .super_selector = ".foo", .sub_selector = ".foo, .bar", .expected = false },
        .{ .super_selector = ".foo, .bar", .sub_selector = ".foo", .expected = true },
        .{ .super_selector = "[x='a b']", .sub_selector = "[x=\"a b\"]", .expected = true },
        .{ .super_selector = "[x=y]", .sub_selector = ".more[x=\"y\"]", .expected = true },
        .{ .super_selector = "[x=y i]", .sub_selector = "[x=y I]", .expected = false },
        .{ .super_selector = "[x]", .sub_selector = "[x=y]", .expected = false },
        .{ .super_selector = "[*|x=y]", .sub_selector = "[svg|x=y]", .expected = false },
        .{ .super_selector = "[x=y][x=y]", .sub_selector = "[x=y]", .expected = false },
        .{ .super_selector = ":not(.a)", .sub_selector = ":not(.a)", .expected = true },
        .{ .super_selector = ":not(.a)", .sub_selector = ":not(.a).b", .expected = true },
        .{ .super_selector = ".a", .sub_selector = ".a:is(.b)", .expected = true },
        .{ .super_selector = ".foo", .sub_selector = ".foo.\\66 oo", .expected = true },
        .{ .super_selector = ".\\66 oo", .sub_selector = ".\\66 oo.bar", .expected = true },
        .{ .super_selector = ".a", .sub_selector = ".a::before", .expected = false },
        .{ .super_selector = "*", .sub_selector = ".a::before", .expected = false },
        .{ .super_selector = "::before", .sub_selector = ".a::before", .expected = true },
        .{ .super_selector = ":before", .sub_selector = "::before", .expected = true },
        .{ .super_selector = ".a::before", .sub_selector = ".a.x::before", .expected = true },
        .{ .super_selector = ".a::before", .sub_selector = ".a::after", .expected = false },
        .{ .super_selector = "> .a", .sub_selector = "> .a", .expected = false },
        .{ .super_selector = ".a >", .sub_selector = ".a >", .expected = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            try selector.isSuperselector(
                std.testing.allocator,
                case.super_selector,
                case.sub_selector,
                .{},
            ),
        );
    }
}

test "native Sass selector relations reject unsupported semantics and limits" {
    try std.testing.expectError(
        error.InvalidSelector,
        selector.isSuperselector(std.testing.allocator, "&.a", ".a", .{}),
    );
    const unsupported = [_]struct {
        super_selector: []const u8,
        sub_selector: []const u8,
    }{
        .{ .super_selector = ":nth-child(2n)", .sub_selector = ":nth-child(4n)" },
        .{ .super_selector = ":host(.a)", .sub_selector = ":host(.a, .b)" },
    };
    for (unsupported) |case| {
        try std.testing.expectError(
            error.UnsupportedSelectorRelation,
            selector.isSuperselector(
                std.testing.allocator,
                case.super_selector,
                case.sub_selector,
                .{},
            ),
        );
    }
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ".a, .b",
            ".a",
            .{ .max_selectors = 2 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ".a .b",
            ".a > .b",
            .{ .max_complex_components = 3 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ".a",
            ".a.b",
            .{ .max_relation_operations = 1 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.isSuperselector(
            std.testing.allocator,
            ".a",
            ".a.b",
            .{ .max_temporary_bytes = 1 },
        ),
    );
}

test "native Sass selector unification intersects bounded compounds" {
    const cases = [_]struct {
        left: []const u8,
        right: []const u8,
        expected: []const []const u8,
    }{
        .{ .left = ".a", .right = ".b", .expected = &.{".a.b"} },
        .{ .left = ".a", .right = ".a", .expected = &.{".a"} },
        .{ .left = "button", .right = ".a", .expected = &.{"button.a"} },
        .{ .left = "*", .right = "button", .expected = &.{"button"} },
        .{ .left = "*|a", .right = "svg|a", .expected = &.{"svg|a"} },
        .{ .left = "*|*", .right = "svg|a", .expected = &.{"svg|a"} },
        .{ .left = "svg|*", .right = ".a", .expected = &.{"svg|*.a"} },
        .{ .left = "[x=\"y\"]", .right = "[x=y]", .expected = &.{"[x=y]"} },
        .{ .left = "[ x = 'a b' ]", .right = "[x=\"a b\"]", .expected = &.{"[x=\"a b\"]"} },
        .{ .left = "[x=y i]", .right = "[x=y I]", .expected = &.{"[x=y i][x=y I]"} },
        .{ .left = "[svg|x=\"y\"]", .right = "[svg|x=y]", .expected = &.{"[svg|x=y]"} },
        .{ .left = ".a", .right = "#id", .expected = &.{".a#id"} },
        .{ .left = "#id", .right = ".a", .expected = &.{"#id.a"} },
        .{ .left = ":hover", .right = "[x]", .expected = &.{"[x]:hover"} },
        .{ .left = "::before", .right = ":hover", .expected = &.{":hover::before"} },
        .{ .left = ".a::before", .right = ":before", .expected = &.{".a::before"} },
        .{ .left = ":not(.a)", .right = ".b:not(.a)", .expected = &.{".b:not(.a)"} },
        .{
            .left = ":not(.a)",
            .right = ":not(.b)",
            .expected = &.{":not(.a):not(.b)"},
        },
        .{
            .left = ".a, .b",
            .right = ".x, .y",
            .expected = &.{ ".a.x", ".a.y", ".b.x", ".b.y" },
        },
        .{
            .left = ".a, .a",
            .right = ".a, .a",
            .expected = &.{ ".a", ".a", ".a", ".a" },
        },
        .{
            .left = "a, .a",
            .right = "b, .b",
            .expected = &.{ "a.b", "b.a", ".a.b" },
        },
    };
    for (cases) |case| {
        var unified = (try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) orelse return error.TestUnexpectedResult;
        defer unified.deinit();
        try expectItems(case.expected, unified);
    }

    const conflicts = [_]struct {
        left: []const u8,
        right: []const u8,
    }{
        .{ .left = "a", .right = "b" },
        .{ .left = "#a", .right = "#b" },
        .{ .left = "svg|a", .right = "html|a" },
        .{ .left = "|a", .right = "a" },
        .{ .left = "*", .right = "svg|a" },
        .{ .left = "::before", .right = "::after" },
        .{ .left = "::before", .right = ":BEFORE" },
    };
    for (conflicts) |case| {
        try std.testing.expect((try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) == null);
    }
}

test "native Sass selector extension and replacement expand compound matches" {
    const cases = [_]struct {
        selector_input: []const u8,
        extendee: []const u8,
        extender: []const u8,
        extended: []const []const u8,
        replaced: []const []const u8,
    }{
        .{
            .selector_input = ".a",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".a", ".b" },
            .replaced = &.{".b"},
        },
        .{
            .selector_input = ".a.c",
            .extendee = ".a",
            .extender = ".b.d",
            .extended = &.{ ".a.c", ".c.b.d" },
            .replaced = &.{".c.b.d"},
        },
        .{
            .selector_input = "a.foo",
            .extendee = "a",
            .extender = "button",
            .extended = &.{ "a.foo", "button.foo" },
            .replaced = &.{"button.foo"},
        },
        .{
            .selector_input = "#a.foo",
            .extendee = "#a",
            .extender = "#b",
            .extended = &.{ "#a.foo", ".foo#b" },
            .replaced = &.{".foo#b"},
        },
        .{
            .selector_input = "%a.foo",
            .extendee = "%a",
            .extender = "%b",
            .extended = &.{ "%a.foo", ".foo%b" },
            .replaced = &.{".foo%b"},
        },
        .{
            .selector_input = ".x > .a + .y",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".x > .a + .y", ".x > .b + .y" },
            .replaced = &.{".x > .b + .y"},
        },
        .{
            .selector_input = ".a.c .a.d",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{
                ".a.c .a.d",
                ".c.b .a.d",
                ".a.c .d.b",
                ".c.b .d.b",
            },
            .replaced = &.{".c.b .d.b"},
        },
        .{
            .selector_input = ".a.c, .x > .a.d, .none",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{
                ".a.c",
                ".c.b",
                ".x > .a.d",
                ".x > .d.b",
                ".none",
            },
            .replaced = &.{ ".c.b", ".x > .d.b", ".none" },
        },
        .{
            .selector_input = ".a.b",
            .extendee = ".a",
            .extender = ".a",
            .extended = &.{".a.b"},
            .replaced = &.{".b.a"},
        },
        .{
            .selector_input = ".a, .x > .a",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".a", ".b", ".x > .a" },
            .replaced = &.{ ".b", ".x > .b" },
        },
        .{
            .selector_input = ".x > .a, .a",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".x > .a", ".a", ".b" },
            .replaced = &.{ ".x > .b", ".b" },
        },
        .{
            .selector_input = ".a, .b",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".a", ".b" },
            .replaced = &.{".b"},
        },
        .{
            .selector_input = ".x .b, .x > .a",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".x .b", ".x > .a" },
            .replaced = &.{ ".x .b", ".x > .b" },
        },
        .{
            .selector_input = ".a, .b.c",
            .extendee = ".a",
            .extender = ".c.b",
            .extended = &.{ ".a", ".b.c" },
            .replaced = &.{ ".c.b", ".b.c" },
        },
        .{
            .selector_input = ".x > .b, .x .a",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".x > .b", ".x .a", ".x .b" },
            .replaced = &.{ ".x > .b", ".x .b" },
        },
        .{
            .selector_input = ".x > .a, .x .b",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".x > .a", ".x .b" },
            .replaced = &.{ ".x > .b", ".x .b" },
        },
        .{
            .selector_input = ".x .a, .x > .b",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".x .a", ".x .b", ".x > .b" },
            .replaced = &.{ ".x .b", ".x > .b" },
        },
    };
    for (cases) |case| {
        var extended = try selector.extend(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer extended.deinit();
        try expectItems(case.extended, extended);

        var replaced = try selector.replace(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer replaced.deinit();
        try expectItems(case.replaced, replaced);
    }
}

test "native Sass selector extension and replacement expand compound lists" {
    const cases = [_]struct {
        selector_input: []const u8,
        extendee: []const u8,
        extender: []const u8,
        extended: []const []const u8,
        replaced: []const []const u8,
    }{
        .{
            .selector_input = ".a.c .a",
            .extendee = ".a, .c",
            .extender = ".x",
            .extended = &.{ ".a.c .a", ".x .a", ".a.c .x", ".x .x" },
            .replaced = &.{".x .x"},
        },
        .{
            .selector_input = ".a .a",
            .extendee = ".a",
            .extender = ".d, .b",
            .extended = &.{
                ".a .a",
                ".d .a",
                ".b .a",
                ".a .d",
                ".d .d",
                ".b .d",
                ".a .b",
                ".d .b",
                ".b .b",
            },
            .replaced = &.{ ".d .d", ".b .d", ".d .b", ".b .b" },
        },
        .{
            .selector_input = ".a.c",
            .extendee = ".a, .c",
            .extender = ".b, .d",
            .extended = &.{ ".a.c", ".b", ".d" },
            .replaced = &.{ ".b", ".d" },
        },
        .{
            .selector_input = ".a, .c",
            .extendee = ".a, .c",
            .extender = ".b, .d",
            .extended = &.{ ".a", ".b", ".d", ".c" },
            .replaced = &.{ ".b", ".d", ".b" },
        },
        .{
            .selector_input = ".a.b.c",
            .extendee = ".a.b, .c",
            .extender = ".x, .y",
            .extended = &.{ ".a.b.c", ".x", ".y" },
            .replaced = &.{ ".x", ".y" },
        },
        .{
            .selector_input = ".a.b.c.d",
            .extendee = ".a.b.c.d",
            .extender = ".x, .y",
            .extended = &.{ ".a.b.c.d", ".x", ".y" },
            .replaced = &.{ ".x", ".y" },
        },
        .{
            .selector_input = ".p > .a + .a",
            .extendee = ".a",
            .extender = ".b, .c",
            .extended = &.{
                ".p > .a + .a",
                ".p > .b + .a",
                ".p > .c + .a",
                ".p > .a + .b",
                ".p > .b + .b",
                ".p > .c + .b",
                ".p > .a + .c",
                ".p > .b + .c",
                ".p > .c + .c",
            },
            .replaced = &.{
                ".p > .b + .b",
                ".p > .c + .b",
                ".p > .b + .c",
                ".p > .c + .c",
            },
        },
        .{
            .selector_input = ".a.b",
            .extendee = ".a, .a.b",
            .extender = ".x",
            .extended = &.{ ".a.b", ".x" },
            .replaced = &.{".b.x"},
        },
        .{
            .selector_input = ".none",
            .extendee = ".a, .c",
            .extender = ".b, .d",
            .extended = &.{".none"},
            .replaced = &.{".none"},
        },
        .{
            .selector_input = ".none",
            .extendee = ".a.b.c.d.e.f.g",
            .extender = ".x, .y",
            .extended = &.{".none"},
            .replaced = &.{".none"},
        },
    };
    for (cases) |case| {
        var extended = try selector.extend(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer extended.deinit();
        try expectItems(case.extended, extended);

        var replaced = try selector.replace(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer replaced.deinit();
        try expectItems(case.replaced, replaced);
    }

    var original_order = try selector.replace(
        std.testing.allocator,
        ".a, .b",
        ".a",
        ".b, .c",
        .{},
    );
    defer original_order.deinit();
    try expectItems(&.{ ".b", ".c", ".b" }, original_order);

    var reversed = try selector.replace(
        std.testing.allocator,
        ".a.b",
        ".a.b, .a",
        ".x",
        .{},
    );
    defer reversed.deinit();
    try expectItems(&.{".x"}, reversed);

    var typed = try selector.replace(
        std.testing.allocator,
        "button.a, #id.a",
        ".a, .z",
        ".b, .c",
        .{},
    );
    defer typed.deinit();
    try expectItems(&.{ "button.b", "button.c", "#id.b", "#id.c" }, typed);

    var above_trim_threshold = try selector.extend(
        std.testing.allocator,
        ".a .a .a .a .a",
        ".a",
        ".b, .c",
        .{},
    );
    defer above_trim_threshold.deinit();
    try std.testing.expectEqual(@as(usize, 243), above_trim_threshold.items.len);
    try std.testing.expectEqualStrings(
        ".a .a .a .a .a",
        above_trim_threshold.items[0],
    );
    try std.testing.expectEqualStrings(
        ".b .a .a .a .a",
        above_trim_threshold.items[1],
    );
    try std.testing.expectEqualStrings(
        ".c .c .c .c .c",
        above_trim_threshold.items[242],
    );
}

test "native Sass selector extension normalizes duplicate simples and equivalent members" {
    const cases = [_]struct {
        selector_input: []const u8,
        extendee: []const u8,
        extender: []const u8,
        extended: []const []const u8,
        replaced: []const []const u8,
    }{
        .{
            .selector_input = ".a.a.c",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".a.a.c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = ".a.a.c",
            .extendee = ".a.a",
            .extender = ".b",
            .extended = &.{ ".a.a.c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = ".a.c",
            .extendee = ".a",
            .extender = ".b.b",
            .extended = &.{ ".a.c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = ".a",
            .extendee = ".a",
            .extender = ".b.b",
            .extended = &.{ ".a", ".b.b" },
            .replaced = &.{".b.b"},
        },
        .{
            .selector_input = "#x#x.c",
            .extendee = "#x",
            .extender = ".b",
            .extended = &.{ "#x#x.c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = ".a.b, .b.a",
            .extendee = ".a",
            .extender = ".c",
            .extended = &.{ ".a.b", ".b.c", ".b.a" },
            .replaced = &.{".b.c"},
        },
        .{
            .selector_input = ".a.b, .b.a",
            .extendee = ".z",
            .extender = ".x",
            .extended = &.{ ".a.b", ".b.a" },
            .replaced = &.{ ".a.b", ".b.a" },
        },
        .{
            .selector_input = ".a, .a",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".a", ".b", ".a" },
            .replaced = &.{".b"},
        },
        .{
            .selector_input = ".a, .a",
            .extendee = ".a",
            .extender = ".a",
            .extended = &.{".a"},
            .replaced = &.{".a"},
        },
        .{
            .selector_input = ".a, .a",
            .extendee = ".z",
            .extender = ".x",
            .extended = &.{ ".a", ".a" },
            .replaced = &.{ ".a", ".a" },
        },
        .{
            .selector_input = ".a, .a, .c",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".a", ".b", ".c" },
            .replaced = &.{ ".b", ".c" },
        },
        .{
            .selector_input = ".a, .a, .b",
            .extendee = ".a",
            .extender = ".b",
            .extended = &.{ ".a", ".b" },
            .replaced = &.{".b"},
        },
        .{
            .selector_input = ".a, .b, .a",
            .extendee = ".a",
            .extender = ".a",
            .extended = &.{ ".a", ".b" },
            .replaced = &.{ ".a", ".b" },
        },
        .{
            .selector_input = ".a",
            .extendee = ".a, .a",
            .extender = ".b",
            .extended = &.{ ".a", ".b" },
            .replaced = &.{".b"},
        },
        .{
            .selector_input = ".a.b",
            .extendee = ".a.b, .b.a",
            .extender = ".x",
            .extended = &.{ ".a.b", ".x" },
            .replaced = &.{".x"},
        },
        .{
            .selector_input = ".a",
            .extendee = ".a",
            .extender = ".b, .b",
            .extended = &.{ ".a", ".b" },
            .replaced = &.{".b"},
        },
        .{
            .selector_input = ".a",
            .extendee = ".a",
            .extender = ".b.c, .c.b",
            .extended = &.{ ".a", ".b.c" },
            .replaced = &.{".b.c"},
        },
        .{
            .selector_input = ".a",
            .extendee = ".a",
            .extender = ".c.b, .b.c",
            .extended = &.{ ".a", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = ".a",
            .extendee = ".a.a.a.a.a",
            .extender = ".b, .c",
            .extended = &.{ ".a", ".b", ".c" },
            .replaced = &.{ ".b", ".c" },
        },
        .{
            .selector_input = ".a, .a, .c",
            .extendee = ".a, .a",
            .extender = ".b, .b",
            .extended = &.{ ".a", ".b", ".c" },
            .replaced = &.{ ".b", ".c" },
        },
        .{
            .selector_input = ".a.b, .b.a, .c",
            .extendee = ".a.b, .b.a",
            .extender = ".x.y, .y.x",
            .extended = &.{ ".a.b", ".x.y", ".b.a", ".c" },
            .replaced = &.{ ".x.y", ".c" },
        },
        .{
            .selector_input = ".a.a .a.a",
            .extendee = ".a.a",
            .extender = ".b.b, .b.b",
            .extended = &.{
                ".a.a .a.a",
                ".b.b .a.a",
                ".a.a .b.b",
                ".b.b .b.b",
            },
            .replaced = &.{".b.b .b.b"},
        },
    };
    for (cases) |case| {
        var extended = try selector.extend(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer extended.deinit();
        try expectItems(case.extended, extended);

        var replaced = try selector.replace(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer replaced.deinit();
        try expectItems(case.replaced, replaced);
    }
}

test "native Sass selector extension normalizes bounded attributes" {
    const cases = [_]struct {
        selector_input: []const u8,
        extendee: []const u8,
        extender: []const u8,
        extended: []const []const u8,
        replaced: []const []const u8,
    }{
        .{
            .selector_input = "[x=\"y\"].c",
            .extendee = "[x=y]",
            .extender = ".b",
            .extended = &.{ "[x=y].c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = "[x='a b'].c",
            .extendee = "[x=\"a b\"]",
            .extender = ".b",
            .extended = &.{ "[x=\"a b\"].c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = "[x=y I].c",
            .extendee = "[x=y i]",
            .extender = ".b",
            .extended = &.{"[x=y I].c"},
            .replaced = &.{"[x=y I].c"},
        },
        .{
            .selector_input = "[ x = \"y\" ]",
            .extendee = "[z]",
            .extender = ".b",
            .extended = &.{"[x=y]"},
            .replaced = &.{"[x=y]"},
        },
        .{
            .selector_input = "[x=y][x=\"y\"].c",
            .extendee = "[x=y]",
            .extender = ".b",
            .extended = &.{ "[x=y][x=y].c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = "[x=y].c",
            .extendee = "[x=y][x=\"y\"]",
            .extender = ".b",
            .extended = &.{ "[x=y].c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = "[x=y].a, .a[x=\"y\"]",
            .extendee = "[x=y]",
            .extender = ".b",
            .extended = &.{ "[x=y].a", ".a.b", ".a[x=y]" },
            .replaced = &.{".a.b"},
        },
        .{
            .selector_input = "[x=y]",
            .extendee = "[x=y]",
            .extender = "[z=\"q\"]",
            .extended = &.{ "[x=y]", "[z=q]" },
            .replaced = &.{"[z=q]"},
        },
        .{
            .selector_input = "[*|x=y].c",
            .extendee = "[*|x=\"y\"]",
            .extender = ".b",
            .extended = &.{ "[*|x=y].c", ".c.b" },
            .replaced = &.{".c.b"},
        },
        .{
            .selector_input = "[svg|x=y].c",
            .extendee = "[*|x=y]",
            .extender = ".b",
            .extended = &.{"[svg|x=y].c"},
            .replaced = &.{"[svg|x=y].c"},
        },
    };
    for (cases) |case| {
        var extended = try selector.extend(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer extended.deinit();
        try expectItems(case.extended, extended);

        var replaced = try selector.replace(
            std.testing.allocator,
            case.selector_input,
            case.extendee,
            case.extender,
            .{},
        );
        defer replaced.deinit();
        try expectItems(case.replaced, replaced);
    }

    const below_exact = [_]selector.Limits{
        .{ .max_selectors = 6 },
        .{ .max_bytes = 49 },
        .{ .max_complex_components = 33 },
        .{ .max_temporary_bytes = 861 },
        .{ .max_relation_operations = 102 },
    };
    for (below_exact) |limits| {
        try std.testing.expectError(
            error.SelectorLimitExceeded,
            selector.extend(
                std.testing.allocator,
                "[x=\"y\"] [x=y]",
                "[x=y]",
                ".b",
                limits,
            ),
        );
    }
    var exactly_bounded = try selector.extend(
        std.testing.allocator,
        "[x=\"y\"] [x=y]",
        "[x=y]",
        ".b",
        .{
            .max_selectors = 7,
            .max_bytes = 50,
            .max_complex_components = 34,
            .max_temporary_bytes = 862,
            .max_relation_operations = 103,
        },
    );
    defer exactly_bounded.deinit();
    try expectItems(
        &.{
            "[x=y] [x=y]",
            ".b [x=y]",
            "[x=y] .b",
            ".b .b",
        },
        exactly_bounded,
    );
}

test "native Sass selector extension and replacement fail closed and honor limits" {
    const unsupported = [_]struct {
        selector_input: []const u8,
        extendee: []const u8,
        extender: []const u8,
    }{
        .{ .selector_input = ".a", .extendee = ".a, .x .c", .extender = ".b" },
        .{ .selector_input = ".a", .extendee = ".a", .extender = ".b, .x .c" },
        .{ .selector_input = "a.foo", .extendee = ".foo", .extender = "button, .x" },
        .{ .selector_input = ".a", .extendee = ".x .a", .extender = ".b" },
        .{ .selector_input = ".a", .extendee = ".a", .extender = ".x .b" },
        .{ .selector_input = "a.foo", .extendee = ".foo", .extender = "button" },
        .{ .selector_input = ":is(.a)", .extendee = ".a", .extender = ".b" },
        .{ .selector_input = ".x::before", .extendee = ".x", .extender = ".y" },
        .{ .selector_input = ".x:hover", .extendee = ":hover", .extender = "::before" },
        .{ .selector_input = "svg|a", .extendee = "svg|a", .extender = "button" },
        .{ .selector_input = "*.a", .extendee = ".a", .extender = ".b" },
    };
    for (unsupported) |case| {
        try std.testing.expectError(
            error.UnsupportedSelectorExtension,
            selector.extend(
                std.testing.allocator,
                case.selector_input,
                case.extendee,
                case.extender,
                .{},
            ),
        );
        try std.testing.expectError(
            error.UnsupportedSelectorExtension,
            selector.replace(
                std.testing.allocator,
                case.selector_input,
                case.extendee,
                case.extender,
                .{},
            ),
        );
    }

    // Dart Sass stops trimming an individual compound's generated extension
    // power set above 100 candidates. The bounded native list slice does not
    // yet materialize those otherwise-redundant mixed compounds, so reject
    // that boundary instead of returning a silently incomplete selector list.
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.extend(
            std.testing.allocator,
            ".a.b.c.d.e",
            ".a.b.c.d.e",
            ".x, .y",
            .{},
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.replace(
            std.testing.allocator,
            ".a.b.c.d.e.f.g",
            ".a.b.c.d.e.f.g",
            ".x, .y",
            .{},
        ),
    );

    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.extend(
            std.testing.allocator,
            ".a .a",
            ".a",
            ".b",
            .{ .max_selectors = 6 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.replace(
            std.testing.allocator,
            ".a .a",
            ".a",
            ".b",
            .{ .max_bytes = 13 },
        ),
    );

    const below_exact = [_]selector.Limits{
        .{ .max_selectors = 6 },
        .{ .max_bytes = 28 },
        .{ .max_complex_components = 33 },
        .{ .max_temporary_bytes = 849 },
        .{ .max_relation_operations = 108 },
    };
    for (below_exact) |limits| {
        try std.testing.expectError(
            error.SelectorLimitExceeded,
            selector.extend(
                std.testing.allocator,
                ".a .a",
                ".a",
                ".b",
                limits,
            ),
        );
    }
    var exactly_bounded = try selector.extend(
        std.testing.allocator,
        ".a .a",
        ".a",
        ".b",
        .{
            .max_selectors = 7,
            .max_bytes = 29,
            .max_complex_components = 34,
            .max_temporary_bytes = 850,
            .max_relation_operations = 109,
        },
    );
    defer exactly_bounded.deinit();
    try expectItems(
        &.{ ".a .a", ".b .a", ".a .b", ".b .b" },
        exactly_bounded,
    );

    const list_below_exact = [_]selector.Limits{
        .{ .max_selectors = 12 },
        .{ .max_bytes = 55 },
    };
    for (list_below_exact) |limits| {
        try std.testing.expectError(
            error.SelectorLimitExceeded,
            selector.extend(
                std.testing.allocator,
                ".a .a",
                ".a",
                ".b, .c",
                limits,
            ),
        );
    }
    var exactly_bounded_list = try selector.extend(
        std.testing.allocator,
        ".a .a",
        ".a",
        ".b, .c",
        .{ .max_selectors = 13, .max_bytes = 56 },
    );
    defer exactly_bounded_list.deinit();
    try expectItems(
        &.{
            ".a .a",
            ".b .a",
            ".c .a",
            ".a .b",
            ".b .b",
            ".c .b",
            ".a .c",
            ".b .c",
            ".c .c",
        },
        exactly_bounded_list,
    );
}

test "native Sass selector unification replaces complex subjects and strict ancestry" {
    const cases = [_]struct {
        left: []const u8,
        right: []const u8,
        expected: []const []const u8,
    }{
        .{ .left = ".a .b", .right = ".c", .expected = &.{".a .b.c"} },
        .{ .left = ".a", .right = ".b .c", .expected = &.{".b .a.c"} },
        .{ .left = ".a > .b", .right = ".a > .b", .expected = &.{".a > .b"} },
        .{ .left = ".a .b", .right = ".a .c", .expected = &.{".a .b.c"} },
        .{
            .left = ".a > .b + .c",
            .right = ".d > .e + .f",
            .expected = &.{".a.d > .b.e + .c.f"},
        },
        .{ .left = ".a ~ .b", .right = ".c", .expected = &.{".a ~ .b.c"} },
        .{
            .left = ".a .b, .x > .y",
            .right = ".c, .z",
            .expected = &.{ ".a .b.c", ".a .b.z", ".x > .y.c", ".x > .y.z" },
        },
        .{
            .left = ".a b, .x .y",
            .right = "c, .z",
            .expected = &.{ ".a b.z", ".x c.y", ".x .y.z" },
        },
    };
    for (cases) |case| {
        var unified = (try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) orelse return error.TestUnexpectedResult;
        defer unified.deinit();
        try expectItems(case.expected, unified);
    }

    try std.testing.expect((try selector.unify(
        std.testing.allocator,
        ".a b",
        "c",
        .{},
    )) == null);
    try std.testing.expect((try selector.unify(
        std.testing.allocator,
        "a > .b",
        "c > .d",
        .{},
    )) == null);
}

test "native Sass selector unification weaves disjoint ancestry chunks" {
    const cases = [_]struct {
        left: []const u8,
        right: []const u8,
        expected: []const []const u8,
    }{
        .{
            .left = ".a .b",
            .right = ".c .d",
            .expected = &.{ ".a .c .b.d", ".c .a .b.d" },
        },
        .{
            .left = ".a > .b .c",
            .right = ".d .e",
            .expected = &.{ ".a > .b .d .c.e", ".d .a > .b .c.e" },
        },
        .{
            .left = ".a + .b .c",
            .right = ".d .e",
            .expected = &.{ ".a + .b .d .c.e", ".d .a + .b .c.e" },
        },
        .{
            .left = ".a > .b",
            .right = ".c .d",
            .expected = &.{".c .a > .b.d"},
        },
        .{
            .left = ".a .b",
            .right = ".c > .d",
            .expected = &.{".a .c > .b.d"},
        },
        .{
            .left = ".a + .b",
            .right = ".c .d",
            .expected = &.{".c .a + .b.d"},
        },
        .{
            .left = ".a .b",
            .right = ".c + .d",
            .expected = &.{".a .c + .b.d"},
        },
        .{
            .left = ".a.b .c",
            .right = ".d.e .f",
            .expected = &.{ ".a.b .d.e .c.f", ".d.e .a.b .c.f" },
        },
        .{
            .left = "a .b",
            .right = "c .d",
            .expected = &.{ "a c .b.d", "c a .b.d" },
        },
        .{
            .left = ".a .b, .x .y",
            .right = ".c .d, .z .w",
            .expected = &.{
                ".a .c .b.d",
                ".c .a .b.d",
                ".a .z .b.w",
                ".z .a .b.w",
                ".x .c .y.d",
                ".c .x .y.d",
                ".x .z .y.w",
                ".z .x .y.w",
            },
        },
    };
    for (cases) |case| {
        var unified = (try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) orelse return error.TestUnexpectedResult;
        defer unified.deinit();
        try expectItems(case.expected, unified);
    }
}

test "native Sass selector unification weaves exact shared descendant anchors" {
    const cases = [_]struct {
        left: []const u8,
        right: []const u8,
        expected: []const []const u8,
    }{
        .{
            .left = ".a .b .c",
            .right = ".d .b .e",
            .expected = &.{ ".a .d .b .c.e", ".d .a .b .c.e" },
        },
        .{
            .left = ".a .b .c",
            .right = ".b .d",
            .expected = &.{".a .b .c.d"},
        },
        .{
            .left = ".a .b .c",
            .right = ".d .a .e",
            .expected = &.{".d .a .b .c.e"},
        },
        .{
            .left = ".a .b .c .d",
            .right = ".x .b .c .e",
            .expected = &.{ ".a .x .b .c .d.e", ".x .a .b .c .d.e" },
        },
        .{
            .left = ".a1 .x .a2 .y .s",
            .right = ".b1 .x .b2 .y .t",
            .expected = &.{
                ".a1 .b1 .x .a2 .b2 .y .s.t",
                ".b1 .a1 .x .a2 .b2 .y .s.t",
                ".a1 .b1 .x .b2 .a2 .y .s.t",
                ".b1 .a1 .x .b2 .a2 .y .s.t",
            },
        },
        .{
            .left = ".a .x .c .s",
            .right = ".b .x .d .t",
            .expected = &.{
                ".a .b .x .c .d .s.t",
                ".b .a .x .c .d .s.t",
                ".a .b .x .d .c .s.t",
                ".b .a .x .d .c .s.t",
            },
        },
        .{
            .left = ".a .b .c",
            .right = ".b .a .d",
            .expected = &.{".a .b .a .c.d"},
        },
        .{
            .left = ".b .a .d",
            .right = ".a .b .c",
            .expected = &.{".b .a .b .d.c"},
        },
        .{
            .left = ".a .b .a .s",
            .right = ".a .a .b .t",
            .expected = &.{".a .b .a .b .s.t"},
        },
        .{
            .left = ".a .b .a .s",
            .right = ".b .a .b .t",
            .expected = &.{".a .b .a .b .s.t"},
        },
        .{
            .left = ".a .b .c",
            .right = ".d .b .e, .x .b .y",
            .expected = &.{
                ".a .d .b .c.e",
                ".d .a .b .c.e",
                ".a .x .b .c.y",
                ".x .a .b .c.y",
            },
        },
    };
    for (cases) |case| {
        var unified = (try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) orelse return error.TestUnexpectedResult;
        defer unified.deinit();
        try expectItems(case.expected, unified);
    }
}

test "native Sass selector unification weaves shared anchors with rigid ancestry suffixes" {
    const cases = [_]struct {
        left: []const u8,
        right: []const u8,
        expected: []const []const u8,
    }{
        .{
            .left = ".a > .b .c",
            .right = ".d .b .e",
            .expected = &.{".d .a > .b .c.e"},
        },
        .{
            .left = ".a + .b .c",
            .right = ".d .b .e",
            .expected = &.{".d .a + .b .c.e"},
        },
        .{
            .left = ".a ~ .b .c",
            .right = ".d .b .e",
            .expected = &.{".d .a ~ .b .c.e"},
        },
        .{
            .left = ".a .b .c",
            .right = ".d > .b .e",
            .expected = &.{".a .d > .b .c.e"},
        },
        .{
            .left = ".p .a > .b .c",
            .right = ".q .d .b .e",
            .expected = &.{
                ".p .q .d .a > .b .c.e",
                ".q .d .p .a > .b .c.e",
            },
        },
        .{
            .left = ".a > .b .x .c",
            .right = ".d .b .y .e",
            .expected = &.{
                ".d .a > .b .x .y .c.e",
                ".d .a > .b .y .x .c.e",
            },
        },
        .{
            .left = ".a > .m + .b .c",
            .right = ".d .b .e",
            .expected = &.{".d .a > .m + .b .c.e"},
        },
        .{
            .left = ".a > .x .b + .y .c",
            .right = ".d .x .e .y .f",
            .expected = &.{".d .a > .x .e .b + .y .c.f"},
        },
        .{
            .left = ".a > .b .c, .u + .v .w",
            .right = ".d .b .e",
            .expected = &.{
                ".d .a > .b .c.e",
                ".u + .v .d .b .w.e",
                ".d .b .u + .v .w.e",
            },
        },
        .{
            .left = ".d .b .e",
            .right = ".a > .b .c",
            .expected = &.{".d .a > .b .e.c"},
        },
        .{
            .left = ".p .a .b .c",
            .right = ".q .d > .b .e",
            .expected = &.{
                ".p .a .q .d > .b .c.e",
                ".q .p .a .d > .b .c.e",
            },
        },
        .{
            .left = ".a .b .c",
            .right = ".d > .m + .b .e",
            .expected = &.{".a .d > .m + .b .c.e"},
        },
        .{
            .left = ".a > .b > .x .s",
            .right = ".c .x .t",
            .expected = &.{".c .a > .b > .x .s.t"},
        },
        .{
            .left = ".p .a > .b > .x .s",
            .right = ".q .c .x .t",
            .expected = &.{
                ".p .q .c .a > .b > .x .s.t",
                ".q .c .p .a > .b > .x .s.t",
            },
        },
        .{
            .left = ".a > .x .b + .y .s",
            .right = ".c .x .d .y .t",
            .expected = &.{".c .a > .x .d .b + .y .s.t"},
        },
    };
    for (cases) |case| {
        var unified = (try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) orelse return error.TestUnexpectedResult;
        defer unified.deinit();
        try expectItems(case.expected, unified);
    }
}

test "native Sass selector unification weaves terminal sibling constraints" {
    const cases = [_]struct {
        left: []const u8,
        right: []const u8,
        expected: []const []const u8,
    }{
        .{
            .left = ".a ~ .b",
            .right = ".c ~ .d",
            .expected = &.{
                ".a ~ .c ~ .b.d",
                ".c ~ .a ~ .b.d",
                ".a.c ~ .b.d",
            },
        },
        .{
            .left = ".a ~ .b",
            .right = ".c + .d",
            .expected = &.{ ".a ~ .c + .b.d", ".a.c + .b.d" },
        },
        .{
            .left = ".a + .b",
            .right = ".c ~ .d",
            .expected = &.{ ".c ~ .a + .b.d", ".c.a + .b.d" },
        },
        .{
            .left = ".a > .b",
            .right = ".c + .d",
            .expected = &.{".a > .c + .b.d"},
        },
        .{
            .left = ".a > .b",
            .right = ".c ~ .d",
            .expected = &.{".a > .c ~ .b.d"},
        },
        .{
            .left = ".a + .b",
            .right = ".c > .d",
            .expected = &.{".c > .a + .b.d"},
        },
        .{
            .left = ".a ~ .b",
            .right = ".c > .d",
            .expected = &.{".c > .a ~ .b.d"},
        },
        .{
            .left = ".a .b",
            .right = ".c ~ .d",
            .expected = &.{".a .c ~ .b.d"},
        },
        .{
            .left = ".a ~ .b",
            .right = ".c .d",
            .expected = &.{".c .a ~ .b.d"},
        },
        .{
            .left = "a ~ .b",
            .right = "c ~ .d",
            .expected = &.{ "a ~ c ~ .b.d", "c ~ a ~ .b.d" },
        },
        .{
            .left = "a ~ .b",
            .right = "c + .d",
            .expected = &.{"a ~ c + .b.d"},
        },
        .{
            .left = "a + .b",
            .right = "c ~ .d",
            .expected = &.{"c ~ a + .b.d"},
        },
        .{
            .left = ".a ~ .b",
            .right = ".a.b ~ .d",
            .expected = &.{".a.b ~ .b.d"},
        },
        .{
            .left = ".a.b ~ .b",
            .right = ".a + .d",
            .expected = &.{ ".a.b ~ .a + .b.d", ".a.b + .b.d" },
        },
        .{
            .left = ".a ~ .b",
            .right = ".a.b + .d",
            .expected = &.{".a.b + .b.d"},
        },
        .{
            .left = ".a ~ .b, .x + .y",
            .right = ".c ~ .d",
            .expected = &.{
                ".a ~ .c ~ .b.d",
                ".c ~ .a ~ .b.d",
                ".a.c ~ .b.d",
                ".c ~ .x + .y.d",
                ".c.x + .y.d",
            },
        },
    };
    for (cases) |case| {
        var unified = (try selector.unify(
            std.testing.allocator,
            case.left,
            case.right,
            .{},
        )) orelse return error.TestUnexpectedResult;
        defer unified.deinit();
        try expectItems(case.expected, unified);
    }

    try std.testing.expect((try selector.unify(
        std.testing.allocator,
        "a + .b",
        "c + .d",
        .{},
    )) == null);
}

test "native Sass selector unification rejects unavailable semantics and limits" {
    try std.testing.expectError(
        error.InvalidSelector,
        selector.unify(std.testing.allocator, "&.a", ".b", .{}),
    );
    const unsupported = [_]struct {
        left: []const u8,
        right: []const u8,
    }{
        .{ .left = ".a.b .c", .right = ".b.d .e" },
        .{ .left = ".a > .b .c", .right = ".d > .b .e" },
        .{ .left = ".a > .b .x .s", .right = ".c .x .t" },
        .{ .left = ".a .x > .b .s", .right = ".c .x .d .t" },
        .{ .left = "* .b", .right = "a .d" },
        .{ .left = ".p .a ~ .b", .right = ".q .c ~ .d" },
        .{ .left = "#a .b", .right = ".c .d" },
        .{ .left = "[x] .b", .right = ".c .d" },
        .{ .left = ":hover .b", .right = ".c .d" },
        .{ .left = "> .a", .right = ".b" },
        .{ .left = ".a >", .right = ".b" },
        .{ .left = ":host", .right = ".b" },
        .{ .left = ":host(.a)", .right = ".b" },
        .{ .left = "::slotted(.a)", .right = ".b" },
    };
    for (unsupported) |case| {
        try std.testing.expectError(
            error.UnsupportedSelectorUnification,
            selector.unify(
                std.testing.allocator,
                case.left,
                case.right,
                .{},
            ),
        );
    }
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a, .b",
            ".x, .y",
            .{ .max_selectors = 7 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a",
            ".b",
            .{ .max_complex_components = 2 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a",
            ".b",
            .{ .max_relation_operations = 1 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a",
            ".b",
            .{ .max_temporary_bytes = 1 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c",
            .{ .max_complex_components = 3 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c",
            .{ .max_bytes = 10 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c",
            .{ .max_relation_operations = 4 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c .d",
            .{ .max_selectors = 3 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c .d",
            .{ .max_bytes = 29 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c .d",
            .{ .max_complex_components = 16 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c .d",
            .{ .max_temporary_bytes = 221 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            ".a .b",
            ".c .d",
            .{ .max_relation_operations = 27 },
        ),
    );
    var exactly_bounded = (try selector.unify(
        std.testing.allocator,
        ".a .b",
        ".c .d",
        .{
            .max_selectors = 4,
            .max_bytes = 30,
            .max_complex_components = 17,
            .max_temporary_bytes = 222,
            .max_relation_operations = 28,
        },
    )) orelse return error.TestUnexpectedResult;
    defer exactly_bounded.deinit();
    try expectItems(&.{ ".a .c .b.d", ".c .a .b.d" }, exactly_bounded);

    const shared_left = ".a1 .x .a2 .y .s";
    const shared_right = ".b1 .x .b2 .y .t";
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            shared_left,
            shared_right,
            .{ .max_selectors = 5 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            shared_left,
            shared_right,
            .{ .max_bytes = 135 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            shared_left,
            shared_right,
            .{ .max_complex_components = 50 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            shared_left,
            shared_right,
            .{ .max_temporary_bytes = 681 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            shared_left,
            shared_right,
            .{ .max_relation_operations = 127 },
        ),
    );
    var shared_exactly_bounded = (try selector.unify(
        std.testing.allocator,
        shared_left,
        shared_right,
        .{
            .max_selectors = 6,
            .max_bytes = 136,
            .max_complex_components = 51,
            .max_temporary_bytes = 682,
            .max_relation_operations = 128,
        },
    )) orelse return error.TestUnexpectedResult;
    defer shared_exactly_bounded.deinit();
    try expectItems(
        &.{
            ".a1 .b1 .x .a2 .b2 .y .s.t",
            ".b1 .a1 .x .a2 .b2 .y .s.t",
            ".a1 .b1 .x .b2 .a2 .y .s.t",
            ".b1 .a1 .x .b2 .a2 .y .s.t",
        },
        shared_exactly_bounded,
    );

    const sibling_left = ".a ~ .b";
    const sibling_right = ".c ~ .d";
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            sibling_left,
            sibling_right,
            .{ .max_selectors = 4 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            sibling_left,
            sibling_right,
            .{ .max_bytes = 52 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            sibling_left,
            sibling_right,
            .{ .max_complex_components = 21 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            sibling_left,
            sibling_right,
            .{ .max_temporary_bytes = 298 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            sibling_left,
            sibling_right,
            .{ .max_relation_operations = 33 },
        ),
    );
    var sibling_exactly_bounded = (try selector.unify(
        std.testing.allocator,
        sibling_left,
        sibling_right,
        .{
            .max_selectors = 5,
            .max_bytes = 53,
            .max_complex_components = 22,
            .max_temporary_bytes = 299,
            .max_relation_operations = 34,
        },
    )) orelse return error.TestUnexpectedResult;
    defer sibling_exactly_bounded.deinit();
    try expectItems(
        &.{
            ".a ~ .c ~ .b.d",
            ".c ~ .a ~ .b.d",
            ".a.c ~ .b.d",
        },
        sibling_exactly_bounded,
    );

    const rigid_left = ".p .a > .b .c";
    const rigid_right = ".q .d .b .e";
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            rigid_left,
            rigid_right,
            .{ .max_selectors = 3 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            rigid_left,
            rigid_right,
            .{ .max_bytes = 65 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            rigid_left,
            rigid_right,
            .{ .max_complex_components = 30 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            rigid_left,
            rigid_right,
            .{ .max_temporary_bytes = 483 },
        ),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.unify(
            std.testing.allocator,
            rigid_left,
            rigid_right,
            .{ .max_relation_operations = 90 },
        ),
    );
    var rigid_exactly_bounded = (try selector.unify(
        std.testing.allocator,
        rigid_left,
        rigid_right,
        .{
            .max_selectors = 4,
            .max_bytes = 66,
            .max_complex_components = 31,
            .max_temporary_bytes = 484,
            .max_relation_operations = 91,
        },
    )) orelse return error.TestUnexpectedResult;
    defer rigid_exactly_bounded.deinit();
    try expectItems(
        &.{
            ".p .q .d .a > .b .c.e",
            ".q .d .p .a > .b .c.e",
        },
        rigid_exactly_bounded,
    );
}

test "native Sass selector parser rejects malformed parents and complex compounds" {
    const invalid_parse = [_][]const u8{
        "",
        "   ",
        "&:hover",
        "a > > b",
        "???",
        ".foo(",
        "[data-x",
        "[=y]",
        "[x=123]",
        "[x=y ii]",
        "[x=y i ]",
        "[x=/* unterminated y]",
        ".foo\\",
    };
    for (invalid_parse) |input| {
        try std.testing.expectError(
            error.InvalidSelector,
            selector.parse(std.testing.allocator, input, .{}),
        );
    }

    const invalid_simple = [_][]const u8{
        "",
        "a b",
        "a, b",
        "a > b",
        "&:hover",
    };
    for (invalid_simple) |input| {
        try std.testing.expectError(
            error.InvalidSelector,
            selector.simpleSelectors(std.testing.allocator, input, .{}),
        );
    }

    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(std.testing.allocator, ".a, .b", .{ .max_selectors = 1 }),
    );
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        selector.parse(std.testing.allocator, ".abcd", .{ .max_bytes = 3 }),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try selector.parse(
        allocator,
        ".foo > .bar, [ data-x = \"a,b\" ]:not(.x, .y)",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.items.len);

    var escaped = try selector.parse(
        allocator,
        ".\\66 oo[\\78 =\"\\79 \"]",
        .{},
    );
    defer escaped.deinit();
    try expectItems(&.{".foo[x=y]"}, escaped);

    var pseudo = try selector.parse(
        allocator,
        ":\\68 over::\\62 efore",
        .{},
    );
    defer pseudo.deinit();
    try expectItems(&.{":hover::before"}, pseudo);

    var functional_pseudo = try selector.parse(
        allocator,
        ":not(:\\69 s(.\\61 , .b))",
        .{},
    );
    defer functional_pseudo.deinit();
    try expectItems(&.{":not(:is(.a, .b))"}, functional_pseudo);

    var simple = try selector.simpleSelectors(
        allocator,
        "a.foo#id:hover[title=\"x\"]",
        .{},
    );
    defer simple.deinit();
    try std.testing.expectEqual(@as(usize, 5), simple.items.len);

    var appended = try selector.append(
        allocator,
        &.{ ".a, .b", ".c, .d", ":hover" },
        .{},
    );
    defer appended.deinit();
    try std.testing.expectEqual(@as(usize, 4), appended.items.len);

    var nested = try selector.nest(
        allocator,
        &.{ ".a, .b", "& + &" },
        .{},
    );
    defer nested.deinit();
    try std.testing.expectEqual(@as(usize, 4), nested.items.len);

    try std.testing.expect(try selector.isSuperselector(
        allocator,
        ".a .b, [data-x='a b'] ~ .d",
        ".x .a > .b, [data-x=\"a b\"] + .d.extra",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        allocator,
        ".foo[x=y]",
        ".\\66 oo[\\78 =\\79 ]",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        allocator,
        ":hover",
        ":\\68 over.more",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        allocator,
        ":is(.a, .b)",
        ":\\69 s(.\\61 , .b).more",
        .{},
    ));
    try std.testing.expect(try selector.isSuperselector(
        allocator,
        ":is(.a .b, .c)",
        ":where(.x .a > .b)",
        .{},
    ));

    var unified = (try selector.unify(
        allocator,
        ".a > .b .c",
        ".d .b .e",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer unified.deinit();
    try expectItems(&.{".d .a > .b .c.e"}, unified);

    var escaped_unified = (try selector.unify(
        allocator,
        ".foo[x=y]",
        ".\\66 oo[\\78 =\\79 ]",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer escaped_unified.deinit();
    try expectItems(&.{".foo[x=y]"}, escaped_unified);

    var pseudo_unified = (try selector.unify(
        allocator,
        ":hover",
        ":\\68 over",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer pseudo_unified.deinit();
    try expectItems(&.{":hover"}, pseudo_unified);

    var functional_pseudo_unified = (try selector.unify(
        allocator,
        ":not(:is(.a, .b))",
        ":not(:\\69 s(.\\61 , .b))",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer functional_pseudo_unified.deinit();
    try expectItems(&.{":not(:is(.a, .b))"}, functional_pseudo_unified);

    var extended = try selector.extend(
        allocator,
        "[data-x=\"y\"].c [data-x=y].d",
        "[data-x='y']",
        ".b",
        .{},
    );
    defer extended.deinit();
    try expectItems(
        &.{
            "[data-x=y].c [data-x=y].d",
            ".c.b [data-x=y].d",
            "[data-x=y].c .d.b",
            ".c.b .d.b",
        },
        extended,
    );

    var escaped_extended = try selector.extend(
        allocator,
        ".\\66 oo[\\78 =\\79 ].c",
        ".foo[x=y]",
        ".bar",
        .{},
    );
    defer escaped_extended.deinit();
    try expectItems(&.{ ".foo[x=y].c", ".c.bar" }, escaped_extended);

    var pseudo_extended = try selector.extend(
        allocator,
        ".x:\\68 over",
        ":hover",
        ".y",
        .{},
    );
    defer pseudo_extended.deinit();
    try expectItems(&.{ ".x:hover", ".x.y" }, pseudo_extended);

    var replaced = try selector.replace(
        allocator,
        "[data-x=\"y\"].c [data-x=y].d",
        "[data-x='y']",
        ".b",
        .{},
    );
    defer replaced.deinit();
    try expectItems(&.{".c.b .d.b"}, replaced);

    var list_extended = try selector.extend(
        allocator,
        ".a.c .a",
        ".a, .c",
        ".x, .y",
        .{},
    );
    defer list_extended.deinit();
    try expectItems(
        &.{
            ".a.c .a",
            ".x .a",
            ".y .a",
            ".a.c .x",
            ".x .x",
            ".y .x",
            ".a.c .y",
            ".x .y",
            ".y .y",
        },
        list_extended,
    );

    var list_replaced = try selector.replace(
        allocator,
        ".a, .c",
        ".a, .c",
        ".b, .d",
        .{},
    );
    defer list_replaced.deinit();
    try expectItems(&.{ ".b", ".d", ".b" }, list_replaced);
}

test "native Sass selector parsing composition relations extension replacement and unification handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
