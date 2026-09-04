# ZigCSS Nuxt source-checkout example

This pinned example proves one deliberately narrow integration: Nuxt 4.5.2 loads an external `card.module.scss` file through its Vite builder and `zigcss/vite`, compiles a native `_tokens.scss` dependency with the freshly built binary from the same ZigCSS checkout, rebases a local SVG asset, and carries the CSS Module binding through the production client, Nitro SSR, and prerender builds with source maps enabled.

Run the maintained proof from the repository root with Zig 0.15.2 and Node
22.22.0:

```bash
zig build -Doptimize=ReleaseFast
npm ci --ignore-scripts
ZIGCSS_NUXT_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:nuxt-example
```

In PowerShell, set `ZIGCSS_NUXT_NATIVE_BINARY` to
`(Resolve-Path .\zig-out\bin\zigcss.exe)` and then run
`npm run test:nuxt-example`. The verifier installs the exact example lock into
a disposable project, repeats installation from its private cache offline,
stages only the current checkout package and binary, runs the real production
build, and removes the project afterward.

Install the exact development-only lock and build the current ZigCSS binary before running the standalone verifier. The direct `cac` and `commander` pins satisfy optional Nuxt CLI peer edges so every non-root lock entry remains development-only. The full lock audit and the empty production graph both report zero vulnerabilities. Nuxt 4.5.2 requires Node `^22.19.0 || ^24.11.0 || >=26.0.0`. The verifier warms a private npm cache, repeats `npm ci` in strict offline mode, stages that binary and the minimum ZigCSS runtime files into the isolated temporary project, and denies all socket and DNS access during the host build. Its child-process allowlist contains only the exact staged ZigCSS `--internal-node-v1` compiler invocation and Nitro's exact lock-pinned esbuild 0.28.2 service invocation; every path, argument, option, shell, and other child-process API is denied. It also blocks Worker and cluster process escapes, direct unsafe Node bindings, inspector activation, and public or internal network entry points. This is a JavaScript host-proof boundary, not an operating-system sandbox; the exact lock-pinned Nuxt host and native addons remain trusted. It checks the CSS Module class and rendered text in client and server output, resolves the rebased asset URL to the exact emitted file, and requires source-map evidence for both the entry and its native partial dependency.

The native SCSS map chain is retained in Nuxt's intermediate Vite SSR output under `.nuxt`. Nitro's public `.output` copy retains client JavaScript maps, including `app.vue`, but does not publish that CSS map chain; this example therefore does not claim a public production CSS map from Nuxt.

This is not a separately published Nuxt adapter. It does not claim support for embedded `<style lang="scss">` blocks, Nuxt modules, framework-specific HMR or watch invalidation, other Nuxt builders, deployment presets, or general compatibility outside the exact pinned host gate. Published ZigCSS 0.6.0 also predates the current `zigcss-node-v1` adapter protocol, so this example is a current-source-checkout proof only.

Nuxt uses Vite by default and exposes Vite configuration through `nuxt.config`: <https://nuxt.com/docs/4.x/getting-started/styling> and <https://nuxt.com/docs/4.x/api/nuxt-config>.
