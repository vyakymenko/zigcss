# Experimental format compatibility

The recovery CLI supports only CSS and rejects every alternate extension with exit status `2` before creating output. The Zig library additionally exposes one explicit experimental syntax, `.css_modules`, for the closed native subset documented below. Every other inherited adapter remains **Unavailable**. Legacy code and positive prototype tests are characterization evidence, not a supported subset or upstream compatibility claim.

The machine-readable authority is `tests/formats/matrix.json`. `npm run test:formats` checks every legacy and native adapter source, legacy format tag, public syntax tag, removed file, ADR-005 strategy, and nine real executable rejection probes.

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
| `limited-native-subset` | Implement only a closed, clearly named grammar with strict errors outside it. |
| `remove-until-funded` | Expose no adapter or ecosystem claim unless a later funded program accepts a new decision. |

## Adapter matrix

| Adapter ID | Recognized extension | Availability | Compatibility | Implementation | Accepted strategy | Owning package |
|---|---|---|---|---|---|---|
| `scss` | `.scss` | Unavailable | Unverified | Removed | `remove-until-funded` | `SCSS-001`, `SCSS-002` |
| `sass` | `.sass` | Unavailable | Unverified | Removed | `remove-until-funded` | `SCSS-001`, `SCSS-002` |
| `less` | `.less` | Unavailable | Unverified | Removed | `remove-until-funded` | `LESS-001` |
| `stylus` | `.styl` | Unavailable | Unverified | Removed | `remove-until-funded` | `STYLUS-001` |
| `css-modules` | `.module.css` | ExperimentalLibrary | NativeSubset | LimitedNative | `limited-native-subset` | `MODULE-001`, `MODULE-002` |
| `css-in-js` | `.css.js`, `.css.ts` | Unavailable | Unverified | LegacyCharacterized | `remove-until-funded` | `JS-001` |
| `postcss` | `.postcss` | Unavailable | Unverified | LegacyCharacterized | `remove-until-funded` | `POSTCSS-001` |
| `tailwind` | `.postcss` (`@apply` path) | Unavailable | Unverified | LegacyCharacterized | `remove-until-funded` | `TAILWIND-001` |

## What the inherited code actually does

| Adapter | Characterized internal boundary | Why it is not compatibility evidence |
|---|---|---|
| SCSS | Removed by `SCSS-001`; no parser or legacy `Format` dispatch remains. | The former byte passes stripped imports/directives and did not implement canonical Sass lexical, scope, module, interpolation, or evaluation rules. |
| Indented Sass | Removed with SCSS by `SCSS-001`; no line converter or legacy `Format` dispatch remains. | The former converter guessed selector/property identity and did not model comments, strings, modules, scope, interpolation, or expressions. |
| Less | Removed by `LESS-001`; no parser or legacy `Format` dispatch remains. | The former global at-variable substitution guessed CSS at-rules and did not model scope, lazy evaluation, mixins, nesting, imports, strings/comments, arithmetic, or dependencies. |
| Stylus | Removed by `STYLUS-001`; no parser or legacy `Format` dispatch remains. | The former indentation converter guessed optional punctuation and selector/property identity, swallowed variable errors, and did not model expressions, scope, dependencies, or strict errors. |
| CSS Modules | The FNV/legacy-AST parser is removed. `.css_modules` walks the rebuilt typed AST with source-specific names, functional scope, plain-class composition, and token-aware local values; results own class/value exports, references, and module dependency facts. | This is the exact [native CSS Modules subset](/guide/css-modules), not a claim of complete ecosystem compatibility. It never loads external modules; imported values, raw ICSS, and ambiguous semantics fail with `CSS0009` and no CSS. |
| CSS-in-JS | Scans backticks and object-like braces, deletes interpolation expressions, and parses remaining bytes as CSS. | It has no JavaScript/TypeScript lexer or AST, cannot identify valid tagged templates safely, and deletes dynamic semantics rather than rejecting them. |
| PostCSS-like | Byte-scans `@apply` and skips selected at-rules before legacy CSS parsing. | `@custom-media` and `@nest` may disappear, and there is no JavaScript plugin discovery, configuration, ordering, lifecycle, dependency, or map contract. |
| Tailwind-like | Expands whitespace-separated names from a fixed in-memory utility table inside the PostCSS-like scanner. | Unknown utilities are omitted; content scanning, configuration, versions, variants, plugins, arbitrary values, ordering, and canonical Tailwind semantics are absent. |

## Accepted direction

ADR-005 chooses removal until a dedicated program is funded for SCSS/Sass, Less, Stylus, CSS-in-JS, PostCSS-like behavior, and Tailwind-like behavior. `SCSS-001`, `LESS-001`, and `STYLUS-001` have deleted their heuristic parser sources and legacy dispatch tags while retaining explicit CLI/LSP rejection. “Removal” means no public syntax tag, CLI option, package claim, or fallback to CSS. Verified native transforms keep ZigCSS-specific names rather than borrowing PostCSS or Tailwind branding.

CSS Modules is the one accepted limited-native direction. `MODULE-001` provides library-only deterministic names, owned export mappings, limits, source maps, direct CSS import facts, recovery-disabled independent generated-CSS validation, and strict negative behavior. `MODULE-002` adds occurrence-keyed functional scope, plain-class composition with owned references/combined dependency limits, and sequential local `@value` definitions with structural use-token replacement. Imported values, raw ICSS import/export, and implicit external resolution stay unavailable by design.

No adapter may graduate on positive examples alone. Admission requires strict negative behavior, strings/comments that cannot corrupt URLs or quoted text, fixture and dependency coverage, allocation-failure cleanup, generated CSS accepted by the stable parser/emitter, and independent differential evidence. Canonical-suite-level evidence is required for any broad upstream compatibility claim.

```bash
zig build test -Doptimize=ReleaseSafe
npm run test:formats
```

- [Current status](/guide/status)
- [CSS grammar compatibility](/guide/css-compatibility)
- [Native CSS Modules subset](/guide/css-modules)
- [Recovery CLI](/guide/recovery-cli)
