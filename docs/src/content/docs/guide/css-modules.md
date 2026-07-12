# Native CSS Modules subset

ZigCSS exposes an experimental, library-only CSS Modules subset through `CompileOptions.syntax = .css_modules`. This surface is deliberately narrower than the broader CSS Modules ecosystem. The recovery CLI and LSP still reject `.module.css`; there is no extension-based fallback to plain CSS.

## Library use

```zig
var result = try zigcss.compile(
    allocator,
    "src/components/card.module.css",
    ".card:is(.icon,.card) { color: red; }",
    .{
        .syntax = .css_modules,
        .format = .minified,
    },
);
defer result.deinit();

if (result.diagnostics.len != 0) return error.InvalidModule;
const exports = result.module_exports orelse return error.MissingModuleExports;
for (exports.entries) |entry| {
    // entry.name is the decoded authored class; entry.value is emitted CSS.
    try useExport(entry.name, entry.value);
}
```

A successful CSS Modules compile always returns non-null `module_exports`, including an owned empty entry slice when no classes exist. Entries are unique by decoded authored class name and retain first occurrence order across top-level rules, nested rules, selector lists, and typed selector pseudos. Repeated classes reuse one generated value. Ordinary CSS continues to return `module_exports = null`.

Every export name/value and the entry slice belong to `CompileResult`. They remain valid after parser cleanup and explicit `take()`, and one idempotent `CompileResult.deinit()` path releases them with CSS, maps, diagnostics, dependencies, and metrics.

## Accepted selector scope

Every authored class selector is local by default. ZigCSS rewrites classes in:

- ordinary and comma-separated style-rule selectors;
- complex selectors and every standard combinator;
- native nested style rules and nested conditional groups;
- typed selector arguments for `:is()`, `:where()`, `:not()`, and `:has()`.

Type, universal, ID, attribute, nesting, non-functional pseudo-class, and pseudo-element selectors are preserved. Forgiving `:is()` and `:where()` lists are emitted from their accepted typed alternatives, so a discarded invalid alternative does not leak unscoped class text.

The initial at-rule allowlist is `@charset`, `@import`, `@namespace`, `@media`, `@container`, `@layer`, `@starting-style`, `@font-face`, `@property`, `@keyframes`, `@-webkit-keyframes`, and `@-moz-keyframes`. Rule blocks recurse and keyframe/descriptor declarations remain ordered. Other at-rules are rejected because an unknown prelude or raw block could contain selector semantics that the adapter cannot safely scope. In particular, `@supports`, `@scope`, `@page`, custom selector definitions, and unknown at-rules are not accepted by this package.

## Deterministic generated names

The non-empty `name` passed to `zigcss.compile` is the module identity. Backslashes are normalized to `/`; all other bytes, including case and repeated path separators, remain significant. A source identity is limited to 64 KiB by default.

Naming algorithm version 1 hashes these unambiguous fields with full SHA-256:

1. the domain separator `zigcss.css-modules.v1` followed by a zero byte;
2. the normalized source-name byte length as little-endian `u64` and its bytes;
3. the decoded authored class-name byte length as little-endian `u64` and its bytes.

The emitted identifier is `_zigcss_<readable>_<digest>`. `<readable>` is at most the first 32 decoded class-name bytes with non-ASCII-alphanumeric, non-hyphen, and non-underscore bytes replaced by `_`; `<digest>` is all 64 lowercase hexadecimal SHA-256 digits. The leading underscore and structural emitter make the result a valid CSS identifier.

The full digest includes both module identity and class name, so the same input is byte-deterministic, slash/backslash spellings agree, and different source identities produce different names absent a SHA-256 collision. Distinct generated values are checked within each compilation; collision evidence returns `CSS9999` with no CSS instead of adding an order-dependent suffix. Changing this algorithm requires a new versioned domain and fixture update.

## Strict errors and limits

The following deferred semantics return one structured `CSS0009` diagnostic and no CSS or partial export map:

- `:local`, `:global`, `:import`, and `:export`;
- `composes` and `composes-with` declarations;
- `@value`;
- untyped functional pseudos such as `:nth-child(...)`, `:lang(...)`, and functional pseudo-elements;
- any at-rule outside the allowlist or any raw at-rule block.

These are owned by `MODULE-002`; ZigCSS does not delete, guess, or treat them as ordinary CSS. Parser errors similarly produce no CSS. An empty module identity returns `API0001`.

`CssModuleLimits` defaults to 100,000 unique exports, 64 MiB of owned export name/value bytes, and a 64 KiB source identity. Limit exhaustion returns `CSS0008`, discards all prepared exports, and emits no CSS. Internal lookup is hash-based during collection and byte-sorted for bounded binary lookup during emission.

## Compatible result features

Pretty and minified output, separate source maps, decoded top-level CSS `@import` dependency facts, and measured profiling are supported. A generated selector mapping is anchored at the authored class selector span; no fabricated per-character source positions are emitted. Generated CSS is reparsed by the stable pipeline and independently canonicalized with recovery-disabled Lightning CSS 1.30.1 in both modes. The format oracle separately recomputes version-1 names with Node's SHA-256 implementation.

Optimizer, target-prefix, and native-plugin composition are intentionally rejected with `API0001` for this initial subset. Those features can alter or inspect selectors and require their own CSS Modules semantic-composition evidence before admission.

- [Experimental format compatibility](/guide/format-compatibility)
- [Build from source](/guide/build-from-source)
- [Current status](/guide/status)
