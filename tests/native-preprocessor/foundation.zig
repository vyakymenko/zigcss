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

test "source ownership limits fail before partial admission" {
    var table = source.Table.init(std.testing.allocator, .{
        .max_sources = 1,
        .max_owned_bytes = 4,
    });
    defer table.deinit();
    _ = try table.add("a", "123");
    try std.testing.expectError(error.SourceLimitExceeded, table.add("b", ""));
    try std.testing.expectEqual(@as(usize, 1), table.count());

    var bytes = source.Table.init(std.testing.allocator, .{ .max_owned_bytes = 2 });
    defer bytes.deinit();
    try std.testing.expectError(error.SourceLimitExceeded, bytes.add("a", "12"));
    try std.testing.expectEqual(@as(usize, 0), bytes.count());
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
    try std.testing.expect((try env.lookup(child, "x")).? == one);
    try std.testing.expect((try env.lookup(shadowed, "x")).? == two);
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
    const owned = try values.own(.{ .string = .{ .bytes = "value", .quoted = true } });

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
