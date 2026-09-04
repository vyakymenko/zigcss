[![ZigCSS — Native by design. Correct by contract.](https://vyakymenko.github.io/zigcss/og.png)](https://vyakymenko.github.io/zigcss/)

# ZigCSS

[![Build](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml/badge.svg)](https://github.com/vyakymenko/zigcss/actions/workflows/build.yml)
[![npm](https://img.shields.io/npm/v/zigcss?color=c8ff55&label=npm&labelColor=101914)](https://www.npmjs.com/package/zigcss)
[![License: MIT](https://img.shields.io/badge/license-MIT-c8ff55.svg?labelColor=101914)](LICENSE)

**Native by design. Fast on purpose. Correct by contract.**

**Compile CSS. Keep the meaning.**

**Five languages in. One deterministic compiler out.**

ZigCSS is a self-contained native Zig compiler for CSS, SCSS, indented Sass, Less, and Stylus. It is built for a low-overhead execution path, deterministic output, and semantics-preserving transforms. It treats CSS like a language—not a string to rewrite until it looks smaller.

Active source candidate `0.7.0-rc.1` is unpublished. The current source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths. All five machine rows are `native-graduated`; executable preprocessor extension and provider-plugin parity remains outside the contract. The experimental build-tool adapters documented below do not expand that language boundary.

[Website](https://vyakymenko.github.io/zigcss/) · [Input/output lab](https://vyakymenko.github.io/zigcss/#formats) · [Get started](https://vyakymenko.github.io/zigcss/getting-started/) · [Documentation](https://vyakymenko.github.io/zigcss/docs/guide/status/) · [npm](https://www.npmjs.com/package/zigcss) · [Releases](https://github.com/vyakymenko/zigcss/releases)

> **Stable package identity: 0.6.0 — published.** npm `latest` serves `zigcss@0.6.0` as an immutable version, and the matching non-prerelease [GitHub Release](https://github.com/vyakymenko/zigcss/releases/tag/v0.6.0) carries 25 verified release files: 15 attested archive/checksum/SBOM subjects and 10 Sigstore bundle files. Historical npm version `0.6.0-rc.2` remains on `next`. Both historical GitHub releases predate Immutable Releases and read back `immutable: false`; `0.7.0-rc.1` must be the first true immutable GitHub Release.

> **Active source candidate: 0.7.0-rc.1 — unpublished.** The current tree extends the native CLI with dependency files, target prefixing, all-syntax optimizer and Source Map guarantees, hardened output commits, and deterministic cross-platform batch naming. It also adds a typed programmatic Node.js API and `zigcss-install` recovery entry point at the package root; experimental adapters for Vite, Rollup, esbuild, Bun, Webpack, and Rspack; bounded Next.js 16.3.4 Turbopack and Webpack host proofs that reuse `zigcss/webpack`; pinned SvelteKit 2.70.3, Astro 7.2.10, and Nuxt 4.5.2 external CSS Module examples that reuse `zigcss/vite`; and a real local-transformer Parcel example. None of these additions rewrites the published 0.6.0 artifact. Use them directly from a checkout after building its current native binary. The distinct prerelease identity prevents a source package from masquerading as stable `zigcss@0.6.0`; it still is not registry delivery until matching native archives pass the release gates.

`release/next-release.json` selects `0.7.0-rc.1` as the planned candidate with `candidateReady: false`. It remains blocked from tagging and publication until all seven pre-tag gates pass; stable `0.6.0` remains the only `latest` identity while that work is open.

Active source versioning is independent of closed published-stable evidence: `VERSION`, package metadata, the CLI, and source-only surfaces advance together, while `release/stable-promotion.json` and `Formula/zigcss.rb` continue to describe the latest independently verified stable publication until a later release completes its own gates.

## Native dependency-free migration

Publication of the provider-backed 0.5 candidate was cancelled before tagging. Dart Sass 1.101.0 and Stylus 0.64.0 remain exact development-only reference oracles. Less 4.9.0 is the current development oracle over the frozen 4.6.7 native conformance baseline; advancing that forward oracle does not regraduate or rewrite the published native behavior. These providers judge tests but do not enter the compiler, release archives, installed production graph, or compilation runtime. The root development graph receives a separate complete high/critical audit through `npm run audit:development`. Its former direct `image-size` 0.5.5 pin is gone: the development host now gives Less and Stylus one shared bounded PNG, GIF, JPEG, and SVG dimension parser over resolver-owned bytes.

The current native package contract has zero `dependencies` and zero `optionalDependencies`. The compiler itself starts no child process, performs no network access, and requires no runtime download. Five archive and offline-package jobs cover Linux x64/arm64, macOS x64/arm64, and Windows x64.

The native implementation was first proven on protected historical tag `v0.6.0-rc.2`: its machine contract records `nativeReleaseReady: true`, and all nine pre-tag evidence surfaces, five attested target archives, offline consumers, and provenance passed. GitHub prerelease and npm `next` publication are verified; GitHub prerelease 369856953 reads back `immutable: false`, while npm version `0.6.0-rc.2` is immutable. Stable `0.6.0` then passed its separate ten-gate terminal and was published from protected tag `v0.6.0`; GitHub Release 372291445 also reads back `immutable: false`, while npm version `0.6.0` is immutable.

`NATIVE-008` closed the finite source-capability inventory. `NATIVE-009` graduated the four preprocessor machine rows together and closed the exact prerelease terminal with five native archives, 25 release assets, one GitHub prerelease, and npm `next`; executable preprocessor extension parity remains outside the contract. `REL-010` owns the separate stable tag, npm `latest`, Pages, and public readback.

## Why ZigCSS

| What matters | ZigCSS contract |
|---|---|
| Native execution | All five source inputs share native Zig compilation paths; the JavaScript launcher and programmatic API invoke only the selected confined native executable and host no language semantics. |
| Semantic safety | Transform classes stay unavailable until equivalence, idempotence, and independent-parser gates pass. |
| Failure behavior | Compilation is atomic. An error, cancellation, limit, or allocation failure returns no partial CSS. |
| Determinism | Replay, batch order, parallel workers, source maps, diagnostics, and packaging have executable checks. |
| Ownership | CSS, diagnostics, dependencies, source maps, module exports, and profile data share one explicit result lifetime. |
| Delivery | Linux x64/arm64, macOS x64/arm64, and Windows x64 archive paths are tested. |

Your CSS deserves a real compiler: bounded input, a recovery-disabled parser, explicit transforms, strict output validation, and an atomic write at the end.

## Install

Install the published stable five-language release:

```bash
npm install --save-dev zigcss
```

The published stable 0.6.0 package installs its matching native release binary during the dependency lifecycle. npm, pnpm, Yarn, and Bun can disable or require approval for those scripts; stable users in that state must allow ZigCSS's install script and reinstall. Stable 0.6.0 does not expose a `zigcss-install` command and does not carry the current source package's independent `native-integrity.json` inventory.

The unpublished `0.7.0-rc.1` package contract adds both of those surfaces. Its `native-integrity.json` is an exact versioned SHA-256 inventory for all five native archives. The normal installer and `zigcss-install` first download the target's GitHub checksum manifest and require that digest to match the independent digest carried through npm; only then do they download the archive, verify the same digest, require one exact archive entry, inspect the ELF/Mach-O/PE target header, and atomically install the executable. Every download is byte-bounded, redirect-bounded, limited to a two-minute total deadline across redirects, and has a 30-second inactivity timeout. Signed GitHub attestations remain separately verifiable release evidence through GitHub's [`gh attestation verify` offline workflow](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline); the npm installer does not claim to perform Sigstore verification itself. No published npm version currently exposes this new recovery command or integrity inventory.

`zigcss-install` is a future-package recovery entry point, not an offline installer: unless release assets are explicitly supplied by a controlled test harness, it requires HTTPS access to the matching GitHub Release. A network-free deployment must carry an already verified binary in the package's expected `bin` location or build from source; the package does not silently fall back to a JavaScript compiler.

The current repository's lifecycle-disabled install matrix packs its source package once, blocks registry access, and installs those exact bytes with npm, pnpm 11.25.0, Yarn Classic 1.22.22, Yarn Modern 4.9.4 in both `node-modules` and default Plug'n'Play modes, and Bun 1.4.0. All six execution variants across those five manager families are mandatory in GitHub Actions; local runs may report an unavailable non-npm CLI as an explicit skip. Every executed installation verifies both command shims, the neutral missing-binary recovery message, the installed integrity inventory, zero runtime dependencies, and every public adapter export. The five `node_modules` variants resolve CommonJS, ESM, and declarations through ordinary package resolution and compile the strict TypeScript consumer. The default-PnP branch instead uses Yarn's loader to resolve every CommonJS and ESM export, verifies the exact import/require declaration bytes, and path-maps only those verified files for a condition-specific strict compile. Exact unpatched TypeScript 7.0.2 without a Yarn SDK or patch is expected to report `TS2307` for no-paths PnP package resolution, so native TypeScript PnP resolution is not claimed; projects that require it should follow [Yarn's official SDK guidance](https://yarnpkg.com/getting-started/editor-sdks), whose integration remains outside this gate. That branch also proves that Yarn's [`preferUnplugged`](https://yarnpkg.com/configuration/manifest#preferUnplugged) contract places ZigCSS in a writable project-local `.yarn/unplugged` area with no `node_modules`, confines both Yarn and Corepack state to disposable test roots, and completes controlled offline recovery from a locally generated fixture without depending on an already published release or mutating the packed artifact's trust data.

The repository also contains a stable, immutable-source Homebrew formula. No tap is published, so a checked-out source tree can install it explicitly:

```bash
brew install --formula ./Formula/zigcss.rb
```

The current checkout also contains a repository-local Nix flake with default package, app, and check outputs for `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, and `aarch64-darwin`. It pins one nixpkgs commit and `narHash`, asserts Zig 0.15.2, admits an explicit source allowlist, and runs bounded version, CSS, and SCSS install checks. The GitHub Actions matrix is configured to validate this contract before an immutable `cachix/install-nix-action` commit and then check, build, and run each native Unix output with Nix 2.35.2.

This Nix route remains a source-checkout facility. Fresh bootstrap, nixpkgs input fetches, and substitutes require network access; the exact-version Nix installer script is not itself content-addressed; hosted runner images can change; and the Nix flake CLI remains experimental. No nixpkgs or registry publication, binary cache, offline installation, Windows output, NixOS or Home Manager module, or stable-release delivery is claimed. See [Build from source](https://vyakymenko.github.io/zigcss/docs/guide/build-from-source/#nix-flake-source-build) for the fail-closed commands.

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

The published stable package exposes the five explicit native language selections below while keeping executable plugin boundaries separate from language graduation. Later subsections explicitly identify current-source CLI additions that are not part of stable 0.6.0.

| Input | Source snapshot execution path | Machine migration state |
|---|---|---|
| CSS (`.css`) | Native ZigCSS tokenizer/parser | `native-graduated` |
| SCSS (`.scss`) | Native Sass-family parser/evaluator | `native-graduated` |
| Sass (`.sass`) | Native Sass-family parser/evaluator | `native-graduated` |
| Less (`.less`) | Native Less parser/evaluator | `native-graduated` |
| Stylus (`.styl`) | Native Stylus parser/evaluator | `native-graduated` |

`native-graduated` means the pinned corpus, negative/resource, deterministic, generated-CSS, product-routing, package, five-target, documentation, release, and publication gates passed for the closed verified release line. It does not grant executable provider or plugin extension points.

To build the exact stable five-language source snapshot locally:

```bash
git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
git checkout v0.6.0
zig build

zig-out/bin/zigcss --syntax css styles.css -o dist/styles.css --minify
zig-out/bin/zigcss --syntax scss styles.scss -o dist/styles.css --minify
zig-out/bin/zigcss --syntax sass styles.sass -o dist/styles.css --minify
zig-out/bin/zigcss --syntax less styles.less -o dist/styles.css --minify
zig-out/bin/zigcss --syntax stylus styles.styl -o dist/styles.css --minify
```

`--syntax` is deliberate: the compiler does not infer a native preprocessor route from the filename alone. Preprocessor imports stay inside the entry directory; additional CLI load paths are not currently exposed.

Arbitrary Sass plugins, custom functions and importers, Less JavaScript and plugins, Stylus plugins and evaluator hooks, and executable project code remain outside the native product contract.

The remaining CLI examples describe the current unpublished `0.7.0-rc.1` source candidate, not the immutable stable 0.6.0 binary. Switch this checkout back to `main` and rebuild before running them:

```bash
git checkout main
zig build
```

```bash
zig-out/bin/zigcss --syntax scss src/app.scss \
  --source-map \
  --minify \
  -o dist/app.css
```

In the current source snapshot, `--source-map` embeds one deterministic inline Source Map for any of the five syntaxes. Its UTF-16 position lookup uses a sparse byte-stride index that stays bounded for newline-dense input. Source maps cannot be combined with the fixed-point `--optimize` path.

Current-source single-file build rules can also request one deterministic Make/Ninja dependency file:

```bash
zig-out/bin/zigcss --syntax scss src/app.scss \
  -o dist/app.css \
  --depfile dist/app.css.d
```

`--depfile` requires exactly one file input and an explicit file output. The authored output spelling is the target; the canonical entry and only native imports actually read are sorted and deduplicated prerequisites. Authored CSS `@import` remains owned by the downstream CSS layer. Before writing, the CLI rejects output/depfile aliases of the entry or any discovered native import, including symlink and hard-link identities. Staging failures preserve existing CSS and dependency files, and the CSS output is committed last as the success marker. Native batches validate the union of every task's entries and discovered dependencies before their first commit. This one primitive is suitable for Make and Ninja rules and for CMake or Meson custom commands that consume depfiles.

The current source extends the same closed seven-pass optimizer across every native frontend:

```bash
zig-out/bin/zigcss --syntax scss src/app.scss \
  --optimize \
  --minify \
  -o dist/app.css
```

For SCSS, indented Sass, Less, and Stylus, the frontend first produces complete CSS and the recovery-disabled core then runs the same bounded byte-stable optimizer used for CSS. `--profile` remains CSS-only.

Current-source verified target prefixing is available for all five syntaxes with one explicit pinned query:

```bash
zig-out/bin/zigcss --syntax scss src/app.scss \
  --autoprefix \
  --browsers "safari >= 7, ie >= 11" \
  --minify \
  -o dist/app.css
```

`--autoprefix` and `--browsers` require each other. The grammar accepts only explicit minimums for `chrome`, `edge`, `firefox`, `safari`, `ios_safari`, and `ie`; there are no defaults, market-share queries, network lookups, or project configuration discovery. The pass covers a reviewed eight-feature subset rather than general autoprefixing. It composes with `--optimize` and, when optimization is not requested, deterministic inline source maps.

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
| Hardware | The publishable archive must come from dedicated Linux x64 bare metal. The runner records `systemd-detect-virt`, CPU-flag, sysfs, container-marker, cgroup, and bounded DMI evidence; any ambiguous or virtualized result fails closed. |
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

## JavaScript delivery surfaces

The `zigcss` command remains a thin launcher. In a direct checkout with regular `build.zig` and `src/node_protocol.zig` markers, it accepts only a regular, non-symlink `zig-out/bin/zigcss` whose real path stays inside that checkout; otherwise it requires the regular confined packaged executable. It forwards the closed CLI arguments, preserves exit and signal behavior, and implements no parser, evaluator, provider host, or fallback.

The current `Unreleased` source package also exports a typed programmatic Node.js API from its package root for both CommonJS and real ESM consumers. Its active identity is unpublished candidate `0.7.0-rc.1`. It provides `compile`, `compileSync`, `compileFile`, `compileFileSync`, `detectSyntax`, and `ZigCssCompileError`, with declarations from `api.d.ts`. In a direct source checkout, first run `zig build -Doptimize=ReleaseFast`; the API selects only the regular, non-symlink `zig-out/bin/zigcss` when the exact source markers are present. Otherwise it requires the installed package's regular executable. Every compile call starts one private native process without a shell or temporary source file; the package retains zero production and optional dependencies.

The published stable 0.6.0 npm package is not compatible with this API because its immutable binary has no `--internal-node-v1` protocol. The current source now carries the distinct `0.7.0-rc.1` prerelease identity, so it cannot masquerade as that stable package. A future publication must still bind these JavaScript surfaces to matching newly built native archives before they become a registry installation claim.

```text
import { compile, compileFileSync, ZigCssCompileError } from 'zigcss'
import { resolve } from 'node:path'

const controller = new AbortController()

try {
  const result = await compile('$accent: #7c3aed; .card { color: $accent; }', {
    syntax: 'scss',
    sourcePath: resolve('src/card.scss'),
    format: 'minified',
    sourceMap: true,
    browsers: 'safari >= 7, ie >= 11',
    timeoutMs: 5_000,
    signal: controller.signal,
  })

  console.log(result.css)
  console.log(result.sourceMap)   // parsed, deeply immutable object or null
  console.log(result.diagnostics)
  console.log(result.dependencies)

  const optimized = compileFileSync('src/theme.less', {
    optimize: true,
    browsers: 'safari >= 7, ie >= 11',
  })
  console.log(optimized.css)
} catch (error) {
  if (error instanceof ZigCssCompileError) {
    console.error(error.code, error.diagnostics)
  } else {
    throw error
  }
}
```

`compile` defaults to CSS when no syntax or recognizable source path is provided; file APIs infer the closed `.css`, `.scss`, `.sass`, `.less`, `.styl`, and `.stylus` set. A string compile may use a virtual `sourcePath`, but its parent directory must exist and is realpath-canonicalized before the request crosses the native boundary. `rootPaths` admits one to sixteen existing directories, canonicalizes each one, and requires at least one root to contain the entry path; file APIs resolve the actual input file and its default root to canonical paths. Source maps cannot be combined with fixed-point optimization. Results and nested facts are immutable snapshots, and failures never expose partial CSS. Async calls support a bounded timeout and `AbortSignal`; sync calls reject signals. The API deliberately provides no watch mode, incremental cache, plugin execution, provider fallback, or private transport access.

## Tooling integration

Published ZigCSS 0.6.0 still ships only the native CLI and thin npm launcher. The current `Unreleased` source package adds explicit, typed adapter subpaths on top of the programmatic compiler. Its active identity is unpublished candidate `0.7.0-rc.1`. They share bounded option validation and a process scheduler, preserve authored CSS imports for the downstream CSS layer, and return no partial CSS on failure. Deterministic protocol-fixture tests keep failure, map, diagnostic, identity, asset, dependency-registration, and concurrency behavior isolated. CI then passes the freshly built current-checkout binary through real Vite, Rollup, esbuild, Webpack, Rspack, pinned Bun 1.4.0, pinned Next.js 16.3.4 Turbopack and Webpack builds, a pinned SvelteKit 2.70.3/Vite 8.2.2 build, a pinned Astro 7.2.10 static build, a pinned Nuxt 4.5.2 client/Nitro/prerender build, and a local Parcel build. Vite, Rollup, esbuild, Webpack, Rspack, both Next.js modes through the reused Webpack loader, the bounded SvelteKit, Astro, and Nuxt examples through the reused Vite plugin, and the local Parcel example report confined native imports through their available dependency APIs. Bun's current `onLoad` result has no `watchFiles` field, so the Bun adapter deliberately makes no native-import watch-invalidation claim.

| Surface | What is actually verified |
|---|---|
| npm scripts, CI, and shell build steps | The installed launcher invokes the checksum-verified native binary and preserves its exit or signal result. |
| Node.js | The current source package exposes typed CommonJS and ESM compile APIs for all five syntaxes, maps, optimizer, explicit target prefixing, diagnostics, dependencies, timeout, and cancellation; a strict TypeScript 7.0.2 consumer compiles the full root and adapter surface. |
| Zig Build | `helpers.addCssCompile` passes fresh consumer builds in Debug and ReleaseSafe. |
| Nix | The repository-local flake exposes pinned default package, app, and check outputs for four native Unix systems; its workflow is configured for exact Nix 2.35.2, without claiming nixpkgs publication, a binary cache, or offline bootstrap. |
| Make, Ninja, CMake, and Meson | A single-file `--depfile` rule reports the canonical entry and only native imports actually read; [`examples/build-systems`](https://github.com/vyakymenko/zigcss/tree/main/examples/build-systems) contains minimal integrations and an incremental clean/no-op/dependency-change test for every installed host. CI runs this suite after the native Debug tests and passes the freshly built `zig-out/bin/zigcss` through `ZIGCSS_REAL_BINARY`, including mandatory real-ZigCSS incremental rebuilds for GNU Make, Ninja, CMake, and Meson. |
| Vite | `zigcss/vite` is an experimental pre-plugin with real Vite host-contract coverage for generated sibling CSS and asset rebasing, plus focused checks for queries, CSS Module identity, maps, diagnostics, and native dependency invalidation. A second CI smoke compiles native SCSS with the freshly built current-checkout binary. |
| Rollup | `zigcss/rollup` is an experimental plugin exercised by a real Rollup host build before a downstream CSS consumer and by a current-native SCSS build. The generated CSS module still requires the project's ordinary CSS plugin or output pipeline. |
| esbuild | `zigcss/esbuild` is an experimental plugin with real esbuild host coverage for emitted assets and CSS Modules, plus contract checks for inline maps, diagnostics, and watch files. A second CI smoke bundles current-native SCSS. |
| Bun | `zigcss/bun` is an experimental plugin with a strict contract test and a real current-native Bun 1.4.0 build on the pinned CI host. |
| Webpack and Rspack | `zigcss/webpack` and `zigcss/rspack` expose the same experimental async raw loader. Real builds with pinned Webpack 5.110.2 and Rspack 2.2.2 verify fixture diagnostics and registration, then separately compile current-native SCSS and register its native dependency. Loader-context, maps, failures, and metadata retain focused contract tests. A watch rebuild after dependency mutation is not yet claimed. |
| Next.js Turbopack and Webpack | [`examples/next-turbopack`](https://github.com/vyakymenko/zigcss/tree/main/examples/next-turbopack) reuses only `zigcss/webpack` for one global `app/styles.scss` entry. The offline current-native gate pins Next.js 16.3.4, React/ReactDOM 19.2.4, and downstream Sass 1.101.0. Turbopack proves exact entry/import `sourcesContent`, persistent-cache invalidation, native diagnostics, package resolution, and a fail-closed JavaScript host boundary that admits only exact pinned workers/children, the staged native protocol process, and reviewed local IPC while denying preload-free eval workers and alternate process/network paths. The separate `next build --webpack` proof uses one path-confined `enforce: 'pre'` rule, blocks public Node network entry points, records the staged native protocol process, proves an unchanged zero-invocation cache hit, then proves dependency-only invalidation invokes ZigCSS and changes emitted CSS; the final Webpack CSS does not retain the original ZigCSS source-map chain, so that delivery is not claimed. These are JavaScript host proofs rather than OS sandboxes, and both remain source-checkout proofs until a future release ships the current native protocol. |
| SvelteKit | [`examples/sveltekit`](https://github.com/vyakymenko/zigcss/tree/main/examples/sveltekit) reuses `zigcss/vite` before the official SvelteKit Vite plugin for one external `card.module.scss` entry. The current-source gate pins SvelteKit 2.70.3, Svelte 5.57.0, Vite 8.2.2, and adapter-static 3.0.10; under deny-network build conditions it proves client, SSR, and prerender CSS Module bindings plus exact entry/native-partial map content. Its JavaScript host boundary admits only the staged native process, three exact pinned SvelteKit workers, and confined local IPC while denying preload-free eval workers and alternate process/network paths; it is not an OS sandbox. Embedded styles, preprocessors, framework HMR/watch invalidation, arbitrary adapters/targets, and general compatibility are not claimed. |
| Astro | [`examples/astro`](https://github.com/vyakymenko/zigcss/tree/main/examples/astro) registers `zigcss/vite` through Astro's Vite configuration for one external `card.module.scss` import. The exact Astro 7.2.10 gate warms an isolated npm cache, repeats the lockfile install offline, and denies network access during the static production build. It proves the same scoped binding in rendered HTML and emitted client JavaScript, one native Sass partial, a rebased fingerprinted SVG asset, and exact composed map content. Embedded Astro styles, HMR/watch invalidation, SSR adapters, every renderer, framework aliases, `zigcss/astro`, and stable 0.6.0 delivery are not claimed. |
| Nuxt | [`examples/nuxt`](https://github.com/vyakymenko/zigcss/tree/main/examples/nuxt) registers `zigcss/vite` through Nuxt's Vite configuration for one external `card.module.scss` import. The exact Nuxt 4.5.2 deny-network production gate proves one scoped binding across the client, Nitro SSR bundle, and prerendered HTML, together with a native Sass partial and rebased SVG asset. Nuxt retains the exact native CSS map chain only in the `.nuxt` intermediate output; the public output retains client JavaScript maps, but no public production CSS map is claimed. Runtime SSR requests, embedded Nuxt styles, modules, HMR/watch invalidation, other builders or presets, `zigcss/nuxt`, and stable 0.6.0 delivery are not claimed. |
| Parcel | [`examples/parcel`](https://github.com/vyakymenko/zigcss/tree/main/examples/parcel) is a real Parcel 2.16.4 local transformer integration with maps, diagnostics, imported-file invalidation, cache behavior, and a native-binary CI smoke. [Parcel requires published transformer packages to use a `parcel-transformer-*` package name](https://parceljs.org/plugin-system/authoring-plugins/#naming), so `zigcss/parcel` is deliberately not exported and no separately published Parcel plugin is claimed. |
| Nx | No executor, generator, or workspace consumer is shipped or claimed. |

The adapters are part of the unpublished `0.7.0-rc.1` source candidate, not stable 0.6.0. Their shared options are `format`, `sourceMap`, `optimize`, `browsers`, `rootPaths`, `timeoutMs`, and `maxWorkers`. Source maps and fixed-point optimization remain mutually exclusive. Each stylesheet compilation is isolated in a native process; the scheduler bounds concurrency but does not claim an incremental compiler cache. A strict TypeScript 7.0.2 no-emit build imports every public subpath and proves immutable results plus rejected sync-signal, file-sourcePath, wrong-type, and unknown-option calls with `@ts-expect-error` assertions.

Vite and Rollup use plugin factories:

```text
// vite.config.js
import { defineConfig } from 'vite'
import zigcss from 'zigcss/vite'

export default defineConfig({ plugins: [zigcss()] })

// rollup.config.js
import zigcss from 'zigcss/rollup'

export default { plugins: [zigcss(), projectCssPlugin] }
```

For Rollup, register the ZigCSS plugin before the project's CSS consumer. esbuild uses its ordinary plugin list:

```text
import { build } from 'esbuild'
import zigcss from 'zigcss/esbuild'

await build({
  entryPoints: ['src/app.js'],
  outdir: 'dist',
  bundle: true,
  plugins: [zigcss({ sourceMap: true, maxWorkers: 4 })],
})
```

Bun accepts the corresponding factory through its own build API:

```text
import zigcss from 'zigcss/bun'

await Bun.build({
  entrypoints: ['src/app.js'],
  outdir: 'dist',
  plugins: [zigcss({ sourceMap: true, maxWorkers: 4 })],
})
```

Place the Webpack or Rspack loader at the rightmost source-loader position so it receives the authored stylesheet and hands CSS to the rest of the chain:

```text
module: {
  rules: [{
    test: /\.(?:css|scss|sass|less|styl|stylus)$/i,
    use: ['css-loader', { loader: 'zigcss/webpack', options: { sourceMap: true } }],
  }],
}
```

Use `zigcss/rspack` in the same rule for Rspack. Incoming source maps are rejected, which makes loader order explicit instead of silently composing an unverified upstream map.

Next.js 16.2+ can reuse that same loader because Turbopack can declare the loader output as CSS. The committed example deliberately narrows the top-level extension glob with a path condition:

```text
module.exports = {
  productionBrowserSourceMaps: true,
  experimental: {
    turbopackFileSystemCacheForBuild: true,
    turbopackUseBuiltinSass: false,
  },
  turbopack: {
    rules: {
      '*.scss': {
        condition: { path: /(?:^|[\\/])app[\\/]styles\.scss$/ },
        loaders: [{ loader: 'zigcss/webpack', options: { sourceMap: true, maxWorkers: 2 } }],
        type: 'css',
      },
    },
  },
}
```

The same pinned example also exercises Next.js's explicit Webpack mode through one pre-loader rule:

```text
const webpackEntry = path.join(__dirname, 'app', 'styles.scss')

webpack(config) {
  config.module.rules.push({
    test(resource) {
      return typeof resource === 'string' && path.resolve(resource) === webpackEntry
    },
    enforce: 'pre',
    use: [{ loader: 'zigcss/webpack', options: { sourceMap: true, maxWorkers: 2 } }],
  })
  return config
}
```

Run `npm run test:next-webpack-example` after building the current native binary. The gate warms a private npm cache, reinstalls the exact lock offline, blocks public Node network entry points (including loopback listeners and Unix sockets), direct unsafe bindings, Worker/cluster escapes, and unreviewed public child-process calls during `next build --webpack`. It binds the build PID to the exact staged `--internal-node-v1` process, requires an unchanged warm build to perform zero native invocations, then changes only `_tokens.scss` and requires changed CSS plus a new native invocation. This JavaScript preload is a host-proof boundary, not an OS sandbox; the exact lock-pinned host and native addons remain trusted. Next.js/Webpack does not preserve the original ZigCSS source-map chain in the final stylesheet, so no source-map delivery claim is made.

Both executable Next.js host gates are pinned to Next.js 16.3.4. They claim only global SCSS at that exact entry: no CSS Modules, indented Sass, Less, Stylus, arbitrary SCSS glob, development HMR or watch invalidation, `zigcss/turbopack` or `zigcss/next` export, dedicated framework adapter, other Next.js/Webpack versions, general Turbopack plugin, or wider Next.js compatibility. [Next.js documents loader output module types here](https://nextjs.org/docs/app/api-reference/config/next-config-js/turbopack#module-types), its [`--webpack` build mode here](https://nextjs.org/docs/app/api-reference/cli/next#next-build-options), and the [custom Webpack hook here](https://nextjs.org/docs/app/api-reference/config/next-config-js/webpack). No PostCSS adapter is shipped: a regular PostCSS plugin receives input only after the PostCSS CSS parser, so presenting it as a general SCSS/Sass/Less/Stylus preprocessor would be incorrect.

The committed SvelteKit example routes one external `.module.scss` file through `zigcss/vite` before the official SvelteKit plugin:

```text
export default defineConfig({
  plugins: [
    zigcss({ maxWorkers: 2, sourceMap: true }),
    sveltekit({ adapter: adapter() }),
  ],
  build: { sourcemap: true },
})
```

Run `npm run test:sveltekit-example` after building the current native binary. The isolated gate pins SvelteKit 2.70.3, Svelte 5.57.0, Vite 8.2.2, and adapter-static 3.0.10, installs and builds only in `os.tmpdir()`, denies network access during the host build, and proves client, SSR, prerender, CSS Module hashing, exact native entry/partial source-map content, exact admitted worker/native-process traces, and denial of preload-free workers plus alternate process/network paths. This JavaScript boundary is not an OS sandbox. It does not claim embedded `<style lang="scss">` blocks, Svelte preprocessors, framework HMR or watch invalidation, arbitrary adapters or deployment targets, or general SvelteKit compatibility. [SvelteKit documents its adapter surface here](https://svelte.dev/docs/kit/adapters).

The committed Astro example uses the same pre-plugin through Astro's documented `vite` field. Run `npm run test:astro-example` after building the current native binary. Its isolated Astro 7.2.10 gate warms a private package cache, repeats `npm ci` with registry access disabled, and then denies public and internal Node network entry points during `astro build`. Its fail-closed preload also blocks Worker/cluster escapes, unsafe process bindings, inspector activation, and every child-process shape except the exact staged ZigCSS and pinned esbuild invocations; it proves static HTML/client CSS Module identity, a native partial, a fingerprinted asset, and exact composed map content. This is a JavaScript host-proof boundary rather than an OS sandbox and continues to trust the exact pinned host and native addons. It deliberately says nothing about embedded `<style lang="scss">`, development HMR/watch invalidation, SSR adapters, every renderer, framework aliases, or a `zigcss/astro` export.

The committed Nuxt example registers `zigcss/vite` in `nuxt.config.ts`. Run `npm run test:nuxt-example` after building the current native binary. Its isolated Nuxt 4.5.2 gate denies public and internal Node socket, DNS, HTTP, WebSocket, TLS, and inspector entry points during `nuxt build`; it also blocks Worker/cluster escapes, unsafe process bindings, and every child-process shape except the exact staged ZigCSS and pinned esbuild invocations. The JavaScript boundary is not an OS sandbox and trusts the exact pinned host and native addons. The gate proves one external CSS Module in the client bundle, Nitro SSR bundle, and prerendered page, plus a native partial and rebased asset. The exact native CSS map chain exists only in `.nuxt` intermediate output; the public output proves client JavaScript maps but not a public production CSS map. The gate does not start or request the runtime SSR server and does not claim embedded styles, Nuxt modules, HMR/watch invalidation, other builders, deployment presets, or `zigcss/nuxt`.

No separately published Parcel transformer or Next.js, SvelteKit, Astro, or Nuxt adapter, Bazel rule, Nx executor, or Angular integration is claimed. A framework using one of the covered builders internally is not, by itself, evidence for framework compatibility beyond the exact pinned Next.js, SvelteKit, Astro, and Nuxt examples above.

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

The explicitly experimental `zigcss.experimental_native` namespace covers the finite SCSS, indented Sass, Less, and Stylus source set. This compiled example parameterizes all four rows, keeps resolver roots explicit, parses one modern canonical target query whose verified rewrite is an exact no-op for these inputs, checks deterministic CSS, and deinitializes every owned result:

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

The same documentation gate executes the five committed files under [examples/native](examples/native) through the source-built binary with explicit `--syntax`. Neither example invokes a provider, child language engine, plugin, network service, or runtime download.

`build.zig.zon` gives the source package stable identity `zigcss`. CI copies its exact allowlist through `zig fetch` into a fresh confined cache and compiles an external consumer against that fetched copy, so package evidence does not depend only on the full checkout. The build module exposes `helpers.addCssCompile` for declared CSS inputs and generated outputs. See [examples/build-integration](examples/build-integration).

## Build and verify

Use Zig 0.15.2:

```bash
npm ci --ignore-scripts
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

## Development container

The compiler-aware documentation environment is available from a checkout with
Docker Compose:

```bash
npm run dev:docker
```

Open `http://127.0.0.1:5173/zigcss/`. The pinned multi-architecture image mounts
source read-only, keeps lockfile-bound documentation dependencies and all build
outputs in project-scoped named volumes, completes the initial Zig build before
Vite starts, and requires both compiler readiness and the site response for
container health. Stop it with
`docker compose -f docker-compose.dev.yml down`; append `--volumes` only when
you intentionally want to discard this project's development caches. This is a
local development image, not a production server, and it has no compiler HTTP
endpoint.

## Editor integration

The experimental CSS LSP covers bounded JSON-RPC framing, full document sync, UTF-16 positions, pull diagnostics, and syntax-aware open-document features.

Its release checks pass large-document, Unicode, malformed-request, leak, and editor-integration gates.

- The closed historical VS Code proof remains a Marketplace-compatible package version 0.6.0 mapped to core 0.6.0-rc.2. The current source extension is version 0.7.0, aligned with core candidate 0.7.0-rc.1; publication remains unauthorized, so build and install the verified pre-release VSIX locally with a separately installed ZigCSS binary.
- The [Neovim configuration](neovim-config/README.md) uses the built-in LSP client and an explicit trusted executable path.

Neither integration bundles a compiler binary.

Editor integrations remain CSS-only today. They do not silently execute preprocessor plugins or project code.

## Project status

- Stable package identity: 0.6.0; the exact GitHub tag, attested release subjects and bundles, npm `latest` package, Pages deployment, and public readback share one fail-closed promotion terminal.
- CSS core: `native-graduated`.
- SCSS, indented Sass, Less, and Stylus: `native-graduated` after parser/evaluator, pinned conformance, native product-routing, package, five-target, and pre-tag release gates.
- Production package closure: verified with zero production dependencies and no provider or host bytes; the compiler itself starts no child process and performs no network access.
- Future-release integrity in the current source: deterministic single-entry archives use the committed `sourceDateEpoch`; a future tag workflow requires every fresh archive to match the exact digest committed in `native-integrity.json`, while its npm installer cross-checks that npm-carried digest against GitHub before downloading the archive. Published stable 0.6.0 predates this independent npm-carried inventory.
- Ecosystem delivery: CI requires six install variants across npm, pnpm 11.25.0, Yarn Classic 1.22.22, Yarn Modern 4.9.4 (`node-modules` and default Plug'n'Play), and Bun 1.4.0; the source tree also carries pinned Next.js Turbopack and Webpack, SvelteKit, Astro, and Nuxt host proofs, Make, Ninja, CMake, Meson, local Parcel 2.16.4, and stable Homebrew evidence without claiming unshipped public integrations.
- Reference engines: Dart Sass 1.101.0, Less 4.9.0, and Stylus 0.64.0 remain development-only and excluded from production bytes and runtime execution; Less forward-checks the frozen 4.6.7 native baseline, and CI separately audits the complete root, documentation, and VS Code development/build graphs.
- Public capability graduation: all seven predeclared `NATIVE-008` surfaces match native evidence; `NATIVE-009` binds the closed prerelease evidence and `REL-010` binds the stable identity.
- Controlled comparative benchmark: the machine-verifiable bare-metal gate is implemented; publication is waiting for the dedicated Linux x64 runner and its scheduled archive.
- Stable publication: verified on protected tag `v0.6.0` at commit `6786655d66ca65c5a06421c8ed70d84183722dce`; the GitHub Release's 15 attested archive/checksum/SBOM subjects and 10 Sigstore bundle files, npm `latest`, SLSA provenance, preserved `next`, and anonymous five-syntax installation all passed exact readback. Historical GitHub Release 372291445 reads back `immutable: false`; the immutable npm version and separately closed RC remain unchanged.

The completed recovery plan and its verbose execution ledger were retired after stable publication. Git history preserves the audit trail; accepted [architecture decisions](docs/adr/README.md), machine-readable native and stable-release contracts, release metadata, and executable tests remain the maintained evidence.

## Contributing

Bring a minimal source input, expected semantics, actual output or diagnostic, and the relevant language-engine version. Run the focused language gate plus Debug and ReleaseSafe before opening a pull request.

High-value contributions include reduced compatibility cases, independent CSS validation, fuzz seeds, controlled benchmark runner capacity, and integrations that preserve the closed execution boundary.

## License

MIT. See [LICENSE](LICENSE).
