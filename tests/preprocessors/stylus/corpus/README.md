# Pinned Stylus conformance corpus

This directory is a reviewed, repository-owned snapshot for the internal
`STYLUS-012` graduation gate. It does not make `.styl` publicly available by
itself.

## Provenance

- Upstream: `stylus/stylus`, the canonical Stylus implementation and official
  integration cases
- Tag: lightweight `0.64.0`
- Revision: `1086c6c1fbd7a7fd0ce9ad94f6cf4a62fc79a6e9`
- Tree: `295654c66ed48ff47a4aeca95b1935edf7a612ba`
- Source archive SHA-256:
  `140a722893f0f05b501a01ce1ff27042b6d7c0769ad746f4b5d04429ec8d429e`
- License: MIT; the exact reviewed upstream text is retained as
  `STYLUS_LICENSE`
- Provider authority: exact npm package `stylus` `0.64.0`

The archive, revision, tree, package manifest, official harness, license,
selection, every copied file, and the complete generated inventory are
checksum-owned. Missing, changed, extra, linked, special, or executable
JavaScript fixture files fail the executable integrity gate. Exact upstream
bytes remain under manifest checksum and inventory ownership; project-authored
metadata, scripts, negative fixtures, and tests remain under normal repository
checks.

## Scope

The official harness exposes 355 paired top-level integration cases. The gate
admits 326 exact CSS successes and adds 20 direct-provider negative integration
cases, for 346 total differentials. The positive corpus spans arithmetic,
at-rules, variables, functions, built-ins, control flow, interpolation,
objects, operators, mixins, extension, selectors, media, keyframes, imports,
recursive globs, package lookup, `@require`, compression, and regressions.
Every official success must match both its upstream CSS and a direct Stylus
0.64.0 render byte-for-byte. Every negative must match direct provider message,
source, line, and column metadata. Eight bounded workers reproduce every
adapter result.

Twenty-nine official cases are explicit non-passing evidence rather than
hidden skips: five require project JavaScript or injected resolver callbacks,
five require the undocumented renderer `prefix` option, and nineteen emit
legacy or intentionally invalid CSS rejected by the independent strict parser.
They remain in the checksum-owned source snapshot and named exclusion ledger,
but are not counted as canonical-language successes. This keeps plugin parity,
undocumented hooks, and invalid generated CSS outside the public claim.

Every admitted CSS result parses with pinned Lightning CSS recovery disabled,
round-trips twice through ZigCSS, and reparses independently. Focused
`adapter.test.mjs` and `imports.test.mjs` independently own options, maps,
cancellation, confinement, aliases, links, encoding, cycles, glob traversal,
depth/count/byte/read limits, file helpers, diagnostic overflow, parser-cache
isolation, and no-partial-CSS behavior.

## Reproduction

Given the checksum-verified official archive extracted at
`/path/to/stylus-0.64.0`:

```bash
node scripts/vendor-stylus-corpus.mjs \
  --source /path/to/stylus-0.64.0 \
  --archive /path/to/stylus-0.64.0.tar.gz \
  --check
```

Use `--write` only for an intentional reviewed refresh. Changes to
`selection.json`, generated files, and `manifest.json` must be committed
together.
