# ADR-010: Autonomous model and single-agent requirement

- Status: Accepted
- Date: 2026-07-11
- Amended: 2026-08-08
- Owners: ZigCSS project owner
- Program: completed autonomous recovery roadmap, preserved in Git history

## Context

The project owner authorized an autonomous persistent goal with an explicit quality and execution constraint: development must use the model configured for the task, `gpt-5.6-sol`, and must not delegate implementation to subagents, child tasks, or a fallback model. The original run used ultra reasoning. On 2026-07-27, the owner changed the approved reasoning effort to xhigh. On 2026-08-08, the owner superseded that setting with max reasoning and requested autonomous continuation, retaining the same model and single-agent boundary.

Repository scripts can preserve the work loop and reconstruct evidence, but they cannot prove which hosted model is executing. Model selection is runtime state owned by the Codex task.

## Decision

- Autonomous roadmap work uses `gpt-5.6-sol` with max reasoning as configured by the latest owner instruction.
- Use one implementation agent for code, tests, decisions, ledger updates, and checkpoints.
- No fallback model, subagent, delegated child task, or parallel implementation lane may continue the approved goal.
- The active agent verifies the runtime model before modifying code at autonomous start and after any runtime/session change that makes model identity uncertain.
- During the active program, the durable execution ledger recorded the verified execution model and isolated worktree.
- The repository-owned orientation script reported that recorded model while requiring the active Codex runtime to verify actual selection.
- If the approved model is unavailable or cannot be verified, stop before further code changes, preserve the worktree, update the ledger with the condition, and request restoration of the approved runtime.
- The persistent goal had no token budget and continued until ADR-016 closed the repository-owned roadmap.

This requirement governs autonomous implementation, not deterministic local tools. Compilers, tests, formatters, documentation builds, artifact inspectors, and read-only scripts may run normally.

ADR-016 closed the autonomous program. Its verbose ledger and stopped supervisor were retired after stable publication; Git history preserves their exact implementation and evidence. This ADR remains the historical authority for any future owner-approved autonomous program.

## Consequences

Positive consequences:

- The owner receives a consistent reasoning and implementation standard across the long-running roadmap.
- Responsibility for architectural decisions and repository mutations remains unambiguous.
- The durable protocol cannot silently turn into a multi-model orchestrator.

Costs and constraints:

- Work pauses when the approved runtime is unavailable even if another model could make progress.
- Independent implementation parallelism is intentionally unavailable.
- The repository can audit the declared contract but cannot cryptographically attest hosted model identity.

## Rejected alternatives

- **Allow automatic model fallback.** Rejected because it violates the owner's explicit authorization boundary.
- **Use subagents for research or tests while retaining one committer.** Rejected because the constraint covers delegation, not only Git authorship.
- **Encode a model launcher in Bash.** Rejected because repository scripts do not own Codex runtime selection or persistent-goal scheduling.
- **Treat model identity as advisory.** Rejected because the roadmap risk register defines model availability as a hard stop.
