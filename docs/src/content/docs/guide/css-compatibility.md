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
| `at-rules.statements` | At-rules | Preserved | Semicolon forms such as `@charset`, `@import`, and `@namespace`; dependency fetching is out of scope. |
| `at-rules.unknown` | At-rules | Preserved | Unknown or future at-rules and values retain nested components and whitespace-token presence. |
| `errors.invalid-declaration` | Diagnostics | Rejected | A declaration candidate without a top-level colon reports its file, location, and code without partial output. |

## Validation boundary

The independent parser gate proves that emitted bytes are accepted as CSS syntax by a separate browser-oriented parser. It does not yet prove computed-style equivalence in browsers, validate every property grammar, execute imports, or enable transformations. Unknown future at-rules are expected to produce a named Lightning CSS warning while still parsing successfully.

Source-map generation exists in the library pipeline, but the recovery CLI still rejects `--source-map` until its map-file and comment policy is defined. Optimizer, prefixing, browser targeting, critical CSS, preprocessors, CSS Modules, CSS-in-JS, and the public compile service remain outside this grammar matrix.

To run the independent gate after building the compiler:

```bash
npm ci --ignore-scripts
npm run test:compat
```

- [Current status](/guide/status)
- [Recovery CLI](/guide/recovery-cli)
- [Build from source](/guide/build-from-source)
