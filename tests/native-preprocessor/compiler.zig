const std = @import("std");
const preprocessor = @import("native_preprocessor");

const compiler = preprocessor.compiler;
const resolver = preprocessor.resolver;
const target_query = preprocessor.target_query;

const RouteCase = struct {
    syntax: compiler.Syntax,
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

const optimize_cases = [_]RouteCase{
    .{ .syntax = .scss, .filename = "optimize.scss", .input = ".empty{}.a{color:#ffffff}.b{color:#fff}", .expected = ".a,.b{color:#fff}" },
    .{ .syntax = .sass, .filename = "optimize.sass", .input = ".a\n  color: #ffffff\n.b\n  color: #fff\n", .expected = ".a,.b{color:#fff}" },
    .{ .syntax = .less, .filename = "optimize.less", .input = ".empty{}.a{color:#ffffff}.b{color:#fff}", .expected = ".a,.b{color:#fff}" },
    .{ .syntax = .stylus, .filename = "optimize.styl", .input = ".a\n  color #ffffff\n.b\n  color #fff\n", .expected = ".a,.b{color:#fff}" },
};

const prefix_cases = [_]RouteCase{
    .{ .syntax = .scss, .filename = "prefix.scss", .input = ".a{user-select:none;display:flex}", .expected = ".a{-webkit-user-select:none;-ms-user-select:none;user-select:none;display:-webkit-flex;display:flex}" },
    .{ .syntax = .sass, .filename = "prefix.sass", .input = ".a\n  user-select: none\n  display: flex\n", .expected = ".a{-webkit-user-select:none;-ms-user-select:none;user-select:none;display:-webkit-flex;display:flex}" },
    .{ .syntax = .less, .filename = "prefix.less", .input = ".a{user-select:none;display:flex}", .expected = ".a{-webkit-user-select:none;-ms-user-select:none;user-select:none;display:-webkit-flex;display:flex}" },
    .{ .syntax = .stylus, .filename = "prefix.styl", .input = ".a\n  user-select none\n  display flex\n", .expected = ".a{-webkit-user-select:none;-ms-user-select:none;user-select:none;display:-webkit-flex;display:flex}" },
};

fn parseTargets(allocator: std.mem.Allocator, input: []const u8) !target_query.Query {
    return switch (try target_query.parse(allocator, input, .{})) {
        .query => |query| query,
        .invalid => error.InvalidQuery,
    };
}

const Fixture = struct {
    allocator: std.mem.Allocator,
    root: []u8,

    fn init(allocator: std.mem.Allocator) !Fixture {
        return .{
            .allocator = allocator,
            .root = try std.process.getCwdAlloc(allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.allocator.free(self.root);
        self.* = undefined;
    }

    fn entryUrl(self: *const Fixture, allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
        const entry_path = try std.fs.path.join(allocator, &.{ self.root, filename });
        defer allocator.free(entry_path);
        return resolver.pathToFileUrl(allocator, entry_path);
    }
};

fn expectEquivalentResults(left: *const compiler.Result, right: *const compiler.Result) !void {
    try std.testing.expectEqualStrings(left.css(), right.css());
    try std.testing.expectEqualSlices(u8, left.sourceMap().?, right.sourceMap().?);
    try std.testing.expectEqual(
        left.frontendMap().?.segments().len,
        right.frontendMap().?.segments().len,
    );
    try std.testing.expectEqual(left.dependencies().len, right.dependencies().len);
}

test "native compiler routes every private frontend through one deterministic transaction" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();

    inline for (route_cases) |case| {
        const entry_url = try fixture.entryUrl(std.testing.allocator, case.filename);
        defer std.testing.allocator.free(entry_url);
        var first = try compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .source_map = true,
        });
        defer first.deinit();
        var second = try compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .source_map = true,
        });
        defer second.deinit();

        try std.testing.expectEqualStrings(case.expected, first.css());
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
        try std.testing.expect(first.frontendMap() != null);
        const entry_source = try first.sourceTable().get(.{ .value = 0 });
        try std.testing.expectEqualStrings(entry_url, entry_source.name);
        try std.testing.expectEqualStrings(case.input, entry_source.bytes);
        try expectEquivalentResults(&first, &second);
    }
}

test "native compiler applies the closed optimizer after every private frontend" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();

    inline for (optimize_cases) |case| {
        const entry_url = try fixture.entryUrl(std.testing.allocator, case.filename);
        defer std.testing.allocator.free(entry_url);
        var first = try compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .optimize = true,
        });
        defer first.deinit();
        var second = try compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .optimize = true,
        });
        defer second.deinit();

        try std.testing.expectEqualStrings(case.expected, first.css());
        try std.testing.expectEqualStrings(first.css(), second.css());
        try std.testing.expect(first.sourceMap() == null);
        try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    }

    const case = optimize_cases[0];
    const entry_url = try fixture.entryUrl(std.testing.allocator, case.filename);
    defer std.testing.allocator.free(entry_url);
    try std.testing.expectError(
        error.InvalidOptions,
        compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            // InvalidOptions must win before even the invalid-root check.
            .root_paths = &.{},
            .source_map = true,
            .optimize = true,
        }),
    );
}

test "native compiler applies verified target prefixing after every private frontend" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var targets = try parseTargets(
        std.testing.allocator,
        "safari >= 7, ie >= 11",
    );
    defer targets.deinit();

    inline for (prefix_cases) |case| {
        const entry_url = try fixture.entryUrl(std.testing.allocator, case.filename);
        defer std.testing.allocator.free(entry_url);
        var prefixed = try compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .source_map = true,
            .prefix = true,
            .targets = &targets,
        });
        defer prefixed.deinit();
        try std.testing.expectEqualStrings(case.expected, prefixed.css());
        try std.testing.expect(prefixed.sourceMap() != null);
        try std.testing.expectEqual(@as(usize, 0), prefixed.coreDiagnostics().len);

        var composed = try compiler.compile(
            std.testing.allocator,
            entry_url,
            switch (case.syntax) {
                .scss, .less => ".empty{}.a{user-select:none;color:#ffffff}.b{user-select:none;color:#fff}",
                .sass => ".a\n  user-select: none\n  color: #ffffff\n.b\n  user-select: none\n  color: #fff\n",
                .stylus => ".a\n  user-select none\n  color #ffffff\n.b\n  user-select none\n  color #fff\n",
            },
            .{
                .syntax = case.syntax,
                .root_paths = &.{fixture.root},
                .format = .minified,
                .optimize = true,
                .prefix = true,
                .targets = &targets,
            },
        );
        defer composed.deinit();
        try std.testing.expectEqualStrings(
            ".a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}",
            composed.css(),
        );

        try std.testing.expectError(
            error.InvalidOptions,
            compiler.compile(std.testing.allocator, entry_url, case.input, .{
                .syntax = case.syntax,
                .root_paths = &.{},
                .prefix = true,
            }),
        );
    }

    var forged_storage = [_]target_query.Target{.{
        .browser = .safari,
        .minimum = .{ .major = 0 },
    }};
    const forged = target_query.Query{
        .allocator = std.testing.allocator,
        .targets = &forged_storage,
    };
    const case = prefix_cases[0];
    const entry_url = try fixture.entryUrl(std.testing.allocator, case.filename);
    defer std.testing.allocator.free(entry_url);
    try std.testing.expectError(
        error.InvalidOptions,
        compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            // Query invariants must win before resolver creation/root checks.
            .root_paths = &.{},
            .prefix = true,
            .targets = &forged,
        }),
    );
}

test "native compiler owns source terminal limits without partial results" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const case = route_cases[0];
    const entry_url = try fixture.entryUrl(std.testing.allocator, case.filename);
    defer std.testing.allocator.free(entry_url);
    const exact_owned_bytes = entry_url.len + case.input.len;

    var terminal = try compiler.compile(std.testing.allocator, entry_url, case.input, .{
        .syntax = case.syntax,
        .root_paths = &.{fixture.root},
        .format = .minified,
        .limits = .{ .sources = .{ .max_owned_bytes = exact_owned_bytes } },
    });
    defer terminal.deinit();
    try std.testing.expectEqualStrings(case.expected, terminal.css());

    try std.testing.expectError(
        error.SourceLimitExceeded,
        compiler.compile(std.testing.allocator, entry_url, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .limits = .{ .sources = .{ .max_owned_bytes = exact_owned_bytes - 1 } },
        }),
    );
}

test "native compiler rejects invalid roots and language failures without a result" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const entry_url = try fixture.entryUrl(std.testing.allocator, "failure.scss");
    defer std.testing.allocator.free(entry_url);

    try std.testing.expectError(
        error.InvalidRoot,
        compiler.compile(std.testing.allocator, entry_url, ".a { color: red; }", .{
            .syntax = .scss,
            .root_paths = &.{},
        }),
    );
    try std.testing.expectError(
        error.UndefinedVariable,
        compiler.compile(std.testing.allocator, entry_url, ".a { color: $missing; }", .{
            .syntax = .scss,
            .root_paths = &.{fixture.root},
        }),
    );

    const parent = std.fs.path.dirname(fixture.root) orelse return error.InvalidRoot;
    const outside_path = try std.fs.path.join(std.testing.allocator, &.{ parent, "outside.scss" });
    defer std.testing.allocator.free(outside_path);
    const outside_url = try resolver.pathToFileUrl(std.testing.allocator, outside_path);
    defer std.testing.allocator.free(outside_url);
    try std.testing.expectError(
        error.PathEscape,
        compiler.compile(std.testing.allocator, outside_url, ".a { color: red; }", .{
            .syntax = .scss,
            .root_paths = &.{fixture.root},
        }),
    );
}

const AllocationContext = struct {
    root: []const u8,
    entry_url: []const u8,
};

fn exerciseCompilerAllocationFailures(
    allocator: std.mem.Allocator,
    context: *const AllocationContext,
) !void {
    var result = try compiler.compile(allocator, context.entry_url, ".a { color: red; }", .{
        .syntax = .scss,
        .root_paths = &.{context.root},
        .format = .minified,
        .source_map = true,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{color:red}", result.css());

    var optimized = try compiler.compile(
        allocator,
        context.entry_url,
        ".empty{}.a{color:#ffffff}.b{color:#fff}",
        .{
            .syntax = .scss,
            .root_paths = &.{context.root},
            .format = .minified,
            .optimize = true,
        },
    );
    defer optimized.deinit();
    try std.testing.expectEqualStrings(".a,.b{color:#fff}", optimized.css());

    var targets = try parseTargets(allocator, "safari >= 7, ie >= 11");
    defer targets.deinit();
    var prefixed = try compiler.compile(
        allocator,
        context.entry_url,
        ".a{user-select:none;display:flex}",
        .{
            .syntax = .scss,
            .root_paths = &.{context.root},
            .format = .minified,
            .prefix = true,
            .targets = &targets,
        },
    );
    defer prefixed.deinit();
    try std.testing.expectEqualStrings(prefix_cases[0].expected, prefixed.css());
}

test "native compiler route handles every allocation failure" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const entry_url = try fixture.entryUrl(std.testing.allocator, "allocation.scss");
    defer std.testing.allocator.free(entry_url);
    const context = AllocationContext{ .root = fixture.root, .entry_url = entry_url };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompilerAllocationFailures,
        .{&context},
    );
}
