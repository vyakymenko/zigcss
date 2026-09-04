# ADR-013: Self-contained native stylesheet frontends

- Status: Accepted
- Date: 2026-07-17
- Amended: 2026-07-27
- Owners: ZigCSS parser, language frontend, CLI, package, security, and release maintainers
- Roadmap: `NATIVE-001` through `NATIVE-009`, `NSASS-010` through `NSASS-012`, `NLESS-010` through `NLESS-012`, and `NSTYLUS-010` through `NSTYLUS-012`
- Supersedes: ADR-012's decision to ship canonical providers as production runtime dependencies; ADR-012 remains the behavioral reference and security oracle until every native replacement graduates

## Context

ADR-012 delivered evidenced SCSS, indented Sass, Less, and Stylus behavior by placing exact canonical engines behind a bounded Node host. That implementation is secure, deterministic, and useful, but its production package contains Dart Sass, Less, Stylus, and their transitive JavaScript dependencies. The standalone Zig binary remains CSS-only.

On 2026-07-17 the project owner cancelled publication of the prepared `0.5.0-rc.1` candidate and required ZigCSS to become a self-contained native compiler with no production language-engine dependencies. No `v0.5.0-rc.1` tag, GitHub Release, signed attestation, or npm publication existed when this decision was accepted.

This is not a packaging-only change. SCSS/Sass, Less, and Stylus each define parsing, evaluation, scoping, imports/modules, control flow, interpolation, diagnostics, and language-specific built-ins. Replacing their canonical engines requires native implementations and conformance evidence at least as strong as the existing reference adapters.

## Decision

### Product boundary

The target product is one ZigCSS binary and one Zig library implementation for CSS, SCSS, indented Sass, Less, and Stylus.

The compiler runtime may use Zig's standard library and the host operating-system ABI. It may not require or discover:

- Node.js, Deno, Bun, a JavaScript engine, or another language runtime to compile a stylesheet;
- Dart Sass, Less, Stylus, a native add-on, a shared non-system language library, or an external executable;
- a shell, package manager, ambient project package, runtime download, network service, or mutable runtime data bundle; or
- a child process for parsing, evaluation, import resolution, transformation, or emission.

Direct release archives are the authoritative self-contained distribution. An optional npm delivery wrapper may require Node because npm itself is a Node distribution channel, but the package must have zero `dependencies` and zero `optionalDependencies`; the wrapper may only select and invoke the shipped ZigCSS binary. The JavaScript API may frame requests to that same binary, but it must not implement or host language semantics.

Development-only tools and exact reference providers may remain in `devDependencies` while migration is active. They are test oracles, not shipped compiler components. Release archives, production package inventory, installed production graph, offline smoke tests, SBOM, and runtime process tracing must prove that no reference engine or transitive runtime enters the product.

### Compatibility authority

The exact ADR-012 baselines remain differential oracles during migration:

| Input | Reference oracle | Native target |
|---|---|---|
| CSS | ZigCSS verified CSS core | Existing native core |
| SCSS | Dart Sass 1.101.0 | Zig implementation |
| Indented Sass | Dart Sass 1.101.0 | Zig implementation sharing Sass semantics |
| Less | Less 4.6.7 | Zig implementation |
| Stylus | Stylus 0.64.0 | Zig implementation |

Maintenance note (2026-09-02): Less 4.6.7 remains the frozen native conformance baseline recorded by this decision. Exact Less 4.9.0 is now the development-only forward oracle used for current differential and security maintenance; it does not regraduate the native row or rewrite the published 0.6 contract. CI separately runs `npm run audit:development` across the complete root development graph. The development host also replaces its former direct `image-size` 0.5.5 dependency with a shared bounded PNG/GIF/JPEG/SVG dimension parser used by Less and Stylus over resolver-owned buffers. Production dependencies and runtime provider execution remain zero.

Upstream source code is not copied into the production implementation. License-reviewed corpora and black-box differential output may be used under their recorded licenses. Every semantic choice that intentionally differs from the reference must be an explicit closed limitation with a diagnostic; it cannot silently fall back to CSS or approximate behavior.

“Native support” is a per-language graduated state. “Full native support” requires all four preprocessor rows to pass on one commit. It does not include arbitrary plugins, custom executable functions/importers, Less JavaScript, Stylus `use()` hooks, project code execution, or future upstream versions.

### Migration without regression

The verified canonical host remains the private reference path until replacement. It is not published as `0.5.0-rc.1`, and no native claim is made from it.

Each native adapter progresses through these states:

1. `reference-only`: the canonical adapter is the oracle and the native product row is unavailable;
2. `native-foundation`: shared native code exists but no public syntax is admitted;
3. `native-differential`: the native adapter passes its selected official corpus, strict negative cases, deterministic reruns, and exact generated-CSS validation;
4. `native-graduated`: CLI, Zig API, JavaScript wrapper, batch, watch, source maps, diagnostics, dependencies, platform, package, and release gates all pass without a runtime provider.

No migration step may replace a green path with a partial native parser. The published native prerelease records all four preprocessor rows as `native-graduated`, retains exact providers only as development oracles, and closes protected tag-workflow publication through the authorized GitHub prerelease and immutable npm `next` version.

The active machine compatibility strategy supersedes the four provider-runtime rows without rewriting their reference evidence:

| Adapter | Strategy | Current development oracle | Frozen conformance baseline |
|---|---|---|---|
| `scss` | `native-reimplementation` | Dart Sass 1.101.0 | Dart Sass 1.101.0 |
| `sass` | `native-reimplementation` | Dart Sass 1.101.0 | Dart Sass 1.101.0 |
| `less` | `native-reimplementation` | Less 4.9.0 forward oracle | Less 4.6.7 |
| `stylus` | `native-reimplementation` | Stylus 0.64.0 | Stylus 0.64.0 |

The exact providers remain development-only differential oracles. They do not enter production archives, the installed production graph, or stylesheet compilation.

### Shared native architecture

The native frontends use one bounded, allocation-explicit foundation:

- a lossless byte/span lexer with explicit newline, indentation, interpolation, string, comment, delimiter, and operator tokens;
- immutable syntax nodes and owned source identities compatible with the rebuilt ZigCSS source/diagnostic model;
- a typed value system for numbers/units, colors, strings, lists, maps, booleans, null, selectors, and callable values;
- bounded lexical environments, module/import graphs, mixin/function calls, loops, recursion, output size, diagnostics, and dependency counts;
- one confined Zig resolver that retains the traversal, symlink, special-file, unstable-read, scheme, cycle, depth, count, and byte protections proven by `PRE-003`;
- deterministic evaluation and emission into complete CSS, followed by recovery-disabled parsing and validation through the existing CSS core; and
- source-map segments, diagnostics, dependency facts, cancellation, and no-partial-CSS ownership integrated directly without a process protocol.

Language parsers and evaluators may share primitives, but they may not erase semantic distinctions merely to reduce code. Sass module rules, Less lazy variables/mixins, and Stylus optional syntax each retain their own versioned behavior and tests.

### Release gate

All tag-triggered releases are fail-closed while the machine-readable native contract reports `nativeReleaseReady: false`. Graduation may set it to `true` only when:

- every preprocessor adapter is `native-graduated` on the same commit;
- production `dependencies` and `optionalDependencies` are empty;
- package and archive inventories exclude the Node host and canonical provider sources;
- runtime tracing proves stylesheet compilation starts no child process and performs no network access;
- five native platform jobs compile all five languages from direct archives and an offline installed package;
- official corpora, differential, fuzz, allocation-failure, resource-limit, map, diagnostic, import, watch, batch, and parallel gates pass; and
- README, website, compatibility metadata, SBOM, changelog, and release notes describe the exact native boundary without plugin-parity claims.

### Publication authority

On 2026-07-27 the project owner separately authorized publication of the first fully graduated native candidate after every `NATIVE-009` gate passes. The authorization is intentionally narrower than general release access:

- the exact candidate commit must already be integrated to `origin/main`, use an unused version and unused protected `v*` tag, match `nativeReleaseVersion`, and report `nativeReleaseReady: true`;
- publication must run only through the existing fail-closed `.github/workflows/release.yml` tag workflow;
- the authorized outputs are its GitHub prerelease, five-target artifacts and attestations, and the exact npm package published under the `next` dist-tag;
- the unpublished provider-backed `0.5.0-rc.1` reference candidate remains permanently outside this authority;
- tags may not be moved or reused, npm `latest` may not be changed, failed gates may not be bypassed, and Homebrew, editor-extension, container, documentation, or service publication is not authorized by this decision; and
- a failed candidate is recorded as closed evidence. Any retry uses a new candidate identity selected and documented by the roadmap rather than rewriting public history.

## Consequences

Positive consequences:

- Direct users receive a self-contained compiler with one implementation, one memory model, and no language-engine installation or discovery.
- Native APIs, CLI behavior, diagnostics, limits, and source maps can share one ownership boundary.
- The production dependency graph and provider supply-chain surface shrink to zero packages.

Costs and constraints:

- This is a multi-milestone compiler program, not a release toggle. Credible parity requires substantial parser, evaluator, resolver, built-in, and conformance work.
- The unpublished `0.5.0-rc.1` candidate is retained only as tested reference evidence and must not be released under the native claim.
- Development retains version-pinned oracles and licensed corpora until native graduation, so the repository may still have dev-only dependencies even though the product target has none.
- Reference providers can expose discrepancies but cannot prove compatibility alone; strict negative behavior, ownership, security, and independent CSS validation remain mandatory.

## Rejected alternatives

- **Publish `0.5.0-rc.1` and remove dependencies later.** Rejected because it would establish the opposite runtime contract immediately before the owner-requested native boundary.
- **Bundle a JavaScript engine or provider bytecode into the executable.** Rejected because embedded third-party runtimes are still runtime dependencies and preserve the same semantic/supply-chain authority.
- **Restore the removed heuristic preprocessors.** Rejected because variable substitution, indentation conversion, or directive stripping can emit plausible but semantically corrupted CSS.
- **Call a limited common subset full support.** Rejected because the branded language claim requires versioned conformance; a subset must remain explicitly named and unavailable for unsupported syntax.
- **Remove reference providers before native parity.** Rejected because doing so destroys the strongest differential oracle and encourages unmeasured behavior drift.
