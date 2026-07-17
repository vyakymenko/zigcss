# Pinned Less conformance corpus

This directory is a reviewed, repository-owned snapshot for the internal
`LESS-012` graduation gate. It does not make `.less` publicly available by
itself.

## Provenance

- Upstream: `less/less.js`, the canonical Less implementation and official
  test data
- Tag: `v4.6.7`; annotated tag object
  `1c14e30ca4a857ebf220c9223a5e71fc2fc1764e`
- Revision: `8ae2cc3bfa79f0718ad6fe5f263a1d6819fe9d5c`
- Tree: `77299b2e4390d6e2b8592d6ca2dbb495189149b1`
- Source archive SHA-256:
  `9c53e2e65ce1b73fb192e735d3b267c590139212bc76b88151ec546793260577`
- License: Apache-2.0; the exact reviewed upstream text is retained as
  `LESS_LICENSE`
- Provider authority: exact npm package `less` `4.6.7`

The root and provider package manifests, archive, tree, license, every selected
file, and the complete generated inventory are checksum-owned. Missing,
changed, extra, linked, or special files fail the executable integrity gate.
Selected upstream fixture bytes are retained verbatim, including intentional
trailing whitespace and blank lines used by parser tests. Repository whitespace
checking excludes only `files/`; the manifest checksum and inventory gate own
those immutable bytes. Project-authored corpus metadata, scripts, and tests
remain under the normal diff checks.

## Scope

The snapshot contains 88 official cases and 217 exact files:

| Outcome | Cases |
|---|---:|
| Exact CSS success | 68 |
| Exact parser/evaluator error | 20 |

The positive matrix spans at-rules, calculations, charsets, colors, comments,
CSS guards and grids, detached rulesets, extension, functions, imports, layers,
lazy evaluation, merge behavior, mixins, namespaces, nesting, operations,
interpolation, property access, rulesets, selectors, strings, variables, and
whitespace. The negative matrix spans parser structure, units, variables,
colors, rulesets, extension, functions, mixins, namespaces, recursion,
at-rules, custom properties, and malformed imports.

`corpus.test.mjs` compares every success or failure directly with canonical
Less 4.6.7. CSS, normalized diagnostics, official formatted errors, and the
complete explicit dependency inventory must agree; canonical `result.imports`
must be a subset because upstream omits some nested reads. Eight bounded
workers must repeat every adapter result exactly. Every successful CSS result
then parses with independent recovery disabled and round-trips twice through
ZigCSS before a second independent parse.

Project JavaScript, user plugins, remote imports, package importers, and
upstream cases that intentionally emit invalid or environment-specific CSS are
outside the default canonical-language boundary. They are not counted as
passing support. Executable extensions remain reserved for the separately
opt-in trusted-project-code package in ADR-012. Focused `adapter.test.mjs` and
`imports.test.mjs` coverage independently owns options, maps, cancellation,
confinement, aliases, links, encoding, cycles, depth/count/byte/read limits,
asset helpers, diagnostic overflow, and no-partial-CSS behavior.

## Reproduction

Given the checksum-verified official archive extracted at
`/path/to/less.js-4.6.7`:

```bash
node scripts/vendor-less-corpus.mjs \
  --source /path/to/less.js-4.6.7 \
  --archive /path/to/less.js-4.6.7.tar.gz \
  --check
```

Use `--write` only for an intentional reviewed refresh. Changes to
`selection.json`, its dependency expectations, generated files, and
`manifest.json` must be committed together.
