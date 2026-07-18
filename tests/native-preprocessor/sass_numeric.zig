const std = @import("std");
const preprocessor = @import("native_preprocessor");
const numeric = preprocessor.sass_numeric;

fn unitNumber(value: f64, unit: []const u8) !numeric.Numeric {
    return numeric.Numeric.init(value, unit);
}

fn valueNumber(item: numeric.Numeric) !preprocessor.value.Number {
    var numerator: [numeric.max_unit_instances][]const u8 = undefined;
    var denominator: [numeric.max_unit_instances][]const u8 = undefined;
    return item.toNumber(&numerator, &denominator);
}

test "native Sass numeric algebra converts every absolute unit family" {
    const cases = [_]struct {
        left: numeric.Numeric,
        right: numeric.Numeric,
        expected: f64,
    }{
        .{ .left = try unitNumber(1, "in"), .right = try unitNumber(96, "px"), .expected = 2 },
        .{ .left = try unitNumber(1, "s"), .right = try unitNumber(500, "ms"), .expected = 1.5 },
        .{ .left = try unitNumber(1, "turn"), .right = try unitNumber(180, "deg"), .expected = 1.5 },
        .{ .left = try unitNumber(1, "khz"), .right = try unitNumber(500, "hz"), .expected = 1.5 },
        .{ .left = try unitNumber(1, "dppx"), .right = try unitNumber(96, "dpi"), .expected = 2 },
    };
    for (cases) |case| {
        const result = try numeric.add(case.left, case.right, '+');
        const output = try valueNumber(result);
        try std.testing.expectApproxEqRel(case.expected, output.value, 1e-12);
        try std.testing.expectEqual(@as(usize, 1), output.numerator_units.len);
        try std.testing.expectEqual(@as(usize, 0), output.denominator_units.len);
    }
}

test "native Sass numeric algebra cancels compatible compound units" {
    const ratio = try numeric.multiply(
        try unitNumber(1, "in"),
        try unitNumber(2.54, "cm"),
        '/',
    );
    try std.testing.expect(ratio.isDimensionless());
    try std.testing.expectApproxEqRel(@as(f64, 1), ratio.value, 1e-12);

    const time_ratio = try numeric.multiply(
        try unitNumber(1, "s"),
        try unitNumber(1_000, "ms"),
        '/',
    );
    const length = try numeric.multiply(try unitNumber(3, "px"), time_ratio, '*');
    const output = try valueNumber(length);
    try std.testing.expectApproxEqRel(@as(f64, 3), output.value, 1e-12);
    try std.testing.expectEqualStrings("px", output.numerator_units[0]);
}

test "native Sass numeric equality and ordering use canonical dimensions" {
    try std.testing.expect(numeric.equal(
        try unitNumber(1, "in"),
        try unitNumber(96, "px"),
    ));
    try std.testing.expect(numeric.equal(
        try unitNumber(1, "dppx"),
        try unitNumber(96, "dpi"),
    ));
    try std.testing.expect(!numeric.equal(
        try numeric.Numeric.init(1, null),
        try unitNumber(1, "px"),
    ));
    try std.testing.expectEqual(
        numeric.Ordering.greater,
        try numeric.compare(try unitNumber(1, "in"), try unitNumber(95, "px")),
    );
    try std.testing.expectEqual(
        numeric.Ordering.less,
        try numeric.compare(try numeric.Numeric.init(1, null), try unitNumber(2, "px")),
    );
    try std.testing.expect(numeric.equal(
        try numeric.Numeric.init(1, null),
        try numeric.Numeric.init(1 + 4e-12, null),
    ));
    try std.testing.expect(!numeric.equal(
        try numeric.Numeric.init(1, null),
        try numeric.Numeric.init(1 + 2e-11, null),
    ));
}

test "native Sass numeric compatibility matches unit addition domains" {
    const unitless = try numeric.Numeric.init(1, null);
    const pixels = try unitNumber(1, "px");
    try std.testing.expect(numeric.compatible(unitless, pixels));
    try std.testing.expect(numeric.compatible(pixels, try unitNumber(1, "in")));
    try std.testing.expect(!numeric.compatible(pixels, try unitNumber(1, "s")));
    try std.testing.expect(numeric.compatible(
        try unitNumber(1, "%"),
        try unitNumber(2, "%"),
    ));
    try std.testing.expect(!numeric.compatible(
        try unitNumber(1, "%"),
        pixels,
    ));
    try std.testing.expect(numeric.compatible(
        try unitNumber(1, "custom"),
        try unitNumber(2, "custom"),
    ));
    try std.testing.expect(!numeric.compatible(
        try unitNumber(1, "custom"),
        try unitNumber(2, "CUSTOM"),
    ));
    try std.testing.expect(!numeric.compatible(
        try unitNumber(1, "PX"),
        pixels,
    ));
    try std.testing.expectError(
        error.IncompatibleUnits,
        numeric.add(try unitNumber(1, "PX"), pixels, '+'),
    );
    const cased_ratio = try numeric.multiply(
        try unitNumber(1, "PX"),
        try unitNumber(1, "in"),
        '/',
    );
    try std.testing.expect(!cased_ratio.isDimensionless());
    const cased_output = try valueNumber(cased_ratio);
    try std.testing.expectEqualStrings("PX", cased_output.numerator_units[0]);
    try std.testing.expectEqualStrings("in", cased_output.denominator_units[0]);

    const left = try numeric.multiply(
        try unitNumber(1, "px"),
        try unitNumber(1, "s"),
        '*',
    );
    const right = try numeric.multiply(
        try unitNumber(2, "in"),
        try unitNumber(1, "ms"),
        '*',
    );
    try std.testing.expect(numeric.compatible(left, right));
}

test "native Sass numeric algebra rejects incompatible unsafe and oversized units" {
    try std.testing.expectError(
        error.IncompatibleUnits,
        numeric.add(try unitNumber(1, "px"), try unitNumber(1, "em"), '+'),
    );
    try std.testing.expectError(
        error.DivisionByZero,
        numeric.multiply(try unitNumber(1, "px"), try numeric.Numeric.init(0, null), '/'),
    );

    var units: [numeric.max_unit_terms + 1][]const u8 = undefined;
    var names: [numeric.max_unit_terms + 1][8]u8 = undefined;
    for (&units, &names, 0..) |*unit, *name, index| {
        unit.* = try std.fmt.bufPrint(name, "u{d}", .{index});
    }
    try std.testing.expectError(
        error.UnitLimitExceeded,
        numeric.Numeric.fromNumber(.{ .value = 1, .numerator_units = &units }),
    );
}

test "native Sass number serialization matches the ten-place contract" {
    const cases = [_]struct {
        value: f64,
        expected: []const u8,
    }{
        .{ .value = 1.0 / 3.0, .expected = ".3333333333" },
        .{ .value = -1.0 / 3.0, .expected = "-.3333333333" },
        .{ .value = 2.0 / 3.0, .expected = ".6666666667" },
        .{ .value = 1.0 / 7.0, .expected = ".1428571429" },
        .{ .value = 1.0 / 30_000_000_000.0, .expected = "0" },
        .{ .value = 123_456_789.0 / 7.0, .expected = "17636684.14285714" },
        .{ .value = 1.23456789012345, .expected = "1.2345678901" },
        .{ .value = -0.0, .expected = "0" },
    };
    for (cases) |case| {
        var buffer: [numeric.max_serialized_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try numeric.serialize(case.value, &buffer, true));
    }
    var expanded_buffer: [numeric.max_serialized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0.3333333333",
        try numeric.serialize(1.0 / 3.0, &expanded_buffer, false),
    );
}
