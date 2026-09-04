const std = @import("std");
const preprocessor = @import("native_preprocessor");
const source = preprocessor.source;
const syntax = preprocessor.syntax;
const value = preprocessor.value;
const environment = preprocessor.environment;
const budget = preprocessor.budget;
const diagnostics = preprocessor.diagnostics;
const sourcemap = preprocessor.sourcemap;

test "source table owns deterministic identities spans and UTF-16 positions" {
    var table = source.Table.init(std.testing.allocator, .{});
    defer table.deinit();

    var name = [_]u8{ 'a', '.', 's', 'c', 's', 's' };
    var bytes = [_]u8{ 'a', 0xf0, 0x9f, 0x98, 0x80, '\r', '\n', 'b' };
    const first = try table.add(&name, &bytes);
    const second = try table.add("b.less", "x");
    name[0] = 'z';
    bytes[0] = 'z';

    try std.testing.expectEqual(@as(u32, 0), first.value);
    try std.testing.expectEqual(@as(u32, 1), second.value);
    try std.testing.expectEqualStrings("a.scss", (try table.get(first)).name);
    try std.testing.expectEqualStrings("a😀\r\nb", (try table.get(first)).bytes);
    try std.testing.expect((table.findByName("a.scss") orelse unreachable).id.eql(first));
    try std.testing.expect((table.findByName("b.less") orelse unreachable).id.eql(second));
    try std.testing.expect(table.findByName("z.scss") == null);
    try std.testing.expectEqual(
        source.Position{ .line = 0, .column = 3 },
        try table.position(first, 5),
    );
    try std.testing.expectEqual(
        source.Position{ .line = 1, .column = 0 },
        try table.position(first, 7),
    );

    const span = try table.span(first, 1, 5);
    try std.testing.expectEqual(@as(u32, 4), span.len());
    try std.testing.expectEqualStrings("😀", try table.slice(span));
    try std.testing.expectError(error.DuplicateSource, table.add("a.scss", "other"));
    try std.testing.expectError(
        error.InvalidSpan,
        table.validateSpan(.{ .source = first, .start = 5, .end = 4 }),
    );
}

test "source name index owns exact wide lookups and rejects duplicates" {
    const source_count: usize = 1_024;
    var table = source.Table.init(std.testing.allocator, .{});
    defer table.deinit();

    var name_buffer: [64]u8 = undefined;
    var payload_buffer: [64]u8 = undefined;
    for (0..source_count) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "source-{d}.scss", .{index});
        const payload = try std.fmt.bufPrint(&payload_buffer, "value-{d}", .{index});
        const id = try table.add(name, payload);
        try std.testing.expectEqual(@as(u32, @intCast(index)), id.value);

        // Every call reuses and poisons the caller buffers. Both the table and
        // its hash keys must therefore be backed only by committed owned names.
        @memset(name_buffer[0..name.len], 0xaa);
        @memset(payload_buffer[0..payload.len], 0xbb);
    }
    try std.testing.expectEqual(source_count, table.count());

    var index = source_count;
    while (index > 0) {
        index -= 1;
        const name = try std.fmt.bufPrint(&name_buffer, "source-{d}.scss", .{index});
        const expected_payload = try std.fmt.bufPrint(&payload_buffer, "value-{d}", .{index});
        const file = table.findByName(name) orelse return error.MissingIndexedSource;
        try std.testing.expectEqual(@as(u32, @intCast(index)), file.id.value);
        try std.testing.expectEqualStrings(name, file.name);
        try std.testing.expectEqualStrings(expected_payload, file.bytes);
    }

    for ([_]usize{ 0, source_count / 2, source_count - 1 }) |duplicate_index| {
        const name = try std.fmt.bufPrint(&name_buffer, "source-{d}.scss", .{duplicate_index});
        try std.testing.expectError(error.DuplicateSource, table.add(name, "replacement"));
    }
    try std.testing.expectEqual(source_count, table.count());
    try std.testing.expect(table.findByName("source-1") == null);
    try std.testing.expect(table.findByName("Source-1.scss") == null);
    try std.testing.expect(table.findByName("source-1024.scss") == null);
}

test "source ownership limits fail before partial admission" {
    var table = source.Table.init(std.testing.allocator, .{
        .max_sources = 1,
        .max_owned_bytes = 4,
    });
    defer table.deinit();
    _ = try table.add("a", "123");
    // Duplicate detection retains its established precedence over capacity.
    try std.testing.expectError(error.DuplicateSource, table.add("a", "replacement"));
    try std.testing.expectError(error.SourceLimitExceeded, table.add("b", ""));
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expect(table.findByName("a") != null);
    try std.testing.expect(table.findByName("b") == null);

    var bytes = source.Table.init(std.testing.allocator, .{ .max_owned_bytes = 2 });
    defer bytes.deinit();
    try std.testing.expectError(error.SourceLimitExceeded, bytes.add("a", "12"));
    try std.testing.expectEqual(@as(usize, 0), bytes.count());
    try std.testing.expect(bytes.findByName("a") == null);
    const admitted = try bytes.add("a", "1");
    try std.testing.expectEqual(@as(u32, 0), admitted.value);
    try std.testing.expect((bytes.findByName("a") orelse unreachable).id.eql(admitted));
}

test "source name index rolls back every allocation failure without stale keys" {
    const source_count: usize = 64;
    var failure_index: usize = 0;
    var completed = false;

    while (failure_index < 1_024) : (failure_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = failure_index,
        });
        var table = source.Table.init(failing.allocator(), .{});
        defer table.deinit();

        var name_buffer: [64]u8 = undefined;
        var lookup_buffer: [64]u8 = undefined;
        var induced = false;
        for (0..source_count) |index| {
            const name = try std.fmt.bufPrint(&name_buffer, "oom-{d}.scss", .{index});
            const admission = table.add(name, "payload");
            if (admission) |id| {
                try std.testing.expectEqual(@as(u32, @intCast(index)), id.value);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(index, table.count());
                try std.testing.expect(table.findByName(name) == null);

                for (0..index) |committed_index| {
                    const committed_name = try std.fmt.bufPrint(
                        &lookup_buffer,
                        "oom-{d}.scss",
                        .{committed_index},
                    );
                    const committed = table.findByName(committed_name) orelse
                        return error.MissingCommittedSource;
                    try std.testing.expectEqual(
                        @as(u32, @intCast(committed_index)),
                        committed.id.value,
                    );
                }

                // Permit future allocations and retry the exact failed name.
                // A partially committed hash key would now report a duplicate.
                failing.fail_index = std.math.maxInt(usize);
                const retried = try table.add(name, "payload");
                try std.testing.expectEqual(@as(u32, @intCast(index)), retried.value);
                try std.testing.expect((table.findByName(name) orelse unreachable).id.eql(retried));
                try std.testing.expectError(error.DuplicateSource, table.add(name, "other"));
                induced = true;
                break;
            }
        }

        if (!induced) {
            try std.testing.expect(!failing.has_induced_failure);
            try std.testing.expectEqual(source_count, table.count());
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}

test "syntax builder produces an immutable acyclic depth-bounded document" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "$x: 1;");
    const all = try sources.span(source_id, 0, 6);
    const name = try sources.span(source_id, 0, 2);
    const number = try sources.span(source_id, 4, 5);

    var builder = syntax.Builder.init(std.testing.allocator, &sources, .{});
    defer builder.deinit();
    const variable_node = try builder.add(.variable, name, name, &.{});
    const number_node = try builder.add(.literal, number, number, &.{});
    const declaration = try builder.add(
        .declaration,
        all,
        null,
        &.{ variable_node, number_node },
    );
    var document = try builder.finish(declaration);
    defer document.deinit();

    try std.testing.expectEqual(syntax.Kind.declaration, (try document.get(document.root)).kind);
    const children = try document.children(document.root);
    try std.testing.expectEqualSlices(
        syntax.NodeId,
        &.{ variable_node, number_node },
        children,
    );
    try std.testing.expectEqual(@as(u16, 2), (try document.get(document.root)).depth);
    try std.testing.expectError(error.UnknownNode, document.get(.{ .value = 99 }));
}

test "syntax rejects forged spans forward edges and resource depth" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "abc");
    const span = try sources.span(source_id, 0, 1);

    var builder = syntax.Builder.init(std.testing.allocator, &sources, .{
        .max_nodes = 2,
        .max_edges = 1,
        .max_depth = 1,
    });
    defer builder.deinit();
    const leaf = try builder.add(.identifier, span, span, &.{});
    try std.testing.expectError(
        error.SyntaxDepthExceeded,
        builder.add(.expression, span, null, &.{leaf}),
    );
    try std.testing.expectError(
        error.UnknownNode,
        builder.add(.expression, span, null, &.{.{ .value = 9 }}),
    );
    try std.testing.expectError(
        error.InvalidSpan,
        builder.add(
            .identifier,
            .{ .source = source_id, .start = 2, .end = 5 },
            null,
            &.{},
        ),
    );
}

test "typed values are deeply owned immutable and structurally comparable" {
    var store = value.Store.init(std.testing.allocator, .{});
    defer store.deinit();

    var text = [_]u8{ '1', '0', 'p', 'x' };
    var unit = [_]u8{ 'p', 'x' };
    const units = [_][]const u8{&unit};
    var items = [_]value.Value{
        .{ .string = .{ .bytes = &text, .quoted = true } },
        .{ .number = .{ .value = 10, .numerator_units = &units } },
        .{ .boolean = true },
    };
    const input = value.Value{ .list = .{
        .items = &items,
        .separator = .space,
        .bracketed = false,
    } };
    const owned = try store.own(input);
    text[0] = '9';
    unit[0] = 'e';
    items[2] = .{ .boolean = false };

    try std.testing.expect(value.eql(owned.*, value.Value{ .list = .{
        .items = &.{
            .{ .string = .{ .bytes = "10px", .quoted = true } },
            .{ .number = .{ .value = 10, .numerator_units = &.{"px"} } },
            .{ .boolean = true },
        },
        .separator = .space,
        .bracketed = false,
    } }));
    try std.testing.expect(!value.eql(owned.*, input));

    const signed_zero = try store.own(.{ .number = .{ .value = -0.0 } });
    try std.testing.expect(std.math.signbit(signed_zero.number.value));

    const authored_color = value.Value{ .color = .{
        .space = .oklab,
        .channels = .{ 0.5, -0.04, 0.08, 1 },
    } };
    const computed_color = value.Value{ .color = .{
        .space = .oklab,
        .channels = .{ 0.5, -0.04, 0.08, 1 },
        .computed = true,
    } };
    try std.testing.expect(value.eql(authored_color, computed_color));
}

test "typed Sass argument lists deeply own positional keyword and usage state" {
    var store = value.Store.init(std.testing.allocator, .{});
    defer store.deinit();

    var state = value.ArgumentListState{};
    var keyword_name = [_]u8{ 'e', 'n', 'd', '-', 'a', 't' };
    var positional = [_]value.Value{.{ .number = .{ .value = 2 } }};
    var keywords = [_]value.ArgumentKeyword{.{
        .name = &keyword_name,
        .value = .{ .number = .{ .value = 3 } },
        .normalize_name = true,
    }};
    const owned = try store.own(.{ .argument_list = .{
        .positional = &positional,
        .keywords = &keywords,
        .state = &state,
    } });
    state.keywords_accessed = true;
    keyword_name[0] = 'x';
    positional[0] = .{ .number = .{ .value = 9 } };
    keywords[0].value = .{ .number = .{ .value = 8 } };

    const argument_list = owned.argument_list;
    try std.testing.expect(!argument_list.state.keywords_accessed);
    try std.testing.expectEqual(@as(usize, 1), argument_list.positional.len);
    try std.testing.expectEqual(@as(f64, 2), argument_list.positional[0].number.value);
    try std.testing.expectEqualStrings("end-at", argument_list.keywords[0].name);
    try std.testing.expectEqual(@as(f64, 3), argument_list.keywords[0].value.number.value);
    argument_list.state.keywords_accessed = true;
    try std.testing.expect(argument_list.state.keywords_accessed);
}

test "typed values reject invalid numbers and bounded recursive growth" {
    var store = value.Store.init(std.testing.allocator, .{ .max_values = 2 });
    defer store.deinit();
    try std.testing.expectError(
        error.InvalidValue,
        store.own(.{ .number = .{ .value = std.math.nan(f64) } }),
    );
    try std.testing.expectError(
        error.ValueLimitExceeded,
        store.own(.{ .list = .{ .items = &.{
            .{ .boolean = true },
            .{ .boolean = false },
        } } }),
    );
}

test "persistent lexical environments preserve snapshots and shadow deterministically" {
    var store = value.Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const one = try store.own(.{ .number = .{ .value = 1 } });
    const two = try store.own(.{ .number = .{ .value = 2 } });

    var env = try environment.Environment.init(std.testing.allocator, .{});
    defer env.deinit();
    const root = env.root();
    const defined = try env.define(root, "x", one);
    const child = try env.push(defined);
    const shadowed = try env.define(child, "x", two);

    try std.testing.expect((try env.lookup(defined, "x")).? == one);
    try std.testing.expect((try env.lookupLocal(defined, "x")).? == one);
    try std.testing.expect((try env.lookupNonGlobal(defined, "x")) == null);
    try std.testing.expect((try env.lookup(child, "x")).? == one);
    try std.testing.expect((try env.lookupLocal(child, "x")) == null);
    try std.testing.expect((try env.lookupNonGlobal(child, "x")) == null);
    try std.testing.expect((try env.lookup(shadowed, "x")).? == two);
    try std.testing.expect((try env.lookupLocal(shadowed, "x")).? == two);
    try std.testing.expect((try env.lookupNonGlobal(shadowed, "x")).? == two);
    try std.testing.expectEqual(defined, try env.pop(shadowed));
    try std.testing.expectError(error.DuplicateBinding, env.define(defined, "x", two));
    try std.testing.expectError(error.RootScope, env.pop(defined));

    const rebound = try env.set(defined, "x", two);
    try std.testing.expect((try env.lookup(rebound, "x")).? == two);
    try std.testing.expect((try env.lookup(defined, "x")).? == one);
}

test "lexical environment enforces scope binding and name budgets" {
    var store = value.Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const item = try store.own(.null_value);
    var env = try environment.Environment.init(std.testing.allocator, .{
        .max_scope_depth = 0,
        .max_bindings = 1,
        .max_name_bytes = 32,
    });
    defer env.deinit();

    try std.testing.expectError(error.ScopeLimitExceeded, env.push(env.root()));
    const bound = try env.define(env.root(), "x", item);
    try std.testing.expectError(error.BindingLimitExceeded, env.define(bound, "y", item));

    var names = try environment.Environment.init(std.testing.allocator, .{
        .max_name_bytes = 1,
    });
    defer names.deinit();
    try std.testing.expectError(error.NameLimitExceeded, names.set(names.root(), "long", item));
}

test "evaluation budget owns independent monotonic ceilings" {
    var limits = budget.Budget.init(.{
        .max_call_depth = 2,
        .max_calls = 2,
        .max_operations = 3,
        .max_loop_iterations = 2,
        .max_output_bytes = 4,
        .max_diagnostics = 1,
    });
    try limits.enterCall();
    try limits.enterCall();
    try std.testing.expectError(error.CallDepthExceeded, limits.enterCall());
    limits.leaveCall();
    limits.leaveCall();
    try std.testing.expectError(error.CallCountExceeded, limits.enterCall());
    try limits.consumeOperations(3);
    try std.testing.expectError(error.OperationLimitExceeded, limits.consumeOperations(1));
    try limits.consumeLoopIterations(2);
    try std.testing.expectError(error.LoopLimitExceeded, limits.consumeLoopIterations(1));
    try limits.reserveOutput(4);
    try std.testing.expectError(error.OutputLimitExceeded, limits.reserveOutput(1));
    try limits.reserveDiagnostic();
    try std.testing.expectError(error.DiagnosticLimitExceeded, limits.reserveDiagnostic());
}

test "diagnostics own ordered structured messages and related spans" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "$x");
    const span = try sources.span(source_id, 0, 2);
    var list = diagnostics.List.init(std.testing.allocator, &sources, .{});
    defer list.deinit();

    var message = [_]u8{ 'b', 'a', 'd' };
    var label = [_]u8{ 'h', 'e', 'r', 'e' };
    try list.append(.err, .undefined_variable, span, &message, &.{.{
        .span = span,
        .label = &label,
    }});
    message[0] = 'x';
    label[0] = 'x';

    try std.testing.expectEqual(@as(usize, 1), list.items().len);
    try std.testing.expectEqualStrings("NATIVE0002", list.items()[0].code.label());
    try std.testing.expectEqualStrings("bad", list.items()[0].message);
    try std.testing.expectEqualStrings("here", list.items()[0].related[0].label);
}

test "diagnostics reject invalid bytes spans and aggregate limits without partial entries" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "x");
    const span = try sources.span(source_id, 0, 1);
    var list = diagnostics.List.init(std.testing.allocator, &sources, .{
        .max_diagnostics = 1,
        .max_message_bytes = 4,
        .max_owned_bytes = 8,
    });
    defer list.deinit();

    try std.testing.expectError(
        error.InvalidDiagnostic,
        list.append(.err, .syntax, span, "bad\n", &.{}),
    );
    try std.testing.expectError(
        error.InvalidSpan,
        list.append(.err, .syntax, .{
            .source = source_id,
            .start = 0,
            .end = 2,
        }, "bad", &.{}),
    );
    try list.append(.err, .syntax, span, "bad", &.{});
    try std.testing.expectError(
        error.DiagnosticLimitExceeded,
        list.append(.note, .syntax, span, "next", &.{}),
    );
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
}

test "source-map primitives retain ordered multi-source UTF-16 mappings" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const first = try sources.add("a.scss", "a😀b");
    const second = try sources.add("b.less", "xy");
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{});
    defer builder.deinit();

    try builder.addMapped(.{ .line = 0, .column = 0 }, try sources.span(first, 5, 6), null);
    try builder.addUnmapped(.{ .line = 0, .column = 4 });
    try builder.addMapped(.{ .line = 1, .column = 0 }, try sources.span(second, 1, 2), "token");
    var map = try builder.finish();
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 3), map.segments().len);
    try std.testing.expectEqual(@as(u32, 3), map.segments()[0].original_column);
    try std.testing.expectEqualStrings("token", map.names()[0]);
    try std.testing.expectEqual(map.segments()[0], map.lookup(.{ .line = 0, .column = 2 }).?);
    try std.testing.expectEqual(map.segments()[1], map.lookup(.{ .line = 0, .column = 8 }).?);
    try std.testing.expect(map.lookup(.{ .line = 2, .column = 0 }) == null);
    const encoded = try map.encodeMappings(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len > 0);
}

test "source maps reject disorder invalid spans and segment limits" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("a.scss", "ab");
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{
        .max_segments = 1,
    });
    defer builder.deinit();
    try builder.addMapped(.{ .line = 1, .column = 1 }, try sources.span(source_id, 0, 1), null);
    try std.testing.expectError(
        error.InvalidGeneratedPosition,
        builder.addUnmapped(.{ .line = 0, .column = 0 }),
    );
    try std.testing.expectError(
        error.MappingLimitExceeded,
        builder.addUnmapped(.{ .line = 1, .column = 2 }),
    );
    try std.testing.expectError(
        error.InvalidSpan,
        builder.addMapped(.{ .line = 1, .column = 1 }, .{
            .source = source_id,
            .start = 0,
            .end = 3,
        }, null),
    );
}

test "source-map sparse positions bound reverse lookups on one adversarial wide line" {
    const source_bytes: usize = 64 * 1024;
    const mapping_count: usize = 4 * 1024;
    const step = source_bytes / mapping_count;
    const input = try std.testing.allocator.alloc(u8, source_bytes);
    defer std.testing.allocator.free(input);
    @memset(input, 'a');

    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("reverse.scss", input);
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{
        .max_segments = mapping_count,
    });
    defer builder.deinit();

    for (0..mapping_count) |index| {
        const original_offset = source_bytes - 1 - index * step;
        try builder.addMapped(
            .{ .line = 0, .column = @intCast(index) },
            try sources.span(
                source_id,
                @intCast(original_offset),
                @intCast(original_offset + 1),
            ),
            null,
        );
    }

    const stats = builder.positionIndexStats();
    try std.testing.expectEqual(@as(usize, 1), stats.indexed_sources);
    try std.testing.expectEqual(@as(u64, source_bytes), stats.indexed_source_bytes);
    try std.testing.expectEqual(
        source_bytes / sourcemap.position_checkpoint_stride,
        stats.checkpoints,
    );
    try std.testing.expect(
        stats.checkpoints <= stats.indexed_source_bytes / sourcemap.position_checkpoint_stride,
    );
    try std.testing.expect(
        stats.max_lookup_scan_bytes < sourcemap.position_checkpoint_stride,
    );
    try std.testing.expect(
        stats.lookup_scanned_bytes <=
            mapping_count * (sourcemap.position_checkpoint_stride - 1),
    );
    try std.testing.expectEqual(mapping_count, builder.segment_items.items.len);
    try std.testing.expectEqual(
        @as(u32, source_bytes - 1),
        builder.segment_items.items[0].original_column,
    );
    try std.testing.expectEqual(
        @as(u32, source_bytes - 1 - (mapping_count - 1) * step),
        builder.segment_items.items[mapping_count - 1].original_column,
    );
}

test "source-map sparse positions preserve Unicode boundaries around a checkpoint" {
    const input = ("a" ** 255) ++ "😀" ++ ("b" ** 300);
    const emoji_start: u32 = 255;
    const after_emoji: u32 = emoji_start + "😀".len;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("unicode.scss", input);
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{});
    defer builder.deinit();

    try builder.addMapped(
        .{ .line = 0, .column = 0 },
        try sources.span(source_id, emoji_start, emoji_start),
        null,
    );
    inline for (1.."😀".len) |inside| {
        const offset: u32 = emoji_start + inside;
        try std.testing.expectError(
            error.InvalidSpan,
            builder.addMapped(.{ .line = 0, .column = 1 }, .{
                .source = source_id,
                .start = offset,
                .end = offset,
            }, null),
        );
    }
    try builder.addMapped(
        .{ .line = 0, .column = 1 },
        try sources.span(source_id, after_emoji, after_emoji),
        null,
    );
    try builder.addMapped(
        .{ .line = 0, .column = 2 },
        try sources.span(source_id, input.len, input.len),
        null,
    );

    try std.testing.expectEqual(@as(u32, 255), builder.segment_items.items[0].original_column);
    try std.testing.expectEqual(@as(u32, 257), builder.segment_items.items[1].original_column);
    try std.testing.expectEqual(@as(u32, 557), builder.segment_items.items[2].original_column);
    const stats = builder.positionIndexStats();
    try std.testing.expectEqual(@as(usize, 1), stats.indexed_sources);
    try std.testing.expectEqual(@as(usize, 2), stats.checkpoints);
    try std.testing.expect(stats.max_lookup_scan_bytes < sourcemap.position_checkpoint_stride);
}

test "source-map sparse positions stay bounded across sources and survive finish reuse" {
    const first_input = "x" ** 600;
    const second_input = ("y" ** 257) ++ "\n" ++ ("z" ** 300);
    const short_input = "😀x";
    const indexed_bytes = first_input.len + second_input.len + short_input.len;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const first = try sources.add("first.scss", first_input);
    const second = try sources.add("second.less", second_input);
    const short = try sources.add("short.styl", short_input);
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{});
    defer builder.deinit();

    try builder.addMapped(
        .{ .line = 0, .column = 0 },
        try sources.span(first, 511, 512),
        null,
    );
    try builder.addMapped(
        .{ .line = 0, .column = 1 },
        try sources.span(second, 518, 519),
        null,
    );
    try builder.addMapped(
        .{ .line = 0, .column = 2 },
        try sources.span(short, 4, 5),
        null,
    );
    try std.testing.expectEqual(@as(u32, 511), builder.segment_items.items[0].original_column);
    try std.testing.expectEqual(@as(u32, 1), builder.segment_items.items[1].original_line);
    try std.testing.expectEqual(@as(u32, 260), builder.segment_items.items[1].original_column);
    try std.testing.expectEqual(@as(u32, 2), builder.segment_items.items[2].original_column);

    const before_finish = builder.positionIndexStats();
    try std.testing.expectEqual(@as(usize, 3), before_finish.indexed_sources);
    try std.testing.expectEqual(@as(u64, indexed_bytes), before_finish.indexed_source_bytes);
    try std.testing.expectEqual(@as(usize, 4), before_finish.checkpoints);
    try std.testing.expect(
        before_finish.checkpoints <=
            before_finish.indexed_source_bytes / sourcemap.position_checkpoint_stride,
    );
    var first_map = try builder.finish();
    defer first_map.deinit();

    try builder.addMapped(
        .{ .line = 0, .column = 0 },
        try sources.span(first, 599, 600),
        null,
    );
    const after_reuse = builder.positionIndexStats();
    try std.testing.expectEqual(before_finish.indexed_sources, after_reuse.indexed_sources);
    try std.testing.expectEqual(before_finish.indexed_source_bytes, after_reuse.indexed_source_bytes);
    try std.testing.expectEqual(before_finish.checkpoints, after_reuse.checkpoints);
    try std.testing.expect(after_reuse.lookup_scanned_bytes > before_finish.lookup_scanned_bytes);
    var second_map = try builder.finish();
    defer second_map.deinit();
    try std.testing.expectEqual(@as(u32, 599), second_map.segments()[0].original_column);
}

test "source-map sparse position admission rolls back every cache allocation failure" {
    const input = "a" ** 1024;
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("position-oom.scss", input);
    const original = try sources.span(source_id, 900, 901);
    const expected_checkpoints = input.len / sourcemap.position_checkpoint_stride;
    var failure_index: usize = 0;
    var completed = false;

    while (failure_index < 64) : (failure_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = failure_index,
        });
        var builder = sourcemap.Builder.init(failing.allocator(), &sources, .{});
        defer builder.deinit();

        const admission = builder.addMapped(.{ .line = 0, .column = 0 }, original, null);
        if (admission) |_| {
            try std.testing.expect(!failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 1), builder.segment_items.items.len);
            completed = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 0), builder.segment_items.items.len);
            const failed_stats = builder.positionIndexStats();
            try std.testing.expect(failed_stats.indexed_sources <= 1);
            if (failed_stats.indexed_sources == 0) {
                try std.testing.expectEqual(@as(usize, 0), failed_stats.checkpoints);
                try std.testing.expectEqual(@as(u64, 0), failed_stats.indexed_source_bytes);
            } else {
                try std.testing.expectEqual(expected_checkpoints, failed_stats.checkpoints);
                try std.testing.expectEqual(@as(u64, input.len), failed_stats.indexed_source_bytes);
            }

            failing.fail_index = std.math.maxInt(usize);
            try builder.addMapped(.{ .line = 0, .column = 0 }, original, null);
            try std.testing.expectEqual(@as(usize, 1), builder.segment_items.items.len);
            const retried_stats = builder.positionIndexStats();
            try std.testing.expectEqual(@as(usize, 1), retried_stats.indexed_sources);
            try std.testing.expectEqual(expected_checkpoints, retried_stats.checkpoints);
            try std.testing.expectEqual(@as(u64, input.len), retried_stats.indexed_source_bytes);
        }
    }
    try std.testing.expect(completed);
}

fn exerciseSourceMapPositionIndexAllocationFailures(allocator: std.mem.Allocator) !void {
    const first_input = ("a" ** 255) ++ "😀" ++ ("b" ** 300);
    const second_input = ("c" ** 512) ++ "\nshort";
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const first = try sources.add("position-first.scss", first_input);
    const second = try sources.add("position-second.less", second_input);
    var builder = sourcemap.Builder.init(allocator, &sources, .{});
    defer builder.deinit();

    try builder.addMapped(
        .{ .line = 0, .column = 0 },
        try sources.span(first, 259, 260),
        null,
    );
    try std.testing.expectError(
        error.InvalidSpan,
        builder.addMapped(.{ .line = 0, .column = 1 }, .{
            .source = first,
            .start = 256,
            .end = 256,
        }, null),
    );
    try builder.addMapped(
        .{ .line = 0, .column = 1 },
        try sources.span(second, 511, 512),
        "named",
    );
    const indexed = builder.positionIndexStats();
    try std.testing.expectEqual(@as(usize, 2), indexed.indexed_sources);
    try std.testing.expect(
        indexed.checkpoints <=
            indexed.indexed_source_bytes / sourcemap.position_checkpoint_stride,
    );

    var first_map = try builder.finish();
    defer first_map.deinit();
    try builder.addMapped(
        .{ .line = 0, .column = 0 },
        try sources.span(first, 558, 559),
        null,
    );
    const reused = builder.positionIndexStats();
    try std.testing.expectEqual(indexed.indexed_sources, reused.indexed_sources);
    try std.testing.expectEqual(indexed.checkpoints, reused.checkpoints);
    var second_map = try builder.finish();
    defer second_map.deinit();
}

test "source-map sparse position index handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSourceMapPositionIndexAllocationFailures,
        .{},
    );
}

test "source-map name index interns wide unique and repeated names once" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("wide.scss", "x");
    const span = try sources.span(source_id, 0, 1);
    const unique_name_count = 2_048;
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{
        .max_segments = unique_name_count * 2,
        .max_names = unique_name_count,
    });
    defer builder.deinit();

    try std.testing.expect(
        @TypeOf(builder.name_index) == std.StringHashMapUnmanaged(u32),
    );
    var name_buffer: [32]u8 = undefined;
    for (0..unique_name_count) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "token-{d}", .{index});
        try builder.addMapped(
            .{ .line = 0, .column = @intCast(index * 2) },
            span,
            name,
        );
        try builder.addMapped(
            .{ .line = 0, .column = @intCast(index * 2 + 1) },
            span,
            name,
        );
    }
    try std.testing.expectEqual(unique_name_count, builder.name_index.count());

    var map = try builder.finish();
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, unique_name_count), map.names().len);
    try std.testing.expectEqual(@as(usize, unique_name_count * 2), map.segments().len);
    for (0..unique_name_count) |index| {
        try std.testing.expectEqual(
            @as(u32, @intCast(index)),
            map.segments()[index * 2].name_id.?,
        );
        try std.testing.expectEqual(
            @as(u32, @intCast(index)),
            map.segments()[index * 2 + 1].name_id.?,
        );
    }
}

test "source-map checkpoint restore removes rolled-back name keys before re-add" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("restore.scss", "x");
    const span = try sources.span(source_id, 0, 1);
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{});
    defer builder.deinit();

    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "base");
    const saved = builder.checkpoint();
    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "rolled-back");
    try std.testing.expectEqual(@as(usize, 2), builder.name_index.count());
    try builder.restore(saved);
    try std.testing.expectEqual(@as(usize, 1), builder.name_index.count());
    try std.testing.expect(builder.name_index.get("rolled-back") == null);

    try builder.addMapped(.{ .line = 0, .column = 1 }, span, "rolled-back");
    var map = try builder.finish();
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 2), map.names().len);
    try std.testing.expectEqualStrings("base", map.names()[0]);
    try std.testing.expectEqualStrings("rolled-back", map.names()[1]);
    try std.testing.expectEqual(@as(u32, 0), map.segments()[0].name_id.?);
    try std.testing.expectEqual(@as(u32, 1), map.segments()[1].name_id.?);
}

test "source-map finish clears borrowed name index for safe builder reuse" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("reuse.scss", "x");
    const span = try sources.span(source_id, 0, 1);
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{});
    defer builder.deinit();

    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "shared");
    var first = try builder.finish();
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), builder.name_index.count());
    try std.testing.expectEqual(@as(usize, 0), builder.checkpoint().name_count);

    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "shared");
    var second = try builder.finish();
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.names().len);
    try std.testing.expectEqual(@as(usize, 1), second.names().len);
    try std.testing.expectEqualStrings("shared", first.names()[0]);
    try std.testing.expectEqualStrings("shared", second.names()[0]);
    try std.testing.expectEqual(@as(u32, 0), second.segments()[0].name_id.?);
}

test "source-map mapped append reserves segments before committing a name" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("transaction.scss", "x");
    const span = try sources.span(source_id, 0, 1);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var builder = sourcemap.Builder.init(failing.allocator(), &sources, .{});
    defer builder.deinit();

    const empty = builder.checkpoint();
    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "seed");
    try builder.restore(empty);
    const segment_capacity = builder.segment_items.capacity;
    try std.testing.expect(segment_capacity > 0);
    for (0..segment_capacity) |index| {
        try builder.addUnmapped(.{ .line = 0, .column = @intCast(index) });
    }
    const before = builder.checkpoint();

    // Force ArrayList growth to allocate, allow that allocation, then fail the
    // following owned-name allocation. With name interning before segment
    // reservation, this exact schedule leaves a partially committed name.
    failing.resize_fail_index = failing.resize_index;
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(
        error.OutOfMemory,
        builder.addMapped(
            .{ .line = 0, .column = @intCast(segment_capacity) },
            span,
            "must-not-commit",
        ),
    );
    try std.testing.expect(failing.has_induced_failure);
    const after = builder.checkpoint();
    try std.testing.expectEqual(before.segment_count, after.segment_count);
    try std.testing.expectEqual(before.name_count, after.name_count);
    try std.testing.expectEqual(before.name_bytes, after.name_bytes);
    try std.testing.expectEqual(before.last_segment, after.last_segment);
    try std.testing.expect(builder.name_index.get("must-not-commit") == null);
}

fn exerciseSourceMapNameIndexAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("allocation.scss", "x");
    const span = try sources.span(source_id, 0, 1);
    var builder = sourcemap.Builder.init(allocator, &sources, .{});
    defer builder.deinit();

    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "base");
    const saved = builder.checkpoint();
    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "temporary");
    try builder.restore(saved);
    try builder.addMapped(.{ .line = 0, .column = 1 }, span, "temporary");
    var first = try builder.finish();
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.names().len);

    try builder.addMapped(.{ .line = 0, .column = 0 }, span, "base");
    var second = try builder.finish();
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.names().len);
    try std.testing.expectEqualStrings("base", second.names()[0]);
}

test "source-map name index transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSourceMapNameIndexAllocationFailures,
        .{},
    );
}

test "source maps compose the bounded core stage over native multi-source mappings" {
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const first = try sources.add("a.scss", "a😀b");
    const second = try sources.add("b.scss", "xy");
    var builder = sourcemap.Builder.init(std.testing.allocator, &sources, .{});
    defer builder.deinit();
    try builder.addMapped(.{ .line = 0, .column = 0 }, try sources.span(first, 5, 6), null);
    try builder.addUnmapped(.{ .line = 0, .column = 4 });
    try builder.addMapped(.{ .line = 1, .column = 0 }, try sources.span(second, 1, 2), "token");
    var frontend = try builder.finish();
    defer frontend.deinit();

    const core =
        "{\"version\":3,\"sources\":[\"zigcss-native:///intermediate.css\"]," ++
        "\"sourcesContent\":[\"first line\\nsecond line\"],\"names\":[]," ++
        "\"mappings\":\"AAAA,IAAI;AACJ\"}";
    const composed = try sourcemap.composeCoreMap(
        std.testing.allocator,
        core,
        &frontend,
        &sources,
        .{ .intermediate_source = "zigcss-native:///intermediate.css" },
    );
    defer std.testing.allocator.free(composed);
    try std.testing.expectEqualStrings(
        "{\"version\":3,\"sources\":[\"a.scss\",\"b.scss\"]," ++
            "\"sourcesContent\":[\"a😀b\",\"xy\"],\"names\":[\"token\"]," ++
            "\"mappings\":\"AAAG,I;ACAFA\"}",
        composed,
    );

    const terminal = try sourcemap.composeCoreMap(
        std.testing.allocator,
        core,
        &frontend,
        &sources,
        .{
            .intermediate_source = "zigcss-native:///intermediate.css",
            .max_segments = 3,
            .max_output_bytes = composed.len,
        },
    );
    defer std.testing.allocator.free(terminal);
    try std.testing.expectEqualStrings(composed, terminal);
    try std.testing.expectError(
        error.MappingLimitExceeded,
        sourcemap.composeCoreMap(
            std.testing.allocator,
            core,
            &frontend,
            &sources,
            .{
                .intermediate_source = "zigcss-native:///intermediate.css",
                .max_segments = 2,
            },
        ),
    );
    try std.testing.expectError(
        error.OutputLimitExceeded,
        sourcemap.composeCoreMap(
            std.testing.allocator,
            core,
            &frontend,
            &sources,
            .{
                .intermediate_source = "zigcss-native:///intermediate.css",
                .max_output_bytes = composed.len - 1,
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidCoreMap,
        sourcemap.composeCoreMap(
            std.testing.allocator,
            "{\"version\":3,\"sources\":[],\"names\":[],\"mappings\":\"\"}",
            &frontend,
            &sources,
            .{ .intermediate_source = "zigcss-native:///intermediate.css" },
        ),
    );
    try std.testing.expectError(
        error.InvalidCoreMap,
        sourcemap.composeCoreMap(
            std.testing.allocator,
            "{\"version\":3,\"file\":\"zigcss-native:///intermediate.css\"," ++
                "\"sources\":[\"zigcss-native:///intermediate.css\"]," ++
                "\"names\":[],\"mappings\":\"\"}",
            &frontend,
            &sources,
            .{ .intermediate_source = "zigcss-native:///intermediate.css" },
        ),
    );
}

fn exerciseFoundationAllocationFailures(allocator: std.mem.Allocator) !void {
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.scss", "$x: 1");
    const span = try sources.span(source_id, 0, 5);

    var syntax_builder = syntax.Builder.init(allocator, &sources, .{});
    defer syntax_builder.deinit();
    const leaf = try syntax_builder.add(.literal, span, span, &.{});
    var document = try syntax_builder.finish(leaf);
    defer document.deinit();

    var values = value.Store.init(allocator, .{});
    defer values.deinit();
    var argument_state = value.ArgumentListState{};
    const owned = try values.own(.{ .argument_list = .{
        .positional = &.{.{ .string = .{ .bytes = "value", .quoted = true } }},
        .keywords = &.{.{
            .name = "end-at",
            .value = .{ .number = .{ .value = 2 } },
            .normalize_name = true,
        }},
        .state = &argument_state,
    } });

    var env = try environment.Environment.init(allocator, .{});
    defer env.deinit();
    _ = try env.define(env.root(), "x", owned);

    var list = diagnostics.List.init(allocator, &sources, .{});
    defer list.deinit();
    try list.append(.note, .syntax, span, "note", &.{});

    var map_builder = sourcemap.Builder.init(allocator, &sources, .{});
    defer map_builder.deinit();
    try map_builder.addMapped(.{ .line = 0, .column = 0 }, span, "x");
    var map = try map_builder.finish();
    defer map.deinit();
    const encoded = try map.encodeMappings(allocator);
    defer allocator.free(encoded);
}

test "shared semantic foundation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFoundationAllocationFailures,
        .{},
    );
}
