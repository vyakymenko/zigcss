# ZigCSS architecture decisions

Architecture Decision Records capture choices that constrain more than one work package. Accepted decisions are mandatory unless a superseding ADR is approved.

| ADR | Status | Decision |
|---|---|---|
| [ADR-001](ADR-001-core-product-scope.md) | Accepted | Stable core product scope |
| [ADR-002](ADR-002-tokenizer-and-syntax-tree.md) | Accepted | Tokenizer and lossless syntax boundaries |
| [ADR-003](ADR-003-memory-and-result-ownership.md) | Accepted | Compilation and result ownership |
| [ADR-004](ADR-004-transform-safety-classes.md) | Accepted | Transform safety classes and pass execution |
| [ADR-005](ADR-005-preprocessor-strategy.md) | Accepted | Experimental format and preprocessor strategy |
| [ADR-006](ADR-006-browser-target-query-language.md) | Accepted | Browser target grammar and generated compatibility data |
| [ADR-007](ADR-007-source-map-policy-for-generated-nodes.md) | Accepted | Source-map policy for generated nodes |
| [ADR-010](ADR-010-autonomous-model-requirement.md) | Accepted | Autonomous model and single-agent gate |
| [ADR-011](ADR-011-native-plugin-contract.md) | Accepted | Experimental native plugin ordering, ownership, and failure behavior |
| [ADR-012](ADR-012-canonical-preprocessor-host.md) | Accepted | Version-pinned canonical preprocessors behind one bounded host |
| [ADR-013](ADR-013-self-contained-native-frontends.md) | Accepted | Self-contained native Zig stylesheet frontends and zero-runtime-dependency graduation |
| [ADR-014](ADR-014-autonomous-convergence-and-ci-throughput.md) | Accepted | Finite release-gap convergence, hosted CI budget, and batched main integration |
| [ADR-015](ADR-015-stable-promotion-and-performance-claims.md) | Accepted | Immutable stable promotion, npm latest, Pages SEO, and evidence-bound performance claims |
| [ADR-016](ADR-016-open-source-completion-and-optional-benchmarks.md) | Accepted | Open-source program completion with controlled benchmarks retained as optional external evidence |

The remaining ADR backlog is listed in `DEVELOPMENT_PLAN.md` and will be resolved when its owning milestone becomes dependency-eligible.
