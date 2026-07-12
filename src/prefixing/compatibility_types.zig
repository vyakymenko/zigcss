const target_query = @import("target_query.zig");

pub const FeatureKind = enum {
    property,
    value,
    selector,
    at_rule,
};

pub const FormKind = enum {
    standard,
    prefix,
    alternative_name,
};

pub const Form = struct {
    kind: FormKind,
    value: []const u8,
};

pub const SupportStatement = struct {
    browser: target_query.Browser,
    added: target_query.Version,
    removed: ?target_query.Version,
    form: Form,
    partial: bool,
    /// The pinned BCD statement carries one or more upstream notes. Note text
    /// is intentionally not interpreted into automatic rewrite authority.
    annotated: bool,

    pub fn includes(self: SupportStatement, version: target_query.Version) bool {
        if (!version.atLeast(self.added)) return false;
        if (self.removed) |removed| return version.order(removed) == .lt;
        return true;
    }
};

pub const Feature = struct {
    id: []const u8,
    kind: FeatureKind,
    support: []const SupportStatement,
};

pub const SourceMetadata = struct {
    package: []const u8,
    version: []const u8,
    git_commit: []const u8,
    released_at: []const u8,
    tarball_sha1: []const u8,
    tarball_integrity: []const u8,
    license: []const u8,
    repository: []const u8,
    manifest_sha256: []const u8,
    selected_data_sha256: []const u8,
};

test "support intervals use inclusive added and exclusive removed versions" {
    const statement = SupportStatement{
        .browser = .safari,
        .added = .{ .major = 7 },
        .removed = .{ .major = 13 },
        .form = .{ .kind = .prefix, .value = "-webkit-" },
        .partial = false,
        .annotated = false,
    };
    try @import("std").testing.expect(!statement.includes(.{ .major = 6, .minor = 1 }));
    try @import("std").testing.expect(statement.includes(.{ .major = 7 }));
    try @import("std").testing.expect(statement.includes(.{ .major = 12, .minor = 1 }));
    try @import("std").testing.expect(!statement.includes(.{ .major = 13 }));
}
