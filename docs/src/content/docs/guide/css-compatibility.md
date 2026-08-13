# CSS grammar compatibility

This is the tested grammar boundary of the experimental recovery compiler. It is not a claim of complete browser compatibility, property-value validation, or production readiness.

Each row maps to a versioned fixture in `tests/compatibility/matrix.json`. For every **Supported** or **Preserved** row, ZigCSS emits both pretty and minified CSS and Lightning CSS 1.30.1 parses both outputs with error recovery disabled. The nesting draft is enabled for the native-nesting fixture. **Rejected** rows must fail in both modes with a structured diagnostic and no CSS output.

## Status meanings

| Status | Meaning |
|---|---|
| Supported | Parsed into typed ZigCSS structure and emitted deterministically. |
| Preserved | Accepted and emitted from lossless component values without a complete typed semantic model. |
| Rejected | Rejected with a structured diagnostic and no CSS output. |

## Matrix

| Feature ID | Area | Status | Tested boundary |
|---|---|---|---|
| `tokens.escapes-and-unicode` | Tokens and syntax | Supported | Unicode identifiers, CSS escapes, strings, URLs, numbers, dimensions, and percentages. |
| `syntax.nested-components` | Tokens and syntax | Supported | Nested functions and `()`, `[]`, and `{}` component blocks do not split outer grammar. |
| `selectors.compounds` | Selectors | Supported | Type, universal, class, ID, compound, and selector-list syntax. |
| `selectors.combinators` | Selectors | Supported | Descendant, child (`>`), next-sibling (`+`), and subsequent-sibling (`~`) combinators. |
| `selectors.namespaces` | Selectors | Supported | Namespace statements and namespace-qualified type, universal, and attribute selectors. |
| `selectors.attributes` | Selectors | Supported | Attribute matchers, quoted or identifier values, namespaces, and `i`/`s` flags. |
| `selectors.functional-pseudos` | Selectors | Supported | `:is()`, `:where()`, `:not()`, `:has()`, pseudo-classes, and pseudo-elements. |
| `selectors.native-nesting` | Selectors | Supported | Explicit `&`, implicit parent references, leading combinators, and nested group rules. |
| `selectors.column-combinator` | Selectors | Rejected | The column combinator is excluded from the selected stable Selectors Level 4 grammar. |
| `declarations.order-and-importance` | Declarations | Supported | Ordered duplicates, fallbacks, and `!important` remain ordered. |
| `declarations.custom-properties` | Declarations | Supported | Case-sensitive names, cascade scopes, fallbacks, cycles, empty values, and token boundaries are retained without static substitution. |
| `declarations.logical-properties` | Declarations | Supported | Flow-relative names and values remain authored under horizontal, RTL, and vertical writing modes; no physical mapping is guessed. |
| `values.property-grammar` | Declarations | Preserved | Property-specific and future values are lossless component trees; broad semantic validation is not claimed. |
| `at-rules.conditional` | At-rules | Supported | Typed `@media`, `@supports`, and named or anonymous `@container` preludes and rule blocks. |
| `at-rules.layers` | At-rules | Supported | `@layer` statements, names, and blocks. |
| `at-rules.descriptors` | At-rules | Supported | Declaration-backed `@property` and `@font-face` blocks. |
| `at-rules.keyframes` | At-rules | Supported | `@keyframes` names, `from`/`to`, percentages, and declaration blocks. |
| `at-rules.page` | At-rules | Supported | `@page` selectors, declarations, and ordered margin at-rules. |
| `at-rules.statements` | At-rules | Preserved | Semicolon forms such as `@charset`, `@import`, and `@namespace`; the API reports decoded top-level string/URL imports in authored order, while dependency fetching remains out of scope. |
| `at-rules.unknown` | At-rules | Preserved | Unknown or future at-rules and values retain nested components and whitespace-token presence. |
| `errors.invalid-declaration` | Diagnostics | Rejected | A declaration candidate without a top-level colon reports its file, location, and code without partial output. |

## Validation boundary

The independent parser gate proves that emitted bytes are accepted as CSS syntax by a separate browser-oriented parser. It does not yet prove computed-style equivalence in browsers, validate every property grammar, execute imports, or by itself authorize a pass or stable CLI option. Unknown future at-rules are expected to produce a named Lightning CSS warning while still parsing successfully.

## Verified optimizer composition

The recovery CLI's `--optimize` flag invokes one closed seven-pass preset over verified order-preserving analysis, cleanup, value, declaration, and rule passes. Compatibility rewriting, extraction, experimental passes, custom-property resolution, logical-to-physical conversion, and reorder authority are excluded. Proof-carrying rewrites can reveal another candidate after emission, so execution is bounded to 32 parse-transform-emit rounds and succeeds only when two consecutive emitted byte sequences match.

The reviewed `verified-optimizer` fixture covers cross-pass math-to-zero and math-to-shorthand candidates, cleanup followed by rule merge, value shortening followed by selector merge, and at-rule merge followed by inner selector merge. It also retains custom-property definitions/substitutions/cycles, importance and fallback order, logical RTL/vertical declarations, unsupported future values, nesting, and non-adjacent rule boundaries. Pretty and minified goldens independently canonicalize to the original with Lightning CSS 1.30.1, the minified form falls from 1,143 to 866 bytes, and optimizing the emitted result is byte-identical. This is representative semantic evidence, not general browser computed-style proof.

## Target compatibility rewrite

A separate `PREFIX-002` acceptance fixture verifies the library-only target pass over the pinned eight-feature subset: `appearance`, `user-select`, `backdrop-filter`, `position: sticky`, `display: flex`, `::placeholder`, `:fullscreen`, and `@keyframes`. Vendor declarations precede the retained standard form; selector variants are separate adjacent rules; prefixed keyframes precede standard keyframes. Layers, media queries, importance, fallback chains, custom properties, logical properties, manual prefixes, unsupported selector shapes, descriptor blocks, and nested declarations are explicit fixture boundaries.

The fixture has reviewed pretty and minified goldens, reparses byte-idempotently, and is independently projected with Lightning CSS 1.30.1 to remove compatibility-only forms before comparison with the original standard semantics. The reviewed legacy target query expands the output, while `chrome >= 120, edge >= 120, firefox >= 120` is exactly transform-free. This evidence is narrower than browser computed-style testing and is not a claim of general autoprefixing.

## Experimental selector extraction matrix

`TREE-001` exposes two library/test-driver modes over an explicit closed selector domain. A non-null inventory category is exhaustive; null means unknown and grants no absence proof. Dead-code mode targets a closed document snapshot. Critical-CSS mode targets a standalone closed selector-matching render tree containing every node that admitted combinators can inspect. Both remain experimental and require separate extraction and experimental policy grants.

| Boundary | Status | Current contract |
|---|---|---|
| Direct class and ID selectors | Supported for extraction | Decoded inventory values are canonicalized and matched conservatively across ASCII case variants. One absent direct requirement proves that selector alternative impossible. |
| Selector lists | Supported conservatively | The whole style rule is omitted only when every alternative is proven impossible; one possible or unknown alternative retains the complete list. |
| Combinators and native nesting | Supported conservatively | Direct class/ID requirements may prove absence, but the caller's closed domain must include every related node matching can inspect. Parent and survivor order is unchanged. |
| Functional pseudo arguments | Preserved | Arguments to `:is()`, `:where()`, `:not()`, `:has()`, and related forms do not grant evidence because their polarity, forgiveness, and relationships differ. Direct requirements outside the function may still prove absence. |
| Type, namespace, and attribute selectors | Preserved | Document-language case, namespace, and attribute semantics are not inferred from CSS or the initial inventory. |
| Imports, layers, descriptors, keyframes, custom-property definitions, and unknown at-rules | Preserved | Dependency-bearing non-style rules are retained. Typed group and possible nested style rules recurse without removing their wrappers. |
| Missing, duplicate, empty-name, or over-limit configuration | Rejected | Invalid inventories produce a structured diagnostic and no CSS. A non-null empty category is valid and means the category is known empty. |
| Dynamic DOM or an inventory that omits selector-related nodes | Unsupported | The proof applies only to the declared closed snapshot/tree. Later DOM mutations or incomplete critical ancestry/relationships require a new inventory. |

The dead-code and critical fixtures share one stylesheet but use different complete inventories. Reviewed pretty/minified goldens preserve custom and logical declarations, layers, media/supports groups, nested styles, functional pseudos, attributes, elements, font faces, and keyframes at the documented boundaries. A separate Lightning CSS visitor independently removes only style rules whose every selector has a direct absent class/ID requirement, then canonicalizes the expected subset. Both modes reduce their transform-free baseline, emit no mappings for extracted rules, reject forged proofs, and remain byte-idempotent after reparse.

Source-map generation exists for ordinary library parse/pass/emit pipelines. The four self-contained native preprocessor frontends compose deterministic maps through the source-built binary and explicit `zigcss.experimental_native` namespace, while the direct native CSS CLI still rejects `--source-map` until its map-file/comment policy is defined. Target/prefix flags, extraction flags, CSS-in-JS, the [experimental library-only CSS Modules subset](/guide/css-modules), and the public compile service remain outside the native CSS grammar/CLI contract. SCSS, Sass, Less, and Stylus have their own exact [format compatibility contract](/guide/format-compatibility) before generated CSS reaches this grammar.

To run the independent gate after building the compiler:

```bash
npm ci --ignore-scripts
npm run test:compat
npm run test:transforms
```

- [Current status](/guide/status)
- [Recovery CLI](/guide/recovery-cli)
- [Build from source](/guide/build-from-source)
