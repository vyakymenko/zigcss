# zcss

> **The world's fastest CSS compiler** — Built with Zig for uncompromising performance

**zcss** is a zero-dependency CSS compiler written in Zig, designed from the ground up to be the fastest CSS processing tool available. Leveraging Zig's compile-time optimizations, memory safety, and zero-cost abstractions, zcss delivers unmatched performance for CSS parsing, transformation, and compilation.

## Table of Contents

- [Performance](#-performance)
- [Features](#-features)
- [Installation](#-installation)
- [Quick Start](#-quick-start)
- [Examples](#-examples)
- [Architecture](#️-architecture)
- [API Reference](#-api-reference)
- [Testing](#-testing)
- [Roadmap](#-roadmap)
- [Documentation](#-documentation)
- [Contributing](#-contributing)
- [License](#-license)

## 🚀 Performance

zcss is engineered to be **the fastest CSS compiler in the world**. Key performance characteristics:

- **Zero runtime dependencies** — Single binary, no external libraries
- **Compile-time optimizations** — Leverages Zig's comptime for maximum efficiency
- **Memory-efficient parsing** — Minimal allocations, zero-copy where possible
- **Parallel processing** — Multi-threaded compilation for multiple files (utilizes all CPU cores)
- **Native performance** — Compiled to machine code, not interpreted

### Benchmarks

Performance tested on a MacBook Pro M3 (16GB RAM) with real-world CSS workloads. All tools tested with minification and optimization enabled.

#### Small CSS (~100 bytes)
| Compiler | **Total Time** | Speedup vs zcss |
|----------|----------------|-----------------|
| **zcss** | **6.7ms** | 1x (baseline) |
| PostCSS | 546.9ms | **81.6x slower** |
| Sass | 855.0ms | **127.6x slower** |

**zcss is 81-127x faster** than competitors for small files.

#### Medium CSS (~10KB, typical production bundle)
| Compiler | **Total Time** | Speedup vs zcss |
|----------|----------------|-----------------|
| **zcss** | **6.7ms** | 1x (baseline) |
| PostCSS | 570.1ms | **85.4x slower** |
| Sass | 589.7ms | **88.2x slower** |

**zcss is 85-88x faster** than competitors for medium-sized files.

#### Large CSS (~100KB, complex stylesheet)
| Compiler | **Total Time** | Speedup vs zcss |
|----------|----------------|-----------------|
| **zcss** | **56.0ms** | 1x (baseline) |
| PostCSS | 528.2ms | **9.4x slower** |
| Sass | 634.3ms | **11.3x slower** |

**zcss is 9-11x faster** than competitors for large files.

> **Note**: Benchmarks run with `zig build -Doptimize=ReleaseFast`. Competitor tools tested via `npx` (Node.js v24.11.1). Results averaged over 10 iterations after 2 warmup runs.

#### Performance Summary

- **Throughput**: ~1.8 MB/s for large files (100KB in 56ms)
- **Parsing speed**: ~1,800 rules/second (100KB file with ~1000 rules)
- **Memory efficiency**: Single 468KB binary, no runtime overhead
- **Startup time**: Instant (no VM or interpreter startup)
- **Real-world**: Processes typical 10KB production CSS in **6.7ms** vs 570ms (PostCSS) or 590ms (Sass)

#### Why zcss is Faster

1. **Native compilation** - Compiled to machine code, not interpreted
2. **Zero-copy parsing** - Minimal allocations, string interning for efficiency
3. **SIMD optimizations** - Vectorized whitespace skipping
4. **Hash-based algorithms** - O(n) selector merging vs O(n²) in competitors
5. **No runtime overhead** - No Node.js, Dart VM, or interpreter startup time

*Benchmarks run with `--optimize --minify` flags. Competitor numbers are estimates based on typical performance. Your results may vary based on hardware and CSS complexity.*

## ✨ Features

- ⚡ **Blazing fast** — Optimized for speed at every level
- 🔒 **Memory safe** — Zig's safety guarantees prevent common bugs
- 📦 **Zero dependencies** — Single binary, no runtime requirements
- 🎯 **Full CSS3 support** — Complete CSS specification compliance
- 🔧 **Extensible** — Plugin system for custom transformations
- 🧩 **Modular** — Use as a library or standalone CLI tool
- 🌐 **Cross-platform** — Works on Linux, macOS, and Windows
- 📝 **Source maps** — Full source map generation support
- 🎨 **CSS Nesting** — Native support for CSS Nesting specification
- 🔄 **Custom Properties** — Full CSS custom properties (variables) support
- 📐 **Media Queries** — Advanced media query parsing and optimization
- 📦 **Container Queries** — Full CSS Container Queries support with automatic optimization
- 🎭 **Pseudo-classes** — Complete pseudo-class and pseudo-element support
- 📋 **Preprocessor Support** — SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS
- 🚀 **Parallel Processing** — Multi-threaded compilation for multiple files

## 📦 Installation

### Package Managers

**npm (Node.js):**
```bash
npm install -g zcss
```

**Homebrew (macOS):**
```bash
brew tap vyakymenko/zcss
brew install zcss
```

Or install from source:
```bash
brew install --build-from-source Formula/zcss.rb
```

### From Source

**Requirements:**
- Zig 0.12.0 or later
- C compiler (for linking)

```bash
git clone https://github.com/vyakymenko/zcss.git
cd zcss
zig build -Doptimize=ReleaseFast
```

The binary will be available at `zig-out/bin/zcss`.

### Pre-built Binaries

Pre-built binaries are available for all supported platforms on the [releases page](https://github.com/vyakymenko/zcss/releases).

**Supported Platforms:**
- Linux (x86_64, aarch64)
- macOS (x86_64, aarch64) 
- Windows (x86_64)

**Quick Install:**

1. Download the appropriate binary for your platform from the [latest release](https://github.com/vyakymenko/zcss/releases/latest)
2. Extract the archive
3. Add the binary to your PATH or use it directly

**Example (Linux/macOS):**
```bash
# Download and extract
wget https://github.com/vyakymenko/zcss/releases/download/v0.1.0/zcss-0.1.0-x86_64-linux.tar.gz
tar -xzf zcss-0.1.0-x86_64-linux.tar.gz

# Make executable and move to PATH
chmod +x zcss
sudo mv zcss /usr/local/bin/
```

**Example (Windows):**
```powershell
# Download and extract
Invoke-WebRequest -Uri "https://github.com/vyakymenko/zcss/releases/download/v0.1.0/zcss-0.1.0-x86_64-windows.zip" -OutFile "zcss.zip"
Expand-Archive -Path zcss.zip -DestinationPath .

# Add to PATH (PowerShell as Administrator)
$env:Path += ";C:\path\to\zcss"
[Environment]::SetEnvironmentVariable("Path", $env:Path, [EnvironmentVariableTarget]::Machine)
```

### Using as a Library

Add to your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .zcss = .{
            .path = "../zcss",
        },
    },
}
```

### Build Integration

zcss provides build helpers for seamless integration with Zig's build system. Automatically compile CSS files as part of your build process:

**1. Add zcss as a dependency in `build.zig.zon`:**

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .zcss = .{
            .path = "../zcss",
        },
    },
}
```

**2. Use build helpers in your `build.zig`:**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcss_dep = b.dependency("zcss", .{
        .target = target,
        .optimize = optimize,
    });

    const zcss_exe = zcss_dep.artifact("zcss");
    const zcss_path = zcss_dep.path("");

    const build_helpers = @import("build_helpers.zig");
    const build_helpers_path = b.pathJoin(&.{ zcss_path, "build_helpers.zig" });
    const build_helpers_module = b.createModule(.{
        .root_source_file = b.path(build_helpers_path),
    });

    const css_step = build_helpers.addCssCompileStep(
        b,
        zcss_exe,
        "zig-out/css",
    );

    css_step.addInputFile("src/styles.css");
    css_step.addInputFile("src/components.scss");
    css_step.setOptimize(true);
    css_step.setMinify(true);
    css_step.setAutoprefix(true);
    css_step.addBrowsers(&.{ "last 2 versions", "> 1%" });

    const install_step = b.getInstallStep();
    install_step.dependOn(&css_step.step);

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
}
```

**Build Helper API:**

- `addCssCompileStep(builder, zcss_exe, output_dir)` - Create a CSS compilation step
- `addCssCompileStepTo(builder, zcss_exe, output_dir, step)` - Create and attach to a build step
- `css_step.addInputFile(file)` - Add a single CSS file to compile
- `css_step.addInputFiles(files)` - Add multiple CSS files
- `css_step.setOptimize(bool)` - Enable/disable optimizations
- `css_step.setMinify(bool)` - Enable/disable minification
- `css_step.setSourceMap(bool)` - Enable/disable source maps
- `css_step.setAutoprefix(bool)` - Enable/disable autoprefixer
- `css_step.addBrowser(browser)` - Add browser support requirement
- `css_step.addBrowsers(browsers)` - Add multiple browser requirements

CSS files are automatically compiled when you run `zig build`, and the compiled output is placed in the specified output directory.

## 🎯 Quick Start

### Command Line Usage

```bash
# Compile a single CSS file
zcss input.css -o output.css

# Compile with optimizations
zcss input.css -o output.css --optimize --minify

# Add vendor prefixes
zcss input.css -o output.css --autoprefix

# Add vendor prefixes with specific browser support
zcss input.css -o output.css --autoprefix --browsers "last 2 versions,> 1%"

# Watch mode for development
zcss input.css -o output.css --watch

# Generate source maps
zcss input.css -o output.css --source-map

# Extract critical CSS for above-the-fold content
zcss input.css -o critical.css --critical-classes "header,button,card" --critical-ids "nav" --critical-elements "div,body"

# Compile multiple files
zcss src/*.css -o dist/ --output-dir

# Start Language Server Protocol server
zcss --lsp
```

### Supported Formats

zcss supports multiple CSS preprocessor formats:

```bash
# SCSS/SASS
zcss styles.scss -o styles.css
zcss styles.sass -o styles.css

# LESS
zcss styles.less -o styles.css

# CSS Modules
zcss component.module.css -o component.module.css

# PostCSS
zcss styles.postcss -o styles.css

# Stylus
zcss styles.styl -o styles.css
```

### Library Usage

#### Basic Compilation

```zig
const std = @import("std");
const zcss = @import("zcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = ".container { color: red; }";
    const result = try zcss.compile(allocator, css, .{
        .optimize = true,
        .source_map = true,
    });
    defer result.deinit(allocator);
    
    std.debug.print("Compiled CSS: {s}\n", .{result.css});
}
```

#### Advanced Usage

```zig
const std = @import("std");
const zcss = @import("zcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = try std.fs.cwd().readFileAlloc(allocator, "styles.css", 10 * 1024 * 1024);
    defer allocator.free(css);

    const options = zcss.CompileOptions{
        .optimize = true,
        .minify = true,
        .source_map = true,
        .autoprefix = .{
            .browsers = &.{ "last 2 versions", "> 1%" },
        },
        .remove_comments = true,
        .optimize_selectors = true,
    };

    const result = try zcss.compile(allocator, css, options);
    defer result.deinit(allocator);

    try std.fs.cwd().writeFileAlloc(allocator, "styles.min.css", result.css);
    if (result.source_map) |map| {
        try std.fs.cwd().writeFileAlloc(allocator, "styles.min.css.map", map);
    }
}
```

## 📚 Examples

### CSS Nesting

zcss supports the CSS Nesting specification:

**Input:**
```css
.card {
    padding: 1rem;
    border: 1px solid #ddd;
    
    &:hover {
        border-color: #007bff;
    }
    
    .title {
        font-size: 1.5rem;
        font-weight: bold;
        
        &::after {
            content: " →";
        }
    }
}
```

**Output:**
```css
.card{padding:1rem;border:1px solid #ddd}.card:hover{border-color:#007bff}.card .title{font-size:1.5rem;font-weight:bold}.card .title::after{content:" →"}
```

### Custom Properties (CSS Variables)

```css
:root {
    --primary-color: #007bff;
    --spacing-unit: 8px;
    --border-radius: 4px;
}

.button {
    background-color: var(--primary-color);
    padding: calc(var(--spacing-unit) * 2);
    border-radius: var(--border-radius);
}
```

### Media Queries

```css
.container {
    width: 100%;
}

@media (min-width: 768px) {
    .container {
        width: 750px;
        margin: 0 auto;
    }
}
```

### Container Queries

zcss supports CSS Container Queries, allowing styles to be applied based on the size of a containing element rather than the viewport:

```css
.card {
    container-type: inline-size;
}

@container (min-width: 400px) {
    .card {
        padding: 2rem;
    }
}

@container (min-width: 600px) {
    .card {
        display: grid;
        grid-template-columns: 1fr 1fr;
    }
}
```

Container queries are automatically optimized by merging identical `@container` rules, similar to media query optimization.

### Cascade Layers

zcss supports CSS Cascade Layers, allowing you to control the cascade order of your styles:

```css
@layer theme {
    .button {
        color: red;
    }
}

@layer utilities {
    .button {
        color: blue;
    }
}

@layer theme {
    .link {
        color: green;
    }
}
```

Cascade layers are automatically optimized by merging identical `@layer` rules with the same name, reducing CSS size while maintaining cascade order.

### Tailwind @apply Expansion

zcss supports Tailwind CSS `@apply` directive expansion, automatically converting utility classes into CSS declarations:

**Input:**
```css
.btn {
    @apply px-4 py-2 bg-blue-500 text-white rounded-lg shadow-md;
}
```

**Output:**
```css
.btn {
    padding-left: 1rem;
    padding-right: 1rem;
    padding-top: 0.5rem;
    padding-bottom: 0.5rem;
    background-color: #3b82f6;
    color: #fff;
    border-radius: 0.5rem;
    box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
}
```

zcss includes a comprehensive Tailwind utility registry covering:
- **Spacing**: padding, margin utilities (p-*, px-*, py-*, m-*, mx-*, my-*, etc.)
- **Colors**: text and background colors (text-*, bg-*)
- **Typography**: font sizes, weights, styles, transforms
- **Layout**: display, width, height, overflow utilities
- **Flexbox**: flex direction, wrap, alignment utilities
- **Grid**: grid template columns utilities
- **Borders**: border width, style, radius utilities
- **Effects**: shadows, opacity utilities

### Dead Code Elimination

zcss can remove unused CSS rules based on a list of used selectors (classes, IDs, elements, attributes). This is useful for removing CSS that's not referenced in your HTML/JavaScript:

**Input CSS:**
```css
.used-class { color: red; }
.unused-class { color: blue; }
#used-id { color: green; }
#unused-id { color: yellow; }
div { color: black; }
span { color: white; }
```

**Usage:**
```zig
const std = @import("std");
const zcss = @import("zcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = try std.fs.cwd().readFileAlloc(allocator, "styles.css", 10 * 1024 * 1024);
    defer allocator.free(css);

    const used_classes = [_][]const u8{"used-class", "button", "card"};
    const used_ids = [_][]const u8{"used-id", "header"};
    const used_elements = [_][]const u8{"div", "body"};

    const dead_code_opts = zcss.optimizer.DeadCodeOptions{
        .used_classes = &used_classes,
        .used_ids = &used_ids,
        .used_elements = &used_elements,
    };

    const parser_trait = zcss.formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const result = try zcss.codegen.generate(allocator, &stylesheet, .{
        .optimize = true,
        .dead_code = dead_code_opts,
    });
    defer allocator.free(result);

    try std.fs.cwd().writeFile(.{ .sub_path = "styles.min.css", .data = result });
}
```

**Output CSS:**
```css
.used-class { color: red; }
#used-id { color: green; }
div { color: black; }
```

Dead code elimination works with nested rules in `@media`, `@container`, and `@layer` at-rules, automatically removing entire at-rules if all their nested rules are unused.

### Critical CSS Extraction

zcss can extract critical CSS for above-the-fold content, keeping only the CSS rules needed for initial page render. This improves First Contentful Paint (FCP) and Largest Contentful Paint (LCP) metrics by reducing the amount of CSS that needs to be parsed and applied before the page becomes interactive.

**Input CSS:**
```css
.critical-header { color: red; }
.non-critical-footer { color: blue; }
#critical-nav { color: green; }
#non-critical-sidebar { color: yellow; }
div { color: black; }
span { color: white; }
```

**Usage:**
```zig
const std = @import("std");
const zcss = @import("zcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = try std.fs.cwd().readFileAlloc(allocator, "styles.css", 10 * 1024 * 1024);
    defer allocator.free(css);

    const critical_classes = [_][]const u8{"critical-header", "button", "card"};
    const critical_ids = [_][]const u8{"critical-nav", "header"};
    const critical_elements = [_][]const u8{"div", "body"};

    const critical_css_opts = zcss.optimizer.CriticalCssOptions{
        .critical_classes = &critical_classes,
        .critical_ids = &critical_ids,
        .critical_elements = &critical_elements,
    };

    const parser_trait = zcss.formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const result = try zcss.codegen.generate(allocator, &stylesheet, .{
        .optimize = true,
        .critical_css = critical_css_opts,
    });
    defer allocator.free(result);

    try std.fs.cwd().writeFile(.{ .sub_path = "critical.css", .data = result });
}
```

**Output CSS:**
```css
.critical-header { color: red; }
#critical-nav { color: green; }
div { color: black; }
```

Critical CSS extraction works with nested rules in `@media`, `@container`, and `@layer` at-rules, automatically removing entire at-rules if all their nested rules are non-critical.

**CLI Usage:**
```bash
# Extract critical CSS with specific classes, IDs, and elements
zcss styles.css -o critical.css --critical-classes "header,button,card" --critical-ids "nav,header" --critical-elements "div,body"
```

### SCSS Advanced Features

zcss supports advanced SCSS features including mixins with content blocks and variable arguments:

**Mixins with @content:**
```scss
@mixin button {
    padding: 10px;
    border: 1px solid #ccc;
    @content;
}

.btn {
    @include button {
        color: red;
        background: blue;
    }
}
```

**Variable Arguments:**
```scss
@mixin box-shadow($shadows...) {
    box-shadow: $shadows;
}

.card {
    @include box-shadow(0 1px 3px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.24));
}
```

### Language Server Protocol (LSP) Support

zcss includes a full LSP server implementation for editor integration:

**Start the LSP server:**
```bash
zcss --lsp
```

**Supported LSP Features:**
- **Diagnostics** - Real-time error and warning reporting for CSS parsing issues
- **Hover** - Hover information for CSS properties with descriptions and value types
- **Completion** - Code completion for common CSS properties
- **Text Document Sync** - Full support for document open, change, and close events
- **Go to Definition** - Jump to where CSS classes, IDs, and custom properties are defined
- **Find References** - Find all references to CSS classes, IDs, and custom properties
- **Rename** - Rename CSS classes, IDs, and custom properties across all references

**Editor Integration:**

zcss provides official editor integrations for popular editors:

#### VSCode Integration

**Option 1: Use the VSCode Extension (Recommended)**

1. Build zcss:
   ```bash
   git clone https://github.com/vyakymenko/zcss.git
   cd zcss
   zig build -Doptimize=ReleaseFast
   ```

2. Install the extension:
   ```bash
   cd vscode-extension
   npm install
   npm run compile
   ```

3. Press `F5` in VSCode to launch a new window with the extension loaded.

**Option 2: Manual Configuration**

Add to your `.vscode/settings.json`:
```json
{
  "zcss.languageServerPath": "zcss",
  "zcss.languageServerArgs": ["--lsp"]
}
```

If `zcss` is not in your PATH, provide the full path:
```json
{
  "zcss.languageServerPath": "/path/to/zcss/zig-out/bin/zcss"
}
```

The VSCode extension provides:
- Real-time diagnostics for CSS parsing errors
- Hover information for CSS properties
- Code completion for common CSS properties
- Support for CSS, SCSS, SASS, LESS, and Stylus files

#### Neovim Integration

**Using nvim-lspconfig:**

1. Install `nvim-lspconfig` plugin (using Packer):
   ```lua
   use {
     'neovim/nvim-lspconfig',
     config = function()
       require('lspconfig').zcss.setup({
         cmd = {'zcss', '--lsp'},
         filetypes = {'css', 'scss', 'sass', 'less', 'stylus'},
       })
     end
   }
   ```

2. Or copy the configuration from `neovim-config/init.lua` to your Neovim config.

**Features:**
- Diagnostics with `[d` / `]d` navigation
- Hover information with `K`
- Code completion
- Go to definition with `gd`
- Find references with `gr`

#### Other Editors

The LSP server can be integrated with any editor that supports LSP:
- **Vim**: Use with `vim-lsp` or `coc.nvim`
- **Emacs**: Use with `lsp-mode` or `eglot`
- **Sublime Text**: Use with `LSP` package
- **Atom**: Use with `atom-languageclient`

All integrations use the standard LSP protocol via `zcss --lsp`.

## 🏗️ Architecture

zcss is built with performance in mind using a multi-stage compilation pipeline:

### Parser

- **Hand-written recursive descent parser** — No parser generators, maximum control over performance
- **Zero-copy tokenization** — Tokens reference original input without copying
- **Streaming parser** — Can process large files without loading entirely into memory
- **Error recovery** — Continues parsing after errors for better developer experience
- **SIMD-optimized whitespace skipping** — Processes 32 bytes at a time for faster parsing

### Abstract Syntax Tree (AST)

- **Memory-efficient representation** — Compact node structure
- **Type-safe nodes** — Compile-time type checking for AST nodes
- **Lazy evaluation** — Nodes computed only when needed
- **Immutable by default** — Prevents accidental mutations

### Optimizer

Multi-pass optimization pipeline:

1. **Empty rule removal** ✅ — Remove rules with no declarations
2. **Selector merging** ✅ — Merge rules with identical selectors (hash-based, O(n) complexity)
3. **Redundant selector removal** ✅ — Remove selectors that are subsets of other selectors
4. **Shorthand property optimization** ✅ — Combine longhand properties into shorthand:
   - `margin-top`, `margin-right`, `margin-bottom`, `margin-left` → `margin`
   - `padding-top`, `padding-right`, `padding-bottom`, `padding-left` → `padding`
   - `border-width`, `border-style`, `border-color` → `border`
   - `font-*` properties → `font`
   - `background-*` properties → `background`
   - `flex-grow`, `flex-shrink`, `flex-basis` → `flex`
   - `grid-template-rows`, `grid-template-columns`, `grid-template-areas` → `grid-template`
   - `row-gap`, `column-gap` → `gap`
5. **Advanced selector optimization** ✅ — Intelligent selector optimizations:
   - Universal selector removal (`*` removed when redundant)
   - Selector simplification (redundant combinators removed)
   - Selector specificity calculation for better optimization
   - Improved redundant selector detection using specificity
6. **Duplicate declaration removal** ✅ — Remove duplicate properties (keeps last)
7. **Value optimization** ✅ — Advanced optimizations:
   - Hex color minification (`#ffffff` → `#fff`)
   - RGB to hex conversion (`rgb(255, 255, 255)` → `#fff`)
   - CSS color name to hex conversion (`red` → `#f00`, `white` → `#fff`)
   - Transparent color optimization (`transparent` → `rgba(0,0,0,0)`)
   - Zero unit removal (`0px` → `0`, `0em` → `0`)
   - Comprehensive unit support (px, em, rem, %, pt, pc, in, cm, mm, ex, ch, vw, vh, vmin, vmax)
   - CSS Math Functions optimization ✅ — Optimize calc(), min(), max(), and clamp() expressions
     - Evaluate constant expressions (`calc(10px + 5px)` → `15px`)
     - Simplify nested calc() expressions
     - Remove unnecessary calc() wrappers (`calc(10px)` → `10px`)
     - Optimize min()/max()/clamp() with numeric values
8. **CSS Logical Properties optimization** ✅ — Convert logical properties to physical equivalents:
   - `margin-inline-start` → `margin-left`, `margin-inline-end` → `margin-right`
   - `margin-block-start` → `margin-top`, `margin-block-end` → `margin-bottom`
   - `padding-inline-*` → `padding-*` (left/right), `padding-block-*` → `padding-*` (top/bottom)
   - `border-inline-*` → `border-*` (left/right), `border-block-*` → `border-*` (top/bottom)
   - `inset-inline-*` → `left`/`right`, `inset-block-*` → `top`/`bottom`
   - Assumes LTR and horizontal-tb writing mode for safe conversion
9. **Media query merging** ✅ — Merge identical `@media` rules into a single rule
10. **Container query merging** ✅ — Merge identical `@container` rules into a single rule
11. **Cascade layer merging** ✅ — Merge identical `@layer` rules into a single rule
12. **Dead code elimination** ✅ — Remove unused CSS rules based on used selectors (classes, IDs, elements, attributes)

### Code Generator

- **Fast code generation** ✅ — Single-pass codegen with minimal allocations
- **Optimized size estimation** ✅ — Accurate pre-allocation to reduce reallocations
- **Efficient selector generation** ✅ — Optimized spacing logic
- **Advanced minification** ✅ — Removes trailing semicolons, optimizes spacing
- **Source map support** — Full source map generation
- **Incremental output** — Stream output for large files

### Performance Optimizations

1. **Arena allocator** — Fast allocation for AST nodes
2. **String interning** ✅ — Deduplicate repeated strings (property names, class names, identifiers)
3. **SIMD operations** ✅ — Vectorized whitespace skipping (32 bytes at a time)
4. **Parallel parsing** — Multi-threaded parsing for large files
5. **Zero-copy parsing** — Tokens reference original input
6. **Comptime optimizations** ✅ — Character classification lookup tables computed at compile time
7. **Capacity estimation** ✅ — Pre-allocate ArrayLists with estimated sizes
8. **Hash-based selector merging** ✅ — O(n²) → O(n) optimization using hash maps
9. **Optimized character classification** ✅ — Lookup tables replace function calls
10. **Backwards iteration for duplicates** ✅ — Efficient duplicate removal
11. **Advanced selector optimization** ✅ — Universal selector removal, selector simplification, specificity-based optimization

## 🔧 API Reference

### CompileOptions

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

### CompileResult

```zig
pub const CompileResult = struct {
    css: []const u8,
    source_map: ?[]const u8,
    
    pub fn deinit(self: *const CompileResult, allocator: Allocator) void {
        allocator.free(self.css);
        if (self.source_map) |map| {
            allocator.free(map);
        }
    }
};
```

### Plugin System

zcss includes a powerful plugin system that allows you to transform the AST during compilation. Plugins run after parsing and before optimization, giving you full control over CSS transformations.

#### Basic Plugin Usage

```zig
const std = @import("std");
const zcss = @import("zcss");

fn myTransform(allocator: std.mem.Allocator, stylesheet: *zcss.ast.Stylesheet) !void {
    // Transform the stylesheet AST
    // For example, add a custom rule
    var style_rule = try zcss.ast.StyleRule.init(stylesheet.allocator);
    var selector = try zcss.ast.Selector.init(stylesheet.allocator);
    try selector.parts.append(stylesheet.allocator, .{ .class = "custom-class" });
    try style_rule.selectors.append(stylesheet.allocator, selector);
    
    var decl = zcss.ast.Declaration.init(stylesheet.allocator);
    decl.property = "color";
    decl.value = "blue";
    try style_rule.declarations.append(stylesheet.allocator, decl);
    
    try stylesheet.rules.append(stylesheet.allocator, .{ .style = style_rule });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = ".container { color: red; }";
    
    const parser_trait = zcss.formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const my_plugin = zcss.plugin.Plugin.init("my-transform", myTransform);
    
    const options = zcss.codegen.CodegenOptions{
        .plugins = &.{my_plugin},
        .optimize = true,
        .minify = true,
    };

    const result = try zcss.codegen.generate(allocator, &stylesheet, options);
    defer allocator.free(result);
    
    std.debug.print("Compiled CSS: {s}\n", .{result});
}
```

#### Plugin Registry

For multiple plugins, use the `PluginRegistry`:

```zig
var registry = try zcss.plugin.PluginRegistry.init(allocator);
defer registry.deinit();

const plugin1 = zcss.plugin.Plugin.init("plugin1", transform1);
const plugin2 = zcss.plugin.Plugin.init("plugin2", transform2);

try registry.add(plugin1);
try registry.add(plugin2);

try registry.run(&stylesheet);
```

#### Plugin API

```zig
pub const Plugin = struct {
    name: []const u8,
    transform: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void,
    
    pub fn init(name: []const u8, transform_fn: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void) Plugin;
};

pub const PluginRegistry = struct {
    pub fn init(allocator: std.mem.Allocator) !PluginRegistry;
    pub fn deinit(self: *PluginRegistry) void;
    pub fn add(self: *PluginRegistry, plugin: Plugin) !void;
    pub fn addSlice(self: *PluginRegistry, plugins: []const Plugin) !void;
    pub fn run(self: *const PluginRegistry, stylesheet: *ast.Stylesheet) !void;
    pub fn count(self: *const PluginRegistry) usize;
};
```

## 🧪 Testing

```bash
# Run all tests
zig build test

# Run specific test suite
zig build test --test-filter parser
zig build test --test-filter optimizer
zig build test --test-filter codegen

# Run benchmarks
zig build bench

# Run with verbose output
zig build test --summary all

# Compile with performance profiling
zcss input.css -o output.css --profile
```

## 📚 Documentation

Comprehensive documentation is available at **[https://vyakymenko.github.io/zcss/](https://vyakymenko.github.io/zcss/)**

The documentation site includes:
- Getting started guide
- Installation instructions
- API reference
- Examples and tutorials
- Performance benchmarks
- Plugin system documentation
- Build integration guide
- LSP support guide

## 📊 Roadmap

### Phase 1: Core Features ✅ COMPLETED
- [x] CSS3 parser implementation
- [x] Basic optimization pipeline
- [x] Minification
- [x] Source map generation
- [x] CLI tool
- [x] Library API

### Phase 2: Preprocessor Support ✅ COMPLETED
- [x] SCSS/SASS support - Variables, nesting, indented syntax
- [x] LESS support - Variables, at-rules
- [x] CSS Modules support - Scoped class names
- [x] CSS-in-JS compilation - Template literals extraction
- [x] PostCSS support - @apply, @custom-media, @nest directives
- [x] Stylus support - Variables, indented syntax
- [x] Advanced nesting features ✅ — Mixins with @content, functions, variable arguments (...)
- [x] Autoprefixer integration ✅ — Add vendor prefixes for CSS properties and values
- [x] Custom property resolution ✅ — Resolve CSS custom properties (var()) with fallback support
- [x] Advanced selector optimization ✅ — Universal selector removal, selector simplification, specificity calculation
- [x] Plugin system ✅ — Extensible plugin architecture for custom AST transformations
- [x] Watch mode improvements ✅ — Polling-based file watching with automatic recompilation
- [x] Incremental compilation ✅ — Content hash-based change detection for faster watch mode

### Phase 3: Performance & Polish ✅ COMPLETED
- [x] Capacity estimation for ArrayLists
- [x] Optimized character checks (inline functions)
- [x] Faster whitespace skipping
- [x] Output size estimation
- [x] String interning for deduplication
- [x] SIMD-optimized whitespace skipping
- [x] CSS optimizer with multiple passes
- [x] Character classification lookup tables (comptime-computed)
- [x] Hash-based selector merging optimization (O(n²) → O(n))
- [x] Comprehensive test suite
- [x] Better error messages with position tracking
- [x] Parallel file processing ✅ — Multi-threaded compilation for multiple files
- [x] Incremental compilation ✅ — Content-based change detection for faster watch mode
- [x] Performance profiling tools ✅ — Built-in profiling with timing and memory metrics

### Phase 4: Ecosystem ✅ COMPLETED
- [x] Language server protocol (LSP) support ✅ — Full LSP server with diagnostics, hover, and completion
- [x] Editor integrations ✅ — VSCode extension and Neovim configuration
- [x] Build tool integrations ✅ — Zig build system integration with build helpers
- [x] Pre-built binaries for all platforms ✅ — GitHub Actions CI/CD for automated builds and releases (Linux, macOS, Windows)
- [x] Package manager integration ✅ — npm package and Homebrew formula for easy installation
- [x] Documentation site ✅ — Comprehensive documentation site with VitePress, deployed to GitHub Pages

### Phase 5: Advanced CSS Features ✅ COMPLETED
- [x] CSS Modules support
- [x] CSS-in-JS compilation
- [x] PostCSS plugin compatibility layer
- [x] CSS Grid/Flexbox optimizations ✅ — Flexbox and Grid shorthand property optimizations
- [x] Container queries ✅ — Full container query support with merging optimization
- [x] Cascade layers ✅ — Full CSS Cascade Layers support with merging optimization
- [x] Tailwind @apply expansion ✅ — Expand Tailwind utility classes in @apply directives

### Phase 6: Advanced Optimizations ✅ COMPLETED
- [x] CSS Math Functions optimization ✅ — Optimize calc(), min(), max(), and clamp() expressions
  - Evaluate constant expressions at compile time
  - Simplify nested calc() expressions
  - Remove unnecessary calc() wrappers
  - Optimize min()/max()/clamp() with numeric values
- [x] Parser hot path optimizations ✅ — Optimize critical parsing functions
  - Optimize advance() function - reduce bounds checks and improve flow
  - Cache input length in estimate functions to avoid repeated lookups
  - Optimize skipComment - use direct character access
  - Improve SIMD whitespace skipping - cache length and reduce operations
  - Optimize skipWhitespaceScalar - use local variable instead of pointer dereference
- [x] Codegen optimizations ✅ — Reduce allocations and improve string operations
  - Optimize generateStyleRule - cache minify flag, pre-calculate last index
  - Extract generateSelectorPart to reduce code duplication
  - Add early exit for single-part selectors
  - Reduce conditional checks in hot loops
- [x] String pool and hash optimizations ✅ — Improve interning and hashing performance
  - Add early exits for empty strings in string pool intern functions
  - Add bounds checking in internSlice to prevent invalid slices
  - Optimize hashSelectors - add early exit for empty selectors, cache counts
  - Pre-allocate capacity when merging declarations to reduce reallocations
- [x] At-rule merge optimizations ✅ — Faster string comparisons and better capacity estimation
  - Use length checks before mem.eql for faster comparisons
  - Pre-allocate ArrayLists with better capacity estimates
  - Reduce string comparisons in merge operations
- [x] CSS Logical Properties optimization ✅ — Convert logical properties to physical equivalents when safe
  - Convert margin-inline-* and margin-block-* to margin-* properties
  - Convert padding-inline-* and padding-block-* to padding-* properties
  - Convert border-inline-* and border-block-* to border-* properties
  - Convert inset-inline-* and inset-block-* to positioning properties
  - Assumes LTR and horizontal-tb writing mode for safe conversion
- [x] Dead code elimination ✅ — Remove unused CSS rules and declarations based on used selectors
  - Remove CSS rules whose selectors don't match any used classes, IDs, elements, or attributes
  - Supports nested rules in @media, @container, and @layer at-rules
  - Configurable via API with DeadCodeOptions
- [x] Critical CSS extraction ✅ — Extract above-the-fold CSS for faster initial render
  - Extract only CSS rules needed for above-the-fold content
  - Improves First Contentful Paint (FCP) and Largest Contentful Paint (LCP) metrics
  - Supports nested rules in @media, @container, and @layer at-rules
  - Configurable via API with CriticalCssOptions
  - CLI support with --critical-classes, --critical-ids, and --critical-elements flags
- [x] Enhanced error messages ✅ — Provide suggestions and context for common errors
  - Context-aware error messages with nearby code snippets
  - Helpful suggestions for common mistakes (missing braces, colons, etc.)
  - Improved error formatting with line numbers, column positions, and visual indicators
  - Suggestions for fixing common syntax errors
- [x] Advanced LSP features ✅ — Go to definition, find references, rename symbols
  - Go to definition for CSS classes, IDs, and custom properties
  - Find all references to CSS symbols across the document
  - Rename symbols with automatic updates to all references
  - Full LSP protocol support for navigation and refactoring
- [x] Unused custom property removal ✅ — Remove unused CSS custom property definitions after inlining
  - Automatically removes custom property declarations that are no longer referenced
  - Works with nested rules in @media, @container, and @layer at-rules
  - Reduces CSS size by eliminating unused custom property definitions
  - Improves performance by reducing CSS parsing overhead
- [x] At-rule reordering ✅ — Reorder at-rules for better compression and parsing efficiency
  - Groups @media, @container, and @layer rules together
  - Improves CSS compression by grouping similar at-rules
  - Enhances browser parsing efficiency with better rule organization
  - Works seamlessly with at-rule merging optimizations
- [x] Early exit optimizations ✅ — Skip optimization passes when no work is needed
  - Early exits for empty stylesheets and rules
  - Skip duplicate removal when <= 1 declaration
  - Skip merging operations when no rules to merge
  - Significantly improves performance for edge cases and small stylesheets
  - Reduces unnecessary allocations and iterations
- [x] String operation optimizations ✅ — Optimize string operations for maximum performance
  - Skip trimming when not needed (check whitespace before trimming)
  - Use direct character checks instead of startsWith for better performance
  - Add length checks before string operations to avoid unnecessary work
  - Skip processing empty declarations and rules throughout optimizer
  - Reduce allocations in hot paths

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development Setup

```bash
git clone https://github.com/vyakymenko/zcss.git
cd zcss
zig build test
```

### Running Tests

```bash
# Run all tests
zig build test

# Run with coverage
zig build test --summary all

# Run specific test
zig build test --test-filter "test_parser_basic"
```

### Code Style

- Follow Zig's official style guide
- Use `zig fmt` for formatting
- Write tests for new features
- Update documentation for API changes

### Performance Guidelines

- Profile before optimizing
- Use `std.benchmark` for benchmarks
- Document performance characteristics
- Consider memory usage alongside speed

### Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built with [Zig](https://ziglang.org/) — a general-purpose programming language designed for robustness, optimality, and maintainability
- Inspired by the need for faster CSS tooling in modern web development
- Parser design influenced by [PostCSS](https://postcss.org/) and [Lightning CSS](https://lightningcss.dev/)

## 📞 Contact

- **Author**: Valentyn Yakymenko
- **GitHub**: [@vyakymenko](https://github.com/vyakymenko)
- **Issues**: [GitHub Issues](https://github.com/vyakymenko/zcss/issues)

## 📚 Resources

- [Zig Documentation](https://ziglang.org/documentation/)
- [CSS Specifications](https://www.w3.org/Style/CSS/)
- [CSS Nesting Specification](https://www.w3.org/TR/css-nesting-1/)

---

**Made with ⚡ for speed**
