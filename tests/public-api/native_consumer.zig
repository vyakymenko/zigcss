const std = @import("std");
const zigcss = @import("zigcss");

const native = zigcss.experimental_native;

const RouteCase = struct {
    syntax: native.Syntax,
    filename: []const u8,
    input: []const u8,
    expected: []const u8,
};

const route_cases = [_]RouteCase{
    .{ .syntax = .scss, .filename = "input.scss", .input = ".a { color: red; }", .expected = ".a{color:red}" },
    .{ .syntax = .sass, .filename = "input.sass", .input = ".a\n  color: red\n", .expected = ".a{color:red}" },
    .{ .syntax = .less, .filename = "input.less", .input = ".a { color: red; }", .expected = ".a{color:red}" },
    .{ .syntax = .stylus, .filename = "input.styl", .input = ".a\n  color red\n", .expected = ".a{color:#f00}" },
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    root: []u8,

    fn init(allocator: std.mem.Allocator) !Fixture {
        return .{
            .allocator = allocator,
            .root = try std.fs.cwd().realpathAlloc(allocator, "."),
        };
    }

    fn deinit(self: *Fixture) void {
        self.allocator.free(self.root);
        self.* = undefined;
    }

    fn entryPath(self: *const Fixture, allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root, filename });
    }
};

test "external Zig API routes the finite native syntax set through owned CSS results" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();

    inline for (route_cases) |case| {
        const entry_path = try fixture.entryPath(std.testing.allocator, case.filename);
        defer std.testing.allocator.free(entry_path);
        var first = try native.compile(std.testing.allocator, entry_path, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
        });
        defer first.deinit();
        var second = try native.compile(std.testing.allocator, entry_path, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
        });
        defer second.deinit();

        try std.testing.expectEqualStrings(case.expected, first.css);
        try std.testing.expectEqualStrings(first.css, second.css);
        var moved = first.take();
        defer moved.deinit();
        try std.testing.expectEqualStrings(case.expected, moved.css);
        try std.testing.expectEqual(@as(usize, 0), first.css.len);
        first.deinit();
    }
}

test "external Zig API preserves exact input resource limits without partial results" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const case = route_cases[0];
    const entry_path = try fixture.entryPath(std.testing.allocator, case.filename);
    defer std.testing.allocator.free(entry_path);

    var terminal = try native.compile(std.testing.allocator, entry_path, case.input, .{
        .syntax = case.syntax,
        .root_paths = &.{fixture.root},
        .format = .minified,
        .max_input_bytes = case.input.len,
    });
    defer terminal.deinit();
    try std.testing.expectEqualStrings(case.expected, terminal.css);

    try std.testing.expectError(
        error.ResourceLimitExceeded,
        native.compile(std.testing.allocator, entry_path, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .max_input_bytes = case.input.len - 1,
        }),
    );
}

test "external Zig API rejects invalid roots paths and language failures" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const entry_path = try fixture.entryPath(std.testing.allocator, "failure.scss");
    defer std.testing.allocator.free(entry_path);

    try std.testing.expectError(
        error.InvalidRoot,
        native.compile(std.testing.allocator, entry_path, ".a { color: red; }", .{
            .syntax = .scss,
            .root_paths = &.{},
        }),
    );
    try std.testing.expectError(
        error.InvalidSourcePath,
        native.compile(std.testing.allocator, "relative.scss", ".a { color: red; }", .{
            .syntax = .scss,
            .root_paths = &.{fixture.root},
        }),
    );
    try std.testing.expectError(
        error.CompilationFailed,
        native.compile(std.testing.allocator, entry_path, ".a { color: $missing; }", .{
            .syntax = .scss,
            .root_paths = &.{fixture.root},
        }),
    );

    const parent = std.fs.path.dirname(fixture.root) orelse return error.MissingParent;
    const outside_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ parent, "zigcss-native-api-outside.scss" },
    );
    defer std.testing.allocator.free(outside_path);
    try std.testing.expectError(
        error.PathEscape,
        native.compile(std.testing.allocator, outside_path, ".a { color: red; }", .{
            .syntax = .scss,
            .root_paths = &.{fixture.root},
        }),
    );
}

test "external Zig API owns opaque watch snapshots and detects one transition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = "$color: red;" });
    try tmp.dir.writeFile(.{
        .sub_path = "input.scss",
        .data = "@use \"tokens\"; .card { color: tokens.$color; }",
    });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "input.scss" },
    );
    defer std.testing.allocator.free(entry_path);

    var result = try native.compile(
        std.testing.allocator,
        entry_path,
        "@use \"tokens\"; .card { color: tokens.$color; }",
        .{
            .syntax = .scss,
            .root_paths = &.{root},
            .format = .minified,
            .watch = true,
        },
    );
    try std.testing.expectEqualStrings(".card{color:red}", result.css);
    var moved = result.take();
    defer moved.deinit();
    result.deinit();
    const reloaded = try moved.readWatchInput(std.testing.allocator);
    defer std.testing.allocator.free(reloaded);
    try std.testing.expectEqualStrings(
        "@use \"tokens\"; .card { color: tokens.$color; }",
        reloaded,
    );
    try std.testing.expect(!(try moved.pollWatchInputs()));
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = "$color: blue;" });
    try std.testing.expect(try moved.pollWatchInputs());
    try std.testing.expect(!(try moved.pollWatchInputs()));
}

const AllocationContext = struct {
    root: []const u8,
    entry_path: []const u8,
};

fn exerciseNativeApiAllocationFailures(
    allocator: std.mem.Allocator,
    context: *const AllocationContext,
) !void {
    var result = try native.compile(allocator, context.entry_path, "@use \"tokens\"; .a { color: tokens.$color; }", .{
        .syntax = .scss,
        .root_paths = &.{context.root},
        .format = .minified,
        .watch = true,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{color:red}", result.css);
    const reloaded = try result.readWatchInput(allocator);
    defer allocator.free(reloaded);
    try std.testing.expectEqualStrings(
        "@use \"tokens\"; .a { color: tokens.$color; }",
        reloaded,
    );
    try std.testing.expect(!(try result.pollWatchInputs()));
}

test "external Zig API route handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = "$color: red;" });
    try tmp.dir.writeFile(.{
        .sub_path = "allocation.scss",
        .data = "@use \"tokens\"; .a { color: tokens.$color; }",
    });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(std.testing.allocator, &.{ root, "allocation.scss" });
    defer std.testing.allocator.free(entry_path);
    const context = AllocationContext{ .root = root, .entry_path = entry_path };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNativeApiAllocationFailures,
        .{&context},
    );
}
