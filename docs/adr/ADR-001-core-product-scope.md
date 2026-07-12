# ADR-001: Core product scope

- Status: Accepted
- Date: 2026-07-11
- Owners: ZigCSS project owner and autonomous implementation agent
- Roadmap: Milestones 0-8 in `DEVELOPMENT_PLAN.md`

## Context

The inherited 0.3 prototype presents one binary as a CSS compiler, several preprocessor implementations, a transform engine, an LSP, a public compile service, and a high-performance production tool. Audit fixtures show that the current parser collapses distinct selector semantics, rejects or corrupts standards syntax, emits invalid minified at-rules, and feeds transforms that can change cascade, ordering, shorthands, logical properties, and typed math.

A broad compatibility promise would make it impossible to establish a trustworthy stable core. Performance and ecosystem claims also create pressure to enable behavior before semantic equivalence is demonstrated.

## Decision

The stable `0.4.x` product is a standards-oriented CSS compiler with:

- a Zig library API;
- a strict CLI adapter over that library;
- standards CSS tokenization and parsing;
- deterministic pretty and grammar-aware minified emission;
- structured diagnostics and source spans;
- Source Map v3 output only after mappings pass consumer validation;
- optional transforms only when each pass has semantic acceptance evidence.

Correctness is the product boundary. Unsupported syntax and unavailable features fail explicitly. The emitter does not run transforms, the CLI does not own compilation logic, and timing cannot promote a transform.

SCSS, SASS, LESS, Stylus, PostCSS-like behavior, CSS Modules, CSS-in-JS, and Tailwind-like `@apply` remain experimental. Each adapter requires an explicit enablement mechanism, its own compatibility contract, negative tests, dependency behavior, and generated-CSS validation before it can be considered for graduation. Experimental adapters do not block the stable CSS release.

The LSP remains experimental while editor publication and binary distribution are incomplete. Its protocol transcript, large-document, Unicode, malformed-request, allocation-failure, repeated lifecycle, local VS Code packaging/discovery, and pinned Neovim client-integration gates pass; implemented features consume the rebuilt tokenizer, syntax tree, spans, diagnostics, and bounded open-document workspace indexes rather than a parallel textual parser. The public compile service remains disabled until compiler correctness and bounded process/request isolation both pass. Package-manager and native artifact claims remain gated on installation smoke tests.

Public performance claims remain withdrawn until benchmarks reject semantically invalid output and compare equivalent execution modes with archived raw data.

## Explicit non-goals

The following are not stable `0.4.0` goals:

- full Dart Sass, LESS, or Stylus compatibility;
- JavaScript PostCSS plugin execution inside the Zig binary;
- full Tailwind scanning, configuration, plugin, variant, or arbitrary-value compatibility;
- a stable cross-language plugin ABI;
- unproven global custom-property evaluation;
- automatic logical-to-physical property conversion;
- public untrusted compilation without tested isolation;
- a performance leadership claim before semantics-first benchmarking.

## Consequences

Positive consequences:

- Parser, emitter, API, CLI, LSP, and format work share one compatibility boundary.
- Features can be rejected honestly instead of silently changing input.
- Release and benchmark gates measure the product that users actually receive.
- Experimental work can continue without weakening stable CSS semantics.

Costs and constraints:

- Much of the inherited feature surface remains disabled or internal for several milestones.
- Existing documentation, examples, editor activation, and packaging must continue to be audited for accidental graduation claims.
- Stable releases wait for parser/emitter correctness even if isolated prototype features appear functional.

## Rejected alternatives

- **Patch the byte parser while adding features.** Rejected because the audit failures share missing tokenizer, nesting, span, and AST foundations.
- **Ship all adapters as best-effort.** Rejected because silent deletion or reinterpretation is incompatible with a compiler contract.
- **Treat minified output size or throughput as the primary gate.** Rejected because invalid CSS can be smaller and faster.
- **Remove all experimental code immediately.** Rejected because characterization fixtures and isolated implementations remain useful during migration, provided stable entry points cannot reach them.
