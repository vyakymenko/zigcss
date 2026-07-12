# ZigCSS

> **Experimental recovery status:** ZigCSS 0.3 is an ambitious compiler prototype undergoing a correctness-first rebuild. It is not suitable for production stylesheets.

The repository contains a rebuilt CSS source/token/syntax/parser/emitter pipeline alongside inherited prototype transforms, format adapters, an LSP, documentation, packaging, and benchmarks. The stable CLI delegates compilation to the owned public `zigcss.compile` facade over the rebuilt pipeline, while the remaining program still prioritizes security and semantics before features or speed.

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
| `.css` parsing and emission | Experimental, matrix-tested | Stable CLI input calls the public compile facade over the rebuilt parser/emitter; the tested grammar boundary is published below. |
| Zig compile API | Experimental, consumer-tested | The `zigcss` module exposes owned compile options/results, located structured diagnostics, ordered `@import` dependencies, maps, accepted transforms, and target queries. |
| Zig package metadata | Experimental, consumer-tested | `build.zig.zon` declares package `zigcss` 0.3.0 with minimum Zig 0.15.2; path and freshly fetched package consumers compile against module `zigcss`. |
| Zig build helper | Experimental, consumer-tested | `@import("zigcss").helpers.addCssCompile` declares one `LazyPath` input and generated CSS output per cached host-tool run; only minification and the verified optimizer are exposed. |
| Native plugins | Experimental, trusted/library-only | Explicit `.experimental` options run borrowed Zig callbacks through deterministic, transactional pass plans; there is no stable or cross-language plugin ABI. |
| `--minify` | Experimental | Compacts emitted whitespace without enabling AST transforms. |
| Output planning | Verified safety boundary | Rejects input/output aliases before writes, deterministically disambiguates batch basenames, and atomically replaces each destination. |
| Verified optimizer preset | Experimental, acceptance-gated | `--optimize` runs a closed seven-pass cleanup/semantic plan to a bounded byte-stable fixed point; legacy, experimental, compatibility, extraction, custom-resolution, logical-conversion, and reorder paths are excluded. |
| Dead-code and critical-CSS extraction | Experimental, library/test-only | Two bounded passes accept complete class/ID inventories and emit only rules proven possible in a closed selector domain; both require experimental plus extraction authority. |
| Target prefix rewrite | Experimental, library-only | One verified pass adds closed forms for eight pinned property/value/selector/at-rule features; it is exercised through the pass manager and test driver, not the recovery CLI. |
| Source maps | Experimental, library-only | Deterministic maps are available from the library pipeline; CLI output policy remains undefined. |
| Browser target queries | Experimental, library-only | A strict explicit-minimum grammar and pinned BCD 8.0.0 subset deterministically configure the verified rewrite; `--browsers` and `--autoprefix` remain unavailable pending later public CLI wiring. |
| SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, CSS-in-JS | Experimental and CLI-disabled | Legacy adapters remain internal until each has a compatibility decision and evidence suite. |
| LSP | Experimental | Still consumes the legacy parser. |
| Public compile API and playground | Disabled | Public compile routes return HTTP 503 pending bounded isolation. |

## Experimental Zig compile API

`build.zig` registers one external module named `zigcss` at `src/lib.zig`. `zigcss.compile` accepts `CompileOptions` for CSS output format, separate source maps, the verified optimizer, verified target prefixing, a borrowed canonical target query, and bounded dependency reporting. Its move-only-by-convention `CompileResult` owns CSS, optional map bytes, located structured diagnostics, ordered decoded top-level `@import` dependencies, and optional module-export state through one idempotent `deinit` path.

The stable CSS path returns `module_exports = null`; CSS Modules remain experimental. Fixed-point optimization and source maps cannot be combined until intermediate maps can be composed, and incoherent options return owned `API0001` diagnostics without CSS.

`build.zig.zon` gives the source package stable identity `zigcss`, version 0.3.0, fingerprint `0xae272a4871e93d07`, and minimum Zig 0.15.2. Its allowlist contains only `build.zig`, the manifest, supported `build_helpers.zig`, `src`, README, and license. `tests/package-consumer` is a real path dependency that resolves `zigcss.module("zigcss")`; an isolated `zig fetch .` copy with only allowlisted files passes the same API smoke. No remote package URL is published.

The dependency build module exports `helpers.addCssCompile`. Each call accepts one input `std.Build.LazyPath`, a bounded portable `.css` output basename, and optional `optimize`/`minify` booleans. It returns the generated output `LazyPath` for checks, installs, or other downstream steps. The helper uses `addFileArg` and `addOutputFileArg`, so unchanged runs are cached and source-byte changes invalidate them. It never mutates the graph during execution and exposes no source-map, autoprefix, browser, arbitrary-argument, or output-directory escape hatch. The supplied compiler artifact must run on the build host; cross-target projects need a separate host-tool dependency instance.

`examples/build-integration` is the complete consumer reference. It resolves separate application-target and host-tool dependency instances, imports the public library, compiles and exact-checks CSS through the helper, installs the generated stylesheet, builds an executable, and runs an API test. CI builds its `test` step in Debug and ReleaseSafe; the root build independently compiles `examples/public_api.zig` in both full local test modes.

Native plugins are a separate trusted-only experiment. `PluginOptions.experimental` borrows `plugin.`-namespaced pass definitions, requests, callbacks, and user state only until `compile` returns. The pass manager closes dependencies and orders execution by phase, priority, and stable ID independent of registration order. Exact safety/maturity permissions remain deny-by-default. Invalid configuration returns `API0002`; callback or validator failure transactionally returns `API0003` without CSS; successful warnings remain owned diagnostics. Active plugins cannot request source maps, do not enter the CLI or HTTP service, and are not a stable ABI or sandbox.

A minimal repository consumer uses the owned high-level result:

<!-- api-example:start -->
```zig
const std = @import("std");
const zigcss = @import("zigcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var result = try zigcss.compile(
        gpa.allocator(),
        "input.css",
        ".notice { color: red; }",
        .{ .format = .minified },
    );
    defer result.deinit();
    if (result.diagnostics.len != 0) return error.InvalidCss;

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.writeAll(result.css);
    try writer.interface.flush();
}
```
<!-- api-example:end -->

## Current limitations

The tested grammar boundary is published in [the CSS compatibility matrix](docs/src/content/docs/guide/css-compatibility.md) and backed by `tests/compatibility/matrix.json`. Pretty and minified fixture output must parse in pinned Lightning CSS with error recovery disabled.

Property-specific values are usually preserved as lossless component trees rather than fully validated semantics. Browser computed-style validation, broader prefix data and prefix CLI exposure, element/attribute or dynamic-DOM extraction, optimized source-map composition, CLI source-map output, LSP migration, alternate formats, and resource-bounded public compilation remain incomplete.

Do not use current output in a production pipeline. A successful compile is not yet a standards-compatibility guarantee.

## Build from source

Use Zig 0.15.2:

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all
zig build test-public-api --summary all
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
npm run test:prefix-data
npm run check:prefix-data
npm run test:zig-package
npm run test:compat
npm run test:transforms
```

## Recovery CLI

Run `zig-out/bin/zigcss --help` for the authoritative option list.

Available recovery options include file or bounded stdin input (`-`), file or stdout output (`-`), explicit `--syntax css`, output selection, explicit batch output planning, whitespace-only `--minify`, the closed verified `--optimize` preset, single-file `--watch`, `--profile`, and synchronized `--version`. The experimental `--lsp` server is separately labeled.

Single-file, watch, and batch CSS compilation all construct public `CompileOptions` and consume owned `CompileResult` values from one `zigcss.compile` call site. The executable retains argument parsing, path planning, file I/O, diagnostic rendering, and writes; it has no runtime import or parallel implementation of the parser, emitter, optimizer, alternate-format adapters, or autoprefixer.

Informational commands and successful compilation exit `0`. CSS diagnostics and operational I/O failures exit `1`; invalid, duplicate, missing, unavailable, or incoherent arguments exit `2`. Help and version text use stdout, while diagnostics, warnings, and usage errors use stderr. Stdin is single-input only and cannot be watched or mixed into batch mode; batch output cannot target stdout. The npm launcher inherits stdin/stdout/stderr, preserves all native exit codes, and re-raises POSIX termination signals instead of reporting false success.

File output creates missing parent directories only when committing a successful compilation, writes through a same-directory temporary file, and atomically replaces the destination without following a destination symlink or hard link. Batch outputs use `<stem>.css` when unique, add a deterministic normalized-path hash when stems collide, and fall back to a bounded hash name for long basenames. Compilation failure creates no output directory; after all inputs compile, each batch destination is committed atomically but the set of files is not a multi-file transaction if a later write or rename fails.

Watch mode hashes each root snapshot once and compiles those already-read bytes, eliminating the former poll-then-reread race. After a successful parse it also watches unique direct local relative `@import` paths, resolving them from the root stylesheet and ignoring remote, scheme-bearing, protocol-relative, origin-absolute, and filesystem-absolute URLs. Query and fragment suffixes do not become filesystem path bytes. A failed compile retains the last valid dependency set, and every observed root/dependency state is recorded before the attempt so unchanged read, parse, transform, or write errors are not retried every 500 ms.

Unavailable options—`--source-map`, `--autoprefix`, `--browsers`, and `--critical-*`—are rejected with an explanation. Unknown and malformed arguments are also rejected.

The optimizer preset reaches only seven verified order-preserving passes and repeats them under a 32-round safety bound until emitted bytes are stable. The rebuilt extraction passes are separate library/test-driver experiments, not CLI tree shaking and never part of `--optimize`. A complete class/ID inventory must describe the whole document snapshot or a closed critical selector-matching tree; missing or dynamic DOM evidence cannot be inferred from CSS.

## Performance claims

Public performance comparisons are withdrawn. Historical timings did not first prove equivalent output, and some measurements included incomparable process startup paths. New benchmark results will be publishable only after semantic validation, reproducible methodology, and the benchmark gates in the development plan pass.

## Contributing

Work in dependency order from `DEVELOPMENT_PLAN.md`. Each package should reproduce or measure first, add or strengthen tests, implement the smallest correct change, run proportionate verification, update `DEVELOPMENT_STATUS.md`, and commit a coherent checkpoint.

Do not re-enable a transform based only on smaller output or faster timing. Semantic equivalence is the gate.

## License

MIT. See [LICENSE](LICENSE).
