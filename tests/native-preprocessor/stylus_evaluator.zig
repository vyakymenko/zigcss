const std = @import("std");
const preprocessor = @import("native_preprocessor");
const diagnostics = preprocessor.diagnostics;
const evaluator = preprocessor.evaluator;
const resolver = preprocessor.resolver;
const source = preprocessor.source;
const stylus = preprocessor.stylus;
const stylus_evaluator = preprocessor.stylus_evaluator;

const eol_escape_input =
    "\nlist = foo \\\n" ++
    "       bar \\\n" ++
    "       baz\n\n" ++
    "map = (one 1) \\\n" ++
    "      (two 2) \\\n" ++
    "      (three 3)\n\n" ++
    "body\n" ++
    "  foo: list\n" ++
    "  for val, key in map\n" ++
    "    {val}: key\n\n" ++
    "foo( \\\n" ++
    "  a, \\\n" ++
    "  b)\n" ++
    "  padding: unit(a, px) \\\n" ++
    "           unit(b, px)\n\n" ++
    "button\n" ++
    "  foo: 1 2\n" ++
    "  box-shadow: \\\n" ++
    "    0 -2px 2px red, \\  \n" ++
    "    0 0 2px red, \\\n" ++
    "    0 0 5px red\n" ++
    "  color: red";

const eol_escape_css = "body{foo:foo bar baz;one:0;two:1;three:2}" ++
    "button{padding:1px 2px;box-shadow:0 -2px 2px #f00, 0 0 2px #f00," ++
    " 0 0 5px #f00;color:#f00}";

const complex_extension_input =
    \\form button
    \\  padding 10px
    \\a.button
    \\  @extends form button
    \\form
    \\  button
    \\    color red
    \\body
    \\  width 75%
    \\form
    \\  if true
    \\    @extend body
    \\a.button
    \\  unless false
    \\    @extend form
    \\.nope
    \\  if false
    \\    @extend body
;

const complex_extension_css = "form button,a.button{padding:10px}" ++
    "form button,a.button button{color:#f00}" ++
    "body,form,a.button{width:75%}";

const loop_extension_input =
    \\.span
    \\  width 100%
    \\for i in 1..4
    \\  .span{i}
    \\    @extend .span
;

const loop_extension_css = ".span,.span1,.span2,.span3,.span4{width:100%}";

const loop_context_extension_input =
    \\.tester1
    \\  tester: 1
    \\.tester2
    \\  tester: 2
    \\for i in 1..2
    \\  .test{i}
    \\    test{i}: i
    \\    @extend .tester{i}
;

const loop_context_extension_css = ".tester1,.test1{tester:1}" ++
    ".tester2,.test2{tester:2}.test1{test1:1}.test2{test2:2}";

const media_query_extension_input =
    \\@media (min-width: 40em)
    \\  .test
    \\    width: 100%
    \\  .test-extend
    \\    @extend .test
;

const media_query_extension_css =
    "@media (min-width: 40em){.test,.test-extend{width:100%}}";

const mixin_extension_input =
    \\.c4
    \\  width 50%
    \\
    \\column()
    \\  @extend .c4
    \\
    \\#col3
    \\  column 4
    \\
    \\grid($namespace='')
    \\  .{$namespace}one-half
    \\    width 50%
    \\
    \\  .{$namespace}two-quarters
    \\    @extend .{$namespace}one-half
    \\
    \\grid()
    \\
    \\@media test-media
    \\  grid('test-')
;

const mixin_extension_css = ".c4,#col3{width:50%}" ++
    ".one-half,.two-quarters{width:50%}" ++
    "@media test-media{.test-one-half,.test-two-quarters{width:50%}}";

const nested_mixin_extension_input =
    \\.class
    \\  position absolute;
    \\
    \\abstract()
    \\  evenMore()
    \\
    \\more()
    \\  @extend .class
    \\
    \\moreAbstract()
    \\  abstract()
    \\
    \\evenMore()
    \\  more()
    \\
    \\.class2
    \\  moreAbstract()
;

const nested_mixin_extension_css = ".class,.class2{position:absolute}";

const multiple_definition_extension_input =
    \\.error
    \\  font-size: bold
    \\.error
    \\  color: red
    \\.serious-error
    \\  @extends .error
    \\  font-size: 18px
;

const multiple_definition_extension_css = ".error,.serious-error{font-size:bold}" ++
    ".error,.serious-error{color:#f00}.serious-error{font-size:18px}";

const multiple_selector_extension_input =
    \\.a
    \\  color: red
    \\.b
    \\  width: 100px
    \\.c
    \\  @extend .a, .b
    \\  height: 200px
    \\.d
    \\  @extend .b,.c
    \\.d[data-prop*='\,']
    \\  color: blue
    \\.d-1
    \\  width: 100%
    \\$cf
    \\  &:before
    \\  &:after
    \\    content: ' '
    \\    clear: both
    \\    display: table
    \\    font: 0/0 a
    \\    visibility: hidden
    \\$ib
    \\  display: inline-block
    \\.foo
    \\  @extend .d[data-prop*=','], $cf, $ib
    \\$i = 1
    \\.e
    \\  @extend .d-{$i}, $cf, $ib
;

const multiple_selector_extension_css = ".a,.c,.d{color:#f00}" ++
    ".b,.c,.d{width:100px}.c,.d{height:200px}" ++
    ".d[data-prop*=\",\"],.foo{color:#00f}.d-1,.e{width:100%}" ++
    ".foo::before,.e::before,.foo::after,.e::after{content:' ';clear:both;" ++
    "display:table;font:0/0 a;visibility:hidden}.foo,.e{display:inline-block}";

const variable_target_extension_input =
    \\.test
    \\  width 100%
    \\var = "test"
    \\.{var}2
    \\  @extend .{var}
;

const variable_target_extension_css = ".test,.test2{width:100%}";

const optional_extension_input =
    \\.tester
    \\  color #FFF
    \\$tester2
    \\  font-size 12px
    \\$tester3
    \\  border-radius 1px
    \\.end
    \\  @extend .tester !optional, notExist1 !optional, $notExist2 !optional, $tester2 !optional, {'$test' + 'er3'} !optional
    \\  border #AAA
;

const optional_extension_css = ".tester,.end{color:#fff}" ++
    ".end{font-size:12px}.end{border-radius:1px}.end{border:#aaa}";

const callable_optional_extension_input =
    \\.base
    \\  width 1px
    \\$placeholder
    \\  height 2px
    \\extend-targets()
    \\  @extend .base !optional, absent !optional, $placeholder !optional
    \\.end
    \\  extend-targets()
    \\  display block
;

const callable_optional_extension_css =
    ".base,.end{width:1px}.end{height:2px}.end{display:block}";

const placeholder_chain_extension_input =
    \\$base
    \\  width 1px
    \\$variant
    \\  @extend $base
    \\  height 2px
    \\make-slots()
    \\  for i in 1..3
    \\    $slot_{i}
    \\      margin 10px*i
    \\make-slots()
    \\extend-slot($index)
    \\  @extend $slot_{$index}
    \\.visible
    \\  @extend $variant
    \\  extend-slot(2)
;

const placeholder_chain_extension_css =
    ".visible{width:1px}.visible{height:2px}.visible{margin:20px}";

const placeholder_plural_extension_input =
    \\$nested-base
    \\  width 1px
    \\.shell
    \\  .item
    \\    @extends $nested-base
    \\$complex-base
    \\  .leaf
    \\    height 2px
    \\.one,
    \\.two
    \\  @extends $complex-base .leaf
    \\$media-base
    \\  color red
    \\@media screen
    \\  .media
    \\    .item
    \\      @extends $media-base
;

const placeholder_plural_extension_css =
    ".shell .item{width:1px}.one,.two{height:2px}" ++
    ".media .item{color:#f00}";

const font_face_input =
    \\@font-face
    \\  font-family "Lower"
    \\  src url("lower.woff")
    \\@font-face
    \\{
    \\  font-family: 'Explicit'
    \\}
;

const font_face_css =
    "@font-face{font-family:\"Lower\";src:url(\"lower.woff\")}" ++
    "@font-face{font-family:'Explicit'}";

const keyframe_loop_terminal_input =
    \\vendors = official
    \\for index in 1..3
    \\  @keyframes {'pulse' + index}
    \\    from
    \\      opacity index
;

const keyframe_loop_terminal_css =
    "@keyframes pulse1{from{opacity:1}}" ++
    "@keyframes pulse2{from{opacity:2}}" ++
    "@keyframes pulse3{from{opacity:3}}";

const keyframe_semantic_input =
    \\steps()
    \\  75%
    \\    opacity 1
    \\@keyframes early
    \\  from
    \\    opacity 0
    \\vendors = official
    \\@keyframes pulse {
    \\  from { opacity: 0; background-image: radial-gradient(yellow 0%, red 50%, black 100%); }
    \\  50% {}
    \\  to {}
    \\  steps() if true
    \\  steps() unless true
    \\}
    \\.owner
    \\  @keyframes nested
    \\    from
    \\      opacity 0
;

const keyframe_semantic_css =
    "@keyframes nested{from{opacity:0}}" ++
    "@-moz-keyframes early{from{opacity:0}}" ++
    "@-webkit-keyframes early{from{opacity:0}}" ++
    "@-o-keyframes early{ from { opacity: 0; } }" ++
    "@keyframes early{from{opacity:0}}" ++
    "@keyframes pulse{from{opacity:0;background-image:radial-gradient(#ff0 0%, #f00 50%, #000 100%)}75%{opacity:1}}";

const complex_for_input =
    \\values = a b c d
    \\body
    \\  for value, index in values[1..2]
    \\    item index value
    \\pairs = (error 'first') (error 'second')
    \\body
    \\  for pair in pairs
    \\    message pair[0] pair[1]
    \\body
    \\  for row in x y
    \\    for column in 0 1
    \\      grid column row
    \\probe()
    \\  marker = 1
    \\  for ignored in arguments
    \\    null
    \\  state marker is defined
    \\body
    \\  probe()
    \\body
    \\  probe(42)
;

const complex_for_css = "body{item:0 b;item:1 c}" ++
    "body{message:error 'first';message:error 'second'}" ++
    "body{grid:0 x;grid:1 x;grid:0 y;grid:1 y}" ++
    "body{state:true}body{state:true}";

const function_arguments_input =
    \\sum()
    \\  n = 0
    \\  for num in arguments
    \\    n = n + num
    \\  n
    \\pair(a, b)
    \\  a = b
    \\  (arguments[0] a)
    \\defaults(p0 = 4px, p1 = 5px)
    \\  p0 arguments[0]
    \\  p1 arguments[1]
    \\color-proxy()
    \\  return rgba(arguments)
    \\semi-transparent()
    \\  return rgba(arguments, 0.5)
    \\width()
    \\  push(arguments, !important)
    \\  {current-property[0]}: arguments
    \\body
    \\  padding sum(1, 2, 3, 4, 5)
    \\  padding pair(1, 2)
    \\.defaults
    \\  defaults()
    \\.opaque
    \\  color color-proxy(0, 0, 0, 1)
    \\.translucent
    \\  color semi-transparent(0, 0, 0)
    \\img
    \\  width: unquote('auto')
;

const function_arguments_css = "body{padding:15;padding:1 2}" ++
    ".defaults{p0:4px;p1:5px}.opaque{color:#000}" ++
    ".translucent{color:rgba(0,0,0,0.5)}img{width:auto!important}";

const keyword_arguments_input =
    \\pad-y(top, bottom)
    \\  padding-top top
    \\  padding-bottom bottom
    \\body
    \\  pad-y(bottom: 100px, top: 15px)
    \\  quotient operate(right: 2, left: 10, op: '/')
    \\  joined join(1 2 3, delim: '|')
    \\  spread join(1, delim: '|', 2, 3)
    \\  tint rgba(alpha: 0.5, green: 50, red: 100, 10)
;

const keyword_arguments_css = "body{padding-top:15px;padding-bottom:100px;" ++
    "quotient:5;joined:'1|2|3';spread:'1|2|3';" ++
    "tint:rgba(100,50,10,0.5)}";

const literal_css_input =
    \\@css {
    \\  body {
    \\    font: 14px;
    \\  }
    \\
    \\  a { text-decoration: none; }
    \\}
;

const literal_css_output = "body{font:14px}a{text-decoration:none}";

const literal_color_input =
    \\body
    \\  color #e
    \\  color #ef
    \\  color #fc0
    \\  color #fc06
    \\  color #ffcc00
    \\  color #ffcc0066
    \\  color rgb(100%, 255, 100%)
    \\  color rgba(100%, 255, 100%, 0.5)
    \\  color hsla(1, 1, 1, 0.75)
    \\  color hsla(1, 1, 1, 75%)
    \\  color rgba(50, 50, 50, 0.75)
    \\  color rgba(50, 50, 50, 75%)
    \\  color rgba(#323232, 75%)
;

const literal_color_css = "body{color:#eee;color:#efefef;color:#fc0;" ++
    "color:rgba(255,204,0,0.4);color:#fc0;color:rgba(255,204,0,0.4);" ++
    "color:#fff;color:rgba(255,255,255,0.5);" ++
    "color:rgba(3,3,3,0.75);color:rgba(3,3,3,0.75);" ++
    "color:rgba(50,50,50,0.75);color:rgba(50,50,50,0.75);" ++
    "color:rgba(50,50,50,0.75)}";

const media_bubble_input =
    \\@media (max-width: 640px), (max-height: 320px)
    \\  .logo
    \\    width 42px
    \\    @media all and (-webkit-min-device-pixel-ratio: 1.5)
    \\      background-size 42px 42px
;

const media_bubble_css =
    "@media (max-width: 640px), (max-height: 320px){.logo{width:42px}}" ++
    "@media all and (max-width: 640px) and (-webkit-min-device-pixel-ratio: 1.5), " ++
    "all and (max-height: 320px) and (-webkit-min-device-pixel-ratio: 1.5)" ++
    "{.logo{background-size:42px 42px}}";

const media_complex_input =
    \\size = 3em
    \\obj = { print: 500px }
    \\@media only screen and (max-width: size * 10), not print and (orientation:portrait) && (min-{'width'} obj.print),
    \\  (monochrome) and (bar baz)
    \\  body
    \\    color #c00
    \\@media /* outer */ all and /* gap */(/* pre */ min-width :/* value */ 100px /* kept */)
    \\  body
    \\    color green
    \\query = 'screen and (min-width: 10px)'
    \\@media query
    \\  body
    \\    width 10px
    \\breakpoints = { small: 'only screen' }
    \\@media breakpoints["small"]
    \\  body
    \\    height 20px
    \\@media (min-width: 1px) {}
    \\bar(width)
    \\  @media (width width)
    \\    body
    \\      color red
    \\@media screen
    \\  if true
    \\    bar(500px)
    \\.foo
    \\  for j in 8..10
    \\    @media (min-width: (1200 / 16 * j / 10)em)
    \\      @media (min-height: (780 / 16 * j / 10)em)
    \\        font-size (j / 10)em
;

const media_complex_css =
    "@media only screen and (max-width: 30em), not print and " ++
    "(orientation: portrait) and (min-width: 500px), (monochrome) and (bar: baz)" ++
    "{body{color:#c00}}" ++
    "@media all and (min-width: 100px /* kept */){body{color:#008000}}" ++
    "@media screen and (min-width: 10px){body{width:10px}}" ++
    "@media only screen{body{height:20px}}" ++
    "@media screen and (width: 500px){body{color:#f00}}" ++
    "@media (min-width: 60em) and (min-height: 39em){.foo{font-size:0.8em}}" ++
    "@media (min-width: 67.5em) and (min-height: 43.875em){.foo{font-size:0.9em}}" ++
    "@media (min-width: 75em) and (min-height: 48.75em){.foo{font-size:1em}}";

const mixin_caller_scope_input =
    \\global = 12
    \\inner(value = global)
    \\  push(items, 3)
    \\  lexical value
    \\  seen-first first
    \\  seen-second second
    \\  seen-items items
    \\outer()
    \\  global = 99
    \\  first = 1
    \\  second = 2
    \\  items = 1 2
    \\  inner()
    \\body
    \\  outer()
;

const mixin_caller_scope_css =
    "body{lexical:12;seen-first:1;seen-second:2;seen-items:1 2 3}";

const function_property_alias_input =
    \\box-shadow-important()
    \\  push(arguments, !important)
    \\  -webkit-box-shadow arguments
    \\  box-shadow arguments
    \\box-shadow = box-shadow-important
    \\p.important
    \\  box-shadow 1px -1px 0 1px rgba(0, 0, 0, .5)
;

const function_property_alias_css =
    "p.important{-webkit-box-shadow:1px -1px 0 1px rgba(0,0,0,0.5)!important;" ++
    "box-shadow:1px -1px 0 1px rgba(0,0,0,0.5)!important}";

const interpolated_property_input =
    \\vendor(prop, args)
    \\  {prop} args
    \\border-radius()
    \\  vendor('border-radius', arguments)
    \\testing(value)
    \\  {value}
    \\top-right()
    \\  position absolute
    \\  top 0
    \\  right 0
    \\#login
    \\  border-radius 1px 2px / 3px 4px
    \\  value testing('one')
    \\  {testing('top')}-right ignored
;

const interpolated_property_css =
    "#login{border-radius:1px 2px/3px 4px;value:'one';" ++
    "position:absolute;top:0;right:0}";

const mixin_introspection_input =
    \\reset()
    \\  if mixin == 'root'
    \\    got
    \\      root true
    \\  else if mixin
    \\    got 'a mixin'
    \\  else
    \\    'not a mixin'
    \\reset()
    \\body
    \\  reset()
    \\  foo reset()
;

const mixin_introspection_css =
    "got{root:true}body{got:'a mixin';foo:'not a mixin'}";

const anonymous_functions_input =
    \\mixin(add) {
    \\  mul = @(c, d) {
    \\    c * d
    \\  }
    \\  width: add(2, 3) + mul(4, 5)
    \\}
    \\body
    \\  mixin(@(a, b) {
    \\    return a + b;
    \\  })
;

const anonymous_functions_css = "body{width:25}";

const call_mixin_block_transport_input =
    \\size()
    \\  10px
    \\blocks = ()
    \\capture()
    \\  display block
    \\  blocks[0] = block
    \\  {blocks}
    \\body
    \\  +capture()
    \\    width size()
;

const call_mixin_block_transport_css = "body{display:block;width:10px}";

const call_mixin_default_block_input =
    \\wrap(block = { height: 10px })
    \\  .inner
    \\    {block}
    \\.outer
    \\  +wrap()
    \\    width 20px
    \\.fallback
    \\  wrap()
;

const call_mixin_default_block_css =
    ".outer .inner{width:20px}.fallback .inner{height:10px}";

const call_mixin_nested_context_input =
    \\passthrough()
    \\  {block}
    \\.base
    \\  color red
    \\.alias
    \\  +passthrough()
    \\    @extend .base
    \\.target
    \\  color blue
    \\.parent
    \\  + article
    \\    @extend .target
    \\emit-font()
    \\  @font-face
    \\    {block}
    \\.owner
    \\  +emit-font()
    \\    width 20px
;

const call_mixin_nested_context_css =
    ".base,.alias{color:#f00}.target,.parent+article{color:#00f}" ++
    "@font-face{width:20px}";

const call_to_string_input =
    \\values = foo bar(baz, buz, 1)
    \\a
    \\  lower: '' + foo()
    \\  source: values
    \\  terminal: '' + @source
    \\  prefixed: 'pre-' + values
;

const call_to_string_css = "a{lower:'foo()';source:foo bar(baz, buz, 1);" ++
    "terminal:'foo bar(baz, buz, 1)';prefixed:'pre-foo bar(baz, buz, 1)'}";

const multiple_call_assignment_input =
    \\pad(y = 100px)
    \\  padding unit(y, 'px')
    \\body
    \\  pad(5px)
    \\  pad()
    \\  pad(10px)
    \\pad-x(n)
    \\  n = unit(n, 'px')
    \\  padding-left n
    \\  padding-right n
    \\pad-y(y)
    \\  padding-top n = unit(y, 'px')
    \\  padding-bottom n
    \\pad(x, y)
    \\  pad-x(x)
    \\  pad-y(y)
    \\form
    \\  pad(5, 10)
;

const multiple_call_assignment_css =
    "body{padding:5px;padding:100px;padding:10px}" ++
    "form{padding-left:5px;padding-right:5px;padding-top:10px;padding-bottom:10px}";

const nested_function_input =
    \\outer(a, b)
    \\  half()
    \\    b / 2
    \\  a + half()
    \\factory(name)
    \\  if name == 'add'
    \\    add(a, b)
    \\      a + b
    \\  else
    \\    sub(a, b)
    \\      a - b
    \\body
    \\  width outer(1, 5)
    \\  fn = factory('add')
    \\  height fn(5, 5)
    \\  fn = factory('sub')
    \\  fn2 = fn
    \\  min-height fn2(5, 5)
;

const nested_function_css = "body{width:3.5;height:10;min-height:0}";

const logical_condition_input =
    \\n = 75
    \\if n < 50 or n > 50 and n < 100
    \\  body
    \\    selected yes
    \\else
    \\  body
    \\    selected no
    \\if false and missing > 0
    \\  body
    \\    and-branch unsafe
    \\else
    \\  body
    \\    and-branch safe
    \\if true or missing > 0
    \\  body
    \\    or-branch safe
;

const logical_condition_css =
    "body{selected:yes}body{and-branch:safe}body{or-branch:safe}";

const commented_if_else_input =
    \\.base
    \\  color red
    \\if false
    \\  .never
    \\    @extend .base
    \\// preserve the root conditional chain
    \\else if false
    \\  .also-never
    \\    @extend .base
    \\// preserve the terminal root branch
    \\else
    \\  .alias
    \\    @extend .base
    \\body
    \\  if false
    \\    color red
    \\  // preserve the nested conditional chain
    \\  else if true
    \\    color blue
    \\  // do not select a later branch
    \\  else
    \\    color green
    \\  if true
    \\    background white
    \\  // do not clear a selected branch
    \\  else
    \\    background black
;

const commented_if_else_css =
    ".base,.alias{color:#f00}body{color:#00f;background:#fff}";

const unitful_mixin_condition_input =
    \\sign(n)
    \\  if n < 0
    \\    result below
    \\  else if n > 0
    \\    result above
    \\  else
    \\    result zero
    \\body
    \\  sign(5px)
    \\  sign(-5px)
    \\  sign(0px)
;

const unitful_mixin_condition_css =
    "body{result:above;result:below;result:zero}";

fn compile(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: stylus_evaluator.Limits,
) !evaluator.ValidatedCss {
    return compileWithOptions(allocator, input, .{}, limits);
}

fn compileWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: stylus_evaluator.Options,
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
    try stylus_evaluator.evaluateWithOptions(
        &sources,
        &document,
        &transaction,
        options,
        limits,
    );
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

const FixtureFile = struct {
    path: []const u8,
    contents: []const u8,
};

fn compileFixture(
    allocator: std.mem.Allocator,
    input: []const u8,
    files: []const FixtureFile,
    resolver_limits: resolver.Limits,
    evaluator_limits: stylus_evaluator.Limits,
) !evaluator.ValidatedCss {
    return compileFixtureWithOptions(
        allocator,
        input,
        files,
        .{},
        resolver_limits,
        evaluator_limits,
    );
}

fn compileFixtureWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    files: []const FixtureFile,
    options: stylus_evaluator.Options,
    resolver_limits: resolver.Limits,
    evaluator_limits: stylus_evaluator.Limits,
) !evaluator.ValidatedCss {
    return compileFixtureWithOptionsAndCancellation(
        allocator,
        input,
        files,
        options,
        resolver_limits,
        evaluator_limits,
        .{},
        .{},
    );
}

fn compileFixtureWithCancellation(
    allocator: std.mem.Allocator,
    input: []const u8,
    files: []const FixtureFile,
    resolver_limits: resolver.Limits,
    evaluator_limits: stylus_evaluator.Limits,
    resolver_cancellation: resolver.Cancellation,
    evaluator_cancellation: evaluator.Cancellation,
) !evaluator.ValidatedCss {
    return compileFixtureWithOptionsAndCancellation(
        allocator,
        input,
        files,
        .{},
        resolver_limits,
        evaluator_limits,
        resolver_cancellation,
        evaluator_cancellation,
    );
}

fn compileFixtureWithOptionsAndCancellation(
    allocator: std.mem.Allocator,
    input: []const u8,
    files: []const FixtureFile,
    options: stylus_evaluator.Options,
    resolver_limits: resolver.Limits,
    evaluator_limits: stylus_evaluator.Limits,
    resolver_cancellation: resolver.Cancellation,
    evaluator_cancellation: evaluator.Cancellation,
) !evaluator.ValidatedCss {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    var root_dir = try temporary.dir.openDir("root", .{});
    defer root_dir.close();
    try root_dir.writeFile(.{ .sub_path = "input.styl", .data = input });
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try root_dir.makePath(parent);
        try root_dir.writeFile(.{ .sub_path = file.path, .data = file.contents });
    }

    const base = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const entry_path = try std.fs.path.join(allocator, &.{ root, "input.styl" });
    defer allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(allocator, entry_path);
    defer allocator.free(entry_url);

    var authority = try resolver.Resolver.init(allocator, &.{root}, resolver_limits);
    defer authority.deinit();
    var session = authority.createSession(allocator, resolver_cancellation);
    defer session.deinit();
    var sources = source.Table.init(allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(entry_url, input);
    var parser = try stylus.Parser.init(allocator, &sources, source_id, .{}, .{});
    defer parser.deinit();
    var document = try parser.parse();
    defer document.deinit();
    var transaction = try evaluator.Transaction.init(
        allocator,
        &sources,
        &session,
        .{},
        evaluator_cancellation,
    );
    defer transaction.deinit();
    try stylus_evaluator.evaluateWithOptions(
        &sources,
        &document,
        &transaction,
        options,
        evaluator_limits,
    );
    return transaction.finish(.{ .format = .minified, .source_map = true });
}

fn expectFixtureRejection(
    input: []const u8,
    files: []const FixtureFile,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_source: u32,
    expected_dependencies: usize,
) !void {
    return expectFixtureRejectionWithOptions(
        input,
        files,
        .{},
        .{},
        .{},
        expected_error,
        expected_code,
        expected_message,
        expected_source,
        expected_dependencies,
    );
}

fn expectFixtureRejectionWithOptions(
    input: []const u8,
    files: []const FixtureFile,
    options: stylus_evaluator.Options,
    resolver_limits: resolver.Limits,
    evaluator_limits: stylus_evaluator.Limits,
    expected_error: anyerror,
    expected_code: diagnostics.Code,
    expected_message: []const u8,
    expected_source: u32,
    expected_dependencies: usize,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("root");
    var root_dir = try temporary.dir.openDir("root", .{});
    defer root_dir.close();
    try root_dir.writeFile(.{ .sub_path = "input.styl", .data = input });
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try root_dir.makePath(parent);
        try root_dir.writeFile(.{ .sub_path = file.path, .data = file.contents });
    }

    const base = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "root" });
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "input.styl" },
    );
    defer std.testing.allocator.free(entry_path);
    const entry_url = try resolver.pathToFileUrl(std.testing.allocator, entry_path);
    defer std.testing.allocator.free(entry_url);

    var authority = try resolver.Resolver.init(
        std.testing.allocator,
        &.{root},
        resolver_limits,
    );
    defer authority.deinit();
    var session = authority.createSession(std.testing.allocator, .{});
    defer session.deinit();
    var sources = source.Table.init(std.testing.allocator, .{});
    defer sources.deinit();
    const source_id = try sources.add(entry_url, input);
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
        stylus_evaluator.evaluateWithOptions(
            &sources,
            &document,
            &transaction,
            options,
            evaluator_limits,
        ),
    );
    try std.testing.expectEqual(
        evaluator.GeneratedPosition{ .line = 0, .column = 0 },
        transaction.position(),
    );
    try std.testing.expectEqual(expected_dependencies, session.dependencies().len);
    try std.testing.expectEqual(@as(usize, 1), transaction.diagnostics().len);
    try std.testing.expectEqual(expected_code, transaction.diagnostics()[0].code);
    try std.testing.expectEqualStrings(expected_message, transaction.diagnostics()[0].message);
    try std.testing.expectEqual(
        expected_source,
        transaction.diagnostics()[0].span.source.value,
    );
    try std.testing.expectError(
        error.SessionFailed,
        transaction.finish(.{ .format = .minified, .source_map = true }),
    );
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

test "native Stylus evaluates explicit CSS nested selectors deterministically" {
    const input =
        \\body {
        \\  margin: 0;
        \\  ul {
        \\    margin: 0;
        \\    li:first-child { border-top: none; }
        \\  }
        \\}
        \\ul { li { &:first-child, &:last-child { display: none; } } }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{margin:0}body ul{margin:0}body ul li:first-child{border-top:none}" ++
            "ul li:first-child,ul li:last-child{display:none}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus normalizes explicit brace whitespace without flattening indentation owners" {
    const input =
        \\body {
        \\     padding: 5px;
        \\  margin: 0;
        \\  article
        \\    color: red;
        \\}
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{padding:5px;margin:0}body article{color:#f00}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
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

test "native Stylus imports require a confined source identity" {
    try expectSemanticRejection(
        "@require 'theme'\n.safe { color: red; }\n",
        error.InvalidImport,
        .invalid_import,
        "native Stylus import load was rejected",
        0,
    );
}

test "native Stylus closes confined import require glob dependency and map semantics" {
    const input =
        \\@import "tokens"
        \\@import "parts/**/*"
        \\@require "once"
        \\@require "once"
        \\@import "bundle"
        \\.card
        \\  width spacing
    ;
    const files = [_]FixtureFile{
        .{ .path = "tokens.styl", .contents = "spacing = 4px\n.tokens\n  order 0\n" },
        .{ .path = "parts/b.styl", .contents = ".glob-b\n  order 2\n" },
        .{ .path = "parts/a.styl", .contents = ".glob-a\n  order 1\n" },
        .{ .path = "parts/nested/c.styl", .contents = ".glob-c\n  order 3\n" },
        .{ .path = "once.styl", .contents = ".once\n  order 4\n" },
        .{ .path = "bundle/index.styl", .contents = ".indexed\n  order 5\n" },
    };
    var first = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        .{},
        .{},
    );
    defer first.deinit();
    var second = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        .{},
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".tokens{order:0}.glob-a{order:1}.glob-b{order:2}.glob-c{order:3}" ++
            ".once{order:4}.indexed{order:5}.card{width:4px}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqual(@as(usize, 6), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 6), first.edges().len);
    for (first.dependencies()) |dependency| {
        try std.testing.expectEqual(resolver.DependencyKind.import, dependency.kind);
        try std.testing.expect(std.mem.endsWith(u8, dependency.url, ".styl"));
    }
    try std.testing.expect(first.map() != null);
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 6);
}

test "native Stylus clones callable dynamic imports for each invocation" {
    const input =
        \\load(path)
        \\  @import path
        \\load('parts/a')
        \\load('parts/b')
    ;
    const files = [_]FixtureFile{
        .{
            .path = "parts/a.styl",
            .contents = ".a\n  color red\n@import \"shared\"\n",
        },
        .{
            .path = "parts/b.styl",
            .contents = ".b\n  color green\n@import \"shared\"\n",
        },
        .{ .path = "parts/shared.styl", .contents = ".shared\n  color blue\n" },
    };
    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 4;
    var result = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        .{},
        terminal,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".a{color:#f00}.shared{color:#00f}" ++
            ".b{color:#008000}.shared{color:#00f}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 3), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, 4), result.edges().len);
    try std.testing.expect(result.map() != null);

    var over_limit = terminal;
    over_limit.max_selectors = 3;
    try std.testing.expectError(
        error.SelectorLimitExceeded,
        compileFixture(
            std.testing.allocator,
            input,
            &files,
            .{},
            over_limit,
        ),
    );
}

test "native Stylus include CSS option owns nested imports and resource boundaries" {
    var preserved = try compileFixture(
        std.testing.allocator,
        "@import \"theme.css\"\n",
        &.{},
        .{},
        .{},
    );
    defer preserved.deinit();
    try std.testing.expectEqualStrings("@import \"theme.css\";", preserved.css());
    try std.testing.expectEqual(@as(usize, 0), preserved.dependencies().len);

    const input = "@import \"chain/a\"\n";
    const files = [_]FixtureFile{
        .{ .path = "chain/a.styl", .contents = "@import \"nested/b\"\n" },
        .{ .path = "chain/nested/b.styl", .contents = "@import \"c.css\"\n" },
        .{
            .path = "chain/nested/c.css",
            .contents = ".c { height: 100px; background: #fff; }\n",
        },
    };
    var terminal = resolver.Limits{};
    terminal.max_files = files.len;
    var first = try compileFixtureWithOptions(
        std.testing.allocator,
        input,
        &files,
        .{ .include_css = true },
        terminal,
        .{},
    );
    defer first.deinit();
    var second = try compileFixtureWithOptions(
        std.testing.allocator,
        input,
        &files,
        .{ .include_css = true },
        terminal,
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".c{height:100px;background:#fff}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, files.len), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), first.edges().len);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_files = files.len - 1;
    try std.testing.expectError(
        error.FileCountExceeded,
        compileFixtureWithOptions(
            std.testing.allocator,
            input,
            &files,
            .{ .include_css = true },
            over_limit,
            .{},
        ),
    );
    try expectFixtureRejectionWithOptions(
        \\.before
        \\  color red
        \\@import "missing.css"
    ,
        &.{},
        .{ .include_css = true },
        .{},
        .{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import was not found",
        0,
        0,
    );
}

test "native Stylus dotted import basenames retain optional extension through property callables" {
    const vendor = FixtureFile{
        .path = "import.include.function/import.vendor.styl",
        .contents =
        \\border-radius()
        \\  -moz-border-radius: arguments
        \\  -webkit-border-radius: arguments
        \\  border-radius: arguments
        ,
    };
    const lower_input =
        \\@import 'import.include.function/import.vendor'
        \\$radius = 10
        \\body
        \\  border-radius: ($radius / 2)px
    ;
    var lower_resolver = resolver.Limits{};
    lower_resolver.max_files = 1;
    var call_terminal = stylus_evaluator.Limits{};
    call_terminal.max_call_depth = 1;
    var lower = try compileFixture(
        std.testing.allocator,
        lower_input,
        &.{vendor},
        lower_resolver,
        call_terminal,
    );
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "body{-moz-border-radius:5px;-webkit-border-radius:5px;border-radius:5px}",
        lower.css(),
    );

    const terminal_input =
        \\@import 'import.include.function/import.vendor'
        \\@import 'import.include.function/import.common'
        \\$radius = 10
        \\body
        \\  border-radius: ($radius / 2)px
    ;
    const files = [_]FixtureFile{
        vendor,
        .{
            .path = "import.include.function/import.common.styl",
            .contents = "body\n  color red\n",
        },
    };
    var terminal_resolver = resolver.Limits{};
    terminal_resolver.max_files = files.len;
    var first = try compileFixture(
        std.testing.allocator,
        terminal_input,
        &files,
        terminal_resolver,
        call_terminal,
    );
    defer first.deinit();
    var second = try compileFixture(
        std.testing.allocator,
        terminal_input,
        &files,
        terminal_resolver,
        call_terminal,
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{color:#f00}body{-moz-border-radius:5px;" ++
            "-webkit-border-radius:5px;border-radius:5px}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, files.len), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), first.edges().len);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal_resolver;
    over_limit.max_files = files.len - 1;
    try expectFixtureRejectionWithOptions(
        terminal_input,
        &files,
        .{},
        over_limit,
        call_terminal,
        error.FileCountExceeded,
        .resource_limit,
        "native Stylus import resource limit exceeded",
        0,
        1,
    );
}

test "native Stylus import lookup owns bounded directory and package resolution" {
    const directory_file = FixtureFile{
        .path = "lookup-a/lookup-a.styl",
        .contents = "body\n  content 'a'\n",
    };
    var lower_limits = resolver.Limits{};
    lower_limits.max_files = 1;
    var lower = try compileFixture(
        std.testing.allocator,
        "@import 'lookup-a'\n",
        &.{directory_file},
        lower_limits,
        .{},
    );
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{content:'a'}", lower.css());
    try std.testing.expectEqual(@as(usize, 1), lower.dependencies().len);
    try std.testing.expectEqual(resolver.DependencyKind.import, lower.dependencies()[0].kind);

    const input =
        \\@import 'lookup-a'
        \\@import 'lookup-b'
        \\@import 'lookup-c'
    ;
    const files = [_]FixtureFile{
        directory_file,
        .{
            .path = "node_modules/lookup-b/package.json",
            .contents = "{\n  \"main\": \"test.styl\"\n}\n",
        },
        .{
            .path = "node_modules/lookup-b/test.styl",
            .contents = "body\n  content 'b'\n",
        },
        .{
            .path = "node_modules/lookup-c.styl/index.styl",
            .contents = "body\n  content 'c'\n",
        },
    };
    var terminal_limits = resolver.Limits{};
    terminal_limits.max_files = files.len;
    var first = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_limits,
        .{},
    );
    defer first.deinit();
    var second = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_limits,
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{content:'a'}body{content:'b'}body{content:'c'}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, files.len), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), first.edges().len);
    try std.testing.expectEqual(resolver.DependencyKind.import, first.dependencies()[0].kind);
    try std.testing.expectEqual(resolver.DependencyKind.reference, first.dependencies()[1].kind);
    try std.testing.expectEqual(resolver.DependencyKind.import, first.dependencies()[2].kind);
    try std.testing.expectEqual(resolver.DependencyKind.import, first.dependencies()[3].kind);
    try std.testing.expect(std.mem.endsWith(
        u8,
        first.dependencies()[1].url,
        "/node_modules/lookup-b/package.json",
    ));
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 3);

    var over_limit = terminal_limits;
    over_limit.max_files = files.len - 1;
    try expectFixtureRejectionWithOptions(
        input,
        &files,
        .{},
        over_limit,
        .{},
        error.FileCountExceeded,
        .resource_limit,
        "native Stylus import resource limit exceeded",
        0,
        files.len - 1,
    );
    try expectFixtureRejection(
        \\.before
        \\  color red
        \\@import 'invalid-package'
    ,
        &.{.{
            .path = "node_modules/invalid-package/package.json",
            .contents = "{\"main\":\"https://example.invalid/theme.styl\"}\n",
        }},
        error.InvalidImport,
        .invalid_import,
        "native Stylus package manifest is invalid",
        0,
        1,
    );
}

test "native Stylus computed top-level imports preserve source ordering and bounds" {
    const two = FixtureFile{
        .path = "import.ordering/two.styl",
        .contents = "two\n  foo bar\n",
    };
    var lower_limits = resolver.Limits{};
    lower_limits.max_files = 1;
    var lower = try compileFixture(
        std.testing.allocator,
        "dir = 'import.ordering'\n@import dir + \"/two\"\n",
        &.{two},
        lower_limits,
        .{},
    );
    defer lower.deinit();
    try std.testing.expectEqualStrings("two{foo:bar}", lower.css());
    try std.testing.expectEqual(@as(usize, 1), lower.dependencies().len);
    try std.testing.expectEqual(@as(usize, 1), lower.edges().len);

    const input =
        \\dir = 'import.ordering'
        \\one
        \\  foo bar
        \\@import dir + "/two"
        \\three
        \\  foo bar
        \\@import dir + '/four'
    ;
    const files = [_]FixtureFile{
        two,
        .{
            .path = "import.ordering/four.styl",
            .contents = "four\n  foo bar\n@import \"import.ordering/five\"\n",
        },
        .{
            .path = "import.ordering/five.styl",
            .contents = "five\n  foo bar\n",
        },
    };
    var terminal_limits = resolver.Limits{};
    terminal_limits.max_files = files.len;
    var first = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_limits,
        .{},
    );
    defer first.deinit();
    var second = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_limits,
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "one{foo:bar}two{foo:bar}three{foo:bar}four{foo:bar}five{foo:bar}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, files.len), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), first.edges().len);
    for ([_][]const u8{ "two.styl", "four.styl", "five.styl" }, 0..) |basename, index| {
        try std.testing.expectEqual(resolver.DependencyKind.import, first.dependencies()[index].kind);
        try std.testing.expectEqualStrings(basename, std.fs.path.basename(first.dependencies()[index].url));
    }
    try std.testing.expectEqualStrings("input.styl", std.fs.path.basename(first.edges()[0].parent_url.?));
    try std.testing.expectEqualStrings("input.styl", std.fs.path.basename(first.edges()[1].parent_url.?));
    try std.testing.expectEqualStrings("four.styl", std.fs.path.basename(first.edges()[2].parent_url.?));
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    var imported_segments: usize = 0;
    for (first.map().?.segments()) |segment| {
        if (segment.source_id) |source_id| {
            imported_segments += @intFromBool(source_id.value != 0);
        }
    }
    try std.testing.expect(imported_segments >= 3);

    var over_limit = terminal_limits;
    over_limit.max_files = files.len - 1;
    try expectFixtureRejectionWithOptions(
        input,
        &files,
        .{},
        over_limit,
        .{},
        error.FileCountExceeded,
        .resource_limit,
        "native Stylus import resource limit exceeded",
        2,
        files.len - 1,
    );
}

test "native Stylus callable dynamic imports fail closed outside their bounded contract" {
    const escaped =
        \\.before
        \\  color red
        \\load(path)
        \\  @import path
        \\load('../outside')
    ;
    try expectFixtureRejection(
        escaped,
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import load was rejected",
        0,
        0,
    );

    const non_string =
        \\.before
        \\  color red
        \\load(path)
        \\  @import path
        \\load(1px)
    ;
    try expectFixtureRejection(
        non_string,
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import target is invalid",
        0,
        0,
    );

    const nested =
        \\.before
        \\  color red
        \\load(path)
        \\  @import path
        \\.scope
        \\  load('part')
    ;
    try expectFixtureRejection(
        nested,
        &.{.{ .path = "part.styl", .contents = ".loaded\n  color blue\n" }},
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus evaluated imports require a top-level evaluation context",
        0,
        0,
    );

    const semantic_import =
        \\.before
        \\  color red
        \\load(path)
        \\  @import path
        \\load('semantic')
    ;
    try expectFixtureRejection(
        semantic_import,
        &.{.{
            .path = "semantic.styl",
            .contents = "tone = red\n.dynamic\n  color tone\n",
        }},
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus evaluated import requires an isolated rule closure",
        0,
        1,
    );
}

test "native Stylus import failures own source diagnostics without partial CSS" {
    try expectFixtureRejection(
        "@import \"missing\"\n.safe\n  color red\n",
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import was not found",
        0,
        0,
    );
    try expectFixtureRejection(
        "@import \"bad\"\n.safe\n  color red\n",
        &.{.{ .path = "bad.styl", .contents = ".bad\n  width (\n" }},
        error.InvalidSyntax,
        .syntax,
        "expected a closing delimiter before EOF",
        1,
        1,
    );
    try expectFixtureRejection(
        "@import \"a\"\n.safe\n  color red\n",
        &.{.{ .path = "a.styl", .contents = "@import \"input\"\n.a\n  color blue\n" }},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import cycle detected",
        1,
        1,
    );
    try expectFixtureRejection(
        "@require \"https://example.invalid/theme.styl\"\n",
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import syntax is unsupported",
        0,
        0,
    );
    try expectFixtureRejection(
        "@import \"../outside/escape\"\n",
        &.{},
        error.InvalidImport,
        .invalid_import,
        "native Stylus import load was rejected",
        0,
        0,
    );
}

const ResolverCancelContext = struct {
    target: resolver.Checkpoint,
    calls: usize = 0,

    fn check(context: *anyopaque, checkpoint: resolver.Checkpoint) bool {
        const self: *ResolverCancelContext = @ptrCast(@alignCast(context));
        self.calls += 1;
        return checkpoint == self.target;
    }
};

test "native Stylus imports own terminal depth count byte and cancellation boundaries" {
    const chain_files = [_]FixtureFile{
        .{ .path = "a.styl", .contents = "@import \"b\"\n.a\n  order 1\n" },
        .{ .path = "b.styl", .contents = ".b\n  order 2\n" },
    };
    var terminal_depth = resolver.Limits{};
    terminal_depth.max_depth = 3;
    var depth_result = try compileFixture(
        std.testing.allocator,
        "@import \"a\"\n",
        &chain_files,
        terminal_depth,
        .{},
    );
    defer depth_result.deinit();
    try std.testing.expectEqualStrings(".b{order:2}.a{order:1}", depth_result.css());

    var over_depth = terminal_depth;
    over_depth.max_depth = 2;
    try std.testing.expectError(
        error.DepthLimitExceeded,
        compileFixture(
            std.testing.allocator,
            "@import \"a\"\n",
            &chain_files,
            over_depth,
            .{},
        ),
    );

    const input =
        \\@import "tokens"
        \\@import "parts/**/*"
        \\@require "once"
        \\@require "once"
    ;
    const files = [_]FixtureFile{
        .{ .path = "tokens.styl", .contents = ".tokens\n  order 0\n" },
        .{ .path = "parts/b.styl", .contents = ".b\n  order 2\n" },
        .{ .path = "parts/a.styl", .contents = ".a\n  order 1\n" },
        .{ .path = "parts/nested/c.styl", .contents = ".c\n  order 3\n" },
        .{ .path = "once.styl", .contents = ".once\n  order 4\n" },
    };
    var terminal_count = resolver.Limits{};
    terminal_count.max_files = files.len;
    var count_result = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_count,
        .{},
    );
    defer count_result.deinit();
    try std.testing.expectEqual(files.len, count_result.dependencies().len);

    var over_count = terminal_count;
    over_count.max_files = files.len - 1;
    try std.testing.expectError(
        error.FileCountExceeded,
        compileFixture(std.testing.allocator, input, &files, over_count, .{}),
    );

    var total_bytes: usize = files[files.len - 1].contents.len;
    for (files) |file| total_bytes += file.contents.len;
    var terminal_bytes = resolver.Limits{};
    terminal_bytes.max_total_bytes = total_bytes;
    var byte_result = try compileFixture(
        std.testing.allocator,
        input,
        &files,
        terminal_bytes,
        .{},
    );
    defer byte_result.deinit();
    try std.testing.expectEqual(@as(u64, @intCast(total_bytes)), byte_result.stats().bytes);

    var over_bytes = terminal_bytes;
    over_bytes.max_total_bytes -= 1;
    try std.testing.expectError(
        error.TotalLimitExceeded,
        compileFixture(std.testing.allocator, input, &files, over_bytes, .{}),
    );

    var cancel_context = ResolverCancelContext{ .target = .read };
    try std.testing.expectError(
        error.Cancelled,
        compileFixtureWithCancellation(
            std.testing.allocator,
            input,
            &files,
            .{},
            .{},
            .{ .context = &cancel_context, .check_fn = ResolverCancelContext.check },
            .{},
        ),
    );
    try std.testing.expect(cancel_context.calls > 0);
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

test "native Stylus compressed numbers retain the finite provider unit exclusions" {
    const input =
        \\body
        \\  removable-zero 0px
        \\  percentage-zero 0%
        \\  seconds-zero 0s
        \\  milliseconds-zero 0ms
        \\  degrees-zero 0deg
        \\  fraction-zero 0fr
        \\  positive-fraction 0.1
        \\  negative-fraction -0.1
        \\  positive-boundary 1.1
        \\  negative-boundary -1.1
        \\  joined join(',', 0.1px 0px)
    ;
    var expanded = try compile(std.testing.allocator, input, .{});
    defer expanded.deinit();
    var compressed = try compileWithOptions(
        std.testing.allocator,
        input,
        .{ .output_style = .compressed },
        .{},
    );
    defer compressed.deinit();

    try std.testing.expectEqualStrings(
        "body{removable-zero:0px;percentage-zero:0%;seconds-zero:0s;" ++
            "milliseconds-zero:0ms;degrees-zero:0deg;fraction-zero:0fr;" ++
            "positive-fraction:0.1;negative-fraction:-0.1;" ++
            "positive-boundary:1.1;negative-boundary:-1.1;joined:'0.1px,0px'}",
        expanded.css(),
    );
    try std.testing.expectEqualStrings(
        "body{removable-zero:0;percentage-zero:0%;seconds-zero:0s;" ++
            "milliseconds-zero:0ms;degrees-zero:0deg;fraction-zero:0fr;" ++
            "positive-fraction:.1;negative-fraction:-.1;" ++
            "positive-boundary:1.1;negative-boundary:-1.1;joined:'0.1px,0px'}",
        compressed.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), expanded.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), compressed.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), expanded.dependencies().len);
    try std.testing.expectEqual(@as(usize, 0), compressed.dependencies().len);
}

test "native Stylus applies the finite selector scope directive" {
    const input =
        \\@scope #sidebar
        \\h2
        \\  color red
        \\a
        \\  &:hover
        \\    color pink
        \\@scope body.signup-page[attr='foo']
        \\& .container
        \\  color red
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "#sidebar h2{color:#f00}#sidebar a:hover{color:#ffc0cb}" ++
            "body.signup-page[attr=\"foo\"] .container{color:#f00}",
        compiled.css(),
    );
}

test "native Stylus evaluates whitespace-separated selector interpolation deterministically" {
    const input =
        \\pos = last
        \\form {'input'}:nth-child({10 + 5}) { display: none; }
        \\body {form} {
        \\  input:{pos}-child { display: none; }
        \\}
        \\{foo} {bar} { foo: bar; }
        \\.plain { color red }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "form input:nth-child(15){display:none}" ++
            "body form input:last-child{display:none}" ++
            "foo bar{foo:bar}.plain{color:#f00}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus evaluates finite color component getters" {
    const input =
        \\body
        \\  background red(#fc0)
        \\  background green(#fc0)
        \\  background blue(#fc0)
        \\  background alpha(#fff - rgba(0,0,0,.6))
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{background:255;background:204;background:0;background:0.4}",
        compiled.css(),
    );
}

test "native Stylus preserves relative saturation endpoints alpha and CSS fallbacks" {
    const input =
        \\body
        \\  saturate-lower saturate(#ee0, 0%)
        \\  saturate-terminal saturate(#fd0cc7, 100%)
        \\  saturate-alpha saturate(rgba(35,124,46,0.5), 80%)
        \\  desaturate-lower desaturate(#ee0, 0%)
        \\  desaturate-terminal desaturate(#fd0cc7, 100%)
        \\  desaturate-alpha desaturate(rgba(35,124,46,0.5), 80%)
        \\  filter-empty saturate()
        \\  filter-amount saturate(100%)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{saturate-lower:#ee0;saturate-terminal:#f0f;" ++
            "saturate-alpha:rgba(0,160,19,0.5);desaturate-lower:#ee0;" ++
            "desaturate-terminal:#858585;desaturate-alpha:rgba(71,88,73,0.5);" ++
            "filter-empty:saturate();filter-amount:saturate(100%)}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), compiled.dependencies().len);
    try std.testing.expect(compiled.map() != null);
}

test "native Stylus reflects composes and lists selector identity" {
    const input =
        \\.foo
        \\  .bar
        \\    current: selector()
        \\    explicit: selector('&:focus')
        \\    root: selector('^[0]:active')
        \\    parent: selector('../:hover')
        \\.foo,
        \\.bar
        \\  list: selector('&:hover, &:active')
        \\  absolute: selector('li a')
        \\wrap()
        \\  {selector()}
        \\    inside: selector('&__item')
        \\.host
        \\  wrap()
        \\selector-list = '.a', '.b', '.c, .d'
        \\{selector(selector-list)}
        \\  terminal: selector()
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".foo .bar{current:'.foo .bar';explicit:'.foo .bar:focus';" ++
            "root:'.foo:active';parent:'.foo:hover'}" ++
            ".foo,.bar{list:'.foo:hover,.bar:hover,.foo:active,.bar:active';" ++
            "absolute:'li a'}" ++
            ".host .host{inside:'.host .host__item'}" ++
            ".a .b .c,.a .b .d{terminal:'.a .b .c,.a .b .d'}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const invalid =
        \\.probe
        \\  value: selector(1)
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "selector").?),
    );
}

test "native Stylus queries previously evaluated selector identity" {
    const input =
        \\$test
        \\  a
        \\    color red
        \\class
        \\  if selector-exists($test a)
        \\    color #fff
        \\  if selector-exists('$test')
        \\    border #fff
        \\  if selector-exists('$test li')
        \\    font-size 12px
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "class{color:#fff;border:#fff}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const lower =
        \\class
        \\  if selector-exists()
        \\    color red
    ;
    try expectSemanticRejection(
        lower,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, lower, "if selector-exists").?),
    );

    const over =
        \\class
        \\  if selector-exists('class', '$test')
        \\    color red
    ;
    try expectSemanticRejection(
        over,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, over, "if selector-exists").?),
    );
}

test "native Stylus reconstructs transparent colors over bounded backdrops" {
    const input =
        \\body
        \\  default-white transparentify(#fff)
        \\  default-black transparentify(#000)
        \\  inferred transparentify(#808080)
        \\  backdrop transparentify(#808080, #000)
        \\  overload-unitless transparentify(#808080, .7)
        \\  explicit-percent transparentify(#808080, #000, 70%)
        \\  explicit-hsl transparentify(hsla(200,40%,40%,.3), hsla(200,0%,100%,1))
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{default-white:rgba(255,255,255,0);default-black:#000;" ++
            "inferred:rgba(0,0,0,0.5);backdrop:rgba(255,255,255,0.5);" ++
            "overload-unitless:rgba(74,74,74,0.7);" ++
            "explicit-percent:rgba(183,183,183,0.7);" ++
            "explicit-hsl:rgba(0,72,108,0.76)}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const missing_top =
        \\body
        \\  value transparentify()
    ;
    try expectSemanticRejection(
        missing_top,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, missing_top, "transparentify").?),
    );

    const invalid_backdrop =
        \\body
        \\  value transparentify(#fff, nope)
    ;
    try expectSemanticRejection(
        invalid_backdrop,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid_backdrop, "transparentify").?),
    );

    const invalid_alpha =
        \\body
        \\  value transparentify(#fff, #000, nope)
    ;
    try expectSemanticRejection(
        invalid_alpha,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid_alpha, "transparentify").?),
    );
}

test "native Stylus evaluates URL expressions without loading assets" {
    const input =
        \\brown = #462323
        \\body
        \\  empty url()
        \\  tokens url(foo bar)
        \\  commas url(foo, bar)
        \\  background url("/images/foo.png")
        \\  background url(/images/foo.png)
        \\  dir = '/images'
        \\  img = 'foo.png'
        \\  background url(dir/foo.png)
        \\  background url(dir/img)
        \\  background url('/images/' + img)
        \\  background url(dir'/foo.png')
        \\  background url(dir + '/foo.png')
        \\  background url(dir + '/' + img)
        \\  list = foo bar
        \\  background url('/images/' + list[0] + '.png')
        \\  background url(http://foo.com/images/bar.png)
        \\  background url(//foo.com/images/bar.png)
        \\  background url(/some/brown/white/icon.png)
        \\  color brown
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{empty:url(\"\");tokens:url(\"foobar\");commas:url(\"foo,bar\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"/images/foo.png\");" ++
            "background:url(\"http://foo.com/images/bar.png\");" ++
            "background:url(\"//foo.com/images/bar.png\");" ++
            "background:url(\"/some/brown/white/icon.png\");color:#462323}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

fn exerciseEmbeddedUrlAllocationFailures(allocator: std.mem.Allocator) !void {
    const asset = "<svg id=\"#x\">\n</svg>\n";
    const files = [_]FixtureFile{.{ .path = "tiny.svg", .contents = asset }};
    const input =
        \\.asset
        \\  background embedurl('tiny.svg#icon')
    ;
    var result = try compileFixture(allocator, input, &files, .{}, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".asset{background:url(\"data:image/svg+xml;base64," ++
            "PHN2ZyBpZD0iI3giPgo8L3N2Zz4K#icon\")}",
        result.css(),
    );
}

test "native Stylus embeds confined URL assets across the provider byte bound" {
    const asset = "<svg id=\"#x\">\n</svg>\n";
    const files = [_]FixtureFile{.{ .path = "tiny.svg", .contents = asset }};
    const input =
        \\.base64
        \\  background embedurl('tiny.svg')
        \\.fragment
        \\  background embedurl('tiny.svg#icon')
        \\.utf8
        \\  background embedurl('tiny.svg', 'utf8')
        \\.query
        \\  background embedurl('tiny.svg?v=1#query')
    ;
    var first = try compileFixture(std.testing.allocator, input, &files, .{}, .{});
    defer first.deinit();
    var second = try compileFixture(std.testing.allocator, input, &files, .{}, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".base64{background:url(\"data:image/svg+xml;base64," ++
            "PHN2ZyBpZD0iI3giPgo8L3N2Zz4K\")}" ++
            ".fragment{background:url(\"data:image/svg+xml;base64," ++
            "PHN2ZyBpZD0iI3giPgo8L3N2Zz4K#icon\")}" ++
            ".utf8{background:url(\"data:image/svg+xml;charset=utf-8," ++
            "%3Csvg id=%22%23x%22%3E %3C/svg%3E\")}" ++
            ".query{background:url(\"data:image/svg+xml;base64," ++
            "PHN2ZyBpZD0iI3giPgo8L3N2Zz4K#query\")}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 1), first.dependencies().len);
    try std.testing.expectEqual(@as(usize, 1), first.edges().len);
    try std.testing.expectEqual(resolver.DependencyKind.reference, first.dependencies()[0].kind);
    try std.testing.expectEqualStrings("tiny.svg", std.fs.path.basename(first.dependencies()[0].url));

    var terminal_asset: [30_000]u8 = undefined;
    @memset(terminal_asset[0..], 'a');
    const terminal_files = [_]FixtureFile{.{
        .path = "terminal.svg",
        .contents = terminal_asset[0..],
    }};
    const terminal_input = "body\n  background embedurl('terminal.svg')\n";
    var terminal = try compileFixture(
        std.testing.allocator,
        terminal_input,
        &terminal_files,
        .{},
        .{},
    );
    defer terminal.deinit();
    const terminal_prefix = "body{background:url(\"data:image/svg+xml;base64,";
    const terminal_suffix = "\")}";
    try std.testing.expect(std.mem.startsWith(u8, terminal.css(), terminal_prefix));
    try std.testing.expect(std.mem.endsWith(u8, terminal.css(), terminal_suffix));
    try std.testing.expectEqual(
        terminal_prefix.len + std.base64.standard.Encoder.calcSize(terminal_asset.len) +
            terminal_suffix.len,
        terminal.css().len,
    );
    try std.testing.expectEqual(@as(u64, terminal_asset.len), terminal.stats().bytes);
    try std.testing.expectEqual(@as(usize, 1), terminal.dependencies().len);

    var over_limit_asset: [30_001]u8 = undefined;
    @memset(over_limit_asset[0..], 'a');
    const over_limit_files = [_]FixtureFile{.{
        .path = "over-limit.svg",
        .contents = over_limit_asset[0..],
    }};
    const over_limit_input = "body\n  background embedurl('over-limit.svg')\n";
    var over_limit = try compileFixture(
        std.testing.allocator,
        over_limit_input,
        &over_limit_files,
        .{},
        .{},
    );
    defer over_limit.deinit();
    try std.testing.expectEqualStrings(
        "body{background:url(\"over-limit.svg\")}",
        over_limit.css(),
    );
    try std.testing.expectEqual(@as(u64, over_limit_asset.len), over_limit.stats().bytes);
    try std.testing.expectEqual(@as(usize, 1), over_limit.dependencies().len);

    var remote = try compile(
        std.testing.allocator,
        "body\n  background embedurl('https://example.invalid/asset.svg')\n",
        .{},
    );
    defer remote.deinit();
    try std.testing.expectEqualStrings(
        "body{background:url(\"https://example.invalid/asset.svg\")}",
        remote.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), remote.dependencies().len);

    var missing = try compile(
        std.testing.allocator,
        "body\n  background embedurl('missing.svg')\n",
        .{},
    );
    defer missing.deinit();
    try std.testing.expectEqualStrings(
        "body{background:url(\"missing.svg\")}",
        missing.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), missing.dependencies().len);

    try expectFixtureRejection(
        "body\n  background embedurl('../escape.svg')\n",
        &.{},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus image asset load was rejected",
        0,
        0,
    );
    try expectFixtureRejection(
        "body\n  background embedurl('invalid.svg', 'utf8')\n",
        &.{.{ .path = "invalid.svg", .contents = "\xff" }},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus embedded URL asset is not valid UTF-8",
        0,
        1,
    );
}

test "native Stylus embedded URL transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEmbeddedUrlAllocationFailures,
        .{},
    );
}

test "native Stylus evaluates compact declaration values inside explicit CSS blocks" {
    const input =
        \\body {background:white;font-size:.8em;background-image:url(src/grid.png);border-color:#e5eCf9;quotes:"" "";content:'';font-family:"Helvetica Neue",Arial;}
    ;
    var first = try compileWithOptions(
        std.testing.allocator,
        input,
        .{ .output_style = .expanded },
        .{},
    );
    defer first.deinit();
    var second = try compileWithOptions(
        std.testing.allocator,
        input,
        .{ .output_style = .expanded },
        .{},
    );
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{background:#fff;font-size:0.8em;background-image:url(\"src/grid.png\");" ++
            "border-color:#e5ecf9;quotes:\"\" \"\";content:'';" ++
            "font-family:\"Helvetica Neue\", Arial}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const invalid =
        \\vendors = 1
        \\@keyframes pulse
        \\  from
        \\    color red
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "@keyframes").?),
    );
}

test "native Stylus keyframe steps preserve the finite empty block contract" {
    var first = try compile(std.testing.allocator, keyframe_semantic_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, keyframe_semantic_input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(keyframe_semantic_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus keyframe loops own finite lower terminal and over-limit boundaries" {
    const lower_input =
        \\vendors = official
        \\for index in 1..1
        \\  @keyframes {'pulse' + index}
        \\    from
        \\      opacity index
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_loop_iterations = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "@keyframes pulse1{from{opacity:1}}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 3;
    var first = try compile(std.testing.allocator, keyframe_loop_terminal_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, keyframe_loop_terminal_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(keyframe_loop_terminal_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_loop_iterations = 2;
    try expectSemanticRejectionWithLimits(
        keyframe_loop_terminal_input,
        over_limit,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, keyframe_loop_terminal_input, "for index").?),
    );
}

test "native Stylus preserves nested rules beside compact mixin declarations" {
    const input =
        \\hover()
        \\  &:hover { color: white; background: black;
        \\    em {
        \\      color: gray;
        \\    }
        \\  }
        \\  &:active { color: black; background: white; }
        \\button(pad)
        \\  button,
        \\  a.button,
        \\  input[type=submit],
        \\  input[type=button] { padding: pad; hover(); }
        \\button(5px 10px);
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "button,a.button,input[type=submit],input[type=button]{padding:5px 10px}" ++
            "button:hover,a.button:hover,input[type=submit]:hover,input[type=button]:hover{" ++
            "color:#fff;background:#000}" ++
            "button:hover em,a.button:hover em,input[type=submit]:hover em," ++
            "input[type=button]:hover em{color:#808080}" ++
            "button:active,a.button:active,input[type=submit]:active," ++
            "input[type=button]:active{color:#000;background:#fff}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus treats top-level property slashes as CSS separators" {
    const input =
        \\size = 14px
        \\height = 1.4
        \\body { font: size / height "Helvetica Neue", Arial; ratio: ((14px) / (2)); path: url(a/b); tokens: foo / bar; }
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{font:14px/1.4 \"Helvetica Neue\", Arial;ratio:7px;" ++
            "path:url(\"a/b\");tokens:foo/bar}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus preserves finite declaration comment boundaries" {
    const input =
        \\/*
        \\.hidden
        \\  color blue
        \\*/
        \\.probe
        \\  font-family: "DIN Alternate"
        \\  background: // ignored,
        \\    url("img.png") 8px 8px no-repeat,
        \\    rgba(0, 0, 0, .41)
        \\  shadow: 1px 0 0 white, /* keep */ 2px 0 0 black
        \\  sources: url("a") format("x"), /* dropped */
        \\           url("b") format("y") /* terminal */
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        ".probe{font-family:\"DIN Alternate\";" ++
            "background:url(\"img.png\") 8px 8px no-repeat, rgba(0,0,0,0.41);" ++
            "shadow:1px 0 0 #fff, /* keep */ 2px 0 0 #000;" ++
            "sources:url(\"a\") format(\"x\"), url(\"b\") format(\"y\") /* terminal */}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus evaluates the finite contrast result object and CSS fallback" {
    const input =
        \\.probe
        \\  test1: contrast(#000).ratio
        \\  test2: contrast(rgba(#000,.5), #fff).ratio
        \\  test3: contrast(#000, rgba(#fff,.5)).ratio
        \\  test4: contrast(#000, rgba(#fff,.5)).error
        \\  test5: contrast(#000, rgba(#fff,.5)).min
        \\  test6: contrast(#000, rgba(#fff,.5)).max
        \\  test7: contrast(200%, red)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".probe{test1:21;test2:3.9;test3:13.15;test4:7.85;" ++
            "test5:5.3;test6:21;test7:contrast(200%)}",
        compiled.css(),
    );

    const invalid =
        \\.probe
        \\  test1: contrast(#000, 1).ratio
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "contrast").?),
    );
}

test "native Stylus evaluates bounded convert and match builtins" {
    const input =
        \\parsed = match('^(height|width)?([<>=]{1,})(.*)', 'height>=10px')
        \\without-dimension = match('^(height|width)?([<>=]{1,})(.*)', '>400px')
        \\direction = 'min'
        \\.probe
        \\  numeric: convert('1.334em')
        \\  color-type: type(convert('#c00'))
        \\  ident-type: type(convert('something'))
        \\  space-list: convert('10 20 30')
        \\  comma-list: convert('10, 20, 30')
        \\  prefix: match('^pad', 'padding')
        \\  captures: parsed
        \\  operator: parsed[2]
        \\  converted: convert(parsed[3])
        \\  global: match('ain', 'The rain in SPAIN stays mainly in the plain', 'gi')
        \\  invalid-flags: match('ain', 'The rain in SPAIN', 'x')
        \\  fallback: direction + '-' + (without-dimension[1] || 'width')
        \\  operated: operate(direction == 'min' ? '+' : '-', 400px, 1px)
        \\  if match('absent', 'present')
        \\    state: bad
        \\  else
        \\    state: good
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".probe{numeric:1.334em;color-type:'rgba';ident-type:'ident';" ++
            "space-list:10 20 30;comma-list:10, 20, 30;prefix:'pad';" ++
            "captures:'height>=10px' 'height' '>=' '10px';operator:'>=';" ++
            "converted:10px;global:'ain' 'AIN' 'ain' 'ain';" ++
            "invalid-flags:'ain';fallback:'min-width';operated:401px;state:good}",
        compiled.css(),
    );

    const invalid =
        \\.probe
        \\  test: convert(1)
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "convert").?),
    );

    const unsupported_match =
        \\.probe
        \\  test: match('a+', 'aaa')
    ;
    try expectSemanticRejection(
        unsupported_match,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, unsupported_match, "match").?),
    );
}

test "native Stylus join preserves nested lists and HSL string identity" {
    const input =
        \\a = 1 2
        \\b = 3 4
        \\.probe
        \\  nested: join(', ', a b)
        \\  flat: join(',', 1 2 3)
        \\  expression: join(',', 1 + 2)
        \\  colors: join(', ', hsl(0, 0%, 0%), hsla(120, 20%, 80%, 1))
        \\  rgb: join(', ', #fff #000)
        \\  scalar: join(',', 1)
        \\  empty: join(',') == null
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".probe{nested:'1 2, 3 4';flat:'1,2,3';expression:'3';" ++
            "colors:'hsla(0,0%,0%,1), hsla(120,20%,80%,1)';" ++
            "rgb:'#fff, #000';scalar:'1';empty:true}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);

    const invalid =
        \\.probe
        \\  value: join(1, 2)
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "join").?),
    );
}

test "native Stylus length preserves provider scalar list and string semantics" {
    const input =
        \\args(n = null)
        \\  length(n)
        \\
        \\vargs(args...)
        \\  length(args)
        \\
        \\argument-count()
        \\  length(arguments)
        \\
        \\body
        \\  zero length()
        \\  null-value length(null)
        \\  identifier length(foo)
        \\  empty-string length('')
        \\  returned-scalar length(args())
        \\  scalar length(1)
        \\  nested length((1 2) (3 4))
        \\  flat length(1 2 3)
        \\  ascii length("hey")
        \\  bmp length("hé")
        \\  astral length("hé😊")
        \\  rest vargs(1, 2, 3, 4)
        \\  default-list args(1 2 3 4 5)
        \\  implicit argument-count(1, 2, 3, 4, 5, 6)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{zero:0;null-value:1;identifier:1;empty-string:0;" ++
            "returned-scalar:1;scalar:1;nested:2;flat:3;ascii:3;" ++
            "bmp:2;astral:4;rest:4;default-list:5;implicit:6}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);
}

test "native Stylus merge mutates maps with shallow and recursive precedence" {
    const input =
        \\base = {
        \\  first: 1
        \\  shared: 2
        \\  nested: {
        \\    keep: 3
        \\    replace: 4
        \\  }
        \\}
        \\alias = base
        \\merged = merge(base, { shared: 5, nested: { replace: 6, add: 7 } }, { tail: 8 }, true)
        \\shallow = {
        \\  nested: {
        \\    keep: 9
        \\  }
        \\}
        \\extended = extend(shallow, { nested: { replacement: 10 }, added: 11 })
        \\flagged = {
        \\  nested: {
        \\    keep: 12
        \\  }
        \\}
        \\flagged-result = merge(flagged, { nested: { replacement: 13 } }, false)
        \\retained = { value: 14 }
        \\retained-alias = retained
        \\retained-peer = retained
        \\retained = { value: 15 }
        \\merge(retained-alias, { value: 16 })
        \\body
        \\  first merged.first
        \\  shared merged.shared
        \\  nested-keep merged.nested.keep
        \\  nested-replace merged.nested.replace
        \\  nested-add merged.nested.add
        \\  tail merged.tail
        \\  alias alias.shared
        \\  original base.nested.add
        \\  shallow-old shallow.nested.keep == null
        \\  shallow-new shallow.nested.replacement
        \\  added shallow.added
        \\  flag-old flagged.nested.keep == null
        \\  flag-new flagged-result.nested.replacement
        \\  retained-root retained.value
        \\  retained-peer retained-peer.value
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{first:1;shared:5;nested-keep:3;nested-replace:6;" ++
            "nested-add:7;tail:8;alias:5;original:7;shallow-old:true;" ++
            "shallow-new:10;added:11;flag-old:true;flag-new:13;" ++
            "retained-root:15;retained-peer:16}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);

    const invalid =
        \\body
        \\  value merge(1, { a: 1 })
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "merge").?),
    );
}

test "native Stylus invokes a provider-prefixed root block mixin" {
    const input =
        \\wrapper()
        \\  @media print
        \\    {block}
        \\+wrapper()
        \\  body
        \\    color red
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "@media print{body{color:#f00}}",
        compiled.css(),
    );
}

test "native Stylus prefixes class selectors inside a bounded block mixin" {
    const input =
        \\+prefix-classes('pre-')
        \\  .alpha.beta:hover, #identity .gamma
        \\    color red
        \\.host
        \\  +prefix-classes(unquoted-)
        \\    .child
        \\      width 1px
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        ".pre-alpha.pre-beta:hover,#identity .pre-gamma{color:#f00}" ++
            ".host .unquoted-child{width:1px}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);

    const invalid =
        \\+prefix-classes(1)
        \\  .child
        \\    width 1px
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        0,
    );
    try expectSemanticRejection(
        \\+prefix-classes('bad .')
        \\  .child
        \\    width 1px
    ,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        0,
    );
    try expectSemanticRejection(
        \\prefix-classes('orphan-')
    ,
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus prefix-classes() requires a content block",
        0,
    );
}

test "native Stylus mutates promoted lists across callable aliases and arguments" {
    const input =
        \\nums = 1
        \\append(nums, 2)
        \\append(nums, 3, 4, 5)
        \\mutate(list)
        \\  push(list, 6)
        \\collect()
        \\  list = ()
        \\  for arg in arguments
        \\    push(list, arg)
        \\  return list
        \\mutate(nums)
        \\body
        \\  appended nums
        \\  pushed: ret = push(nums, 7, 8)
        \\  unshifted unshift(nums, -1, 0)
        \\  final nums
        \\  args collect(alpha, beta)
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "body{appended:1 2 3 4 5 6;pushed:8;unshifted:10;" ++
            "final:0 -1 1 2 3 4 5 6 7 8;args:alpha beta}",
        compiled.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), compiled.nativeDiagnostics().len);
    try std.testing.expect(compiled.map() != null);
}

test "native Stylus composes match conversion and root media mixins" {
    const input =
        \\unit-intervals = { 'px': 1, 'em': 0.01, 'rem': 0.1 }
        \\media(expression)
        \\  parsed-expression = match('^(height|width)?([<>=]{1,})(.*)', expression)
        \\  operator = parsed-expression[2]
        \\  direction = match('>', operator) ? 'min' : 'max'
        \\  type = direction + '-' + (parsed-expression[1] || 'width')
        \\  value = convert(parsed-expression[3])
        \\  unless match('=', operator)
        \\    value = operate(direction == 'min' ? '+' : '-', value, unit-intervals[unit(value)])
        \\  @media ({type}: value)
        \\    {block}
        \\+media('>400px')
        \\  body
        \\    margin 1px
    ;
    var compiled = try compile(std.testing.allocator, input, .{});
    defer compiled.deinit();
    try std.testing.expectEqualStrings(
        "@media (min-width: 401px){body{margin:1px}}",
        compiled.css(),
    );
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
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
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

test "native Stylus evaluates bounded compound conditions with short circuiting" {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_expression_depth = 3;
    var first = try compile(std.testing.allocator, logical_condition_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, logical_condition_input, terminal);
    defer second.deinit();

    try std.testing.expectEqualStrings(logical_condition_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal;
    over_limit.max_expression_depth = 2;
    try expectSemanticRejectionWithLimits(
        logical_condition_input,
        over_limit,
        error.ExpressionDepthExceeded,
        .resource_limit,
        "native Stylus expression depth exceeded",
        @intCast(std.mem.indexOf(u8, logical_condition_input, "if n < 50").?),
    );
}

test "native Stylus preserves comment-separated conditional chains" {
    var first = try compile(std.testing.allocator, commented_if_else_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, commented_if_else_input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(commented_if_else_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus compares unitful mixin arguments with unitless bounds" {
    var first = try compile(std.testing.allocator, unitful_mixin_condition_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, unitful_mixin_condition_input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(unitful_mixin_condition_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const incompatible =
        \\body
        \\  before safe
        \\  if 1px < 1s
        \\    after unsafe
    ;
    try expectSemanticRejection(
        incompatible,
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus expression is invalid",
        @intCast(std.mem.indexOf(u8, incompatible, "if 1px < 1s").?),
    );
}

test "native Stylus evaluates filtered postfix declaration loops" {
    const input =
        \\list = red green blue
        \\no-colors = false
        \\
        \\body
        \\  color: color for color in list if length(list) > 2 unless no-colors
        \\
        \\mixin()
        \\  color: color for color in list if length(list) > 2 unless no-colors
        \\
        \\body
        \\  mixin()
        \\
        \\short-list = red
        \\.blocked-by-length
        \\  color: color for color in short-list if length(short-list) > 2 unless no-colors
        \\
        \\no-colors = true
        \\.blocked-by-unless
        \\  color: color for color in list if length(list) > 2 unless no-colors
    ;
    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 10;
    var first = try compile(std.testing.allocator, input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, terminal);
    defer second.deinit();

    const expected = "body{color:#f00;color:#008000;color:#00f}" ++
        "body{color:#f00;color:#008000;color:#00f}";
    try std.testing.expectEqualStrings(expected, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const limit_input =
        \\list = red green blue
        \\body
        \\  color: color for color in list
    ;
    var over_limit = terminal;
    over_limit.max_loop_iterations = 2;
    try expectSemanticRejectionWithLimits(
        limit_input,
        over_limit,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, limit_input, "color: color for").?),
    );
}

test "native Stylus evaluates explicit end-of-line escapes" {
    var first = try compile(std.testing.allocator, eol_escape_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, eol_escape_input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(eol_escape_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const over_limit_input = "list = red \\\n  blue";
    var over_limit = stylus_evaluator.Limits{};
    over_limit.max_temporary_bytes = 1;
    try expectSemanticRejectionWithLimits(
        over_limit_input,
        over_limit,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        0,
    );
}

test "native Stylus evaluates single-line implicit-return functions with postfix guards" {
    const input =
        \\large(n){ n > 100 }
        \\
        \\body
        \\  foo large(5)
        \\  foo large(300)
        \\
        \\large(n){ n > 100 if n is a 'unit' }
        \\
        \\body
        \\  foo large(5)
        \\  foo large(300)
        \\  foo large('test')
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "body{foo:false;foo:true}body{foo:false;foo:true;foo:}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus keyframe fabrication follows the bounded vendor value" {
    const input =
        \\vendors = webkit ms official
        \\@keyframes pulse
        \\  from
        \\    color red
    ;
    var first = try compile(std.testing.allocator, input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, input, .{});
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "@-webkit-keyframes pulse{from{color:#f00}}" ++
            "@keyframes pulse{from{color:#f00}}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);
}

test "native Stylus keyframe fabrication owns the provider default terminal contract" {
    const lower_input =
        \\vendors = official
        \\@keyframes pulse { from { color: red; } }
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.values.max_collection_items = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "@keyframes pulse{from{color:#f00}}",
        lower.css(),
    );

    const terminal_input =
        \\@keyframes pulse {
        \\  from { color: black; }
        \\  to { color: white; }
        \\}
    ;
    var terminal_limits = stylus_evaluator.Limits{};
    terminal_limits.values.max_collection_items = 5;
    var first = try compile(std.testing.allocator, terminal_input, terminal_limits);
    defer first.deinit();
    var second = try compile(std.testing.allocator, terminal_input, terminal_limits);
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "@-moz-keyframes pulse{from{color:#000}to{color:#fff}}" ++
            "@-webkit-keyframes pulse{from{color:#000}to{color:#fff}}" ++
            "@-o-keyframes pulse{ from { color: #000; } to { color: #fff; } }" ++
            "@keyframes pulse{from{color:#000}to{color:#fff}}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal_limits;
    over_limit.values.max_collection_items = 4;
    try expectSemanticRejectionWithLimits(
        terminal_input,
        over_limit,
        error.ValueLimitExceeded,
        .resource_limit,
        "native Stylus value limit exceeded",
        @intCast(std.mem.indexOf(u8, terminal_input, "@keyframes").?),
    );
}

test "native Stylus newline keyframe selectors own the finite terminal contract" {
    const lower_input =
        \\vendors = o
        \\@keyframes pulse
        \\  0%
        \\  100%
        \\    opacity 1
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_selectors = 2;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "@-o-keyframes pulse{ 0%, 100% { opacity: 1; } }",
        lower.css(),
    );
    var compressed = try compileWithOptions(
        std.testing.allocator,
        lower_input,
        .{ .output_style = .compressed },
        lower_limits,
    );
    defer compressed.deinit();
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, compressed.css(), "%, "),
    );

    const terminal_input =
        \\@keyframes pulse
        \\  0%
        \\  50%
        \\  100%
        \\    opacity 1
        \\  to
        \\    opacity 0
    ;
    var terminal_limits = stylus_evaluator.Limits{};
    terminal_limits.max_selectors = 16;
    var first = try compile(std.testing.allocator, terminal_input, terminal_limits);
    defer first.deinit();
    var second = try compile(std.testing.allocator, terminal_input, terminal_limits);
    defer second.deinit();

    try std.testing.expectEqualStrings(
        "@-moz-keyframes pulse{0%,50%,100%{opacity:1}to{opacity:0}}" ++
            "@-webkit-keyframes pulse{0%,50%,100%{opacity:1}to{opacity:0}}" ++
            "@-o-keyframes pulse{ 0%, 50%, 100% { opacity: 1; } " ++
            "to { opacity: 0; } }" ++
            "@keyframes pulse{0%,50%,100%{opacity:1}to{opacity:0}}",
        first.css(),
    );
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal_limits;
    over_limit.max_selectors = 15;
    try expectSemanticRejectionWithLimits(
        terminal_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOf(u8, terminal_input, "to").?),
    );
}

test "native Stylus add-property preserves declaration context and interpolation" {
    const input =
        \\custom(name, value)
        \\  {name} value
        \\replacement()
        \\  add-property(current-property[0], before)
        \\  after
        \\copy()
        \\  add-property(current-property[0], current-property[1])
        \\  done
        \\.direct
        \\  add-property(foo, bar)
        \\.custom
        \\  custom(height, 10px)
        \\.nested
        \\  width replacement()
        \\.copy
        \\  background test copy(), stuff
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".direct{foo:bar}.custom{height:10px}.nested{width:before;width:after}" ++
            ".copy{background:test __CALL__, stuff;background:test done, stuff}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Stylus indexed current-property access retains its callable snapshot" {
    const input =
        \\identity(value)
        \\  add-property('captured', value)
        \\  return 1px
        \\outer()
        \\  temporary: identity(current-property[0])
        \\  return 2px
        \\body
        \\  width: outer()
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "body{captured:'width';width:2px}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Stylus interpolated property callables preserve the finite terminal contract" {
    const lower_input =
        \\identity(value)
        \\  {value}
        \\body
        \\  {identity('width')} 1px
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_call_depth = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{width:1px}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compile(std.testing.allocator, interpolated_property_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, interpolated_property_input, terminal);
    defer second.deinit();

    try std.testing.expectEqualStrings(interpolated_property_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal;
    over_limit.max_call_depth = 1;
    try expectSemanticRejectionWithLimits(
        interpolated_property_input,
        over_limit,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.indexOf(
            u8,
            interpolated_property_input,
            "vendor('border-radius'",
        ).?),
    );
}

test "native Stylus callable context introspection preserves the finite terminal contract" {
    const lower_input =
        \\probe()
        \\  if mixin == 'root'
        \\    got
        \\      root true
        \\probe()
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_call_depth = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings("got{root:true}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var first = try compile(std.testing.allocator, mixin_introspection_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, mixin_introspection_input, terminal);
    defer second.deinit();

    try std.testing.expectEqualStrings(mixin_introspection_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const over_limit_input =
        \\probe()
        \\  mixin
        \\outer()
        \\  probe()
        \\body
        \\  outer()
    ;
    try expectSemanticRejectionWithLimits(
        over_limit_input,
        terminal,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.indexOf(u8, over_limit_input, "  probe()\nbody").? + 2),
    );
}

test "native Stylus define owns local and explicit global scope" {
    const input =
        \\a = 1
        \\local()
        \\  define('b', 2)
        \\  return b
        \\global()
        \\  define('c', 3, true)
        \\shadow()
        \\  a = 2
        \\  define('a', 3, true)
        \\  return a
        \\body
        \\  local-result: local()
        \\  local-visible: b is defined
        \\  global()
        \\  global-visible: c
        \\  shadow-result: shadow()
        \\  global-a: a
    ;
    var result = try compile(std.testing.allocator, input, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "body{local-result:2;local-visible:false;global-visible:3;" ++
            "shadow-result:2;global-a:3}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);

    const nested =
        \\value = define('hidden', 1)
        \\body
        \\  test: value
    ;
    try expectSemanticRejection(
        nested,
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus define() is supported only as a statement",
        0,
    );
}

test "native Stylus reads bounded image dimensions through resolver ownership" {
    const allocator = std.testing.allocator;
    const image_root = "tests/preprocessors/stylus/corpus/files/upstream/images";
    const names = [_][]const u8{
        "gif",
        "tux.png",
        "flowers.jpeg",
        "flowers_p.jpg",
        "tiger.svg",
    };
    var contents: [names.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (contents[0..loaded]) |bytes| allocator.free(bytes);
    for (names, 0..) |name, index| {
        const path = try std.fs.path.join(allocator, &.{ image_root, name });
        defer allocator.free(path);
        contents[index] = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
        loaded += 1;
    }

    const files = [_]FixtureFile{
        .{ .path = names[0], .contents = contents[0] },
        .{ .path = names[1], .contents = contents[1] },
        .{ .path = names[2], .contents = contents[2] },
        .{ .path = names[3], .contents = contents[3] },
        .{ .path = names[4], .contents = contents[4] },
    };
    const input =
        \\body
        \\  gif: image-size('gif')
        \\  gif-width: image-size('gif')[0]
        \\  png: image-size('tux.png')
        \\  jpeg: image-size('flowers.jpeg')
        \\  progressive-jpeg: image-size('flowers_p.jpg')
        \\  svg: image-size('tiger.svg')
        \\  missing: image-size('missing.png', true)
        \\.present
        \\  if image-size('tux.png', true)
        \\    found: yes
        \\  else
        \\    found: no
        \\.missing
        \\  if image-size('missing.png', true)
        \\    found: yes
        \\  else
        \\    found: no
    ;
    var result = try compileFixture(allocator, input, &files, .{}, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "body{gif:118px 104px;gif-width:118px;png:510px 640px;" ++
            "jpeg:640px 480px;progressive-jpeg:640px 480px;" ++
            "svg:900px 900px;missing:0 0}.present{found:yes}.missing{found:no}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, names.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, names.len), result.edges().len);
    for (result.dependencies(), names) |dependency, name| {
        try std.testing.expectEqual(resolver.DependencyKind.reference, dependency.kind);
        try std.testing.expectEqualStrings(name, std.fs.path.basename(dependency.url));
    }
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
}

test "native Stylus image dimensions reject invalid assets and unconfined targets" {
    const invalid_assets = [_]FixtureFile{
        .{ .path = "invalid.gif", .contents = "GIF89a\x00\x00\x01\x00" },
        .{ .path = "invalid.png", .contents = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x00\x00\x00\x00\x01" },
        .{ .path = "invalid.jpeg", .contents = "\xff\xd8\xff\xc0\x00\x07\x08\x00\x00\x00\x01" },
        .{ .path = "invalid.svg", .contents = "<svg width='0' height='1'></svg>" },
    };
    for (invalid_assets) |asset| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "body\n  size: image-size('{s}')\n",
            .{asset.path},
        );
        defer std.testing.allocator.free(input);
        try expectFixtureRejection(
            input,
            &.{asset},
            error.InvalidOperation,
            .invalid_operation,
            "native Stylus image asset is invalid",
            0,
            1,
        );
    }

    try expectFixtureRejection(
        "body\n  size: image-size('missing.png')\n",
        &.{},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus image asset was not found",
        0,
        0,
    );
    for ([_][]const u8{ "../escape.png", "https://example.invalid/image.png" }) |target| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "body\n  size: image-size('{s}')\n",
            .{target},
        );
        defer std.testing.allocator.free(input);
        try expectFixtureRejection(
            input,
            &.{},
            error.InvalidOperation,
            .invalid_operation,
            "native Stylus image asset load was rejected",
            0,
            0,
        );
    }
}

test "native Stylus image dimensions preserve resolver byte limits" {
    const input = "body\n  size: image-size('tiny.gif')\n";
    const gif = "GIF89a\x01\x00\x01\x00";
    const files = [_]FixtureFile{.{ .path = "tiny.gif", .contents = gif }};
    var terminal = resolver.Limits{};
    terminal.max_total_bytes = gif.len;
    var result = try compileFixture(std.testing.allocator, input, &files, terminal, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("body{size:1px 1px}", result.css());
    try std.testing.expectEqual(@as(u64, gif.len), result.stats().bytes);

    var over_limit = terminal;
    over_limit.max_total_bytes -= 1;
    try std.testing.expectError(
        error.TotalLimitExceeded,
        compileFixture(std.testing.allocator, input, &files, over_limit, .{}),
    );
}

test "native Stylus JSON owns legacy variables, hashes, and optional assets" {
    const files = [_]FixtureFile{
        .{
            .path = "vars.json",
            .contents =
            \\{
            \\  "nope": "none",
            \\  "color": "#abc",
            \\  "length": "10px",
            \\  "count": 2,
            \\  "nested": { "value": "ready" },
            \\  "enabled": true
            \\}
            ,
        },
        .{
            .path = "local.json",
            .contents = "{\"theme\":{\"color\":\"blue\"},\"size\":5}",
        },
        .{
            .path = "strings.json",
            .contents = "{\"color\":\"#abc\",\"length\":\"10px\"}",
        },
    };
    const input =
        \\json('vars.json')
        \\.global
        \\  ident: nope
        \\  color: color
        \\  length: length
        \\  numeric: count * 2
        \\  nested: nested-value
        \\  truth: enabled
        \\.local
        \\  prefix = '$'
        \\  json('local.json', true, prefix)
        \\  color: $theme-color
        \\  size: $size * 2
        \\.hash
        \\  vars = json('vars.json', { hash: true })
        \\  ident: vars.nope
        \\  color: vars.color
        \\  length: vars.length
        \\  numeric: vars.count * 2
        \\  nested: vars.nested.value
        \\  truth: vars.enabled
        \\.strings
        \\  vars = json('strings.json', { hash: true, leave-strings: true })
        \\  color: vars.color
        \\  length: vars.length
        \\.outside
        \\  color: $theme-color
        \\.optional
        \\  vars = json('missing.json', { hash: true, optional: true })
        \\  missing: typeof(vars)
    ;
    var result = try compileFixture(std.testing.allocator, input, &files, .{}, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings(
        ".global{ident:none;color:#abc;length:10px;numeric:4;nested:ready;truth:true}" ++
            ".local{color:#00f;size:10}.hash{ident:none;color:#abc;length:10px;" ++
            "numeric:4;nested:ready;truth:true}.strings{color:'#abc';length:'10px'}" ++
            ".outside{color:$theme-color}.optional{missing:'null'}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, files.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), result.edges().len);
    for (result.dependencies()) |dependency| {
        try std.testing.expectEqual(resolver.DependencyKind.reference, dependency.kind);
    }
    try std.testing.expectEqual(@as(usize, 0), result.nativeDiagnostics().len);
    try std.testing.expect(result.map() != null);
}

test "native Stylus JSON rejects malformed and unconfined assets" {
    try expectFixtureRejection(
        "vars = json('invalid.json', { hash: true })\n",
        &.{.{ .path = "invalid.json", .contents = "{\"value\":" }},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus JSON asset is invalid",
        0,
        1,
    );
    try expectFixtureRejection(
        "vars = json('missing.json', { hash: true })\n",
        &.{},
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus JSON asset was not found",
        0,
        0,
    );
    try expectFixtureRejection(
        "vars = json('array.json', { hash: true })\n",
        &.{.{ .path = "array.json", .contents = "{\"values\":[1,2]}" }},
        error.UnsupportedFeature,
        .unsupported_feature,
        "native Stylus JSON arrays are unavailable",
        0,
        1,
    );
    const invalid_options = "vars = json('data.json', { hash: false })\n";
    try expectSemanticRejection(
        invalid_options,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        0,
    );
    for ([_][]const u8{ "../escape.json", "https://example.invalid/data.json" }) |target| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "vars = json('{s}', {{ hash: true }})\n",
            .{target},
        );
        defer std.testing.allocator.free(input);
        try expectFixtureRejection(
            input,
            &.{},
            error.InvalidOperation,
            .invalid_operation,
            "native Stylus JSON asset load was rejected",
            0,
            0,
        );
    }
}

test "native Stylus JSON preserves resolver byte limits" {
    const input = "vars = json('data.json', { hash: true })\nbody\n  value: vars.value\n";
    const json = "{\"value\":1}";
    const files = [_]FixtureFile{.{ .path = "data.json", .contents = json }};
    var terminal = resolver.Limits{};
    terminal.max_total_bytes = json.len;
    var result = try compileFixture(std.testing.allocator, input, &files, terminal, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("body{value:1}", result.css());
    try std.testing.expectEqual(@as(u64, json.len), result.stats().bytes);

    var over_limit = terminal;
    over_limit.max_total_bytes -= 1;
    try std.testing.expectError(
        error.TotalLimitExceeded,
        compileFixture(std.testing.allocator, input, &files, over_limit, .{}),
    );
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

test "native Stylus complex extension aliases preserve selected branch and nesting semantics" {
    var first = try compile(std.testing.allocator, complex_extension_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, complex_extension_input, .{});
    defer second.deinit();
    try std.testing.expectEqualStrings(complex_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
}

test "native Stylus loop extensions use rendered iteration selectors deterministically" {
    var first = try compile(std.testing.allocator, loop_extension_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, loop_extension_input, .{});
    defer second.deinit();
    try std.testing.expectEqualStrings(loop_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
}

test "native Stylus loop extension discovery retains finite iteration ceilings" {
    const lower_input =
        \\.span
        \\  width 100%
        \\for i in 1..1
        \\  .span{i}
        \\    @extend .span
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(".span,.span1{width:100%}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 4;
    var terminal_result = try compile(std.testing.allocator, loop_extension_input, terminal);
    defer terminal_result.deinit();
    try std.testing.expectEqualStrings(loop_extension_css, terminal_result.css());

    var over_limit = terminal;
    over_limit.max_loop_iterations = 3;
    try expectSemanticRejectionWithLimits(
        loop_extension_input,
        over_limit,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, loop_extension_input, "for i").?),
    );
}

test "native Stylus loop context extensions render targets within finite ceilings" {
    const lower_input =
        \\.tester1
        \\  tester: 1
        \\for i in 1..1
        \\  .test{i}
        \\    test{i}: i
        \\    @extend .tester{i}
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        ".tester1,.test1{tester:1}.test1{test1:1}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 2;
    var first = try compile(std.testing.allocator, loop_context_extension_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, loop_context_extension_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(loop_context_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_loop_iterations = 1;
    try expectSemanticRejectionWithLimits(
        loop_context_extension_input,
        over_limit,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, loop_context_extension_input, "for i").?),
    );
}

test "native Stylus media query extensions retain bounded selector ownership" {
    const lower_input =
        \\@media print
        \\  .base
        \\    width: 1px
        \\  .extended
        \\    @extend .base
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "@media print{.base,.extended{width:1px}}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 3;
    var first = try compile(std.testing.allocator, media_query_extension_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, media_query_extension_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(media_query_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_selectors = 1;
    try expectSemanticRejectionWithLimits(
        media_query_extension_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOf(u8, media_query_extension_input, ".test").?),
    );
}

test "native Stylus direct mixin extensions retain bounded invocation ownership" {
    const lower_input =
        \\.base
        \\  width 1px
        \\extend-base()
        \\  @extend .base
        \\.derived
        \\  extend-base()
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(".base,.derived{width:1px}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    terminal.max_selectors = 9;
    var first = try compile(std.testing.allocator, mixin_extension_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, mixin_extension_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(mixin_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_selectors = 7;
    try expectSemanticRejectionWithLimits(
        mixin_extension_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOf(u8, mixin_extension_input, ".{$namespace}one-half").?),
    );
}

test "native Stylus nested mixin extensions retain bounded invocation ownership" {
    const lower_input =
        \\.base
        \\  width 1px
        \\extend-base()
        \\  @extend .base
        \\bridge()
        \\  extend-base()
        \\.derived
        \\  bridge()
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_call_depth = 2;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings(".base,.derived{width:1px}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 4;
    var first = try compile(std.testing.allocator, nested_mixin_extension_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, nested_mixin_extension_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(nested_mixin_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_call_depth = 3;
    try expectSemanticRejectionWithLimits(
        nested_mixin_extension_input,
        over_limit,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.lastIndexOf(u8, nested_mixin_extension_input, "more()").?),
    );
}

test "native Stylus plural extension aliases cover each prior matching definition" {
    const lower_input =
        \\.error
        \\  font-size: bold
        \\.serious-error
        \\  @extends .error
        \\  font-size: 18px
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_selectors = 3;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        ".error,.serious-error{font-size:bold}.serious-error{font-size:18px}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 5;
    var first = try compile(
        std.testing.allocator,
        multiple_definition_extension_input,
        terminal,
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        multiple_definition_extension_input,
        terminal,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(multiple_definition_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_selectors = 3;
    try expectSemanticRejectionWithLimits(
        multiple_definition_extension_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOfPos(
            u8,
            multiple_definition_extension_input,
            ".error".len,
            ".error",
        ).?),
    );
}

test "native Stylus multiple selector extensions retain bounded target ownership" {
    const lower_input =
        \\.a
        \\  color: red
        \\.b[data-prop*='\,']
        \\  width: 1px
        \\.c
        \\  @extend .a, .b[data-prop*=',']
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_selectors = 5;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        ".a,.c{color:#f00}.b[data-prop*=\",\"],.c{width:1px}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 27;
    var first = try compile(
        std.testing.allocator,
        multiple_selector_extension_input,
        terminal,
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        multiple_selector_extension_input,
        terminal,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(multiple_selector_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_selectors = 26;
    try expectSemanticRejectionWithLimits(
        multiple_selector_extension_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.lastIndexOf(u8, multiple_selector_extension_input, ".e").?),
    );
}

test "native Stylus variable extension targets retain bounded lexical ownership" {
    const lower_input =
        \\.base
        \\  width 1px
        \\target = "base"
        \\.derived
        \\  @extend .{target}
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(".base,.derived{width:1px}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 3;
    var first = try compile(
        std.testing.allocator,
        variable_target_extension_input,
        terminal,
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        variable_target_extension_input,
        terminal,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(variable_target_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_selectors = 2;
    try expectSemanticRejectionWithLimits(
        variable_target_extension_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOf(u8, variable_target_extension_input, ".{var}2").?),
    );
}

test "native Stylus optional extension targets retain bounded list ownership" {
    const lower_input =
        \\.base
        \\  width 1px
        \\$placeholder
        \\  height 2px
        \\.end
        \\  @extend .base !optional, absent !optional, $placeholder !optional
        \\  display block
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        ".base,.end{width:1px}.end{height:2px}.end{display:block}",
        lower.css(),
    );

    var callable = try compile(
        std.testing.allocator,
        callable_optional_extension_input,
        .{},
    );
    defer callable.deinit();
    try std.testing.expectEqualStrings(callable_optional_extension_css, callable.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 7;
    var first = try compile(std.testing.allocator, optional_extension_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, optional_extension_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(optional_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_selectors = 6;
    try expectSemanticRejectionWithLimits(
        optional_extension_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOf(u8, optional_extension_input, ".end").?),
    );
}

test "native Stylus placeholder extensions retain bounded chain and plural ownership" {
    var first = try compile(
        std.testing.allocator,
        placeholder_chain_extension_input,
        .{},
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        placeholder_chain_extension_input,
        .{},
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(placeholder_chain_extension_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 14;
    var plural = try compile(
        std.testing.allocator,
        placeholder_plural_extension_input,
        terminal,
    );
    defer plural.deinit();
    var plural_again = try compile(
        std.testing.allocator,
        placeholder_plural_extension_input,
        terminal,
    );
    defer plural_again.deinit();
    try std.testing.expectEqualStrings(placeholder_plural_extension_css, plural.css());
    try std.testing.expectEqualStrings(plural.css(), plural_again.css());
    try std.testing.expectEqualSlices(
        u8,
        plural.sourceMap().?,
        plural_again.sourceMap().?,
    );
    try std.testing.expectEqual(@as(usize, 0), plural.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), plural.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_selectors = 13;
    try expectSemanticRejectionWithLimits(
        placeholder_plural_extension_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.lastIndexOf(u8, placeholder_plural_extension_input, ".item").?),
    );
}

test "native Stylus indentation-owned font face rules are evaluated deterministically" {
    const lower_input =
        \\@font-face
        \\  font-family Lower
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "@font-face{font-family:Lower}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_nodes = 17;
    var first = try compile(std.testing.allocator, font_face_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, font_face_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(font_face_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_nodes = 16;
    try expectSemanticRejectionWithLimits(
        font_face_input,
        over_limit,
        error.NodeLimitExceeded,
        .resource_limit,
        "native Stylus evaluator node limit exceeded",
        0,
    );
}

test "native Stylus complex loops retain bounded range group nesting and callable ownership" {
    const lower_input =
        \\values = a b
        \\body
        \\  for value in values[0]
        \\    item value
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_loop_iterations = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{item:a}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 11;
    var first = try compile(std.testing.allocator, complex_for_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, complex_for_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(complex_for_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_loop_iterations = 10;
    try expectSemanticRejectionWithLimits(
        complex_for_input,
        over_limit,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, complex_for_input, "for ignored").?),
    );
}

test "native Stylus function arguments preserve defaults forwarding and property mutation" {
    const lower_input =
        \\defaults(value = 4px)
        \\  result arguments[0]
        \\body
        \\  defaults()
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{result:4px}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 5;
    var first = try compile(std.testing.allocator, function_arguments_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, function_arguments_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(function_arguments_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_loop_iterations = 4;
    try expectSemanticRejectionWithLimits(
        function_arguments_input,
        over_limit,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, function_arguments_input, "for num").?),
    );
}

test "native Stylus keyword arguments bind builtins and user callables deterministically" {
    const lower_input =
        \\body
        \\  quotient operate(10, op: '/', 2)
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{quotient:5}", lower.css());

    var first = try compile(std.testing.allocator, keyword_arguments_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, keyword_arguments_input, .{});
    defer second.deinit();
    try std.testing.expectEqualStrings(keyword_arguments_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const collection_input =
        \\body
        \\  joined join(1 2 3, delim: '|')
    ;
    var terminal = stylus_evaluator.Limits{};
    terminal.values.max_collection_items = 3;
    var collection = try compile(std.testing.allocator, collection_input, terminal);
    defer collection.deinit();
    try std.testing.expectEqualStrings("body{joined:'1|2|3'}", collection.css());

    var over_limit = terminal;
    over_limit.values.max_collection_items = 2;
    try expectSemanticRejectionWithLimits(
        collection_input,
        over_limit,
        error.ValueLimitExceeded,
        .resource_limit,
        "native Stylus value limit exceeded",
        @intCast(std.mem.indexOf(u8, collection_input, "join(1 2 3").?),
    );

    const duplicate =
        \\body
        \\  value operate(op: '/', left: 10, right: 2, op: '*')
    ;
    try expectSemanticRejection(
        duplicate,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, duplicate, "operate").?),
    );

    const missing =
        \\body
        \\  value operate(op: '/', left: 10)
    ;
    try expectSemanticRejection(
        missing,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, missing, "operate").?),
    );

    const excess =
        \\body
        \\  value rgba(red: 100, green: 50, blue: 10, alpha: 0.5, 1)
    ;
    try expectSemanticRejection(
        excess,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, excess, "rgba").?),
    );

    const unknown =
        \\body
        \\  value join(separator: '|', 1, 2)
    ;
    try expectSemanticRejection(
        unknown,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, unknown, "join").?),
    );
}

test "native Stylus literal CSS blocks preserve bounded raw root and nested content" {
    const lower_input = "@css { .icon::before { content: \"}\"; } /* { */ }";
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(".icon::before{content:\"}\"}", lower.css());

    const opening = std.mem.indexOfScalar(u8, literal_css_input, '{').?;
    const closing = std.mem.lastIndexOfScalar(u8, literal_css_input, '}').?;
    const literal_bytes = closing - opening - 1;
    var terminal = stylus_evaluator.Limits{};
    terminal.max_temporary_bytes = literal_bytes;
    var first = try compile(std.testing.allocator, literal_css_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, literal_css_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(literal_css_output, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const nested_input =
        \\@media print
        \\  @css {
        \\    body { color: red }
        \\  }
    ;
    var nested = try compileWithOptions(
        std.testing.allocator,
        nested_input,
        .{ .output_style = .compressed },
        .{},
    );
    defer nested.deinit();
    try std.testing.expectEqualStrings("@media print{body{color:red}}", nested.css());

    var over_limit = terminal;
    over_limit.max_temporary_bytes = literal_bytes - 1;
    try expectSemanticRejectionWithLimits(
        literal_css_input,
        over_limit,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        0,
    );

    try expectSemanticRejection(
        "@css",
        error.InvalidDocument,
        .invalid_operation,
        "native Stylus literal CSS block is invalid",
        0,
    );
}

test "native Stylus literal colors own the finite lexical and callable terminal contract" {
    const lower_input =
        \\body
        \\  short #e
        \\  pair #ef
        \\  alpha rgba(#fc0, 40%)
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "body{short:#eee;pair:#efefef;alpha:rgba(255,204,0,0.4)}",
        lower.css(),
    );

    var first = try compile(std.testing.allocator, literal_color_input, .{});
    defer first.deinit();
    var second = try compile(std.testing.allocator, literal_color_input, .{});
    defer second.deinit();
    try std.testing.expectEqualStrings(literal_color_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    const terminal_input =
        \\body
        \\  color rgba(100%, 255, 100%, 50%)
    ;
    var terminal_limits = stylus_evaluator.Limits{};
    terminal_limits.values.max_collection_items = 4;
    var terminal = try compile(std.testing.allocator, terminal_input, terminal_limits);
    defer terminal.deinit();
    try std.testing.expectEqualStrings(
        "body{color:rgba(255,255,255,0.5)}",
        terminal.css(),
    );

    var over_limit = terminal_limits;
    over_limit.values.max_collection_items = 3;
    try expectSemanticRejectionWithLimits(
        terminal_input,
        over_limit,
        error.ValueLimitExceeded,
        .resource_limit,
        "native Stylus value limit exceeded",
        @intCast(std.mem.indexOf(u8, terminal_input, "rgba").?),
    );

    const invalid =
        \\body
        \\  color rgba(100%, 255, 100%, invalid)
    ;
    try expectSemanticRejection(
        invalid,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, invalid, "rgba").?),
    );
}

test "native Stylus media bubbling owns the finite query product contract" {
    const lower_input =
        \\@media (min-width: 1px)
        \\  @media screen and (orientation: landscape)
        \\    body
        \\      color red
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "@media screen and (min-width: 1px) and (orientation: landscape)" ++
            "{body{color:#f00}}",
        lower.css(),
    );

    var terminal_limits = stylus_evaluator.Limits{};
    terminal_limits.max_selectors = 2;
    var first = try compile(std.testing.allocator, media_bubble_input, terminal_limits);
    defer first.deinit();
    var second = try compile(std.testing.allocator, media_bubble_input, terminal_limits);
    defer second.deinit();
    try std.testing.expectEqualStrings(media_bubble_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var incompatible = try compile(
        std.testing.allocator,
        "@media screen\n  @media print\n    body\n      color red\n",
        .{},
    );
    defer incompatible.deinit();
    try std.testing.expectEqualStrings("", incompatible.css());

    var over_limit = terminal_limits;
    over_limit.max_selectors = 1;
    try expectSemanticRejectionWithLimits(
        media_bubble_input,
        over_limit,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.lastIndexOf(u8, media_bubble_input, "@media").?),
    );
}

test "native Stylus complex media expressions own the finite semantic contract" {
    const lower_input =
        \\size = 2em
        \\@media (max-width size * 2)
        \\  body
        \\    color red
    ;
    var lower = try compile(std.testing.allocator, lower_input, .{});
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "@media (max-width: 4em){body{color:#f00}}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    terminal.max_loop_iterations = 3;
    terminal.max_selectors = 16;
    var first = try compile(std.testing.allocator, media_complex_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, media_complex_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(media_complex_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal;
    over_limit.max_loop_iterations = 2;
    try expectSemanticRejectionWithLimits(
        media_complex_input,
        over_limit,
        error.LoopLimitExceeded,
        .loop_limit,
        "native Stylus loop iteration limit exceeded",
        @intCast(std.mem.indexOf(u8, media_complex_input, "for j").?),
    );
}

test "native Stylus nested mixins own the finite caller scope contract" {
    const lower_input =
        \\inner()
        \\  seen local
        \\outer()
        \\  local = 1
        \\  inner()
        \\body
        \\  outer()
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_call_depth = 2;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{seen:1}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compile(std.testing.allocator, mixin_caller_scope_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, mixin_caller_scope_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(mixin_caller_scope_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal;
    over_limit.max_call_depth = 1;
    try expectSemanticRejectionWithLimits(
        mixin_caller_scope_input,
        over_limit,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.lastIndexOf(u8, mixin_caller_scope_input, "inner()").?),
    );
}

test "native Stylus property functions emit declarations through callable aliases" {
    const lower_input =
        \\border-radius(size)
        \\  -webkit-border-radius size
        \\  border-radius size
        \\form
        \\  border-radius 5px
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_call_depth = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings(
        "form{-webkit-border-radius:5px;border-radius:5px}",
        lower.css(),
    );

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var first = try compile(std.testing.allocator, function_property_alias_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, function_property_alias_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(function_property_alias_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
}

test "native Stylus anonymous functions preserve lexical callbacks within the call-depth bound" {
    const lower_input =
        \\identity = @(value) {
        \\  value
        \\}
        \\body
        \\  width identity(3)
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_call_depth = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{width:3}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compile(std.testing.allocator, anonymous_functions_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, anonymous_functions_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(anonymous_functions_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_call_depth = 1;
    try expectSemanticRejectionWithLimits(
        anonymous_functions_input,
        over_limit,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.indexOf(u8, anonymous_functions_input, "add(2, 3)").?),
    );

    const lexical_escape =
        \\make()
        \\  private = @(value) {
        \\    value
        \\  }
        \\  private(1)
        \\make()
        \\body
        \\  private(2)
    ;
    try expectSemanticRejection(
        lexical_escape,
        error.UndefinedCallable,
        .invalid_operation,
        "native Stylus callable is undefined",
        @intCast(std.mem.lastIndexOf(u8, lexical_escape, "private(2)").?),
    );
}

test "native Stylus declaration assignments persist across repeated callable output" {
    const lower_input =
        \\persist(value)
        \\  first local = unit(value, 'px')
        \\  second local
        \\lower
        \\  persist(2)
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.max_call_depth = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings("lower{first:2px;second:2px}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compile(
        std.testing.allocator,
        multiple_call_assignment_input,
        terminal,
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        multiple_call_assignment_input,
        terminal,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(multiple_call_assignment_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal;
    over_limit.max_call_depth = 1;
    try expectSemanticRejectionWithLimits(
        multiple_call_assignment_input,
        over_limit,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.indexOf(u8, multiple_call_assignment_input, "pad-x(x)").?),
    );
}

test "native Stylus nested functions return bounded callable values without leaking names" {
    const lower_input =
        \\outer(a, b)
        \\  half()
        \\    b / 2
        \\  a + half()
        \\body
        \\  width outer(1, 5)
    ;
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var lower = try compile(std.testing.allocator, lower_input, terminal);
    defer lower.deinit();
    try std.testing.expectEqualStrings("body{width:3.5}", lower.css());

    var first = try compile(std.testing.allocator, nested_function_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, nested_function_input, terminal);
    defer second.deinit();
    try std.testing.expectEqualStrings(nested_function_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.dependencies().len);

    var over_limit = terminal;
    over_limit.max_call_depth = 1;
    try expectSemanticRejectionWithLimits(
        nested_function_input,
        over_limit,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.lastIndexOf(u8, nested_function_input, "half()").?),
    );

    const leak_input =
        \\factory()
        \\  hidden(value)
        \\    value + 1
        \\body
        \\  factory()
        \\  width hidden(1)
    ;
    var leak = try compile(std.testing.allocator, leak_input, terminal);
    defer leak.deinit();
    try std.testing.expectEqualStrings("body{width:hidden(1)}", leak.css());
}

test "native Stylus call mixins transport a content block through an empty list" {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var first = try compile(
        std.testing.allocator,
        call_mixin_block_transport_input,
        terminal,
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        call_mixin_block_transport_input,
        terminal,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(call_mixin_block_transport_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.max_call_depth = 1;
    try expectSemanticRejectionWithLimits(
        call_mixin_block_transport_input,
        over_limit,
        error.CallDepthExceeded,
        .call_limit,
        "native Stylus call depth exceeded",
        @intCast(std.mem.lastIndexOf(u8, call_mixin_block_transport_input, "size()").?),
    );
}

test "native Stylus call mixins prefer content over a default inline block" {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var first = try compile(
        std.testing.allocator,
        call_mixin_default_block_input,
        terminal,
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        call_mixin_default_block_input,
        terminal,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(call_mixin_default_block_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
}

test "native Stylus call mixins retain caller extensions and declaration at-rule context" {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var first = try compile(
        std.testing.allocator,
        call_mixin_nested_context_input,
        terminal,
    );
    defer first.deinit();
    var second = try compile(
        std.testing.allocator,
        call_mixin_nested_context_input,
        terminal,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings(call_mixin_nested_context_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);
}

test "native Stylus quoted strings coerce the finite call expression contract" {
    const lower_input =
        \\a
        \\  value: '' + foo()
    ;
    var lower_limits = stylus_evaluator.Limits{};
    lower_limits.values.max_depth = 1;
    var lower = try compile(std.testing.allocator, lower_input, lower_limits);
    defer lower.deinit();
    try std.testing.expectEqualStrings("a{value:'foo()'}", lower.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.values.max_depth = 2;
    var first = try compile(std.testing.allocator, call_to_string_input, terminal);
    defer first.deinit();
    var second = try compile(std.testing.allocator, call_to_string_input, terminal);
    defer second.deinit();

    try std.testing.expectEqualStrings(call_to_string_css, first.css());
    try std.testing.expectEqualStrings(first.css(), second.css());
    try std.testing.expectEqualSlices(u8, first.sourceMap().?, second.sourceMap().?);
    try std.testing.expectEqual(@as(usize, 0), first.nativeDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), first.coreDiagnostics().len);

    var over_limit = terminal;
    over_limit.values.max_depth = 1;
    try expectSemanticRejectionWithLimits(
        call_to_string_input,
        over_limit,
        error.ValueDepthExceeded,
        .resource_limit,
        "native Stylus value limit exceeded",
        0,
    );
}

test "native Stylus scalar conversion and expansion limits fail closed" {
    const bitwise_overflow =
        \\.a
        \\  width ~1e300
    ;
    try expectSemanticRejection(
        bitwise_overflow,
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus expression is invalid",
        @intCast(std.mem.indexOf(u8, bitwise_overflow, "~1e300").?),
    );

    const index_overflow =
        \\.a
        \\  width (1 2)[1e300]
    ;
    try expectSemanticRejection(
        index_overflow,
        error.InvalidOperation,
        .invalid_operation,
        "native Stylus expression is invalid",
        @intCast(std.mem.indexOf(u8, index_overflow, "(1 2)").?),
    );

    const empty_split =
        \\.a
        \\  content split('', 'abc')
    ;
    try expectSemanticRejection(
        empty_split,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, empty_split, "split").?),
    );

    const empty_replace =
        \\.a
        \\  content replace('', 'x', 'abc')
    ;
    try expectSemanticRejection(
        empty_replace,
        error.InvalidArguments,
        .type_mismatch,
        "native Stylus callable arguments are invalid",
        @intCast(std.mem.indexOf(u8, empty_replace, "replace").?),
    );

    const repetition =
        \\.a
        \\  content 'ab' * 3
    ;
    var terminal_temporary = stylus_evaluator.Limits{};
    terminal_temporary.max_temporary_bytes = 64;
    var repeated = try compile(std.testing.allocator, repetition, terminal_temporary);
    defer repeated.deinit();
    try std.testing.expectEqualStrings(".a{content:'ababab'}", repeated.css());

    var over_temporary = terminal_temporary;
    over_temporary.max_temporary_bytes = 43;
    try expectSemanticRejectionWithLimits(
        repetition,
        over_temporary,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        @intCast(std.mem.indexOf(u8, repetition, "'ab'").?),
    );

    const extension =
        \\.base
        \\  width 1px
        \\.one
        \\  @extend .base
    ;
    var terminal_selectors = stylus_evaluator.Limits{};
    terminal_selectors.max_selectors = 3;
    var extended = try compile(std.testing.allocator, extension, terminal_selectors);
    defer extended.deinit();
    try std.testing.expectEqualStrings(".base,.one{width:1px}", extended.css());

    var over_selectors = terminal_selectors;
    over_selectors.max_selectors = 1;
    try expectSemanticRejectionWithLimits(
        extension,
        over_selectors,
        error.SelectorLimitExceeded,
        .resource_limit,
        "native Stylus selector limit exceeded",
        @intCast(std.mem.indexOf(u8, extension, ".base").?),
    );

    const padded =
        \\.a
        \\  content base-convert(15, 16, 100)
    ;
    try expectSemanticRejectionWithLimits(
        padded,
        terminal_temporary,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        @intCast(std.mem.indexOf(u8, padded, "base-convert").?),
    );

    const replacement_growth =
        \\.a
        \\  content replace('a', '0123456789', 'aaaaaaaaaaaaaaaaaaaa')
    ;
    var bounded_replacement = stylus_evaluator.Limits{};
    bounded_replacement.max_temporary_bytes = 128;
    try expectSemanticRejectionWithLimits(
        replacement_growth,
        bounded_replacement,
        error.TemporaryLimitExceeded,
        .resource_limit,
        "native Stylus temporary byte limit exceeded",
        @intCast(std.mem.indexOf(u8, replacement_growth, "replace").?),
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
        var invalid = stylus_evaluator.Limits{};
        invalid.asset_load_paths = &.{"relative"};
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
        "base = {\n" ++
            "  a: 1\n" ++
            "}\n" ++
            "alias = base\n" ++
            "merged = merge(base, { b: 2 })\n" ++
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
            "  merged alias.b\n" ++
            "  count length(1 2 3)\n" ++
            "  kind type(4px)\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".card{padding:4px;margin:5px;border-top-width:1px;" ++
            "border-right-width:1px;merged:2;count:3;kind:'unit'}",
        result.css(),
    );
}

fn exerciseImportAllocationFailures(allocator: std.mem.Allocator) !void {
    const files = [_]FixtureFile{
        .{ .path = "parts/a.styl", .contents = "spacing = 4px\n.a\n  order 1\n" },
        .{ .path = "parts/b.styl", .contents = ".b\n  order 2\n" },
        .{ .path = "once.styl", .contents = ".once\n  order 3\n" },
    };
    var result = try compileFixture(
        allocator,
        "@import \"parts/*\"\n" ++
            "@require \"once\"\n" ++
            "@require \"once\"\n" ++
            ".card\n" ++
            "  width spacing\n",
        &files,
        .{},
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ".a{order:1}.b{order:2}.once{order:3}.card{width:4px}",
        result.css(),
    );
}

fn exerciseCallableDynamicImportAllocationFailures(allocator: std.mem.Allocator) !void {
    const input =
        \\load(path)
        \\  @import path
        \\load('part')
    ;
    const files = [_]FixtureFile{
        .{ .path = "part.styl", .contents = ".loaded\n  color blue\n" },
    };
    var result = try compileFixture(allocator, input, &files, .{}, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(".loaded{color:#00f}", result.css());
}

fn exerciseIncludeCssAllocationFailures(allocator: std.mem.Allocator) !void {
    const files = [_]FixtureFile{
        .{ .path = "chain/a.styl", .contents = "@import \"nested/b\"\n" },
        .{ .path = "chain/nested/b.styl", .contents = "@import \"c.css\"\n" },
        .{ .path = "chain/nested/c.css", .contents = ".c { color: red; }\n" },
    };
    var terminal = resolver.Limits{};
    terminal.max_files = files.len;
    var result = try compileFixtureWithOptions(
        allocator,
        "@import \"chain/a\"\n",
        &files,
        .{ .include_css = true },
        terminal,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(".c{color:red}", result.css());
    try std.testing.expectEqual(@as(usize, files.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), result.edges().len);
}

fn exerciseImportedPropertyCallableUnitArithmeticAllocationFailures(
    allocator: std.mem.Allocator,
) !void {
    const input =
        \\@import 'import.include.function/import.vendor'
        \\@import 'import.include.function/import.common'
        \\$radius = 10
        \\body
        \\  border-radius: ($radius / 2)px
    ;
    const files = [_]FixtureFile{
        .{
            .path = "import.include.function/import.vendor.styl",
            .contents =
            \\border-radius()
            \\  -moz-border-radius: arguments
            \\  -webkit-border-radius: arguments
            \\  border-radius: arguments
            ,
        },
        .{
            .path = "import.include.function/import.common.styl",
            .contents = "body\n  color red\n",
        },
    };
    var resolver_terminal = resolver.Limits{};
    resolver_terminal.max_files = files.len;
    var evaluator_terminal = stylus_evaluator.Limits{};
    evaluator_terminal.max_call_depth = 1;
    var result = try compileFixture(
        allocator,
        input,
        &files,
        resolver_terminal,
        evaluator_terminal,
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{color:#f00}body{-moz-border-radius:5px;" ++
            "-webkit-border-radius:5px;border-radius:5px}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, files.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), result.edges().len);
}

fn exerciseImportLookupAllocationFailures(allocator: std.mem.Allocator) !void {
    const input =
        \\@import 'lookup-a'
        \\@import 'lookup-b'
        \\@import 'lookup-c'
    ;
    const files = [_]FixtureFile{
        .{
            .path = "lookup-a/lookup-a.styl",
            .contents = "body\n  content 'a'\n",
        },
        .{
            .path = "node_modules/lookup-b/package.json",
            .contents = "{\n  \"main\": \"test.styl\"\n}\n",
        },
        .{
            .path = "node_modules/lookup-b/test.styl",
            .contents = "body\n  content 'b'\n",
        },
        .{
            .path = "node_modules/lookup-c.styl/index.styl",
            .contents = "body\n  content 'c'\n",
        },
    };
    var terminal = resolver.Limits{};
    terminal.max_files = files.len;
    var result = try compileFixture(allocator, input, &files, terminal, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{content:'a'}body{content:'b'}body{content:'c'}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, files.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), result.edges().len);
}

fn exerciseComputedTopLevelImportAllocationFailures(allocator: std.mem.Allocator) !void {
    const input =
        \\dir = 'import.ordering'
        \\one
        \\  foo bar
        \\@import dir + "/two"
        \\three
        \\  foo bar
        \\@import dir + '/four'
    ;
    const files = [_]FixtureFile{
        .{
            .path = "import.ordering/two.styl",
            .contents = "two\n  foo bar\n",
        },
        .{
            .path = "import.ordering/four.styl",
            .contents = "four\n  foo bar\n@import \"import.ordering/five\"\n",
        },
        .{
            .path = "import.ordering/five.styl",
            .contents = "five\n  foo bar\n",
        },
    };
    var terminal = resolver.Limits{};
    terminal.max_files = files.len;
    var result = try compileFixture(allocator, input, &files, terminal, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "one{foo:bar}two{foo:bar}three{foo:bar}four{foo:bar}five{foo:bar}",
        result.css(),
    );
    try std.testing.expectEqual(@as(usize, files.len), result.dependencies().len);
    try std.testing.expectEqual(@as(usize, files.len), result.edges().len);
}

fn exerciseCompactDeclarationAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compileWithOptions(
        allocator,
        "body {background:white;font-size:.8em;background-image:url(src/grid.png);" ++
            "border-color:#e5eCf9;quotes:\"\" \"\";content:'';" ++
            "font-family:\"Helvetica Neue\",Arial;}\n",
        .{ .output_style = .expanded },
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{background:#fff;font-size:0.8em;background-image:url(\"src/grid.png\");" ++
            "border-color:#e5ecf9;quotes:\"\" \"\";content:'';" ++
            "font-family:\"Helvetica Neue\", Arial}",
        result.css(),
    );
}

fn exerciseSingleLineCallableAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "large(n){ n > 100 if n is a 'unit' }\nbody\n  foo large(5)\n  foo large('test')\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("body{foo:false;foo:}", result.css());
}

fn exerciseKeyframeVendorAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "vendors = webkit\n@keyframes pulse\n  from\n    opacity 0\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "@-webkit-keyframes pulse{from{opacity:0}}",
        result.css(),
    );

    var defaults = try compile(
        allocator,
        "@keyframes pulse { from { color: black; } to { color: white; } }\n",
        .{},
    );
    defer defaults.deinit();
    try std.testing.expectEqualStrings(
        "@-moz-keyframes pulse{from{color:#000}to{color:#fff}}" ++
            "@-webkit-keyframes pulse{from{color:#000}to{color:#fff}}" ++
            "@-o-keyframes pulse{ from { color: #000; } to { color: #fff; } }" ++
            "@keyframes pulse{from{color:#000}to{color:#fff}}",
        defaults.css(),
    );

    var newlines = try compile(
        allocator,
        "vendors = o\n@keyframes pulse\n  0%\n  100%\n    opacity 1\n",
        .{},
    );
    defer newlines.deinit();
    try std.testing.expectEqualStrings(
        "@-o-keyframes pulse{ 0%, 100% { opacity: 1; } }",
        newlines.css(),
    );
}

fn exerciseKeyframeConformanceAllocationFailures(allocator: std.mem.Allocator) !void {
    var semantic = try compile(allocator, keyframe_semantic_input, .{});
    defer semantic.deinit();
    try std.testing.expectEqualStrings(keyframe_semantic_css, semantic.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 3;
    var result = try compile(allocator, keyframe_loop_terminal_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(keyframe_loop_terminal_css, result.css());
}

fn exercisePropertySlashAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "size = 14px\nheight = 1.4\nbody { font: size / height \"Helvetica Neue\", Arial; }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{font:14px/1.4 \"Helvetica Neue\", Arial}",
        result.css(),
    );
}

fn exerciseCompactNestedRuleAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "hover()\n" ++
            "  &:hover { color: white; background: black;\n" ++
            "    em {\n" ++
            "      color: gray;\n" ++
            "    }\n" ++
            "  }\n" ++
            "body { hover(); }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body:hover{color:#fff;background:#000}body:hover em{color:#808080}",
        result.css(),
    );
}

fn exerciseSpacedSelectorInterpolationAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "pos = last\n" ++
            "body {form} { input:{pos}-child { display: none; } }\n" ++
            ".plain { color red }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body form input:last-child{display:none}.plain{color:#f00}",
        result.css(),
    );
}

fn exerciseExplicitCssNestedSelectorAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "body { margin: 0; ul {\n/* test */\nmargin: 0; li { color: red; } } }\n" ++
            "ul { li { &:first-child, &:last-child { display: none; } } }\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{margin:0}body ul{margin:0}body ul li{color:#f00}" ++
            "ul li:first-child,ul li:last-child{display:none}",
        result.css(),
    );
}

fn exerciseExplicitWhitespaceAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "body {\n     padding: 5px;\n  margin: 0;\n  article\n    color: red;\n}\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{padding:5px;margin:0}body article{color:#f00}",
        result.css(),
    );
}

fn exercisePostfixDeclarationLoopAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(
        allocator,
        "list = red green blue\n" ++
            "no-colors = false\n" ++
            "body\n" ++
            "  color: color for color in list if length(list) > 2 unless no-colors\n" ++
            "mixin()\n" ++
            "  color: color for color in list if length(list) > 2 unless no-colors\n" ++
            "body\n" ++
            "  mixin()\n",
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "body{color:#f00;color:#008000;color:#00f}" ++
            "body{color:#f00;color:#008000;color:#00f}",
        result.css(),
    );
}

fn exerciseEolEscapeAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, eol_escape_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(eol_escape_css, result.css());
}

fn exerciseComplexExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, complex_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(complex_extension_css, result.css());
}

fn exerciseLoopExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, loop_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(loop_extension_css, result.css());
}

fn exerciseLoopContextExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, loop_context_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(loop_context_extension_css, result.css());
}

fn exerciseMediaQueryExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, media_query_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(media_query_extension_css, result.css());
}

fn exerciseMixinExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, mixin_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(mixin_extension_css, result.css());
}

fn exerciseNestedMixinExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, nested_mixin_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(nested_mixin_extension_css, result.css());
}

fn exerciseMultipleDefinitionExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, multiple_definition_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(multiple_definition_extension_css, result.css());
}

fn exerciseMultipleSelectorExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, multiple_selector_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(multiple_selector_extension_css, result.css());
}

fn exerciseVariableTargetExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, variable_target_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(variable_target_extension_css, result.css());
}

fn exerciseOptionalExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var callable = try compile(allocator, callable_optional_extension_input, .{});
    defer callable.deinit();
    try std.testing.expectEqualStrings(callable_optional_extension_css, callable.css());

    var result = try compile(allocator, optional_extension_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(optional_extension_css, result.css());
}

fn exercisePlaceholderExtensionAllocationFailures(allocator: std.mem.Allocator) !void {
    var chain = try compile(allocator, placeholder_chain_extension_input, .{});
    defer chain.deinit();
    try std.testing.expectEqualStrings(placeholder_chain_extension_css, chain.css());

    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 14;
    var plural = try compile(allocator, placeholder_plural_extension_input, terminal);
    defer plural.deinit();
    try std.testing.expectEqualStrings(placeholder_plural_extension_css, plural.css());
}

fn exerciseFontFaceAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_nodes = 17;
    var result = try compile(allocator, font_face_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(font_face_css, result.css());
}

fn exerciseComplexForAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 11;
    var result = try compile(allocator, complex_for_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(complex_for_css, result.css());
}

fn exerciseFunctionArgumentsAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_loop_iterations = 5;
    var result = try compile(allocator, function_arguments_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(function_arguments_css, result.css());
}

fn exerciseKeywordArgumentsAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, keyword_arguments_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(keyword_arguments_css, result.css());
}

fn exerciseLiteralCssAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, literal_css_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(literal_css_output, result.css());
}

fn exerciseLiteralColorAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, literal_color_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(literal_color_css, result.css());
}

fn exerciseMediaBubbleAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_selectors = 2;
    var result = try compile(allocator, media_bubble_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(media_bubble_css, result.css());
}

fn exerciseMediaComplexAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    terminal.max_loop_iterations = 3;
    terminal.max_selectors = 16;
    var result = try compile(allocator, media_complex_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(media_complex_css, result.css());
}

fn exerciseMixinCallerScopeAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var result = try compile(allocator, mixin_caller_scope_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(mixin_caller_scope_css, result.css());
}

fn exerciseFunctionPropertyAliasAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var result = try compile(allocator, function_property_alias_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(function_property_alias_css, result.css());
}

fn exerciseInterpolatedPropertyAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var result = try compile(allocator, interpolated_property_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(interpolated_property_css, result.css());
}

fn exerciseMixinIntrospectionAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var result = try compile(allocator, mixin_introspection_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(mixin_introspection_css, result.css());
}

fn exerciseAnonymousFunctionsAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var result = try compile(allocator, anonymous_functions_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(anonymous_functions_css, result.css());
}

fn exerciseCallMixinAllocationFailures(allocator: std.mem.Allocator) !void {
    var nested_limits = stylus_evaluator.Limits{};
    nested_limits.max_call_depth = 2;
    var transported = try compile(
        allocator,
        call_mixin_block_transport_input,
        nested_limits,
    );
    defer transported.deinit();
    try std.testing.expectEqualStrings(call_mixin_block_transport_css, transported.css());

    var defaulted = try compile(
        allocator,
        call_mixin_default_block_input,
        .{},
    );
    defer defaulted.deinit();
    try std.testing.expectEqualStrings(call_mixin_default_block_css, defaulted.css());

    var contextual = try compile(
        allocator,
        call_mixin_nested_context_input,
        .{},
    );
    defer contextual.deinit();
    try std.testing.expectEqualStrings(call_mixin_nested_context_css, contextual.css());
}

fn exerciseCallToStringAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.values.max_depth = 2;
    var result = try compile(allocator, call_to_string_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(call_to_string_css, result.css());
}

fn exerciseMultipleCallAssignmentAllocationFailures(allocator: std.mem.Allocator) !void {
    const input =
        \\persist(value)
        \\  first local = unit(value, 'px')
        \\  second local
        \\body
        \\  persist(2)
    ;
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 1;
    var result = try compile(allocator, input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings("body{first:2px;second:2px}", result.css());
}

fn exerciseNestedFunctionAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_call_depth = 2;
    var result = try compile(allocator, nested_function_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(nested_function_css, result.css());
}

fn exerciseLogicalConditionAllocationFailures(allocator: std.mem.Allocator) !void {
    var terminal = stylus_evaluator.Limits{};
    terminal.max_expression_depth = 3;
    var result = try compile(allocator, logical_condition_input, terminal);
    defer result.deinit();
    try std.testing.expectEqualStrings(logical_condition_css, result.css());
}

fn exerciseCommentedIfElseAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, commented_if_else_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(commented_if_else_css, result.css());
}

fn exerciseUnitfulMixinConditionAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try compile(allocator, unitful_mixin_condition_input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(unitful_mixin_condition_css, result.css());
}

test "native Stylus transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "native Stylus import transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseImportAllocationFailures,
        .{},
    );
}

test "native Stylus callable dynamic imports handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCallableDynamicImportAllocationFailures,
        .{},
    );
}

test "native Stylus include CSS imports handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseIncludeCssAllocationFailures,
        .{},
    );
}

test "native Stylus dotted import property callables handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseImportedPropertyCallableUnitArithmeticAllocationFailures,
        .{},
    );
}

test "native Stylus import lookup handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseImportLookupAllocationFailures,
        .{},
    );
}

test "native Stylus computed top-level imports handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseComputedTopLevelImportAllocationFailures,
        .{},
    );
}

test "native Stylus compact declaration transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompactDeclarationAllocationFailures,
        .{},
    );
}

test "native Stylus single-line callable transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSingleLineCallableAllocationFailures,
        .{},
    );
}

test "native Stylus keyframe vendor transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseKeyframeVendorAllocationFailures,
        .{},
    );
}

test "native Stylus keyframe conformance handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseKeyframeConformanceAllocationFailures,
        .{},
    );
}

test "native Stylus property slash transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePropertySlashAllocationFailures,
        .{},
    );
}

test "native Stylus compact nested rule transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompactNestedRuleAllocationFailures,
        .{},
    );
}

test "native Stylus whitespace-separated selector interpolation handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSpacedSelectorInterpolationAllocationFailures,
        .{},
    );
}

test "native Stylus explicit CSS nested selector transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExplicitCssNestedSelectorAllocationFailures,
        .{},
    );
}

test "native Stylus explicit brace whitespace transaction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExplicitWhitespaceAllocationFailures,
        .{},
    );
}

test "native Stylus postfix declaration loops handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePostfixDeclarationLoopAllocationFailures,
        .{},
    );
}

test "native Stylus end-of-line escapes handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEolEscapeAllocationFailures,
        .{},
    );
}

test "native Stylus complex extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseComplexExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus loop extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLoopExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus loop context extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLoopContextExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus media query extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMediaQueryExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus direct mixin extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMixinExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus nested mixin extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNestedMixinExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus multiple definition extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMultipleDefinitionExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus multiple selector extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMultipleSelectorExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus variable extension targets handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseVariableTargetExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus optional extension targets handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseOptionalExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus placeholder extensions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePlaceholderExtensionAllocationFailures,
        .{},
    );
}

test "native Stylus indentation-owned font face rules handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFontFaceAllocationFailures,
        .{},
    );
}

test "native Stylus complex loops handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseComplexForAllocationFailures,
        .{},
    );
}

test "native Stylus function arguments handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFunctionArgumentsAllocationFailures,
        .{},
    );
}

test "native Stylus keyword arguments handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseKeywordArgumentsAllocationFailures,
        .{},
    );
}

test "native Stylus literal CSS blocks handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLiteralCssAllocationFailures,
        .{},
    );
}

test "native Stylus literal colors handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLiteralColorAllocationFailures,
        .{},
    );
}

test "native Stylus media bubbling handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMediaBubbleAllocationFailures,
        .{},
    );
}

test "native Stylus complex media expressions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMediaComplexAllocationFailures,
        .{},
    );
}

test "native Stylus nested mixin caller scope handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMixinCallerScopeAllocationFailures,
        .{},
    );
}

test "native Stylus property function aliases handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFunctionPropertyAliasAllocationFailures,
        .{},
    );
}

test "native Stylus interpolated property callables handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseInterpolatedPropertyAllocationFailures,
        .{},
    );
}

test "native Stylus callable context introspection handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMixinIntrospectionAllocationFailures,
        .{},
    );
}

test "native Stylus anonymous functions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAnonymousFunctionsAllocationFailures,
        .{},
    );
}

test "native Stylus call mixins handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCallMixinAllocationFailures,
        .{},
    );
}

test "native Stylus call expression string coercion handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCallToStringAllocationFailures,
        .{},
    );
}

test "native Stylus declaration assignment callables handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMultipleCallAssignmentAllocationFailures,
        .{},
    );
}

test "native Stylus nested functions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseNestedFunctionAllocationFailures,
        .{},
    );
}

test "native Stylus compound conditions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLogicalConditionAllocationFailures,
        .{},
    );
}

test "native Stylus comment-separated conditional chains handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCommentedIfElseAllocationFailures,
        .{},
    );
}

test "native Stylus unitful mixin conditions handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseUnitfulMixinConditionAllocationFailures,
        .{},
    );
}
