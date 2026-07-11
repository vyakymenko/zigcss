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
- Work package: Milestone 0 validation
- State: `IN_PROGRESS`
- Next eligible package: Milestone 0 validation, then operator-requested autonomous-loop tooling

## Milestone 0 package ledger

| Package | State | Evidence / decision | Commit |
|---|---|---|---|
| `SEC-001` | `VERIFIED` | HTTP regressions reject encoded slash/backslash traversal and escaping symlinks, malformed encoding returns 400 without terminating the server, safe assets and SPA fallback remain available; full docs tests and build pass. | `14e8878` |
| `SEC-002` | `DEFERRED` | Public compile routes return 503 and contain no process-spawn path. Bounded execution remains deferred until body/time/output/process/concurrency/cleanup isolation is implemented. Focused 9/9 and full docs 46/46 tests pass. | `ed5b2ff` |
| `SEC-003` | `VERIFIED` | The docs image builds from a 5.46 kB filtered context, contains only the built site and static server under `/app`, carries no compiler/download stage, runs as uid 1000 (`node`), and serves on 8080. Static regressions, image inspection, and a live container smoke test pass. | `8d8d81b` |
| `SAFE-001` | `VERIFIED` | CLI, package, docs, editor, formula, release, and benchmark surfaces identify the compiler as experimental. Alternate-format inputs fail before writes, unsafe/absent features are listed explicitly, unsupported public guides are withdrawn, and claim regressions pass. Debug/ReleaseSafe pass 105/105; docs pass 59/59 and build. | Checkpoint pending |
| `TEST-001` | `VERIFIED` | Added 18 isolated compiler/CLI characterization regressions covering every non-server Milestone 0 audit case; fixed server regressions remain active assertions. Debug and ReleaseSafe each pass 94/94 tests. | `0334d05` |
| `OPT-001` | `VERIFIED` | Stable code generation rejects optimize, autoprefix, dead-code, and critical-CSS requests before AST mutation or emission. All optimizer corruption/crash inputs now assert explicit containment; Debug and ReleaseSafe pass 95/95. | `1f8323a` |
| `PROF-001` | `VERIFIED` | Timing handles end idempotently and transfer/free their name exactly once. CLI profiling exits 0, emits CSS, and reports each stage once; Debug and ReleaseSafe pass 97/97. | `0c7e56d` |
| `CLI-001` | `VERIFIED` | Canonical/real-path and inode-aware planning rejects input aliases, symlink/hard-link aliases, duplicate batch destinations, and unsafe default batch naming before writes. Debug and ReleaseSafe pass 99/99. | `5d2fc1d` |
| `CLI-002` | `VERIFIED` | Unknown/duplicate options, missing values, invalid batch contracts, and unavailable features exit 2 with explicit diagnostics. Help separates available from rejected recovery features. Debug and ReleaseSafe pass 102/102. | `4719d02` |
| `CI-001` | `VERIFIED` | PRs run locked docs install, 49 tests, and Vite build; Pages artifact uses `docs/dist`; deployment is isolated to non-PR events. Workflow regression tests and YAML parse pass. | `e39a674` |
| `CI-002` | `VERIFIED` | Build/release pass every matrix target to Zig after native tests and verify headers before upload. Five real cross-builds verified: ELF x86_64/aarch64, Mach-O x86_64/aarch64, PE x86_64. | `fcc1658` |

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
- `SEC-002` containment decision: the public compile service is disabled rather than exposed without its required resource and isolation limits. Re-enablement requires the full package gates.
- `TEST-001`: the audit corpus runs the actual CLI as a child process, safely captures crash signatures, and maps every quarantine to the package that must replace it with a target-contract assertion.
- `OPT-001`: code generation no longer invokes the legacy optimizer. Transform-bearing requests fail with `UnsafeTransformsDisabled` and a CLI diagnostic; minification remains emission-only.
- `PROF-001`: explicit and deferred `end()` calls are safe; profiler cleanup no longer double-frees timing names.
- `CLI-001`: every planned output is checked against every input and prior output before directory creation or compilation; rejected plans preserve all sources.
- `CLI-002`: the CLI accepts only functional recovery-scope options; unavailable source maps, transforms, target queries, and extraction modes fail before reading input.
- `CI-001`: documentation validation and deployment are separate jobs; pull requests cannot execute the deploy job and the uploaded artifact matches Vite's verified output directory.
- `CI-002`: target builds happen after native tests so tests cannot replace cross artifacts; a shared tested inspector validates architecture and executable format before upload or release archive creation.
- `SEC-003`: the public docs runtime is static-only, non-root, high-port, and root-owned; a filtered build context excludes repository metadata, generated output, dependency trees, and environment files.
- `SAFE-001`: the recovery CLI emits an experimental warning and rejects legacy format adapters; active public documentation is limited to the tested status, source-build, and CLI contracts, while prior performance comparisons are explicitly invalidated.

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
- Legacy compiler failures are executable characterization quarantines, not accepted contracts. Each owning fix must replace its quarantine with the correct behavior assertion in the same commit.
- Legacy optimizer functions remain reachable only to explicitly labeled internal tests. They are not part of the stable CLI/code-generation path and must not be re-enabled without pass-specific acceptance evidence.
- Operator-requested post-Milestone-0 tooling: add a ZigCSS autonomous-loop protocol plus a read-only `orient.sh`, modeled on Alvo's protocol/orient split and adapted to this repository's no-push/no-deploy authority boundary.
- Alternate-format parsers remain available only as experimental internals for characterization; `.scss`, `.sass`, `.less`, `.styl`, `.postcss`, `.module.css`, and CSS-in-JS extensions are rejected by the recovery CLI before any output is written.

## Last full validation

Milestone 0 full validation is now in progress. Latest package validation: Debug and ReleaseSafe each pass 105/105 Zig tests; 59/59 documentation tests, Vite build, and npm package dry run pass.
