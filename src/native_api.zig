//! Pre-graduation Zig API route for the self-contained stylesheet frontends.
//!
//! This explicit experimental namespace does not graduate a public language
//! row or authorize CLI, JavaScript, package, documentation, or release claims.
//! Compilation currently exposes owned CSS plus opaque watch invalidation;
//! diagnostics, dependency identities, and source maps remain behind their
//! separately declared NATIVE-006 routing gates.

const std = @import("std");
const native_compiler = @import("preprocessor/compiler.zig");
const native_resolver = @import("preprocessor/resolver.zig");

pub const max_entry_input_bytes: usize = 10 * 1024 * 1024;

pub const Syntax = enum {
    scss,
    sass,
    less,
    stylus,
};

pub const OutputFormat = enum {
    pretty,
    minified,
};

pub const Options = struct {
    syntax: Syntax,
    /// Borrowed canonical directory capabilities for this compilation only.
    root_paths: []const []const u8,
    format: OutputFormat = .pretty,
    /// Applies to the already-loaded entry bytes. Imported resources retain
    /// the shared resolver and language evaluator ceilings.
    max_input_bytes: usize = max_entry_input_bytes,
    /// Retain an opaque snapshot of successfully loaded local inputs so the
    /// native CLI can poll for watch invalidation without exposing dependency
    /// identities through the still-pending result-facts route.
    watch: bool = false,
};

pub const Error = std.mem.Allocator.Error || error{
    CompilationFailed,
    InvalidOptions,
    InvalidRoot,
    InvalidSourcePath,
    PathEscape,
    ResourceLimitExceeded,
};

const WatchFingerprint = union(enum) {
    contents: u64,
    unavailable: anyerror,

    fn eql(left: WatchFingerprint, right: WatchFingerprint) bool {
        return switch (left) {
            .contents => |left_hash| switch (right) {
                .contents => |right_hash| left_hash == right_hash,
                .unavailable => false,
            },
            .unavailable => |left_error| switch (right) {
                .contents => false,
                .unavailable => |right_error| @intFromError(left_error) == @intFromError(right_error),
            },
        };
    }
};

const WatchItem = struct {
    url: []u8,
    fingerprint: WatchFingerprint,
};

const WatchState = struct {
    allocator: std.mem.Allocator,
    authority: native_resolver.Resolver,
    entry_url: []u8,
    max_input_bytes: usize,
    items: []WatchItem,

    fn init(
        allocator: std.mem.Allocator,
        compiled: *const native_compiler.Result,
        entry_url: []const u8,
        root_paths: []const []const u8,
        max_input_bytes: usize,
    ) Error!WatchState {
        const dependencies = compiled.dependencies();
        var authority = native_resolver.Resolver.init(allocator, root_paths, .{}) catch |err|
            return mapWatchPathError(err);
        errdefer authority.deinit();
        const owned_entry_url = try allocator.dupe(u8, entry_url);
        errdefer allocator.free(owned_entry_url);

        var items: []WatchItem = &.{};
        if (dependencies.len > 0) items = try allocator.alloc(WatchItem, dependencies.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| allocator.free(item.url);
            if (items.len > 0) allocator.free(items);
        }
        for (dependencies, 0..) |dependency, index| {
            const url = try allocator.dupe(u8, dependency.url);
            errdefer allocator.free(url);
            const bytes = dependencySourceBytes(compiled, dependency.url) orelse
                return error.CompilationFailed;
            items[index] = .{
                .url = url,
                .fingerprint = .{ .contents = contentHash(bytes) },
            };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .authority = authority,
            .entry_url = owned_entry_url,
            .max_input_bytes = max_input_bytes,
            .items = items,
        };
    }

    fn deinit(self: *WatchState) void {
        for (self.items) |item| self.allocator.free(item.url);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.allocator.free(self.entry_url);
        self.authority.deinit();
        self.* = undefined;
    }

    fn readEntry(self: *WatchState, allocator: std.mem.Allocator) Error![]u8 {
        var session = self.authority.createSession(allocator, .{});
        defer session.deinit();
        var loaded = session.load(self.entry_url, .{
            .kind = .reference,
            .ancestry = &.{},
        }) catch |err| return mapWatchReadError(err);
        defer loaded.deinit();
        if (loaded.contents.len > self.max_input_bytes) return error.ResourceLimitExceeded;
        return allocator.dupe(u8, loaded.contents);
    }

    fn poll(self: *WatchState) std.mem.Allocator.Error!bool {
        if (self.items.len == 0) return false;
        var session = self.authority.createSession(self.allocator, .{});
        defer session.deinit();

        var changed = false;
        for (self.items) |*item| {
            var loaded = session.load(item.url, .{
                .kind = .reference,
                .ancestry = &.{},
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const next = WatchFingerprint{ .unavailable = err };
                    if (!item.fingerprint.eql(next)) {
                        item.fingerprint = next;
                        changed = true;
                    }
                    continue;
                },
            };
            defer loaded.deinit();
            const next = WatchFingerprint{ .contents = contentHash(loaded.contents) };
            if (!item.fingerprint.eql(next)) {
                item.fingerprint = next;
                changed = true;
            }
        }
        return changed;
    }
};

fn contentHash(bytes: []const u8) u64 {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(bytes);
    return hasher.final();
}

fn dependencySourceBytes(
    compiled: *const native_compiler.Result,
    dependency_url: []const u8,
) ?[]const u8 {
    const sources = compiled.sourceTable();
    for (0..sources.count()) |index| {
        const source = sources.get(.{ .value = @intCast(index) }) catch return null;
        if (std.mem.eql(u8, source.name, dependency_url)) return source.bytes;
    }
    return null;
}

fn mapWatchPathError(err: native_resolver.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompilationFailed,
    };
}

/// Move-only by convention. The CSS remains owned independently of all native
/// parser, resolver, source-table, and evaluation transaction lifetimes.
pub const CompileResult = struct {
    result_allocator: std.mem.Allocator,
    css: []const u8,
    watch_state: ?WatchState,

    pub fn take(self: *CompileResult) CompileResult {
        const moved = self.*;
        self.* = empty(self.result_allocator);
        return moved;
    }

    pub fn deinit(self: *CompileResult) void {
        const allocator = self.result_allocator;
        if (self.watch_state) |*watch_state| watch_state.deinit();
        if (self.css.len > 0) allocator.free(self.css);
        self.* = empty(allocator);
    }

    /// Reports only whether one previously loaded local input changed. File
    /// identities and dependency facts remain private to the watch route.
    pub fn pollWatchInputs(self: *CompileResult) std.mem.Allocator.Error!bool {
        if (self.watch_state) |*watch_state| return watch_state.poll();
        return false;
    }

    /// Reloads the entry through the retained confined resolver. The caller
    /// owns the returned bytes with `allocator`.
    pub fn readWatchInput(
        self: *CompileResult,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        if (self.watch_state) |*watch_state| return watch_state.readEntry(allocator);
        return error.InvalidOptions;
    }

    fn empty(allocator: std.mem.Allocator) CompileResult {
        return .{ .result_allocator = allocator, .css = &.{}, .watch_state = null };
    }
};

/// Compiles already-loaded source bytes through the single shared native
/// compiler. `entry_path` must be an absolute path lexically contained by one
/// of `root_paths`; the entry need not be read from the filesystem.
pub fn compile(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    input: []const u8,
    options: Options,
) Error!CompileResult {
    if (options.max_input_bytes == 0 or
        options.max_input_bytes > max_entry_input_bytes)
    {
        return error.InvalidOptions;
    }
    if (input.len > options.max_input_bytes) return error.ResourceLimitExceeded;

    const entry_url = native_resolver.pathToFileUrl(allocator, entry_path) catch |err|
        return mapPathError(err);
    defer allocator.free(entry_url);

    var compiled = native_compiler.compile(allocator, entry_url, input, .{
        .syntax = switch (options.syntax) {
            .scss => .scss,
            .sass => .sass,
            .less => .less,
            .stylus => .stylus,
        },
        .root_paths = options.root_paths,
        .format = switch (options.format) {
            .pretty => .pretty,
            .minified => .minified,
        },
        .source_map = false,
        .limits = .{
            .sass_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .less_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .less_evaluator = .{ .max_source_bytes = options.max_input_bytes },
            .stylus_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .stylus_evaluator = .{ .max_source_bytes = options.max_input_bytes },
        },
    }) catch |err| return mapCompileError(err);
    defer compiled.deinit();

    var watch_state = if (options.watch)
        try WatchState.init(
            allocator,
            &compiled,
            entry_url,
            options.root_paths,
            options.max_input_bytes,
        )
    else
        null;
    errdefer if (watch_state) |*state| state.deinit();
    const css = try allocator.dupe(u8, compiled.css());
    return .{
        .result_allocator = allocator,
        .css = css,
        .watch_state = watch_state,
    };
}

fn mapPathError(err: native_resolver.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSourcePath,
    };
}

fn mapWatchReadError(err: native_resolver.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PathEscape => error.PathEscape,
        error.FileLimitExceeded, error.TotalLimitExceeded => error.ResourceLimitExceeded,
        else => error.CompilationFailed,
    };
}

fn mapCompileError(err: native_compiler.Error) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.InvalidRoot) return error.InvalidRoot;
    if (err == error.PathEscape) return error.PathEscape;
    if (err == error.InvalidLimits) return error.InvalidOptions;
    const name = @errorName(err);
    if (std.mem.endsWith(u8, name, "LimitExceeded") or
        std.mem.eql(u8, name, "SourceTooLarge"))
    {
        return error.ResourceLimitExceeded;
    }
    return error.CompilationFailed;
}
