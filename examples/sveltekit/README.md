# ZigCSS SvelteKit source-checkout example

This pinned example proves one deliberately narrow integration: SvelteKit 2.70.3 loads an external `card.module.scss` file through `zigcss/vite`, compiles its native `_tokens.scss` dependency with the freshly built binary from the same ZigCSS checkout, and carries the result through Vite 8.2.2 client, SSR, and static-prerender builds with source maps enabled.

Run the maintained proof from the repository root with Zig 0.15.2 and Node 24.20.0 LTS:

```bash
zig build -Doptimize=ReleaseFast
npm ci --ignore-scripts
ZIGCSS_SVELTEKIT_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:sveltekit-example
```

In PowerShell, set `ZIGCSS_SVELTEKIT_NATIVE_BINARY` to
`(Resolve-Path .\zig-out\bin\zigcss.exe)` and then run
`npm run test:sveltekit-example`. The verifier installs the exact example lock
into a disposable project, stages only the current checkout package and binary,
runs the real production build, and removes the project afterward.

Install the exact development-only lock and build the current ZigCSS binary before running the standalone verifier. The lock carries an exact `cookie` 0.7.2 security override for the host-only SvelteKit graph; the full lock audit and the empty production graph both report zero vulnerabilities. The verifier stages that binary and the minimum ZigCSS runtime files into an isolated temporary project, denies network access during the host build, checks the CSS Module class in client, server, and prerendered output, and requires source-map evidence for both the entry and its native partial dependency. Its fail-closed JavaScript preload denies arbitrary workers, cluster and process escapes, unsafe bindings, DNS, HTTP, HTTP/2, TLS, WebSocket, datagram, and public socket paths. It admits only the exact staged ZigCSS protocol process, three exact lock-pinned SvelteKit postbuild worker modules, and trace-root-confined local IPC; the negative gate explicitly proves that an `eval` worker with empty `execArgv` and environment cannot shed the preload.

This is not a separately published SvelteKit adapter. It does not claim support for embedded `<style lang="scss">` blocks, Svelte preprocessors, framework-specific HMR or watch invalidation, arbitrary SvelteKit adapters or deployment targets, or general compatibility outside the exact pinned host gate. Published ZigCSS 0.6.0 also predates the current `zigcss-node-v1` adapter protocol, so this example is a current-source-checkout proof only. The preload is a JavaScript host-proof boundary, not an OS sandbox; the exact lock-pinned host and admitted native code remain trusted.

SvelteKit is configured through its official Vite plugin surface, and the static output uses the official adapter-static package: <https://svelte.dev/docs/kit/adapters>.
