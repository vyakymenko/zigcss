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
- A deleted rule remains represented as a proof-carrying `omitted_rules` entry on its source `RuleList`. AST validation and emission independently accept only structurally empty style rules and the explicitly authorized empty conditional groups; an arbitrary omitted source range is invalid.

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

Each pass has a stable identifier and revision, phase, deterministic priority, dependency IDs, maturity, safety class, documented precondition/postcondition/no-op conditions, nesting support, order effect, and acceptance evidence.

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

A successful fold stores a finite number, a closed known-unit enum, and the whole math function's causal span as structured AST data. The emitter—not the pass—serializes that data and applies the one-segment mapping contract from `ADR-007`. The verified pass reconstructs only changed declaration/rule paths, preserves order and importance, validates a second independently computed candidate plus source map, and remains available only through explicit semantic-rewrite policy and the test driver. It is not registered in the stable CLI.

### Typed color and zero shortening

`OPT-012` recognizes a closed exact subset of [CSS Color Level 4](https://drafts.csswg.org/css-color-4/): 3/4/6/8-digit hexadecimal colors, the standardized basic named-color set and aliases, and `rgb()`/`rgba()` channels that map exactly to 8-bit sRGB. Wider color spaces, contextual/system colors, missing or calculated channels, fractional channels, out-of-range clamping, and non-endpoint alpha values retain authored syntax. The serializer chooses only deterministic lowercase hex or a shorter universally supported basic name.

Compatibility is part of equivalence. Opaque named, hex, and RGB forms may share the older basic-name/hex output surface. A non-opaque `rgba()` or `transparent` value is not changed into alpha-hex without target data because that could raise the browser requirement; only authored alpha-hex may shorten within alpha-hex notation. Color rewriting is further restricted to a closed list of properties whose complete value can be one `<color>`.

CSS Values Level 4 permits a zero `<length>` to omit its unit, but a zero that can also parse as `<number>` must take the number interpretation. Zero shortening therefore accepts only a complete positive-zero length dimension on a closed length-only or length-percentage property list. Percentages, angles, times, signed zero, math functions, custom properties, descriptors, and number-or-length grammars such as `line-height` remain unchanged.

Numeric and color output are variants of one structured generated-value union. A shared bounded immutable traversal covers style/nested declarations, group rules, keyframes, pages, and margin boxes while deliberately skipping declaration-backed descriptors. `OPT-012` requires strict byte reduction, recomputed output/source-map validation, idempotence, allocation-failure coverage, and independent canonical equivalence. Like `MATH-001`, it is exposed only through explicit semantic-rewrite policy and the test driver, not the stable CLI.

### Adjacent selector-rule merge

`OPT-014` implements only the reverse of expanding one selector list into adjacent style rules with equivalent declaration blocks. [Selectors Level 4](https://drafts.csswg.org/selectors/) assigns a selector list the specificity of its most specific matching selector, so concatenating the two selector lists retains the winning specificity when an element matches one or both alternatives. Because the rules are adjacent in the same rule list, every outside declaration remains before both or after both; layers, scopes, queries, importance, fallback order, and declaration order are unchanged.

Nested style rules are eligible only when both blocks contain declarations and no child rules. This is required by [CSS Nesting Level 1](https://drafts.csswg.org/css-nesting/): a descendant nesting selector derives specificity from its parent rule's selector list, so changing a parent list that owns child rules would require a separate proof. Declaration-only nested siblings keep the same parent selector context and may merge after the same declaration-equivalence check as top-level siblings.

The AST retains both complete authored rules plus ordered non-overlapping proof metadata. Property identity, importance, numeric token type/sign, decoded token text, nested component structure, meaningful whitespace, custom-property token boundaries, and authored value comments are compared before eligibility. The emitter independently repeats that proof before composing typed selectors with the first authored block, and `ADR-007` defines mappings for the retained authored segments and unmapped structural separator. The pass remains available only through explicit semantic-rewrite policy and the test driver.

### Deterministic planning

- Requested passes include their transitive dependencies.
- Duplicate IDs, duplicate requests/dependencies, missing dependencies, cycles, later-phase dependencies, invalid metadata, and registries over the fixed pass limit are errors.
- Ready passes are ordered by phase, then numeric priority, then stable identifier. Registration order and request order cannot change the plan.
- A plan borrows pass definitions and user data and owns only its ordered pointer slice. Those borrowed definitions must outlive plan execution.

### Validation lifecycle

The manager invokes pass-specific validation at precondition and postcondition boundaries. Tests and nightly gates may request an additional second pass execution; its result is checked through the idempotence hook and discarded rather than replacing the first accepted output.

Plans refuse recovered inputs that already contain error diagnostics and abort if a pass or validator introduces an error diagnostic. Diagnostics appended by a failed plan are rolled back to the pre-plan checkpoint; warnings from a fully successful plan may remain. The manager always checks that roots remain bound to the compilation source and satisfy the root `RuleList` invariant. Deeper semantic obligations remain pass-specific and are enforced through required validators. An analysis pass is also mechanically prevented from returning another root.

`PASS-001` does not enable `--optimize` or connect any inherited optimizer function. CLI enablement begins only when one rebuilt pass independently satisfies the acceptance template.

## Consequences

Positive consequences:

- Pass selection is auditable, deterministic, and deny-by-default.
- A failed pass or validator cannot publish a partially transformed root.
- Experimental dependencies cannot hitchhike into a verified stable plan.
- Passes can share compilation ownership while validation avoids permanently consuming arena storage.
- Idempotence, nesting, allocation, semantic, differential, order, and size evidence are visible before enablement.

Costs and constraints:

- Reconstructing changed paths uses more temporary arena memory than unrestricted in-place mutation.
- Proof-carrying omissions retain small unreachable-rule paths until compilation cleanup instead of reducing the AST to unauditable deleted byte ranges.
- Each pass needs dedicated recursive traversal and validation rather than access to a monolithic optimizer.
- Constness is a contract rather than a language-enforced guarantee against malicious `@constCast`; code review and tests must reject such implementations.
- Structural equivalence alone is insufficient for every cleanup or rewrite, so some validators require browser computed-style or domain-specific cascade proofs.

## Rejected alternatives

- **Wrap the inherited optimizer as one pass.** Rejected because it preserves the unsafe coupling and supplies no pass-specific evidence or rollback boundary.
- **Treat safety classes as an ordinal maximum.** Rejected because authority for cleanup must not silently authorize semantic, target-dependent, or extraction behavior.
- **Mutate the shared AST and undo on error.** Rejected because complete rollback across arena allocations, slices, and nested structures is fragile and difficult to verify.
- **Trust registration order.** Rejected because unrelated refactors would change output and dependency behavior.
- **Mark a pass verified from metadata alone.** Rejected because metadata records evidence; executable acceptance suites remain authoritative.
