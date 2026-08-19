# ADR-014: Autonomous convergence and CI throughput

- Status: Accepted
- Date: 2026-08-02
- Decision owner: project owner

## Context

The single-lane autonomous runner safely produced and pushed green checkpoints, but its selection rule treated every bounded sibling observation as the next work item. During `NSASS-011`, a configurable callable re-export test moved its accepted depth one module at a time through sixty-two modules. Each pass was locally correct and fully verified, yet no specification, provider boundary, or resource policy supplied a terminal value. The unsupported boundary simply moved to the next integer, so the loop could continue toward the unrelated 4,096-module resource ceiling without materially approaching the native Sass exit gate.

The same pass cadence integrated every checkpoint to `main`. GitHub Build then received commits faster than its aggregate job could finish. Recent runs passed all five platform jobs but the Test Suite was cancelled at the six-hour job limit. Inspection showed that the aggregate job ran `zig build test-native-preprocessor` and then `zig build test`, while `build.zig` already makes the complete `test` step depend directly on all eleven native frontend runners. The hosted job therefore compiled and executed the growing native suite twice.

Green local commits and rising test counts are valuable evidence, but they are not sufficient evidence of roadmap convergence or a completing hosted release gate.

## Decision

ZigCSS autonomous development is release-gap directed.

1. During the active program, the durable execution ledger owned a finite release-gap inventory. Each item mapped a stable family code to a milestone exit criterion, dependencies, required evidence, and a closure condition.
2. Every `PROGRESS` result identifies one work package, one stable lowercase-kebab family, and whether the pass `REDUCED` or `CLOSED` it.
3. A family may receive at most four consecutive `REDUCED` passes. The next pass is a convergence review and must close the same family by declaring and testing a finite terminal contract, consolidating equivalent evidence, or proving the exit criterion already satisfies it. Renaming the same underlying family does not reset the threshold.
4. Numeric or ordinal `N+1` work requires a terminal bound derived before implementation from a specification, pinned provider, closed data set, or explicit resource policy. Representative lower/terminal/over-limit tests and generated parameterization are preferred to one cloned fixture per intermediate number.
5. Sibling search remains mandatory inspection. A sibling becomes work only when it exposes a distinct release gap, not merely because another passing case can be added.
6. Hosted CI throughput is a release gate. A required job at or above 75% of its hard timeout preempts feature breadth until its budget is restored without weakening coverage.
7. The Build Test Suite runs the complete root `zig build test` graph once. Workflow policy also proves that this root graph retains all eleven native runners. A second focused native invocation in the same job is forbidden.
8. Build uses one non-cancelling concurrency group per ref. The running validation can finish and GitHub retains only the newest pending checkpoint for that ref.
9. Every green checkpoint is still non-force pushed and read back on the recovery branch. `main` is integrated after four green passes, or immediately for `COMPLETE`, a release-candidate gate, or an explicit operator integration. This supersedes every-pass `main` integration but not every-pass remote recovery.

## Enforcement

The runner requires this marker immediately before every `PROGRESS` status:

```text
ZIGCSS-AUTODEVELOP-GAP: <work-package> <stable-family> <REDUCED|CLOSED>
```

Malformed or missing progress metadata is a runner error. The supervisor stores family identity and count outside Git under confined `.autodevelop/state`. At the threshold it injects a convergence-review contract into the next model prompt; another reduction or a different family cannot be accepted as progress until the required family closes.

The workflow validator rejects missing Build concurrency, a duplicate focused native invocation in the aggregate job, loss of the single complete root test command, or removal of any native runner from the root Zig test graph. The autonomous selftest exercises marker validation, threshold state, forced closure, recovery-only push, and batched-main contracts without a model call or production remote.

ADR-016 closed the autonomous program. The ledger, local supervisor, and its selftest were retired after stable publication; their exact bytes remain in Git history. The CI throughput and single-root-test-graph requirements remain active repository policy.

## Consequences

- The runner can still make small, test-first commits, but a repeated family now has a finite end.
- Equivalent generated or parameterized tests may replace copied intermediate fixtures only when they preserve the same semantic, failure, allocation, and limit evidence; this decision does not authorize weaker coverage.
- Recovery history can lead `main` by up to three green passes during ordinary work. Completion and release validation always use an exact integrated `main` checkpoint.
- Fewer `main` triggers and non-cancelling per-ref concurrency give hosted validation a completing evidence window.
- Existing sixty-two-module evidence remains valid. It is not itself a rationale for sixty-three or any later ordinal; the next `sass-callable-reexport-depth` work is a convergence review.
- Publication, tag, deployment, secret, billing, and external-infrastructure authority remain unchanged.

## Superseded behavior

This ADR supersedes the parts of `OPS-004` and `OPS-008` that integrated every green pass to `main`. Their closed-origin allowlist, clean-tree check, non-force semantics, bounded push/readback, single-agent ownership, and failure behavior remain mandatory.
