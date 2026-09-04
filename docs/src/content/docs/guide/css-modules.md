# Native CSS Modules subset

ZigCSS exposes an experimental, library-only CSS Modules subset through `CompileOptions.syntax = .css_modules`. This surface is deliberately narrower than the broader CSS Modules ecosystem. The CLI and LSP do not expose CSS Modules semantics. A `.module.css` filename is rejected on the default CSS route; an explicit native preprocessor syntax still controls parsing regardless of the filename.

## Library use

```zig
const std = @import("std");
const zigcss = @import("zigcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var result = try zigcss.compile(
        gpa.allocator(),
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
    if (exports.entries.len != 2) return error.UnexpectedExports;
    if (!std.mem.eql(u8, exports.entries[0].name, "card")) return error.MissingCardExport;
    if (!std.mem.eql(u8, exports.entries[1].name, "icon")) return error.MissingIconExport;

    for (exports.entries) |entry| {
        if (entry.value.len == 0) return error.EmptyExportValue;
        // entry.composes owns ordered local, global, or dependency references.
        _ = entry.composes;
    }
}
```

A successful CSS Modules compile always returns non-null `module_exports`, including an owned empty entry slice when no classes or values exist. Class and local-value exports share one unique decoded-name namespace and retain first authored occurrence order across value rules, top-level/nested rules, selector lists, and typed selector pseudos. Repeated classes reuse one generated value; a class/value name collision is a strict error. Ordinary CSS continues to return `module_exports = null`.

Every export name/value and the entry slice belong to `CompileResult`. They remain valid after parser cleanup and explicit `take()`, and one idempotent `CompileResult.deinit()` path releases them with CSS, maps, diagnostics, dependencies, and metrics.

## Composition and module dependencies

The canonical `composes` property is supported only in a style rule whose selector is one plain local class, such as `.button { ... }`. Composition declarations must precede ordinary declarations and are removed from generated CSS after validation. `composes-with`, `!important`, complex/pseudo/explicit-wrapper targets, malformed operands, missing local classes, and local composition cycles return `CSS0009` without partial output.

One declaration may contain multiple decoded identifier names:

```css
.base { color: black; }
.button {
  composes: base;
  composes: reset from global;
  composes: icon label from "./theme.module.css";
  display: grid;
}
```

The `button` export keeps its generated `value` and owns ordered `composes` references. A local reference contains the referenced generated class name; a global reference contains the authored global name; a dependency reference contains the requested export name and decoded quoted module specifier. ZigCSS does not read the filesystem, resolve packages, flatten imported exports, or execute a loader.

Each external composition declaration also adds one result-owned `DependencyKind.css_module` fact, regardless of how many names it references. These facts share the existing dependency count/owned-byte limits with top-level CSS `@import` facts and are sorted by authored span. Repeated declarations remain repeated facts. A combined limit failure discards all dependency facts, exports, and CSS.

## Local values

ZigCSS supports one top-level local definition per rule: `@value <ident>: <component-values>;`. The rule is removed from CSS and contributes an export whose `name` is the decoded identifier and whose `value` is a deterministic component serialization. Outer whitespace is trimmed, whitespace runs collapse to one space, and comments act as safe token separators. Strings and URLs remain opaque; identifiers inside them are never replaced.

Definitions may reference earlier local definitions by an exact decoded identifier token. Definition resolution is intentionally sequential, matching the canonical values pass: a definition does not retroactively resolve a later definition. CSS uses are analyzed after the complete table is collected, so a declaration or supported at-rule prelude may use a value defined later in the file. Exact identifier tokens are replaced recursively inside functions and blocks; property names, function names, strings, URLs, and comments are not scanned.

A local value may stand in for a class selector only when its resolved value is exactly one identifier; hashing and export collection use that resolved class name. Other selector positions are rejected rather than partially substituted. A local value resolving to exactly one string may be used as an external `composes ... from <alias>` path; the dependency and reference store the decoded string. Example:

```css
@value primary: #bf4040;
@value alias: primary;
@value modulePath: "./theme.module.css";
@value selectorName: card;

.selectorName { color: alias; }
.button {
  composes: external from modulePath;
}
```

Imported `@value ... from ...` forms are not accepted because a single-file compile has no owned external value to substitute. Raw ICSS `:import`/`:export` is also outside this subset. Neither form becomes an unresolved token or triggers implicit filesystem/package loading.

## Accepted selector scope

Every authored class selector is local by default. ZigCSS rewrites classes in:

- ordinary and comma-separated style-rule selectors;
- complex selectors and every standard combinator;
- native nested style rules and nested conditional groups;
- typed selector arguments for `:is()`, `:where()`, `:not()`, and `:has()`.

Canonical functional scope wrappers are supported for class selectors. `:local(...)` keeps the enclosed class occurrences local, while `:global(...)` preserves their decoded authored names and does not add exports. The wrapper itself is removed from generated CSS. Scope is occurrence-sensitive, so `:global(.shared), .shared` preserves the first occurrence and scopes the second even though both have the same decoded name.

Each wrapper must contain exactly one inline-safe compound with at least one class. Classes in typed selector pseudos inside that compound inherit the wrapper mode. Bare mode switches, selector lists or combinators inside a wrapper, nested scope wrappers, pseudo-element scope functions, and ID-only or type-leading wrapper arguments return `CSS0009`. This closed functional grammar avoids the ambiguous selector-state behavior of bare `:local` and `:global`.

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

- `:import` and `:export`;
- `composes-with` and any `composes` form outside the composition grammar above;
- imported, duplicate, empty, nested, importance-bearing, or otherwise invalid `@value` forms;
- untyped functional pseudos such as `:nth-child(...)`, `:lang(...)`, and functional pseudo-elements;
- any at-rule outside the allowlist or any raw at-rule block.

Imported-value resolution and raw module-import/export behavior remain outside the chosen `MODULE-002` scope; ZigCSS does not delete, guess, or treat them as ordinary CSS. Invalid values, composition, or explicit-scope forms fail under the same no-partial-output rule. Parser errors similarly produce no CSS. An empty module identity returns `API0001`.

`CssModuleLimits` defaults to 100,000 unique exports, 100,000 composition references, 64 MiB of owned export/reference bytes, a 64 KiB source identity, and 1,000,000 combined class/scope rewrite records. Limit exhaustion returns `CSS0008`, discards all prepared exports, and emits no CSS. Export lookup is hash-based during collection; emission uses source-span-sorted occurrence, wrapper, and declaration-omission arrays with bounded binary lookup.

## Compatible result features

Pretty and minified output, separate source maps, decoded top-level CSS `@import` dependency facts, and measured profiling are supported. Generated and preserved selector mappings are anchored at authored class spans, including classes inside functional scope wrappers. A substituted value maps once to its authored use token; omitted `@value`/`composes` syntax has no fabricated mapping. Generated CSS is reparsed by the stable pipeline and independently canonicalized with recovery-disabled Lightning CSS 1.30.1 in both modes. The format oracle separately recomputes version-1 names, exercises one decoded name in both global and local occurrences, validates composition references against Lightning CSS, and checks local-value fixture projections.

Optimizer, target-prefix, and native-plugin composition are intentionally rejected with `API0001` for this initial subset. Those features can alter or inspect selectors and require their own CSS Modules semantic-composition evidence before admission.

- [Experimental format compatibility](/guide/format-compatibility)
- [Build from source](/guide/build-from-source)
- [Current status](/guide/status)
