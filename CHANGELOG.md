# Changelog

> Recovery note: entries below describe prototype implementation history, not current compatibility guarantees. ZigCSS prereleases and their experimental adapters follow the active contract in `README.md`.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No later stable identity is selected.

### Changed

- Retire the completed autonomous roadmap, verbose execution ledger, stopped runner, and obsolete prototype fixtures after stable publication; Git history retains the full audit trail while ADRs and machine-readable release contracts remain maintained.
- Document the exact tooling boundary: the native CLI and Zig build helper are verified, the website's Vite usage is not a public ZigCSS plugin, and Webpack, Rollup, esbuild, Nx, and framework-specific adapters remain unimplemented and unclaimed.
- Replace the overflowing small-screen header links with an accessible mobile navigation panel, restore canonical and reload-safe hash links plus sticky-header scrolling, keep every primary destination keyboard reachable, and render a branded fallback instead of a blank first-load frame.

## [0.6.0] - 2026-08-18

Released as immutable tag `v0.6.0`, non-prerelease GitHub Release `372291445`, and `zigcss@0.6.0` on npm `latest` with provenance.

Stable `0.6.0` promotes the exact self-contained native surface proven by immutable `0.6.0-rc.2`; it does not move, replace, or republish the RC. Release run `32130950531` passed on attempt 1 with five architecture-matched archives, 25 signed assets, npm SLSA provenance, preserved `next`, and anonymous CSS/SCSS/Sass/Less/Stylus installation. The package retains zero production and optional dependencies, deterministic and fail-closed compilation, and explicit plugin boundaries.

### Changed

- Remove the release-candidate warning from the stable CLI while keeping unavailable transforms, executable plugins, arbitrary project code, and experimental library/editor surfaces explicitly bounded.
- Make the tag workflow choose GitHub prerelease state and npm `next`/`latest` from canonical SemVer, with exact-main and stable-promotion interlocks before authentication or artifacts.
- Refresh the README, npm metadata, getting-started flow, capability pages, release notes, and terminal website around the verified native product.
- Add static canonical metadata for public routes, software-source structured data, a crawl policy, and an XML sitemap for the GitHub Pages project site.
- Keep every comparative timing, ranking, throughput, memory, ratio, and superlative speed claim withdrawn until the controlled non-emulated Linux x64 benchmark archive passes its publication gate.

## [0.6.0-rc.2] - 2026-08-13

Target release: `0.6.0-rc.2` (published as a GitHub prerelease and on npm `next`).

The provider-backed `0.5.0-rc.1` historical reference identity remains ineligible for publication. The native `0.6.0-rc.1` candidate failed closed during automatic Windows hosted validation before any tag or publication, so it remains immutable failure evidence. Replacement candidate `0.6.0-rc.2` was selected only after its GitHub tag and npm version were proven unused; every ordered pre-tag `NATIVE-009` evidence surface is now verified.

`NATIVE-008` closes the finite source-capability inventory for the self-contained native stylesheet frontends: machine rows, binary help, README, website lab, compiled examples, compatibility guides, and these migration notes describe one self-contained implementation. `NATIVE-009` graduates all four preprocessor rows together; `nativeReleaseReady` is `true` for exact candidate `0.6.0-rc.2`, and its one immutable tag workflow produced the verified GitHub prerelease, 25 release assets, and npm `next` package with provenance while npm `latest` remained stable.

### Added

- Add self-contained native Zig parser/evaluators for SCSS, indented Sass, Less, and Stylus, with confined imports, owned diagnostics/dependencies, deterministic composed maps, bounded resources, cancellation, and strict recovery-disabled validation of generated CSS.
- Add the explicit `zigcss.experimental_native` Zig namespace and stable source-built binary routes for the finite `scss`, `sass`, `less`, and `stylus` syntax set. CSS remains on the stable `zigcss.compile` facade.
- Add a parameterized compiled Zig API example and five finite binary input examples. The documentation build executes every row and checks exact minified output.
- Add a five-tab native website input/output lab whose recorded fixtures execute through the source-built ZigCSS binary.

### Changed

- Replace the prototype's stable CSS path with the tested tokenizer, typed parser/emitter, bounded CLI/API, verified transform plan, LSP/editor integrations, and release-integrity gates described by the generated capability matrix.
- Remove canonical providers from the production stylesheet path and package closure. Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 remain exact development-only reference oracles and do not run during compilation.
- Reduce the native package contract to zero production dependencies and zero optional dependencies. The compiler starts no child language process, performs no network access, and requires no runtime download; the JavaScript wrapper only locates and invokes the native binary.
- Keep arbitrary preprocessor plugins, custom functions/importers, Less JavaScript, Stylus evaluator hooks, executable project code, CSS-in-JS/PostCSS/Tailwind-like adapters, native plugins, extraction passes, editor packages, and the public compile service outside the graduated contract.
- Preserve explicit CLI migration: source users select `--syntax scss|sass|less|stylus` and optional confined `--load-path` roots. Zig consumers use `zigcss.experimental_native`; the stable CSS API and build helper remain CSS-only. The former programmatic provider-backed JavaScript preprocessor API is not part of this source contract.
- Keep the unpublished provider-backed `0.5.0-rc.1` identity ineligible for release. Every future native archive must pass the architecture-matched offline package, provenance, artifact, consumer, and hosted gates under `NATIVE-009` before any separately authorized publication.

## [0.3.0] - 2026-03-20

### Features
- Add comprehensive SCSS support with full preprocessor pipeline
- Add SCSS `//` single-line comment stripping
- Add SCSS `#{}` interpolation in selectors and property values
- Add SCSS `!default` flag for conditional variable assignment
- Add SCSS nesting with `&` parent selector (BEM `&__item`, `&--mod`, pseudo `&:hover`)
- Add SCSS descendant nesting (`.parent { .child {} }` → `.parent .child {}`)
- Add SCSS `@for $i from X through/to Y {}` loop directive
- Add SCSS `@each $var in list {}` with comma-separated lists and `$key, $value` map iteration
- Add SCSS `@if` / `@else if` / `@else` conditional blocks with comparison operators
- Add SCSS `@while` loop directive with max-iteration safety (1000)
- Add SCSS `%placeholder` selector extraction and `@extend %name` directive
- Add SCSS `@warn`, `@error`, `@debug` directive stripping
- Add SCSS `@import`, `@use`, `@forward` directive stripping
- Add SCSS built-in function support: `map-get`, `map-has-key` for map lookups
- Add SCSS math functions: `round`, `ceil`, `floor`, `abs`, `min`, `max`, `percentage`
- Add SCSS string functions: `to-upper-case`, `to-lower-case`, `str-length`, `unquote`, `quote`
- Add SCSS utility functions: `type-of`, `if()`, `unique-id`, `strip-unit`, `nth`, `length`
- Add SCSS color function passthrough: `lighten`, `darken`, `rgba`, `rgb`, `hsl`, `hsla`, `mix`, `saturate`, `desaturate`, `adjust-hue`, `opacify`, `transparentize`
- Add full-file variable, mixin, and function collection scan
- Add Control Flow and Built-in Functions to website comparison table

### Tests
- Add 19 new SCSS unit tests covering all implemented features (76 total Zig tests)
- Add 7 new website component tests for Features page (11 total)
- Add comprehensive SCSS integration test file (`parsing/integration_test.scss`)

## [0.2.0] - 2026-02-16

### Features
- Add early exit optimizations - skip optimization passes when no work is needed
- Add early exits for empty stylesheets and rules in all optimization functions
- Skip duplicate removal when <= 1 declaration for better performance
- Skip merging operations when no rules to merge
- Add at-rule reordering optimization - reorder @media, @container, and @layer rules for better compression and parsing efficiency
- Group similar at-rules together to improve CSS compression
- Add comprehensive test coverage for at-rule reordering
- Add unused custom property removal optimization - automatically removes CSS custom property definitions that are no longer referenced after inlining
- Add removeUnusedCustomProperties function to optimizer - removes unused custom property declarations from stylesheet
- Add support for removing unused custom properties in nested rules (@media, @container, @layer)
- Add comprehensive test coverage for unused custom property removal

### Performance Improvements
- Optimize string operations - skip trimming when not needed, use direct character checks
- Add length checks before string operations to avoid unnecessary work
- Skip processing empty declarations and rules throughout optimizer
- Reduce allocations in hot paths by checking collection sizes first
- Add early exit optimizations - significantly improves performance for edge cases and small stylesheets
- Reduce unnecessary allocations and iterations by skipping optimization passes when no work is needed
- Improve performance for empty stylesheets and rules with single declarations
- Add at-rule reordering - improves CSS compression by grouping similar at-rules together
- Improve browser parsing efficiency with better rule organization
- Add unused custom property removal - reduces CSS size by eliminating unused custom property definitions after inlining
- Improve CSS compilation performance by removing unnecessary custom property declarations
- Optimize parser hot paths - reduce bounds checks in advance(), cache input lengths, optimize skipComment
- Improve SIMD whitespace skipping - cache length and reduce pointer operations
- Optimize codegen - cache flags, pre-calculate indices, extract common patterns
- Optimize string pool - add early exits for empty strings, improve bounds checking
- Optimize hash operations - cache counts, pre-allocate capacity, reduce reallocations
- Optimize at-rule merging - use length checks before string comparisons for faster matching
- Optimize parser hot paths - parseIdentifier, parseDeclaration, parseSelector, parseStyleRule
- Reduce bounds checks and function calls in parser loops
- Optimize optimizer loops - cache lengths, pre-allocate hash maps, reduce lookups
- Improve loop performance by caching collection sizes throughout optimizer

### Features
- Add advanced LSP features - go to definition, find references, and rename symbols
- Add textDocument/definition handler for CSS classes, IDs, and custom properties
- Add textDocument/references handler to find all references to CSS symbols
- Add textDocument/rename handler for renaming CSS symbols across all references
- Add symbol tracking and position calculation utilities for LSP navigation
- Add enhanced error messages with suggestions and context for common errors
- Add context-aware error messages showing nearby code snippets
- Add helpful suggestions for fixing common syntax errors (missing braces, colons, etc.)
- Improve error formatting with better visual indicators and suggestions
- Add critical CSS extraction - extract above-the-fold CSS for faster initial render
- Add CriticalCssOptions API for configuring critical CSS extraction with critical selectors (classes, IDs, elements, attributes)
- Add critical CSS extraction support for nested rules in @media, @container, and @layer at-rules
- Add CLI flags for critical CSS extraction: --critical-classes, --critical-ids, --critical-elements
- Add comprehensive test coverage for critical CSS extraction
- Add dead code elimination optimization - remove unused CSS rules based on used selectors (classes, IDs, elements, attributes)
- Add DeadCodeOptions API for configuring dead code elimination with used selectors
- Add dead code elimination support for nested rules in @media, @container, and @layer at-rules
- Add comprehensive test coverage for dead code elimination
- Add documentation site - comprehensive documentation built with VitePress
- Add VitePress configuration - modern documentation site with search, navigation, and GitHub Pages deployment
- Add documentation pages - getting started guide, installation, API reference, examples, and advanced topics
- Add GitHub Pages deployment workflow - automated documentation deployment on push to main/development branches
- Add documentation site link to README - direct link to documentation site
- Add GitHub Actions CI/CD workflows - automated builds and releases for all platforms
- Add build workflow - test and build binaries for Linux, macOS, and Windows on every push
- Add release workflow - automatically create GitHub releases with pre-built binaries on version tags
- Add multi-platform binary support - x86_64 and aarch64 for Linux and macOS, x86_64 for Windows
- Add pre-built binaries documentation - installation instructions for all supported platforms
- Add npm package integration - install zigcss globally via `npm install -g zigcss`
- Add npm install script - automatically downloads appropriate binary for platform during npm install
- Add an experimental, checksum-pinned Homebrew source formula for local verification; no tap is published.
- Add package manager installation instructions to README
- Add VSCode extension - full VSCode integration with LSP support for CSS, SCSS, SASS, LESS, and Stylus files
- Add VSCode extension configuration - package.json, TypeScript extension code, and build configuration
- Add Neovim integration - complete Neovim configuration with nvim-lspconfig setup and key mappings
- Add editor integration documentation - comprehensive setup guides for VSCode and Neovim
- Add VSCode workspace settings - recommended settings for zigcss development
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
- Add CSS Math Functions optimization - optimize calc(), min(), max(), and clamp() expressions
- Add constant expression evaluation for CSS Math Functions - evaluate constant expressions at compile time
- Add calc() wrapper removal - remove unnecessary calc() wrappers when safe
- Add min()/max()/clamp() numeric optimization - optimize math functions with numeric values
- Add CSS Logical Properties optimization - convert logical properties to physical equivalents when safe
- Add logical property conversion for margin, padding, border, and inset properties
- Convert margin-inline-* and margin-block-* to margin-* properties (assumes LTR and horizontal-tb writing mode)
- Convert padding-inline-* and padding-block-* to padding-* properties
- Convert border-inline-* and border-block-* to border-* properties
- Convert inset-inline-* and inset-block-* to positioning properties (left, right, top, bottom)

### Performance Improvements
- Add critical CSS extraction - improves First Contentful Paint (FCP) and Largest Contentful Paint (LCP) by extracting only above-the-fold CSS
- Add dead code elimination optimization - reduces CSS size by removing unused rules based on used selectors
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
- Add CSS Math Functions optimization - reduces CSS size by evaluating and simplifying calc(), min(), max(), and clamp() expressions
- Optimize constant math expressions at compile time for faster runtime performance
- Add CSS Logical Properties optimization - converts logical properties to physical equivalents for better browser compatibility and potential size reduction
- Fix ArrayList initialization for Zig 0.15.2 compatibility - update ArrayList.init() calls to use initCapacity() with proper error handling

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
