# Experimental recovery status

ZigCSS 0.3 is an experimental compiler prototype undergoing a correctness-first rebuild. It is not suitable for production stylesheets yet.

## Current contract

| Surface | Status | Current behavior |
|---|---|---|
| CSS CLI parsing and emission | Experimental, matrix-tested | The stable CLI uses the new source/token/syntax/typed-parser pipeline; its current grammar boundary is published and independently parsed. |
| Zig compile API | Experimental, consumer-tested | `zigcss.compile` returns owned CSS/maps, located diagnostics, ordered decoded imports, and optional module-export state; accepted transforms and borrowed canonical targets are explicit options. |
| Zig package metadata | Experimental, consumer-tested | Package `zigcss` 0.3.0 declares minimum Zig 0.15.2 and a minimal source allowlist; path and fresh fetched-cache consumers resolve module `zigcss`. |
| Zig build helper | Experimental, consumer-tested | `@import("zigcss").helpers.addCssCompile` uses declared lazy file inputs/outputs and a host compiler artifact; unavailable CLI features are not represented. |
| Native plugins | Experimental, trusted/library-only | Explicit `.experimental` options run borrowed `plugin.`-namespaced Zig callbacks through bounded deterministic pass plans; there is no stable ABI, sandbox, CLI, or HTTP path. |
| `--minify` | Experimental | Changes whitespace during emission only; it is independent of `--optimize`. |
| Output planning | Safety boundary verified | Input/output aliases and multi-file destination collisions are rejected before writes. |
| `--profile` | Experimental | Reports parse, optimizer-stage, and emission timings without the former lifecycle crash. |
| Verified optimizer preset | Experimental, acceptance-gated | `--optimize` runs exactly seven verified analysis/cleanup/semantic passes to a bounded byte-stable fixed point; unsafe and separately authorized classes are excluded. |
| Dead-code and critical-CSS extraction | Experimental, library/test-only | Two bounded passes use complete class/ID inventories and require separate experimental plus extraction authorization; stable CLI flags remain unavailable. |
| Target prefix rewrite | Experimental, library-only | One verified pass covers eight pinned property/value/selector/at-rule features through the pass manager and test driver; it is not a general autoprefixer. |
| Source maps | Experimental, library-only | The library pipeline produces deterministic mappings; the CLI flag remains unavailable until its output policy is defined. |
| Browser target queries | Experimental, library-only | The Zig API accepts a strict explicit-minimum grammar over six browsers and deterministically configures the verified rewrite from pinned BCD 8.0.0 data; CLI flags remain unavailable pending public option wiring. |
| SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS | Experimental and CLI-disabled | Legacy adapters remain internal pending a compatibility contract and dedicated test suites. |
| LSP | Experimental | Shares the legacy parser and is not a stable editor contract. |
| Public compile API and playground | Disabled | Public routes return HTTP 503 until bounded isolation is implemented. |

## Current boundaries

The stable CLI no longer consumes the inherited byte parser. Its typed and lossless grammar boundary is listed in the [CSS compatibility matrix](/guide/css-compatibility), and every emitting fixture is checked in pretty and minified modes by an independent parser with recovery disabled.

The build registers `src/lib.zig` as the external `zigcss` module. A separate consumer test imports that name rather than testing from inside the root, then calls the owned high-level compile facade. Results retain CSS, optional map bytes, source names and line/column locations for diagnostics, ordered decoded top-level `@import` dependencies, and optional module-export state after compilation cleanup. Duplicate imports remain ordered; malformed or dynamic import preludes do not become guessed dependencies; count/owned-byte limits fail with a structured resource diagnostic and no partial facts.

`CompileOptions` currently admits only CSS, pretty/minified output, separate maps, the closed optimizer preset, the verified target-prefix pass with a borrowed canonical query, and explicitly experimental trusted native plugins. Targets without prefixing, prefixing without targets, forged queries, optimized source maps, and active plugin source maps return `API0001` diagnostics without CSS. Stable CSS returns no module exports. Remote package publication, build helpers, and CSS Modules remain later packages.

The Zig manifest pins package identity, project version 0.3.0, and minimum Zig 0.15.2. Its allowlist contains only the build entry point, manifest, supported build helper, compiler sources, README, and license. A path dependency and an isolated `zig fetch .` copy both compile the public module. Tests, docs, wrappers, and editor files are not exported; no remote URL/hash is claimed before publication.

The dependency's build module exports `helpers.addCssCompile`. It configures an ordinary cached run step during graph construction, accepts one declared input `LazyPath`, creates one generated CSS output path, and exposes only the stable CLI's optimize/minify choices. A downstream `CheckFile` proves exact output, repeated runs are cached, and changing only the input bytes reruns compilation. Output names are bounded portable `.css` basenames. The caller must supply a host-runnable ZigCSS artifact; source maps, prefix/target options, alternate formats, arbitrary arguments, and batch directories remain absent.

## Experimental native plugin boundary

Native plugins reuse the immutable pass contract; the inherited mutable `PluginRegistry` is not public. Definitions, metadata strings, request/dependency slices, callbacks, and `user_data` are borrowed only during synchronous `compile`, while all AST output stays in the compilation arena and no plugin pointer enters `CompileResult`. IDs must use the isolated `plugin.` namespace. Only requested IDs and their plugin dependencies execute, after the optional optimizer fixed point; a target prefix pass joins the same final plan. Dependencies take precedence, then ready passes are ordered by phase, ascending priority, and bytewise stable ID.

The outer `.experimental` tag does not grant transform authority by itself. `PluginPolicy` still defaults to verified analysis only; experimental maturity and each output-changing safety class require their own exact booleans. Invalid registries or policy return owned `API0002` diagnostics before callbacks or dependency collection. Callback/validator failure rolls back the compiler root and plan diagnostics, returns owned `API0003` without CSS, and retains already discovered import facts. Caller-owned `user_data` side effects are not reversible. Warnings survive only when the whole plan succeeds.

This is trusted in-process Zig code, not a sandbox or stable ABI. A panic, nontermination, process exit, undefined behavior, or malicious mutation cannot be recovered. Plugins remain unavailable from the recovery CLI and disabled public compiler routes. The complete source contract is recorded in `docs/adr/ADR-005-native-plugin-contract.md`.

Property-specific values are generally preserved as component trees rather than fully validated semantic values. Browser computed-style validation, broader target data and stable CLI prefix exposure, optimized source-map composition, CLI source-map output, the LSP migration, alternate formats, and public untrusted compilation remain later gates. Independent syntax acceptance is evidence, not a complete browser-semantics guarantee.

## Verified optimizer boundary

`--optimize` invokes one static preset: duplicate-declaration analysis, empty-rule cleanup, numeric math folding, typed color/zero shortening, margin shorthand synthesis, adjacent at-rule merge, and adjacent selector-rule merge. Every definition is verified, validator-backed, recursively nested, order-preserving, and independently acceptance-tested. The preset policy grants only cleanup and semantic rewrite; target compatibility, extraction, experimental passes, reorder authority, custom-property resolution, and logical-to-physical conversion have no path into it.

Because one proof-carrying rewrite can expose another safe candidate after emission, the preset runs bounded parse-transform-emit rounds until two consecutive byte sequences match. The 32-round limit fails without partial output. Its combined pretty/minified fixture covers cross-pass candidates, fallback and importance order, custom/logical preservation, nested groups, unsupported values, exact byte idempotence, independent Lightning CSS canonical semantics, and size reduction. Fixed-point source-map composition is not yet exposed; the CLI continues to reject `--source-map`.

## Experimental extraction boundary

The library exposes distinct conservative dead-code and critical-CSS passes. A non-null class or ID category is exhaustive for the declared domain; null is unknown and cannot prove absence. Dead-code mode requires a closed document snapshot. Critical mode requires a closed selector-matching render tree that includes every related node a combinator can inspect—not merely a list of preferred names from a larger live page.

Only direct positive class and ID requirements participate. A style rule is removed only when every selector-list alternative contains a required token absent from a complete category. Type/attribute evidence, functional pseudo arguments, possible selector alternatives, imports, descriptors, keyframes, custom-property dependencies, layers, and other non-style rules remain authored. Inventories are owned, canonical, bounded, and conservative across ASCII case variants.

Both modes remain experimental and library/test-driver only. They require `allow_extraction` and `allow_experimental`, pass independent Lightning CSS selector projection in pretty and minified modes, and are never reached by `--optimize` or `--critical-*`.

## Library target boundary

The experimental Zig API accepts comma-separated explicit minimums such as `chrome >= 120, firefox >= 115, safari >= 17.2`. The closed browser set is `chrome`, `edge`, `firefox`, `safari`, `ios_safari`, and `ie`. Queries are lowercase, contain no defaults, and do not implement Browserslist market-share, recency, negation, alias, or configuration syntax.

Compatibility facts are generated from the exact `@mdn/browser-compat-data` 8.0.0 lock for a reviewed eight-feature property/value/selector/at-rule subset. The verified library pass emits only complete, unannotated closed forms, keeps vendor declarations before the authored standard, separates vendor selector rules, clones prefixed keyframes, retains manual vendor policy, and produces deterministic source maps. A modern Chrome/Edge/Firefox query is an exact no-op; the reviewed legacy query materially changes output and passes independent Lightning CSS projection in both modes.

This is still not general autoprefixing. Partial, annotated, unsupported, mixed-selector, functional-pseudo, descriptor, recovered, and conflicting/manual cases default to no rewrite. `--browsers` and `--autoprefix` continue to fail until later public API/CLI work carries the target query and authorizes only the rebuilt pass.

Use the current binary only for contributing, testing, or evaluating the recovery work. Do not place it in a production build pipeline.

## Project direction

The approved roadmap has replaced the stable CLI's byte-oriented parser with a tokenizer, source model, syntax tree, standards-oriented parser, and semantics-preserving emitter. It enables only the closed evidence-backed optimizer preset while separately gated or inherited transform paths remain unavailable. Public performance comparisons remain withdrawn until equivalent output is validated first.

- [Build from source](/guide/build-from-source)
- [Recovery CLI](/guide/recovery-cli)
- [CSS compatibility](/guide/css-compatibility)
