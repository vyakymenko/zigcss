# ADR-006: Browser target query language and compatibility data

- Status: Accepted
- Date: 2026-07-11
- Owners: ZigCSS prefixing, transform, and release maintainers
- Roadmap: `PREFIX-001`, prerequisite for `PREFIX-002`

## Context

The inherited autoprefixer accepts a browser string list but never interprets it. It applies one hand-written prefix list independently of targets, duplicates some declarations, omits selector and at-rule semantics, and can emit historical forms that are wrong for the requested browsers. The stable CLI currently rejects both `--autoprefix` and `--browsers`, so no accepted option is an output-invariant no-op.

[Browserslist](https://github.com/browserslist/browserslist) defines a broad language containing market-share, recency, region, negation, intersection, configuration discovery, and changing default queries. Implementing a subset under the same name would be misleading, while accepting dynamic queries would make output depend on usage statistics and database update time. ZigCSS therefore uses its own deliberately closed language.

[MDN Browser Compatibility Data](https://github.com/mdn/browser-compat-data) publishes machine-readable support statements with version, prefix, alternative-name, removal, and partial-implementation facts. It is suitable as upstream evidence only when the exact release and selected paths are pinned, reviewed, normalized, and regenerated deterministically.

## Decision

### Query grammar

The library accepts only explicit minimum versions:

```text
query    = target *( optional-whitespace "," optional-whitespace target )
target   = browser optional-whitespace ">=" optional-whitespace version
browser  = "chrome" | "edge" | "firefox" | "safari" | "ios_safari" | "ie"
version  = positive-integer [ "." integer [ "." integer ] ]
```

Browser identifiers are lowercase ASCII and may occur once. Version components are decimal `u16` values; the major component is nonzero and multi-digit components cannot have leading zeroes. Input defaults to 4,096 bytes and six targets, with caller-lowerable limits. Empty queries, unknown browsers, duplicates, extra punctuation, other comparators, ranges, aliases, and dynamic forms such as `last 2 versions`, `> 1%`, `defaults`, or `not dead` are structured failures with byte offsets.

Whitespace around `>=` and commas is representational. Successful queries own only normalized browser/version values, do not borrow input, sort by the closed browser order, and serialize canonically as `browser >= version`. There is no implicit default target. A target means every version of that browser from the stated minimum forward, not one exact release.

This is not Browserslist syntax or configuration discovery. A future language expansion requires an ADR revision, grammar fixtures, deterministic data semantics, and explicit compatibility documentation.

### Generated compatibility data

`data/prefixing/compatibility-source.json` pins `@mdn/browser-compat-data` 8.0.0, upstream Git commit `d256a4fd553dbc52d651d49d8b2eb660b027efe3`, release timestamp, npm SHA-1 and integrity, CC0-1.0 license, selected browsers, and reviewed feature paths. The dependency is exact in `package.json` and `package-lock.json`.

`scripts/generate-prefix-data.mjs` validates the manifest against the installed package metadata and lock integrity, rejects duplicate or malformed selections, unresolved mirrors, unknown/inexact versions, and ambiguous removal intervals, then extracts only the reviewed support statements. It records manifest and normalized-data SHA-256 digests and formats the Zig output through the pinned compiler. `npm run check:prefix-data` is a read-only byte comparison and runs in CI before the main test suite.

The initial table intentionally covers a small cross-category basis for `PREFIX-002`:

- properties: `user-select`, `appearance`, and `backdrop-filter`;
- values: `position: sticky` and `display: flex`;
- selectors: `::placeholder` and `:fullscreen`;
- at-rules: `@keyframes`.

Each statement retains browser, inclusive added version, optional exclusive removed version, standard/prefix/alternative-name form, partial-support state, and whether BCD attaches one or more notes. Note text is neither copied nor interpreted into rewrite authority; an annotated result remains explicit so `PREFIX-002` must decline it unless a dedicated semantic fixture resolves the caveat. Flag-gated statements are rejected. Adding a feature or browser requires a manifest change, regenerated digest, reviewed output, and new `PREFIX-002` semantic fixtures.

### Requirement resolution

For every target, the resolver proves continuous support from the requested minimum forward. At each interval boundary it selects the statement reaching furthest into the future, preferring complete and unannotated support before the standard form on exact ties. Nonstandard forms from the selected chain are deduplicated across browsers. The unprefixed authored form is always retained by the later rewrite pass.

If no known statement covers the current boundary, resolution reports the browser, requested minimum, and first unsupported version instead of guessing. Partial and annotated support remain explicit result facts. Unknown feature IDs and any forged noncanonical query are errors. Resolution is deterministic, bounded, allocation-failure tested, and independent of network or wall-clock state.

### Product boundary

`PREFIX-001` exposes target parsing and compatibility resolution through the Zig library only. It does not register a compatibility rewrite, enable the inherited autoprefixer, or make `--browsers`/`--autoprefix` available. CLI enablement waits for `PREFIX-002` to implement property, value, selector, and at-rule forms with proof-carrying ordering, source maps, independent validation, and materially different target outputs.

## Consequences

- Identical query bytes and a fixed data checkpoint produce identical normalized targets and requirements.
- Invalid or unsupported inputs fail locally with no database lookup or fallback default.
- The supported language is less convenient than Browserslist but does not silently pretend to implement it.
- Compatibility data updates are intentional source changes rather than ambient dependency drift.
- The initial feature/browser surface is incomplete and must not be advertised as general autoprefixing until `PREFIX-002` and later data expansions pass their acceptance suites.

## Rejected alternatives

- **Treat the inherited browser list as advisory.** Rejected because target-invariant output makes the option deceptive.
- **Implement a loose Browserslist subset.** Rejected because accepted syntax and configuration discovery would diverge from the established tool while retaining its name.
- **Use `defaults` or market share.** Rejected because output would vary with time, geography, and database updates without query changes.
- **Copy a hand-written prefix table.** Rejected because it has no version/removal provenance and was the inherited failure mode.
- **Fetch compatibility data during builds.** Rejected because release output must not depend on network state.
