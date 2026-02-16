# Getting Started

zcss is a high-performance CSS compiler built with Zig. This guide will help you get started with zcss.

## What is zcss?

zcss is a zero-dependency CSS compiler that processes CSS and various CSS preprocessor formats (SCSS, SASS, LESS, Stylus, PostCSS) into optimized, production-ready CSS.

## Key Features

- **Blazing Fast** — 81-127x faster than competitors
- **Memory Safe** — Built with Zig's safety guarantees
- **Zero Dependencies** — Single binary, no runtime requirements
- **Full CSS3 Support** — Complete CSS specification compliance
- **Extensible** — Plugin system for custom transformations

## Installation

See the [Installation Guide](/guide/installation) for detailed installation instructions.

## Quick Example

```bash
# Compile a CSS file
zcss input.css -o output.css

# With optimizations
zcss input.css -o output.css --optimize --minify

# Watch mode for development
zcss input.css -o output.css --watch
```

## Next Steps

- [Installation](/guide/installation) — Install zcss on your system
- [Quick Start](/guide/quick-start) — Learn the basics
- [Examples](/examples/css-nesting) — See zcss in action
