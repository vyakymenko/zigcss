# Build tools and framework integrations

The current unpublished 0.7.0-rc.1 source checkout has executable integration evidence for the direct
JavaScript builders, selected framework hosts, four native build systems, and
six package-manager installation modes. These are `Unreleased` source
capabilities: the immutable published `zigcss@0.6.0` binary predates the
`zigcss-node-v1` protocol and must not be presented as adapter delivery.

## Prepare one verified checkout

Use Zig 0.15.2 and exact Node.js 22.22.0. Run every command on this page from
the repository root. Dependency lifecycle scripts stay disabled so preparing a
source checkout cannot download the older published binary into `bin/`.

```bash
set -euo pipefail
npm ci --ignore-scripts
zig build -Doptimize=ReleaseFast
```

On Windows PowerShell, use the same two tools and set each documented native
binary variable to `(Resolve-Path .\zig-out\bin\zigcss.exe)` before its matching
`npm run` command.

## Direct JavaScript builders

| Host | Current checkout entry point | Verified boundary |
|---|---|---|
| Vite 8.2.2 | `zigcss/vite` | Pre-plugin, generated sibling CSS identity, assets, maps, diagnostics, modules, and native dependencies |
| Rollup 4.63.1 | `zigcss/rollup` | Plugin before the project's ordinary CSS consumer |
| esbuild 0.28.1 | `zigcss/esbuild` | CSS/local-CSS loaders, emitted assets, maps, warnings, failures, and watch files |
| Bun 1.4.0 | `zigcss/bun` | Pinned real build; no native-import watch claim because Bun's current result has no watch-file channel |
| Webpack 5.110.2 | `zigcss/webpack` | Async raw loader in the rightmost source-transform position |
| Rspack 2.2.2 | `zigcss/rspack` | The same bounded loader contract and native dependency registration |

Run the complete contract and real-host suite, then compile the strict
TypeScript 7.0.2 consumer of every public subpath:

```bash
ZIGCSS_ADAPTER_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:bundler-adapters
npm run test:types
```

The verifier uses disposable workspaces. It checks CJS and ESM resolution,
closed option validation, bounded concurrency, asset identity, independent
host-facing maps, diagnostics, failures, and current-native SCSS builds. A local
run reports Bun as an explicit skip if Bun is unavailable; CI requires the
pinned Bun host.

## Framework host proofs

Each framework example owns an exact version-3 lockfile with development-only
host packages and an empty production dependency graph. The verifier stages the
current package and compiler into a disposable project; it does not rewrite the
published stable package.

```bash
ZIGCSS_TURBOPACK_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:turbopack-example
ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:next-webpack-example
ZIGCSS_SVELTEKIT_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:sveltekit-example
ZIGCSS_ASTRO_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:astro-example
ZIGCSS_NUXT_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:nuxt-example
```

- [Next.js 16.3.4 Turbopack and Webpack](https://github.com/vyakymenko/zigcss/tree/main/examples/next-turbopack) prove one confined global SCSS entry, native diagnostics, and dependency-only persistent-cache invalidation. The Webpack route additionally proves an unchanged zero-invocation cache hit.
- [SvelteKit 2.70.3](https://github.com/vyakymenko/zigcss/tree/main/examples/sveltekit) reuses `zigcss/vite` for one external SCSS CSS Module through client, SSR, and static prerender output.
- [Astro 7.2.10](https://github.com/vyakymenko/zigcss/tree/main/examples/astro) reuses `zigcss/vite` for one external module through a cached-offline static build, with a native partial, rebased asset, and composed map.
- [Nuxt 4.5.2](https://github.com/vyakymenko/zigcss/tree/main/examples/nuxt) proves one external module in client, Nitro, and prerender output plus a native partial and rebased asset. The native CSS map chain is claimed only in `.nuxt` intermediate output.

These are narrow host proofs, not dedicated Next.js, SvelteKit, Astro, or Nuxt
adapters. Their JavaScript deny-network/process preloads are evidence boundaries,
not operating-system sandboxes.

## Parcel local transformer

Parcel requires a separately published transformer package to follow its own
naming convention, so ZigCSS deliberately exposes no `zigcss/parcel` subpath.
The dependency-free, script-free local example uses the root-pinned Parcel
2.16.4 toolchain:

```bash
ZIGCSS_PARCEL_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:parcel-example
```

That gate proves a real native transformation, diagnostics, Source Maps,
imported-file invalidation, and cache behavior without claiming a published
Parcel package.

## Make, Ninja, CMake, and Meson

The native CLI's single-file `--depfile` output drives the checked-in Make,
Ninja, CMake, and Meson examples. Install the relevant host tools and run:

```bash
ZIGCSS_REAL_BINARY="$PWD/zig-out/bin/zigcss" npm run test:build-systems
```

Every available local tool must pass clean, no-op, and native-dependency-change
rebuilds with both the contract fixture and, when `ZIGCSS_REAL_BINARY` is set,
the exact current-checkout compiler. CI requires all four toolchains and runs
the real compiler through Make, Ninja, CMake, and Meson; an unavailable local
tool is reported as an explicit skip. This build-system primitive is implemented
only in the current `Unreleased` checkout—no Bazel rule, Nx executor, Angular
integration, or stable 0.6.0 delivery is claimed.

## Package-manager installation matrix

The package gate packs the source package once and exercises npm, pnpm 11.25.0,
Yarn Classic 1.22.22, Yarn Modern 4.9.4 in both node-modules and Plug'n'Play
modes, and Bun 1.4.0 with lifecycle scripts and registry access disabled during
installation:

```bash
npm run test:package-managers
```

CI requires all six execution modes. Local absence of a non-npm manager is
visible as a skip, never a fabricated pass. The matrix checks both command
shims, missing-binary recovery, native integrity inventory, CJS, ESM,
declarations, adapter exports, and the strict TypeScript consumer.

## Deliberate limits

There is no general PostCSS preprocessor adapter: a regular PostCSS plugin sees
input only after its CSS parser. There is also no stable-release claim for the
current Node API or builder adapters, no persistent compiler service, and no
general framework compatibility inferred from a framework's internal builder.
Those surfaces need matching native release artifacts and their own real-host
evidence before they can graduate.

- [Build from source](/guide/build-from-source)
- [Format compatibility](/guide/format-compatibility)
- [Current capability status](/guide/status)
- [Recovery CLI](/guide/recovery-cli)
