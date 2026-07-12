# ADR-005: Experimental native plugin contract

- Status: Accepted
- Date: 2026-07-12
- Owners: ZigCSS public API and transform maintainers
- Roadmap: `API-003`, dependent on `API-002` and `PASS-001`

## Context

The inherited prototype exposes `src/plugin.zig`, whose callbacks mutate the legacy AST in place, return `anyerror`, execute in registration order, and share a registry allocator without a rollback or validation boundary. That surface cannot safely enter the rebuilt compiler. The rebuilt pass manager already provides immutable AST handoff, exact safety authority, deterministic dependency planning, validators, and transactional root publication, so a second plugin execution model would duplicate and weaken those rules.

Native callbacks execute inside the compiler process. ZigCSS cannot catch a plugin panic, memory corruption, `@constCast` mutation, blocking call, or other arbitrary behavior. Calling such code a sandbox or stable ABI would create a security and compatibility promise the library cannot enforce.

## Decision

### Stability and trust

- The public surface is named `experimental` in both `PluginOptions` and `PluginStability`. It is a trusted, Zig-only, in-process callback contract—not a stable plugin ABI and not a cross-language host.
- Plugins are unavailable from the recovery CLI, public HTTP compiler, verified optimizer preset, and default `CompileOptions`.
- The inherited mutable plugin registry remains quarantined with the legacy code generator and is not exported from the public `zigcss` root.
- Callers must opt into the `.experimental` union tag and grant each selected pass maturity/safety capability through the deny-by-default `PluginPolicy`. A plugin claiming verified metadata is still third-party trusted code; its metadata is not a ZigCSS release attestation.

### Names and selection

- Every plugin definition, dependency, and requested ID must begin with `plugin.` and must also satisfy the pass manager's bounded stable-ID grammar. This isolates plugins from built-in IDs and prevents a plugin dependency from selecting or impersonating a built-in pass.
- The complete registry is validated even when only a subset is requested. Unknown or duplicate requests, duplicate IDs/dependencies, invalid metadata, missing dependencies, later-phase dependencies, cycles, and registries, request lists, or dependency lists beyond 256 entries fail before a callback runs.
- Only explicitly requested plugins and their transitive plugin dependencies execute. Registry order and request order do not affect execution.

### Ordering

- The optional closed verified optimizer reaches its bounded byte fixed point first.
- Selected plugins then execute through one pass-manager plan. If target prefixing is enabled, its verified built-in pass joins that same plan after the plugin-only selection has already passed the caller's exact policy.
- The shared plan orders ready definitions by phase, then ascending numeric priority, then bytewise stable ID. Dependency edges take precedence. Compatibility therefore precedes extraction, and target prefixing cannot accidentally widen authority for a plugin dependency.
- Active plugins and source maps are rejected with `API0001` until plugin-generated mappings have an independent acceptance contract. Fixed-point optimization retains its separate source-map prohibition.

### Ownership and lifetime

- `ExperimentalPluginOptions.definitions`, `requested`, all metadata strings and dependency slices, callbacks, and `user_data` are borrowed only for synchronous `compile` plan construction and execution. They must remain valid until `compile` returns.
- A plan owns only its ordered pointer slice. Plugin definitions and `user_data` remain caller-owned, and neither enters `CompileResult`.
- A callback receives a borrowed pass context and immutable root. Persistent replacement nodes must use the compilation arena; scratch analysis uses the supplied scratch allocator. A callback must not retain the context, root, source views, or arena pointers after it returns.
- Result CSS, maps, diagnostics, dependencies, and future module exports keep the independent `API-002` ownership contract. No plugin context escapes through them.

### Failure behavior

- Invalid namespace, graph, metadata, selection, or policy returns one owned `API0002` diagnostic and no CSS; no plugin callback runs and dependency collection has not begun.
- A callback or validator error aborts the complete plan, rolls back diagnostics appended by that plan, publishes no candidate root, and returns one owned `API0003` diagnostic with no CSS. Ordered import facts collected before transformation remain available for dependency/watch recovery.
- Transactionality covers the compiler root and compilation diagnostics, not arbitrary caller-owned `user_data` side effects. Plugins must perform their own commit/rollback if external state changes require it.
- Warnings from a completely successful plan remain in the owned result. A warning from a plan that later fails is rolled back with the plan.
- Allocation failure remains `error.OutOfMemory`. The public wrapper does not mislabel operational allocation failure as a CSS or plugin diagnostic.
- Panics, undefined behavior, process exit, nontermination, and malicious memory mutation cannot be recovered in-process. Consumers requiring an untrusted extension boundary must isolate a compiler process themselves; the disabled public compile service grants no plugin path.

## Consequences

Positive consequences:

- Plugins reuse the same deterministic, bounded, deny-by-default transform machinery as built-in passes.
- Borrowed callback state and compilation-owned AST output have one explicit lifetime, while public results remain independently owned.
- Configuration and execution failures are distinguishable, structured, and all-or-nothing for CSS output.
- Built-in optimizer and prefix authority cannot be reached through a plugin namespace dependency.

Costs and constraints:

- Native plugins are suitable only for trusted Zig code linked into the consumer.
- Authors must provide pass metadata, exact policy grants, immutable reconstruction, and validators instead of mutating a legacy AST.
- Active plugin source maps remain unavailable until generated mapping behavior has separate evidence.
- The contract may change before stabilization; no binary or cross-language compatibility is promised.

## Rejected alternatives

- **Export the inherited `PluginRegistry`.** Rejected because mutable legacy AST callbacks, registration-order execution, `anyerror`, and partial mutation violate the rebuilt ownership and transaction boundaries.
- **Run plugins in registration order.** Rejected because unrelated construction order would change output and dependency semantics.
- **Let plugin IDs reference built-ins.** Rejected because transitive dependencies could smuggle stable or separately authorized capabilities into a plugin plan.
- **Catch every plugin failure as a normal diagnostic.** Rejected because in-process panic, undefined behavior, and nontermination are not recoverable errors.
- **Declare a stable ABI now.** Rejected because the rebuilt AST and experimental callback contract remain Zig source-level APIs and cross-language hosting is an explicit `0.4.0` non-goal.
