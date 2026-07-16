# Pinned Sass conformance corpus

This directory is a reviewed, repository-owned snapshot used by the internal
`SASS-012` graduation gate. It does not make SCSS or indented Sass publicly
available by itself.

## Provenance

- Upstream: `sass/sass-spec`, the official Sass language test suite
- Revision: `1b03109a6205c8cff146defeae8488094b147c88`
- Tree: `2e2c5127e220ccc6fc1cbeef7b74f79fbadcb32c`
- Archive SHA-256: `a7918374582d19cb4e403411a888c91499a7286f021b6f91278219f471b76790`
- License: MIT; the reviewed upstream text is retained as `SASS_SPEC_LICENSE`
- Provider authority: exact `sass` `1.101.0`, Dart Sass tag commit
  `63b9922f5ddbf34bc742b50949e0ee5c47f4686d`

The Sass-spec revision is the last official commit at the Dart Sass `1.101.0`
tag timestamp. Both commits cover the same upstream package-import behavior.
Every selected virtual file has its byte length and SHA-256 recorded in
`manifest.json`; the test gate rejects missing, changed, extra, linked, or
special files.

## Scope

The snapshot contains 80 cases:

| Syntax | Success | Error |
|---|---:|---:|
| SCSS | 41 | 13 |
| Indented Sass | 19 | 7 |

The selection spans variables and scope, operators, interpolation, control
flow, functions, mixins, extension, selectors, lists, maps, numbers, units,
strings, colors, calculations, custom properties, keyframes, built-in modules,
`@use`, `@forward`, `meta.load-css`, legacy `@import`, warnings, parser errors,
semantic errors, and indented-syntax whitespace behavior. The focused
`adapter.test.mjs` and `imports.test.mjs` suites independently own protocol,
option, source-map, cancellation, confinement, ambiguity, cycle, encoding,
filesystem, and depth-limit cases.

`corpus.test.mjs` compiles every case directly with the exact canonical provider
and through the ZigCSS adapter. It compares provider CSS bytes, Sass-spec
expectations under the official newline normalization, normalized diagnostics,
and dependency order. It then repeats all outcomes with eight bounded workers.
Every successful provider result must parse and emit idempotently through the
stable ZigCSS CSS compiler and parse independently with error recovery disabled.

Executable custom functions, user importers, package importers, and plugins are
not part of the default canonical-language boundary. They remain reserved for
the separately opt-in trusted-project-code package in ADR-012.

## Reproduction

Given the checksum-verified upstream archive extracted at `/path/to/sass-spec`:

```bash
node scripts/vendor-sass-spec-corpus.mjs \
  --source /path/to/sass-spec \
  --archive /path/to/sass-spec-1b03109a.tar.gz \
  --check
```

Use `--write` only for an intentional, reviewed corpus refresh. Selection
changes belong in `selection.json`; generated case bytes and `manifest.json`
must be committed together.
