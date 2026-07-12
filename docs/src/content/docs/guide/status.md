# Experimental recovery status

ZigCSS 0.3 is an experimental compiler prototype undergoing a correctness-first rebuild. It is not suitable for production stylesheets yet.

## Current contract

| Surface | Status | Current behavior |
|---|---|---|
| CSS CLI parsing and emission | Experimental, matrix-tested | The stable CLI uses the new source/token/syntax/typed-parser pipeline; its current grammar boundary is published and independently parsed. |
| `--minify` | Experimental | Changes whitespace during emission only. It does not enable optimizer transforms. |
| Output planning | Safety boundary verified | Input/output aliases and multi-file destination collisions are rejected before writes. |
| `--profile` | Experimental | Reports parse, optimizer-stage, and emission timings without the former lifecycle crash. |
| General optimizer | Disabled | Unsafe transform paths fail explicitly. |
| Dead-code and critical-CSS extraction | Experimental, library/test-only | Two bounded passes use complete class/ID inventories and require separate experimental plus extraction authorization; stable CLI flags remain unavailable. |
| Target prefix rewrite | Experimental, library-only | One verified pass covers eight pinned property/value/selector/at-rule features through the pass manager and test driver; it is not a general autoprefixer. |
| Source maps | Experimental, library-only | The library pipeline produces deterministic mappings; the CLI flag remains unavailable until its output policy is defined. |
| Browser target queries | Experimental, library-only | The Zig API accepts a strict explicit-minimum grammar over six browsers and deterministically configures the verified rewrite from pinned BCD 8.0.0 data; CLI flags remain unavailable pending public option wiring. |
| SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS | Experimental and CLI-disabled | Legacy adapters remain internal pending a compatibility contract and dedicated test suites. |
| LSP | Experimental | Shares the legacy parser and is not a stable editor contract. |
| Public compile API and playground | Disabled | Public routes return HTTP 503 until bounded isolation is implemented. |

## Current boundaries

The stable CLI no longer consumes the inherited byte parser. Its typed and lossless grammar boundary is listed in the [CSS compatibility matrix](/guide/css-compatibility), and every emitting fixture is checked in pretty and minified modes by an independent parser with recovery disabled.

Property-specific values are generally preserved as component trees rather than fully validated semantic values. Browser computed-style validation, broader target data and stable CLI prefix exposure, CLI source-map output, the LSP migration, alternate formats, and public untrusted compilation remain later gates. Independent syntax acceptance is evidence, not a complete browser-semantics guarantee.

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

The approved roadmap has replaced the stable CLI's byte-oriented parser with a tokenizer, source model, syntax tree, standards-oriented parser, and semantics-preserving emitter. It keeps transforms disabled until each pass has stronger semantic evidence. Public performance comparisons remain withdrawn until equivalent output is validated first.

- [Build from source](/guide/build-from-source)
- [Recovery CLI](/guide/recovery-cli)
- [CSS compatibility](/guide/css-compatibility)
