const std = @import("std");
const preprocessor = @import("native_preprocessor");
const arguments = preprocessor.sass_arguments;

test "native Sass arguments retain positional and keyword value ranges" {
    const body = "foo, $start_at: 2, $end-at: fn(a:b)";
    const first_comma = std.mem.indexOfScalar(u8, body, ',').?;
    const second_comma = first_comma + 1 +
        std.mem.indexOfScalar(u8, body[first_comma + 1 ..], ',').?;
    const ranges = [_]arguments.Range{
        .{ .start = 0, .end = first_comma },
        .{ .start = first_comma + 1, .end = second_comma },
        .{ .start = second_comma + 1, .end = body.len },
    };
    var parsed = try arguments.parseAlloc(std.testing.allocator, body, &ranges, 8);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.items[0].name);
    try std.testing.expect(!parsed.items[0].splat);
    try std.testing.expectEqualStrings("foo", body[parsed.items[0].value.start..parsed.items[0].value.end]);
    try std.testing.expectEqualStrings("start_at", parsed.items[1].name.?);
    try std.testing.expectEqualStrings("2", body[parsed.items[1].value.start..parsed.items[1].value.end]);
    try std.testing.expectEqualStrings("end-at", parsed.items[2].name.?);
    try std.testing.expectEqualStrings(
        "fn(a:b)",
        body[parsed.items[2].value.start..parsed.items[2].value.end],
    );
}

test "native Sass arguments retain bounded splat expression ranges" {
    const body = "$items..., (left: 1, right: 2)...";
    const comma = std.mem.indexOfScalar(u8, body, ',').?;
    const ranges = [_]arguments.Range{
        .{ .start = 0, .end = comma },
        .{ .start = comma + 1, .end = body.len },
    };
    var parsed = try arguments.parseAlloc(std.testing.allocator, body, &ranges, 8);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.items.len);
    try std.testing.expect(parsed.items[0].splat);
    try std.testing.expect(parsed.items[1].splat);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.items[0].name);
    try std.testing.expectEqualStrings(
        "$items",
        body[parsed.items[0].value.start..parsed.items[0].value.end],
    );
    try std.testing.expectEqualStrings(
        "(left: 1, right: 2)",
        body[parsed.items[1].value.start..parsed.items[1].value.end],
    );
}

test "native Sass arguments bind canonical names and optional parameters" {
    const body = "value, $end_at: -1";
    const comma = std.mem.indexOfScalar(u8, body, ',').?;
    const ranges = [_]arguments.Range{
        .{ .start = 0, .end = comma },
        .{ .start = comma + 1, .end = body.len },
    };
    var parsed = try arguments.parseAlloc(std.testing.allocator, body, &ranges, 8);
    defer parsed.deinit();
    const parameters = [_]arguments.Parameter{
        .{ .name = "string" },
        .{ .name = "start-at", .required = false },
        .{ .name = "end-at", .required = false },
    };
    var bound = try arguments.bindAlloc(
        std.testing.allocator,
        parsed.items,
        &parameters,
        parameters.len,
    );
    defer bound.deinit();
    try std.testing.expect(bound.values[0] != null);
    try std.testing.expect(bound.values[1] == null);
    try std.testing.expect(bound.values[2] != null);
    const end_range = bound.values[2].?;
    try std.testing.expectEqualStrings("-1", body[end_range.start..end_range.end]);
    try std.testing.expect(arguments.nameEql("start_at", "start-at"));
}

test "native Sass arguments bind an empty call to an empty parameter list" {
    var bound = try arguments.bindAlloc(std.testing.allocator, &.{}, &.{}, 0);
    defer bound.deinit();
    try std.testing.expectEqual(@as(usize, 0), bound.values.len);
}

test "native Sass arguments reject ambiguous and unsupported calls" {
    const duplicate_body = "$start-at: 1, $start_at: 2";
    const duplicate_comma = std.mem.indexOfScalar(u8, duplicate_body, ',').?;
    const duplicate_ranges = [_]arguments.Range{
        .{ .start = 0, .end = duplicate_comma },
        .{ .start = duplicate_comma + 1, .end = duplicate_body.len },
    };
    var duplicate = try arguments.parseAlloc(
        std.testing.allocator,
        duplicate_body,
        &duplicate_ranges,
        8,
    );
    defer duplicate.deinit();
    const parameters = [_]arguments.Parameter{
        .{ .name = "start-at", .required = false },
    };
    try std.testing.expectError(
        error.DuplicateArgument,
        arguments.bindAlloc(std.testing.allocator, duplicate.items, &parameters, 1),
    );

    const ordered_body = "$string: foo, 2";
    const ordered_comma = std.mem.indexOfScalar(u8, ordered_body, ',').?;
    const ordered_ranges = [_]arguments.Range{
        .{ .start = 0, .end = ordered_comma },
        .{ .start = ordered_comma + 1, .end = ordered_body.len },
    };
    try std.testing.expectError(
        error.PositionalAfterKeyword,
        arguments.parseAlloc(std.testing.allocator, ordered_body, &ordered_ranges, 8),
    );
    const splat_range = [_]arguments.Range{.{ .start = 0, .end = "$args...".len }};
    var splat = try arguments.parseAlloc(
        std.testing.allocator,
        "$args...",
        &splat_range,
        8,
    );
    defer splat.deinit();
    try std.testing.expectError(
        error.SplatUnsupported,
        arguments.bindAlloc(std.testing.allocator, splat.items, &parameters, 1),
    );
    const empty_splat_range = [_]arguments.Range{.{ .start = 0, .end = "...".len }};
    try std.testing.expectError(
        error.InvalidArgument,
        arguments.parseAlloc(std.testing.allocator, "...", &empty_splat_range, 8),
    );
    const positional = [_]arguments.Argument{.{
        .name = null,
        .value = .{ .start = 0, .end = 1 },
    }};
    try std.testing.expectError(
        error.PositionalLimitExceeded,
        arguments.bindAlloc(std.testing.allocator, &positional, &parameters, 0),
    );
    const unknown = [_]arguments.Argument{.{
        .name = "unknown",
        .value = .{ .start = 0, .end = 1 },
    }};
    try std.testing.expectError(
        error.UnknownArgument,
        arguments.bindAlloc(std.testing.allocator, &unknown, &parameters, 1),
    );
    const required = [_]arguments.Parameter{.{ .name = "required" }};
    try std.testing.expectError(
        error.MissingArgument,
        arguments.bindAlloc(std.testing.allocator, &.{}, &required, 1),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const body = "value, $end-at: -1";
    const comma = std.mem.indexOfScalar(u8, body, ',').?;
    const ranges = [_]arguments.Range{
        .{ .start = 0, .end = comma },
        .{ .start = comma + 1, .end = body.len },
    };
    var parsed = try arguments.parseAlloc(allocator, body, &ranges, 8);
    defer parsed.deinit();
    const parameters = [_]arguments.Parameter{
        .{ .name = "string" },
        .{ .name = "end-at", .required = false },
    };
    var bound = try arguments.bindAlloc(allocator, parsed.items, &parameters, 2);
    defer bound.deinit();
    try std.testing.expect(bound.values[0] != null);
    try std.testing.expect(bound.values[1] != null);

    const splat_body = "$args...";
    const splat_ranges = [_]arguments.Range{.{ .start = 0, .end = splat_body.len }};
    var splat = try arguments.parseAlloc(allocator, splat_body, &splat_ranges, 2);
    defer splat.deinit();
    try std.testing.expect(splat.items[0].splat);
}

test "native Sass argument binding handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
