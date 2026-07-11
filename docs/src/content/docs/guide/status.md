# Experimental recovery status

ZigCSS 0.3 is an experimental compiler prototype undergoing a correctness-first rebuild. It is not suitable for production stylesheets yet.

## Current contract

| Surface | Status | Current behavior |
|---|---|---|
| Basic CSS CLI parsing and emission | Experimental | Useful for development and characterization; known syntax and semantic gaps remain. |
| `--minify` | Experimental | Changes whitespace during emission only. It does not enable optimizer transforms. |
| Output planning | Safety boundary verified | Input/output aliases and multi-file destination collisions are rejected before writes. |
| `--profile` | Experimental | Reports parse, optimizer-stage, and emission timings without the former lifecycle crash. |
| Optimizer, autoprefixing, critical CSS | Disabled | Unsafe transform paths fail explicitly. |
| Source maps and browser target queries | Unavailable | Flags fail explicitly instead of silently doing nothing. |
| SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS | Experimental and CLI-disabled | Legacy adapters remain internal pending a compatibility contract and dedicated test suites. |
| LSP | Experimental | Shares the legacy parser and is not a stable editor contract. |
| Public compile API and playground | Disabled | Public routes return HTTP 503 until bounded isolation is implemented. |

## Known parser limitations

The current parser cannot safely preserve all standards CSS. Known quarantined cases include compound selectors, functional pseudo-classes, attribute selectors, delimiters inside strings and functions, declaration-bearing at-rules, percentage keyframes, and mandatory whitespace in some minified at-rules.

Use the current binary only for contributing, testing, or evaluating the recovery work. Do not place it in a production build pipeline.

## Project direction

The approved roadmap replaces the byte-oriented parser with a tokenizer, source model, syntax tree, standards-oriented parser, and semantics-preserving emitter before transforms are re-enabled. Public performance comparisons remain withdrawn until equivalent output is validated first.

- [Build from source](/guide/build-from-source)
- [Recovery CLI](/guide/recovery-cli)
