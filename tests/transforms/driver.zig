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
    selector_rule_merge,
    at_rule_merge,
    target_prefix_rewrite,
    dead_code_extraction,
    critical_css_extraction,
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
    var targets: ?[]const u8 = null;
    var complete_classes = false;
    var complete_ids = false;
    var known_classes = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer known_classes.deinit(allocator);
    var known_ids = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer known_ids.deinit(allocator);
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
        if (std.mem.eql(u8, argument, "--targets")) {
            if (targets != null) return invalidArguments("duplicate --targets argument", .{});
            index += 1;
            if (index >= args.len) return invalidArguments("--targets requires a value", .{});
            targets = args[index];
            continue;
        }
        if (std.mem.eql(u8, argument, "--complete-classes")) {
            if (complete_classes) return invalidArguments("duplicate --complete-classes argument", .{});
            complete_classes = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--complete-ids")) {
            if (complete_ids) return invalidArguments("duplicate --complete-ids argument", .{});
            complete_ids = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--known-class")) {
            index += 1;
            if (index >= args.len) return invalidArguments("--known-class requires a value", .{});
            try known_classes.append(allocator, args[index]);
            continue;
        }
        if (std.mem.eql(u8, argument, "--known-id")) {
            index += 1;
            if (index >= args.len) return invalidArguments("--known-id requires a value", .{});
            try known_ids.append(allocator, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--")) {
            return invalidArguments("unknown argument: {s}", .{argument});
        }
        if (input_path != null) return invalidArguments("multiple input files", .{});
        input_path = argument;
    }
    const input = input_path orelse return invalidArguments(
        "usage: zigcss-transform-test-driver <input.css> [--pass <none|empty-rule-cleanup|typed-color-zero-shortening|numeric-math-folding|margin-shorthand-synthesis|adjacent-selector-rule-merge|adjacent-at-rule-merge|target-prefix-rewrite|conservative-dead-code-extraction|conservative-critical-css-extraction>] [--targets <query>] [--complete-classes [--known-class <name>]...] [--complete-ids [--known-id <name>]...] [--minify]",
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

    const extraction_requested = requested_pass == .dead_code_extraction or
        requested_pass == .critical_css_extraction;
    if (known_classes.items.len != 0 and !complete_classes) {
        return invalidArguments("--known-class requires --complete-classes", .{});
    }
    if (known_ids.items.len != 0 and !complete_ids) {
        return invalidArguments("--known-id requires --complete-ids", .{});
    }
    const has_extraction_arguments = complete_classes or complete_ids or
        known_classes.items.len != 0 or known_ids.items.len != 0;

    if (requested_pass == .target_prefix_rewrite) {
        if (has_extraction_arguments) {
            return invalidArguments("inventory arguments require an extraction pass", .{});
        }
        const target_input = targets orelse return invalidArguments(
            "target-prefix-rewrite requires --targets",
            .{},
        );
        const target_result = try zigcss.prefixing.target_query.parse(allocator, target_input, .{});
        var target_query = switch (target_result) {
            .query => |value| value,
            .invalid => |failure| return invalidArguments(
                "invalid target query at byte {d}: {s}",
                .{ failure.offset, @tagName(failure.kind) },
            ),
        };
        defer target_query.deinit();
        const config = try zigcss.prefixing.rewrite.Configuration.init(allocator, &target_query);
        const registry = [_]zigcss.transform.pass_manager.Pass{
            zigcss.prefixing.rewrite.definition(&config),
        };
        var plan = try zigcss.transform.pass_manager.buildPlan(
            allocator,
            &registry,
            &.{zigcss.prefixing.rewrite.id},
            .{ .allow_compatibility_rewrite = true },
        );
        defer plan.deinit();
        try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    } else if (extraction_requested) {
        if (targets != null) return invalidArguments("--targets requires target-prefix-rewrite", .{});
        if (!complete_classes and !complete_ids) {
            return invalidArguments("extraction requires at least one complete inventory category", .{});
        }
        var config = zigcss.transform.selector_extraction.Configuration.init(
            allocator,
            if (requested_pass == .dead_code_extraction) .dead_code else .critical_css,
            .{
                .classes = if (complete_classes) known_classes.items else null,
                .ids = if (complete_ids) known_ids.items else null,
            },
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalidArguments("invalid extraction inventory: {s}", .{@errorName(err)}),
        };
        defer config.deinit();
        const registry = [_]zigcss.transform.pass_manager.Pass{
            zigcss.transform.selector_extraction.definition(&config),
        };
        var plan = try zigcss.transform.pass_manager.buildPlan(
            allocator,
            &registry,
            &.{config.passId()},
            .{ .allow_extraction = true, .allow_experimental = true },
        );
        defer plan.deinit();
        try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    } else if (requested_pass != .none) {
        if (has_extraction_arguments) {
            return invalidArguments("inventory arguments require an extraction pass", .{});
        }
        if (targets != null) return invalidArguments("--targets requires target-prefix-rewrite", .{});
        const registry = [_]zigcss.transform.pass_manager.Pass{
            zigcss.transform.empty_cleanup.definition(),
            zigcss.transform.color_zero_shortening.definition(),
            zigcss.transform.math_folding.definition(),
            zigcss.transform.duplicate_declarations.definition(),
            zigcss.transform.shorthand_synthesis.definition(),
            zigcss.transform.selector_rule_merge.definition(),
            zigcss.transform.at_rule_merge.definition(),
        };
        const requested_ids = [_][]const u8{switch (requested_pass) {
            .none => unreachable,
            .empty_cleanup => zigcss.transform.empty_cleanup.id,
            .color_zero_shortening => zigcss.transform.color_zero_shortening.id,
            .math_folding => zigcss.transform.math_folding.id,
            .shorthand_synthesis => zigcss.transform.shorthand_synthesis.id,
            .selector_rule_merge => zigcss.transform.selector_rule_merge.id,
            .at_rule_merge => zigcss.transform.at_rule_merge.id,
            .target_prefix_rewrite => unreachable,
            .dead_code_extraction, .critical_css_extraction => unreachable,
        }};
        const policy: zigcss.transform.pass_manager.Policy = switch (requested_pass) {
            .none => unreachable,
            .empty_cleanup => .{ .allow_lossless_cleanup = true },
            .color_zero_shortening => .{ .allow_semantic_rewrite = true },
            .math_folding => .{ .allow_semantic_rewrite = true },
            .shorthand_synthesis => .{ .allow_semantic_rewrite = true },
            .selector_rule_merge => .{ .allow_semantic_rewrite = true },
            .at_rule_merge => .{ .allow_semantic_rewrite = true },
            .target_prefix_rewrite => unreachable,
            .dead_code_extraction, .critical_css_extraction => unreachable,
        };
        var plan = try zigcss.transform.pass_manager.buildPlan(
            allocator,
            &registry,
            &requested_ids,
            policy,
        );
        defer plan.deinit();
        try parsed.applyPassPlan(allocator, &plan, .{ .verify_idempotence = true });
    } else {
        if (targets != null) return invalidArguments("--targets requires target-prefix-rewrite", .{});
        if (has_extraction_arguments) {
            return invalidArguments("inventory arguments require an extraction pass", .{});
        }
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
    if (std.mem.eql(u8, value, zigcss.transform.selector_rule_merge.id)) return .selector_rule_merge;
    if (std.mem.eql(u8, value, zigcss.transform.at_rule_merge.id)) return .at_rule_merge;
    if (std.mem.eql(u8, value, zigcss.prefixing.rewrite.id)) return .target_prefix_rewrite;
    if (std.mem.eql(u8, value, zigcss.transform.selector_extraction.dead_code_id)) {
        return .dead_code_extraction;
    }
    if (std.mem.eql(u8, value, zigcss.transform.selector_extraction.critical_css_id)) {
        return .critical_css_extraction;
    }
    return null;
}

fn invalidArguments(comptime format: []const u8, arguments: anytype) Error {
    std.debug.print(format ++ "\n", arguments);
    return error.InvalidArguments;
}
