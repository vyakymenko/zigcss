# ZigCSS Codex autonomous development loop

This is the repository-owned operating procedure for executing `DEVELOPMENT_PLAN.md`. It adapts Alvo's protocol/orientation split to ZigCSS, its persistent Codex goal, and its stricter single-agent and no-publication authority boundary.

The short operator request is only an invocation. This file, `DEVELOPMENT_PLAN.md`, and `DEVELOPMENT_STATUS.md` are the durable contract.

## 1. What is automated

The repository-owned Bash supervisor provides the durable outer loop. It launches exactly one ephemeral non-interactive Codex pass at a time, pins `gpt-5.6-sol` with `ultra` reasoning, limits each pass to one dependency-eligible package, requires a clean committed checkpoint for progress, classifies the result, and starts the next pass. No subagent, child-task, alternate-model, or concurrent-lane path exists.

Run the preflight and start the background supervisor from anywhere inside the worktree:

```bash
scripts/autodevelop/ctl.sh doctor
scripts/autodevelop/ctl.sh start
scripts/autodevelop/ctl.sh status
```

The control surface also provides `test` (one foreground pass), `run` (foreground loop), `pause`, `resume`, `stop`, `logs`, and `orient`. `pause` and `stop` are graceful: an active pass finishes first so the runner does not manufacture an unowned half-edit. Use `pause` before starting manual work in the same worktree.

The background process lasts for the current login. It deliberately does not install a LaunchAgent, modify login items, or mutate any system startup surface. Ignored `.autodevelop/` storage inside the isolated worktree owns logs, caches, control files, and outcome state.

On macOS, the supervisor prefers the Codex CLI bundled with the current ChatGPT or Codex app before an optional older user-local binary. Each pass writes the agent's final message to a separate file through Codex's `--output-last-message` contract; status markers are read only from that file, while transport diagnostics stay in the ordinary pass log. Echoed prompt text therefore cannot impersonate completion, a blocker, or a rate-limit response.

The orientation helper itself remains intentionally read-only: it reconstructs repository facts so every fresh pass starts from durable evidence instead of conversational memory. Run it directly with:

```bash
bash scripts/autodevelop/orient.sh
```

## 2. Standing execution contract

- Use one implementation agent: the model configured for the active task (`gpt-5.6-sol` with ultra reasoning for the approved run). Do not delegate to subagents, child tasks, or fallback models.
- Work only in the isolated ZigCSS worktree on a `vale/` branch. Never alter or clean the user's main checkout.
- Read `DEVELOPMENT_PLAN.md` completely before the first code change. Re-read the current milestone, dependencies, gates, and relevant decisions when orienting to each package.
- Treat `DEVELOPMENT_STATUS.md` as the durable execution ledger. Repository and test evidence outrank memory or stale commentary.
- Preserve inherited and unrelated changes. Never reset, rewrite, or discard work that is not owned by the current package.
- Keep exactly one continuation owner active without a token budget: either the interactive persistent goal or this Bash supervisor. Never advance the same worktree manually while the supervisor is running.
- Do not push, publish, deploy, or open a pull request. Do not create tags, releases, packages, or external-system changes without new explicit authorization.
- Do not weaken tests, suppress failures, lower safety gates, or re-enable an unsafe transform to make a package green.
- Security, parser correctness, semantic preservation, deterministic behavior, and regression evidence take priority over performance or feature count.

If the configured model cannot be verified, stop before modifying code and report the model-availability blocker. The shell helper can show the model recorded in the ledger, but only the active Codex runtime can verify its actual model selection.

## 3. Orient before every package

Run:

```bash
bash scripts/autodevelop/orient.sh
```

Then verify:

1. The branch and worktree are the expected isolated recovery state.
2. Any dirty files belong to a coherent in-progress package; finish or preserve that package before selecting another.
3. Recent commits agree with the ledger.
4. The ledger names current work, blockers, and the last full validation.
5. The roadmap still makes the candidate package dependency-eligible.
6. The runtime model still matches the approved model requirement.

Do not fetch, rebase, merge, or consult the user's main checkout as part of orientation. This autonomous run has no authority to publish or integrate externally.

## 4. Select the next package

Use the dependency graph and milestone order in `DEVELOPMENT_PLAN.md`.

- Finish a dangling coherent package before starting another.
- Choose the smallest dependency-eligible slice that advances an exit criterion.
- Prefer a correctness or security boundary over feature breadth.
- A blocked package is parked with its condition and evidence; continue another eligible package when the graph permits it.
- Do not invent polish to remain busy. When a milestone's packages are complete, run its exit gate, record the result, and proceed to the next milestone.
- If the roadmap is underspecified, make the safest reversible engineering decision and record it in the ledger or an ADR. Ask only when the choice is irreversible, outward-facing, or changes approved product scope.

## 5. Execute one package

Every package follows this order:

1. **Reproduce or measure.** Establish the failure, unsafe reachability, missing contract, or baseline before implementation.
2. **Add or strengthen tests.** Make the desired contract executable and observe the focused failure when practical.
3. **Implement the smallest correct change.** Respect architecture boundaries and avoid unrelated cleanup.
4. **Run proportionate verification.** Start focused, then run every affected integration and milestone gate. Use Debug and ReleaseSafe where Zig semantics or memory ownership are involved.
5. **Search bounded sibling surfaces.** Check the exact family touched for another accepted no-op, collision, claim, ownership path, or duplicate implementation.
6. **Update `DEVELOPMENT_STATUS.md`.** Record state, commands, results, decisions, blockers, and the pending checkpoint.
7. **Checkpoint intentionally.** Commit one coherent green package with the work-package ID in the body.
8. **Re-orient immediately.** Record the commit hash in the next ledger update and take the next eligible package.

An example commit form is:

```text
feat(tokenizer): preserve escaped identifiers

Work-Package: TOK-002
```

## 6. Verification policy

Verification scales with the change, but evidence never disappears:

- Parser/emitter/ownership changes: focused unit and regression tests, then Debug and ReleaseSafe suites.
- CLI changes: child-process integration tests including exit code, stdout/stderr, filesystem effects, aliases, and malformed inputs.
- Docs/server changes: focused Vitest coverage, full docs tests, Vite build, and a live container/server smoke when relevant.
- CI/release changes: workflow regression tests, syntax parsing, real target builds, and artifact inspection where applicable.
- Package changes: dry-run contents and a temporary local wrapper/install smoke without publishing.
- Performance work: reject timing samples until structural or semantic output validation passes.

If a repository-wide gate already failed at baseline, prove the package did not widen it, keep the debt visible in the ledger, and schedule its owning work package. Do not hide it or mix a broad mechanical rewrite into an unrelated semantic commit.

## 7. Continuation and STOP conditions

A green checkpoint is not a handoff. An interactive task continues in-session; a bounded runner pass emits `PROGRESS` and exits so the outer Bash supervisor can immediately start the next pass. Continue autonomously unless one of these holds:

1. New authority is required for an outward action such as push, publication, deployment, PR creation, paid service use, secrets, or an external-system mutation.
2. An irreversible product, compatibility, licensing, or architecture decision is not already resolved by the roadmap and cannot safely be represented by a reversible ADR proposal.
3. Required external state or access is unavailable and no other dependency-eligible work can make meaningful progress.
4. The approved model is unavailable or cannot be verified.
5. The complete roadmap definition of done is achieved and all required evidence is recorded.

Difficulty, a failing test, incomplete work, a long milestone, or a package that benefits from clarification is not a blocker. Diagnose and continue.

Do not treat the roadmap as blocked on the first encounter. Park a local blocker and continue elsewhere when possible. The supervisor pauses as blocked only after the same true condition repeats for three consecutive passes and no meaningful in-scope progress remains, matching the Codex goal rule.

## 8. On a true STOP

For a blocker:

- preserve the worktree without destructive cleanup;
- update the ledger with the exact condition, evidence, attempted alternatives, and the authority or state needed;
- report one concrete decision or unblock request;
- do not claim the package or goal is complete.

For genuine completion:

- run the plan's complete validation and release-readiness gates;
- ensure generated artifacts and the worktree are clean;
- update every package/milestone state and final evidence in the ledger;
- mark an interactive persistent goal complete only when no required work remains; the Bash supervisor instead writes `COMPLETE` state and stops for review;
- report that push, publication, deployment, and PR creation were not performed unless separately authorized.

## 9. Orientation helper safety contract

`scripts/autodevelop/orient.sh` may read Git metadata, the roadmap, the ledger, and local tool versions. It must not:

- edit, stage, commit, reset, clean, switch, fetch, pull, push, or merge;
- run builds, tests, installers, package publication, or deployment;
- access secrets or network services;
- infer completion from commit count alone.

Its output is orientation evidence, not a scheduler and not a substitute for the roadmap gates.

## 10. Supervisor safety contract

`scripts/autodevelop/loop.sh` and `run-pass.sh` enforce one serialized implementation lane:

- an atomic directory lock and live PID prevent a second supervisor;
- an initial start requires a clean tree, while a runner-recorded interrupted WIP marker permits only recovery of the same package;
- `PROGRESS` requires both a new local commit and a clean tree;
- state and dependency caches stay under ignored `.autodevelop/` storage;
- every invocation explicitly selects the approved model and reasoning effort with no fallback;
- the Codex sandbox admits the worktree plus the worktree/common Git metadata needed for local commits, while the prompt forbids the main checkout and every outward mutation;
- rate limits use bounded backoff, authentication failure pauses immediately, five consecutive tool failures pause, and the same reported blocker must recur three times before the supervisor pauses as blocked;
- `COMPLETE` stops the loop for operator review; it does not publish, push, or mark an external release complete.

`scripts/autodevelop/selftest.sh` tests isolated final-message classification, prompt-echo rejection, rate-limit parsing, timeout precedence, authentication detection, exact CLI arguments, and atomic state counters without a model call or repository mutation. The control script exposes no install/deploy/publish command.
