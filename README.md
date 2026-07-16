# ZigCSS

[![Build](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml/badge.svg)](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-17201b.svg)](LICENSE)

ZigCSS is a native CSS compiler and Zig library focused on deterministic output, semantic preservation, and explicit safety boundaries.

> **Experimental release candidate:** ZigCSS 0.4.0-rc.2 is ready for evaluation, not unrestricted production adoption. CSS coverage is matrix-tested but not complete, and public performance comparisons remain withdrawn until the controlled benchmark gate closes.

## Install

Install the prerelease channel from npm:

```bash
npm install --save-dev zigcss@next
```

Pin the exact candidate for reproducible evaluation:

```bash
npm install --save-dev zigcss@0.4.0-rc.2
```

The npm launcher downloads the matching native binary during installation. Release archives are built for:

| Platform | Architecture |
|---|---|
| Linux | x64, arm64 |
| macOS | x64, arm64 |
| Windows | x64 |

You can also use the signed assets on [GitHub Releases](https://github.com/vyakymenko/zigcss/releases), install the repository [Homebrew formula](Formula/zigcss.rb), or build from source.

## Use

Compile one CSS file:

```bash
npx zigcss input.css -o output.css
```

Minify whitespace:

```bash
npx zigcss input.css -o output.css --minify
```

Run the closed, acceptance-gated optimizer preset:

```bash
npx zigcss input.css -o output.css --optimize --minify
```

Standard input and output are explicit:

```bash
printf '.notice { color: red; }' | npx zigcss - -o - --minify
```

The result is:

```css
.notice{color:red}
```

Run `npx zigcss --help` for the authoritative option list. Successful commands exit `0`, compilation or I/O failures exit `1`, and usage/configuration failures exit `2`.

## Language support

ZigCSS does **not** claim full CSS, SCSS, Sass, or Less support.

| Input | Current status | Boundary |
|---|---|---|
| CSS (`.css`) | Experimental, matrix-tested | Stable CLI input. The published compatibility matrix defines the tested grammar. |
| CSS Modules | Experimental Zig-library subset | Opt-in native API syntax; not exposed by the CLI or LSP. |
| SCSS / Sass | Not supported | Extensions are rejected before output; there is no preprocessor adapter. |
| Less | Not supported | Extensions are rejected before output; there is no preprocessor adapter. |
| Stylus, CSS-in-JS, PostCSS, Tailwind adapters | Not supported | No alternate-format or ecosystem adapter is shipped. |

See the [CSS compatibility matrix](docs/src/content/docs/guide/css-compatibility.md), [format compatibility guide](docs/src/content/docs/guide/format-compatibility.md), and [complete capability status](docs/src/content/docs/guide/status.md) before adopting the candidate.

## What is verified

- The CSS tokenizer, parser, emitter, CLI, and output planner have regression and independent-parser gates.
- Output files are planned deterministically and replaced atomically; aliases and duplicate destinations fail closed.
- `--minify` is independent from the seven-pass `--optimize` preset.
- Debug and ReleaseSafe test suites exercise the same public compile path used by the CLI.
- Release archives must pass native execution, offline npm lifecycle, SHA-256, SPDX SBOM, SLSA provenance, and signed-SBOM verification before upload.
- Browser-target prefixing, source maps, extraction, plugins, and CSS Modules remain explicitly library-only or experimental where documented.

A successful compile is not a browser-equivalence guarantee. Property values outside the typed transforms are often preserved as lossless component trees, and computed-style validation is not yet a release gate.

## Zig API

The public Zig API returns one owned result containing CSS, diagnostics, ordered imports, optional source maps, optional module exports, and optional profiling metrics. Call `deinit` exactly once after use.

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

`build.zig.zon` gives the source package stable identity `zigcss` and a minimal allowlist. The build module exposes `helpers.addCssCompile`, which accepts one declared CSS input, produces one generated output, and participates in Zig's build cache. The complete consumer example is in [examples/build-integration](examples/build-integration).

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

## Editor integration

The experimental LSP covers bounded JSON-RPC framing, full document sync, UTF-16 positions, pull diagnostics, and syntax-aware open-document features. Its stress tests pass large-document, Unicode, malformed-request, leak, and editor-integration gates.

- The VS Code preview uses Marketplace version 0.4.0 and requires a separately installed ZigCSS binary.
- The [Neovim configuration](neovim-config/README.md) uses the built-in LSP client and an explicit trusted executable path.

Neither integration bundles a compiler binary.

## Documentation

- [Package website](https://vyakymenko.github.io/zigcss/)
- [Getting started](https://vyakymenko.github.io/zigcss/getting-started)
- [Current capability status](docs/src/content/docs/guide/status.md)
- [Recovery CLI contract](docs/src/content/docs/guide/recovery-cli.md)
- [CSS Modules subset](docs/src/content/docs/guide/css-modules.md)
- [Build and package integration](docs/src/content/docs/guide/build-from-source.md)
- [Benchmark evidence status](BENCHMARK_REPORT.md)

## Performance claims

ZigCSS currently publishes no comparative speed ranking or multiplier. The benchmark pipeline requires equivalent output, pinned modes, complete statistics, controlled Linux x64 provenance, and a retained scheduled archive before it can update [BENCHMARK_REPORT.md](BENCHMARK_REPORT.md).

## Contributing

Please open a focused issue or pull request with a minimal reproduction and semantic expectation. Run the relevant Debug and ReleaseSafe gates before submitting parser, emitter, or transform changes.

The internal [development plan](DEVELOPMENT_PLAN.md) and [execution ledger](DEVELOPMENT_STATUS.md) remain in the repository until the release and controlled benchmark gates are complete; they are not package usage documentation.

## License

MIT. See [LICENSE](LICENSE).
