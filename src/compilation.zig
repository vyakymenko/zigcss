const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const source = @import("source.zig");

/// Owns every source, diagnostic, token, syntax node, and temporary allocation
/// created for one compilation. The arena control block is heap-stable so this
/// value can be returned or moved without invalidating allocators stored by its
/// child containers.
pub const Compilation = struct {
    backing_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    sources: source.SourceManager,
    diagnostics: diagnostics.DiagnosticList,

    pub fn init(backing_allocator: std.mem.Allocator) !Compilation {
        const arena = try backing_allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer {
            arena.deinit();
            backing_allocator.destroy(arena);
        }

        const arena_allocator = arena.allocator();
        var sources = try source.SourceManager.init(arena_allocator);
        errdefer sources.deinit();
        return .{
            .backing_allocator = backing_allocator,
            .arena = arena,
            .sources = sources,
            .diagnostics = try diagnostics.DiagnosticList.init(arena_allocator),
        };
    }

    pub fn deinit(self: *Compilation) void {
        self.diagnostics.deinit();
        self.sources.deinit();
        self.arena.deinit();
        self.backing_allocator.destroy(self.arena);
        self.* = undefined;
    }

    /// Returns compilation-scoped storage. Any allocation made through this
    /// allocator becomes invalid when `deinit` is called and must not escape in
    /// a public result.
    pub fn arenaAllocator(self: *Compilation) std.mem.Allocator {
        return self.arena.allocator();
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

/// Result data owns buffers independently of a `Compilation`: `init` clones
/// borrowed input while `initOwned` consumes emitter-owned buffers. It is
/// move-only by convention; `take` provides an explicitly emptied moved-from
/// state and `deinit` is the only public cleanup path.
pub const CompileResult = struct {
    result_allocator: std.mem.Allocator,
    css: []const u8,
    source_map: ?[]const u8,
    diagnostics: []const diagnostics.Diagnostic,

    pub fn init(
        result_allocator: std.mem.Allocator,
        css: []const u8,
        source_map: ?[]const u8,
        diagnostic_items: []const diagnostics.Diagnostic,
    ) !CompileResult {
        const owned_css = try result_allocator.dupe(u8, css);
        errdefer if (owned_css.len > 0) result_allocator.free(owned_css);

        var owned_source_map: ?[]const u8 = null;
        if (source_map) |bytes| {
            owned_source_map = try result_allocator.dupe(u8, bytes);
        }
        errdefer if (owned_source_map) |bytes| {
            if (bytes.len > 0) result_allocator.free(bytes);
        };

        const owned_diagnostics = try cloneDiagnostics(result_allocator, diagnostic_items);
        errdefer releaseDiagnostics(result_allocator, owned_diagnostics);

        return .{
            .result_allocator = result_allocator,
            .css = owned_css,
            .source_map = owned_source_map,
            .diagnostics = owned_diagnostics,
        };
    }

    /// Consumes already-owned emitter buffers and clones only diagnostics.
    /// On either success or error, the caller has surrendered both buffers.
    pub fn initOwned(
        result_allocator: std.mem.Allocator,
        owned_css: []u8,
        owned_source_map: ?[]u8,
        diagnostic_items: []const diagnostics.Diagnostic,
    ) !CompileResult {
        errdefer if (owned_css.len > 0) result_allocator.free(owned_css);
        errdefer if (owned_source_map) |bytes| {
            if (bytes.len > 0) result_allocator.free(bytes);
        };

        const owned_diagnostics = try cloneDiagnostics(result_allocator, diagnostic_items);
        errdefer releaseDiagnostics(result_allocator, owned_diagnostics);

        return .{
            .result_allocator = result_allocator,
            .css = owned_css,
            .source_map = owned_source_map,
            .diagnostics = owned_diagnostics,
        };
    }

    pub fn take(self: *CompileResult) CompileResult {
        const moved = self.*;
        self.* = empty(self.result_allocator);
        return moved;
    }

    pub fn deinit(self: *CompileResult) void {
        const result_allocator = self.result_allocator;
        if (self.css.len > 0) result_allocator.free(self.css);
        if (self.source_map) |bytes| {
            if (bytes.len > 0) result_allocator.free(bytes);
        }
        releaseDiagnostics(result_allocator, self.diagnostics);
        self.* = empty(result_allocator);
    }

    fn empty(result_allocator: std.mem.Allocator) CompileResult {
        return .{
            .result_allocator = result_allocator,
            .css = &.{},
            .source_map = null,
            .diagnostics = &.{},
        };
    }

    fn cloneDiagnostics(
        allocator: std.mem.Allocator,
        items: []const diagnostics.Diagnostic,
    ) ![]diagnostics.Diagnostic {
        if (items.len == 0) return &.{};
        const cloned = try allocator.alloc(diagnostics.Diagnostic, items.len);
        errdefer allocator.free(cloned);
        var initialized: usize = 0;
        errdefer for (cloned[0..initialized]) |diagnostic| {
            if (diagnostic.message.len > 0) allocator.free(diagnostic.message);
        };

        for (items, 0..) |diagnostic, index| {
            const message = try allocator.dupe(u8, diagnostic.message);
            cloned[index] = diagnostic;
            cloned[index].message = message;
            initialized += 1;
        }
        return cloned;
    }

    fn releaseDiagnostics(allocator: std.mem.Allocator, items: []const diagnostics.Diagnostic) void {
        if (items.len == 0) return;
        for (items) |diagnostic| {
            if (diagnostic.message.len > 0) allocator.free(diagnostic.message);
        }
        allocator.free(items);
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

test "compilation arena owns temporary allocations across a struct move" {
    const allocator = std.testing.allocator;
    var original = try Compilation.init(allocator);
    var compilation = original;
    original = undefined;
    defer compilation.deinit();

    const temporary = try compilation.arenaAllocator().alloc(u8, 4096);
    @memset(temporary, 0xaa);
    const id = try compilation.addSource("moved.css", ".moved{}");
    try compilation.report(.note, .unexpected_token, try source.Span.init(id, 0, 1), "arena owned");
    try std.testing.expectEqual(@as(usize, 4096), temporary.len);
    try std.testing.expectEqualStrings(".moved{}", (try compilation.sources.get(id)).bytes);
}

test "compile result deeply outlives compilation and supports explicit moves" {
    const allocator = std.testing.allocator;
    var compilation = try Compilation.init(allocator);
    const id = try compilation.addSource("result.css", ".a{}");
    try compilation.report(.warning, .unexpected_token, try source.Span.init(id, 1, 2), "owned warning");

    var css = [_]u8{ '.', 'a', '{', '}' };
    var source_map = [_]u8{ '{', '}' };
    var original = try CompileResult.init(allocator, &css, &source_map, compilation.diagnostics.items());
    css[1] = 'x';
    source_map[0] = '[';
    compilation.deinit();

    var moved = original.take();
    defer moved.deinit();
    original.deinit();
    try std.testing.expectEqualStrings(".a{}", moved.css);
    try std.testing.expectEqualStrings("{}", moved.source_map.?);
    try std.testing.expectEqual(@as(usize, 1), moved.diagnostics.len);
    try std.testing.expectEqualStrings("owned warning", moved.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 0), original.css.len);
    try std.testing.expectEqual(@as(usize, 0), original.diagnostics.len);
}

test "compile result consumes emitter buffers without copying them" {
    const allocator = std.testing.allocator;
    const css = try allocator.dupe(u8, ".owned{}");
    const source_map = try allocator.dupe(u8, "{}");
    const css_pointer = css.ptr;
    const map_pointer = source_map.ptr;
    var result = try CompileResult.initOwned(allocator, css, source_map, &.{});
    defer result.deinit();

    try std.testing.expectEqual(css_pointer, result.css.ptr);
    try std.testing.expectEqual(map_pointer, result.source_map.?.ptr);
    try std.testing.expectEqualStrings(".owned{}", result.css);
    try std.testing.expectEqualStrings("{}", result.source_map.?);
}

fn exerciseCompilationAllocationFailures(allocator: std.mem.Allocator) !void {
    var compilation = try Compilation.init(allocator);
    defer compilation.deinit();
    const id = try compilation.addSource("oom.css", "é\r\n.a{}");
    try compilation.report(.err, .unexpected_token, try source.Span.init(id, 4, 5), "allocation failure coverage");
    _ = try compilation.arenaAllocator().dupe(u8, "temporary syntax storage");
}

fn exerciseResultAllocationFailures(allocator: std.mem.Allocator) !void {
    const entries = [_]diagnostics.Diagnostic{
        .{
            .severity = .err,
            .code = .unexpected_token,
            .span = .{ .source = .{ .value = 7 }, .start = 2, .end = 4 },
            .message = "first",
        },
        .{
            .severity = .warning,
            .code = .unexpected_eof,
            .span = .{ .source = .{ .value = 7 }, .start = 5, .end = 5 },
            .message = "second",
        },
    };
    var result = try CompileResult.init(allocator, "body{}", "{}", &entries);
    defer result.deinit();
}

fn exerciseOwnedResultAllocationFailures(allocator: std.mem.Allocator) !void {
    const css = try allocator.dupe(u8, "body{}");
    var css_surrendered = false;
    defer if (!css_surrendered) allocator.free(css);
    const source_map = try allocator.dupe(u8, "{}");
    var map_surrendered = false;
    defer if (!map_surrendered) allocator.free(source_map);
    const entries = [_]diagnostics.Diagnostic{.{
        .severity = .warning,
        .code = .unexpected_token,
        .span = .{ .source = .{ .value = 0 }, .start = 0, .end = 1 },
        .message = "owned diagnostic",
    }};

    css_surrendered = true;
    map_surrendered = true;
    var result = try CompileResult.initOwned(allocator, css, source_map, &entries);
    defer result.deinit();
}

test "compilation and result constructors handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompilationAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseResultAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseOwnedResultAllocationFailures,
        .{},
    );
}

test "empty compile results have one safe cleanup path" {
    var result = try CompileResult.init(std.testing.allocator, "", null, &.{});
    result.deinit();
    result.deinit();
}
