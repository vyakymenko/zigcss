//! Allocation-free bounded number and unit algebra for the private native Sass
//! evaluator. Unit spelling is retained for emission while compatibility and
//! conversion use canonical physical dimensions.

const std = @import("std");
const native_value = @import("value.zig");

pub const max_unit_terms = 16;
pub const max_unit_instances = 64;
pub const max_serialized_bytes = 512;

pub const Error = error{
    DivisionByZero,
    IncompatibleUnits,
    InvalidNumber,
    SerializationLimitExceeded,
    UnitLimitExceeded,
};

pub const Ordering = enum {
    less,
    equal,
    greater,
};

const Dimension = enum {
    length,
    angle,
    time,
    frequency,
    resolution,
};

const Definition = struct {
    name: []const u8,
    dimension: Dimension,
    factor: f64,
};

const definitions = [_]Definition{
    .{ .name = "px", .dimension = .length, .factor = 1 },
    .{ .name = "in", .dimension = .length, .factor = 96 },
    .{ .name = "cm", .dimension = .length, .factor = 96.0 / 2.54 },
    .{ .name = "mm", .dimension = .length, .factor = 96.0 / 25.4 },
    .{ .name = "q", .dimension = .length, .factor = 96.0 / 101.6 },
    .{ .name = "pt", .dimension = .length, .factor = 96.0 / 72.0 },
    .{ .name = "pc", .dimension = .length, .factor = 16 },
    .{ .name = "deg", .dimension = .angle, .factor = 1 },
    .{ .name = "grad", .dimension = .angle, .factor = 0.9 },
    .{ .name = "rad", .dimension = .angle, .factor = 180.0 / std.math.pi },
    .{ .name = "turn", .dimension = .angle, .factor = 360 },
    .{ .name = "s", .dimension = .time, .factor = 1 },
    .{ .name = "ms", .dimension = .time, .factor = 0.001 },
    .{ .name = "hz", .dimension = .frequency, .factor = 1 },
    .{ .name = "khz", .dimension = .frequency, .factor = 1_000 },
    .{ .name = "dpi", .dimension = .resolution, .factor = 1 },
    .{ .name = "dpcm", .dimension = .resolution, .factor = 2.54 },
    .{ .name = "dppx", .dimension = .resolution, .factor = 96 },
    .{ .name = "x", .dimension = .resolution, .factor = 96 },
};

const Term = struct {
    unit: []const u8,
    power: i8,
};

pub const Numeric = struct {
    value: f64,
    terms: [max_unit_terms]Term = undefined,
    terms_len: u8 = 0,

    pub fn init(value: f64, unit: ?[]const u8) Error!Numeric {
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        var result = Numeric{ .value = canonicalZero(value) };
        if (unit) |name| try result.mergeTerm(name, 1);
        return result;
    }

    pub fn fromNumber(number: native_value.Number) Error!Numeric {
        var result = try Numeric.init(number.value, null);
        for (number.numerator_units) |unit| try result.mergeTerm(unit, 1);
        for (number.denominator_units) |unit| try result.mergeTerm(unit, -1);
        return result;
    }

    pub fn toNumber(
        self: Numeric,
        numerator: *[max_unit_instances][]const u8,
        denominator: *[max_unit_instances][]const u8,
    ) Error!native_value.Number {
        var numerator_len: usize = 0;
        var denominator_len: usize = 0;
        for (self.activeTerms()) |term| {
            const count: usize = @intCast(@abs(term.power));
            if (term.power > 0) {
                if (numerator_len + count > numerator.len) return error.UnitLimitExceeded;
                for (0..count) |_| {
                    numerator[numerator_len] = term.unit;
                    numerator_len += 1;
                }
            } else {
                if (denominator_len + count > denominator.len) return error.UnitLimitExceeded;
                for (0..count) |_| {
                    denominator[denominator_len] = term.unit;
                    denominator_len += 1;
                }
            }
        }
        return .{
            .value = canonicalZero(self.value),
            .numerator_units = numerator[0..numerator_len],
            .denominator_units = denominator[0..denominator_len],
        };
    }

    pub fn isDimensionless(self: Numeric) bool {
        return self.terms_len == 0;
    }

    pub fn isCssNumber(self: Numeric) bool {
        return self.terms_len == 0 or
            (self.terms_len == 1 and self.terms[0].power == 1);
    }

    fn activeTerms(self: *const Numeric) []const Term {
        return self.terms[0..self.terms_len];
    }

    fn mergeTerm(self: *Numeric, unit: []const u8, power: i8) Error!void {
        if (unit.len == 0 or power == 0) return error.InvalidNumber;
        for (self.terms[0..self.terms_len], 0..) |term, index| {
            if (!std.mem.eql(u8, term.unit, unit)) continue;
            const next = std.math.add(i8, term.power, power) catch
                return error.UnitLimitExceeded;
            if (next == 0) {
                self.removeTerm(index);
            } else {
                self.terms[index].power = next;
            }
            try self.validateInstanceCount();
            return;
        }
        if (self.terms_len >= max_unit_terms) return error.UnitLimitExceeded;
        self.terms[self.terms_len] = .{ .unit = unit, .power = power };
        self.terms_len += 1;
        try self.validateInstanceCount();
    }

    fn validateInstanceCount(self: *const Numeric) Error!void {
        var count: usize = 0;
        for (self.activeTerms()) |term| {
            count = std.math.add(usize, count, @intCast(@abs(term.power))) catch
                return error.UnitLimitExceeded;
        }
        if (count > max_unit_instances) return error.UnitLimitExceeded;
    }

    fn removeTerm(self: *Numeric, index: usize) void {
        var cursor = index;
        while (cursor + 1 < self.terms_len) : (cursor += 1) {
            self.terms[cursor] = self.terms[cursor + 1];
        }
        self.terms_len -= 1;
    }
};

pub fn add(left: Numeric, right: Numeric, operation: u8) Error!Numeric {
    var result = if (left.isDimensionless() and !right.isDimensionless()) right else left;
    if (left.isDimensionless() or right.isDimensionless()) {
        result.value = if (operation == '+') left.value + right.value else left.value - right.value;
    } else {
        if (!dimensionsEqual(left, right)) return error.IncompatibleUnits;
        const base = if (operation == '+') baseValue(left) + baseValue(right) else baseValue(left) - baseValue(right);
        result.value = base / unitScale(result);
    }
    if (!std.math.isFinite(result.value)) return error.InvalidNumber;
    result.value = canonicalZero(result.value);
    return result;
}

pub fn multiply(left: Numeric, right: Numeric, operation: u8) Error!Numeric {
    if (operation == '/' and right.value == 0) return error.DivisionByZero;
    var result = left;
    result.value = if (operation == '*') left.value * right.value else left.value / right.value;
    if (!std.math.isFinite(result.value)) return error.InvalidNumber;
    for (right.activeTerms()) |term| {
        try result.mergeTerm(term.unit, if (operation == '*') term.power else -term.power);
    }
    try simplifyUnits(&result);
    result.value = canonicalZero(result.value);
    return result;
}

pub fn modulo(left: Numeric, right: Numeric) Error!Numeric {
    if (right.value == 0) return error.DivisionByZero;
    var result = if (left.isDimensionless() and !right.isDimensionless()) right else left;
    var right_value = right.value;
    if (!left.isDimensionless() and !right.isDimensionless()) {
        if (!dimensionsEqual(left, right)) return error.IncompatibleUnits;
        right_value = baseValue(right) / unitScale(left);
    }
    result.value = @mod(left.value, right_value);
    if (!std.math.isFinite(result.value)) return error.InvalidNumber;
    result.value = canonicalZero(result.value);
    return result;
}

pub fn equal(left: Numeric, right: Numeric) bool {
    if (left.isDimensionless() != right.isDimensionless()) return false;
    if (left.isDimensionless()) return left.value == right.value;
    if (!dimensionsEqual(left, right)) return false;
    return approximatelyEqual(baseValue(left), baseValue(right));
}

pub fn compare(left: Numeric, right: Numeric) Error!Ordering {
    const values = if (left.isDimensionless() or right.isDimensionless())
        .{ left.value, right.value }
    else blk: {
        if (!dimensionsEqual(left, right)) return error.IncompatibleUnits;
        break :blk .{ baseValue(left), baseValue(right) };
    };
    const left_value = values[0];
    const right_value = values[1];
    if (approximatelyEqual(left_value, right_value)) return .equal;
    return if (left_value < right_value) .less else .greater;
}

/// Matches Dart Sass's non-inspect number precision: shortest decimal values
/// longer than eleven bytes are rounded to at most ten fractional digits.
pub fn serialize(
    value: f64,
    buffer: *[max_serialized_bytes]u8,
    minified: bool,
) Error![]const u8 {
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    const normalized = canonicalZero(value);
    const raw = std.fmt.bufPrint(buffer, "{d}", .{normalized}) catch
        return error.SerializationLimitExceeded;
    if (raw.len < 12) return finishSerialization(buffer, raw, minified);
    const decimal = std.mem.indexOfScalar(u8, raw, '.') orelse
        return finishSerialization(buffer, raw, minified);
    if (raw.len - decimal - 1 <= 10) return finishSerialization(buffer, raw, minified);

    const scaled = normalized * 1e10;
    if (!std.math.isFinite(scaled)) return finishSerialization(buffer, raw, minified);
    const rounded = @round(scaled) / 1e10;
    const formatted = std.fmt.bufPrint(buffer, "{d}", .{canonicalZero(rounded)}) catch
        return error.SerializationLimitExceeded;
    return finishSerialization(buffer, formatted, minified);
}

fn finishSerialization(
    buffer: *[max_serialized_bytes]u8,
    formatted: []const u8,
    minified: bool,
) []const u8 {
    if (!minified) return formatted;
    if (std.mem.startsWith(u8, formatted, "0.")) return formatted[1..];
    if (std.mem.startsWith(u8, formatted, "-0.")) {
        std.mem.copyForwards(u8, buffer[1 .. formatted.len - 1], buffer[2..formatted.len]);
        return buffer[0 .. formatted.len - 1];
    }
    return formatted;
}

fn simplifyUnits(number: *Numeric) Error!void {
    var numerator_index: usize = 0;
    while (numerator_index < number.terms_len) {
        if (number.terms[numerator_index].power <= 0) {
            numerator_index += 1;
            continue;
        }
        var denominator_index: usize = 0;
        while (denominator_index < number.terms_len and
            number.terms[numerator_index].power > 0)
        {
            if (number.terms[denominator_index].power >= 0 or
                !unitsCompatible(number.terms[numerator_index].unit, number.terms[denominator_index].unit))
            {
                denominator_index += 1;
                continue;
            }
            const cancelled = @min(
                number.terms[numerator_index].power,
                -number.terms[denominator_index].power,
            );
            const ratio = unitFactor(number.terms[numerator_index].unit) /
                unitFactor(number.terms[denominator_index].unit);
            number.value *= integerPower(ratio, cancelled);
            number.terms[numerator_index].power -= cancelled;
            number.terms[denominator_index].power += cancelled;
            if (!std.math.isFinite(number.value)) return error.InvalidNumber;
            if (number.terms[denominator_index].power == 0) {
                number.removeTerm(denominator_index);
                if (denominator_index < numerator_index) numerator_index -= 1;
            } else {
                denominator_index += 1;
            }
        }
        if (numerator_index < number.terms_len and number.terms[numerator_index].power == 0) {
            number.removeTerm(numerator_index);
        } else {
            numerator_index += 1;
        }
    }
    try number.validateInstanceCount();
}

fn dimensionsEqual(left: Numeric, right: Numeric) bool {
    for (left.activeTerms()) |term| {
        if (dimensionPower(left, term.unit) != dimensionPower(right, term.unit)) return false;
    }
    for (right.activeTerms()) |term| {
        if (dimensionPower(left, term.unit) != dimensionPower(right, term.unit)) return false;
    }
    return true;
}

fn dimensionPower(number: Numeric, unit: []const u8) i16 {
    var result: i16 = 0;
    for (number.activeTerms()) |term| {
        if (unitsCompatible(unit, term.unit)) result += term.power;
    }
    return result;
}

fn unitsCompatible(left: []const u8, right: []const u8) bool {
    const left_definition = unitDefinition(left);
    const right_definition = unitDefinition(right);
    if (left_definition) |known_left| {
        if (right_definition) |known_right| return known_left.dimension == known_right.dimension;
        return false;
    }
    return right_definition == null and std.mem.eql(u8, left, right);
}

fn unitScale(number: Numeric) f64 {
    var result: f64 = 1;
    for (number.activeTerms()) |term| result *= integerPower(unitFactor(term.unit), term.power);
    return result;
}

fn baseValue(number: Numeric) f64 {
    return number.value * unitScale(number);
}

fn unitFactor(unit: []const u8) f64 {
    return if (unitDefinition(unit)) |definition| definition.factor else 1;
}

fn unitDefinition(unit: []const u8) ?Definition {
    for (definitions) |definition| {
        if (std.ascii.eqlIgnoreCase(unit, definition.name)) return definition;
    }
    return null;
}

fn integerPower(base: f64, power: i8) f64 {
    var result: f64 = 1;
    const count: usize = @intCast(@abs(power));
    for (0..count) |_| result *= base;
    return if (power < 0) 1 / result else result;
}

fn approximatelyEqual(left: f64, right: f64) bool {
    if (left == right) return true;
    if (@abs(left - right) > 1e-11) return false;
    return @round(left * 1e11) == @round(right * 1e11);
}

fn canonicalZero(value: f64) f64 {
    if (value == 0) return 0;
    const integer = @round(value);
    if (approximatelyEqual(value, integer)) return integer;
    return value;
}
