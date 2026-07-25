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
    return compileWithTransactionLimits(allocator, name, input, mode, limits, .{});
}

fn compileWithTransactionLimits(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    mode: sass.Mode,
    semantic_limits: sass_evaluator.Limits,
    transaction_limits: evaluator.Limits,
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
        transaction_limits,
        .{},
    );
    defer transaction.deinit();
    try sass_evaluator.evaluate(
        allocator,
        &sources,
        &document,
        &transaction,
        semantic_limits,
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

test "native Sass implements default global and null variable assignment semantics" {
    const input =
        \\$tone: red !default;
        \\$tone: blue !default;
        \\$gap: null;
        \\$gap: 4px !default;
        \\.a {
        \\  before: $tone;
        \\  $tone: green !global;
        \\  after: $tone;
        \\  gap: $gap;
        \\}
        \\.b { color: $tone; }
    ;
    var result = try compile(std.testing.allocator, "modifiers.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{before:red;after:green;gap:4px}.b{color:green}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass warns when global assignment creates a variable" {
    const input = ".a { $new: blue !global; color: $new; } .b { color: $new; }";
    var result = try compile(std.testing.allocator, "new-global.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{color:blue}.b{color:blue}", result.css());
    try std.testing.expectEqual(@as(usize, 1), result.nativeDiagnostics().len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        result.nativeDiagnostics()[0].severity,
    );
}

test "native Sass variable modifier parsing ignores quoted text and rejects duplicates" {
    var quoted = try compile(
        std.testing.allocator,
        "quoted-modifier.scss",
        "$text: \"!default\"; .a { content: $text; }",
        .scss,
        .{},
    );
    defer quoted.deinit();
    try std.testing.expectEqualStrings(".a{content:\"!default\"}", quoted.css());

    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "duplicate-modifier.scss",
            "$tone: red !default !default; .a { color: $tone; }",
            .scss,
            .{},
        ),
    );
}

test "native Sass evaluates typed lists maps and native accessors" {
    const input =
        \\$spaces: 2px 4px 8px;
        \\$theme: (primary: red, spaces: $spaces, nested: (tone: blue));
        \\.card {
        \\  margin: $spaces;
        \\  color: map-get($theme, primary);
        \\  gap: nth(map-get($theme, spaces), 2);
        \\  border-color: map-get($theme, nested, tone);
        \\  count: length($spaces);
        \\  pair: nth($theme, 1);
        \\  tracks: [a, b];
        \\  ratio: 16/9;
        \\}
    ;
    var result = try compile(std.testing.allocator, "collections.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{margin:2px 4px 8px;color:red;gap:4px;border-color:blue;count:3;pair:primary red;tracks:[a,b];ratio:16/9}",
        result.css(),
    );
}

test "native Sass map-get preserves variadic access and binds bounded keywords" {
    const input =
        \\$theme: (tone: blue, nested: (tone: red));
        \\.a {
        \\  reordered: map-get($key: tone, $map: $theme);
        \\  mixed: map-get($theme, $key: tone);
        \\  nested: map-get($theme, nested, tone);
        \\}
    ;
    var result = try compile(std.testing.allocator, "map-keywords.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{reordered:blue;mixed:blue;nested:red}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass map-get keyword binding rejects ambiguous calls before evaluation" {
    const invalid = [_]struct {
        name: []const u8,
        expression: []const u8,
    }{
        .{ .name = "map-keyword-missing.scss", .expression = "map-get($map: $theme)" },
        .{ .name = "map-keyword-unknown.scss", .expression = "map-get($undefined, $unknown: $also-undefined)" },
        .{ .name = "map-keyword-order.scss", .expression = "map-get($map: $theme, tone)" },
        .{ .name = "map-keyword-rest-name.scss", .expression = "map-get($map: $theme, $key: tone, $keys: nested)" },
        .{ .name = "map-keyword-duplicate.scss", .expression = "map-get($theme, tone, $key: nested)" },
    };
    for (invalid) |case| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "$theme: (tone: blue); .a {{ value: {s}; }}",
            .{case.expression},
        );
        defer std.testing.allocator.free(input);
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "map-keyword-splat.scss",
            "$args: ((tone: blue), tone); .a { value: map-get($args...); }",
            .scss,
            .{},
        ),
    );
}

test "native Sass rejects maps as CSS values and duplicate map keys" {
    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "map-css-value.scss",
            "$theme: (primary: red); .safe { color: blue; } .broken { value: $theme; }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "duplicate-map-key.scss",
            "$theme: (primary: red, primary: blue); .a { color: red; }",
            .scss,
            .{},
        ),
    );
}

test "native Sass queries maps through global and built-in module functions" {
    const input =
        \\@use "sass:map";
        \\@use "sass:map" as maps;
        \\@use "sass:map" as *;
        \\$theme: (tone: blue, nested: (tone: red), spaces: (1, 2));
        \\@function empty-rest($args...) { @return map.has-key($args, tone); }
        \\.a {
        \\  get: map.get($theme, nested, tone);
        \\  alias: maps.get($theme, tone);
        \\  star: get($theme, tone);
        \\  legacy: map-get($theme, nested, tone);
        \\  keyword-get: map.get($key: tone, $map: $theme);
        \\  has: map.has-key($theme, nested, tone);
        \\  missing: map.has-key($theme, nested, absent);
        \\  nested-non-map: map.has-key($theme, tone, absent);
        \\  legacy-has: map-has-key($theme, tone);
        \\  keyword-has: maps.has-key($key: tone, $map: $theme);
        \\  second-key: nth(map.keys($theme), 2);
        \\  first-value: nth(maps.values($theme), 1);
        \\  key-count: length(keys($theme));
        \\  legacy-key: nth(map-keys($theme), 3);
        \\  legacy-value: nth(map-values($theme), 3);
        \\  keyword-key: nth(map.keys($map: $theme), 1);
        \\  empty-keys: length(map.keys(()));
        \\  empty-brackets: length(map.values([]));
        \\  empty-has: map.has-key((), tone);
        \\  empty-rest: empty-rest();
        \\  omitted-missing: map.get($theme, nested, absent);
        \\  omitted-non-map: map.get($theme, tone, absent);
        \\}
    ;
    var result = try compile(std.testing.allocator, "map-queries.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{get:red;alias:blue;star:blue;legacy:red;keyword-get:blue;has:true;missing:false;nested-non-map:false;legacy-has:true;keyword-has:true;second-key:nested;first-value:blue;key-count:3;legacy-key:spaces;legacy-value:1,2;keyword-key:tone;empty-keys:0;empty-brackets:0;empty-has:false;empty-rest:false}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:map" as m
        \\$theme: (tone: purple, nested: (tone: orange))
        \\.sass
        \\  value: m.get($theme, nested, tone)
        \\  has: m.has-key($theme, tone)
        \\  key: nth(m.keys($theme), 1)
        \\  nested: map-get(nth(m.values($theme), 2), tone)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "map-queries.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{value:orange;has:true;key:tone;nested:orange}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass map queries reject unowned calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-map-module.scss",
            .input = ".a { value: map.get((tone: blue), tone); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unknown-map-member.scss",
            .input = "@use \"sass:map\"; .a { value: map.nope($undefined); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-get-type.scss",
            .input = "@use \"sass:map\"; .a { value: map.get(1, tone); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-has-key-type.scss",
            .input = "@use \"sass:map\"; .a { value: map.has-key(1, tone); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-keys-type.scss",
            .input = "@use \"sass:map\"; .a { value: map.keys(1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-values-type.scss",
            .input = "@use \"sass:map\"; .a { value: map.values(1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-get-arity.scss",
            .input = "@use \"sass:map\"; .a { value: map.get((tone: blue)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-has-key-arity.scss",
            .input = "@use \"sass:map\"; .a { value: map.has-key((tone: blue)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-keys-arity.scss",
            .input = "@use \"sass:map\"; .a { value: map.keys((tone: blue), tone); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-values-arity.scss",
            .input = "@use \"sass:map\"; .a { value: map.values(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-query-splat.scss",
            .input = "@use \"sass:map\"; $args: ((tone: blue), tone); .a { value: map.get($args...); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "duplicate-map-module-namespace.scss",
            .input = "@use \"sass:meta\" as tools; @use \"sass:map\" as tools;",
            .expected = error.InvalidSassSyntax,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var depth_limits = sass_evaluator.Limits{};
    depth_limits.max_evaluation_depth = 2;
    try std.testing.expectError(
        error.EvaluationDepthExceeded,
        compile(
            std.testing.allocator,
            "nested-map-depth-limit.scss",
            "@use \"sass:map\"; $value: map.set((), a, b, c, d, 1);",
            .scss,
            depth_limits,
        ),
    );

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 1;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "map-mutation-temporary-limit.scss",
            "@use \"sass:map\"; $value: map.set((a: 1), b, 2);",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass mutates shallow maps immutably" {
    const input =
        \\@use "sass:map";
        \\@use "sass:map" as maps;
        \\@use "sass:map" as *;
        \\$order: 0;
        \\@function stamp($key) { $order: $order + 1 !global; @return ($key: $order); }
        \\$left: (a: 1, b: 2);
        \\$right: (b: 20, c: 3);
        \\$merged: map.merge($left, $right);
        \\$alias-merged: maps.merge($left, (d: 4));
        \\$legacy-merged: map-merge($left, (e: 5));
        \\$removed: map.remove($merged, a, c, missing);
        \\$star-removed: remove($merged, b);
        \\$legacy-removed: map-remove($merged, b);
        \\$unchanged: map.remove($left);
        \\$set: map.set($left, b, 22);
        \\$appended: maps.set($left, c, 3);
        \\$star-set: set((), z, 9);
        \\$named-set: map.set($map: $left, $key: a, $value: 10);
        \\$named-merge: map.merge($map1: $left, $map2: (f: 6));
        \\$named-removed: map.remove($map: $left);
        \\$source-ordered: map.merge($map2: stamp(b), $map1: stamp(a));
        \\.a {
        \\  merged-a: map.get($merged, a);
        \\  merged-b: map.get($merged, b);
        \\  merged-c: map.get($merged, c);
        \\  merged-first: nth(map.keys($merged), 1);
        \\  merged-last: nth(map.keys($merged), 3);
        \\  original: map.get($left, b);
        \\  alias: map.get($alias-merged, d);
        \\  legacy: map.get($legacy-merged, e);
        \\  removed-count: length(map.keys($removed));
        \\  removed-key: nth(map.keys($removed), 1);
        \\  star-removed: map.has-key($star-removed, b);
        \\  legacy-removed: map.has-key($legacy-removed, b);
        \\  unchanged: length(map.keys($unchanged));
        \\  set: map.get($set, b);
        \\  set-order: nth(map.keys($set), 2);
        \\  appended: map.get($appended, c);
        \\  appended-order: nth(map.keys($appended), 3);
        \\  star-set: map.get($star-set, z);
        \\  named-set: map.get($named-set, a);
        \\  named-merge: map.get($named-merge, f);
        \\  named-removed: length(map.keys($named-removed));
        \\  source-ordered-a: map.get($source-ordered, a);
        \\  source-ordered-b: map.get($source-ordered, b);
        \\  equal: $merged == (a: 1, b: 20, c: 3);
        \\}
    ;
    var result = try compile(std.testing.allocator, "map-mutations.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{merged-a:1;merged-b:20;merged-c:3;merged-first:a;merged-last:c;original:2;alias:4;legacy:5;removed-count:1;removed-key:b;star-removed:false;legacy-removed:false;unchanged:2;set:22;set-order:b;appended:3;appended-order:c;star-set:9;named-set:10;named-merge:6;named-removed:2;source-ordered-a:2;source-ordered-b:1;equal:true}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:map" as m
        \\$base: (a: 1, b: 2)
        \\$merged: m.merge($base, (b: 3, c: 4))
        \\$removed: m.remove($merged, a, c)
        \\$set: m.set($base, b, 5)
        \\.sass
        \\  merged: m.get($merged, b)
        \\  key: nth(m.keys($merged), 3)
        \\  removed: m.get($removed, b)
        \\  set: m.get($set, b)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "map-mutations.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{merged:3;key:c;removed:3;set:5}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass shallow map mutations reject unowned calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "map-merge-left-type.scss",
            .input = "@use \"sass:map\"; $value: map.merge(1, (a: 1));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-merge-right-type.scss",
            .input = "@use \"sass:map\"; $value: map.merge((a: 1), 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-remove-type.scss",
            .input = "@use \"sass:map\"; $value: map.remove(1, a);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-set-type.scss",
            .input = "@use \"sass:map\"; $value: map.set(1, a, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-merge-arity.scss",
            .input = "@use \"sass:map\"; $value: map.merge((a: 1));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-set-arity.scss",
            .input = "@use \"sass:map\"; $value: map.set((a: 1), a);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-remove-arity.scss",
            .input = "@use \"sass:map\"; $value: map.remove();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-remove-rest-keyword.scss",
            .input = "@use \"sass:map\"; $value: map.remove($map: (a: 1), $keys: a);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "map-mutation-splat.scss",
            .input = "@use \"sass:map\"; $args: ((a: 1), (b: 2)); $value: map.merge($args...);",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 5;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "math-unit-temporary-limit.scss",
            "@use \"sass:math\"; $value: math.unit(1abcdef);",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass mutates nested and deep maps immutably" {
    const input =
        \\@use "sass:map";
        \\@use "sass:map" as maps;
        \\@use "sass:map" as *;
        \\$order: 0;
        \\@function stamp($key) { $order: $order + 1 !global; @return ($key: $order); }
        \\$base: (theme: (color: red, nested: (x: 1)), scalar: 5, untouched: (u: 1));
        \\$nested-merge: map.merge($base, theme, nested, (x: 10, z: 3));
        \\$legacy-nested: map-merge($base, theme, (accent: blue));
        \\$missing-merge: map.merge($base, new-merge, a, (b: 2));
        \\$scalar-merge: map.merge($base, scalar, (x: 9));
        \\$nested-set: maps.set($base, theme, nested, y, 2);
        \\$missing-set: map.set($base, new-set, a, b, 3);
        \\$scalar-set: map.set($base, scalar, x, 9);
        \\$deep: map.deep-merge((a: (x: 1, y: 2), b: 1), (a: (y: 20, z: 3), b: (nested: true), c: 4));
        \\$star-deep: deep-merge((), (ready: true));
        \\$named-deep: map.deep-merge($map2: stamp(b), $map1: stamp(a));
        \\$removed: map.deep-remove($base, theme, nested, x);
        \\$empty-child: map.deep-remove((single: (leaf: 1)), single, leaf);
        \\$named-removed: map.deep-remove($key: color, $map: map.get($base, theme));
        \\$missing-removed: map.deep-remove($base, theme, missing, x);
        \\$scalar-removed: map.deep-remove($base, scalar, x);
        \\.a {
        \\  nested-merge-x: map.get($nested-merge, theme, nested, x);
        \\  nested-merge-z: map.get($nested-merge, theme, nested, z);
        \\  nested-merge-order: nth(map.keys(map.get($nested-merge, theme, nested)), 2);
        \\  legacy-nested: map.get($legacy-nested, theme, accent);
        \\  missing-merge: map.get($missing-merge, new-merge, a, b);
        \\  scalar-merge: map.get($scalar-merge, scalar, x);
        \\  nested-set: map.get($nested-set, theme, nested, y);
        \\  missing-set: map.get($missing-set, new-set, a, b);
        \\  scalar-set: map.get($scalar-set, scalar, x);
        \\  original: map.get($base, theme, nested, x);
        \\  deep-x: map.get($deep, a, x);
        \\  deep-y: map.get($deep, a, y);
        \\  deep-z: map.get($deep, a, z);
        \\  deep-b: map.get($deep, b, nested);
        \\  deep-root-order: nth(map.keys($deep), 3);
        \\  deep-child-order: nth(map.keys(map.get($deep, a)), 3);
        \\  star-deep: map.get($star-deep, ready);
        \\  source-ordered-a: map.get($named-deep, a);
        \\  source-ordered-b: map.get($named-deep, b);
        \\  removed: map.has-key(map.get($removed, theme, nested), x);
        \\  removed-parent: map.has-key(map.get($removed, theme), nested);
        \\  empty-child: length(map.keys(map.get($empty-child, single)));
        \\  empty-parent: map.has-key($empty-child, single);
        \\  named-removed: map.has-key($named-removed, color);
        \\  missing-unchanged: map.get($missing-removed, theme, nested, x);
        \\  scalar-unchanged: map.get($scalar-removed, scalar);
        \\}
    ;
    var result = try compile(std.testing.allocator, "deep-map-mutations.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{nested-merge-x:10;nested-merge-z:3;nested-merge-order:z;legacy-nested:blue;missing-merge:2;scalar-merge:9;nested-set:2;missing-set:3;scalar-set:9;original:1;deep-x:1;deep-y:20;deep-z:3;deep-b:true;deep-root-order:c;deep-child-order:z;star-deep:true;source-ordered-a:2;source-ordered-b:1;removed:false;removed-parent:true;empty-child:0;empty-parent:true;named-removed:false;missing-unchanged:1;scalar-unchanged:5}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:map" as m
        \\$base: (a: (b: (c: 1)), keep: 2)
        \\$merged: m.merge($base, a, b, (c: 3, d: 4))
        \\$set: m.set($base, a, b, e, 5)
        \\$deep: m.deep-merge($base, (a: (b: (f: 6))))
        \\$removed: m.deep-remove($base, a, b, c)
        \\.sass
        \\  merged: m.get($merged, a, b, d)
        \\  set: m.get($set, a, b, e)
        \\  deep: m.get($deep, a, b, f)
        \\  removed: m.has-key(m.get($removed, a, b), c)
        \\  keep: m.get($removed, keep)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "deep-map-mutations.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{merged:4;set:5;deep:6;removed:false;keep:2}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass nested and deep map mutations reject unsafe calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "deep-merge-left-type.scss",
            .input = "@use \"sass:map\"; $value: map.deep-merge(1, (a: 1));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "deep-merge-right-type.scss",
            .input = "@use \"sass:map\"; $value: map.deep-merge((a: 1), 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "deep-merge-arity.scss",
            .input = "@use \"sass:map\"; $value: map.deep-merge((a: 1));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "deep-remove-type.scss",
            .input = "@use \"sass:map\"; $value: map.deep-remove(1, a);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "deep-remove-arity.scss",
            .input = "@use \"sass:map\"; $value: map.deep-remove((a: 1));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "nested-merge-value-type.scss",
            .input = "@use \"sass:map\"; $value: map.merge((a: (b: 1)), a, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "nested-set-root-type.scss",
            .input = "@use \"sass:map\"; $value: map.set(1, a, b, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "deep-merge-splat.scss",
            .input = "@use \"sass:map\"; $args: ((a: 1), (b: 2)); $value: map.deep-merge($args...);",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "deep-remove-splat.scss",
            .input = "@use \"sass:map\"; $args: ((a: 1), a); $value: map.deep-remove($args...);",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass bounds recursive collection evaluation" {
    var limits = sass_evaluator.Limits{};
    limits.max_evaluation_depth = 3;
    try std.testing.expectError(
        error.EvaluationDepthExceeded,
        compile(
            std.testing.allocator,
            "collection-depth.scss",
            "$tone: ((((red)))); .a { color: $tone; }",
            .scss,
            limits,
        ),
    );
}

test "native Sass evaluates logical comparison and list precedence" {
    const input =
        \\$n: 2px;
        \\$fallback: null;
        \\.a {
        \\  equal: $n * 2 == 4px;
        \\  different: red != blue;
        \\  ordered: 1px < 2px;
        \\  selected: $fallback or red;
        \\  guarded: true and 4px;
        \\  inverse: not(false);
        \\  quoted-equal: "foo" == foo;
        \\  comma-precedence: a, b and c;
        \\  space-precedence: a b and c;
        \\}
    ;
    var result = try compile(std.testing.allocator, "logic.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{equal:true;different:true;ordered:true;selected:red;guarded:4px;inverse:true;quoted-equal:true;comma-precedence:a,c;space-precedence:a c}",
        result.css(),
    );
}

test "native Sass converts and cancels compatible units" {
    const input =
        \\$inch: 1in;
        \\$px: 96px;
        \\$duration: 1s;
        \\.a {
        \\  length-left: $inch + $px;
        \\  length-right: $px + $inch;
        \\  time: $duration + 500ms;
        \\  angle: 1turn + 180deg;
        \\  resolution: 1dppx == 96dpi;
        \\  converted-eq: 1in == 96px;
        \\  converted-order: 1in >= 95px;
        \\  cancelled: ($inch / 2.54cm);
        \\  compound: $px * 1s / 1000ms;
        \\  unitless-left: 1 + 2px;
        \\  unitless-right: 2px - 1;
        \\  remainder: 5px % 2px;
        \\  converted-remainder: 5px % 0.2in;
        \\}
    ;
    var result = try compile(std.testing.allocator, "units.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{length-left:2in;length-right:192px;time:1.5s;angle:1.5turn;resolution:true;converted-eq:true;converted-order:true;cancelled:1;compound:96px;unitless-left:3px;unitless-right:1px;remainder:1px;converted-remainder:5px}",
        result.css(),
    );
}

test "native Sass rejects incompatible and non-CSS compound units" {
    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "incompatible-units.scss",
            ".a { value: 1px + 1em; }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "compound-units.scss",
            "$value: 1px * 1s; .safe { color: red; } .broken { value: $value; }",
            .scss,
            .{},
        ),
    );
}

test "native Sass serializes repeating arithmetic with canonical precision" {
    const input =
        \\$one: 1;
        \\$two: 2;
        \\$large: 123456789;
        \\.a {
        \\  third: $one / 3;
        \\  two-thirds: $two / 3;
        \\  seventh: $one / 7;
        \\  tiny: $one / 30000000000;
        \\  large: $large / 7;
        \\}
    ;
    var result = try compile(std.testing.allocator, "precision.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{third:.3333333333;two-thirds:.6666666667;seventh:.1428571429;tiny:0;large:17636684.14285714}",
        result.css(),
    );
}

test "native Sass reduces and safely preserves CSS calculations" {
    const input =
        \\$one: 1px;
        \\$gap: 20px;
        \\$dynamic: var(--size);
        \\.a {
        \\  calc-reduced: calc(1px + 2px);
        \\  calc-variable: calc($one + 2px);
        \\  calc-preserved: calc(100% - $gap);
        \\  calc-relative: calc(1em + 2px);
        \\  calc-dynamic: calc($dynamic);
        \\  minimum: min(3px, 2px);
        \\  maximum: max(3px, 2px);
        \\  clamped: clamp(1px, 2px, 3px);
        \\  converted-max: max(1in, 95px);
        \\  converted-clamp: clamp(1in, 97px, 3cm);
        \\  relative-min: min(1em, 2px);
        \\  dynamic: max(var(--size), $gap);
        \\}
    ;
    var result = try compile(std.testing.allocator, "calculations.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{calc-reduced:3px;calc-variable:3px;calc-preserved:calc(100% - 20px);calc-relative:calc(1em + 2px);calc-dynamic:calc(var(--size));minimum:2px;maximum:3px;clamped:2px;converted-max:1in;converted-clamp:97px;relative-min:min(1em,2px);dynamic:max(var(--size),20px)}",
        result.css(),
    );
}

test "native Sass evaluates the dependency-free legacy color core" {
    const input =
        \\.a {
        \\  named: rebeccapurple;
        \\  alpha-hex: #ff000080;
        \\  rgb-percent: rgb(100%, 0%, 0%);
        \\  rgb-modern: rgb(255 0 0 / 50%);
        \\  rgba-color: rgba(red, .5);
        \\  hsl: hsl(120, 40%, 50%);
        \\  hsl-angle: hsl(.5turn, 100%, 50%);
        \\  hwb-normalized: hwb(0 80% 80%);
        \\  cross-space: purple == hsl(300, 100%, 25.098039215686%);
        \\  quoted-is-string: "red" == red;
        \\  red-channel: red(#123456);
        \\  green-channel: green(#123456);
        \\  blue-channel: blue(#123456);
        \\  alpha-channel: alpha(rgba(1, 2, 3, .4));
        \\  hue-channel: hue(hsl(120, 40%, 50%));
        \\  saturation-channel: saturation(hsl(120, 40%, 50%));
        \\  lightness-channel: lightness(hsl(120, 40%, 50%));
        \\}
    ;
    var result = try compile(std.testing.allocator, "colors.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{named:#639;alpha-hex:rgba(255,0,0,.5019607843);rgb-percent:red;rgb-modern:rgba(255,0,0,.5);rgba-color:rgba(255,0,0,.5);hsl:hsl(120,40%,50%);hsl-angle:aqua;hwb-normalized:hsl(0,0%,50%);cross-space:true;quoted-is-string:false;red-channel:18;green-channel:52;blue-channel:86;alpha-channel:.4;hue-channel:120deg;saturation-channel:40%;lightness-channel:50%}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass preserves dynamic colors and rejects invalid static colors" {
    const dynamic_input =
        \\$channel: var(--red);
        \\.a {
        \\  rgb: rgb($channel 0 0 / .5);
        \\  hsl: hsl(calc(var(--hue) + 10deg) 50% 50%);
        \\  fallback: rgb(var(--r, 1, 2), 0, 0);
        \\}
    ;
    var dynamic = try compile(
        std.testing.allocator,
        "dynamic-colors.scss",
        dynamic_input,
        .scss,
        .{},
    );
    defer dynamic.deinit();
    try std.testing.expectEqualStrings(
        ".a{rgb:rgb(var(--red) 0 0 / .5);hsl:hsl(calc(var(--hue) + 10deg) 50% 50%);fallback:rgb(var(--r, 1, 2),0,0)}",
        dynamic.css(),
    );

    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "short-rgb.scss", .input = ".a { color: rgb(1, 2); }" },
        .{ .name = "typed-rgb.scss", .input = ".a { color: rgb(red, 2, 3); }" },
        .{ .name = "unit-rgb.scss", .input = ".a { color: rgb(1px, 2, 3); }" },
        .{ .name = "unit-hsl.scss", .input = ".a { color: hsl(0, 2px, 3%); }" },
        .{ .name = "channel-type.scss", .input = ".a { value: red(1); }" },
        .{ .name = "comma-hwb.scss", .input = ".a { color: hwb(0, 20%, 30%); }" },
        .{ .name = "space-rgba-color.scss", .input = ".a { color: rgba(red 50%); }" },
        .{ .name = "mixed-color-syntax.scss", .input = ".a { color: rgb(1, 2, 3 / .5); }" },
        .{ .name = "double-alpha.scss", .input = ".a { color: rgb(1 2 3 / .5 / .4); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var limits = sass_evaluator.Limits{};
    limits.max_function_arguments = 2;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "color-argument-limit.scss",
            ".a { color: rgb(var(--red) 1 2); }",
            .scss,
            limits,
        ),
    );
}

test "native Sass evaluates legacy color manipulation without a provider" {
    const input =
        \\.a {
        \\  lighten: lighten(#123456, 10%);
        \\  darken: darken(#123456, 10%);
        \\  saturate: saturate(#669966, 20%);
        \\  desaturate: desaturate(#669966, 20%);
        \\  adjust-hue: adjust-hue(#123456, 30deg);
        \\  complement: complement(#123456);
        \\  grayscale-red: grayscale(red);
        \\  grayscale-base: grayscale(#123456);
        \\  invert: invert(#123456);
        \\  invert-weighted: invert(#123456, 25%);
        \\  mix: mix(red, blue);
        \\  mix-weighted: mix(red, blue, 25%);
        \\  mix-alpha: mix(rgba(255, 0, 0, .5), blue);
        \\  opacify: opacify(rgba(1, 2, 3, .4), .2);
        \\  fade-in: fade-in(rgba(1, 2, 3, .4), .2);
        \\  transparentize: transparentize(rgba(1, 2, 3, .4), .2);
        \\  fade-out: fade-out(rgba(1, 2, 3, .4), .2);
        \\  opacity-channel: opacity(rgba(1, 2, 3, .4));
        \\  filter-saturate: saturate(20%);
        \\  filter-grayscale: grayscale(20%);
        \\  filter-invert: invert(var(--amount));
        \\  filter-opacity: opacity(20%);
        \\  ie-hex: ie-hex-str(rgba(1, 2, 3, .4));
        \\}
    ;
    var result = try compile(std.testing.allocator, "color-manipulation.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{lighten:rgb(26.8269230769,77.5,128.1730769231);darken:rgb(9.1730769231,26.5,43.8269230769);saturate:hsl(120,40%,50%);desaturate:hsl(0,0%,50%);adjust-hue:#121256;complement:#563412;grayscale-red:hsl(0,0%,50%);grayscale-base:#343434;invert:#edcba9;invert-weighted:rgb(72.75,89.75,106.75);mix:hsl(300,100%,25%);mix-weighted:rgb(63.75,0,191.25);mix-alpha:rgba(63.75,0,191.25,.75);opacify:rgba(1,2,3,.6);fade-in:rgba(1,2,3,.6);transparentize:rgba(1,2,3,.2);fade-out:rgba(1,2,3,.2);opacity-channel:.4;filter-saturate:saturate(20%);filter-grayscale:grayscale(20%);filter-invert:invert(var(--amount));filter-opacity:opacity(20%);ie-hex:#66010203}",
        result.css(),
    );
}

test "native Sass legacy color manipulation rejects unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "short-mix.scss", .input = ".a { color: mix(red); }" },
        .{ .name = "mix-range.scss", .input = ".a { color: mix(red, blue, 101%); }" },
        .{ .name = "lighten-range.scss", .input = ".a { color: lighten(red, 101%); }" },
        .{ .name = "lighten-type.scss", .input = ".a { color: lighten(1, 10%); }" },
        .{ .name = "hue-unit.scss", .input = ".a { color: adjust-hue(red, 1px); }" },
        .{ .name = "complement-type.scss", .input = ".a { color: complement(1); }" },
        .{ .name = "opacify-unit.scss", .input = ".a { color: opacify(red, 20%); }" },
        .{ .name = "opacify-range.scss", .input = ".a { color: opacify(red, 2); }" },
        .{ .name = "transparentize-type.scss", .input = ".a { color: transparentize(1, .2); }" },
        .{ .name = "ie-hex-type.scss", .input = ".a { color: ie-hex-str(1); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass loads the built-in color module without a provider" {
    const input =
        \\$seed: 1;
        \\@use "sass:color";
        \\@use "sass:color" as palette;
        \\@use "sass:color" as *;
        \\.a {
        \\  default: color.adjust(#123456, $red: 10);
        \\  alias: palette.change(lab(50% 10 20), $a: 5, $space: lab);
        \\  star: scale(color(display-p3 .2 .3 .4), $red: 50%);
        \\  seed: $seed;
        \\}
    ;
    var result = try compile(std.testing.allocator, "color-module.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{default:#1c3456;alias:lab(50 5 20);star:color(display-p3 .6 .3 .4);seed:1}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:color" as c
        \\.a
        \\  adjusted: c.adjust(lab(50% 10 20), $a: 5, $space: lab)
        \\  changed: c.change(#123456, $blue: 100)
        \\  scaled: c.scale(#123456, $red: -50%)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "color-module.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".a{adjusted:lab(50 15 20);changed:#123464;scaled:#093456}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass queries math unit predicates without a provider" {
    const input =
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$order: 0;
        \\$first: null;
        \\@function stamp($value) {
        \\  $order: $order + 1 !global;
        \\  @if $order == 1 { $first: $value !global; }
        \\  @return $value;
        \\}
        \\.a {
        \\  compatible: math.compatible(1px, 1in);
        \\  incompatible: math.compatible(1px, 1s);
        \\  unitless-mixed: math.compatible(1, 2px);
        \\  percentage: math.compatible(1%, 2%);
        \\  percentage-length: math.compatible(1%, 2px);
        \\  compound: math.compatible(1px * 1s, 2in * 1ms);
        \\  custom: math.compatible(1foo, 2foo);
        \\  custom-case: math.compatible(1foo, 2FOO);
        \\  known-case: math.compatible(1PX, 2px);
        \\  alias: numbers.compatible(1deg, 1turn);
        \\  star: compatible(1s, 1ms);
        \\  is-unitless: math.is-unitless(1);
        \\  has-unit: math.is-unitless(1px);
        \\  cancelled: math.is-unitless(1px / 1in);
        \\  known-case-cancelled: math.is-unitless(1PX / 1in);
        \\  percent-unitless: math.is-unitless(1%);
        \\  named: math.compatible($number2: stamp(1in), $number1: stamp(1px));
        \\  first-evaluated: $first;
        \\  legacy-comparable: comparable(1px, 1in);
        \\  legacy-unitless: unitless(1);
        \\}
    ;
    var result = try compile(std.testing.allocator, "math-unit-predicates.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{compatible:true;incompatible:false;unitless-mixed:true;percentage:true;percentage-length:false;compound:true;custom:true;custom-case:false;known-case:false;alias:true;star:true;is-unitless:true;has-unit:false;cancelled:true;known-case-cancelled:false;percent-unitless:false;named:true;first-evaluated:1in;legacy-comparable:true;legacy-unitless:true}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:math" as m
        \\.sass
        \\  compatible: m.compatible(1px, 1in)
        \\  incompatible: m.compatible(1px, 1s)
        \\  mixed: m.compatible(1, 2px)
        \\  compound: m.compatible(1px * 1s, 2in * 1ms)
        \\  unitless: m.is-unitless(1)
        \\  unitful: m.is-unitless(1px)
        \\  cancelled: m.is-unitless(1px / 1in)
        \\  global: comparable(1px, 1in)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "math-unit-predicates.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{compatible:true;incompatible:false;mixed:true;compound:true;unitless:true;unitful:false;cancelled:true;global:true}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var css_functions = try compile(
        std.testing.allocator,
        "math-unit-predicate-globals.scss",
        "@use \"sass:math\"; .plain { compatible: compatible(1px, 1in); unitless: is-unitless(1); }",
        .scss,
        .{},
    );
    defer css_functions.deinit();
    try std.testing.expectEqualStrings(
        ".plain{compatible:compatible(1px, 1in);unitless:is-unitless(1)}",
        css_functions.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), css_functions.nativeDiagnostics().len);
}

test "native Sass math unit predicates reject unowned calls and unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-math-module.scss",
            .input = ".a { value: math.compatible(1px, 1in); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-undefined-limit.scss",
            .input = "@use \"sass:math\"; .a { value: math.random($undefined); }",
            .expected = error.UndefinedVariable,
        },
        .{
            .name = "unprefixed-math-random-undefined-limit.scss",
            .input = "@use \"sass:math\" as *; .a { value: random($undefined); }",
            .expected = error.UndefinedVariable,
        },
        .{
            .name = "case-sensitive-math-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.compatible(1px, 1in); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "duplicate-math-namespace.scss",
            .input = "@use \"sass:map\" as tools; @use \"sass:math\" as tools;",
            .expected = error.InvalidSassSyntax,
        },
        .{
            .name = "math-compatible-empty.scss",
            .input = "@use \"sass:math\"; $value: math.compatible();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-compatible-short.scss",
            .input = "@use \"sass:math\"; $value: math.compatible(1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-compatible-long.scss",
            .input = "@use \"sass:math\"; $value: math.compatible(1px, 1in, 1cm);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-compatible-type.scss",
            .input = "@use \"sass:math\"; $value: math.compatible(\"1px\", 1in);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-compatible-list-type.scss",
            .input = "@use \"sass:math\"; $value: math.compatible((1px, 1in), 1cm);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-compatible-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.compatible(1px, 1in, $other: 1cm);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-compatible-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.compatible($number1: 1px, $number1: 1in, $number2: 1cm);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-compatible-splat.scss",
            .input = "@use \"sass:math\"; $args: (1px, 1in); $value: math.compatible($args...);",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "math-is-unitless-empty.scss",
            .input = "@use \"sass:math\"; $value: math.is-unitless();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-is-unitless-long.scss",
            .input = "@use \"sass:math\"; $value: math.is-unitless(1, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-is-unitless-type.scss",
            .input = "@use \"sass:math\"; $value: math.is-unitless(null);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "legacy-comparable-type.scss",
            .input = "$value: comparable(red, 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "legacy-unitless-type.scss",
            .input = "$value: unitless(red);",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var argument_limits = sass_evaluator.Limits{};
    argument_limits.max_function_arguments = 1;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "math-compatible-argument-limit.scss",
            "@use \"sass:math\"; $value: math.compatible(1px, 1in);",
            .scss,
            argument_limits,
        ),
    );
}

test "native Sass serializes math units without a provider" {
    const input =
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$evaluations: 0;
        \\@function stamp($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.a {
        \\  unitless: math.unit(1);
        \\  px: math.unit(1px);
        \\  known-case: math.unit(1PX);
        \\  custom: math.unit(1Foo);
        \\  percent: math.unit(1%);
        \\  product: math.unit(1px * 1s);
        \\  reversed: math.unit(1s * 1px);
        \\  quotient: math.unit(1px / 1s);
        \\  denominator-only: math.unit(1 / 1s);
        \\  powers: math.unit(1px * 1px / 1s / 1s);
        \\  denominator-many: math.unit(1 / 1s / 1foo);
        \\  mixed-many: math.unit(1foo * 1bar / 1baz / 1qux);
        \\  cancelled: math.unit(1px / 1in);
        \\  alias: numbers.unit(1deg / 1s);
        \\  star: unit(1em / 1ms);
        \\  named: math.unit($number: stamp((1px / 1s)));
        \\  evaluations: $evaluations;
        \\  legacy: unit(1foo);
        \\}
    ;
    var result = try compile(std.testing.allocator, "math-unit.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{unitless:\"\";px:\"px\";known-case:\"PX\";custom:\"Foo\";percent:\"%\";product:\"px*s\";reversed:\"s*px\";quotient:\"px/s\";denominator-only:\"s^-1\";powers:\"px*px/(s*s)\";denominator-many:\"(s*foo)^-1\";mixed-many:\"foo*bar/(baz*qux)\";cancelled:\"\";alias:\"deg/s\";star:\"em/ms\";named:\"px/s\";evaluations:1;legacy:\"foo\"}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:math" as m
        \\.sass
        \\  unitless: m.unit(1)
        \\  single: m.unit(1px)
        \\  product: m.unit(1px * 1s)
        \\  quotient: m.unit(1px / 1s)
        \\  denominator: m.unit(1 / 1s / 1foo)
        \\  case: m.unit(1PX / 1in)
        \\  cancelled: m.unit(1px / 1in)
        \\  global: unit(1foo)
    ;
    var sass_result = try compile(std.testing.allocator, "math-unit.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{unitless:\"\";single:\"px\";product:\"px*s\";quotient:\"px/s\";denominator:\"(s*foo)^-1\";case:\"PX/in\";cancelled:\"\";global:\"foo\"}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass math unit serialization rejects unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-math-unit-module.scss",
            .input = ".a { value: math.unit(1px); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-math-unit-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.unit(1px); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-empty.scss",
            .input = "@use \"sass:math\"; $value: math.unit();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-long.scss",
            .input = "@use \"sass:math\"; $value: math.unit(1px, 2px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-string.scss",
            .input = "@use \"sass:math\"; $value: math.unit(\"1px\");",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-list.scss",
            .input = "@use \"sass:math\"; $value: math.unit((1px, 2px));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-null.scss",
            .input = "@use \"sass:math\"; $value: math.unit(null);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.unit($other: 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.unit($number: 1px, $number: 2px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-unit-splat.scss",
            .input = "@use \"sass:math\"; $args: (1px,); $value: math.unit($args...);",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "legacy-unit-type.scss",
            .input = "$value: unit(red);",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass evaluates unary math functions without a provider" {
    const input =
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$evaluations: 0;
        \\@function stamp($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.a {
        \\  abs: math.abs(-1.5px);
        \\  abs-percent: math.abs(-2%);
        \\  abs-compound-unit: math.unit(math.abs(-1px * 1s / 1foo));
        \\  ceil: math.ceil(1.2px);
        \\  ceil-negative: math.ceil(-1.8px);
        \\  ceil-zero: math.ceil(-.1px);
        \\  floor: math.floor(1.8s);
        \\  floor-negative: math.floor(-1.2s);
        \\  floor-zero: math.floor(.1s);
        \\  round-low: math.round(1.49em);
        \\  round-half: math.round(1.5em);
        \\  round-negative-half: math.round(-1.5em);
        \\  round-zero: math.round(-.49em);
        \\  round-case: math.round(1.5PX);
        \\  percentage: math.percentage(.125);
        \\  percentage-negative: math.percentage(-.125);
        \\  percentage-cancelled: math.percentage(1px / 1in);
        \\  alias: numbers.ceil(2.1ms);
        \\  star: floor(-2.1deg);
        \\  named: math.round($number: stamp(2.5foo));
        \\  evaluations: $evaluations;
        \\  legacy-abs: abs(-2px);
        \\  legacy-ceil: ceil(1.2px);
        \\  legacy-floor: floor(1.8px);
        \\  legacy-round: round(1.5px);
        \\  legacy-percentage: percentage(.125);
        \\}
    ;
    var result = try compile(std.testing.allocator, "math-unary.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{abs:1.5px;abs-percent:2%;abs-compound-unit:\"px*s/foo\";ceil:2px;ceil-negative:-1px;ceil-zero:0px;floor:1s;floor-negative:-2s;floor-zero:0s;round-low:1em;round-half:2em;round-negative-half:-2em;round-zero:0em;round-case:2PX;percentage:12.5%;percentage-negative:-12.5%;percentage-cancelled:1.0416666667%;alias:3ms;star:-3deg;named:3foo;evaluations:1;legacy-abs:2px;legacy-ceil:2px;legacy-floor:1px;legacy-round:2px;legacy-percentage:12.5%}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:math" as m
        \\.sass
        \\  abs: m.abs(-1.5px)
        \\  ceil: m.ceil(-1.2s)
        \\  floor: m.floor(1.8em)
        \\  round: m.round(-1.5deg)
        \\  percentage: m.percentage(.25)
        \\  global-abs: abs(-2foo)
        \\  global-ceil: ceil(1.2foo)
        \\  global-floor: floor(1.8foo)
        \\  global-round: round(1.5foo)
        \\  global-percentage: percentage(.25)
    ;
    var sass_result = try compile(std.testing.allocator, "math-unary.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{abs:1.5px;ceil:-1s;floor:1em;round:-2deg;percentage:25%;global-abs:2foo;global-ceil:2foo;global-floor:1foo;global-round:2foo;global-percentage:25%}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var css_result = try compile(
        std.testing.allocator,
        "math-unary-css-functions.scss",
        ".plain { abs: abs(var(--size)); abs-name: abs(foo); round: round(var(--size), 1px); round-name: round(foo); }",
        .scss,
        .{},
    );
    defer css_result.deinit();
    try std.testing.expectEqualStrings(
        ".plain{abs:abs(var(--size));abs-name:abs(foo);round:round(var(--size),1px);round-name:round(foo)}",
        css_result.css(),
    );

    const deferred_input =
        \\$evaluations: 0;
        \\@function dynamic($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.dynamic {
        \\  abs: abs(#{dynamic(foo)});
        \\  round: round(#{dynamic(bar)});
        \\  evaluations: $evaluations;
        \\}
    ;
    var deferred_result = try compile(
        std.testing.allocator,
        "math-unary-deferred.scss",
        deferred_input,
        .scss,
        .{},
    );
    defer deferred_result.deinit();
    try std.testing.expectEqualStrings(
        ".dynamic{abs:abs(foo);round:round(bar);evaluations:2}",
        deferred_result.css(),
    );
}

test "native Sass unary math functions reject unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-unary-math-module.scss",
            .input = ".a { value: math.abs(-1px); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-unary-math-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.ceil(1.2px); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-empty.scss",
            .input = "@use \"sass:math\"; $value: math.abs();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-long.scss",
            .input = "@use \"sass:math\"; $value: math.round(1.2px, 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-string.scss",
            .input = "@use \"sass:math\"; $value: math.abs(\"-1px\");",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-unquoted-string.scss",
            .input = "@use \"sass:math\"; $value: math.abs(foo);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-list.scss",
            .input = "@use \"sass:math\"; $value: math.ceil((1px, 2px));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-null.scss",
            .input = "@use \"sass:math\"; $value: math.floor(null);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-color.scss",
            .input = "@use \"sass:math\"; $value: math.round(red);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-unitful-percentage.scss",
            .input = "@use \"sass:math\"; $value: math.percentage(1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-overflowing-percentage.scss",
            .input = "@use \"sass:math\"; $value: math.percentage(1e308);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "unary-math-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.abs($other: $undefined);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.floor($number: 1.2px, $number: 2.3px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unary-math-splat.scss",
            .input = "@use \"sass:math\"; $args: (1px,); $value: math.abs($args...);",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "star-unary-math-css-value.scss",
            .input = "@use \"sass:math\" as *; $value: abs(var(--size));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "legacy-ceil-css-value.scss",
            .input = "$value: ceil(var(--size));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "legacy-abs-quoted-string.scss",
            .input = "$value: abs(\"foo\");",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "legacy-percentage-css-value.scss",
            .input = "$value: percentage(var(--size));",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass divides math values without a provider" {
    const input =
        \\@use "sass:list";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$evaluations: 0;
        \\@function stamp($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.a {
        \\  plain: math.div(6px, 2);
        \\  converted: math.div(1in, 96px);
        \\  decimal: math.div(1, 4);
        \\  quotient-unit: math.unit(math.div(1px, 1s));
        \\  denominator-unit: math.unit(math.div(1, 2px));
        \\  custom-case: math.unit(math.div(1Foo, 1foo));
        \\  alias: numbers.div(9s, 3);
        \\  star: div(8em, 4);
        \\  named: math.div($number2: stamp(2), $number1: stamp(10px));
        \\  evaluations: $evaluations;
        \\  strings: math.div(foo, bar);
        \\  booleans: math.div(true, false);
        \\  quoted: math.div("a b", c);
        \\  left-color-string: math.div(red, foo);
        \\  right-color: math.div(2, red);
        \\  nested-color: math.div((red, x), foo);
        \\  spaces: math.div((a b), (c d));
        \\  lists: math.div((a, b), (c, d));
        \\  brackets: math.div([a, b], [c d]);
        \\  null-left: math.div(null, b);
        \\  null-right: math.div(a, null);
        \\  legacy-separator: list.separator(math.div((a, b), (c, d)));
        \\  legacy-length: list.length(math.div((a, b), (c, d)));
        \\}
    ;
    var result = try compile(std.testing.allocator, "math-div.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{plain:3px;converted:1;decimal:.25;quotient-unit:\"px/s\";denominator-unit:\"px^-1\";custom-case:\"Foo/foo\";alias:3s;star:2em;named:5px;evaluations:2;strings:foo/bar;booleans:true/false;quoted:\"a b\"/c;left-color-string:red/foo;right-color:2/red;nested-color:red, x/foo;spaces:a b/c d;lists:a, b/c, d;brackets:[a, b]/[c d];null-left:/b;null-right:a/;legacy-separator:space;legacy-length:1}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:math" as m
        \\.sass
        \\  plain: m.div(8px, 2)
        \\  unit: m.unit(m.div(1s, 1px))
        \\  string: m.div(a, b)
        \\  starless: div(6px, 2)
    ;
    var sass_result = try compile(std.testing.allocator, "math-div.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{plain:4px;unit:\"s/px\";string:a/b;starless:div(6px, 2)}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var css_result = try compile(
        std.testing.allocator,
        "math-div-global.scss",
        ".plain { value: div(6px, 2); }",
        .scss,
        .{},
    );
    defer css_result.deinit();
    try std.testing.expectEqualStrings(".plain{value:div(6px, 2)}", css_result.css());
}

test "native Sass math division rejects unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-math-div-module.scss",
            .input = ".a { value: math.div(6px, 2); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-math-div-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.div(6px, 2); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-empty.scss",
            .input = "@use \"sass:math\"; $value: math.div();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-short.scss",
            .input = "@use \"sass:math\"; $value: math.div(1);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-long.scss",
            .input = "@use \"sass:math\"; $value: math.div(1, 2, 3);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-zero.scss",
            .input = "@use \"sass:math\"; $value: math.div(1, 0);",
            .expected = error.DivisionByZero,
        },
        .{
            .name = "math-div-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.div($other: $undefined, $number2: 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.div($number1: 1, $number1: 2, $number2: 3);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-splat.scss",
            .input = "@use \"sass:math\"; $args: (6px, 2); $value: math.div($args...);",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "math-div-compound-css.scss",
            .input = "@use \"sass:math\"; .a { value: math.div(1px, 1s); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-colors.scss",
            .input = "@use \"sass:math\"; $value: math.div(red, blue);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-color-number.scss",
            .input = "@use \"sass:math\"; $value: math.div(red, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-maps.scss",
            .input = "@use \"sass:math\"; $value: math.div((a: 1), (b: 2));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-div-empty-list.scss",
            .input = "@use \"sass:math\"; $value: math.div((), b);",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 8;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "math-div-temporary-limit.scss",
            "@use \"sass:math\"; $value: math.div(\"abcdef\", g);",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass evaluates powers roots and logarithms without a provider" {
    const input =
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$evaluations: 0;
        \\@function stamp($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.a {
        \\  pow: math.pow(2, 3);
        \\  pow-negative: math.pow(2, -3);
        \\  pow-fraction: math.pow(9, .5);
        \\  sqrt: math.sqrt(2);
        \\  sqrt-perfect: math.sqrt(81);
        \\  log: math.log(10);
        \\  log-base: math.log(8, 2);
        \\  log-half: math.log(.25, .5);
        \\  log-zero-base: math.log(8, 0);
        \\  alias: numbers.pow(3, 2);
        \\  star: sqrt(16);
        \\  named-pow: math.pow($exponent: stamp(3), $base: stamp(2));
        \\  named-log: math.log($base: stamp(2), $number: stamp(8));
        \\  evaluations: $evaluations;
        \\  legacy-pow: pow(2, 4);
        \\  legacy-sqrt: sqrt(25);
        \\  legacy-log: log(100, 10);
        \\}
    ;
    var result = try compile(std.testing.allocator, "math-powers.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{pow:8;pow-negative:.125;pow-fraction:3;sqrt:1.4142135624;sqrt-perfect:9;log:2.302585093;log-base:3;log-half:2;log-zero-base:0;alias:9;star:4;named-pow:8;named-log:3;evaluations:4;legacy-pow:16;legacy-sqrt:5;legacy-log:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:math" as m
        \\.sass
        \\  pow: m.pow(2, 5)
        \\  sqrt: m.sqrt(49)
        \\  log: m.log(27, 3)
        \\  globals: pow(2, 3) sqrt(4) log(8, 2)
    ;
    var sass_result = try compile(std.testing.allocator, "math-powers.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{pow:32;sqrt:7;log:3;globals:8 2 3}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var css_result = try compile(
        std.testing.allocator,
        "math-powers-global.scss",
        ".plain { pow: pow(var(--base), 2); pow-name: pow(foo, 2); sqrt: sqrt(var(--number)); sqrt-name: sqrt(foo); log: log(var(--number), 2); log-name: log(foo); }",
        .scss,
        .{},
    );
    defer css_result.deinit();
    try std.testing.expectEqualStrings(
        ".plain{pow:pow(var(--base),2);pow-name:pow(foo,2);sqrt:sqrt(var(--number));sqrt-name:sqrt(foo);log:log(var(--number),2);log-name:log(foo)}",
        css_result.css(),
    );

    const deferred_input =
        \\$evaluations: 0;
        \\@function dynamic($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.dynamic {
        \\  pow: pow(#{dynamic(foo)}, 2);
        \\  sqrt: sqrt(#{dynamic(bar)});
        \\  log: log(#{dynamic(baz)}, 2);
        \\  evaluations: $evaluations;
        \\}
    ;
    var deferred_result = try compile(
        std.testing.allocator,
        "math-powers-deferred.scss",
        deferred_input,
        .scss,
        .{},
    );
    defer deferred_result.deinit();
    try std.testing.expectEqualStrings(
        ".dynamic{pow:pow(foo,2);sqrt:sqrt(bar);log:log(baz,2);evaluations:3}",
        deferred_result.css(),
    );
}

test "native Sass powers roots and logarithms reject unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-math-pow-module.scss",
            .input = ".a { value: math.pow(2, 3); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-math-pow-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.pow(2, 3); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-pow-empty.scss",
            .input = "@use \"sass:math\"; $value: math.pow();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-pow-short.scss",
            .input = "@use \"sass:math\"; $value: math.pow(2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-pow-long.scss",
            .input = "@use \"sass:math\"; $value: math.pow(2, 3, 4);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sqrt-empty.scss",
            .input = "@use \"sass:math\"; $value: math.sqrt();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sqrt-long.scss",
            .input = "@use \"sass:math\"; $value: math.sqrt(4, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-log-empty.scss",
            .input = "@use \"sass:math\"; $value: math.log();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-log-long.scss",
            .input = "@use \"sass:math\"; $value: math.log(8, 2, 1);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-pow-unit-base.scss",
            .input = "@use \"sass:math\"; $value: math.pow(2px, 3);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-pow-unit-exponent.scss",
            .input = "@use \"sass:math\"; $value: math.pow(2, 3px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sqrt-unit.scss",
            .input = "@use \"sass:math\"; $value: math.sqrt(4px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-log-unit.scss",
            .input = "@use \"sass:math\"; $value: math.log(8px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-log-unit-base.scss",
            .input = "@use \"sass:math\"; $value: math.log(8, 2px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-pow-string.scss",
            .input = "@use \"sass:math\"; $value: math.pow(foo, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sqrt-string.scss",
            .input = "@use \"sass:math\"; $value: math.sqrt(foo);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-log-string.scss",
            .input = "@use \"sass:math\"; $value: math.log(foo);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sqrt-negative.scss",
            .input = "@use \"sass:math\"; $value: math.sqrt(-1);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-log-zero.scss",
            .input = "@use \"sass:math\"; $value: math.log(0);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-log-negative.scss",
            .input = "@use \"sass:math\"; $value: math.log(-1);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-log-base-one.scss",
            .input = "@use \"sass:math\"; $value: math.log(8, 1);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-pow-infinite.scss",
            .input = "@use \"sass:math\"; $value: math.pow(0, -1);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-pow-nan.scss",
            .input = "@use \"sass:math\"; $value: math.pow(-1, .5);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-pow-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.pow($other: $undefined, $exponent: 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-log-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.log($number: 8, $number: 4);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sqrt-splat.scss",
            .input = "@use \"sass:math\"; $args: (4,); $value: math.sqrt($args...);",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "global-pow-named-dynamic.scss",
            .input = "$value: pow($base: var(--base), $exponent: 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-pow-quoted.scss",
            .input = "$value: pow(\"foo\", 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-sqrt-list.scss",
            .input = "$value: sqrt((1, 2));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-log-color.scss",
            .input = "$value: log(red, 2);",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass evaluates trigonometric functions without a provider" {
    const input =
        \\@use "sass:math";
        \\@use "sass:math" as trig;
        \\@use "sass:math" as *;
        \\$evaluations: 0;
        \\@function stamp($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.a {
        \\  sin-zero: math.sin(0);
        \\  sin-deg: math.sin(30deg);
        \\  sin-grad: math.sin(100grad);
        \\  sin-turn: math.sin(.25turn);
        \\  sin-rad: math.sin(1rad);
        \\  cos-zero: math.cos(0);
        \\  cos-deg: math.cos(60deg);
        \\  tan: math.tan(45deg);
        \\  asin: math.asin(.5);
        \\  acos: math.acos(.5);
        \\  atan: math.atan(1);
        \\  atan-negative: math.atan(-1);
        \\  atan2: math.atan2(1, 1);
        \\  atan2-units: math.atan2(1in, 96px);
        \\  atan2-percent: math.atan2(1%, 2%);
        \\  atan2-compound: math.atan2(math.div(1px, 1s), math.div(96in, 1s));
        \\  atan2-custom: math.atan2(2foo, 1foo);
        \\  atan2-zero: math.atan2(0, 0);
        \\  atan2-negative-x-zero: math.atan2(0, -0);
        \\  atan2-negative-zero-pair: math.atan2(-0, -0);
        \\  atan2-negative-y-zero: math.atan2(-0, 0);
        \\  atan2-negative: math.atan2(-1, -1);
        \\  alias: trig.sin(90deg);
        \\  star: cos(180deg);
        \\  named: math.atan2($x: stamp(1), $y: stamp(1));
        \\  evaluations: $evaluations;
        \\  global-sin: sin(30deg);
        \\  global-cos: cos(60deg);
        \\  global-tan: tan(45deg);
        \\  global-asin: asin(.5);
        \\  global-acos: acos(.5);
        \\  global-atan: atan(1);
        \\  global-atan2: atan2(1, 1);
        \\}
    ;
    var result = try compile(std.testing.allocator, "math-trig.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{sin-zero:0;sin-deg:.5;sin-grad:1;sin-turn:1;sin-rad:.8414709848;cos-zero:1;cos-deg:.5;tan:1;asin:30deg;acos:60deg;atan:45deg;atan-negative:-45deg;atan2:45deg;atan2-units:45deg;atan2-percent:26.5650511771deg;atan2-compound:.0062169899deg;atan2-custom:63.4349488229deg;atan2-zero:0deg;atan2-negative-x-zero:180deg;atan2-negative-zero-pair:-180deg;atan2-negative-y-zero:0deg;atan2-negative:-135deg;alias:1;star:-1;named:45deg;evaluations:2;global-sin:.5;global-cos:.5;global-tan:1;global-asin:30deg;global-acos:60deg;global-atan:45deg;global-atan2:45deg}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:math" as m
        \\.sass
        \\  sin: m.sin(30deg)
        \\  cos: m.cos(60deg)
        \\  tan: m.tan(45deg)
        \\  asin: m.asin(.5)
        \\  acos: m.acos(.5)
        \\  atan: m.atan(1)
        \\  atan2: m.atan2(1in, 96px)
        \\  globals: sin(30deg) cos(60deg) tan(45deg) asin(.5) acos(.5) atan(1) atan2(1, 1)
    ;
    var sass_result = try compile(std.testing.allocator, "math-trig.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{sin:.5;cos:.5;tan:1;asin:30deg;acos:60deg;atan:45deg;atan2:45deg;globals:.5 .5 1 30deg 60deg 45deg 45deg}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var css_result = try compile(
        std.testing.allocator,
        "math-trig-global.scss",
        ".plain { sin: sin(var(--number)); sin-name: sin(foo); cos: cos(var(--number)); cos-name: cos(foo); tan: tan(var(--number)); tan-name: tan(foo); asin: asin(var(--number)); asin-name: asin(foo); acos: acos(var(--number)); acos-name: acos(foo); atan: atan(var(--number)); atan-name: atan(foo); atan2: atan2(var(--y), 1); atan2-name: atan2(foo, bar); }",
        .scss,
        .{},
    );
    defer css_result.deinit();
    try std.testing.expectEqualStrings(
        ".plain{sin:sin(var(--number));sin-name:sin(foo);cos:cos(var(--number));cos-name:cos(foo);tan:tan(var(--number));tan-name:tan(foo);asin:asin(var(--number));asin-name:asin(foo);acos:acos(var(--number));acos-name:acos(foo);atan:atan(var(--number));atan-name:atan(foo);atan2:atan2(var(--y),1);atan2-name:atan2(foo,bar)}",
        css_result.css(),
    );

    const deferred_input =
        \\$evaluations: 0;
        \\@function dynamic($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.dynamic {
        \\  sin: sin(#{dynamic(foo)});
        \\  atan2: atan2(#{dynamic(bar)}, 1);
        \\  evaluations: $evaluations;
        \\}
    ;
    var deferred_result = try compile(
        std.testing.allocator,
        "math-trig-deferred.scss",
        deferred_input,
        .scss,
        .{},
    );
    defer deferred_result.deinit();
    try std.testing.expectEqualStrings(
        ".dynamic{sin:sin(foo);atan2:atan2(bar,1);evaluations:2}",
        deferred_result.css(),
    );
}

test "native Sass trigonometric functions reject unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-math-sin-module.scss",
            .input = ".a { value: math.sin(30deg); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-math-sin-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.sin(30deg); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sin-empty.scss",
            .input = "@use \"sass:math\"; $value: math.sin();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sin-long.scss",
            .input = "@use \"sass:math\"; $value: math.sin(0, 1);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-atan2-short.scss",
            .input = "@use \"sass:math\"; $value: math.atan2(1);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-atan2-long.scss",
            .input = "@use \"sass:math\"; $value: math.atan2(1, 2, 3);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sin-length.scss",
            .input = "@use \"sass:math\"; $value: math.sin(1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sin-custom-unit.scss",
            .input = "@use \"sass:math\"; $value: math.sin(1foo);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sin-cased-angle.scss",
            .input = "@use \"sass:math\"; $value: math.sin(30DEG);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-sin-compound-unit.scss",
            .input = "@use \"sass:math\"; $value: math.sin(1px / 1s);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-asin-unit.scss",
            .input = "@use \"sass:math\"; $value: math.asin(1deg);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-acos-percentage.scss",
            .input = "@use \"sass:math\"; $value: math.acos(50%);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-atan-unit.scss",
            .input = "@use \"sass:math\"; $value: math.atan(1deg);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-asin-nan.scss",
            .input = "@use \"sass:math\"; $value: math.asin(2);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-acos-nan.scss",
            .input = "@use \"sass:math\"; $value: math.acos(-2);",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "math-atan2-mixed-units.scss",
            .input = "@use \"sass:math\"; $value: math.atan2(1px, 1);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-atan2-incompatible-units.scss",
            .input = "@use \"sass:math\"; $value: math.atan2(1px, 1s);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-atan2-cased-custom-unit.scss",
            .input = "@use \"sass:math\"; $value: math.atan2(1Foo, 1foo);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-sin-string.scss",
            .input = "@use \"sass:math\"; $value: math.sin(foo);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-atan2-color.scss",
            .input = "@use \"sass:math\"; $value: math.atan2(red, 1);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-cos-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.cos($other: $undefined);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-atan2-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.atan2($y: 1, $y: 2, $x: 1);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-tan-splat.scss",
            .input = "@use \"sass:math\"; $args: (45deg,); $value: math.tan($args...);",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "unprefixed-math-sin-string.scss",
            .input = "@use \"sass:math\" as *; $value: sin(foo);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "module-math-sin-dynamic.scss",
            .input = "@use \"sass:math\"; $value: math.sin(var(--number));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-math-sin-named-dynamic.scss",
            .input = "$value: sin($number: var(--number));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-math-sin-quoted.scss",
            .input = "$value: sin(\"foo\");",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-math-atan-list.scss",
            .input = "$value: atan((1, 2));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-math-atan2-color.scss",
            .input = "$value: atan2(red, blue);",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass evaluates extrema clamping and hypotenuse without a provider" {
    const input =
        \\@use "sass:math";
        \\@use "sass:math" as ext;
        \\@use "sass:math" as *;
        \\$evaluations: 0;
        \\@function stamp($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\$minimums: (3px, 1px, 2px);
        \\$legs: (5foo, 12foo);
        \\.a {
        \\  min: math.min(3px, 1px, 2px);
        \\  min-converted: math.min(1in, 95px);
        \\  min-unitless: math.min(1px, 2);
        \\  min-negative: math.min(-1px, -2px);
        \\  max: math.max(3px, 1px, 2px);
        \\  max-converted: math.max(1in, 97px);
        \\  max-unitless: math.max(1px, 2);
        \\  max-negative: math.max(-1px, -2px);
        \\  clamp: math.clamp(1px, 2px, 3px);
        \\  clamp-low: math.clamp(1px, -2px, 3px);
        \\  clamp-high: math.clamp(1px, 4px, 3px);
        \\  clamp-equal: math.clamp(96px, 1in, 2in);
        \\  hypot: math.hypot(3px, 4px);
        \\  hypot-converted: math.hypot(1in, 96px);
        \\  hypot-frequency: math.hypot(1Hz, 2kHz);
        \\  hypot-percent: math.hypot(3%, 4%);
        \\  hypot-custom: math.hypot($legs...);
        \\  hypot-one: math.hypot(-3px);
        \\  hypot-compound-unit: math.unit(math.hypot(math.div(3px, 1s), math.div(4px, 1s)));
        \\  alias: ext.min(5s, 3s);
        \\  star: max(1em, 2em);
        \\  splat: math.min($minimums...);
        \\  named-clamp: math.clamp($max: stamp(3px), $number: stamp(2px), $min: stamp(1px));
        \\  evaluations: $evaluations;
        \\  min-zero-angle: math.atan2(0, math.min(0, -0));
        \\  max-zero-angle: math.atan2(0, math.max(-0, 0));
        \\  clamp-zero-angle: math.atan2(0, math.clamp(-0, -0, 0));
        \\  hypot-zero-angle: math.atan2(0, math.hypot(-0, -0));
        \\  global-min: min(3ms, 2ms);
        \\  global-max: max(3deg, 4deg);
        \\  global-clamp: clamp(1foo, 2foo, 3foo);
        \\  global-hypot: hypot(8px, 15px);
        \\}
    ;
    var result = try compile(std.testing.allocator, "math-extrema.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{min:1px;min-converted:95px;min-unitless:1px;min-negative:-2px;max:3px;max-converted:97px;max-unitless:2;max-negative:-1px;clamp:2px;clamp-low:1px;clamp-high:3px;clamp-equal:96px;hypot:5px;hypot-converted:1.4142135624in;hypot-frequency:2000.00025Hz;hypot-percent:5%;hypot-custom:13foo;hypot-one:3px;hypot-compound-unit:\"px/s\";alias:3s;star:2em;splat:1px;named-clamp:2px;evaluations:3;min-zero-angle:0deg;max-zero-angle:180deg;clamp-zero-angle:180deg;hypot-zero-angle:0deg;global-min:2ms;global-max:4deg;global-clamp:2foo;global-hypot:17px}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:math" as m
        \\.sass
        \\  min: m.min(3px, 1px, 2px)
        \\  max: m.max(1s, 2s)
        \\  clamp: m.clamp(1em, 2em, 3em)
        \\  hypot: m.hypot(3foo, 4foo)
        \\  globals: min(3px, 1px) max(1s, 2s) clamp(1em, 2em, 3em) hypot(3foo, 4foo)
    ;
    var sass_result = try compile(std.testing.allocator, "math-extrema.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{min:1px;max:2s;clamp:2em;hypot:5foo;globals:1px 2s 2em 5foo}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var global_result = try compile(
        std.testing.allocator,
        "math-extrema-global.scss",
        ".plain { static-min: min(3px, 1px); static-max: max(1s, 2s); static-clamp: clamp(1em, 2em, 3em); static-hypot: hypot(3foo, 4foo); relative-hypot: hypot(1em, 2px); min: min(var(--x), 1px); min-name: min(foo, 1px); max: max(var(--x), 2px); max-name: max(foo, 2px); clamp: clamp(1px, var(--x), 3px); clamp-name: clamp(1px, foo, 3px); hypot: hypot(var(--x), 4px); hypot-name: hypot(foo, 4px); }",
        .scss,
        .{},
    );
    defer global_result.deinit();
    try std.testing.expectEqualStrings(
        ".plain{static-min:1px;static-max:2s;static-clamp:2em;static-hypot:5foo;relative-hypot:hypot(1em,2px);min:min(var(--x),1px);min-name:min(foo,1px);max:max(var(--x),2px);max-name:max(foo,2px);clamp:clamp(1px,var(--x),3px);clamp-name:clamp(1px,foo,3px);hypot:hypot(var(--x),4px);hypot-name:hypot(foo,4px)}",
        global_result.css(),
    );

    const deferred_input =
        \\$evaluations: 0;
        \\@function dynamic($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.dynamic {
        \\  min: min(#{dynamic(var(--a))}, 1px);
        \\  max: max(#{dynamic(var(--b))}, 2px);
        \\  clamp: clamp(1px, #{dynamic(var(--c))}, 3px);
        \\  hypot: hypot(#{dynamic(var(--d))}, 4px);
        \\  evaluations: $evaluations;
        \\}
    ;
    var deferred_result = try compile(
        std.testing.allocator,
        "math-extrema-deferred.scss",
        deferred_input,
        .scss,
        .{},
    );
    defer deferred_result.deinit();
    try std.testing.expectEqualStrings(
        ".dynamic{min:min(var(--a),1px);max:max(var(--b),2px);clamp:clamp(1px,var(--c),3px);hypot:hypot(var(--d),4px);evaluations:4}",
        deferred_result.css(),
    );
}

test "native Sass extrema clamping and hypotenuse reject unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-math-min-module.scss",
            .input = ".a { value: math.min(1px, 2px); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-math-min-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.min(1px, 2px); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-min-empty.scss",
            .input = "@use \"sass:math\"; $value: math.min();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-max-empty.scss",
            .input = "@use \"sass:math\"; $value: math.max();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-hypot-empty.scss",
            .input = "@use \"sass:math\"; $value: math.hypot();",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-clamp-short.scss",
            .input = "@use \"sass:math\"; $value: math.clamp(1px, 2px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-clamp-long.scss",
            .input = "@use \"sass:math\"; $value: math.clamp(1px, 2px, 3px, 4px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-min-incompatible.scss",
            .input = "@use \"sass:math\"; $value: math.min(1px, 1s);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-max-cased-custom.scss",
            .input = "@use \"sass:math\"; $value: math.max(1Foo, 2foo);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-clamp-mixed.scss",
            .input = "@use \"sass:math\"; $value: math.clamp(1px, 2, 3px);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-clamp-incompatible.scss",
            .input = "@use \"sass:math\"; $value: math.clamp(1px, 2s, 3px);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-hypot-mixed.scss",
            .input = "@use \"sass:math\"; $value: math.hypot(3px, 4);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-hypot-incompatible.scss",
            .input = "@use \"sass:math\"; $value: math.hypot(3px, 4s);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-hypot-cased-frequency.scss",
            .input = "@use \"sass:math\"; $value: math.hypot(1hz, 2khz);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "global-hypot-incompatible.scss",
            .input = "$value: hypot(1px, 2s);",
            .expected = error.IncompatibleUnits,
        },
        .{
            .name = "math-min-color.scss",
            .input = "@use \"sass:math\"; $value: math.min(red, 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-max-quoted.scss",
            .input = "@use \"sass:math\"; $value: math.max(\"foo\", 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-clamp-string.scss",
            .input = "@use \"sass:math\"; $value: math.clamp(1px, foo, 3px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-hypot-list.scss",
            .input = "@use \"sass:math\"; $value: math.hypot((3px, 4px));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-min-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.min($other: 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-clamp-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.clamp($min: 1px, $number: 2px, $other: 3px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-clamp-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.clamp($min: 1px, $min: 2px, $number: 2px, $max: 3px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "module-math-min-dynamic.scss",
            .input = "@use \"sass:math\"; $value: math.min(var(--x), 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "module-math-hypot-dynamic.scss",
            .input = "@use \"sass:math\"; $value: math.hypot(var(--x), 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unprefixed-math-max-string.scss",
            .input = "@use \"sass:math\" as *; $value: max(foo, 1px);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-hypot-nonfinite.scss",
            .input = "@use \"sass:math\"; $value: math.hypot(1e308, 1e308, 1e308, 1e308);",
            .expected = error.InvalidNumber,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var limits = sass_evaluator.Limits{};
    limits.max_function_arguments = 2;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "math-extrema-argument-limit.scss",
            "@use \"sass:math\"; $value: math.min(1px, 2px, 3px);",
            .scss,
            limits,
        ),
    );
}

test "native Sass resolves math constants and deterministic random values without a provider" {
    const constants =
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\@function local-pi() { $pi: 1; @return $pi; }
        \\.constants {
        \\  e: math.$e;
        \\  pi: math.$pi;
        \\  epsilon-scaled: math.$epsilon * 1000000000000000;
        \\  max-ratio: math.div(math.$max-number, 1e300);
        \\  max-safe: math.$max-safe-integer;
        \\  min-number: math.$min-number;
        \\  min-safe: math.$min-safe-integer;
        \\  alias: numbers.$pi;
        \\  star: $e;
        \\  underscore: math.$max_safe_integer;
        \\  trig: math.sin(math.div(math.$pi, 2));
        \\  interpolated: #{math.$pi};
        \\  local-shadow: local-pi();
        \\}
    ;
    var constants_result = try compile(
        std.testing.allocator,
        "math-constants.scss",
        constants,
        .scss,
        .{},
    );
    defer constants_result.deinit();
    try std.testing.expectEqualStrings(
        ".constants{e:2.7182818285;pi:3.1415926536;epsilon-scaled:.2220446049;max-ratio:179769313.48623157;max-safe:9007199254740991;min-number:0;min-safe:-9007199254740991;alias:3.1415926536;star:2.7182818285;underscore:9007199254740991;trig:1;interpolated:3.1415926536;local-shadow:1}",
        constants_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), constants_result.nativeDiagnostics().len);

    const random =
        \\@use "sass:math";
        \\@use "sass:math" as rng;
        \\@use "sass:math" as *;
        \\$evaluations: 0;
        \\@function stamp($value) { $evaluations: $evaluations + 1 !global; @return $value; }
        \\$unit-a: math.random();
        \\$unit-b: math.random(null);
        \\$unit-c: math.random();
        \\$bounded: math.random(5);
        \\$named: rng.random($limit: 7);
        \\$splat: random((9,)...);
        \\$map-splat: math.random((limit: 11)...);
        \\$empty-splat: math.random(()...);
        \\$overridden: math.random($limit: 0, (limit: 5)...);
        \\$maximum: math.random(4294967296);
        \\$stamped: math.random($limit: stamp(6));
        \\$unit-limit: math.random(4px);
        \\.random {
        \\  unit-range: $unit-a >= 0 and $unit-a < 1 and $unit-b >= 0 and $unit-b < 1 and $unit-c >= 0 and $unit-c < 1;
        \\  sequence-varies: $unit-a != $unit-b or $unit-b != $unit-c;
        \\  bounded-range: $bounded >= 1 and $bounded <= 5 and $bounded == math.floor($bounded);
        \\  named-range: $named >= 1 and $named <= 7 and $named == math.floor($named);
        \\  splat-range: $splat >= 1 and $splat <= 9 and $splat == math.floor($splat);
        \\  map-splat-range: $map-splat >= 1 and $map-splat <= 11 and $map-splat == math.floor($map-splat);
        \\  empty-splat-range: $empty-splat >= 0 and $empty-splat < 1;
        \\  override-range: $overridden >= 1 and $overridden <= 5;
        \\  maximum-range: $maximum >= 1 and $maximum <= 4294967296 and $maximum == math.floor($maximum);
        \\  stamped-range: $stamped >= 1 and $stamped <= 6 and $evaluations == 1;
        \\  unit-limit-range: $unit-limit >= 1 and $unit-limit <= 4 and $unit-limit == math.floor($unit-limit) and math.is-unitless($unit-limit);
        \\  samples: $unit-a $unit-b $unit-c $bounded $named $splat $map-splat $empty-splat $overridden $maximum $stamped $unit-limit;
        \\}
    ;
    var first_random = try compile(
        std.testing.allocator,
        "math-random-first.scss",
        random,
        .scss,
        .{},
    );
    defer first_random.deinit();
    var replay_random = try compile(
        std.testing.allocator,
        "math-random-replay.scss",
        random,
        .scss,
        .{},
    );
    defer replay_random.deinit();
    try std.testing.expectEqualStrings(first_random.css(), replay_random.css());
    try std.testing.expect(std.mem.startsWith(
        u8,
        first_random.css(),
        ".random{unit-range:true;sequence-varies:true;bounded-range:true;named-range:true;splat-range:true;map-splat-range:true;empty-splat-range:true;override-range:true;maximum-range:true;stamped-range:true;unit-limit-range:true;samples:",
    ));
    try std.testing.expect(std.mem.endsWith(u8, first_random.css(), "}"));

    const deterministic_golden =
        \\@use "sass:math";
        \\.golden {
        \\  first: math.random();
        \\  bounded: math.random(10);
        \\  second: math.random();
        \\}
    ;
    var golden_result = try compile(
        std.testing.allocator,
        "math-random-golden.scss",
        deterministic_golden,
        .scss,
        .{},
    );
    defer golden_result.deinit();
    try std.testing.expectEqualStrings(
        ".golden{first:.7417619928;bounded:5;second:.2622934202}",
        golden_result.css(),
    );

    const indented =
        \\@use "sass:math" as m
        \\$sample: m.random(8)
        \\.sass
        \\  e: m.$e
        \\  pi: m.$pi
        \\  safe: m.$min-safe-integer
        \\  random-range: $sample >= 1 and $sample <= 8 and $sample == m.floor($sample)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "math-constants-random.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{e:2.7182818285;pi:3.1415926536;safe:-9007199254740991;random-range:true}",
        sass_result.css(),
    );

    const global_random =
        \\$sample: random(6);
        \\.global { range: $sample >= 1 and $sample <= 6; sample: $sample; }
    ;
    var first_global = try compile(
        std.testing.allocator,
        "math-global-random-first.scss",
        global_random,
        .scss,
        .{},
    );
    defer first_global.deinit();
    var replay_global = try compile(
        std.testing.allocator,
        "math-global-random-replay.scss",
        global_random,
        .scss,
        .{},
    );
    defer replay_global.deinit();
    try std.testing.expectEqualStrings(first_global.css(), replay_global.css());
    try std.testing.expect(std.mem.startsWith(u8, first_global.css(), ".global{range:true;sample:"));
    try std.testing.expect(std.mem.endsWith(u8, first_global.css(), "}"));
}

test "native Sass math constants and random reject unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-math-constant-module.scss",
            .input = ".a { value: math.$pi; }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "plain-math-constant-without-star.scss",
            .input = "@use \"sass:math\"; .a { value: $pi; }",
            .expected = error.UndefinedVariable,
        },
        .{
            .name = "unknown-math-constant.scss",
            .input = "@use \"sass:math\"; .a { value: math.$unknown; }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "cased-math-constant.scss",
            .input = "@use \"sass:math\"; .a { value: math.$PI; }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-math-constant-namespace.scss",
            .input = "@use \"sass:math\" as Math; .a { value: math.$pi; }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "wrong-module-math-constant.scss",
            .input = "@use \"sass:list\"; .a { value: list.$pi; }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "modify-star-math-constant.scss",
            .input = "@use \"sass:math\" as *; $pi: 1; .a { value: $pi; }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "modify-qualified-math-constant.scss",
            .input = "@use \"sass:math\"; math.$pi: 1; .a { value: math.$pi; }",
            .expected = error.InvalidSyntax,
        },
        .{
            .name = "preexisting-star-math-constant.scss",
            .input = "$pi: 1; @use \"sass:math\" as *; .a { value: $pi; }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "global-modify-star-math-constant.scss",
            .input = "@use \"sass:math\" as *; @function mutate() { $pi: 1 !global; @return $pi; } .a { value: mutate(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-decimal.scss",
            .input = "@use \"sass:math\"; $value: math.random(2.5);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-zero.scss",
            .input = "@use \"sass:math\"; $value: math.random(0);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-negative.scss",
            .input = "@use \"sass:math\"; $value: math.random(-2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-bound-too-large.scss",
            .input = "@use \"sass:math\"; $value: math.random(4294967297);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-string.scss",
            .input = "@use \"sass:math\"; $value: math.random(foo);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-dynamic.scss",
            .input = "@use \"sass:math\"; $value: math.random(var(--limit));",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-too-many.scss",
            .input = "@use \"sass:math\"; $value: math.random(1, 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-unknown-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.random($other: 2);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-duplicate-keyword.scss",
            .input = "@use \"sass:math\"; $value: math.random(2, $limit: 3);",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "math-random-position-and-map-splat.scss",
            .input = "@use \"sass:math\"; $value: math.random(2, (limit: 3)...);",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass meta inspection reports exact types and canonical representations" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as introspect;
        \\@use "sass:meta" as *;
        \\@use "sass:list";
        \\@use "sass:map";
        \\$empty-map: map.remove((a: 1), a);
        \\@function argument-type($args...) { @return meta.type-of($args); }
        \\@function argument-inspect($args...) {
        \\  $keywords: meta.keywords($args);
        \\  @return meta.inspect($args);
        \\}
        \\.values {
        \\  null-type: meta.type-of(null);
        \\  bool-type: meta.type-of(true);
        \\  number-type: meta.type-of(1px);
        \\  string-type: meta.type-of("hello");
        \\  color-type: meta.type-of(#abc);
        \\  list-type: meta.type-of((1, 2));
        \\  map-type: meta.type-of((a: 1));
        \\  calculation-type: meta.type-of(calc(1px + var(--x)));
        \\  css-variable-type: meta.type-of(var(--x));
        \\  uppercase-calculation-type: meta.type-of(CALC(1px + var(--x)));
        \\  composite-type: meta.type-of(foo calc(1px + var(--x)));
        \\  empty-map-type: meta.type-of($empty-map);
        \\  arglist-type: argument-type(1, 2);
        \\  null-inspect: meta.inspect(null);
        \\  bool-inspect: meta.inspect(true);
        \\  number-inspect: meta.inspect(1px);
        \\  quoted-inspect: meta.inspect("hello world");
        \\  unquoted-inspect: meta.inspect(hello world);
        \\  color-inspect: meta.inspect(#a1b2c3);
        \\  comma-inspect: meta.inspect((1, 2));
        \\  space-inspect: meta.inspect(1 2);
        \\  bracket-inspect: meta.inspect([1 2]);
        \\  slash-inspect: meta.inspect(list.slash(1, 2));
        \\  map-inspect: meta.inspect((a: 1, "b": (2, 3)));
        \\  empty-map-inspect: meta.inspect($empty-map);
        \\  null-list-inspect: meta.inspect((null, 1, null));
        \\  calculation-inspect: meta.inspect(calc(1px + var(--x)));
        \\  arglist-inspect: argument-inspect(1, 2);
        \\  single-arglist-inspect: argument-inspect(1);
        \\  keyword-arglist-inspect: argument-inspect(1, $tone: red);
        \\  alias: introspect.type-of($value: #abc);
        \\  star: inspect((a: 1));
        \\  global-type: type-of(1px);
        \\}
    ;
    var result = try compile(std.testing.allocator, "meta-inspection.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{null-type:null;bool-type:bool;number-type:number;string-type:string;color-type:color;list-type:list;map-type:map;calculation-type:calculation;css-variable-type:string;uppercase-calculation-type:calculation;composite-type:list;empty-map-type:map;arglist-type:arglist;null-inspect:null;bool-inspect:true;number-inspect:1px;quoted-inspect:\"hello world\";unquoted-inspect:hello world;color-inspect:#a1b2c3;comma-inspect:1, 2;space-inspect:1 2;bracket-inspect:[1 2];slash-inspect:1 / 2;map-inspect:(a: 1, \"b\": (2, 3));empty-map-inspect:();null-list-inspect:null, 1, null;calculation-inspect:calc(1px + var(--x));arglist-inspect:1, 2;single-arglist-inspect:(1,);keyword-arglist-inspect:(1,);alias:color;star:(a: 1);global-type:number}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\.sass
        \\  type: m.type-of((a: 1))
        \\  inspect: m.inspect([1 2])
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-inspection.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(".sass{type:map;inspect:[1 2]}", sass_result.css());
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta calculation introspection names and materializes retained arguments" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as introspect;
        \\@use "sass:meta" as *;
        \\@use "sass:list";
        \\$calc-args: meta.calc-args(calc(1px + var(--x)));
        \\$min-args: meta.calc-args(min(var(--x, 1px), max(2px, var(--y, 3px))));
        \\$round-args: meta.calc-args(round(to-zero, var(--x), 1px));
        \\$spaced: EXP(  var(--x)  );
        \\$commented: min(1px/**/,/**/var(--x));
        \\.values {
        \\  calc: meta.calc-name(calc(1px + var(--x)));
        \\  min: meta.calc-name(min(1px, var(--x)));
        \\  max: meta.calc-name(max(1px, var(--x)));
        \\  clamp: meta.calc-name(clamp(1px, var(--x), 3px));
        \\  round: meta.calc-name(round(var(--x), 1px));
        \\  mod: meta.calc-name(mod(var(--x), 3px));
        \\  rem: meta.calc-name(rem(var(--x), 3px));
        \\  sin: meta.calc-name(sin(var(--x)));
        \\  cos: meta.calc-name(cos(var(--x)));
        \\  tan: meta.calc-name(tan(var(--x)));
        \\  asin: meta.calc-name(asin(var(--x)));
        \\  acos: meta.calc-name(acos(var(--x)));
        \\  atan: meta.calc-name(atan(var(--x)));
        \\  atan2: meta.calc-name(atan2(var(--x), 1));
        \\  pow: meta.calc-name(pow(var(--x), 2));
        \\  sqrt: meta.calc-name(sqrt(var(--x)));
        \\  hypot: meta.calc-name(hypot(var(--x), 4px));
        \\  log: meta.calc-name(log(var(--x), 2));
        \\  exp: meta.calc-name(exp(var(--x)));
        \\  abs: meta.calc-name(abs(var(--x)));
        \\  sign: meta.calc-name(sign(var(--x)));
        \\  uppercase: meta.calc-name(CALC(1px + var(--x)));
        \\  escaped: meta.calc-name(c\61 lc(1px + var(--x)));
        \\  simple-escaped: meta.calc-name(ca\lc(1px + var(--x)));
        \\  escaped-type: meta.type-of(c\61 lc(1px + var(--x)));
        \\  escaped-inspect: meta.inspect(ca\lc(1px + var(--x)));
        \\  spaced-inspect: meta.inspect($spaced);
        \\  commented-inspect: meta.inspect($commented);
        \\  commented-args: meta.inspect(meta.calc-args($commented));
        \\  calc-args: meta.inspect($calc-args);
        \\  calc-count: list.length($calc-args);
        \\  calc-first-type: meta.type-of(list.nth($calc-args, 1));
        \\  min-args: meta.inspect($min-args);
        \\  min-count: list.length($min-args);
        \\  min-first-type: meta.type-of(list.nth($min-args, 1));
        \\  min-second-type: meta.type-of(list.nth($min-args, 2));
        \\  round-args: meta.inspect($round-args);
        \\  round-first-type: meta.type-of(list.nth($round-args, 1));
        \\  round-third-type: meta.type-of(list.nth($round-args, 3));
        \\  keyword: introspect.calc-name($calc: max(1px, var(--x)));
        \\  underscore: meta.calc_name(calc(1px + var(--x)));
        \\  alias-args: introspect.inspect(introspect.calc-args(clamp(1px, var(--x), 3px)));
        \\  star: calc-name(min(1px, var(--x)));
        \\  star-args: inspect(calc-args(max(1px, var(--x))));
        \\  reflected: meta.function-exists("calc-name", "meta");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-calculation-introspection.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{calc:\"calc\";min:\"min\";max:\"max\";clamp:\"clamp\";round:\"round\";mod:\"mod\";rem:\"rem\";sin:\"sin\";cos:\"cos\";tan:\"tan\";asin:\"asin\";acos:\"acos\";atan:\"atan\";atan2:\"atan2\";pow:\"pow\";sqrt:\"sqrt\";hypot:\"hypot\";log:\"log\";exp:\"exp\";abs:\"abs\";sign:\"sign\";uppercase:\"calc\";escaped:\"calc\";simple-escaped:\"calc\";escaped-type:calculation;escaped-inspect:calc(1px + var(--x));spaced-inspect:exp(var(--x));commented-inspect:min(1px, var(--x));commented-args:1px, var(--x);calc-args:(1px + var(--x),);calc-count:1;calc-first-type:string;min-args:var(--x, 1px), max(2px, var(--y, 3px));min-count:2;min-first-type:string;min-second-type:calculation;round-args:to-zero, var(--x), 1px;round-first-type:string;round-third-type:number;keyword:\"max\";underscore:\"calc\";alias-args:1px, var(--x), 3px;star:\"min\";star-args:1px, var(--x);reflected:true}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\.sass
        \\  name: m.calc-name(calc(1px + var(--x)))
        \\  args: m.inspect(m.calc-args(min(1px, var(--x))))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-calculation-introspection.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{name:\"calc\";args:1px, var(--x)}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var unowned = try compile(
        std.testing.allocator,
        "meta-calculation-unowned.scss",
        ".unowned { value: calc-name(calc(1px + var(--x))); }",
        .scss,
        .{},
    );
    defer unowned.deinit();
    try std.testing.expectEqualStrings(
        ".unowned{value:calc-name(calc(1px + var(--x)))}",
        unowned.css(),
    );
}

test "native Sass meta calculation introspection rejects non-calculations and preserves ceilings" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "meta-calc-name-missing-module.scss",
            .input = ".a { value: meta.calc-name(calc(1px + var(--x))); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-name-case-namespace.scss",
            .input = "@use \"sass:meta\" as Meta; .a { value: meta.calc-name(calc(1px + var(--x))); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-name-number.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-name(1px); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-name-reduced.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-name(calc(1px + 2px)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-name-quoted.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-name(\"calc(1px)\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-args-map.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-args((a: 1)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-args-composite.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-args(foo calc(1px + var(--x))); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-name-missing.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-name(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-args-too-many.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-args(calc(1px + var(--x)), 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-name-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-name($value: calc(1px + var(--x))); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-calc-name-duplicate.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.calc-name(calc(1px + var(--x)), $calc: calc(2px + var(--y))); }",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 16;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "meta-calc-temporary-limit.scss",
            "@use \"sass:meta\"; .a { value: meta.calc-name(calc(1px + var(--long-name))); }",
            .scss,
            temporary_limits,
        ),
    );

    var argument_limits = sass_evaluator.Limits{};
    argument_limits.max_function_arguments = 1;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "meta-calc-argument-limit.scss",
            "@use \"sass:meta\"; .a { value: meta.calc-args(mod(var(--x), 1px)); }",
            .scss,
            argument_limits,
        ),
    );
}

test "native Sass meta existence queries inspect scope declarations globals and built-in modules" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\@use "sass:list";
        \\@use "sass:map";
        \\@use "sass:selector";
        \\@use "sass:string";
        \\$global_name: 1;
        \\.before {
        \\  function: meta.function-exists("later_fn");
        \\  mixin: meta.mixin-exists("later_mix");
        \\}
        \\@function later_fn() { @return 1; }
        \\@mixin later_mix() { $inside: true; }
        \\@function scope_probe() {
        \\  $local_name: 2;
        \\  @return meta.inspect((
        \\    local: meta.variable-exists("local_name"),
        \\    local-global: meta.global-variable-exists("local-name"),
        \\    outer: meta.variable-exists("global-name"),
        \\    outer-global: meta.global-variable-exists("global_name")
        \\  ));
        \\}
        \\.values {
        \\  function: meta.function-exists("later_fn");
        \\  function-hyphen: meta.function-exists("later-fn");
        \\  function-escaped: meta.function-exists("later\2d fn");
        \\  function-case: meta.function-exists("LATER-FN");
        \\  mixin: meta.mixin-exists("later_mix");
        \\  variable: meta.variable-exists("global_name");
        \\  global: meta.global-variable-exists("global-name");
        \\  dollar: meta.variable-exists("$global-name");
        \\  scope: scope_probe();
        \\  builtin: meta.function-exists("rgb");
        \\  keywords-global: meta.function-exists("keywords");
        \\  keywords-module: meta.function-exists("keywords", "meta");
        \\  module: meta.function-exists("ceil", "numbers");
        \\  module-missing: meta.function-exists("nope", "numbers");
        \\  module-variable: meta.global-variable-exists("pi", "numbers");
        \\  star-function: meta.function-exists("compatible");
        \\  star-variable: meta.variable-exists("pi");
        \\  star-global: meta.global-variable-exists("pi");
        \\  list: meta.function-exists("append", "list");
        \\  map: meta.function-exists("get", "map");
        \\  selector: meta.function-exists("parse", "selector");
        \\  string: meta.function-exists("quote", "string");
        \\  keyword: meta.function-exists($module: "numbers", $name: "ceil");
        \\}
    ;
    var result = try compile(std.testing.allocator, "meta-existence.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".before{function:false;mixin:false}.values{function:true;function-hyphen:true;function-escaped:true;function-case:false;mixin:true;variable:true;global:true;dollar:false;scope:(local: true, local-global: false, outer: true, outer-global: true);builtin:true;keywords-global:true;keywords-module:true;module:true;module-missing:false;module-variable:true;star-function:true;star-variable:true;star-global:true;list:true;map:true;selector:true;string:true;keyword:true}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$global_name: 1
        \\@function native_fn()
        \\  @return 1
        \\@mixin native_mix()
        \\  $inside: true
        \\.sass
        \\  function: m.function-exists("native_fn")
        \\  mixin: m.mixin-exists("native_mix")
        \\  variable: m.variable-exists("global_name")
        \\  global: m.global-variable-exists("global-name")
        \\  module: m.function-exists("ceil", "numbers")
        \\  missing: m.function-exists("nope", "numbers")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-existence.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{function:true;mixin:true;variable:true;global:true;module:true;missing:false}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass feature existence owns the exact supported set and spelling" {
    const cases = [_]struct {
        name: []const u8,
        expected: bool,
    }{
        .{ .name = "global-variable-shadowing", .expected = true },
        .{ .name = "extend-selector-pseudoclass", .expected = true },
        .{ .name = "units-level-3", .expected = true },
        .{ .name = "at-error", .expected = true },
        .{ .name = "custom-property", .expected = true },
        .{ .name = "at\\2d error", .expected = true },
        .{ .name = "at_error", .expected = false },
        .{ .name = "AT-ERROR", .expected = false },
        .{ .name = "unknown", .expected = false },
    };
    for (cases) |case| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "@use \"sass:meta\"; .feature {{ value: meta.feature-exists(\"{s}\"); }}",
            .{case.name},
        );
        defer std.testing.allocator.free(input);
        var result = try compile(
            std.testing.allocator,
            "meta-feature-exists.scss",
            input,
            .scss,
            .{},
        );
        defer result.deinit();
        try std.testing.expectEqualStrings(
            if (case.expected) ".feature{value:true}" else ".feature{value:false}",
            result.css(),
        );
        const diagnostics = result.nativeDiagnostics();
        try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostics[0].severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostics[0].code,
        );
        try std.testing.expectEqualStrings(
            "The feature-exists() function is deprecated.",
            diagnostics[0].message,
        );
    }
}

test "native Sass meta existence queries preserve feature and legacy deprecation warnings" {
    const input =
        \\@use "sass:meta";
        \\.warnings {
        \\  module-feature: meta.feature-exists("at-error");
        \\  module-unknown: meta.feature-exists("unknown");
        \\  global-feature: feature-exists("custom-property");
        \\  global-function: function-exists("rgb");
        \\  global-mixin: mixin-exists("missing");
        \\  global-variable: variable-exists("missing");
        \\  global-global: global-variable-exists("missing");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-existence-warnings.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".warnings{module-feature:true;module-unknown:false;global-feature:true;global-function:true;global-mixin:false;global-variable:false;global-global:false}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 8), diagnostics.len);
    var global_warnings: usize = 0;
    var feature_warnings: usize = 0;
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(preprocessor.diagnostics.Severity.warning, diagnostic.severity);
        try std.testing.expectEqual(preprocessor.diagnostics.Code.invalid_operation, diagnostic.code);
        if (std.mem.eql(
            u8,
            diagnostic.message,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        )) {
            global_warnings += 1;
        } else if (std.mem.eql(
            u8,
            diagnostic.message,
            "The feature-exists() function is deprecated.",
        )) {
            feature_warnings += 1;
        } else {
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), global_warnings);
    try std.testing.expectEqual(@as(usize, 3), feature_warnings);
}

test "native Sass meta existence queries reject invalid reflection and preserve resource ceilings" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "meta-function-exists-missing-module.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.function-exists(\"ceil\", \"math\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-function-exists-number-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.function-exists(1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-function-exists-number-module.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.function-exists(\"ceil\", 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-function-exists-missing-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.function-exists(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-function-exists-too-many.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.function-exists(\"rgb\", null, 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-function-exists-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.function-exists($function: \"rgb\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-variable-exists-module.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.variable-exists(\"x\", null); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-feature-exists-number.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.feature-exists(1); }",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 3;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "meta-existence-temporary-limit.scss",
            "@use \"sass:meta\"; .a { value: meta.function-exists(\"long-name\"); }",
            .scss,
            temporary_limits,
        ),
    );

    var transaction_limits = evaluator.Limits{};
    transaction_limits.diagnostics.max_diagnostics = 1;
    try std.testing.expectError(
        error.DiagnosticLimitExceeded,
        compileWithTransactionLimits(
            std.testing.allocator,
            "meta-existence-diagnostic-limit.scss",
            "@use \"sass:meta\"; .a { one: meta.feature-exists(\"at-error\"); two: meta.feature-exists(\"custom-property\"); }",
            .scss,
            .{},
            transaction_limits,
        ),
    );
}

test "native Sass meta content existence reflects only the active mixin invocation" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\@mixin child {
        \\  .child { present: meta.content-exists(); }
        \\}
        \\@mixin sink($label, $exists) {
        \\  .argument-#{$label} { value: $exists; }
        \\}
        \\@mixin probe($label) {
        \\  .#{$label} {
        \\    module: meta.content-exists();
        \\    alias: reflect.content_exists();
        \\    star: content-exists();
        \\    reflected: meta.function-exists("content-exists", "meta");
        \\  }
        \\  @include sink($label, meta.content-exists());
        \\  @include child;
        \\  @if meta.content-exists() { @content; }
        \\}
        \\@include probe(empty);
        \\@include probe(filled) { .payload { ok: yes; } }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-content-existence.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".empty{module:false;alias:false;star:false;reflected:true}.argument-empty{value:false}.child{present:false}.filled{module:true;alias:true;star:true;reflected:true}.argument-filled{value:true}.child{present:false}.payload{ok:yes}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@mixin probe
        \\  .sass
        \\    value: m.content-exists()
        \\  @if m.content-exists()
        \\    @content
        \\@include probe
        \\@include probe
        \\  .payload
        \\    ok: yes
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-content-existence.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{value:false}.sass{value:true}.payload{ok:yes}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta content existence preserves the legacy warning" {
    const input =
        \\@mixin legacy-probe {
        \\  .legacy { value: content-exists(); }
        \\  @content;
        \\}
        \\@include legacy-probe { .legacy-content { ok: yes; } }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-content-existence-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{value:true}.legacy-content{ok:yes}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        diagnostics[0].message,
    );
}

test "native Sass meta content existence rejects calls outside a mixin body" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "meta-content-exists-at-root.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.content-exists(); }",
        },
        .{
            .name = "global-content-exists-at-root.scss",
            .input = ".a { value: content-exists(); }",
        },
        .{
            .name = "meta-content-exists-in-function.scss",
            .input = "@use \"sass:meta\"; @function probe() { @return meta.content-exists(); } @mixin outer { .a { value: probe(); } } @include outer;",
        },
        .{
            .name = "meta-content-exists-in-caller-content.scss",
            .input = "@use \"sass:meta\"; @mixin outer { @content; } @include outer { .a { value: meta.content-exists(); } }",
        },
        .{
            .name = "meta-content-exists-in-mixin-default.scss",
            .input = "@use \"sass:meta\"; @mixin inner($exists: meta.content-exists()) { .a { value: $exists; } } @mixin outer { @include inner; @content; } @include outer { .b { ok: yes; } }",
        },
        .{
            .name = "meta-content-exists-in-content-default.scss",
            .input = "@use \"sass:meta\"; @mixin supply { @content; } @include supply using ($exists: meta.content-exists()) { .a { value: $exists; } }",
        },
        .{
            .name = "meta-content-exists-missing-module.scss",
            .input = "@mixin probe { .a { value: meta.content-exists(); } } @include probe;",
        },
        .{
            .name = "meta-content-exists-case-namespace.scss",
            .input = "@use \"sass:meta\" as Meta; @mixin probe { .a { value: meta.content-exists(); } } @include probe;",
        },
        .{
            .name = "meta-content-exists-too-many.scss",
            .input = "@use \"sass:meta\"; @mixin probe { .a { value: meta.content-exists(1); } } @include probe;",
        },
        .{
            .name = "meta-content-exists-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @mixin probe { .a { value: meta.content-exists($other: 1); } } @include probe;",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass meta mixin references preserve callable identity and module ownership" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\@mixin first_name {}
        \\@mixin second {}
        \\$first: meta.get-mixin("first-name");
        \\$escaped: meta.get-mixin("\66 irst-name");
        \\$marked: meta.get-mixin(mark("first_name"), mark(null));
        \\@mixin first-name {}
        \\$replacement: meta.get-mixin("first-name");
        \\.values {
        \\  type: meta.type-of($first);
        \\  same: $first == $escaped;
        \\  redefined: $first == $replacement;
        \\  different: $first == meta.get-mixin("second");
        \\  alias: reflect.type-of(reflect.get_mixin("second"));
        \\  star: type-of(get-mixin("second"));
        \\  builtin: meta.type-of(meta.get-mixin("load-css", "meta"));
        \\  builtin-alias: meta.get-mixin("load_css", "meta") == reflect.get-mixin("load-css", "reflect");
        \\  builtin-apply: meta.type-of(meta.get-mixin("apply", "meta"));
        \\  builtin-distinct: meta.get-mixin("load-css", "meta") == meta.get-mixin("apply", "meta");
        \\  builtin-reflected: meta.mixin-exists("load-css", "meta");
        \\  apply-reflected: meta.mixin-exists("apply", "meta");
        \\  reflected: meta.function-exists("get-mixin", "meta");
        \\  evaluations: $evaluations;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-mixin-references.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{type:mixin;same:true;redefined:false;different:false;alias:mixin;star:mixin;builtin:mixin;builtin-alias:true;builtin-apply:mixin;builtin-distinct:false;builtin-reflected:true;apply-reflected:true;reflected:true;evaluations:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@mixin first_name
        \\  $inside: true
        \\.sass
        \\  type: m.type-of(m.get-mixin("first-name"))
        \\  same: m.get-mixin("first_name") == m.get-mixin("first-name")
        \\  builtin: m.type-of(m.get-mixin("load-css", "m"))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-mixin-references.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{type:mixin;same:true;builtin:mixin}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta mixin references preserve the legacy warning" {
    const input =
        \\@use "sass:meta";
        \\@mixin legacy_probe {}
        \\.legacy { type: meta.type-of(get-mixin("legacy-probe")); }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-mixin-reference-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".legacy{type:mixin}", result.css());
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        diagnostics[0].message,
    );
}

test "native Sass meta mixin references reject invalid or unavailable reflection" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "meta-get-mixin-before-declaration.scss",
            .input = "@use \"sass:meta\"; $reference: meta.get-mixin(\"later\"); @mixin later {}",
        },
        .{
            .name = "meta-get-mixin-missing.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-mixin(\"missing\")); }",
        },
        .{
            .name = "meta-get-mixin-case.scss",
            .input = "@use \"sass:meta\"; @mixin Mixed {} .a { value: meta.type-of(meta.get-mixin(\"mixed\")); }",
        },
        .{
            .name = "meta-get-mixin-local-builtin.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-mixin(\"load-css\")); }",
        },
        .{
            .name = "meta-get-mixin-user-from-module.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.type-of(meta.get-mixin(\"local\", \"meta\")); }",
        },
        .{
            .name = "meta-get-mixin-loaded-module-missing.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.type-of(meta.get-mixin(\"ceil\", \"math\")); }",
        },
        .{
            .name = "meta-get-mixin-unloaded-module.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-mixin(\"load-css\", \"reflect\")); }",
        },
        .{
            .name = "meta-get-mixin-number-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-mixin(1)); }",
        },
        .{
            .name = "meta-get-mixin-number-module.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.type-of(meta.get-mixin(\"local\", 1)); }",
        },
        .{
            .name = "meta-get-mixin-missing-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-mixin()); }",
        },
        .{
            .name = "meta-get-mixin-too-many.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.type-of(meta.get-mixin(\"local\", null, 1)); }",
        },
        .{
            .name = "meta-get-mixin-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.type-of(meta.get-mixin($mixin: \"local\")); }",
        },
        .{
            .name = "meta-get-mixin-callable-css.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.get-mixin(\"local\"); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 3;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "meta-get-mixin-temporary-limit.scss",
            "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-mixin(\"long-name\")); }",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass meta function references preserve callable identity and module ownership" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as arithmetic;
        \\@use "sass:selector" as selectors;
        \\@use "sass:selector" as *;
        \\$evaluations: 0;
        \\$trace: 0;
        \\@function mark($tag, $value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  $trace: $trace * 10 + $tag !global;
        \\  @return $value;
        \\}
        \\@function first_name($value) { @return $value; }
        \\@function second($value) { @return $value; }
        \\$first: meta.get-function("first-name");
        \\$escaped: meta.get-function("\66 irst_name");
        \\$marked: meta.get-function(mark(1, "first_name"), $css: mark(2, false), $module: mark(3, null));
        \\@function first-name($value) { @return $value; }
        \\$replacement: meta.get-function("first-name");
        \\.values {
        \\  type: meta.type-of($first);
        \\  same: $first == $escaped;
        \\  marked: $first == $marked;
        \\  redefined: $first == $replacement;
        \\  different: $first == meta.get-function("second");
        \\  alias: reflect.type-of(reflect.get_function("second"));
        \\  star: type-of(get-function("second"));
        \\  global: meta.type-of(meta.get-function("length", $css: false));
        \\  global-alias: meta.get-function("str_length") == meta.get-function("str-length", $css: null);
        \\  module: meta.type-of(meta.get-function("ceil", $module: "numbers"));
        \\  module-alias: meta.get-function("ceil", $module: "numbers") == reflect.get-function("ceil", $module: "arithmetic");
        \\  star-module: meta.get-function("parse") == meta.get-function("parse", $module: "selectors");
        \\  global-distinct: meta.get-function("ceil") == meta.get-function("ceil", $module: "numbers");
        \\  own: meta.type-of(meta.get-function("type-of", $module: "meta"));
        \\  own-alias: meta.get-function("type_of", $module: "meta") == reflect.get-function("type-of", $module: "reflect");
        \\  conditional: meta.type-of(meta.get-function("if"));
        \\  conditional-same: meta.get-function("if") == meta.get-function("if");
        \\  reflected: meta.function-exists("get-function", "meta");
        \\  evaluations: $evaluations;
        \\  trace: $trace;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-function-references.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{type:function;same:true;marked:true;redefined:false;different:false;alias:function;star:function;global:function;global-alias:true;module:function;module-alias:true;star-module:true;global-distinct:false;own:function;own-alias:true;conditional:function;conditional-same:true;reflected:true;evaluations:3;trace:123}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\@function first_name($value)
        \\  @return $value
        \\.sass
        \\  user: m.type-of(m.get-function("first-name"))
        \\  same: m.get-function("first_name") == m.get-function("first-name")
        \\  module: m.type-of(m.get-function("ceil", $module: "numbers"))
        \\  global-distinct: m.get-function("ceil") == m.get-function("ceil", $module: "numbers")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-function-references.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{user:function;same:true;module:function;global-distinct:false}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta function references preserve the legacy warning" {
    const input =
        \\@use "sass:meta";
        \\@function legacy_probe($value) { @return $value; }
        \\.legacy { type: meta.type-of(get-function("legacy-probe")); }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-function-reference-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".legacy{type:function}", result.css());
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        diagnostics[0].message,
    );
}

test "native Sass meta inspection renders function and mixin references canonically" {
    const input =
        \\@use "sass:color";
        \\@use "sass:list";
        \\@use "sass:map";
        \\@use "sass:math";
        \\@use "sass:meta";
        \\@use "sass:selector";
        \\@use "sass:string";
        \\@function first_name($value) { @return $value; }
        \\@mixin first_mixin {}
        \\$user-function: meta.get-function("first_name");
        \\$user-mixin: meta.get-mixin("first_mixin");
        \\.values {
        \\  user-function: meta.inspect($user-function);
        \\  global-map: meta.inspect(meta.get-function("map_get"));
        \\  global-list: meta.inspect(meta.get-function("index"));
        \\  global-math: meta.inspect(meta.get-function("comparable"));
        \\  global-string: meta.inspect(meta.get-function("str_length"));
        \\  module-color: meta.inspect(meta.get-function("adjust", $module: "color"));
        \\  module-list: meta.inspect(meta.get-function("is_bracketed", $module: "list"));
        \\  module-map: meta.inspect(meta.get-function("deep_merge", $module: "map"));
        \\  module-math: meta.inspect(meta.get-function("is_unitless", $module: "math"));
        \\  module-meta: meta.inspect(meta.get-function("accepts_content", $module: "meta"));
        \\  module-selector: meta.inspect(meta.get-function("simple_selectors", $module: "selector"));
        \\  module-string: meta.inspect(meta.get-function("to_upper_case", $module: "string"));
        \\  conditional: meta.inspect(meta.get-function("if"));
        \\  user-mixin: meta.inspect($user-mixin);
        \\  builtin-mixin: meta.inspect(meta.get-mixin("load_css", "meta"));
        \\  nested: meta.inspect(($user-function, (kind: $user-mixin)));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-callable-inspection.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{user-function:get-function(\"first-name\");global-map:get-function(\"map-get\");global-list:get-function(\"index\");global-math:get-function(\"comparable\");global-string:get-function(\"str-length\");module-color:get-function(\"adjust\");module-list:get-function(\"is-bracketed\");module-map:get-function(\"deep-merge\");module-math:get-function(\"is-unitless\");module-meta:get-function(\"accepts-content\");module-selector:get-function(\"simple-selectors\");module-string:get-function(\"to-upper-case\");conditional:get-function(\"if\");user-mixin:get-mixin(\"first-mixin\");builtin-mixin:get-mixin(\"load-css\");nested:get-function(\"first-name\"), (kind: get-mixin(\"first-mixin\"))}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math"
        \\@function first_name($value)
        \\  @return $value
        \\@mixin first_mixin
        \\  $inside: true
        \\.sass
        \\  function: m.inspect(m.get-function("first_name"))
        \\  module: m.inspect(m.get-function("ceil", $module: "math"))
        \\  mixin: m.inspect(m.get-mixin("first_mixin"))
        \\  builtin-mixin: m.inspect(m.get-mixin("apply", "m"))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-callable-inspection.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{function:get-function(\"first-name\");module:get-function(\"ceil\");mixin:get-mixin(\"first-mixin\");builtin-mixin:get-mixin(\"apply\")}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call invokes user function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@function collect($first, $second: 2, $rest...) {
        \\  @return meta.inspect(($first, $second, $rest, meta.keywords($rest)));
        \\}
        \\@function forward($fn, $args...) {
        \\  @return meta.call($fn, $args...);
        \\}
        \\@function choice($value) { @return $value; }
        \\$old-choice: meta.get-function("choice");
        \\@function choice($value) { @return $value + 100; }
        \\$new-choice: meta.get-function("choice");
        \\$collector: meta.get-function("collect");
        \\.values {
        \\  direct: meta.call($collector, 1);
        \\  named: reflect.call($collector, $second: 4, $first: 3);
        \\  list-splat: call($collector, (5, 6)...);
        \\  map-splat: meta.call($collector, (first: 7, second: 8, named: 9)...);
        \\  forwarded: forward($collector, 10, $second: 11, $named: 12);
        \\  ordered: meta.call(mark(1, $collector), mark(2, 13), $second: mark(3, 14));
        \\  trace: $trace;
        \\  old: meta.call($old-choice, 1);
        \\  new: meta.call($new-choice, 1);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-user-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{direct:1, 2, (), ();named:3, 4, (), ();list-splat:5, 6, (), ();map-splat:7, 8, (), (named: 9);forwarded:10, 11, (), (named: 12);ordered:13, 14, (), ();trace:123;old:1;new:101}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@function double($value)
        \\  @return $value * 2
        \\$fn: m.get-function("double")
        \\.sass
        \\  direct: m.call($fn, 4)
        \\  named: m.call($function: $fn, $value: 5)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-user-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{direct:8;named:10}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call invokes list function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\@use "sass:list" as seq;
        \\@use "sass:list" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@function forward($function, $args...) {
        \\  @return meta.call($function, $args...);
        \\}
        \\$nth: meta.get-function("nth", $module: "seq");
        \\$length: meta.get-function("length", $module: "seq");
        \\$index: meta.get-function("index", $module: "seq");
        \\$separator: meta.get-function("separator", $module: "seq");
        \\$append: meta.get-function("append", $module: "seq");
        \\$set-nth: meta.get-function("set-nth", $module: "seq");
        \\$join: meta.get-function("join", $module: "seq");
        \\$zip: meta.get-function("zip", $module: "seq");
        \\$slash: meta.get-function("slash", $module: "seq");
        \\.values {
        \\  nth: meta.call($nth, $n: 2, $list: (a, b));
        \\  length: reflect.call($function: $length, $list: [a b c]);
        \\  index: meta.call($index, (a, b), b);
        \\  separator: meta.call($separator, (a b));
        \\  append: meta.inspect(meta.call($append, (list: (a, b), val: c, separator: space)...));
        \\  set-nth: meta.inspect(meta.call($set-nth, (a, b, c), 2, x));
        \\  join: meta.inspect(meta.call($join, (a, b), (c, d), $bracketed: true));
        \\  zip: meta.inspect(meta.call($zip, ((a, b), (1, 2))...));
        \\  slash: meta.inspect(meta.call($slash, 10px, 2s, 3));
        \\  ordered: meta.call(mark(1, $nth), $list: mark(2, (x, y)), $n: mark(3, 2));
        \\  forwarded: forward($nth, $list: (p, q), $n: 2);
        \\  trace: $trace;
        \\  star: call(meta.get-function("is-bracketed"), [x]);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-list-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{nth:b;length:3;index:2;separator:space;append:a b c;set-nth:a, x, c;join:[a, b, c, d];zip:a 1, b 2;slash:10px / 2s / 3;ordered:y;forwarded:q;trace:123;star:true}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:list" as seq
        \\$nth: m.get-function("nth", $module: "seq")
        \\$slash: m.get-function("slash", $module: "seq")
        \\.sass
        \\  named: m.call($nth, $list: (a, b), $n: 2)
        \\  slash: m.inspect(m.call($slash, 4px, 2s))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-list-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{named:b;slash:4px / 2s}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves list function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$length: meta.get-function("length");
        \\.legacy { value: meta.call($length, (a, b)); }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-list-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".legacy{value:2}", result.css());
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        diagnostics[0].message,
    );
}

test "native Sass meta call invokes map query function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:map" as maps;
        \\@use "sass:map" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@function forward($function, $args...) {
        \\  @return meta.call($function, $args...);
        \\}
        \\$get: meta.get-function("get", $module: "maps");
        \\$has: meta.get-function("has-key", $module: "maps");
        \\$keys: meta.get-function("keys", $module: "maps");
        \\$values: meta.get-function("values", $module: "maps");
        \\$star: meta.get-function("get");
        \\$theme: (nested: (tone: blue, alt: red), plain: 2);
        \\$query: ($theme, nested, tone);
        \\.values {
        \\  get: meta.call($get, $theme, nested, tone);
        \\  missing: meta.call($get, $theme, nested, absent);
        \\  has: meta.call($has, $theme, nested, tone);
        \\  absent: meta.call($has, $theme, plain, tone);
        \\  keys: meta.inspect(meta.call($keys, (a: 1, b: 2)));
        \\  values: meta.inspect(meta.call($values, (a: 1, b: 2)));
        \\  named: meta.inspect(meta.call($get, $key: nested, $map: $theme));
        \\  forwarded: forward($get, $theme, nested, alt);
        \\  list-splat: meta.call($get, $query...);
        \\  map-splat: meta.call($get, (map: $theme, key: plain)...);
        \\  ordered: meta.call(mark(1, $get), mark(2, $theme), mark(3, nested), mark(4, tone));
        \\  trace: $trace;
        \\  star: meta.call($star, $theme, plain);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-map-query-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{get:blue;has:true;absent:false;keys:a, b;values:1, 2;named:(tone: blue, alt: red);forwarded:red;list-splat:blue;map-splat:2;ordered:blue;trace:1234;star:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:map" as dictionaries
        \\$get: m.get-function("get", $module: "dictionaries")
        \\$keys: m.get-function("keys", $module: "dictionaries")
        \\$theme: (nested: (tone: blue), plain: 2)
        \\.sass
        \\  get: m.call($get, $theme, nested, tone)
        \\  keys: m.inspect(m.call($keys, (a: 1, b: 2)))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-map-query-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{get:blue;keys:a, b}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves map query function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$get: meta.get-function("map-get");
        \\.legacy { value: meta.call($get, (a: 1), a); }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-map-query-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".legacy{value:1}", result.css());
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        diagnostics[0].message,
    );
}

test "native Sass meta call invokes map mutation function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:map" as maps;
        \\@use "sass:map" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@function forward($function, $args...) {
        \\  @return meta.call($function, $args...);
        \\}
        \\$merge: meta.get-function("merge", $module: "maps");
        \\$remove: meta.get-function("remove", $module: "maps");
        \\$set: meta.get-function("set", $module: "maps");
        \\$deep-merge: meta.get-function("deep-merge", $module: "maps");
        \\$deep-remove: meta.get-function("deep-remove", $module: "maps");
        \\$star: meta.get-function("set");
        \\$base: (theme: (tone: red, keep: true), old: 1);
        \\$nested: meta.call($merge, $base, theme, (tone: blue, added: 2));
        \\$removed: meta.call($remove, $nested, old, absent);
        \\$setted: meta.call($set, $removed, theme, tone, green);
        \\$deep: meta.call($deep-merge, $setted, (theme: (extra: 3), root: 4));
        \\$pruned: meta.call($deep-remove, $deep, theme, keep);
        \\$named: meta.call($merge, $map2: (b: 2), $map1: (a: 1));
        \\$named-remove: meta.call($remove, $key: a, $map: (a: 1, b: 2));
        \\$named-set: meta.call($set, $value: 2, $key: a, $map: (a: 1));
        \\$named-deep-remove: meta.call($deep-remove, $key: b, $map: (a: 1, b: 2));
        \\$remove-args: ((a: 1, b: 2), a);
        \\$list-splat: meta.call($remove, $remove-args...);
        \\$map-splat: meta.call($deep-merge, (map1: (a: 1), map2: (b: 2))...);
        \\$forwarded: forward($remove, (a: 1, b: 2), a);
        \\$ordered: meta.call(mark(1, $merge), $map2: mark(2, (b: 2)), $map1: mark(3, (a: 1)));
        \\.values {
        \\  nested: maps.get($nested, theme, added);
        \\  removed: maps.has-key($removed, old);
        \\  set: maps.get($setted, theme, tone);
        \\  deep: maps.get($deep, theme, extra);
        \\  pruned: maps.has-key(maps.get($pruned, theme), keep);
        \\  named: meta.inspect($named);
        \\  named-remove: meta.inspect($named-remove);
        \\  named-set: meta.inspect($named-set);
        \\  named-deep-remove: meta.inspect($named-deep-remove);
        \\  list-splat: meta.inspect($list-splat);
        \\  map-splat: meta.inspect($map-splat);
        \\  forwarded: meta.inspect($forwarded);
        \\  ordered: meta.inspect($ordered);
        \\  trace: $trace;
        \\  star: maps.get(meta.call($star, (), z, 9), z);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-map-mutation-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{nested:2;removed:false;set:green;deep:3;pruned:false;named:(a: 1, b: 2);named-remove:(b: 2);named-set:(a: 2);named-deep-remove:(a: 1);list-splat:(b: 2);map-splat:(a: 1, b: 2);forwarded:(b: 2);ordered:(a: 1, b: 2);trace:123;star:9}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:map" as dictionaries
        \\$merge: m.get-function("merge", $module: "dictionaries")
        \\$set: m.get-function("set", $module: "dictionaries")
        \\$remove: m.get-function("deep-remove", $module: "dictionaries")
        \\$base: (a: (b: 1), keep: 2)
        \\$merged: m.call($merge, $base, (c: 3))
        \\$setted: m.call($set, $merged, a, d, 4)
        \\$removed: m.call($remove, $setted, a, b)
        \\.sass
        \\  merged: dictionaries.get($merged, c)
        \\  set: dictionaries.get($setted, a, d)
        \\  removed: dictionaries.has-key(dictionaries.get($removed, a), b)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-map-mutation-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{merged:3;set:4;removed:false}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves map mutation function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$merge: meta.get-function("map-merge");
        \\$remove: meta.get-function("map-remove");
        \\$merged: meta.call($merge, (a: 1), (b: 2));
        \\$removed: meta.call($remove, $merged, a);
        \\.legacy {
        \\  merged: meta.inspect($merged);
        \\  removed: meta.inspect($removed);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-map-mutation-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{merged:(a: 1, b: 2);removed:(b: 2)}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            diagnostic.message,
        );
    }
}

test "native Sass meta call invokes meta inspection function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@function forward($function, $args...) {
        \\  @return meta.call($function, $args...);
        \\}
        \\$inspect: meta.get-function("inspect", $module: "reflect");
        \\$type: meta.get-function("type-of", $module: "reflect");
        \\$star: get-function("type-of");
        \\$list-args: ((a: (1, 2)),);
        \\.values {
        \\  inspected: meta.call($inspect, (a: (1, 2)));
        \\  typed: meta.call($type, $value: calc(1px + var(--x)));
        \\  callable: meta.call($inspect, meta.get-function("length"));
        \\  list-splat: meta.call($inspect, $list-args...);
        \\  map-splat: meta.call($type, (value: (a: 1))...);
        \\  forwarded: forward($type, #abc);
        \\  ordered: meta.call(mark(1, $inspect), $value: mark(2, (x, y)));
        \\  trace: $trace;
        \\  star: meta.call($star, true);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-inspection-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{inspected:(a: (1, 2));typed:calculation;callable:get-function(\"length\");list-splat:(a: (1, 2));map-splat:map;forwarded:color;ordered:x, y;trace:12;star:bool}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:meta" as reflection
        \\$inspect: m.get-function("inspect", $module: "reflection")
        \\$type: m.get-function("type-of", $module: "reflection")
        \\.sass
        \\  inspected: m.call($inspect, (a: 1))
        \\  typed: m.call($type, 2px)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-meta-inspection-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{inspected:(a: 1);typed:number}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves meta inspection function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$inspect: meta.get-function("inspect");
        \\$type: meta.get-function("type-of");
        \\.legacy {
        \\  inspected: meta.call($inspect, (a: 1));
        \\  typed: meta.call($type, 1px);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-inspection-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{inspected:(a: 1);typed:number}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            diagnostic.message,
        );
    }
}

test "native Sass meta call invokes meta keywords function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@function direct($function, $args...) {
        \\  @return meta.call($function, $args);
        \\}
        \\@function named($function, $args...) {
        \\  @return meta.call($function, $args: $args);
        \\}
        \\@function named-function($function, $args...) {
        \\  @return meta.call($function: $function, $args: $args);
        \\}
        \\@function list-splat($function, $args...) {
        \\  @return meta.call($function, ($args,)...);
        \\}
        \\@function map-splat($function, $args...) {
        \\  @return meta.call($function, (args: $args)...);
        \\}
        \\@function ordered($function, $args...) {
        \\  @return meta.call(mark(2, $function), $args: mark(3, $args));
        \\}
        \\$keywords: meta.get-function("keywords", $module: "reflect");
        \\$star: get-function("keywords");
        \\.values {
        \\  direct: meta.inspect(direct($keywords, base, $alpha: 1, $start_at: 2));
        \\  named: meta.inspect(named($keywords, $tone: red));
        \\  named-function: meta.inspect(named-function($keywords, $via_named: 7));
        \\  list-splat: meta.inspect(list-splat($keywords, $left: 3));
        \\  map-splat: meta.inspect(map-splat($keywords, $right: 4));
        \\  ordered: meta.inspect(ordered(mark(1, $keywords), $final: 5));
        \\  trace: $trace;
        \\  star: meta.inspect(direct($star, $unprefixed: 6));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-keywords-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{direct:(alpha: 1, start-at: 2);named:(tone: red);named-function:(via-named: 7);list-splat:(left: 3);map-splat:(right: 4);ordered:(final: 5);trace:123;star:(unprefixed: 6)}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:meta" as reflection
        \\@function read($function, $args...)
        \\  @return m.call($function, $args)
        \\$keywords: m.get-function("keywords", $module: "reflection")
        \\.sass
        \\  keywords: m.inspect(read($keywords, base, $tone: blue))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-meta-keywords-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{keywords:(tone: blue)}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves meta keywords function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\@function read($function, $args...) {
        \\  @return meta.call($function, $args);
        \\}
        \\$keywords: meta.get-function("keywords");
        \\.legacy { value: meta.inspect(read($keywords, $tone: red)); }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-keywords-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{value:(tone: red)}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        diagnostics[0].message,
    );
}

test "native Sass meta call invokes meta calculation function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflection;
        \\@use "sass:meta" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$name: meta.get-function("calc-name", $module: "reflection");
        \\$args: get-function("calc-args");
        \\$list-args: (min(var(--x), 2px),);
        \\$map-args: (calc: clamp(1px, var(--x), 3px));
        \\.values {
        \\  name: meta.call($name, calc(1px + var(--x)));
        \\  named: meta.call($name, $calc: max(1px, var(--x)));
        \\  list-splat: meta.call($name, $list-args...);
        \\  map-splat: meta.call($name, $map-args...);
        \\  args: meta.inspect(meta.call($args, min(var(--x, 1px), max(2px, var(--y, 3px)))));
        \\  ordered: meta.call(mark(1, $name), $calc: mark(2, round(to-zero, var(--x), 1px)));
        \\  trace: $trace;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-calculation-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{name:\"calc\";named:\"max\";list-splat:\"min\";map-splat:\"clamp\";args:var(--x, 1px), max(2px, var(--y, 3px));ordered:\"round\";trace:12}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:meta" as reflection
        \\$name: m.get-function("calc-name", $module: "reflection")
        \\$args: m.get-function("calc-args", $module: "reflection")
        \\.sass
        \\  name: m.call($name, calc(1px + var(--x)))
        \\  args: m.inspect(m.call($args, min(1px, var(--x))))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-meta-calculation-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{name:\"calc\";args:1px, var(--x)}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call invokes meta existence function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\@use "sass:math" as numbers;
        \\$global-name: 1;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@function local-fn() { @return ok; }
        \\@mixin local-mixin() {}
        \\@function scope-probe($variable, $global) {
        \\  $local-name: 2;
        \\  @return meta.inspect((
        \\    local: meta.call($variable, "local-name"),
        \\    local-global: meta.call($global, "local-name"),
        \\    outer: meta.call($variable, "global_name"),
        \\    outer-global: meta.call($global, "global-name")
        \\  ));
        \\}
        \\$function: meta.get-function("function-exists", $module: "reflect");
        \\$mixin: meta.get-function("mixin-exists", $module: "reflect");
        \\$variable: meta.get-function("variable-exists", $module: "reflect");
        \\$global: meta.get-function("global-variable-exists", $module: "reflect");
        \\$feature: meta.get-function("feature-exists", $module: "reflect");
        \\$star: get-function("function-exists");
        \\$list-args: ("local-fn",);
        \\$map-args: (name: "local-mixin");
        \\.values {
        \\  function: meta.call($function, "local_fn");
        \\  function-module: meta.call($function, "ceil", "numbers");
        \\  function-named: meta.call($function, $module: "numbers", $name: "ceil");
        \\  function-list: meta.call($function, $list-args...);
        \\  mixin: meta.call($mixin, $map-args...);
        \\  variable: meta.call($variable, "global_name");
        \\  global: meta.call($global, $name: "global-name");
        \\  scope: scope-probe($variable, $global);
        \\  feature: meta.call($feature, $feature: "at-error");
        \\  ordered: meta.call(mark(1, $function), $name: mark(2, "local-fn"));
        \\  trace: $trace;
        \\  star: meta.call($star, "local-fn");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-existence-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{function:true;function-module:true;function-named:true;function-list:true;mixin:true;variable:true;global:true;scope:(local: true, local-global: false, outer: true, outer-global: true);feature:true;ordered:true;trace:12;star:true}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "The feature-exists() function is deprecated.",
        diagnostics[0].message,
    );

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:meta" as reflection
        \\@use "sass:math" as numbers
        \\$global_name: 1
        \\@function native_fn()
        \\  @return 1
        \\@mixin native_mix()
        \\  $inside: true
        \\$function: m.get-function("function-exists", $module: "reflection")
        \\$mixin: m.get-function("mixin-exists", $module: "reflection")
        \\$variable: m.get-function("variable-exists", $module: "reflection")
        \\$global: m.get-function("global-variable-exists", $module: "reflection")
        \\.sass
        \\  function: m.call($function, "native_fn")
        \\  module: m.call($function, "ceil", "numbers")
        \\  mixin: m.call($mixin, "native_mix")
        \\  variable: m.call($variable, "global_name")
        \\  global: m.call($global, "global-name")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-meta-existence-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{function:true;module:true;mixin:true;variable:true;global:true}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves meta existence function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$function: meta.get-function("function-exists");
        \\$mixin: meta.get-function("mixin-exists");
        \\$variable: meta.get-function("variable-exists");
        \\$global: meta.get-function("global-variable-exists");
        \\$feature: meta.get-function("feature-exists");
        \\.legacy {
        \\  function: meta.call($function, "rgb");
        \\  mixin: meta.call($mixin, "missing");
        \\  variable: meta.call($variable, "missing");
        \\  global: meta.call($global, "missing");
        \\  feature: meta.call($feature, "at-error");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-existence-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{function:true;mixin:false;variable:false;global:false;feature:true}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 6), diagnostics.len);
    var global_warnings: usize = 0;
    var feature_warnings: usize = 0;
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        if (std.mem.eql(
            u8,
            diagnostic.message,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        )) {
            global_warnings += 1;
        } else if (std.mem.eql(
            u8,
            diagnostic.message,
            "The feature-exists() function is deprecated.",
        )) {
            feature_warnings += 1;
        } else {
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), global_warnings);
    try std.testing.expectEqual(@as(usize, 1), feature_warnings);
}

test "native Sass meta call invokes unary math function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$abs: meta.get-function("abs", $module: "numbers");
        \\$ceil: meta.get-function("ceil", $module: "math");
        \\$floor: meta.get-function("floor");
        \\$round: meta.get-function("round", $module: "math");
        \\$percentage: meta.get-function("percentage", $module: "math");
        \\$list-args: (-1.2px,);
        \\.values {
        \\  abs: meta.call($abs, -1.5px);
        \\  ceil: meta.call($ceil, $number: 1.2px);
        \\  floor: meta.call($floor, -1.2px);
        \\  round-list: meta.call($round, $list-args...);
        \\  percentage-map: meta.call($percentage, (number: .125)...);
        \\  ordered: meta.call(mark(1, $round), $number: mark(2, -1.5foo));
        \\  trace: $trace;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-unary-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{abs:1.5px;ceil:2px;floor:-2px;round-list:-1px;percentage-map:12.5%;ordered:-2foo;trace:12}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$abs: m.get-function("abs", $module: "numbers")
        \\$round: m.get-function("round", $module: "numbers")
        \\.sass
        \\  abs: m.call($abs, -1.5px)
        \\  named: m.call($round, $number: -1.5deg)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-unary-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{abs:1.5px;named:-2deg}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves unary math function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$abs: meta.get-function("abs");
        \\$ceil: meta.get-function("ceil");
        \\$floor: meta.get-function("floor");
        \\$round: meta.get-function("round");
        \\$percentage: meta.get-function("percentage");
        \\.legacy {
        \\  abs: meta.call($abs, -1px);
        \\  ceil: meta.call($ceil, 1.2px);
        \\  floor: meta.call($floor, 1.8px);
        \\  round: meta.call($round, 1.5px);
        \\  percentage: meta.call($percentage, .125);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-unary-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{abs:1px;ceil:2px;floor:1px;round:2px;percentage:12.5%}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 5), diagnostics.len);
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            diagnostic.message,
        );
    }
}

test "native Sass meta call invokes math compatibility function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$custom: meta.get-function("compatible", $module: "numbers");
        \\$default: meta.get-function("compatible", $module: "math");
        \\$star: meta.get-function("compatible");
        \\$list-args: (1px, 1in);
        \\$map-args: (number1: 1px, number2: 1s);
        \\.values {
        \\  compatible: meta.call($custom, 1px, 1in);
        \\  incompatible: meta.call($default, $number2: 1s, $number1: 1px);
        \\  list-splat: meta.call($custom, $list-args...);
        \\  map-splat: meta.call($default, $map-args...);
        \\  compound: meta.call($star, 1px * 1s, 2in * 1ms);
        \\  ordered: meta.call(mark(1, $custom), $number2: mark(2, 1in), $number1: mark(3, 1px));
        \\  trace: $trace;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-compatibility-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{compatible:true;incompatible:false;list-splat:true;map-splat:false;compound:true;ordered:true;trace:123}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$compatible: m.get-function("compatible", $module: "numbers")
        \\.sass
        \\  compatible: m.call($compatible, 1px, 1in)
        \\  named: m.call($compatible, $number2: 1s, $number1: 1px)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-compatibility-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{compatible:true;named:false}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves math compatibility function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$comparable: meta.get-function("comparable");
        \\.legacy {
        \\  compatible: meta.call($comparable, 1px, 1in);
        \\  incompatible: meta.call($comparable, 1px, 1s);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-compatibility-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{compatible:true;incompatible:false}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            diagnostic.message,
        );
    }
}

test "native Sass meta call invokes math unitless function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$custom: meta.get-function("is-unitless", $module: "numbers");
        \\$default: meta.get-function("is-unitless", $module: "math");
        \\$star: meta.get-function("is-unitless");
        \\$list-args: (1,);
        \\$map-args: (number: 1px);
        \\.values {
        \\  unitless: meta.call($custom, 1);
        \\  unitful: meta.call($default, $number: 1px);
        \\  list-splat: meta.call($custom, $list-args...);
        \\  map-splat: meta.call($default, $map-args...);
        \\  ordered: meta.call(mark(1, $star), $number: mark(2, 1));
        \\  trace: $trace;
        \\  star: meta.call($star, 2);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-unitless-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{unitless:true;unitful:false;list-splat:true;map-splat:false;ordered:true;trace:12;star:true}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$unitless: m.get-function("is-unitless", $module: "numbers")
        \\.sass
        \\  unitless: m.call($unitless, 1)
        \\  named: m.call($unitless, $number: 1px)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-unitless-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{unitless:true;named:false}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves math unitless function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$unitless: meta.get-function("unitless");
        \\.legacy {
        \\  unitless: meta.call($unitless, 1);
        \\  unitful: meta.call($unitless, 1px);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-unitless-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{unitless:true;unitful:false}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            diagnostic.message,
        );
    }
}

test "native Sass meta call invokes math unit function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$custom: meta.get-function("unit", $module: "numbers");
        \\$default: meta.get-function("unit", $module: "math");
        \\$star: meta.get-function("unit");
        \\$list-args: (1px * 1s,);
        \\$map-args: (number: math.div(1px, 1s));
        \\.values {
        \\  unitless: meta.call($custom, 1);
        \\  single: meta.call($default, $number: 1px);
        \\  list-splat: meta.call($custom, $list-args...);
        \\  map-splat: meta.call($default, $map-args...);
        \\  ordered: meta.call(mark(1, $star), $number: mark(2, math.div(1deg, 1s)));
        \\  trace: $trace;
        \\  star: meta.call($star, math.div(1em, 1ms));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-unit-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{unitless:\"\";single:\"px\";list-splat:\"px*s\";map-splat:\"px/s\";ordered:\"deg/s\";trace:12;star:\"em/ms\"}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$unit: m.get-function("unit", $module: "numbers")
        \\.sass
        \\  unitless: m.call($unit, 1)
        \\  named: m.call($unit, $number: numbers.div(1px, 1s))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-unit-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{unitless:\"\";named:\"px/s\"}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves math unit function origin warnings" {
    const input =
        \\@use "sass:meta";
        \\$unit: meta.get-function("unit");
        \\.legacy {
        \\  unitless: meta.call($unit, 1);
        \\  unitful: meta.call($unit, 1foo);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-unit-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".legacy{unitless:\"\";unitful:\"foo\"}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    for (diagnostics) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            diagnostic.message,
        );
    }
}

test "native Sass meta call invokes math acos function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$custom: meta.get-function("acos", $module: "numbers");
        \\$default: meta.get-function("acos", $module: "math");
        \\$star: meta.get-function("acos");
        \\$list-args: (.5,);
        \\$map-args: (number: -1);
        \\.values {
        \\  half: meta.call($custom, .5);
        \\  named: meta.call($default, $number: 0);
        \\  list-splat: meta.call($custom, $list-args...);
        \\  map-splat: meta.call($default, $map-args...);
        \\  ordered: meta.call(mark(1, $star), $number: mark(2, 1));
        \\  trace: $trace;
        \\  star: meta.call($star, -.5);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-acos-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{half:60deg;named:90deg;list-splat:60deg;map-splat:180deg;ordered:0deg;trace:12;star:120deg}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$acos: m.get-function("acos", $module: "numbers")
        \\.sass
        \\  half: m.call($acos, .5)
        \\  named: m.call($acos, $number: -1)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-acos-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{half:60deg;named:180deg}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call rejects global math acos reflection" {
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-acos-global-exists.scss",
        "@use \"sass:meta\"; .a { exists: meta.function-exists(\"acos\"); }",
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{exists:false}", result.css());
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "meta-call-math-acos-global-reference.scss",
            "@use \"sass:meta\"; $acos: meta.get-function(\"acos\");",
            .scss,
            .{},
        ),
    );
}

test "native Sass meta call invokes math asin function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$custom: meta.get-function("asin", $module: "numbers");
        \\$default: meta.get-function("asin", $module: "math");
        \\$star: meta.get-function("asin");
        \\$list-args: (.5,);
        \\$map-args: (number: -1);
        \\.values {
        \\  half: meta.call($custom, .5);
        \\  named: meta.call($default, $number: 0);
        \\  list-splat: meta.call($custom, $list-args...);
        \\  map-splat: meta.call($default, $map-args...);
        \\  ordered: meta.call(mark(1, $star), $number: mark(2, 1));
        \\  trace: $trace;
        \\  star: meta.call($star, -.5);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-asin-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{half:30deg;named:0deg;list-splat:30deg;map-splat:-90deg;ordered:90deg;trace:12;star:-30deg}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$asin: m.get-function("asin", $module: "numbers")
        \\.sass
        \\  half: m.call($asin, .5)
        \\  named: m.call($asin, $number: -1)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-asin-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{half:30deg;named:-90deg}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call rejects global math asin reflection" {
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-asin-global-exists.scss",
        "@use \"sass:meta\"; .a { exists: meta.function-exists(\"asin\"); }",
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{exists:false}", result.css());
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "meta-call-math-asin-global-reference.scss",
            "@use \"sass:meta\"; $asin: meta.get-function(\"asin\");",
            .scss,
            .{},
        ),
    );
}

test "native Sass meta call invokes math atan function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$custom: meta.get-function("atan", $module: "numbers");
        \\$default: meta.get-function("atan", $module: "math");
        \\$star: meta.get-function("atan");
        \\$list-args: (1,);
        \\$map-args: (number: -1);
        \\.values {
        \\  half: meta.call($custom, 1);
        \\  named: meta.call($default, $number: 0);
        \\  list-splat: meta.call($custom, $list-args...);
        \\  map-splat: meta.call($default, $map-args...);
        \\  ordered: meta.call(mark(1, $star), $number: mark(2, 1));
        \\  trace: $trace;
        \\  star: meta.call($star, -1);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-atan-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{half:45deg;named:0deg;list-splat:45deg;map-splat:-45deg;ordered:45deg;trace:12;star:-45deg}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$atan: m.get-function("atan", $module: "numbers")
        \\.sass
        \\  half: m.call($atan, 1)
        \\  named: m.call($atan, $number: -1)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-atan-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{half:45deg;named:-45deg}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call rejects global math atan reflection" {
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-atan-global-exists.scss",
        "@use \"sass:meta\"; .a { exists: meta.function-exists(\"atan\"); }",
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{exists:false}", result.css());
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "meta-call-math-atan-global-reference.scss",
            "@use \"sass:meta\"; $atan: meta.get-function(\"atan\");",
            .scss,
            .{},
        ),
    );
}

test "native Sass meta call invokes math atan2 function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:math";
        \\@use "sass:math" as numbers;
        \\@use "sass:math" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\$custom: meta.get-function("atan2", $module: "numbers");
        \\$default: meta.get-function("atan2", $module: "math");
        \\$star: meta.get-function("atan2");
        \\$list-args: (1, 1);
        \\$map-args: (y: -1, x: 1);
        \\.values {
        \\  diagonal: meta.call($custom, 1, 1);
        \\  named: meta.call($default, $x: -1, $y: 0);
        \\  list-splat: meta.call($custom, $list-args...);
        \\  map-splat: meta.call($default, $map-args...);
        \\  units: meta.call($default, 1in, 96px);
        \\  percent: meta.call($default, 1%, 2%);
        \\  ordered: meta.call(mark(1, $star), $x: mark(2, 1), $y: mark(3, 1));
        \\  trace: $trace;
        \\  star: meta.call($star, -1, -1);
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-atan2-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{diagonal:45deg;named:180deg;list-splat:45deg;map-splat:-45deg;units:45deg;percent:26.5650511771deg;ordered:45deg;trace:123;star:-135deg}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:math" as numbers
        \\$atan2: m.get-function("atan2", $module: "numbers")
        \\.sass
        \\  diagonal: m.call($atan2, 1, 1)
        \\  named: m.call($atan2, $x: 1, $y: -1)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-math-atan2-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{diagonal:45deg;named:-45deg}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call rejects global math atan2 reflection" {
    var result = try compile(
        std.testing.allocator,
        "meta-call-math-atan2-global-exists.scss",
        "@use \"sass:meta\"; .a { exists: meta.function-exists(\"atan2\"); }",
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{exists:false}", result.css());
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    try std.testing.expectError(
        error.InvalidExpression,
        compile(
            std.testing.allocator,
            "meta-call-math-atan2-global-reference.scss",
            "@use \"sass:meta\"; $atan2: meta.get-function(\"atan2\");",
            .scss,
            .{},
        ),
    );
}

test "native Sass meta call invokes meta content acceptance function references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\$trace: 0;
        \\@function mark($digit, $value) {
        \\  $trace: $trace * 10 + $digit !global;
        \\  @return $value;
        \\}
        \\@mixin plain {}
        \\@mixin slot { @content; }
        \\$accepts: meta.get-function("accepts-content", $module: "reflect");
        \\$star: get-function("accepts-content");
        \\$list-args: (meta.get-mixin("plain"),);
        \\$map-args: (mixin: meta.get-mixin("slot"));
        \\.values {
        \\  plain: meta.call($accepts, meta.get-mixin("plain"));
        \\  slot: meta.call($accepts, meta.get-mixin("slot"));
        \\  named: meta.call($accepts, $mixin: meta.get-mixin("slot"));
        \\  list-splat: meta.call($accepts, $list-args...);
        \\  map-splat: meta.call($accepts, $map-args...);
        \\  load: meta.call($accepts, meta.get-mixin("load-css", $module: "meta"));
        \\  apply: meta.call($accepts, meta.get-mixin("apply", $module: "meta"));
        \\  ordered: meta.call(mark(1, $accepts), $mixin: mark(2, meta.get-mixin("slot")));
        \\  trace: $trace;
        \\  star: meta.call($star, meta.get-mixin("plain"));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-meta-content-acceptance-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{plain:false;slot:true;named:true;list-splat:false;map-splat:true;load:false;apply:true;ordered:true;trace:12;star:false}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@use "sass:meta" as reflection
        \\@mixin slot
        \\  @content
        \\$accepts: m.get-function("accepts-content", $module: "reflection")
        \\.sass
        \\  accepts: m.call($accepts, m.get-mixin("slot"))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-call-meta-content-acceptance-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{accepts:true}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta call preserves the legacy warning" {
    const input =
        \\@use "sass:meta";
        \\@function identity($value) { @return $value; }
        \\.legacy { value: call(meta.get-function("identity"), ok); }
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-call-global.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".legacy{value:ok}", result.css());
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[0].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[0].code,
    );
    try std.testing.expectEqualStrings(
        "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
        diagnostics[0].message,
    );
}

test "native Sass meta call rejects unavailable callable kinds and invalid binding" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "meta-call-non-callable.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(1, ok); }",
        },
        .{
            .name = "meta-call-mixin.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.call(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "meta-call-unavailable-builtin.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"sin\", $module: \"math\"), 1); }",
        },
        .{
            .name = "meta-call-math-compatible-missing-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"compatible\", $module: \"math\"), 1px); }",
        },
        .{
            .name = "meta-call-math-compatible-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"compatible\", $module: \"math\"), 1px, 1in, 1cm); }",
        },
        .{
            .name = "meta-call-math-compatible-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"compatible\", $module: \"math\"), $number1: 1px, $number2: 1in, $other: 1cm); }",
        },
        .{
            .name = "meta-call-math-compatible-duplicate-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"compatible\", $module: \"math\"), 1px, $number1: 1in, $number2: 1cm); }",
        },
        .{
            .name = "meta-call-math-compatible-string.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"compatible\", $module: \"math\"), \"1px\", 1in); }",
        },
        .{
            .name = "meta-call-math-compatible-list.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"compatible\", $module: \"math\"), (1px, 1in), 1cm); }",
        },
        .{
            .name = "meta-call-math-unitless-missing-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"is-unitless\", $module: \"math\")); }",
        },
        .{
            .name = "meta-call-math-unitless-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"is-unitless\", $module: \"math\"), 1, 2); }",
        },
        .{
            .name = "meta-call-math-unitless-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"is-unitless\", $module: \"math\"), $other: 1); }",
        },
        .{
            .name = "meta-call-math-unitless-duplicate-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"is-unitless\", $module: \"math\"), 1, $number: 2); }",
        },
        .{
            .name = "meta-call-math-unitless-string.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"is-unitless\", $module: \"math\"), \"1\"); }",
        },
        .{
            .name = "meta-call-math-unitless-list.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"is-unitless\", $module: \"math\"), (1, 2)); }",
        },
        .{
            .name = "meta-call-math-unit-missing-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"unit\", $module: \"math\")); }",
        },
        .{
            .name = "meta-call-math-unit-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"unit\", $module: \"math\"), 1px, 2px); }",
        },
        .{
            .name = "meta-call-math-unit-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"unit\", $module: \"math\"), $other: 1px); }",
        },
        .{
            .name = "meta-call-math-unit-duplicate-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"unit\", $module: \"math\"), 1px, $number: 2px); }",
        },
        .{
            .name = "meta-call-math-unit-string.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"unit\", $module: \"math\"), \"1px\"); }",
        },
        .{
            .name = "meta-call-math-unit-list.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"unit\", $module: \"math\"), (1px, 2px)); }",
        },
        .{
            .name = "meta-call-math-acos-missing-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"acos\", $module: \"math\")); }",
        },
        .{
            .name = "meta-call-math-acos-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"acos\", $module: \"math\"), .5, 1); }",
        },
        .{
            .name = "meta-call-math-acos-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"acos\", $module: \"math\"), $other: .5); }",
        },
        .{
            .name = "meta-call-math-acos-duplicate-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"acos\", $module: \"math\"), .5, $number: 1); }",
        },
        .{
            .name = "meta-call-math-acos-string.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"acos\", $module: \"math\"), \".5\"); }",
        },
        .{
            .name = "meta-call-math-acos-list.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"acos\", $module: \"math\"), (.5, 1)); }",
        },
        .{
            .name = "meta-call-math-acos-unit.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"acos\", $module: \"math\"), 1deg); }",
        },
        .{
            .name = "meta-call-math-asin-missing-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"asin\", $module: \"math\")); }",
        },
        .{
            .name = "meta-call-math-asin-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"asin\", $module: \"math\"), .5, 1); }",
        },
        .{
            .name = "meta-call-math-asin-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"asin\", $module: \"math\"), $other: .5); }",
        },
        .{
            .name = "meta-call-math-asin-duplicate-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"asin\", $module: \"math\"), .5, $number: 1); }",
        },
        .{
            .name = "meta-call-math-asin-string.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"asin\", $module: \"math\"), \".5\"); }",
        },
        .{
            .name = "meta-call-math-asin-list.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"asin\", $module: \"math\"), (.5, 1)); }",
        },
        .{
            .name = "meta-call-math-asin-unit.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"asin\", $module: \"math\"), 1deg); }",
        },
        .{
            .name = "meta-call-math-atan-missing-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan\", $module: \"math\")); }",
        },
        .{
            .name = "meta-call-math-atan-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan\", $module: \"math\"), 1, 2); }",
        },
        .{
            .name = "meta-call-math-atan-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan\", $module: \"math\"), $other: 1); }",
        },
        .{
            .name = "meta-call-math-atan-duplicate-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan\", $module: \"math\"), 1, $number: 2); }",
        },
        .{
            .name = "meta-call-math-atan-string.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan\", $module: \"math\"), \"1\"); }",
        },
        .{
            .name = "meta-call-math-atan-list.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan\", $module: \"math\"), (1, 2)); }",
        },
        .{
            .name = "meta-call-math-atan-unit.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan\", $module: \"math\"), 1deg); }",
        },
        .{
            .name = "meta-call-math-atan2-missing-x.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), 1); }",
        },
        .{
            .name = "meta-call-math-atan2-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), 1, 2, 3); }",
        },
        .{
            .name = "meta-call-math-atan2-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), $y: 1, $x: 1, $other: 2); }",
        },
        .{
            .name = "meta-call-math-atan2-duplicate-y.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), 1, $y: 2, $x: 1); }",
        },
        .{
            .name = "meta-call-math-atan2-string.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), \"1\", 1); }",
        },
        .{
            .name = "meta-call-math-atan2-list.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), (1, 2), 1); }",
        },
        .{
            .name = "meta-call-math-unary-missing-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"abs\", $module: \"math\")); }",
        },
        .{
            .name = "meta-call-math-unary-extra-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"ceil\", $module: \"math\"), 1.2, 2.3); }",
        },
        .{
            .name = "meta-call-math-unary-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"floor\", $module: \"math\"), $other: 1.2); }",
        },
        .{
            .name = "meta-call-math-unary-duplicate-number.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"round\", $module: \"math\"), 1.2, $number: 2.3); }",
        },
        .{
            .name = "meta-call-math-unary-type.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"abs\", $module: \"math\"), \"-1px\"); }",
        },
        .{
            .name = "meta-call-math-unary-percentage-unit.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"percentage\", $module: \"math\"), 1px); }",
        },
        .{
            .name = "meta-call-list-missing-argument.scss",
            .input = "@use \"sass:meta\"; @use \"sass:list\"; .a { value: meta.call(meta.get-function(\"nth\", $module: \"list\"), (a, b)); }",
        },
        .{
            .name = "meta-call-list-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:list\"; .a { value: meta.call(meta.get-function(\"length\", $module: \"list\"), $other: (a, b)); }",
        },
        .{
            .name = "meta-call-list-zip-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:list\"; .a { value: meta.call(meta.get-function(\"zip\", $module: \"list\"), $lists: (a, b)); }",
        },
        .{
            .name = "meta-call-map-query-missing-key.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"get\", $module: \"map\"), (a: 1)); }",
        },
        .{
            .name = "meta-call-map-query-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"get\", $module: \"map\"), $other: (a: 1), $key: a); }",
        },
        .{
            .name = "meta-call-map-query-rest-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"get\", $module: \"map\"), $map: (a: (b: 1)), $key: a, $keys: b); }",
        },
        .{
            .name = "meta-call-map-query-extra-argument.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"keys\", $module: \"map\"), (a: 1), a); }",
        },
        .{
            .name = "meta-call-map-merge-missing-map.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"merge\", $module: \"map\"), (a: 1)); }",
        },
        .{
            .name = "meta-call-map-merge-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"merge\", $module: \"map\"), $map1: (a: 1), $other: (b: 2)); }",
        },
        .{
            .name = "meta-call-map-remove-rest-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"remove\", $module: \"map\"), $map: (a: 1), $keys: a); }",
        },
        .{
            .name = "meta-call-map-set-rest-keyword.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"set\", $module: \"map\"), $map: (a: 1), $keys: a, $value: 2); }",
        },
        .{
            .name = "meta-call-map-deep-merge-extra-argument.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"deep-merge\", $module: \"map\"), (a: 1), (b: 2), (c: 3)); }",
        },
        .{
            .name = "meta-call-map-deep-remove-missing-key.scss",
            .input = "@use \"sass:meta\"; @use \"sass:map\"; .a { value: meta.call(meta.get-function(\"deep-remove\", $module: \"map\"), (a: 1)); }",
        },
        .{
            .name = "meta-call-meta-inspect-missing-value.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"inspect\", $module: \"meta\")); }",
        },
        .{
            .name = "meta-call-meta-type-extra-value.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"type-of\", $module: \"meta\"), 1, 2); }",
        },
        .{
            .name = "meta-call-meta-inspect-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"inspect\", $module: \"meta\"), $other: 1); }",
        },
        .{
            .name = "meta-call-meta-keywords-missing-args.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"keywords\", $module: \"meta\")); }",
        },
        .{
            .name = "meta-call-meta-keywords-extra-args.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"keywords\", $module: \"meta\"), 1, 2); }",
        },
        .{
            .name = "meta-call-meta-keywords-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"keywords\", $module: \"meta\"), $other: 1); }",
        },
        .{
            .name = "meta-call-meta-keywords-type.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"keywords\", $module: \"meta\"), (a: 1)); }",
        },
        .{
            .name = "meta-call-meta-content-acceptance-missing-mixin.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"accepts-content\", $module: \"meta\")); }",
        },
        .{
            .name = "meta-call-meta-content-acceptance-extra-mixin.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.call(meta.get-function(\"accepts-content\", $module: \"meta\"), meta.get-mixin(\"local\"), meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "meta-call-meta-content-acceptance-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.call(meta.get-function(\"accepts-content\", $module: \"meta\"), $other: meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "meta-call-meta-content-acceptance-type.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"accepts-content\", $module: \"meta\"), meta.get-function(\"inspect\", $module: \"meta\")); }",
        },
        .{
            .name = "meta-call-meta-calculation-missing-calc.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"calc-name\", $module: \"meta\")); }",
        },
        .{
            .name = "meta-call-meta-calculation-extra-calc.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"calc-args\", $module: \"meta\"), calc(1px + var(--x)), 1); }",
        },
        .{
            .name = "meta-call-meta-calculation-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"calc-name\", $module: \"meta\"), $value: calc(1px + var(--x))); }",
        },
        .{
            .name = "meta-call-meta-calculation-duplicate-calc.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"calc-name\", $module: \"meta\"), calc(1px + var(--x)), $calc: calc(2px + var(--y))); }",
        },
        .{
            .name = "meta-call-meta-calculation-number.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"calc-name\", $module: \"meta\"), 1px); }",
        },
        .{
            .name = "meta-call-meta-existence-missing-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"function-exists\", $module: \"meta\")); }",
        },
        .{
            .name = "meta-call-meta-existence-extra-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"function-exists\", $module: \"meta\"), \"rgb\", null, 1); }",
        },
        .{
            .name = "meta-call-meta-existence-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"function-exists\", $module: \"meta\"), $other: \"rgb\"); }",
        },
        .{
            .name = "meta-call-meta-existence-variable-extra-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"variable-exists\", $module: \"meta\"), \"x\", null); }",
        },
        .{
            .name = "meta-call-meta-existence-feature-type.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"feature-exists\", $module: \"meta\"), 1); }",
        },
        .{
            .name = "meta-call-meta-existence-missing-module.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.call(meta.get-function(\"function-exists\", $module: \"meta\"), \"ceil\", \"numbers\"); }",
        },
        .{
            .name = "meta-call-missing-user-argument.scss",
            .input = "@use \"sass:meta\"; @function local($value) { @return $value; } .a { value: meta.call(meta.get-function(\"local\")); }",
        },
        .{
            .name = "meta-call-unknown-user-keyword.scss",
            .input = "@use \"sass:meta\"; @function local($value) { @return $value; } .a { value: meta.call(meta.get-function(\"local\"), $other: 1); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    const incompatible_units = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "meta-call-math-atan2-mixed-units.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), 1px, 1); }",
        },
        .{
            .name = "meta-call-math-atan2-incompatible-units.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.call(meta.get-function(\"atan2\", $module: \"math\"), 1px, 1s); }",
        },
    };
    for (incompatible_units) |case| {
        try std.testing.expectError(
            error.IncompatibleUnits,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var argument_limits = sass_evaluator.Limits{};
    argument_limits.max_function_arguments = 2;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "meta-call-argument-limit.scss",
            "@use \"sass:meta\"; @function local($args...) { @return 1; } .a { value: meta.call(meta.get-function(\"local\"), 1, 2); }",
            .scss,
            argument_limits,
        ),
    );
}

test "native Sass meta function references reject invalid or unavailable reflection" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "meta-get-function-before-declaration.scss",
            .input = "@use \"sass:meta\"; $reference: meta.get-function(\"later\"); @function later() { @return 1; }",
        },
        .{
            .name = "meta-get-function-missing.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(\"missing\")); }",
        },
        .{
            .name = "meta-get-function-case.scss",
            .input = "@use \"sass:meta\"; @function Mixed() { @return 1; } .a { value: meta.type-of(meta.get-function(\"mixed\")); }",
        },
        .{
            .name = "meta-get-function-user-from-module.scss",
            .input = "@use \"sass:meta\"; @function local() { @return 1; } .a { value: meta.type-of(meta.get-function(\"local\", $module: \"meta\")); }",
        },
        .{
            .name = "meta-get-function-loaded-module-missing.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.type-of(meta.get-function(\"type-of\", $module: \"math\")); }",
        },
        .{
            .name = "meta-get-function-unloaded-module.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(\"ceil\", $module: \"numbers\")); }",
        },
        .{
            .name = "meta-get-function-number-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(1)); }",
        },
        .{
            .name = "meta-get-function-number-module.scss",
            .input = "@use \"sass:meta\"; @function local() { @return 1; } .a { value: meta.type-of(meta.get-function(\"local\", $module: 1)); }",
        },
        .{
            .name = "meta-get-function-missing-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function()); }",
        },
        .{
            .name = "meta-get-function-too-many.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(\"length\", false, null, 1)); }",
        },
        .{
            .name = "meta-get-function-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function($function: \"length\")); }",
        },
        .{
            .name = "meta-get-function-css-reference.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(\"custom\", true)); }",
        },
        .{
            .name = "meta-get-function-truthy-css-reference.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(\"custom\", 0)); }",
        },
        .{
            .name = "meta-get-function-css-module.scss",
            .input = "@use \"sass:meta\"; @use \"sass:math\"; .a { value: meta.type-of(meta.get-function(\"ceil\", true, \"math\")); }",
        },
        .{
            .name = "meta-get-function-invalid-name.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(\"not valid\")); }",
        },
        .{
            .name = "meta-get-function-callable-css.scss",
            .input = "@use \"sass:meta\"; @function local() { @return 1; } .a { value: meta.get-function(\"local\"); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 3;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "meta-get-function-temporary-limit.scss",
            "@use \"sass:meta\"; .a { value: meta.type-of(meta.get-function(\"long-name\")); }",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass evaluates plain CSS function arguments before serialization" {
    const input =
        \\@use "sass:meta";
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\$name: outer;
        \\.values {
        \\  arithmetic: outer(1px + 2px);
        \\  module: outer(meta.type-of(1));
        \\  user: outer(mark(3));
        \\  nested: outer(inner(mark(4)));
        \\  spread: outer((a, b)...);
        \\  interpolated: #{$name}(mark(5));
        \\  escaped: o\75 ter(mark(6));
        \\  nulls: outer(null, 1, null);
        \\  empty: outer();
        \\  trailing: outer(1,);
        \\  var-empty: var(--missing,);
        \\  url-data: url(data:image/svg+xml,%3Csvg%3E);
        \\  literal: outer("mark(8)");
        \\  evaluations: $evaluations;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "plain-css-function-arguments.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{arithmetic:outer(3px);module:outer(number);user:outer(3);nested:outer(inner(4));spread:outer(a, b);interpolated:outer(5);escaped:outer(6);nulls:outer(, 1, );empty:outer();trailing:outer(1);var-empty:var(--missing, );url-data:url(data:image/svg+xml,%3Csvg%3E);literal:outer(\"mark(8)\");evaluations:4}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\$evaluations: 0
        \\@function mark($value)
        \\  $evaluations: $evaluations + 1 !global
        \\  @return $value
        \\.sass
        \\  arithmetic: outer(1px + 2px)
        \\  module: outer(m.type-of(1))
        \\  user: outer(mark(3))
        \\  evaluations: $evaluations
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "plain-css-function-arguments.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{arithmetic:outer(3px);module:outer(number);user:outer(3);evaluations:1}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass rejects non-CSS values in plain CSS function arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "plain-css-callable-user.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: outer(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-builtin.scss",
            .input = "@use \"sass:meta\"; .a { value: outer(meta.get-mixin(\"load-css\", \"meta\")); }",
        },
        .{
            .name = "plain-css-callable-alias.scss",
            .input = "@use \"sass:meta\" as reflect; @mixin local {} .a { value: outer(reflect.get_mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-star.scss",
            .input = "@use \"sass:meta\" as *; @mixin local {} .a { value: outer(get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-nested.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: outer(inner(meta.get-mixin(\"local\"))); }",
        },
        .{
            .name = "plain-css-callable-later-argument.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: outer(1, meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-user-function.scss",
            .input = "@use \"sass:meta\"; @mixin local {} @function reflected() { @return meta.get-mixin(\"local\"); } .a { value: outer(reflected()); }",
        },
        .{
            .name = "plain-css-callable-var.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: var(--fallback, meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-url.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: url(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-rgb.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: rgb(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-lab.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: lab(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-color.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: color(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-calc.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: calc(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-min.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: min(meta.get-mixin(\"local\"), 1px); }",
        },
        .{
            .name = "plain-css-callable-sin.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: sin(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-callable-opacity.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: opacity(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "plain-css-map.scss",
            .input = ".a { value: outer((a: 1)); }",
        },
        .{
            .name = "plain-css-keyword.scss",
            .input = ".a { value: outer($value: 1); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var argument_limits = sass_evaluator.Limits{};
    argument_limits.max_function_arguments = 1;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "plain-css-function-argument-limit.scss",
            ".a { value: outer(1, 2); }",
            .scss,
            argument_limits,
        ),
    );

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 4;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "plain-css-function-temporary-limit.scss",
            ".a { value: outer(1); }",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass meta accepts content reflects stable user and built-in mixin references" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as reflect;
        \\@use "sass:meta" as *;
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\@mixin none {}
        \\$old: meta.get-mixin("none");
        \\@mixin none { @content; }
        \\$new: meta.get-mixin("none");
        \\@mixin direct { @content; }
        \\@mixin nested { @if true { @content; } }
        \\.values {
        \\  old: meta.accepts-content($old);
        \\  new: meta.accepts-content($new);
        \\  direct: meta.accepts-content(meta.get-mixin("direct"));
        \\  nested: meta.accepts-content(meta.get-mixin("nested"));
        \\  marked: meta.accepts-content(mark(meta.get-mixin("direct")));
        \\  keyword: meta.accepts-content($mixin: meta.get-mixin("direct"));
        \\  alias: reflect.accepts_content(reflect.get_mixin("direct"));
        \\  star: accepts-content(get-mixin("direct"));
        \\  load: meta.accepts-content(meta.get-mixin("load-css", "meta"));
        \\  load-alias: reflect.accepts-content(reflect.get-mixin("load_css", "reflect"));
        \\  apply: meta.accepts-content(meta.get-mixin("apply", "meta"));
        \\  reflected: meta.function-exists("accepts-content", "meta");
        \\  evaluations: $evaluations;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "meta-accepts-content.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{old:false;new:true;direct:true;nested:true;marked:true;keyword:true;alias:true;star:true;load:false;load-alias:false;apply:true;reflected:true;evaluations:1}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@mixin contentful
        \\  @content
        \\.sass
        \\  user: m.accepts-content(m.get-mixin("contentful"))
        \\  load: m.accepts-content(m.get-mixin("load-css", "m"))
        \\  apply: m.accepts-content(m.get-mixin("apply", "m"))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-accepts-content.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{user:true;load:false;apply:true}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta accepts content rejects invalid or unavailable calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "meta-accepts-content-missing-module.scss",
            .input = "@mixin local {} .a { value: meta.accepts-content(meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "meta-accepts-content-case-module.scss",
            .input = "@use \"sass:meta\" as Meta; @mixin local {} .a { value: meta.accepts-content(Meta.get-mixin(\"local\")); }",
        },
        .{
            .name = "meta-accepts-content-string.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.accepts-content(\"local\"); }",
        },
        .{
            .name = "meta-accepts-content-number.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.accepts-content(1); }",
        },
        .{
            .name = "meta-accepts-content-missing.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.accepts-content(); }",
        },
        .{
            .name = "meta-accepts-content-too-many.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.accepts-content(meta.get-mixin(\"local\"), 1); }",
        },
        .{
            .name = "meta-accepts-content-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; @mixin local {} .a { value: meta.accepts-content($value: meta.get-mixin(\"local\")); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass meta inspection rejects unavailable or invalid calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-meta-type-module.scss",
            .input = ".a { value: meta.type-of(1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-meta-type-namespace.scss",
            .input = "@use \"sass:meta\" as Meta; .a { value: meta.type-of(1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-type-missing.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-type-too-many.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of(1, 2); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-type-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.type-of($input: 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-inspect-missing.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.inspect(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-inspect-too-many.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.inspect(1, 2); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-inspect-unknown-keyword.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.inspect($input: 1); }",
            .expected = error.InvalidExpression,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass selector module parses lists and decomposes compounds" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:selector" as sel;
        \\@use "sass:selector" as *;
        \\@use "sass:meta";
        \\@use "sass:list";
        \\$count: 0;
        \\@function mark($value) { $count: $count + 1 !global; @return $value; }
        \\.values {
        \\  basic: selector.parse(".foo");
        \\  list: selector.parse(".foo > .bar, #id:hover");
        \\  normalized: selector.parse("  .foo   >   .bar , #id:hover  ");
        \\  functional: selector.parse("[data-x=\"a,b\"]:not(.x, .y)");
        \\  leading: selector.parse("> .foo, + .bar, ~ .baz");
        \\  from-list: selector.parse((a, b));
        \\  interpolated: selector.parse(".item-#{2}");
        \\  type: meta.type-of(selector.parse(".foo"));
        \\  parse-item-type: meta.type-of(list.nth(selector.parse("a.foo"), 1));
        \\  single-inspect: meta.inspect(selector.parse(".foo"));
        \\  parse-length: list.length(selector.parse(".foo, .bar"));
        \\  parse-separator: list.separator(selector.parse(".foo"));
        \\  inspect: meta.inspect(selector.parse(".foo > .bar, #id:hover"));
        \\  simple: selector.simple-selectors("a.foo#id:hover::before[title=\"x\"]");
        \\  simple-item-type: meta.type-of(list.nth(selector.simple-selectors("a.foo"), 1));
        \\  functional-simple: meta.inspect(selector.simple-selectors(":not(.a, .b).x"));
        \\  simple-len: list.length(selector.simple-selectors("a.foo#id"));
        \\  simple-first: list.nth(selector.simple-selectors("a.foo"), 1);
        \\  simple-second: list.nth(selector.simple-selectors("a.foo"), 2);
        \\  named: selector.parse($selector: ".named");
        \\  named-simple: selector.simple-selectors($selector: "button.primary");
        \\  alias: sel.parse(".alias");
        \\  star: parse(".star");
        \\  marked: selector.parse(mark(".marked"));
        \\  marked-simple: selector.simple-selectors(mark("a.marked"));
        \\  evaluations: $count;
        \\}
    ;
    var result = try compile(std.testing.allocator, "selector-parse-simple.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{basic:.foo;list:.foo > .bar,#id:hover;normalized:.foo > .bar,#id:hover;functional:[data-x=\"a,b\"]:not(.x, .y);leading:> .foo,+ .bar,~ .baz;from-list:a,b;interpolated:.item-2;type:list;parse-item-type:list;single-inspect:(.foo,);parse-length:2;parse-separator:comma;inspect:.foo > .bar, #id:hover;simple:a,.foo,#id,:hover,::before,[title=x];simple-item-type:string;functional-simple::not(.a, .b), .x;simple-len:3;simple-first:a;simple-second:.foo;named:.named;named-simple:button,.primary;alias:.alias;star:.star;marked:.marked;marked-simple:a,.marked;evaluations:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\@use "sass:meta"
        \\.sass
        \\  type: meta.type-of(selector.parse(".foo, #bar:hover"))
        \\  parse: selector.parse(".foo > .bar, #bar:hover")
        \\  inspect: meta.inspect(selector.parse(".foo > .bar, #bar:hover"))
        \\  simple: selector.simple-selectors("button.primary:hover")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-parse-simple.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{type:list;parse:.foo > .bar,#bar:hover;inspect:.foo > .bar, #bar:hover;simple:button,.primary,:hover}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module appends and nests selector values" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\@use "sass:list";
        \\@use "sass:selector" as sel;
        \\@use "sass:selector" as *;
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.values {
        \\  append-one: selector.append(".a");
        \\  append-basic: selector.append(".foo", ".bar");
        \\  append-three: selector.append(".accordion", "__copy", ".open");
        \\  append-list: selector.append(".a, .b", ".c, .d");
        \\  append-complex: selector.append(".a > .b", ".c > .d");
        \\  append-pseudo: selector.append(".foo", ":hover");
        \\  append-type: selector.append(".foo", "button");
        \\  append-attr: selector.append(".foo", "[x]");
        \\  append-universal: selector.append("*", ".foo");
        \\  append-namespaced: selector.append("svg|a", ".foo");
        \\  nest-one: selector.nest(".a, .b");
        \\  nest-basic: selector.nest(".foo", ".bar");
        \\  nest-parent: selector.nest(".foo", "&:hover");
        \\  nest-list: selector.nest(".a, .b", ".c, .d");
        \\  nest-repeat: selector.nest(".foo, .bar", "& + &");
        \\  nest-deep: selector.nest(".a, .b", "&:hover, .c &");
        \\  nest-combinator: selector.nest(".a", "> .b");
        \\  nest-three: selector.nest(".a", "&.b", "&:hover");
        \\  append-typeof: meta.type-of(selector.append(".foo", ".bar"));
        \\  nest-typeof: meta.type-of(selector.nest(".foo", ".bar"));
        \\  append-inspect: meta.inspect(selector.append(".foo", ".bar"));
        \\  nest-inspect: meta.inspect(selector.nest(".foo", ".bar"));
        \\  append-length: list.length(selector.append(".a, .b", ".c"));
        \\  from-value: selector.append(selector.parse(".typed"), ".value");
        \\  list-splat: selector.append((".splat", ".item")...);
        \\  nest-splat: selector.nest((".root", "&.child")...);
        \\  alias: sel.append(".alias", ".ok");
        \\  star: nest(".star", "&.ok");
        \\  marked: selector.append(mark(".marked"), mark(".ok"));
        \\  evaluations: $evaluations;
        \\}
    ;
    var result = try compile(std.testing.allocator, "selector-append-nest.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{append-one:.a;append-basic:.foo.bar;append-three:.accordion__copy.open;append-list:.a.c,.a.d,.b.c,.b.d;append-complex:.a > .b.c > .d;append-pseudo:.foo:hover;append-type:.foobutton;append-attr:.foo[x];append-universal:*.foo;append-namespaced:svg|a.foo;nest-one:.a,.b;nest-basic:.foo .bar;nest-parent:.foo:hover;nest-list:.a .c,.a .d,.b .c,.b .d;nest-repeat:.foo + .foo,.foo + .bar,.bar + .foo,.bar + .bar;nest-deep:.a:hover,.c .a,.b:hover,.c .b;nest-combinator:.a > .b;nest-three:.a.b:hover;append-typeof:list;nest-typeof:list;append-inspect:(.foo.bar,);nest-inspect:(.foo .bar,);append-length:2;from-value:.typed.value;list-splat:.splat.item;nest-splat:.root.child;alias:.alias.ok;star:.star.ok;marked:.marked.ok;evaluations:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\@use "sass:meta"
        \\.sass
        \\  type: meta.type-of(selector.append(".a", ".b"))
        \\  append: selector.append(".a, .b", ".c")
        \\  nest: selector.nest(".a, .b", "&:hover")
        \\  inspect: meta.inspect(selector.nest(".root", "> .child"))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-append-nest.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{type:list;append:.a.c,.b.c;nest:.a:hover,.b:hover;inspect:(.root > .child,)}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module compares structural superselectors" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:selector" as sel;
        \\@use "sass:selector" as *;
        \\$count: 0;
        \\@function mark($value) {
        \\  $count: $count + 1 !global;
        \\  @return $value;
        \\}
        \\.values {
        \\  same: selector.is-superselector(".a", ".a");
        \\  class-extra: selector.is-superselector(".a", ".a.b");
        \\  class-reverse: selector.is-superselector(".a.b", ".a");
        \\  universal-type: selector.is-superselector("*", "button");
        \\  type-universal: selector.is-superselector("button", "*");
        \\  type-class: selector.is-superselector("button", "button.primary");
        \\  namespaced: selector.is-superselector("svg|*", "svg|a.icon");
        \\  any-namespace: selector.is-superselector("*|a", "svg|a");
        \\  wrong-namespace: selector.is-superselector("html|*", "svg|a");
        \\  descendant: selector.is-superselector(".a .b", ".x .a .y .b");
        \\  descendant-child: selector.is-superselector(".a .b", ".a > .b");
        \\  child-descendant: selector.is-superselector(".a > .b", ".a .b");
        \\  sibling: selector.is-superselector(".a ~ .b", ".a + .b");
        \\  adjacent: selector.is-superselector(".a + .b", ".a ~ .b");
        \\  list-all: selector.is-superselector(".foo, .bar", ".foo.baz, .bar.qux");
        \\  list-not-all: selector.is-superselector(".foo", ".foo, .bar");
        \\  target-one: selector.is-superselector(".foo, .bar", ".foo");
        \\  functional-exact: selector.is-superselector(":not(.a)", ":not(.a)");
        \\  functional-extra: selector.is-superselector(":not(.a)", ":not(.a).b");
        \\  ordinary-functional-extra: selector.is-superselector(".a", ".a:is(.b)");
        \\  pseudo-element-subject: selector.is-superselector(".a", ".a::before");
        \\  pseudo-element-extra: selector.is-superselector("::before", ".a::before");
        \\  legacy-pseudo-element: selector.is-superselector(":before", "::before");
        \\  typed: selector.is-superselector(selector.parse(".typed"), ".typed.more");
        \\  from-list: selector.is-superselector((".a", ".b"), (".a.x", ".b.y"));
        \\  alias: sel.is-superselector("#id", "#id.item");
        \\  star: is-superselector("[x=y]", "button[x=y]");
        \\  keyword: selector.is-superselector($sub: ".k.x", $super: ".k");
        \\  marked: selector.is-superselector(mark(".m"), mark(".m.x"));
        \\  evaluations: $count;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-is-superselector.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{same:true;class-extra:true;class-reverse:false;universal-type:true;type-universal:false;type-class:true;namespaced:true;any-namespace:true;wrong-namespace:false;descendant:true;descendant-child:true;child-descendant:false;sibling:true;adjacent:false;list-all:true;list-not-all:false;target-one:true;functional-exact:true;functional-extra:true;ordinary-functional-extra:true;pseudo-element-subject:false;pseudo-element-extra:true;legacy-pseudo-element:true;typed:true;from-list:true;alias:true;star:true;keyword:true;marked:true;evaluations:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  same: selector.is-superselector(".a", ".a.b")
        \\  complex: selector.is-superselector(".a .b", ".a > .b")
        \\  list: selector.is-superselector(".a, .b", ".a.x, .b.y")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-is-superselector.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{same:true;complex:true;list:true}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module extends and replaces compound matches" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\@use "sass:list";
        \\@use "sass:selector" as sel;
        \\@use "sass:selector" as *;
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.values {
        \\  basic: selector.extend(".a", ".a", ".b");
        \\  replace: selector.replace(".a", ".a", ".b");
        \\  compound: selector.extend(".a.c", ".a", ".b.d");
        \\  complex: selector.extend(".x > .a + .y", ".a", ".b");
        \\  repeated: selector.extend(".a.c .a.d", ".a", ".b");
        \\  list: selector.replace(".a, .x > .a, .none", ".a", ".b");
        \\  no-match: selector.extend(".none", ".a", ".b");
        \\  typed: selector.replace(selector.parse("button.a"), ".a", ".b");
        \\  keyword: selector.extend($extender: ".k3", $selector: ".k1.k2", $extendee: ".k1");
        \\  alias: sel.replace(".m1.m2", ".m1", ".m3");
        \\  star: extend(".s1", ".s1", ".s2");
        \\  marked: selector.replace(mark(".q1"), mark(".q1"), mark(".q2"));
        \\  evaluations: $evaluations;
        \\  type: meta.type-of(selector.extend(".a", ".a", ".b"));
        \\  separator: list.separator(selector.extend(".a", ".a", ".b"));
        \\  inspect: meta.inspect(selector.extend(".a", ".a", ".b"));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-extend-replace.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{basic:.a,.b;replace:.b;compound:.a.c,.c.b.d;complex:.x > .a + .y,.x > .b + .y;repeated:.a.c .a.d,.c.b .a.d,.a.c .d.b,.c.b .d.b;list:.b,.x > .b,.none;no-match:.none;typed:button.b;keyword:.k1.k2,.k2.k3;alias:.m2.m3;star:.s1,.s2;marked:.q2;evaluations:3;type:list;separator:comma;inspect:.a, .b}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  extend: selector.extend(".a.c", ".a", ".b")
        \\  replace: selector.replace(".x > .a", ".a", ".b")
        \\  repeated: selector.extend(".a .a", ".a", ".b")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-extend-replace.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{extend:.a.c,.c.b;replace:.x > .b;repeated:.a .a,.b .a,.a .b,.b .b}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module extends and replaces compound lists" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\@use "sass:list";
        \\.values {
        \\  extendee-list: selector.extend(".a.c .a", ".a, .c", ".x");
        \\  replace-extendee-list: selector.replace(".a.c .a", ".a, .c", ".x");
        \\  extender-list: selector.extend(".a .a", ".a", ".d, .b");
        \\  replace-extender-list: selector.replace(".a .a", ".a", ".d, .b");
        \\  both-lists: selector.extend(".a.c", ".a, .c", ".b, .d");
        \\  replace-both-lists: selector.replace(".a, .c", ".a, .c", ".b, .d");
        \\  ordered: selector.replace(".a.b", ".a, .a.b", ".x");
        \\  reversed: selector.replace(".a.b", ".a.b, .a", ".x");
        \\  typed: selector.replace("button.a, #id.a", ".a, .z", ".b, .c");
        \\  no-match: selector.extend(".none", ".a, .c", ".b, .d");
        \\  type: meta.type-of(selector.extend(".a", ".a, .c", ".b, .d"));
        \\  separator: list.separator(selector.extend(".a", ".a, .c", ".b, .d"));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-extend-replace-lists.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{extendee-list:.a.c .a,.x .a,.a.c .x,.x .x;replace-extendee-list:.x .x;extender-list:.a .a,.d .a,.b .a,.a .d,.d .d,.b .d,.a .b,.d .b,.b .b;replace-extender-list:.d .d,.b .d,.d .b,.b .b;both-lists:.a.c,.b,.d;replace-both-lists:.b,.d,.b;ordered:.b.x;reversed:.x;typed:button.b,button.c,#id.b,#id.c;no-match:.none;type:list;separator:comma}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  extendee: selector.extend(".a.c", ".a, .c", ".x")
        \\  extender: selector.replace(".a .a", ".a", ".d, .b")
        \\  ordered: selector.replace(".a.b", ".a, .a.b", ".x")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-extend-replace-lists.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{extendee:.a.c,.x;extender:.d .d,.b .d,.d .b,.b .b;ordered:.b.x}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module normalizes duplicate simples and equivalent members" {
    const input =
        \\@use "sass:selector";
        \\.values {
        \\  target-duplicate: selector.extend(".a.a.c", ".a", ".b");
        \\  target-duplicate-replace: selector.replace(".a.a.c", ".a", ".b");
        \\  extendee-duplicate: selector.extend(".a.a.c", ".a.a", ".b");
        \\  extender-duplicate: selector.extend(".a.c", ".a", ".b.b");
        \\  whole-extender-duplicate: selector.replace(".a", ".a", ".b.b");
        \\  equivalent-target: selector.extend(".a.b, .b.a", ".a", ".c");
        \\  duplicate-target: selector.extend(".a, .a", ".a", ".b");
        \\  duplicate-trim: selector.extend(".a, .a, .c", ".a", ".b");
        \\  duplicate-identity: selector.extend(".a, .a", ".a", ".a");
        \\  duplicate-extendee-list: selector.replace(".a", ".a, .a", ".b");
        \\  equivalent-extendee-list: selector.replace(".a.b", ".a.b, .b.a", ".x");
        \\  normalized-pattern: selector.extend(".a", ".a.a.a.a.a", ".b, .c");
        \\  duplicate-extender-list: selector.extend(".a", ".a", ".b, .b");
        \\  equivalent-extender-list: selector.replace(".a", ".a", ".b.c, .c.b");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-extend-replace-normalized.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{target-duplicate:.a.a.c,.c.b;target-duplicate-replace:.c.b;extendee-duplicate:.a.a.c,.c.b;extender-duplicate:.a.c,.c.b;whole-extender-duplicate:.b.b;equivalent-target:.a.b,.b.c,.b.a;duplicate-target:.a,.b,.a;duplicate-trim:.a,.b,.c;duplicate-identity:.a;duplicate-extendee-list:.b;equivalent-extendee-list:.x;normalized-pattern:.a,.b,.c;duplicate-extender-list:.a,.b;equivalent-extender-list:.b.c}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  duplicate: selector.extend(".a.a", ".a", ".b")
        \\  equivalent: selector.replace(".a", ".a", ".c.b, .b.c")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-extend-replace-normalized.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{duplicate:.a.a,.b;equivalent:.c.b}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module normalizes bounded attributes" {
    const input =
        \\@use "sass:selector";
        \\.values {
        \\  parse: selector.parse("[ x = \"y\" ]");
        \\  quoted: selector.parse("[x='a b']");
        \\  simple: selector.simple-selectors("button[x='a b']");
        \\  relation: selector.is-superselector("[x='a b']", ".more[x=\"a b\"]");
        \\  modifier: selector.is-superselector("[x=y i]", "[x=y I]");
        \\  unify: selector.unify("[ x = 'a b' ]", "[x=\"a b\"]");
        \\  extend: selector.extend("[x=\"y\"].c", "[x=y]", ".b");
        \\  replace: selector.replace("[x='a b'].c", "[x=\"a b\"]", ".b");
        \\  duplicate: selector.extend("[x=y][x=\"y\"].c", "[x=y]", ".b");
        \\  no-match: selector.extend("[ x = \"y\" ]", "[z]", ".b");
        \\  extender: selector.replace("[x=y]", "[x=y]", "[z=\"q\"]");
        \\  namespace: selector.extend("[*|x=y].c", "[*|x=\"y\"]", ".b");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-attributes.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{parse:[x=y];quoted:[x=\"a b\"];simple:button,[x=\"a b\"];relation:true;modifier:false;unify:[x=\"a b\"];extend:[x=y].c,.c.b;replace:.c.b;duplicate:[x=y][x=y].c,.c.b;no-match:[x=y];extender:[z=q];namespace:[*|x=y].c,.c.b}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  parsed: selector.parse("[ data = 'wide value' I]")
        \\  extended: selector.extend("[data='wide value'].x", "[data=\"wide value\"]", ".y")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-attributes.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{parsed:[data=\"wide value\" I];extended:[data=\"wide value\"].x,.x.y}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module normalizes bounded escapes" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\.values {
        \\  class: selector.parse(".\\66 oo");
        \\  digit: selector.parse(".\\00003123");
        \\  unicode: selector.parse(".caf\\e9 ");
        \\  emoji: selector.parse(".\\1f49a ");
        \\  punctuation: selector.parse(".foo\\2b bar");
        \\  escaped-hyphen: selector.parse(".\\2d foo");
        \\  id: selector.parse("#\\66 oo");
        \\  placeholder: selector.parse("%\\31 23");
        \\  type: selector.parse("\\62 utton");
        \\  qualified: selector.parse("\\73 vg|\\61 ");
        \\  escaped-star: selector.parse("\\2a ");
        \\  attribute-name: selector.parse("[\\78 =y]");
        \\  attribute-namespace: selector.parse("[\\6e s|\\78 =y]");
        \\  attribute-value: selector.parse("[x=\\79 es]");
        \\  attribute-digit: selector.parse("[x=\\31 23]");
        \\  attribute-punctuation: selector.parse("[x=foo\\2b bar]");
        \\  attribute-quoted: selector.parse("[x='\\79 ']");
        \\  attribute-space: selector.parse("[x='a\\20 b']");
        \\  relation-class: selector.is-superselector(".foo", ".\\66 oo");
        \\  relation-attribute: selector.is-superselector("[x=y]", "[\\78 =\\79 ]");
        \\  escaped-distinct: selector.is-superselector(".-foo", ".\\2d foo");
        \\  unify-class: selector.unify(".foo", ".\\66 oo");
        \\  unify-attribute: selector.unify("[x=yes]", "[\\78 =\\79 es]");
        \\  extend-class: selector.extend(".\\66 oo.c", ".foo", ".bar");
        \\  replace-attribute: selector.replace("[\\78 =\\79 ].c", "[x=y]", ".bar");
        \\  type-of: meta.type-of(selector.parse(".\\66 oo"));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-escapes.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{class:.foo;digit:.\\31 23;unicode:.café;emoji:.💚;punctuation:.foo\\+bar;escaped-hyphen:.\\-foo;id:#foo;placeholder:%\\31 23;type:button;qualified:svg|a;escaped-star:\\*;attribute-name:[x=y];attribute-namespace:[ns|x=y];attribute-value:[x=yes];attribute-digit:[x=\\31 23];attribute-punctuation:[x=foo\\+bar];attribute-quoted:[x=y];attribute-space:[x=\"a b\"];relation-class:true;relation-attribute:true;escaped-distinct:false;unify-class:.foo;unify-attribute:[x=yes];extend-class:.foo.c,.c.bar;replace-attribute:.c.bar;type-of:list}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  parsed: selector.parse(".\\66 oo")
        \\  attribute: selector.parse("[\\78 =\\79 es]")
        \\  relation: selector.is-superselector(".foo", ".\\66 oo")
        \\  extended: selector.extend("[\\78 =\\79 ].x", "[x=y]", ".z")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-escapes.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{parsed:.foo;attribute:[x=yes];relation:true;extended:[x=y].x,.x.z}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module normalizes bounded simple pseudos" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\.values {
        \\  simple: selector.parse(":\\68 over");
        \\  digit: selector.parse(":\\00003123");
        \\  unicode: selector.parse(":caf\\e9 ");
        \\  emoji: selector.parse(":\\1f49a ");
        \\  punctuation: selector.parse(":foo\\2b bar");
        \\  escaped-hyphen: selector.parse(":\\2d foo");
        \\  element: selector.parse("::\\62 efore");
        \\  element-emoji: selector.parse("::\\1f49a ");
        \\  relation: selector.is-superselector(":hover", ":\\68 over.foo");
        \\  relation-element: selector.is-superselector(":before", "::\\62 efore.foo");
        \\  case-distinct: selector.is-superselector(":HOVER", ":hover");
        \\  unify: selector.unify(":hover", ":\\68 over");
        \\  unify-element: selector.unify(":before", "::\\62 efore");
        \\  extend: selector.extend(".x:hover", ":\\68 over", ".y");
        \\  replace: selector.replace(".x:hover", ":\\68 over", ".y");
        \\  extend-context: selector.extend(".x:hover", ".x", ":focus");
        \\  replace-context: selector.replace(".x:hover", ".x", ":focus");
        \\  type: meta.type-of(selector.parse(":\\68 over"));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-simple-pseudos.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{simple::hover;digit::\\31 23;unicode::café;emoji::💚;punctuation::foo\\+bar;escaped-hyphen::\\-foo;element:::before;element-emoji:::💚;relation:true;relation-element:true;case-distinct:false;unify::hover;unify-element::before;extend:.x:hover,.x.y;replace:.x.y;extend-context:.x:hover,:hover:focus;replace-context::hover:focus;type:list}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  parsed: selector.parse(":\\68 over")
        \\  element: selector.parse("::\\62 efore")
        \\  relation: selector.is-superselector(":hover", ":\\68 over.x")
        \\  unified: selector.unify(":before", "::\\62 efore")
        \\  extended: selector.extend(".x:hover", ":\\68 over", ".y")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-simple-pseudos.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{parsed::hover;element:::before;relation:true;unified::before;extended:.x:hover,.x.y}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module normalizes bounded selector-list functional pseudos" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\.values {
        \\  not: selector.parse(":not( .\\61 , #\\62 )");
        \\  is: selector.parse(":\\69 s(.\\61 ,, .b)");
        \\  where: selector.parse(":where(.a, :\\6e ot( .b , .c ))");
        \\  has: selector.parse(":has(> .\\61 , + #\\62 )");
        \\  matches: selector.parse(":\\6d atches(.\\61 , .b)");
        \\  any: selector.parse(":\\61 ny(.\\61 , .b)");
        \\  webkit: selector.parse(":-webkit-any(.\\61 , .b)");
        \\  nested: selector.parse(":not(:\\69 s(.\\61 , :where(.b, .c)))");
        \\  relation-not: selector.is-superselector(":not(.a, .b)", ":\\6e ot(.\\61 , .b).x");
        \\  relation-is: selector.is-superselector(":is(.a, .b)", ":\\69 s(.\\61 , .b).x");
        \\  relation-where: selector.is-superselector(":where(.a, .b)", ":\\77 here(.\\61 , .b).x");
        \\  relation-has: selector.is-superselector(":has(.a, .b)", ":\\68 as(.\\61 , .b).x");
        \\  relation-relative: selector.is-superselector(":has(> .a)", ":has(> .a)");
        \\  relation-covered: selector.is-superselector("*, :has(> .a)", "*, :has(> .a)");
        \\  unify-not: selector.unify(":not(.a, .b)", ":\\6e ot(.\\61 , .b)");
        \\  unify-is: selector.unify(":is(.a, .b)", ":\\69 s(.\\61 , .b)");
        \\  unify-has: selector.unify(":has(> .a, + .b)", ":\\68 as(> .\\61 , + .b)");
        \\  type: meta.type-of(selector.parse(":\\69 s(.a, .b)"));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-functional-pseudos.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{not::not(.a, #b);is::is(.a, .b);where::where(.a, :not(.b, .c));has::has(> .a, + #b);matches::matches(.a, .b);any::any(.a, .b);webkit::-webkit-any(.a, .b);nested::not(:is(.a, :where(.b, .c)));relation-not:true;relation-is:true;relation-where:true;relation-has:true;relation-relative:false;relation-covered:true;unify-not::not(.a, .b);unify-is::is(.a, .b);unify-has::has(> .a, + .b);type:list}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  parsed: selector.parse(":\\69 s(.\\61 , .b)")
        \\  nested: selector.parse(":not(:\\77 here(.\\61 , .b))")
        \\  relation: selector.is-superselector(":is(.a, .b)", ":\\69 s(.\\61 , .b).x")
        \\  relative: selector.is-superselector(":has(> .a)", ":has(> .a)")
        \\  unified: selector.unify(":not(.a, .b)", ":\\6e ot(.\\61 , .b)")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-functional-pseudos.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{parsed::is(.a, .b);nested::not(:where(.a, .b));relation:true;relative:false;unified::not(.a, .b)}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module compares selector-list functional pseudos" {
    const input =
        \\@use "sass:selector";
        \\.values {
        \\  is-subset: selector.is-superselector(":is(.a, .b)", ":where(.a)");
        \\  is-reverse: selector.is-superselector(":is(.a)", ":where(.a, .b)");
        \\  legacy-cross: selector.is-superselector(":-webkit-any(.a, .b)", ":-moz-any(.a)");
        \\  plain-super: selector.is-superselector(".a", ":matches(.a)");
        \\  positive-super: selector.is-superselector(":any(.a, .b)", ".b.x");
        \\  not-subset: selector.is-superselector(":not(.a)", ":not(.a, .b)");
        \\  not-reverse: selector.is-superselector(":not(.a, .b)", ":not(.a)");
        \\  nested-not: selector.is-superselector(":not(:is(.a, .b))", ":not(.a, .b)");
        \\  nested-not-reverse: selector.is-superselector(":not(.a, .b)", ":not(:is(.a, .b))");
        \\  has-subset: selector.is-superselector(":has(.a, .b)", ":has(.a.x)");
        \\  has-reverse: selector.is-superselector(":has(.a.x)", ":has(.a)");
        \\  has-nested: selector.is-superselector(":has(.a, .b)", ":has(:is(.a, .b))");
        \\  has-nested-reverse: selector.is-superselector(":has(:is(.a, .b))", ":has(.a, .b)");
        \\  relative: selector.is-superselector(":has(> .a)", ":has(> .a)");
        \\  relative-covered: selector.is-superselector("*, :has(> .a)", ":has(> .a)");
        \\  positive-relative: selector.is-superselector(":is(.a)", ":where(> .a)");
        \\  positive-relative-self: selector.is-superselector(":is(> .a)", ":is(> .a)");
        \\  list-forward: selector.is-superselector(":is(.a), .b", ":is(.a, .b)");
        \\  list-reverse: selector.is-superselector(":is(.a, .b)", ":is(.a), .b");
        \\  case-distinct: selector.is-superselector(":is(.a)", ":IS(.a)");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-functional-pseudo-relations.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{is-subset:true;is-reverse:false;legacy-cross:true;plain-super:true;positive-super:true;not-subset:true;not-reverse:false;nested-not:false;nested-not-reverse:true;has-subset:true;has-reverse:false;has-nested:false;has-nested-reverse:true;relative:false;relative-covered:true;positive-relative:true;positive-relative-self:false;list-forward:false;list-reverse:true;case-distinct:false}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  positive: selector.is-superselector(":where(.a, .b)", ":matches(.b.x)")
        \\  negated: selector.is-superselector(":not(.a)", ":not(.a, .b)")
        \\  relational: selector.is-superselector(":has(.a, .b)", ":has(.a.x)")
        \\  relative: selector.is-superselector(":has(+ .a)", ":has(+ .a)")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-functional-pseudo-relations.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{positive:true;negated:true;relational:true;relative:false}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module extends and replaces selector-list functional pseudos" {
    const input =
        \\@use "sass:selector";
        \\.values {
        \\  extend: selector.extend(":is(.a,.b)", ".a", ".x");
        \\  replace: selector.replace(":is(.a,.b)", ".a", ".x");
        \\  context: selector.extend(".root:where(.a,.b):hover", ".a", ".x");
        \\  nested: selector.extend(":not(:is(.a,.b),.c)", ".a", ".x");
        \\  partial: selector.replace(":matches(.a.b,.c)", ".a", ".x");
        \\  complex: selector.extend(":any(.a .b,.c)", ".b", ".x");
        \\  relative: selector.replace(":has(> .a,+ .b)", ".a", ".x");
        \\  whole: selector.extend(".root:-webkit-any(.a,.b)", ":-webkit-any(.a,.b)", ".x");
        \\  same-component: selector.extend(".a:is(.a,.b)", ".a", ".x");
        \\  functional-extender: selector.extend(":is(.a,.b)", ".a", ":is(.x,.y)");
        \\  ignored-extender: selector.replace(":is(.a,.b)", ".a", ":where(.x,.y)");
        \\  case-distinct: selector.extend(":IS(.a,.b)", ".a", ".x");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-functional-pseudo-extension.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{extend::is(.a, .x, .b);replace::is(.x, .b);context:.root:where(.a, .x, .b):hover;nested::not(.a, .x, .b, .c);partial::matches(.b.x, .c);complex::any(.a .b, .a .x, .c);relative::has(> .x, + .b);whole:.root:-webkit-any(.a, .b),.root.x;same-component:.a:is(.a, .x, .b),.x:is(.a, .x, .b);functional-extender::is(.a, .x, .y, .b);ignored-extender::is(.b);case-distinct::IS(.a,.b)}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.sass
        \\  extended: selector.extend(":where(.a,.b)", ".a", ".x")
        \\  replaced: selector.replace(":not(.a,.b)", ".a", ".x")
        \\  nested: selector.extend(":not(:matches(.a,.b),.c)", ".a", ".x")
        \\  relative: selector.extend(":has(+ .a, ~ .b)", ".a", ".x")
        \\  whole: selector.replace(".root:is(.a,.b)", ":is(.a,.b)", ".x")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-functional-pseudo-extension.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{extended::where(.a, .x, .b);replaced::not(.x, .b);nested::not(.a, .x, .b, .c);relative::has(+ .a, + .x, ~ .b);whole:.root.x}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module supports nth-function grammar relations unification and extension" {
    const input =
        \\@use "sass:selector";
        \\.values {
        \\  parsed: selector.parse(":nth-child(2N + 01 oF .a,.b)");
        \\  simple: selector.simple-selectors(".root:nth-last-child(-n + 4 of .a,.b):hover");
        \\  exact: selector.is-superselector(":nth-child(2n + 1 of .a)", ":nth-child(2n+1 of .a)");
        \\  formula-equivalent: selector.is-superselector(":nth-child(odd)", ":nth-child(2n+1)");
        \\  selector-subset: selector.is-superselector(":nth-child(odd of .a,.b)", ":nth-child(odd of .a.x)");
        \\  subject: selector.is-superselector(".a", ":nth-child(odd of .a)");
        \\  reverse-subject: selector.is-superselector(":nth-child(odd of .a)", ".a");
        \\  relative: selector.is-superselector(":nth-child(odd of > .a)", ":nth-child(odd of > .a)");
        \\  unified: selector.unify(":nth-child(odd)", ":nth-child(2n+1)");
        \\  invalid-unified: selector.unify(":nth-child(odd of > .a)", ".x");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-nth-functions.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{parsed::nth-child(2n+01 of .a, .b);simple:.root,:nth-last-child(-n+4 of .a, .b),:hover;exact:true;formula-equivalent:false;selector-subset:true;subject:true;reverse-subject:false;relative:false;unified::nth-child(odd):nth-child(2n+1)}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const extension_input =
        \\@use "sass:selector";
        \\.extensions {
        \\  extend: selector.extend(":nth-child(2n + 1 of .a,.b)", ".a", ".x");
        \\}
    ;
    var extension_result = try compile(
        std.testing.allocator,
        "selector-nth-function-extension.scss",
        extension_input,
        .scss,
        .{},
    );
    defer extension_result.deinit();
    try std.testing.expectEqualStrings(
        ".extensions{extend::nth-child(2n+1 of .a, .x, .b)}",
        extension_result.css(),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        extension_result.nativeDiagnostics().len,
    );
}

test "native Sass selector module supports opaque lang-function grammar relations unification and extension" {
    const input =
        \\@use "sass:selector";
        \\.values {
        \\  parsed: selector.parse(":lang( EN , fr )");
        \\  uppercase: selector.parse(":LANG( EN )");
        \\  simple: selector.simple-selectors(".root:lang(en/**/, fr):hover");
        \\  exact: selector.is-superselector(":lang(en   US)", ":lang(en US)");
        \\  distinct: selector.is-superselector(":lang(en)", ":lang(fr)");
        \\  case-distinct: selector.is-superselector(":LANG(en)", ":lang(en)");
        \\  subject: selector.is-superselector(".a", ".a:lang(en)");
        \\  reverse-subject: selector.is-superselector(".a:lang(en)", ".a");
        \\  unified: selector.unify(":lang(en)", ":lang(fr)");
        \\}
        \\.extensions {
        \\  partial: selector.extend(".a:lang(en)", ".a", ".x");
        \\  replaced: selector.replace(".a:lang(en)", ".a", ".x");
        \\  whole: selector.extend(".a:lang(en)", ":lang(en)", ".x");
        \\  nested: selector.extend(":is(:lang(en),.a)", ":lang(en)", ".x");
        \\  opaque: selector.extend(":lang(.a)", ".a", ".x");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-lang-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{parsed::lang(EN , fr);uppercase::LANG(EN);simple:.root,:lang(en/**/, fr),:hover;exact:true;distinct:false;case-distinct:false;subject:true;reverse-subject:false;unified::lang(en):lang(fr)}.extensions{partial:.a:lang(en),.x:lang(en);replaced:.x:lang(en);whole:.a:lang(en),.a.x;nested::is(:lang(en), .x, .a);opaque::lang(.a)}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass selector module supports opaque dir-function grammar relations unification and extension" {
    const input =
        \\@use "sass:selector";
        \\.values {
        \\  parsed: selector.parse(":dir( LTR , rtl )");
        \\  uppercase: selector.parse(":DIR( RTL )");
        \\  simple: selector.simple-selectors(".root:dir(ltr/**/ rtl):hover");
        \\  exact: selector.is-superselector(":dir(ltr   rtl)", ":dir(ltr rtl)");
        \\  distinct: selector.is-superselector(":dir(ltr)", ":dir(rtl)");
        \\  case-distinct: selector.is-superselector(":DIR(ltr)", ":dir(ltr)");
        \\  subject: selector.is-superselector(".a", ".a:dir(ltr)");
        \\  reverse-subject: selector.is-superselector(".a:dir(ltr)", ".a");
        \\  unified: selector.unify(":dir(ltr)", ":dir(rtl)");
        \\}
        \\.extensions {
        \\  partial: selector.extend(".a:dir(ltr)", ".a", ".x");
        \\  replaced: selector.replace(".a:dir(ltr)", ".a", ".x");
        \\  whole: selector.extend(".a:dir(ltr)", ":dir(ltr)", ".x");
        \\  nested: selector.extend(":is(:dir(ltr),.a)", ":dir(ltr)", ".x");
        \\  opaque: selector.extend(":dir(.a)", ".a", ".x");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-dir-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{parsed::dir(LTR , rtl);uppercase::DIR(RTL);simple:.root,:dir(ltr/**/ rtl),:hover;exact:true;distinct:false;case-distinct:false;subject:true;reverse-subject:false;unified::dir(ltr):dir(rtl)}.extensions{partial:.a:dir(ltr),.x:dir(ltr);replaced:.x:dir(ltr);whole:.a:dir(ltr),.a.x;nested::is(:dir(ltr), .x, .a);opaque::dir(.a)}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass selector module unifies compound selector values" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\@use "sass:list";
        \\@use "sass:selector" as sel;
        \\@use "sass:selector" as *;
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.values {
        \\  class: selector.unify(".a", ".b");
        \\  same: selector.unify(".a", ".a");
        \\  type-class: selector.unify("button", ".a");
        \\  universal-type: selector.unify("*", "button");
        \\  namespace: selector.unify("*|a", "svg|a");
        \\  attributes: selector.unify("[x]", "[y]");
        \\  pseudo: selector.unify(":hover", ".a");
        \\  pseudo-element: selector.unify("::before", ".a");
        \\  list: selector.unify(".a, .b", ".x, .y");
        \\  functional-exact: selector.unify(":not(.a)", ".b:not(.a)");
        \\  typed: selector.unify(selector.parse(".typed"), ".more");
        \\  from-list: selector.unify((".l", ".r"), ".x");
        \\  keyword: selector.unify($selector2: ".k2", $selector1: ".k1");
        \\  alias: sel.unify(".m1", ".m2");
        \\  star: unify(".m1", ".m2");
        \\  marked: selector.unify(mark(".m1"), mark(".m2"));
        \\  evaluations: $evaluations;
        \\  type: meta.type-of(selector.unify(".a", ".b"));
        \\  separator: list.separator(selector.unify(".a", ".b"));
        \\  inspect: meta.inspect(selector.unify(".a", ".b"));
        \\  type-conflict: meta.inspect(selector.unify("a", "b"));
        \\  id-conflict: meta.inspect(selector.unify("#a", "#b"));
        \\  namespace-conflict: meta.inspect(selector.unify("svg|a", "html|a"));
        \\  pseudo-conflict: meta.inspect(selector.unify("::before", "::after"));
        \\}
    ;
    var result = try compile(std.testing.allocator, "selector-unify.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{class:.a.b;same:.a;type-class:button.a;universal-type:button;namespace:svg|a;attributes:[x][y];pseudo:.a:hover;pseudo-element:.a::before;list:.a.x,.a.y,.b.x,.b.y;functional-exact:.b:not(.a);typed:.typed.more;from-list:.l.x,.r.x;keyword:.k1.k2;alias:.m1.m2;star:.m1.m2;marked:.m1.m2;evaluations:2;type:list;separator:comma;inspect:(.a.b,);type-conflict:null;id-conflict:null;namespace-conflict:null;pseudo-conflict:null}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\@use "sass:meta"
        \\.sass
        \\  value: selector.unify(".a", ".b")
        \\  list: selector.unify(".a, .b", ".x")
        \\  pseudo: selector.unify("::before", ".a")
        \\  null: meta.inspect(selector.unify("a", "b"))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-unify.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{value:.a.b;list:.a.x,.b.x;pseudo:.a::before;null:null}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module unifies strict complex selector values" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\.complex {
        \\  left: selector.unify(".a .b", ".c");
        \\  right: selector.unify(".a", ".b .c");
        \\  exact: selector.unify(".a > .b", ".a > .b");
        \\  shared: selector.unify(".a .b", ".a .c");
        \\  strict: selector.unify(".a > .b + .c", ".d > .e + .f");
        \\  list: selector.unify(".a .b, .x > .y", ".c, .z");
        \\  partial: selector.unify(".a b, .x .y", "c, .z");
        \\  following-one: selector.unify(".a ~ .b", ".c");
        \\  conflict: meta.inspect(selector.unify(".a b", "c"));
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-unify-complex.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".complex{left:.a .b.c;right:.b .a.c;exact:.a > .b;shared:.a .b.c;strict:.a.d > .b.e + .c.f;list:.a .b.c,.a .b.z,.x > .y.c,.x > .y.z;partial:.a b.z,.x c.y,.x .y.z;following-one:.a ~ .b.c;conflict:null}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\@use "sass:meta"
        \\.complex
        \\  left: selector.unify(".a .b", ".c")
        \\  strict: selector.unify(".a > .b", ".c > .d")
        \\  list: selector.unify(".a .b, .x > .y", ".c")
        \\  conflict: meta.inspect(selector.unify(".a b", "c"))
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-unify-complex.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".complex{left:.a .b.c;strict:.a.c > .b.d;list:.a .b.c,.x > .y.c;conflict:null}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module weaves disjoint complex selector values" {
    const input =
        \\@use "sass:selector";
        \\.weave {
        \\  descendant: selector.unify(".a .b", ".c .d");
        \\  deep: selector.unify(".a > .b .c", ".d .e");
        \\  left-rigid: selector.unify(".a > .b", ".c .d");
        \\  right-rigid: selector.unify(".a .b", ".c > .d");
        \\  list: selector.unify(".a .b, .x .y", ".c .d, .z .w");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-unify-weave.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".weave{descendant:.a .c .b.d,.c .a .b.d;deep:.a > .b .d .c.e,.d .a > .b .c.e;left-rigid:.c .a > .b.d;right-rigid:.a .c > .b.d;list:.a .c .b.d,.c .a .b.d,.a .z .b.w,.z .a .b.w,.x .c .y.d,.c .x .y.d,.x .z .y.w,.z .x .y.w}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.weave
        \\  descendant: selector.unify(".a .b", ".c .d")
        \\  rigid: selector.unify(".a > .b", ".c .d")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-unify-weave.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".weave{descendant:.a .c .b.d,.c .a .b.d;rigid:.c .a > .b.d}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module weaves exact shared descendant anchors" {
    const input =
        \\@use "sass:selector";
        \\.shared {
        \\  one: selector.unify(".a .b .c", ".d .b .e");
        \\  prefix: selector.unify(".a .b .c", ".b .d");
        \\  suffix: selector.unify(".a .b .c", ".d .a .e");
        \\  multiple: selector.unify(".a .b .c .d", ".x .b .c .e");
        \\  segments: selector.unify(".a1 .x .a2 .y .s", ".b1 .x .b2 .y .t");
        \\  tail: selector.unify(".a .x .c .s", ".b .x .d .t");
        \\  tie: selector.unify(".a .b .c", ".b .a .d");
        \\  list: selector.unify(".a .b .c", ".d .b .e, .x .b .y");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-unify-shared-lcs.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".shared{one:.a .d .b .c.e,.d .a .b .c.e;prefix:.a .b .c.d;suffix:.d .a .b .c.e;multiple:.a .x .b .c .d.e,.x .a .b .c .d.e;segments:.a1 .b1 .x .a2 .b2 .y .s.t,.b1 .a1 .x .a2 .b2 .y .s.t,.a1 .b1 .x .b2 .a2 .y .s.t,.b1 .a1 .x .b2 .a2 .y .s.t;tail:.a .b .x .c .d .s.t,.b .a .x .c .d .s.t,.a .b .x .d .c .s.t,.b .a .x .d .c .s.t;tie:.a .b .a .c.d;list:.a .d .b .c.e,.d .a .b .c.e,.a .x .b .c.y,.x .a .b .c.y}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.shared
        \\  one: selector.unify(".a .b .c", ".d .b .e")
        \\  multiple: selector.unify(".a .b .c .d", ".x .b .c .e")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-unify-shared-lcs.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".shared{one:.a .d .b .c.e,.d .a .b .c.e;multiple:.a .x .b .c .d.e,.x .a .b .c .d.e}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module weaves shared anchors with rigid ancestry suffixes" {
    const input =
        \\@use "sass:selector";
        \\.rigid {
        \\  child: selector.unify(".a > .b .c", ".d .b .e");
        \\  adjacent: selector.unify(".a + .b .c", ".d .b .e");
        \\  following: selector.unify(".a ~ .b .c", ".d .b .e");
        \\  right: selector.unify(".a .b .c", ".d > .b .e");
        \\  prefix: selector.unify(".p .a > .b .c", ".q .d .b .e");
        \\  tail: selector.unify(".a > .b .x .c", ".d .b .y .e");
        \\  chain: selector.unify(".a > .m + .b .c", ".d .b .e");
        \\  multiple: selector.unify(".a > .x .b + .y .c", ".d .x .e .y .f");
        \\  list: selector.unify(".a > .b .c, .u + .v .w", ".d .b .e");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-unify-shared-rigid.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".rigid{child:.d .a > .b .c.e;adjacent:.d .a + .b .c.e;following:.d .a ~ .b .c.e;right:.a .d > .b .c.e;prefix:.p .q .d .a > .b .c.e,.q .d .p .a > .b .c.e;tail:.d .a > .b .x .y .c.e,.d .a > .b .y .x .c.e;chain:.d .a > .m + .b .c.e;multiple:.d .a > .x .e .b + .y .c.f;list:.d .a > .b .c.e,.u + .v .d .b .w.e,.d .b .u + .v .w.e}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.rigid
        \\  child: selector.unify(".a > .b .c", ".d .b .e")
        \\  prefix: selector.unify(".p .a > .b .c", ".q .d .b .e")
        \\  chain: selector.unify(".a > .m + .b .c", ".d .b .e")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-unify-shared-rigid.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".rigid{child:.d .a > .b .c.e;prefix:.p .q .d .a > .b .c.e,.q .d .p .a > .b .c.e;chain:.d .a > .m + .b .c.e}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector module weaves terminal sibling constraints" {
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\.siblings {
        \\  following: selector.unify(".a ~ .b", ".c ~ .d");
        \\  following-adjacent: selector.unify(".a ~ .b", ".c + .d");
        \\  adjacent-following: selector.unify(".a + .b", ".c ~ .d");
        \\  child-adjacent: selector.unify(".a > .b", ".c + .d");
        \\  adjacent-child: selector.unify(".a + .b", ".c > .d");
        \\  child-following: selector.unify(".a > .b", ".c ~ .d");
        \\  following-child: selector.unify(".a ~ .b", ".c > .d");
        \\  descendant-following: selector.unify(".a .b", ".c ~ .d");
        \\  following-descendant: selector.unify(".a ~ .b", ".c .d");
        \\  conflict-following: selector.unify("a ~ .b", "c ~ .d");
        \\  conflict-following-adjacent: selector.unify("a ~ .b", "c + .d");
        \\  conflict-adjacent: meta.inspect(selector.unify("a + .b", "c + .d"));
        \\  list: selector.unify(".a ~ .b, .x + .y", ".c ~ .d");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-unify-terminal-siblings.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".siblings{following:.a ~ .c ~ .b.d,.c ~ .a ~ .b.d,.a.c ~ .b.d;following-adjacent:.a ~ .c + .b.d,.a.c + .b.d;adjacent-following:.c ~ .a + .b.d,.c.a + .b.d;child-adjacent:.a > .c + .b.d;adjacent-child:.c > .a + .b.d;child-following:.a > .c ~ .b.d;following-child:.c > .a ~ .b.d;descendant-following:.a .c ~ .b.d;following-descendant:.c .a ~ .b.d;conflict-following:a ~ c ~ .b.d,c ~ a ~ .b.d;conflict-following-adjacent:a ~ c + .b.d;conflict-adjacent:null;list:.a ~ .c ~ .b.d,.c ~ .a ~ .b.d,.a.c ~ .b.d,.c ~ .x + .y.d,.c.x + .y.d}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:selector"
        \\.siblings
        \\  following: selector.unify(".a ~ .b", ".c ~ .d")
        \\  adjacent: selector.unify(".a ~ .b", ".c + .d")
        \\  child: selector.unify(".a > .b", ".c + .d")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "selector-unify-terminal-siblings.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".siblings{following:.a ~ .c ~ .b.d,.c ~ .a ~ .b.d,.a.c ~ .b.d;adjacent:.a ~ .c + .b.d,.a.c + .b.d;child:.a > .c + .b.d}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass selector unification budgets growing compounds without truncation" {
    const input =
        \\@use "sass:selector";
        \\.value {
        \\  result: selector.unify(".a", ".b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u");
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "selector-unify-operation-budget.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".value{result:.a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass selector module rejects invalid or unavailable calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-selector-module.scss",
            .input = ".a { value: selector.parse(\".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-selector-namespace.scss",
            .input = "@use \"sass:selector\" as Selector; .a { value: selector.parse(\".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unknown-selector-member.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.nope(\".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-missing.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-too-many.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\".a\", \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-unknown-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse($value: \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-duplicate-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\".a\", $selector: \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-empty.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\"\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-parent.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\"&:hover\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-leading-empty.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\",a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-column-combinator.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\"a || b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-invalid-attribute-value.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\"[x=123]\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-invalid-attribute-modifier.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\"[x=y ii]\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-boolean.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(true); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-map.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse((a: 1)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-parse-splat.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse((\".a\",)...); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "selector-simple-missing.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.simple-selectors(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-simple-too-many.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.simple-selectors(\"a\", \"b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-simple-unknown-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.simple-selectors($value: \"a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-simple-empty.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.simple-selectors(\"\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-simple-complex.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.simple-selectors(\"a b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-simple-list.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.simple-selectors(\"a, b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-simple-parent.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.simple-selectors(\"&:hover\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-append-empty.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.append(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-append-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.append($selector: \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-append-parent.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.append(\".a\", \"&.b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-append-leading-combinator.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.append(\".a\", \"> .b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-append-number.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.append(\".a\", 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-nest-empty.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.nest(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-nest-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.nest($selector: \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-nest-number.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.nest(\".a\", 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-nest-invalid-parent.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.nest(\".a\", \".b&\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-superselector-missing.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.is-superselector(\".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-superselector-too-many.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.is-superselector(\".a\", \".a\", \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-superselector-unknown-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.is-superselector($selector: \".a\", $sub: \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-superselector-number.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.is-superselector(1, \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-superselector-parent.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.is-superselector(\"&.a\", \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-superselector-arbitrary-functional-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.is-superselector(\":foo(ltr)\", \":foo(rtl)\"); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "selector-parse-surrogate-escape-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.parse(\".\\\\d800 \"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-extend-missing.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.extend(\".a\", \".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-replace-too-many.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.replace(\".a\", \".a\", \".b\", \".c\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-extend-unknown-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.extend($selector: \".a\", $extendee: \".a\", $replacement: \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-extend-number.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.extend(1, \".a\", \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-replace-complex-extender-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.replace(\".a\", \".a\", \".x .b\"); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "selector-extend-host-functional-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.extend(\":host(.a)\", \".a\", \".b\"); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "selector-unify-missing.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\".a\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-unify-too-many.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\".a\", \".b\", \".c\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-unify-unknown-keyword.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify($left: \".a\", $selector2: \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-unify-number.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(1, \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-unify-empty.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\"\", \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-unify-parent.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\"&.a\", \".b\"); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "selector-unify-partial-anchor-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\".a.b .c\", \".b.d .e\"); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "selector-unify-dual-rigid-shared-anchor-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\".a > .b .c\", \".d > .b .e\"); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "selector-unify-long-sibling-weave-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\".p .a ~ .b\", \".q .c ~ .d\"); }",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "selector-unify-host-pending.scss",
            .input = "@use \"sass:selector\"; .a { value: selector.unify(\":host(.a)\", \".b\"); }",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var selector_count = sass_evaluator.Limits{};
    selector_count.max_selectors = 1;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-value-count-limit.scss",
            "@use \"sass:selector\"; $value: selector.parse(\".a, .b\");",
            .scss,
            selector_count,
        ),
    );

    var selector_bytes = sass_evaluator.Limits{};
    selector_bytes.max_selector_bytes = 3;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-value-byte-limit.scss",
            "@use \"sass:selector\"; $value: selector.parse(\".abcd\");",
            .scss,
            selector_bytes,
        ),
    );

    var temporary = sass_evaluator.Limits{};
    temporary.max_temporary_bytes = 3;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-value-temporary-limit.scss",
            "@use \"sass:selector\"; $value: selector.parse(\".abcd\");",
            .scss,
            temporary,
        ),
    );

    var composition_count = sass_evaluator.Limits{};
    composition_count.max_selectors = 3;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-composition-count-limit.scss",
            "@use \"sass:selector\"; $value: selector.nest(\".a, .b\", \"& + &\");",
            .scss,
            composition_count,
        ),
    );

    var composition_bytes = sass_evaluator.Limits{};
    composition_bytes.max_selector_bytes = 5;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-composition-byte-limit.scss",
            "@use \"sass:selector\"; $value: selector.append(\".abc\", \".def\");",
            .scss,
            composition_bytes,
        ),
    );

    var unification_count = sass_evaluator.Limits{};
    unification_count.max_selectors = 7;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-unification-count-limit.scss",
            "@use \"sass:selector\"; $value: selector.unify(\".a, .b\", \".x, .y\");",
            .scss,
            unification_count,
        ),
    );

    var extension_count = sass_evaluator.Limits{};
    extension_count.max_selectors = 6;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-extension-count-limit.scss",
            "@use \"sass:selector\"; $value: selector.extend(\".a .a\", \".a\", \".b\");",
            .scss,
            extension_count,
        ),
    );

    var extension_list_count = sass_evaluator.Limits{};
    extension_list_count.max_selectors = 12;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compile(
            std.testing.allocator,
            "selector-extension-list-count-limit.scss",
            "@use \"sass:selector\"; $value: selector.extend(\".a .a\", \".a\", \".b, .c\");",
            .scss,
            extension_list_count,
        ),
    );
}

test "native Sass inspects callable keywords through the built-in meta module" {
    const input =
        \\@use "sass:meta";
        \\@use "sass:meta" as introspect;
        \\@use "sass:meta" as *;
        \\@function pick($first, $rest...) {
        \\  $keywords: meta.keywords($rest);
        \\  @return map-get($keywords, target);
        \\}
        \\@function spelling($args...) {
        \\  $keywords: introspect.keywords($args);
        \\  @return map-get($keywords, start-at) map-get($keywords, "start_at");
        \\}
        \\@function override($args...) {
        \\  $keywords: meta.keywords($args);
        \\  @return map-get($keywords, start-at);
        \\}
        \\@function fixed($value) { @return $value; }
        \\@function forwarded($args...) { @return pick(0, $args...); }
        \\@function empty($args...) { @return length(keywords($args)); }
        \\@mixin expose($args...) {
        \\  $keywords: meta.keywords($args);
        \\  mixin: map-get($keywords, tone);
        \\}
        \\@mixin supply { @content($tone: teal); }
        \\.a {
        \\  direct: pick(0, 1, 2, $target: red);
        \\  forwarded: forwarded($target: blue);
        \\  spelling: spelling($start_at: 7, ("start_at": 8)...);
        \\  override: override($start_at: 1, ("start-at": 2)...);
        \\  reordered: override(("start-at": 3)..., $start_at: 4);
        \\  merged: override(("start-at": 1)..., ("start-at": 2)...);
        \\  fixed: fixed($value: 1, (value: 2)...);
        \\  fixed-reordered: fixed((value: 3)..., $value: 4);
        \\  empty: empty(1, 2);
        \\  @include expose($tone: green);
        \\  @include supply using ($args...) {
        \\    $keywords: meta.keywords($args);
        \\    content: map-get($keywords, tone);
        \\  }
        \\}
    ;
    var result = try compile(std.testing.allocator, "meta-keywords.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{direct:red;forwarded:blue;spelling:7 8;override:2;reordered:3;merged:2;fixed:2;fixed-reordered:3;empty:0;mixin:green;content:teal}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:meta" as m
        \\@function take($args...)
        \\  $keywords: m.keywords($args)
        \\  @return map-get($keywords, tone)
        \\.sass
        \\  value: take($tone: purple)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "meta-keywords.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(".sass{value:purple}", sass_result.css());
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass meta keyword inspection rejects unowned calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-meta-module.scss",
            .input = "@function read($args...) { @return meta.keywords($args); } .a { value: read($x: 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unknown-meta-member.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.nope($undefined); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-keywords-type.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.keywords((a: b)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-keywords-missing.scss",
            .input = "@use \"sass:meta\"; .a { value: meta.keywords(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "meta-keywords-extra.scss",
            .input = "@use \"sass:meta\"; @function read($args...) { @return meta.keywords($args, 1); } .a { value: read(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "duplicate-mixed-module-namespace.scss",
            .input = "@use \"sass:color\" as tools; @use \"sass:meta\" as tools;",
            .expected = error.InvalidSassSyntax,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass color module rejects unresolved ambiguous or unsupported use" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-color-module.scss",
            .input = ".a { color: color.adjust(#123456, $red: 10); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unknown-color-member.scss",
            .input = "@use \"sass:color\"; .a { color: color.nope(red); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-color-namespace.scss",
            .input = "@use \"sass:color\" as Color; .a { color: color.adjust(red, $blue: 1); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "duplicate-color-namespace.scss",
            .input = "@use \"sass:color\"; @use \"sass:color\";",
            .expected = error.InvalidSassSyntax,
        },
        .{
            .name = "late-color-module.scss",
            .input = ".a { color: red; } @use \"sass:color\";",
            .expected = error.InvalidSassSyntax,
        },
        .{
            .name = "nested-color-module.scss",
            .input = ".a { @use \"sass:color\"; color: red; }",
            .expected = error.InvalidSassSyntax,
        },
        .{
            .name = "malformed-color-alias.scss",
            .input = "@use \"sass:color\" as two words;",
            .expected = error.InvalidSassSyntax,
        },
        .{
            .name = "unsupported-builtin-module.scss",
            .input = "@use \"sass:root\";",
            .expected = error.UnsupportedFeature,
        },
        .{
            .name = "unsupported-forward.scss",
            .input = "@forward \"sass:color\";",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var module_limits = sass_evaluator.Limits{};
    module_limits.max_modules = 1;
    try std.testing.expectError(
        error.ModuleLimitExceeded,
        compile(
            std.testing.allocator,
            "color-module-limit.scss",
            "@use \"sass:color\" as first; @use \"sass:color\" as second;",
            .scss,
            module_limits,
        ),
    );
    module_limits.max_modules = 0;
    try std.testing.expectError(
        error.InvalidLimits,
        compile(
            std.testing.allocator,
            "invalid-color-module-limit.scss",
            "@use \"sass:color\";",
            .scss,
            module_limits,
        ),
    );
}

test "native Sass evaluates keyword color transforms without a provider" {
    const input =
        \\.a {
        \\  unchanged: adjust-color(#123456);
        \\  adjust-red: adjust-color(#123456, $red: 10);
        \\  adjust-red-percent: adjust-color(#123456, $red: 10%);
        \\  adjust-green: adjust-color(#123456, $green: 10);
        \\  adjust-blue-percent: adjust-color(#123456, $blue: 10%);
        \\  adjust-hue: adjust-color(#123456, $hue: 30deg);
        \\  adjust-saturation: adjust-color(#123456, $saturation: 20%);
        \\  adjust-lightness: adjust-color(#123456, $lightness: 20%);
        \\  adjust-alpha: adjust-color(rgba(18, 52, 86, .4), $alpha: .2);
        \\  adjust-alpha-percent: adjust-color(rgba(18, 52, 86, .4), $alpha: .2%);
        \\  change-red: change-color(#123456, $red: 256);
        \\  change-green-percent: change-color(#123456, $green: 10%);
        \\  change-blue: change-color(#123456, $blue: 100);
        \\  change-hue: change-color(#123456, $hue: .5turn);
        \\  change-saturation: change-color(#123456, $saturation: 101%);
        \\  change-alpha: change-color(#123456, $alpha: 50%);
        \\  scale-red-up: scale-color(#123456, $red: 50%);
        \\  scale-red-down: scale-color(#123456, $red: -50%);
        \\  scale-green: scale-color(#123456, $green: 100%);
        \\  scale-blue: scale-color(#123456, $blue: -100%);
        \\  scale-saturation: scale-color(#123456, $saturation: 50%);
        \\  scale-lightness: scale-color(#123456, $lightness: 50%);
        \\  scale-alpha: scale-color(rgba(18, 52, 86, .4), $alpha: 50%);
        \\  reordered: adjust-color($red: 10, $color: #123456);
        \\  explicit-rgb: adjust-color(#123456, $red: 10, $space: rgb);
        \\  explicit-hsl: adjust-color(#123456, $hue: 30deg, $space: hsl);
        \\  hsl-to-rgb: adjust-color(hsl(210, 65%, 20%), $red: 10);
        \\  hsl-in-place: adjust-color(hsl(210, 65%, 20%), $hue: 30deg);
        \\}
    ;
    var result = try compile(std.testing.allocator, "keyword-colors.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{unchanged:#123456;adjust-red:#1c3456;adjust-red-percent:rgb(43.5,52,86);adjust-green:#123e56;adjust-blue-percent:rgb(18,52,111.5);adjust-hue:#121256;adjust-saturation:rgb(7.6,52,96.4);adjust-lightness:rgb(35.6538461538,103,170.3461538462);adjust-alpha:rgba(18,52,86,.6);adjust-alpha-percent:rgba(18,52,86,.6);change-red:hsl(350,100.9900990099%,60.3921568627%);change-green-percent:rgb(18,25.5,86);change-blue:#123464;change-hue:#125656;change-saturation:hsl(210,101%,20.3921568627%);change-alpha:rgba(18,52,86,.5);scale-red-up:rgb(136.5,52,86);scale-red-down:#093456;scale-green:#12ff56;scale-blue:#123400;scale-saturation:#09345f;scale-lightness:hsl(210,65.3846153846%,60.1960784314%);scale-alpha:rgba(18,52,86,.7);reordered:#1c3456;explicit-rgb:#1c3456;explicit-hsl:#121256;hsl-to-rgb:rgb(27.85,51,84.15);hsl-in-place:hsl(240,65%,20%)}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass keyword color transforms reject unsafe calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "positional-adjust.scss", .input = ".a { color: adjust-color(#123456, 10); }" },
        .{ .name = "mixed-adjust.scss", .input = ".a { color: adjust-color(#123456, $red: 1, $hue: 1deg); }" },
        .{ .name = "wrong-space.scss", .input = ".a { color: adjust-color(#123456, $red: 1, $space: hsl); }" },
        .{ .name = "unitless-scale.scss", .input = ".a { color: scale-color(#123456, $red: 50); }" },
        .{ .name = "scale-range.scss", .input = ".a { color: scale-color(#123456, $red: 101%); }" },
        .{ .name = "alpha-range.scss", .input = ".a { color: change-color(#123456, $alpha: 1.1); }" },
        .{ .name = "channel-type.scss", .input = ".a { color: adjust-color(#123456, $red: blue); }" },
        .{ .name = "channel-unit.scss", .input = ".a { color: adjust-color(#123456, $green: 1px); }" },
        .{ .name = "scale-hue.scss", .input = ".a { color: scale-color(#123456, $hue: 10%); }" },
        .{ .name = "quoted-space.scss", .input = ".a { color: adjust-color(#123456, $red: 1, $space: \"rgb\"); }" },
        .{ .name = "duplicate-transform.scss", .input = ".a { color: adjust-color(#123456, $red: 1, $red: 2); }" },
        .{ .name = "unknown-transform.scss", .input = ".a { color: adjust-color(#123456, $unknown: 1); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "transform-splat.scss",
            ".a { color: adjust-color($args...); }",
            .scss,
            .{},
        ),
    );
}

test "native Sass evaluates modern cross-space color transforms without a provider" {
    const input =
        \\.a {
        \\  inferred-lab-lightness: adjust-color(lab(50% 10 20), $lightness: 10%);
        \\  lab-axis: adjust-color(lab(50% 10 20), $a: 5, $space: lab);
        \\  lch-chroma: adjust-color(lch(50% 20 30deg), $chroma: 5, $space: lch);
        \\  lch-hue: change-color(lch(50% 20 30deg), $hue: .5turn, $space: lch);
        \\  oklab-axis: adjust-color(oklab(50% .1 .2), $a: .01, $space: oklab);
        \\  oklch-scale: scale-color(oklch(50% .1 30deg), $chroma: 50%, $space: oklch);
        \\  lab-negative-scale: scale-color(lab(50% 10 20), $a: -50%, $space: lab);
        \\  lab-percent-adjust: adjust-color(lab(50% 10 20), $a: 10%, $space: lab);
        \\  oklab-light-scale: scale-color(oklab(50% .1 .2), $lightness: -50%, $space: oklab);
        \\  lch-hue-wrap: adjust-color(lch(50% 20 350deg), $hue: 20deg, $space: lch);
        \\  lch-negative-change: change-color(lch(50% 5 30deg), $chroma: -10, $space: lch);
        \\  lab-outward-scale: scale-color(lab(50% 200 20), $a: 50%, $space: lab);
        \\  lab-out-of-range: change-color(lab(50% 10 20), $lightness: 120%, $space: lab);
        \\  p3-red: adjust-color(color(display-p3 .2 .3 .4), $red: .1);
        \\  linear-green: change-color(color(srgb-linear .2 .3 .4), $green: .5, $space: srgb-linear);
        \\  a98-blue: scale-color(color(a98-rgb .2 .3 .4), $blue: 50%, $space: a98-rgb);
        \\  prophoto-green: adjust-color(color(prophoto-rgb .2 .3 .4), $green: .1, $space: prophoto-rgb);
        \\  rec-blue: scale-color(color(rec2020 .2 .3 .4), $blue: 50%, $space: rec2020);
        \\  xyz-x: adjust-color(color(xyz .2 .3 .4), $x: .1);
        \\  xyz50-y: change-color(color(xyz-d50 .2 .3 .4), $y: .5, $space: xyz-d50);
        \\  xyz65-z: change-color(color(xyz-d65 .2 .3 .4), $z: .6, $space: xyz-d65);
        \\  p3-negative-scale: scale-color(color(display-p3 .2 .3 .4), $red: -50%, $space: display-p3);
        \\  legacy-through-lab: adjust-color(red, $lightness: 10%, $space: lab);
        \\  p3-through-lab: adjust-color(color(display-p3 1 0 0), $lightness: 10%, $space: lab);
        \\  lab-through-p3: adjust-color(lab(50% 10 20), $red: .1, $space: display-p3);
        \\  modern-through-rgb: adjust-color(color(display-p3 .2 .3 .4), $red: 10, $space: rgb);
        \\  modern-through-hsl: adjust-color(lab(50% 10 20), $hue: 30deg, $space: hsl);
        \\  modern-through-hwb: adjust-color(oklab(.5 .1 .2), $whiteness: 10%, $space: hwb);
        \\  modern-alpha: scale-color(oklab(50% .1 .2 / .4), $alpha: 50%);
        \\}
    ;
    var result = try compile(std.testing.allocator, "modern-transform.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{inferred-lab-lightness:lab(60 10 20);lab-axis:lab(50 15 20);lch-chroma:lch(50 25 30);lch-hue:lch(50 20 180);oklab-axis:oklab(.5 .11 .2);oklch-scale:oklch(.5 .25 30);lab-negative-scale:lab(50 -57.5 20);lab-percent-adjust:lab(50 22.5 20);oklab-light-scale:oklab(.25 .1 .2);lch-hue-wrap:lch(50 20 10);lch-negative-change:lch(50 10 210);lab-outward-scale:lab(50 200 20);lab-out-of-range:color-mix(in lab,color(xyz 1.5892547003 1.6026853084 1.3409230175)100%,red);p3-red:color(display-p3 .3 .3 .4);linear-green:color(srgb-linear .2 .5 .4);a98-blue:color(a98-rgb .2 .3 .7);prophoto-green:color(prophoto-rgb .2 .4 .4);rec-blue:color(rec2020 .2 .3 .7);xyz-x:color(xyz .3 .3 .4);xyz50-y:color(xyz-d50 .2 .5 .4);xyz65-z:color(xyz .2 .3 .6);p3-negative-scale:color(display-p3 .1 .3 .4);legacy-through-lab:hsl(7.3040012065,135.5651909831%,62.7601597049%);p3-through-lab:color(display-p3 1.1297177442 .2553231029 .0951073704);lab-through-p3:lab(53.1692982441 23.3919676168 25.5088400346);modern-through-rgb:color(display-p3 .227974604 .3007646632 .400278314);modern-through-hsl:lab(58.0168993346 -5.5681261381 30.2024872988);modern-through-hwb:oklab(.5191187943 .1155788696 .1325347996);modern-alpha:oklab(.5 .1 .2/.7)}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\.a
        \\  lab-axis: adjust-color(lab(50% 10 20), $a: 5, $space: lab)
        \\  p3-through-lab: adjust-color(color(display-p3 1 0 0), $lightness: 10%, $space: lab)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "modern-transform.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".a{lab-axis:lab(50 15 20);p3-through-lab:color(display-p3 1.1297177442 .2553231029 .0951073704)}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass modern color transforms reject ambiguous or unsafe calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "modern-mismatched-inferred.scss", .input = ".a { color: adjust-color(lab(50% 10 20), $red: .1); }" },
        .{ .name = "modern-needs-space.scss", .input = ".a { color: adjust-color(red, $a: 1); }" },
        .{ .name = "modern-wrong-space.scss", .input = ".a { color: adjust-color(lab(50% 10 20), $x: .1, $space: lab); }" },
        .{ .name = "modern-mixed-space.scss", .input = ".a { color: adjust-color(lab(50% 10 20), $a: 1, $chroma: 1, $space: lab); }" },
        .{ .name = "modern-channel-unit.scss", .input = ".a { color: adjust-color(lab(50% 10 20), $a: 1px, $space: lab); }" },
        .{ .name = "modern-scale-hue.scss", .input = ".a { color: scale-color(lch(50% 20 30deg), $hue: 10%, $space: lch); }" },
        .{ .name = "modern-missing-source.scss", .input = ".a { color: adjust-color(lab(none 10 20), $a: 1, $space: lab); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "modern-missing-transform.scss",
            ".a { color: adjust-color(lab(50% 10 20), $a: none, $space: lab); }",
            .scss,
            .{},
        ),
    );
}

test "native Sass evaluates HWB keyword color transforms without a provider" {
    const input =
        \\.a {
        \\  adjust-white: adjust-color(#123456, $whiteness: 10%);
        \\  adjust-black: adjust-color(#123456, $blackness: 10%, $space: hwb);
        \\  adjust-hue: adjust-color(hwb(210 10% 20%), $hue: 30deg);
        \\  adjust-white-input: adjust-color(hwb(210 10% 20%), $whiteness: 20%);
        \\  change-white: change-color(#123456, $whiteness: 10%, $space: hwb);
        \\  change-black: change-color(#123456, $blackness: 20%, $space: hwb);
        \\  change-hue: change-color(#123456, $hue: .5turn, $space: hwb);
        \\  scale-white: scale-color(#123456, $whiteness: 50%, $space: hwb);
        \\  scale-black: scale-color(#123456, $blackness: -50%, $space: hwb);
        \\  normalized-scale: scale-color(hwb(210 10% 20%), $whiteness: 100%);
        \\  reordered: change-color($blackness: 20%, $color: #123456, $space: hwb);
        \\}
    ;
    var result = try compile(std.testing.allocator, "hwb-keyword-colors.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{adjust-white:rgb(43.5,64.75,86);adjust-black:rgb(18,39.25,60.5);adjust-hue:rgb(25.5,25.5,204);adjust-white-input:rgb(76.5,140.25,204);change-white:rgb(25.5,55.75,86);change-black:#126fcc;change-hue:#125656;scale-white:hsl(0,0%,44.6808510638%);scale-black:rgb(18,94.25,170.5);normalized-scale:rgb(212.5,212.5,212.5);reordered:#126fcc}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass HWB keyword color transforms reject unsafe calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "hwb-hsl-mix.scss", .input = ".a { color: adjust-color(#123456, $whiteness: 1%, $lightness: 1%); }" },
        .{ .name = "hwb-rgb-mix.scss", .input = ".a { color: adjust-color(#123456, $whiteness: 1%, $red: 1); }" },
        .{ .name = "hwb-wrong-space.scss", .input = ".a { color: adjust-color(#123456, $whiteness: 1%, $space: hsl); }" },
        .{ .name = "hwb-unitless-scale.scss", .input = ".a { color: scale-color(#123456, $whiteness: 50); }" },
        .{ .name = "hwb-unit.scss", .input = ".a { color: change-color(#123456, $blackness: 1px); }" },
        .{ .name = "hwb-scale-range.scss", .input = ".a { color: scale-color(#123456, $blackness: -101%); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass fixed built-ins accept bounded keyword arguments" {
    const input =
        \\.a {
        \\  nth: nth($n: 2, $list: (a, b, c));
        \\  length: length($list: (a, b, c));
        \\  red: red($color: #123456);
        \\  green: green($color: #123456);
        \\  blue: blue($color: #123456);
        \\  alpha: alpha($color: rgba(1, 2, 3, .4));
        \\  opacity: opacity($color: rgba(1, 2, 3, .4));
        \\  hue: hue($color: #123456);
        \\  saturation: saturation($color: #123456);
        \\  lightness: lightness($color: #123456);
        \\  mix: mix($color2: blue, $color1: red);
        \\  mix-weighted: mix($weight: 25%, $color2: blue, $color1: red);
        \\  lighten: lighten($amount: 10%, $color: #123456);
        \\  darken: darken($color: #123456, $amount: 10%);
        \\  saturate: saturate($amount: 20%, $color: #669966);
        \\  desaturate: desaturate($color: #669966, $amount: 20%);
        \\  adjust-hue: adjust-hue($degrees: 30deg, $color: #123456);
        \\  complement: complement($color: #123456);
        \\  grayscale: grayscale($color: #123456);
        \\  invert: invert($weight: 25%, $color: #123456);
        \\  opacify: opacify($amount: .2, $color: rgba(1, 2, 3, .4));
        \\  fade-in: fade-in($color: rgba(1, 2, 3, .4), $amount: .2);
        \\  transparentize: transparentize($amount: .2, $color: rgba(1, 2, 3, .4));
        \\  fade-out: fade-out($color: rgba(1, 2, 3, .4), $amount: .2);
        \\  ie-hex: ie-hex-str($color: rgba(1, 2, 3, .4));
        \\}
    ;
    var result = try compile(std.testing.allocator, "fixed-keywords.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{nth:b;length:3;red:18;green:52;blue:86;alpha:.4;opacity:.4;hue:210deg;saturation:65.3846153846%;lightness:20.3921568627%;mix:hsl(300,100%,25%);mix-weighted:rgb(63.75,0,191.25);lighten:rgb(26.8269230769,77.5,128.1730769231);darken:rgb(9.1730769231,26.5,43.8269230769);saturate:hsl(120,40%,50%);desaturate:hsl(0,0%,50%);adjust-hue:#121256;complement:#563412;grayscale:#343434;invert:rgb(72.75,89.75,106.75);opacify:rgba(1,2,3,.6);fade-in:rgba(1,2,3,.6);transparentize:rgba(1,2,3,.2);fade-out:rgba(1,2,3,.2);ie-hex:#66010203}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass fixed built-in keyword arguments reject ambiguous calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "fixed-duplicate.scss", .input = ".a { value: length($list: a, $list: b); }" },
        .{ .name = "fixed-unknown.scss", .input = ".a { color: complement($unknown: red); }" },
        .{ .name = "fixed-missing.scss", .input = ".a { color: mix($color1: red); }" },
        .{ .name = "fixed-order.scss", .input = ".a { color: mix($color1: red, blue); }" },
        .{ .name = "fixed-positional.scss", .input = ".a { value: length(a, b); }" },
        .{ .name = "fixed-method.scss", .input = ".a { color: mix(red, blue, $method: rgb); }" },
        .{ .name = "fixed-filter-keyword.scss", .input = ".a { filter: opacity($amount: 20%); }" },
        .{ .name = "fixed-named-saturate.scss", .input = ".a { filter: saturate($color: 20%); }" },
        .{ .name = "fixed-named-grayscale.scss", .input = ".a { filter: grayscale($color: 20%); }" },
        .{ .name = "fixed-named-invert.scss", .input = ".a { filter: invert($color: 20%); }" },
        .{ .name = "fixed-named-opacity.scss", .input = ".a { filter: opacity($color: 20%); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "fixed-splat.scss",
            ".a { color: complement($args...); }",
            .scss,
            .{},
        ),
    );
}

test "native Sass color constructors accept bounded keyword overloads" {
    const input =
        \\.a {
        \\  rgb-legacy: rgb($green: 0, $red: 255, $blue: 0);
        \\  rgb-alpha: rgb($alpha: .5, $blue: 0, $red: 255, $green: 0);
        \\  rgba-legacy: rgba($blue: 0, $alpha: .5, $red: 255, $green: 0);
        \\  rgb-color: rgb($alpha: .5, $color: red);
        \\  rgba-color: rgba($alpha: .5, $color: red);
        \\  hsl-legacy: hsl($lightness: 50%, $hue: 120, $saturation: 40%);
        \\  hsl-alpha: hsl($alpha: .5, $lightness: 50%, $hue: 120, $saturation: 40%);
        \\  hsla-legacy: hsla($alpha: .5, $lightness: 50%, $hue: 120, $saturation: 40%);
        \\  rgb-channels: rgb($channels: 255 0 0 / .5);
        \\  rgba-channels: rgba($channels: 255 0 0 / .5);
        \\  hsl-channels: hsl($channels: 120 40% 50% / .5);
        \\  hsla-channels: hsla($channels: 120 40% 50% / .5);
        \\  hwb-channels: hwb($channels: 120 10% 20% / .5);
        \\  mixed-positional: rgb(255, $green: 0, $blue: 0);
        \\}
    ;
    var result = try compile(std.testing.allocator, "constructor-keywords.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{rgb-legacy:red;rgb-alpha:rgba(255,0,0,.5);rgba-legacy:rgba(255,0,0,.5);rgb-color:rgba(255,0,0,.5);rgba-color:rgba(255,0,0,.5);hsl-legacy:hsl(120,40%,50%);hsl-alpha:hsla(120,40%,50%,.5);hsla-legacy:hsla(120,40%,50%,.5);rgb-channels:rgba(255,0,0,.5);rgba-channels:rgba(255,0,0,.5);hsl-channels:hsla(120,40%,50%,.5);hsla-channels:hsla(120,40%,50%,.5);hwb-channels:rgba(25.5,204,25.5,.5);mixed-positional:red}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass color constructor keyword overloads reject ambiguous calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "constructor-missing.scss", .input = ".a { color: rgb($red: 255, $green: 0); }" },
        .{ .name = "constructor-mixed-overload.scss", .input = ".a { color: rgb($channels: 255 0 0, $red: 255); }" },
        .{ .name = "constructor-unknown.scss", .input = ".a { color: hsl($unknown: 1); }" },
        .{ .name = "constructor-duplicate.scss", .input = ".a { color: rgb($red: 1, $red: 2, $green: 3, $blue: 4); }" },
        .{ .name = "constructor-order.scss", .input = ".a { color: rgb($red: 255, 0, 0); }" },
        .{ .name = "constructor-hwb-legacy.scss", .input = ".a { color: hwb($hue: 120, $whiteness: 10%, $blackness: 20%); }" },
        .{ .name = "constructor-bad-channels.scss", .input = ".a { color: rgb($channels: 255 0); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "constructor-splat.scss",
            ".a { color: rgb($channels...); }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "constructor-deferred.scss",
            ".a { color: rgb($channels: var(--channels)); }",
            .scss,
            .{},
        ),
    );
}

test "native Sass evaluates modern Lab color constructors without a provider" {
    const input =
        \\$lightness: 50%;
        \\$axis: 10;
        \\.a {
        \\  lab-basic: lab($lightness $axis 20);
        \\  lab-scaled: lab(120% 10% -10% / 2);
        \\  lab-keyword: lab($channels: 50% 10 20 / .5);
        \\  lch-value: lch(50% 20% .5turn);
        \\  oklab-value: oklab(50% 10% -10% / 50%);
        \\  oklch-value: oklch(120% -10% 480deg / -1);
        \\  missing: lab(none none none / none);
        \\  equal-lab: lab(50% 10 20) == lab(50 10 20);
        \\  equal-ok: oklab(50% .1 .2) == oklab(.5 .1 .2);
        \\  different: lab(50 10 20) == oklab(.5 .1 .2);
        \\}
    ;
    var result = try compile(std.testing.allocator, "modern-colors.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{lab-basic:lab(50 10 20);lab-scaled:lab(100 12.5 -12.5);lab-keyword:lab(50 10 20/.5);lch-value:lch(50 30 180);oklab-value:oklab(.5 .04 -0.04/.5);oklch-value:oklch(1 0 120/0);missing:lab(none none none/none);equal-lab:true;equal-ok:true;different:false}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    var deferred = try compile(
        std.testing.allocator,
        "deferred-modern-colors.scss",
        ".a { first: lab(var(--channels)); second: lch(calc(var(--l) + 1) 20 30deg); }",
        .scss,
        .{},
    );
    defer deferred.deinit();
    try std.testing.expectEqualStrings(
        ".a{first:lab(var(--channels));second:lch(calc(var(--l) + 1) 20 30deg)}",
        deferred.css(),
    );
}

test "native Sass modern Lab constructors reject ambiguous and invalid calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "modern-comma.scss", .input = ".a { color: lab(50%, 10, 20); }" },
        .{ .name = "modern-short.scss", .input = ".a { color: lab(50% 10); }" },
        .{ .name = "modern-long.scss", .input = ".a { color: lab(50% 10 20 30); }" },
        .{ .name = "modern-unit.scss", .input = ".a { color: lab(50px 10 20); }" },
        .{ .name = "modern-hue-unit.scss", .input = ".a { color: lch(50% 20 1px); }" },
        .{ .name = "modern-none-case.scss", .input = ".a { color: lab(None none none); }" },
        .{ .name = "modern-missing.scss", .input = ".a { color: lab(); }" },
        .{ .name = "modern-unknown.scss", .input = ".a { color: lab($unknown: $undefined); }" },
        .{ .name = "modern-duplicate.scss", .input = ".a { color: lab(50% 10 20, $channels: $undefined); }" },
        .{ .name = "modern-order.scss", .input = ".a { color: lab($channels: 50% 10 20, $undefined); }" },
        .{ .name = "modern-double-alpha.scss", .input = ".a { color: oklch(.5 .2 120deg / .5 / .4); }" },
        .{ .name = "modern-deferred-double-alpha.scss", .input = ".a { color: lab(var(--channels) / .5 / .4); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "modern-splat.scss",
            ".a { color: lab($channels...); }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "modern-keyword-deferred.scss",
            ".a { color: lab($channels: var(--channels)); }",
            .scss,
            .{},
        ),
    );

    var limits = sass_evaluator.Limits{};
    limits.max_function_arguments = 2;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "modern-channel-limit.scss",
            ".a { color: lab(50% 10 20); }",
            .scss,
            limits,
        ),
    );
}

test "native Sass evaluates predefined wide-gamut colors without a provider" {
    const input =
        \\$space: display-p3;
        \\$red: 100%;
        \\.a {
        \\  srgb: color(srgb 1 0 0);
        \\  linear: color(srgb-linear 1 0 0 / .5);
        \\  p3: color(display-p3 1 0 0 / .5);
        \\  a98: color(a98-rgb 1 0 0 / .5);
        \\  prophoto: color(prophoto-rgb 1 0 0 / .5);
        \\  rec2020: color(rec2020 1 0 0 / .5);
        \\  xyz: color(xyz .4 .3 .2 / .5);
        \\  xyz50: color(xyz-d50 .4 .3 .2 / .5);
        \\  xyz65: color(xyz-d65 .4 .3 .2 / .5);
        \\  variable: color($space $red 0% -10% / 50%);
        \\  keyword: color($description: display-p3 1 0 0 / .5);
        \\  uppercase: color(DISPLAY-P3 1 0 0);
        \\  missing: color(display-p3 none none none / none);
        \\  alias-equal: color(xyz .4 .3 .2) == color(xyz-d65 .4 .3 .2);
        \\  same: color(display-p3 1 0 0) == color(display-p3 1 0 0);
        \\  legacy-distinct: color(srgb 1 0 0) == red;
        \\}
    ;
    var result = try compile(std.testing.allocator, "wide-colors.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{srgb:color(srgb 1 0 0);linear:color(srgb-linear 1 0 0/.5);p3:color(display-p3 1 0 0/.5);a98:color(a98-rgb 1 0 0/.5);prophoto:color(prophoto-rgb 1 0 0/.5);rec2020:color(rec2020 1 0 0/.5);xyz:color(xyz .4 .3 .2/.5);xyz50:color(xyz-d50 .4 .3 .2/.5);xyz65:color(xyz .4 .3 .2/.5);variable:color(display-p3 1 0 -0.1/.5);keyword:color(display-p3 1 0 0/.5);uppercase:color(display-p3 1 0 0);missing:color(display-p3 none none none/none);alias-equal:true;same:true;legacy-distinct:false}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    var deferred = try compile(
        std.testing.allocator,
        "deferred-wide-colors.scss",
        ".a { description: color(var(--description)); channel: color(display-p3 var(--r) 0 0); }",
        .scss,
        .{},
    );
    defer deferred.deinit();
    try std.testing.expectEqualStrings(
        ".a{description:color(var(--description));channel:color(display-p3 var(--r) 0 0)}",
        deferred.css(),
    );
}

test "native Sass predefined colors reject unknown and ambiguous descriptions" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "wide-comma.scss", .input = ".a { color: color(display-p3, 1, 0, 0); }" },
        .{ .name = "wide-short.scss", .input = ".a { color: color(display-p3 1 0); }" },
        .{ .name = "wide-long.scss", .input = ".a { color: color(display-p3 1 0 0 1); }" },
        .{ .name = "wide-alpha-without-slash.scss", .input = ".a { color: color(display-p3 1 0 0 .5); }" },
        .{ .name = "wide-unit.scss", .input = ".a { color: color(display-p3 1px 0 0); }" },
        .{ .name = "wide-quoted-space.scss", .input = ".a { color: color(\"display-p3\" 1 0 0); }" },
        .{ .name = "wide-underscore-space.scss", .input = ".a { color: color(display_p3 1 0 0); }" },
        .{ .name = "wide-custom-space.scss", .input = ".a { color: color(--profile 1 0 0); }" },
        .{ .name = "wide-unknown-space.scss", .input = ".a { color: color(unknown $undefined $also-undefined $still-undefined); }" },
        .{ .name = "wide-missing.scss", .input = ".a { color: color(); }" },
        .{ .name = "wide-unknown-keyword.scss", .input = ".a { color: color($unknown: $undefined); }" },
        .{ .name = "wide-duplicate.scss", .input = ".a { color: color(display-p3 1 0 0, $description: $undefined); }" },
        .{ .name = "wide-order.scss", .input = ".a { color: color($description: display-p3 1 0 0, $undefined); }" },
        .{ .name = "wide-double-alpha.scss", .input = ".a { color: color(display-p3 1 0 0 / .5 / .4); }" },
        .{ .name = "wide-deferred-double-alpha.scss", .input = ".a { color: color(var(--description) / .5 / .4); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "wide-splat.scss",
            ".a { color: color($description...); }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "wide-keyword-deferred.scss",
            ".a { color: color($description: var(--description)); }",
            .scss,
            .{},
        ),
    );

    var limits = sass_evaluator.Limits{};
    limits.max_function_arguments = 3;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "wide-channel-limit.scss",
            ".a { color: color(display-p3 1 0 0); }",
            .scss,
            limits,
        ),
    );
}

test "native Sass legacy if function binds and evaluates only the selected branch" {
    const input =
        \\@use "sass:meta";
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\@function if($condition, $if-true, $if-false) {
        \\  @return overridden;
        \\}
        \\.values {
        \\  truthy: if(true, 1, $missing);
        \\  falsey: if(false, $missing, 2);
        \\  nullish: if(null, $missing, 3);
        \\  zero: if(0, 4, $missing);
        \\  keyword-order: if($if-false: $missing, $condition: mark(true), $if-true: mark($evaluations));
        \\  escaped: \69 f(true, 6, $missing);
        \\  commented-false: if(false /* condition */, $missing, 7 /* selected */);
        \\  trailing: if(true, 8, $missing,);
        \\  selected-map: meta.type-of(if(true, (a: b), $missing));
        \\  selected-null: if(true, null, $missing);
        \\  nested: if(true, if(false, $missing, 5), $missing);
        \\  arithmetic: if(true, 1, $missing) + 2;
        \\  calculation: calc(if(true, 1px, $missing) + 1px);
        \\  minimum: min(if(false, $missing, 2px), 3px);
        \\  plain-nested: outer(if(true, 9, $missing));
        \\  modern-css: if(style(--scheme: dark): white; else: black);
        \\  evaluations: $evaluations;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "legacy-if-function.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{truthy:1;falsey:2;nullish:3;zero:4;keyword-order:1;escaped:6;commented-false:7;trailing:8;selected-map:map;nested:5;arithmetic:3;calculation:2px;minimum:2px;plain-nested:outer(9);modern-css:if(style(--scheme: dark): white; else: #000);evaluations:2}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 6), diagnostics.len);
    for (diagnostics[0..5]) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "The Sass if() syntax is deprecated in favor of the modern CSS syntax.",
            diagnostic.message,
        );
    }
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[5].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[5].code,
    );
    try std.testing.expectEqualStrings(
        "11 repetitive deprecation warnings omitted.",
        diagnostics[5].message,
    );

    const indented =
        \\@use "sass:meta" as m
        \\.sass
        \\  truthy: if(true, yes, $missing)
        \\  falsey: if(false, $missing, no)
        \\  reflected: m.function-exists("if")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "legacy-if-function.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{truthy:yes;falsey:no;reflected:true}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 2), sass_result.nativeDiagnostics().len);
}

test "native Sass legacy if function expands one final splat eagerly" {
    const input =
        \\$evaluations: 0;
        \\$trace: "";
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  $trace: "#{$trace}#{$value}," !global;
        \\  @return $value;
        \\}
        \\@function relay($args...) { @return if($args...); }
        \\$list: true, 1, 2;
        \\$map: ("condition": false, "if-true": 3, "if-false": 4);
        \\.values {
        \\  inline: if((true, 5, 6)...);
        \\  variable: if($list...);
        \\  prefixed: if(false, (7, 8)...);
        \\  map: if($map...);
        \\  map-override: if($condition: true, $map...);
        \\  rest: relay(false, $if-true: 11, $if-false: 12);
        \\  before-eager: $evaluations;
        \\  eager: if(mark(true), (mark(13), mark(14))...);
        \\  after-eager: $evaluations;
        \\  scalar: if(false, 15, 16...);
        \\  space: if((mark(true) mark(17) mark(18))...);
        \\  evaluations: $evaluations;
        \\  trace: $trace;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "legacy-if-splat.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{inline:5;variable:1;prefixed:8;map:4;map-override:4;rest:12;before-eager:0;eager:13;after-eager:3;scalar:16;space:17;evaluations:6;trace:\"13,14,true,true,17,18,\"}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 6), diagnostics.len);
    for (diagnostics[0..5]) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "The Sass if() syntax is deprecated in favor of the modern CSS syntax.",
            diagnostic.message,
        );
    }
    try std.testing.expectEqualStrings(
        "4 repetitive deprecation warnings omitted.",
        diagnostics[5].message,
    );

    const indented =
        \\@function relay($args...)
        \\  @return if($args...)
        \\$list: false, yes, no
        \\.sass
        \\  list: if($list...)
        \\  rest: relay(true, chosen, skipped)
        \\  scalar: if(false, wrong, right...)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "legacy-if-splat.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{list:no;rest:chosen;scalar:right}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 3), sass_result.nativeDiagnostics().len);
}

test "native Sass legacy if function preserves one misplaced rest argument" {
    const input =
        \\$trace: "";
        \\@function mark($tag, $value) {
        \\  $trace: "#{$trace}#{$tag}," !global;
        \\  @return $value;
        \\}
        \\$map: ("condition": false);
        \\.values {
        \\  scalar: if(true..., 1, 2);
        \\  list: if((true, 3)..., 4);
        \\  middle: if(mark(condition, true), mark(rest, 5)..., mark(false-branch, 6));
        \\  map: if($map..., $if-true: 7, $if-false: 8);
        \\  mixed: if(true..., 9, $if-false: 10);
        \\  named: if(false..., $if-true: yes, $if-false: no);
        \\  trace: $trace;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "legacy-if-misplaced-rest.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{scalar:2;list:true;middle:6;map:8;mixed:true;named:no;trace:\"rest,condition,false-branch,\"}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 11), diagnostics.len);
    for (0..5) |index| {
        const misplaced = diagnostics[index * 2];
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            misplaced.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            misplaced.code,
        );
        try std.testing.expectEqualStrings(
            if (index == 3)
                "Named arguments must come before rest arguments. This will be an error in Dart Sass 2.0.0."
            else
                "Positional arguments must come before rest arguments. This will be an error in Dart Sass 2.0.0.",
            misplaced.message,
        );

        const legacy_if = diagnostics[index * 2 + 1];
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            legacy_if.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            legacy_if.code,
        );
        try std.testing.expectEqualStrings(
            "The Sass if() syntax is deprecated in favor of the modern CSS syntax.",
            legacy_if.message,
        );
    }
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[10].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[10].code,
    );
    try std.testing.expectEqualStrings(
        "2 repetitive deprecation warnings omitted.",
        diagnostics[10].message,
    );

    const indented =
        \\$arg: false
        \\.sass
        \\  positional: if($arg..., yes, no)
        \\  named: if($arg..., $if-true: yes, $if-false: no)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "legacy-if-misplaced-rest.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{positional:no;named:no}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 4), sass_result.nativeDiagnostics().len);
}

test "native Sass legacy if function expands terminal positional and keyword splats eagerly" {
    const input =
        \\$trace: "";
        \\@function mark($tag, $value) {
        \\  $trace: "#{$trace}#{$tag}," !global;
        \\  @return $value;
        \\}
        \\@function relay($args...) { @return if($args..., ("if-false": 13)...); }
        \\$positional: false, 1;
        \\$keywords: ("if-false": 2);
        \\$first-map: ("condition": false, "if-true": 3);
        \\$last-map: ("condition": true, "if-true": 4, "if-false": 5);
        \\.values {
        \\  list-map: if($positional..., $keywords...);
        \\  scalar-map: if(true..., ("if-true": 6, "if-false": 7)...);
        \\  two-maps: if($first-map..., ("if-false": 8)...);
        \\  overrides: if($condition: false, $if-true: 9, $if-false: 10, $first-map..., $last-map...);
        \\  first-arglist: relay(false, $if-true: 12);
        \\  before-eager: $trace;
        \\  eager: if(mark(direct, false), mark(positional, (mark(if-true, 14),))..., mark(keywords, ("if-false": mark(if-false, 15)))...);
        \\  trace: $trace;
        \\}
    ;
    var result = try compile(
        std.testing.allocator,
        "legacy-if-dual-splat.scss",
        input,
        .scss,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".values{list-map:2;scalar-map:6;two-maps:8;overrides:4;first-arglist:13;before-eager:\"\";eager:15;trace:\"if-true,positional,if-false,keywords,direct,\"}",
        result.css(),
    );
    const diagnostics = result.nativeDiagnostics();
    try std.testing.expectEqual(@as(usize, 6), diagnostics.len);
    for (diagnostics[0..5]) |diagnostic| {
        try std.testing.expectEqual(
            preprocessor.diagnostics.Severity.warning,
            diagnostic.severity,
        );
        try std.testing.expectEqual(
            preprocessor.diagnostics.Code.invalid_operation,
            diagnostic.code,
        );
        try std.testing.expectEqualStrings(
            "The Sass if() syntax is deprecated in favor of the modern CSS syntax.",
            diagnostic.message,
        );
    }
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        diagnostics[5].severity,
    );
    try std.testing.expectEqual(
        preprocessor.diagnostics.Code.invalid_operation,
        diagnostics[5].code,
    );
    try std.testing.expectEqualStrings(
        "1 repetitive deprecation warnings omitted.",
        diagnostics[5].message,
    );

    const indented =
        \\$positional: false, yes
        \\$keywords: ("if-false": no)
        \\.sass
        \\  list-map: if($positional..., $keywords...)
        \\  scalar-map: if(true..., ("if-true": chosen, "if-false": skipped)...)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "legacy-if-dual-splat.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{list-map:no;scalar-map:chosen}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 2), sass_result.nativeDiagnostics().len);
}

test "native Sass legacy if function rejects malformed and unsupported calls within limits" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "legacy-if-missing.scss", .input = ".a { value: if(true, 1); }" },
        .{ .name = "legacy-if-extra.scss", .input = ".a { value: if(true, 1, 2, 3); }" },
        .{ .name = "legacy-if-unknown.scss", .input = ".a { value: if($condition: true, $if-true: 1, $if-false: 2, $unknown: 3); }" },
        .{ .name = "legacy-if-duplicate.scss", .input = ".a { value: if($condition: true, $if_true: 1, $if-true: 2, $if-false: 3); }" },
        .{ .name = "legacy-if-order.scss", .input = ".a { value: if($condition: true, 1, 2); }" },
        .{ .name = "legacy-if-invalid-clause.scss", .input = ".a { value: if(foo: red; else: blue); }" },
        .{ .name = "legacy-if-splat-missing.scss", .input = ".a { value: if((true, 1)...); }" },
        .{ .name = "legacy-if-splat-extra.scss", .input = ".a { value: if((true, 1, 2, 3)...); }" },
        .{ .name = "legacy-if-splat-map-name.scss", .input = ".a { value: if((condition: true, if_true: 1, if_false: 2)...); }" },
        .{ .name = "legacy-if-splat-map-key.scss", .input = ".a { value: if((1: true, if-true: 1, if-false: 2)...); }" },
        .{ .name = "legacy-if-dual-keyword-list.scss", .input = ".safe { value: 1; } .a { value: if((true, 1)..., (2, 3)...); }" },
        .{ .name = "legacy-if-dual-keyword-scalar.scss", .input = ".a { value: if((true, 1)..., 2...); }" },
        .{ .name = "legacy-if-dual-keyword-empty.scss", .input = ".a { value: if((true, 1, 2)..., ()...); }" },
        .{ .name = "legacy-if-dual-keyword-arglist.scss", .input = "@function relay($positional, $keywords...) { @return if($positional..., $keywords...); } .a { value: relay((false, 1), $if-false: 2); }" },
        .{ .name = "legacy-if-dual-keyword-map-key.scss", .input = ".a { value: if((true, 1)..., (1: 2)...); }" },
        .{ .name = "legacy-if-dual-keyword-map-name.scss", .input = ".a { value: if((true, 1)..., (\"if_false\": 2)...); }" },
        .{ .name = "legacy-if-dual-duplicate.scss", .input = ".a { value: if(true, (\"if-true\": 1)..., (\"condition\": false, \"if-false\": 2)...); }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.UndefinedVariable,
        compile(
            std.testing.allocator,
            "legacy-if-separated-name.scss",
            ".a { value: if (true, 1, $missing); }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "legacy-if-nonterminal-dual-splat.scss",
            ".a { value: if(true..., (\"if-true\": 1)..., 2); }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "legacy-if-three-splats.scss",
            ".a { value: if(true..., 1..., (\"if-false\": 2)...); }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.UndefinedVariable,
        compile(
            std.testing.allocator,
            "legacy-if-splat-eager.scss",
            ".a { value: if(true, (1, $missing)...); }",
            .scss,
            .{},
        ),
    );

    var limits = sass_evaluator.Limits{};
    limits.max_function_arguments = 2;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "legacy-if-argument-limit.scss",
            ".a { value: if(true, 1, 2); }",
            .scss,
            limits,
        ),
    );
    limits.max_function_arguments = 3;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "legacy-if-expanded-argument-limit.scss",
            ".a { value: if((true, 1, 2, 3)...); }",
            .scss,
            limits,
        ),
    );
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "legacy-if-dual-expanded-argument-limit.scss",
            ".a { value: if((true, 1)..., (\"if-false\": 2, \"extra\": 3)...); }",
            .scss,
            limits,
        ),
    );
}

test "native Sass lazily evaluates bounded conditional chains" {
    const input =
        \\$enabled: true;
        \\$disabled: false;
        \\$zero: 0;
        \\@if $enabled { .root { value: yes; } }
        \\@else if $undefined { .wrong-condition { value: no; } }
        \\@else { .wrong { value: $undefined; } }
        \\@if $disabled { .skip { value: no; } }
        \\@else if 1 < 2 { .fallback { value: yes; } }
        \\@else { .wrong-two { value: no; } }
        \\@if $zero { .truthy { value: zero; } }
        \\@if false { @for $i from 1 through 2 { .unselected-#{$i} { value: no; } } }
        \\.card {
        \\  before: 1;
        \\  @if $disabled { branch: no; }
        \\  @else if $enabled {
        \\    branch: yes;
        \\    .child {
        \\      nested: true;
        \\      @if false { deep: no; }
        \\      @else { deep: yes; }
        \\    }
        \\  }
        \\  @else { branch: never; }
        \\  after: 2;
        \\}
    ;
    var result = try compile(std.testing.allocator, "conditionals.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".root{value:yes}.fallback{value:yes}.truthy{value:zero}.card{before:1;branch:yes}.card .child{nested:true;deep:yes}.card{after:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\$enabled: true
        \\@if $enabled
        \\  .sass-branch
        \\    value: yes
        \\@else
        \\  .wrong
        \\    value: no
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "conditionals.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(".sass-branch{value:yes}", sass_result.css());
}

test "native Sass flow scopes update existing variables and confine fresh bindings" {
    const input =
        \\$root: 1;
        \\$nullable: null;
        \\$global-only: global;
        \\@if true {
        \\  $root: 2;
        \\  $nullable: 3 !default;
        \\  $fresh: branch;
        \\  @if true {
        \\    $root: 4;
        \\    $fresh: nested;
        \\    .inside { root: $root; fresh: $fresh; }
        \\  }
        \\  .outer { root: $root; fresh: $fresh; nullable: $nullable; }
        \\}
        \\.after { root: $root; nullable: $nullable; global-only: $global-only; }
        \\.card {
        \\  $local: 1;
        \\  before: $local;
        \\  @if true {
        \\    $local: 2;
        \\    $global-only: local;
        \\    $new: branch;
        \\    inside-local: $local;
        \\    inside-global: $global-only;
        \\    inside-new: $new;
        \\    @if true {
        \\      $local: 3;
        \\      $new: nested;
        \\      nested-local: $local;
        \\      nested-new: $new;
        \\    }
        \\    after-nested-local: $local;
        \\    after-nested-new: $new;
        \\  }
        \\  after: $local;
        \\  inherited: $global-only;
        \\}
        \\.final { global-only: $global-only; }
    ;
    var result = try compile(std.testing.allocator, "flow-scope.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".inside{root:4;fresh:nested}.outer{root:4;fresh:nested;nullable:3}.after{root:4;nullable:3;global-only:global}.card{before:1;inside-local:2;inside-global:local;inside-new:branch;nested-local:3;nested-new:nested;after-nested-local:3;after-nested-new:nested;after:3;inherited:global}.final{global-only:global}",
        result.css(),
    );

    const global_input =
        \\$x: global;
        \\$defaulted: 1;
        \\.shadow {
        \\  $x: local;
        \\  @if true {
        \\    $x: new !global;
        \\    $defaulted: 2 !global !default;
        \\  }
        \\  local: $x;
        \\  global-default: $defaulted;
        \\}
        \\.direct {
        \\  $x: direct-local;
        \\  $x: direct-global !global;
        \\  local: $x;
        \\}
        \\.between { value: $x; }
        \\.unshadowed {
        \\  @if true { $x: final !global; }
        \\  value: $x;
        \\}
        \\.result { x: $x; defaulted: $defaulted; }
    ;
    var global_result = try compile(
        std.testing.allocator,
        "flow-global.scss",
        global_input,
        .scss,
        .{},
    );
    defer global_result.deinit();
    try std.testing.expectEqualStrings(
        ".shadow{local:local;global-default:1}.direct{local:direct-local}.between{value:direct-global}.unshadowed{value:final}.result{x:final;defaulted:1}",
        global_result.css(),
    );

    var ordered_global = try compile(
        std.testing.allocator,
        "flow-ordered-global.scss",
        "$x: old; .a { @if true { $x: new !global; $x: local; inside: $x; } after: $x; } .b { value: $x; }",
        .scss,
        .{},
    );
    defer ordered_global.deinit();
    try std.testing.expectEqualStrings(
        ".a{inside:local;after:new}.b{value:new}",
        ordered_global.css(),
    );

    var nested_lexical = try compile(
        std.testing.allocator,
        "flow-nested-lexical.scss",
        ".parent { $local: parent; .child { @if true { $local: changed; seen: $local; } after: $local; } parent: $local; }",
        .scss,
        .{},
    );
    defer nested_lexical.deinit();
    try std.testing.expectEqualStrings(
        ".parent .child{seen:changed;after:changed}.parent{parent:changed}",
        nested_lexical.css(),
    );

    var nested_direct = try compile(
        std.testing.allocator,
        "flow-nested-direct.scss",
        "@if true { $fresh: outer; .child { $fresh: direct; seen: $fresh; } .outer { value: $fresh; } }",
        .scss,
        .{},
    );
    defer nested_direct.deinit();
    try std.testing.expectEqualStrings(
        ".child{seen:direct}.outer{value:direct}",
        nested_direct.css(),
    );

    var nested_global = try compile(
        std.testing.allocator,
        "flow-nested-global.scss",
        "$x: old; @if true { .child { $x: new !global; local: $x; } .inside { value: $x; } } .after { value: $x; }",
        .scss,
        .{},
    );
    defer nested_global.deinit();
    try std.testing.expectEqualStrings(
        ".child{local:new}.inside{value:new}.after{value:new}",
        nested_global.css(),
    );

    var new_global = try compile(
        std.testing.allocator,
        "flow-new-global.scss",
        ".a { @if true { $created: local; $created: 2 !global; value: $created; } } .b { value: $created; }",
        .scss,
        .{},
    );
    defer new_global.deinit();
    try std.testing.expectEqualStrings(".a{value:local}.b{value:2}", new_global.css());
    try std.testing.expectEqual(@as(usize, 1), new_global.nativeDiagnostics().len);
    try std.testing.expectEqual(
        preprocessor.diagnostics.Severity.warning,
        new_global.nativeDiagnostics()[0].severity,
    );

    const indented =
        \\$inline_size: 1
        \\@if true
        \\  $inline-size: 2
        \\.sass-flow
        \\  value: $inline_size
    ;
    var sass_result = try compile(std.testing.allocator, "flow-scope.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(".sass-flow{value:2}", sass_result.css());

    var upstream_regression = try compile(
        std.testing.allocator,
        "flow-upstream-1250.scss",
        "$a: global; b { @if true { @if true { $a: local; } } } c { d: $a; }",
        .scss,
        .{},
    );
    defer upstream_regression.deinit();
    try std.testing.expectEqualStrings("c{d:global}", upstream_regression.css());
}

test "native Sass fresh flow variables do not escape their declaring branch" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "fresh-root-flow.scss", .input = "@if true { $new: 1; } .a { value: $new; }" },
        .{ .name = "fresh-rule-flow.scss", .input = ".a { @if true { $new: 1; } value: $new; }" },
        .{ .name = "fresh-nested-flow.scss", .input = "@if true { @if true { $new: 1; } .a { value: $new; } }" },
        .{ .name = "fresh-nested-rule.scss", .input = ".parent { .child { $new: 1; } value: $new; }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.UndefinedVariable,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var scope_limits = sass_evaluator.Limits{};
    scope_limits.environment.max_scopes = 2;
    try std.testing.expectError(
        error.ScopeLimitExceeded,
        compile(
            std.testing.allocator,
            "flow-scope-limit.scss",
            "@if true { .a { value: yes; } }",
            .scss,
            scope_limits,
        ),
    );

    var binding_limits = sass_evaluator.Limits{};
    binding_limits.environment.max_bindings = 1;
    try std.testing.expectError(
        error.BindingLimitExceeded,
        compile(
            std.testing.allocator,
            "flow-binding-limit.scss",
            "@if true { $fresh: value; }",
            .scss,
            binding_limits,
        ),
    );
}

test "native Sass executes bounded for each and while loops" {
    const input =
        \\$i: outer;
        \\$sum: 0;
        \\@for $i from 1 through 3 {
        \\  $sum: $sum + $i;
        \\  $first: $i !default;
        \\  .for-#{$i} { sum: $sum; first: $first; }
        \\}
        \\@for $j from 3 to 1 { .down-#{$j} { value: $j; } }
        \\@for $unit from 1px through 2px { .unit { value: $unit; } }
        \\$range-start: 1;
        \\$range-end: 3;
        \\@for $expr from $range-start + 1 through $range-end { .expr-#{$expr} { value: $expr; } }
        \\@each $item in a, b { .each-#{$item} { value: $item; } }
        \\$items: p, q;
        \\@each $item in $items { .variable-each-#{$item} { value: $item; } }
        \\@each $key, $value in (one: 1, two: 2) { .map-#{$key} { value: $value; } }
        \\@each $a, $b, $c in (x y, z) { .tuple-#{$a} { b: $b; c: $c; } }
        \\$while: 0;
        \\@while $while < 2 {
        \\  $while: $while + 1;
        \\  .while-#{$while} { value: $while; }
        \\}
        \\.after { i: $i; sum: $sum; while: $while; }
    ;
    var result = try compile(std.testing.allocator, "loops.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".for-1{sum:1;first:1}.for-2{sum:3;first:1}.for-3{sum:6;first:1}.down-3{value:3}.down-2{value:2}.unit{value:1px}.unit{value:2px}.expr-2{value:2}.expr-3{value:3}.each-a{value:a}.each-b{value:b}.variable-each-p{value:p}.variable-each-q{value:q}.map-one{value:1}.map-two{value:2}.tuple-x{b:y}.while-1{value:1}.while-2{value:2}.after{i:outer;sum:6;while:2}",
        result.css(),
    );

    const indented =
        \\$total: 0
        \\@for $i from 1 through 2
        \\  $total: $total + $i
        \\  .sass-#{$i}
        \\    value: $total
        \\.result
        \\  total: $total
    ;
    var sass_result = try compile(std.testing.allocator, "loops.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass-1{value:1}.sass-2{value:3}.result{total:3}",
        sass_result.css(),
    );

    const nested =
        \\.container {
        \\  $sum: 0;
        \\  @for $i from 1 through 2 {
        \\    $sum: $sum + $i;
        \\    item-#{$i}: $sum;
        \\    .child-#{$i} { value: $sum; }
        \\  }
        \\  after: $sum;
        \\}
        \\@each $single in solo { .scalar { value: $single; } }
        \\@each $pair in (one: 1) { .pair { value: $pair; first: nth($pair, 1); } }
        \\@each $duplicate, $duplicate in (one: 1, two: 2) { .duplicate-#{$duplicate} { value: $duplicate; } }
        \\@if true { @for $nested from 1 through 2 { .selected-#{$nested} { value: $nested; } } }
        \\$counter: 0;
        \\.global-while { @while $counter < 2 { $counter: $counter + 1; inside: $counter; } after: $counter; }
        \\.local-while { $counter: 0; @while $counter < 2 { $counter: $counter + 1; inside: $counter; } after: $counter; }
        \\.counter-final { value: $counter; }
    ;
    var nested_result = try compile(std.testing.allocator, "nested-loops.scss", nested, .scss, .{});
    defer nested_result.deinit();
    try std.testing.expectEqualStrings(
        ".container{item-1:1}.container .child-1{value:1}.container{item-2:3}.container .child-2{value:3}.container{after:3}.scalar{value:solo}.pair{value:one 1;first:one}.duplicate-1{value:1}.duplicate-2{value:2}.selected-1{value:1}.selected-2{value:2}.global-while{inside:1;inside:2;after:0}.local-while{inside:1;inside:2;after:2}.counter-final{value:0}",
        nested_result.css(),
    );
}

test "native Sass zero-iteration loops leave unsupported bodies lazy" {
    const input =
        \\@for $i from 1 to 1 { @include unavailable; }
        \\@each $item in () { @include unavailable; }
        \\@while false { @include unavailable; }
        \\.after { value: yes; }
    ;
    var result = try compile(std.testing.allocator, "lazy-loops.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(".after{value:yes}", result.css());
}

test "native Sass loops reject malformed unbounded and escaping evaluation" {
    const malformed = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "for-missing-from.scss", .input = "@for $i 1 through 2 { .a { value: $i; } }" },
        .{ .name = "for-missing-kind.scss", .input = "@for $i from 1 2 { .a { value: $i; } }" },
        .{ .name = "for-missing-end.scss", .input = "@for $i from 1 through { .a { value: $i; } }" },
        .{ .name = "each-missing-comma.scss", .input = "@each $a $b in (x y) { .a { value: $a; } }" },
        .{ .name = "each-trailing-comma.scss", .input = "@each $a, in (x y) { .a { value: $a; } }" },
        .{ .name = "each-missing-iterable.scss", .input = "@each $a in { .a { value: $a; } }" },
        .{ .name = "while-missing-condition.scss", .input = "@while { .a { value: no; } }" },
        .{ .name = "loop-missing-block.scss", .input = "@for $i from 1 through 2;" },
    };
    for (malformed) |case| {
        try std.testing.expectError(
            error.InvalidSassSyntax,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "for-string.scss", .input = "@for $i from red through blue { .a { value: $i; } }" },
        .{ .name = "for-fraction.scss", .input = "@for $i from 1.5 through 2 { .a { value: $i; } }" },
        .{ .name = "for-no-progress.scss", .input = "@for $i from 9007199254740992 through 9007199254740994 { .a { value: $i; } }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
    try std.testing.expectError(
        error.IncompatibleUnits,
        compile(
            std.testing.allocator,
            "for-incompatible.scss",
            "@for $i from 1px through 2s { .a { value: $i; } }",
            .scss,
            .{},
        ),
    );

    const escaping = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "for-variable-escape.scss", .input = "@for $i from 1 through 1 {} .a { value: $i; }" },
        .{ .name = "each-variable-escape.scss", .input = "@each $item in one {} .a { value: $item; }" },
        .{ .name = "while-variable-escape.scss", .input = "$i: 0; @while $i < 1 { $i: $i + 1; $fresh: yes; } .a { value: $fresh; }" },
    };
    for (escaping) |case| {
        try std.testing.expectError(
            error.UndefinedVariable,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var semantic_limits = sass_evaluator.Limits{};
    semantic_limits.max_loop_variables = 1;
    try std.testing.expectError(
        error.LoopVariableLimitExceeded,
        compile(
            std.testing.allocator,
            "loop-variable-limit.scss",
            "@each $a, $b in (x y) { .a { value: $a; } }",
            .scss,
            semantic_limits,
        ),
    );
    semantic_limits = .{};
    semantic_limits.max_evaluation_depth = 1;
    try std.testing.expectError(
        error.EvaluationDepthExceeded,
        compile(
            std.testing.allocator,
            "loop-depth-limit.scss",
            "@for $i from 1 through 1 { .a { value: $i; } }",
            .scss,
            semantic_limits,
        ),
    );
    semantic_limits = .{};
    semantic_limits.max_loop_variables = 0;
    try std.testing.expectError(
        error.InvalidLimits,
        compile(
            std.testing.allocator,
            "invalid-loop-limits.scss",
            ".a { value: yes; }",
            .scss,
            semantic_limits,
        ),
    );

    var transaction_limits = evaluator.Limits{};
    transaction_limits.budget.max_loop_iterations = 2;
    try std.testing.expectError(
        error.LoopLimitExceeded,
        compileWithTransactionLimits(
            std.testing.allocator,
            "loop-iteration-limit.scss",
            "@while true { .a { value: yes; } }",
            .scss,
            .{},
            transaction_limits,
        ),
    );
}

test "native Sass evaluates bounded source-ordered user functions" {
    const input =
        \\$base: 2;
        \\@function twice($value) { @return $value * 2; }
        \\@function add($a, $b: $a + 1) { @return $a + $b; }
        \\@function count-down($n) {
        \\  @if $n <= 0 { @return 0; }
        \\  @return count_down($n - 1) + 1;
        \\}
        \\@function stop-at-two($limit) {
        \\  @for $i from 1 through $limit { @if $i == 2 { @return $i; } }
        \\  @return 0;
        \\}
        \\@function first-item($items) {
        \\  @each $item in $items { @return $item; }
        \\  @return null;
        \\}
        \\@function while-once() {
        \\  $value: 0;
        \\  @while $value < 1 { $value: $value + 1; @return $value; }
        \\  @return 0;
        \\}
        \\@function global-base() { @return $base; }
        \\@function red($color) { @return 7; }
        \\.before {
        \\  unresolved: later(2);
        \\  direct: twice(3);
        \\  nested: add(twice(2), $b: 3);
        \\  defaulted: add(2);
        \\  recursive: count-down(3);
        \\  loop-return: stop-at-two(3);
        \\  each-return: first-item((a, b));
        \\  while-return: while-once();
        \\}
        \\@function later($value) { @return $value + 1; }
        \\$base: 3;
        \\@function with-base($value) { @return $value + $base; }
        \\.after {
        \\  $base: 10;
        \\  later: later(2);
        \\  base: with-base(1);
        \\  trailing: add(1,);
        \\  captured: global-base();
        \\  override: red(#fff);
        \\}
        \\@function with-base($value) { @return $value + $base + 1; }
        \\.redefined { value: with-base(1); }
    ;
    var result = try compile(std.testing.allocator, "user-functions.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".before{unresolved:later(2);direct:6;nested:7;defaulted:5;recursive:3;loop-return:2;each-return:a;while-return:1}.after{later:3;base:4;trailing:3;captured:3;override:7}.redefined{value:5}",
        result.css(),
    );
}

test "native Sass user functions retain lexical definition scope in both syntaxes" {
    const scss =
        \\$local: 100;
        \\.scope {
        \\  $local: 4;
        \\  @function local-add($value, $amount: $local) { @return $value + $amount; }
        \\  first: local-add(1);
        \\  $local: 5;
        \\  second: local-add(1);
        \\  .child { value: local_add(2); }
        \\}
        \\.outside { value: local-add(1); }
    ;
    var scss_result = try compile(std.testing.allocator, "lexical-functions.scss", scss, .scss, .{});
    defer scss_result.deinit();
    try std.testing.expectEqualStrings(
        ".scope{first:5;second:6}.scope .child{value:7}.outside{value:local-add(1)}",
        scss_result.css(),
    );

    const indented =
        \\@function double($value)
        \\  @return $value * 2
        \\@function choose($value)
        \\  @if $value > 0
        \\    @return double($value)
        \\  @return 0
        \\.sass
        \\  positive: choose(3)
        \\  zero: choose(0)
    ;
    var sass_result = try compile(std.testing.allocator, "user-functions.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(".sass{positive:6;zero:0}", sass_result.css());
}

test "native Sass user functions reject invalid declarations calls and placement" {
    const invalid_syntax = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "function-no-parameters.scss", .input = "@function f { @return 1; }" },
        .{ .name = "function-no-block.scss", .input = "@function f();" },
        .{ .name = "function-reserved-name.scss", .input = "@function --f() { @return 1; }" },
        .{ .name = "function-empty-parameter.scss", .input = "@function f($a,, $b) { @return $a; }" },
        .{ .name = "function-empty-default.scss", .input = "@function f($a:) { @return $a; }" },
        .{ .name = "function-duplicate-parameter.scss", .input = "@function f($a_b, $a-b) { @return $a-b; }" },
        .{ .name = "function-selected-control.scss", .input = "@if true { @function f() { @return 1; } }" },
        .{ .name = "function-unselected-control.scss", .input = "@if false { @function f() { @return 1; } } .a { value: ok; }" },
        .{ .name = "function-property.scss", .input = "@function f() { color: red; } .a { value: ok; }" },
        .{ .name = "function-rule.scss", .input = "@function f() { .x { value: no; } } .a { value: ok; }" },
        .{ .name = "function-include.scss", .input = "@function f() { @include unavailable; @return 1; } .a { value: ok; }" },
        .{ .name = "function-extend.scss", .input = "@function f() { @extend .x; @return 1; } .a { value: ok; }" },
        .{ .name = "return-root.scss", .input = "@return 1;" },
        .{ .name = "return-rule.scss", .input = ".a { @return 1; }" },
        .{ .name = "function-missing-return.scss", .input = "@function f() { $x: 1; } .a { value: f(); }" },
    };
    for (invalid_syntax) |case| {
        try std.testing.expectError(
            error.InvalidSassSyntax,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    const invalid_calls = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "function-missing-argument.scss", .input = "@function f($a) { @return $a; } .a { value: f(); }" },
        .{ .name = "function-unknown-keyword.scss", .input = "@function f($a) { @return $a; } .a { value: f($b: 1); }" },
        .{ .name = "function-duplicate-argument.scss", .input = "@function f($a) { @return $a; } .a { value: f(1, $a: 2); }" },
        .{ .name = "function-positional-after-keyword.scss", .input = "@function f($a, $b) { @return $a; } .a { value: f($a: 1, 2); }" },
        .{ .name = "function-too-many-arguments.scss", .input = "@function f() { @return 1; } .a { value: f(1); }" },
        .{ .name = "function-unused-rest-keyword.scss", .input = "@function f($args...) { @return length($args); } .a { value: f($extra: 1); }" },
        .{ .name = "function-non-string-map-key.scss", .input = "@function f($value: 0) { @return $value; } $args: (1: 2); .a { value: f($args...); }" },
        .{ .name = "function-map-key-is-exact.scss", .input = "@function f($start-at: 0) { @return $start-at; } $args: (start_at: 2); .a { value: f($args...); }" },
        .{ .name = "function-expanded-duplicate.scss", .input = "@function f($value) { @return $value; } $values: 1; $named: (value: 2); .a { value: f($values..., $named...); }" },
    };
    for (invalid_calls) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    const invalid_rest_parameters = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "function-rest-not-final.scss", .input = "@function f($args..., $last) { @return 1; }" },
        .{ .name = "function-rest-default.scss", .input = "@function f($args...: 1) { @return 1; }" },
    };
    for (invalid_rest_parameters) |case| {
        try std.testing.expectError(
            error.InvalidSassSyntax,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass user functions enforce callable parameter and transaction limits" {
    var semantic_limits = sass_evaluator.Limits{};
    semantic_limits.max_callables = 1;
    try std.testing.expectError(
        error.CallableLimitExceeded,
        compile(
            std.testing.allocator,
            "function-count-limit.scss",
            "@function a() { @return 1; } @function b() { @return 2; }",
            .scss,
            semantic_limits,
        ),
    );
    semantic_limits = .{};
    semantic_limits.max_function_arguments = 1;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "function-parameter-limit.scss",
            "@function f($a, $b) { @return $a; }",
            .scss,
            semantic_limits,
        ),
    );
    semantic_limits.max_function_arguments = 2;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "function-expanded-argument-limit.scss",
            "@function f($args...) { @return length($args); } $values: 1, 2, 3; .a { value: f($values...); }",
            .scss,
            semantic_limits,
        ),
    );
    semantic_limits = .{};
    semantic_limits.max_callables = 0;
    try std.testing.expectError(
        error.InvalidLimits,
        compile(
            std.testing.allocator,
            "invalid-callable-limits.scss",
            ".a { value: yes; }",
            .scss,
            semantic_limits,
        ),
    );

    var transaction_limits = evaluator.Limits{};
    transaction_limits.budget.max_call_depth = 2;
    try std.testing.expectError(
        error.CallDepthExceeded,
        compileWithTransactionLimits(
            std.testing.allocator,
            "function-depth-limit.scss",
            "@function recurse($n) { @if $n <= 0 { @return 0; } @return recurse($n - 1); } .a { value: recurse(3); }",
            .scss,
            .{},
            transaction_limits,
        ),
    );
    transaction_limits = .{};
    transaction_limits.budget.max_calls = 1;
    try std.testing.expectError(
        error.CallCountExceeded,
        compileWithTransactionLimits(
            std.testing.allocator,
            "function-call-limit.scss",
            "@function f() { @return 1; } .a { first: f(); second: f(); }",
            .scss,
            .{},
            transaction_limits,
        ),
    );
}

test "native Sass evaluates bounded source-ordered mixins and content blocks" {
    const input =
        \\$base: 1;
        \\@mixin dimensions($size, $gap: $size + 1px) {
        \\  width: $size;
        \\  gap: $gap;
        \\  @content;
        \\}
        \\@mixin optional-content() { marker: yes; @content; }
        \\@mixin frame($size) { border-width: $size; @content; }
        \\@mixin card($size) { @include frame($size) { padding: $size; } }
        \\@mixin repeat-content($count) {
        \\  @for $i from 1 through $count { @content; }
        \\}
        \\@mixin using($value: allowed) { using-value: $value; }
        \\@mixin inner-content { @content; }
        \\@mixin forward-content { @include inner-content { @content; } }
        \\@mixin swallow-content { @content; }
        \\@mixin isolate-content { @if false { @content; } @include swallow-content; }
        \\@if false { @include unavailable($arguments...); }
        \\$base: 2;
        \\@mixin use-base($value: $base) { base: $value; }
        \\.card {
        \\  $base: 10;
        \\  @include dimensions(3px, $gap: 5px) { content-base: $base; }
        \\  @include optional-content;
        \\  @include card(2px);
        \\  @include repeat-content(2) { repeated: $base; }
        \\  @include using;
        \\  @include forward-content { forwarded: $base; }
        \\  @include isolate-content { leaked: no; }
        \\  @include use-base;
        \\}
        \\@mixin use-base($value: $base) { base: $value + 1; }
        \\.redefined { @include use_base; }
        \\@mixin root-rule($name) { .#{$name} { value: ok; } }
        \\@include root-rule(generated);
    ;
    var result = try compile(std.testing.allocator, "user-mixins.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{width:3px;gap:5px;content-base:10;marker:yes;border-width:2px;padding:2px;repeated:10;repeated:10;using-value:allowed;forwarded:10;base:2}.redefined{base:3}.generated{value:ok}",
        result.css(),
    );
}

test "native Sass mixins retain lexical definition and content scope in both syntaxes" {
    const scss =
        \\.scope {
        \\  $local: 4;
        \\  @mixin local($value: $local) { first: $value; @content; }
        \\  @include local { from-content: $local; }
        \\  $local: 5;
        \\  @include local;
        \\  .child { @include local($value: 6); }
        \\}
    ;
    var scss_result = try compile(std.testing.allocator, "lexical-mixins.scss", scss, .scss, .{});
    defer scss_result.deinit();
    try std.testing.expectEqualStrings(
        ".scope{first:4;from-content:4;first:5}.scope .child{first:6}",
        scss_result.css(),
    );

    const indented =
        \\@mixin badge($value: 2)
        \\  width: $value * 1px
        \\  @content
        \\.sass
        \\  @include badge(3)
        \\    height: 4px
    ;
    var sass_result = try compile(std.testing.allocator, "user-mixins.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(".sass{width:3px;height:4px}", sass_result.css());
}

test "native Sass evaluates rest arguments splats and parameterized content natively" {
    const scss =
        \\@function total($head, $tail...) {
        \\  $result: $head;
        \\  @each $value in $tail { $result: $result + $value; }
        \\  @return $result;
        \\}
        \\@function relay($args...) { @return total($args...); }
        \\@function named($left: 0, $right: 0) { @return $left + $right; }
        \\@function target($a, $b: 0) { @return $a + $b; }
        \\@function proxy($args...) { @return target($args...); }
        \\@function argument-list-equals($args...) { @return $args == (1, 2); }
        \\@function echo-arguments($args...) { @return $args; }
        \\$list: 2, 3;
        \\$map: (left: 4, right: 5);
        \\.functions {
        \\  sum: relay(1, $list...);
        \\  named: named($map...);
        \\  forwarded: proxy($a: 6, $b: 7);
        \\  equal: argument-list-equals(1, 2);
        \\  emitted: echo-arguments(1, 2);
        \\}
        \\@mixin collect($first, $rest...) {
        \\  first: $first;
        \\  count: length($rest);
        \\  @each $item in $rest { item: $item; }
        \\}
        \\.mixins { @include collect(1, $list...); }
        \\@mixin provide($values...) {
        \\  @each $value in $values { @content($value, $suffix: 10); }
        \\}
        \\.content {
        \\  @include provide(a, b) using ($value, $suffix: 0) {
        \\    result: $value $suffix;
        \\  }
        \\}
        \\@mixin provide-rest { @content(1, 2, 3); }
        \\.content-rest {
        \\  @include provide-rest using ($head, $tail...) {
        \\    count: length($tail);
        \\    last: nth($tail, 2);
        \\  }
        \\}
        \\@mixin provide-default { @content(8); }
        \\.content-default {
        \\  @include provide-default using ($value, $fallback: 9) {
        \\    value: $value;
        \\    fallback: $fallback;
        \\  }
        \\}
    ;
    var scss_result = try compile(std.testing.allocator, "rest-splat-content.scss", scss, .scss, .{});
    defer scss_result.deinit();
    try std.testing.expectEqualStrings(
        ".functions{sum:6;named:9;forwarded:13;equal:true;emitted:1,2}.mixins{first:1;count:2;item:2;item:3}.content{result:a 10;result:b 10}.content-rest{count:2;last:3}.content-default{value:8;fallback:9}",
        scss_result.css(),
    );

    const indented =
        \\@function total($head, $tail...)
        \\  $result: $head
        \\  @each $value in $tail
        \\    $result: $result + $value
        \\  @return $result
        \\@mixin provide($values...)
        \\  @each $value in $values
        \\    @content($value)
        \\.sass
        \\  value: total(1, 2, 3)
        \\  @include provide(a) using ($value)
        \\    content: $value
    ;
    var sass_result = try compile(std.testing.allocator, "rest-splat-content.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(".sass{value:6;content:a}", sass_result.css());
}

test "native Sass mixins reject invalid declarations calls content and placement" {
    const invalid_syntax = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "mixin-missing-name.scss", .input = "@mixin { .a { value: no; } }" },
        .{ .name = "mixin-missing-block.scss", .input = "@mixin f;" },
        .{ .name = "mixin-reserved-name.scss", .input = "@mixin --f { .a { value: no; } }" },
        .{ .name = "mixin-empty-parameter.scss", .input = "@mixin f($a,, $b) { .a { value: no; } }" },
        .{ .name = "mixin-empty-default.scss", .input = "@mixin f($a:) { .a { value: no; } }" },
        .{ .name = "mixin-duplicate-parameter.scss", .input = "@mixin f($a_b, $a-b) { .a { value: no; } }" },
        .{ .name = "mixin-selected-control.scss", .input = "@if true { @mixin f { .a { value: no; } } }" },
        .{ .name = "mixin-unselected-control.scss", .input = "@if false { @mixin f { .a { value: no; } } } .a { value: ok; }" },
        .{ .name = "nested-mixin.scss", .input = "@mixin outer { @mixin inner { .a { value: no; } } }" },
        .{ .name = "content-at-root.scss", .input = "@content;" },
        .{ .name = "unknown-mixin.scss", .input = ".a { @include unavailable; }" },
        .{ .name = "mixin-rejects-content.scss", .input = "@mixin f { value: yes; } .a { @include f { value: no; } }" },
        .{ .name = "local-mixin-escape.scss", .input = ".scope { @mixin local { value: yes; } } .outside { @include local; }" },
    };
    for (invalid_syntax) |case| {
        try std.testing.expectError(
            error.InvalidSassSyntax,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    const invalid_calls = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "mixin-missing-argument.scss", .input = "@mixin f($a) { value: $a; } .a { @include f; }" },
        .{ .name = "mixin-unknown-keyword.scss", .input = "@mixin f($a) { value: $a; } .a { @include f($b: 1); }" },
        .{ .name = "mixin-duplicate-argument.scss", .input = "@mixin f($a) { value: $a; } .a { @include f(1, $a: 2); }" },
        .{ .name = "unselected-mixin-duplicate-argument.scss", .input = "@mixin f($a) {} @if false { @include f($a_b: 1, $a-b: 2); } .a { value: ok; }" },
        .{ .name = "mixin-positional-after-keyword.scss", .input = "@mixin f($a, $b) { value: $a; } .a { @include f($a: 1, 2); }" },
        .{ .name = "unselected-mixin-positional-after-keyword.scss", .input = "@mixin f($a, $b) {} @if false { @include f($a: 1, 2); } .a { value: ok; }" },
        .{ .name = "mixin-too-many-arguments.scss", .input = "@mixin f { value: yes; } .a { @include f(1); }" },
    };
    for (invalid_calls) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    const invalid_content_calls = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "content-arguments.scss", .input = "@mixin f { @content(1); } .a { @include f { value: yes; } }" },
        .{ .name = "content-missing-argument.scss", .input = "@mixin f { @content; } .a { @include f using ($value) { value: $value; } }" },
        .{ .name = "content-too-many-arguments.scss", .input = "@mixin f { @content(1, 2); } .a { @include f using ($value) { value: $value; } }" },
        .{ .name = "content-duplicate-argument.scss", .input = "@mixin f { @content(1, $value: 2); } .a { @include f using ($value) { value: $value; } }" },
        .{ .name = "content-unused-rest-keyword.scss", .input = "@mixin f { @content($extra: 1); } .a { @include f using ($args...) { value: length($args); } }" },
    };
    for (invalid_content_calls) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    try std.testing.expectError(
        error.InvalidSassSyntax,
        compile(
            std.testing.allocator,
            "content-using-without-block.scss",
            "@mixin f { @content; } .a { @include f using ($value); }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidSassSyntax,
        compile(
            std.testing.allocator,
            "mixin-rest-not-final.scss",
            "@mixin f($args..., $last) { value: $last; }",
            .scss,
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidSassSyntax,
        compile(
            std.testing.allocator,
            "mixin-rest-default.scss",
            "@mixin f($args...: 1) { value: yes; }",
            .scss,
            .{},
        ),
    );
}

test "native Sass mixins enforce callable and transaction limits" {
    var semantic_limits = sass_evaluator.Limits{};
    semantic_limits.max_callables = 1;
    try std.testing.expectError(
        error.CallableLimitExceeded,
        compile(
            std.testing.allocator,
            "mixed-callable-count-limit.scss",
            "@function f() { @return 1; } @mixin m { .a { value: no; } }",
            .scss,
            semantic_limits,
        ),
    );

    var transaction_limits = evaluator.Limits{};
    transaction_limits.budget.max_call_depth = 2;
    try std.testing.expectError(
        error.CallDepthExceeded,
        compileWithTransactionLimits(
            std.testing.allocator,
            "mixin-depth-limit.scss",
            "@mixin recurse($n) { @if $n > 0 { @include recurse($n - 1); } } .a { @include recurse(3); }",
            .scss,
            .{},
            transaction_limits,
        ),
    );
    transaction_limits = .{};
    transaction_limits.budget.max_calls = 1;
    try std.testing.expectError(
        error.CallCountExceeded,
        compileWithTransactionLimits(
            std.testing.allocator,
            "content-call-limit.scss",
            "@mixin f { @content; } .a { @include f { value: yes; } }",
            .scss,
            .{},
            transaction_limits,
        ),
    );
}

test "native Sass conditionals reject malformed chains" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "stray-else.scss", .input = "@else { .a { value: no; } }" },
        .{ .name = "missing-if-condition.scss", .input = "@if { .a { value: no; } }" },
        .{ .name = "missing-if-block.scss", .input = "@if true;" },
        .{ .name = "missing-else-if-condition.scss", .input = "@if false { .a { value: no; } } @else if { .b { value: no; } }" },
        .{ .name = "invalid-else-prelude.scss", .input = "@if false { .a { value: no; } } @else when true { .b { value: no; } }" },
        .{ .name = "missing-else-block.scss", .input = "@if false { .a { value: no; } } @else;" },
        .{ .name = "duplicate-else.scss", .input = "@if false { .a { x: 1; } } @else { .b { x: 2; } } @else { .c { x: 3; } }" },
        .{ .name = "else-if-after-else.scss", .input = "@if false { .a { x: 1; } } @else { .b { x: 2; } } @else if true { .c { x: 3; } }" },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidSassSyntax,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var limits = sass_evaluator.Limits{};
    limits.max_evaluation_depth = 2;
    try std.testing.expectError(
        error.EvaluationDepthExceeded,
        compile(
            std.testing.allocator,
            "conditional-depth.scss",
            "@if true { @if true { .a { value: yes; } } }",
            .scss,
            limits,
        ),
    );
}

test "native Sass evaluates bounded Unicode string functions without a provider" {
    const input =
        \\.a {
        \\  quote: quote(foo);
        \\  quote-escape: quote(foo\ bar);
        \\  unquote: unquote("foo bar");
        \\  unquote-escape: unquote("foo\ bar");
        \\  length: str-length("💚a");
        \\  escaped-length: str-length("a\62 c");
        \\  unquoted-escaped-length: str-length(foo\ bar);
        \\  index: str-index("a💚b", "💚");
        \\  missing: str-index("abc", "z");
        \\  slice: str-slice("a💚b", 2, 2);
        \\  slice-negative: str-slice("hello", -2);
        \\  insert: str-insert("a💚b", "🌍", -1);
        \\  upper: to-upper-case("Abc-é-ß-ı-i");
        \\  lower: to-lower-case("AbC-É-ẞ-I");
        \\  keyword-length: str-length($string: "💚a");
        \\  keyword-index: str-index($substring: "💚", $string: "a💚b");
        \\  keyword-slice: str-slice($end_at: 2, $string: "a💚b", $start-at: 2);
        \\  keyword-insert: str-insert($index: 2, $insert: "X", $string: "ab");
        \\}
    ;
    var result = try compile(std.testing.allocator, "strings.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{quote:\"foo\";quote-escape:\"foo\\\\ bar\";unquote:foo bar;unquote-escape:foo bar;length:2;escaped-length:3;unquoted-escaped-length:8;index:2;slice:\"💚\";slice-negative:\"lo\";insert:\"a💚b🌍\";upper:\"ABC-é-ß-ı-I\";lower:\"abc-É-ẞ-i\";keyword-length:2;keyword-index:2;keyword-slice:\"💚\";keyword-insert:\"aXb\"}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass loads the admitted built-in string module without a provider" {
    const input =
        \\@use "sass:string";
        \\@use "sass:string" as text;
        \\@use "sass:string" as *;
        \\$order: 0;
        \\$first: null;
        \\@function stamp($value) {
        \\  $order: $order + 1 !global;
        \\  @if $order == 1 { $first: $value !global; }
        \\  @return $value;
        \\}
        \\.a {
        \\  quote: string.quote(foo);
        \\  unquote: text.unquote("foo bar");
        \\  length: length("💚a");
        \\  index: string.index("a💚b", "💚");
        \\  missing: string.index("abc", "z");
        \\  slice: text.slice("a💚b", 2, 2);
        \\  insert: string.insert("ab", "X", 2);
        \\  upper: to-upper-case("Abc-é");
        \\  lower: string.to-lower-case("AbC-É");
        \\  source-order: string.index($substring: stamp(b), $string: stamp(abc));
        \\  first: $first;
        \\}
    ;
    var result = try compile(std.testing.allocator, "string-module.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{quote:\"foo\";unquote:foo bar;length:2;index:2;slice:\"💚\";insert:\"aXb\";upper:\"ABC-é\";lower:\"abc-É\";source-order:2;first:b}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:string" as s
        \\.sass
        \\  length: s.length("💚a")
        \\  index: s.index("abc", "b")
        \\  slice: s.slice("hello", -2)
        \\  insert: s.insert("ab", "X", 2)
        \\  upper: s.to-upper-case("Abc-é")
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "string-module.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{length:2;index:2;slice:\"lo\";insert:\"aXb\";upper:\"ABC-é\"}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass string module rejects unowned calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-string-module.scss",
            .input = ".a { value: string.length(abc); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unknown-string-member.scss",
            .input = "@use \"sass:string\"; .a { value: string.nope($undefined); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-string-namespace.scss",
            .input = "@use \"sass:string\" as String; .a { value: string.length(abc); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "duplicate-string-namespace.scss",
            .input = "@use \"sass:map\" as tools; @use \"sass:string\" as tools;",
            .expected = error.InvalidSassSyntax,
        },
        .{
            .name = "unsupported-string-member.scss",
            .input = "@use \"sass:string\"; .a { value: string.unique-id(); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "string-module-type.scss",
            .input = "@use \"sass:string\"; .a { value: string.length(red); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "string-module-splat.scss",
            .input = "@use \"sass:string\"; $args: (abc,); .a { value: string.length($args...); }",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass loads the admitted built-in list module without a provider" {
    const input =
        \\@use "sass:list";
        \\@use "sass:list" as seq;
        \\@use "sass:list" as *;
        \\$order: 0;
        \\$first: null;
        \\@function stamp($value) {
        \\  $order: $order + 1 !global;
        \\  @if $order == 1 { $first: $value !global; }
        \\  @return $value;
        \\}
        \\.a {
        \\  nth: list.nth((a, b, c), -1);
        \\  length: seq.length((a, b, c));
        \\  scalar: length(solo);
        \\  map-nth: list.nth((a: 1, b: 2), 2);
        \\  source-order: list.nth($n: stamp(2), $list: stamp((a, b, c)));
        \\  first: $first;
        \\}
    ;
    var result = try compile(std.testing.allocator, "list-module.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{nth:c;length:3;scalar:1;map-nth:b 2;source-order:b;first:2}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:list" as l
        \\.sass
        \\  nth: l.nth((a, b, c), -2)
        \\  length: l.length((a, b, c))
        \\  scalar: l.length(solo)
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "list-module.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{nth:b;length:3;scalar:1}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass list module rejects unowned calls" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "missing-list-module.scss",
            .input = ".a { value: list.length((a, b)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "unknown-list-member.scss",
            .input = "@use \"sass:list\"; .a { value: list.nope($undefined); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "case-sensitive-list-namespace.scss",
            .input = "@use \"sass:list\" as List; .a { value: list.length((a, b)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "duplicate-list-namespace.scss",
            .input = "@use \"sass:map\" as tools; @use \"sass:list\" as tools;",
            .expected = error.InvalidSassSyntax,
        },
        .{
            .name = "unsupported-list-member.scss",
            .input = "@use \"sass:list\"; .a { value: list.unknown($undefined, b); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "list-module-index-type.scss",
            .input = "@use \"sass:list\"; .a { value: list.nth((a, b), nope); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "list-module-index-bounds.scss",
            .input = "@use \"sass:list\"; .a { value: list.nth((a, b), 0); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "list-module-arity.scss",
            .input = "@use \"sass:list\"; .a { value: list.nth((a, b)); }",
            .expected = error.InvalidExpression,
        },
        .{
            .name = "list-module-splat.scss",
            .input = "@use \"sass:list\"; $args: ((a, b), 1); .a { value: list.nth($args...); }",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass queries lists through module and legacy functions" {
    const input =
        \\@use "sass:list";
        \\@use "sass:list" as seq;
        \\@use "sass:list" as *;
        \\$order: 0;
        \\$first: null;
        \\@function stamp($value) {
        \\  $order: $order + 1 !global;
        \\  @if $order == 1 { $first: $value !global; }
        \\  @return $value;
        \\}
        \\.a {
        \\  index: list.index((a, b, a), a);
        \\  missing: list.index((a, b), z) == null;
        \\  map-index: list.index((a: 1, b: 2), b 2);
        \\  separator-space: list.separator(a b);
        \\  separator-comma: seq.separator((a, b));
        \\  separator-undecided: list.separator(solo);
        \\  bracketed: is-bracketed([a b]);
        \\  unbracketed: list.is-bracketed(a b);
        \\  global-index: index((a, b), b);
        \\  global-separator: list-separator((a, b));
        \\  global-bracketed: is-bracketed([a]);
        \\  slash-length: list.length(a/b);
        \\  slash-separator: list.separator(a/b);
        \\  slash-index: list.index(a/b, a/b);
        \\  slash-nth: list.nth(a/b, 1);
        \\  source-order: list.index($value: stamp(b), $list: stamp((a, b)));
        \\  first: $first;
        \\}
    ;
    var result = try compile(std.testing.allocator, "list-queries.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{index:1;missing:true;map-index:2;separator-space:space;separator-comma:comma;separator-undecided:space;bracketed:true;unbracketed:false;global-index:2;global-separator:comma;global-bracketed:true;slash-length:1;slash-separator:space;slash-index:1;slash-nth:a/b;source-order:2;first:b}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:list" as l
        \\.sass
        \\  index: l.index((a, b), b)
        \\  missing: l.index((a, b), z) == null
        \\  separator: l.separator(a b)
        \\  bracketed: l.is-bracketed([a b])
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "list-queries.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{index:2;missing:true;separator:space;bracketed:true}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass list queries reject unsafe arguments" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror = error.InvalidExpression,
    }{
        .{
            .name = "list-index-short.scss",
            .input = "@use \"sass:list\"; .a { value: list.index((a, b)); }",
        },
        .{
            .name = "list-index-long.scss",
            .input = "@use \"sass:list\"; .a { value: list.index((a, b), b, c); }",
        },
        .{
            .name = "list-separator-arity.scss",
            .input = "@use \"sass:list\"; .a { value: list.separator(a, b); }",
        },
        .{
            .name = "list-bracketed-arity.scss",
            .input = "@use \"sass:list\"; .a { value: list.is-bracketed(); }",
        },
        .{
            .name = "list-query-unknown-keyword.scss",
            .input = "@use \"sass:list\"; .a { value: list.index($list: (a, b), $needle: b); }",
        },
        .{
            .name = "list-query-duplicate-keyword.scss",
            .input = "@use \"sass:list\"; .a { value: list.index($list: (a, b), $list: (c, d)); }",
        },
        .{
            .name = "list-query-splat.scss",
            .input = "@use \"sass:list\"; $args: ((a, b), b); .a { value: list.index($args...); }",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }
}

test "native Sass transforms lists immutably through module and legacy functions" {
    const input =
        \\@use "sass:list";
        \\@use "sass:list" as seq;
        \\@use "sass:list" as *;
        \\$append-order: 0;
        \\$append-first: null;
        \\$set-order: 0;
        \\$set-first: null;
        \\@function stamp-append($value) {
        \\  $append-order: $append-order + 1 !global;
        \\  @if $append-order == 1 { $append-first: $value !global; }
        \\  @return $value;
        \\}
        \\@function stamp-set($value) {
        \\  $set-order: $set-order + 1 !global;
        \\  @if $set-order == 1 { $set-first: $value !global; }
        \\  @return $value;
        \\}
        \\@function grow-rest($args...) { @return list.append($args, z); }
        \\@function replace-rest($args...) { @return list.set-nth($args, 2, x); }
        \\$original: [a b];
        \\$map: (a: 1, b: 2);
        \\$slash: list.append(a b, c, $separator: slash);
        \\$legacy: a/b;
        \\$legacy-bracketed: [a/b];
        \\.a {
        \\  scalar-auto: list.append(solo, next);
        \\  space-auto: list.append(a b, c);
        \\  comma-auto: seq.append((a, b), c);
        \\  explicit-auto: list.append((a, b), c, $separator: auto);
        \\  quoted-comma: list.append(a b, c, $separator: "comma");
        \\  comma-override: list.append(a b, c, $separator: comma);
        \\  space-override: list.append((a, b), c, $separator: space);
        \\  slash: $slash;
        \\  slash-length: list.length($slash);
        \\  slash-separator: list.separator($slash);
        \\  slash-index: list.index($slash, b);
        \\  bracketed: list.append($original, c);
        \\  original: $original;
        \\  map: list.append($map, c);
        \\  empty: list.append((), x);
        \\  rest: grow-rest(a, b);
        \\  legacy-append: append((a, b), c);
        \\  set-space: list.set-nth(a b c, -2, x);
        \\  set-comma: seq.set-nth((a, b, c), 1, x);
        \\  set-bracket: list.set-nth([a b c], 3, x);
        \\  set-map: list.set-nth($map, 2, x);
        \\  set-scalar: list.set-nth(solo, 1, x);
        \\  set-slash: list.set-nth($slash, -2, x);
        \\  set-rest: replace-rest(a, b, c);
        \\  legacy-set: set-nth(a b c, 2, x);
        \\  legacy-auto: list.append($legacy, c);
        \\  legacy-auto-length: list.length(list.append($legacy, c));
        \\  legacy-slash-length: list.length(list.append($legacy, c, $separator: slash));
        \\  legacy-set-single: list.set-nth($legacy, 1, x);
        \\  legacy-bracket-append: list.append($legacy-bracketed, c);
        \\  legacy-bracket-length: list.length($legacy-bracketed);
        \\  legacy-bracket-nth: list.nth($legacy-bracketed, 1);
        \\  legacy-bracket-index: list.index($legacy-bracketed, a/b);
        \\  legacy-bracket-set: list.set-nth($legacy-bracketed, 1, x);
        \\  source-append: list.append($val: stamp-append(c), $list: stamp-append(a b), $separator: space);
        \\  append-first: $append-first;
        \\  source-set: list.set-nth($value: stamp-set(x), $n: stamp-set(2), $list: stamp-set(a b c));
        \\  set-first: $set-first;
        \\}
    ;
    var result = try compile(std.testing.allocator, "list-transformations.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{scalar-auto:solo next;space-auto:a b c;comma-auto:a,b,c;explicit-auto:a,b,c;quoted-comma:a,b,c;comma-override:a,b,c;space-override:a b c;slash:a/b/c;slash-length:3;slash-separator:slash;slash-index:2;bracketed:[a b c];original:[a b];map:a 1,b 2,c;empty:x;rest:a,b,z;legacy-append:a,b,c;set-space:a x c;set-comma:x,b,c;set-bracket:[a b x];set-map:a 1,x;set-scalar:x;set-slash:a/x/c;set-rest:a,x,c;legacy-set:a x c;legacy-auto:a/b c;legacy-auto-length:2;legacy-slash-length:2;legacy-set-single:x;legacy-bracket-append:[a/b c];legacy-bracket-length:1;legacy-bracket-nth:a/b;legacy-bracket-index:1;legacy-bracket-set:[x];source-append:a b c;append-first:c;source-set:a x c;set-first:x}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:list" as l
        \\$original: [a b]
        \\.sass
        \\  append: l.append($original, c)
        \\  set: l.set-nth(a b c, -1, x)
        \\  legacy-append: append((a, b), c)
        \\  legacy-set: set-nth(a b c, 2, x)
        \\  slash: l.append(a b, c, $separator: slash)
        \\  original: $original
    ;
    var sass_result = try compile(
        std.testing.allocator,
        "list-transformations.sass",
        indented,
        .sass,
        .{},
    );
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{append:[a b c];set:a b x;legacy-append:a,b,c;legacy-set:a x c;slash:a/b/c;original:[a b]}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass list transformations reject unsafe arguments and limits" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror = error.InvalidExpression,
    }{
        .{
            .name = "list-append-short.scss",
            .input = "@use \"sass:list\"; .a { value: list.append((a, b)); }",
        },
        .{
            .name = "list-append-long.scss",
            .input = "@use \"sass:list\"; .a { value: list.append((a, b), c, comma, extra); }",
        },
        .{
            .name = "list-append-non-string-separator.scss",
            .input = "@use \"sass:list\"; .a { value: list.append((a, b), c, true); }",
        },
        .{
            .name = "list-append-unknown-separator.scss",
            .input = "@use \"sass:list\"; .a { value: list.append((a, b), c, invalid); }",
        },
        .{
            .name = "list-set-nth-short.scss",
            .input = "@use \"sass:list\"; .a { value: list.set-nth((a, b), 1); }",
        },
        .{
            .name = "list-set-nth-type.scss",
            .input = "@use \"sass:list\"; .a { value: list.set-nth((a, b), nope, x); }",
        },
        .{
            .name = "list-set-nth-zero.scss",
            .input = "@use \"sass:list\"; .a { value: list.set-nth((a, b), 0, x); }",
        },
        .{
            .name = "list-set-nth-bounds.scss",
            .input = "@use \"sass:list\"; .a { value: list.set-nth((a, b), 3, x); }",
        },
        .{
            .name = "list-transform-unknown-keyword.scss",
            .input = "@use \"sass:list\"; .a { value: list.append($list: (a, b), $value: c); }",
        },
        .{
            .name = "list-transform-duplicate-keyword.scss",
            .input = "@use \"sass:list\"; .a { value: list.set-nth($list: (a, b), $n: 1, $n: 2, $value: x); }",
        },
        .{
            .name = "list-transform-splat.scss",
            .input = "@use \"sass:list\"; $args: ((a, b), c); .a { value: list.append($args...); }",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 1;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "list-transform-temporary-limit.scss",
            "@use \"sass:list\"; $value: list.append((a, b), c);",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass joins lists immutably through module and legacy functions" {
    const input =
        \\@use "sass:list";
        \\@use "sass:list" as seq;
        \\@use "sass:list" as *;
        \\@use "sass:map";
        \\$join-order: 0;
        \\$join-first: null;
        \\@function stamp($value) {
        \\  $join-order: $join-order + 1 !global;
        \\  @if $join-order == 1 { $join-first: $value !global; }
        \\  @return $value;
        \\}
        \\@function join-rest($args...) { @return list.join($args, z); }
        \\$left: [a b];
        \\$slash: list.append(a b, c, $separator: slash);
        \\$legacy: a/b;
        \\$map: (x: 1, y: 2);
        \\$empty-map: map.remove((gone: 1), gone);
        \\.a {
        \\  space: list.join(a b, c d);
        \\  comma: seq.join((a, b), (c, d));
        \\  first-separator: list.join(a b, (c, d));
        \\  second-separator: list.join(a, (c, d));
        \\  bracket-left: list.join($left, c d);
        \\  original: $left;
        \\  bracket-right: list.join(a b, [c d]);
        \\  bracket-defer: list.join([a], (b, c));
        \\  unbracket: list.join($left, c d, $bracketed: false);
        \\  force-bracket: list.join(a b, c d, $bracketed: true);
        \\  truthy-bracket: list.join(a, b, $bracketed: 1);
        \\  null-unbracket: list.join([a], b, $bracketed: null);
        \\  quoted-auto: list.join(a b, (c, d), $separator: "auto", $bracketed: "auto");
        \\  force-comma: list.join(a b, c d, $separator: comma);
        \\  force-space: list.join((a, b), (c, d), $separator: space);
        \\  force-slash: list.join(a b, c d, $separator: slash);
        \\  slash-auto: list.join($slash, (d, e));
        \\  slash-length: list.length(list.join($slash, (d, e)));
        \\  slash-separator: list.separator(list.join($slash, (d, e)));
        \\  legacy: list.join($legacy, (c, d));
        \\  legacy-length: list.length(list.join($legacy, (c, d)));
        \\  legacy-first: list.nth(list.join($legacy, (c, d)), 1);
        \\  map: list.join($map, (z: 3));
        \\  empty-map-separator: list.separator($empty-map);
        \\  empty-map-append-separator: list.separator(list.append($empty-map, x));
        \\  empty-map-join: list.join($empty-map, (b, c));
        \\  rest: join-rest(a, b);
        \\  empty-length: list.length(list.join((), ()));
        \\  empty-separator: list.separator(list.join((), ()));
        \\  legacy-join: join((a, b), (c, d));
        \\  source-order: list.join($bracketed: stamp(false), $separator: stamp(comma), $list2: stamp(c d), $list1: stamp(a b));
        \\  first: $join-first;
        \\}
    ;
    var result = try compile(std.testing.allocator, "list-join.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{space:a b c d;comma:a,b,c,d;first-separator:a b c d;second-separator:a,c,d;bracket-left:[a b c d];original:[a b];bracket-right:a b c d;bracket-defer:[a,b,c];unbracket:a b c d;force-bracket:[a b c d];truthy-bracket:[a b];null-unbracket:a b;quoted-auto:a b c d;force-comma:a,b,c,d;force-space:a b c d;force-slash:a/b/c/d;slash-auto:a/b/c/d/e;slash-length:5;slash-separator:slash;legacy:a/b,c,d;legacy-length:3;legacy-first:a/b;map:x 1,y 2,z 3;empty-map-separator:space;empty-map-append-separator:space;empty-map-join:b,c;rest:a,b,z;empty-length:0;empty-separator:space;legacy-join:a,b,c,d;source-order:a,b,c,d;first:false}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:list" as l
        \\$left: [a b]
        \\.sass
        \\  value: l.join($left, c d)
        \\  original: $left
        \\  comma: l.join(a, (b, c))
        \\  bracket: l.join(a b, c d, $bracketed: true)
        \\  legacy: join((a, b), (c, d))
    ;
    var sass_result = try compile(std.testing.allocator, "list-join.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{value:[a b c d];original:[a b];comma:a,b,c;bracket:[a b c d];legacy:a,b,c,d}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass list join rejects unsafe arguments and limits" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: anyerror = error.InvalidExpression,
    }{
        .{
            .name = "list-join-short.scss",
            .input = "@use \"sass:list\"; .a { value: list.join(a); }",
        },
        .{
            .name = "list-join-long.scss",
            .input = "@use \"sass:list\"; .a { value: list.join(a, b, auto, auto, extra); }",
        },
        .{
            .name = "list-join-separator-type.scss",
            .input = "@use \"sass:list\"; .a { value: list.join(a, b, true); }",
        },
        .{
            .name = "list-join-separator-name.scss",
            .input = "@use \"sass:list\"; .a { value: list.join(a, b, invalid); }",
        },
        .{
            .name = "list-join-separator-case.scss",
            .input = "@use \"sass:list\"; .a { value: list.join(a, b, Comma); }",
        },
        .{
            .name = "list-join-unknown-keyword.scss",
            .input = "@use \"sass:list\"; .a { value: list.join($list1: a, $value: b); }",
        },
        .{
            .name = "list-join-duplicate-keyword.scss",
            .input = "@use \"sass:list\"; .a { value: list.join($list1: a, $list2: b, $list2: c); }",
        },
        .{
            .name = "list-join-splat.scss",
            .input = "@use \"sass:list\"; $args: (a, b); .a { value: list.join($args...); }",
            .expected = error.UnsupportedFeature,
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            case.expected,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 1;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "list-join-temporary-limit.scss",
            "@use \"sass:list\"; $value: list.join((a, b), (c, d));",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass zips lists immutably through module legacy and splat calls" {
    const input =
        \\@use "sass:list";
        \\@use "sass:list" as seq;
        \\@use "sass:list" as *;
        \\@use "sass:map";
        \\$zip-order: 0;
        \\$zip-first: null;
        \\@function stamp($value) {
        \\  $zip-order: $zip-order + 1 !global;
        \\  @if $zip-order == 1 { $zip-first: $value !global; }
        \\  @return $value;
        \\}
        \\@function zip-rest($args...) { @return list.zip($args, x y z); }
        \\@function zip-forward($args...) { @return list.zip($args...); }
        \\$slash: list.append(a b, c, $separator: slash);
        \\$legacy: a/b;
        \\$map1: (a: 1, b: 2);
        \\$map2: (c: 3, d: 4);
        \\$empty-map: map.remove((gone: 1), gone);
        \\$spread: (a b, c d);
        \\.a {
        \\  basic: list.zip(a b c, 1 2 3);
        \\  shortest: seq.zip(a b c, 1 2);
        \\  comma-input: list.zip((a, b), (1, 2));
        \\  bracket-input: list.zip([a b], [1 2]);
        \\  slash-input: list.zip($slash, list.append(1, 2, $separator: slash));
        \\  scalar: list.zip(a, b);
        \\  single: list.zip(a b);
        \\  map: list.zip($map1, $map2);
        \\  empty-map-length: list.length(list.zip($empty-map, a b));
        \\  zero-length: list.length(list.zip());
        \\  zero-separator: list.separator(list.zip());
        \\  outer-separator: list.separator(list.zip(a b, 1 2));
        \\  outer-bracketed: list.is-bracketed(list.zip(a b, 1 2));
        \\  inner-separator: list.separator(list.nth(list.zip(a b, 1 2), 1));
        \\  inner-bracketed: list.is-bracketed(list.nth(list.zip(a b, 1 2), 1));
        \\  null-value: list.zip(null, a b);
        \\  legacy: list.zip($legacy, c d);
        \\  legacy-length: list.length(list.zip($legacy, c d));
        \\  legacy-first: list.nth(list.nth(list.zip($legacy, c d), 1), 1);
        \\  spread: list.zip($spread...);
        \\  legacy-splat: list.zip($legacy...);
        \\  rest-list: zip-rest(a, b);
        \\  forwarded: zip-forward(a b, c d);
        \\  legacy-zip: zip(a b, c d);
        \\  source-order: list.zip(stamp(a b), stamp(c d));
        \\  first: $zip-first;
        \\}
    ;
    var result = try compile(std.testing.allocator, "list-zip.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{basic:a 1,b 2,c 3;shortest:a 1,b 2;comma-input:a 1,b 2;bracket-input:a 1,b 2;slash-input:a 1,b 2;scalar:a b;single:a,b;map:a 1 c 3,b 2 d 4;empty-map-length:0;zero-length:0;zero-separator:comma;outer-separator:comma;outer-bracketed:false;inner-separator:space;inner-bracketed:false;null-value:a;legacy:a/b c;legacy-length:1;legacy-first:a/b;spread:a c,b d;legacy-splat:a/b;rest-list:a x,b y;forwarded:a c,b d;legacy-zip:a c,b d;source-order:a c,b d;first:a b}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:list" as l
        \\$spread: (a b, c d)
        \\$legacy: a/b
        \\.sass
        \\  value: l.zip(a b, 1 2)
        \\  shortest: l.zip(a b, 1)
        \\  spread: l.zip($spread...)
        \\  legacy: l.zip($legacy, c d)
        \\  global: zip(a b, c d)
    ;
    var sass_result = try compile(std.testing.allocator, "list-zip.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{value:a 1,b 2;shortest:a 1;spread:a c,b d;legacy:a/b c;global:a c,b d}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);
}

test "native Sass list zip rejects keywords and enforces expansion and temporary limits" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "list-zip-keyword.scss",
            .input = "@use \"sass:list\"; .a { value: list.zip($foo: a b); }",
        },
        .{
            .name = "list-zip-rest-name.scss",
            .input = "@use \"sass:list\"; .a { value: list.zip($lists: a b); }",
        },
        .{
            .name = "list-zip-keyword-splat.scss",
            .input = "@use \"sass:list\"; $args: (foo: a b); .a { value: list.zip($args...); }",
        },
        .{
            .name = "list-zip-invalid-keyword-splat.scss",
            .input = "@use \"sass:list\"; $args: (1: a b); .a { value: list.zip($args...); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var argument_limits = sass_evaluator.Limits{};
    argument_limits.max_function_arguments = 1;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "list-zip-argument-limit.scss",
            "@use \"sass:list\"; $value: list.zip(a b, c d);",
            .scss,
            argument_limits,
        ),
    );
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "list-zip-expanded-limit.scss",
            "@use \"sass:list\"; $args: (a b, c d); $value: list.zip($args...);",
            .scss,
            argument_limits,
        ),
    );

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 1;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "list-zip-temporary-limit.scss",
            "@use \"sass:list\"; $value: list.zip(a b, c d);",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass constructs slash lists immutably through module and splat calls" {
    const input =
        \\@use "sass:list";
        \\@use "sass:list" as seq;
        \\@use "sass:list" as *;
        \\@use "sass:map";
        \\$slash-order: 0;
        \\$slash-first: null;
        \\@function stamp($value) {
        \\  $slash-order: $slash-order + 1 !global;
        \\  @if $slash-order == 1 { $slash-first: $value !global; }
        \\  @return $value;
        \\}
        \\@function slash-rest($args...) { @return list.slash($args, x); }
        \\@function slash-forward($args...) { @return list.slash($args...); }
        \\$legacy: a/b;
        \\$spread: (a b, c d, e);
        \\$empty-map: map.remove((gone: 1), gone);
        \\.a {
        \\  basic: list.slash(a, b, c);
        \\  custom: seq.slash(a, b);
        \\  star: slash(a, b);
        \\  groups: list.slash(a b, c d);
        \\  commas: list.slash((a, b), (c, d));
        \\  bracket-input: list.slash([a b], [c d]);
        \\  nested: list.slash(list.slash(a, b), list.slash(c, d));
        \\  nested-length: list.length(list.slash(list.slash(a, b), list.slash(c, d)));
        \\  nested-first-length: list.length(list.nth(list.slash(list.slash(a, b), list.slash(c, d)), 1));
        \\  nulls: list.slash(null, a, null, b);
        \\  all-null-length: list.length(list.slash(null, null));
        \\  map-length: list.length(list.slash((a: 1, b: 2), (c: 3)));
        \\  map-first: map.get(list.nth(list.slash((a: 1, b: 2), (c: 3)), 1), a);
        \\  empty-map-length: list.length(list.slash($empty-map, a));
        \\  empty-map-first-length: list.length(list.nth(list.slash($empty-map, a), 1));
        \\  spread: list.slash($spread...);
        \\  legacy: list.slash($legacy, c);
        \\  rest-list: slash-rest(a, b);
        \\  forwarded: slash-forward(a b, c d);
        \\  separator: list.separator(list.slash(a, b));
        \\  length: list.length(list.slash(a, b));
        \\  first-item: list.nth(list.slash(a b, c d), 1);
        \\  bracketed: list.is-bracketed(list.slash(a, b));
        \\  source-order: list.slash(stamp(a), stamp(b));
        \\  first-evaluated: $slash-first;
        \\}
    ;
    var result = try compile(std.testing.allocator, "list-slash.scss", input, .scss, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{basic:a/b/c;custom:a/b;star:a/b;groups:a b/c d;commas:a,b/c,d;bracket-input:[a b]/[c d];nested:a/b/c/d;nested-length:2;nested-first-length:2;nulls:a/b;all-null-length:2;map-length:2;map-first:1;empty-map-length:2;empty-map-first-length:0;spread:a b/c d/e;legacy:a/b/c;rest-list:a,b/x;forwarded:a b/c d;separator:slash;length:2;first-item:a b;bracketed:false;source-order:a/b;first-evaluated:a}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const indented =
        \\@use "sass:list" as l
        \\$legacy: a/b
        \\$spread: (a b, c d, e)
        \\.sass
        \\  value: l.slash(a, b, c)
        \\  groups: l.slash(a b, c d)
        \\  spread: l.slash($spread...)
        \\  legacy: l.slash($legacy, c)
        \\  separator: l.separator(l.slash(a, b))
    ;
    var sass_result = try compile(std.testing.allocator, "list-slash.sass", indented, .sass, .{});
    defer sass_result.deinit();
    try std.testing.expectEqualStrings(
        ".sass{value:a/b/c;groups:a b/c d;spread:a b/c d/e;legacy:a/b/c;separator:slash}",
        sass_result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), sass_result.nativeDiagnostics().len);

    var css_function = try compile(
        std.testing.allocator,
        "list-slash-global.scss",
        "@use \"sass:list\"; .plain { value: slash(a, b); }",
        .scss,
        .{},
    );
    defer css_function.deinit();
    try std.testing.expectEqualStrings(
        ".plain{value:slash(a, b)}",
        css_function.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), css_function.nativeDiagnostics().len);
}

test "native Sass list slash rejects unsafe arguments and enforces expansion and temporary limits" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{
            .name = "list-slash-empty.scss",
            .input = "@use \"sass:list\"; $value: list.slash();",
        },
        .{
            .name = "list-slash-single.scss",
            .input = "@use \"sass:list\"; $value: list.slash(a);",
        },
        .{
            .name = "list-slash-keyword.scss",
            .input = "@use \"sass:list\"; $value: list.slash(a, b, $foo: c);",
        },
        .{
            .name = "list-slash-named-only.scss",
            .input = "@use \"sass:list\"; $value: list.slash($foo: a, $bar: b);",
        },
        .{
            .name = "list-slash-keyword-splat.scss",
            .input = "@use \"sass:list\"; $args: (foo: a, bar: b); $value: list.slash($args...);",
        },
        .{
            .name = "list-slash-invalid-keyword-splat.scss",
            .input = "@use \"sass:list\"; $args: (1: a, 2: b); $value: list.slash($args...);",
        },
        .{
            .name = "list-slash-legacy-splat.scss",
            .input = "@use \"sass:list\"; $legacy: a/b; $value: list.slash($legacy...);",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var argument_limits = sass_evaluator.Limits{};
    argument_limits.max_function_arguments = 1;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "list-slash-argument-limit.scss",
            "@use \"sass:list\"; $value: list.slash(a, b);",
            .scss,
            argument_limits,
        ),
    );
    argument_limits = .{};
    argument_limits.max_function_arguments = 2;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "list-slash-expanded-limit.scss",
            "@use \"sass:list\"; $args: (a, b, c); $value: list.slash($args...);",
            .scss,
            argument_limits,
        ),
    );

    var temporary_limits = sass_evaluator.Limits{};
    temporary_limits.max_temporary_bytes = 1;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "list-slash-temporary-limit.scss",
            "@use \"sass:list\"; $value: list.slash(a, b);",
            .scss,
            temporary_limits,
        ),
    );
}

test "native Sass string functions reject unsafe arity types indexes and limits" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "quote-number.scss", .input = ".a { value: quote(12); }" },
        .{ .name = "length-color.scss", .input = ".a { value: str-length(red); }" },
        .{ .name = "index-type.scss", .input = ".a { value: str-index(12, x); }" },
        .{ .name = "slice-fraction.scss", .input = ".a { value: str-slice(abc, 1.2); }" },
        .{ .name = "slice-unit.scss", .input = ".a { value: str-slice(abc, 1px); }" },
        .{ .name = "insert-type.scss", .input = ".a { value: str-insert(abc, 12, 2); }" },
        .{ .name = "case-type.scss", .input = ".a { value: to-upper-case(false); }" },
        .{ .name = "short-index.scss", .input = ".a { value: str-index(abc); }" },
        .{ .name = "long-slice.scss", .input = ".a { value: str-slice(abc, 1, 2, 3); }" },
        .{
            .name = "duplicate-string-keyword.scss",
            .input = ".a { value: str-length($string: foo, $string: bar); }",
        },
        .{
            .name = "unknown-string-keyword.scss",
            .input = ".a { value: str-length($unknown: foo); }",
        },
        .{
            .name = "ordered-string-keyword.scss",
            .input = ".a { value: str-slice($string: abc, 1); }",
        },
        .{
            .name = "missing-string-keyword.scss",
            .input = ".a { value: str-index($substring: b); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    try std.testing.expectError(
        error.UnsupportedFeature,
        compile(
            std.testing.allocator,
            "string-splat.scss",
            ".a { value: str-length($args...); }",
            .scss,
            .{},
        ),
    );

    var limits = sass_evaluator.Limits{};
    limits.max_temporary_bytes = 3;
    try std.testing.expectError(
        error.TemporaryLimitExceeded,
        compile(
            std.testing.allocator,
            "string-limit.scss",
            ".a { value: str-insert(abc, def, 2); }",
            .scss,
            limits,
        ),
    );
}

test "native Sass calculations reject invalid arity types syntax and limits" {
    const invalid = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "empty-calc.scss", .input = ".a { value: calc(); }" },
        .{ .name = "empty-min.scss", .input = ".a { value: min(); }" },
        .{ .name = "short-clamp.scss", .input = ".a { value: clamp(1px, 2px); }" },
        .{ .name = "long-clamp.scss", .input = ".a { value: clamp(1px, 2px, 3px, 4px); }" },
        .{ .name = "typed-min.scss", .input = ".a { value: min(red, 2px); }" },
        .{ .name = "typed-calc.scss", .input = ".a { value: calc(red); }" },
        .{ .name = "quoted-calc.scss", .input = ".a { value: calc(\"var(--size)\"); }" },
        .{
            .name = "comment-spoofed-calc.scss",
            .input = ".a { value: calc(/* var(--size) */ red); }",
        },
        .{ .name = "invalid-calc.scss", .input = ".a { value: calc(1px +); }" },
        .{ .name = "zero-calc.scss", .input = ".a { value: calc(1px / 0); }" },
        .{ .name = "mixed-calc.scss", .input = ".a { value: calc(1 + 2px); }" },
        .{ .name = "mixed-clamp.scss", .input = ".a { value: clamp(1, 2px, 3px); }" },
        .{
            .name = "deferred-mixed-clamp.scss",
            .input = ".a { value: clamp(1, var(--size), 3px); }",
        },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidExpression,
            compile(std.testing.allocator, case.name, case.input, .scss, .{}),
        );
    }

    var limits = sass_evaluator.Limits{};
    limits.max_function_arguments = 1;
    try std.testing.expectError(
        error.FunctionArgumentLimitExceeded,
        compile(
            std.testing.allocator,
            "calculation-limit.scss",
            ".a { value: min(1px, 2px); }",
            .scss,
            limits,
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

const MathAllocationContext = struct {
    root: []const u8,
};

const MetaInspectionAllocationContext = struct {
    root: []const u8,
};

const SelectorAllocationContext = struct {
    root: []const u8,
};

// Heap-layout-dependent in-place remaps make allocation counts unstable across
// hosts. Force growth through explicit allocations so every OOM point is tested.
const DeterministicAllocationBacking = struct {
    child: std.mem.Allocator,

    fn allocator(self: *DeterministicAllocationBacking) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *DeterministicAllocationBacking = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(length, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) bool {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_length;
        _ = return_address;
        return false;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_length;
        _ = return_address;
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *DeterministicAllocationBacking = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
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
        \\@use "sass:color";
        \\@use "sass:list" as lists;
        \\@use "sass:map";
        \\@use "sass:math";
        \\@use "sass:meta";
        \\@use "sass:string" as strings;
        \\$size: 2px;
        \\$name: card;
        \\$spaces: 1px 2px 3px;
        \\$list-length: lists.length($spaces);
        \\$list-nth: lists.nth($spaces, 2);
        \\$list-index: lists.index($spaces, 2px);
        \\$list-separator: lists.separator($spaces);
        \\$list-bracketed: lists.is-bracketed([$spaces]);
        \\$list-appended: lists.append($spaces, 4px, $separator: comma);
        \\$list-replaced: lists.set-nth($list-appended, 2, 5px);
        \\$list-joined: lists.join($list-appended, (6px, 7px));
        \\$list-zipped: lists.zip($spaces, a b c);
        \\$list-slashed: lists.slash($spaces, a b c);
        \\$theme: (tone: blue, spaces: $spaces);
        \\$merged-theme: map.merge($theme, (accent: red));
        \\$removed-theme: map.remove($merged-theme, tone);
        \\$updated-theme: map.set($removed-theme, accent, green);
        \\$deep-base: (a: (b: (x: 1)), scalar: 2);
        \\$nested-merged: map.merge($deep-base, a, b, (y: 3));
        \\$nested-set: map.set($deep-base, a, b, z, 4);
        \\$deep-merged: map.deep-merge($deep-base, (a: (b: (x: 5, q: 6))));
        \\$deep-removed: map.deep-remove($deep-base, a, b, x);
        \\$enabled: not false;
        \\$inch: 1in;
        \\$math-compatible: math.compatible($inch, 96px);
        \\$math-unitless: math.is-unitless($inch / 96px);
        \\$math-unit: math.unit($inch / 1s);
        \\$math-round: math.round(1.5px);
        \\$math-percentage: math.percentage(.125);
        \\$math-div: math.div($inch, 96px);
        \\$math-div-string: math.div(foo, bar);
        \\$math-pow: math.pow(2, 3);
        \\$math-sqrt: math.sqrt(81);
        \\$math-log: math.log(8, 2);
        \\$math-pow-css: pow(var(--base), 2);
        \\$math-sin: math.sin(30deg);
        \\$math-asin: math.asin(.5);
        \\$math-atan2: math.atan2(1in, 96px);
        \\$math-sin-css: sin(var(--angle));
        \\$math-min: math.min(3px, 1px, 2px);
        \\$math-max: math.max(3px, 1px, 2px);
        \\$math-clamp: math.clamp(1px, 2px, 3px);
        \\$math-hypot: math.hypot(3px, 4px);
        \\$math-hypot-frequency: math.hypot(1Hz, 2kHz);
        \\$math-min-css: min(var(--minimum), 2px);
        \\$math-max-css: max(var(--maximum), 2px);
        \\$math-clamp-css: clamp(1px, var(--number), 3px);
        \\$math-hypot-css: hypot(var(--leg), 4px);
        \\@function allocation-value($value, $extra: 1) { @return $value + $extra; }
        \\@function allocation-rest($head, $tail...) { @return nth($tail, 1); }
        \\@function allocation-target($left, $right: 0) { @return $left + $right; }
        \\@function allocation-proxy($args...) { @return allocation-target($args...); }
        \\@function allocation-keyword($args...) {
        \\  $keywords: meta.keywords($args);
        \\  @return map-get($keywords, value);
        \\}
        \\@mixin allocation-mixin($value, $extra: 1) { mixin-value: $value + $extra; @content; }
        \\@mixin allocation-content($values...) {
        \\  @each $value in $values { @content($value, $offset: 1); }
        \\}
        \\.#{$name} {
        \\  $flow: 1px;
        \\  $loop-total: 0;
        \\  width: $size * $list-length;
        \\  color: map-get($theme, tone);
        \\  gap: lists.nth($spaces, $list-index);
        \\  enabled: $enabled and $list-bracketed and $list-separator == space;
        \\  list-appended: $list-appended;
        \\  list-replaced: $list-replaced;
        \\  list-joined: $list-joined;
        \\  list-zipped: $list-zipped;
        \\  list-slashed: $list-slashed;
        \\  function-value: allocation_value(2);
        \\  plain-function: outer(allocation-value(2));
        \\  rest-function: allocation-rest(1, (2, 3)...);
        \\  forwarded-function: allocation-proxy($left: 2, $right: 3);
        \\  inspected-keyword: allocation-keyword($value: 4);
        \\  @include allocation-mixin(2) { mixin-content: yes; }
        \\  @include allocation-content(a, b) using ($item, $offset: 0) {
        \\    content-item: $item $offset;
        \\  }
        \\  @if $enabled { $flow: 2px; $ephemeral: yes; conditional: $flow; ephemeral: $ephemeral; }
        \\  @for $iteration from 1 through 1 { $loop-total: $loop-total + $iteration; for-loop: $iteration; }
        \\  @each $entry in only { each-loop: $entry; }
        \\  @while $loop-total < 2 { $loop-total: $loop-total + 1; while-loop: $loop-total; }
        \\  loop-after: $loop-total;
        \\  flow-after: $flow;
        \\  converted: $inch + 96px;
        \\  cancelled: ($inch / 2.54cm);
        \\  math-compatible: $math-compatible;
        \\  math-unitless: $math-unitless;
        \\  math-unit: $math-unit;
        \\  math-round: $math-round;
        \\  math-percentage: $math-percentage;
        \\  math-div: $math-div;
        \\  math-div-string: $math-div-string;
        \\  math-pow: $math-pow;
        \\  math-sqrt: $math-sqrt;
        \\  math-log: $math-log;
        \\  math-pow-css: $math-pow-css;
        \\  math-sin: $math-sin;
        \\  math-asin: $math-asin;
        \\  math-atan2: $math-atan2;
        \\  math-sin-css: $math-sin-css;
        \\  math-min: $math-min;
        \\  math-max: $math-max;
        \\  math-clamp: $math-clamp;
        \\  math-hypot: $math-hypot;
        \\  math-hypot-frequency: $math-hypot-frequency;
        \\  math-min-css: $math-min-css;
        \\  math-max-css: $math-max-css;
        \\  math-clamp-css: $math-clamp-css;
        \\  math-hypot-css: $math-hypot-css;
        \\  reduced-calc: calc($size + 2px);
        \\  deferred-calc: calc(100% - $size);
        \\  color: rgba(hsl(.5turn, 100%, 50%), .4);
        \\  red-channel: red(#123456);
        \\  mixed-color: mix(red, blue, 25%);
        \\  adjusted-color: lighten(#123456, 10%);
        \\  keyword-color: adjust-color($red: 10, $color: #123456);
        \\  hwb-keyword: change-color($blackness: 20%, $color: #123456, $space: hwb);
        \\  modern-transform: adjust-color(lab(50% 10 20), $a: 5, $space: lab);
        \\  module-transform: color.adjust(lab(50% 10 20), $a: 5, $space: lab);
        \\  fixed-keyword: mix($weight: 25%, $color2: blue, $color1: red);
        \\  nth-keyword: nth($n: 2, $list: (a, b));
        \\  constructor-keyword: rgb($channels: 255 0 0 / .5);
        \\  modern-color: oklab($channels: 50% 10% -10% / .5);
        \\  wide-color: color($description: display-p3 100% 0% -10% / .5);
        \\  map-keyword: map-get($key: tone, $map: $theme);
        \\  module-map: map.get($theme, tone);
        \\  map-has: map.has-key($theme, tone);
        \\  map-first-key: nth(map.keys($theme), 1);
        \\  map-first-value: nth(map.values($theme), 1);
        \\  map-merged: map.get($merged-theme, accent);
        \\  map-removed: map.has-key($removed-theme, tone);
        \\  map-set: map.get($updated-theme, accent);
        \\  map-nested-merged: map.get($nested-merged, a, b, y);
        \\  map-nested-set: map.get($nested-set, a, b, z);
        \\  map-deep-merged: map.get($deep-merged, a, b, q);
        \\  map-deep-removed: map.has-key(map.get($deep-removed, a, b), x);
        \\  string-length: strings.length($string: "💚a");
        \\  string-slice: strings.slice("hello", -2);
        \\  string-quote: strings.quote(foo);
        \\  string-unquote: strings.unquote("foo bar");
        \\  string-index: strings.index("a💚b", "💚");
        \\  string-insert: strings.insert("ab", "X", 2);
        \\  string-upper: strings.to-upper-case("Abc-é");
        \\  &:hover { margin: $size + 1px; }
        \\}
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
        ".card{width:6px;color:blue;gap:2px;enabled:true;list-appended:1px,2px,3px,4px;list-replaced:1px,5px,3px,4px;list-joined:1px,2px,3px,4px,6px,7px;list-zipped:1px a,2px b,3px c;list-slashed:1px 2px 3px/a b c;function-value:3;plain-function:outer(3);rest-function:2;forwarded-function:5;inspected-keyword:4;mixin-value:3;mixin-content:yes;content-item:a 1;content-item:b 1;conditional:2px;ephemeral:yes;for-loop:1;each-loop:only;while-loop:2;loop-after:2;flow-after:2px;converted:2in;cancelled:1;math-compatible:true;math-unitless:true;math-unit:\"in/s\";math-round:2px;math-percentage:12.5%;math-div:1;math-div-string:foo/bar;math-pow:8;math-sqrt:9;math-log:3;math-pow-css:pow(var(--base),2);math-sin:.5;math-asin:30deg;math-atan2:45deg;math-sin-css:sin(var(--angle));math-min:1px;math-max:3px;math-clamp:2px;math-hypot:5px;math-hypot-frequency:2000.00025Hz;math-min-css:min(var(--minimum),2px);math-max-css:max(var(--maximum),2px);math-clamp-css:clamp(1px,var(--number),3px);math-hypot-css:hypot(var(--leg),4px);reduced-calc:4px;deferred-calc:calc(100% - 2px);color:rgba(0,255,255,.4);red-channel:18;mixed-color:rgb(63.75,0,191.25);adjusted-color:rgb(26.8269230769,77.5,128.1730769231);keyword-color:#1c3456;hwb-keyword:#126fcc;modern-transform:lab(50 15 20);module-transform:lab(50 15 20);fixed-keyword:rgb(63.75,0,191.25);nth-keyword:b;constructor-keyword:rgba(255,0,0,.5);modern-color:oklab(.5 .04 -0.04/.5);wide-color:color(display-p3 1 0 -0.1/.5);map-keyword:blue;module-map:blue;map-has:true;map-first-key:tone;map-first-value:blue;map-merged:red;map-removed:false;map-set:green;map-nested-merged:3;map-nested-set:4;map-deep-merged:6;map-deep-removed:false;string-length:2;string-slice:\"lo\";string-quote:\"foo\";string-unquote:foo bar;string-index:2;string-insert:\"aXb\";string-upper:\"ABC-é\"}.card:hover{margin:3px}",
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
    var backing = DeterministicAllocationBacking{ .child = std.testing.allocator };
    try std.testing.checkAllAllocationFailures(
        backing.allocator(),
        exerciseAllocationFailures,
        .{&context},
    );
}

fn exerciseLegacyIfAllocationFailures(
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
        \\@use "sass:meta";
        \\$evaluations: 0;
        \\@function mark($value) {
        \\  $evaluations: $evaluations + 1 !global;
        \\  @return $value;
        \\}
        \\.allocation {
        \\  value: if($if-false: mark(9), $condition: mark(false), $if-true: $missing);
        \\  splat: if((false, mark(8), mark(9))...);
        \\  misplaced: if(mark(false)..., mark(10), mark(11));
        \\  dual: if((false, mark(12))..., ("if-false": mark(13))...);
        \\  evaluations: $evaluations;
        \\  reflected: meta.function-exists("if");
        \\}
    ;
    const source_id = try sources.add("legacy-if-allocation.scss", input);
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
        ".allocation{value:9;splat:9;misplaced:11;dual:13;evaluations:9;reflected:true}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 5), result.nativeDiagnostics().len);
}

test "native Sass legacy if function handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const context = AllocationContext{ .root = root };
    var backing = DeterministicAllocationBacking{ .child = std.testing.allocator };
    try std.testing.checkAllAllocationFailures(
        backing.allocator(),
        exerciseLegacyIfAllocationFailures,
        .{&context},
    );
}

fn exerciseMathConstantRandomAllocationFailures(
    allocator: std.mem.Allocator,
    context: *const MathAllocationContext,
) !void {
    var authority = try resolver.Resolver.init(allocator, &.{context.root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const input =
        \\@use "sass:math";
        \\$sample: math.random((limit: 5px)...);
        \\.allocation {
        \\  e: math.$e;
        \\  epsilon: math.$epsilon * 1000000000000000;
        \\  random-range: $sample >= 1 and $sample <= 5;
        \\  random: $sample;
        \\}
    ;
    const source_id = try sources.add("math-allocation.scss", input);
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
    try std.testing.expect(std.mem.startsWith(
        u8,
        result.css(),
        ".allocation{e:2.7182818285;epsilon:.2220446049;random-range:true;random:",
    ));
    try std.testing.expect(std.mem.endsWith(u8, result.css(), "}"));
    try std.testing.expectEqual(@as(usize, 1), result.nativeDiagnostics().len);
}

test "native Sass math constants and random handle every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const context = MathAllocationContext{ .root = root };
    var backing = DeterministicAllocationBacking{ .child = std.testing.allocator };
    try std.testing.checkAllAllocationFailures(
        backing.allocator(),
        exerciseMathConstantRandomAllocationFailures,
        .{&context},
    );
}

fn exerciseMetaInspectionAllocationFailures(
    allocator: std.mem.Allocator,
    context: *const MetaInspectionAllocationContext,
) !void {
    var authority = try resolver.Resolver.init(allocator, &.{context.root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const input =
        \\@use "sass:meta";
        \\@use "sass:list" as sequences;
        \\@use "sass:map" as dictionaries;
        \\@use "sass:math" as numbers;
        \\@mixin allocation-mixin() { $inside: true; }
        \\@mixin content-probe() {
        \\  .content { exists: meta.content-exists(); }
        \\  @content;
        \\}
        \\@function inspect-args($args...) {
        \\  $keywords: meta.keywords($args);
        \\  @return meta.inspect($args);
        \\}
        \\@function invoke-keywords($function, $args...) {
        \\  @return meta.call($function, $args);
        \\}
        \\@function allocation-function($value) { @return $value; }
        \\$calculation: calc(1px + var(--x));
        \\.allocation {
        \\  type: meta.type-of($calculation);
        \\  inspect: meta.inspect((a: (1, 2)));
        \\  calc-name: meta.calc-name($calculation);
        \\  calc-args: meta.inspect(meta.calc-args(min(1px, var(--y))));
        \\  args: inspect-args(1, $tone: red);
        \\  function: meta.function-exists("inspect_args");
        \\  mixin: meta.mixin-exists("allocation_mixin");
        \\  variable: meta.variable-exists("calculation");
        \\  global: meta.global-variable-exists("calculation");
        \\  module: meta.function-exists("ceil", "numbers");
        \\  user-function-reference: meta.type-of(meta.get-function("allocation-function"));
        \\  global-function-reference: meta.type-of(meta.get-function("length"));
        \\  module-function-reference: meta.type-of(meta.get-function("ceil", $module: "numbers"));
        \\  same-function-reference: meta.get-function("ceil", $module: "numbers") == meta.get-function("ceil", $module: "numbers");
        \\  mixin-reference: meta.type-of(meta.get-mixin("allocation-mixin"));
        \\  builtin-mixin-reference: meta.type-of(meta.get-mixin("load-css", "meta"));
        \\  user-function-inspect: meta.inspect(meta.get-function("allocation-function"));
        \\  global-function-inspect: meta.inspect(meta.get-function("length"));
        \\  module-function-inspect: meta.inspect(meta.get-function("ceil", $module: "numbers"));
        \\  mixin-inspect: meta.inspect(meta.get-mixin("allocation-mixin"));
        \\  builtin-mixin-inspect: meta.inspect(meta.get-mixin("load-css", "meta"));
        \\  user-function-call: meta.call(meta.get-function("allocation-function"), 7);
        \\  list-function-call: meta.inspect(meta.call(meta.get-function("join", $module: "sequences"), (a, b), (c, d), $bracketed: true));
        \\  map-query-function-call: meta.call(meta.get-function("get", $module: "dictionaries"), (map: (a: 8), key: a)...);
        \\  map-mutation-function-call: meta.inspect(meta.call(meta.get-function("set", $module: "dictionaries"), (a: 1), b, 9));
        \\  meta-inspect-function-call: meta.call(meta.get-function("inspect", $module: "meta"), (a: (1, 2)));
        \\  meta-type-function-call: meta.call(meta.get-function("type-of", $module: "meta"), $value: $calculation);
        \\  meta-keywords-function-call: meta.inspect(invoke-keywords(meta.get-function("keywords", $module: "meta"), base, $invoked: true));
        \\  meta-content-acceptance-function-call: meta.call(meta.get-function("accepts-content", $module: "meta"), meta.get-mixin("content-probe"));
        \\  meta-calc-name-function-call: meta.call(meta.get-function("calc-name", $module: "meta"), $calculation);
        \\  meta-calc-args-function-call: meta.inspect(meta.call(meta.get-function("calc-args", $module: "meta"), min(1px, var(--y))));
        \\  meta-function-exists-call: meta.call(meta.get-function("function-exists", $module: "meta"), "allocation-function");
        \\  meta-mixin-exists-call: meta.call(meta.get-function("mixin-exists", $module: "meta"), "allocation-mixin");
        \\  meta-variable-exists-call: meta.call(meta.get-function("variable-exists", $module: "meta"), "calculation");
        \\  meta-global-variable-exists-call: meta.call(meta.get-function("global-variable-exists", $module: "meta"), "calculation");
        \\  meta-module-function-exists-call: meta.call(meta.get-function("function-exists", $module: "meta"), "ceil", "numbers");
        \\  math-abs-function-call: meta.call(meta.get-function("abs", $module: "numbers"), -7px);
        \\  math-percentage-function-call: meta.call(meta.get-function("percentage", $module: "numbers"), .125);
        \\  math-compatibility-function-call: meta.call(meta.get-function("compatible", $module: "numbers"), 1px, 1in);
        \\  math-unitless-function-call: meta.call(meta.get-function("is-unitless", $module: "numbers"), 1);
        \\  math-unit-function-call: meta.call(meta.get-function("unit", $module: "numbers"), 1px);
        \\  math-acos-function-call: meta.call(meta.get-function("acos", $module: "numbers"), .5);
        \\  math-asin-function-call: meta.call(meta.get-function("asin", $module: "numbers"), .5);
        \\  math-atan-function-call: meta.call(meta.get-function("atan", $module: "numbers"), 1);
        \\  math-atan2-function-call: meta.call(meta.get-function("atan2", $module: "numbers"), 1, 1);
        \\  accepts-content: meta.accepts-content(meta.get-mixin("content-probe"));
        \\  load-accepts-content: meta.accepts-content(meta.get-mixin("load-css", "meta"));
        \\  apply-accepts-content: meta.accepts-content(meta.get-mixin("apply", "meta"));
        \\}
        \\@include content-probe { .payload { ok: yes; } }
    ;
    const source_id = try sources.add("meta-inspection-allocation.scss", input);
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
        ".allocation{type:calculation;inspect:(a: (1, 2));calc-name:\"calc\";calc-args:1px, var(--y);args:(1,);function:true;mixin:true;variable:true;global:true;module:true;user-function-reference:function;global-function-reference:function;module-function-reference:function;same-function-reference:true;mixin-reference:mixin;builtin-mixin-reference:mixin;user-function-inspect:get-function(\"allocation-function\");global-function-inspect:get-function(\"length\");module-function-inspect:get-function(\"ceil\");mixin-inspect:get-mixin(\"allocation-mixin\");builtin-mixin-inspect:get-mixin(\"load-css\");user-function-call:7;list-function-call:[a, b, c, d];map-query-function-call:8;map-mutation-function-call:(a: 1, b: 9);meta-inspect-function-call:(a: (1, 2));meta-type-function-call:calculation;meta-keywords-function-call:(invoked: true);meta-content-acceptance-function-call:true;meta-calc-name-function-call:\"calc\";meta-calc-args-function-call:1px, var(--y);meta-function-exists-call:true;meta-mixin-exists-call:true;meta-variable-exists-call:true;meta-global-variable-exists-call:true;meta-module-function-exists-call:true;math-abs-function-call:7px;math-percentage-function-call:12.5%;math-compatibility-function-call:true;math-unitless-function-call:true;math-unit-function-call:\"px\";math-acos-function-call:60deg;math-asin-function-call:30deg;math-atan-function-call:45deg;math-atan2-function-call:45deg;accepts-content:true;load-accepts-content:false;apply-accepts-content:true}.content{exists:true}.payload{ok:yes}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Sass meta inspection handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const context = MetaInspectionAllocationContext{ .root = root };
    var backing = DeterministicAllocationBacking{ .child = std.testing.allocator };
    try std.testing.checkAllAllocationFailures(
        backing.allocator(),
        exerciseMetaInspectionAllocationFailures,
        .{&context},
    );
}

fn exerciseSelectorAllocationFailures(
    allocator: std.mem.Allocator,
    context: *const SelectorAllocationContext,
) !void {
    var authority = try resolver.Resolver.init(allocator, &.{context.root}, .{});
    defer authority.deinit();
    var session = authority.createSession(allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const input =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\.allocation {
        \\  parsed: selector.parse(".a > .b, [ data-x = 'a b' ]#c:hover");
        \\  nth: selector.parse(":nth-child(2N + 1 of .a,.b)");
        \\  lang: selector.parse(":lang( en , \\65 n )");
        \\  dir: selector.parse(":dir( ltr , \\6c tr )");
        \\  inspected: meta.inspect(selector.parse(".a, .b"));
        \\  simple: selector.simple-selectors("[title=\"x\"].foo:hover");
        \\  from-value: selector.simple-selectors(selector.parse("button.primary"));
        \\  appended: selector.append(".a, .b", ".c");
        \\  nested: selector.nest(".a, .b", "& + &");
        \\  nested-value: selector.nest(selector.parse(".root"), "&.child");
        \\  splat: selector.append((".splat", ".item")...);
        \\  relation: selector.is-superselector("[data-x='a b'] .b", ".x [data-x=\"a b\"] > .b.extra");
        \\  extended: selector.extend("[data-x=\"y\"].c [data-x=y].d", "[data-x='y']", ".b");
        \\  replaced: selector.replace("[data-x=\"y\"].c [data-x=y].d", "[data-x='y']", ".b");
        \\  list-extended: selector.extend(".a.c .a", ".a, .c", ".x, .y");
        \\  list-replaced: selector.replace(".a, .c", ".a, .c", ".b, .d");
        \\  unified: selector.unify(".a > .b .c", ".d .b .e");
        \\}
    ;
    const source_id = try sources.add("selector-allocation.scss", input);
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
        ".allocation{parsed:.a > .b,[data-x=\"a b\"]#c:hover;nth::nth-child(2n+1 of .a, .b);lang::lang(en , en);dir::dir(ltr , ltr);inspected:.a, .b;simple:[title=x],.foo,:hover;from-value:button,.primary;appended:.a.c,.b.c;nested:.a + .a,.a + .b,.b + .a,.b + .b;nested-value:.root.child;splat:.splat.item;relation:true;extended:[data-x=y].c [data-x=y].d,.c.b [data-x=y].d,[data-x=y].c .d.b,.c.b .d.b;replaced:.c.b .d.b;list-extended:.a.c .a,.x .a,.y .a,.a.c .x,.x .x,.y .x,.a.c .y,.x .y,.y .y;list-replaced:.b,.d,.b;unified:.d .a > .b .c.e}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
    try std.testing.expect(result.map() != null);
}

test "native Sass selector parsing composition relations extension replacement and unification handle every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("root");
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const context = SelectorAllocationContext{ .root = root };
    var backing = DeterministicAllocationBacking{ .child = std.testing.allocator };
    try std.testing.checkAllAllocationFailures(
        backing.allocator(),
        exerciseSelectorAllocationFailures,
        .{&context},
    );
}
