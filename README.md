# ZigCSS

> **Experimental recovery status:** ZigCSS 0.3 is an ambitious compiler prototype undergoing a correctness-first rebuild. It is not suitable for production stylesheets.

The repository contains a rebuilt CSS source/token/syntax/parser/emitter pipeline alongside inherited prototype transforms, format adapters, an LSP, documentation, packaging, and benchmarks. The stable CLI now uses the rebuilt pipeline, while the remaining program still prioritizes security and semantics before features or speed.

The authoritative roadmap is [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Execution evidence and package state are tracked in [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md).

## Autonomous development operations

The repository keeps its persistent Codex procedure in [docs/operations/codex-loop-protocol.md](docs/operations/codex-loop-protocol.md). A read-only orientation helper reconstructs branch, dirty state, ledger work, blockers, validation evidence, checkpoints, and toolchain visibility:

```bash
bash scripts/autodevelop/orient.sh
```

The helper does not launch a model or mutate the repository; the active Codex task owns scheduling and goal continuation.

## Current contract

| Surface | Status | Behavior |
|---|---|---|
| `.css` parsing and emission | Experimental, matrix-tested | Stable CLI input uses the rebuilt parser/emitter; the tested grammar boundary is published below. |
| `--minify` | Experimental | Compacts emitted whitespace without enabling AST transforms. |
| Output planning | Verified safety boundary | Rejects input/output aliases and duplicate batch destinations before writes. |
| Optimizer, autoprefixing, critical CSS | Disabled | Unsafe transform requests fail explicitly. |
| Source maps | Experimental, library-only | Deterministic maps are available from the library pipeline; CLI output policy remains undefined. |
| Browser target queries | Unavailable | Requests fail explicitly; versioned compatibility data is not yet available. |
| SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS | Experimental and CLI-disabled | Legacy adapters remain internal until each has a compatibility decision and evidence suite. |
| LSP | Experimental | Still consumes the legacy parser. |
| Public compile API and playground | Disabled | Public compile routes return HTTP 503 pending bounded isolation. |

## Current limitations

The tested grammar boundary is published in [the CSS compatibility matrix](docs/src/content/docs/guide/css-compatibility.md) and backed by `tests/compatibility/matrix.json`. Pretty and minified fixture output must parse in pinned Lightning CSS with error recovery disabled.

Property-specific values are usually preserved as lossless component trees rather than fully validated semantics. Browser computed-style validation, optimizer transforms, compatibility target data, CLI source-map output, LSP migration, alternate formats, and resource-bounded public compilation remain incomplete.

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

After building, the independent grammar gate can be run with Node.js:

```bash
npm ci --ignore-scripts
npm run test:compat
```

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
