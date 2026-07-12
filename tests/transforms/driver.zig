const std = @import("std");
const zigcss = @import("zigcss");

const Error = error{
    InvalidArguments,
    ParseFailed,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: zigcss-transform-test-driver <input.css> [--minify]\n", .{});
        return error.InvalidArguments;
    }
    const minified = args.len == 3 and std.mem.eql(u8, args[2], "--minify");
    if (args.len == 3 and !minified) {
        std.debug.print("unknown argument: {s}\n", .{args[2]});
        return error.InvalidArguments;
    }

    const input = try std.fs.cwd().readFileAlloc(allocator, args[1], 8 * 1024 * 1024);
    defer allocator.free(input);
    var parsed = try zigcss.css.pipeline.parse(allocator, args[1], input);
    defer parsed.deinit();
    if (parsed.hasErrors()) {
        const formatted = try parsed.formatDiagnostics(allocator);
        defer allocator.free(formatted);
        std.debug.print("{s}", .{formatted});
        return error.ParseFailed;
    }

    const registry = [_]zigcss.transform.pass_manager.Pass{
        zigcss.transform.empty_cleanup.definition(),
    };
    var plan = try zigcss.transform.pass_manager.buildPlan(
        allocator,
        &registry,
        &.{zigcss.transform.empty_cleanup.id},
        .{ .allow_lossless_cleanup = true },
    );
    defer plan.deinit();
    try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(allocator, .{
        .mode = if (minified) .minified else .pretty,
    });
    defer result.deinit();
    const stdout_file = std.fs.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    try stdout_writer.interface.writeAll(result.css);
    try stdout_writer.interface.flush();
}
