[![ZigCSS — Compile CSS. Keep the meaning.](https://vyakymenko.github.io/zigcss/og.png)](https://vyakymenko.github.io/zigcss/)

# ZigCSS

[![Build](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml/badge.svg)](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-17201b.svg)](LICENSE)

**Compile CSS. Keep the meaning.**

## Five languages in. One deterministic compiler out.

ZigCSS is an experimental native CSS compiler with canonical SCSS, indented Sass, Less, and Stylus frontends. Exact language engines handle their own grammars; the Zig core then reparses, validates, transforms, and emits the result through one fail-closed contract.

**This is where preprocessor convenience meets compiler discipline:** confined imports, owned diagnostics and dependencies, composed source maps, atomic output, deterministic batches, and no partial CSS after failure.

[Website](https://vyakymenko.github.io/zigcss/) · [Interactive input/output lab](https://vyakymenko.github.io/zigcss/#formats) · [Get started](https://vyakymenko.github.io/zigcss/getting-started) · [Documentation](https://vyakymenko.github.io/zigcss/docs) · [npm](https://www.npmjs.com/package/zigcss) · [Releases](https://github.com/vyakymenko/zigcss/releases)

> **Experimental release candidate notice:** the green `main` branch is the unpublished ZigCSS 0.5.0-rc.1 source candidate described below. The currently published npm package, ZigCSS 0.4.0-rc.3, exposes the earlier CSS-only surface. Five-language npm publication and release artifacts remain pending the explicit release step. Evaluate both before production.

## Why ZigCSS feels different

- **Canonical language behavior.** SCSS and Sass use Dart Sass 1.101.0, Less uses Less 4.6.7, and Stylus uses Stylus 0.64.0. ZigCSS does not pretend a hand-written approximation is the language.
- **One hard output boundary.** Provider output must survive the recovery-disabled ZigCSS parser before any CSS is returned or committed.
- **Security is part of the API.** Local imports are root-confined. Network access and executable project extensions are denied by default.
- **Determinism is tested, not implied.** Repetition, parallel workers, batch ordering, watch invalidation, maps, diagnostics, packages, and five native targets have executable gates.
- **Semantics before speed.** Stable transforms cross equivalence, idempotence, and independent-parser gates. Unsupported authority stays unavailable.

## Install

The public prerelease channel currently installs the CSS-only ZigCSS 0.4.0-rc.3 candidate:

```bash
npm install --save-dev zigcss@next
```

To evaluate the five-language 0.5.0-rc.1 source candidate today:

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
npm ci
zig build
node index.js --help
```

The package selects a matching native core for Linux x64/arm64, macOS x64/arm64, or Windows x64. The 0.5 source snapshot's package manifest also carries its exact canonical providers and reviewed runtime closure; it does not discover language engines from ambient project dependencies.

## Use five input languages

The npm launcher detects syntax by extension, or accepts `--syntax <css|scss|sass|less|stylus>` for stdin and explicit selection.

```bash
node index.js styles.css -o dist/styles.css --minify
node index.js styles.scss -o dist/styles.css --minify
node index.js styles.sass -o dist/styles.css --minify
node index.js styles.less -o dist/styles.css --minify
node index.js styles.styl -o dist/styles.css --minify
```

For installed 0.5 package bytes, the same commands use `npx zigcss` rather than `node index.js`.

Imports stay inside the entry directory and any explicit load paths:

```bash
node index.js src/app.scss --load-path src/tokens -o dist/app.css --source-map
```

Standard input requires an explicit syntax for preprocessors:

```bash
printf '$accent: red; .notice { color: $accent; }' | node index.js - --syntax scss -o - --minify
```

The result is:

```css
.notice{color:red}
```

Run `node index.js --help` for the combined contract. Successful commands exit `0`, compilation or I/O failures exit `1`, and usage/configuration failures exit `2`.

## Language contract

| Input | Canonical engine | Public 0.5 surface | Deliberate boundary |
|---|---|---|---|
| CSS (`.css`) | Native ZigCSS | npm CLI and API | Experimental, matrix-tested CSS grammar |
| SCSS (`.scss`) | Dart Sass 1.101.0 | npm CLI and API | Exact provider language; no arbitrary plugins, custom functions, or custom importers |
| Indented Sass (`.sass`) | Dart Sass 1.101.0 | npm CLI and API | Source bytes stay indented Sass; same executable-extension boundary |
| Less (`.less`) | Less 4.6.7 | npm CLI and API | JavaScript, plugins, and custom file managers remain disabled |
| Stylus (`.styl`) | Stylus 0.64.0 | npm CLI and API | Project plugins, custom functions, and evaluator hooks remain disabled |
| CSS Modules (`.module.css`) | ZigCSS native subset | Experimental Zig library only | Closed documented subset; not npm CLI or LSP input |

“Canonical support” means behavior owned by those exact provider versions plus the documented ZigCSS integration options. It does **not** mean parity with every third-party plugin, custom function, custom importer, JavaScript hook, future provider version, or framework toolchain. CSS-in-JS, PostCSS plugin hosts, and Tailwind-like adapters remain outside the public contract.

See the [format compatibility matrix](docs/src/content/docs/guide/format-compatibility.md), [CSS compatibility matrix](docs/src/content/docs/guide/css-compatibility.md), and [complete capability status](docs/src/content/docs/guide/status.md).

## JavaScript API

The npm API exposes the same five syntax values and returns owned CSS, diagnostics, ordered dependencies, and an optional composed source map.

```text
import { compileFile, compileString } from 'zigcss/api';

const file = await compileFile('src/app.scss', {
  format: 'minified',
  loadPaths: ['src/tokens'],
  sourceMap: true,
});

const inline = await compileString('@accent: red; .a { color: @accent; }', {
  syntax: 'less',
  format: 'minified',
});
```

Failures throw `ZigCssCompileError` with normalized diagnostics and never attach partial CSS. Option schemas are closed before a provider process starts.

## Zig API

The native Zig API remains the CSS core. It returns one owned result containing CSS, diagnostics, ordered imports, optional source maps, optional module exports, and optional profiling metrics. Call `deinit` exactly once.

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

`build.zig.zon` gives the source package stable identity `zigcss` and a minimal allowlist. The build module exposes `helpers.addCssCompile` for declared CSS inputs and generated outputs. See [examples/build-integration](examples/build-integration).

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

The CSS-only native executable is written to `zig-out/bin/zigcss`; the root npm launcher composes it with the canonical frontend host.

## Editor integration

The experimental CSS LSP covers bounded JSON-RPC framing, full document sync, UTF-16 positions, pull diagnostics, and syntax-aware open-document features. Its stress tests pass large-document, Unicode, malformed-request, leak, and editor-integration gates.

- The VS Code preview uses Marketplace version 0.5.0 for the current core mapping and requires a separately installed ZigCSS binary.
- The [Neovim configuration](neovim-config/README.md) uses the built-in LSP client and an explicit trusted executable path.

Neither integration bundles a compiler binary.

Editor integrations remain CSS-only today; they do not silently execute preprocessor plugins or project code.

## Release and performance status

The source tree is release-gated, but 0.5 packages and artifacts have not been published. Publication is a separate authorized operation, not an automatic consequence of a green branch.

ZigCSS currently publishes no comparative speed ranking or multiplier. The benchmark pipeline requires equivalent output, pinned modes, complete statistics, controlled Linux x64 provenance, and a retained scheduled archive before it can update [BENCHMARK_REPORT.md](BENCHMARK_REPORT.md).

## Contributing

Open a focused issue or pull request with a minimal source input, expected semantics, actual diagnostics/output, and provider version where relevant. Run the focused language gate plus Debug and ReleaseSafe core gates.

The internal [development plan](DEVELOPMENT_PLAN.md) and [execution ledger](DEVELOPMENT_STATUS.md) remain until the roadmap, release, and controlled benchmark gates close.

## License

MIT. See [LICENSE](LICENSE).
