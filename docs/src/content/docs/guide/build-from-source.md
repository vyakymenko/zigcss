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
```

The executable is written to `zig-out/bin/zigcss`.

`test-public-api` compiles a separate Zig consumer against the module name `zigcss`. It verifies the owned high-level compile facade, result cleanup, and an explicitly experimental borrowed native-plugin callback without claiming a stable plugin ABI or CSS Modules.

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

## Local Zig package dependency

The root `build.zig.zon` declares package `zigcss` 0.3.0, fingerprint `0xae272a4871e93d07`, and minimum Zig 0.15.2. It exports only `build.zig`, `build.zig.zon`, `src`, `README.md`, and `LICENSE`. The unsupported legacy build helper, tests, docs, package-manager wrappers, and editor files are not part of the Zig package.

`tests/package-consumer` declares the repository as a path dependency, requests `zigcss.module("zigcss")`, and compiles the owned API from outside the package. Run its exact consumer gate with:

```bash
cd tests/package-consumer
zig build test --summary all
```

The package is also verified through a fresh `zig fetch .` cache so the allowlisted copy—not only the full checkout—can satisfy a consumer. A remote URL/hash is intentionally not documented before an artifact is published. `build_helpers.zig` will enter the allowlist only after `BUILD-002` replaces its unsupported build APIs.

The independent parser gate additionally requires Node.js. After the Zig build has produced the executable, run:

```bash
npm ci --ignore-scripts
npm run test:prefix-data
npm run check:prefix-data
npm run test:zig-package
npm run test:compat
npm run test:transforms
```

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
- [Recovery CLI](/guide/recovery-cli)
