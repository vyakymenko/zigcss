const std = @import("std");
const builtin = @import("builtin");
const zigcss = @import("zigcss");
const lsp = @import("lsp.zig");
const lsp_transport = @import("lsp_transport.zig");

const version = "0.4.0-rc.1";
const experimental_notice = std.fmt.comptimePrint(
    "Warning: ZigCSS {s} is an experimental release candidate; do not use it for production CSS.\n",
    .{version},
);
const unsafe_transforms_message = "legacy and non-verified transform paths are disabled pending safety validation";
const max_input_bytes = 10 * 1024 * 1024;
const max_batch_output_basename_bytes = 128;
const max_batch_workers = 8;
const stdin_source_name = "<stdin>";
const stdio_path = "-";
const exit_compile_failure: u8 = 1;
const exit_usage: u8 = 2;

const CompileConfig = struct {
    input_file: []const u8,
    output_file: ?[]const u8,
    syntax: zigcss.Syntax,
    optimize: bool,
    minify: bool,
    profile: bool = false,
};

const CompileTaskAllocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });

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
    result: ?zigcss.CompileResult = null,
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
        if (self.err_owned) task_allocator.free(self.err.?);
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
    profile: bool,
) zigcss.CompileError!zigcss.CompileResult {
    return zigcss.compile(
        allocator,
        source_name,
        input,
        .{
            .syntax = syntax,
            .format = if (minify) .minified else .pretty,
            .transforms = .{ .optimize = optimize },
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

fn writeOutputFile(path: []const u8, bytes: []const u8) !void {
    const cwd = std.fs.cwd();
    const mode = blk: {
        const stat = cwd.statFile(path) catch |err| switch (err) {
            error.FileNotFound => break :blk std.fs.File.default_mode,
            else => {
                std.debug.print("Error: failed to inspect output {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            },
        };
        break :blk if (stat.kind == .file) stat.mode else std.fs.File.default_mode;
    };

    var buffer: [4096]u8 = undefined;
    var atomic_file = cwd.atomicFile(path, .{
        .mode = mode,
        .make_path = true,
        .write_buffer = &buffer,
    }) catch |err| {
        std.debug.print("Error: failed to write {s} atomically: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer atomic_file.deinit();

    atomic_file.file_writer.interface.writeAll(bytes) catch {
        const err = atomic_file.file_writer.err orelse error.Unexpected;
        std.debug.print("Error: failed to write {s} atomically: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    atomic_file.finish() catch |err| {
        std.debug.print("Error: failed to write {s} atomically: {s}\n", .{ path, @errorName(err) });
        return err;
    };
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
        config.profile,
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

    if (config.output_file) |out| {
        if (isStdioPath(out)) {
            writeStdout(result.css) catch |err| {
                std.debug.print("Error: failed to write stdout: {s}\n", .{@errorName(err)});
                return err;
            };
        } else {
            try writeOutputFile(out, result.css);
            std.debug.print("Compiled: {s} -> {s}\n", .{ config.input_file, out });
        }
    } else {
        writeStdout(result.css) catch |err| {
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
        false,
    ) catch |err| {
        setTaskError(task, "Compilation error: {s}", .{@errorName(err)}, "Compilation error");
        return false;
    };
    task.result = result.take();
    result.deinit();
    task.state = if (hasErrorDiagnostics(task.result.?.diagnostics)) .failed else .succeeded;
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

    for (tasks) |*task| {
        if (task.state != .succeeded) return error.CompileError;
        try writeOutputFile(task.output_file, task.result.?.css);
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

fn expandGlob(allocator: std.mem.Allocator, pattern: []const u8) !std.ArrayList([]const u8) {
    var files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    
    if (std.mem.indexOf(u8, pattern, "*") == null) {
        const pattern_copy = try allocator.dupe(u8, pattern);
        try files.append(allocator, pattern_copy);
        return files;
    }

    const cwd = std.fs.cwd();
    const dir_path = std.fs.path.dirname(pattern) orelse ".";
    const basename_pattern = std.fs.path.basename(pattern);
    
    var dir = try cwd.openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (matchPattern(basename_pattern, entry.name)) {
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try files.append(allocator, full_path);
        }
    }
    
    return files;
}

fn matchPattern(pattern: []const u8, name: []const u8) bool {
    var pattern_idx: usize = 0;
    var name_idx: usize = 0;
    
    while (pattern_idx < pattern.len and name_idx < name.len) {
        if (pattern[pattern_idx] == '*') {
            pattern_idx += 1;
            if (pattern_idx >= pattern.len) return true;
            while (name_idx < name.len) {
                if (matchPattern(pattern[pattern_idx..], name[name_idx..])) {
                    return true;
                }
                name_idx += 1;
            }
            return false;
        } else if (pattern[pattern_idx] == name[name_idx]) {
            pattern_idx += 1;
            name_idx += 1;
        } else {
            return false;
        }
    }
    
    return pattern_idx >= pattern.len and name_idx >= name.len;
}

const PathIdentity = struct {
    normalized: []u8,
    inode: ?std.fs.File.INode,

    fn deinit(self: *PathIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized);
    }
};

const OutputCollision = struct {
    kind: enum {
        output_is_input,
        duplicate_output,
    },
    path: []const u8,
};

fn canonicalizeAbsolutePath(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, absolute_path) catch |err| {
        if (err != error.FileNotFound and err != error.NotDir) return err;

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

    const inode: ?std.fs.File.INode = blk: {
        const stat = std.fs.cwd().statFile(raw_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => break :blk null,
            else => return err,
        };
        break :blk stat.inode;
    };

    return .{
        .normalized = try canonicalizeAbsolutePath(allocator, absolute_path),
        .inode = inode,
    };
}

fn pathsEquivalent(a: *const PathIdentity, b: *const PathIdentity) bool {
    const normalized_equal = switch (builtin.os.tag) {
        .windows, .macos, .ios, .tvos, .watchos => std.ascii.eqlIgnoreCase(a.normalized, b.normalized),
        else => std.mem.eql(u8, a.normalized, b.normalized),
    };
    if (normalized_equal) return true;

    if (a.inode) |a_inode| {
        if (b.inode) |b_inode| {
            return a_inode != 0 and a_inode == b_inode;
        }
    }
    return false;
}

fn findOutputCollision(allocator: std.mem.Allocator, input_paths: []const []const u8, output_paths: []const []const u8) !?OutputCollision {
    const input_identities = try allocator.alloc(PathIdentity, input_paths.len);
    defer allocator.free(input_identities);
    var initialized_inputs: usize = 0;
    defer for (input_identities[0..initialized_inputs]) |*identity| identity.deinit(allocator);

    for (input_paths, 0..) |input_path, i| {
        input_identities[i] = try identifyPath(allocator, input_path);
        initialized_inputs += 1;
    }

    var output_identities = try std.ArrayList(PathIdentity).initCapacity(allocator, output_paths.len);
    defer {
        for (output_identities.items) |*identity| identity.deinit(allocator);
        output_identities.deinit(allocator);
    }

    for (output_paths) |output_path| {
        var output_identity = try identifyPath(allocator, output_path);
        errdefer output_identity.deinit(allocator);

        for (input_identities) |*input_identity| {
            if (pathsEquivalent(input_identity, &output_identity)) {
                output_identity.deinit(allocator);
                return .{ .kind = .output_is_input, .path = output_path };
            }
        }
        for (output_identities.items) |*prior_output| {
            if (pathsEquivalent(prior_output, &output_identity)) {
                output_identity.deinit(allocator);
                return .{ .kind = .duplicate_output, .path = output_path };
            }
        }

        try output_identities.append(allocator, output_identity);
    }

    return null;
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
        std.fmt.comptimePrint("ZigCSS {s} recovery CLI — EXPERIMENTAL, not production-ready\n\n", .{version}) ++
            "Usage: zigcss <input.css|-> [-o <output.css|->] [options]\n" ++
            "       zigcss <input1.css> <input2.css> ... -o <output-dir> --output-dir [options]\n" ++
            "       zigcss --lsp          Start experimental Language Server Protocol server\n" ++
            "\nAvailable options:\n" ++
            "  -o, --output <path|->    Output file/stdout, or directory with --output-dir\n" ++
            "  --output-dir             Require batch output under the -o directory\n" ++
            "  --syntax <css>           Select CSS input syntax (default: css)\n" ++
            "  --minify                 Emit compact whitespace (independent of --optimize)\n" ++
            "  --optimize               Run the closed verified optimizer preset\n" ++
            "  --watch                  Watch one input and its local CSS imports\n" ++
            "  --profile                Report API stages and requested memory bytes\n" ++
            "  --lsp                    Start the experimental LSP server\n" ++
            "  -V, --version            Show the package version\n" ++
            "  -h, --help               Show this help\n" ++
            "\nExit status: 0 success/info, 1 compilation or I/O failure, 2 usage error.\n" ++
            "\nUnavailable and rejected during recovery:\n" ++
            "  --source-map, --autoprefix, --browsers, --critical-*\n",
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

fn outputNameEqual(left: []const u8, right: []const u8) bool {
    return switch (builtin.os.tag) {
        .windows, .macos, .ios, .tvos, .watchos => std.ascii.eqlIgnoreCase(left, right),
        else => std.mem.eql(u8, left, right),
    };
}

fn batchNameNeedsDisambiguation(input_files: []const []const u8, index: usize) bool {
    const stem = batchOutputStem(input_files[index]);
    for (input_files, 0..) |other, other_index| {
        if (other_index != index and outputNameEqual(stem, batchOutputStem(other))) return true;
    }
    return false;
}

fn normalizedInputHash(allocator: std.mem.Allocator, input_file: []const u8) !u64 {
    const cwd_path = try std.fs.path.resolve(allocator, &.{"."});
    defer allocator.free(cwd_path);
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
    input_files: []const []const u8,
    index: usize,
    output_dir: []const u8,
) ![]u8 {
    const raw_stem = batchOutputStem(input_files[index]);
    const stem = if (raw_stem.len == 0) "output" else raw_stem;
    const needs_disambiguation = batchNameNeedsDisambiguation(input_files, index);
    const plain_name_len = std.math.add(usize, stem.len, ".css".len) catch std.math.maxInt(usize);
    const output_basename = if (!needs_disambiguation and plain_name_len <= max_batch_output_basename_bytes)
        try std.fmt.allocPrint(allocator, "{s}.css", .{stem})
    else blk: {
        const path_hash = try normalizedInputHash(allocator, input_files[index]);
        const suffixed_name_len = std.math.add(usize, stem.len, "-0000000000000000.css".len) catch std.math.maxInt(usize);
        if (suffixed_name_len <= max_batch_output_basename_bytes) {
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
) !void {
    var tasks = try std.ArrayList(CompileTask).initCapacity(allocator, input_files.len);
    defer {
        for (tasks.items) |*task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    for (input_files, 0..) |input, input_index| {
        const out_file = try determineBatchOutputFile(
            allocator,
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

fn experimentalFormatName(filename: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, filename, ".scss")) return "SCSS";
    if (std.mem.endsWith(u8, filename, ".sass")) return "SASS";
    if (std.mem.endsWith(u8, filename, ".less")) return "LESS";
    if (std.mem.endsWith(u8, filename, ".module.css")) return "CSS Modules";
    if (std.mem.endsWith(u8, filename, ".css.js") or
        std.mem.endsWith(u8, filename, ".css.ts")) return "CSS-in-JS";
    if (std.mem.endsWith(u8, filename, ".postcss")) return "PostCSS";
    if (std.mem.endsWith(u8, filename, ".styl")) return "Stylus";
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) exitWithCliError("no input files specified; use --help for usage", .{});

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
        std.debug.print("{s}", .{experimental_notice});
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
    
    var output_file: ?[]const u8 = null;
    var output_dir_flag = false;
    var syntax: zigcss.Syntax = .css;
    var syntax_flag_set = false;
    var optimize_flag = false;
    var minify_flag = false;
    var watch_flag = false;
    var profile_flag = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (output_file != null) exitWithCliError("{s} may only be specified once", .{args[i]});
            output_file = requireOptionValue(args, i, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir")) {
            if (output_dir_flag) exitWithCliError("--output-dir may only be specified once", .{});
            output_dir_flag = true;
        } else if (std.mem.eql(u8, args[i], "--syntax")) {
            if (syntax_flag_set) exitWithCliError("--syntax may only be specified once", .{});
            const value = requireOptionValue(args, i, args[i]);
            if (!std.mem.eql(u8, value, "css")) exitWithCliError("unsupported syntax: {s}", .{value});
            syntax = .css;
            syntax_flag_set = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--optimize")) {
            if (optimize_flag) exitWithCliError("--optimize may only be specified once", .{});
            optimize_flag = true;
        } else if (std.mem.eql(u8, args[i], "--minify")) {
            if (minify_flag) exitWithCliError("--minify may only be specified once", .{});
            minify_flag = true;
        } else if (std.mem.eql(u8, args[i], "--source-map")) {
            exitWithCliError("--source-map is unavailable until the CLI output policy is defined", .{});
        } else if (std.mem.eql(u8, args[i], "--watch")) {
            if (watch_flag) exitWithCliError("--watch may only be specified once", .{});
            watch_flag = true;
        } else if (std.mem.eql(u8, args[i], "--autoprefix")) {
            exitWithCliError("--autoprefix is unavailable: {s}", .{unsafe_transforms_message});
        } else if (std.mem.eql(u8, args[i], "--profile")) {
            if (profile_flag) exitWithCliError("--profile may only be specified once", .{});
            profile_flag = true;
        } else if (std.mem.eql(u8, args[i], "--browsers")) {
            _ = requireOptionValue(args, i, args[i]);
            exitWithCliError("--browsers is unavailable until target queries and prefix rules are validated", .{});
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
            const path_copy = try allocator.dupe(u8, args[i]);
            try input_files.append(allocator, path_copy);
        } else if (args[i].len == 0) {
            exitWithCliError("empty arguments are not valid input paths", .{});
        } else if (args[i][0] != '-') {
            var expanded = try expandGlob(allocator, args[i]);
            defer {
                for (expanded.items) |path| {
                    allocator.free(path);
                }
                expanded.deinit(allocator);
            }
            for (expanded.items) |path| {
                const path_copy = try allocator.dupe(u8, path);
                try input_files.append(allocator, path_copy);
            }
        } else {
            exitWithCliError("unknown option: {s}", .{args[i]});
        }
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
    if (profile_flag and input_files.items.len > 1) {
        exitWithCliError("--profile supports exactly one input", .{});
    }

    if (output_dir_flag and input_files.items.len < 2) {
        exitWithCliError("--output-dir requires multiple inputs", .{});
    }
    if (input_files.items.len > 1 and !output_dir_flag) {
        exitWithCliError("multiple inputs require --output-dir", .{});
    }
    if (output_dir_flag and output_file == null) {
        exitWithCliError("--output-dir requires -o or --output", .{});
    }
    if (output_dir_flag and isStdioPath(output_file.?)) {
        exitWithCliError("--output-dir cannot write to stdout", .{});
    }

    for (input_files.items) |input_file| {
        if (isStdioPath(input_file)) continue;
        if (experimentalFormatName(input_file)) |format_name| {
            exitWithCliError(
                "{s} format adapter is experimental and unavailable in the recovery CLI",
                .{format_name},
            );
        }
    }

    std.debug.print("{s}", .{experimental_notice});

    if (input_files.items.len == 1) {
        if (output_file) |out| {
            if (!isStdioPath(input_files.items[0]) and !isStdioPath(out)) {
                const planned_outputs = [_][]const u8{out};
                if (try findOutputCollision(allocator, input_files.items, &planned_outputs)) |collision| {
                    rejectOutputCollision(collision);
                }
            }
        }
    }

    if (watch_flag) {
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .syntax = syntax,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .profile = profile_flag,
        };
        try watchFile(allocator, config);
    } else if (input_files.items.len == 1) {
        const config = CompileConfig{
            .input_file = input_files.items[0],
            .output_file = output_file,
            .syntax = syntax,
            .optimize = optimize_flag,
            .minify = minify_flag,
            .profile = profile_flag,
        };
        compileFile(allocator, config) catch {
            std.process.exit(exit_compile_failure);
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
        ) catch |err| {
            if (err != error.CompileError and err != error.BatchUsageError) {
                std.debug.print("Error: batch compilation failed: {s}\n", .{@errorName(err)});
            }
            std.process.exit(if (err == error.BatchUsageError) exit_usage else exit_compile_failure);
        };
    }
}

test "CLI format boundary rejects every experimental extension without importing adapters" {
    const cases = [_]struct { filename: []const u8, name: []const u8 }{
        .{ .filename = "input.scss", .name = "SCSS" },
        .{ .filename = "input.sass", .name = "SASS" },
        .{ .filename = "input.less", .name = "LESS" },
        .{ .filename = "input.module.css", .name = "CSS Modules" },
        .{ .filename = "input.css.js", .name = "CSS-in-JS" },
        .{ .filename = "input.css.ts", .name = "CSS-in-JS" },
        .{ .filename = "input.postcss", .name = "PostCSS" },
        .{ .filename = "input.styl", .name = "Stylus" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.name, experimentalFormatName(case.filename).?);
    }
    try std.testing.expect(experimentalFormatName("input.css") == null);
    try std.testing.expect(experimentalFormatName("input.unknown") == null);
}

fn exerciseBatchNamingAllocationFailures(allocator: std.mem.Allocator) !void {
    const forward = [_][]const u8{ "one/shared.css", "two/shared.input", "unique.raw" };
    const reverse = [_][]const u8{ "unique.raw", "two/shared.input", "one/shared.css" };
    const forward_one = try determineBatchOutputFile(allocator, &forward, 0, "out");
    defer allocator.free(forward_one);
    const forward_two = try determineBatchOutputFile(allocator, &forward, 1, "out");
    defer allocator.free(forward_two);
    const forward_unique = try determineBatchOutputFile(allocator, &forward, 2, "out");
    defer allocator.free(forward_unique);
    const reverse_one = try determineBatchOutputFile(allocator, &reverse, 2, "out");
    defer allocator.free(reverse_one);
    const reverse_two = try determineBatchOutputFile(allocator, &reverse, 1, "out");
    defer allocator.free(reverse_two);
    const long_inputs = [_][]const u8{"dir/" ++ ("a" ** 140) ++ ".raw"};
    const long_output = try determineBatchOutputFile(allocator, &long_inputs, 0, "out");
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
        if (i + 6 <= result.len and std.mem.eql(u8, result[i..i+6], "@layer")) {
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
        if (i + 6 <= result.len and std.mem.eql(u8, result[i..i+6], "@layer")) {
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
