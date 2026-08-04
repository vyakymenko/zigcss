const std = @import("std");
const preprocessor = @import("native_preprocessor");
const diagnostics = preprocessor.diagnostics;
const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;
const stylus = preprocessor.stylus;
const stylus_evaluator = preprocessor.stylus_evaluator;

fn compile(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: stylus_evaluator.Limits,
) !evaluator.ValidatedCss {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    const base = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);

    var authority = try resolver.Resolver.init(allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("input.styl", input);
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var transaction = try evaluator.Transaction.init(
        allocator,
        &sources,
        &session,
        .{},
        .{},
    );
    defer transaction.deinit();
    try stylus_evaluator.evaluate(&sources, &document, &transaction, limits);
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

fn expectSemanticRejection(
    input: []const u8,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_start: u32,
) !void {
    return expectSemanticRejectionWithLimits(
        input,
        .{},
        expected_error,
        expected_code,
        expected_message,
        expected_start,
    );
}

fn expectSemanticRejectionWithLimits(
    input: []const u8,
    limits: stylus_evaluator.Limits,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_start: u32,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    const base = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);

    var authority = try resolver.Resolver.init(std.testing.allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add("semantic-error.styl", input);
    var parser = try stylus.Parser.init(
        std.testing.allocator,
        &sources,
        source_id,
        .{},
        .{},
    );
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var transaction = try evaluator.Transaction.init(
        std.testing.allocator,
        &sources,
        &session,
        .{},
        .{},
    );
    defer transaction.deinit();

    try std.testing.expectError(
        expected_error,
        stylus_evaluator.evaluate(&sources, &document, &transaction, limits),
    );
    try std.testing.expectEqual(
        evaluator.GeneratedPosition{ .line = 0, .column = 0 },
        transaction.position(),
    );
    try std.testing.expectEqual(@as(usize, 0), session.dependencies().len);
    try std.testing.expectEqual(@as(usize, 1), transaction.diagnostics().len);
    try std.testing.expectEqual(expected_code, transaction.diagnostics()[0].code);
    try std.testing.expectEqualStrings(expected_message, transaction.diagnostics()[0].message);
    try std.testing.expectEqual(expected_start, transaction.diagnostics()[0].span.start);
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified, .source_map = true }),
    );
}

test "native Stylus transaction preserves the finite plain CSS foundation" {
    const input =
        \\.card { color: red; margin: calc(1px + 2%); content: "use('safe')"; }
        \\@media print { .x { --raw: a b; } }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".card{color:red;margin:calc(1px + 2%);content:\"use('safe')\"}" ++
            "@media print{.x{--raw:a b}}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len >= 1);
}

test "native Stylus permanently rejects use plugins without partial CSS" {
    const official_use = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/preprocessors/stylus/corpus/files/upstream/cases/bifs.use.styl",
        1024 * 1024,
    );
    defer std.testing.allocator.free(official_use);
    try expectSemanticRejection(
        official_use,
        error.PluginDisabled,
        .unsupported_feature,
        "native Stylus use() plugins are permanently disabled",
        0,
    );
    try expectSemanticRejection(
        \\.safe { color: red; }
        \\u\73 e('plugins/add.js')
    ,
        error.PluginDisabled,
        .unsupported_feature,
        "native Stylus use() plugins are permanently disabled",
        22,
    );
}

test "native Stylus imports remain explicit before their evaluator slice" {
    try expectSemanticRejection(
        "@require 'theme'\n.safe { color: red; }\n",
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus imports are not implemented in this evaluator slice",
        0,
    );
}

test "native Stylus evaluates the fixed variable property selector expression slice" {
    const input =
        \\base = 8px
        \\name = 'card'
        \\tone = #123456
        \\.{name}, .panel
        \\  local = base + 2px
        \\  width local * 2
        \\  margin (base / 2)
        \\  color tone
        \\  border-{name} 1px + 1px
        \\  &:hover
        \\    width local
        \\  > span
        \\    padding base
        \\.other
        \\  width base
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".card,.panel{width:20px;margin:4px;color:#123456;border-card:2px}" ++
            ".card:hover,.panel:hover{width:10px}" ++
            ".card>span,.panel>span{padding:8px}.other{width:8px}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len >= 9);
}

test "native Stylus semantic failures own diagnostics without partial CSS" {
    try expectSemanticRejection(
        \\.a
        \\  width $missing
    ,
        error.UndefinedVariable,
        .undefined_variable,
        "native Stylus variable is undefined",
        11,
    );
    try expectSemanticRejection(
        \\base = 1px
        \\.a
        \\  width push(base)
    ,
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus built-in functions are not implemented in this evaluator slice",
        22,
    );
}

test "native Stylus evaluates the fixed callable control operator builtin slice" {
    const input =
        \\factor = 2
        \\bump(value)
        \\  return value * factor
        \\box(value)
        \\  padding value
        \\  if value > 2px
        \\    margin value + 1px
        \\  else
        \\    margin 0
        \\  for side in top right
        \\    border-{side}-width value % 3
        \\.card
        \\  box(bump(2px))
        \\  count length(1 2 3)
        \\  kind type(4px)
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".card{padding:4px;margin:5px;border-top-width:1px;" ++
            "border-right-width:1px;count:3;kind:'unit'}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
    try std.testing.expect(first.map() != null);
    try std.testing.expect(first.map().?.segments().len >= 7);
}

test "native Stylus callable control slice fails closed with exact diagnostics" {
    const missing =
        \\.a
        \\  missing(1)
    ;
    try expectSemanticRejection(
        missing,
        error.UndefinedCallable,
        .invalid_operation,
        "native Stylus callable is undefined",
        @intCast(std.mem.indexOf(u8, missing, "missing").?),
    );

    const recursive =
        \\countdown(value)
        \\  if value > 0
        \\    return countdown(value - 1)
        \\  return 0
        \\.a
        \\  width countdown(2)
    ;
    var terminal_calls = stylus_evaluator.Limits{};
    terminal_calls.max_call_depth = 3;
    var result = try compile(std.testing.allocator, recursive, terminal_calls);
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{width:0}", result.css());

    var over_calls = terminal_calls;
    over_calls.max_call_depth = 2;
    try expectSemanticRejectionWithLimits(
        recursive,
        over_calls,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.indexOf(u8, recursive, "return countdown").?),
    );

    const finite_loop =
        \\box()
        \\  for side in top right
        \\    border-{side}-width 1px
        \\.a
        \\  box()
    ;
    var terminal_loop = stylus_evaluator.Limits{};
    terminal_loop.max_loop_iterations = 2;
    var loop_result = try compile(std.testing.allocator, finite_loop, terminal_loop);
    defer loop_result.deinit();
    try std.testing.expectEqualStrings(
        ".a{border-top-width:1px;border-right-width:1px}",
        loop_result.css(),
    );

    var over_loop = terminal_loop;
    over_loop.max_loop_iterations = 1;
    try expectSemanticRejectionWithLimits(
        finite_loop,
        over_loop,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, finite_loop, "for side").?),
    );
}

test "native Stylus semantic values and bindings retain finite ceilings" {
    const value_input =
        \\base = 1px
        \\.a
        \\  width base
    ;
    var terminal_values = stylus_evaluator.Limits{};
    terminal_values.values.max_values = 2;
    var value_result = try compile(std.testing.allocator, value_input, terminal_values);
    defer value_result.deinit();
    try std.testing.expectEqualStrings(".a{width:1px}", value_result.css());

    var over_values = terminal_values;
    over_values.values.max_values = 1;
    try expectSemanticRejectionWithLimits(
        value_input,
        over_values,
        error.ValueLimitExceeded,
        .resource_limit,
        "native Stylus value limit exceeded",
        @intCast(std.mem.lastIndexOf(u8, value_input, "base").?),
    );

    const binding_input =
        \\base = 1px
        \\.a
        \\  local = base
        \\  width local
    ;
    var over_bindings = stylus_evaluator.Limits{};
    over_bindings.environment.max_bindings = 1;
    try expectSemanticRejectionWithLimits(
        binding_input,
        over_bindings,
        error.BindingLimitExceeded,
        .resource_limit,
        "native Stylus lexical environment limit exceeded",
        @intCast(std.mem.indexOf(u8, binding_input, "local =").?),
    );
}

const CancelContext = struct {
    target: evaluator.Checkpoint,
    calls: usize = 0,

    fn check(context: *anyopaque, checkpoint: evaluator.Checkpoint) bool {
        const self: *CancelContext = @ptrCast(@alignCast(context));
        self.calls += 1;
        return checkpoint == self.target;
    }
};

test "native Stylus plain CSS foundation owns resource and cancellation boundaries" {
    const input = ".a { color: red; }\n";
    {
        var limits = stylus_evaluator.Limits{};
        limits.max_source_bytes = input.len - 1;
        try std.testing.expectError(
            error.SourceLimitExceeded,
            compile(std.testing.allocator, input, limits),
        );
    }
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.makeDir("root");
        const base = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
        defer std.testing.allocator.free(base);
        const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
        defer std.testing.allocator.free(root);
        var authority = try resolver.Resolver.init(std.testing.allocator, &.{root}, .{});
        defer authority.deinit();
        var session = authority.createSession(std.testing.allocator, .{});
        defer session.deinit();
        var sources = source.Table.init(std.testing.allocator, .{});
        defer sources.deinit();
        const source_id = try sources.add("input.styl", input);
        var parser = try stylus.Parser.init(
            std.testing.allocator,
            &sources,
            source_id,
            .{},
            .{},
        );
        defer parser.deinit();
        var document = try parser.parse();
        defer document.deinit();

        var node_limits = stylus_evaluator.Limits{};
        node_limits.max_nodes = document.nodes().len - 1;
        var node_transaction = try evaluator.Transaction.init(
            std.testing.allocator,
            &sources,
            &session,
            .{},
            .{},
        );
        defer node_transaction.deinit();
        try std.testing.expectError(
            error.NodeLimitExceeded,
            stylus_evaluator.evaluate(
                &sources,
                &document,
                &node_transaction,
                node_limits,
            ),
        );
        try std.testing.expectEqual(@as(usize, 1), node_transaction.diagnostics().len);
        try std.testing.expectEqual(
            diagnostics.Code.resource_limit,
            node_transaction.diagnostics()[0].code,
        );

        var cancelled_session = authority.createSession(std.testing.allocator, .{});
        defer cancelled_session.deinit();
        var cancel_context = CancelContext{ .target = .operation };
        var cancelled_transaction = try evaluator.Transaction.init(
            std.testing.allocator,
            &sources,
            &cancelled_session,
            .{},
            .{ .context = &cancel_context, .check_fn = CancelContext.check },
        );
        defer cancelled_transaction.deinit();
        try std.testing.expectError(
            error.Cancelled,
            stylus_evaluator.evaluate(
                &sources,
                &document,
                &cancelled_transaction,
                .{},
            ),
        );
        try std.testing.expect(cancel_context.calls > 0);
        try std.testing.expectError(
            error.SessionFailed,
            cancelled_transaction.finish(.{ .format = .minified }),
        );
    }
    {
        var invalid = stylus_evaluator.Limits{};
        invalid.max_nodes = 0;
        try std.testing.expectError(
            error.InvalidLimits,
            compile(std.testing.allocator, input, invalid),
        );
    }
    {
        var terminal = stylus_evaluator.Limits{};
        terminal.max_selectors = 2;
        var result = try compile(
            std.testing.allocator,
            ".a, .b\n  width 1px + 1px\n",
            terminal,
        );
        defer result.deinit();
        try std.testing.expectEqualStrings(".a,.b{width:2px}", result.css());

        var over_limit = terminal;
        over_limit.max_selectors = 1;
        try std.testing.expectError(
            error.SelectorLimitExceeded,
            compile(
                std.testing.allocator,
                ".a, .b\n  width 1px + 1px\n",
                over_limit,
            ),
        );
    }
    {
        var terminal = stylus_evaluator.Limits{};
        terminal.max_expression_depth = 2;
        var result = try compile(
            std.testing.allocator,
            ".a\n  width (1px + 1px)\n",
            terminal,
        );
        defer result.deinit();
        try std.testing.expectEqualStrings(".a{width:2px}", result.css());

        try std.testing.expectError(
            error.ExpressionDepthExceeded,
            compile(
                std.testing.allocator,
                ".a\n  width ((1px + 1px))\n",
                terminal,
            ),
        );
    }
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "factor = 2\n" ++
            "bump(value)\n" ++
            "  return value * factor\n" ++
            "box(value)\n" ++
            "  padding value\n" ++
            "  if value > 2px\n" ++
            "    margin value + 1px\n" ++
            "  else\n" ++
            "    margin 0\n" ++
            "  for side in top right\n" ++
            "    border-{side}-width value % 3\n" ++
            ".card\n" ++
            "  box(bump(2px))\n" ++
            "  count length(1 2 3)\n" ++
            "  kind type(4px)\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{padding:4px;margin:5px;border-top-width:1px;" ++
            "border-right-width:1px;count:3;kind:'unit'}",
        result.css(),
    );
}

test "native Stylus transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
