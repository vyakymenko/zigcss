# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Performance Improvements
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
