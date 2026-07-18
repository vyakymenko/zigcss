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

test "native Sass keyword color transforms reject unsafe and unimplemented calls" {
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
            "modern-space.scss",
            ".a { color: adjust-color(#123456, $lightness: 10%, $space: lab); }",
            .scss,
            .{},
        ),
    );
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
        \\$spaces: 1px 2px 3px;
        \\$theme: (tone: blue, spaces: $spaces);
        \\$enabled: not false;
        \\$inch: 1in;
        \\.#{$name} {
        \\  width: $size * 3;
        \\  color: map-get($theme, tone);
        \\  gap: nth(map-get($theme, spaces), 2);
        \\  enabled: $enabled and true;
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
        \\  fixed-keyword: mix($weight: 25%, $color2: blue, $color1: red);
        \\  nth-keyword: nth($n: 2, $list: (a, b));
        \\  constructor-keyword: rgb($channels: 255 0 0 / .5);
        \\  modern-color: oklab($channels: 50% 10% -10% / .5);
        \\  wide-color: color($description: display-p3 100% 0% -10% / .5);
        \\  map-keyword: map-get($key: tone, $map: $theme);
        \\  string-length: str-length($string: "💚a");
        \\  string-slice: str-slice("hello", -2);
        \\  string-quote: quote(foo);
        \\  string-unquote: unquote("foo bar");
        \\  string-index: str-index("a💚b", "💚");
        \\  string-insert: str-insert("ab", "X", 2);
        \\  string-upper: to-upper-case("Abc-é");
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
        ".card{width:6px;color:blue;gap:2px;enabled:true;converted:2in;cancelled:1;reduced-calc:4px;deferred-calc:calc(100% - 2px);color:rgba(0,255,255,.4);red-channel:18;mixed-color:rgb(63.75,0,191.25);adjusted-color:rgb(26.8269230769,77.5,128.1730769231);keyword-color:#1c3456;hwb-keyword:#126fcc;fixed-keyword:rgb(63.75,0,191.25);nth-keyword:b;constructor-keyword:rgba(255,0,0,.5);modern-color:oklab(.5 .04 -0.04/.5);wide-color:color(display-p3 1 0 -0.1/.5);map-keyword:blue;string-length:2;string-slice:\"lo\";string-quote:\"foo\";string-unquote:foo bar;string-index:2;string-insert:\"aXb\";string-upper:\"ABC-é\"}.card:hover{margin:3px}",
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
