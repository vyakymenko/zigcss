const std = @import("std");
const zigcss = @import("zigcss");

const Error = error{
    InvalidArguments,
    ParseFailed,
};

const RequestedPass = enum {
    none,
    empty_cleanup,
    color_zero_shortening,
    math_folding,
    shorthand_synthesis,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var input_path: ?[]const u8 = null;
    var requested_pass: RequestedPass = .empty_cleanup;
    var pass_was_set = false;
    var minified = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--minify")) {
            if (minified) return invalidArguments("duplicate --minify argument", .{});
            minified = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--pass")) {
            if (pass_was_set) return invalidArguments("duplicate --pass argument", .{});
            index += 1;
            if (index >= args.len) return invalidArguments("--pass requires a value", .{});
            requested_pass = parsePass(args[index]) orelse {
                return invalidArguments("unknown pass: {s}", .{args[index]});
            };
            pass_was_set = true;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--")) {
            return invalidArguments("unknown argument: {s}", .{argument});
        }
        if (input_path != null) return invalidArguments("multiple input files", .{});
        input_path = argument;
    }
    const input = input_path orelse return invalidArguments(
        "usage: zigcss-transform-test-driver <input.css> [--pass <none|empty-rule-cleanup|typed-color-zero-shortening|numeric-math-folding|margin-shorthand-synthesis>] [--minify]",
        .{},
    );

    const source = try std.fs.cwd().readFileAlloc(allocator, input, 8 * 1024 * 1024);
    defer allocator.free(source);
    var parsed = try zigcss.css.pipeline.parse(allocator, input, source);
    defer parsed.deinit();
    if (parsed.hasErrors()) {
        const formatted = try parsed.formatDiagnostics(allocator);
        defer allocator.free(formatted);
        std.debug.print("{s}", .{formatted});
        return error.ParseFailed;
    }

    const registry = [_]zigcss.transform.pass_manager.Pass{
        zigcss.transform.empty_cleanup.definition(),
        zigcss.transform.color_zero_shortening.definition(),
        zigcss.transform.math_folding.definition(),
        zigcss.transform.duplicate_declarations.definition(),
        zigcss.transform.shorthand_synthesis.definition(),
    };
    if (requested_pass != .none) {
        const requested_ids = [_][]const u8{switch (requested_pass) {
            .none => unreachable,
            .empty_cleanup => zigcss.transform.empty_cleanup.id,
            .color_zero_shortening => zigcss.transform.color_zero_shortening.id,
            .math_folding => zigcss.transform.math_folding.id,
            .shorthand_synthesis => zigcss.transform.shorthand_synthesis.id,
        }};
        const policy: zigcss.transform.pass_manager.Policy = switch (requested_pass) {
            .none => unreachable,
            .empty_cleanup => .{ .allow_lossless_cleanup = true },
            .color_zero_shortening => .{ .allow_semantic_rewrite = true },
            .math_folding => .{ .allow_semantic_rewrite = true },
            .shorthand_synthesis => .{ .allow_semantic_rewrite = true },
        };
        var plan = try zigcss.transform.pass_manager.buildPlan(
            allocator,
            &registry,
            &requested_ids,
            policy,
        );
        defer plan.deinit();
        try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    }

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

fn parsePass(value: []const u8) ?RequestedPass {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, zigcss.transform.empty_cleanup.id)) return .empty_cleanup;
    if (std.mem.eql(u8, value, zigcss.transform.color_zero_shortening.id)) return .color_zero_shortening;
    if (std.mem.eql(u8, value, zigcss.transform.math_folding.id)) return .math_folding;
    if (std.mem.eql(u8, value, zigcss.transform.shorthand_synthesis.id)) return .shorthand_synthesis;
    return null;
}

fn invalidArguments(comptime format: []const u8, arguments: anytype) Error {
    std.debug.print(format ++ "\n", arguments);
    return error.InvalidArguments;
}
