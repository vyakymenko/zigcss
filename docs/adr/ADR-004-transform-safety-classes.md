# ADR-004: Transform safety classes and pass execution

- Status: Accepted
- Date: 2026-07-11
- Owners: ZigCSS transform and validation maintainers
- Roadmap: `PASS-001`, `OPT-010` through `OPT-015`, `VAL-001`, `MATH-001`, `CUSTOM-001`, `LOGICAL-001`, `PREFIX-002`, and `TREE-001`

## Context

The inherited optimizer is one mutable procedure that resolves custom properties globally, removes nodes with order-unstable operations, rewrites logical and shorthand properties without complete context, merges non-adjacent rules, and runs many unrelated transforms whenever optimization is enabled. It has no dependency plan, pass-local contract, maturity state, rollback boundary, or validation hook. Audit fixtures prove that smaller output from this path can change cascade, rule order, writing-mode behavior, fallback chains, and custom-property semantics.

The rebuilt CSS AST is compilation-owned and intentionally exposed through const pointers and slices. A transform system must preserve that ownership model, make every enabled capability explicit, and prevent an experimental pass or dependency from entering a stable plan accidentally.

## Decision

### Immutable pass handoff

- A pass receives a const `RuleList` root and returns either that same root for a no-op or a reconstructed root allocated in the compilation arena.
- In-place mutation, including mutation through `@constCast`, is outside the pass contract. A plan publishes only the final root after every selected pass and validator succeeds.
- Failed candidates may remain arena-allocated until compilation cleanup, but no failed root is returned or installed. This provides a transaction boundary without unsafe partial rollback.
- Persistent AST allocations use the compilation arena. Temporary comparison and validation work uses an explicit caller-provided scratch allocator.
- A lossless-cleanup deletion remains represented as a proof-carrying `omitted_rules` entry on its source `RuleList`. AST validation and emission independently accept only structurally empty style rules and the explicitly authorized empty conditional groups. Experimental extraction instead retains a nonempty authored rule under a zero-output generated proof carrying its complete inventory; an arbitrary omitted source range is invalid in either channel.

### Safety classes

Every pass declares exactly one class:

| Class | Authority |
|---|---|
| `analysis` | Observe the AST only; returning a different root is a manager error. |
| `lossless_cleanup` | Remove only syntax proven semantically inert, without changing surviving order. |
| `semantic_rewrite` | Rewrite typed CSS under a pass-specific equivalence proof. |
| `compatibility_rewrite` | Add or rewrite syntax according to explicit versioned target data. |
| `extraction` | Produce a conservative subset only in an explicit extraction mode. |

Safety classes are not an ordered permission ladder. Policy contains one boolean per class and defaults to verified analysis only. Enabling one class never enables another implicitly. Experimental passes, unsupported nesting, validators, and proven reorder operations each require separate policy authority. Transitive dependencies are subject to the same checks as directly requested passes.

Safety and phase metadata must agree: analysis, cleanup, compatibility, and extraction use their matching phases, while semantic rewrites are confined to value, declaration, or rule phases.

### Metadata and acceptance evidence

Each pass has a stable identifier and revision, phase, deterministic priority, dependency IDs, maturity, safety class, custom/logical-property effects, documented precondition/postcondition/no-op conditions, nesting support, order effect, and acceptance evidence.

A pass marked `verified` is invalid unless it has a validator and evidence for postconditions, idempotence, every allocation failure, and nested rules. Output-changing verified passes additionally require semantic and differential validation. A claimed size reduction requires a size check. A pass that can reorder syntax requires both a written rationale and explicit order-validation evidence; stable policy may still reject it.

These metadata flags record completed evidence. They do not replace the executable fixtures, allocation tests, independent parsing, computed-style checks, or pass-specific proof required by the development plan.

Analysis results are facts rather than latent mutation authority. Duplicate-declaration analysis groups only within one ordered declaration-list segment, matches standard property names ASCII case-insensitively and custom properties case-sensitively, records every importance transition, and treats same-importance chains as potential compatibility fallbacks. It does not nominate a declaration for deletion without later typed property/value evidence.

### Typed numeric prerequisite

Semantic value rewrites depend on one immutable typed numeric layer rather than property-name heuristics. Its grammar, precedence, math constants, and unit taxonomy follow the current [CSS Values and Units Level 4](https://drafts.csswg.org/css-values-4/) Editor's Draft. Dimension maps, percentage hints, addition, multiplication, and inversion follow the [CSS Typed OM Level 1 type algebra](https://www.w3.org/TR/css-typed-om-1/). Container-relative units additionally track [CSS Conditional Rules Level 5](https://drafts.csswg.org/css-conditional/). Executable fixtures freeze the reviewed behavior so a later living-spec change is an intentional update.

The numeric parser validates source ownership and complete nested spans, rejects unterminated or unsupported component trees, and enforces independent instruction, argument, and nesting limits. It produces a caller-owned flat postfix instruction stream with source envelopes and a result type; it never mutates the CSS AST or rewrites output. Dimensionally invalid expressions remain distinguishable from unsupported grammar and operational failures. Context-sensitive percentages receive a caller-supplied hint, while context-relative lengths retain their unit instead of being guessed into pixels.

`VAL-001` supplies type evidence only. Folding, unit conversion, or shortening requires a later verified semantic-rewrite pass with pass-specific compatibility, finite-value, precision, output-equivalence, idempotence, and size evidence. Unknown units, unresolved substitutions such as `var()`, and compound result types therefore default to no rewrite.

### Conservative numeric math folding

`MATH-001` evaluates the postfix evidence with a bounded stack only when every intermediate operation remains finite and can retain one exact authored unit. Addition, subtraction, `min()`, `max()`, and finite `clamp()` bounds require identical units. Multiplication requires a unitless side; division requires a unitless divisor or identical units that cancel. Static cross-unit conversion is deliberately deferred even when `VAL-001` records a conversion factor.

Rewriting is restricted to a complete single `calc()`, `min()`, `max()`, or `clamp()` component in a closed property-specific allowlist. Each property policy declares the accepted numeric category and whether negative results are valid. Custom properties, descriptor blocks, comments, substitutions, unsupported properties, mixed units, non-finite results, ambiguous signed-zero comparisons, invalid ranges, and results that are not strictly shorter all retain the exact input root.

A successful fold stores a finite number, a closed known-unit enum, and the whole math function's causal span as structured AST data. The emitter—not the pass—serializes that data and applies the one-segment mapping contract from `ADR-007`. The verified pass reconstructs only changed declaration/rule paths, preserves order and importance, and validates a second independently computed candidate plus source map. Direct library plans still require explicit semantic-rewrite policy; the stable CLI reaches it only through the closed verified optimizer preset described below.

### Typed color and zero shortening

`OPT-012` recognizes a closed exact subset of [CSS Color Level 4](https://drafts.csswg.org/css-color-4/): 3/4/6/8-digit hexadecimal colors, the standardized basic named-color set and aliases, and `rgb()`/`rgba()` channels that map exactly to 8-bit sRGB. Wider color spaces, contextual/system colors, missing or calculated channels, fractional channels, out-of-range clamping, and non-endpoint alpha values retain authored syntax. The serializer chooses only deterministic lowercase hex or a shorter universally supported basic name.

Compatibility is part of equivalence. Opaque named, hex, and RGB forms may share the older basic-name/hex output surface. A non-opaque `rgba()` or `transparent` value is not changed into alpha-hex without target data because that could raise the browser requirement; only authored alpha-hex may shorten within alpha-hex notation. Color rewriting is further restricted to a closed list of properties whose complete value can be one `<color>`.

CSS Values Level 4 permits a zero `<length>` to omit its unit, but a zero that can also parse as `<number>` must take the number interpretation. Zero shortening therefore accepts only a complete positive-zero length dimension on a closed length-only or length-percentage property list. Percentages, angles, times, signed zero, math functions, custom properties, descriptors, and number-or-length grammars such as `line-height` remain unchanged.

Numeric and color output are variants of one structured generated-value union. A shared bounded immutable traversal covers style/nested declarations, group rules, keyframes, pages, and margin boxes while deliberately skipping declaration-backed descriptors. `OPT-012` requires strict byte reduction, recomputed output/source-map validation, idempotence, allocation-failure coverage, and independent canonical equivalence. Like `MATH-001`, direct library plans require explicit semantic-rewrite policy; stable CLI access is confined to the closed verified optimizer preset.

### Custom-property preservation boundary

[CSS Custom Properties Level 1](https://drafts.csswg.org/css-variables/) makes custom-property names case-sensitive, applies the normal cascade and inheritance per element, preserves arbitrary token streams, and resolves `var()` fallbacks and dependency cycles at computed-value time. A source-only compiler therefore lacks the element, cascade, registration, and computed-value state required for general substitution. `CUSTOM-001` treats custom-property definitions and every declaration containing a decoded `var()` function at any component depth as authored protected values.

The shared value-rewrite traversal never invokes a generator for a protected value and rejects any generated-declaration proof that consumes one. Detection validates source ownership, decodes escaped and case-varied function names, walks nested functions and blocks under an explicit depth limit, and participates in allocation-failure testing. Rule-level proofs may still compose adjacent equivalent contexts because they retain the complete authored declarations and independently prove cascade/order equivalence; they do not resolve or rewrite the protected values.

Pass metadata defaults to `custom_property_effect = preserves`. Static custom-property resolution is confined to an experimental semantic value-pass classification and is rejected unless policy separately authorizes semantic rewriting, experimental maturity, and static resolution. A pass claiming that effect cannot be marked verified under the current ADR. The closed `--optimize` preset contains no such pass and mechanically requires preservation; the inherited global resolver remains on the quarantined legacy optimizer path. Any future resolver requires its own roadmap package, DOM/cascade inputs, validation strategy, and an ADR revision rather than reuse of the default traversal.

### Logical-property preservation boundary

[CSS Logical Properties Level 1](https://drafts.csswg.org/css-logical/) defines flow-relative properties and values whose physical mapping depends on the used `writing-mode`, `direction`, and `text-orientation`. Logical and physical declarations in one property group cascade together according to their relative declaration order after that mapping is known. A source-only property-name table cannot recover the required element, containing-block, inheritance, HTML directionality, or computed-style context and can reverse inline sides under RTL or rotate them under vertical writing modes.

`LOGICAL-001` therefore retains no logical-to-physical conversion mode in the rebuilt pipeline. Pass metadata defaults to `logical_property_effect = preserves`; the reserved `physical_conversion` effect is registry-invalid rather than unlockable through policy. Every pass admitted by the closed stable preset declares preservation, the AST exposes no generated property-name payload, and the stable CLI never calls the inherited optimizer. Typed value-only rewrites may still shorten a value on a logical property when their independent proof leaves the property name, cascade position, importance, and direction-sensitive keyword structure unchanged.

A future conversion proposal must begin with a new roadmap package and ADR revision defining DOM/style inputs, the exact box whose writing mode controls each mapping, interactions between physical and logical declarations, inheritance, target compatibility, source maps, and computed-style validation. A global `ltr`/`rtl` switch is insufficient and is intentionally not part of current policy.

### Adjacent selector-rule merge

`OPT-014` implements only the reverse of expanding one selector list into adjacent style rules with equivalent declaration blocks. [Selectors Level 4](https://drafts.csswg.org/selectors/) assigns a selector list the specificity of its most specific matching selector, so concatenating the two selector lists retains the winning specificity when an element matches one or both alternatives. Because the rules are adjacent in the same rule list, every outside declaration remains before both or after both; layers, scopes, queries, importance, fallback order, and declaration order are unchanged.

Nested style rules are eligible only when both blocks contain declarations and no child rules. This is required by [CSS Nesting Level 1](https://drafts.csswg.org/css-nesting/): a descendant nesting selector derives specificity from its parent rule's selector list, so changing a parent list that owns child rules would require a separate proof. Declaration-only nested siblings keep the same parent selector context and may merge after the same declaration-equivalence check as top-level siblings.

The AST retains both complete authored rules plus ordered non-overlapping proof metadata. Property identity, importance, numeric token type/sign, decoded token text, nested component structure, meaningful whitespace, custom-property token boundaries, and authored value comments are compared before eligibility. The emitter independently repeats that proof before composing typed selectors with the first authored block, and `ADR-007` defines mappings for the retained authored segments and unmapped structural separator. Direct plans require explicit semantic-rewrite policy; the stable CLI reaches this pass only through the closed verified preset.

### Adjacent typed group-rule merge

`OPT-015` is limited to adjacent typed `@media`, `@supports`, `@container`, and named `@layer` rule blocks. [CSS Conditional Rules Level 3](https://drafts.csswg.org/css-conditional-3/) applies the contents of a true conditional group as though they occurred at the group's location, and [CSS Conditional Rules Level 5](https://drafts.csswg.org/css-conditional/) defines `@container` as a conditional group rule. Two adjacent groups of the same kind, nesting mode, and structurally equivalent condition can therefore share one header while their complete child streams remain in source order. Different, untyped, recovered, empty, or non-rule-block contexts remain authored.

[CSS Cascade Level 5](https://drafts.csswg.org/css-cascade-5/) defines identical named layer paths as the same cascade layer and fixes layer order by the first declaration of that name. Combining adjacent blocks with one identical nonempty name retains that first occurrence and concatenates contents without crossing another layer or rule. Anonymous layer occurrences have unique identities and are never merged. Nested named layers are considered only within their existing parent rule list, so a child cannot escape or change parent layer context.

The current independent oracle cannot prove direct declaration runs inside nested conditional groups: Lightning CSS 1.30.1 serializes the two-group input without a required declaration separator. `OPT-015` therefore excludes any candidate block whose immediate child list contains a nested-declarations rule, even though ordinary nested style-rule groups remain eligible. Both authored at-rules remain as proof metadata; the emitter rechecks typed kind, prelude equivalence, layer identity, termination, nesting mode, child shape, adjacency, and source containment before composing the first header with both child streams. Direct plans require explicit semantic-rewrite policy; the stable CLI reaches this pass only through the closed verified preset.

### Conservative selector extraction

`TREE-001` replaces the inherited token-presence heuristic with two explicit experimental extraction modes: `conservative-dead-code-extraction` and `conservative-critical-css-extraction`. [Selectors Level 4](https://drafts.csswg.org/selectors/) evaluates selectors against an element tree whose class, ID, type, namespace, and attribute semantics can depend on the document language. [CSS Nesting Level 1](https://drafts.csswg.org/css-nesting/) further makes nested selectors relative to their parent selector context. A source-only stylesheet cannot infer that tree, runtime DOM mutations, shadow boundaries, pseudo state, or selector relationships.

The caller must therefore provide at least one non-null complete category. A class or ID slice is an exhaustive decoded inventory for the declared domain; null means unknown and grants no absence proof, while a non-null empty slice means the category is known empty. Dead-code mode requires a closed document snapshot. Critical mode requires a closed selector-matching render tree containing the selected subjects and every ancestor, sibling, descendant, or other node that admitted combinators can inspect. It is not sound to pass only a list of aesthetically “critical” names from a larger live DOM.

Inventories are deeply owned, byte/count/depth/rule/proof bounded, deterministically sorted, and duplicate-free under conservative ASCII folding. Class comparisons retain ASCII case variants because Selectors requires quirks-mode class matching to be ASCII case-insensitive. The initial matrix uses only direct positive class and ID simple selectors. Type and attribute selectors remain authored because their case and namespace behavior depends on the document language. Functional pseudo arguments remain authored because `:is()`, `:where()`, `:not()`, `:has()`, and related forms have positive, negative, forgiving, or relational semantics. A direct class or ID outside those arguments can still prove its containing complex selector impossible.

A style rule produces zero output only when every selector-list alternative contains at least one such required token absent from a complete category. One possible or unknown alternative retains the whole rule. Traversal recurses through typed group and nested style rules, but imports, layers, descriptors, custom-property definitions, keyframes, unknown at-rules, and every other dependency-bearing non-style rule remain present. Existing generated-rule ranges are protected from overlapping extraction proofs, and all survivors remain in source order.

The AST retains each extracted authored style rule plus the canonical inventory and mode in a closed zero-output proof. The emitter independently re-runs selector impossibility analysis before omitting bytes; forged proofs fail, removed rules receive no source-map segment, and reparsed output is byte-idempotent. Lightning CSS 1.30.1 independently applies the same published matrix through a separate selector visitor for both reviewed modes. Invalid, incomplete, duplicate, or over-limit inventories fail without CSS output.

Both passes remain `experimental` even after their package acceptance suite. A plan must separately grant `allow_extraction` and `allow_experimental`; neither pass is registered in the stable CLI, and the inherited optimizer is never called. Dynamic DOM use, element/attribute inventories, functional-pseudo reasoning, dependency pruning, selector removal within a retained list, and browser computed-style validation require later matrix expansions rather than inference.

### Deterministic planning

- Requested passes include their transitive dependencies.
- Duplicate IDs, duplicate requests/dependencies, missing dependencies, cycles, later-phase dependencies, invalid metadata, and registries over the fixed pass limit are errors.
- Ready passes are ordered by phase, then numeric priority, then stable identifier. Registration order and request order cannot change the plan.
- A plan borrows pass definitions and user data and owns only its ordered pointer slice. Those borrowed definitions must outlive plan execution.

### Validation lifecycle

The manager invokes pass-specific validation at precondition and postcondition boundaries. Tests and nightly gates may request an additional second pass execution; its result is checked through the idempotence hook and discarded rather than replacing the first accepted output.

Plans refuse recovered inputs that already contain error diagnostics and abort if a pass or validator introduces an error diagnostic. Diagnostics appended by a failed plan are rolled back to the pre-plan checkpoint; warnings from a fully successful plan may remain. The manager always checks that roots remain bound to the compilation source and satisfy the root `RuleList` invariant. Deeper semantic obligations remain pass-specific and are enforced through required validators. An analysis pass is also mechanically prevented from returning another root.

### Stable verified optimizer preset

Milestone 3 enables `--optimize` through one static `verified-optimizer` registry containing only `duplicate-declaration-analysis`, `empty-rule-cleanup`, `numeric-math-folding`, `typed-color-zero-shortening`, `margin-shorthand-synthesis`, `adjacent-at-rule-merge`, and `adjacent-selector-rule-merge`. The analysis pass enters through the shorthand dependency edge. Every definition is verified, recursively nested, order-preserving, validator-backed, and acceptance-gated. Policy grants only lossless cleanup and semantic rewriting. Compatibility rewrites, extraction, experimental maturity, proven reorder, custom-property resolution, and logical-to-physical conversion have no registry path into this preset.

Proof-carrying generated nodes intentionally prevent overlapping rewrites within one AST snapshot. A single ordered plan can therefore expose a new safe candidate after emission—for example math folding followed by unitless-zero shortening, value shortening followed by selector merge, or at-rule merge followed by an inner selector merge. The CLI and public preset helper close that composition gap with at most 32 parse-transform-emit rounds and stop only after two consecutive emitted byte sequences are identical. Every round reparses without recovery, runs the same validators, preserves the no-partial-output boundary, and remains allocation-failure tested. The combined reviewed fixture independently canonicalizes against the original with Lightning CSS and covers importance, fallbacks, custom properties, logical directions, unsupported values, nesting, layers/groups, cross-pass candidates, exact order, size reduction, and repeated byte stability.

The fixed-point helper deliberately accepts an emission mode but no source-map option. Reparse rounds create intermediate authored snapshots, so a map back to the original input requires a future composed-map proof. The recovery CLI already rejects `--source-map`; ordinary single-plan library calls retain the per-pass source-map contracts in `ADR-007`.

`PASS-001` itself did not connect any inherited optimizer function. The stable flag now invokes only this rebuilt closed preset, and target prefixing plus both extraction modes remain separately authorized surfaces.

## Consequences

Positive consequences:

- Pass selection is auditable, deterministic, and deny-by-default.
- A failed pass or validator cannot publish a partially transformed root.
- Experimental dependencies cannot hitchhike into a verified stable plan.
- Passes can share compilation ownership while validation avoids permanently consuming arena storage.
- Idempotence, nesting, allocation, semantic, differential, order, and size evidence are visible before enablement.

Costs and constraints:

- Reconstructing changed paths uses more temporary arena memory than unrestricted in-place mutation.
- Proof-carrying cleanup omissions and extraction proofs retain small unreachable-rule paths until compilation cleanup instead of reducing the AST to unauditable deleted byte ranges.
- Each pass needs dedicated recursive traversal and validation rather than access to a monolithic optimizer.
- Constness is a contract rather than a language-enforced guarantee against malicious `@constCast`; code review and tests must reject such implementations.
- Structural equivalence alone is insufficient for every cleanup or rewrite, so some validators require browser computed-style or domain-specific cascade proofs.

## Rejected alternatives

- **Wrap the inherited optimizer as one pass.** Rejected because it preserves the unsafe coupling and supplies no pass-specific evidence or rollback boundary.
- **Treat safety classes as an ordinal maximum.** Rejected because authority for cleanup must not silently authorize semantic, target-dependent, or extraction behavior.
- **Mutate the shared AST and undo on error.** Rejected because complete rollback across arena allocations, slices, and nested structures is fragile and difficult to verify.
- **Trust registration order.** Rejected because unrelated refactors would change output and dependency behavior.
- **Mark a pass verified from metadata alone.** Rejected because metadata records evidence; executable acceptance suites remain authoritative.
