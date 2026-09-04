# ADR-012: Canonical preprocessor host

- Status: Accepted
- Date: 2026-07-16
- Owners: ZigCSS CLI, package, security, source-map, and format-adapter maintainers
- Roadmap: `PRE-001` through `PRE-009`, `SASS-010` through `SASS-012`, `LESS-010` through `LESS-012`, and `STYLUS-010` through `STYLUS-012`
- Supersedes: the future strategy chosen by ADR-005 for `scss`, `sass`, `less`, and `stylus`; ADR-005's current removal and admission boundaries remain in force until graduation

## Context

ADR-005 removed the inherited SCSS, indented Sass, Less, and Stylus byte-rewrite heuristics because they could silently change meaning and had no defensible compatibility boundary. It allowed a later funded program to choose a version-pinned canonical implementation under a new decision. On 2026-07-16 the project owner funded that program and requested full SCSS, Sass, Less, and Stylus support.

Implementing four mature languages independently in Zig would create new compatibility authorities and a large, open-ended semantic gap. The upstream implementations already define parsing, evaluation, module/import behavior, diagnostics, and extension APIs. ZigCSS should preserve its standards-oriented CSS core while integrating those canonical engines through one narrow, testable boundary.

“Full” must remain a versioned, evidenced claim. It cannot mean that every third-party plugin, host callback, ambient package resolver, or future upstream release is automatically supported.

## Decision

### Compatibility authority and baseline pins

ZigCSS will pursue **full language compatibility** with the exact canonical provider versions below. Dependency updates are intentional work packages: each update must repeat license review, conformance, differential, packaging, and release gates before changing the published compatibility version.

| Provider ID | Adapters | Canonical package baseline | License | Authority |
|---|---|---|---|---|
| `dart-sass` | `scss`, `sass` | `sass` `1.101.0` | MIT | Dart Sass modern compile API |
| `less` | `less` | `less` `4.6.7` | Apache-2.0 | Less programmatic render API |
| `stylus` | `stylus` | `stylus` `0.64.0` | MIT | Stylus programmatic render API |

Maintenance note (2026-09-02): this table remains the historical compatibility baseline accepted by this ADR and is intentionally not rewritten. The current development-only Less forward oracle is exact 4.9.0 over the frozen 4.6.7 native conformance baseline. The complete root development graph is audited with `npm run audit:development`; the former direct `image-size` 0.5.5 pin has been removed in favor of one shared bounded PNG/GIF/JPEG/SVG dimension parser over resolver-owned bytes. None of this restores a provider to production or changes the immutable native 0.6 release.

| Adapter ID | Strategy | Provider |
|---|---|---|
| `scss` | `canonical-integration` | `dart-sass` |
| `sass` | `canonical-integration` | `dart-sass` |
| `less` | `canonical-integration` | `less` |
| `stylus` | `canonical-integration` | `stylus` |

The versions above are exact compatibility baselines, not semver ranges. Lockfile integrity and the package manager's transitive graph are part of the release evidence. The initial authoritative integrated surface is the npm-distributed CLI. The standalone native binary and direct Zig library remain the CSS core unless an explicitly configured compatible host is available; they must never claim embedded preprocessor support they do not contain.

### One bounded protocol

All engines are reached through the versioned `zigcss-preprocessor-v1` protocol. One Node host owns provider loading and translates between that protocol and canonical APIs. The compiler-facing request contains only validated data: syntax, source bytes, canonical source URL, output style, source-map policy, explicitly permitted load roots, and bounded provider options. The response is exactly one of:

- complete CSS plus an optional source map, ordered normalized diagnostics, and ordered dependency facts; or
- a structured failure with no partial CSS.

The host is not a shell. It receives framed input without command interpolation, has bounded input, output, diagnostics, dependencies, recursion, concurrency, and execution time, and is terminated on protocol or limit failure. It must not perform network access, package installation, or implicit process execution. Filesystem loads are confined to explicit roots, reject symlink escapes, and become owned dependency facts. Provider stdout, stderr, malformed frames, duplicate terminal messages, unexpected files, and post-result output fail closed.

Canonical output then enters the stable ZigCSS CSS parser, validated transform pipeline, and emitter. A successful integrated result requires the generated CSS to be accepted without recovery. Source maps are composed across the preprocessor and ZigCSS stages; diagnostics and dependency paths are normalized into public owned results. No adapter may bypass CSS-core limits or return unvalidated generated bytes.

### Extensions and trust boundary

Built-in canonical language behavior, ordinary filesystem imports/modules, documented provider options, diagnostics, dependencies, and source maps belong to the language-compatibility program. Arbitrary JavaScript plugins, custom functions, custom importers, or executable configuration do not.

Those executable extension points may be added later only through an explicit **trusted-project-code mode**. That mode must be opt-in, unavailable to the public compile service, visibly non-hermetic, isolated from untrusted requests, and separately tested and documented. Default compilation never loads application JavaScript or provider plugins merely because they exist in a project.

### Graduation and claims

SCSS, indented Sass, Less, and Stylus remain unavailable until their individual roadmap packages pass. In particular, they **remain unavailable until** all of the following are true for the pinned provider version:

1. the bounded host, import confinement, diagnostic normalization, dependency capture, and two-stage source-map composition gates pass;
2. official or versioned upstream fixtures and independent differential cases cover language semantics, errors, imports/modules, and representative options;
3. generated CSS passes the recovery-disabled ZigCSS parser and the integrated result is deterministic under repeated and parallel execution;
4. package installation, offline execution after install, all claimed platforms, watch/batch behavior, time/output/resource limits, and production dependency audits pass;
5. the machine-readable matrix, CLI help, README, website, and release metadata all describe the exact admitted provider/version boundary; and
6. no code path silently falls back to CSS, deletes unsupported syntax, emits partial CSS, or enables executable extensions outside trusted-project-code mode.

An adapter may graduate independently; one provider's success does not change another row. “Full SCSS/Sass/Less/Stylus support” is publishable only as full canonical language behavior for the named pinned versions and documented host options. Ecosystem-plugin parity remains a separate claim.

## Consequences

Positive consequences:

- ZigCSS reuses the actual language authorities instead of rebuilding heuristic approximations.
- The stable CSS parser, transforms, emitter, result ownership, diagnostics, dependencies, and release discipline remain one shared core.
- Provider versions, licenses, trust boundaries, and graduation evidence are explicit and machine-checkable.
- Each language can graduate independently without weakening failure behavior for the others.

Costs and constraints:

- The npm integration gains exact runtime dependencies and a supported-Node requirement that must be audited and packaged deliberately.
- The first integrated preprocessor path is not a single-file native executable; native-only consumers retain CSS-only behavior unless they configure a compatible host.
- Two-stage source maps, filesystem confinement, cancellation, watch dependencies, and normalized diagnostics require dedicated engineering before any public support claim.
- Canonical providers can differ in APIs and ecosystem conventions, so one transport does not imply one lowest-common-denominator language feature set.
- Upstream version updates are release work, not automatic dependency refreshes.

## Rejected alternatives

- **Reimplement all four languages natively in Zig.** Rejected because it creates four new semantic authorities and delays credible compatibility behind years of parity work.
- **Restore the removed byte preprocessors as experimental.** Rejected because an experimental label does not prevent silent corruption.
- **Spawn provider CLIs through a shell.** Rejected because quoting, ambient executable discovery, unbounded streams, and inconsistent diagnostics enlarge the security and determinism boundary.
- **Advertise support as soon as a canonical package compiles one fixture.** Rejected because source maps, imports, diagnostics, dependencies, limits, packaging, and negative behavior are part of the user contract.
- **Enable arbitrary plugins and application callbacks by default.** Rejected because executing project code is a materially different trust model from compiling stylesheet input.
- **Bundle provider behavior into the public untrusted compile endpoint.** Rejected until a separately reviewed service-isolation program proves it safe.
