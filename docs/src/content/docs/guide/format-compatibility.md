# Format compatibility

The ZigCSS 0.5 development snapshot admits five stylesheet syntaxes through one npm CLI and JavaScript API: CSS, SCSS, indented Sass, Less, and Stylus. CSS enters the native compiler directly. Each preprocessor grammar is owned by an exact canonical engine, then its complete generated CSS is parsed without recovery by ZigCSS before output can be returned or committed.

This page describes the green source snapshot. The public npm release candidate `0.4.0-rc.3` is still CSS-only; the five-language package has not been published.

Publication of the provider-backed `0.5.0-rc.1` snapshot was cancelled before tag creation. ADR-013 now governs a staged self-contained native replacement targeting zero production package dependencies. Until each new native row passes its own corpus, security, package, and platform gates, the canonical adapters below remain reference behavior rather than a native-binary claim.

The machine-readable authority is `tests/formats/matrix.json`. `npm run test:formats` verifies the closed adapter inventory, accepted ADR strategy, provider binding, containment evidence, and real CLI probes. Provider-focused suites additionally own official corpora, diagnostics, imports, limits, concurrency, source maps, package contents, and platform smoke tests.

## What the status terms mean

| Term | Meaning |
|---|---|
| CanonicalCliApi | Available through the npm CLI and API by extension detection or explicit syntax. |
| CanonicalVersion | Language behavior is owned by the exact provider version; ecosystem extensions are separate. |
| CanonicalProvider | The provider runs through the bounded host and feeds strict generated CSS into the native compiler. |
| ExperimentalLibrary | Available only through an explicit Zig library syntax tag. |
| NativeSubset | Only the named ZigCSS-native grammar and result contract are admitted. |
| Unavailable | The extension is rejected and no public compile syntax exists. |
| Unverified | Characterization is not a compatibility contract. |
| Removed | No adapter parser source remains; filename handling exists only for explicit rejection. |

## Executable adapter matrix

| Adapter ID | Recognized extension | Availability | Compatibility | Implementation | Accepted strategy | Owning package |
|---|---|---|---|---|---|---|
| `scss` | `.scss` | CanonicalCliApi | CanonicalVersion | CanonicalProvider | `canonical-integration` | `SCSS-001`, `SCSS-002`, `SASS-010`, `SASS-011`, `SASS-012`, `PRE-005`, `PRE-006`, `PRE-008` |
| `sass` | `.sass` | CanonicalCliApi | CanonicalVersion | CanonicalProvider | `canonical-integration` | `SCSS-001`, `SCSS-002`, `SASS-010`, `SASS-011`, `SASS-012`, `PRE-005`, `PRE-006`, `PRE-008` |
| `less` | `.less` | CanonicalCliApi | CanonicalVersion | CanonicalProvider | `canonical-integration` | `LESS-001`, `LESS-010`, `LESS-011`, `LESS-012`, `PRE-005`, `PRE-006`, `PRE-008` |
| `stylus` | `.styl` | CanonicalCliApi | CanonicalVersion | CanonicalProvider | `canonical-integration` | `STYLUS-001`, `STYLUS-010`, `STYLUS-011`, `STYLUS-012`, `PRE-005`, `PRE-006`, `PRE-008` |
| `css-modules` | `.module.css` | ExperimentalLibrary | NativeSubset | LimitedNative | `limited-native-subset` | `MODULE-001`, `MODULE-002` |
| `css-in-js` | `.css.js`, `.css.ts` | Unavailable | Unverified | Removed | `remove-until-funded` | `JS-001` |
| `postcss` | `.postcss` | Unavailable | Unverified | Removed | `remove-until-funded` | `POSTCSS-001` |
| `tailwind` | `.postcss` | Unavailable | Unverified | Removed | `remove-until-funded` | `TAILWIND-001` |

## Canonical language frontends

| Input | Provider | Version | License | Default extension boundary |
|---|---|---|---|---|
| SCSS | Dart Sass (`sass`) | `1.101.0` | MIT | No plugins, custom functions, custom importers, package importers, or project code |
| Indented Sass | Dart Sass (`sass`) | `1.101.0` | MIT | Original indented bytes; same executable-extension boundary |
| Less | Less (`less`) | `4.6.7` | Apache-2.0 | JavaScript, plugins, and custom file managers disabled |
| Stylus | Stylus (`stylus`) | `0.64.0` | MIT | Project plugins, custom functions, prefix hooks, and custom evaluators disabled |

Canonical support means the language semantics of these exact provider versions plus ZigCSS's documented option surface. It does not imply compatibility with every plugin, JavaScript hook, framework wrapper, ambient configuration, or future provider release. Such execution would require a separately authorized trusted-project-code mode; the default CLI and API never infer that authority.

Every local dependency byte passes through the confined resolver. Entry-relative imports are allowed inside the entry root. Additional roots require repeated `--load-path` values or API `loadPaths`. Network schemes, traversal escapes, symlinks, special files, unstable reads, invalid UTF-8, cycles, and exhausted resource ceilings fail without CSS.

## CLI examples

Syntax is normally detected from the filename:

```bash
node index.js src/app.scss -o dist/app.css --minify
node index.js src/app.sass -o dist/app.css --minify
node index.js src/app.less -o dist/app.css --minify
node index.js src/app.styl -o dist/app.css --minify
```

Stdin requires explicit preprocessor syntax:

```bash
node index.js - --syntax scss -o - --minify
```

Run the executable matrix and focused frontend gates with:

```bash
npm run test:formats
npm run test:preprocessor-sass
npm run test:preprocessor-less
npm run test:preprocessor-stylus
npm run test:preprocessor-product
npm run check:preprocessor-package
```

## Other format boundaries

The [native CSS Modules subset](/guide/css-modules) remains a deliberately closed Zig-library surface. It provides source-specific class names, functional scope, plain-class composition, and local values with owned exports and dependency facts, but the npm CLI and LSP do not admit `.module.css`.

CSS-in-JS, PostCSS plugin execution, and Tailwind-like compilation remain unavailable. Their former heuristic implementations were removed because byte scanning could not preserve the semantics of JavaScript execution, plugin lifecycle, configuration, content scanning, variants, or arbitrary values.

- [Current status](/guide/status)
- [CSS grammar compatibility](/guide/css-compatibility)
- [Native CSS Modules subset](/guide/css-modules)
- [Recovery CLI](/guide/recovery-cli)
- [ADR-012: canonical preprocessor host](https://github.com/vyakymenko/zigcss/blob/main/docs/adr/ADR-012-canonical-preprocessor-host.md)
- [ADR-013: self-contained native frontends](https://github.com/vyakymenko/zigcss/blob/main/docs/adr/ADR-013-self-contained-native-frontends.md)
