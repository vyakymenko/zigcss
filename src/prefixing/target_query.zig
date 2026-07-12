const std = @import("std");

pub const Browser = enum(u8) {
    chrome,
    edge,
    firefox,
    safari,
    ios_safari,
    ie,

    pub fn name(self: Browser) []const u8 {
        return switch (self) {
            .chrome => "chrome",
            .edge => "edge",
            .firefox => "firefox",
            .safari => "safari",
            .ios_safari => "ios_safari",
            .ie => "ie",
        };
    }

    fn fromName(value: []const u8) ?Browser {
        inline for (std.meta.fields(Browser)) |field| {
            const browser: Browser = @enumFromInt(field.value);
            if (std.mem.eql(u8, value, browser.name())) return browser;
        }
        return null;
    }
};

pub const Version = struct {
    major: u16,
    minor: u16 = 0,
    patch: u16 = 0,

    pub fn order(left: Version, right: Version) std.math.Order {
        if (left.major != right.major) return std.math.order(left.major, right.major);
        if (left.minor != right.minor) return std.math.order(left.minor, right.minor);
        return std.math.order(left.patch, right.patch);
    }

    pub fn atLeast(self: Version, minimum: Version) bool {
        return self.order(minimum) != .lt;
    }
};

pub const Target = struct {
    browser: Browser,
    minimum: Version,
};

pub const Query = struct {
    allocator: std.mem.Allocator,
    targets: []Target,

    pub fn deinit(self: *Query) void {
        if (self.targets.len > 0) self.allocator.free(self.targets);
        self.targets = &.{};
    }

    pub fn minimum(self: *const Query, browser: Browser) ?Version {
        for (self.targets) |target| {
            if (target.browser == browser) return target.minimum;
        }
        return null;
    }

    /// Returns whether this query has the canonical shape produced by `parse`.
    /// Public callers can construct Zig structs directly, so consumers must not
    /// assume the parser established these invariants for them.
    pub fn validate(self: *const Query) bool {
        if (self.targets.len == 0 or self.targets.len > browser_count) return false;
        for (self.targets, 0..) |target, index| {
            if (@intFromEnum(target.browser) >= browser_count) return false;
            if (target.minimum.major == 0) return false;
            if (index > 0 and
                @intFromEnum(self.targets[index - 1].browser) >= @intFromEnum(target.browser))
            {
                return false;
            }
        }
        return true;
    }

    pub fn canonicalAlloc(
        self: *const Query,
        allocator: std.mem.Allocator,
    ) (std.mem.Allocator.Error || error{InvalidQuery})![]u8 {
        if (!self.validate()) return error.InvalidQuery;
        var output = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer output.deinit(allocator);
        for (self.targets, 0..) |target, index| {
            if (index > 0) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, target.browser.name());
            try output.appendSlice(allocator, " >= ");
            var buffer: [32]u8 = undefined;
            const version = if (target.minimum.patch != 0)
                std.fmt.bufPrint(
                    &buffer,
                    "{d}.{d}.{d}",
                    .{ target.minimum.major, target.minimum.minor, target.minimum.patch },
                ) catch unreachable
            else if (target.minimum.minor != 0)
                std.fmt.bufPrint(
                    &buffer,
                    "{d}.{d}",
                    .{ target.minimum.major, target.minimum.minor },
                ) catch unreachable
            else
                std.fmt.bufPrint(&buffer, "{d}", .{target.minimum.major}) catch unreachable;
            try output.appendSlice(allocator, version);
        }
        return output.toOwnedSlice(allocator);
    }
};

pub const FailureKind = enum {
    empty_query,
    query_too_long,
    too_many_targets,
    expected_browser,
    unknown_browser,
    expected_comparator,
    expected_version,
    invalid_version,
    duplicate_browser,
    unexpected_character,
};

pub const Failure = struct {
    kind: FailureKind,
    offset: usize,
};

pub const Result = union(enum) {
    query: Query,
    invalid: Failure,
};

pub const Options = struct {
    max_input_bytes: usize = 4096,
    max_targets: usize = browser_count,
};

const browser_count = std.meta.fields(Browser).len;

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
) std.mem.Allocator.Error!Result {
    if (input.len > options.max_input_bytes) {
        return .{ .invalid = .{ .kind = .query_too_long, .offset = options.max_input_bytes } };
    }
    var parser = Parser{ .input = input, .options = options };
    const parsed = parser.parse() orelse return .{ .invalid = parser.failure.? };
    const targets = try allocator.dupe(Target, parsed);
    return .{ .query = .{ .allocator = allocator, .targets = targets } };
}

const Parser = struct {
    input: []const u8,
    options: Options,
    index: usize = 0,
    targets: [browser_count]Target = undefined,
    target_count: usize = 0,
    seen: [browser_count]bool = .{false} ** browser_count,
    failure: ?Failure = null,

    fn parse(self: *Parser) ?[]const Target {
        self.skipWhitespace();
        if (self.index == self.input.len) return self.fail(.empty_query, self.index);

        while (true) {
            const browser_start = self.index;
            const browser_name = self.browserName() orelse return self.fail(.expected_browser, self.index);
            const browser = Browser.fromName(browser_name) orelse return self.fail(.unknown_browser, browser_start);
            self.skipWhitespace();
            if (!self.consume(">=")) return self.fail(.expected_comparator, self.index);
            self.skipWhitespace();
            const minimum_version = self.version() orelse return null;

            const browser_index = @intFromEnum(browser);
            if (self.seen[browser_index]) return self.fail(.duplicate_browser, browser_start);
            if (self.target_count >= self.options.max_targets or self.target_count == browser_count) {
                return self.fail(.too_many_targets, browser_start);
            }
            self.seen[browser_index] = true;
            self.targets[self.target_count] = .{ .browser = browser, .minimum = minimum_version };
            self.target_count += 1;

            self.skipWhitespace();
            if (self.index == self.input.len) break;
            if (self.input[self.index] != ',') return self.fail(.unexpected_character, self.index);
            self.index += 1;
            self.skipWhitespace();
            if (self.index == self.input.len) return self.fail(.expected_browser, self.index);
        }

        self.sortTargets();
        return self.targets[0..self.target_count];
    }

    fn browserName(self: *Parser) ?[]const u8 {
        const start = self.index;
        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            if ((byte >= 'a' and byte <= 'z') or byte == '_') {
                self.index += 1;
            } else break;
        }
        if (self.index == start) return null;
        return self.input[start..self.index];
    }

    fn version(self: *Parser) ?Version {
        const start = self.index;
        const major = self.component() orelse {
            if (self.failure == null) self.failure = .{ .kind = .expected_version, .offset = start };
            return null;
        };
        if (major == 0) {
            self.failure = .{ .kind = .invalid_version, .offset = start };
            return null;
        }
        var result = Version{ .major = major };
        if (self.index < self.input.len and self.input[self.index] == '.') {
            self.index += 1;
            result.minor = self.component() orelse {
                if (self.failure == null) self.failure = .{ .kind = .invalid_version, .offset = self.index };
                return null;
            };
            if (self.index < self.input.len and self.input[self.index] == '.') {
                self.index += 1;
                result.patch = self.component() orelse {
                    if (self.failure == null) self.failure = .{ .kind = .invalid_version, .offset = self.index };
                    return null;
                };
            }
        }
        if (self.index < self.input.len) {
            const byte = self.input[self.index];
            if (!isWhitespace(byte) and byte != ',') {
                self.failure = .{ .kind = .unexpected_character, .offset = self.index };
                return null;
            }
        }
        return result;
    }

    fn component(self: *Parser) ?u16 {
        const start = self.index;
        while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) {
            self.index += 1;
        }
        if (self.index == start) return null;
        if (self.index - start > 1 and self.input[start] == '0') {
            self.failure = .{ .kind = .invalid_version, .offset = start };
            return null;
        }
        return std.fmt.parseInt(u16, self.input[start..self.index], 10) catch {
            self.failure = .{ .kind = .invalid_version, .offset = start };
            return null;
        };
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.input.len and isWhitespace(self.input[self.index])) self.index += 1;
    }

    fn consume(self: *Parser, expected: []const u8) bool {
        if (!std.mem.startsWith(u8, self.input[self.index..], expected)) return false;
        self.index += expected.len;
        return true;
    }

    fn fail(self: *Parser, kind: FailureKind, offset: usize) ?[]const Target {
        self.failure = .{ .kind = kind, .offset = offset };
        return null;
    }

    fn sortTargets(self: *Parser) void {
        var index: usize = 1;
        while (index < self.target_count) : (index += 1) {
            const value = self.targets[index];
            var insertion = index;
            while (insertion > 0 and
                @intFromEnum(self.targets[insertion - 1].browser) > @intFromEnum(value.browser))
            {
                self.targets[insertion] = self.targets[insertion - 1];
                insertion -= 1;
            }
            self.targets[insertion] = value;
        }
    }
};

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

test "target query parses closed explicit minimum versions deterministically" {
    const result = try parse(
        std.testing.allocator,
        " safari >= 15.4 , chrome>=120, ie >= 11, ios_safari >= 17.2.1 ",
        .{},
    );
    var query = switch (result) {
        .query => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    defer query.deinit();
    try std.testing.expect(query.validate());
    try std.testing.expectEqual(@as(usize, 4), query.targets.len);
    try std.testing.expectEqual(Version{ .major = 120 }, query.minimum(.chrome).?);
    try std.testing.expectEqual(Version{ .major = 15, .minor = 4 }, query.minimum(.safari).?);
    try std.testing.expect(query.minimum(.firefox) == null);

    const canonical = try query.canonicalAlloc(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "chrome >= 120, safari >= 15.4, ios_safari >= 17.2.1, ie >= 11",
        canonical,
    );
}

test "target query validation rejects forged noncanonical values" {
    const empty = Query{ .allocator = std.testing.allocator, .targets = &.{} };
    try std.testing.expect(!empty.validate());

    var zero_major_targets = [_]Target{
        .{ .browser = .chrome, .minimum = .{ .major = 0 } },
    };
    const zero_major = Query{
        .allocator = std.testing.allocator,
        .targets = &zero_major_targets,
    };
    try std.testing.expect(!zero_major.validate());

    var duplicate_targets = [_]Target{
        .{ .browser = .chrome, .minimum = .{ .major = 120 } },
        .{ .browser = .chrome, .minimum = .{ .major = 121 } },
    };
    const duplicate = Query{
        .allocator = std.testing.allocator,
        .targets = &duplicate_targets,
    };
    try std.testing.expect(!duplicate.validate());

    var unsorted_targets = [_]Target{
        .{ .browser = .safari, .minimum = .{ .major = 17 } },
        .{ .browser = .chrome, .minimum = .{ .major = 120 } },
    };
    const unsorted = Query{
        .allocator = std.testing.allocator,
        .targets = &unsorted_targets,
    };
    try std.testing.expect(!unsorted.validate());
    try std.testing.expectError(
        error.InvalidQuery,
        unsorted.canonicalAlloc(std.testing.allocator),
    );
}

test "target query rejects ambiguous dynamic and malformed syntax with offsets" {
    const cases = [_]struct {
        input: []const u8,
        kind: FailureKind,
    }{
        .{ .input = "", .kind = .empty_query },
        .{ .input = "   ", .kind = .empty_query },
        .{ .input = "last 2 chrome versions", .kind = .unknown_browser },
        .{ .input = "> 1%", .kind = .expected_browser },
        .{ .input = "not dead", .kind = .unknown_browser },
        .{ .input = "opera >= 12", .kind = .unknown_browser },
        .{ .input = "Chrome >= 120", .kind = .expected_browser },
        .{ .input = "chrome 120", .kind = .expected_comparator },
        .{ .input = "chrome > 120", .kind = .expected_comparator },
        .{ .input = "chrome >=", .kind = .expected_version },
        .{ .input = "chrome >= 0", .kind = .invalid_version },
        .{ .input = "chrome >= 01", .kind = .invalid_version },
        .{ .input = "chrome >= 1.", .kind = .invalid_version },
        .{ .input = "chrome >= 1.2.3.4", .kind = .unexpected_character },
        .{ .input = "chrome >= 120; safari >= 17", .kind = .unexpected_character },
        .{ .input = "chrome >= 120,", .kind = .expected_browser },
        .{ .input = "chrome >= 120, chrome >= 121", .kind = .duplicate_browser },
    };
    for (cases) |case| {
        const result = try parse(std.testing.allocator, case.input, .{});
        switch (result) {
            .query => |value| {
                var query = value;
                query.deinit();
                return error.TestUnexpectedResult;
            },
            .invalid => |failure| try std.testing.expectEqual(case.kind, failure.kind),
        }
    }
}

test "target query enforces byte and target limits before allocation" {
    const too_long = try parse(
        std.testing.allocator,
        "chrome >= 120",
        .{ .max_input_bytes = 5 },
    );
    try std.testing.expectEqual(FailureKind.query_too_long, too_long.invalid.kind);
    const too_many = try parse(
        std.testing.allocator,
        "chrome >= 120, safari >= 17",
        .{ .max_targets = 1 },
    );
    try std.testing.expectEqual(FailureKind.too_many_targets, too_many.invalid.kind);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const result = try parse(
        allocator,
        "chrome >= 120, firefox >= 115, safari >= 17.2",
        .{},
    );
    var query = switch (result) {
        .query => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    defer query.deinit();
    const canonical = try query.canonicalAlloc(allocator);
    defer allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "chrome >= 120, firefox >= 115, safari >= 17.2",
        canonical,
    );
}

test "target query handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "target query rejects every one-byte input without crashing" {
    var byte: usize = 0;
    while (byte <= std.math.maxInt(u8)) : (byte += 1) {
        const input = [_]u8{@intCast(byte)};
        const result = try parse(std.testing.allocator, &input, .{});
        switch (result) {
            .invalid => {},
            .query => |value| {
                var query = value;
                query.deinit();
                return error.TestUnexpectedResult;
            },
        }
    }
}
