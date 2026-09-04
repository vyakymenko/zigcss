# Build from source

Source builds are the verified alternative to the published five-language native-graduated package. Local Zig package dependencies and the thin npm delivery wrapper are consumer-tested below.

## Requirements

- Zig 0.15.2
- Node.js 20.19 or newer for the published package wrapper; hosted CI, release, documentation, container, benchmark, and pinned framework execution use exact Node.js 24.20.0 LTS; stylesheet compilation itself does not require Node.js
- Nix 2.35.2 only for the optional repository-local flake route
- Git

## Build and test

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
npm ci --ignore-scripts
zig build
zig build test --summary all
zig build test-public-api --summary all
zig build test-native-zig-api --summary all
zig build test-documentation-examples --summary all
```

The self-contained executable is written to `zig-out/bin/zigcss` and compiles CSS, SCSS, indented Sass, Less, and Stylus through native Zig paths. In a direct checkout, the root `index.js` launcher selects that executable only when `build.zig` and `src/node_protocol.zig` are regular non-symlink markers and the executable is itself regular, non-symlink, executable, and confined to the checkout. Exact Dart Sass 1.101.0, Less 4.9.0, and Stylus 0.64.0 providers remain development-only reference oracles and do not run during compilation. Less 4.9.0 is a forward oracle over the frozen 4.6.7 native conformance baseline, not a new native graduation.

## Compiler-aware development container

With Docker Compose available, the complete local compiler-and-site loop has one
host command and no host Node or Zig prerequisite:

```bash
npm run dev:docker
```

Open `http://127.0.0.1:5173/zigcss/`. The image pins its Node base, Dockerfile
frontend, and architecture-specific Zig archive by digest. It mounts the source
checkout read-only and keeps documentation dependencies, compiler caches, and
outputs in project-scoped named volumes. Vite starts only after a successful
initial Zig build; health requires both the current compiler readiness marker and
the loopback site response. A later failed rebuild makes the service unhealthy
instead of accepting a stale binary.

Stop the service while retaining those caches:

```bash
docker compose -f docker-compose.dev.yml down
```

To deliberately discard only this Compose project's development volumes and
force a clean dependency install and compiler build next time:

```bash
docker compose -f docker-compose.dev.yml down --volumes
```

This is a development surface, not the production static-site image, and it
does not expose the compiler over HTTP.

`test-public-api` compiles a separate Zig consumer against the module name `zigcss`. It verifies the owned high-level compile facade, result cleanup, the explicit native CSS Modules subset, and an experimental borrowed native-plugin callback without claiming a stable plugin ABI or full ecosystem compatibility.

## Nix flake source build

The current checkout has one repository-local flake with default `packages`, `apps`, and `checks` for `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, and `aarch64-darwin`. Its only input is one commit- and `narHash`-pinned nixpkgs revision, its Zig package must report exactly 0.15.2, and its source is reduced to an explicit build/source/license allowlist.

Run the static policy first, then use Nix 2.35.2 without registry lookup or lock regeneration:

```bash
npm run test:nix-flake
npm run check:nix-flake
nix flake check --all-systems --no-build \
  --no-update-lock-file --no-write-lock-file --no-use-registries .
nix flake check \
  --no-update-lock-file --no-write-lock-file --no-use-registries .
nix build --no-link \
  --no-update-lock-file --no-write-lock-file --no-use-registries .#default
nix run \
  --no-update-lock-file --no-write-lock-file --no-use-registries \
  .#default -- --version
git diff --exit-code -- flake.nix flake.lock
```

The `--all-systems --no-build` command evaluates the four declared output sets; it does not cross-compile them. The ordinary check, build, and run commands select the current native system. The package check includes bounded version, CSS, and SCSS compilation smokes, not the complete Zig test suite. The GitHub Actions workflow is configured to run the static check before the full-SHA installer action and to execute the native route on four matching Unix runners.

This is not an offline or published distribution path. Bootstrap, the pinned nixpkgs input, and substitute acquisition require network access. CI uses the exact Nix 2.35.2 release URL, but the versioned installer script is not content-addressed even though that official script verifies its selected binary tarball. Hosted runner images remain mutable, and flakes are an experimental Nix interface. The flake declares no Windows output, development shell, NixOS module, or Home Manager module; it does not publish ZigCSS to nixpkgs or a registry, provide a binary cache, alter stable 0.6.0, or promise offline installation.

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

Set `.syntax = .css_modules` only for the [experimental native CSS Modules subset](/guide/css-modules). A successful result owns class/local-value exports, nested composition references, and bounded module dependency facts; it never loads dependencies. The stable compile facade and build helper remain CSS-oriented.

## Native stylesheet Zig API example

The finite native Zig API remains explicitly namespaced as `zigcss.experimental_native` even after machine graduation; the namespace does not grant executable plugin parity. This exact example parses one modern canonical target query, proves that the verified rewrite is an exact no-op for these inputs across all four frontends, and is compiled and executed by `test-documentation-examples`:

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
    .{ .syntax = .stylus, .filename = "example.styl", .source = "color = red\n.card\n  color color\n", .expected = ".card{color:red}" },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var targets = switch (try zigcss.prefixing.target_query.parse(
        allocator,
        "chrome >= 120, edge >= 120, firefox >= 120",
        .{},
    )) {
        .query => |query| query,
        .invalid => return error.InvalidTargetQuery,
    };
    defer targets.deinit();

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    inline for (examples) |example| {
        const entry = try std.fs.path.join(allocator, &.{ root, example.filename });
        defer allocator.free(entry);
        var result = try native.compile(allocator, entry, example.source, .{
            .syntax = example.syntax,
            .root_paths = &.{root},
            .format = .minified,
            .optimize = true,
            .prefix = true,
            .targets = &targets,
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

Arbitrary Sass plugins, custom functions/importers, Less JavaScript/plugins, Stylus plugins/evaluator hooks, and executable project code remain outside this API. The namespace starts no provider child process and exposes owned CSS, diagnostics, dependencies, and optional composed source maps.

## Local Zig package dependency

The root `build.zig.zon` declares the active source package `zigcss` 0.7.0-rc.1, fingerprint `0xae272a4871e93d07`, and minimum Zig 0.15.2. It exports only `build.zig`, `build.zig.zon`, supported `build_helpers.zig`, `src`, `README.md`, and `LICENSE`. Tests, docs, package-manager wrappers, and editor files are not part of the Zig package. This candidate is not the published stable 0.6.0 release.

`tests/package-consumer` declares the repository as a path dependency, requests `zigcss.module("zigcss")`, and compiles the owned API from outside the package. Run its exact consumer gate with:

```bash
cd tests/package-consumer
zig build test --summary all
```

CI also runs `zig fetch` with a fresh isolated global cache, checks that the resulting package contains exactly the declared top-level allowlist with no symlinks or oversized tree, and rewires the external consumer to that fetched cache copy. The consumer then compiles the public module and build helper without reading the full checkout. The published GitHub release provides architecture-matched binary archives; this source dependency remains intentionally documented through the repository rather than a hand-maintained remote URL/hash.

## Cached CSS build helper

A dependency build script imports `const zigcss_build = @import("zigcss")`, obtains the executable with `b.dependency("zigcss", ...).artifact("zigcss")`, and calls `zigcss_build.helpers.addCssCompile`. The exact working form is the committed `tests/package-consumer/build.zig`; its test runs in CI rather than relying on an uncompiled documentation fragment.

Each call declares one CSS input as `std.Build.LazyPath` and one generated output through a portable `.css` basename of at most 128 bytes. The returned `getOutput()` path can feed `b.addCheckFile`, `b.addInstallFile`, or another step. Optional `optimize` and `minify` fields map only to the native compiler features. Source maps, browser targeting, prefixing, arbitrary extra arguments, batch output directories, and preprocessor syntaxes are deliberately absent from this CSS build-helper contract; native preprocessors use the direct CLI or the explicit Zig namespace.

The executable passed to the helper must run on the build host. A cross-target project must obtain a separate host-target ZigCSS artifact for this run step instead of attempting to execute its application-target binary. The helper's file/output arguments make unchanged builds cacheable; the package fixture proves a second run is cached and a source-byte change reruns compilation while preserving exact output.

## Complete build integration example

`examples/build-integration` is a self-contained path-dependency project. Its build script creates separate application-target and host-tool ZigCSS dependencies, imports the library module, compiles and exact-checks a generated stylesheet through `helpers.addCssCompile`, installs that stylesheet, builds an executable, and runs the embedded API test.

```bash
cd examples/build-integration
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build
```

CI runs both test modes. A static enumeration gate requires every `.zig` file under `examples` to appear in the root build graph or the committed integration project, preventing unbuilt snippets from accumulating.

The same gate parameterizes the exact finite binary example set instead of cloning one test per syntax:

```bash
zig-out/bin/zigcss examples/native/styles.css --syntax css --minify
zig-out/bin/zigcss examples/native/styles.scss --syntax scss --minify
zig-out/bin/zigcss examples/native/styles.sass --syntax sass --minify
zig-out/bin/zigcss examples/native/styles.less --syntax less --minify
zig-out/bin/zigcss examples/native/styles.styl --syntax stylus --minify
```

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
npm run audit:development
npm run test:zig-package
npm run test:compat
npm run test:transforms
```

The documentation gate syntax-checks every tracked shell, JSON, Lua, and Vim fence, compiles every CSS fence, runs the compiled Zig examples through the build graph, and resolves every tracked internal Markdown/site link. Set `NVIM` to a Neovim 0.11.7-or-later executable so the checked Lua and Ex-command examples use the real editor parser without loading user configuration.

The dependency gate inventories the root package, documentation site, Next.js Turbopack example, SvelteKit example, Astro example, Nuxt example, and VS Code extension as seven exact npm manifest/version-3-lockfile pairs. It separately binds the local Parcel example as one exact dependency-free and script-free manifest whose Parcel toolchain is owned by the root lockfile; any additional package manifest or lockfile fails the inventory. The gate requires exact direct dependency versions; all four framework-host examples keep their host packages development-only and have empty production graphs. CI first audits all seven production lock graphs, then the complete root development graph—including Parcel 2.16.4—with `npm run audit:development`, then the complete documentation and VS Code build graphs, and finally the four full pinned Next.js, SvelteKit, Astro, and Nuxt host-lock audits. Any high or critical finding fails. The Pages workflow repeats the complete documentation build-graph audit before testing and building, and deploys only the exact commit from a successful same-repository `Build` push on `main`. The root audit covers the exact development-only Less 4.9.0 forward oracle and confirms that the former direct `image-size` 0.5.5 pin is absent; Less and Stylus image metadata instead share the bounded PNG/GIF/JPEG/SVG parser over resolver-owned bytes. The reviewed `.github/dependabot.yml` opens only bounded weekly version-update pull requests for the seven independently locked npm directories, GitHub Actions, and the root Docker ecosystem; the root-bound Parcel manifest receives dependency updates through the root directory and cannot declare its own dependency graph. The policy grants no automerge, registry credentials, publishing, or deployment authority. The build workflow's Test job uses exact Node 24.20.0 LTS for one maintained hosted runtime across the pinned Astro, Nuxt, and remaining JavaScript host gates; package engine ranges continue to define the broader supported consumer floor.

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
- [Builder integrations](/guide/builder-integrations)
- [Recovery CLI](/guide/recovery-cli)
