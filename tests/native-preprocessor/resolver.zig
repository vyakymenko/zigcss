const std = @import("std");
const builtin = @import("builtin");
const preprocessor = @import("native_preprocessor");
const resolver = preprocessor.resolver;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,
    root: []u8,
    outside: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.makeDir("root");
        try tmp.dir.makeDir("outside");
        const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
        errdefer std.testing.allocator.free(base);
        const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
        errdefer std.testing.allocator.free(root);
        const outside = try std.fs.path.join(std.testing.allocator, &.{ base, "outside" });
        return .{ .tmp = tmp, .base = base, .root = root, .outside = outside };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.outside);
        std.testing.allocator.free(self.root);
        std.testing.allocator.free(self.base);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn path(self: *const Fixture, relative: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.root, relative });
    }

    fn outsidePath(self: *const Fixture, relative: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.outside, relative });
    }
};

fn fileUrl(path: []const u8) ![]u8 {
    return resolver.pathToFileUrl(std.testing.allocator, path);
}

test "resolver owns canonical roots and rejects invalid root authority" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var confined = try resolver.Resolver.init(
        std.testing.allocator,
        &.{ fixture.outside, fixture.root },
        .{},
    );
    defer confined.deinit();
    try std.testing.expectEqual(@as(usize, 2), confined.roots().len);
    try std.testing.expect(std.mem.order(u8, confined.roots()[0], confined.roots()[1]) == .lt);

    try std.testing.expectError(
        error.InvalidRoot,
        resolver.Resolver.init(std.testing.allocator, &.{}, .{}),
    );
    try std.testing.expectError(
        error.InvalidRoot,
        resolver.Resolver.init(std.testing.allocator, &.{"."}, .{}),
    );
    try std.testing.expectError(
        error.InvalidRoot,
        resolver.Resolver.init(std.testing.allocator, &.{ fixture.root, fixture.root }, .{}),
    );
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root-file", .data = "not a directory" });
    const root_file = try std.fs.path.join(std.testing.allocator, &.{ fixture.base, "root-file" });
    defer std.testing.allocator.free(root_file);
    try std.testing.expectError(
        error.InvalidRoot,
        resolver.Resolver.init(std.testing.allocator, &.{root_file}, .{}),
    );
    var excessive_roots: [65][]const u8 = undefined;
    @memset(&excessive_roots, fixture.root);
    try std.testing.expectError(
        error.InvalidRoot,
        resolver.Resolver.init(std.testing.allocator, &excessive_roots, .{}),
    );
    try std.testing.expectError(
        error.InvalidRoot,
        resolver.Resolver.init(std.testing.allocator, &.{"/tmp/bad\nroot"}, .{}),
    );
    try std.testing.expectError(
        error.InvalidLimits,
        resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{ .max_file_bytes = 0 }),
    );
    try std.testing.expectError(
        error.InvalidLimits,
        resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{ .max_depth = 129 }),
    );

    if (builtin.os.tag != .windows) {
        try fixture.tmp.dir.symLink("root", "root-link", .{ .is_directory = true });
        const link = try std.fs.path.join(std.testing.allocator, &.{ fixture.base, "root-link" });
        defer std.testing.allocator.free(link);
        try std.testing.expectError(
            error.InvalidRoot,
            resolver.Resolver.init(std.testing.allocator, &.{link}, .{}),
        );
    }
}

test "loads owned bytes and records deterministic first-success dependencies" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/first.scss", .data = "a" });
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/second.scss", .data = "bb" });
    const first_path = try fixture.path("first.scss");
    defer std.testing.allocator.free(first_path);
    const second_path = try fixture.path("second.scss");
    defer std.testing.allocator.free(second_path);
    const first_url = try fileUrl(first_path);
    defer std.testing.allocator.free(first_url);
    const second_url = try fileUrl(second_path);
    defer std.testing.allocator.free(second_url);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();

    var second = try session.load(second_url, .{ .kind = .use, .ancestry = &.{} });
    defer second.deinit();
    var first = try session.load(first_url, .{ .kind = .import, .ancestry = &.{} });
    defer first.deinit();
    var duplicate = try session.load(second_url, .{ .kind = .forward, .ancestry = &.{} });
    defer duplicate.deinit();

    try std.testing.expectEqualStrings("bb", second.contents);
    try std.testing.expectEqualStrings("a", first.contents);
    try std.testing.expectEqualStrings("bb", duplicate.contents);
    try std.testing.expectEqualStrings(second.url, duplicate.url);
    try std.testing.expect(second.contents.ptr != duplicate.contents.ptr);
    try std.testing.expectEqual(@as(usize, 2), session.dependencies().len);
    try std.testing.expectEqual(resolver.DependencyKind.use, session.dependencies()[0].kind);
    try std.testing.expectEqualStrings(second.url, session.dependencies()[0].url);
    try std.testing.expectEqual(resolver.DependencyKind.import, session.dependencies()[1].kind);
    try std.testing.expectEqualStrings(first.url, session.dependencies()[1].url);
    try std.testing.expectEqual(@as(usize, 2), session.edges().len);
    try std.testing.expect(session.edges()[0].parent_url == null);
    try std.testing.expectEqualStrings(second.url, session.edges()[0].child_url);
    try std.testing.expectEqual(
        resolver.Stats{ .attempts = 3, .files = 2, .bytes = 5 },
        session.stats(),
    );

    var replay = confined.createSession(std.testing.allocator, .{});
    defer replay.deinit();
    var replay_second = try replay.load(second_url, .{ .kind = .use, .ancestry = &.{} });
    defer replay_second.deinit();
    var replay_first = try replay.load(first_url, .{ .kind = .import, .ancestry = &.{} });
    defer replay_first.deinit();
    var replay_duplicate = try replay.load(second_url, .{ .kind = .forward, .ancestry = &.{} });
    defer replay_duplicate.deinit();
    try std.testing.expectEqual(session.stats(), replay.stats());
    for (session.dependencies(), replay.dependencies()) |expected, actual| {
        try std.testing.expectEqual(expected.kind, actual.kind);
        try std.testing.expectEqualStrings(expected.url, actual.url);
    }
    for (session.edges(), replay.edges()) |expected, actual| {
        try std.testing.expectEqual(expected.kind, actual.kind);
        try std.testing.expect(optionalStringsEqual(expected.parent_url, actual.parent_url));
        try std.testing.expectEqualStrings(expected.child_url, actual.child_url);
    }
}

test "loads empty files across the exact end-of-file boundary" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/empty.scss", .data = "" });
    const path = try fixture.path("empty.scss");
    defer std.testing.allocator.free(path);
    const url = try fileUrl(path);
    defer std.testing.allocator.free(url);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var loaded = try session.load(url, .{ .kind = .import, .ancestry = &.{} });
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.contents.len);
    try std.testing.expectEqual(
        resolver.Stats{ .attempts = 1, .files = 1, .bytes = 0 },
        session.stats(),
    );
}

test "canonical URLs percent-encode path bytes and round-trip Unicode input" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const name = "space # карта.scss";
    const relative = try std.fs.path.join(std.testing.allocator, &.{ "root", name });
    defer std.testing.allocator.free(relative);
    try fixture.tmp.dir.writeFile(.{ .sub_path = relative, .data = ".map{}" });
    const path = try fixture.path(name);
    defer std.testing.allocator.free(path);
    const url = try fileUrl(path);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "%20") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "%23") != null);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var loaded = try session.load(url, .{ .kind = .reference, .ancestry = &.{} });
    defer loaded.deinit();
    try std.testing.expectEqualStrings(".map{}", loaded.contents);
    try std.testing.expectEqualStrings(url, loaded.url);
}

test "rejects schemes aliases malformed URLs encoded separators and lexical escapes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/inside.scss", .data = ".inside{}" });
    try fixture.tmp.dir.writeFile(.{ .sub_path = "outside/escaped.scss", .data = ".escaped{}" });
    const inside_path = try fixture.path("inside.scss");
    defer std.testing.allocator.free(inside_path);
    const escaped_path = try fixture.outsidePath("escaped.scss");
    defer std.testing.allocator.free(escaped_path);
    const inside_url = try fileUrl(inside_path);
    defer std.testing.allocator.free(inside_url);
    const escaped_url = try fileUrl(escaped_path);
    defer std.testing.allocator.free(escaped_url);
    const query = try std.fmt.allocPrint(std.testing.allocator, "{s}?raw=1", .{inside_url});
    defer std.testing.allocator.free(query);
    const fragment = try std.fmt.allocPrint(std.testing.allocator, "{s}#fragment", .{inside_url});
    defer std.testing.allocator.free(fragment);
    const encoded_separator = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}%2Fchild.scss",
        .{inside_url},
    );
    defer std.testing.allocator.free(encoded_separator);
    const encoded_backslash = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}%5Cchild.scss",
        .{inside_url},
    );
    defer std.testing.allocator.free(encoded_backslash);
    const encoded_nul = try std.fmt.allocPrint(std.testing.allocator, "{s}%00", .{inside_url});
    defer std.testing.allocator.free(encoded_nul);
    const credentials = try std.fmt.allocPrint(
        std.testing.allocator,
        "file://user@{s}",
        .{inside_url["file://".len..]},
    );
    defer std.testing.allocator.free(credentials);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(
        error.SchemeNotAllowed,
        session.load("https://example.com/input.scss", .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectError(
        error.PathEscape,
        session.load(escaped_url, .{ .kind = .import, .ancestry = &.{} }),
    );
    const invalid_urls = [_][]const u8{
        query,
        fragment,
        encoded_separator,
        encoded_backslash,
        encoded_nul,
        credentials,
        "file:///tmp/%ZZ.scss",
        inside_path,
    };
    for (&invalid_urls) |invalid| {
        try std.testing.expectError(
            error.InvalidUrl,
            session.load(invalid, .{ .kind = .import, .ancestry = &.{} }),
        );
    }
    try std.testing.expectError(
        error.InvalidUrl,
        session.load("file://example.com/share.scss", .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectEqual(@as(usize, 0), session.dependencies().len);
}

test "distinguishes missing directories non-directory parents and special files" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.makeDir("root/directory");
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/file.scss", .data = ".file{}" });
    const missing_path = try fixture.path("missing.scss");
    defer std.testing.allocator.free(missing_path);
    const directory_path = try fixture.path("directory");
    defer std.testing.allocator.free(directory_path);
    const nested_path = try fixture.path("file.scss/nested.scss");
    defer std.testing.allocator.free(nested_path);
    const missing_url = try fileUrl(missing_path);
    defer std.testing.allocator.free(missing_url);
    const directory_url = try fileUrl(directory_path);
    defer std.testing.allocator.free(directory_url);
    const nested_url = try fileUrl(nested_path);
    defer std.testing.allocator.free(nested_url);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(
        error.Missing,
        session.load(missing_url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectError(
        error.IsDirectory,
        session.load(directory_url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectError(
        error.ParentNotDirectory,
        session.load(nested_url, .{ .kind = .import, .ancestry = &.{} }),
    );

    if (builtin.os.tag != .windows) {
        var devices = try resolver.Resolver.init(std.testing.allocator, &.{"/dev"}, .{});
        defer devices.deinit();
        var device_session = devices.createSession(std.testing.allocator, .{});
        defer device_session.deinit();
        const null_url = try fileUrl("/dev/null");
        defer std.testing.allocator.free(null_url);
        try std.testing.expectError(
            error.NotRegular,
            device_session.load(null_url, .{ .kind = .reference, .ancestry = &.{} }),
        );
    }
}

test "rejects every file and parent symlink without dependency admission" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/inside.scss", .data = ".inside{}" });
    try fixture.tmp.dir.writeFile(.{ .sub_path = "outside/outside.scss", .data = ".outside{}" });
    try fixture.tmp.dir.symLink("inside.scss", "root/inside-link.scss", .{});
    try fixture.tmp.dir.symLink("../outside", "root/outside-directory", .{ .is_directory = true });
    const file_link = try fixture.path("inside-link.scss");
    defer std.testing.allocator.free(file_link);
    const directory_link = try fixture.path("outside-directory/outside.scss");
    defer std.testing.allocator.free(directory_link);
    const file_url = try fileUrl(file_link);
    defer std.testing.allocator.free(file_url);
    const directory_url = try fileUrl(directory_link);
    defer std.testing.allocator.free(directory_url);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(
        error.Symlink,
        session.load(file_url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectError(
        error.Symlink,
        session.load(directory_url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectEqual(@as(usize, 0), session.dependencies().len);
}

test "rejects unreadable regular files without dependency admission" {
    if (builtin.os.tag == .windows or std.posix.geteuid() == 0) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/unreadable.scss", .data = ".secret{}" });
    var permission_handle = try fixture.tmp.dir.openFile("root/unreadable.scss", .{});
    defer permission_handle.close();
    try std.posix.fchmod(permission_handle.handle, 0);
    defer std.posix.fchmod(permission_handle.handle, 0o600) catch {};
    const path = try fixture.path("unreadable.scss");
    defer std.testing.allocator.free(path);
    const url = try fileUrl(path);
    defer std.testing.allocator.free(url);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(
        error.Unreadable,
        session.load(url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectEqual(@as(usize, 0), session.dependencies().len);
}

test "enforces canonical ancestry depth cycles and graph-level cycle safety" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const names = [_][]const u8{ "first.scss", "second.scss", "third.scss" };
    for (&names) |name| {
        const relative = try std.fs.path.join(std.testing.allocator, &.{ "root", name });
        defer std.testing.allocator.free(relative);
        try fixture.tmp.dir.writeFile(.{ .sub_path = relative, .data = name });
    }
    const first_path = try fixture.path("first.scss");
    defer std.testing.allocator.free(first_path);
    const second_path = try fixture.path("second.scss");
    defer std.testing.allocator.free(second_path);
    const third_path = try fixture.path("third.scss");
    defer std.testing.allocator.free(third_path);
    const first_url = try fileUrl(first_path);
    defer std.testing.allocator.free(first_url);
    const second_url = try fileUrl(second_path);
    defer std.testing.allocator.free(second_url);
    const third_url = try fileUrl(third_path);
    defer std.testing.allocator.free(third_url);

    var confined = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_depth = 2 },
    );
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(
        error.Cycle,
        session.load(first_url, .{ .kind = .import, .ancestry = &.{first_url} }),
    );
    try std.testing.expectError(
        error.DepthLimitExceeded,
        session.load(third_url, .{
            .kind = .import,
            .ancestry = &.{ first_url, second_url },
        }),
    );
    try std.testing.expectError(
        error.InvalidAncestry,
        session.load(first_url, .{
            .kind = .import,
            .ancestry = &.{"https://example.com/base.scss"},
        }),
    );
    try std.testing.expectError(
        error.Cycle,
        session.load(third_url, .{
            .kind = .import,
            .ancestry = &.{ first_url, first_url },
        }),
    );

    var first = try session.load(first_url, .{ .kind = .import, .ancestry = &.{} });
    defer first.deinit();
    var second = try session.load(second_url, .{
        .kind = .use,
        .ancestry = &.{first.url},
    });
    defer second.deinit();
    try std.testing.expectError(
        error.Cycle,
        session.load(first_url, .{ .kind = .forward, .ancestry = &.{second.url} }),
    );
    try std.testing.expectEqual(@as(usize, 2), session.edges().len);
    try std.testing.expectEqualStrings(first.url, session.edges()[1].parent_url.?);
    try std.testing.expectEqualStrings(second.url, session.edges()[1].child_url);
}

test "enforces per-file cumulative unique-file and attempt ceilings" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/first.scss", .data = "abc" });
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/second.scss", .data = "def" });
    const first_path = try fixture.path("first.scss");
    defer std.testing.allocator.free(first_path);
    const second_path = try fixture.path("second.scss");
    defer std.testing.allocator.free(second_path);
    const first_url = try fileUrl(first_path);
    defer std.testing.allocator.free(first_url);
    const second_url = try fileUrl(second_path);
    defer std.testing.allocator.free(second_url);

    var per_file = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_file_bytes = 2 },
    );
    defer per_file.deinit();
    var per_file_session = per_file.createSession(std.testing.allocator, .{});
    defer per_file_session.deinit();
    try std.testing.expectError(
        error.FileLimitExceeded,
        per_file_session.load(first_url, .{ .kind = .import, .ancestry = &.{} }),
    );

    var total = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_total_bytes = 5 },
    );
    defer total.deinit();
    var total_session = total.createSession(std.testing.allocator, .{});
    defer total_session.deinit();
    var total_first = try total_session.load(first_url, .{ .kind = .import, .ancestry = &.{} });
    defer total_first.deinit();
    try std.testing.expectError(
        error.TotalLimitExceeded,
        total_session.load(second_url, .{ .kind = .import, .ancestry = &.{} }),
    );

    var files = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_files = 1 },
    );
    defer files.deinit();
    var file_session = files.createSession(std.testing.allocator, .{});
    defer file_session.deinit();
    var only = try file_session.load(first_url, .{ .kind = .import, .ancestry = &.{} });
    defer only.deinit();
    try std.testing.expectError(
        error.FileCountExceeded,
        file_session.load(second_url, .{ .kind = .import, .ancestry = &.{} }),
    );

    var attempts = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_attempts = 1 },
    );
    defer attempts.deinit();
    var attempt_session = attempts.createSession(std.testing.allocator, .{});
    defer attempt_session.deinit();
    var attempted = try attempt_session.load(first_url, .{ .kind = .import, .ancestry = &.{} });
    defer attempted.deinit();
    try std.testing.expectError(
        error.AttemptLimitExceeded,
        attempt_session.load(first_url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectEqual(
        resolver.Stats{ .attempts = 1, .files = 1, .bytes = 3 },
        attempt_session.stats(),
    );
}

const CancelContext = struct {
    checkpoint: resolver.Checkpoint,

    fn check(raw: *anyopaque, checkpoint: resolver.Checkpoint) bool {
        const self: *CancelContext = @ptrCast(@alignCast(raw));
        return checkpoint == self.checkpoint;
    }
};

test "confined glob enumeration is sorted bounded and grants no file bytes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.makePath("root/parts/nested");
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/parts/b.styl", .data = "b" });
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/parts/a.styl", .data = "a" });
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/parts/nested/c.styl", .data = "c" });
    const pattern_path = try fixture.path("parts/**/*");
    defer std.testing.allocator.free(pattern_path);
    const pattern_url = try fileUrl(pattern_path);
    defer std.testing.allocator.free(pattern_url);
    const outside_pattern_path = try fixture.outsidePath("**/*");
    defer std.testing.allocator.free(outside_pattern_path);
    const outside_pattern_url = try fileUrl(outside_pattern_path);
    defer std.testing.allocator.free(outside_pattern_url);

    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var matches = try session.glob(pattern_url, &.{});
    defer matches.deinit();
    try std.testing.expectEqual(@as(usize, 3), matches.urls.len);
    try std.testing.expect(std.mem.endsWith(u8, matches.urls[0], "/parts/a.styl"));
    try std.testing.expect(std.mem.endsWith(u8, matches.urls[1], "/parts/b.styl"));
    try std.testing.expect(std.mem.endsWith(u8, matches.urls[2], "/parts/nested/c.styl"));
    try std.testing.expectEqual(@as(usize, 0), session.dependencies().len);
    try std.testing.expectEqual(resolver.Stats{ .attempts = 0, .files = 0, .bytes = 0 }, session.stats());
    try std.testing.expectError(error.PathEscape, session.glob(outside_pattern_url, &.{}));

    var bounded = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_files = 2 },
    );
    defer bounded.deinit();
    var bounded_session = bounded.createSession(std.testing.allocator, .{});
    defer bounded_session.deinit();
    try std.testing.expectError(
        error.FileCountExceeded,
        bounded_session.glob(pattern_url, &.{}),
    );

    var terminal_scan = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_attempts = 8 },
    );
    defer terminal_scan.deinit();
    var terminal_scan_session = terminal_scan.createSession(std.testing.allocator, .{});
    defer terminal_scan_session.deinit();
    var terminal_matches = try terminal_scan_session.glob(pattern_url, &.{});
    defer terminal_matches.deinit();
    try std.testing.expectEqual(@as(usize, 3), terminal_matches.urls.len);

    var over_scan = try resolver.Resolver.init(
        std.testing.allocator,
        &.{fixture.root},
        .{ .max_attempts = 7 },
    );
    defer over_scan.deinit();
    var over_scan_session = over_scan.createSession(std.testing.allocator, .{});
    defer over_scan_session.deinit();
    try std.testing.expectError(
        error.AttemptLimitExceeded,
        over_scan_session.glob(pattern_url, &.{}),
    );

    if (builtin.os.tag != .windows) {
        try fixture.tmp.dir.symLink(
            "../../outside",
            "root/parts/link",
            .{ .is_directory = true },
        );
        try std.testing.expectError(error.Symlink, session.glob(pattern_url, &.{}));
    }
}

const MutationContext = struct {
    dir: *std.fs.Dir,
    fired: bool = false,

    fn check(raw: *anyopaque, checkpoint: resolver.Checkpoint) bool {
        const self: *MutationContext = @ptrCast(@alignCast(raw));
        if (checkpoint == .read and !self.fired) {
            self.fired = true;
            self.dir.writeFile(.{
                .sub_path = "root/mutable.scss",
                .data = "replacement-is-longer",
            }) catch return true;
        }
        return false;
    }
};

test "cancellation and unstable reads fail without partial dependency facts" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/mutable.scss", .data = "abc" });
    const path = try fixture.path("mutable.scss");
    defer std.testing.allocator.free(path);
    const url = try fileUrl(path);
    defer std.testing.allocator.free(url);
    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();

    var cancel_context = CancelContext{ .checkpoint = .read };
    var cancelled = confined.createSession(std.testing.allocator, .{
        .context = &cancel_context,
        .check_fn = CancelContext.check,
    });
    defer cancelled.deinit();
    try std.testing.expectError(
        error.Cancelled,
        cancelled.load(url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectEqual(@as(usize, 0), cancelled.dependencies().len);
    try std.testing.expectEqual(@as(u64, 0), cancelled.stats().bytes);

    var mutation_context = MutationContext{ .dir = &fixture.tmp.dir };
    var unstable = confined.createSession(std.testing.allocator, .{
        .context = &mutation_context,
        .check_fn = MutationContext.check,
    });
    defer unstable.deinit();
    try std.testing.expectError(
        error.FileChanged,
        unstable.load(url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expect(mutation_context.fired);
    try std.testing.expectEqual(@as(usize, 0), unstable.dependencies().len);
    try std.testing.expectEqual(@as(u64, 0), unstable.stats().bytes);
}

test "canonical root replacement invalidates the pinned capability" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/file.scss", .data = "original" });
    const path = try fixture.path("file.scss");
    defer std.testing.allocator.free(path);
    const url = try fileUrl(path);
    defer std.testing.allocator.free(url);
    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();

    try fixture.tmp.dir.rename("root", "moved-root");
    try fixture.tmp.dir.makeDir("root");
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/file.scss", .data = "replacement" });
    try std.testing.expectError(
        error.FileChanged,
        session.load(url, .{ .kind = .import, .ancestry = &.{} }),
    );
    try std.testing.expectEqual(@as(usize, 0), session.dependencies().len);
}

test "closed sessions reject work while preserving already-owned results" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/file.scss", .data = "owned" });
    const path = try fixture.path("file.scss");
    defer std.testing.allocator.free(path);
    const url = try fileUrl(path);
    defer std.testing.allocator.free(url);
    var confined = try resolver.Resolver.init(std.testing.allocator, &.{fixture.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var loaded = try session.load(url, .{ .kind = .reference, .ancestry = &.{} });
    defer loaded.deinit();
    session.close();
    try std.testing.expectError(
        error.SessionClosed,
        session.load(url, .{ .kind = .reference, .ancestry = &.{} }),
    );
    try std.testing.expectEqualStrings("owned", loaded.contents);
}

const AllocationContext = struct {
    root: []const u8,
    url: []const u8,
};

fn exerciseResolverAllocationFailures(
    allocator: std.mem.Allocator,
    context: AllocationContext,
) !void {
    var confined = try resolver.Resolver.init(allocator, &.{context.root}, .{});
    defer confined.deinit();
    var session = confined.createSession(allocator, .{});
    defer session.deinit();
    var loaded = try session.load(context.url, .{ .kind = .import, .ancestry = &.{} });
    defer loaded.deinit();
    try std.testing.expectEqualStrings("allocation", loaded.contents);
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "resolver handles every initialization resolution graph and result allocation failure" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(.{ .sub_path = "root/file.scss", .data = "allocation" });
    const path = try fixture.path("file.scss");
    defer std.testing.allocator.free(path);
    const url = try fileUrl(path);
    defer std.testing.allocator.free(url);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseResolverAllocationFailures,
        .{AllocationContext{ .root = fixture.root, .url = url }},
    );
}
