[![ZigCSS — Native by design. Correct by contract.](https://vyakymenko.github.io/zigcss/og.png)](https://vyakymenko.github.io/zigcss/)

# ZigCSS

[![Build](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml/badge.svg)](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml)
[![npm](https://img.shields.io/npm/v/zigcss?color=c8ff55&label=npm&labelColor=101914)](https://www.npmjs.com/package/zigcss)
[![License: MIT](https://img.shields.io/badge/license-MIT-c8ff55.svg?labelColor=101914)](LICENSE)

**Native by design. Fast on purpose. Correct by contract.**

**Compile CSS. Keep the meaning.**

**Five languages in. One deterministic compiler out.**

ZigCSS is an experimental native Zig CSS compiler built for low-overhead builds, deterministic output, and semantics-preserving transforms. It treats CSS like a language—not a string to rewrite until it looks smaller.

The current source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths. All five machine rows are `native-graduated`; executable plugin parity remains outside the contract.

[Website](https://vyakymenko.github.io/zigcss/) · [Input/output lab](https://vyakymenko.github.io/zigcss/#formats) · [Get started](https://vyakymenko.github.io/zigcss/getting-started) · [Documentation](https://vyakymenko.github.io/zigcss/docs) · [npm](https://www.npmjs.com/package/zigcss) · [Releases](https://github.com/vyakymenko/zigcss/releases)

> **Experimental release candidate:** npm currently serves ZigCSS 0.4.0-rc.3 with the tested CSS-only package surface. The release-ready native 0.6.0-rc.2 candidate remains unpublished pending its immutable tag workflow; evaluate it before production.

## Native dependency-free migration

Publication of the provider-backed 0.5 candidate was cancelled before tagging. Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 remain development-only reference oracles. They judge differential tests but do not enter the compiler, release archives, installed production graph, or compilation runtime.

The current native package contract has zero `dependencies` and zero `optionalDependencies`. The compiler itself starts no child process, performs no network access, and requires no runtime download. Five archive and offline-package jobs cover Linux x64/arm64, macOS x64/arm64, and Windows x64.

Publication remains a separate gate: `nativeReleaseReady: true` is bound to exact version 0.6.0-rc.2 after all nine pre-tag evidence surfaces passed. The tag workflow must still prove that this exact candidate checkpoint is live on `origin/main` before creating one immutable tag, GitHub prerelease, or npm `next` package.

`NATIVE-008` closed the finite source-capability inventory. `NATIVE-009` now graduates the four preprocessor machine rows together and opens only the exact release-candidate interlock; immutable tag-workflow publication remains pending, and executable plugin parity remains outside the contract.

## Why ZigCSS

| What matters | ZigCSS contract |
|---|---|
| Native execution | All five source inputs share native Zig compilation paths; the JavaScript delivery shim only invokes the binary. |
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

The source snapshot exposes explicit native CLI selection while keeping implementation evidence separate from public release state.

| Input | Source snapshot execution path | Machine migration state |
|---|---|---|
| CSS (`.css`) | Native ZigCSS tokenizer/parser | `native-graduated` |
| SCSS (`.scss`) | Native Sass-family parser/evaluator | `native-graduated` |
| Sass (`.sass`) | Native Sass-family parser/evaluator | `native-graduated` |
| Less (`.less`) | Native Less parser/evaluator | `native-graduated` |
| Stylus (`.styl`) | Native Stylus parser/evaluator | `native-graduated` |

`native-graduated` means the pinned corpus, negative/resource, deterministic, generated-CSS, product-routing, package, five-target, documentation, and pre-tag release gates pass on the same candidate. It does not grant executable provider or plugin extension points.

To evaluate the unpublished five-language source snapshot:

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build

zig-out/bin/zigcss --syntax css styles.css -o dist/styles.css --minify
zig-out/bin/zigcss --syntax scss styles.scss -o dist/styles.css --minify
zig-out/bin/zigcss --syntax sass styles.sass -o dist/styles.css --minify
zig-out/bin/zigcss --syntax less styles.less -o dist/styles.css --minify
zig-out/bin/zigcss --syntax stylus styles.styl -o dist/styles.css --minify
```

`--syntax` is deliberate: the compiler does not infer a native preprocessor route from the filename alone. Imports stay inside the entry directory and explicitly admitted load paths.

Arbitrary Sass plugins, custom functions and importers, Less JavaScript and plugins, Stylus plugins and evaluator hooks, and executable project code remain outside the native product contract.

```bash
zig-out/bin/zigcss --syntax scss src/app.scss \
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

The source-built executable is written to `zig-out/bin/zigcss` and routes all five inputs through native Zig code. The package JavaScript wrapper only locates and invokes the installed native binary; it does not host language semantics. Reference providers and their host remain development-only differential tools.

## JavaScript wrapper

The installed package exports a thin launcher. It forwards the closed CLI arguments to the packaged binary, preserves exit and signal behavior, and implements no parser, evaluator, provider host, or fallback. A public programmatic JavaScript preprocessor API is not claimed by this snapshot.

## Zig API

The stable `zigcss.compile` example remains CSS-only. It returns one owned compile result; call `deinit` exactly once.

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

The explicitly experimental `zigcss.experimental_native` namespace covers the finite SCSS, indented Sass, Less, and Stylus source set. This compiled example parameterizes all four rows, keeps resolver roots explicit, checks exact deterministic CSS, and deinitializes every owned result:

<!-- native-api-example:start -->
```zig
const std = @import("std");
const zigcss = @import("zigcss");

const native = zigcss.experimental_native;

const Example = struct {
    syntax: native.Syntax,
    filename: []const u8,
    source: []const u8,
    expected: []const u8,
};

const examples = [_]Example{
    .{ .syntax = .scss, .filename = "example.scss", .source = "$color: red; .card { color: $color; }", .expected = ".card{color:red}" },
    .{ .syntax = .sass, .filename = "example.sass", .source = "$color: red\n.card\n  color: $color\n", .expected = ".card{color:red}" },
    .{ .syntax = .less, .filename = "example.less", .source = "@color: red; .card { color: @color; }", .expected = ".card{color:red}" },
    .{ .syntax = .stylus, .filename = "example.styl", .source = "color = red\n.card\n  color color\n", .expected = ".card{color:#f00}" },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    inline for (examples) |example| {
        const entry = try std.fs.path.join(allocator, &.{ root, example.filename });
        defer allocator.free(entry);
        var result = try native.compile(allocator, entry, example.source, .{
            .syntax = example.syntax,
            .root_paths = &.{root},
            .format = .minified,
        });
        defer result.deinit();
        if (result.diagnostics.len != 0 or !std.mem.eql(u8, result.css, example.expected)) {
            return error.UnexpectedNativeResult;
        }
        try writer.interface.print("{s}\n", .{result.css});
    }
    try writer.interface.flush();
}
```
<!-- native-api-example:end -->

The same documentation gate executes the five committed files under [examples/native](examples/native) through the source-built binary with explicit `--syntax`. Neither example invokes a provider, child language engine, plugin, network service, or runtime download.

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

- The VS Code preview uses Marketplace version 0.6.0 for the current CSS core mapping and requires a separately installed ZigCSS binary.
- The [Neovim configuration](neovim-config/README.md) uses the built-in LSP client and an explicit trusted executable path.

Neither integration bundles a compiler binary.

Editor integrations remain CSS-only today. They do not silently execute preprocessor plugins or project code.

## Project status

- Source candidate: 0.6.0-rc.2 is release-ready, experimental, unpublished, and pending its immutable tag workflow.
- CSS core: `native-graduated`.
- SCSS, indented Sass, Less, and Stylus: `native-graduated` after parser/evaluator, pinned conformance, native product-routing, package, five-target, and pre-tag release gates.
- Production package closure: verified with zero production dependencies and no provider or host bytes; the compiler itself starts no child process and performs no network access.
- Reference engines: retained only as exact development oracles and excluded from production bytes and runtime execution.
- Public capability graduation: all seven predeclared `NATIVE-008` surfaces match native evidence; `NATIVE-009` binds the exact release-ready identity while immutable publication remains pending.
- Controlled comparative benchmark: waiting for the dedicated Linux x64 archive.
- Publication: pending until the existing workflow rechecks the exact candidate against live `origin/main`, then produces the single authorized immutable tag outcome, GitHub prerelease, and npm `next` publication.

The [development plan](DEVELOPMENT_PLAN.md) and [durable execution ledger](DEVELOPMENT_STATUS.md) remain in the repository until the native roadmap, release, and benchmark gates close.

## Contributing

Bring a minimal source input, expected semantics, actual output or diagnostic, and the relevant language-engine version. Run the focused language gate plus Debug and ReleaseSafe before opening a pull request.

High-value contributions include reduced compatibility cases, independent CSS validation, fuzz seeds, controlled benchmark runner capacity, and integrations that preserve the closed execution boundary.

## License

MIT. See [LICENSE](LICENSE).
