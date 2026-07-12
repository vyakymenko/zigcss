const std = @import("std");
const generated = @import("generated_compat.zig");
const target_query = @import("target_query.zig");
const types = @import("compatibility_types.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidData,
    InvalidQuery,
    TooManyAlternatives,
    UnknownFeature,
};

pub const max_alternatives: usize = 16;

pub const Requirement = struct {
    allocator: std.mem.Allocator,
    alternatives: []const types.Form,
    partial: bool,
    annotated: bool,

    pub fn deinit(self: *Requirement) void {
        if (self.alternatives.len > 0) self.allocator.free(self.alternatives);
        self.alternatives = &.{};
    }
};

pub const UnsupportedTarget = struct {
    browser: target_query.Browser,
    minimum: target_query.Version,
    first_unsupported: target_query.Version,
};

pub const Resolution = union(enum) {
    supported: Requirement,
    unsupported: UnsupportedTarget,
};

pub fn sourceMetadata() *const types.SourceMetadata {
    return &generated.source;
}

pub fn allFeatures() []const types.Feature {
    return &generated.features;
}

pub fn findFeature(id: []const u8) ?*const types.Feature {
    for (&generated.features) |*feature| {
        if (std.mem.eql(u8, feature.id, id)) return feature;
    }
    return null;
}

/// Resolves the nonstandard forms required at each browser's explicit minimum
/// version. The standard form is always retained by PREFIX-002. A target below
/// every known form is reported as unsupported rather than guessed.
pub fn resolve(
    allocator: std.mem.Allocator,
    feature_id: []const u8,
    query: *const target_query.Query,
) Error!Resolution {
    if (!query.validate()) return error.InvalidQuery;
    const feature = findFeature(feature_id) orelse return error.UnknownFeature;
    return resolveFeature(allocator, feature, query);
}

fn resolveFeature(
    allocator: std.mem.Allocator,
    feature: *const types.Feature,
    query: *const target_query.Query,
) Error!Resolution {
    var alternatives: [max_alternatives]types.Form = undefined;
    var alternative_count: usize = 0;
    var any_partial = false;
    var any_annotated = false;

    for (query.targets) |target| {
        var cursor = target.minimum;
        var steps: usize = 0;
        while (true) {
            const statement = bestSupportAt(feature, target.browser, cursor) orelse {
                return .{ .unsupported = .{
                    .browser = target.browser,
                    .minimum = target.minimum,
                    .first_unsupported = cursor,
                } };
            };
            any_partial = any_partial or statement.partial;
            any_annotated = any_annotated or statement.annotated;
            if (statement.form.kind != .standard) {
                try appendUnique(&alternatives, &alternative_count, statement.form);
            }
            const removed = statement.removed orelse break;
            if (removed.order(cursor) != .gt) return error.InvalidData;
            cursor = removed;
            steps += 1;
            if (steps > feature.support.len) return error.InvalidData;
        }
    }

    const owned: []const types.Form = if (alternative_count == 0)
        &.{}
    else
        try allocator.dupe(types.Form, alternatives[0..alternative_count]);
    return .{ .supported = .{
        .allocator = allocator,
        .alternatives = owned,
        .partial = any_partial,
        .annotated = any_annotated,
    } };
}

test "compatibility resolution follows contiguous intervals and rejects later gaps" {
    var query = try parseTestQuery("chrome >= 7");
    defer query.deinit();

    const prefix = types.SupportStatement{
        .browser = .chrome,
        .added = .{ .major = 7 },
        .removed = .{ .major = 13 },
        .form = .{ .kind = .prefix, .value = "-example-" },
        .partial = false,
        .annotated = false,
    };
    const standard = types.SupportStatement{
        .browser = .chrome,
        .added = .{ .major = 13 },
        .removed = null,
        .form = .{ .kind = .standard, .value = "" },
        .partial = false,
        .annotated = false,
    };
    const contiguous_support = [_]types.SupportStatement{ prefix, standard };
    const contiguous_feature = types.Feature{
        .id = "property.synthetic",
        .kind = .property,
        .support = &contiguous_support,
    };
    var contiguous = try resolveFeature(std.testing.allocator, &contiguous_feature, &query);
    switch (contiguous) {
        .supported => |*requirement| {
            defer requirement.deinit();
            try std.testing.expectEqual(@as(usize, 1), requirement.alternatives.len);
            try std.testing.expectEqualStrings("-example-", requirement.alternatives[0].value);
        },
        .unsupported => return error.TestUnexpectedResult,
    }

    const gap_standard = types.SupportStatement{
        .browser = .chrome,
        .added = .{ .major = 14 },
        .removed = null,
        .form = .{ .kind = .standard, .value = "" },
        .partial = false,
        .annotated = false,
    };
    const gap_support = [_]types.SupportStatement{ prefix, gap_standard };
    const gap_feature = types.Feature{
        .id = "property.synthetic-gap",
        .kind = .property,
        .support = &gap_support,
    };
    const gap = try resolveFeature(std.testing.allocator, &gap_feature, &query);
    try std.testing.expectEqual(target_query.Version{ .major = 13 }, gap.unsupported.first_unsupported);
}

fn bestSupportAt(
    feature: *const types.Feature,
    browser: target_query.Browser,
    version: target_query.Version,
) ?types.SupportStatement {
    var best: ?types.SupportStatement = null;
    for (feature.support) |statement| {
        if (statement.browser != browser or !statement.includes(version)) continue;
        if (best == null or betterSupport(statement, best.?)) best = statement;
    }
    return best;
}

fn betterSupport(candidate: types.SupportStatement, current: types.SupportStatement) bool {
    if ((candidate.removed == null) != (current.removed == null)) return candidate.removed == null;
    if (candidate.removed) |candidate_removed| {
        const removed_order = candidate_removed.order(current.removed.?);
        if (removed_order != .eq) return removed_order == .gt;
    }
    if (candidate.partial != current.partial) return !candidate.partial;
    if (candidate.annotated != current.annotated) return !candidate.annotated;
    if ((candidate.form.kind == .standard) != (current.form.kind == .standard)) {
        return candidate.form.kind == .standard;
    }
    if (candidate.form.kind != current.form.kind) {
        return @intFromEnum(candidate.form.kind) < @intFromEnum(current.form.kind);
    }
    return std.mem.lessThan(u8, candidate.form.value, current.form.value);
}

fn appendUnique(
    output: *[max_alternatives]types.Form,
    length: *usize,
    value: types.Form,
) Error!void {
    for (output[0..length.*]) |existing| {
        if (existing.kind == value.kind and std.mem.eql(u8, existing.value, value.value)) return;
    }
    if (length.* == output.len) return error.TooManyAlternatives;
    output[length.*] = value;
    length.* += 1;
}

fn parseTestQuery(input: []const u8) !target_query.Query {
    const parsed = try target_query.parse(std.testing.allocator, input, .{});
    return switch (parsed) {
        .query => |query| query,
        .invalid => error.TestUnexpectedResult,
    };
}

test "compatibility resolution changes deterministically with explicit targets" {
    var modern = try parseTestQuery("chrome >= 120, safari >= 18");
    defer modern.deinit();
    var modern_resolution = try resolve(std.testing.allocator, "property.appearance", &modern);
    switch (modern_resolution) {
        .supported => |*requirement| {
            defer requirement.deinit();
            try std.testing.expectEqual(@as(usize, 0), requirement.alternatives.len);
            try std.testing.expect(!requirement.partial);
            try std.testing.expect(!requirement.annotated);
        },
        .unsupported => return error.TestUnexpectedResult,
    }

    var legacy = try parseTestQuery("safari >= 15.3");
    defer legacy.deinit();
    var legacy_resolution = try resolve(std.testing.allocator, "property.appearance", &legacy);
    switch (legacy_resolution) {
        .supported => |*requirement| {
            defer requirement.deinit();
            try std.testing.expectEqual(@as(usize, 1), requirement.alternatives.len);
            try std.testing.expectEqual(types.FormKind.prefix, requirement.alternatives[0].kind);
            try std.testing.expectEqualStrings("-webkit-", requirement.alternatives[0].value);
            try std.testing.expect(!requirement.annotated);
        },
        .unsupported => return error.TestUnexpectedResult,
    }
}

test "compatibility resolution unions forms and reports unsupported targets" {
    var query = try parseTestQuery("chrome >= 120, safari >= 17, ie >= 11");
    defer query.deinit();
    var resolution = try resolve(std.testing.allocator, "property.user-select", &query);
    switch (resolution) {
        .supported => |*requirement| {
            defer requirement.deinit();
            try std.testing.expectEqual(@as(usize, 2), requirement.alternatives.len);
            try std.testing.expectEqualStrings("-webkit-", requirement.alternatives[0].value);
            try std.testing.expectEqualStrings("-ms-", requirement.alternatives[1].value);
        },
        .unsupported => return error.TestUnexpectedResult,
    }

    var unsupported_query = try parseTestQuery("ie >= 11");
    defer unsupported_query.deinit();
    const unsupported = try resolve(
        std.testing.allocator,
        "property.backdrop-filter",
        &unsupported_query,
    );
    try std.testing.expectEqual(target_query.Browser.ie, unsupported.unsupported.browser);
}

test "compatibility resolution retains alternative names and partial support facts" {
    var safari = try parseTestQuery("safari >= 15");
    defer safari.deinit();
    var fullscreen = try resolve(std.testing.allocator, "selector.fullscreen", &safari);
    switch (fullscreen) {
        .supported => |*requirement| {
            defer requirement.deinit();
            try std.testing.expectEqual(@as(usize, 1), requirement.alternatives.len);
            try std.testing.expectEqual(types.FormKind.alternative_name, requirement.alternatives[0].kind);
            try std.testing.expectEqualStrings(":-webkit-full-screen", requirement.alternatives[0].value);
            try std.testing.expect(!requirement.partial);
        },
        .unsupported => return error.TestUnexpectedResult,
    }

    var ie = try parseTestQuery("ie >= 11");
    defer ie.deinit();
    var flex = try resolve(std.testing.allocator, "value.display.flex", &ie);
    switch (flex) {
        .supported => |*requirement| {
            defer requirement.deinit();
            try std.testing.expectEqual(@as(usize, 0), requirement.alternatives.len);
            try std.testing.expect(requirement.partial);
            try std.testing.expect(requirement.annotated);
        },
        .unsupported => return error.TestUnexpectedResult,
    }
}

test "generated compatibility table is sorted versioned and structurally closed" {
    const metadata = sourceMetadata();
    try std.testing.expectEqualStrings("@mdn/browser-compat-data", metadata.package);
    try std.testing.expectEqualStrings("8.0.0", metadata.version);
    try std.testing.expectEqual(@as(usize, 64), metadata.manifest_sha256.len);
    try std.testing.expectEqual(@as(usize, 64), metadata.selected_data_sha256.len);
    try std.testing.expect(allFeatures().len > 0);
    for (allFeatures(), 0..) |feature, index| {
        try std.testing.expect(feature.support.len > 0);
        if (index > 0) try std.testing.expect(std.mem.lessThan(
            u8,
            allFeatures()[index - 1].id,
            feature.id,
        ));
        for (feature.support) |statement| {
            try std.testing.expect(statement.added.major > 0);
            if (statement.removed) |removed| {
                try std.testing.expect(removed.order(statement.added) == .gt);
            }
            if (statement.annotated) {
                try std.testing.expect(statement.browser == .firefox or
                    statement.browser == .ios_safari or statement.browser == .ie);
            }
            if (statement.form.kind == .standard) {
                try std.testing.expectEqual(@as(usize, 0), statement.form.value.len);
            } else {
                try std.testing.expect(statement.form.value.len > 0);
            }
        }
    }
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const parsed = try target_query.parse(
        allocator,
        "chrome >= 120, safari >= 15, ie >= 11",
        .{},
    );
    var query = switch (parsed) {
        .query => |value| value,
        .invalid => return error.TestUnexpectedResult,
    };
    defer query.deinit();
    var resolution = try resolve(allocator, "property.user-select", &query);
    switch (resolution) {
        .supported => |*requirement| {
            defer requirement.deinit();
            try std.testing.expectEqual(@as(usize, 2), requirement.alternatives.len);
        },
        .unsupported => return error.TestUnexpectedResult,
    }
}

test "compatibility resolution handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "compatibility resolution rejects unknown features and forged queries" {
    var query = try parseTestQuery("chrome >= 120");
    defer query.deinit();
    try std.testing.expectError(
        error.UnknownFeature,
        resolve(std.testing.allocator, "property.unknown", &query),
    );
    const empty = target_query.Query{ .allocator = std.testing.allocator, .targets = &.{} };
    try std.testing.expectError(
        error.InvalidQuery,
        resolve(std.testing.allocator, "property.user-select", &empty),
    );

    var duplicate_targets = [_]target_query.Target{
        .{ .browser = .chrome, .minimum = .{ .major = 120 } },
        .{ .browser = .chrome, .minimum = .{ .major = 121 } },
    };
    const duplicate = target_query.Query{
        .allocator = std.testing.allocator,
        .targets = &duplicate_targets,
    };
    try std.testing.expectError(
        error.InvalidQuery,
        resolve(std.testing.allocator, "property.user-select", &duplicate),
    );
}
