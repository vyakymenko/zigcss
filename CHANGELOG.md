# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Features
- Add GitHub Actions CI/CD workflows - automated builds and releases for all platforms
- Add build workflow - test and build binaries for Linux, macOS, and Windows on every push
- Add release workflow - automatically create GitHub releases with pre-built binaries on version tags
- Add multi-platform binary support - x86_64 and aarch64 for Linux and macOS, x86_64 for Windows
- Add pre-built binaries documentation - installation instructions for all supported platforms
- Add npm package integration - install zcss globally via `npm install -g zcss`
- Add npm install script - automatically downloads appropriate binary for platform during npm install
- Add Homebrew formula - install zcss via Homebrew on macOS with `brew tap vyakymenko/zcss && brew install zcss`
- Add package manager installation instructions to README
- Add VSCode extension - full VSCode integration with LSP support for CSS, SCSS, SASS, LESS, and Stylus files
- Add VSCode extension configuration - package.json, TypeScript extension code, and build configuration
- Add Neovim integration - complete Neovim configuration with nvim-lspconfig setup and key mappings
- Add editor integration documentation - comprehensive setup guides for VSCode and Neovim
- Add VSCode workspace settings - recommended settings for zcss development
- Add Language Server Protocol (LSP) support - full LSP server implementation for editor integration
- Add LSP diagnostics - real-time error and warning reporting for CSS parsing issues
- Add LSP hover information - hover support for CSS properties with descriptions and value types
- Add LSP code completion - code completion for common CSS properties
- Add --lsp CLI flag to start LSP server mode
- Add LspServer module with JSON-RPC protocol handling and text document synchronization
- Add Tailwind @apply expansion - automatically expand Tailwind utility classes in @apply directives into CSS declarations
- Add SCSS @content directive support - mixins can now accept content blocks using @content
- Add SCSS variable arguments support - mixins and functions can accept variable arguments using ... syntax
- Enhance SCSS mixin expansion with content block processing and variable argument handling
- Add comprehensive Tailwind utility registry with 200+ utility classes covering spacing, colors, typography, layout, flexbox, grid, borders, and effects
- Add TailwindRegistry module for managing and expanding Tailwind utility classes
- Integrate Tailwind @apply expansion into PostCSS processor
- Add CSS Cascade Layers support - full parsing and optimization for @layer at-rules
- Add cascade layer merging optimization - merge identical @layer rules for smaller output
- Add cascade layer test coverage
- Add CSS Grid/Flexbox shorthand optimizations - combine flex-grow/flex-shrink/flex-basis into flex, grid-template-* into grid-template, row-gap/column-gap into gap
- Add container query support - full CSS Container Queries parsing and optimization
- Add container query merging optimization - merge identical @container rules for smaller output
- Add container query test coverage
- Add Zig build system integration - build helpers for seamless CSS compilation in Zig projects
- Add CssCompileStep API for programmatic CSS compilation in build.zig
- Add build_helpers.zig module with addCssCompileStep and addCssCompileStepTo functions
- Add support for configuring CSS compilation options (optimize, minify, autoprefix) in build system
- Add performance profiling tools - built-in profiling system with timing and memory metrics
- Add --profile CLI flag for performance profiling during compilation
- Add benchmark suite with `zig build bench` command
- Add Profiler module for detailed performance analysis (parse, optimize, codegen timing)
- Add benchmarkCompilation function for automated performance testing
- Add plugin system - extensible plugin architecture for custom AST transformations
- Add PluginRegistry for managing multiple plugins
- Add plugin support to CodegenOptions for library API
- Add incremental compilation - content hash-based change detection for faster watch mode
- Add advanced selector optimization - universal selector removal, selector simplification, and specificity-based optimization
- Add parallel file processing - compile multiple files concurrently using all CPU cores
- Add --output-dir flag support for batch compilation of multiple files
- Add glob pattern support for input files (e.g., `src/*.css`)

### Performance Improvements
- Add cascade layer merging optimization - reduces CSS size by combining identical cascade layers
- Fix memory safety issue in media query, container query, and cascade layer merging - properly move rules instead of copying to prevent double-free
- Add CSS Grid/Flexbox shorthand optimizations - reduces CSS size by combining related Grid and Flexbox properties into shorthand form
- Add container query merging optimization - reduces CSS size by combining identical container queries
- Add performance profiling infrastructure for identifying bottlenecks and measuring improvements
- Add detailed timing breakdowns for parse, optimize, and codegen phases
- Add benchmark suite for automated performance regression testing
- Add incremental compilation with content hash tracking - watch mode only recompiles when file content actually changes
- Add advanced selector optimization with universal selector removal and selector simplification
- Add font and background shorthand optimizations
- Add redundant selector removal and media query merging optimizations
- Add transparent color optimization
- Optimize duplicate removal with backwards iteration
- Add border shorthand and color name optimizations
- Optimize selector merging with hash-based approach (O(n²) → O(n))
- Add character classification lookup tables (comptime-computed)
- Optimize codegen with improved size estimation
- Add shorthand property optimization (margin, padding, border)
- Add advanced value optimization (RGB to hex, color names, zero units)
- Add string interning for deduplication
- Add SIMD-optimized whitespace skipping (32 bytes at a time)
- Optimize parser with capacity hints and faster whitespace skipping
- Optimize character checks and string trimming
- Use optimized character checks in selector parsing

### Features
- Add autoprefixer integration with vendor prefix support for CSS properties and values
- Add CSS custom property resolution with var() function support and fallback values
- Add watch mode with automatic recompilation on file changes
- Add basic CSS optimizer with multiple optimization passes
- Enable full optimizer pipeline
- Add better error messages with position tracking (line/column information)

### Bug Fixes
- Fix string pool copying issue
- Fix memory leaks and optimize parser performance
- Close all selectors when encountering selector after property
- Properly handle selector after property in SASS nesting
- Track last line type to properly close selectors after properties
- Correct SASS nesting logic to close parent selectors
- Add CSS conversion for Stylus and fix SASS nesting
- Add infinite loop protection to Stylus parser
- Use local index variable to prevent infinite loop in processVariables
- Completely rewrite Stylus processVariables to fix infinite loop
- Fix infinite loop in Stylus processVariables
- Correct isAlnum function call - remove self prefix
- Fix Stylus variable parsing and optimize codegen
- Update PostCSS custom media test with valid CSS
- Properly skip @apply directives in PostCSS
- Add missing PostCSS and Stylus cases to parser switch
- Only close selectors when encountering a new selector
- Handle optional return from ArrayList.pop() in Zig 0.15
- Use SelectorInfo struct to track selectors and indents
- Correct syntax for freeing selectors in SASS converter
- Fix memory management and nesting in SASS converter
- Convert SASS nested selectors to proper CSS
- Improve SASS nesting conversion logic
- Update SASS test expectations
- Remove duplicate variable parsing in SASS
- Use const for stylesheet in SASS parser
- Process SASS variables in property lines during conversion
- Simplify SASS variable parsing from lines

### Documentation
- Update README with codegen and shorthand optimizations
- Update README with completed optimizations
- Update roadmap with completed features and current status
- Update README with format support and fix Stylus infinite loop

## [0.1.0] - 2026-02-16

### Added
- Initial CSS parser implementation
- SCSS/SASS format support with variables and nesting
- LESS format support with variables and at-rules
- CSS Modules support with scoped class names
- CSS-in-JS compilation with template literals extraction
- PostCSS support with @apply, @custom-media, @nest directives
- Stylus format support with variables and indented syntax
- Basic optimization pipeline
- Minification support
- Source map generation
- CLI tool
- Library API
- Comprehensive test suite (22/22 tests passing)

### Performance
- Zero-copy tokenization
- Streaming parser for large files
- Arena allocator for AST nodes
- Capacity estimation for ArrayLists
- Output size estimation

---

## Types of Changes

- **Added** for new features
- **Changed** for changes in existing functionality
- **Deprecated** for soon-to-be removed features
- **Removed** for now removed features
- **Fixed** for any bug fixes
- **Security** for vulnerability fixes
