# Experimental format compatibility

ZigCSS currently supports only CSS through its public compile API and recovery CLI. Every inherited alternate-format adapter is **Unavailable**: the CLI rejects its extension with exit status `2` before creating output, and the public `Syntax` enum has no matching tag. Internal legacy code and positive prototype tests are characterization evidence, not a supported subset or upstream compatibility claim.

The machine-readable authority is `tests/formats/matrix.json`. `npm run test:formats` checks every remaining legacy source and format tag, proves files recorded as removed are absent, matches ADR-005, and exact-tests nine extension probes against the real executable.

## Status and strategy meanings

| Term | Meaning |
|---|---|
| Unavailable | Rejected by the recovery CLI before output and absent from the public compile syntax enum. |
| Unverified | Legacy characterization is not a compatibility contract or supported subset. |
| LegacyCharacterized | Heuristic adapter source remains only behind the test-only legacy boundary. |
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
| `css-modules` | `.module.css` | Unavailable | Unverified | LegacyCharacterized | `limited-native-subset` | `MODULE-001`, `MODULE-002` |
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
| CSS Modules | Rewrites encountered legacy-AST class selectors with a name-only FNV-1a suffix. | Names are not file-specific, no export map is returned, and local/global scope, composition, values, dependencies, nested coverage, and collision policy are absent. |
| CSS-in-JS | Scans backticks and object-like braces, deletes interpolation expressions, and parses remaining bytes as CSS. | It has no JavaScript/TypeScript lexer or AST, cannot identify valid tagged templates safely, and deletes dynamic semantics rather than rejecting them. |
| PostCSS-like | Byte-scans `@apply` and skips selected at-rules before legacy CSS parsing. | `@custom-media` and `@nest` may disappear, and there is no JavaScript plugin discovery, configuration, ordering, lifecycle, dependency, or map contract. |
| Tailwind-like | Expands whitespace-separated names from a fixed in-memory utility table inside the PostCSS-like scanner. | Unknown utilities are omitted; content scanning, configuration, versions, variants, plugins, arbitrary values, ordering, and canonical Tailwind semantics are absent. |

## Accepted direction

ADR-005 chooses removal until a dedicated program is funded for SCSS/Sass, Less, Stylus, CSS-in-JS, PostCSS-like behavior, and Tailwind-like behavior. `SCSS-001`, `LESS-001`, and `STYLUS-001` have deleted their heuristic parser sources and legacy dispatch tags while retaining explicit CLI/LSP rejection. “Removal” means no public syntax tag, CLI option, package claim, or fallback to CSS. Verified native transforms keep ZigCSS-specific names rather than borrowing PostCSS or Tailwind branding.

CSS Modules is the one accepted limited-native direction. `MODULE-001` must first produce file-specific deterministic names and owned export mappings. `MODULE-002` may then add an explicitly bounded grammar for local/global scope, composition, values, and dependencies. Any construct outside that published grammar must fail with a structured diagnostic and no partial CSS.

No adapter may graduate on positive examples alone. Admission requires strict negative behavior, strings/comments that cannot corrupt URLs or quoted text, fixture and dependency coverage, allocation-failure cleanup, generated CSS accepted by the stable parser/emitter, and independent differential evidence. Canonical-suite-level evidence is required for any broad upstream compatibility claim.

```bash
zig build -Doptimize=ReleaseSafe
npm run test:formats
```

- [Current status](/guide/status)
- [CSS grammar compatibility](/guide/css-compatibility)
- [Recovery CLI](/guide/recovery-cli)
