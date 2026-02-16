# zigcss

> **The world's fastest CSS compiler** — Built with Zig for uncompromising performance

**zigcss** is a zero-dependency CSS compiler written in Zig, designed from the ground up to be the fastest CSS processing tool available. Leveraging Zig's compile-time optimizations, memory safety, and zero-cost abstractions, zigcss delivers unmatched performance for CSS parsing, transformation, and compilation.

## 🚀 Why zigcss?

- ⚡ **81-127x faster** than PostCSS and Sass for small files
- 🔒 **Memory safe** — Zig's safety guarantees prevent common bugs
- 📦 **Zero dependencies** — Single binary, no runtime requirements
- 🎯 **Full CSS3 support** — Complete CSS specification compliance
- 🔧 **Extensible** — Plugin system for custom transformations
- 🧩 **Modular** — Use as a library or standalone CLI tool

## Quick Start

```bash
# Install via npm
npm install -g zigcss

# Or via Homebrew
brew tap vyakymenko/zigcss
brew install zigcss

# Compile CSS
zigcss input.css -o output.css --optimize --minify
```

## Performance

Performance tested on a MacBook Pro M3 (16GB RAM) with real-world CSS workloads.

| File Size | zigcss | PostCSS | Sass |
|-----------|------|---------|------|
| Small (~100 bytes) | **6.7ms** | 546.9ms (81.6x slower) | 855.0ms (127.6x slower) |
| Medium (~10KB) | **6.7ms** | 570.1ms (85.4x slower) | 589.7ms (88.2x slower) |
| Large (~100KB) | **56.0ms** | 528.2ms (9.4x slower) | 634.3ms (11.3x slower) |

## Features

- 🎨 **CSS Nesting** — Native support for CSS Nesting specification
- 🔄 **Custom Properties** — Full CSS custom properties (variables) support
- 📐 **Media Queries** — Advanced media query parsing and optimization
- 📦 **Container Queries** — Full CSS Container Queries support
- 🎭 **Pseudo-classes** — Complete pseudo-class and pseudo-element support
- 📋 **Preprocessor Support** — SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules
- 🚀 **Parallel Processing** — Multi-threaded compilation for multiple files
- 🔧 **Plugin System** — Extensible plugin architecture
- 📝 **Source Maps** — Full source map generation support
- 🎯 **LSP Support** — Language Server Protocol for editor integration

## Get Started

- [Installation Guide](/guide/installation)
- [Quick Start Tutorial](/guide/quick-start)
- [API Reference](/api/compile-options)
- [Examples](/examples/css-nesting)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

[View on GitHub](https://github.com/vyakymenko/zigcss)
