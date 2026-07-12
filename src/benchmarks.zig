const std = @import("std");
const builtin = @import("builtin");
const zigcss = @import("zigcss");

const small_css = @embedFile("benchmark-small-css");
const medium_css = @embedFile("benchmark-medium-css");
const large_css = @embedFile("benchmark-large-css");

const Corpus = struct {
    name: []const u8,
    css: []const u8,
};

const corpora = [_]Corpus{
    .{ .name = "small-flat.css", .css = small_css },
    .{ .name = "medium-flat.css", .css = medium_css },
    .{ .name = "large-flat.css", .css = large_css },
};

const api_warmup_iterations = 1;
const throughput_iterations = 2;
const throughput_operation_count = corpora.len * throughput_iterations;
const statistical_sample_count = 20;

const TimedCompile = struct {
    result: zigcss.CompileResult,
    duration_ns: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--raw-report")) {
        if (builtin.mode != .ReleaseFast) return error.BenchmarkRunnerRequiresReleaseFast;
        return writeRawReport(allocator);
    }
    if (arguments.len != 1) return error.InvalidBenchmarkArguments;

    const api_samples = try smokeInProcessApiLatency(allocator);
    const memory_observations = try smokeAllocatorRequestedMemory(allocator);
    const throughput_samples = try smokeInProcessThroughput(allocator);
    std.debug.print(
        "Benchmark mode smoke verified: {d} in-process API latency samples, " ++
            "{d} allocator-requested memory observations, and {d} in-process throughput sample; " ++
            "every timed output validated before admission and no result archived.\n",
        .{ api_samples, memory_observations, throughput_samples },
    );
}

const MemorySamples = struct {
    total_allocated_bytes: [statistical_sample_count]u64,
    total_freed_bytes: [statistical_sample_count]u64,
    peak_live_bytes: [statistical_sample_count]u64,
    retained_result_bytes: [statistical_sample_count]u64,
    allocation_count: [statistical_sample_count]u64,
    deallocation_count: [statistical_sample_count]u64,
    resize_count: [statistical_sample_count]u64,
};

fn writeRawReport(allocator: std.mem.Allocator) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };

    try json.beginObject();
    try json.objectField("schemaVersion");
    try json.write(1);
    try json.objectField("zigVersion");
    try json.write(builtin.zig_version_string);
    try json.objectField("optimizationMode");
    try json.write(@tagName(builtin.mode));
    try json.objectField("platform");
    try json.write(@tagName(builtin.os.tag));
    try json.objectField("architecture");
    try json.write(@tagName(builtin.cpu.arch));
    try json.objectField("series");
    try json.beginArray();

    for (corpora) |corpus| {
        var samples: [statistical_sample_count]u64 = undefined;
        try collectApiLatencySamples(allocator, corpus, &samples);
        try writeSeries(
            &json,
            "in-process-api",
            "latency-nanoseconds",
            corpusId(corpus),
            null,
            "nanoseconds",
            &samples,
        );
    }

    for (corpora) |corpus| {
        var samples: MemorySamples = undefined;
        try collectMemorySamples(allocator, corpus, &samples);
        try writeSeries(&json, "memory", "allocator-requested-bytes", corpusId(corpus), "totalAllocatedBytes", "bytes", &samples.total_allocated_bytes);
        try writeSeries(&json, "memory", "allocator-requested-bytes", corpusId(corpus), "totalFreedBytes", "bytes", &samples.total_freed_bytes);
        try writeSeries(&json, "memory", "allocator-requested-bytes", corpusId(corpus), "peakLiveBytes", "bytes", &samples.peak_live_bytes);
        try writeSeries(&json, "memory", "allocator-requested-bytes", corpusId(corpus), "retainedResultBytes", "bytes", &samples.retained_result_bytes);
        try writeSeries(&json, "memory", "allocator-requested-bytes", corpusId(corpus), "allocationCount", "count", &samples.allocation_count);
        try writeSeries(&json, "memory", "allocator-requested-bytes", corpusId(corpus), "deallocationCount", "count", &samples.deallocation_count);
        try writeSeries(&json, "memory", "allocator-requested-bytes", corpusId(corpus), "resizeCount", "count", &samples.resize_count);
    }

    var throughput_samples: [statistical_sample_count]u64 = undefined;
    try collectThroughputSamples(allocator, &throughput_samples);
    try writeSeries(
        &json,
        "throughput",
        "input-bytes-per-second",
        "all-v1",
        null,
        "input-bytes-per-second",
        &throughput_samples,
    );

    try json.endArray();
    try json.endObject();
    const bytes = try output.toOwnedSlice();
    defer allocator.free(bytes);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout.interface.writeAll(bytes);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn corpusId(corpus: Corpus) []const u8 {
    return corpus.name[0 .. corpus.name.len - ".css".len];
}

fn writeSeries(
    json: *std.json.Stringify,
    mode: []const u8,
    metric: []const u8,
    corpus: []const u8,
    field: ?[]const u8,
    unit: []const u8,
    samples: []const u64,
) !void {
    try json.beginObject();
    try json.objectField("mode");
    try json.write(mode);
    try json.objectField("metric");
    try json.write(metric);
    try json.objectField("tool");
    try json.write("zigcss");
    try json.objectField("corpus");
    try json.write(corpus);
    if (field) |name| {
        try json.objectField("field");
        try json.write(name);
    }
    try json.objectField("unit");
    try json.write(unit);
    try json.objectField("samples");
    try json.beginArray();
    for (samples) |sample| {
        var buffer: [20]u8 = undefined;
        try json.write(try std.fmt.bufPrint(&buffer, "{d}", .{sample}));
    }
    try json.endArray();
    try json.endObject();
}

fn collectApiLatencySamples(
    allocator: std.mem.Allocator,
    corpus: Corpus,
    samples: *[statistical_sample_count]u64,
) !void {
    for (0..api_warmup_iterations) |_| {
        var warmup = try compile(allocator, corpus, false);
        defer warmup.deinit();
        try validateCompileResult(allocator, corpus, &warmup);
    }
    for (samples) |*sample| {
        var measured = try compileTimed(allocator, corpus);
        defer measured.result.deinit();
        try validateCompileResult(allocator, corpus, &measured.result);
        sample.* = measured.duration_ns;
    }
}

fn collectMemorySamples(
    allocator: std.mem.Allocator,
    corpus: Corpus,
    samples: *MemorySamples,
) !void {
    for (0..statistical_sample_count) |index| {
        var result = try compile(allocator, corpus, true);
        defer result.deinit();
        try validateCompileResult(allocator, corpus, &result);
        const metrics = result.metrics orelse return error.MissingBenchmarkMemoryMetrics;
        const memory = metrics.memory;
        try validateMemoryMetrics(memory);
        samples.total_allocated_bytes[index] = memory.total_allocated_bytes;
        samples.total_freed_bytes[index] = memory.total_freed_bytes;
        samples.peak_live_bytes[index] = memory.peak_live_bytes;
        samples.retained_result_bytes[index] = memory.retained_result_bytes;
        samples.allocation_count[index] = memory.allocation_count;
        samples.deallocation_count[index] = memory.deallocation_count;
        samples.resize_count[index] = memory.resize_count;
    }
}

fn collectThroughputSamples(
    allocator: std.mem.Allocator,
    samples: *[statistical_sample_count]u64,
) !void {
    for (corpora) |corpus| {
        for (0..api_warmup_iterations) |_| {
            var warmup = try compile(allocator, corpus, false);
            defer warmup.deinit();
            try validateCompileResult(allocator, corpus, &warmup);
        }
    }
    for (samples) |*sample| sample.* = try measureThroughput(allocator);
}

fn compile(allocator: std.mem.Allocator, corpus: Corpus, profile: bool) !zigcss.CompileResult {
    return zigcss.compile(allocator, corpus.name, corpus.css, .{
        .format = .minified,
        .profile = profile,
    });
}

fn compileTimed(allocator: std.mem.Allocator, corpus: Corpus) !TimedCompile {
    var timer = try std.time.Timer.start();
    var result = try compile(allocator, corpus, false);
    const duration_ns = timer.read();
    if (duration_ns == 0) {
        result.deinit();
        return error.InvalidBenchmarkDuration;
    }
    return .{ .result = result, .duration_ns = duration_ns };
}

fn validateCompileResult(
    allocator: std.mem.Allocator,
    corpus: Corpus,
    result: *const zigcss.CompileResult,
) !void {
    if (result.diagnostics.len != 0 or result.css.len == 0) {
        return error.InvalidBenchmarkOutput;
    }
    try validateOutput(allocator, corpus.name, corpus.css, result.css);
}

fn smokeInProcessApiLatency(allocator: std.mem.Allocator) !usize {
    var accepted: usize = 0;
    for (corpora) |corpus| {
        for (0..api_warmup_iterations) |_| {
            var warmup = try compile(allocator, corpus, false);
            defer warmup.deinit();
            try validateCompileResult(allocator, corpus, &warmup);
        }

        var measured = try compileTimed(allocator, corpus);
        defer measured.result.deinit();
        try validateCompileResult(allocator, corpus, &measured.result);
        if (measured.duration_ns == 0) return error.InvalidBenchmarkDuration;
        accepted += 1;
    }
    return accepted;
}

fn smokeAllocatorRequestedMemory(allocator: std.mem.Allocator) !usize {
    var observations: usize = 0;
    for (corpora) |corpus| {
        var result = try compile(allocator, corpus, true);
        defer result.deinit();
        try validateCompileResult(allocator, corpus, &result);

        const metrics = result.metrics orelse return error.MissingBenchmarkMemoryMetrics;
        const memory = metrics.memory;
        try validateMemoryMetrics(memory);
        observations += 1;
    }
    return observations;
}

fn validateMemoryMetrics(memory: zigcss.CompileMemoryMetrics) !void {
    if (memory.total_allocated_bytes == 0 or
        memory.total_allocated_bytes < memory.total_freed_bytes or
        memory.total_allocated_bytes - memory.total_freed_bytes != memory.retained_result_bytes or
        memory.peak_live_bytes < memory.retained_result_bytes or
        memory.allocation_count == 0)
    {
        return error.InvalidBenchmarkMemoryMetrics;
    }
}

fn smokeInProcessThroughput(allocator: std.mem.Allocator) !usize {
    for (corpora) |corpus| {
        for (0..api_warmup_iterations) |_| {
            var warmup = try compile(allocator, corpus, false);
            defer warmup.deinit();
            try validateCompileResult(allocator, corpus, &warmup);
        }
    }

    _ = try measureThroughput(allocator);
    return 1;
}

fn measureThroughput(allocator: std.mem.Allocator) !u64 {
    var results = [_]?zigcss.CompileResult{null} ** throughput_operation_count;
    defer for (&results) |*result| {
        if (result.*) |*owned| owned.deinit();
    };

    var timer = try std.time.Timer.start();
    var index: usize = 0;
    for (0..throughput_iterations) |_| {
        for (corpora) |corpus| {
            results[index] = try compile(allocator, corpus, false);
            index += 1;
        }
    }
    const duration_ns = timer.read();
    if (duration_ns == 0 or index != throughput_operation_count) {
        return error.InvalidBenchmarkDuration;
    }

    index = 0;
    for (0..throughput_iterations) |_| {
        for (corpora) |corpus| {
            if (results[index]) |*result| {
                try validateCompileResult(allocator, corpus, result);
            } else {
                return error.MissingBenchmarkOutput;
            }
            index += 1;
        }
    }
    var input_bytes: u128 = 0;
    for (corpora) |corpus| input_bytes += corpus.css.len;
    input_bytes *= throughput_iterations;
    const rate = input_bytes * std.time.ns_per_s / duration_ns;
    if (rate == 0 or rate > std.math.maxInt(u64)) return error.InvalidBenchmarkThroughput;
    return @intCast(rate);
}

fn validateOutput(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    output: []const u8,
) !void {
    if (input.len == 0) return error.InvalidBenchmarkInput;
    if (output.len == 0) return error.InvalidBenchmarkOutput;

    var expected = try zigcss.css.pipeline.parse(allocator, name, input);
    defer expected.deinit();
    if (expected.hasErrors()) return error.InvalidBenchmarkInput;

    var actual = try zigcss.css.pipeline.parse(allocator, "benchmark-output.css", output);
    defer actual.deinit();
    if (actual.hasErrors()) return error.InvalidBenchmarkOutput;

    if (!try zigcss.css.equivalence.equivalent(
        allocator,
        expected.file(),
        expected.rules,
        actual.file(),
        actual.rules,
    )) return error.BenchmarkOutputMismatch;
}

test "benchmark output validation accepts equivalent public compiler output" {
    const input = ".component-0000{color:#aabbcc;background:#112233;padding:0px 0px;margin:0px;border-radius:0px}\n";
    var result = try zigcss.compile(std.testing.allocator, "valid.css", input, .{
        .format = .minified,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try validateOutput(std.testing.allocator, "valid.css", input, result.css);
}

test "benchmark output validation rejects malformed and changed output" {
    const input = ".component-0000{color:red;background:white;padding:1px;margin:2px;border-radius:3px}\n";

    try std.testing.expectError(
        error.InvalidBenchmarkOutput,
        validateOutput(std.testing.allocator, "invalid.css", input, ".component-0000{color:red"),
    );
    try std.testing.expectError(
        error.BenchmarkOutputMismatch,
        validateOutput(
            std.testing.allocator,
            "changed.css",
            input,
            ".component-0000{color:blue;background:white;padding:1px;margin:2px;border-radius:3px}",
        ),
    );
}
