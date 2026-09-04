# Format compatibility

The ZigCSS 0.7.0-rc.1 source candidate compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths; this candidate is not published. CSS enters the verified core directly. Each preprocessor frontend evaluates to complete CSS, which is then parsed with recovery disabled before output can be returned or committed.

Stable 0.6.0 contains the self-contained native five-language surface and is published on npm `latest` by the exact stable promotion workflow; historical `0.6.0-rc.2` remains available as an immutable npm version on `next`. Their GitHub releases predate Immutable Releases and read back `immutable: false`.

The four preprocessor rows are `native-graduated` on the published stable release: their pinned corpora, strict negative/resource cases, deterministic reruns, generated-CSS validation, product routing, zero-dependency package, five-target, artifact, provenance, consumer, documentation, and publication gates pass. Executable plugin parity remains separate.

The machine-readable authority is `tests/formats/matrix.json`. `npm run test:formats` verifies the closed adapter inventory, accepted ADR strategy, exact native source inventory, development-oracle binding, containment evidence, and direct native CLI probes. The native contract additionally binds every language source, package state, exact release version, and release-ready interlock.

## What the status terms mean

| Term | Meaning |
|---|---|
| NativeCliZigApi | Available in the source-built native binary and explicit `zigcss.experimental_native` namespace with an explicit syntax value. |
| NativeGraduated | The native row passes its pinned oracle, strict failure/resource, deterministic, product, package, five-target, and pre-tag release gates; executable preprocessor extension and provider-plugin parity remains excluded. |
| NativeFrontend | A self-contained Zig parser/evaluator feeds complete CSS through the recovery-disabled ZigCSS core without a provider process. |
| ExperimentalLibrary | Available only through an explicit Zig library syntax tag. |
| NativeSubset | Only the named ZigCSS-native grammar and result contract are admitted. |
| Unavailable | The extension is rejected and no public compile syntax exists. |
| Unverified | Characterization is not a compatibility contract. |
| Removed | No adapter parser source remains; filename handling exists only for explicit rejection. |

## Executable adapter matrix

| Adapter ID | Recognized extension | Availability | Compatibility | Implementation | Accepted strategy | Owning package |
|---|---|---|---|---|---|---|
| `scss` | `.scss` | NativeCliZigApi | NativeGraduated | NativeFrontend | `native-reimplementation` | `NSASS-010`, `NSASS-011`, `NSASS-012`, `NATIVE-006`, `NATIVE-007`, `NATIVE-008`, `NATIVE-009` |
| `sass` | `.sass` | NativeCliZigApi | NativeGraduated | NativeFrontend | `native-reimplementation` | `NSASS-010`, `NSASS-011`, `NSASS-012`, `NATIVE-006`, `NATIVE-007`, `NATIVE-008`, `NATIVE-009` |
| `less` | `.less` | NativeCliZigApi | NativeGraduated | NativeFrontend | `native-reimplementation` | `NLESS-010`, `NLESS-011`, `NLESS-012`, `NATIVE-006`, `NATIVE-007`, `NATIVE-008`, `NATIVE-009` |
| `stylus` | `.styl` | NativeCliZigApi | NativeGraduated | NativeFrontend | `native-reimplementation` | `NSTYLUS-010`, `NSTYLUS-011`, `NSTYLUS-012`, `NATIVE-006`, `NATIVE-007`, `NATIVE-008`, `NATIVE-009` |
| `css-modules` | `.module.css` | ExperimentalLibrary | NativeSubset | LimitedNative | `limited-native-subset` | `MODULE-001`, `MODULE-002` |
| `css-in-js` | `.css.js`, `.css.ts` | Unavailable | Unverified | Removed | `remove-until-funded` | `JS-001` |
| `postcss` | `.postcss` | Unavailable | Unverified | Removed | `remove-until-funded` | `POSTCSS-001` |
| `tailwind` | `.postcss` | Unavailable | Unverified | Removed | `remove-until-funded` | `TAILWIND-001` |

## Development-only reference oracles

| Input | Oracle | Version | License | Permanent execution boundary |
|---|---|---|---|---|
| SCSS | Dart Sass (`sass`) | `1.101.0` | MIT | No plugins, custom functions/importers, package importers, or project code |
| Indented Sass | Dart Sass (`sass`) | `1.101.0` | MIT | Original indented bytes; same executable-extension boundary |
| Less | Less (`less`) | `4.9.0` forward oracle; frozen `4.6.7` native baseline | Apache-2.0 | JavaScript, plugins, and custom file managers disabled |
| Stylus | Stylus (`stylus`) | `0.64.0` | MIT | Project plugins, custom functions, prefix hooks, and custom evaluators disabled |

These exact providers are development-only reference oracles. They judge differential tests but do not enter production dependencies, archives, installed packages, SBOM runtime closure, or stylesheet compilation, and they do not run during compilation. Less 4.9.0 is a forward oracle over the frozen 4.6.7 native conformance baseline; the checksum-owned 4.6.7 corpus remains the graduation authority until a separate regraduation changes it. Matching an oracle version does not imply ecosystem-plugin compatibility or future-version compatibility. CI audits the complete root development graph with `npm run audit:development`, independently of the production-only audits. The former direct `image-size` 0.5.5 dependency is absent; the development host routes Less and Stylus image metadata through one shared bounded PNG/GIF/JPEG/SVG dimension parser over resolver-owned bytes.

Every local dependency byte passes through the confined native resolver. Entry-relative imports are allowed inside the entry root. The CLI does not expose additional roots; Zig consumers can configure them with API `root_paths`. Network schemes, traversal escapes, symlinks, special files, unstable reads, invalid UTF-8, cycles, and exhausted resource ceilings fail without CSS.

The optimizer, target-prefix, Source Map, and hardened output behavior below describes the current `Unreleased` source snapshot, not the immutable stable 0.6.0 CLI. After any native frontend produces complete CSS, `--optimize` runs the same closed seven-pass preset used by direct CSS input and reaches the same bounded byte-stable fixed point before output is committed. This applies to file, stdin, watch, and bounded batch routes for SCSS, indented Sass, Less, and Stylus. Fixed-point optimization remains incompatible with `--source-map`; `--profile` remains CSS-only.

The separate `--autoprefix --browsers <query>` pair applies the verified eight-feature target pass after frontend evaluation and any requested optimizer fixed point. One strict canonical query is shared immutably across file, stdin, watch, and bounded batch routes. Prefixing works with deterministic composed source maps when fixed-point optimization is not requested; it is not general Browserslist or general autoprefixing support.

## Native CLI examples

The native route is explicit; filename extension alone does not select a preprocessor:

```bash
zig-out/bin/zigcss src/app.scss --syntax scss -o dist/app.css --minify --optimize
zig-out/bin/zigcss src/app.sass --syntax sass -o dist/app.css --minify --optimize
zig-out/bin/zigcss src/app.less --syntax less -o dist/app.css --minify --optimize
zig-out/bin/zigcss src/app.styl --syntax stylus -o dist/app.css --minify --optimize
```

An explicit legacy query can be applied to any row without target discovery:

```bash
zig-out/bin/zigcss src/app.scss --syntax scss -o dist/app.css --minify \
  --autoprefix --browsers "safari >= 7, ie >= 11"
```

Stdin also requires an explicit syntax:

```bash
zig-out/bin/zigcss - --syntax scss -o - --minify
```

The current `Unreleased` package-root Node.js API exposes the same closed five-syntax set through `compile`, `compileSync`, `compileFile`, and `compileFileSync`; `detectSyntax` recognizes only the six supported filename extensions. It returns immutable CSS, parsed source maps, diagnostics, and dependency facts from the freshly built, confined native binary in the same source checkout. Published or repacked 0.6.0 is not a runtime-delivery claim for this new protocol because its immutable stable binary predates `zigcss-node-v1`. Explicit experimental adapters now expose the current-checkout compiler through `zigcss/vite`, `zigcss/rollup`, `zigcss/esbuild`, `zigcss/bun`, `zigcss/webpack`, and `zigcss/rspack`.

A pinned Next.js 16.3.4 Turbopack example reuses only `zigcss/webpack` for one condition-confined global SCSS entry; Next.js 16.2+ loader output module types are required. The same exact host now has a separate Webpack proof with Sass 1.101.0 only as the downstream parser: one exact-project-file `enforce: 'pre'` rule performs cached-offline `next build --webpack` production builds while blocking public Node network entry points, records the exact staged native process, proves an unchanged zero-native-invocation cache hit, and then proves dependency-only invalidation changes the emitted CSS and invokes ZigCSS again. Its JavaScript preload is not an OS sandbox and trusts the exact lock-pinned host/native addons. The final Webpack stylesheet does not retain the original ZigCSS source-map chain. Both modes remain source-checkout-only and claim no CSS Modules, other syntaxes, arbitrary SCSS globs, development HMR/watch invalidation, `zigcss/turbopack` or `zigcss/next` export, other Next.js/Webpack versions, or general framework compatibility. A separate pinned SvelteKit 2.70.3/Svelte 5.57.0/Vite 8.2.2 example reuses `zigcss/vite` for one external `.module.scss` entry and proves client, SSR, prerender, native partial, and source-map behavior under a deny-network build. Embedded styles, Svelte preprocessors, framework HMR/watch invalidation, arbitrary adapters/targets, and general SvelteKit compatibility remain unclaimed.

A pinned Astro 7.2.10 static example registers `zigcss/vite` through Astro's Vite configuration for one external `card.module.scss` import. Its source-checkout gate warms an isolated npm cache, repeats `npm ci` offline, denies network access during the production build, and passes the freshly built checkout binary. It verifies the same CSS Module binding in rendered HTML and emitted client JavaScript, a native Sass partial, a rebased fingerprinted SVG asset, and exact composed source-map content. Embedded Astro styles, HMR/watch invalidation, SSR adapters, every renderer, framework aliases, `zigcss/astro`, and stable 0.6.0 delivery remain unclaimed.

A pinned Nuxt 4.5.2 example also registers `zigcss/vite` for one external `card.module.scss` import. Its source-checkout gate denies network access during the production build and verifies the binding across the client bundle, Nitro SSR bundle, and prerendered page, together with a native Sass partial and rebased SVG asset. The exact native CSS map chain is present only in Nuxt's `.nuxt` intermediate Vite output; the public output retains client JavaScript maps, but no public production CSS map or runtime SSR request is claimed. Embedded Nuxt styles, modules, HMR/watch invalidation, other builders or deployment presets, `zigcss/nuxt`, and stable 0.6.0 delivery remain unclaimed.

A tested Parcel 2.16.4 local transformer example uses the same compiler, but Parcel's package-naming contract prevents a `zigcss/parcel` export. These integrations do not add new source languages or imply a published Parcel transformer, framework-specific adapter, Nx executor, Bazel rule, Angular integration, or general framework compatibility. No PostCSS adapter is shipped because the PostCSS CSS parser receives input before normal plugin execution.

The [compiled public examples](/guide/build-from-source) parameterize all four Zig API rows and all five binary inputs. Run the focused gates with:

```bash
zig build test-native-sass-conformance --summary all
zig build test-native-less-conformance --summary all
zig build test-native-stylus-conformance --summary all
zig build test-native-zig-api --summary all
zig build test-native-cli --summary all
npm run test:node-api
npm run test:bundler-adapters
npm run test:turbopack-example
npm run test:next-webpack-example
npm run test:sveltekit-example
npm run test:astro-example
npm run test:nuxt-example
npm run test:parcel-example
npm run test:native-contract
npm run test:native-package-evidence
```

## Other format boundaries

The [native CSS Modules subset](/guide/css-modules) remains a deliberately closed Zig-library surface. It provides source-specific class names, functional scope, plain-class composition, and local values with owned exports and dependency facts, but the CLI and LSP do not admit `.module.css`.

CSS-in-JS, PostCSS plugin execution, and Tailwind-like compilation remain unavailable. Their former heuristic implementations were removed because byte scanning could not preserve JavaScript execution, plugin lifecycle, configuration, content scanning, variants, or arbitrary values.

- [Current status](/guide/status)
- [CSS grammar compatibility](/guide/css-compatibility)
- [Native CSS Modules subset](/guide/css-modules)
- [Build from source](/guide/build-from-source)
- [Recovery CLI](/guide/recovery-cli)
- [ADR-012: canonical reference host](https://github.com/vyakymenko/zigcss/blob/main/docs/adr/ADR-012-canonical-preprocessor-host.md)
- [ADR-013: self-contained native frontends](https://github.com/vyakymenko/zigcss/blob/main/docs/adr/ADR-013-self-contained-native-frontends.md)
