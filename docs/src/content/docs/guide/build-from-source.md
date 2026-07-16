# Build from source

Source builds are the verified installation path during recovery. Local Zig package dependencies are consumer-tested below; no remote package URL or prebuilt-release installation is advertised until later artifact and installer gates pass.

## Requirements

- Zig 0.15.2
- Git

## Build and test

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all
zig build test-public-api --summary all
zig build test-documentation-examples --summary all
```

The executable is written to `zig-out/bin/zigcss`.

`test-public-api` compiles a separate Zig consumer against the module name `zigcss`. It verifies the owned high-level compile facade, result cleanup, the explicit native CSS Modules subset, and an experimental borrowed native-plugin callback without claiming a stable plugin ABI or full ecosystem compatibility.

## Zig library example

This exact example is compiled by `test-public-api`:

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

Set `.profile = true` to populate `result.metrics` with `CompileMetrics`; the public root also exports `CompileStageTimings` and `CompileMemoryMetrics`. The total uses one monotonic session around the real compile, while stage fields cover parse, validation, dependencies, optimization, plugin/prefix transforms, emission, result promotion, and temporary cleanup. Memory fields count allocator-requested bytes and operations through a forwarding wrapper; they are not process RSS. Result buffers remain compatible with normal `result.deinit()` because the wrapper forwards exact pointers from the caller's allocator.

Set `.syntax = .css_modules` only for the [experimental native CSS Modules subset](/guide/css-modules). A successful result owns class/local-value exports, nested composition references, and bounded module dependency facts; it never loads dependencies. The recovery executable and build helper remain CSS-only.

## Local Zig package dependency

The root `build.zig.zon` declares package `zigcss` 0.4.0-rc.3, fingerprint `0xae272a4871e93d07`, and minimum Zig 0.15.2. It exports only `build.zig`, `build.zig.zon`, supported `build_helpers.zig`, `src`, `README.md`, and `LICENSE`. Tests, docs, package-manager wrappers, and editor files are not part of the Zig package.

`tests/package-consumer` declares the repository as a path dependency, requests `zigcss.module("zigcss")`, and compiles the owned API from outside the package. Run its exact consumer gate with:

```bash
cd tests/package-consumer
zig build test --summary all
```

The package is also verified through a fresh `zig fetch .` cache so the allowlisted copy—not only the full checkout—can satisfy a consumer. A remote URL/hash is intentionally not documented before an artifact is published.

## Cached CSS build helper

A dependency build script imports `const zigcss_build = @import("zigcss")`, obtains the executable with `b.dependency("zigcss", ...).artifact("zigcss")`, and calls `zigcss_build.helpers.addCssCompile`. The exact working form is the committed `tests/package-consumer/build.zig`; its test runs in CI rather than relying on an uncompiled documentation fragment.

Each call declares one CSS input as `std.Build.LazyPath` and one generated output through a portable `.css` basename of at most 128 bytes. The returned `getOutput()` path can feed `b.addCheckFile`, `b.addInstallFile`, or another step. Optional `optimize` and `minify` fields map only to the accepted CLI features. Source maps, browser targeting, prefixing, arbitrary extra arguments, batch output directories, and alternate syntaxes are absent while their CLI contracts remain unavailable.

The executable passed to the helper must run on the build host. A cross-target project must obtain a separate host-target ZigCSS artifact for this run step instead of attempting to execute its application-target binary. The helper's file/output arguments make unchanged builds cacheable; the package fixture proves a second run is cached and a source-byte change reruns compilation while preserving exact output.

## Complete build integration example

`examples/build-integration` is a self-contained path-dependency project. Its build script creates separate application-target and host-tool ZigCSS dependencies, imports the library module, compiles and exact-checks a generated stylesheet through `helpers.addCssCompile`, installs that stylesheet, builds an executable, and runs the embedded API test.

```bash
cd examples/build-integration
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build
```

CI runs both test modes. A static enumeration gate requires every `.zig` file under `examples` to appear in either this project or the root compiled public-API example, preventing unbuilt snippets from accumulating.

The independent parser gate additionally requires Node.js. After the Zig build has produced the executable, run:

```bash
npm ci --ignore-scripts
npm run test:prefix-data
npm run check:prefix-data
NVIM=/absolute/path/to/nvim npm run test:documentation
npm run check:documentation
npm run test:dependencies
npm run check:dependencies
npm run audit:production
npm run test:zig-package
npm run test:compat
npm run test:transforms
```

The documentation gate syntax-checks every tracked shell, JSON, Lua, and Vim fence, compiles every CSS fence, runs the canonical Zig examples through the build graph, and resolves every tracked internal Markdown/site link. Set `NVIM` to a Neovim 0.11.7-or-later executable so the checked Lua and Ex-command examples use the real editor parser without loading user configuration.

The dependency gate inventories the root, documentation, and VS Code npm manifests and version-3 lockfiles, requires exact direct dependency versions, and audits each production lock graph from the lockfile with high/critical findings as failures. The reviewed `.github/dependabot.yml` opens only bounded weekly version-update pull requests for those npm directories, GitHub Actions, and the root Docker ecosystem; it grants no automerge, registry credentials, publishing, or deployment authority.

## Characterization example

Use a deliberately simple stylesheet while evaluating the prototype:

```css
.notice {
  color: red;
}
```

```bash
zig-out/bin/zigcss input.css -o output.css
```

The CLI writes an experimental-build warning to standard error. Treat successful output as prototype output, not as a compatibility guarantee.

- [Current status](/guide/status)
- [CSS compatibility](/guide/css-compatibility)
- [CSS Modules subset](/guide/css-modules)
- [Recovery CLI](/guide/recovery-cli)
