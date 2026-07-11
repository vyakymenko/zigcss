# Audit regression quarantine

These integration tests preserve the exact failure signatures reproduced during the Milestone 0 baseline. They intentionally execute the legacy compiler as a child process so crashes cannot terminate the test runner.

While a case is quarantined, its test name begins with `legacy quarantine:` and asserts both the unsafe signature and the intended owner package. This is characterization, not acceptance of the behavior. When an owner package makes the case safe, that package must replace the quarantine assertion with the target contract in the same commit.

Cases labeled `optimizer containment:` are active safety assertions: every transform-bearing request must fail explicitly before output or AST mutation. They remain in place until the named future pass satisfies its acceptance template.

| Regression | Current status | Owning package |
|---|---|---|
| Compound versus descendant selectors | Quarantined | `AST-001`, `PAR-001` |
| Functional pseudo-classes and attribute selectors | Quarantined | `AST-001`, `PAR-001` |
| Delimiters inside strings and functions | Quarantined | `TOK-002`, `SYN-001`, `PAR-002` |
| Declaration-bearing at-rules | Quarantined | `AST-003`, `PAR-003`, `PAR-004` |
| Percentage keyframes | Quarantined | `AST-003`, `PAR-004` |
| Mandatory at-rule whitespace | Quarantined | `EMIT-002` |
| Importance and fallback declaration order | Contained by `OPT-001` | `AST-002`, `OPT-011` |
| Empty-rule removal order | Contained by `OPT-001` | `OPT-010` |
| Non-adjacent selector and at-rule merging | Contained by `OPT-001` | `OPT-014`, `OPT-015` |
| Custom-property cascade | Contained by `OPT-001` | `CUSTOM-001` |
| Logical properties in RTL/vertical modes | Contained by `OPT-001` | `LOGICAL-001` |
| Background and font shorthand resets | Contained by `OPT-001` | `OPT-013` |
| Typed math precedence and units | Contained by `OPT-001` | `VAL-001`, `MATH-001` |
| Selector simplification crash | Contained by `OPT-001` | A future selector pass requires a new package and acceptance suite. |
| Profiling lifecycle crash | Verified by `PROF-001` | `PROF-010` owns real allocator-backed metrics. |
| Source-map no-op behavior | Explicitly unavailable via `CLI-002` | `MAP-001` |
| Browser-target prefix behavior | Explicitly unavailable via `OPT-001` and `CLI-002` | `PREFIX-001`, `PREFIX-002` |
| Input overwrite and batch output collision | Verified by `CLI-001` | `CLI-012` later adds atomic writes and final naming policy. |
| Unknown flags and missing flag values | Verified by `CLI-002` | `CLI-011` later owns the final public option contract. |

Static traversal, malformed URL handling, and compile-service containment are active passing assertions in `docs/src/server.test.ts` because `SEC-001` is verified and the public compile service is disabled pending `SEC-002`.
