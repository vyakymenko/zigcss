# ZigCSS Parcel source-checkout example

This deliberately local proof connects Parcel 2.16.4 to the current
`zigcss-node-v1` compiler through the repository-owned transformer. Parcel and
its complete toolchain are pinned by the root lock; this example manifest stays
dependency-free and script-free so it cannot pretend to be a published Parcel
package.

Run the maintained proof from the repository root with Zig 0.15.2 and Node 22.22.0:

```bash
zig build -Doptimize=ReleaseFast
npm ci --ignore-scripts
ZIGCSS_PARCEL_NATIVE_BINARY="$PWD/zig-out/bin/zigcss" npm run test:parcel-example
```

In PowerShell, set `ZIGCSS_PARCEL_NATIVE_BINARY` to
`(Resolve-Path .\zig-out\bin\zigcss.exe)` and then run
`npm run test:parcel-example`. The verifier creates a disposable checkout,
reuses the exact root-owned Parcel modules, stages the current ZigCSS package
and binary, and proves native compilation, source maps, diagnostics, cache hits,
and dependency invalidation before removing the checkout.

This is not a published `zigcss/parcel` export or a separately installable
transformer. It makes no claim for Parcel versions other than 2.16.4, general
Parcel compatibility, development watch mode, HMR, or stable ZigCSS 0.6.0
delivery; the published binary predates the protocol used by this source proof.
