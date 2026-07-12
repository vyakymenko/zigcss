# ZigCSS

> **Experimental recovery status:** ZigCSS 0.4.0-rc.1 is an unpublished release candidate produced by a correctness-first rebuild. It is not suitable for production stylesheets.

The repository contains a rebuilt CSS source/token/syntax/parser/emitter pipeline alongside inherited prototype transforms, format adapters, an LSP, documentation, packaging, and benchmarks. The stable CLI delegates compilation to the owned public `zigcss.compile` facade over the rebuilt pipeline, while the remaining program still prioritizes security and semantics before features or speed.

The authoritative roadmap is [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Execution evidence and package state are tracked in [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md).

## Autonomous development operations

The repository keeps its persistent Codex procedure in [docs/operations/codex-loop-protocol.md](docs/operations/codex-loop-protocol.md). A read-only orientation helper reconstructs branch, dirty state, ledger work, blockers, validation evidence, checkpoints, and toolchain visibility:

```bash
bash scripts/autodevelop/orient.sh
```

The helper does not launch a model or mutate the repository; the active Codex task owns scheduling and goal continuation.

## Current contract

<!-- capability-status:start -->
| Surface | Status | Current behavior |
|---|---|---|
| .css parsing and emission | Experimental, matrix-tested | Strict file/stdin and file/stdout modes delegate to `zigcss.compile`; version, syntax, options, and 0/1/2 exit statuses are executable contracts. |
| Zig compile API | Experimental, consumer-tested | `zigcss.compile` returns owned CSS, maps, located diagnostics, ordered imports, optional module exports, and metrics; accepted transforms and borrowed canonical targets are explicit options. |
| Zig package metadata | Experimental, consumer-tested | Package `zigcss` 0.4.0-rc.1 declares minimum Zig 0.15.2 and a minimal source allowlist; path and fresh fetched-cache consumers resolve module `zigcss`. |
| Zig build helper | Experimental, consumer-tested | `@import("zigcss").helpers.addCssCompile` uses declared lazy inputs and generated outputs with a host compiler artifact; unavailable CLI features have no helper path. |
| Native plugins | Experimental, trusted/library-only | Explicit `.experimental` options run borrowed `plugin.`-namespaced Zig callbacks through bounded deterministic pass plans; there is no stable ABI, sandbox, CLI, or HTTP path. |
| --minify | Experimental | Compacts emitted whitespace without enabling AST transforms and remains independent of `--optimize`. |
| Output planning | Safety boundary verified | Rejects input/output aliases and duplicate final destinations; batch names are deterministic and every file destination is atomically replaced. |
| --profile | Experimental, measured | Reports one monotonic public compile total, actual stage intervals, and allocator-requested allocation, live, and retained metrics from the owned API result. |
| Verified optimizer preset | Experimental, acceptance-gated | `--optimize` runs exactly seven verified analysis, cleanup, and semantic passes to a bounded byte-stable fixed point; separately authorized classes remain excluded. |
| Dead-code and critical-CSS extraction | Experimental, library/test-only | Two bounded passes use complete class/ID inventories and require separate experimental plus extraction authority; stable CLI flags remain unavailable. |
| Target prefix rewrite | Experimental, library-only | One verified pass covers eight pinned property, value, selector, and at-rule features through the pass manager and test driver; it is not a general autoprefixer. |
| Source maps | Experimental, library-only | The library pipeline produces deterministic separately owned mappings; the CLI output policy remains unavailable. |
| Browser target queries | Experimental, library-only | A strict explicit-minimum grammar over six browsers configures pinned BCD 8.0.0 data; `--browsers` and `--autoprefix` remain unavailable in the CLI. |
| CSS Modules | Experimental, Zig-library-only native subset | Explicit `.syntax = .css_modules` provides source-specific class names, functional scope, plain-class composition references and dependencies, and local values with owned results; CLI and LSP exposure remain unavailable. |
| Alternate format adapters | Unavailable | SCSS, Sass, Less, Stylus, CSS-in-JS, PostCSS-like, and Tailwind-like compiler adapters are removed; their extensions are rejected before output. |
| LSP | Experimental, stress-tested | Bounded framing, JSON-RPC lifecycle, full sync, UTF-16 positions, pull diagnostics, and syntax-aware open-document features pass large-document, Unicode, malformed-request, leak, and editor-integration gates. |
| VS Code extension | Experimental, package-tested | Marketplace version 0.4.0 maps to core 0.4.0-rc.1 and packages only with the pre-release marker; its exact lockfile, CSS-only trust boundaries, deterministic executable discovery, 13 tests, and five-file VSIX are verified; no binary is bundled or published. |
| Neovim configuration | Experimental, integration-tested | The CSS-only built-in config resolves one trusted absolute executable and passes real Neovim 0.11.7 and 0.12.4 command, capability, diagnostic, hover, rejection, and shutdown smokes; no plugin or binary is bundled. |
| Public compile API and playground | Disabled | Public compile routes return HTTP 503 until bounded process and request isolation is implemented. |
<!-- capability-status:end -->

This table, the published status guide, and the site feature page consume `docs/src/data/capabilities.json`. Every row names executable evidence gates, and `npm run check:capability-status` rejects metadata, evidence-anchor, or generated-table drift.

## Experimental Zig compile API

`build.zig` registers one external module named `zigcss` at `src/lib.zig`. `zigcss.compile` accepts `CompileOptions` for syntax, output format, separate source maps, verified CSS transforms, a borrowed canonical target query, bounded dependency/module reporting, and opt-in profiling. Its move-only-by-convention `CompileResult` owns CSS, optional map bytes, located structured diagnostics, ordered decoded top-level `@import` dependencies, optional module exports, and optional measured compile metrics through one idempotent `deinit` path.

The stable CSS path returns `module_exports = null`. Explicit `.syntax = .css_modules` selects the [experimental native subset](docs/src/content/docs/guide/css-modules.md): local-by-default classes receive versioned source-specific SHA-256 names; functional local/global scope is occurrence-sensitive; plain-class composition owns ordered local/global/dependency references; and sequential local values share the first-authored export namespace. Module dependencies are facts, never implicit loads. The CLI remains CSS-only. CSS Modules reject optimizer/prefix/plugin composition, imported values, raw ICSS, and syntax outside the closed grammar without partial CSS or metadata; incoherent options return owned `API0001` diagnostics.

With `.profile = true`, the result includes one monotonic end-to-end duration plus measured parse, validation, dependency, optimizer, plugin/prefix transform, emit, result-promotion, and cleanup stages. A forwarding allocator records successful allocation/free/resize events, cumulative requested/freed bytes, peak live requested bytes, and result bytes retained after compiler cleanup. These are allocator-requested byte metrics, not operating-system RSS. Profiling-disabled calls install no wrapper; an unavailable monotonic timer fails explicitly instead of returning invented zeroes.

`build.zig.zon` gives the source package stable identity `zigcss`, version 0.4.0-rc.1, fingerprint `0xae272a4871e93d07`, and minimum Zig 0.15.2. Its allowlist contains only `build.zig`, the manifest, supported `build_helpers.zig`, `src`, README, and license. `tests/package-consumer` is a real path dependency that resolves `zigcss.module("zigcss")`; an isolated `zig fetch .` copy with only allowlisted files passes the same API smoke. No remote package URL is published.

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

Property-specific values are usually preserved as lossless component trees rather than fully validated semantics. Browser computed-style validation, broader prefix data and prefix CLI exposure, element/attribute or dynamic-DOM extraction, optimized source-map composition, CLI source-map output, filesystem-backed LSP workspace loading, editor publication/binary distribution, CSS Modules ID/keyframe scoping, imported values/raw ICSS, other alternate formats, and resource-bounded public compilation remain incomplete.

Do not use current output in a production pipeline. A successful compile is not yet a standards-compatibility guarantee.

## Build from source

Use Zig 0.15.2:

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all
zig build test-public-api --summary all
zig build test-documentation-examples --summary all
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
npm run test:capability-status
npm run check:capability-status
NVIM=/absolute/path/to/nvim npm run test:documentation
npm run check:documentation
npm run test:dependencies
npm run check:dependencies
npm run audit:production
npm run test:zig-package
npm run test:vscode
NVIM=/absolute/path/to/nvim npm run test:neovim
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

Batch compilation uses a dynamic queue with at most eight workers and never shares a result allocator between tasks. The first observed task failure closes the queue; already-running tasks finish safely, unclaimed tasks become explicitly cancelled, and no destination is written unless every task succeeds. Worker-spawn failure cancels and joins every started thread before ownership unwinds. Diagnostics, atomic output commits, and status lines are processed in original argument order rather than completion order.

Unavailable options—`--source-map`, `--autoprefix`, `--browsers`, and `--critical-*`—are rejected with an explanation. Unknown and malformed arguments are also rejected.

The optimizer preset reaches only seven verified order-preserving passes and repeats them under a 32-round safety bound until emitted bytes are stable. The rebuilt extraction passes are separate library/test-driver experiments, not CLI tree shaking and never part of `--optimize`. A complete class/ID inventory must describe the whole document snapshot or a closed critical selector-matching tree; missing or dynamic DOM evidence cannot be inferred from CSS.

## Performance claims

Public performance comparisons are withdrawn. Historical timings did not first prove equivalent output, and some measurements included incomparable process startup paths. New benchmark results will be publishable only after semantic validation, reproducible methodology, and the benchmark gates in the development plan pass.

## Contributing

Work in dependency order from `DEVELOPMENT_PLAN.md`. Each package should reproduce or measure first, add or strengthen tests, implement the smallest correct change, run proportionate verification, update `DEVELOPMENT_STATUS.md`, and commit a coherent checkpoint.

Do not re-enable a transform based only on smaller output or faster timing. Semantic equivalence is the gate.

## License

MIT. See [LICENSE](LICENSE).
