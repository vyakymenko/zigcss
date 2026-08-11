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

const ResultFactCase = struct {
    syntax: native.Syntax,
    filename: []const u8,
    dependency_filename: []const u8,
    dependency_input: []const u8,
    input: []const u8,
    expected: []const u8,
    dependency_kind: native.DependencyKind,
};

const result_fact_cases = [_]ResultFactCase{
    .{
        .syntax = .scss,
        .filename = "facts.scss",
        .dependency_filename = "_scss_tokens.scss",
        .dependency_input = "$color: red;",
        .input = "@use \"scss_tokens\" as tokens; .a { color: tokens.$color; }",
        .expected = ".a{color:red}",
        .dependency_kind = .use,
    },
    .{
        .syntax = .sass,
        .filename = "facts.sass",
        .dependency_filename = "_sass_tokens.sass",
        .dependency_input = "$color: red\n",
        .input = "@use \"sass_tokens\" as tokens\n.a\n  color: tokens.$color\n",
        .expected = ".a{color:red}",
        .dependency_kind = .use,
    },
    .{
        .syntax = .scss,
        .filename = "forward.scss",
        .dependency_filename = "_forward_tokens.scss",
        .dependency_input = "$color: red;",
        .input = "@forward \"forward_tokens\"; .a { color: red; }",
        .expected = ".a{color:red}",
        .dependency_kind = .forward,
    },
    .{
        .syntax = .scss,
        .filename = "reference.scss",
        .dependency_filename = "_reference_tokens.scss",
        .dependency_input = ".from-reference { color: red; }",
        .input = "@use \"sass:meta\"; @include meta.load-css(\"reference_tokens\");",
        .expected = ".from-reference{color:red}",
        .dependency_kind = .reference,
    },
    .{
        .syntax = .less,
        .filename = "facts.less",
        .dependency_filename = "less_tokens.less",
        .dependency_input = "@color: red;",
        .input = "@import \"less_tokens.less\"; .a { color: @color; }",
        .expected = ".a{color:red}",
        .dependency_kind = .import,
    },
    .{
        .syntax = .stylus,
        .filename = "facts.styl",
        .dependency_filename = "stylus_tokens.styl",
        .dependency_input = "color = red\n",
        .input = "@import \"stylus_tokens\"\n.a\n  color color\n",
        .expected = ".a{color:#f00}",
        .dependency_kind = .import,
    },
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

test "external Zig API owns native diagnostics and dependency facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    inline for (result_fact_cases) |case| {
        try tmp.dir.writeFile(.{
            .sub_path = case.dependency_filename,
            .data = case.dependency_input,
        });
        const entry_path = try std.fs.path.join(
            std.testing.allocator,
            &.{ root, case.filename },
        );
        defer std.testing.allocator.free(entry_path);

        var first = try native.compile(std.testing.allocator, entry_path, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{root},
            .format = .minified,
        });
        defer first.deinit();
        var second = try native.compile(std.testing.allocator, entry_path, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{root},
            .format = .minified,
        });
        defer second.deinit();

        try std.testing.expectEqualStrings(case.expected, first.css);
        try std.testing.expectEqual(@as(usize, 0), first.diagnostics.len);
        try std.testing.expectEqual(@as(usize, 1), first.dependencies.len);
        try std.testing.expectEqual(case.dependency_kind, first.dependencies[0].kind);
        try std.testing.expect(std.mem.endsWith(
            u8,
            first.dependencies[0].url,
            case.dependency_filename,
        ));
        try std.testing.expectEqual(first.dependencies[0].kind, second.dependencies[0].kind);
        try std.testing.expectEqualStrings(
            first.dependencies[0].url,
            second.dependencies[0].url,
        );

        var moved = first.take();
        defer moved.deinit();
        try std.testing.expectEqual(@as(usize, 0), first.dependencies.len);
        try std.testing.expectEqual(@as(usize, 1), moved.dependencies.len);
        try std.testing.expect(std.mem.endsWith(
            u8,
            moved.dependencies[0].url,
            case.dependency_filename,
        ));
        first.deinit();
    }

    try tmp.dir.writeFile(.{
        .sub_path = "_ordered_first.scss",
        .data = "$value: 1px;",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "_ordered_second.scss",
        .data = "$value: 2px;",
    });
    const ordered_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "ordered.scss" },
    );
    defer std.testing.allocator.free(ordered_path);
    var ordered = try native.compile(
        std.testing.allocator,
        ordered_path,
        "@use \"ordered_first\" as first; @use \"ordered_second\" as second; @use \"ordered_first\" as repeated; .ordered { width: first.$value; height: second.$value; margin: repeated.$value; }",
        .{
            .syntax = .scss,
            .root_paths = &.{root},
            .format = .minified,
        },
    );
    defer ordered.deinit();
    try std.testing.expectEqualStrings(
        ".ordered{width:1px;height:2px;margin:1px}",
        ordered.css,
    );
    try std.testing.expectEqual(@as(usize, 2), ordered.dependencies.len);
    try std.testing.expect(std.mem.endsWith(
        u8,
        ordered.dependencies[0].url,
        "_ordered_first.scss",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        ordered.dependencies[1].url,
        "_ordered_second.scss",
    ));

    const warning_input = "/* 😀 */ .a { $new: blue !global; color: $new; } .b { color: $new; }";
    const warning_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "warning.scss" },
    );
    defer std.testing.allocator.free(warning_path);
    var warning_result = try native.compile(
        std.testing.allocator,
        warning_path,
        warning_input,
        .{
            .syntax = .scss,
            .root_paths = &.{root},
            .format = .minified,
        },
    );
    defer warning_result.deinit();
    try std.testing.expectEqualStrings(".a{color:blue}.b{color:blue}", warning_result.css);
    try std.testing.expectEqual(@as(usize, 1), warning_result.diagnostics.len);
    const diagnostic = warning_result.diagnostics[0];
    try std.testing.expectEqual(native.DiagnosticSeverity.warning, diagnostic.severity);
    try std.testing.expectEqual(native.DiagnosticCode.syntax, diagnostic.code);
    try std.testing.expectEqualStrings("NATIVE0001", diagnostic.code.label());
    try std.testing.expectEqualStrings(
        "!global assignment declares a new variable; Sass 2.0 will reject it",
        diagnostic.message,
    );
    try std.testing.expect(std.mem.endsWith(u8, diagnostic.source_name, "/warning.scss"));
    try std.testing.expectEqual(@as(u32, 22), diagnostic.span.start);
    try std.testing.expectEqual(@as(u32, 34), diagnostic.span.end);
    try std.testing.expectEqual(native.SourcePosition{ .line = 0, .column = 20 }, diagnostic.start);
    try std.testing.expectEqual(native.SourcePosition{ .line = 0, .column = 32 }, diagnostic.end);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.related.len);
    try std.testing.expectEqual(@as(usize, 0), warning_result.dependencies.len);
}

test "external Zig API returns structured native failures without partial facts" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const entry_path = try fixture.entryPath(std.testing.allocator, "failure.scss");
    defer std.testing.allocator.free(entry_path);
    const input = "/* 😀 */ .a { color: $missing; }";

    var result = try native.compile(std.testing.allocator, entry_path, input, .{
        .syntax = .scss,
        .root_paths = &.{fixture.root},
        .format = .minified,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.css.len);
    try std.testing.expectEqual(@as(usize, 0), result.dependencies.len);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    const diagnostic = result.diagnostics[0];
    try std.testing.expectEqual(native.DiagnosticSeverity.err, diagnostic.severity);
    try std.testing.expectEqual(native.DiagnosticCode.undefined_variable, diagnostic.code);
    try std.testing.expectEqualStrings("undefined Sass variable", diagnostic.message);
    try std.testing.expect(std.mem.endsWith(u8, diagnostic.source_name, "/failure.scss"));
    try std.testing.expectEqual(@as(u32, 23), diagnostic.span.start);
    try std.testing.expectEqual(@as(u32, 31), diagnostic.span.end);
    try std.testing.expectEqual(native.SourcePosition{ .line = 0, .column = 21 }, diagnostic.start);
    try std.testing.expectEqual(native.SourcePosition{ .line = 0, .column = 29 }, diagnostic.end);

    var parse_failure = try native.compile(
        std.testing.allocator,
        entry_path,
        ".a { color: red;",
        .{
            .syntax = .scss,
            .root_paths = &.{fixture.root},
            .format = .minified,
        },
    );
    defer parse_failure.deinit();
    try std.testing.expectEqual(@as(usize, 0), parse_failure.css.len);
    try std.testing.expectEqual(@as(usize, 0), parse_failure.dependencies.len);
    try std.testing.expect(parse_failure.diagnostics.len > 0);
    try std.testing.expectEqual(native.DiagnosticSeverity.err, parse_failure.diagnostics[0].severity);
    try std.testing.expectEqual(native.DiagnosticCode.syntax, parse_failure.diagnostics[0].code);
    try std.testing.expect(std.mem.endsWith(
        u8,
        parse_failure.diagnostics[0].source_name,
        "/failure.scss",
    ));
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
    var result = try native.compile(allocator, context.entry_path, "@use \"tokens\"; .a { $new: tokens.$color !global; color: $new; }", .{
        .syntax = .scss,
        .root_paths = &.{context.root},
        .format = .minified,
        .watch = true,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{color:red}", result.css);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    const reloaded = try result.readWatchInput(allocator);
    defer allocator.free(reloaded);
    try std.testing.expectEqualStrings(
        "@use \"tokens\"; .a { color: tokens.$color; }",
        reloaded,
    );
    try std.testing.expect(!(try result.pollWatchInputs()));

    var failure = try native.compile(allocator, context.entry_path, ".a { color: $missing; }", .{
        .syntax = .scss,
        .root_paths = &.{context.root},
        .format = .minified,
    });
    defer failure.deinit();
    try std.testing.expectEqual(@as(usize, 0), failure.css.len);
    try std.testing.expectEqual(@as(usize, 1), failure.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), failure.dependencies.len);
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
