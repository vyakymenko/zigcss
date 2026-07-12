# ADR-005: Experimental format and preprocessor strategy

- Status: Accepted
- Date: 2026-07-12
- Owners: ZigCSS parser, public API, and adapter maintainers
- Roadmap: `FMT-001`, governing `SCSS-001`, `SCSS-002`, `LESS-001`, `STYLUS-001`, `MODULE-001`, `MODULE-002`, `JS-001`, `POSTCSS-001`, and `TAILWIND-001`

## Context

The inherited prototype contains ad hoc SCSS, indented Sass, Less, Stylus, CSS Modules, CSS-in-JS, PostCSS-like, and Tailwind-like implementations. They preprocess bytes into the legacy CSS parser with heuristics rather than implementing the source language's lexical, scope, module, dependency, evaluation, and diagnostic contracts. Some paths intentionally strip imports or directives, skip expressions, ignore unknown utility names, or rewrite every class without producing an export map. Their small positive tests do not establish compatibility with canonical implementations.

At the `FMT-001` decision point, the recovery CLI rejected every alternate extension before reading or writing files and the public `CompileOptions.Syntax` enum admitted only CSS. That containment remains the default until an adapter has its own exact contract, strict negative behavior, dependency model, generated-CSS validation, and ownership rules. A legacy parser continuing to compile in test-only code is not a supported language surface. `MODULE-001` subsequently met that threshold for one explicitly named library-only CSS Modules subset; it did not change the CLI/LSP boundary.

The roadmap originally reserved ADR-005 for this decision. The native-plugin contract created during `API-003` used that provisional number, so it is renumbered to ADR-011 rather than leaving two decisions with one durable identifier.

## Decision

### Common admission policy

- Every adapter remains unavailable from the stable CLI. Public compile-facade exposure requires its owning package to satisfy the exact subset's admission criteria; it does not imply CLI or ecosystem graduation.
- Unsupported syntax must produce a structured diagnostic and no partial CSS. Deletion, guessed substitution, vacuous success, and fallback to plain CSS are not compatibility behavior.
- An admitted adapter must use the rebuilt source/token/component/typed-CSS pipeline or a version-pinned canonical implementation boundary. It must not feed transformed bytes into the inherited parser.
- Filesystem dependencies are facts and explicit inputs. No adapter may perform implicit network access, package installation, arbitrary process execution, or unbounded recursive loading.
- Fixture, negative, dependency, allocation-failure, generated-CSS, and independent differential evidence is required. Canonical-suite-level evidence is required before any claim broader than an explicitly named native subset.
- Source maps, module exports, diagnostics, and dependency paths follow the public result ownership contract. A feature with no truthful representation in that result stays unavailable.

### Per-adapter strategy

| Adapter ID | Strategy | Decision |
|---|---|---|
| `scss` | `remove-until-funded` | Remove the heuristic native implementation from product paths. Full SCSS requires lexical scoping, modules/imports, interpolation, strings/comments, arithmetic, control flow, and canonical error behavior; a future program may integrate a version-pinned canonical Sass implementation under a new decision. |
| `sass` | `remove-until-funded` | Treat indented Sass as the same language family and compatibility authority as SCSS. The line/indent converter is not a separate supported subset and will not be admitted independently. |
| `less` | `remove-until-funded` | Remove the byte-substitution implementation from product paths. A future limited subset or canonical integration requires a new scoped decision and differential suite. |
| `stylus` | `remove-until-funded` | Remove the indentation/variable heuristic from product paths. Stylus's optional punctuation and expression semantics are not inferred from line shape. |
| `css-modules` | `limited-native-subset` | Build a clearly named native subset through `MODULE-001` and `MODULE-002`: file-specific deterministic names, owned export mappings, explicit local/global scope, composition, values, and dependency behavior. Everything outside the published subset is a strict error. |
| `css-in-js` | `remove-until-funded` | Remove byte scanning and expression deletion. Any future extraction requires an actual version-pinned JavaScript/TypeScript parser, a non-executing static contract, and explicit handling for dynamic expressions; arbitrary JavaScript evaluation is out of scope. |
| `postcss` | `remove-until-funded` | Remove the PostCSS name from the fixed byte-rewrite adapter. Verified native transformations remain ZigCSS passes, not PostCSS plugins. A real JavaScript plugin host would require a separate isolation, lifecycle, configuration, and compatibility program. |
| `tailwind` | `remove-until-funded` | Remove the Tailwind name from the fixed utility registry and `@apply` scanner. It does not implement canonical content scanning, configuration, variants, plugins, arbitrary values, or versioned utility semantics. A finite ZigCSS preset may be proposed later under its own non-Tailwind name and exact table. |

`MODULE-001` implements the first CSS Modules slice through the rebuilt typed pipeline: local-by-default authored classes, versioned source-specific SHA-256 names, owned first-seen export entries, bounded metadata, source maps, strict deferred-syntax diagnostics, and no optimizer/prefix/plugin composition. The former FNV legacy parser and `Format.css_modules` dispatch are removed. `MODULE-002` adds occurrence-sensitive functional scope, plain-local-class composition with owned references, and sequential local `@value` definitions with token-aware declaration/at-rule/class use replacement. External composition produces facts and never loads or resolves; imported values, ambiguous bare scope, and raw ICSS import/export remain rejected.

`remove-until-funded` means no public syntax tag, CLI option, package claim, or silent fallback. Owning packages may delete legacy code immediately or retain it temporarily behind the existing test-only boundary while adding regressions that prevent reachability. It does not promise a future integration.

`limited-native-subset` is not a compatibility claim for the complete upstream ecosystem. The subset name, grammar, outputs, errors, and dependencies must be machine-readable and independently tested before exposure.

## Consequences

Positive consequences:

- The stable CSS compiler is not delayed by unrelated ecosystem emulation and cannot silently corrupt alternate-language input.
- Each future adapter has one explicit compatibility authority and an evidence threshold proportionate to its semantics.
- CSS Modules can evolve through the existing owned result and dependency model without implying Sass, JavaScript, PostCSS, or Tailwind compatibility.
- Existing verified ZigCSS passes keep their precise names and policies instead of borrowing ecosystem brands.

Costs and constraints:

- Existing prototype adapter tests become characterization only and cannot be cited as support.
- Users needing preprocessors must run their established tool before ZigCSS unless a later admitted adapter says otherwise.
- Removing or renaming inherited code may be disruptive to undocumented internal consumers; no stable API promised those modules.
- Canonical integrations, if later proposed, must address tool discovery, version pinning, process isolation, dependency capture, reproducibility, and offline behavior.

## Rejected alternatives

- **Ship every inherited adapter as experimental best effort.** Rejected because an experimental label does not make deletion, guessed parsing, or corrupted strings safe.
- **Call positive unit examples a limited subset.** Rejected because a subset requires a closed grammar and strict errors outside it, not merely a list of examples that happened to parse.
- **Fallback to CSS when preprocessing fails.** Rejected because the same bytes can have different meanings and fallback can emit plausible but incorrect output.
- **Treat fixed rewrites as PostCSS or Tailwind compatibility.** Rejected because neither a JavaScript plugin lifecycle nor canonical Tailwind compilation semantics exists.
- **Evaluate CSS-in-JS expressions.** Rejected because executing untrusted application code is outside the compiler's security and reproducibility boundary.
