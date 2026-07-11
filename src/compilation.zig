const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const source = @import("source.zig");

/// Owns every source and diagnostic created for one compilation. AST and token
/// ownership will move under this boundary as their milestones land.
pub const Compilation = struct {
    allocator: std.mem.Allocator,
    sources: source.SourceManager,
    diagnostics: diagnostics.DiagnosticList,

    pub fn init(allocator: std.mem.Allocator) !Compilation {
        var sources = try source.SourceManager.init(allocator);
        errdefer sources.deinit();
        return .{
            .allocator = allocator,
            .sources = sources,
            .diagnostics = try diagnostics.DiagnosticList.init(allocator),
        };
    }

    pub fn deinit(self: *Compilation) void {
        self.diagnostics.deinit();
        self.sources.deinit();
    }

    pub fn addSource(self: *Compilation, name: []const u8, bytes: []const u8) !source.SourceId {
        return self.sources.add(name, bytes);
    }

    pub fn report(
        self: *Compilation,
        severity: diagnostics.Severity,
        code: diagnostics.Code,
        span: source.Span,
        message: []const u8,
    ) !void {
        const file = try self.sources.get(span.source);
        _ = try file.slice(span);
        try self.diagnostics.append(severity, code, span, message);
    }
};

test "compilation owns copied sources and validates diagnostic spans" {
    const allocator = std.testing.allocator;
    var compilation = try Compilation.init(allocator);
    defer compilation.deinit();

    var bytes = [_]u8{ '.', 'a', '{', '}' };
    const id = try compilation.addSource("input.css", &bytes);
    bytes[1] = 'x';

    const span = try source.Span.init(id, 1, 2);
    try compilation.report(.warning, .unexpected_token, span, "example warning");
    try std.testing.expectEqualStrings(".a{}", (try compilation.sources.get(id)).bytes);
    try std.testing.expectEqual(@as(usize, 1), compilation.diagnostics.items().len);

    const invalid = source.Span{ .source = id, .start = 0, .end = 100 };
    try std.testing.expectError(error.InvalidSpan, compilation.report(.err, .unexpected_eof, invalid, "invalid"));
    try std.testing.expectEqual(@as(usize, 1), compilation.diagnostics.items().len);
}
