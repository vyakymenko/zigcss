[![ZigCSS — Native by design. Correct by contract.](https://vyakymenko.github.io/zigcss/og.png)](https://vyakymenko.github.io/zigcss/)

# ZigCSS

[![Build](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml/badge.svg)](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml)
[![npm](https://img.shields.io/npm/v/zigcss?color=c8ff55&label=npm&labelColor=101914)](https://www.npmjs.com/package/zigcss)
[![License: MIT](https://img.shields.io/badge/license-MIT-c8ff55.svg?labelColor=101914)](LICENSE)

**Native by design. Fast on purpose. Correct by contract.**

**Compile CSS. Keep the meaning.**

**Five languages in. One deterministic compiler out.**

ZigCSS is an experimental native Zig CSS compiler built for low-overhead builds, deterministic output, and semantics-preserving transforms. It treats CSS like a language—not a string to rewrite until it looks smaller.

The destination is one self-contained compiler for CSS, SCSS, indented Sass, Less, and Stylus. CSS is native today; the four preprocessor frontends are moving through private native conformance gates before ZigCSS makes a public dependency-free claim.

[Website](https://vyakymenko.github.io/zigcss/) · [Input/output lab](https://vyakymenko.github.io/zigcss/#formats) · [Get started](https://vyakymenko.github.io/zigcss/getting-started) · [Documentation](https://vyakymenko.github.io/zigcss/docs) · [npm](https://www.npmjs.com/package/zigcss) · [Releases](https://github.com/vyakymenko/zigcss/releases)

> **Experimental release candidate:** npm currently serves ZigCSS 0.4.0-rc.3 with the tested CSS-only package surface. The green 0.5.0-rc.1 source snapshot adds a canonical five-language reference pipeline, but it is unpublished and should be evaluated before production.

## Native dependency-free migration

Publication of the provider-backed 0.5 candidate was cancelled before tagging. Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 now act as pinned development oracles while Zig replacements earn graduation. The target 0.6 release has zero production dependencies, no provider process, and no runtime download.

## Why ZigCSS

| What matters | ZigCSS contract |
|---|---|
| Native execution | The direct CSS path is a Zig binary and library with no language-provider startup. |
| Semantic safety | Transform classes stay unavailable until equivalence, idempotence, and independent-parser gates pass. |
| Failure behavior | Compilation is atomic. An error, cancellation, limit, or allocation failure returns no partial CSS. |
| Determinism | Replay, batch order, parallel workers, source maps, diagnostics, and packaging have executable checks. |
| Ownership | CSS, diagnostics, dependencies, source maps, module exports, and profile data share one explicit result lifetime. |
| Delivery | Linux x64/arm64, macOS x64/arm64, and Windows x64 archive paths are tested. |

Your CSS deserves a real compiler: bounded input, a recovery-disabled parser, explicit transforms, strict output validation, and an atomic write at the end.

## Install

Install the public CSS-only prerelease:

```bash
npm install --save-dev zigcss@next
```

Compile CSS:

```bash
npx zigcss input.css -o dist/output.css --minify
```

Input:

```css
.button {
  color: #08100b;
  background: #c8ff55;
}
```

Output:

```css
.button{color:#08100b;background:#c8ff55}
```

Successful commands exit `0`; compilation and I/O failures exit `1`; usage or configuration failures exit `2`.

## Five syntaxes, one CSS destination

The current repository snapshot keeps native availability and reference behavior deliberately separate.

| Input | Current execution path | Native target |
|---|---|---|
| CSS (`.css`) | Native ZigCSS | Graduated |
| SCSS (`.scss`) | Dart Sass 1.101.0 → ZigCSS validation | Private Zig parser/evaluator in progress |
| Sass (`.sass`) | Dart Sass 1.101.0 → ZigCSS validation | Private Zig parser/evaluator in progress |
| Less (`.less`) | Less 4.6.7 → ZigCSS validation | Planned after Sass graduation |
| Stylus (`.styl`) | Stylus 0.64.0 → ZigCSS validation | Planned after Less graduation |

To evaluate the unpublished five-language source snapshot:

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
npm ci
zig build

node index.js styles.css -o dist/styles.css --minify
node index.js styles.scss -o dist/styles.css --minify
node index.js styles.sass -o dist/styles.css --minify
node index.js styles.less -o dist/styles.css --minify
node index.js styles.styl -o dist/styles.css --minify
```

The canonical reference pipeline disables arbitrary plugins, custom functions, custom importers, Less JavaScript, custom file managers, Stylus evaluator hooks, and executable project code by default. Imports stay inside the entry directory and explicitly admitted load paths.

```bash
node index.js src/app.scss \
  --load-path src/tokens \
  --source-map \
  --minify \
  -o dist/app.css
```

See the [format compatibility matrix](docs/src/content/docs/guide/format-compatibility.md), [CSS compatibility matrix](docs/src/content/docs/guide/css-compatibility.md), and [current capability status](docs/src/content/docs/guide/status.md).

## Benchmarks

ZigCSS is engineered for a low-overhead native path, but this project does not turn a laptop stopwatch into a marketing multiplier.

The benchmark program is already executable and publication-gated:

| Evidence gate | Required proof |
|---|---|
| Semantic equivalence | Every timed output must pass independent CSS admission before its timing is accepted. |
| Workload coverage | Small, medium, and large deterministic corpora are versioned and checksum-bound. |
| Execution modes | Cold CLI, warm CLI, in-process API, allocator memory, and throughput stay separately labeled. |
| Statistics | 43 ordered series and 860 raw observations are retained—never only the winning median. |
| Hardware | The publishable archive must come from dedicated, non-emulated, controlled Linux x64 hardware. |
| Reproduction | Source SHA, runner identity, tool versions, raw report, manifest, digest, and artifact link are sealed together. |

**Current status:** the pipeline is ready, but the final controlled runner archive does not exist yet. Timing, ranking, throughput, memory, and ratio numbers remain unpublished until that evidence lands.

Read the [benchmark report and publication contract](BENCHMARK_REPORT.md). When the controlled archive passes, the report and this section can be generated from retained evidence instead of hand-edited hype.

## Compiler pipeline

```text
source bytes
    ↓
bounded lexer and parser
    ↓
typed, safety-classed transforms
    ↓
recovery-disabled CSS validation
    ↓
owned result + atomic output
```

The CSS-only native executable is written to `zig-out/bin/zigcss`. In the 0.5 source snapshot, the root npm launcher composes that core with the exact canonical development providers. The 0.6 target removes that host boundary after all native language rows graduate.

## JavaScript API

The source snapshot exposes the same five syntax values through `zigcss/api` and returns CSS, diagnostics, ordered dependencies, and an optional composed source map.

```text
import { compileFile, compileString } from 'zigcss/api';

const file = await compileFile('src/app.scss', {
  format: 'minified',
  loadPaths: ['src/tokens'],
  sourceMap: true,
});

const inline = await compileString('.notice { color: red; }', {
  syntax: 'css',
  format: 'minified',
});
```

Failures throw `ZigCssCompileError` with normalized diagnostics and never attach partial CSS. Option schemas are closed before any provider process can start.

## Zig API

The native Zig API returns one owned compile result. Call `deinit` exactly once.

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

`build.zig.zon` gives the source package stable identity `zigcss`. The build module exposes `helpers.addCssCompile` for declared CSS inputs and generated outputs. See [examples/build-integration](examples/build-integration).

## Build and verify

Use Zig 0.15.2:

```bash
npm ci
zig build
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
npm run test:preprocessor-product
npm run test:formats
```

The native migration boundary is machine-readable and fail-closed:

```bash
npm run test:native-contract
npm run check:native-contract
```

ADR-013 defines the [self-contained native frontend contract](docs/adr/ADR-013-self-contained-native-frontends.md).

## Editor integration

The experimental CSS LSP covers bounded JSON-RPC framing, full document sync, UTF-16 positions, pull diagnostics, and syntax-aware open-document features.

Its release checks pass large-document, Unicode, malformed-request, leak, and editor-integration gates.

- The VS Code preview uses Marketplace version 0.5.0 for the current CSS core mapping and requires a separately installed ZigCSS binary.
- The [Neovim configuration](neovim-config/README.md) uses the built-in LSP client and an explicit trusted executable path.

Neither integration bundles a compiler binary.

Editor integrations remain CSS-only today. They do not silently execute preprocessor plugins or project code.

## Project status

- Source candidate: 0.5.0-rc.1 on green main; experimental and unpublished.
- CSS core: native and graduated.
- SCSS/Sass: native parser complete; semantic core under active conformance development.
- Less and Stylus: exact reference suites retained; native implementations pending in dependency order.
- Native package routing and zero-dependency cutover: gated behind all language graduations.
- Controlled comparative benchmark: waiting for the dedicated Linux x64 archive.
- Publication: always a separate authorized, fail-closed operation.

The [development plan](DEVELOPMENT_PLAN.md) and [durable execution ledger](DEVELOPMENT_STATUS.md) remain in the repository until the native roadmap, release, and benchmark gates close.

## Contributing

Bring a minimal source input, expected semantics, actual output or diagnostic, and the relevant language-engine version. Run the focused language gate plus Debug and ReleaseSafe before opening a pull request.

High-value contributions include reduced compatibility cases, independent CSS validation, fuzz seeds, controlled benchmark runner capacity, and integrations that preserve the closed execution boundary.

## License

MIT. See [LICENSE](LICENSE).
