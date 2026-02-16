const std = @import("std");
const ast = @import("ast.zig");

pub const Profiler = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    timings: std.ArrayList(Timing),
    memory_stats: MemoryStats,
    
    const Timing = struct {
        name: []const u8,
        duration_ns: u64,
        memory_before: usize,
        memory_after: usize,
    };
    
    const MemoryStats = struct {
        peak_memory: usize,
        total_allocations: usize,
        total_deallocations: usize,
    };
    
    pub fn init(allocator: std.mem.Allocator, enabled: bool) !Profiler {
        return .{
            .allocator = allocator,
            .enabled = enabled,
            .timings = try std.ArrayList(Timing).initCapacity(allocator, 10),
            .memory_stats = .{
                .peak_memory = 0,
                .total_allocations = 0,
                .total_deallocations = 0,
            },
        };
    }
    
    pub fn deinit(self: *Profiler) void {
        for (self.timings.items) |timing| {
            self.allocator.free(timing.name);
        }
        self.timings.deinit(self.allocator);
    }
    
    pub fn startTiming(self: *Profiler, name: []const u8) !TimingHandle {
        if (!self.enabled) {
            return TimingHandle{
                .profiler = self,
                .name = name,
                .start_time = 0,
                .memory_before = 0,
            };
        }
        
        const name_copy = try self.allocator.dupe(u8, name);
        const start_time = std.time.nanoTimestamp();
        const memory_before = self.getCurrentMemoryUsage();
        
        return TimingHandle{
            .profiler = self,
            .name = name_copy,
            .start_time = start_time,
            .memory_before = memory_before,
        };
    }
    
    pub fn getCurrentMemoryUsage(self: *const Profiler) usize {
        if (!self.enabled) return 0;
        return 0;
    }
    
    pub fn printReport(self: *const Profiler) void {
        if (!self.enabled or self.timings.items.len == 0) return;
        
        std.debug.print("\n=== Performance Profile ===\n\n", .{});
        
        var total_ns: u64 = 0;
        for (self.timings.items) |timing| {
            total_ns += timing.duration_ns;
        }
        
        std.debug.print("Timing Breakdown:\n", .{});
        std.debug.print("{s:<30} {s:>12} {s:>8} {s:>12}\n", .{ "Operation", "Time (ms)", "%", "Memory (KB)" });
        std.debug.print("{s:-<30} {s:->12} {s:->8} {s:->12}\n", .{ "", "", "", "" });
        
        for (self.timings.items) |timing| {
            const ms = @as(f64, @floatFromInt(timing.duration_ns)) / 1_000_000.0;
            const percentage = if (total_ns > 0) (@as(f64, @floatFromInt(timing.duration_ns)) / @as(f64, @floatFromInt(total_ns))) * 100.0 else 0.0;
            const memory_kb = @as(f64, @floatFromInt(timing.memory_after - timing.memory_before)) / 1024.0;
            
            std.debug.print("{s:<30} {d:>11.3} {d:>7.1}% {d:>11.2}\n", .{
                timing.name,
                ms,
                percentage,
                memory_kb,
            });
        }
        
        const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
        std.debug.print("{s:-<30} {s:->12} {s:->8} {s:->12}\n", .{ "", "", "", "" });
        std.debug.print("{s:<30} {d:>11.3} {s:>8} {s:>12}\n", .{ "Total", total_ms, "100.0%", "" });
        
        std.debug.print("\nMemory Statistics:\n", .{});
        std.debug.print("  Peak Memory: {d:.2} KB\n", .{@as(f64, @floatFromInt(self.memory_stats.peak_memory)) / 1024.0});
        std.debug.print("  Total Allocations: {d}\n", .{self.memory_stats.total_allocations});
        std.debug.print("  Total Deallocations: {d}\n", .{self.memory_stats.total_deallocations});
        
        std.debug.print("\n", .{});
    }
    
    pub fn getMetrics(self: *const Profiler) Metrics {
        if (!self.enabled or self.timings.items.len == 0) {
            return Metrics{
                .total_time_ns = 0,
                .parse_time_ns = 0,
                .optimize_time_ns = 0,
                .codegen_time_ns = 0,
                .peak_memory_bytes = 0,
            };
        }
        
        var total_ns: u64 = 0;
        var parse_ns: u64 = 0;
        var optimize_ns: u64 = 0;
        var codegen_ns: u64 = 0;
        
        for (self.timings.items) |timing| {
            total_ns += timing.duration_ns;
            if (std.mem.indexOf(u8, timing.name, "parse") != null) {
                parse_ns += timing.duration_ns;
            } else if (std.mem.indexOf(u8, timing.name, "optimize") != null) {
                optimize_ns += timing.duration_ns;
            } else if (std.mem.indexOf(u8, timing.name, "codegen") != null) {
                codegen_ns += timing.duration_ns;
            }
        }
        
        return Metrics{
            .total_time_ns = total_ns,
            .parse_time_ns = parse_ns,
            .optimize_time_ns = optimize_ns,
            .codegen_time_ns = codegen_ns,
            .peak_memory_bytes = self.memory_stats.peak_memory,
        };
    }
    
    pub const Metrics = struct {
        total_time_ns: u64,
        parse_time_ns: u64,
        optimize_time_ns: u64,
        codegen_time_ns: u64,
        peak_memory_bytes: usize,
    };
};

pub const TimingHandle = struct {
    profiler: *Profiler,
    name: []const u8,
    start_time: i128,
    memory_before: usize,
    
    pub fn end(self: *TimingHandle) !void {
        if (!self.profiler.enabled) {
            return;
        }
        
        const end_time = std.time.nanoTimestamp();
        const duration_ns = @as(u64, @intCast(@abs(end_time - self.start_time)));
        const memory_after = self.profiler.getCurrentMemoryUsage();
        
        if (memory_after > self.profiler.memory_stats.peak_memory) {
            self.profiler.memory_stats.peak_memory = memory_after;
        }
        
        try self.profiler.timings.append(self.profiler.allocator, .{
            .name = self.name,
            .duration_ns = duration_ns,
            .memory_before = self.memory_before,
            .memory_after = memory_after,
        });
    }
};

pub fn benchmarkCompilation(
    allocator: std.mem.Allocator,
    css: []const u8,
    iterations: usize,
) !BenchmarkResult {
    var total_parse_ns: u64 = 0;
    var total_optimize_ns: u64 = 0;
    var total_codegen_ns: u64 = 0;
    var total_memory: usize = 0;
    
    for (0..iterations) |_| {
        const parse_start = std.time.nanoTimestamp();
        var parser = @import("parser.zig").Parser.init(allocator, css);
        defer if (parser.owns_pool) {
            parser.string_pool.deinit();
            allocator.destroy(parser.string_pool);
        };
        
        var parse_result = parser.parseWithErrorInfo();
        const parse_end = std.time.nanoTimestamp();
        
        switch (parse_result) {
            .success => |*stylesheet_ptr| {
                const stylesheet = @constCast(stylesheet_ptr);
                defer stylesheet.deinit();
                
                total_parse_ns += @as(u64, @intCast(@abs(parse_end - parse_start)));
                
                const optimize_start = std.time.nanoTimestamp();
                const optimizer = @import("optimizer.zig");
                var opt = optimizer.Optimizer.init(allocator);
                try opt.optimize(stylesheet);
                const optimize_end = std.time.nanoTimestamp();
                total_optimize_ns += @as(u64, @intCast(@abs(optimize_end - optimize_start)));
                
                const codegen_start = std.time.nanoTimestamp();
                const codegen = @import("codegen.zig");
                const result = try codegen.generate(allocator, stylesheet, .{ .optimize = true, .minify = true });
                defer allocator.free(result);
                const codegen_end = std.time.nanoTimestamp();
                total_codegen_ns += @as(u64, @intCast(@abs(codegen_end - codegen_start)));
                
                total_memory += result.len;
            },
            .parse_error => |parse_error| {
                std.debug.print("Parse error at line {d}, column {d}: {s}\n", .{ parse_error.line, parse_error.column, parse_error.message });
                return error.ParseError;
            },
        }
    }
    
    return BenchmarkResult{
        .parse_time_ns = total_parse_ns / iterations,
        .optimize_time_ns = total_optimize_ns / iterations,
        .codegen_time_ns = total_codegen_ns / iterations,
        .total_time_ns = (total_parse_ns + total_optimize_ns + total_codegen_ns) / iterations,
        .avg_output_size = total_memory / iterations,
        .throughput_mb_per_s = if (total_parse_ns + total_optimize_ns + total_codegen_ns > 0) 
            (@as(f64, @floatFromInt(css.len * iterations)) / @as(f64, @floatFromInt(total_parse_ns + total_optimize_ns + total_codegen_ns))) * 1_000_000_000.0 / (1024.0 * 1024.0)
        else 0.0,
    };
}

pub const BenchmarkResult = struct {
    parse_time_ns: u64,
    optimize_time_ns: u64,
    codegen_time_ns: u64,
    total_time_ns: u64,
    avg_output_size: usize,
    throughput_mb_per_s: f64,
    
    pub fn print(self: BenchmarkResult) void {
        std.debug.print("\n=== Benchmark Results ===\n\n", .{});
        std.debug.print("Parse Time:      {d:.3} ms\n", .{@as(f64, @floatFromInt(self.parse_time_ns)) / 1_000_000.0});
        std.debug.print("Optimize Time:   {d:.3} ms\n", .{@as(f64, @floatFromInt(self.optimize_time_ns)) / 1_000_000.0});
        std.debug.print("Codegen Time:    {d:.3} ms\n", .{@as(f64, @floatFromInt(self.codegen_time_ns)) / 1_000_000.0});
        std.debug.print("Total Time:      {d:.3} ms\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000.0});
        std.debug.print("Output Size:     {d} bytes\n", .{self.avg_output_size});
        std.debug.print("Throughput:      {d:.2} MB/s\n", .{self.throughput_mb_per_s});
        std.debug.print("\n", .{});
    }
};
