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
            .input = "@use \"sass:math\";",
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
            .input = "@use \"sass:list\"; .a { value: list.zip($undefined, b); }",
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
        \\  function-value: allocation_value(2);
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
        ".card{width:6px;color:blue;gap:2px;enabled:true;list-appended:1px,2px,3px,4px;list-replaced:1px,5px,3px,4px;list-joined:1px,2px,3px,4px,6px,7px;function-value:3;rest-function:2;forwarded-function:5;inspected-keyword:4;mixin-value:3;mixin-content:yes;content-item:a 1;content-item:b 1;conditional:2px;ephemeral:yes;for-loop:1;each-loop:only;while-loop:2;loop-after:2;flow-after:2px;converted:2in;cancelled:1;reduced-calc:4px;deferred-calc:calc(100% - 2px);color:rgba(0,255,255,.4);red-channel:18;mixed-color:rgb(63.75,0,191.25);adjusted-color:rgb(26.8269230769,77.5,128.1730769231);keyword-color:#1c3456;hwb-keyword:#126fcc;modern-transform:lab(50 15 20);module-transform:lab(50 15 20);fixed-keyword:rgb(63.75,0,191.25);nth-keyword:b;constructor-keyword:rgba(255,0,0,.5);modern-color:oklab(.5 .04 -0.04/.5);wide-color:color(display-p3 1 0 -0.1/.5);map-keyword:blue;module-map:blue;map-has:true;map-first-key:tone;map-first-value:blue;map-merged:red;map-removed:false;map-set:green;map-nested-merged:3;map-nested-set:4;map-deep-merged:6;map-deep-removed:false;string-length:2;string-slice:\"lo\";string-quote:\"foo\";string-unquote:foo bar;string-index:2;string-insert:\"aXb\";string-upper:\"ABC-é\"}.card:hover{margin:3px}",
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
