const std = @import("std");
const zigcss = @import("zigcss");

const small_css = @embedFile("benchmark-small-css");
const medium_css = @embedFile("benchmark-medium-css");
const large_css = @embedFile("benchmark-large-css");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const corpora = [_]struct {
        name: []const u8,
        css: []const u8,
    }{
        .{ .name = "small-flat.css", .css = small_css },
        .{ .name = "medium-flat.css", .css = medium_css },
        .{ .name = "large-flat.css", .css = large_css },
    };

    for (corpora) |corpus| {
        var result = try zigcss.compile(allocator, corpus.name, corpus.css, .{
            .format = .minified,
        });
        defer result.deinit();
        if (result.diagnostics.len != 0 or result.css.len == 0) {
            return error.InvalidBenchmarkOutput;
        }
        try validateOutput(allocator, corpus.name, corpus.css, result.css);
        std.debug.print(
            "Validated {s}: {d} input bytes -> {d} output bytes; no timing sample accepted.\n",
            .{ corpus.name, corpus.css.len, result.css.len },
        );
    }
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
