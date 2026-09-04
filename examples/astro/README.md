# Astro host proof

This is one deliberately narrow integration proof for the current ZigCSS source checkout. It pins Astro 7.2.10 exactly and registers the existing `zigcss/vite` plugin through Astro's documented `vite` configuration surface. Astro 7.2.10 requires Node `>=22.12.0`; the example manifest preserves that supported lower bound while its maintained CI host is pinned to Node 24.20.0 LTS.

Run the maintained proof from the repository root with Zig 0.15.2 and Node
24.20.0 LTS:

```bash
zig build -Doptimize=ReleaseFast
npm ci --ignore-scripts
ZIGCSS_ASTRO_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:astro-example
```

In PowerShell, set `ZIGCSS_ASTRO_NATIVE_BINARY` to
`(Resolve-Path .\zig-out\bin\zigcss.exe)` and then run
`npm run test:astro-example`. The verifier installs the exact example lock into
a disposable project, repeats installation from its private cache offline,
stages only the current checkout package and binary, runs the real production
build, and removes the project afterward.

The production gate builds one external `card.module.scss` import for Astro's rendered page and client bundle. It proves the same CSS Module binding in rendered static HTML and emitted JavaScript, an imported Sass token, CSS `url()` rebasing to a fingerprinted SVG asset, and a composed production source map containing both Sass sources. The verifier installs the exact lock in a temporary copy, repeats `npm ci` from an isolated cache in offline mode, stages the current checkout package and native binary, and denies every socket and DNS operation during `astro build`. Its child-process allowlist contains only the exact canonical staged ZigCSS `--internal-node-v1` invocation and Astro's exact lock-pinned esbuild 0.28.2 platform service with fixed arguments, project working directory, and standard streams. It also blocks Worker and cluster process escapes, direct unsafe Node bindings, inspector activation, and public or internal network entry points. This is a JavaScript host-proof boundary, not an operating-system sandbox; the exact lock-pinned Astro host and native addons remain trusted. The final trace is cleared after package resolution and bound to the actual Astro build PID before the complete temporary tree is removed.

This is current-source-checkout proof only: the published `zigcss@0.6.0` binary predates the current `zigcss-node-v1` protocol. It does not claim embedded Astro `<style lang="scss">` preprocessing, dev-server HMR or watch invalidation, framework aliases, every Astro renderer, SSR adapters, or a separate `zigcss/astro` export.

Astro documents passing Vite options through its [`vite` configuration field](https://docs.astro.build/en/reference/configuration-reference/#vite).
