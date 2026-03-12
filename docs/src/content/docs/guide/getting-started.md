# Getting Started

zigcss is a high-performance CSS compiler built with Zig. This guide will help you get started with zigcss.

## What is zigcss?

zigcss is a zero-dependency CSS compiler that processes CSS and various CSS preprocessor formats (SCSS, SASS, LESS, Stylus, PostCSS) into optimized, production-ready CSS.

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
zigcss input.css -o output.css

# With optimizations
zigcss input.css -o output.css --optimize --minify

# Watch mode for development
zigcss input.css -o output.css --watch
```

## Next Steps

- [Installation](/guide/installation) — Install zigcss on your system
- [Quick Start](/guide/quick-start) — Learn the basics
- [Examples](/examples/css-nesting) — See zigcss in action
