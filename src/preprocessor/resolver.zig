//! Confined local dependency loading for the self-contained native frontends.
//!
//! This module resolves concrete candidates only. Language-specific partial,
//! extension, package, and load-path search belongs to each native adapter.
//! All filesystem authority starts at an explicitly opened root capability;
//! candidate and ancestry identities are canonical local file URLs.

const std = @import("std");
const builtin = @import("builtin");

const max_roots = 64;
const max_root_bytes = 4_096;
const max_url_bytes = 8_192;
const hard_max_file_bytes = 10 * 1024 * 1024;
const hard_max_total_bytes = 40 * 1024 * 1024;
const hard_max_files = 4_096;
const hard_max_attempts = 8_192;
const hard_max_depth = 128;
const read_chunk_bytes = 64 * 1024;

extern "kernel32" fn GetFinalPathNameByHandleW(
    handle: std.os.windows.HANDLE,
    path: [*]u16,
    path_len: std.os.windows.DWORD,
    flags: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.DWORD;

pub const Limits = struct {
    max_file_bytes: usize = hard_max_file_bytes,
    max_total_bytes: usize = hard_max_total_bytes,
    max_files: usize = hard_max_files,
    max_attempts: usize = hard_max_attempts,
    max_depth: usize = 64,
};

pub const Error = std.mem.Allocator.Error || error{
    AttemptLimitExceeded,
    Cancelled,
    Cycle,
    DepthLimitExceeded,
    FileChanged,
    FileCountExceeded,
    FileLimitExceeded,
    InvalidAncestry,
    InvalidGlob,
    InvalidLimits,
    InvalidRoot,
    InvalidUrl,
    IsDirectory,
    Missing,
    NotRegular,
    ParentNotDirectory,
    PathEscape,
    SchemeNotAllowed,
    SessionClosed,
    Symlink,
    TotalLimitExceeded,
    Unreadable,
    UnsupportedPlatform,
};

pub const DependencyKind = enum {
    import,
    use,
    forward,
    reference,
};

pub const Checkpoint = enum {
    resolve,
    path_component,
    open,
    graph,
    read,
    verify,
    complete,
};

pub const Cancellation = struct {
    context: ?*anyopaque = null,
    check_fn: ?*const fn (*anyopaque, Checkpoint) bool = null,

    fn check(self: Cancellation, checkpoint: Checkpoint) Error!void {
        const check_fn = self.check_fn orelse return;
        const context = self.context orelse return error.Cancelled;
        if (check_fn(context, checkpoint)) return error.Cancelled;
    }
};

pub const LoadOptions = struct {
    kind: DependencyKind,
    ancestry: []const []const u8,
};

pub const Dependency = struct {
    url: []const u8,
    kind: DependencyKind,
};

pub const Edge = struct {
    parent_url: ?[]const u8,
    child_url: []const u8,
    kind: DependencyKind,
};

pub const Stats = struct {
    attempts: u64,
    files: usize,
    bytes: u64,
};

pub const Loaded = struct {
    url: []const u8,
    contents: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Loaded) void {
        self.allocator.free(self.url);
        self.allocator.free(self.contents);
        self.* = undefined;
    }
};

pub const Globbed = struct {
    urls: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Globbed) void {
        for (self.urls) |url| self.allocator.free(url);
        if (self.urls.len > 0) self.allocator.free(self.urls);
        self.* = undefined;
    }
};

const ObjectIdentity = struct {
    volume: u64,
    inode: u128,
    size: u64,
    kind: std.fs.File.Kind,
    mtime: i128,
    ctime: i128,

    fn read(file: std.fs.File) Error!ObjectIdentity {
        const stat = file.stat() catch return error.Unreadable;
        return .{
            .volume = try volumeIdentity(file),
            .inode = inodeIdentity(stat.inode),
            .size = stat.size,
            .kind = stat.kind,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
        };
    }

    fn sameObject(left: ObjectIdentity, right: ObjectIdentity) bool {
        return left.volume == right.volume and
            left.inode == right.inode and
            left.kind == right.kind;
    }

    fn sameStable(left: ObjectIdentity, right: ObjectIdentity) bool {
        return left.sameObject(right) and
            left.size == right.size and
            left.mtime == right.mtime and
            left.ctime == right.ctime;
    }
};

const Root = struct {
    input: []u8,
    canonical: []u8,
    dir: std.fs.Dir,
    identity: ObjectIdentity,
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    root_items: std.ArrayList(Root) = .empty,
    root_views: std.ArrayList([]const u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        root_paths: []const []const u8,
        limits: Limits,
    ) Error!Resolver {
        try validateLimits(limits);
        if (root_paths.len == 0 or root_paths.len > max_roots) return error.InvalidRoot;

        var result = Resolver{ .allocator = allocator, .limits = limits };
        errdefer result.deinit();
        try result.root_items.ensureTotalCapacity(allocator, root_paths.len);
        for (root_paths) |root_path| try result.addRoot(root_path);
        std.mem.sort(Root, result.root_items.items, {}, rootLessThan);
        try result.root_views.ensureTotalCapacity(allocator, result.root_items.items.len);
        for (result.root_items.items) |root| {
            result.root_views.appendAssumeCapacity(root.canonical);
        }
        return result;
    }

    pub fn deinit(self: *Resolver) void {
        self.root_views.deinit(self.allocator);
        for (self.root_items.items) |*root| {
            root.dir.close();
            self.allocator.free(root.canonical);
            self.allocator.free(root.input);
        }
        self.root_items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn roots(self: *const Resolver) []const []const u8 {
        return self.root_views.items;
    }

    /// Validates an already-loaded entry source identity against the resolver's
    /// explicit directory capabilities. The entry bytes remain caller-owned;
    /// every filesystem load still passes through `Session.load`.
    pub fn containsSourceUrl(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        source_url: []const u8,
    ) Error!bool {
        const source_path = try fileUrlToPath(allocator, source_url);
        defer allocator.free(source_path);
        return lexicalRoot(self, source_path) != null;
    }

    pub fn createSession(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        cancellation: Cancellation,
    ) Session {
        return .{
            .allocator = allocator,
            .resolver = self,
            .cancellation = cancellation,
        };
    }

    fn addRoot(self: *Resolver, root_path: []const u8) Error!void {
        if (!validPathInput(root_path) or !isSupportedAbsolutePath(root_path)) {
            return error.InvalidRoot;
        }
        const input = try std.fs.path.resolve(self.allocator, &.{root_path});
        errdefer self.allocator.free(input);
        if (input.len == 0 or input.len > max_root_bytes or !isSupportedAbsolutePath(input)) {
            return error.InvalidRoot;
        }

        var input_dir = std.fs.openDirAbsolute(input, .{ .no_follow = true }) catch
            return error.InvalidRoot;
        defer input_dir.close();
        const input_identity = ObjectIdentity.read(.{ .handle = input_dir.fd }) catch
            return error.InvalidRoot;
        if (input_identity.kind != .directory) return error.InvalidRoot;

        const canonical = try canonicalPathFromHandle(self.allocator, input_dir.fd, input);
        errdefer self.allocator.free(canonical);
        if (!validPathInput(canonical) or !isSupportedAbsolutePath(canonical)) {
            return error.InvalidRoot;
        }

        var canonical_dir = std.fs.openDirAbsolute(canonical, .{ .no_follow = true }) catch
            return error.InvalidRoot;
        errdefer canonical_dir.close();
        const canonical_identity = ObjectIdentity.read(.{ .handle = canonical_dir.fd }) catch
            return error.InvalidRoot;
        if (canonical_identity.kind != .directory or
            !input_identity.sameObject(canonical_identity))
        {
            return error.InvalidRoot;
        }
        for (self.root_items.items) |root| {
            if (pathEql(root.canonical, canonical)) return error.InvalidRoot;
        }
        self.root_items.appendAssumeCapacity(.{
            .input = input,
            .canonical = canonical,
            .dir = canonical_dir,
            .identity = canonical_identity,
        });
    }
};

fn canonicalPathFromHandle(
    allocator: std.mem.Allocator,
    handle: std.fs.File.Handle,
    input: []const u8,
) Error![]u8 {
    if (builtin.os.tag != .windows) {
        return std.fs.realpathAlloc(allocator, input) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidRoot,
        };
    }

    var buffer: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const length = GetFinalPathNameByHandleW(
        handle,
        &buffer,
        @intCast(buffer.len),
        std.os.windows.FILE_NAME_NORMALIZED | std.os.windows.VOLUME_NAME_DOS,
    );
    if (length == 0 or @as(usize, length) >= buffer.len) return error.InvalidRoot;

    var canonical_wide = buffer[0..length];
    const extended_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    if (std.mem.startsWith(u16, canonical_wide, extended_prefix)) {
        canonical_wide = canonical_wide[extended_prefix.len..];
    }
    return std.unicode.wtf16LeToWtf8Alloc(allocator, canonical_wide);
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    resolver: *const Resolver,
    cancellation: Cancellation,
    dependency_items: std.ArrayList(Dependency) = .empty,
    edge_items: std.ArrayList(Edge) = .empty,
    attempts: u64 = 0,
    glob_entries: usize = 0,
    bytes: u64 = 0,
    closed: bool = false,

    pub fn deinit(self: *Session) void {
        for (self.edge_items.items) |edge| {
            if (edge.parent_url) |parent_url| self.allocator.free(parent_url);
            self.allocator.free(edge.child_url);
        }
        self.edge_items.deinit(self.allocator);
        for (self.dependency_items.items) |dependency| {
            self.allocator.free(dependency.url);
        }
        self.dependency_items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn close(self: *Session) void {
        self.closed = true;
    }

    pub fn dependencies(self: *const Session) []const Dependency {
        return self.dependency_items.items;
    }

    pub fn edges(self: *const Session) []const Edge {
        return self.edge_items.items;
    }

    pub fn stats(self: *const Session) Stats {
        return .{
            .attempts = self.attempts,
            .files = self.dependency_items.items.len,
            .bytes = self.bytes,
        };
    }

    pub fn load(self: *Session, candidate_url: []const u8, options: LoadOptions) Error!Loaded {
        if (self.closed) return error.SessionClosed;
        try self.cancellation.check(.resolve);
        if (self.attempts >= self.resolver.limits.max_attempts) {
            return error.AttemptLimitExceeded;
        }
        self.attempts += 1;
        try self.validateAncestry(options.ancestry);

        var resolved = try self.resolveCandidate(candidate_url);
        defer resolved.deinit(self.allocator);
        try self.cancellation.check(.open);

        var file = try openFileNoFollow(resolved.parent, resolved.basename);
        defer file.close();
        const before = try ObjectIdentity.read(file);
        switch (before.kind) {
            .sym_link => return error.Symlink,
            .directory => return error.IsDirectory,
            .file => {},
            else => return error.NotRegular,
        }

        const canonical_path = canonicalPathFromHandle(
            self.allocator,
            file.handle,
            resolved.absolute,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileChanged,
        };
        defer self.allocator.free(canonical_path);
        if (!containsCanonical(self.resolver, canonical_path)) return error.PathEscape;
        const canonical_identity = try self.identityAtCanonical(canonical_path);
        if (!before.sameStable(canonical_identity)) return error.FileChanged;
        const canonical_url = try pathToFileUrl(self.allocator, canonical_path);
        errdefer self.allocator.free(canonical_url);
        for (options.ancestry) |ancestor| {
            if (std.mem.eql(u8, ancestor, canonical_url)) return error.Cycle;
        }

        const is_new_dependency = !containsDependency(self.dependency_items.items, canonical_url);
        if (is_new_dependency and
            self.dependency_items.items.len >= self.resolver.limits.max_files)
        {
            return error.FileCountExceeded;
        }
        const parent_url = if (options.ancestry.len == 0)
            null
        else
            options.ancestry[options.ancestry.len - 1];
        const is_new_edge = !containsEdge(self.edge_items.items, parent_url, canonical_url);
        if (is_new_edge and parent_url != null and
            try self.wouldCreateGraphCycle(parent_url.?, canonical_url))
        {
            return error.Cycle;
        }

        const contents = try self.stableRead(
            file,
            resolved.parent,
            resolved.basename,
            resolved.absolute,
            canonical_path,
            before,
        );
        errdefer self.allocator.free(contents);

        try self.dependency_items.ensureUnusedCapacity(
            self.allocator,
            @intFromBool(is_new_dependency),
        );
        try self.edge_items.ensureUnusedCapacity(
            self.allocator,
            @intFromBool(is_new_edge),
        );
        const dependency_url = if (is_new_dependency)
            try self.allocator.dupe(u8, canonical_url)
        else
            null;
        errdefer if (dependency_url) |owned| self.allocator.free(owned);
        const edge_parent = if (is_new_edge and parent_url != null)
            try self.allocator.dupe(u8, parent_url.?)
        else
            null;
        errdefer if (edge_parent) |owned| self.allocator.free(owned);
        const edge_child = if (is_new_edge)
            try self.allocator.dupe(u8, canonical_url)
        else
            null;
        errdefer if (edge_child) |owned| self.allocator.free(owned);
        try self.cancellation.check(.complete);

        if (dependency_url) |owned| {
            self.dependency_items.appendAssumeCapacity(.{ .url = owned, .kind = options.kind });
        }
        if (edge_child) |owned_child| {
            self.edge_items.appendAssumeCapacity(.{
                .parent_url = edge_parent,
                .child_url = owned_child,
                .kind = options.kind,
            });
        }
        self.bytes += contents.len;
        return .{
            .url = canonical_url,
            .contents = contents,
            .allocator = self.allocator,
        };
    }

    /// Enumerates one confined local `*`, `?`, or `**` pattern. Enumeration
    /// grants no file bytes and records no dependency; every returned candidate
    /// must still pass through `load`, which owns stable reads and graph facts.
    pub fn glob(
        self: *Session,
        pattern_url: []const u8,
        ancestry: []const []const u8,
    ) Error!Globbed {
        if (self.closed) return error.SessionClosed;
        try self.cancellation.check(.resolve);
        try self.validateAncestry(ancestry);
        const pattern_path = try fileUrlToPath(self.allocator, pattern_url);
        defer self.allocator.free(pattern_path);
        const match = lexicalRoot(self.resolver, pattern_path) orelse return error.PathEscape;
        try verifyRootPath(match.root);
        const relative = relativePath(match.base, pattern_path);
        if (relative.len == 0) return error.InvalidGlob;

        var components: std.ArrayList([]const u8) = .empty;
        defer components.deinit(self.allocator);
        var iterator = std.mem.tokenizeAny(u8, relative, nativeSeparators());
        var has_pattern = false;
        while (iterator.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, "..") or
                std.mem.indexOfAny(u8, component, "[]{}\x00\r\n") != null)
            {
                return error.InvalidGlob;
            }
            has_pattern = has_pattern or std.mem.indexOfAny(u8, component, "*?") != null;
            try components.append(self.allocator, component);
        }
        if (!has_pattern or components.items.len == 0) return error.InvalidGlob;

        var root_dir = std.fs.openDirAbsolute(match.root.canonical, .{
            .iterate = true,
            .no_follow = true,
        }) catch return error.Unreadable;
        defer root_dir.close();
        const root_identity = ObjectIdentity.read(.{ .handle = root_dir.fd }) catch
            return error.Unreadable;
        if (!match.root.identity.sameObject(root_identity) or
            root_identity.kind != .directory)
        {
            return error.FileChanged;
        }

        var urls: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (urls.items) |url| self.allocator.free(url);
            urls.deinit(self.allocator);
        }
        try self.walkGlob(
            root_dir,
            match.root.canonical,
            components.items,
            0,
            ancestry.len,
            &urls,
        );
        std.mem.sort([]const u8, urls.items, {}, stringLessThan);
        return .{ .urls = try urls.toOwnedSlice(self.allocator), .allocator = self.allocator };
    }

    fn walkGlob(
        self: *Session,
        directory: std.fs.Dir,
        absolute_directory: []const u8,
        components: []const []const u8,
        component_index: usize,
        depth: usize,
        urls: *std.ArrayList([]const u8),
    ) Error!void {
        try self.cancellation.check(.path_component);
        if (component_index >= components.len) return;
        if (depth >= self.resolver.limits.max_depth) return error.DepthLimitExceeded;
        const component = components[component_index];
        const recursive = std.mem.eql(u8, component, "**");
        const patterned = std.mem.indexOfAny(u8, component, "*?") != null;
        const terminal = component_index + 1 == components.len;

        if (!patterned) {
            const child_absolute = try std.fs.path.join(
                self.allocator,
                &.{ absolute_directory, component },
            );
            defer self.allocator.free(child_absolute);
            if (terminal) {
                try self.appendGlobUrl(urls, child_absolute);
                return;
            }
            var child = directory.openDir(component, .{
                .iterate = true,
                .no_follow = true,
            }) catch |failure| return mapParentOpenError(failure);
            defer child.close();
            try self.walkGlob(
                child,
                child_absolute,
                components,
                component_index + 1,
                depth + 1,
                urls,
            );
            return;
        }

        const directory_before = try ObjectIdentity.read(.{ .handle = directory.fd });
        var entries = try readGlobEntries(
            self.allocator,
            directory,
            &self.glob_entries,
            self.resolver.limits.max_attempts,
        );
        defer entries.deinit(self.allocator);
        if (recursive) {
            if (terminal) return error.InvalidGlob;
            var zero_directory = std.fs.openDirAbsolute(absolute_directory, .{
                .iterate = true,
                .no_follow = true,
            }) catch return error.FileChanged;
            defer zero_directory.close();
            const zero_identity = ObjectIdentity.read(.{ .handle = zero_directory.fd }) catch
                return error.FileChanged;
            if (!directory_before.sameStable(zero_identity)) return error.FileChanged;
            try self.walkGlob(
                zero_directory,
                absolute_directory,
                components,
                component_index + 1,
                depth,
                urls,
            );
        }
        for (entries.items) |entry| {
            if (!recursive and !globComponentMatches(component, entry.name)) continue;
            if (entry.kind == .sym_link) return error.Symlink;
            const child_absolute = try std.fs.path.join(
                self.allocator,
                &.{ absolute_directory, entry.name },
            );
            defer self.allocator.free(child_absolute);
            if (!recursive and terminal) {
                if (entry.kind != .directory) try self.appendGlobUrl(urls, child_absolute);
                continue;
            }
            if (entry.kind != .directory) continue;
            var child = directory.openDir(entry.name, .{
                .iterate = true,
                .no_follow = true,
            }) catch |failure| return mapParentOpenError(failure);
            defer child.close();
            try self.walkGlob(
                child,
                child_absolute,
                components,
                if (recursive) component_index else component_index + 1,
                depth + 1,
                urls,
            );
        }
        const directory_after = try ObjectIdentity.read(.{ .handle = directory.fd });
        if (!directory_before.sameStable(directory_after)) return error.FileChanged;
    }

    fn appendGlobUrl(
        self: *Session,
        urls: *std.ArrayList([]const u8),
        absolute: []const u8,
    ) Error!void {
        if (urls.items.len >= self.resolver.limits.max_files) {
            return error.FileCountExceeded;
        }
        const url = try pathToFileUrl(self.allocator, absolute);
        errdefer self.allocator.free(url);
        try urls.append(self.allocator, url);
    }

    fn validateAncestry(self: *Session, ancestry: []const []const u8) Error!void {
        if (ancestry.len > hard_max_depth) return error.DepthLimitExceeded;
        for (ancestry, 0..) |ancestor, index| {
            const path = fileUrlToPath(self.allocator, ancestor) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidAncestry,
            };
            defer self.allocator.free(path);
            if (!containsCanonical(self.resolver, path)) return error.InvalidAncestry;
            const canonical_url = pathToFileUrl(self.allocator, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidAncestry,
            };
            defer self.allocator.free(canonical_url);
            if (!std.mem.eql(u8, canonical_url, ancestor)) return error.InvalidAncestry;
            for (ancestry[0..index]) |prior| {
                if (std.mem.eql(u8, prior, ancestor)) return error.Cycle;
            }
        }
        if (ancestry.len + 1 > self.resolver.limits.max_depth) {
            return error.DepthLimitExceeded;
        }
    }

    fn resolveCandidate(self: *Session, candidate_url: []const u8) Error!Resolved {
        const absolute = try fileUrlToPath(self.allocator, candidate_url);
        errdefer self.allocator.free(absolute);
        const match = lexicalRoot(self.resolver, absolute) orelse return error.PathEscape;
        try verifyRootPath(match.root);
        const relative = relativePath(match.base, absolute);
        if (relative.len == 0) return error.IsDirectory;

        var components = std.mem.tokenizeAny(u8, relative, nativeSeparators());
        var current_component = components.next() orelse return error.IsDirectory;
        var current_dir = match.root.dir;
        var owned_parent: ?std.fs.Dir = null;
        errdefer if (owned_parent) |*dir| dir.close();
        while (components.next()) |next_component| {
            try self.cancellation.check(.path_component);
            var next_dir = current_dir.openDir(current_component, .{ .no_follow = true }) catch |err| {
                if (err == error.NotDir) {
                    var probe = openFileNoFollow(current_dir, current_component) catch |probe_error| {
                        return switch (probe_error) {
                            error.Symlink => error.Symlink,
                            error.Missing => error.Missing,
                            else => error.ParentNotDirectory,
                        };
                    };
                    defer probe.close();
                    const identity = ObjectIdentity.read(probe) catch return error.Unreadable;
                    if (identity.kind == .sym_link) return error.Symlink;
                    return error.ParentNotDirectory;
                }
                return mapParentOpenError(err);
            };
            const identity = ObjectIdentity.read(.{ .handle = next_dir.fd }) catch {
                next_dir.close();
                return error.Unreadable;
            };
            if (identity.kind != .directory) {
                next_dir.close();
                if (identity.kind == .sym_link) return error.Symlink;
                return error.ParentNotDirectory;
            }
            if (owned_parent) |*dir| dir.close();
            owned_parent = next_dir;
            current_dir = next_dir;
            current_component = next_component;
        }
        return .{
            .absolute = absolute,
            .parent = current_dir,
            .owned_parent = owned_parent,
            .basename = current_component,
        };
    }

    fn stableRead(
        self: *Session,
        file: std.fs.File,
        parent: std.fs.Dir,
        basename: []const u8,
        absolute: []const u8,
        canonical_path: []const u8,
        before: ObjectIdentity,
    ) Error![]u8 {
        if (before.size > self.resolver.limits.max_file_bytes) {
            return error.FileLimitExceeded;
        }
        const next_total = std.math.add(u64, self.bytes, before.size) catch
            return error.TotalLimitExceeded;
        if (next_total > self.resolver.limits.max_total_bytes) {
            return error.TotalLimitExceeded;
        }
        const size: usize = @intCast(before.size);
        const contents = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(contents);
        const parent_before = try ObjectIdentity.read(.{ .handle = parent.fd });

        var offset: usize = 0;
        while (offset < size) {
            try self.cancellation.check(.read);
            const amount = readAt(
                file,
                contents[offset..@min(size, offset + read_chunk_bytes)],
                offset,
            ) catch return error.Unreadable;
            if (amount == 0) return error.FileChanged;
            offset += amount;
        }
        try self.cancellation.check(.read);
        var extra: [1]u8 = undefined;
        const extra_bytes = readAt(file, &extra, size) catch return error.Unreadable;
        if (extra_bytes != 0) {
            if (size >= self.resolver.limits.max_file_bytes) return error.FileLimitExceeded;
            return error.FileChanged;
        }

        try self.cancellation.check(.verify);
        const after = try ObjectIdentity.read(file);
        if (!before.sameStable(after) or after.kind != .file) return error.FileChanged;
        var reopened = openFileNoFollow(parent, basename) catch return error.FileChanged;
        defer reopened.close();
        const path_identity = ObjectIdentity.read(reopened) catch return error.FileChanged;
        if (!after.sameStable(path_identity) or path_identity.kind != .file) {
            return error.FileChanged;
        }
        const parent_after = ObjectIdentity.read(.{ .handle = parent.fd }) catch
            return error.FileChanged;
        if (!parent_before.sameObject(parent_after)) return error.FileChanged;

        const canonical_after = canonicalPathFromHandle(
            self.allocator,
            reopened.handle,
            absolute,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileChanged,
        };
        defer self.allocator.free(canonical_after);
        if (!pathEql(canonical_path, canonical_after) or
            !containsCanonical(self.resolver, canonical_after))
        {
            return error.FileChanged;
        }
        const canonical_identity = try self.identityAtCanonical(canonical_after);
        if (!after.sameStable(canonical_identity)) return error.FileChanged;
        try self.cancellation.check(.verify);
        return contents;
    }

    fn identityAtCanonical(self: *Session, canonical_path: []const u8) Error!ObjectIdentity {
        const root = canonicalRoot(self.resolver, canonical_path) orelse
            return error.FileChanged;
        try verifyRootPath(root);
        const relative = relativePath(root.canonical, canonical_path);
        if (relative.len == 0) return error.FileChanged;

        var components = std.mem.tokenizeAny(u8, relative, nativeSeparators());
        var current_component = components.next() orelse return error.FileChanged;
        var current_dir = root.dir;
        var owned_parent: ?std.fs.Dir = null;
        defer if (owned_parent) |*dir| dir.close();
        while (components.next()) |next_component| {
            try self.cancellation.check(.verify);
            var next_dir = current_dir.openDir(current_component, .{ .no_follow = true }) catch
                return error.FileChanged;
            const identity = ObjectIdentity.read(.{ .handle = next_dir.fd }) catch {
                next_dir.close();
                return error.FileChanged;
            };
            if (identity.kind != .directory) {
                next_dir.close();
                return error.FileChanged;
            }
            if (owned_parent) |*dir| dir.close();
            owned_parent = next_dir;
            current_dir = next_dir;
            current_component = next_component;
        }
        var file = openFileNoFollow(current_dir, current_component) catch
            return error.FileChanged;
        defer file.close();
        const identity = ObjectIdentity.read(file) catch return error.FileChanged;
        if (identity.kind != .file) return error.FileChanged;
        return identity;
    }

    fn wouldCreateGraphCycle(
        self: *Session,
        parent_url: []const u8,
        child_url: []const u8,
    ) Error!bool {
        if (std.mem.eql(u8, parent_url, child_url)) return true;
        var pending: std.ArrayList([]const u8) = .empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, child_url);
        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            try self.cancellation.check(.graph);
            const current = pending.items[index];
            if (std.mem.eql(u8, current, parent_url)) return true;
            for (self.edge_items.items) |edge| {
                const edge_parent = edge.parent_url orelse continue;
                if (!std.mem.eql(u8, edge_parent, current)) continue;
                if (!containsString(pending.items, edge.child_url)) {
                    try pending.append(self.allocator, edge.child_url);
                }
            }
        }
        return false;
    }
};

const GlobEntry = struct {
    name: []u8,
    kind: std.fs.File.Kind,
};

const GlobEntries = struct {
    items: []GlobEntry,

    fn deinit(self: *GlobEntries, allocator: std.mem.Allocator) void {
        for (self.items) |entry| allocator.free(entry.name);
        if (self.items.len > 0) allocator.free(self.items);
        self.* = undefined;
    }
};

fn readGlobEntries(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    consumed: *usize,
    limit: usize,
) Error!GlobEntries {
    var entries: std.ArrayList(GlobEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }
    var iterator = directory.iterate();
    while (iterator.next() catch return error.Unreadable) |entry| {
        if (consumed.* >= limit) return error.AttemptLimitExceeded;
        consumed.* += 1;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try entries.append(allocator, .{ .name = name, .kind = entry.kind });
    }
    std.mem.sort(GlobEntry, entries.items, {}, globEntryLessThan);
    return .{ .items = try entries.toOwnedSlice(allocator) };
}

fn globEntryLessThan(_: void, left: GlobEntry, right: GlobEntry) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn globComponentMatches(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var star_index: ?usize = null;
    var star_candidate: usize = 0;
    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == candidate[candidate_index]))
        {
            pattern_index += 1;
            candidate_index += 1;
            continue;
        }
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_candidate = candidate_index;
            continue;
        }
        if (star_index) |star| {
            pattern_index = star + 1;
            star_candidate += 1;
            candidate_index = star_candidate;
            continue;
        }
        return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

const RootMatch = struct {
    root: *const Root,
    base: []const u8,
};

fn containsCanonical(self: *const Resolver, candidate: []const u8) bool {
    for (self.root_items.items) |*root| {
        if (containsPath(root.canonical, candidate)) return true;
    }
    return false;
}

fn lexicalRoot(self: *const Resolver, candidate: []const u8) ?RootMatch {
    for (self.root_items.items) |*root| {
        if (containsPath(root.input, candidate)) return .{ .root = root, .base = root.input };
        if (containsPath(root.canonical, candidate)) return .{ .root = root, .base = root.canonical };
    }
    return null;
}

fn canonicalRoot(self: *const Resolver, candidate: []const u8) ?*const Root {
    for (self.root_items.items) |*root| {
        if (containsPath(root.canonical, candidate)) return root;
    }
    return null;
}

fn verifyRootPath(root: *const Root) Error!void {
    var current = std.fs.openDirAbsolute(root.canonical, .{ .no_follow = true }) catch
        return error.FileChanged;
    defer current.close();
    const identity = ObjectIdentity.read(.{ .handle = current.fd }) catch
        return error.FileChanged;
    if (identity.kind != .directory or !root.identity.sameObject(identity)) {
        return error.FileChanged;
    }
}

const Resolved = struct {
    absolute: []u8,
    parent: std.fs.Dir,
    owned_parent: ?std.fs.Dir,
    basename: []const u8,

    fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        if (self.owned_parent) |*dir| dir.close();
        allocator.free(self.absolute);
        self.* = undefined;
    }
};

pub fn pathToFileUrl(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    if (!validPathInput(path) or !isSupportedAbsolutePath(path)) return error.InvalidUrl;
    const normalized = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(normalized);
    if (normalized.len == 0 or normalized.len > max_root_bytes or
        !isSupportedAbsolutePath(normalized))
    {
        return error.InvalidUrl;
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "file://");
    if (builtin.os.tag == .windows) try output.append(allocator, '/');
    for (normalized) |byte| {
        const value = if (builtin.os.tag == .windows and byte == '\\') '/' else byte;
        if (isUrlPathByte(value)) {
            try output.append(allocator, value);
        } else {
            try output.append(allocator, '%');
            try output.append(allocator, hexDigit(value >> 4));
            try output.append(allocator, hexDigit(value & 0x0f));
        }
    }
    if (output.items.len > max_url_bytes) return error.InvalidUrl;
    return try output.toOwnedSlice(allocator);
}

/// Decodes one canonical local file URL for language-owned candidate search.
/// Opening and confinement remain exclusively owned by `Session.load`.
pub fn fileUrlToPath(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    if (value.len == 0 or value.len > max_url_bytes or
        std.mem.indexOfAny(u8, value, "\x00\r\n\\") != null)
    {
        return error.InvalidUrl;
    }
    const uri = std.Uri.parse(value) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file")) return error.SchemeNotAllowed;
    if (uri.user != null or uri.password != null or uri.port != null or
        uri.query != null or uri.fragment != null)
    {
        return error.InvalidUrl;
    }
    if (uri.host) |host| {
        if (!host.isEmpty()) return error.InvalidUrl;
    }
    const encoded = switch (uri.path) {
        .raw => |raw| raw,
        .percent_encoded => |percent_encoded| percent_encoded,
    };
    if (encoded.len == 0) return error.InvalidUrl;
    const decoded_storage = try allocator.alloc(u8, encoded.len);
    defer allocator.free(decoded_storage);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < encoded.len) {
        var byte = encoded[input_index];
        if (byte == '%') {
            if (input_index + 2 >= encoded.len) return error.InvalidUrl;
            const high = hexValue(encoded[input_index + 1]) orelse return error.InvalidUrl;
            const low = hexValue(encoded[input_index + 2]) orelse return error.InvalidUrl;
            byte = (high << 4) | low;
            if (byte == '/' or byte == '\\' or byte == 0 or byte == '\r' or byte == '\n') {
                return error.InvalidUrl;
            }
            input_index += 3;
        } else {
            if (byte == 0 or byte == '\r' or byte == '\n' or byte == '\\') {
                return error.InvalidUrl;
            }
            input_index += 1;
        }
        decoded_storage[output_index] = byte;
        output_index += 1;
    }
    var decoded = decoded_storage[0..output_index];
    if (builtin.os.tag == .windows) {
        if (decoded.len >= 3 and decoded[0] == '/' and
            std.ascii.isAlphabetic(decoded[1]) and decoded[2] == ':')
        {
            decoded = decoded[1..];
        }
        for (decoded) |*byte| {
            if (byte.* == '/') byte.* = '\\';
        }
    }
    if (!isSupportedAbsolutePath(decoded) or decoded.len > max_root_bytes) {
        return error.InvalidUrl;
    }
    return try std.fs.path.resolve(allocator, &.{decoded});
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_file_bytes == 0 or limits.max_file_bytes > hard_max_file_bytes or
        limits.max_total_bytes == 0 or limits.max_total_bytes > hard_max_total_bytes or
        limits.max_files == 0 or limits.max_files > hard_max_files or
        limits.max_attempts == 0 or limits.max_attempts > hard_max_attempts or
        limits.max_depth == 0 or limits.max_depth > hard_max_depth)
    {
        return error.InvalidLimits;
    }
}

fn validPathInput(path: []const u8) bool {
    return path.len > 0 and path.len <= max_root_bytes and
        std.mem.indexOfAny(u8, path, "\x00\r\n") == null;
}

fn isSupportedAbsolutePath(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const parsed = std.fs.path.windowsParsePath(path);
        return parsed.is_abs and parsed.kind == .Drive;
    }
    return std.fs.path.isAbsolutePosix(path);
}

fn rootLessThan(_: void, left: Root, right: Root) bool {
    const folded = pathOrder(left.canonical, right.canonical);
    if (folded != .eq) return folded == .lt;
    return std.mem.order(u8, left.canonical, right.canonical) == .lt;
}

fn pathOrder(left: []const u8, right: []const u8) std.math.Order {
    const length = @min(left.len, right.len);
    for (left[0..length], right[0..length]) |left_byte, right_byte| {
        const folded_left = pathByte(left_byte);
        const folded_right = pathByte(right_byte);
        if (folded_left < folded_right) return .lt;
        if (folded_left > folded_right) return .gt;
    }
    return std.math.order(left.len, right.len);
}

fn pathEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (pathByte(left_byte) != pathByte(right_byte)) return false;
    }
    return true;
}

fn pathByte(byte: u8) u8 {
    if (builtin.os.tag != .windows) return byte;
    if (byte == '/') return '\\';
    return std.ascii.toLower(byte);
}

fn containsPath(root: []const u8, candidate: []const u8) bool {
    if (candidate.len < root.len) return false;
    for (root, candidate[0..root.len]) |root_byte, candidate_byte| {
        if (pathByte(root_byte) != pathByte(candidate_byte)) return false;
    }
    if (candidate.len == root.len) return true;
    if (isNativeSeparator(root[root.len - 1])) return true;
    return isNativeSeparator(candidate[root.len]);
}

fn relativePath(root: []const u8, candidate: []const u8) []const u8 {
    if (candidate.len == root.len) return "";
    var index = root.len;
    if (!isNativeSeparator(root[root.len - 1])) index += 1;
    return candidate[index..];
}

fn nativeSeparators() []const u8 {
    return if (builtin.os.tag == .windows) "/\\" else "/";
}

fn isNativeSeparator(byte: u8) bool {
    return byte == '/' or (builtin.os.tag == .windows and byte == '\\');
}

fn isUrlPathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/", byte) != null;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

fn hexValue(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

fn containsDependency(items: []const Dependency, url: []const u8) bool {
    for (items) |dependency| {
        if (std.mem.eql(u8, dependency.url, url)) return true;
    }
    return false;
}

fn containsEdge(items: []const Edge, parent_url: ?[]const u8, child_url: []const u8) bool {
    for (items) |edge| {
        if (!optionalStringEql(edge.parent_url, parent_url)) continue;
        if (std.mem.eql(u8, edge.child_url, child_url)) return true;
    }
    return false;
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn containsString(items: []const []const u8, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn mapParentOpenError(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.Missing,
        error.NotDir => error.ParentNotDirectory,
        error.SymLinkLoop => error.Symlink,
        error.AccessDenied, error.PermissionDenied => error.Unreadable,
        else => error.Unreadable,
    };
}

fn mapFileOpenError(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.Missing,
        error.NotDir => error.ParentNotDirectory,
        error.IsDir => error.IsDirectory,
        error.SymLinkLoop => error.Symlink,
        error.AccessDenied, error.PermissionDenied => error.Unreadable,
        else => error.Unreadable,
    };
}

fn openFileNoFollow(parent: std.fs.Dir, basename: []const u8) Error!std.fs.File {
    if (basename.len == 0 or std.mem.indexOfAny(u8, basename, "\x00/\\") != null) {
        return error.InvalidUrl;
    }
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const path_w = windows.sliceToPrefixedFileW(parent.fd, basename) catch
            return error.Unreadable;
        const handle = windows.OpenFile(path_w.span(), .{
            .dir = parent.fd,
            .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE,
            .creation = windows.FILE_OPEN,
            .filter = .any,
            .follow_symlinks = false,
        }) catch |err| return mapFileOpenError(err);
        return .{ .handle = handle };
    }
    if (builtin.os.tag == .wasi) return error.UnsupportedPlatform;

    const basename_z = std.posix.toPosixPath(basename) catch return error.Unreadable;
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "NOFOLLOW")) flags.NOFOLLOW = true;
    if (@hasField(std.posix.O, "NONBLOCK")) flags.NONBLOCK = true;
    const descriptor = std.posix.openatZ(parent.fd, &basename_z, flags, 0) catch |err|
        return mapFileOpenError(err);
    return .{ .handle = descriptor };
}

fn readAt(file: std.fs.File, buffer: []u8, offset: u64) Error!usize {
    if (builtin.os.tag != .windows) {
        return file.pread(buffer, offset) catch error.Unreadable;
    }
    const windows = std.os.windows;
    const wanted: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
    var amount: windows.DWORD = 0;
    var overlapped = windows.OVERLAPPED{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{ .DUMMYSTRUCTNAME = .{
            .Offset = @truncate(offset),
            .OffsetHigh = @truncate(offset >> 32),
        } },
        .hEvent = null,
    };
    if (windows.kernel32.ReadFile(
        file.handle,
        buffer.ptr,
        wanted,
        &amount,
        &overlapped,
    ) != 0) return amount;
    return switch (windows.GetLastError()) {
        .IO_PENDING => blk: {
            var completed: windows.DWORD = 0;
            if (windows.kernel32.GetOverlappedResult(
                file.handle,
                &overlapped,
                &completed,
                @intFromBool(true),
            ) != 0) break :blk completed;
            break :blk switch (windows.GetLastError()) {
                // An overlapped read exactly at the end of a regular file
                // reports HANDLE_EOF here rather than from ReadFile itself.
                .HANDLE_EOF => 0,
                else => error.Unreadable,
            };
        },
        .HANDLE_EOF => 0,
        else => error.Unreadable,
    };
}

fn volumeIdentity(file: std.fs.File) Error!u64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var io_status: windows.IO_STATUS_BLOCK = undefined;
        var volume_info: windows.FILE_FS_VOLUME_INFORMATION = undefined;
        switch (windows.ntdll.NtQueryVolumeInformationFile(
            file.handle,
            &io_status,
            &volume_info,
            @sizeOf(windows.FILE_FS_VOLUME_INFORMATION),
            .FileFsVolumeInformation,
        )) {
            .SUCCESS, .BUFFER_OVERFLOW => {},
            else => return error.Unreadable,
        }
        return volume_info.VolumeSerialNumber;
    }
    if (builtin.os.tag == .wasi) return 0;
    const stat = std.posix.fstat(file.handle) catch return error.Unreadable;
    const Device = @TypeOf(stat.dev);
    const UnsignedDevice = std.meta.Int(.unsigned, @bitSizeOf(Device));
    const identity: UnsignedDevice = @bitCast(stat.dev);
    return @intCast(identity);
}

pub fn inodeIdentity(inode: anytype) u128 {
    const Inode = @TypeOf(inode);
    const UnsignedInode = std.meta.Int(.unsigned, @bitSizeOf(Inode));
    const identity: UnsignedInode = @bitCast(inode);
    return identity;
}

test {
    _ = Resolver;
    _ = Session;
}
