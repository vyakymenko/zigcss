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
}

test "native Sass selector parser handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
