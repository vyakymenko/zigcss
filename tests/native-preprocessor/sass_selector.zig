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

test "native Sass selector parser retains escapes and forgiving empty segments" {
    var parsed = try selector.parse(std.testing.allocator, "a,,b,", .{});
    defer parsed.deinit();
    try expectItems(&.{ "a", "b" }, parsed);

    var escaped = try selector.parse(std.testing.allocator, ".\\31 23#\\66 oo", .{});
    defer escaped.deinit();
    try expectItems(&.{".\\31 23#\\66 oo"}, escaped);

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
        .{ .super_selector = ".foo", .sub_selector = ".\\66 oo" },
        .{ .super_selector = ":is(.a)", .sub_selector = ".a" },
        .{ .super_selector = "[x=y]", .sub_selector = "[x=\"y\"]" },
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

test "native Sass selector unification rejects unavailable semantics and limits" {
    try std.testing.expectError(
        error.InvalidSelector,
        selector.unify(std.testing.allocator, "&.a", ".b", .{}),
    );
    const unsupported = [_]struct {
        left: []const u8,
        right: []const u8,
    }{
        .{ .left = ".a .b", .right = ".c .d" },
        .{ .left = ".a ~ .b", .right = ".c ~ .d" },
        .{ .left = "> .a", .right = ".b" },
        .{ .left = ".a >", .right = ".b" },
        .{ .left = ".foo", .right = ".\\66 oo" },
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
        ".foo > .bar, [data-x=\"a,b\"]:not(.x, .y)",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.items.len);

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
        ".a .b, .c ~ .d",
        ".x .a > .b, .c + .d.extra",
        .{},
    ));

    var unified = (try selector.unify(
        allocator,
        ".a .b, .x > .y",
        ".c",
        .{},
    )) orelse return error.TestUnexpectedResult;
    defer unified.deinit();
    try expectItems(
        &.{ ".a .b.c", ".x > .y.c" },
        unified,
    );
}

test "native Sass selector parsing composition relations and unification handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
