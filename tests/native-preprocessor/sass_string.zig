const std = @import("std");
const preprocessor = @import("native_preprocessor");
const string = preprocessor.sass_string;

test "native Sass strings decode quoted and unquoted escapes exactly" {
    const allocator = std.testing.allocator;
    const quoted = try string.decodeAlloc(allocator, "a\\62 c", true, 1024);
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("abc", quoted);

    const escaped_space = try string.decodeAlloc(allocator, "foo\\ bar", false, 1024);
    defer allocator.free(escaped_space);
    try std.testing.expectEqualStrings("foo\\ bar", escaped_space);
    try std.testing.expectEqual(@as(usize, 8), try string.length(
        allocator,
        "foo\\ bar",
        false,
        1024,
    ));
    try std.testing.expectEqual(@as(usize, 7), try string.length(
        allocator,
        "foo\\ bar",
        true,
        1024,
    ));

    const quoted_form = try string.reencodeAlloc(
        allocator,
        "foo\\ bar",
        false,
        true,
        1024,
    );
    defer allocator.free(quoted_form);
    try std.testing.expectEqualStrings("foo\\\\ bar", quoted_form);
    const unquoted_form = try string.reencodeAlloc(
        allocator,
        "foo\\ bar",
        true,
        false,
        1024,
    );
    defer allocator.free(unquoted_form);
    try std.testing.expectEqualStrings("foo bar", unquoted_form);
}

test "native Sass strings index and slice Unicode code points" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        @as(?usize, 2),
        try string.indexOf(allocator, "a💚b", true, "💚", true, 1024),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        try string.indexOf(allocator, "abc", true, "", true, 1024),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        try string.indexOf(allocator, "abc", true, "z", true, 1024),
    );

    const middle = try string.sliceAlloc(allocator, "a💚b", true, 2, 2, 1024);
    defer allocator.free(middle);
    try std.testing.expectEqualStrings("💚", middle);
    const suffix = try string.sliceAlloc(allocator, "hello", true, -2, -1, 1024);
    defer allocator.free(suffix);
    try std.testing.expectEqualStrings("lo", suffix);
    const clamped = try string.sliceAlloc(allocator, "hello", true, -20, 20, 1024);
    defer allocator.free(clamped);
    try std.testing.expectEqualStrings("hello", clamped);
    const empty = try string.sliceAlloc(allocator, "hello", true, 3, 1, 1024);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const raw_escape = try string.sliceAlloc(allocator, "foo\\ bar", false, 4, 4, 1024);
    defer allocator.free(raw_escape);
    try std.testing.expectEqualStrings("\\", raw_escape);
}

test "native Sass strings insert with clamped indexes and fold ASCII only" {
    const allocator = std.testing.allocator;
    const appended = try string.insertAlloc(
        allocator,
        "a💚b",
        true,
        "🌍",
        true,
        -1,
        1024,
    );
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("a💚b🌍", appended);
    const middle = try string.insertAlloc(allocator, "abcd", true, "X", true, -2, 1024);
    defer allocator.free(middle);
    try std.testing.expectEqualStrings("abcXd", middle);
    const prepended = try string.insertAlloc(allocator, "abcd", true, "X", true, -20, 1024);
    defer allocator.free(prepended);
    try std.testing.expectEqualStrings("Xabcd", prepended);

    const upper = try string.changeCaseAlloc(
        allocator,
        "Abc-é-ß-ı-i",
        true,
        .upper,
        1024,
    );
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("ABC-é-ß-ı-I", upper);
    const lower = try string.changeCaseAlloc(
        allocator,
        "AbC-É-ẞ-I",
        true,
        .lower,
        1024,
    );
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("abc-É-ẞ-i", lower);
}

test "native Sass strings split decoded values into bounded bracket items" {
    const allocator = std.testing.allocator;
    var quoted = try string.splitAlloc(
        allocator,
        "a💚b💚c",
        true,
        "💚",
        true,
        null,
        1024,
    );
    defer quoted.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), quoted.items.len);
    try std.testing.expectEqualStrings("a", quoted.items[0]);
    try std.testing.expectEqualStrings("b", quoted.items[1]);
    try std.testing.expectEqualStrings("c", quoted.items[2]);

    var limited = try string.splitAlloc(
        allocator,
        "a-b-c",
        true,
        "-",
        true,
        1,
        1024,
    );
    defer limited.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), limited.items.len);
    try std.testing.expectEqualStrings("a", limited.items[0]);
    try std.testing.expectEqualStrings("b-c", limited.items[1]);

    var scalars = try string.splitAlloc(
        allocator,
        "a💚b",
        true,
        "",
        true,
        1,
        1024,
    );
    defer scalars.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), scalars.items.len);
    try std.testing.expectEqualStrings("a", scalars.items[0]);
    try std.testing.expectEqualStrings("💚", scalars.items[1]);
    try std.testing.expectEqualStrings("b", scalars.items[2]);

    var empty = try string.splitAlloc(
        allocator,
        "",
        true,
        "-",
        true,
        null,
        1024,
    );
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "native Sass strings fail closed on malformed data and output ceilings" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidString,
        string.decodeAlloc(allocator, "trailing\\", true, 1024),
    );
    try std.testing.expectError(
        error.InvalidString,
        string.decodeAlloc(allocator, &.{0xff}, true, 1024),
    );
    try std.testing.expectError(
        error.InvalidString,
        string.decodeAlloc(allocator, &.{ '\\', 0 }, false, 1024),
    );
    try std.testing.expectError(
        error.OutputLimitExceeded,
        string.insertAlloc(allocator, "abcd", true, "efgh", true, 1, 7),
    );
    try std.testing.expectError(
        error.OutputLimitExceeded,
        string.reencodeAlloc(allocator, "\\", false, true, 1),
    );
    try std.testing.expectError(
        error.OutputLimitExceeded,
        string.splitAlloc(allocator, "a-b-c-d", true, "-", true, null, 48),
    );
}
