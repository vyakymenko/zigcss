const std = @import("std");
const preprocessor = @import("native_preprocessor");
const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const sass = preprocessor.sass;
const sass_evaluator = preprocessor.sass_evaluator;
const source = preprocessor.source;

fn compile(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    mode: sass.Mode,
    limits: sass_evaluator.Limits,
) !evaluator.ValidatedCss {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);

    var authority = try resolver.Resolver.init(allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(name, input);

    var parser = try sass.Parser.init(
        allocator,
        &sources,
        source_id,
        mode,
        .{},
        .{},
    );
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
    try sass_evaluator.evaluate(
        allocator,
        &sources,
        &document,
        &transaction,
        limits,
    );
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

test "native SCSS evaluates variables arithmetic interpolation and selector nesting" {
    const input =
        \\$space: 4px;
        \\$tone: red;
        \\.card, .panel {
        \\  padding: $space * 2;
        \\  color: $tone;
        \\  &--#{$tone} { margin: $space + 1px; }
        \\}
    ;
    var result = try compile(std.testing.allocator, "input.scss", input, .scss, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".card,.panel{padding:8px;color:red}.card--red,.panel--red{margin:5px}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), result.dependencies().len);
    try std.testing.expect(result.map() != null);
    try std.testing.expect(result.map().?.segments().len >= 2);
}

test "native indented Sass shares the semantic core" {
    const input =
        \\$space: 3px
        \\$state: active
        \\.button
        \\  margin: $space * 2
        \\  &-#{$state}
        \\    padding: $space + 1px
    ;
    var result = try compile(std.testing.allocator, "input.sass", input, .sass, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".button{margin:6px}.button-active{padding:4px}",
        result.css(),
    );
}

test "native Sass lexical scopes are ordered and persistent" {
    const input =
        \\$tone: red;
        \\.a {
        \\  color: $tone;
        \\  $tone: blue;
        \\  border-color: $tone;
        \\  .b { color: $tone; }
        \\}
        \\.c { color: $tone; }
    ;
    var result = try compile(std.testing.allocator, "scope.scss", input, .scss, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".a{color:red;border-color:blue}.a .b{color:blue}.c{color:red}",
        result.css(),
    );
}

test "native Sass expands nested properties and quoted interpolation" {
    const input =
        \\$size: 1rem;
        \\.card {
        \\  font: { size: $size; family: "Inter"; }
        \\  content: "size-#{$size}";
        \\}
    ;
    var result = try compile(std.testing.allocator, "properties.scss", input, .scss, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".card{font-size:1rem;font-family:\"Inter\";content:\"size-1rem\"}",
        result.css(),
    );
}

test "native Sass rejects undefined variables without exposing partial CSS" {
    const input =
        \\.safe { color: red; }
        \\.broken { color: $missing; }
    ;
    try std.testing.expectError(
        error.UndefinedVariable,
        compile(std.testing.allocator, "undefined.scss", input, .scss, .{}),
    );
}

test "native Sass semantic limits fail closed" {
    const input = ".a, .b { color: red; }";
    var limits = sass_evaluator.Limits{};
    limits.max_selectors = 1;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(std.testing.allocator, "limits.scss", input, .scss, limits),
    );
}

test "native Sass variable names canonicalize underscores and hyphens" {
    const input =
        \\$inline_size: 12px;
        \\.card { inline-size: $inline-size; }
    ;
    var result = try compile(std.testing.allocator, "names.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(".card{inline-size:12px}", result.css());
}

test "native Sass preserves slash lists unless arithmetic is forced" {
    const input =
        \\$size: 4px;
        \\.card { literal: 4px/2; variable: $size/2; grouped: (4px/2); }
    ;
    var result = try compile(std.testing.allocator, "slash.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{literal:4px/2;variable:2px;grouped:2px}",
        result.css(),
    );
}

test "native Sass rejects unimplemented variable modifiers" {
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "modifier.scss",
            "$tone: red !default; .card { color: $tone; }",
            .scss,
            .{},
        ),
    );
}

test "native Sass preserves declaration order around nested rules" {
    const input =
        \\.a {
        \\  color: red;
        \\  .b { x: y; }
        \\  background: blue;
        \\}
    ;
    var result = try compile(std.testing.allocator, "mixed.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{color:red}.a .b{x:y}.a{background:blue}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 3), result.map().?.segments().len);
}

test "native Sass expands every repeated parent selector combination in canonical order" {
    const input =
        \\.a, .b {
        \\  &:hover, & + & { x: y; }
        \\}
    ;
    var result = try compile(std.testing.allocator, "parents.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a:hover,.a+.a,.a+.b,.b:hover,.b+.a,.b+.b{x:y}",
        result.css(),
    );
}

test "native Sass custom properties require interpolation for variables" {
    const input =
        \\$tone: red;
        \\.card { --literal: $tone; --evaluated: #{$tone}; }
    ;
    var result = try compile(std.testing.allocator, "custom.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{--literal:$tone;--evaluated:red}",
        result.css(),
    );
}

test "native Sass replay is deterministic across CSS and both source-map stages" {
    const input =
        \\$n: 2px;
        \\.a { width: $n * 3; & + & { gap: $n; } }
    ;
    var first = try compile(std.testing.allocator, "deterministic.scss", input, .scss, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, "deterministic.scss", input, .scss, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualStrings(first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqualSlices(
        preprocessor.sourcemap.Segment,
        first.map().?.segments(),
        second.map().?.segments(),
    );
}

const TransactionCancelContext = struct {
    operations: usize = 0,

    fn check(context: *anyopaque, checkpoint: evaluator.Checkpoint) bool {
        const self: *TransactionCancelContext = @ptrCast(@alignCast(context));
        if (checkpoint != .operation) return false;
        self.operations += 1;
        return self.operations == 3;
    }
};

test "native Sass cancellation poisons staged CSS before commit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    var authority = try resolver.Resolver.init(allocator, &.{root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const input = ".a { color: red; } .b { color: blue; }";
    const source_id = try sources.add("cancel.scss", input);
    var parser = try sass.Parser.init(allocator, &sources, source_id, .scss, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var cancel = TransactionCancelContext{};
    var transaction = try evaluator.Transaction.init(
        allocator,
        &sources,
        &session,
        .{},
        .{ .context = &cancel, .check_fn = TransactionCancelContext.check },
    );
    defer transaction.deinit();

    try std.testing.expectError(
        error.Cancelled,
        sass_evaluator.evaluate(allocator, &sources, &document, &transaction, .{}),
    );
    try std.testing.expect(cancel.operations >= 3);
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified }),
    );
    try std.testing.expectError(
        error.SessionClosed,
        session.load("file:///missing.scss", .{ .kind = .import, .ancestry = &.{} }),
    );
}

const AllocationContext = struct {
    root: []const u8,
};

fn exerciseAllocationFailures(
    allocator: std.mem.Allocator,
    context: *const AllocationContext,
) !void {
    var authority = try resolver.Resolver.init(allocator, &.{context.root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const input =
        \\$size: 2px;
        \\$name: card;
        \\.#{$name} { width: $size * 3; &:hover { margin: $size + 1px; } }
    ;
    const source_id = try sources.add("allocation.scss", input);
    var parser = try sass.Parser.init(allocator, &sources, source_id, .scss, .{}, .{});
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
    try sass_evaluator.evaluate(allocator, &sources, &document, &transaction, .{});
    var result = try transaction.finish(.{ .format = .minified, .source_map = true });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{width:6px}.card:hover{margin:3px}",
        result.css(),
    );
}

test "native Sass semantic core handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const context = AllocationContext{ .root = root };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{&context},
    );
}
