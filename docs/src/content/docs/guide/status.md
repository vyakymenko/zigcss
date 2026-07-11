# Experimental recovery status

ZigCSS 0.3 is an experimental compiler prototype undergoing a correctness-first rebuild. It is not suitable for production stylesheets yet.

## Current contract

| Surface | Status | Current behavior |
|---|---|---|
| CSS CLI parsing and emission | Experimental, matrix-tested | The stable CLI uses the new source/token/syntax/typed-parser pipeline; its current grammar boundary is published and independently parsed. |
| `--minify` | Experimental | Changes whitespace during emission only. It does not enable optimizer transforms. |
| Output planning | Safety boundary verified | Input/output aliases and multi-file destination collisions are rejected before writes. |
| `--profile` | Experimental | Reports parse, optimizer-stage, and emission timings without the former lifecycle crash. |
| Optimizer, autoprefixing, critical CSS | Disabled | Unsafe transform paths fail explicitly. |
| Source maps | Experimental, library-only | The library pipeline produces deterministic mappings; the CLI flag remains unavailable until its output policy is defined. |
| Browser target queries | Unavailable | Target queries fail explicitly; no compatibility data is claimed. |
| SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS | Experimental and CLI-disabled | Legacy adapters remain internal pending a compatibility contract and dedicated test suites. |
| LSP | Experimental | Shares the legacy parser and is not a stable editor contract. |
| Public compile API and playground | Disabled | Public routes return HTTP 503 until bounded isolation is implemented. |

## Current boundaries

The stable CLI no longer consumes the inherited byte parser. Its typed and lossless grammar boundary is listed in the [CSS compatibility matrix](/guide/css-compatibility), and every emitting fixture is checked in pretty and minified modes by an independent parser with recovery disabled.

Property-specific values are generally preserved as component trees rather than fully validated semantic values. Browser computed-style validation, transformations, target data, CLI source-map output, the LSP migration, alternate formats, and public untrusted compilation remain later gates. Independent syntax acceptance is evidence, not a complete browser-semantics guarantee.

Use the current binary only for contributing, testing, or evaluating the recovery work. Do not place it in a production build pipeline.

## Project direction

The approved roadmap has replaced the stable CLI's byte-oriented parser with a tokenizer, source model, syntax tree, standards-oriented parser, and semantics-preserving emitter. It keeps transforms disabled until each pass has stronger semantic evidence. Public performance comparisons remain withdrawn until equivalent output is validated first.

- [Build from source](/guide/build-from-source)
- [Recovery CLI](/guide/recovery-cli)
- [CSS compatibility](/guide/css-compatibility)
