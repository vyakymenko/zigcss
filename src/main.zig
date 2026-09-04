const std = @import("std");
const builtin = @import("builtin");
const core_protocol = @import("core_protocol.zig");
const node_protocol = @import("node_protocol.zig");
const zigcss = @import("zigcss");
const lsp = @import("lsp.zig");
const lsp_transport = @import("lsp_transport.zig");

const native_api = zigcss.experimental_native;

const version = "0.7.0-rc.1";
const prerelease_notice = std.fmt.comptimePrint(
    "Warning: ZigCSS {s} is an experimental release candidate; do not use it for production CSS.\n",
    .{version},
);
const lsp_experimental_notice = "Warning: ZigCSS LSP is experimental; evaluate before production editor use.\n";
const max_input_bytes = 10 * 1024 * 1024;
const max_rendered_output_bytes = 96 * 1024 * 1024;
const max_batch_output_basename_bytes = 128;
const max_batch_workers = 8;
const max_input_patterns = 4096;
const max_expanded_inputs = 16 * 1024;
const max_cli_input_path_bytes = 16 * 1024;
const max_glob_component_bytes = 4096;
const max_depfile_path_bytes = 16 * 1024;
const max_depfile_prerequisites = 4097;
const max_depfile_bytes = 64 * 1024 * 1024;
const max_native_dependency_url_bytes = 8 * 1024;
const max_native_dependency_path_bytes = 4 * 1024;
const stdin_source_name = "<stdin>";
const stdio_path = "-";
const exit_compile_failure: u8 = 1;
const exit_usage: u8 = 2;

const TargetPrefixConfig = struct {
    enabled: bool = false,
    /// Canonical query owned by `main`; immutable sharing across bounded batch
    /// workers and a synchronous watch lifetime is safe.
    targets: ?*const zigcss.TargetQuery = null,
};

const CompileConfig = struct {
    input_file: []const u8,
    output_file: ?[]const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool = false,
    profile: bool = false,
    prefix: TargetPrefixConfig = .{},
    depfile: ?[]const u8 = null,
};

const CompileTaskAllocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });
const NativeBatchTaskAllocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });

const CompileTaskState = enum {
    pending,
    running,
    succeeded,
    failed,
    cancelled,
};

const CompileTask = struct {
    input_file: []const u8,
    output_file: []const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool = false,
    prefix: TargetPrefixConfig = .{},
    result: ?zigcss.CompileResult = null,
    rendered_css: ?[]u8 = null,
    err: ?[]const u8 = null,
    err_owned: bool = false,
    state: CompileTaskState = .pending,
    allocator_state: CompileTaskAllocator = .{},

    fn allocator(self: *CompileTask) std.mem.Allocator {
        return self.allocator_state.allocator();
    }

    fn deinit(self: *CompileTask, planning_allocator: std.mem.Allocator) void {
        const task_allocator = self.allocator();
        if (self.result) |*result| result.deinit();
        if (self.rendered_css) |bytes| task_allocator.free(bytes);
        if (self.err_owned) task_allocator.free(self.err.?);
        const allocator_check = self.allocator_state.deinit();
        std.debug.assert(allocator_check == .ok);
        planning_allocator.free(self.output_file);
    }
};

const NativeBatchTask = struct {
    input_file: []const u8,
    output_file: []const u8,
    syntax: native_api.Syntax,
    optimize: bool = false,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig = .{},
    result: ?native_api.CompileResult = null,
    rendered_css: ?[]u8 = null,
    err: ?anyerror = null,
    state: CompileTaskState = .pending,
    allocator_state: NativeBatchTaskAllocator = .{},

    fn allocator(self: *NativeBatchTask) std.mem.Allocator {
        return self.allocator_state.allocator();
    }

    fn deinit(self: *NativeBatchTask, planning_allocator: std.mem.Allocator) void {
        const task_allocator = self.allocator();
        if (self.result) |*result| result.deinit();
        if (self.rendered_css) |bytes| task_allocator.free(bytes);
        const allocator_check = self.allocator_state.deinit();
        std.debug.assert(allocator_check == .ok);
        planning_allocator.free(self.output_file);
    }
};

fn setTaskError(
    task: *CompileTask,
    comptime format: []const u8,
    args: anytype,
    fallback: []const u8,
) void {
    const allocator = task.allocator();
    task.err = std.fmt.allocPrint(allocator, format, args) catch {
        task.err = fallback;
        task.err_owned = false;
        task.state = .failed;
        return;
    };
    task.err_owned = true;
    task.state = .failed;
}

fn compileCss(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    input: []const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    profile: bool,
    prefix: TargetPrefixConfig,
) zigcss.CompileError!zigcss.CompileResult {
    return zigcss.compile(
        allocator,
        source_name,
        input,
        .{
            .syntax = syntax,
            .format = if (minify) .minified else .pretty,
            .source_map = if (source_map) .{ .external = .{} } else .none,
            .transforms = .{ .optimize = optimize, .prefix = prefix.enabled },
            .targets = prefix.targets,
            .profile = profile,
        },
    );
}

fn hasErrorDiagnostics(diagnostics: []const zigcss.Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

fn severityLabel(severity: zigcss.DiagnosticSeverity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

fn printDiagnostics(diagnostics: []const zigcss.Diagnostic) void {
    for (diagnostics) |diagnostic| {
        std.debug.print(
            "{s}:{d}:{d}: {s} {s}: {s}\n",
            .{
                diagnostic.source_name,
                diagnostic.start.line,
                diagnostic.start.column,
                severityLabel(diagnostic.severity),
                diagnostic.code.label(),
                diagnostic.message,
            },
        );
    }
}

fn hasNativeErrorDiagnostics(diagnostics: []const native_api.Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

fn nativeSeverityLabel(severity: native_api.DiagnosticSeverity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

fn printNativeDiagnostics(diagnostics: []const native_api.Diagnostic) void {
    for (diagnostics) |diagnostic| {
        std.debug.print(
            "{s}:{d}:{d}: {s} {s}: {s}\n",
            .{
                diagnostic.source_name,
                diagnostic.start.line,
                diagnostic.start.column,
                nativeSeverityLabel(diagnostic.severity),
                diagnostic.code.label(),
                diagnostic.message,
            },
        );
        for (diagnostic.related) |related| {
            std.debug.print(
                "{s}:{d}:{d}: note: {s}\n",
                .{
                    related.source_name,
                    related.start.line,
                    related.start.column,
                    related.label,
                },
            );
        }
    }
}

fn printProfile(metrics: zigcss.CompileMetrics) void {
    std.debug.print("\n=== Performance Profile ===\n", .{});
    std.debug.print("Timing (nanoseconds):\n", .{});
    std.debug.print("  total_time_ns: {d}\n", .{metrics.total_time_ns});
    std.debug.print("  parse_time_ns: {d}\n", .{metrics.stages.parse_time_ns});
    std.debug.print("  validation_time_ns: {d}\n", .{metrics.stages.validation_time_ns});
    std.debug.print("  dependency_time_ns: {d}\n", .{metrics.stages.dependency_time_ns});
    std.debug.print("  optimize_time_ns: {d}\n", .{metrics.stages.optimize_time_ns});
    std.debug.print("  transform_time_ns: {d}\n", .{metrics.stages.transform_time_ns});
    std.debug.print("  emit_time_ns: {d}\n", .{metrics.stages.emit_time_ns});
    std.debug.print("  result_time_ns: {d}\n", .{metrics.stages.result_time_ns});
    std.debug.print("  cleanup_time_ns: {d}\n", .{metrics.stages.cleanup_time_ns});
    std.debug.print("Allocator requested-byte metrics:\n", .{});
    std.debug.print("  total_allocated_bytes: {d}\n", .{metrics.memory.total_allocated_bytes});
    std.debug.print("  total_freed_bytes: {d}\n", .{metrics.memory.total_freed_bytes});
    std.debug.print("  peak_live_bytes: {d}\n", .{metrics.memory.peak_live_bytes});
    std.debug.print("  retained_result_bytes: {d}\n", .{metrics.memory.retained_result_bytes});
    std.debug.print("  allocation_count: {d}\n", .{metrics.memory.allocation_count});
    std.debug.print("  deallocation_count: {d}\n", .{metrics.memory.deallocation_count});
    std.debug.print("  resize_count: {d}\n\n", .{metrics.memory.resize_count});
}

fn isStdioPath(path: []const u8) bool {
    return std.mem.eql(u8, path, stdio_path);
}

fn inputDisplayName(path: []const u8) []const u8 {
    return if (isStdioPath(path)) stdin_source_name else path;
}

fn readInput(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (isStdioPath(path)) {
        return std.fs.File.stdin().readToEndAlloc(allocator, max_input_bytes);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, max_input_bytes);
}

fn writeStdout(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

const windows_atomic_operation_attempt_limit: usize = 100;
const windows_atomic_retry_delay_ns: u64 = 10 * std.time.ns_per_ms;

fn shouldRetryWindowsAtomicAccess(
    os_tag: std.Target.Os.Tag,
    err: anyerror,
    attempt: usize,
) bool {
    return os_tag == .windows and
        err == error.AccessDenied and
        attempt < windows_atomic_operation_attempt_limit - 1;
}

fn finishAtomicFileWithRetry(
    atomic_file: anytype,
    os_tag: std.Target.Os.Tag,
    retry_delay_ns: u64,
) !void {
    try atomic_file.flush();
    for (0..windows_atomic_operation_attempt_limit) |attempt| {
        atomic_file.renameIntoPlace() catch |err| {
            if (!shouldRetryWindowsAtomicAccess(os_tag, err, attempt)) return err;
            if (retry_delay_ns > 0) std.Thread.sleep(retry_delay_ns);
            continue;
        };
        return;
    }
    unreachable;
}

fn outputFileMode(
    cwd: std.fs.Dir,
    path: []const u8,
) !std.fs.File.Mode {
    for (0..windows_atomic_operation_attempt_limit) |attempt| {
        if (builtin.os.tag == .windows) {
            // statFile opens entries as files on Windows and reports
            // AccessDenied for directories. A directory destination should be
            // carried through preparation so the atomic rename reports the
            // stable write failure and still cleans up its temporary file.
            if (cwd.openDir(path, .{})) |opened| {
                var directory = opened;
                directory.close();
                return std.fs.File.default_mode;
            } else |err| switch (err) {
                error.FileNotFound => return std.fs.File.default_mode,
                error.NotDir, error.AccessDenied => {},
                else => return err,
            }
        }
        const stat = cwd.statFile(path) catch |err| {
            if (err == error.FileNotFound) return std.fs.File.default_mode;
            if (shouldRetryWindowsAtomicAccess(builtin.os.tag, err, attempt)) {
                std.Thread.sleep(windows_atomic_retry_delay_ns);
                continue;
            }
            return err;
        };
        return if (stat.kind == .file) @intCast(stat.mode) else std.fs.File.default_mode;
    }
    unreachable;
}

const PreparedOutputDestination = struct {
    display_path: []const u8,
    canonical_path: []u8,
    directory_identity: ?FileObjectIdentity,
    expected_object: ?FileObjectIdentity,
    dir: std.fs.Dir,
    close_dir: bool,
    mode: std.fs.File.Mode,

    fn init(allocator: std.mem.Allocator, path: []const u8) !PreparedOutputDestination {
        return initFallible(allocator, path) catch |err| {
            std.debug.print(
                "Error: failed to prepare {s} for atomic output: {s}\n",
                .{ path, @errorName(err) },
            );
            return err;
        };
    }

    fn initFallible(allocator: std.mem.Allocator, path: []const u8) !PreparedOutputDestination {
        const parent = std.fs.path.dirname(path);
        const output_basename = try validatedOutputBasename(path);

        // Resolve/create the parent once, then retain that directory capability
        // through the final rename. A later pathname/symlink swap cannot move
        // the commit into a different directory.
        var dir = if (parent) |parent_path|
            try std.fs.cwd().makeOpenPath(parent_path, .{})
        else if (builtin.os.tag == .windows)
            // std.fs.cwd() uses a process-relative sentinel on Windows rather
            // than an owned directory handle. Retain a real handle so identity
            // queries and the final rename use the same directory capability.
            try std.fs.cwd().openDir(".", .{})
        else
            std.fs.cwd();
        const close_dir = parent != null or builtin.os.tag == .windows;
        errdefer if (close_dir) dir.close();
        const canonical_parent = if (close_dir)
            try dir.realpathAlloc(allocator, ".")
        else
            try std.process.getCwdAlloc(allocator);
        defer allocator.free(canonical_parent);
        const canonical_path = try std.fs.path.join(allocator, &.{ canonical_parent, output_basename });
        errdefer allocator.free(canonical_path);
        const directory_identity = if (!close_dir and
            builtin.os.tag != .windows and builtin.os.tag != .wasi)
            null
        else
            try objectIdentityFromFile(std.fs.File{ .handle = dir.fd });
        const mode = try outputFileMode(dir, output_basename);
        var destination = PreparedOutputDestination{
            .display_path = path,
            .canonical_path = canonical_path,
            .directory_identity = directory_identity,
            .expected_object = null,
            .dir = dir,
            .close_dir = close_dir,
            .mode = mode,
        };
        destination.expected_object = try objectIdentityAtDestination(&destination);
        return destination;
    }

    /// Batch planning produces sibling files under one output directory. Reuse
    /// its retained capability instead of consuming one descriptor per input.
    fn initSibling(
        allocator: std.mem.Allocator,
        owner: *const PreparedOutputDestination,
        path: []const u8,
    ) !PreparedOutputDestination {
        return initSiblingFallible(allocator, owner, path) catch |err| {
            std.debug.print(
                "Error: failed to prepare {s} for atomic output: {s}\n",
                .{ path, @errorName(err) },
            );
            return err;
        };
    }

    fn initSiblingFallible(
        allocator: std.mem.Allocator,
        owner: *const PreparedOutputDestination,
        path: []const u8,
    ) !PreparedOutputDestination {
        const owner_parent = std.fs.path.dirname(owner.display_path) orelse ".";
        const sibling_parent = std.fs.path.dirname(path) orelse ".";
        if (!std.mem.eql(u8, owner_parent, sibling_parent)) return error.BadPathName;

        const output_basename = try validatedOutputBasename(path);
        const canonical_parent = std.fs.path.dirname(owner.canonical_path) orelse
            return error.BadPathName;
        const canonical_path = try std.fs.path.join(
            allocator,
            &.{ canonical_parent, output_basename },
        );
        errdefer allocator.free(canonical_path);
        var destination = PreparedOutputDestination{
            .display_path = path,
            .canonical_path = canonical_path,
            .directory_identity = owner.directory_identity,
            .expected_object = null,
            .dir = owner.dir,
            .close_dir = false,
            .mode = try outputFileMode(owner.dir, output_basename),
        };
        destination.expected_object = try objectIdentityAtDestination(&destination);
        return destination;
    }

    fn deinit(self: *PreparedOutputDestination, allocator: std.mem.Allocator) void {
        if (self.close_dir) self.dir.close();
        allocator.free(self.canonical_path);
        self.* = undefined;
    }

    fn basename(self: *const PreparedOutputDestination) []const u8 {
        return std.fs.path.basename(self.canonical_path);
    }
};

fn validatedOutputBasename(path: []const u8) ![]const u8 {
    const output_basename = std.fs.path.basename(path);
    if (output_basename.len == 0 or
        std.mem.eql(u8, output_basename, ".") or
        std.mem.eql(u8, output_basename, ".."))
    {
        return error.BadPathName;
    }
    return output_basename;
}

fn verifyPreparedDestinationUnchanged(destination: *const PreparedOutputDestination) !void {
    const current_object = try objectIdentityAtDestination(destination);
    if (!std.meta.eql(destination.expected_object, current_object)) {
        return error.OutputDestinationChanged;
    }
}

fn verifyPreparedDestinationUnchangedWithRetry(
    destination: *const PreparedOutputDestination,
    retry_delay_ns: u64,
) !void {
    for (0..windows_atomic_operation_attempt_limit) |attempt| {
        verifyPreparedDestinationUnchanged(destination) catch |err| {
            if (!shouldRetryWindowsAtomicAccess(builtin.os.tag, err, attempt)) return err;
            if (retry_delay_ns > 0) std.Thread.sleep(retry_delay_ns);
            continue;
        };
        return;
    }
    unreachable;
}

fn finishPreparedAtomicFileWithRetry(
    atomic_file: anytype,
    destination: *const PreparedOutputDestination,
    retry_delay_ns: u64,
) !void {
    try atomic_file.flush();
    for (0..windows_atomic_operation_attempt_limit) |attempt| {
        verifyPreparedDestinationUnchanged(destination) catch |err| {
            if (!shouldRetryWindowsAtomicAccess(builtin.os.tag, err, attempt)) return err;
            if (retry_delay_ns > 0) std.Thread.sleep(retry_delay_ns);
            continue;
        };
        atomic_file.renameIntoPlace() catch |err| {
            if (!shouldRetryWindowsAtomicAccess(builtin.os.tag, err, attempt)) return err;
            if (retry_delay_ns > 0) std.Thread.sleep(retry_delay_ns);
            continue;
        };
        return;
    }
    unreachable;
}

fn writePreparedOutput(destination: *const PreparedOutputDestination, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var atomic_file = std.fs.AtomicFile.init(
        destination.basename(),
        destination.mode,
        destination.dir,
        false,
        &buffer,
    ) catch |err| {
        std.debug.print(
            "Error: failed to write {s} atomically: {s}\n",
            .{ destination.display_path, @errorName(err) },
        );
        return err;
    };
    defer atomic_file.deinit();

    atomic_file.file_writer.interface.writeAll(bytes) catch {
        const err = atomic_file.file_writer.err orelse error.Unexpected;
        std.debug.print(
            "Error: failed to write {s} atomically: {s}\n",
            .{ destination.display_path, @errorName(err) },
        );
        return err;
    };
    atomic_file.flush() catch |err| {
        std.debug.print(
            "Error: failed to flush {s} atomically: {s}\n",
            .{ destination.display_path, @errorName(err) },
        );
        return err;
    };
    finishPreparedAtomicFileWithRetry(
        &atomic_file,
        destination,
        windows_atomic_retry_delay_ns,
    ) catch |err| {
        std.debug.print(
            "Error: failed to write {s} atomically: {s}\n",
            .{ destination.display_path, @errorName(err) },
        );
        return err;
    };
}

const DepfileError = error{
    DepfileTooLarge,
    DepfileUsageError,
    InvalidDepfileDependency,
    InvalidDepfilePath,
    TooManyDepfilePrerequisites,
};

fn validateDepfilePath(path: []const u8) DepfileError!void {
    if (path.len == 0 or path.len > max_depfile_path_bytes) {
        return error.InvalidDepfilePath;
    }
    for (path) |byte| {
        // Make and Ninja depfiles have no lossless portable spelling for line
        // breaks. Reject all other ASCII controls as well instead of emitting
        // a field that either parser could split differently.
        if (byte < 0x20 or byte == 0x7f) return error.InvalidDepfilePath;
    }
}

fn depfileEscapedLength(path: []const u8) DepfileError!usize {
    try validateDepfilePath(path);
    var length: usize = 0;
    for (path) |byte| {
        const encoded_length: usize = switch (byte) {
            ' ', '#', '$', ':', '\\' => 2,
            else => 1,
        };
        length = std.math.add(usize, length, encoded_length) catch
            return error.DepfileTooLarge;
        if (length > max_depfile_bytes) return error.DepfileTooLarge;
    }
    return length;
}

fn appendDepfilePath(output: []u8, cursor: *usize, path: []const u8) void {
    for (path) |byte| {
        switch (byte) {
            ' ', '#', ':', '\\' => {
                output[cursor.*] = '\\';
                output[cursor.* + 1] = byte;
                cursor.* += 2;
            },
            '$' => {
                output[cursor.*] = '$';
                output[cursor.* + 1] = '$';
                cursor.* += 2;
            },
            else => {
                output[cursor.*] = byte;
                cursor.* += 1;
            },
        }
    }
}

fn renderDepfileWithLimit(
    allocator: std.mem.Allocator,
    target: []const u8,
    prerequisites: []const []const u8,
    maximum_bytes: usize,
) (std.mem.Allocator.Error || DepfileError)![]u8 {
    if (prerequisites.len == 0 or prerequisites.len > max_depfile_prerequisites) {
        return error.TooManyDepfilePrerequisites;
    }
    if (maximum_bytes == 0 or maximum_bytes > max_depfile_bytes) {
        return error.DepfileTooLarge;
    }

    var total = try depfileEscapedLength(target);
    total = std.math.add(usize, total, 1) catch return error.DepfileTooLarge; // ':'
    for (prerequisites) |path| {
        total = std.math.add(usize, total, 1) catch return error.DepfileTooLarge; // ' '
        total = std.math.add(usize, total, try depfileEscapedLength(path)) catch
            return error.DepfileTooLarge;
        if (total > maximum_bytes) return error.DepfileTooLarge;
    }
    total = std.math.add(usize, total, 1) catch return error.DepfileTooLarge; // '\n'
    if (total > maximum_bytes) return error.DepfileTooLarge;

    const rendered = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    appendDepfilePath(rendered, &cursor, target);
    rendered[cursor] = ':';
    cursor += 1;
    for (prerequisites) |path| {
        rendered[cursor] = ' ';
        cursor += 1;
        appendDepfilePath(rendered, &cursor, path);
    }
    rendered[cursor] = '\n';
    cursor += 1;
    std.debug.assert(cursor == rendered.len);
    return rendered;
}

fn renderDepfile(
    allocator: std.mem.Allocator,
    target: []const u8,
    prerequisites: []const []const u8,
) (std.mem.Allocator.Error || DepfileError)![]u8 {
    return renderDepfileWithLimit(
        allocator,
        target,
        prerequisites,
        max_depfile_bytes,
    );
}

fn depfilePathLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn depfileHexValue(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

fn isSupportedDepfileDependencyPath(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const parsed = std.fs.path.windowsParsePath(path);
        return parsed.is_abs and parsed.kind == .Drive;
    }
    return std.fs.path.isAbsolutePosix(path);
}

/// Native compilation returns canonical local file URLs. Decode that owned
/// result fact without reopening the filesystem or adding a public API solely
/// for the CLI-only depfile surface.
fn nativeDependencyPathAlloc(
    allocator: std.mem.Allocator,
    dependency: native_api.Dependency,
) (std.mem.Allocator.Error || DepfileError)![]u8 {
    const value = dependency.url;
    if (value.len == 0 or value.len > max_native_dependency_url_bytes or
        std.mem.indexOfAny(u8, value, "\x00\r\n\\") != null)
    {
        return error.InvalidDepfileDependency;
    }
    const uri = std.Uri.parse(value) catch return error.InvalidDepfileDependency;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file")) {
        return error.InvalidDepfileDependency;
    }
    if (uri.user != null or uri.password != null or uri.port != null or
        uri.query != null or uri.fragment != null)
    {
        return error.InvalidDepfileDependency;
    }
    if (uri.host) |host| {
        if (!host.isEmpty()) return error.InvalidDepfileDependency;
    }
    const encoded = switch (uri.path) {
        .raw => |raw| raw,
        .percent_encoded => |percent_encoded| percent_encoded,
    };
    if (encoded.len == 0) return error.InvalidDepfileDependency;

    const decoded_storage = try allocator.alloc(u8, encoded.len);
    defer allocator.free(decoded_storage);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < encoded.len) {
        var byte = encoded[input_index];
        if (byte == '%') {
            if (input_index + 2 >= encoded.len) return error.InvalidDepfileDependency;
            const high = depfileHexValue(encoded[input_index + 1]) orelse
                return error.InvalidDepfileDependency;
            const low = depfileHexValue(encoded[input_index + 2]) orelse
                return error.InvalidDepfileDependency;
            byte = (high << 4) | low;
            if (byte == '/' or byte == '\\' or byte == 0 or byte == '\r' or byte == '\n') {
                return error.InvalidDepfileDependency;
            }
            input_index += 3;
        } else {
            if (byte == 0 or byte == '\r' or byte == '\n' or byte == '\\') {
                return error.InvalidDepfileDependency;
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
    if (decoded.len == 0 or decoded.len > max_native_dependency_path_bytes or
        !isSupportedDepfileDependencyPath(decoded))
    {
        return error.InvalidDepfileDependency;
    }
    return try std.fs.path.resolve(allocator, &.{decoded});
}

fn printDepfileCollision(collision: OutputCollision) void {
    switch (collision.kind) {
        .output_is_input => std.debug.print(
            "Error: output or depfile path resolves to a compilation input: {s}\n",
            .{collision.path},
        ),
        .duplicate_output => std.debug.print(
            "Error: output and depfile resolve to the same destination: {s}\n",
            .{collision.path},
        ),
    }
}

fn prepareDepfile(
    allocator: std.mem.Allocator,
    target_path: []const u8,
    depfile_path: []const u8,
    entry_path: []const u8,
    native_dependencies: []const native_api.Dependency,
) ![]u8 {
    try validateDepfilePath(depfile_path);
    try validateDepfilePath(target_path);
    const prerequisite_count = std.math.add(usize, native_dependencies.len, 1) catch
        return error.TooManyDepfilePrerequisites;
    if (prerequisite_count > max_depfile_prerequisites) {
        return error.TooManyDepfilePrerequisites;
    }

    const canonical_entry = try std.fs.cwd().realpathAlloc(allocator, entry_path);
    defer allocator.free(canonical_entry);
    try validateDepfilePath(canonical_entry);

    const dependency_paths = try allocator.alloc([]const u8, native_dependencies.len);
    defer allocator.free(dependency_paths);
    var initialized: usize = 0;
    defer for (dependency_paths[0..initialized]) |path| allocator.free(path);

    for (native_dependencies) |dependency| {
        const path = try nativeDependencyPathAlloc(allocator, dependency);
        errdefer allocator.free(path);
        try validateDepfilePath(path);
        dependency_paths[initialized] = path;
        initialized += 1;
    }
    std.mem.sort([]const u8, dependency_paths[0..initialized], {}, depfilePathLessThan);

    // Resolver results are already deduplicated, but keep the serialized build
    // boundary independently deterministic and defensive. The canonical entry
    // is always prerequisite zero and is never repeated.
    var retained: usize = 0;
    for (dependency_paths[0..initialized]) |path| {
        const duplicate_entry = std.mem.eql(u8, canonical_entry, path);
        const duplicate_previous = retained > 0 and
            std.mem.eql(u8, dependency_paths[retained - 1], path);
        if (duplicate_entry or duplicate_previous) {
            allocator.free(path);
            continue;
        }
        dependency_paths[retained] = path;
        retained += 1;
    }
    initialized = retained;

    const prerequisites = try allocator.alloc([]const u8, retained + 1);
    defer allocator.free(prerequisites);
    prerequisites[0] = canonical_entry;
    @memcpy(prerequisites[1..], dependency_paths[0..retained]);

    const destinations = [_][]const u8{ target_path, depfile_path };
    if (try findOutputCollision(allocator, prerequisites, &destinations)) |collision| {
        printDepfileCollision(collision);
        return error.DepfileUsageError;
    }
    return renderDepfile(allocator, target_path, prerequisites);
}

fn writePreparedOutputAndDepfile(
    output_destination: *const PreparedOutputDestination,
    output: []const u8,
    depfile_destination: *const PreparedOutputDestination,
    depfile: []const u8,
) !void {
    // Prepare and flush both independent atomic files before either pathname
    // is replaced. The depfile is committed first and CSS last, so the build
    // target remains the success marker for generators that inspect mtimes.
    var output_buffer: [4096]u8 = undefined;
    var output_atomic = try std.fs.AtomicFile.init(
        output_destination.basename(),
        output_destination.mode,
        output_destination.dir,
        false,
        &output_buffer,
    );
    defer output_atomic.deinit();
    var depfile_buffer: [4096]u8 = undefined;
    var depfile_atomic = try std.fs.AtomicFile.init(
        depfile_destination.basename(),
        depfile_destination.mode,
        depfile_destination.dir,
        false,
        &depfile_buffer,
    );
    defer depfile_atomic.deinit();

    try output_atomic.file_writer.interface.writeAll(output);
    try depfile_atomic.file_writer.interface.writeAll(depfile);
    try output_atomic.flush();
    try depfile_atomic.flush();

    // Check both entries after both temporary files are complete and before
    // committing either one. The per-rename helper repeats the same check, but
    // this joint preflight prevents a known-stale CSS target from allowing a
    // depfile-only commit.
    try verifyPreparedDestinationUnchangedWithRetry(
        output_destination,
        windows_atomic_retry_delay_ns,
    );
    try verifyPreparedDestinationUnchangedWithRetry(
        depfile_destination,
        windows_atomic_retry_delay_ns,
    );
    try finishPreparedAtomicFileWithRetry(
        &depfile_atomic,
        depfile_destination,
        windows_atomic_retry_delay_ns,
    );
    // The output helper rechecks its entry after the depfile commit and before
    // every rename attempt, then makes CSS the externally visible marker.
    try finishPreparedAtomicFileWithRetry(
        &output_atomic,
        output_destination,
        windows_atomic_retry_delay_ns,
    );
}

fn compileLoadedFile(
    allocator: std.mem.Allocator,
    config: CompileConfig,
    input: []const u8,
) !zigcss.CompileResult {
    var result = compileCss(
        allocator,
        inputDisplayName(config.input_file),
        input,
        config.syntax,
        config.optimize,
        config.minify,
        config.source_map,
        config.profile,
        config.prefix,
    ) catch |err| {
        std.debug.print("Error: CSS compilation failed: {s}\n", .{@errorName(err)});
        return err;
    };
    errdefer result.deinit();

    if (hasErrorDiagnostics(result.diagnostics)) {
        printDiagnostics(result.diagnostics);
        if (config.profile) printProfile(result.metrics orelse return error.MissingProfileMetrics);
        return error.CompileError;
    }

    const rendered = if (config.source_map) blk: {
        const source_map = result.source_map orelse {
            std.debug.print("Error: requested CSS source map is missing\n", .{});
            return error.MissingSourceMap;
        };
        break :blk renderCssWithInlineSourceMap(
            allocator,
            result.css,
            source_map,
        ) catch |err| {
            std.debug.print("Error: failed to render inline source map: {s}\n", .{@errorName(err)});
            return err;
        };
    } else null;
    defer if (rendered) |bytes| allocator.free(bytes);
    const output = rendered orelse result.css;

    const depfile = if (config.depfile) |depfile_path| blk: {
        const target_path = config.output_file orelse return error.DepfileUsageError;
        break :blk prepareDepfile(
            allocator,
            target_path,
            depfile_path,
            config.input_file,
            &.{},
        ) catch |err| {
            if (err != error.DepfileUsageError) {
                std.debug.print("Error: failed to prepare depfile: {s}\n", .{@errorName(err)});
            }
            return err;
        };
    } else null;
    defer if (depfile) |bytes| allocator.free(bytes);

    var prepared_storage: [2]PreparedOutputDestination = undefined;
    var prepared_count: usize = 0;
    defer for (prepared_storage[0..prepared_count]) |*destination| destination.deinit(allocator);
    var output_destination_index: ?usize = null;
    var depfile_destination_index: ?usize = null;
    if (config.output_file) |path| {
        if (!isStdioPath(path)) {
            output_destination_index = prepared_count;
            prepared_storage[prepared_count] = try PreparedOutputDestination.init(allocator, path);
            prepared_count += 1;
        }
    }
    if (config.depfile) |path| {
        depfile_destination_index = prepared_count;
        prepared_storage[prepared_count] = try PreparedOutputDestination.init(allocator, path);
        prepared_count += 1;
    }
    if (prepared_count != 0) {
        const inputs = [_][]const u8{config.input_file};
        const collision_inputs = if (isStdioPath(config.input_file)) inputs[0..0] else inputs[0..];
        if (try findPreparedOutputCollision(
            allocator,
            collision_inputs,
            prepared_storage[0..prepared_count],
        )) |collision| {
            if (config.depfile != null) {
                printDepfileCollision(collision);
            } else {
                printOutputCollision(collision);
            }
            return error.DepfileUsageError;
        }
    }

    if (config.output_file) |out| {
        if (isStdioPath(out)) {
            writeStdout(output) catch |err| {
                std.debug.print("Error: failed to write stdout: {s}\n", .{@errorName(err)});
                return err;
            };
        } else {
            if (config.depfile != null) {
                writePreparedOutputAndDepfile(
                    &prepared_storage[output_destination_index.?],
                    output,
                    &prepared_storage[depfile_destination_index.?],
                    depfile.?,
                ) catch |err| {
                    std.debug.print("Error: failed to commit output and depfile files: {s}\n", .{@errorName(err)});
                    return err;
                };
            } else {
                try writePreparedOutput(&prepared_storage[output_destination_index.?], output);
            }
            std.debug.print("Compiled: {s} -> {s}\n", .{ config.input_file, out });
        }
    } else {
        writeStdout(output) catch |err| {
            std.debug.print("Error: failed to write stdout: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    if (config.profile) printProfile(result.metrics orelse return error.MissingProfileMetrics);

    return result.take();
}

fn compileFile(allocator: std.mem.Allocator, config: CompileConfig) !void {
    const input = readInput(allocator, config.input_file) catch |err| {
        std.debug.print("Error: failed to read {s}: {s}\n", .{ inputDisplayName(config.input_file), @errorName(err) });
        return err;
    };
    defer allocator.free(input);

    var result = try compileLoadedFile(allocator, config, input);
    defer result.deinit();
}

fn parseNativeSyntax(value: []const u8) ?native_api.Syntax {
    if (std.mem.eql(u8, value, "scss")) return .scss;
    if (std.mem.eql(u8, value, "sass")) return .sass;
    if (std.mem.eql(u8, value, "less")) return .less;
    if (std.mem.eql(u8, value, "stylus")) return .stylus;
    return null;
}

fn nativeSyntaxLabel(syntax: native_api.Syntax) []const u8 {
    return switch (syntax) {
        .scss => "SCSS",
        .sass => "Sass",
        .less => "Less",
        .stylus => "Stylus",
    };
}

fn nativeStdinEntryName(syntax: native_api.Syntax) []const u8 {
    return switch (syntax) {
        .scss => ".zigcss-stdin.scss",
        .sass => ".zigcss-stdin.sass",
        .less => ".zigcss-stdin.less",
        .stylus => ".zigcss-stdin.styl",
    };
}

fn compileNativeLoadedSource(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    root_path: []const u8,
    input: []const u8,
    syntax: native_api.Syntax,
    optimize: bool,
    minify: bool,
    watch: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
    report_errors: bool,
) !native_api.CompileResult {
    const root_paths = [_][]const u8{root_path};
    var result = native_api.compile(allocator, entry_path, input, .{
        .syntax = syntax,
        .root_paths = &root_paths,
        .format = if (minify) .minified else .pretty,
        .watch = watch,
        .source_map = source_map,
        .optimize = optimize,
        .prefix = prefix.enabled,
        .targets = prefix.targets,
    }) catch |err| {
        if (report_errors) {
            std.debug.print(
                "Error: native {s} compilation failed: {s}\n",
                .{ nativeSyntaxLabel(syntax), @errorName(err) },
            );
        }
        return err;
    };
    errdefer result.deinit();
    if (report_errors) printNativeDiagnostics(result.diagnostics);
    return result.take();
}

fn compileNativeSourceWithReporting(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    syntax: native_api.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
    report_errors: bool,
) !native_api.CompileResult {
    const stdin_root = if (isStdioPath(input_file))
        std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
            if (report_errors) std.debug.print("Error: failed to resolve stdin root: {s}\n", .{@errorName(err)});
            return err;
        }
    else
        null;
    defer if (stdin_root) |root| allocator.free(root);

    const entry_path = if (stdin_root) |root|
        try std.fs.path.join(allocator, &.{ root, nativeStdinEntryName(syntax) })
    else
        std.fs.cwd().realpathAlloc(allocator, input_file) catch |err| {
            if (report_errors) std.debug.print("Error: failed to resolve {s}: {s}\n", .{ input_file, @errorName(err) });
            return err;
        };
    defer allocator.free(entry_path);

    const read_path = if (stdin_root != null) input_file else entry_path;
    const input = readInput(allocator, read_path) catch |err| {
        if (report_errors) std.debug.print("Error: failed to read {s}: {s}\n", .{ inputDisplayName(input_file), @errorName(err) });
        return err;
    };
    defer allocator.free(input);

    const root_path = if (stdin_root) |root|
        root
    else
        std.fs.path.dirname(entry_path) orelse return error.InvalidSourcePath;
    return compileNativeLoadedSource(
        allocator,
        entry_path,
        root_path,
        input,
        syntax,
        optimize,
        minify,
        false,
        source_map,
        prefix,
        report_errors,
    );
}

fn compileNativeSource(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    syntax: native_api.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
) !native_api.CompileResult {
    return compileNativeSourceWithReporting(
        allocator,
        input_file,
        syntax,
        optimize,
        minify,
        source_map,
        prefix,
        true,
    );
}

fn compileNativeSourceQuiet(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    syntax: native_api.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
) !native_api.CompileResult {
    return compileNativeSourceWithReporting(
        allocator,
        input_file,
        syntax,
        optimize,
        minify,
        source_map,
        prefix,
        false,
    );
}

fn renderCssWithInlineSourceMap(
    allocator: std.mem.Allocator,
    css: []const u8,
    source_map: []const u8,
) ![]u8 {
    const marker = "/*# sourceMappingURL=data:application/json;charset=utf-8;base64,";
    const encoded_len = std.base64.standard.Encoder.calcSize(source_map.len);
    const newline_len: usize = @intFromBool(!std.mem.endsWith(u8, css, "\n"));
    var total = std.math.add(usize, css.len, newline_len) catch
        return error.ResourceLimitExceeded;
    total = std.math.add(usize, total, marker.len) catch
        return error.ResourceLimitExceeded;
    total = std.math.add(usize, total, encoded_len) catch
        return error.ResourceLimitExceeded;
    total = std.math.add(usize, total, " */".len) catch
        return error.ResourceLimitExceeded;
    if (total > max_rendered_output_bytes) return error.ResourceLimitExceeded;

    const rendered = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    @memcpy(rendered[cursor..][0..css.len], css);
    cursor += css.len;
    if (newline_len != 0) {
        rendered[cursor] = '\n';
        cursor += 1;
    }
    @memcpy(rendered[cursor..][0..marker.len], marker);
    cursor += marker.len;
    _ = std.base64.standard.Encoder.encode(rendered[cursor..][0..encoded_len], source_map);
    cursor += encoded_len;
    @memcpy(rendered[cursor..][0.." */".len], " */");
    cursor += " */".len;
    std.debug.assert(cursor == rendered.len);
    return rendered;
}

fn renderNativeCss(
    allocator: std.mem.Allocator,
    result: *const native_api.CompileResult,
) ![]u8 {
    return renderCssWithInlineSourceMap(
        allocator,
        result.css,
        result.source_map orelse return error.CompilationFailed,
    );
}

fn commitNativeResult(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    output_file: ?[]const u8,
    result: *const native_api.CompileResult,
    source_map: bool,
    depfile_path: ?[]const u8,
) !void {
    var destination_storage: [2][]const u8 = undefined;
    var destination_count: usize = 0;
    var output_destination_index: ?usize = null;
    var depfile_destination_index: ?usize = null;
    if (output_file) |path| {
        if (!isStdioPath(path)) {
            output_destination_index = destination_count;
            destination_storage[destination_count] = path;
            destination_count += 1;
        }
    }
    if (depfile_path) |path| {
        depfile_destination_index = destination_count;
        destination_storage[destination_count] = path;
        destination_count += 1;
    }
    if (destination_count != 0) {
        const entries = [_][]const u8{input_file};
        const collision_entries = if (isStdioPath(input_file)) entries[0..0] else entries[0..];
        const dependency_groups = [_][]const native_api.Dependency{result.dependencies};
        if (try findNativeOutputCollision(
            allocator,
            collision_entries,
            &dependency_groups,
            destination_storage[0..destination_count],
        )) |collision| {
            printNativeOutputCollision(collision);
            return error.NativeOutputCollision;
        }
    }

    var prepared_storage: [2]PreparedOutputDestination = undefined;
    var prepared_count: usize = 0;
    defer for (prepared_storage[0..prepared_count]) |*destination| destination.deinit(allocator);
    for (destination_storage[0..destination_count]) |path| {
        prepared_storage[prepared_count] = try PreparedOutputDestination.init(allocator, path);
        prepared_count += 1;
    }
    if (prepared_count != 0) {
        const entries = [_][]const u8{input_file};
        const collision_entries = if (isStdioPath(input_file)) entries[0..0] else entries[0..];
        const dependency_groups = [_][]const native_api.Dependency{result.dependencies};
        if (try findNativePreparedOutputCollision(
            allocator,
            collision_entries,
            &dependency_groups,
            prepared_storage[0..prepared_count],
        )) |collision| {
            printNativeOutputCollision(collision);
            return error.NativeOutputCollision;
        }
    }

    const rendered = if (source_map)
        renderNativeCss(allocator, result) catch |err| {
            std.debug.print("Error: failed to render inline source map: {s}\n", .{@errorName(err)});
            return err;
        }
    else
        null;
    defer if (rendered) |bytes| allocator.free(bytes);
    const output = if (rendered) |bytes| bytes else result.css;

    const depfile = if (depfile_path) |path| blk: {
        const target_path = output_file orelse return error.DepfileUsageError;
        break :blk prepareDepfile(
            allocator,
            target_path,
            path,
            input_file,
            result.dependencies,
        ) catch |err| {
            if (err != error.DepfileUsageError) {
                std.debug.print("Error: failed to prepare depfile: {s}\n", .{@errorName(err)});
            }
            return err;
        };
    } else null;
    defer if (depfile) |bytes| allocator.free(bytes);

    if (output_file) |out| {
        if (isStdioPath(out)) {
            writeStdout(output) catch |err| {
                std.debug.print("Error: failed to write stdout: {s}\n", .{@errorName(err)});
                return err;
            };
        } else {
            if (depfile_path) |path| {
                _ = path;
                writePreparedOutputAndDepfile(
                    &prepared_storage[output_destination_index.?],
                    output,
                    &prepared_storage[depfile_destination_index.?],
                    depfile.?,
                ) catch |err| {
                    std.debug.print("Error: failed to commit output and depfile files: {s}\n", .{@errorName(err)});
                    return err;
                };
            } else {
                try writePreparedOutput(&prepared_storage[output_destination_index.?], output);
            }
            std.debug.print("Compiled: {s} -> {s}\n", .{ input_file, out });
        }
    } else {
        writeStdout(output) catch |err| {
            std.debug.print("Error: failed to write stdout: {s}\n", .{@errorName(err)});
            return err;
        };
    }
}

fn compileNativeInput(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    output_file: ?[]const u8,
    syntax: native_api.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
    depfile_path: ?[]const u8,
) !void {
    var result = try compileNativeSource(
        allocator,
        input_file,
        syntax,
        optimize,
        minify,
        source_map,
        prefix,
    );
    defer result.deinit();
    if (hasNativeErrorDiagnostics(result.diagnostics)) return error.CompileError;
    try commitNativeResult(
        allocator,
        input_file,
        output_file,
        &result,
        source_map,
        depfile_path,
    );
}

fn computeFileHash(content: []const u8) u64 {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(content);
    return hasher.final();
}

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

const WatchTracker = struct {
    last_source: ?WatchFingerprint = null,

    fn observeSource(self: *WatchTracker, current: WatchFingerprint) bool {
        const changed = if (self.last_source) |previous| !previous.eql(current) else true;
        self.last_source = current;
        return changed;
    }

    fn shouldCompile(
        self: *WatchTracker,
        current: WatchFingerprint,
        dependency_changed: bool,
    ) bool {
        return self.observeSource(current) or dependency_changed;
    }
};

const WatchPathContext = struct {
    pub fn hash(_: WatchPathContext, path: []const u8) u64 {
        return switch (builtin.os.tag) {
            .windows, .macos, .ios, .tvos, .watchos => blk: {
                var hasher = std.hash.Wyhash.init(0);
                var normalized: [128]u8 = undefined;
                var start: usize = 0;
                while (start < path.len) {
                    const end = @min(start + normalized.len, path.len);
                    for (path[start..end], 0..) |byte, index| {
                        normalized[index] = std.ascii.toLower(byte);
                    }
                    hasher.update(normalized[0 .. end - start]);
                    start = end;
                }
                break :blk hasher.final();
            },
            else => std.hash.Wyhash.hash(0, path),
        };
    }

    pub fn eql(_: WatchPathContext, left: []const u8, right: []const u8) bool {
        return switch (builtin.os.tag) {
            .windows, .macos, .ios, .tvos, .watchos => std.ascii.eqlIgnoreCase(left, right),
            else => std.mem.eql(u8, left, right),
        };
    }
};

const WatchPathMap = std.HashMapUnmanaged(
    []const u8,
    usize,
    WatchPathContext,
    80,
);

const WatchDependency = struct {
    path: []u8,
    fingerprint: WatchFingerprint,
};

const WatchDependencies = struct {
    allocator: std.mem.Allocator,
    items: []WatchDependency,

    fn init(allocator: std.mem.Allocator) WatchDependencies {
        return .{ .allocator = allocator, .items = &.{} };
    }

    fn deinit(self: *WatchDependencies) void {
        for (self.items) |item| self.allocator.free(item.path);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = &.{};
    }

    fn poll(self: *WatchDependencies) !bool {
        var changed = false;
        for (self.items) |*item| {
            const next = try watchFileFingerprint(self.allocator, item.path);
            if (!item.fingerprint.eql(next)) {
                item.fingerprint = next;
                changed = true;
            }
        }
        return changed;
    }
};

fn watchFileFingerprint(allocator: std.mem.Allocator, path: []const u8) !WatchFingerprint {
    const content = std.fs.cwd().readFileAlloc(allocator, path, max_input_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .unavailable = err },
    };
    defer allocator.free(content);
    return .{ .contents = computeFileHash(content) };
}

fn hasUrlScheme(specifier: []const u8) bool {
    if (specifier.len < 2 or !std.ascii.isAlphabetic(specifier[0])) return false;
    for (specifier[1..]) |byte| {
        if (byte == ':') return true;
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    return false;
}

fn localDependencyPath(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    specifier: []const u8,
) !?[]u8 {
    var path_end = specifier.len;
    if (std.mem.indexOfScalar(u8, specifier, '?')) |query| path_end = @min(path_end, query);
    if (std.mem.indexOfScalar(u8, specifier, '#')) |fragment| path_end = @min(path_end, fragment);
    const path = specifier[0..path_end];
    if (path.len == 0 or
        path[0] == '/' or
        path[0] == '\\' or
        hasUrlScheme(path) or
        std.fs.path.isAbsolute(path))
    {
        return null;
    }

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    return try std.fs.path.resolve(allocator, &.{ source_dir, path });
}

fn buildWatchDependencies(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dependencies: []const zigcss.Dependency,
    previous: *const WatchDependencies,
) !WatchDependencies {
    const source_absolute = try std.fs.path.resolve(allocator, &.{source_path});
    defer allocator.free(source_absolute);

    var previous_paths = WatchPathMap.empty;
    defer previous_paths.deinit(allocator);
    for (previous.items, 0..) |item, index| {
        try previous_paths.putContext(allocator, item.path, index, .{});
    }

    var seen = WatchPathMap.empty;
    defer seen.deinit(allocator);
    var items = try std.ArrayList(WatchDependency).initCapacity(allocator, 0);
    defer items.deinit(allocator);
    errdefer for (items.items) |item| allocator.free(item.path);

    for (dependencies) |dependency| {
        const resolved = try localDependencyPath(
            allocator,
            source_path,
            dependency.specifier,
        ) orelse continue;
        if (WatchPathContext.eql(.{}, source_absolute, resolved)) {
            allocator.free(resolved);
            continue;
        }

        const seen_entry = seen.getOrPutContext(allocator, resolved, .{}) catch |err| {
            allocator.free(resolved);
            return err;
        };
        if (seen_entry.found_existing) {
            allocator.free(resolved);
            continue;
        }
        seen_entry.value_ptr.* = items.items.len;

        const fingerprint = if (previous_paths.getContext(resolved, .{})) |previous_index|
            previous.items[previous_index].fingerprint
        else
            watchFileFingerprint(allocator, resolved) catch |err| {
                allocator.free(resolved);
                return err;
            };
        items.append(allocator, .{
            .path = resolved,
            .fingerprint = fingerprint,
        }) catch |err| {
            allocator.free(resolved);
            return err;
        };
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn watchFile(allocator: std.mem.Allocator, config: CompileConfig) !void {
    std.debug.print("Watching {s} for changes... (Press Ctrl+C to stop)\n", .{config.input_file});

    var tracker = WatchTracker{};
    var watched_dependencies = WatchDependencies.init(allocator);
    defer watched_dependencies.deinit();

    while (true) {
        const input = readInput(allocator, config.input_file) catch |err| {
            if (err == error.OutOfMemory) return err;
            const source_changed = tracker.observeSource(.{ .unavailable = err });
            _ = try watched_dependencies.poll();
            if (source_changed) {
                std.debug.print("Error: failed to read {s}: {s}\n", .{ config.input_file, @errorName(err) });
            }
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(input);

        const first_attempt = tracker.last_source == null;
        const dependency_changed = try watched_dependencies.poll();
        if (tracker.shouldCompile(
            .{ .contents = computeFileHash(input) },
            dependency_changed,
        )) {
            if (!first_attempt) std.debug.print("Source or dependency changed, recompiling...\n", .{});

            var result = compileLoadedFile(allocator, config, input) catch |err| {
                if (err == error.OutOfMemory) return err;
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            };
            defer result.deinit();

            const next_dependencies = try buildWatchDependencies(
                allocator,
                config.input_file,
                result.dependencies,
                &watched_dependencies,
            );
            watched_dependencies.deinit();
            watched_dependencies = next_dependencies;
        }

        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn watchNativeFile(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    output_file: ?[]const u8,
    syntax: native_api.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
) !void {
    const entry_path = std.fs.cwd().realpathAlloc(allocator, input_file) catch |err| {
        std.debug.print("Error: failed to resolve {s}: {s}\n", .{ input_file, @errorName(err) });
        return err;
    };
    defer allocator.free(entry_path);
    const root_path = std.fs.path.dirname(entry_path) orelse return error.InvalidSourcePath;

    std.debug.print("Watching {s} for changes... (Press Ctrl+C to stop)\n", .{input_file});
    var tracker = WatchTracker{};
    var watched_result: ?native_api.CompileResult = null;
    defer if (watched_result) |*result| result.deinit();

    while (true) {
        const input = (if (watched_result) |*result|
            result.readWatchInput(allocator)
        else
            std.fs.cwd().readFileAlloc(allocator, entry_path, max_input_bytes)) catch |err| {
            if (err == error.OutOfMemory) return err;
            const source_changed = tracker.observeSource(.{ .unavailable = err });
            if (watched_result) |*result| _ = try result.pollWatchInputs();
            if (source_changed) {
                std.debug.print("Error: failed to read {s}: {s}\n", .{ input_file, @errorName(err) });
            }
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(input);

        const first_attempt = tracker.last_source == null;
        const dependency_changed = if (watched_result) |*result|
            try result.pollWatchInputs()
        else
            false;
        if (tracker.shouldCompile(
            .{ .contents = computeFileHash(input) },
            dependency_changed,
        )) {
            if (!first_attempt) std.debug.print("Source or dependency changed, recompiling...\n", .{});

            var next_result = compileNativeLoadedSource(
                allocator,
                entry_path,
                root_path,
                input,
                syntax,
                optimize,
                minify,
                true,
                source_map,
                prefix,
                true,
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            };
            errdefer next_result.deinit();
            if (hasNativeErrorDiagnostics(next_result.diagnostics)) {
                next_result.deinit();
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            }
            try commitNativeResult(
                allocator,
                input_file,
                output_file,
                &next_result,
                source_map,
                null,
            );

            if (watched_result) |*result| result.deinit();
            watched_result = next_result.take();
            next_result.deinit();
        }

        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn compileTask(task: *CompileTask) bool {
    const allocator = task.allocator();
    const input = std.fs.cwd().readFileAlloc(allocator, task.input_file, max_input_bytes) catch |err| {
        setTaskError(task, "Failed to read {s}: {s}", .{ task.input_file, @errorName(err) }, "Read error");
        return false;
    };
    defer allocator.free(input);

    var result = compileCss(
        allocator,
        task.input_file,
        input,
        task.syntax,
        task.optimize,
        task.minify,
        task.source_map,
        false,
        task.prefix,
    ) catch |err| {
        setTaskError(task, "Compilation error: {s}", .{@errorName(err)}, "Compilation error");
        return false;
    };
    task.result = result.take();
    result.deinit();
    if (hasErrorDiagnostics(task.result.?.diagnostics)) {
        task.state = .failed;
        return false;
    }
    if (task.source_map) {
        const source_map = task.result.?.source_map orelse {
            setTaskError(task, "Compilation error: {s}", .{"MissingSourceMap"}, "Compilation error");
            return false;
        };
        task.rendered_css = renderCssWithInlineSourceMap(
            allocator,
            task.result.?.css,
            source_map,
        ) catch |err| {
            setTaskError(task, "Compilation error: {s}", .{@errorName(err)}, "Compilation error");
            return false;
        };
    }
    task.state = .succeeded;
    return task.state == .succeeded;
}

fn taskFailed(task: *const CompileTask) bool {
    return task.state == .failed;
}

fn printTaskFailure(task: *const CompileTask) void {
    if (task.err) |err| {
        std.debug.print("Error compiling {s}: {s}\n", .{ task.input_file, err });
        return;
    }
    if (task.result != null and hasErrorDiagnostics(task.result.?.diagnostics)) {
        printDiagnostics(task.result.?.diagnostics);
    }
}

const BatchWorkQueue = struct {
    tasks: []CompileTask,
    mutex: std.Thread.Mutex = .{},
    next_index: usize = 0,
    cancelled: bool = false,
    failed: bool = false,

    fn claim(self: *BatchWorkQueue) ?*CompileTask {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancelled or self.next_index >= self.tasks.len) return null;

        const task = &self.tasks[self.next_index];
        self.next_index += 1;
        std.debug.assert(task.state == .pending);
        task.state = .running;
        return task;
    }

    fn cancel(self: *BatchWorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
    }

    fn cancelForFailure(self: *BatchWorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failed = true;
        self.cancelled = true;
    }

    fn markPendingCancelled(self: *BatchWorkQueue) void {
        for (self.tasks) |*task| {
            if (task.state == .pending) task.state = .cancelled;
        }
    }
};

fn batchWorker(queue: *BatchWorkQueue) void {
    while (queue.claim()) |task| {
        if (!compileTask(task)) {
            queue.cancelForFailure();
            return;
        }
    }
}

fn batchWorkerCount(task_count: usize, cpu_count: usize) usize {
    if (task_count == 0) return 0;
    return @min(task_count, @min(@max(cpu_count, 1), max_batch_workers));
}

fn compileFilesParallel(allocator: std.mem.Allocator, tasks: []CompileTask) !void {
    if (tasks.len == 0) return;
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const worker_count = batchWorkerCount(tasks.len, cpu_count);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var queue = BatchWorkQueue{ .tasks = tasks };
    var spawned: usize = 0;
    var spawn_error: ?anyerror = null;
    while (spawned < worker_count) {
        threads[spawned] = std.Thread.spawn(.{}, batchWorker, .{&queue}) catch |err| {
            queue.cancel();
            spawn_error = err;
            break;
        };
        spawned += 1;
    }
    for (threads[0..spawned]) |thread| thread.join();
    queue.markPendingCancelled();

    if (spawn_error) |err| return err;
    if (queue.failed) {
        for (tasks) |*task| {
            if (taskFailed(task)) printTaskFailure(task);
        }
        return error.CompileError;
    }

    const prepared_destinations = try allocator.alloc(PreparedOutputDestination, tasks.len);
    defer allocator.free(prepared_destinations);
    var prepared_count: usize = 0;
    defer for (prepared_destinations[0..prepared_count]) |*destination| destination.deinit(allocator);
    const input_paths = try allocator.alloc([]const u8, tasks.len);
    defer allocator.free(input_paths);
    for (tasks, 0..) |*task, task_index| {
        if (task.state != .succeeded) return error.CompileError;
        input_paths[prepared_count] = task.input_file;
        prepared_destinations[prepared_count] = if (task_index == 0)
            try PreparedOutputDestination.init(allocator, task.output_file)
        else
            try PreparedOutputDestination.initSibling(
                allocator,
                &prepared_destinations[0],
                task.output_file,
            );
        prepared_count += 1;
    }
    if (try findPreparedOutputCollision(
        allocator,
        input_paths,
        prepared_destinations,
    )) |collision| {
        printOutputCollision(collision);
        return error.BatchUsageError;
    }

    for (tasks, 0..) |*task, task_index| {
        try writePreparedOutput(
            &prepared_destinations[task_index],
            task.rendered_css orelse task.result.?.css,
        );
        std.debug.print("Compiled: {s} -> {s}\n", .{ task.input_file, task.output_file });
    }
}

fn compileNativeTask(task: *NativeBatchTask) bool {
    const allocator = task.allocator();
    task.result = compileNativeSourceQuiet(
        allocator,
        task.input_file,
        task.syntax,
        task.optimize,
        task.minify,
        task.source_map,
        task.prefix,
    ) catch |err| {
        task.err = err;
        task.state = .failed;
        return false;
    };
    if (hasNativeErrorDiagnostics(task.result.?.diagnostics)) {
        task.state = .failed;
        return false;
    }
    if (task.source_map) {
        task.rendered_css = renderNativeCss(allocator, &task.result.?) catch |err| {
            task.err = err;
            task.state = .failed;
            return false;
        };
    }
    task.state = .succeeded;
    return task.state == .succeeded;
}

fn printNativeTaskFailure(task: *const NativeBatchTask) void {
    if (task.result) |result| {
        if (hasNativeErrorDiagnostics(result.diagnostics)) {
            printNativeDiagnostics(result.diagnostics);
            return;
        }
    }
    std.debug.print(
        "Error: native {s} compilation failed for {s}: {s}\n",
        .{
            nativeSyntaxLabel(task.syntax),
            task.input_file,
            @errorName(task.err orelse error.CompileError),
        },
    );
}

const NativeBatchWorkQueue = struct {
    tasks: []NativeBatchTask,
    mutex: std.Thread.Mutex = .{},
    next_index: usize = 0,
    cancelled: bool = false,
    failed: bool = false,

    fn claim(self: *NativeBatchWorkQueue) ?*NativeBatchTask {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancelled or self.next_index >= self.tasks.len) return null;

        const task = &self.tasks[self.next_index];
        self.next_index += 1;
        std.debug.assert(task.state == .pending);
        task.state = .running;
        return task;
    }

    fn cancel(self: *NativeBatchWorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
    }

    fn cancelForFailure(self: *NativeBatchWorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failed = true;
        self.cancelled = true;
    }

    fn markPendingCancelled(self: *NativeBatchWorkQueue) void {
        for (self.tasks) |*task| {
            if (task.state == .pending) task.state = .cancelled;
        }
    }
};

fn nativeBatchWorker(queue: *NativeBatchWorkQueue) void {
    while (queue.claim()) |task| {
        if (!compileNativeTask(task)) {
            queue.cancelForFailure();
            return;
        }
    }
}

fn compileNativeFilesParallel(allocator: std.mem.Allocator, tasks: []NativeBatchTask) !void {
    if (tasks.len == 0) return;
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const worker_count = batchWorkerCount(tasks.len, cpu_count);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var queue = NativeBatchWorkQueue{ .tasks = tasks };
    var spawned: usize = 0;
    var spawn_error: ?anyerror = null;
    while (spawned < worker_count) {
        threads[spawned] = std.Thread.spawn(.{}, nativeBatchWorker, .{&queue}) catch |err| {
            queue.cancel();
            spawn_error = err;
            break;
        };
        spawned += 1;
    }
    for (threads[0..spawned]) |thread| thread.join();
    queue.markPendingCancelled();

    if (spawn_error) |err| return err;
    if (queue.failed) {
        var allocation_failed = false;
        for (tasks) |*task| {
            if (task.state == .failed) {
                printNativeTaskFailure(task);
                if (task.err) |err| {
                    if (err == error.OutOfMemory) allocation_failed = true;
                }
            }
        }
        if (allocation_failed) return error.OutOfMemory;
        return error.CompileError;
    }

    const entry_paths = try allocator.alloc([]const u8, tasks.len);
    defer allocator.free(entry_paths);
    const dependency_groups = try allocator.alloc([]const native_api.Dependency, tasks.len);
    defer allocator.free(dependency_groups);
    const destination_paths = try allocator.alloc([]const u8, tasks.len);
    defer allocator.free(destination_paths);
    for (tasks, 0..) |*task, task_index| {
        if (task.state != .succeeded) return error.CompileError;
        entry_paths[task_index] = task.input_file;
        dependency_groups[task_index] = task.result.?.dependencies;
        destination_paths[task_index] = task.output_file;
    }
    if (try findNativeOutputCollision(
        allocator,
        entry_paths,
        dependency_groups,
        destination_paths,
    )) |collision| {
        printNativeOutputCollision(collision);
        return error.NativeOutputCollision;
    }

    const prepared_destinations = try allocator.alloc(PreparedOutputDestination, tasks.len);
    defer allocator.free(prepared_destinations);
    var prepared_count: usize = 0;
    defer for (prepared_destinations[0..prepared_count]) |*destination| destination.deinit(allocator);
    for (tasks, 0..) |*task, task_index| {
        prepared_destinations[task_index] = if (task_index == 0)
            try PreparedOutputDestination.init(allocator, task.output_file)
        else
            try PreparedOutputDestination.initSibling(
                allocator,
                &prepared_destinations[0],
                task.output_file,
            );
        prepared_count += 1;
    }
    if (try findNativePreparedOutputCollision(
        allocator,
        entry_paths,
        dependency_groups,
        prepared_destinations,
    )) |collision| {
        printNativeOutputCollision(collision);
        return error.NativeOutputCollision;
    }

    for (tasks, 0..) |*task, task_index| {
        printNativeDiagnostics(task.result.?.diagnostics);
        try writePreparedOutput(
            &prepared_destinations[task_index],
            task.rendered_css orelse task.result.?.css,
        );
        std.debug.print("Compiled: {s} -> {s}\n", .{ task.input_file, task.output_file });
    }
}

const CompileError = error{CompileError};

fn runLspServer(allocator: std.mem.Allocator) !lsp.ExitStatus {
    var server = lsp.LspServer.init(allocator);
    defer server.deinit();

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

    while (try lsp_transport.readFrame(allocator, &stdin_reader.interface)) |request| {
        defer allocator.free(request);
        switch (try server.handleMessage(request)) {
            .response => |response| {
                defer allocator.free(response);
                try lsp_transport.writeFrame(&stdout_writer.interface, response);
                try stdout_writer.interface.flush();
            },
            .no_response => {},
            .exit => |status| return status,
        }
    }
    return .success;
}

const InputPatternError = error{
    TooManyInputPatterns,
    InputPathTooLong,
    InputNameTooLong,
};

fn validateInputPattern(pattern: []const u8) InputPatternError!void {
    if (pattern.len > max_cli_input_path_bytes) return error.InputPathTooLong;
    if (std.fs.path.basename(pattern).len > max_glob_component_bytes) {
        return error.InputNameTooLong;
    }
}

fn appendInputPattern(
    allocator: std.mem.Allocator,
    patterns: *std.ArrayList([]const u8),
    pattern: []const u8,
) (InputPatternError || std.mem.Allocator.Error)!void {
    if (patterns.items.len >= max_input_patterns) return error.TooManyInputPatterns;
    try validateInputPattern(pattern);
    try patterns.append(allocator, pattern);
}

fn globPathLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn expandGlob(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    max_results: usize,
) !std.ArrayList([]const u8) {
    try validateInputPattern(pattern);
    var files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }

    if (std.mem.indexOf(u8, pattern, "*") == null) {
        if (max_results == 0) return error.TooManyExpandedInputs;
        const pattern_copy = try allocator.dupe(u8, pattern);
        files.append(allocator, pattern_copy) catch |err| {
            allocator.free(pattern_copy);
            return err;
        };
        return files;
    }

    const cwd = std.fs.cwd();
    const dir_path = std.fs.path.dirname(pattern) orelse ".";
    const basename_pattern = std.fs.path.basename(pattern);

    var dir = try cwd.openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name.len > max_glob_component_bytes) {
            return error.GlobEntryNameTooLong;
        }
        if (matchPattern(basename_pattern, entry.name)) {
            if (files.items.len >= max_results) return error.TooManyExpandedInputs;
            const joined_len = std.math.add(usize, dir_path.len, entry.name.len) catch
                return error.ExpandedInputPathTooLong;
            const joined_len_with_separator = std.math.add(usize, joined_len, 1) catch
                return error.ExpandedInputPathTooLong;
            if (joined_len_with_separator > max_cli_input_path_bytes) {
                return error.ExpandedInputPathTooLong;
            }
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            files.append(allocator, full_path) catch |err| {
                allocator.free(full_path);
                return err;
            };
        }
    }

    std.mem.sort([]const u8, files.items, {}, globPathLessThan);
    return files;
}

fn findLiteralLinear(haystack: []const u8, needle: []const u8, prefix: []usize) ?usize {
    if (needle.len == 0) return 0;
    std.debug.assert(prefix.len >= needle.len);

    prefix[0] = 0;
    var pattern_index: usize = 1;
    var prefix_len: usize = 0;
    while (pattern_index < needle.len) {
        if (needle[pattern_index] == needle[prefix_len]) {
            prefix_len += 1;
            prefix[pattern_index] = prefix_len;
            pattern_index += 1;
        } else if (prefix_len > 0) {
            prefix_len = prefix[prefix_len - 1];
        } else {
            prefix[pattern_index] = 0;
            pattern_index += 1;
        }
    }

    var haystack_index: usize = 0;
    var needle_index: usize = 0;
    while (haystack_index < haystack.len) {
        if (haystack[haystack_index] == needle[needle_index]) {
            haystack_index += 1;
            needle_index += 1;
            if (needle_index == needle.len) return haystack_index - needle.len;
        } else if (needle_index > 0) {
            needle_index = prefix[needle_index - 1];
        } else {
            haystack_index += 1;
        }
    }
    return null;
}

fn matchPattern(pattern: []const u8, name: []const u8) bool {
    const first_star = std.mem.indexOfScalar(u8, pattern, '*') orelse
        return std.mem.eql(u8, pattern, name);
    const last_star = std.mem.lastIndexOfScalar(u8, pattern, '*').?;
    const prefix = pattern[0..first_star];
    const suffix = pattern[last_star + 1 ..];

    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (prefix.len > name.len or suffix.len > name.len - prefix.len) return false;
    if (!std.mem.endsWith(u8, name, suffix)) return false;

    var name_cursor = prefix.len;
    const search_end = name.len - suffix.len;
    var prefix_table: [max_glob_component_bytes]usize = undefined;
    const middle = if (last_star > first_star)
        pattern[first_star + 1 .. last_star]
    else
        "";
    var chunks = std.mem.splitScalar(u8, middle, '*');
    while (chunks.next()) |chunk| {
        if (chunk.len == 0) continue;
        if (chunk.len > prefix_table.len) return false;
        const relative_index = findLiteralLinear(
            name[name_cursor..search_end],
            chunk,
            prefix_table[0..chunk.len],
        ) orelse return false;
        name_cursor += relative_index + chunk.len;
    }
    return true;
}

fn exerciseLiteralGlobAllocationFailures(allocator: std.mem.Allocator) !void {
    var files = try expandGlob(allocator, "input.css", 1);
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expectEqualStrings("input.css", files.items[0]);
}

test "literal glob expansion unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLiteralGlobAllocationFailures,
        .{},
    );
}

test "glob star matcher preserves anchored wildcard semantics" {
    const cases = [_]struct {
        pattern: []const u8,
        name: []const u8,
        matches: bool,
    }{
        .{ .pattern = "", .name = "", .matches = true },
        .{ .pattern = "", .name = "a", .matches = false },
        .{ .pattern = "*", .name = "", .matches = true },
        .{ .pattern = "***", .name = "anything.css", .matches = true },
        .{ .pattern = "a*b", .name = "ab", .matches = true },
        .{ .pattern = "a*b", .name = "axxxb", .matches = true },
        .{ .pattern = "a*b", .name = "axxxc", .matches = false },
        .{ .pattern = "a*a", .name = "a", .matches = false },
        .{ .pattern = "*ab*cd*ef", .name = "00ab11cd22ef", .matches = true },
        .{ .pattern = "*ab*cd*ef", .name = "00ab11dc22ef", .matches = false },
        .{ .pattern = "file.*.css", .name = "file.theme.css", .matches = true },
        .{ .pattern = "file.*.css", .name = "xfile.theme.css", .matches = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.matches, matchPattern(case.pattern, case.name));
    }
}

test "glob star matcher handles the maximum adversarial pattern iteratively" {
    const pattern = try std.testing.allocator.alloc(u8, max_glob_component_bytes);
    defer std.testing.allocator.free(pattern);
    const name = try std.testing.allocator.alloc(u8, max_glob_component_bytes - 2);
    defer std.testing.allocator.free(name);

    @memset(pattern, 'a');
    pattern[0] = '*';
    pattern[pattern.len - 2] = 'b';
    pattern[pattern.len - 1] = '*';
    @memset(name, 'a');
    // The suffix already matches: the long, self-overlapping middle literal is
    // what must fail without recursive restart/backtracking.
    try std.testing.expect(!matchPattern(pattern, name));
    name[name.len - 1] = 'b';
    try std.testing.expect(matchPattern(pattern, name));
}

test "glob expansion sorts matches and enforces its result budget before joining" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "z.css", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "a.css", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "m.css", .data = "" });
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const pattern = try std.fs.path.join(std.testing.allocator, &.{ directory, "*.css" });
    defer std.testing.allocator.free(pattern);

    var expanded = try expandGlob(std.testing.allocator, pattern, 3);
    defer {
        for (expanded.items) |path| std.testing.allocator.free(path);
        expanded.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), expanded.items.len);
    try std.testing.expectEqualStrings("a.css", std.fs.path.basename(expanded.items[0]));
    try std.testing.expectEqualStrings("m.css", std.fs.path.basename(expanded.items[1]));
    try std.testing.expectEqualStrings("z.css", std.fs.path.basename(expanded.items[2]));
    try std.testing.expectError(
        error.TooManyExpandedInputs,
        expandGlob(std.testing.allocator, pattern, 2),
    );
}

test "input and glob expansion bounds fail before unbounded growth" {
    var patterns = try std.ArrayList([]const u8).initCapacity(
        std.testing.allocator,
        max_input_patterns,
    );
    defer patterns.deinit(std.testing.allocator);
    for (0..max_input_patterns) |_| {
        try appendInputPattern(std.testing.allocator, &patterns, "input.css");
    }
    try std.testing.expectError(
        error.TooManyInputPatterns,
        appendInputPattern(std.testing.allocator, &patterns, "overflow.css"),
    );

    const long_path = try std.testing.allocator.alloc(u8, max_cli_input_path_bytes + 1);
    defer std.testing.allocator.free(long_path);
    @memset(long_path, 'a');
    try std.testing.expectError(error.InputPathTooLong, validateInputPattern(long_path));

    const long_name = try std.testing.allocator.alloc(u8, max_glob_component_bytes + 1);
    defer std.testing.allocator.free(long_name);
    @memset(long_name, 'a');
    try std.testing.expectError(error.InputNameTooLong, validateInputPattern(long_name));

    try std.testing.expectError(
        error.TooManyExpandedInputs,
        expandGlob(std.testing.allocator, "literal.css", 0),
    );
}

const PathIdentity = struct {
    normalized: []u8,
    object: ?FileObjectIdentity,

    fn deinit(self: *PathIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized);
    }
};

const FileObjectIdentity = struct {
    /// File indexes/inodes are scoped to one filesystem. Pairing them with the
    /// volume/device identity prevents unrelated mounts from becoming aliases.
    volume: u64,
    inode: u128,
};

fn unsignedObjectIdentity(value: anytype) u128 {
    const Value = @TypeOf(value);
    const Unsigned = std.meta.Int(.unsigned, @bitSizeOf(Value));
    const identity: Unsigned = @bitCast(value);
    return @intCast(identity);
}

fn windowsVolumeIdentity(file: std.fs.File) !u64 {
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
        else => return error.Unexpected,
    }
    return volume_info.VolumeSerialNumber;
}

fn objectIdentityFromFile(file: std.fs.File) !?FileObjectIdentity {
    const stat = try file.stat();
    if (stat.inode == 0) return null;
    if (builtin.os.tag == .windows) {
        // A Windows file index is only unique within its volume. If the volume
        // query is unavailable, do not publish a globally comparable partial
        // identity; callers retain their canonical-path checks.
        const volume = windowsVolumeIdentity(file) catch return null;
        return .{
            .volume = volume,
            .inode = unsignedObjectIdentity(stat.inode),
        };
    }

    const native = try std.posix.fstat(file.handle);
    return .{
        .volume = @intCast(unsignedObjectIdentity(native.dev)),
        .inode = unsignedObjectIdentity(stat.inode),
    };
}

fn objectIdentityAtPath(raw_path: []const u8) !?FileObjectIdentity {
    if (builtin.os.tag == .windows) {
        var file = std.fs.cwd().openFile(raw_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => return null,
            else => return err,
        };
        defer file.close();
        return objectIdentityFromFile(file);
    }

    // fstatat preserves the historical ability to identify readable or
    // unreadable filesystem entries while adding the device id to the key.
    const native = std.posix.fstatat(std.fs.cwd().fd, raw_path, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (native.ino == 0) return null;
    return .{
        .volume = @intCast(unsignedObjectIdentity(native.dev)),
        .inode = unsignedObjectIdentity(native.ino),
    };
}

fn objectIdentityAtDestination(destination: *const PreparedOutputDestination) !?FileObjectIdentity {
    if (builtin.os.tag == .windows) {
        // Windows openFile reports AccessDenied for a directory. Try the
        // directory shape first so an existing directory is still tracked as
        // the prepared object and the later atomic rename fails consistently,
        // instead of rejecting an otherwise valid parent capability early.
        if (destination.dir.openDir(destination.basename(), .{})) |opened| {
            var directory = opened;
            defer directory.close();
            return objectIdentityFromFile(std.fs.File{ .handle = directory.fd });
        } else |dir_err| switch (dir_err) {
            error.FileNotFound => return null,
            error.NotDir, error.AccessDenied => {},
            else => return dir_err,
        }

        var file = destination.dir.openFile(destination.basename(), .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => return null,
            else => return err,
        };
        defer file.close();
        return objectIdentityFromFile(file);
    }

    const native = std.posix.fstatat(destination.dir.fd, destination.basename(), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (native.ino == 0) return null;
    return .{
        .volume = @intCast(unsignedObjectIdentity(native.dev)),
        .inode = unsignedObjectIdentity(native.ino),
    };
}

const OutputCollision = struct {
    kind: enum {
        output_is_input,
        duplicate_output,
    },
    path: []const u8,
};

fn canonicalizeAbsolutePath(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, absolute_path) catch |err| {
        if (err != error.FileNotFound and err != error.NotDir and err != error.IsDir) return err;

        const parent = std.fs.path.dirname(absolute_path) orelse return allocator.dupe(u8, absolute_path);
        if (std.mem.eql(u8, parent, absolute_path)) return allocator.dupe(u8, absolute_path);

        const canonical_parent = try canonicalizeAbsolutePath(allocator, parent);
        defer allocator.free(canonical_parent);
        return std.fs.path.join(allocator, &.{ canonical_parent, std.fs.path.basename(absolute_path) });
    };
}

fn identifyPath(allocator: std.mem.Allocator, raw_path: []const u8) !PathIdentity {
    const absolute_path = try std.fs.path.resolve(allocator, &.{raw_path});
    defer allocator.free(absolute_path);
    const object = try objectIdentityAtPath(raw_path);

    return .{
        .normalized = try canonicalizeAbsolutePath(allocator, absolute_path),
        .object = object,
    };
}

fn identifyPreparedDestination(
    allocator: std.mem.Allocator,
    destination: *const PreparedOutputDestination,
) !PathIdentity {
    const object = try objectIdentityAtDestination(destination);
    return .{
        .normalized = try allocator.dupe(u8, destination.canonical_path),
        .object = object,
    };
}

const PathIdentityStringSet = std.HashMapUnmanaged(
    []const u8,
    void,
    WatchPathContext,
    80,
);
const PathIdentityObjectSet = std.AutoHashMapUnmanaged(FileObjectIdentity, void);

const PreparedDirectoryNameKey = struct {
    directory: FileObjectIdentity,
    basename: []const u8,
};

const PreparedDirectoryNameContext = struct {
    pub fn hash(_: PreparedDirectoryNameContext, key: PreparedDirectoryNameKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.directory.volume));
        hasher.update(std.mem.asBytes(&key.directory.inode));
        switch (builtin.os.tag) {
            .windows, .macos, .ios, .tvos, .watchos => {
                var normalized: [128]u8 = undefined;
                var start: usize = 0;
                while (start < key.basename.len) {
                    const end = @min(start + normalized.len, key.basename.len);
                    for (key.basename[start..end], 0..) |byte, index| {
                        normalized[index] = std.ascii.toLower(byte);
                    }
                    hasher.update(normalized[0 .. end - start]);
                    start = end;
                }
            },
            else => hasher.update(key.basename),
        }
        return hasher.final();
    }

    pub fn eql(
        _: PreparedDirectoryNameContext,
        left: PreparedDirectoryNameKey,
        right: PreparedDirectoryNameKey,
    ) bool {
        if (!std.meta.eql(left.directory, right.directory)) return false;
        return switch (builtin.os.tag) {
            .windows, .macos, .ios, .tvos, .watchos => std.ascii.eqlIgnoreCase(left.basename, right.basename),
            else => std.mem.eql(u8, left.basename, right.basename),
        };
    }
};

const PreparedDirectoryNameSet = std.HashMapUnmanaged(
    PreparedDirectoryNameKey,
    void,
    PreparedDirectoryNameContext,
    80,
);

fn preparedDirectoriesEqual(
    left: *const PreparedOutputDestination,
    right: *const PreparedOutputDestination,
) bool {
    if (left.directory_identity) |left_identity| {
        if (right.directory_identity) |right_identity| {
            return std.meta.eql(left_identity, right_identity);
        }
    }

    const left_parent = std.fs.path.dirname(left.canonical_path) orelse return false;
    const right_parent = std.fs.path.dirname(right.canonical_path) orelse return false;
    return switch (builtin.os.tag) {
        .windows => std.os.windows.eqlIgnoreCaseWtf8(left_parent, right_parent),
        .macos, .ios, .tvos, .watchos => std.ascii.eqlIgnoreCase(left_parent, right_parent),
        else => std.mem.eql(u8, left_parent, right_parent),
    };
}

fn applePreparedNamesMayAlias(left_name: []const u8, right_name: []const u8) bool {
    if (!containsNonAscii(left_name) and !containsNonAscii(right_name)) return false;

    // APFS/HFS Unicode normalization and case rules are volume-configurable and
    // have no portable userspace hash. Different all-ASCII extensions cannot
    // normalize to the same name; otherwise fail closed before either rename.
    const left_extension = std.fs.path.extension(left_name);
    const right_extension = std.fs.path.extension(right_name);
    if (containsNonAscii(left_extension) or containsNonAscii(right_extension)) return true;
    return std.ascii.eqlIgnoreCase(left_extension, right_extension);
}

fn preparedNamesMayAlias(
    left: *const PreparedOutputDestination,
    right: *const PreparedOutputDestination,
) bool {
    if (!preparedDirectoriesEqual(left, right)) return false;
    return switch (builtin.os.tag) {
        .windows => std.os.windows.eqlIgnoreCaseWtf8(left.basename(), right.basename()),
        .macos, .ios, .tvos, .watchos => applePreparedNamesMayAlias(left.basename(), right.basename()),
        else => std.mem.eql(u8, left.basename(), right.basename()),
    };
}

fn preparedNameNeedsConservativeScanForOs(
    os_tag: std.Target.Os.Tag,
    basename: []const u8,
) bool {
    // Windows and Apple filesystems need platform Unicode case/normalization
    // semantics for arbitrary explicit names. Other targets can index exact
    // non-ASCII bytes without degrading a large batch to pairwise scans.
    return usesCaseInsensitivePathPolicy(os_tag) and containsNonAscii(basename);
}

fn findPreparedOutputCollision(
    allocator: std.mem.Allocator,
    input_paths: []const []const u8,
    destinations: []const PreparedOutputDestination,
) !?OutputCollision {
    const input_identities = try allocator.alloc(PathIdentity, input_paths.len);
    defer allocator.free(input_identities);
    var initialized_inputs: usize = 0;
    defer for (input_identities[0..initialized_inputs]) |*identity| identity.deinit(allocator);

    var input_paths_by_name: PathIdentityStringSet = .empty;
    defer input_paths_by_name.deinit(allocator);
    try input_paths_by_name.ensureTotalCapacity(allocator, @intCast(input_paths.len));
    var input_paths_by_object: PathIdentityObjectSet = .empty;
    defer input_paths_by_object.deinit(allocator);
    try input_paths_by_object.ensureTotalCapacity(allocator, @intCast(input_paths.len));
    for (input_paths, 0..) |input_path, index| {
        input_identities[index] = try identifyPath(allocator, input_path);
        initialized_inputs += 1;
        input_paths_by_name.putAssumeCapacity(input_identities[index].normalized, {});
        if (input_identities[index].object) |object| input_paths_by_object.putAssumeCapacity(object, {});
    }

    const output_identities = try allocator.alloc(PathIdentity, destinations.len);
    defer allocator.free(output_identities);
    var initialized_outputs: usize = 0;
    defer for (output_identities[0..initialized_outputs]) |*identity| identity.deinit(allocator);
    var output_paths_by_name: PathIdentityStringSet = .empty;
    defer output_paths_by_name.deinit(allocator);
    try output_paths_by_name.ensureTotalCapacity(allocator, @intCast(destinations.len));
    var output_paths_by_object: PathIdentityObjectSet = .empty;
    defer output_paths_by_object.deinit(allocator);
    try output_paths_by_object.ensureTotalCapacity(allocator, @intCast(destinations.len));
    var output_names_by_directory: PreparedDirectoryNameSet = .empty;
    defer output_names_by_directory.deinit(allocator);
    try output_names_by_directory.ensureTotalCapacity(allocator, @intCast(destinations.len));

    var saw_conservative_destination = false;
    for (destinations, 0..) |*destination, index| {
        const destination_needs_conservative_scan =
            preparedNameNeedsConservativeScanForOs(builtin.os.tag, destination.basename());
        const directory_name_key: ?PreparedDirectoryNameKey = if (!destination_needs_conservative_scan)
            if (destination.directory_identity) |directory| .{
                .directory = directory,
                .basename = destination.basename(),
            } else null
        else
            null;
        if (directory_name_key) |key| {
            if (output_names_by_directory.contains(key)) {
                return .{ .kind = .duplicate_output, .path = destination.display_path };
            }
        }
        if (destination_needs_conservative_scan or saw_conservative_destination) {
            for (destinations[0..index]) |*previous| {
                const previous_needs_conservative_scan =
                    preparedNameNeedsConservativeScanForOs(builtin.os.tag, previous.basename());
                if (!destination_needs_conservative_scan and !previous_needs_conservative_scan) continue;
                if (preparedNamesMayAlias(previous, destination)) {
                    return .{ .kind = .duplicate_output, .path = destination.display_path };
                }
            }
        }
        saw_conservative_destination =
            saw_conservative_destination or destination_needs_conservative_scan;

        output_identities[index] = try identifyPreparedDestination(allocator, destination);
        initialized_outputs += 1;
        const output_identity = output_identities[index];
        if (!std.meta.eql(destination.expected_object, output_identity.object)) {
            std.debug.print(
                "Error: output destination changed while preparing commit: {s}\n",
                .{destination.display_path},
            );
            return error.OutputDestinationChanged;
        }
        const matches_input_name = input_paths_by_name.contains(output_identity.normalized);
        const matches_input_object = if (output_identity.object) |object|
            input_paths_by_object.contains(object)
        else
            false;
        if (matches_input_name or matches_input_object) {
            return .{ .kind = .output_is_input, .path = destination.display_path };
        }
        if (output_paths_by_name.contains(output_identity.normalized) or
            (if (output_identity.object) |object| output_paths_by_object.contains(object) else false))
        {
            return .{ .kind = .duplicate_output, .path = destination.display_path };
        }
        output_paths_by_name.putAssumeCapacity(output_identity.normalized, {});
        if (output_identity.object) |object| output_paths_by_object.putAssumeCapacity(object, {});
        if (directory_name_key) |key| output_names_by_directory.putAssumeCapacity(key, {});
    }
    return null;
}

fn findOutputCollision(allocator: std.mem.Allocator, input_paths: []const []const u8, output_paths: []const []const u8) !?OutputCollision {
    const input_identities = try allocator.alloc(PathIdentity, input_paths.len);
    defer allocator.free(input_identities);
    var initialized_inputs: usize = 0;
    defer for (input_identities[0..initialized_inputs]) |*identity| identity.deinit(allocator);

    var input_paths_by_name: PathIdentityStringSet = .empty;
    defer input_paths_by_name.deinit(allocator);
    try input_paths_by_name.ensureTotalCapacity(allocator, @intCast(input_paths.len));
    var input_paths_by_object: PathIdentityObjectSet = .empty;
    defer input_paths_by_object.deinit(allocator);
    try input_paths_by_object.ensureTotalCapacity(allocator, @intCast(input_paths.len));

    for (input_paths, 0..) |input_path, i| {
        input_identities[i] = try identifyPath(allocator, input_path);
        initialized_inputs += 1;
        input_paths_by_name.putAssumeCapacity(input_identities[i].normalized, {});
        if (input_identities[i].object) |object| input_paths_by_object.putAssumeCapacity(object, {});
    }

    var output_identities = try std.ArrayList(PathIdentity).initCapacity(allocator, output_paths.len);
    defer {
        for (output_identities.items) |*identity| identity.deinit(allocator);
        output_identities.deinit(allocator);
    }
    var output_paths_by_name: PathIdentityStringSet = .empty;
    defer output_paths_by_name.deinit(allocator);
    try output_paths_by_name.ensureTotalCapacity(allocator, @intCast(output_paths.len));
    var output_paths_by_object: PathIdentityObjectSet = .empty;
    defer output_paths_by_object.deinit(allocator);
    try output_paths_by_object.ensureTotalCapacity(allocator, @intCast(output_paths.len));

    for (output_paths) |output_path| {
        var output_identity = try identifyPath(allocator, output_path);
        errdefer output_identity.deinit(allocator);

        const matches_input_name = input_paths_by_name.contains(output_identity.normalized);
        const matches_input_object = if (output_identity.object) |object|
            input_paths_by_object.contains(object)
        else
            false;
        if (matches_input_name or matches_input_object) {
            output_identity.deinit(allocator);
            return .{ .kind = .output_is_input, .path = output_path };
        }

        const matches_output_name = output_paths_by_name.contains(output_identity.normalized);
        const matches_output_object = if (output_identity.object) |object|
            output_paths_by_object.contains(object)
        else
            false;
        if (matches_output_name or matches_output_object) {
            output_identity.deinit(allocator);
            return .{ .kind = .duplicate_output, .path = output_path };
        }

        output_paths_by_name.putAssumeCapacity(output_identity.normalized, {});
        if (output_identity.object) |object| output_paths_by_object.putAssumeCapacity(object, {});
        // All fallible storage was reserved before the loop. Commit the owned
        // identity only after both borrowed-key indexes have accepted it, with
        // no possible allocation failure that could leave a dangling key.
        output_identities.appendAssumeCapacity(output_identity);
    }

    return null;
}

const NativeCollisionInputSet = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList([]const u8),
    owned_dependencies: std.ArrayList([]u8),
    dependency_index: std.StringHashMapUnmanaged(void),

    fn deinit(self: *NativeCollisionInputSet) void {
        // The index borrows dependency strings, so release its storage before
        // freeing the strings that back its keys.
        self.dependency_index.deinit(self.allocator);
        for (self.owned_dependencies.items) |path| self.allocator.free(path);
        self.owned_dependencies.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Builds one owned, deduplicated dependency union after native compilation.
/// Entry paths remain borrowed; canonical dependency file URLs are decoded
/// into paths owned by the returned set.
fn collectNativeCollisionInputs(
    allocator: std.mem.Allocator,
    entry_paths: []const []const u8,
    dependency_groups: []const []const native_api.Dependency,
) !NativeCollisionInputSet {
    var dependency_count: usize = 0;
    for (dependency_groups) |dependencies| {
        dependency_count = try std.math.add(usize, dependency_count, dependencies.len);
    }
    const maximum_paths = try std.math.add(usize, entry_paths.len, dependency_count);

    var paths = try std.ArrayList([]const u8).initCapacity(allocator, maximum_paths);
    errdefer paths.deinit(allocator);
    paths.appendSliceAssumeCapacity(entry_paths);

    var owned_dependencies = try std.ArrayList([]u8).initCapacity(allocator, dependency_count);
    errdefer {
        for (owned_dependencies.items) |path| allocator.free(path);
        owned_dependencies.deinit(allocator);
    }
    var dependency_index: std.StringHashMapUnmanaged(void) = .empty;
    errdefer dependency_index.deinit(allocator);
    try dependency_index.ensureTotalCapacity(allocator, @intCast(dependency_count));

    for (dependency_groups) |dependencies| {
        for (dependencies) |dependency| {
            const path = try nativeDependencyPathAlloc(allocator, dependency);
            if (dependency_index.contains(path)) {
                allocator.free(path);
                continue;
            }
            paths.appendAssumeCapacity(path);
            owned_dependencies.appendAssumeCapacity(path);
            dependency_index.putAssumeCapacityNoClobber(path, {});
        }
    }

    return .{
        .allocator = allocator,
        .paths = paths,
        .owned_dependencies = owned_dependencies,
        .dependency_index = dependency_index,
    };
}

fn findNativeOutputCollision(
    allocator: std.mem.Allocator,
    entry_paths: []const []const u8,
    dependency_groups: []const []const native_api.Dependency,
    destination_paths: []const []const u8,
) !?OutputCollision {
    var inputs = try collectNativeCollisionInputs(
        allocator,
        entry_paths,
        dependency_groups,
    );
    defer inputs.deinit();
    return findOutputCollision(allocator, inputs.paths.items, destination_paths);
}

fn findNativePreparedOutputCollision(
    allocator: std.mem.Allocator,
    entry_paths: []const []const u8,
    dependency_groups: []const []const native_api.Dependency,
    destinations: []const PreparedOutputDestination,
) !?OutputCollision {
    var inputs = try collectNativeCollisionInputs(
        allocator,
        entry_paths,
        dependency_groups,
    );
    defer inputs.deinit();
    return findPreparedOutputCollision(allocator, inputs.paths.items, destinations);
}

fn printNativeOutputCollision(collision: OutputCollision) void {
    switch (collision.kind) {
        .output_is_input => std.debug.print(
            "Error: native output or depfile path resolves to an entry or dependency: {s}\n",
            .{collision.path},
        ),
        .duplicate_output => std.debug.print(
            "Error: native output and depfile paths resolve to the same destination: {s}\n",
            .{collision.path},
        ),
    }
}

fn printOutputCollision(collision: OutputCollision) void {
    switch (collision.kind) {
        .output_is_input => std.debug.print("Error: output path resolves to an input: {s}\n", .{collision.path}),
        .duplicate_output => std.debug.print("Error: multiple inputs resolve to the same output: {s}\n", .{collision.path}),
    }
}

fn rejectOutputCollision(collision: OutputCollision) noreturn {
    printOutputCollision(collision);
    std.process.exit(exit_usage);
}

fn exitWithCliError(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print("Error: " ++ format ++ "\n", values);
    std.process.exit(exit_usage);
}

fn appendCliInputPattern(
    allocator: std.mem.Allocator,
    patterns: *std.ArrayList([]const u8),
    pattern: []const u8,
) std.mem.Allocator.Error!void {
    appendInputPattern(allocator, patterns, pattern) catch |err| switch (err) {
        error.TooManyInputPatterns => exitWithCliError(
            "too many input patterns (maximum {d})",
            .{max_input_patterns},
        ),
        error.InputPathTooLong => exitWithCliError(
            "input path exceeds {d} bytes",
            .{max_cli_input_path_bytes},
        ),
        error.InputNameTooLong => exitWithCliError(
            "input name exceeds {d} bytes",
            .{max_glob_component_bytes},
        ),
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn expandCliGlob(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    max_results: usize,
) !std.ArrayList([]const u8) {
    return expandGlob(allocator, pattern, max_results) catch |err| switch (err) {
        error.TooManyExpandedInputs => exitWithCliError(
            "expanded input count exceeds {d}",
            .{max_expanded_inputs},
        ),
        error.InputPathTooLong => exitWithCliError(
            "input path exceeds {d} bytes",
            .{max_cli_input_path_bytes},
        ),
        error.InputNameTooLong => exitWithCliError(
            "input name exceeds {d} bytes",
            .{max_glob_component_bytes},
        ),
        error.GlobEntryNameTooLong => exitWithCliError(
            "glob entry name exceeds {d} bytes",
            .{max_glob_component_bytes},
        ),
        error.ExpandedInputPathTooLong => exitWithCliError(
            "expanded glob path exceeds {d} bytes",
            .{max_cli_input_path_bytes},
        ),
        else => return err,
    };
}

fn requireOptionValue(args: []const []const u8, index: usize, option: []const u8) []const u8 {
    if (index + 1 >= args.len) exitWithCliError("{s} requires a value", .{option});
    const value = args[index + 1];
    if (value.len == 0 or (value[0] == '-' and !isStdioPath(value))) {
        exitWithCliError("{s} requires a value", .{option});
    }
    return value;
}

fn printUsage() !void {
    try writeStdout(
        std.fmt.comptimePrint("ZigCSS {s} native stylesheet compiler — RELEASE CANDIDATE\n\n", .{version}) ++
            "Usage: zigcss <input.css|-> [-o <output.css|->] [options]\n" ++
            "       zigcss <input1.css> <input2.css> ... -o <output-dir> --output-dir [options]\n" ++
            "       zigcss --lsp          Start experimental Language Server Protocol server\n" ++
            "\nAvailable options:\n" ++
            "  -o, --output <path|->    Output file/stdout, or directory with --output-dir\n" ++
            "  --output-dir             Require batch output under the -o directory\n" ++
            "  --depfile <path>         Write one bounded Make/Ninja dependency file\n" ++
            "  --syntax <syntax>        Select css (default), scss, sass, less, or stylus\n" ++
            "  --minify                 Emit compact whitespace (independent of --optimize)\n" ++
            "  --source-map             Embed a deterministic inline source map\n" ++
            "  --optimize               Run the closed verified optimizer preset\n" ++
            "  --autoprefix             Run verified eight-feature target prefixing\n" ++
            "  --browsers <query>       Set explicit browser minima (requires --autoprefix)\n" ++
            "  --watch                  Watch one input and its confined local imports\n" ++
            "  --profile                Report API stages and requested memory bytes\n" ++
            "  --lsp                    Start the experimental LSP server\n" ++
            "  -V, --version            Show the package version\n" ++
            "  -h, --help               Show this help\n" ++
            "\nExit status: 0 success/info, 1 compilation or I/O failure, 2 usage error.\n" ++
            "\nUnavailable by the stable contract:\n" ++
            "  --critical-*\n",
    );
}

fn printVersion() !void {
    var buffer: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "zigcss {s}\n", .{version});
    try writeStdout(rendered);
}

fn batchOutputStem(input_file: []const u8) []const u8 {
    const basename = std.fs.path.basename(input_file);
    const extension = std.fs.path.extension(basename);
    if (extension.len == 0 or extension.len == basename.len) return basename;
    return basename[0 .. basename.len - extension.len];
}

fn usesCaseInsensitivePathPolicy(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .windows, .macos, .ios, .tvos, .watchos => true,
        else => false,
    };
}

fn containsNonAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!std.ascii.isAscii(byte)) return true;
    }
    return false;
}

fn requiresPortableHashedStemForOs(
    os_tag: std.Target.Os.Tag,
    stem: []const u8,
) bool {
    // The filesystem's Unicode case/normalization table is not available as a
    // portable hashing primitive. Emit an ASCII-only hashed basename instead:
    // exact hash collisions are then visible to the ordinary collision index.
    return usesCaseInsensitivePathPolicy(os_tag) and containsNonAscii(stem);
}

fn requiresPortableHashedStem(stem: []const u8) bool {
    return requiresPortableHashedStemForOs(builtin.os.tag, stem);
}

const BatchStemCountMap = std.HashMapUnmanaged(
    []const u8,
    usize,
    WatchPathContext,
    80,
);

const BatchNamePlan = struct {
    counts: BatchStemCountMap = .empty,
    cwd_path: ?[]u8 = null,
    indexed_inputs: usize = 0,
    cwd_resolutions: usize = 0,

    fn init(allocator: std.mem.Allocator, input_files: []const []const u8) !BatchNamePlan {
        var plan = BatchNamePlan{};
        errdefer plan.deinit(allocator);
        try plan.counts.ensureTotalCapacity(allocator, @intCast(input_files.len));
        var requires_hash = false;
        for (input_files) |input_file| {
            const stem = batchOutputStem(input_file);
            const entry = plan.counts.getOrPutAssumeCapacity(stem);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
                requires_hash = true;
            } else {
                entry.value_ptr.* = 1;
            }
            const output_stem = if (stem.len == 0) "output" else stem;
            const plain_name_len = std.math.add(usize, output_stem.len, ".css".len) catch
                std.math.maxInt(usize);
            if (plain_name_len > max_batch_output_basename_bytes or
                requiresPortableHashedStem(output_stem))
            {
                requires_hash = true;
            }
            plan.indexed_inputs += 1;
        }
        if (requires_hash) {
            plan.cwd_path = try std.fs.path.resolve(allocator, &.{"."});
            plan.cwd_resolutions = 1;
        }
        return plan;
    }

    fn deinit(self: *BatchNamePlan, allocator: std.mem.Allocator) void {
        self.counts.deinit(allocator);
        if (self.cwd_path) |cwd_path| allocator.free(cwd_path);
        self.* = .{};
    }

    fn needsDisambiguation(self: *const BatchNamePlan, input_file: []const u8) bool {
        return (self.counts.get(batchOutputStem(input_file)) orelse 0) > 1;
    }
};

fn normalizedInputHash(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    input_file: []const u8,
) !u64 {
    const absolute_path = try std.fs.path.resolve(allocator, &.{input_file});
    defer allocator.free(absolute_path);
    const relative_path = try std.fs.path.relative(allocator, cwd_path, absolute_path);
    defer allocator.free(relative_path);
    const key = relative_path;

    var hasher = std.hash.XxHash64.init(0);
    switch (builtin.os.tag) {
        .windows, .macos, .ios, .tvos, .watchos => {
            for (key) |byte| {
                const normalized = [_]u8{std.ascii.toLower(byte)};
                hasher.update(&normalized);
            }
        },
        else => hasher.update(key),
    }
    return hasher.final();
}

fn determineBatchOutputFile(
    allocator: std.mem.Allocator,
    name_plan: *const BatchNamePlan,
    input_files: []const []const u8,
    index: usize,
    output_dir: []const u8,
) ![]u8 {
    const raw_stem = batchOutputStem(input_files[index]);
    const stem = if (raw_stem.len == 0) "output" else raw_stem;
    const needs_disambiguation = name_plan.needsDisambiguation(input_files[index]);
    const needs_portable_name = requiresPortableHashedStem(stem);
    const plain_name_len = std.math.add(usize, stem.len, ".css".len) catch std.math.maxInt(usize);
    const output_basename = if (!needs_disambiguation and !needs_portable_name and
        plain_name_len <= max_batch_output_basename_bytes)
        try std.fmt.allocPrint(allocator, "{s}.css", .{stem})
    else blk: {
        const path_hash = try normalizedInputHash(
            allocator,
            name_plan.cwd_path orelse unreachable,
            input_files[index],
        );
        const suffixed_name_len = std.math.add(usize, stem.len, "-0000000000000000.css".len) catch std.math.maxInt(usize);
        if (!needs_portable_name and suffixed_name_len <= max_batch_output_basename_bytes) {
            break :blk try std.fmt.allocPrint(allocator, "{s}-{x:0>16}.css", .{ stem, path_hash });
        }
        break :blk try std.fmt.allocPrint(allocator, "zigcss-{x:0>16}.css", .{path_hash});
    };
    defer allocator.free(output_basename);
    return std.fs.path.join(allocator, &.{ output_dir, output_basename });
}

fn compileBatch(
    allocator: std.mem.Allocator,
    input_files: []const []const u8,
    output_dir: []const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
) !void {
    var name_plan = try BatchNamePlan.init(allocator, input_files);
    defer name_plan.deinit(allocator);
    var tasks = try std.ArrayList(CompileTask).initCapacity(allocator, input_files.len);
    defer {
        for (tasks.items) |*task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    for (input_files, 0..) |input, input_index| {
        const out_file = try determineBatchOutputFile(
            allocator,
            &name_plan,
            input_files,
            input_index,
            output_dir,
        );
        tasks.append(allocator, CompileTask{
            .input_file = input,
            .output_file = out_file,
            .syntax = syntax,
            .optimize = optimize,
            .minify = minify,
            .source_map = source_map,
            .prefix = prefix,
        }) catch |err| {
            allocator.free(out_file);
            return err;
        };
    }

    const planned_outputs = try allocator.alloc([]const u8, tasks.items.len);
    defer allocator.free(planned_outputs);
    for (tasks.items, 0..) |task, task_index| {
        planned_outputs[task_index] = task.output_file;
    }
    if (try findOutputCollision(allocator, input_files, planned_outputs)) |collision| {
        printOutputCollision(collision);
        return error.BatchUsageError;
    }

    try compileFilesParallel(allocator, tasks.items);
}

fn compileNativeBatch(
    allocator: std.mem.Allocator,
    input_files: []const []const u8,
    output_dir: []const u8,
    syntax: native_api.Syntax,
    optimize: bool,
    minify: bool,
    source_map: bool,
    prefix: TargetPrefixConfig,
) !void {
    var name_plan = try BatchNamePlan.init(allocator, input_files);
    defer name_plan.deinit(allocator);
    var tasks = try std.ArrayList(NativeBatchTask).initCapacity(allocator, input_files.len);
    defer {
        for (tasks.items) |*task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    for (input_files, 0..) |input_file, input_index| {
        const output_file = try determineBatchOutputFile(
            allocator,
            &name_plan,
            input_files,
            input_index,
            output_dir,
        );
        tasks.append(allocator, .{
            .input_file = input_file,
            .output_file = output_file,
            .syntax = syntax,
            .optimize = optimize,
            .minify = minify,
            .source_map = source_map,
            .prefix = prefix,
        }) catch |err| {
            allocator.free(output_file);
            return err;
        };
    }

    const planned_outputs = try allocator.alloc([]const u8, tasks.items.len);
    defer allocator.free(planned_outputs);
    for (tasks.items, 0..) |task, task_index| {
        planned_outputs[task_index] = task.output_file;
    }
    if (try findOutputCollision(allocator, input_files, planned_outputs)) |collision| {
        printOutputCollision(collision);
        return error.BatchUsageError;
    }

    try compileNativeFilesParallel(allocator, tasks.items);
}

fn experimentalFormatName(filename: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, filename, ".module.css")) return "CSS Modules";
    if (std.mem.endsWith(u8, filename, ".css.js") or
        std.mem.endsWith(u8, filename, ".css.ts")) return "CSS-in-JS";
    if (std.mem.endsWith(u8, filename, ".postcss")) return "PostCSS";
    return null;
}

fn nativeSyntaxForFilename(filename: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, filename, ".scss")) return "scss";
    if (std.mem.endsWith(u8, filename, ".sass")) return "sass";
    if (std.mem.endsWith(u8, filename, ".less")) return "less";
    if (std.mem.endsWith(u8, filename, ".styl")) return "stylus";
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) exitWithCliError("no input files specified; use --help for usage", .{});

    if (std.mem.eql(u8, args[1], "--internal-core-v1")) {
        if (args.len != 2) std.process.exit(exit_usage);
        core_protocol.runStdio(allocator) catch std.process.exit(exit_compile_failure);
        return;
    }

    if (std.mem.eql(u8, args[1], "--internal-node-v1")) {
        if (args.len != 2) std.process.exit(exit_usage);
        node_protocol.runStdio(allocator) catch std.process.exit(exit_compile_failure);
        return;
    }

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        if (args.len != 2) exitWithCliError("--help does not accept additional arguments", .{});
        try printUsage();
        return;
    }
    if (std.mem.eql(u8, args[1], "-V") or std.mem.eql(u8, args[1], "--version")) {
        if (args.len != 2) exitWithCliError("--version does not accept additional arguments", .{});
        try printVersion();
        return;
    }
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--lsp") or std.mem.eql(u8, args[1], "-lsp"))) {
        if (args.len != 2) exitWithCliError("--lsp does not accept additional arguments", .{});
        std.debug.print("{s}{s}", .{ prerelease_notice, lsp_experimental_notice });
        const status = try runLspServer(allocator);
        if (status == .failure) std.process.exit(exit_compile_failure);
        return;
    }

    var input_files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (input_files.items) |path| {
            allocator.free(path);
        }
        input_files.deinit(allocator);
    }
    var input_patterns = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer input_patterns.deinit(allocator);

    var output_file: ?[]const u8 = null;
    var depfile_path: ?[]const u8 = null;
    var output_dir_flag = false;
    var syntax: zigcss.Syntax = .css;
    var native_syntax: ?native_api.Syntax = null;
    var syntax_flag_set = false;
    var experimental_native_flag = false;
    var optimize_flag = false;
    var minify_flag = false;
    var source_map_flag = false;
    var autoprefix_flag = false;
    var browsers_value: ?[]const u8 = null;
    var watch_flag = false;
    var profile_flag = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (output_file != null) exitWithCliError("{s} may only be specified once", .{args[i]});
            output_file = requireOptionValue(args, i, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--depfile")) {
            if (depfile_path != null) exitWithCliError("--depfile may only be specified once", .{});
            depfile_path = requireOptionValue(args, i, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir")) {
            if (output_dir_flag) exitWithCliError("--output-dir may only be specified once", .{});
            output_dir_flag = true;
        } else if (std.mem.eql(u8, args[i], "--syntax")) {
            if (syntax_flag_set) exitWithCliError("--syntax may only be specified once", .{});
            const value = requireOptionValue(args, i, args[i]);
            if (std.mem.eql(u8, value, "css")) {
                syntax = .css;
            } else if (parseNativeSyntax(value)) |parsed| {
                native_syntax = parsed;
            } else {
                exitWithCliError("unsupported syntax: {s}", .{value});
            }
            syntax_flag_set = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--experimental-native")) {
            if (experimental_native_flag) {
                exitWithCliError("--experimental-native may only be specified once", .{});
            }
            experimental_native_flag = true;
        } else if (std.mem.eql(u8, args[i], "--optimize")) {
            if (optimize_flag) exitWithCliError("--optimize may only be specified once", .{});
            optimize_flag = true;
        } else if (std.mem.eql(u8, args[i], "--minify")) {
            if (minify_flag) exitWithCliError("--minify may only be specified once", .{});
            minify_flag = true;
        } else if (std.mem.eql(u8, args[i], "--source-map")) {
            if (source_map_flag) exitWithCliError("--source-map may only be specified once", .{});
            source_map_flag = true;
        } else if (std.mem.eql(u8, args[i], "--watch")) {
            if (watch_flag) exitWithCliError("--watch may only be specified once", .{});
            watch_flag = true;
        } else if (std.mem.eql(u8, args[i], "--autoprefix")) {
            if (autoprefix_flag) exitWithCliError("--autoprefix may only be specified once", .{});
            autoprefix_flag = true;
        } else if (std.mem.eql(u8, args[i], "--profile")) {
            if (profile_flag) exitWithCliError("--profile may only be specified once", .{});
            profile_flag = true;
        } else if (std.mem.eql(u8, args[i], "--browsers")) {
            if (browsers_value != null) exitWithCliError("--browsers may only be specified once", .{});
            browsers_value = requireOptionValue(args, i, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--critical-classes") or
            std.mem.eql(u8, args[i], "--critical-ids") or
            std.mem.eql(u8, args[i], "--critical-elements"))
        {
            _ = requireOptionValue(args, i, args[i]);
            exitWithCliError("{s} is unavailable in the recovery CLI; conservative extraction remains library/test-driver only", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            exitWithCliError("--help must be used alone", .{});
        } else if (std.mem.eql(u8, args[i], "-V") or std.mem.eql(u8, args[i], "--version")) {
            exitWithCliError("--version must be used alone", .{});
        } else if (isStdioPath(args[i])) {
            try appendCliInputPattern(allocator, &input_patterns, args[i]);
        } else if (args[i].len == 0) {
            exitWithCliError("empty arguments are not valid input paths", .{});
        } else if (args[i][0] != '-') {
            try appendCliInputPattern(allocator, &input_patterns, args[i]);
        } else {
            exitWithCliError("unknown option: {s}", .{args[i]});
        }
    }

    if (input_patterns.items.len == 0) exitWithCliError("no input files specified", .{});

    if (autoprefix_flag and browsers_value == null) {
        exitWithCliError("--autoprefix requires --browsers <query>", .{});
    }
    if (!autoprefix_flag and browsers_value != null) {
        exitWithCliError("--browsers requires --autoprefix", .{});
    }
    if (depfile_path) |path| {
        validateDepfilePath(path) catch exitWithCliError(
            "--depfile path must contain 1 through {d} bytes without control characters",
            .{max_depfile_path_bytes},
        );
        if (isStdioPath(path)) exitWithCliError("--depfile requires a file destination", .{});
        const out = output_file orelse exitWithCliError(
            "--depfile requires an explicit -o or --output file",
            .{},
        );
        if (isStdioPath(out)) exitWithCliError("--depfile requires a file output", .{});
        validateDepfilePath(out) catch exitWithCliError(
            "--depfile output path must contain 1 through {d} bytes without control characters",
            .{max_depfile_path_bytes},
        );
        if (output_dir_flag) exitWithCliError("--depfile cannot be combined with --output-dir", .{});
        if (watch_flag) exitWithCliError("--depfile cannot be combined with --watch", .{});
        if (input_patterns.items.len != 1) {
            exitWithCliError("--depfile supports exactly one file input", .{});
        }
    }
    var parsed_targets: ?zigcss.TargetQuery = null;
    defer if (parsed_targets) |*query| query.deinit();
    if (browsers_value) |value| {
        const parsed = try zigcss.prefixing.target_query.parse(allocator, value, .{});
        switch (parsed) {
            .query => |query| parsed_targets = query,
            .invalid => |failure| exitWithCliError(
                "invalid --browsers query at byte {d}: {s}",
                .{ failure.offset, @tagName(failure.kind) },
            ),
        }
    }
    const prefix_config = TargetPrefixConfig{
        .enabled = autoprefix_flag,
        .targets = if (parsed_targets) |*query| query else null,
    };

    if (source_map_flag and optimize_flag) {
        exitWithCliError("--source-map cannot be combined with --optimize", .{});
    }
    if (native_syntax != null) {
        if (profile_flag) exitWithCliError("--profile is unavailable for native stylesheet syntax", .{});
    } else if (experimental_native_flag) {
        exitWithCliError("--experimental-native requires --syntax <scss|sass|less|stylus>", .{});
    }
    if (output_dir_flag and output_file == null) {
        exitWithCliError("--output-dir requires -o or --output", .{});
    }
    if (output_dir_flag and isStdioPath(output_file.?)) {
        exitWithCliError("--output-dir cannot write to stdout", .{});
    }

    var raw_stdin_inputs: usize = 0;
    for (input_patterns.items) |pattern| {
        if (isStdioPath(pattern)) raw_stdin_inputs += 1;
    }
    if (raw_stdin_inputs > 1) exitWithCliError("stdin may only be specified once", .{});
    if (raw_stdin_inputs == 1 and input_patterns.items.len != 1) {
        exitWithCliError("stdin cannot be combined with file or batch inputs", .{});
    }
    if (raw_stdin_inputs == 1 and watch_flag) exitWithCliError("--watch requires a file input", .{});
    if (raw_stdin_inputs == 1 and depfile_path != null) {
        exitWithCliError("--depfile requires a file input", .{});
    }
    if (watch_flag and input_patterns.items.len > 1) {
        exitWithCliError("--watch supports exactly one file", .{});
    }
    if (profile_flag and input_patterns.items.len > 1) {
        exitWithCliError("--profile supports exactly one input", .{});
    }

    // Input expansion can touch the filesystem. Keep it after every validation
    // that depends only on arguments so usage errors are deterministic and
    // cannot be shadowed by an inaccessible glob directory.
    for (input_patterns.items) |pattern| {
        var expanded = try expandCliGlob(
            allocator,
            pattern,
            max_expanded_inputs - input_files.items.len,
        );
        defer {
            for (expanded.items) |path| allocator.free(path);
            expanded.deinit(allocator);
        }
        try input_files.ensureUnusedCapacity(allocator, expanded.items.len);
        for (expanded.items) |path| input_files.appendAssumeCapacity(path);
        // Ownership of each matched path moves to `input_files`; the temporary
        // list still releases only its pointer storage.
        expanded.clearRetainingCapacity();
    }
    if (input_files.items.len == 0) exitWithCliError("no input files specified", .{});

    var stdin_inputs: usize = 0;
    for (input_files.items) |input_file| {
        if (isStdioPath(input_file)) stdin_inputs += 1;
    }
    if (stdin_inputs > 1) exitWithCliError("stdin may only be specified once", .{});

    if (stdin_inputs == 1 and input_files.items.len != 1) {
        exitWithCliError("stdin cannot be combined with file or batch inputs", .{});
    }
    if (stdin_inputs == 1 and watch_flag) exitWithCliError("--watch requires a file input", .{});
    if (watch_flag and input_files.items.len != 1) {
        exitWithCliError("--watch supports exactly one file", .{});
    }
    if (depfile_path != null and input_files.items.len != 1) {
        exitWithCliError("--depfile supports exactly one file input", .{});
    }
    if (profile_flag and input_files.items.len > 1) {
        exitWithCliError("--profile supports exactly one input", .{});
    }

    if (output_dir_flag and input_files.items.len < 2) {
        exitWithCliError("--output-dir requires multiple inputs", .{});
    }
    if (input_files.items.len > 1 and !output_dir_flag) {
        exitWithCliError("multiple inputs require --output-dir", .{});
    }

    for (input_files.items) |input_file| {
        if (isStdioPath(input_file)) continue;
        if (native_syntax != null) continue;
        if (nativeSyntaxForFilename(input_file)) |required_syntax| {
            exitWithCliError(
                "{s} input requires --syntax {s}",
                .{ input_file, required_syntax },
            );
        }
        if (experimentalFormatName(input_file)) |format_name| {
            exitWithCliError(
                "{s} format adapter is experimental and unavailable in the recovery CLI",
                .{format_name},
            );
        }
    }

    if (input_files.items.len == 1) {
        if (output_file) |out| {
            if (!isStdioPath(input_files.items[0]) and !isStdioPath(out)) {
                if (depfile_path) |path| {
                    const planned_outputs = [_][]const u8{ out, path };
                    if (try findOutputCollision(allocator, input_files.items, &planned_outputs)) |collision| {
                        printDepfileCollision(collision);
                        std.process.exit(exit_usage);
                    }
                } else {
                    const planned_outputs = [_][]const u8{out};
                    if (try findOutputCollision(allocator, input_files.items, &planned_outputs)) |collision| {
                        rejectOutputCollision(collision);
                    }
                }
            }
        }
    }

    std.debug.print("{s}", .{prerelease_notice});

    if (native_syntax) |selected| {
        if (watch_flag) {
            watchNativeFile(
                allocator,
                input_files.items[0],
                output_file,
                selected,
                optimize_flag,
                minify_flag,
                source_map_flag,
                prefix_config,
            ) catch |err| {
                std.process.exit(if (err == error.NativeOutputCollision) exit_usage else exit_compile_failure);
            };
        } else if (input_files.items.len == 1) {
            compileNativeInput(
                allocator,
                input_files.items[0],
                output_file,
                selected,
                optimize_flag,
                minify_flag,
                source_map_flag,
                prefix_config,
                depfile_path,
            ) catch |err| {
                std.process.exit(if (err == error.DepfileUsageError or
                    err == error.NativeOutputCollision)
                    exit_usage
                else
                    exit_compile_failure);
            };
        } else {
            compileNativeBatch(
                allocator,
                input_files.items,
                output_file.?,
                selected,
                optimize_flag,
                minify_flag,
                source_map_flag,
                prefix_config,
            ) catch |err| {
                if (err != error.CompileError and err != error.BatchUsageError and
                    err != error.NativeOutputCollision)
                {
                    std.debug.print("Error: native batch compilation failed: {s}\n", .{@errorName(err)});
                }
                std.process.exit(if (err == error.BatchUsageError or
                    err == error.NativeOutputCollision)
                    exit_usage
                else
                    exit_compile_failure);
            };
        }
        return;
    }

    if (watch_flag) {
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .syntax = syntax,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .source_map = source_map_flag,
            .profile = profile_flag,
            .prefix = prefix_config,
            .depfile = depfile_path,
        };
        try watchFile(allocator, config);
    } else if (input_files.items.len == 1) {
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .syntax = syntax,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .source_map = source_map_flag,
            .profile = profile_flag,
            .prefix = prefix_config,
            .depfile = depfile_path,
        };
        compileFile(allocator, config) catch |err| {
            std.process.exit(if (err == error.DepfileUsageError) exit_usage else exit_compile_failure);
        };
    } else {
        const output_dir = output_file.?;
        compileBatch(
            allocator,
            input_files.items,
            output_dir,
            syntax,
            optimize_flag,
            minify_flag,
            source_map_flag,
            prefix_config,
        ) catch |err| {
            if (err != error.CompileError and err != error.BatchUsageError) {
                std.debug.print("Error: batch compilation failed: {s}\n", .{@errorName(err)});
            }
            std.process.exit(if (err == error.BatchUsageError) exit_usage else exit_compile_failure);
        };
    }
}

test "depfile renderer escapes the shared Make and Ninja path subset exactly" {
    const prerequisites = [_][]const u8{
        "/tmp/in file#x$:y\\z.css",
        "/tmp/theme.css",
    };
    const rendered = try renderDepfile(
        std.testing.allocator,
        "out dir/a#b$:c\\z.css",
        &prerequisites,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "out\\ dir/a\\#b$$\\:c\\\\z.css: /tmp/in\\ file\\#x$$\\:y\\\\z.css /tmp/theme.css\n",
        rendered,
    );
}

test "depfile renderer rejects controls empty inputs and byte overflow" {
    for ([_][]const u8{
        "bad\x00path.css",
        "bad\rpath.css",
        "bad\npath.css",
        "bad\tpath.css",
    }) |path| {
        try std.testing.expectError(error.InvalidDepfilePath, validateDepfilePath(path));
    }
    try std.testing.expectError(
        error.TooManyDepfilePrerequisites,
        renderDepfile(std.testing.allocator, "out.css", &.{}),
    );
    const terminal = try renderDepfileWithLimit(
        std.testing.allocator,
        "o",
        &.{"i"},
        "o: i\n".len,
    );
    defer std.testing.allocator.free(terminal);
    try std.testing.expectEqualStrings("o: i\n", terminal);
    try std.testing.expectError(
        error.DepfileTooLarge,
        renderDepfileWithLimit(
            std.testing.allocator,
            "o",
            &.{"i"},
            "o: i\n".len - 1,
        ),
    );

    const maximum_path = try std.testing.allocator.alloc(u8, max_depfile_path_bytes);
    defer std.testing.allocator.free(maximum_path);
    @memset(maximum_path, 'a');
    try validateDepfilePath(maximum_path);
    const oversized_path = try std.testing.allocator.alloc(u8, max_depfile_path_bytes + 1);
    defer std.testing.allocator.free(oversized_path);
    @memset(oversized_path, 'a');
    try std.testing.expectError(error.InvalidDepfilePath, validateDepfilePath(oversized_path));

    const maximum_prerequisites = try std.testing.allocator.alloc(
        []const u8,
        max_depfile_prerequisites,
    );
    defer std.testing.allocator.free(maximum_prerequisites);
    @memset(maximum_prerequisites, "i");
    const maximum_rendered = try renderDepfile(
        std.testing.allocator,
        "o",
        maximum_prerequisites,
    );
    defer std.testing.allocator.free(maximum_rendered);
    const excessive_prerequisites = try std.testing.allocator.alloc(
        []const u8,
        max_depfile_prerequisites + 1,
    );
    defer std.testing.allocator.free(excessive_prerequisites);
    @memset(excessive_prerequisites, "i");
    try std.testing.expectError(
        error.TooManyDepfilePrerequisites,
        renderDepfile(std.testing.allocator, "o", excessive_prerequisites),
    );
}

fn exerciseDepfilePreparationAllocationFailures(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    output_path: []const u8,
    depfile_path: []const u8,
) !void {
    const rendered = try prepareDepfile(
        allocator,
        output_path,
        depfile_path,
        entry_path,
        &.{},
    );
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\n"));
}

test "depfile preparation unwinds every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.css", .data = ".a{}" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry = try std.fs.path.join(std.testing.allocator, &.{ root, "input.css" });
    defer std.testing.allocator.free(entry);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "output.css" });
    defer std.testing.allocator.free(output);
    const depfile = try std.fs.path.join(std.testing.allocator, &.{ root, "output.css.d" });
    defer std.testing.allocator.free(depfile);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDepfilePreparationAllocationFailures,
        .{ entry, output, depfile },
    );
}

fn exerciseNativeDepfilePreparationAllocationFailures(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    output_path: []const u8,
    depfile_path: []const u8,
    dependencies: []const native_api.Dependency,
) !void {
    const rendered = try prepareDepfile(
        allocator,
        output_path,
        depfile_path,
        entry_path,
        dependencies,
    );
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\n"));
}

test "native depfile URL decoding unwinds every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = "@use \"tokens\";.a{color:tokens.$color}";
    try tmp.dir.writeFile(.{ .sub_path = "input.scss", .data = input });
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = "$color:red;" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry = try std.fs.path.join(std.testing.allocator, &.{ root, "input.scss" });
    defer std.testing.allocator.free(entry);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "output.css" });
    defer std.testing.allocator.free(output);
    const depfile = try std.fs.path.join(std.testing.allocator, &.{ root, "output.css.d" });
    defer std.testing.allocator.free(depfile);
    const roots = [_][]const u8{root};
    var result = try native_api.compile(std.testing.allocator, entry, input, .{
        .syntax = .scss,
        .root_paths = &roots,
        .format = .minified,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNativeDepfilePreparationAllocationFailures,
        .{ entry, output, depfile, result.dependencies },
    );
}

fn exerciseInlineSourceMapRendering(allocator: std.mem.Allocator) !void {
    const rendered = try renderCssWithInlineSourceMap(allocator, ".a{}", "{}");
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        ".a{}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,e30= */",
        rendered,
    );

    const already_terminated = try renderCssWithInlineSourceMap(allocator, ".a{}\n", "{}");
    defer allocator.free(already_terminated);
    try std.testing.expectEqualStrings(
        ".a{}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,e30= */",
        already_terminated,
    );
}

test "inline source map rendering is deterministic and allocation-safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseInlineSourceMapRendering,
        .{},
    );
}

test "atomic output rename retry has a finite Windows terminal" {
    var lower = AtomicRenameProbe{ .access_denied_before_success = 0 };
    try finishAtomicFileWithRetry(&lower, .windows, 0);
    try std.testing.expectEqual(@as(usize, 1), lower.flushes);
    try std.testing.expectEqual(@as(usize, 1), lower.attempts);

    var terminal = AtomicRenameProbe{
        .access_denied_before_success = windows_atomic_operation_attempt_limit - 1,
    };
    try finishAtomicFileWithRetry(&terminal, .windows, 0);
    try std.testing.expectEqual(@as(usize, 1), terminal.flushes);
    try std.testing.expectEqual(windows_atomic_operation_attempt_limit, terminal.attempts);

    var over_limit = AtomicRenameProbe{
        .access_denied_before_success = windows_atomic_operation_attempt_limit,
    };
    try std.testing.expectError(
        error.AccessDenied,
        finishAtomicFileWithRetry(&over_limit, .windows, 0),
    );
    try std.testing.expectEqual(@as(usize, 1), over_limit.flushes);
    try std.testing.expectEqual(windows_atomic_operation_attempt_limit, over_limit.attempts);

    var wrong_host = AtomicRenameProbe{ .access_denied_before_success = 1 };
    try std.testing.expectError(
        error.AccessDenied,
        finishAtomicFileWithRetry(&wrong_host, .linux, 0),
    );
    try std.testing.expectEqual(@as(usize, 1), wrong_host.flushes);
    try std.testing.expectEqual(@as(usize, 1), wrong_host.attempts);

    var unrelated = AtomicRenameProbe{
        .access_denied_before_success = 0,
        .terminal_error = error.PermissionDenied,
    };
    try std.testing.expectError(
        error.PermissionDenied,
        finishAtomicFileWithRetry(&unrelated, .windows, 0),
    );
    try std.testing.expectEqual(@as(usize, 1), unrelated.flushes);
    try std.testing.expectEqual(@as(usize, 1), unrelated.attempts);
}

const AtomicRenameProbe = struct {
    access_denied_before_success: usize,
    terminal_error: ?anyerror = null,
    flushes: usize = 0,
    attempts: usize = 0,

    fn flush(self: *AtomicRenameProbe) !void {
        self.flushes += 1;
    }

    fn renameIntoPlace(self: *AtomicRenameProbe) !void {
        self.attempts += 1;
        if (self.attempts <= self.access_denied_before_success) {
            return error.AccessDenied;
        }
        if (self.terminal_error) |err| return err;
    }
};

test "prepared output retains its directory and rejects a changed entry" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try tmp.dir.makeDir("held");
    const held_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "held", "output.css" },
    );
    defer std.testing.allocator.free(held_path);
    var held = try PreparedOutputDestination.init(std.testing.allocator, held_path);
    defer held.deinit(std.testing.allocator);
    const sibling_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "held", "sibling.css" },
    );
    defer std.testing.allocator.free(sibling_path);
    var sibling = try PreparedOutputDestination.initSibling(
        std.testing.allocator,
        &held,
        sibling_path,
    );
    defer sibling.deinit(std.testing.allocator);
    try std.testing.expect(!sibling.close_dir);
    try std.testing.expectEqual(held.dir.fd, sibling.dir.fd);

    try tmp.dir.rename("held", "moved");
    try tmp.dir.makeDir("held");
    try tmp.dir.writeFile(.{ .sub_path = "held/output.css", .data = "replacement-sentinel" });
    try writePreparedOutput(&held, "held-directory-commit");

    const committed = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "moved/output.css",
        1024,
    );
    defer std.testing.allocator.free(committed);
    try std.testing.expectEqualStrings("held-directory-commit", committed);
    const replacement = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "held/output.css",
        1024,
    );
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualStrings("replacement-sentinel", replacement);

    try tmp.dir.makeDir("stable");
    const stable_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "stable", "output.css" },
    );
    defer std.testing.allocator.free(stable_path);
    var stable = try PreparedOutputDestination.init(std.testing.allocator, stable_path);
    defer stable.deinit(std.testing.allocator);
    try tmp.dir.writeFile(.{ .sub_path = "stable/output.css", .data = "concurrent-sentinel" });
    const stable_view = [_]PreparedOutputDestination{stable};
    try std.testing.expectError(
        error.OutputDestinationChanged,
        findPreparedOutputCollision(std.testing.allocator, &.{}, &stable_view),
    );
    try std.testing.expectError(
        error.OutputDestinationChanged,
        writePreparedOutput(&stable, "must-not-replace"),
    );
    const retained = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "stable/output.css",
        1024,
    );
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("concurrent-sentinel", retained);

    // A stale CSS entry must be rejected before the companion depfile can be
    // committed, even though the depfile is normally renamed first.
    try tmp.dir.makeDir("pair");
    const pair_output_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "pair", "output.css" },
    );
    defer std.testing.allocator.free(pair_output_path);
    const pair_depfile_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "pair", "output.css.d" },
    );
    defer std.testing.allocator.free(pair_depfile_path);
    var pair_output = try PreparedOutputDestination.init(
        std.testing.allocator,
        pair_output_path,
    );
    defer pair_output.deinit(std.testing.allocator);
    var pair_depfile = try PreparedOutputDestination.initSibling(
        std.testing.allocator,
        &pair_output,
        pair_depfile_path,
    );
    defer pair_depfile.deinit(std.testing.allocator);
    try tmp.dir.writeFile(.{
        .sub_path = "pair/output.css",
        .data = "concurrent-pair-sentinel",
    });
    try std.testing.expectError(
        error.OutputDestinationChanged,
        writePreparedOutputAndDepfile(
            &pair_output,
            "must-not-replace",
            &pair_depfile,
            "must-not-commit",
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access("pair/output.css.d", .{}),
    );
    const retained_pair = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "pair/output.css",
        1024,
    );
    defer std.testing.allocator.free(retained_pair);
    try std.testing.expectEqualStrings("concurrent-pair-sentinel", retained_pair);
}

test "prepared collision index pairs ASCII basename with held directory object" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("before");
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const before_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "before", "output.css" },
    );
    defer std.testing.allocator.free(before_path);
    const after_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "after", "output.css" },
    );
    defer std.testing.allocator.free(after_path);

    var destinations: [2]PreparedOutputDestination = undefined;
    var initialized: usize = 0;
    defer for (destinations[0..initialized]) |*destination| {
        destination.deinit(std.testing.allocator);
    };
    destinations[0] = try PreparedOutputDestination.init(std.testing.allocator, before_path);
    initialized += 1;
    try tmp.dir.rename("before", "after");
    destinations[1] = try PreparedOutputDestination.init(std.testing.allocator, after_path);
    initialized += 1;

    const collision = (try findPreparedOutputCollision(
        std.testing.allocator,
        &.{},
        &destinations,
    )) orelse return error.ExpectedOutputCollision;
    try std.testing.expect(collision.kind == .duplicate_output);
    try std.testing.expectEqualStrings(after_path, collision.path);
}

test "file object identity scopes equal inode numbers to their volume" {
    var identities: PathIdentityObjectSet = .empty;
    defer identities.deinit(std.testing.allocator);
    try identities.put(
        std.testing.allocator,
        .{ .volume = 1, .inode = 7 },
        {},
    );
    try std.testing.expect(identities.contains(.{
        .volume = 1,
        .inode = 7,
    }));
    try std.testing.expect(!identities.contains(.{
        .volume = 2,
        .inode = 7,
    }));
}

test "CLI format boundary rejects every experimental extension without importing adapters" {
    const cases = [_]struct { filename: []const u8, name: []const u8 }{
        .{ .filename = "input.module.css", .name = "CSS Modules" },
        .{ .filename = "input.css.js", .name = "CSS-in-JS" },
        .{ .filename = "input.css.ts", .name = "CSS-in-JS" },
        .{ .filename = "input.postcss", .name = "PostCSS" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.name, experimentalFormatName(case.filename).?);
    }
    try std.testing.expect(experimentalFormatName("input.css") == null);
    try std.testing.expect(experimentalFormatName("input.unknown") == null);
}

test "CLI preprocessor extensions fail closed with explicit stable syntax guidance" {
    const cases = [_]struct { filename: []const u8, syntax: []const u8 }{
        .{ .filename = "input.scss", .syntax = "scss" },
        .{ .filename = "input.sass", .syntax = "sass" },
        .{ .filename = "input.less", .syntax = "less" },
        .{ .filename = "input.styl", .syntax = "stylus" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.syntax, nativeSyntaxForFilename(case.filename).?);
    }
    try std.testing.expect(nativeSyntaxForFilename("input.css") == null);
    try std.testing.expect(nativeSyntaxForFilename("input.unknown") == null);
}

fn exerciseBatchNamingAllocationFailures(allocator: std.mem.Allocator) !void {
    const forward = [_][]const u8{ "one/shared.css", "two/shared.input", "unique.raw" };
    const reverse = [_][]const u8{ "unique.raw", "two/shared.input", "one/shared.css" };
    var forward_plan = try BatchNamePlan.init(allocator, &forward);
    defer forward_plan.deinit(allocator);
    var reverse_plan = try BatchNamePlan.init(allocator, &reverse);
    defer reverse_plan.deinit(allocator);
    const forward_one = try determineBatchOutputFile(allocator, &forward_plan, &forward, 0, "out");
    defer allocator.free(forward_one);
    const forward_two = try determineBatchOutputFile(allocator, &forward_plan, &forward, 1, "out");
    defer allocator.free(forward_two);
    const forward_unique = try determineBatchOutputFile(allocator, &forward_plan, &forward, 2, "out");
    defer allocator.free(forward_unique);
    const reverse_one = try determineBatchOutputFile(allocator, &reverse_plan, &reverse, 2, "out");
    defer allocator.free(reverse_one);
    const reverse_two = try determineBatchOutputFile(allocator, &reverse_plan, &reverse, 1, "out");
    defer allocator.free(reverse_two);
    const long_inputs = [_][]const u8{"dir/" ++ ("a" ** 140) ++ ".raw"};
    var long_plan = try BatchNamePlan.init(allocator, &long_inputs);
    defer long_plan.deinit(allocator);
    const long_output = try determineBatchOutputFile(allocator, &long_plan, &long_inputs, 0, "out");
    defer allocator.free(long_output);

    try std.testing.expect(!std.mem.eql(u8, forward_one, forward_two));
    try std.testing.expectEqualStrings(forward_one, reverse_one);
    try std.testing.expectEqualStrings(forward_two, reverse_two);
    try std.testing.expect(std.mem.endsWith(u8, forward_one, ".css"));
    try std.testing.expect(std.mem.endsWith(u8, forward_two, ".css"));
    const expected_unique = try std.fs.path.join(allocator, &.{ "out", "unique.css" });
    defer allocator.free(expected_unique);
    try std.testing.expectEqualStrings(expected_unique, forward_unique);
    const long_basename = std.fs.path.basename(long_output);
    try std.testing.expect(long_basename.len <= max_batch_output_basename_bytes);
    try std.testing.expect(std.mem.startsWith(u8, long_basename, "zigcss-"));
}

test "batch output names are normalized deterministic and allocation-safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseBatchNamingAllocationFailures,
        .{},
    );
}

test "case-insensitive batch policies hash every non-ASCII stem" {
    const non_ascii_stems = [_][]const u8{
        "\xc3\x84",
        "\xc3\xa4",
        "\xc3\xa9",
        "e\xcc\x81",
    };
    for (non_ascii_stems) |stem| {
        try std.testing.expect(requiresPortableHashedStemForOs(.windows, stem));
        try std.testing.expect(requiresPortableHashedStemForOs(.macos, stem));
        try std.testing.expect(!requiresPortableHashedStemForOs(.linux, stem));
    }
    try std.testing.expect(!requiresPortableHashedStemForOs(.windows, "ASCII"));
    try std.testing.expect(!requiresPortableHashedStemForOs(.macos, "ascii"));
}

test "prepared Unicode collision strategy stays indexed on case-sensitive targets" {
    try std.testing.expect(!preparedNameNeedsConservativeScanForOs(.linux, "\xc3\xa9.css"));
    try std.testing.expect(preparedNameNeedsConservativeScanForOs(.windows, "\xc3\xa9.css"));
    try std.testing.expect(preparedNameNeedsConservativeScanForOs(.macos, "\xc3\xa9.css"));
    try std.testing.expect(!preparedNameNeedsConservativeScanForOs(.windows, "ASCII.css"));
}

test "batch stem index plans thousands of colliding names with one lookup per input" {
    const input_count = 8192;
    const inputs = try std.testing.allocator.alloc([]const u8, input_count);
    defer std.testing.allocator.free(inputs);
    var initialized: usize = 0;
    defer for (inputs[0..initialized]) |input| std.testing.allocator.free(input);

    for (inputs, 0..) |*input, index| {
        input.* = try std.fmt.allocPrint(
            std.testing.allocator,
            "directory-{d}/shared.css",
            .{index},
        );
        initialized += 1;
    }

    var plan = try BatchNamePlan.init(std.testing.allocator, inputs);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(input_count, plan.indexed_inputs);
    try std.testing.expectEqual(@as(usize, 1), plan.cwd_resolutions);
    try std.testing.expectEqual(@as(usize, 1), plan.counts.count());
    for (inputs) |input| try std.testing.expect(plan.needsDisambiguation(input));

    const unique = [_][]const u8{ "one.css", "two.css", "three.css" };
    var unique_plan = try BatchNamePlan.init(std.testing.allocator, &unique);
    defer unique_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unique_plan.cwd_resolutions);
}

test "output collision hash indexes scan thousands of paths in argument order" {
    const path_count = 2048;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);

    const inputs = try std.testing.allocator.alloc([]const u8, path_count);
    defer std.testing.allocator.free(inputs);
    var initialized_inputs: usize = 0;
    defer for (inputs[0..initialized_inputs]) |path| std.testing.allocator.free(path);
    const outputs = try std.testing.allocator.alloc([]const u8, path_count);
    defer std.testing.allocator.free(outputs);
    var initialized_outputs: usize = 0;
    defer for (outputs[0..initialized_outputs]) |path| std.testing.allocator.free(path);

    for (0..path_count) |index| {
        inputs[index] = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}/input-{d}.css",
            .{ directory, index },
        );
        initialized_inputs += 1;
        outputs[index] = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}/output-{d}.css",
            .{ directory, if (index + 1 == path_count) 0 else index },
        );
        initialized_outputs += 1;
    }

    const collision = (try findOutputCollision(
        std.testing.allocator,
        inputs,
        outputs,
    )) orelse return error.ExpectedOutputCollision;
    try std.testing.expect(collision.kind == .duplicate_output);
    try std.testing.expectEqualStrings(outputs[path_count - 1], collision.path);
}

fn exerciseNativeDependencyCollisionUnionAllocationFailures(allocator: std.mem.Allocator) !void {
    const dependency_path = "/tmp/zigcss-native-dependency-collision.scss";
    const first_dependencies = [_]native_api.Dependency{.{
        .kind = .use,
        .url = "file:///tmp/zigcss-native-shared.scss",
    }};
    const second_dependencies = [_]native_api.Dependency{
        .{ .kind = .use, .url = "file:///tmp/zigcss-native-shared.scss" },
        .{ .kind = .import, .url = "file:///tmp/zigcss-native-dependency-collision.scss" },
    };
    const entries = [_][]const u8{
        "/tmp/zigcss-native-entry-one.scss",
        "/tmp/zigcss-native-entry-two.scss",
    };
    const dependency_groups = [_][]const native_api.Dependency{
        &first_dependencies,
        &second_dependencies,
    };
    const destinations = [_][]const u8{
        "/tmp/zigcss-native-output-one.css",
        dependency_path,
    };

    const collision = (try findNativeOutputCollision(
        allocator,
        &entries,
        &dependency_groups,
        &destinations,
    )) orelse return error.ExpectedOutputCollision;
    try std.testing.expect(collision.kind == .output_is_input);
    try std.testing.expectEqualStrings(dependency_path, collision.path);
}

test "native dependency collision union is deduplicated and allocation-safe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNativeDependencyCollisionUnionAllocationFailures,
        .{},
    );
}

fn exerciseWatchDependencyAllocationFailures(allocator: std.mem.Allocator) !void {
    const dependencies = [_]zigcss.Dependency{
        .{ .kind = .import, .specifier = "theme.css?cache=1", .source_name = "", .span = undefined },
        .{ .kind = .import, .specifier = "./theme.css#section", .source_name = "", .span = undefined },
        .{ .kind = .import, .specifier = "nested/extra.css", .source_name = "", .span = undefined },
        .{ .kind = .import, .specifier = "main.css", .source_name = "", .span = undefined },
        .{ .kind = .import, .specifier = "https://example.test/remote.css", .source_name = "", .span = undefined },
        .{ .kind = .import, .specifier = "//example.test/protocol-relative.css", .source_name = "", .span = undefined },
        .{ .kind = .import, .specifier = "/origin-relative.css", .source_name = "", .span = undefined },
        .{ .kind = .import, .specifier = "data:text/css,.remote{}", .source_name = "", .span = undefined },
    };
    var previous = WatchDependencies.init(allocator);
    defer previous.deinit();
    var watched = try buildWatchDependencies(
        allocator,
        "fixtures/main.css",
        &dependencies,
        &previous,
    );
    defer watched.deinit();

    try std.testing.expectEqual(@as(usize, 2), watched.items.len);
    const expected_theme = try std.fs.path.resolve(allocator, &.{ "fixtures", "theme.css" });
    defer allocator.free(expected_theme);
    const expected_extra = try std.fs.path.resolve(allocator, &.{ "fixtures", "nested", "extra.css" });
    defer allocator.free(expected_extra);
    try std.testing.expectEqualStrings(expected_theme, watched.items[0].path);
    try std.testing.expectEqualStrings(expected_extra, watched.items[1].path);

    var rebuilt = try buildWatchDependencies(
        allocator,
        "fixtures/main.css",
        &dependencies,
        &watched,
    );
    defer rebuilt.deinit();
    try std.testing.expectEqual(@as(usize, 2), rebuilt.items.len);
    try std.testing.expect(watched.items[0].fingerprint.eql(rebuilt.items[0].fingerprint));
    try std.testing.expect(watched.items[1].fingerprint.eql(rebuilt.items[1].fingerprint));
}

test "watch dependencies are local deduplicated ordered and allocation-safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseWatchDependencyAllocationFailures,
        .{},
    );
}

test "watch dependency fingerprints detect one transition without looping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "dependency.css", .data = ".one{}" });
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "main.css" });
    defer std.testing.allocator.free(source_path);
    const dependencies = [_]zigcss.Dependency{
        .{ .kind = .import, .specifier = "dependency.css?version=1", .source_name = "", .span = undefined },
    };
    var previous = WatchDependencies.init(std.testing.allocator);
    defer previous.deinit();
    var watched = try buildWatchDependencies(
        std.testing.allocator,
        source_path,
        &dependencies,
        &previous,
    );
    defer watched.deinit();

    try std.testing.expect(!(try watched.poll()));
    try tmp.dir.writeFile(.{ .sub_path = "dependency.css", .data = ".two{}" });
    try std.testing.expect(try watched.poll());
    try std.testing.expect(!(try watched.poll()));
    try tmp.dir.deleteFile("dependency.css");
    try std.testing.expect(try watched.poll());
    try std.testing.expect(!(try watched.poll()));
    try tmp.dir.writeFile(.{ .sub_path = "dependency.css", .data = ".three{}" });
    try std.testing.expect(try watched.poll());
    try std.testing.expect(!(try watched.poll()));
}

test "watch tracker records source state before a failed compile attempt" {
    var tracker = WatchTracker{};
    const invalid_source = WatchFingerprint{ .contents = computeFileHash(".broken{") };
    try std.testing.expect(tracker.shouldCompile(invalid_source, false));
    // A compile failure does not roll back the observed state, so an unchanged
    // source waits for a real source/dependency transition instead of looping.
    try std.testing.expect(!tracker.shouldCompile(invalid_source, false));
    try std.testing.expect(tracker.shouldCompile(invalid_source, true));
    try std.testing.expect(!tracker.shouldCompile(invalid_source, false));
    const unavailable = WatchFingerprint{ .unavailable = error.FileNotFound };
    try std.testing.expect(tracker.observeSource(unavailable));
    try std.testing.expect(!tracker.observeSource(unavailable));
}

fn testCompileTask(name: []const u8) CompileTask {
    return .{
        .input_file = name,
        .output_file = name,
        .syntax = .css,
        .optimize = false,
        .minify = false,
    };
}

test "parallel worker count has an explicit process-local cap" {
    try std.testing.expectEqual(@as(usize, 0), batchWorkerCount(0, 128));
    try std.testing.expectEqual(@as(usize, 1), batchWorkerCount(10, 0));
    try std.testing.expectEqual(@as(usize, 3), batchWorkerCount(3, 128));
    try std.testing.expectEqual(max_batch_workers, batchWorkerCount(1000, 128));
}

test "parallel queue cancellation leaves unclaimed work explicitly cancelled" {
    var tasks = [_]CompileTask{
        testCompileTask("zero.css"),
        testCompileTask("one.css"),
        testCompileTask("two.css"),
        testCompileTask("three.css"),
    };
    var queue = BatchWorkQueue{ .tasks = &tasks };
    const first = queue.claim() orelse return error.MissingClaimedTask;
    const second = queue.claim() orelse return error.MissingClaimedTask;
    try std.testing.expectEqualStrings("zero.css", first.input_file);
    try std.testing.expectEqualStrings("one.css", second.input_file);
    first.state = .failed;
    second.state = .succeeded;
    queue.cancelForFailure();
    try std.testing.expect(queue.claim() == null);
    queue.markPendingCancelled();
    try std.testing.expect(queue.failed);
    try std.testing.expectEqual(CompileTaskState.failed, tasks[0].state);
    try std.testing.expectEqual(CompileTaskState.succeeded, tasks[1].state);
    try std.testing.expectEqual(CompileTaskState.cancelled, tasks[2].state);
    try std.testing.expectEqual(CompileTaskState.cancelled, tasks[3].state);
}

test "parallel tasks own independent allocator lifetimes" {
    var first = testCompileTask("first.css");
    var second = testCompileTask("second.css");
    const first_allocator = first.allocator();
    const second_allocator = second.allocator();
    try std.testing.expect(first_allocator.ptr != second_allocator.ptr);

    const first_bytes = try first_allocator.dupe(u8, "first");
    const second_bytes = try second_allocator.dupe(u8, "second");
    try std.testing.expectEqualStrings("first", first_bytes);
    try std.testing.expectEqualStrings("second", second_bytes);
    first_allocator.free(first_bytes);
    second_allocator.free(second_bytes);
    try std.testing.expect(first.allocator_state.deinit() == .ok);
    try std.testing.expect(second.allocator_state.deinit() == .ok);
}

test "parallel batch failure unwinds every task allocator before returning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "broken.css", .data = ".broken{missing}" });
    try tmp.dir.writeFile(.{ .sub_path = "valid.css", .data = ".valid{color:green}" });
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const broken = try std.fs.path.join(std.testing.allocator, &.{ directory, "broken.css" });
    defer std.testing.allocator.free(broken);
    const valid = try std.fs.path.join(std.testing.allocator, &.{ directory, "valid.css" });
    defer std.testing.allocator.free(valid);
    const output = try std.fs.path.join(std.testing.allocator, &.{ directory, "out" });
    defer std.testing.allocator.free(output);
    const inputs = [_][]const u8{ broken, valid };

    try std.testing.expectError(
        error.CompileError,
        compileBatch(
            std.testing.allocator,
            &inputs,
            output,
            .css,
            false,
            true,
            false,
            .{},
        ),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out", .{}));
}

test "legacy compiler imports remain test-only" {
    _ = formats;
    _ = codegen;
    _ = optimizer;
}

const formats = @import("formats.zig");
const codegen = @import("codegen.zig");
const optimizer = @import("optimizer.zig");

test "legacy codegen rejects transform requests without mutating its AST" {
    const css = ".stable { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .optimize = true }),
    );
    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .autoprefix = .{} }),
    );
    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .dead_code = .{} }),
    );
    try std.testing.expectError(
        error.UnsafeTransformsDisabled,
        codegen.generate(allocator, &stylesheet, .{ .critical_css = .{} }),
    );

    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.items.len);
    try std.testing.expectEqualStrings("color", stylesheet.rules.items[0].style.declarations.items[0].property);
    try std.testing.expectEqualStrings("red", stylesheet.rules.items[0].style.declarations.items[0].value);
}

test "profiler timing handles can be ended more than once safely" {
    const profiler = @import("profiler.zig");
    var perf_profiler = try profiler.Profiler.init(std.testing.allocator, true);
    defer perf_profiler.deinit();

    var timing = try perf_profiler.startTiming("parse");
    try timing.end();
    try timing.end();

    const metrics = perf_profiler.getMetrics();
    try std.testing.expect(metrics.parse_time_ns <= metrics.total_time_ns);
}

test "basic compilation" {
    const css = ".container { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".container"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "color"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "red"));
}

test "minify output" {
    const css = ".container { color: red; background: white; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const result = try codegen.generate(allocator, &stylesheet, .{ .minify = true });
    defer allocator.free(result);

    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".container"));
}

test "important flag" {
    const css = ".test { color: red !important; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 1);
    try std.testing.expect(rule.style.declarations.items[0].important == true);
}

test "multiple selectors" {
    const css = ".a, .b, .c { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.selectors.items.len == 3);
}

test "at-rule parsing" {
    const css = "@media (min-width: 768px) { .container { width: 100%; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "media"));
}

test "container query parsing" {
    const css = "@container (min-width: 400px) { .card { padding: 1rem; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "container"));
}

test "cascade layer parsing" {
    const css = "@layer utilities { .button { color: red; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "layer"));
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.prelude, "utilities"));
}

test "legacy optimizer internal: cascade layer merging" {
    const css = "@layer theme { .button { color: red; } } @layer theme { .link { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    var layer_count: usize = 0;
    var i: usize = 0;
    while (i < result.len) {
        if (i + 6 <= result.len and std.mem.eql(u8, result[i .. i + 6], "@layer")) {
            layer_count += 1;
            i += 6;
        } else {
            i += 1;
        }
    }
    try std.testing.expect(layer_count == 1);
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".button"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".link"));
}

test "legacy optimizer internal: cascade layer anonymous merging" {
    const css = "@layer { .a { color: red; } } @layer { .b { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    var layer_count: usize = 0;
    var i: usize = 0;
    while (i < result.len) {
        if (i + 6 <= result.len and std.mem.eql(u8, result[i .. i + 6], "@layer")) {
            layer_count += 1;
            i += 6;
        } else {
            i += 1;
        }
    }
    try std.testing.expect(layer_count == 1);
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".a"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".b"));
}

test "legacy optimizer internal: flexbox shorthand optimization" {
    const css = ".flex { flex-grow: 1; flex-shrink: 1; flex-basis: 0%; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "flex:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-grow"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-shrink"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "flex-basis"));
}

test "legacy optimizer internal: grid template shorthand optimization" {
    const css = ".grid { grid-template-rows: 1fr 1fr; grid-template-columns: repeat(2, 1fr); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "grid-template:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "grid-template-rows"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "grid-template-columns"));
}

test "legacy optimizer internal: gap shorthand optimization" {
    const css = ".container { row-gap: 20px; column-gap: 20px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "gap:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "row-gap"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "column-gap"));
}

test "legacy optimizer internal: gap shorthand optimization different values" {
    const css = ".container { row-gap: 10px; column-gap: 20px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "gap:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "10px"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "20px"));
}

test "legacy optimizer internal: logical properties optimization" {
    const css = ".box { margin-inline-start: 10px; margin-inline-end: 20px; padding-block-start: 5px; padding-block-end: 15px; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "margin-left"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "margin-right"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "padding-top"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "padding-bottom"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "margin-inline-start"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "margin-inline-end"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "padding-block-start"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "padding-block-end"));
}

test "legacy optimizer internal: logical border properties optimization" {
    const css = ".border { border-inline-start-width: 2px; border-inline-end-color: red; border-block-start-style: solid; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    var opt = optimizer.Optimizer.init(allocator);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-left-width"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-right-color"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "border-top-style"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-inline-start-width"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-inline-end-color"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "border-block-start-style"));
}

test "legacy optimizer internal: dead code elimination" {
    const css = ".used-class { color: red; } .unused-class { color: blue; } #used-id { color: green; } #unused-id { color: yellow; } div { color: black; } span { color: white; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const used_classes = [_][]const u8{"used-class"};
    const used_ids = [_][]const u8{"used-id"};
    const used_elements = [_][]const u8{"div"};

    const dead_code_opts = optimizer.DeadCodeOptions{
        .used_classes = &used_classes,
        .used_ids = &used_ids,
        .used_elements = &used_elements,
    };

    var opt = optimizer.Optimizer.initWithDeadCode(allocator, dead_code_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".used-class"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "#used-id"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "div"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".unused-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "#unused-id"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "span"));
}

test "legacy optimizer internal: dead code elimination with media queries" {
    const css = "@media (min-width: 768px) { .used-class { color: red; } .unused-class { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const used_classes = [_][]const u8{"used-class"};

    const dead_code_opts = optimizer.DeadCodeOptions{
        .used_classes = &used_classes,
    };

    var opt = optimizer.Optimizer.initWithDeadCode(allocator, dead_code_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".used-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".unused-class"));
}

test "legacy optimizer internal: critical CSS extraction" {
    const css = ".critical-class { color: red; } .non-critical-class { color: blue; } #critical-id { color: green; } #non-critical-id { color: yellow; } div { color: black; } span { color: white; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const critical_classes = [_][]const u8{"critical-class"};
    const critical_ids = [_][]const u8{"critical-id"};
    const critical_elements = [_][]const u8{"div"};

    const critical_css_opts = optimizer.CriticalCssOptions{
        .critical_classes = &critical_classes,
        .critical_ids = &critical_ids,
        .critical_elements = &critical_elements,
    };

    var opt = optimizer.Optimizer.initWithCriticalCss(allocator, critical_css_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".critical-class"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "#critical-id"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "div"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".non-critical-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "#non-critical-id"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "span"));
}

test "legacy optimizer internal: critical CSS extraction with media queries" {
    const css = "@media (min-width: 768px) { .critical-class { color: red; } .non-critical-class { color: blue; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parser_trait = formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const critical_classes = [_][]const u8{"critical-class"};

    const critical_css_opts = optimizer.CriticalCssOptions{
        .critical_classes = &critical_classes,
    };

    var opt = optimizer.Optimizer.initWithCriticalCss(allocator, critical_css_opts);
    try opt.optimize(&stylesheet);

    const result = try codegen.generate(allocator, &stylesheet, .{});
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ".critical-class"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, ".non-critical-class"));
}
