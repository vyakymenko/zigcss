# Format compatibility

The ZigCSS source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths. CSS enters the verified core directly. Each preprocessor frontend evaluates to complete CSS, which is then parsed with recovery disabled before output can be returned or committed.

The public npm `next` release is the self-contained native `0.6.0-rc.2` prerelease. npm `latest` remains the stable 0.3.0 line.

The four preprocessor rows are `native-graduated` on the published prerelease: their pinned corpora, strict negative/resource cases, deterministic reruns, generated-CSS validation, product routing, zero-dependency package, five-target, artifact, provenance, consumer, documentation, and publication gates pass. Executable plugin parity remains separate.

The machine-readable authority is `tests/formats/matrix.json`. `npm run test:formats` verifies the closed adapter inventory, accepted ADR strategy, exact native source inventory, development-oracle binding, containment evidence, and direct native CLI probes. The native contract additionally binds every language source, package state, exact release version, and release-ready interlock.

## What the status terms mean

| Term | Meaning |
|---|---|
| NativeCliZigApi | Available in the source-built native binary and explicit `zigcss.experimental_native` namespace with an explicit syntax value. |
| NativeGraduated | The native row passes its pinned oracle, strict failure/resource, deterministic, product, package, five-target, and pre-tag release gates; executable plugin parity remains excluded. |
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
| Less | Less (`less`) | `4.6.7` | Apache-2.0 | JavaScript, plugins, and custom file managers disabled |
| Stylus | Stylus (`stylus`) | `0.64.0` | MIT | Project plugins, custom functions, prefix hooks, and custom evaluators disabled |

These exact providers are development-only reference oracles. They judge differential tests but do not enter production dependencies, archives, installed packages, SBOM runtime closure, or stylesheet compilation, and they do not run during compilation. Matching an oracle version does not imply ecosystem-plugin compatibility or future-version compatibility.

Every local dependency byte passes through the confined native resolver. Entry-relative imports are allowed inside the entry root. Additional roots require repeated `--load-path` values or API `root_paths`. Network schemes, traversal escapes, symlinks, special files, unstable reads, invalid UTF-8, cycles, and exhausted resource ceilings fail without CSS.

## Native CLI examples

The native route is explicit; filename extension alone does not select a preprocessor:

```bash
zig-out/bin/zigcss src/app.scss --syntax scss -o dist/app.css --minify
zig-out/bin/zigcss src/app.sass --syntax sass -o dist/app.css --minify
zig-out/bin/zigcss src/app.less --syntax less -o dist/app.css --minify
zig-out/bin/zigcss src/app.styl --syntax stylus -o dist/app.css --minify
```

Stdin also requires an explicit syntax:

```bash
zig-out/bin/zigcss - --syntax scss -o - --minify
```

The [compiled public examples](/guide/build-from-source) parameterize all four Zig API rows and all five binary inputs. Run the focused gates with:

```bash
zig build test-native-sass-conformance --summary all
zig build test-native-less-conformance --summary all
zig build test-native-stylus-conformance --summary all
zig build test-native-zig-api --summary all
zig build test-native-cli --summary all
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
