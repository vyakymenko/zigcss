# CompileOptions

`CompileOptions` controls how zcss compiles CSS.

## Structure

```zig
pub const CompileOptions = struct {
    optimize: bool = false,
    minify: bool = false,
    source_map: bool = false,
    remove_comments: bool = false,
    optimize_selectors: bool = false,
    remove_empty_rules: bool = false,
    autoprefix: ?AutoprefixOptions = null,
    plugins: []const Plugin = &.{},
};
```

## Options

### `optimize: bool`

Enable CSS optimizations. When `true`, enables all optimization passes:

- Empty rule removal
- Selector merging
- Redundant selector removal
- Shorthand property optimization
- Advanced selector optimization
- Duplicate declaration removal
- Value optimization
- Media query merging
- Container query merging
- Cascade layer merging

**Default:** `false`

### `minify: bool`

Minify CSS output by removing unnecessary whitespace and comments.

**Default:** `false`

### `source_map: bool`

Generate source maps for debugging. Source maps map compiled CSS back to original source files.

**Default:** `false`

### `remove_comments: bool`

Remove CSS comments from output.

**Default:** `false`

### `optimize_selectors: bool`

Enable advanced selector optimizations:

- Universal selector removal
- Selector simplification
- Specificity-based optimization

**Default:** `false`

### `remove_empty_rules: bool`

Remove rules with no declarations.

**Default:** `false`

### `autoprefix: ?AutoprefixOptions`

Enable autoprefixer with vendor prefix support. When `null`, autoprefixer is disabled.

```zig
.autoprefix = .{
    .browsers = &.{ "last 2 versions", "> 1%" },
}
```

**Default:** `null`

### `plugins: []const Plugin`

Array of plugins to run during compilation. Plugins run after parsing and before optimization.

**Default:** `&.{}` (empty array)

## Example

```zig
const options = zcss.CompileOptions{
    .optimize = true,
    .minify = true,
    .source_map = true,
    .remove_comments = true,
    .optimize_selectors = true,
    .remove_empty_rules = true,
    .autoprefix = .{
        .browsers = &.{ "last 2 versions", "> 1%" },
    },
    .plugins = &.{my_plugin},
};
```

## Related

- [CompileResult](/api/compile-result) — Compilation result structure
- [Plugin API](/api/plugin-api) — Plugin system documentation
