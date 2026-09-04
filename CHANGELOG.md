# Changelog

> Recovery note: entries below describe prototype implementation history, not current compatibility guarantees. ZigCSS prereleases and their experimental adapters follow the active contract in `README.md`.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No later stable identity is selected.

Planned prerelease target `0.7.0-rc.1` is selected in `release/next-release.json` but remains unpublished with `candidateReady: false` until all seven pre-tag gates pass. Published stable identity remains immutable at `0.6.0`.

### Added

- Add a repository-local, source-checkout-only Nix flake with one commit- and `narHash`-pinned nixpkgs input, exact Zig 0.15.2, explicit package, app, and check outputs for four native Unix systems, a strict source allowlist, and bounded version, CSS, and SCSS install checks. GitHub Actions is configured to fail closed on the static contract before an immutable installer action and then check, build, and run each native output with exact Nix 2.35.2. Bootstrap and input or substitute acquisition remain networked, the versioned installer script is not content-addressed, hosted runner images and the experimental flake CLI remain mutable interfaces, and no nixpkgs or registry publication, binary cache, offline installation, Windows output, module, or stable-release repackaging is claimed.
- Add a typed zero-production-dependency Node.js API at the package root for CommonJS and ESM consumers: `compile`, `compileSync`, `compileFile`, `compileFileSync`, `detectSyntax`, and `ZigCssCompileError` route CSS, SCSS, indented Sass, Less, and Stylus through one bounded native process per call. A direct checkout admits only its regular freshly built `zig-out/bin/zigcss`; an installed package admits only its regular packaged binary. The immutable stable 0.6.0 binary predates this protocol, so published or repacked 0.6.0 is not claimed as a runtime delivery path. The API returns immutable CSS, parsed source maps, diagnostics, and dependencies; exposes fixed-point optimization and explicit target prefixing; supports async timeout and `AbortSignal`; caps sync framed output and both-mode stderr at 4 MiB; and fails closed on malformed or ill-typed transport data, resource limits, cancellation, or compilation errors without partial CSS.
- Add a private length-framed `zigcss-node-v1` native transport for the programmatic API, with exact request/response schemas, bounded UTF-8 JSON, correlated request IDs, strict path/option/query validation, and no shell, temporary-file, provider, plugin, network, or fallback path.
- Add experimental package subpath adapters for Vite, Rollup, esbuild, Bun, Webpack, and Rspack. The factories and shared raw loader use one strict zero-production-dependency core with bounded native-process concurrency, source maps, structured diagnostics, host dependency registration where the API supports it, exact query/fragment identity, UTF-16 host diagnostics where required, CSS Module identity where the host supports it, and atomic failures. Deterministic protocol-fixture tests retain focused host contracts; after the native Debug build, a second real-host layer passes that exact current-checkout binary through Vite, Rollup, esbuild, Bun 1.4.0, Webpack, and Rspack. Bun's current `onLoad` contract does not expose native-import watch files.
- Add a bounded Next.js Turbopack example that reuses only `zigcss/webpack`, with no new public subpath or production dependency. An offline CI gate pins Next.js 16.3.4 and React/ReactDOM 19.2.4, passes the exact current-checkout native binary after the Debug suite, and proves global SCSS output, exact entry/native-import source-map contents, dependency-only persistent-cache rebuilds, package-subpath resolution, and native diagnostics. Configurable loader output module types require Next.js 16.2+; CSS Modules, indented Sass, Less, Stylus, arbitrary SCSS globs, a general Turbopack plugin, wider framework compatibility, and stable-release delivery remain unclaimed. No PostCSS adapter is shipped because the ordinary PostCSS CSS parser receives the input before plugin execution.
- Add a separate exact Next.js 16.3.4 Webpack host proof in the same zero-production-dependency example. One exact-project-file `enforce: 'pre'` rule reuses `zigcss/webpack` before exact downstream Sass 1.101.0; the gate warms an isolated npm cache, repeats `npm ci` offline, blocks public Node network entry points plus direct unsafe binding, Worker, cluster, and unreviewed child-process escapes during `next build --webpack`, and records the staged ZigCSS `--internal-node-v1` process. It verifies prerendered HTML and emitted CSS, requires an unchanged warm build to use the persistent cache with zero native invocations, then changes only `_tokens.scss` and requires both changed output and another native invocation. The JavaScript preload is not an OS sandbox and trusts the exact lock-pinned host/native addons. The final Webpack stylesheet does not retain the original ZigCSS source-map chain, so no map-delivery, HMR/watch, CSS Modules, other-version, dedicated `zigcss/next`, stable-release, or general Next.js compatibility claim is made.
- Add a bounded SvelteKit source-checkout example that reuses `zigcss/vite` before the official SvelteKit plugin for one external `card.module.scss` entry. The zero-production-dependency host lock pins SvelteKit 2.70.3, Svelte 5.57.0, Vite 8.2.2, and adapter-static 3.0.10; its isolated deny-network CI gate passes the exact current native binary after the Debug suite and proves client, SSR, prerender, CSS Module hashing, a native partial, and exact source maps. Embedded styles, Svelte preprocessors, framework HMR/watch invalidation, arbitrary adapters/targets, general SvelteKit compatibility, and stable-release delivery remain unclaimed.
- Add a bounded Astro source-checkout example that registers `zigcss/vite` through Astro's Vite configuration for one external `card.module.scss` import. The exact Astro 7.2.10 gate warms an isolated npm cache, repeats the lockfile install offline, blocks Worker/cluster and unsafe process-binding escapes plus public and internal Node network entry points during the static build, admits only the exact staged ZigCSS and pinned esbuild child processes, passes the freshly built checkout binary, and proves one CSS Module binding in rendered HTML and emitted client JavaScript, a native Sass partial, a fingerprinted SVG asset, and exact composed maps. The JavaScript proof is not an OS sandbox and trusts the exact pinned host/native addons. Embedded Astro styles, HMR/watch invalidation, SSR adapters, every renderer, framework aliases, a `zigcss/astro` export, and stable-release delivery remain unclaimed.
- Add a bounded Nuxt source-checkout example that registers `zigcss/vite` through Nuxt's Vite configuration for one external `card.module.scss` import. The exact Nuxt 4.5.2 gate blocks Worker/cluster and unsafe process-binding escapes plus public and internal Node network entry points, admits only the exact staged ZigCSS and pinned esbuild child processes, passes the freshly built checkout binary, and proves the CSS Module binding across the client, Nitro SSR bundle, and prerendered page, together with a native Sass partial and rebased SVG asset. The JavaScript proof is not an OS sandbox and trusts the exact pinned host/native addons. The exact native CSS map chain is retained only in `.nuxt` intermediate output while public client JavaScript maps remain verified; no public production CSS map or runtime SSR request is claimed. Embedded Nuxt styles, modules, HMR/watch invalidation, other builders, deployment presets, a `zigcss/nuxt` export, and stable-release delivery remain unclaimed.
- Add a real Parcel 2.16.4 local-transformer example for SCSS, Sass, Less, and Stylus with maps, diagnostic code frames, imported-file invalidation, cache checks, and a native-binary CI smoke. A public `zigcss/parcel` subpath is intentionally absent because Parcel requires published transformer packages to use a separate `parcel-transformer-*` package name; no separately published Parcel plugin is claimed.
- Add a strict no-emit TypeScript 7.0.2 consumer gate for the package root and every adapter subpath, including negative assertions for immutable results, sync cancellation, file-owned source paths, option types, and the closed adapter option surface.
- Add the `zigcss-install` package binary as an explicit recovery path when npm, pnpm, Yarn, or Bun suppresses the dependency install lifecycle. The launcher reports the same package-manager-neutral recovery without scanning ambient binary paths or claiming that recovery downloads work offline.
- Add an exact lifecycle-disabled package matrix for npm, pnpm 11.25.0, Yarn Classic 1.22.22, Yarn Modern 4.9.4 in both `node-modules` and default Plug'n'Play modes, and Bun 1.4.0. GitHub Actions requires all six execution variants, packs once, blocks registry access for installation, and runs binary-shim, recovery, integrity-inventory, CommonJS, ESM, declaration, and strict TypeScript checks against the same archive. The PnP route uses `preferUnplugged`, creates no `node_modules`, confines Yarn caches, and proves recovery with a locally generated fixture rather than an already published release.
- Add deterministic single-entry tar.gz and ZIP release generation with normalized metadata and a committed `sourceDateEpoch`, plus a strict `native-integrity.json` inventory that binds the npm package to the exact five GitHub archive digests. The installer verifies the GitHub checksum against that independent npm-carried digest before downloading an archive, then checks archive bytes, one-entry shape, target header, bounded redirects, per-download total deadline, and atomic placement. Release-side `gh attestation verify` is additionally pinned to the exact `release.yml` signer, workflow commit, tag ref, and source commit for both bundle types.
- Add `--depfile <path>` for one explicit file-to-file compilation. It emits a bounded Make/Ninja-compatible rule over the canonical entry and only native dependencies actually read, rejects aliases and incompatible stdin/watch/batch routes, preserves existing destinations on preparation or staging failure, and commits CSS last as the per-file success marker for Make, Ninja, CMake, and Meson integrations. The ordinary CI build now runs the integration suite after its native Debug tests with the freshly built binary in `ZIGCSS_REAL_BINARY`, including mandatory real-ZigCSS incremental rebuilds for GNU Make, Ninja, CMake, and Meson.

### Changed

- Make documentation security and publication gates match the deployed surfaces: GitHub Pages receives an early restrictive meta CSP, while the standalone container additionally owns strict response-only CSP, framing, opener/resource, referrer, feature, cache, method, and MIME headers verified by an exact-byte live Docker smoke. Pages deployment now consumes only the exact SHA from a successful same-repository `Build` push on `main`, and the unfiltered common Build workflow runs the complete locked documentation test suite for every pull request.
- Require every release publication path to prove an exact-SHA successful same-repository `Build` run before authentication or packaging authority, pin workflow display/path identity, and give every documentation and release job a finite enforced timeout.
- Pin the public development container to the exact reviewed Node image and content-addressed architecture-matched Zig archives, disable dependency lifecycle scripts, keep recursive dependency trees, framework outputs, editor metadata, logs, and nested environment files out of its context, and bind live source read-only while lockfile-keyed dependency and compiler outputs stay in isolated volumes. Its mandatory live CI smoke builds the real image, retains the tracked Stylus resolution fixture, starts Vite only after a successful Zig build, requires compiler-plus-HTTP health, validates the exact mount boundary, and cleans the project-scoped image and volumes. Also ignore every standard generated output of the checked-in Next.js, SvelteKit, Astro, Nuxt, and Parcel examples.
- Promote the repository Homebrew formula to stable 0.6.0 with an immutable commit URL, verified source SHA-256, the exact Zig 0.15 toolchain path, and a bounded formula-equivalent source download/build/CLI smoke. This is not represented as a Homebrew install transaction, and no tap publication is claimed.
- Make ordinary development archive smokes stage an isolated allowlisted package copy with only the current target's temporary digest changed. Tag releases still consume the exact prepacked npm archive and fail unless every freshly created native archive matches the committed integrity inventory.

- Refresh the documentation toolchain lock to patched PostCSS 8.5.26 and Nano ID 3.3.18 transitive releases; both the production-only and complete documentation dependency audits now report zero vulnerabilities.
- Advance the development-only Less oracle from 4.6.7 to exact 4.9.0 while retaining 4.6.7 as the frozen native conformance baseline. Remove the direct legacy `image-size` 0.5.5 pin, route both Less and Stylus image metadata through one shared bounded PNG/GIF/JPEG/SVG parser over resolver-owned bytes, and make CI run a complete high/critical root development-graph audit after the seven production audits and before the four full framework-host lock audits. Audit subprocesses now explicitly include production, development, optional, and peer classes after stripping ambient npm scope overrides. The image parser validates complete bounded PNG chunks and CRCs, GIF block structure, JPEG frame/scan termination, and quote-aware SVG root attributes. Production dependencies, runtime compilation, the immutable stable release, and its historical oracle record remain unchanged.
- Skip emit and reparse work when a complete verified optimizer plan leaves the syntax tree unchanged: no-op runs now report one pass, zero emits, and zero reparses, while changed trees retain the existing bounded byte-stable fixed-point behavior.
- Cache only pointer-exact, successfully proven minified mapped emissions for immutable arena AST roots: a complete no-op optimizer plan and a modern no-op prefix plan now perform one proof emit per pass context, while distinct changed roots retain the full two-output CSS/source-map differential check.
- Stream native watch dependency fingerprints through fixed 64 KiB XxHash64 chunks instead of allocating full file contents and temporary graph facts on every poll, while retaining confined no-follow opens, stable-object verification, cancellation, and resource ceilings.
- Index native resolver dependency and edge admission with owned-key hash tables, maintain a borrowed adjacency index for cycle checks, and traverse each reachable cycle fact once with a visited set; preserve deterministic first-success facts and transactional OOM/cancellation rollback.
- Bound CLI admission to 4,096 input patterns, 16,384 expanded inputs, 16 KiB paths, and 4 KiB glob components; replace recursive wildcard backtracking with a linear matcher, byte-sort filesystem matches, and use indexed batch-name and destination-collision planning for deterministic large batches.
- Index native source-name and source-map-name admission with owned-key hash tables, use exact source lookup when creating watch snapshots, and add lazy sparse UTF-16 position checkpoints for long mapped lines; duplicate, rollback, finish/reuse, and allocation-failure behavior remains transactional.
- Transfer already-owned CSS and source-map emitter buffers through pipeline, stable result, native compiler, and native API ownership boundaries instead of duplicating the full outputs at each promotion stage; moved-from results retain one safe cleanup path.
- Promote the rebuilt verified target-prefix pass to CSS, SCSS, indented Sass, Less, and Stylus CLI and Zig API routes: require paired `--autoprefix --browsers <query>` options, parse one strict pinned six-browser query before dispatch, share it immutably across file, stdin, watch, and parallel batch work, and verify composition with optimizer and source-map paths without enabling the inherited autoprefixer or dynamic Browserslist behavior.
- Route `--optimize` through the same closed seven-pass, bounded fixed-point core after the native SCSS, indented Sass, Less, and Stylus frontends, including file, stdin, watch, and parallel batch paths; keep `--source-map` incompatible with optimization and `--profile` CSS-only.
- Give native CSS the same bounded deterministic inline `--source-map` policy as SCSS, Sass, Less, and Stylus across file, stdin, watch, and parallel batch compilation; reject its unsupported combination with fixed-point `--optimize` before reading inputs.
- Retire the completed autonomous roadmap, verbose execution ledger, stopped runner, and obsolete prototype fixtures after stable publication; Git history retains the full audit trail while ADRs and machine-readable release contracts remain maintained.
- Document the exact tooling boundary: stable 0.6.0 remains the CLI-launcher release; the current source snapshot adds experimental Vite, Rollup, esbuild, Bun, Webpack, and Rspack package adapters, exact Next.js Turbopack and Webpack, SvelteKit, Astro, and Nuxt source-checkout host proofs, plus a tested local Parcel transformer example. A separately published Parcel transformer, framework-specific adapter export, Bazel rule, Nx executor, and Angular integration remain unimplemented and unclaimed.
- Replace the overflowing small-screen header links with an accessible mobile navigation panel, restore canonical and reload-safe hash links plus sticky-header scrolling, keep every primary destination keyboard reachable, serve the legacy `/docs` entry point without an HTTP 404, and render a branded fallback instead of a blank first-load frame.

## [0.6.0] - 2026-08-18

Released as immutable tag `v0.6.0`, non-prerelease GitHub Release `372291445`, and `zigcss@0.6.0` on npm `latest` with provenance.

Stable `0.6.0` promotes the exact self-contained native surface proven by immutable `0.6.0-rc.2`; it does not move, replace, or republish the RC. Release run `32130950531` passed on attempt 1 with five architecture-matched archives, 15 attested archive/checksum/SBOM subjects, 10 Sigstore bundle files, npm SLSA provenance, preserved `next`, and anonymous CSS/SCSS/Sass/Less/Stylus installation. The package retains zero production and optional dependencies, deterministic and fail-closed compilation, and explicit plugin boundaries.

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
- Preserve explicit CLI migration: source users select `--syntax scss|sass|less|stylus`, with imports confined to the entry directory. Zig consumers can configure additional `root_paths` through `zigcss.experimental_native`; the stable CSS API and build helper remain CSS-only. The former programmatic provider-backed JavaScript preprocessor API is not part of this source contract.
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
