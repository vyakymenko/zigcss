const std = @import("std");
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

const TimedCompile = struct {
    result: zigcss.CompileResult,
    duration_ns: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

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
        if (memory.total_allocated_bytes == 0 or
            memory.total_allocated_bytes < memory.total_freed_bytes or
            memory.total_allocated_bytes - memory.total_freed_bytes != memory.retained_result_bytes or
            memory.peak_live_bytes < memory.retained_result_bytes or
            memory.allocation_count == 0)
        {
            return error.InvalidBenchmarkMemoryMetrics;
        }
        observations += 1;
    }
    return observations;
}

fn smokeInProcessThroughput(allocator: std.mem.Allocator) !usize {
    for (corpora) |corpus| {
        for (0..api_warmup_iterations) |_| {
            var warmup = try compile(allocator, corpus, false);
            defer warmup.deinit();
            try validateCompileResult(allocator, corpus, &warmup);
        }
    }

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
    return 1;
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
