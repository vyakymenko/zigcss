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

const DecodedMapping = struct {
    generated_line: u32,
    generated_column: u32,
    source: ?u32,
    original_line: ?u32,
    original_column: ?u32,
};

fn base64Value(byte: u8) ?u8 {
    if (byte >= 'A' and byte <= 'Z') return byte - 'A';
    if (byte >= 'a' and byte <= 'z') return byte - 'a' + 26;
    if (byte >= '0' and byte <= '9') return byte - '0' + 52;
    if (byte == '+') return 62;
    if (byte == '/') return 63;
    return null;
}

fn decodeVlq(encoded: []const u8, cursor: *usize, end: usize) !i64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (cursor.* < end) {
        const digit = base64Value(encoded[cursor.*]) orelse return error.InvalidSourceMap;
        cursor.* += 1;
        const payload: u64 = digit & 0x1f;
        if (shift >= 32 and payload != 0) return error.InvalidSourceMap;
        value |= payload << shift;
        if ((digit & 0x20) == 0) {
            const magnitude = value >> 1;
            if (magnitude > std.math.maxInt(i32)) return error.InvalidSourceMap;
            const signed: i64 = @intCast(magnitude);
            return if ((value & 1) != 0) -signed else signed;
        }
        if (shift > 26) return error.InvalidSourceMap;
        shift += 5;
    }
    return error.InvalidSourceMap;
}

fn decodeMappings(allocator: std.mem.Allocator, encoded: []const u8) ![]DecodedMapping {
    var decoded: std.ArrayList(DecodedMapping) = .empty;
    errdefer decoded.deinit(allocator);
    var generated_line: i64 = 0;
    var previous_source: i64 = 0;
    var previous_original_line: i64 = 0;
    var previous_original_column: i64 = 0;
    var line_start: usize = 0;
    while (line_start <= encoded.len) {
        const line_end = std.mem.indexOfScalarPos(u8, encoded, line_start, ';') orelse encoded.len;
        var generated_column: i64 = 0;
        if (line_start < line_end) {
            var segment_start = line_start;
            while (segment_start <= line_end) {
                const segment_end = if (std.mem.indexOfScalar(
                    u8,
                    encoded[segment_start..line_end],
                    ',',
                )) |relative| segment_start + relative else line_end;
                if (segment_start == segment_end) return error.InvalidSourceMap;
                var cursor = segment_start;
                var fields: [5]i64 = undefined;
                var field_count: usize = 0;
                while (cursor < segment_end) {
                    if (field_count == fields.len) return error.InvalidSourceMap;
                    fields[field_count] = try decodeVlq(encoded, &cursor, segment_end);
                    field_count += 1;
                }
                if (field_count != 1 and field_count != 4 and field_count != 5) {
                    return error.InvalidSourceMap;
                }
                generated_column += fields[0];
                if (generated_line < 0 or generated_column < 0 or
                    generated_line > std.math.maxInt(u32) or
                    generated_column > std.math.maxInt(u32))
                {
                    return error.InvalidSourceMap;
                }
                var mapping = DecodedMapping{
                    .generated_line = @intCast(generated_line),
                    .generated_column = @intCast(generated_column),
                    .source = null,
                    .original_line = null,
                    .original_column = null,
                };
                if (field_count >= 4) {
                    previous_source += fields[1];
                    previous_original_line += fields[2];
                    previous_original_column += fields[3];
                    if (previous_source < 0 or previous_original_line < 0 or
                        previous_original_column < 0 or
                        previous_source > std.math.maxInt(u32) or
                        previous_original_line > std.math.maxInt(u32) or
                        previous_original_column > std.math.maxInt(u32))
                    {
                        return error.InvalidSourceMap;
                    }
                    mapping.source = @intCast(previous_source);
                    mapping.original_line = @intCast(previous_original_line);
                    mapping.original_column = @intCast(previous_original_column);
                }
                try decoded.append(allocator, mapping);
                if (segment_end == line_end) break;
                segment_start = segment_end + 1;
            }
        }
        if (line_end == encoded.len) break;
        generated_line += 1;
        line_start = line_end + 1;
    }
    return decoded.toOwnedSlice(allocator);
}

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
        try std.testing.expect(first.source_map == null);
        var moved = first.take();
        defer moved.deinit();
        try std.testing.expectEqualStrings(case.expected, moved.css);
        try std.testing.expectEqual(@as(usize, 0), first.css.len);
        first.deinit();
    }
}

test "external Zig API composes deterministic source maps for the finite native syntax set" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();

    inline for (route_cases) |case| {
        const entry_path = try fixture.entryPath(std.testing.allocator, case.filename);
        defer std.testing.allocator.free(entry_path);
        var first = try native.compile(std.testing.allocator, entry_path, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .source_map = true,
        });
        defer first.deinit();
        var second = try native.compile(std.testing.allocator, entry_path, case.input, .{
            .syntax = case.syntax,
            .root_paths = &.{fixture.root},
            .format = .minified,
            .source_map = true,
        });
        defer second.deinit();

        const first_map = first.source_map orelse return error.MissingSourceMap;
        const second_map = second.source_map orelse return error.MissingSourceMap;
        try std.testing.expectEqualStrings(first_map, second_map);
        try std.testing.expect(std.mem.indexOf(u8, first_map, "zigcss-native:///intermediate.css") == null);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            first_map,
            .{},
        );
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqual(@as(i64, 3), object.get("version").?.integer);
        const sources = object.get("sources").?.array.items;
        const contents = object.get("sourcesContent").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), sources.len);
        try std.testing.expectEqual(sources.len, contents.len);
        try std.testing.expect(std.mem.endsWith(u8, sources[0].string, case.filename));
        try std.testing.expectEqualStrings(case.input, contents[0].string);
        const mappings = object.get("mappings").?.string;
        const decoded = try decodeMappings(std.testing.allocator, mappings);
        defer std.testing.allocator.free(decoded);
        try std.testing.expect(decoded.len > 0);
        for (decoded) |mapping| {
            if (mapping.source) |source_index| {
                try std.testing.expect(source_index < sources.len);
            }
        }

        var moved = first.take();
        defer moved.deinit();
        try std.testing.expect(first.source_map == null);
        try std.testing.expectEqualStrings(first_map, moved.source_map.?);
        first.deinit();
    }
}

test "external Zig API composes imported Unicode source positions without intermediate leaks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dependency_input = ".😀{color:red}.b{color:blue}";
    try tmp.dir.writeFile(.{ .sub_path = "_mapped.scss", .data = dependency_input });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "mapped.scss" },
    );
    defer std.testing.allocator.free(entry_path);
    const entry_input = "@use \"mapped\"; .entry { color: green; }";

    var result = try native.compile(std.testing.allocator, entry_path, entry_input, .{
        .syntax = .scss,
        .root_paths = &.{root},
        .format = .minified,
        .source_map = true,
    });
    defer result.deinit();
    const source_map = result.source_map orelse return error.MissingSourceMap;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        source_map,
        .{},
    );
    defer parsed.deinit();
    const object = parsed.value.object;
    const sources = object.get("sources").?.array.items;
    const contents = object.get("sourcesContent").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqual(sources.len, contents.len);
    try std.testing.expect(std.mem.endsWith(u8, sources[0].string, "/mapped.scss"));
    try std.testing.expect(std.mem.endsWith(u8, sources[1].string, "/_mapped.scss"));
    try std.testing.expectEqualStrings(entry_input, contents[0].string);
    try std.testing.expectEqualStrings(dependency_input, contents[1].string);
    const decoded = try decodeMappings(
        std.testing.allocator,
        object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(decoded);
    var saw_entry = false;
    var saw_import = false;
    var saw_utf16_terminal = false;
    for (decoded) |mapping| {
        const source_index = mapping.source orelse continue;
        try std.testing.expect(source_index < sources.len);
        if (source_index == 0) saw_entry = true;
        if (source_index == 1) {
            saw_import = true;
            if (mapping.original_line.? == 0 and mapping.original_column.? == 14) {
                saw_utf16_terminal = true;
            }
        }
    }
    try std.testing.expect(saw_entry);
    try std.testing.expect(saw_import);
    try std.testing.expect(saw_utf16_terminal);
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
        .source_map = true,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.css.len);
    try std.testing.expect(result.source_map == null);
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
            .source_map = true,
        },
    );
    defer parse_failure.deinit();
    try std.testing.expectEqual(@as(usize, 0), parse_failure.css.len);
    try std.testing.expect(parse_failure.source_map == null);
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
        .source_map = true,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{color:red}", result.css);
    try std.testing.expect(result.source_map != null);
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
        .source_map = true,
    });
    defer failure.deinit();
    try std.testing.expectEqual(@as(usize, 0), failure.css.len);
    try std.testing.expect(failure.source_map == null);
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
