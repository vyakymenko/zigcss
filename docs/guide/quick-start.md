# Quick Start

This guide will walk you through the basics of using zigcss.

## Command Line Usage

### Basic Compilation

```bash
# Compile a single CSS file
zigcss input.css -o output.css
```

### With Optimizations

```bash
# Compile with optimizations and minification
zigcss input.css -o output.css --optimize --minify
```

### Add Vendor Prefixes

```bash
# Add vendor prefixes automatically
zigcss input.css -o output.css --autoprefix

# With specific browser support
zigcss input.css -o output.css --autoprefix --browsers "last 2 versions,> 1%"
```

### Watch Mode

```bash
# Watch for changes and recompile automatically
zigcss input.css -o output.css --watch
```

### Generate Source Maps

```bash
# Generate source maps for debugging
zigcss input.css -o output.css --source-map
```

### Compile Multiple Files

```bash
# Compile multiple files to a directory
zigcss src/*.css -o dist/ --output-dir
```

## Supported Formats

zigcss supports multiple CSS preprocessor formats:

```bash
# SCSS/SASS
zigcss styles.scss -o styles.css
zigcss styles.sass -o styles.css

# LESS
zigcss styles.less -o styles.css

# CSS Modules
zigcss component.module.css -o component.module.css

# PostCSS
zigcss styles.postcss -o styles.css

# Stylus
zigcss styles.styl -o styles.css
```

## Library Usage

### Basic Compilation

```zig
const std = @import("std");
const zigcss = @import("zigcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = ".container { color: red; }";
    const result = try zigcss.compile(allocator, css, .{
        .optimize = true,
        .source_map = true,
    });
    defer result.deinit(allocator);
    
    std.debug.print("Compiled CSS: {s}\n", .{result.css});
}
```

### Advanced Usage

```zig
const std = @import("std");
const zigcss = @import("zigcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = try std.fs.cwd().readFileAlloc(allocator, "styles.css", 10 * 1024 * 1024);
    defer allocator.free(css);

    const options = zigcss.CompileOptions{
        .optimize = true,
        .minify = true,
        .source_map = true,
        .autoprefix = .{
            .browsers = &.{ "last 2 versions", "> 1%" },
        },
        .remove_comments = true,
        .optimize_selectors = true,
    };

    const result = try zigcss.compile(allocator, css, options);
    defer result.deinit(allocator);

    try std.fs.cwd().writeFileAlloc(allocator, "styles.min.css", result.css);
    if (result.source_map) |map| {
        try std.fs.cwd().writeFileAlloc(allocator, "styles.min.css.map", map);
    }
}
```

## Next Steps

- [Examples](/examples/css-nesting) — See more examples
- [API Reference](/api/compile-options) — Learn about the API
- [Plugin System](/guide/plugins) — Create custom transformations
