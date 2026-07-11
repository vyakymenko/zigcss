# ZigCSS

> **Experimental recovery status:** ZigCSS 0.3 is an ambitious compiler prototype undergoing a correctness-first rebuild. It is not suitable for production stylesheets.

The repository contains useful Zig scaffolding for a CSS CLI, parser, emitter, transforms, format adapters, an LSP, documentation, packaging, and benchmarks. The inherited byte-oriented parser and optimizer do not yet preserve standards CSS reliably, so the current program prioritizes security and semantics before features or speed.

The authoritative roadmap is [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Execution evidence and package state are tracked in [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md).

## Current contract

| Surface | Status | Behavior |
|---|---|---|
| Basic `.css` parsing and emission | Experimental | Intended for development and characterization only; known syntax and semantic gaps remain. |
| `--minify` | Experimental | Compacts emitted whitespace without enabling AST transforms. |
| Output planning | Verified safety boundary | Rejects input/output aliases and duplicate batch destinations before writes. |
| Optimizer, autoprefixing, critical CSS | Disabled | Unsafe transform requests fail explicitly. |
| Source maps and browser target queries | Unavailable | Requests fail explicitly instead of acting as no-ops. |
| SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS | Experimental and CLI-disabled | Legacy adapters remain internal until each has a compatibility decision and evidence suite. |
| LSP | Experimental | Still consumes the legacy parser. |
| Public compile API and playground | Disabled | Public compile routes return HTTP 503 pending bounded isolation and parser replacement. |

## Known limitations

Committed regressions currently quarantine failures involving:

- compound versus descendant selectors;
- functional pseudo-classes and attribute selectors;
- delimiters inside strings and functions;
- declaration-bearing at-rules and percentage keyframes;
- mandatory whitespace in some minified at-rules;
- optimizer transformations affecting cascade, ordering, logical properties, shorthands, and typed math.

Do not use current output in a production pipeline. A successful compile is not yet a standards-compatibility guarantee.

## Build from source

Use Zig 0.15.2:

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all
```

The executable is written to `zig-out/bin/zigcss`.

For a characterization run, start with deliberately simple CSS:

```css
.notice {
  color: red;
}
```

```bash
zig-out/bin/zigcss input.css -o output.css
```

The CLI prints an experimental-build warning to standard error.

## Recovery CLI

Run `zig-out/bin/zigcss --help` for the authoritative option list.

Available recovery options include output selection, explicit batch output planning, whitespace-only `--minify`, single-file `--watch`, and `--profile`. The experimental `--lsp` server is separately labeled.

Unavailable options—`--optimize`, `--source-map`, `--autoprefix`, `--browsers`, and `--critical-*`—are rejected with an explanation. Unknown and malformed arguments are also rejected.

## Performance claims

Public performance comparisons are withdrawn. Historical timings did not first prove equivalent output, and some measurements included incomparable process startup paths. New benchmark results will be publishable only after semantic validation, reproducible methodology, and the benchmark gates in the development plan pass.

## Contributing

Work in dependency order from `DEVELOPMENT_PLAN.md`. Each package should reproduce or measure first, add or strengthen tests, implement the smallest correct change, run proportionate verification, update `DEVELOPMENT_STATUS.md`, and commit a coherent checkpoint.

Do not re-enable a transform based only on smaller output or faster timing. Semantic equivalence is the gate.

## License

MIT. See [LICENSE](LICENSE).
