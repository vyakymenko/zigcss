# Experimental format compatibility

The current recovery CLI supports only CSS and rejects every alternate extension with exit status `2` before creating output. The Zig library additionally exposes one explicit experimental syntax, `.css_modules`, for the closed native subset documented below. Every other inherited adapter remains **Unavailable**. Legacy code and positive prototype tests are characterization evidence, not a supported subset or upstream compatibility claim.

The machine-readable authority is `tests/formats/matrix.json`. `npm run test:formats` checks every legacy and native adapter source, legacy format tag, public syntax tag, removed file, accepted ADR strategy, pinned canonical provider, and nine real executable rejection probes. ADR-012 now funds canonical SCSS, Sass, Less, and Stylus integration, but a funded roadmap is not shipped support.

## Status and strategy meanings

| Term | Meaning |
|---|---|
| Unavailable | Rejected by the recovery CLI before output and absent from the public compile syntax enum. |
| ExperimentalLibrary | Available only through an explicit Zig library syntax tag; the CLI and LSP still reject the extension. |
| Unverified | Legacy characterization is not a compatibility contract or supported subset. |
| NativeSubset | Only the exact ZigCSS-native grammar and result contract are supported; this is not full ecosystem compatibility. |
| LegacyCharacterized | Heuristic adapter source remains only behind the test-only legacy boundary. |
| LimitedNative | A closed implementation uses the rebuilt parser, structural emitter, strict diagnostics, and owned public results. |
| Removed | No adapter parser source or legacy `Format` tag remains; filename handling exists only to reject the unavailable input. |
| `canonical-integration` | Integrate an exact canonical provider through the bounded `zigcss-preprocessor-v1` host; remain unavailable until the adapter's admission gates pass. |
| `limited-native-subset` | Implement only a closed, clearly named grammar with strict errors outside it. |
| `remove-until-funded` | Expose no adapter or ecosystem claim unless a later funded program accepts a new decision. |

## Adapter matrix

| Adapter ID | Recognized extension | Availability | Compatibility | Implementation | Accepted strategy | Owning package |
|---|---|---|---|---|---|---|
| `scss` | `.scss` | Unavailable | Unverified | Removed | `canonical-integration` | `SCSS-001`, `SCSS-002`, `SASS-010`, `SASS-011`, `SASS-012` |
| `sass` | `.sass` | Unavailable | Unverified | Removed | `canonical-integration` | `SCSS-001`, `SCSS-002`, `SASS-010`, `SASS-011`, `SASS-012` |
| `less` | `.less` | Unavailable | Unverified | Removed | `canonical-integration` | `LESS-001`, `LESS-010`, `LESS-011`, `LESS-012` |
| `stylus` | `.styl` | Unavailable | Unverified | Removed | `canonical-integration` | `STYLUS-001`, `STYLUS-010`, `STYLUS-011`, `STYLUS-012` |
| `css-modules` | `.module.css` | ExperimentalLibrary | NativeSubset | LimitedNative | `limited-native-subset` | `MODULE-001`, `MODULE-002` |
| `css-in-js` | `.css.js`, `.css.ts` | Unavailable | Unverified | Removed | `remove-until-funded` | `JS-001` |
| `postcss` | `.postcss` | Unavailable | Unverified | Removed | `remove-until-funded` | `POSTCSS-001` |
| `tailwind` | `.postcss` (`@apply` path) | Unavailable | Unverified | Removed | `remove-until-funded` | `TAILWIND-001` |

## What the inherited code actually does

| Adapter | Characterized internal boundary | Why it is not compatibility evidence |
|---|---|---|
| SCSS | Removed by `SCSS-001`; no parser or legacy `Format` dispatch remains. | The former byte passes stripped imports/directives and did not implement canonical Sass lexical, scope, module, interpolation, or evaluation rules. |
| Indented Sass | Removed with SCSS by `SCSS-001`; no line converter or legacy `Format` dispatch remains. | The former converter guessed selector/property identity and did not model comments, strings, modules, scope, interpolation, or expressions. |
| Less | Removed by `LESS-001`; no parser or legacy `Format` dispatch remains. | The former global at-variable substitution guessed CSS at-rules and did not model scope, lazy evaluation, mixins, nesting, imports, strings/comments, arithmetic, or dependencies. |
| Stylus | Removed by `STYLUS-001`; no parser or legacy `Format` dispatch remains. | The former indentation converter guessed optional punctuation and selector/property identity, swallowed variable errors, and did not model expressions, scope, dependencies, or strict errors. |
| CSS Modules | The FNV/legacy-AST parser is removed. `.css_modules` walks the rebuilt typed AST with source-specific names, functional scope, plain-class composition, and token-aware local values; results own class/value exports, references, and module dependency facts. | This is the exact [native CSS Modules subset](/guide/css-modules), not a claim of complete ecosystem compatibility. It never loads external modules; imported values, raw ICSS, and ambiguous semantics fail with `CSS0009` and no CSS. |
| CSS-in-JS | Removed by `JS-001`; no byte scanner or legacy `Format` dispatch remains. | The former code had no JavaScript/TypeScript lexer or AST, could not identify valid tagged templates safely, and deleted dynamic semantics rather than rejecting them. |
| PostCSS-like | Removed by `POSTCSS-001`; no directive scanner or legacy `Format` dispatch remains. | The former path could delete `@custom-media` and `@nest`, and had no JavaScript plugin discovery, configuration, ordering, lifecycle, dependency, or map contract. |
| Tailwind-like | Removed by `TAILWIND-001`; no fixed utility registry or `@apply` scanner remains. | The former table omitted unknown utilities and had no canonical content scanning, configuration, versions, variants, plugins, arbitrary values, or ordering semantics. |

## Accepted direction

ADR-005 originally chose removal until a dedicated program was funded. ADR-012 now supersedes that future direction for SCSS, indented Sass, Less, and Stylus: ZigCSS will integrate exact canonical engines through one bounded host, then feed complete generated CSS through the stable ZigCSS parser, transforms, emitter, diagnostics, dependencies, and result ownership boundary. The current removal remains protective containment while that implementation is built. CSS-in-JS, PostCSS-like behavior, and Tailwind-like behavior remain removal-until-funded. “Removal” still means no public syntax tag, CLI option, package claim, or fallback to CSS.

The accepted provider baselines are exact and release-controlled:

| Language input | Canonical provider | Baseline | License |
|---|---|---|---|
| SCSS and indented Sass | Dart Sass | `sass` `1.101.0` | MIT |
| Less | Less | `less` `4.6.7` | Apache-2.0 |
| Stylus | Stylus | `stylus` `0.64.0` | MIT |

“Full language compatibility” will mean canonical behavior for these named provider versions and the documented integrated options—not automatic compatibility with every third-party plugin or future provider release. Ordinary imports, modules where the language defines them, diagnostics, dependencies, deterministic output, and composed source maps are release gates. Arbitrary JavaScript plugins, custom functions, and custom importers belong to a separate opt-in **trusted-project-code mode** that is never enabled for untrusted public compilation.

CSS Modules is the one accepted limited-native direction. `MODULE-001` provides library-only deterministic names, owned export mappings, limits, source maps, direct CSS import facts, recovery-disabled independent generated-CSS validation, and strict negative behavior. `MODULE-002` adds occurrence-keyed functional scope, plain-class composition with owned references/combined dependency limits, and sequential local `@value` definitions with structural use-token replacement. Imported values, raw ICSS import/export, and implicit external resolution stay unavailable by design.

No adapter may graduate on positive examples alone. Admission requires the bounded host and confined resolver, strict negative behavior, source-map composition, normalized diagnostics and dependencies, resource-limit cleanup, generated CSS accepted by the stable parser/emitter, official/versioned corpus coverage, independent differential evidence, and install/offline smoke tests on every claimed platform. Each language graduates independently.

```bash
zig build test -Doptimize=ReleaseSafe
npm run test:formats
```

- [Current status](/guide/status)
- [CSS grammar compatibility](/guide/css-compatibility)
- [Native CSS Modules subset](/guide/css-modules)
- [ADR-012: canonical preprocessor host](https://github.com/vyakymenko/zigcss/blob/main/docs/adr/ADR-012-canonical-preprocessor-host.md)
- [Recovery CLI](/guide/recovery-cli)
