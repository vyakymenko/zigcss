# Next.js Turbopack and Webpack global-SCSS example

This source-checkout example reuses the existing `zigcss/webpack` raw loader in
Next.js Turbopack. It is intentionally bounded to the one global
`app/styles.scss` entry shown here. Next.js added configurable loader output
module types in 16.2; the executable gate is pinned to Next.js 16.3.4 with
React and ReactDOM 19.2.4.

Build the current checkout's native binary before using this example. The
published `zigcss@0.6.0` binary predates the current `zigcss-node-v1` protocol,
so this example is not a stable-release consumer yet.

From the repository root, the supported checkout proof builds ZigCSS with Zig
0.15.2, installs the exact root lock with Node 22.22.0, and runs both isolated real-host
gates:

```bash
zig build -Doptimize=ReleaseFast
npm ci --ignore-scripts
ZIGCSS_TURBOPACK_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:turbopack-example
ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:next-webpack-example
```

In PowerShell, set each variable to
`(Resolve-Path .\zig-out\bin\zigcss.exe)` before its matching `npm run` command.
The verifiers install the pinned host into disposable projects, run the real
production builds, enforce their network and process boundaries, and remove the
projects afterward.

```bash
zig build -Doptimize=ReleaseFast
cd examples/next-turbopack
npm ci --ignore-scripts
npm install --ignore-scripts --no-save --install-links=false ../..
npm run build
npm run build:webpack
```

The configuration disables Next.js's built-in Sass loader, passes the generated
CSS to Turbopack as `type: 'css'`, emits production browser source maps, and
enables the persistent build cache so ZigCSS dependency registration is tested.

The same exact host also exposes an explicit `next build --webpack` proof. Its
documented `webpack(config)` extension adds one path-confined `enforce: 'pre'`
rule, keeping `zigcss/webpack` as the rightmost source transformation before
Next.js's ordinary Sass and CSS pipeline. The example pins `sass` 1.101.0 only
as that downstream parser. The isolated executable gate records the exact
staged ZigCSS child process and its `--internal-node-v1` argument, so the
built-in Sass implementation cannot create a false-positive native proof.

The Webpack gate performs a production build, then requires an unchanged warm
build to reuse the persistent cache with zero ZigCSS invocations. Only after
that control does it change `_tokens.scss` and require both changed CSS and a
new native invocation. It verifies the prerendered HTML, emitted CSS, native
process trace, cache hit, and imported-file cache invalidation. Its preload
blocks public Node network entry points including loopback listeners and Unix
sockets, direct unsafe process/network bindings, Worker and cluster escapes,
and every child process except exact Next workers and the staged ZigCSS
protocol process. This is a JavaScript host-proof boundary, not an OS sandbox;
the exact lock-pinned host and native addons remain trusted. Next.js 16
documents the `--webpack` mode and custom configuration hook, but does not
cover custom Webpack configuration under semver; this proof therefore remains
pinned to the exact host and current source checkout.

This example does not claim CSS Modules, Sass-indented, Less, Stylus, arbitrary
SCSS entry globs, a `zigcss/turbopack` export, a general Turbopack plugin, or
framework support beyond the pinned Next.js host gate. It also does not claim
development HMR or watch invalidation, a `zigcss/next` export, stable 0.6.0
delivery, or compatibility with other Next.js or Webpack versions. Those
surfaces require their own real-host evidence.

Official contract: [Next.js Turbopack loader rules and module types](https://nextjs.org/docs/app/api-reference/config/next-config-js/turbopack#module-types).

Webpack contracts: [Next.js CLI `--webpack`](https://nextjs.org/docs/app/api-reference/cli/next#next-build-options), [custom Webpack configuration](https://nextjs.org/docs/app/api-reference/config/next-config-js/webpack), and [Webpack pre-loader ordering](https://webpack.js.org/configuration/module/#ruleenforce).
