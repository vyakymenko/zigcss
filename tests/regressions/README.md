# Audit regression quarantine

These integration tests preserve the exact failure signatures reproduced during the Milestone 0 baseline. They intentionally execute the legacy compiler as a child process so crashes cannot terminate the test runner.

While a case is quarantined, its test name begins with `legacy quarantine:` and asserts both the unsafe signature and the intended owner package. This is characterization, not acceptance of the behavior. When an owner package makes the case safe, that package must replace the quarantine assertion with the target contract in the same commit.

The legacy code-generator transform fields remain active containment assertions and must fail before mutation. The rebuilt CLI's `--optimize` path instead has target-contract tests for its closed verified preset; separately authorized prefix and extraction flags remain explicit failures.

| Regression | Current status | Owning package |
|---|---|---|
| Compound versus descendant selectors | Quarantined | `AST-001`, `PAR-001` |
| Functional pseudo-classes and attribute selectors | Quarantined | `AST-001`, `PAR-001` |
| Delimiters inside strings and functions | Quarantined | `TOK-002`, `SYN-001`, `PAR-002` |
| Declaration-bearing at-rules | Quarantined | `AST-003`, `PAR-003`, `PAR-004` |
| Percentage keyframes | Quarantined | `AST-003`, `PAR-004` |
| Mandatory at-rule whitespace | Quarantined | `EMIT-002` |
| Importance and fallback declaration order | Verified through the stable optimizer preset | `AST-002`, `OPT-011`, Milestone 3 exit |
| Empty-rule removal order | Verified through the stable optimizer preset | `OPT-010`, Milestone 3 exit |
| Non-adjacent selector and at-rule merging | Verified as a no-crossing boundary through the stable optimizer preset | `OPT-014`, `OPT-015`, Milestone 3 exit |
| Custom-property cascade | Verified by `CUSTOM-001` | `CUSTOM-001` |
| Logical properties in RTL/vertical modes | Verified by `LOGICAL-001` | `LOGICAL-001` |
| Background and font shorthand resets | Verified as an unchanged unsupported-shorthand boundary through the stable optimizer preset | `OPT-013`, Milestone 3 exit |
| Typed math precedence and units | Verified through the stable optimizer preset | `VAL-001`, `MATH-001`, Milestone 3 exit |
| Selector simplification crash | Verified as an unchanged no-pass boundary through the stable optimizer preset | A future selector simplification pass still requires a new package and acceptance suite. |
| Profiling lifecycle crash | Verified by `PROF-001` | `PROF-010` owns real allocator-backed metrics. |
| Source-map no-op behavior | Explicitly unavailable via `CLI-002` | `MAP-001` |
| Browser-target prefix behavior | Verified at the library/test-driver boundary by `PREFIX-001` and `PREFIX-002`; stable target flags remain explicitly unavailable via `CLI-002` and are not part of `--optimize` | Later public API/CLI wiring |
| Dead-code and critical-CSS selector filtering | Verified as two bounded experimental library/test-driver modes by `TREE-001`; extraction flags remain unavailable via `CLI-002` and are not part of `--optimize` | Later public API/CLI wiring and matrix expansion |
| Input overwrite and batch output collision | Verified by `CLI-001` | `CLI-012` later adds atomic writes and final naming policy. |
| Unknown flags and missing flag values | Verified by `CLI-002` | `CLI-011` later owns the final public option contract. |

Static traversal, malformed URL handling, and compile-service containment are active passing assertions in `docs/src/server.test.ts` because `SEC-001` is verified and the public compile service is disabled pending `SEC-002`.
