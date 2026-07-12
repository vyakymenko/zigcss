const std = @import("std");
const source = @import("source.zig");

pub const Severity = enum {
    err,
    warning,
    note,
};

pub const Code = enum {
    invalid_utf8,
    unexpected_eof,
    invalid_escape,
    unterminated_comment,
    unterminated_string,
    bad_url,
    unexpected_token,
    resource_limit,
    invalid_option,
    invalid_plugin,
    plugin_failed,
    internal,

    pub fn label(self: Code) []const u8 {
        return switch (self) {
            .invalid_utf8 => "CSS0001",
            .unexpected_eof => "CSS0002",
            .invalid_escape => "CSS0003",
            .unterminated_comment => "CSS0004",
            .unterminated_string => "CSS0005",
            .bad_url => "CSS0006",
            .unexpected_token => "CSS0007",
            .resource_limit => "CSS0008",
            .invalid_option => "API0001",
            .invalid_plugin => "API0002",
            .plugin_failed => "API0003",
            .internal => "CSS9999",
        };
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    span: source.Span,
    message: []const u8,
};

pub const DiagnosticList = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) !DiagnosticList {
        return .{
            .allocator = allocator,
            .entries = try std.ArrayList(Diagnostic).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *DiagnosticList) void {
        for (self.entries.items) |diagnostic| {
            self.allocator.free(diagnostic.message);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn append(
        self: *DiagnosticList,
        severity: Severity,
        code: Code,
        span: source.Span,
        message: []const u8,
    ) !void {
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        try self.entries.append(self.allocator, .{
            .severity = severity,
            .code = code,
            .span = span,
            .message = owned_message,
        });
    }

    pub fn items(self: *const DiagnosticList) []const Diagnostic {
        return self.entries.items;
    }

    pub fn truncate(self: *DiagnosticList, new_len: usize) void {
        std.debug.assert(new_len <= self.entries.items.len);
        for (self.entries.items[new_len..]) |diagnostic| {
            self.allocator.free(diagnostic.message);
        }
        self.entries.shrinkRetainingCapacity(new_len);
    }
};

test "diagnostic list owns messages and preserves structured fields" {
    const allocator = std.testing.allocator;
    var diagnostics = try DiagnosticList.init(allocator);
    defer diagnostics.deinit();

    var message = [_]u8{ 'b', 'a', 'd' };
    const span = source.Span{ .source = .{ .value = 3 }, .start = 4, .end = 5 };
    try diagnostics.append(.err, .invalid_escape, span, &message);
    message[0] = 'x';

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items().len);
    const diagnostic = diagnostics.items()[0];
    try std.testing.expectEqual(Severity.err, diagnostic.severity);
    try std.testing.expectEqual(Code.invalid_escape, diagnostic.code);
    try std.testing.expectEqualStrings("CSS0003", diagnostic.code.label());
    try std.testing.expectEqualStrings("bad", diagnostic.message);
    try std.testing.expectEqual(span, diagnostic.span);

    try diagnostics.append(.warning, .unexpected_token, span, "temporary");
    diagnostics.truncate(1);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items().len);
}
