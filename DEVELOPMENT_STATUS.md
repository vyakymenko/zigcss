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

- Milestone: Milestone 2 — Standards-correct CSS parser and emitter
- Work package: `ROUND-001`
- State: `IN_PROGRESS`
- Next eligible package: `ROUND-001` and `MAP-001`

## Milestone 0 package ledger

| Package | State | Evidence / decision | Commit |
|---|---|---|---|
| `SEC-001` | `VERIFIED` | HTTP regressions reject encoded slash/backslash traversal and escaping symlinks, malformed encoding returns 400 without terminating the server, safe assets and SPA fallback remain available; full docs tests and build pass. | `14e8878` |
| `SEC-002` | `DEFERRED` | Public compile routes return 503 and contain no process-spawn path. Bounded execution remains deferred until body/time/output/process/concurrency/cleanup isolation is implemented. Focused 9/9 and full docs 46/46 tests pass. | `ed5b2ff` |
| `SEC-003` | `VERIFIED` | The final M0 docs image builds from a 42.79 kB filtered context, contains only the built site and static server under `/app`, carries no compiler/download stage, runs as uid 1000 (`node`), and serves on 8080. Static regressions, image inspection, and a live container smoke test pass. | `8d8d81b` |
| `SAFE-001` | `VERIFIED` | CLI, package, docs, editor, formula, release, and benchmark surfaces identify the compiler as experimental. Alternate-format inputs fail before writes, unsafe/absent features are listed explicitly, unsupported public guides are withdrawn, and claim regressions pass. Debug/ReleaseSafe pass 105/105; docs pass 59/59 and build. | `6a2b594` |
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

## Milestone 0 exit validation

Completed on recovery commit `6a2b594`.

| Gate | Result |
|---|---|
| Clean isolated branch | `PASS`; `vale/zigcss-recovery` was clean before and after validation. |
| Debug / ReleaseSafe builds | `PASS`; each completed 3/3 build steps. |
| Debug / ReleaseSafe tests | `PASS`; each completed 105/105 tests (80 unit, 25 CLI integration). |
| Documentation | `PASS`; 59/59 tests and the Vite production build completed. |
| Workflow / script syntax | `PASS`; JSON, workflow YAML, `docs/server.js`, and the artifact inspector parsed successfully. |
| Native target matrix | `PASS`; real ReleaseSafe builds inspected as ELF x86_64/aarch64, Mach-O x86_64/aarch64, and PE x86_64. |
| Documentation container | `PASS`; filtered 42.79 kB build context, uid 1000 runtime, live HTTP response, only `/app/dist` and `/app/server.js`, no compiler binary. |
| Editor integration | `PASS`; VSCode extension dependencies installed with no reported advisory and TypeScript completed with `--noEmit`. |
| npm package surfaces | `PASS`; five-file dry run (11.7 kB unpacked) and a temporary wrapper-to-native-binary help smoke test completed. |
| Zig formatting | `KNOWN DEBT`; the same 19 inherited files reported at baseline remain. Focused newly added/edited regression and format files pass. Formatting debt must be isolated from semantic packages. |
| Dependency audit | `KNOWN DEBT`; docs report one high production advisory in direct `react-router` 7.13.0 and 10 total advisories including dev tooling. Owned by `DEP-001`. |

Milestone 0 exit criteria pass: static serving is contained; the public compiler endpoint is disabled; destructive CLI output paths and accepted no-op flags are rejected; unsafe transforms are unreachable from stable paths; every audit crash/corruption has an executable regression or explicit containment; public documentation describes the current experimental boundary.

## Operator-requested tooling ledger

| Package | State | Evidence / decision | Commit |
|---|---|---|---|
| `OPS-001` | `VERIFIED` | Added a canonical single-agent Codex loop protocol and executable read-only `scripts/autodevelop/orient.sh`. Tests prove it preserves Git status while reporting branch, ledger work, blockers, validation, checkpoints, recovery delta, durable-file hashes, and local tool versions from a nested directory. Bash syntax, 61/61 docs tests, claims checks, and Vite build pass. | `a648ad6` |

## Foundational ADR ledger

| Decision | State | Evidence / decision | Commit |
|---|---|---|---|
| `ADR-001` | `VERIFIED` | Stable scope is standards-oriented CSS library/CLI parsing, diagnostics, spans, deterministic emission, and only evidence-backed transforms; ecosystem adapters remain explicit experiments. | `cd5c45f` |
| `ADR-002` | `VERIFIED` | CSS Syntax algorithms define token behavior; original byte spans, retained trivia, lossless nested component values, recoverable diagnostics, and transform-free syntax boundaries are mandatory. | `cd5c45f` |
| `ADR-003` | `VERIFIED` | A per-compilation arena owns sources through AST; returned CSS/maps/diagnostics have independent result ownership and one cleanup path with allocation-failure coverage. | `cd5c45f` |
| `ADR-010` | `VERIFIED` | The configured `gpt-5.6-sol` ultra runtime and one implementation agent are hard gates; fallback models and delegated implementation are prohibited. | `cd5c45f` |

## Milestone 1 package ledger

| Package | State | Evidence / decision | Commit |
|---|---|---|---|
| `ARCH-001` | `VERIFIED` | Public `zigcss` module now roots at `src/lib.zig`. `SourceManager` owns copied names/bytes/line indexes; spans are source-bound half-open byte ranges; locations handle CR/LF/CRLF/form-feed and Unicode scalar columns; diagnostics own structured messages; `Compilation` owns per-input sources/diagnostics and validates spans. Debug and ReleaseSafe pass 113/113. | `4f290c1` |
| `TOK-001` | `VERIFIED` | Defined every CSS Syntax token category plus comment trivia/EOF and an on-demand progress-safe dispatcher for punctuation, CDO/CDC, whitespace, basic ASCII ident-like tokens, strings, UTF-8 delimiters, and EOF. All 256 byte values make progress; Debug and ReleaseSafe pass 120/120. | `a9d8a2c` |
| `TOK-002` | `VERIFIED` | Added CSS input preprocessing over original-byte spans; escape decoding; Unicode identifiers; number, percentage, dimension, URL/bad-URL, and opt-in unicode-range consumers; numeric representation metadata; raw/decoded token access; and bounded EOF/malformed-input recovery. Tests cover distinct string/name EOF escapes, quoted URL dispatch, escaped bad-URL recovery, incomplete exponents, invalid UTF-8 progress, all escape scalar limits, and every decoded-value allocation failure. Debug and ReleaseSafe pass 135/135. | `ece86be` |
| `TOK-003` | `VERIFIED` | Retains terminated and unterminated comments as explicit trivia with content/raw spans, identifies whitespace/comment trivia uniformly, and derives token start/end locations through the source line index. Tests prove bounded comment EOF recovery, contiguous lossless spans, and original-byte locations across CRLF, form feed, and multibyte UTF-8. Debug and ReleaseSafe pass 139/139. | `ccfa315` |
| `SYN-001` | `VERIFIED` | Added arena-owned lossless component values with preserved tokens, recursive simple blocks, functions, optional closing tokens, and original-byte node spans. Tests prove exact top-level round trips, independent `()[]{}` nesting, quoted/unquoted URL behavior, retained trivia, mismatched-closer preservation, bounded truncated-input recovery, unknown-source errors, exhaustive allocation-failure cleanup, and a configurable default nesting cap. Debug and ReleaseSafe pass 152/152. | `396b6b9` |
| `AST-001` | `VERIFIED` | Introduced the new `src/css/ast.zig` selector model: selector lists, complex selectors with optional leading and explicit inter-compound combinators, ordered compounds/simple selectors, namespace states, type/universal/id/class/nesting selectors, fully representable attribute operators/quoted values/case flags, and pseudo class/element arguments retaining both raw component values and optional typed selector lists. Constructors validate source/span containment and impossible shapes. Tests prove `.a.b` differs structurally from `.a .b`, every combinator/namespace is representable, functional pseudo syntax stays lossless, and attribute metadata survives. Debug and ReleaseSafe pass 161/161. | `ef810d5` |
| `AST-002` | `VERIFIED` | Added contiguous lossless component-value lists, ordered declaration lists, explicit name/colon/value/terminator spans, custom-property identity, and validated top-level `!important` metadata that retains its raw marker/trivia while exposing the semantic value prefix. Tests prove nested semicolons/colons stay inside component nodes, comments/case in `!important` are preserved, invalid markers are rejected, and duplicate fallback declarations retain order. Debug and ReleaseSafe pass 164/164. | `2869b7c` |
| `AST-003` | `VERIFIED` | Added exact terminated/unterminated block envelopes; ordered style/at-rule lists; declaration, nested-rule, keyframe, raw, and no-block at-rule variants; raw preludes; keyframe rules; and source-contained constructors. Tests cover every category, nested unknown syntax, percentage keyframe preludes, rule order, invalid block gaps, and semicolon-free EOF forms. Debug and ReleaseSafe pass 170/170. | `78bc6d1` |
| `MEM-001` | `VERIFIED` | `Compilation` now owns a heap-stable, caller-backed arena used by sources, diagnostics, and temporary syntax storage. Foundational `CompileResult` storage deeply owns CSS, optional source-map bytes, and cloned diagnostic messages independently of compilation lifetime; `take` makes moves explicit and leaves one safe cleanup path. Tests cover compilation moves, unfreed arena temporaries, post-compilation result access, empty/double cleanup, diagnostic-bearing results, and every constructor allocation failure. Debug and ReleaseSafe pass 143/143. | `3330a57` |
| `DIAG-001` | `VERIFIED` | Token recovery metadata and syntax parsing now append compilation-owned diagnostics for invalid UTF-8 and escapes, bad/unterminated strings and URLs, unterminated comments/blocks/functions, mismatched or top-level closers, and nesting limits while preserving a usable lossless document whenever recovery is possible. Diagnostic spans remain source-valid (including zero-width EOF spans), allocation failures propagate separately, and result cloning already deep-copies messages. Debug and ReleaseSafe pass 155/155, including exhaustive diagnostic-allocation failure injection. | `182aa5c` |

## Milestone 1 exit validation

Milestone 1 is `PASS` at gate checkpoint `31a00c1`. The gate adds a representative modern-CSS round-trip corpus, exercises every truncation boundary of nested escaped input (including cuts inside multibyte UTF-8), and passes every single byte through the full lossless syntax boundary.

| Gate | Result |
|---|---|
| Package closure | `PASS`; `ARCH-001`, `TOK-001` through `TOK-003`, `SYN-001`, `AST-001` through `AST-003`, `MEM-001`, and `DIAG-001` are verified and checkpointed. |
| Debug / ReleaseSafe tests | `PASS`; each completed 173/173 tests (80 legacy unit, 68 new library/core, 25 CLI integration). |
| Lossless corpus and truncation recovery | `PASS`; representative custom-property, selector, keyframe, nesting, Unicode/escape, URL, and unknown-syntax inputs round-trip exactly; every tested prefix and byte does likewise without a leak or panic. |
| Diagnostics and positions | `PASS`; malformed/truncated input remains usable and carries source-valid structured spans; LF/CRLF/form-feed, multibyte columns, EOF spans, invalid UTF-8, comments, strings, URLs, escapes, mismatched closers, and nesting limits are covered. |
| AST invariants | `PASS`; adjacency/combinators, attributes, functional pseudos, nested declaration values, importance/fallback ordering, at-rule categories, keyframe preludes, block EOF state, and rule order have independent tests. |
| Ownership / allocation failure | `PASS`; compilation arena, result cloning, decoded tokens, syntax construction, and diagnostics pass exhaustive allocation-failure injection. |
| Debug / ReleaseSafe builds | `PASS`; each completed 3/3 build steps. |
| Documentation | `PASS`; 69/69 tests and the Vite production build completed. |
| Editor and package surfaces | `PASS`; VS Code TypeScript completed with `--noEmit`; npm dry-run contains the expected five files (12.2 kB unpacked). |
| Focused formatting | `PASS`; all Milestone 1 files pass `zig fmt --check`. Repository-wide checking reports only the same 19 inherited files recorded at baseline. |
| Compatibility boundary | `PASS`; the new public source/token/syntax/CSS-AST modules coexist separately from the inherited parser; stable CLI transformation paths remain contained until Milestone 2 replaces them. |

## Milestone 2 package ledger

| Package | State | Evidence / decision | Commit |
|---|---|---|---|
| `PAR-001` | `VERIFIED` | Added arena-owned selector lowering from lossless component values into selector lists, compounds, standard descendant/child/sibling combinators, namespaces, universal/type/class/ID selectors, attributes with every matcher and `i`/`s` flag, legacy/modern pseudo-elements, raw functional pseudos, and typed selector arguments for `:is`, `:where`, `:not`, and `:has`. Comments and whitespace retain distinct semantics; `:is`/`:where` use silent forgiving lists (including empty results), while strict/relative pseudo lists, nested `:has`, pseudo-element contexts, unsupported column combinators, and pre-`NEST-001` `&` are rejected. Names decode into the compilation arena while full spans preserve spelling. Debug and ReleaseSafe pass 185/185, including official Selectors Level 4 grammar examples, negative recovery, recursion limits, and exhaustive allocation-failure injection. | `8c6a9cf` |
| `PAR-002` | `VERIFIED` | Added arena-owned declaration-list lowering and top-level semicolon recovery. Property names decode with raw spans; values remain exact contiguous component lists; functions, blocks, strings, and custom-property syntax cannot be split by nested delimiters; final trivia-separated `!important` markers are case/escape aware while raw marker spelling remains retained; empty values, duplicate fallbacks, and missing final semicolons are preserved. Invalid candidates append diagnostics and resume at the next top-level semicolon. Debug and ReleaseSafe pass 194/194, including count limits and exhaustive valid/recovery allocation-failure injection. | `a5d65f9` |
| `PAR-003` | `VERIFIED` | Added stylesheet/rule-list lowering that composes selector and declaration parsers, ignores CDO/CDC only at top level, preserves style/at-rule order, recurses through rule-list at-rules, classifies declaration/keyframe/raw/no-block bodies, and retains keyframe bodies for PAR-004. Invalid qualified rules synchronize at a top-level semicolon or complete curly block; unterminated blocks keep declarations and explicit missing-close metadata. Escaped at-rule names classify by decoded value. Debug and ReleaseSafe pass 203/203, including rule/depth limits and exhaustive valid/recovery allocation-failure injection. | `01cbce3` |
| `PAR-004` | `VERIFIED` | Added a lossless specialization layer for media query lists; supports conditions with unary/conjunction/disjunction structure; named container queries; statement, named-block, and anonymous layers; declaration-backed property/font-face details; typed keyframe names, selectors, percentages, and declaration blocks; and page selectors, declarations, and margin boxes. Invalid structures append diagnostics while leaving the generic raw AST available; invalid keyframes recover frame-by-frame; page scanning distinguishes margin at-rules from at-keywords inside declaration values. Debug and ReleaseSafe pass 212/212, including mixed/empty/percentage recovery, raw-retention assertions, and exhaustive allocation-failure injection; both build modes and focused formatting pass. | `51b1ce4` |
| `ERR-001` | `VERIFIED` | Added a shared top-level semicolon/curly/EOF synchronization scanner with explicit progress metadata and reused it for qualified rules, at-rules, keyframes, and invalid page children. Selector diagnostic checkpoints suppress redundant outer messages after precise nested failures; syntax-diagnosed stray closers are isolated so they cannot consume the next valid rule. Recovery tests preserve ordered valid siblings, nested rules, declarations, frames, and page descriptors across ten independent errors; every typed-corpus truncation, all 256 bytes, and exhaustive allocation failures remain usable with valid diagnostic spans. Debug and ReleaseSafe pass 220/220; both build modes and focused formatting pass. | `e46a74d` |
| `EMIT-001` | `VERIFIED` | Added deterministic pretty emission over the typed CSS AST with configurable indentation/final newline, canonical selector/rule/declaration formatting, ordered page/keyframe children, duplicate fallback and importance retention, raw component-value preservation for property-specific/unknown syntax, and CSSOM-compatible identifier/string escaping. Every possible byte serializes into one valid identifier and one terminated string token. Emission refuses source mismatches, missing closers, invalid known at-rule structures, discarded rules/declarations/frames, and other recovery gaps rather than inventing or silently deleting syntax. Representative output reparses cleanly; Debug and ReleaseSafe pass 231/231, exhaustive allocation failures, both builds, and focused formatting pass. | `0c91387` |
| `EMIT-002` | `VERIFIED` | Pretty and minified modes now share one emitter, escaping implementation, recovery gate, and ordered traversal. Minified mode removes structural indentation/newlines/optional block-final semicolons, selector-list spaces, and explicit-combinator spaces while retaining descendant combinators, the separator between at-rule names and preludes, CSS escape terminators, comment separators, and one normalized whitespace token everywhere an unknown/property-specific component stream originally contained whitespace. Nested functions/blocks are serialized recursively without flattening. Pretty/minified outputs are deterministic, minified output is smaller, representative style/conditional/keyframe/page/font/raw output reparses cleanly, and both modes refuse the same recovery gaps. Debug and ReleaseSafe pass 234/234 with exhaustive allocation failures; both builds and focused formatting pass. | Checkpoint pending |
| `ROUND-001` | `NOT_STARTED` | Parse/emit/parse equivalence depends on `EMIT-001`. | — |
| `MAP-001` | `NOT_STARTED` | Source Map v3 mappings depend on `EMIT-001`. | — |
| `NEST-001` | `NOT_STARTED` | Native CSS nesting remains gated on `PAR-003` plus its dedicated grammar suite. | — |

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
- `TOK-002`: semantic token values decode CSS escapes on demand while raw original spelling remains source-addressable; URL and malformed-token recovery always terminates, and unicode-range recognition is enabled only for its descriptor-specific entry point.
- `TOK-003`: lossless consumers receive comment and whitespace tokens instead of implicit gaps; normalized consumers can discard both through `Token.isTrivia()`, while unterminated-comment metadata remains available for later structured diagnostics.
- `MEM-001`: compilation-lifetime objects allocate from one arena, while result-lifetime CSS, maps, and diagnostic messages are deep-copied into a recorded result allocator and released only through `CompileResult.deinit`.
- `SYN-001`: component values retain every top-level source byte while representing nested blocks and functions explicitly; missing closers remain `null` metadata for recovery/diagnostics instead of being synthesized into the source model.
- `DIAG-001`: CSS parse problems are structured values on `Compilation.diagnostics`; only allocator exhaustion, unknown sources, and explicit resource limits leave the parse API as operational errors.
- `AST-001`: the new standards-oriented selector AST represents adjacency inside a compound separately from explicit combinators between compounds; typed pseudo arguments never replace their lossless component-value backing.
- `AST-002`: declaration values retain the complete raw component stream (including `!important` and trivia); `ImportantAnnotation.value_end` identifies the semantic prefix without deleting spelling or collapsing duplicate declarations.
- `AST-003`: at-rule block interpretation is a tagged choice rather than a universal rule/declaration assumption; every category retains the original prelude and exact brace/EOF envelope.
- `PAR-001`: selector lowering follows the current CSSWG Selectors Level 4 Editor's Draft grammar; style-rule lists are strict, only `:is()`/`:where()` are forgiving, and their discarded items do not create compilation errors.
- `PAR-002`: declaration parsing never searches raw delimiters inside nested syntax; only top-level semicolon component values synchronize candidates, and malformed candidates remain source-preserved gaps in the ordered declaration-list span.
- `PAR-003`: rule parsing recognizes only top-level semicolon and curly-block component boundaries; qualified rules compose the typed selector/declaration parsers, while each at-rule stores a decoded name, exact raw prelude, and explicit body category.
- `PAR-004`: structured at-rule details are additive views over the generic lossless at-rule. Typed lowering never deletes raw preludes/bodies; invalid typed syntax leaves `details` null or skips only the invalid keyframe/page child while retaining source-addressable raw syntax and diagnostics.
- `ERR-001`: lowering synchronizes only at top-level component-value boundaries, so nested delimiters cannot split an outer rule. Precise nested diagnostics suppress generic parent fallbacks, while matching syntax containers consume their own closers and any visible stray closer is isolated before the next rule.
- `EMIT-001`: pretty emission is structural where the grammar is typed and lossless where values/unknown at-rules remain component streams. It canonicalizes identifiers and strings, never invokes transforms, preserves declaration/rule order, and returns `UnrepresentableRecovery` or `UnterminatedSyntax` whenever formatting would otherwise discard or synthesize meaningful source.
- `EMIT-002`: minification is aggressive only across typed structural grammar. Raw component streams conservatively collapse existing whitespace runs to one token instead of guessing that whitespace is semantically removable; this protects custom syntax, descendant selectors in raw pseudo arguments, list separation, and whitespace-sensitive operators while still removing all structural formatting.

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
- The persistent Codex goal remains the scheduler. `scripts/autodevelop/orient.sh` is deliberately read-only and cannot launch a model, wake a task, or mutate repository/external state; `docs/operations/codex-loop-protocol.md` is the canonical resume procedure.
- Foundational implementation must conform to accepted `ADR-001`, `ADR-002`, `ADR-003`, and `ADR-010`; changing stable scope, source/syntax boundaries, ownership, or autonomous runtime requires a superseding approved ADR.
- CSS strings use their distinct trailing-backslash-at-EOF rule when producing decoded values; identifiers, dimensions, hashes, at-keywords, and URLs retain the general escaped-code-point replacement behavior.
- The arena control block is separately allocated from its caller-provided backing allocator so allocators retained by movable child containers never point into a relocated `Compilation` value.
- Component-value recursion defaults to a 256-container nesting budget and returns `NestingLimitExceeded` before exceeding it; resource-limit diagnostics are added by `DIAG-001` rather than conflated with allocation failures.
- The allocation-free tokenizer records bounded recovery metadata on tokens; the compilation-backed syntax layer converts it to owned diagnostics so no allocation error can be swallowed inside `Tokenizer.next`.
- The new `src/css/ast.zig` model coexists with the inherited `src/ast.zig` prototype until Milestone 2 parsing/emission migration; stable recovery paths do not consume the legacy selector representation.
- Declaration lists are ordered slices rather than property maps, preserving fallback declarations and leaving cascade/importance decisions to later explicit passes.
- Rule lists remain ordered and recursive through pointers, preventing non-adjacent at-rules/rules from being merged by the data model itself.
- Column combinators remain representable in the AST but are not accepted by the stable parser because the current Selectors Level 4 grammar lists only descendant, child, next-sibling, and subsequent-sibling combinators. CSS nesting selectors remain rejected until `NEST-001`.
- Parsed declarations retain the complete raw value (including importance trivia/marker) while `valueWithoutImportance()` exposes the semantic prefix; no property map or early value interpretation may remove fallback order.
- Generic rule-list at-rules (`media`, `supports`, `container`, `layer`, `scope`, and related forms) recurse immediately; keyframes retain raw frame syntax for PAR-004, and page/unknown mixed grammars stay raw until their dedicated classifier can preserve all nested forms.
- Structured at-rule specialization keeps generic blocks as the recovery boundary. Keyframes retain the full raw frame stream alongside typed valid frames; page remains a raw mixed-content block alongside ordered typed declarations/margin boxes; malformed typed preludes never erase the underlying rule.
- Rule recovery uses the shared `css/recovery.zig` boundary contract: semicolon and complete curly-block boundaries always advance one component, EOF is stable, nested components remain opaque, and syntax diagnostics remain the sole report for stray closing tokens.
- Pretty emission follows CSSOM identifier/string escaping and CSS Syntax round-trip constraints. Comments inside raw component values are retained as token separators; generic structural whitespace is canonicalized; incomplete or partially lowered constructs are rejected before a successful output is returned.
- Pretty and minified emission are modes of the same implementation. Minified mode defaults to no final newline, may omit only a declaration immediately before its closing brace, and retains a semicolon when a following page item still needs an explicit declaration boundary.

## Last full validation

Milestones 0 and 1 are `PASS`. Latest package validation (`EMIT-002`): Debug and ReleaseSafe each pass 234/234 tests (80 legacy unit, 129 new library/core, 25 CLI integration); Debug and ReleaseSafe builds complete and `src/css/emitter.zig` passes formatting. The same 19 inherited formatting failures and recorded dependency-audit debt remain scheduled work. `ROUND-001` is active; `MAP-001` is also dependency-eligible.
