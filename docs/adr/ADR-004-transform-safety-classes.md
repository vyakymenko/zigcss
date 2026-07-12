# ADR-004: Transform safety classes and pass execution

- Status: Accepted
- Date: 2026-07-11
- Owners: ZigCSS transform and validation maintainers
- Roadmap: `PASS-001`, `OPT-010` through `OPT-015`, `CUSTOM-001`, `LOGICAL-001`, `PREFIX-002`, and `TREE-001`

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
