//! Native-differential Zig API route for the self-contained stylesheet frontends.
//!
//! This explicit experimental namespace is part of the documented source
//! snapshot, but does not mark a language row native-graduated or authorize a
//! release.
//! Compilation exposes owned CSS, structured diagnostics, ordered local
//! dependency identities, composed Source Map v3 bytes, and opaque watch
//! invalidation behind an explicit native-differential boundary.

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

pub const DiagnosticSeverity = enum {
    err,
    warning,
    note,
};

pub const DiagnosticCode = enum {
    syntax,
    undefined_variable,
    duplicate_binding,
    type_mismatch,
    invalid_operation,
    call_limit,
    loop_limit,
    resource_limit,
    invalid_import,
    unsupported_feature,
    internal,

    pub fn label(self: DiagnosticCode) []const u8 {
        return switch (self) {
            .syntax => "NATIVE0001",
            .undefined_variable => "NATIVE0002",
            .duplicate_binding => "NATIVE0003",
            .type_mismatch => "NATIVE0004",
            .invalid_operation => "NATIVE0005",
            .call_limit => "NATIVE0006",
            .loop_limit => "NATIVE0007",
            .resource_limit => "NATIVE0008",
            .invalid_import => "NATIVE0009",
            .unsupported_feature => "NATIVE0010",
            .internal => "NATIVE9999",
        };
    }
};

pub const SourceSpan = struct {
    start: u32,
    end: u32,
};

/// Zero-based line and UTF-16 code-unit column.
pub const SourcePosition = struct {
    line: u32,
    column: u32,
};

pub const RelatedDiagnostic = struct {
    source_name: []const u8,
    span: SourceSpan,
    start: SourcePosition,
    end: SourcePosition,
    label: []const u8,
};

/// Every slice is independently result-owned; source names are canonical
/// local file URLs retained after the private compiler source table is gone.
pub const Diagnostic = struct {
    severity: DiagnosticSeverity,
    code: DiagnosticCode,
    source_name: []const u8,
    span: SourceSpan,
    start: SourcePosition,
    end: SourcePosition,
    message: []const u8,
    related: []const RelatedDiagnostic,
};

pub const DependencyKind = enum {
    import,
    use,
    forward,
    reference,
};

/// Ordered, deduplicated local dependency fact. `url` is a canonical file URL
/// and remains owned by the result after resolver teardown.
pub const Dependency = struct {
    kind: DependencyKind,
    url: []const u8,
};

pub const Options = struct {
    syntax: Syntax,
    /// Borrowed canonical directory capabilities for this compilation only.
    root_paths: []const []const u8,
    format: OutputFormat = .pretty,
    /// Applies to the already-loaded entry bytes. Imported resources retain
    /// the shared resolver and language evaluator ceilings.
    max_input_bytes: usize = max_entry_input_bytes,
    /// Retain an opaque content snapshot of successfully loaded local inputs
    /// so the native CLI can poll for watch invalidation.
    watch: bool = false,
    /// Compose the core-emitter and native-frontend mapping stages into one
    /// result-owned Source Map v3 document over original sources.
    source_map: bool = false,
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

/// Move-only by convention. CSS and result facts remain owned independently of
/// all native parser, resolver, source-table, and transaction lifetimes.
pub const CompileResult = struct {
    result_allocator: std.mem.Allocator,
    css: []const u8,
    source_map: ?[]const u8,
    diagnostics: []const Diagnostic,
    dependencies: []const Dependency,
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
        if (self.source_map) |bytes| allocator.free(bytes);
        releaseDiagnostics(allocator, self.diagnostics);
        releaseDependencies(allocator, self.dependencies);
        self.* = empty(allocator);
    }

    /// Reports only whether one previously loaded local input changed.
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
        return .{
            .result_allocator = allocator,
            .css = &.{},
            .source_map = null,
            .diagnostics = &.{},
            .dependencies = &.{},
            .watch_state = null,
        };
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

    var outcome = native_compiler.compileReported(allocator, entry_url, input, .{
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
        .source_map = options.source_map,
        .limits = .{
            .sass_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .less_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .less_evaluator = .{ .max_source_bytes = options.max_input_bytes },
            .stylus_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .stylus_evaluator = .{ .max_source_bytes = options.max_input_bytes },
        },
    }) catch |err| return mapCompileError(err);
    return switch (outcome) {
        .success => |*compiled| success: {
            defer compiled.deinit();
            if (compiled.coreDiagnostics().len != 0) return error.CompilationFailed;
            const diagnostics = try cloneDiagnostics(
                allocator,
                compiled.sourceTable(),
                compiled.nativeDiagnostics(),
            );
            errdefer releaseDiagnostics(allocator, diagnostics);
            const dependencies = try cloneDependencies(allocator, compiled.dependencies());
            errdefer releaseDependencies(allocator, dependencies);
            const source_map = if (options.source_map)
                compiled.composeSourceMap(allocator) catch |err| return mapCompileError(err)
            else
                null;
            errdefer if (source_map) |bytes| allocator.free(bytes);
            var watch_state = if (options.watch)
                try WatchState.init(
                    allocator,
                    compiled,
                    entry_url,
                    options.root_paths,
                    options.max_input_bytes,
                )
            else
                null;
            errdefer if (watch_state) |*state| state.deinit();
            const css = try allocator.dupe(u8, compiled.css());
            break :success .{
                .result_allocator = allocator,
                .css = css,
                .source_map = source_map,
                .diagnostics = diagnostics,
                .dependencies = dependencies,
                .watch_state = watch_state,
            };
        },
        .failure => |*failure| failed: {
            defer failure.deinit();
            const diagnostics = try cloneDiagnostics(
                allocator,
                failure.sourceTable(),
                failure.diagnostics(),
            );
            break :failed .{
                .result_allocator = allocator,
                .css = &.{},
                .source_map = null,
                .diagnostics = diagnostics,
                .dependencies = &.{},
                .watch_state = null,
            };
        },
    };
}

fn cloneDiagnostics(
    allocator: std.mem.Allocator,
    sources: *const native_compiler.SourceTable,
    items: []const native_compiler.Diagnostic,
) Error![]const Diagnostic {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(Diagnostic, items.len);
    var initialized: usize = 0;
    errdefer {
        releaseDiagnosticFields(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        const source_file = sources.get(item.span.source) catch
            return error.CompilationFailed;
        const source_name = try allocator.dupe(u8, source_file.name);
        errdefer if (source_name.len > 0) allocator.free(source_name);
        const message = try allocator.dupe(u8, item.message);
        errdefer if (message.len > 0) allocator.free(message);
        const related = try cloneRelatedDiagnostics(allocator, sources, item.related);
        errdefer releaseRelatedDiagnostics(allocator, related);
        cloned[index] = .{
            .severity = mapDiagnosticSeverity(item.severity),
            .code = mapDiagnosticCode(item.code),
            .source_name = source_name,
            .span = .{ .start = item.span.start, .end = item.span.end },
            .start = positionFor(sources, item.span.source, item.span.start) catch
                return error.CompilationFailed,
            .end = positionFor(sources, item.span.source, item.span.end) catch
                return error.CompilationFailed,
            .message = message,
            .related = related,
        };
        initialized += 1;
    }
    return cloned;
}

fn cloneRelatedDiagnostics(
    allocator: std.mem.Allocator,
    sources: *const native_compiler.SourceTable,
    items: []const native_compiler.Related,
) Error![]const RelatedDiagnostic {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(RelatedDiagnostic, items.len);
    var initialized: usize = 0;
    errdefer {
        releaseRelatedFields(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        const source_file = sources.get(item.span.source) catch
            return error.CompilationFailed;
        const source_name = try allocator.dupe(u8, source_file.name);
        errdefer if (source_name.len > 0) allocator.free(source_name);
        const label = try allocator.dupe(u8, item.label);
        errdefer if (label.len > 0) allocator.free(label);
        cloned[index] = .{
            .source_name = source_name,
            .span = .{ .start = item.span.start, .end = item.span.end },
            .start = positionFor(sources, item.span.source, item.span.start) catch
                return error.CompilationFailed,
            .end = positionFor(sources, item.span.source, item.span.end) catch
                return error.CompilationFailed,
            .label = label,
        };
        initialized += 1;
    }
    return cloned;
}

fn positionFor(
    sources: *const native_compiler.SourceTable,
    source_id: native_compiler.SourceId,
    offset: u32,
) !SourcePosition {
    const position = try sources.position(source_id, offset);
    return .{ .line = position.line, .column = position.column };
}

fn mapDiagnosticSeverity(value: @FieldType(native_compiler.Diagnostic, "severity")) DiagnosticSeverity {
    return switch (value) {
        .err => .err,
        .warning => .warning,
        .note => .note,
    };
}

fn mapDiagnosticCode(value: @FieldType(native_compiler.Diagnostic, "code")) DiagnosticCode {
    return switch (value) {
        .syntax => .syntax,
        .undefined_variable => .undefined_variable,
        .duplicate_binding => .duplicate_binding,
        .type_mismatch => .type_mismatch,
        .invalid_operation => .invalid_operation,
        .call_limit => .call_limit,
        .loop_limit => .loop_limit,
        .resource_limit => .resource_limit,
        .invalid_import => .invalid_import,
        .unsupported_feature => .unsupported_feature,
        .internal => .internal,
    };
}

fn releaseDiagnostics(allocator: std.mem.Allocator, items: []const Diagnostic) void {
    if (items.len == 0) return;
    releaseDiagnosticFields(allocator, items);
    allocator.free(items);
}

fn releaseDiagnosticFields(allocator: std.mem.Allocator, items: []const Diagnostic) void {
    for (items) |item| {
        if (item.source_name.len > 0) allocator.free(item.source_name);
        if (item.message.len > 0) allocator.free(item.message);
        releaseRelatedDiagnostics(allocator, item.related);
    }
}

fn releaseRelatedDiagnostics(
    allocator: std.mem.Allocator,
    items: []const RelatedDiagnostic,
) void {
    if (items.len == 0) return;
    releaseRelatedFields(allocator, items);
    allocator.free(items);
}

fn releaseRelatedFields(allocator: std.mem.Allocator, items: []const RelatedDiagnostic) void {
    for (items) |item| {
        if (item.source_name.len > 0) allocator.free(item.source_name);
        if (item.label.len > 0) allocator.free(item.label);
    }
}

fn cloneDependencies(
    allocator: std.mem.Allocator,
    items: []const native_compiler.Dependency,
) std.mem.Allocator.Error![]const Dependency {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(Dependency, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item.url);
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        cloned[index] = .{
            .kind = switch (item.kind) {
                .import => .import,
                .use => .use,
                .forward => .forward,
                .reference => .reference,
            },
            .url = try allocator.dupe(u8, item.url),
        };
        initialized += 1;
    }
    return cloned;
}

fn releaseDependencies(allocator: std.mem.Allocator, items: []const Dependency) void {
    if (items.len == 0) return;
    for (items) |item| allocator.free(item.url);
    allocator.free(items);
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
