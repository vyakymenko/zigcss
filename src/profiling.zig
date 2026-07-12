const std = @import("std");

pub const Stage = enum {
    parse,
    validation,
    dependencies,
    optimize,
    transform,
    emit,
    result,
    cleanup,
};

pub const StageTimings = struct {
    parse_time_ns: u64 = 0,
    validation_time_ns: u64 = 0,
    dependency_time_ns: u64 = 0,
    optimize_time_ns: u64 = 0,
    transform_time_ns: u64 = 0,
    emit_time_ns: u64 = 0,
    result_time_ns: u64 = 0,
    cleanup_time_ns: u64 = 0,

    pub fn total(self: StageTimings) u64 {
        var value: u64 = 0;
        inline for (std.meta.fields(StageTimings)) |field| {
            value = saturatingAdd(u64, value, @field(self, field.name));
        }
        return value;
    }
};

pub const MemoryMetrics = struct {
    total_allocated_bytes: usize = 0,
    total_freed_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    retained_result_bytes: usize = 0,
    allocation_count: usize = 0,
    deallocation_count: usize = 0,
    resize_count: usize = 0,
};

pub const Metrics = struct {
    total_time_ns: u64,
    stages: StageTimings,
    memory: MemoryMetrics,
};

const CounterState = struct {
    total_allocated_bytes: usize = 0,
    total_freed_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    allocation_count: usize = 0,
    deallocation_count: usize = 0,
    resize_count: usize = 0,
};

/// Counts allocator-requested bytes. It deliberately forwards exact child
/// pointers, so result allocations may later be released through the original
/// child allocator after this stack-owned wrapper is gone.
pub const TrackingAllocator = struct {
    child: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    counters: CounterState = .{},

    pub fn init(child: std.mem.Allocator) TrackingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn snapshot(self: *TrackingAllocator) MemoryMetrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .total_allocated_bytes = self.counters.total_allocated_bytes,
            .total_freed_bytes = self.counters.total_freed_bytes,
            .peak_live_bytes = self.counters.peak_live_bytes,
            .retained_result_bytes = self.counters.live_bytes,
            .allocation_count = self.counters.allocation_count,
            .deallocation_count = self.counters.deallocation_count,
            .resize_count = self.counters.resize_count,
        };
    }

    fn allocate(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        const memory = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.counters.allocation_count = saturatingAdd(usize, self.counters.allocation_count, 1);
        self.recordGrowth(len);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        self.counters.resize_count = saturatingAdd(usize, self.counters.resize_count, 1);
        self.recordResize(memory.len, new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        self.counters.resize_count = saturatingAdd(usize, self.counters.resize_count, 1);
        self.recordResize(memory.len, new_len);
        return result;
    }

    fn release(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child.rawFree(memory, alignment, return_address);
        self.counters.deallocation_count = saturatingAdd(usize, self.counters.deallocation_count, 1);
        self.recordShrink(memory.len);
    }

    fn recordGrowth(self: *TrackingAllocator, bytes: usize) void {
        self.counters.total_allocated_bytes = saturatingAdd(
            usize,
            self.counters.total_allocated_bytes,
            bytes,
        );
        self.counters.live_bytes = saturatingAdd(usize, self.counters.live_bytes, bytes);
        self.counters.peak_live_bytes = @max(
            self.counters.peak_live_bytes,
            self.counters.live_bytes,
        );
    }

    fn recordShrink(self: *TrackingAllocator, bytes: usize) void {
        std.debug.assert(bytes <= self.counters.live_bytes);
        self.counters.total_freed_bytes = saturatingAdd(
            usize,
            self.counters.total_freed_bytes,
            bytes,
        );
        self.counters.live_bytes -= bytes;
    }

    fn recordResize(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.recordGrowth(new_len - old_len);
        } else if (new_len < old_len) {
            self.recordShrink(old_len - new_len);
        }
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = release,
    };
};

pub const Session = struct {
    enabled: bool,
    timer: ?std.time.Timer,
    tracker: TrackingAllocator,
    stages: StageTimings = .{},

    pub fn init(child: std.mem.Allocator, enabled: bool) std.time.Timer.Error!Session {
        return .{
            .enabled = enabled,
            .timer = if (enabled) try std.time.Timer.start() else null,
            .tracker = TrackingAllocator.init(child),
        };
    }

    pub fn workAllocator(self: *Session) std.mem.Allocator {
        return if (self.enabled) self.tracker.allocator() else self.tracker.child;
    }

    pub fn startStage(self: *Session) u64 {
        return self.now();
    }

    pub fn endStage(self: *Session, stage: Stage, started_ns: u64) void {
        if (!self.enabled) return;
        const elapsed = self.now() - started_ns;
        const destination = switch (stage) {
            .parse => &self.stages.parse_time_ns,
            .validation => &self.stages.validation_time_ns,
            .dependencies => &self.stages.dependency_time_ns,
            .optimize => &self.stages.optimize_time_ns,
            .transform => &self.stages.transform_time_ns,
            .emit => &self.stages.emit_time_ns,
            .result => &self.stages.result_time_ns,
            .cleanup => &self.stages.cleanup_time_ns,
        };
        destination.* = saturatingAdd(u64, destination.*, elapsed);
    }

    pub fn finish(self: *Session) ?Metrics {
        if (!self.enabled) return null;
        return .{
            .total_time_ns = self.now(),
            .stages = self.stages,
            .memory = self.tracker.snapshot(),
        };
    }

    fn now(self: *Session) u64 {
        if (self.timer) |*timer| return timer.read();
        return 0;
    }
};

fn saturatingAdd(comptime T: type, left: T, right: T) T {
    return std.math.add(T, left, right) catch std.math.maxInt(T);
}

test "tracking allocator reports exact requested-byte ownership" {
    var tracker = TrackingAllocator.init(std.testing.allocator);
    const allocator = tracker.allocator();
    const first = try allocator.alloc(u8, 16);
    const second = try allocator.alloc(u8, 32);
    var metrics = tracker.snapshot();
    try std.testing.expectEqual(@as(usize, 48), metrics.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 48), metrics.peak_live_bytes);
    try std.testing.expectEqual(@as(usize, 48), metrics.retained_result_bytes);
    try std.testing.expectEqual(@as(usize, 2), metrics.allocation_count);

    allocator.free(first);
    metrics = tracker.snapshot();
    try std.testing.expectEqual(@as(usize, 16), metrics.total_freed_bytes);
    try std.testing.expectEqual(@as(usize, 32), metrics.retained_result_bytes);
    allocator.free(second);
    metrics = tracker.snapshot();
    try std.testing.expectEqual(@as(usize, 48), metrics.total_freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), metrics.retained_result_bytes);
    try std.testing.expectEqual(@as(usize, 2), metrics.deallocation_count);
}

test "profiling session reports stages and forwards retained result pointers" {
    var session = try Session.init(std.testing.allocator, true);
    const parse_start = session.startStage();
    const retained = try session.workAllocator().alloc(u8, 64);
    session.endStage(.parse, parse_start);
    const metrics = session.finish() orelse return error.MissingMetrics;
    try std.testing.expect(metrics.total_time_ns >= metrics.stages.total());
    try std.testing.expect(metrics.memory.peak_live_bytes >= 64);
    try std.testing.expectEqual(@as(usize, 64), metrics.memory.retained_result_bytes);
    try std.testing.expect(metrics.memory.allocation_count >= 1);

    // The wrapper forwards exact child pointers, matching CompileResult's
    // post-return cleanup through the original caller allocator.
    std.testing.allocator.free(retained);

    var disabled = try Session.init(std.testing.allocator, false);
    try std.testing.expect(disabled.workAllocator().ptr == std.testing.allocator.ptr);
    try std.testing.expect(disabled.finish() == null);
}
