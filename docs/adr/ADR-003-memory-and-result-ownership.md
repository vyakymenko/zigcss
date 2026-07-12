# ADR-003: Compilation and result ownership

- Status: Accepted
- Date: 2026-07-11
- Owners: ZigCSS library and CLI maintainers
- Roadmap: `ARCH-001`, `MEM-001`, and `API-001` through `API-003`

## Context

The prototype mixes heap allocations, parser-owned string pools, copied AST structures, output buffers, and callbacks with different lifetimes. Several paths require callers to know hidden ownership details, and optimizer code has demonstrated leaks and double-free risks. A stable Zig library must make input, compilation, AST, diagnostic, and returned-output lifetimes mechanically clear.

## Decision

### Per-compilation ownership

- Each compile invocation creates a `Compilation` with a compilation-scoped arena backed by a caller-owned allocator.
- The compilation owns its source manager, copied source bytes, line indexes, tokens, component values, typed AST, temporary transform data, and in-progress diagnostics.
- `SourceFile`, token, syntax, and AST slices are valid only until `Compilation.deinit`.
- No AST pointer, arena allocation, plugin context, or diagnostic message may escape through the stable result.
- The CLI creates one compilation per independent input. Parallel tasks never share an arena or mutable compiler state.

Copying source bytes into compilation ownership is the safe default. A future zero-copy or ownership-transfer API requires a separate explicit type and must not silently change the stable lifetime contract.

### Returned ownership

- The stable compile entry point accepts a caller-owned allocator for allocations that must outlive the compilation.
- The low-level pipeline result owns generated CSS, optional source-map bytes, and cloned parser diagnostics allocated from that result allocator. The public `API-002` result promotes those buffers into the high-level contract and additionally owns located diagnostics, dependency facts, and optional module-export state.
- `CompileResult.deinit` is the single public cleanup path for all owned result fields. The result records the allocator it must use, so cleanup does not depend on callers remembering an undocumented allocator pairing.
- A result is move-only by convention: copying it and deinitializing both copies is invalid. APIs take a pointer when consuming or deinitializing it.
- On failure before a result is returned, `errdefer` paths release all non-arena allocations and the compilation arena releases the remainder.

### Diagnostics and borrowed views

- Diagnostics inside a live compilation may borrow source bytes but own any synthesized message text in the arena.
- Diagnostics copied into the public `CompileResult` own message and source-name strings and contain stable source IDs, byte spans, codes, severity, and one-based start/end line and scalar-column locations. They remain useful without a live source manager.
- Public accessors must label slices as borrowed or owned through their containing type and lifetime documentation.

### Public compile facade

`zigcss.compile` accepts one caller allocator, a borrowed input name and byte slice, and `CompileOptions`. The public syntax enum contains stable CSS and an explicit experimental CSS Modules subset; the recovery CLI remains CSS-only. Output format, separate source-map output, verified CSS transforms, a borrowed canonical target query, dependency limits, and CSS Modules metadata limits are explicit independent fields. A target query remains caller-owned for the duration of the call; no pointer to it enters the result.

Incoherent option combinations are result diagnostics rather than accepted no-ops: prefixing requires targets, targets require prefixing, forged queries fail validation, and source maps cannot accompany fixed-point optimization until intermediate maps can be composed. Such results contain no CSS. Allocation failures and broken internal invariants remain operational errors rather than being mislabeled as CSS diagnostics.

Dependency reporting recognizes only decoded string or URL operands of top-level `@import` statements. Results deeply own the decoded specifier and source name, retain authored order and duplicates, and carry the operand span. Unsupported, malformed, or dynamic preludes are not guessed into dependencies. Count and owned-byte bounds report `resource_limit` and discard partial facts. Stable CSS returns `module_exports = null`; a successful experimental CSS Modules compile transfers unique first-seen decoded name/generated value entries into the same result allocator. Errors and module-limit failures publish no partial export state.

### Verification

- Unit tests use `std.testing.allocator` so leaks fail tests.
- Allocation-bearing constructors have failure-path tests; critical builders are exercised with allocator-failure injection at successive allocation points.
- Deinitialization tests cover empty, partial, successful, diagnostic-bearing, and moved-result states.
- No cleanup implementation relies on process exit, a global allocator, or CLI-only behavior.

## Consequences

Positive consequences:

- Most parser and AST cleanup becomes one arena deinitialization.
- Returned buffers have one explicit owner independent of temporary compiler state.
- Parallel compilation is isolated by construction.
- Allocation and I/O failures remain distinguishable from CSS diagnostics.

Costs and constraints:

- The safe default copies input bytes and clones result diagnostics.
- Long-lived tooling such as the LSP must retain source text outside a compilation and create bounded compilations or snapshots, rather than holding AST pointers indefinitely.
- Arena allocation does not excuse resource limits; token, nesting, source, and output caps remain required for untrusted input.
- Move-only ownership is a documented Zig convention until language-level move checking exists.

## Rejected alternatives

- **One global arena or string pool.** Rejected because it couples requests, prevents deterministic reclamation, and makes parallel use unsafe.
- **Return slices into the compilation arena.** Rejected because results would dangle after required cleanup.
- **Allocate every AST node independently.** Rejected because cleanup complexity and partial-failure risk outweigh selective reuse benefits for a per-input compiler.
- **Require callers to manually free each result field.** Rejected because it spreads ownership policy across every consumer.
