# ADR-006: Browser target query language and compatibility data

- Status: Accepted
- Date: 2026-07-11
- Owners: ZigCSS prefixing, transform, and release maintainers
- Roadmap: `PREFIX-001`, `PREFIX-002`

## Context

The inherited autoprefixer accepts a browser string list but never interprets it. It applies one hand-written prefix list independently of targets, duplicates some declarations, omits selector and at-rule semantics, and can emit historical forms that are wrong for the requested browsers. At adoption time the stable CLI rejected both `--autoprefix` and `--browsers`, ensuring no accepted option was an output-invariant no-op while the replacement accumulated evidence.

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

### Prefix rewrite contract

`PREFIX-002` registers one verified `compatibility_rewrite` pass for the eight reviewed features. It consumes an explicit `Configuration` built from the canonical query and pinned data, then stores only closed property, value, selector, or at-rule forms in proof-carrying AST nodes. The emitter independently validates each proof and serializes known syntax; the pass cannot inject raw CSS bytes.

Each feature is resolved per target. Complete, unannotated statements may contribute a required form. Partial or annotated statements remain visible as conservative facts but do not authorize output, and an unsupported interval is recorded rather than guessed. Forms from other targets can still be emitted when independently proven safe. A query requiring no reviewed legacy form returns the exact input root.

Compatibility declarations are emitted immediately before the retained authored standard declaration, preserving declaration-list position, fallback order, and `!important`. This standard-last ordering follows the [CSS Cascade rule that the last declaration in document order wins](https://drafts.csswg.org/css-cascade-5/#cascade-order). Selector variants are emitted as separate adjacent style rules rather than combined with the standard selector: ordinary style rules use unforgiving selector lists, where an invalid selector invalidates the list, as defined by [Selectors Level 4](https://drafts.csswg.org/selectors/#invalid). Prefixed keyframes are complete adjacent clones followed by the authored standard `@keyframes` rule.

Selector eligibility is intentionally narrow: every selector in the list must contain exactly one direct `::placeholder` or `:fullscreen`, and functional or mixed compatibility selector lists remain authored. Any manual vendor form in the same declaration or rule list makes that feature a list-level no-op, preventing duplication and avoiding a guess about the author's fallback policy. Descriptor blocks, page contexts, supports conditions, custom-property definitions, unsupported values, recovered syntax, and conflicting or already-generated proofs are not rewritten. `var()` consumers may be copied only byte-for-byte as fallbacks; they are never resolved or substituted.

Generated segments follow `ADR-007`: each has one causal authored span, no fabricated inner precision, and deterministic maps. Validators recompute the candidate, standard-semantic equivalence, emitted CSS, source map, and second-run idempotence. Reviewed pretty and minified fixtures are also projected independently through Lightning CSS 1.30.1; legacy targets add required forms while a modern query produces exact transform-free output.

### Product boundary

`PREFIX-001` and `PREFIX-002` first exposed target parsing, compatibility resolution, and the verified rewrite through the Zig library and test-only pass driver without enabling the inherited autoprefixer. The later source-built CLI and native Zig API promotion fulfills the separate public-routing gate: `--autoprefix` and `--browsers <query>` require each other, the CLI parses one owned canonical query before dispatch and borrows it immutably across file, stdin, watch, and bounded batch work, malformed input reports its byte offset and failure kind, and only the rebuilt verified pass receives compatibility-rewrite authority. Native preprocessor frontends complete before optional fixed-point optimization, which completes before prefixing. Prefixing composes with deterministic source maps when optimization is absent; optimizer-plus-map remains rejected before input work.

## Consequences

- Identical query bytes and a fixed data checkpoint produce identical normalized targets and requirements.
- Invalid or unsupported inputs fail locally with no database lookup or fallback default.
- The supported language is less convenient than Browserslist but does not silently pretend to implement it.
- Compatibility data updates are intentional source changes rather than ambient dependency drift.
- The initial feature/browser surface remains incomplete despite the verified rewrite and must not be advertised as general autoprefixing; every data expansion needs reviewed semantic fixtures and the same acceptance suite.
- Legacy and modern target queries materially and deterministically differ only where the pinned evidence grants a closed form.
- The source-built CLI admits the flags only as a paired explicit query and verified rewrite; it never falls back to the inherited target-invariant autoprefixer.

## Rejected alternatives

- **Treat the inherited browser list as advisory.** Rejected because target-invariant output makes the option deceptive.
- **Implement a loose Browserslist subset.** Rejected because accepted syntax and configuration discovery would diverge from the established tool while retaining its name.
- **Use `defaults` or market share.** Rejected because output would vary with time, geography, and database updates without query changes.
- **Copy a hand-written prefix table.** Rejected because it has no version/removal provenance and was the inherited failure mode.
- **Fetch compatibility data during builds.** Rejected because release output must not depend on network state.
