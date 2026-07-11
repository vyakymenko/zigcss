# ZigCSS Development Status

Last updated: 2026-07-11

## Execution context

- Goal: complete the approved roadmap in `DEVELOPMENT_PLAN.md`.
- Branch: `vale/zigcss-recovery`
- Base commit: `2d2c0d90208610e1e7a623185372ddeab01fc44c` (`main` and `origin/main` at autonomous start)
- Verified execution model: `gpt-5.6-sol`, ultra reasoning, as explicitly configured and approved in the autonomous-development handoff.
- Worktree: isolated Codex worktree `/Users/vyakymenko/.codex/worktrees/9302/zigcss`; the user's main checkout is out of scope.
- Inherited changes preserved: the approved `DEVELOPMENT_PLAN.md` was untracked at autonomous start and is being committed unchanged as the roadmap.
- External actions: pushing, publishing, deployment, pull requests, and external-system changes are not authorized.

## Current work

- Milestone: Milestone 0 — Containment and regression baseline
- Work package: compile API containment pending `SEC-002`
- State: `IN_PROGRESS`
- Next eligible package: disable the public compile API, then `TEST-001`

## Milestone 0 package ledger

| Package | State | Evidence / decision | Commit |
|---|---|---|---|
| `SEC-001` | `VERIFIED` | HTTP regressions reject encoded slash/backslash traversal and escaping symlinks, malformed encoding returns 400 without terminating the server, safe assets and SPA fallback remain available; full docs tests and build pass. | Checkpoint pending |
| `SEC-002` | `NOT_STARTED` | Compile API limits pending; endpoint will be disabled immediately after `SEC-001` until bounded isolation is verified. | — |
| `SEC-003` | `NOT_STARTED` | Non-root/minimal docs container pending. | — |
| `SAFE-001` | `NOT_STARTED` | Experimental-status and claims audit pending. | — |
| `TEST-001` | `NOT_STARTED` | Audit regression suite pending. | — |
| `OPT-001` | `NOT_STARTED` | Unsafe optimizer defaults pending regression harness. | — |
| `PROF-001` | `NOT_STARTED` | Profiling lifecycle fix pending regression harness. | — |
| `CLI-001` | `NOT_STARTED` | Input/output and batch collision protection pending. | — |
| `CLI-002` | `NOT_STARTED` | Strict flag/value/feature rejection pending. | — |
| `CI-001` | `NOT_STARTED` | Docs artifact and PR test enforcement pending. | — |
| `CI-002` | `NOT_STARTED` | Target triple and architecture inspection pending. | — |

## Baseline commands and results

Baseline captured on base commit `2d2c0d9` with Zig 0.15.2, Node 24.16.0, and npm 11.13.0. The host is macOS 26.5; Zig 0.15.2's bundled linker could not consume the macOS 26.5 SDK stubs, so native commands used an isolated `xcrun` wrapper pointing at the already-installed macOS 15.4 SDK plus `MACOSX_DEPLOYMENT_TARGET=15.4`. A fresh-cache retry against the 26.5 SDK reproduced the linker failure, while the 15.4 SDK completed unchanged builds and tests.

| Surface | Command | Result |
|---|---|---|
| Zig Debug build | `zig build --summary all` | `PASS`; 3/3 steps succeeded. |
| Zig ReleaseSafe build | `zig build -Doptimize=ReleaseSafe --summary all` | `PASS`; 3/3 steps succeeded. |
| Zig tests | `zig build test --summary all` | `PASS`; 76/76 tests. |
| Zig formatting | `zig fmt --check build.zig build_helpers.zig src examples` | `FAIL`; 19 inherited `.zig` files require formatting. No bulk formatting was applied because it would mix unrelated churn into containment packages. |
| Docs tests | `cd docs && npm run test:run` | `PASS`; 6 files and 37 tests. |
| Docs build | `cd docs && npm run build` | `PASS`; Vite emitted `docs/dist`. |
| Docs dependency install/audit | `cd docs && npm ci --ignore-scripts` | Install passed; npm reported 10 advisories: 1 low, 2 moderate, 6 high, 1 critical. Resolution belongs to `DEP-001`. |
| npm package dry run | `npm pack --dry-run --ignore-scripts` | `PASS`; package contains 5 files, 53.0 kB unpacked. |
| Audit reproductions | Temporary corpus and live docs-server requests | `FAIL` as expected; concrete evidence below. |

## Completed work packages

- `SEC-001`: static serving is contained within the configured real root and malformed URL encoding is handled without a process crash. Focused result: 7/7 security tests; integration result: 44/44 docs tests plus successful Vite build.

## Active blockers

None.

## Known regressions and risks

The authoritative regression list remains the Milestone 0 list in `DEVELOPMENT_PLAN.md`. Base-commit reproductions established:

| Area | Base-commit evidence |
|---|---|
| Static traversal | `GET /..%2fpackage.json` served `docs/package.json`; double traversal served repository `package.json`. |
| Malformed URL | `GET /%E0%A4%A` threw `URIError: URI malformed`, terminated the docs server, and returned an empty reply. |
| Compile-service limits | Code inspection found unbounded request accumulation, no timeout/output/concurrency/process limit, synchronous temp I/O, and incomplete error-path cleanup. |
| Compound selectors | `.a.b` and `.a .b` both emitted `.a .b`, proving semantic collapse. |
| Functional/attribute selectors and nested delimiters | A selector containing `:not(...)` and `[data-x=...]` failed at byte 1 instead of parsing. |
| Declaration-bearing at-rules | `@font-face` failed as an invalid identifier. |
| Percentage keyframes and at-rule spacing | The combined at-rule corpus could not parse; optimized media output elsewhere emitted invalid `@mediascreen`. |
| Important/fallback ordering | Three `color` declarations collapsed to only the last important value. |
| Rule/at-rule ordering | Optimization merged non-adjacent `.keep` rules and non-adjacent `@media` blocks, moved the media block, reversed nested rule order, and reported allocator leaks. |
| Custom-property cascade | Optimization replaced `var(--theme)` with a global/static value and shortened custom property values, ignoring dynamic cascade semantics. |
| Logical/reset behavior | Optimization converted `margin-inline-start` to `margin-left` despite RTL/vertical modes and synthesized a background shorthand. |
| Source-map/browser flags | `--source-map` and `--browsers chrome100` were accepted but output was unchanged and no source map was produced. |
| Unknown/missing CLI arguments | An unknown flag and a missing `-o` value both exited 0 and compiled normally. |
| Profiling lifecycle | `--profile` printed a report and then crashed with SIGABRT/segmentation fault (exit 134), confirming the double-end path. |
| Input overwrite | `input.css -o input.css --minify` exited 0 and replaced the input in place. |
| Batch collision | Two different `shared.css` inputs mapped to the same output, both reported success, and the second silently overwrote the first. |

## Decisions

- The approved plan is authoritative.
- Security and semantic containment precede feature work.
- Inherited work is preserved and will not be rewritten or discarded.
- The compile API will be disabled after `SEC-001` unless `SEC-002` isolation is implemented and verified immediately.

## Last full validation

Milestone 0 is not yet eligible for full validation. Latest package validation: `npm run test:run` (44/44) and `npm run build` passed after `SEC-001`.
