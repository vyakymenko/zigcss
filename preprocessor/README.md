# ZigCSS canonical preprocessor host

Status: internal `PRE-002` through `PRE-004`, `SASS-010` through `SASS-012`, and `LESS-010`. SCSS and indented Sass have passed the internal exact-provider, confined-import, pinned-corpus, negative, limit, determinism, and generated-CSS gates. The exact Less renderer is connected only for pre-admission work; its imports, corpus, and product gates remain incomplete. SCSS, indented Sass, Less, and Stylus are still publicly unavailable. No provider becomes a public format until its remaining product, packaging, and graduation gates pass.

## Wire contract

`zigcss-preprocessor-v1` is a one-request-per-process protocol. Standard input contains exactly one frame followed by EOF. Standard output contains exactly one terminal frame. Any stderr byte is an operational failure.

A frame is a four-byte unsigned big-endian payload length followed by that many UTF-8 JSON bytes. Zero-length, truncated, oversized, malformed, second, or trailing frames fail. Request and response objects use exact field sets; unknown fields fail rather than being ignored.

The compile request contains the protocol name, a bounded opaque request ID, the literal `compile` operation, an exact provider ID, its matching syntax, source text, a null or absolute local file source URL, and the closed common options `style`, `sourceMap`, `loadPaths`, and `providerOptions`. Dart Sass accepts exactly the boolean provider options `charset`, `quietDeps`, and `verbose`; Less and Stylus currently accept an empty provider-option object. Unknown, missing, cross-provider, executable, and dynamically discovered options fail validation. Provider ownership is fixed:

| Provider ID | Syntaxes | Accepted package baseline | Internal stage |
|---|---|---|---|
| `dart-sass` | `scss`, `sass` | `sass` `1.101.0` | `SASS-012`; canonical conformance internal only |
| `less` | `less` | `less` `4.6.7` | `LESS-010`; canonical renderer internal only |
| `stylus` | `stylus` | `stylus` `0.64.0` | Not connected |

A success contains complete CSS, a nullable source map, ordered diagnostics, and ordered dependencies. A failure contains only a bounded code, sanitized message, and ordered normalized diagnostics—never CSS, a partial result, a stack, or an internal filesystem error. Generic host failures use an empty diagnostic list. Request IDs must match across the exchange.

## Fixed ceilings

| Resource | Ceiling |
|---|---|
| Source text | 10 MiB UTF-8 |
| Request frame | source ceiling plus bounded protocol metadata |
| CSS output | 20 MiB UTF-8 |
| Response frame | output ceiling plus bounded result metadata |
| Provider deadline | 8 seconds |
| Supervising process deadline | 10 seconds; internal callers may lower it, never exceed 30 seconds |
| Stderr capture | 64 KiB, while any stderr byte still fails the exchange |
| Load-path entries | 64 absolute unique paths, confined by `PRE-003` before providers are enabled |
| Diagnostics / dependencies | 1,000 / 4,096 |

The outer supervisor validates and frames the request before spawn, executes the current absolute Node runtime with the absolute regular non-symlink host file, sets `shell: false`, strips `PATH`, `HOME`, `NODE_OPTIONS`, and `NODE_PATH`, and the child deletes any OS-injected environment key before provider loading. It bounds every stream and resolves only after the child has closed. Timeout, overflow, stderr, nonzero exit, signal, malformed response, extra response, and request-ID mismatch terminate or reject the process without returning CSS.

## Trust boundary

The host core imports no networking or child-process modules and performs no dynamic imports. The production provider registry is closed and version-bound; Dart Sass and Less are static exact dependencies and no provider is discovered from user input or ambient paths. Provider source bytes are framed stdin data and are never command arguments or shell text.

`PRE-003` adds canonical local-path confinement before providers may load dependencies. `PRE-004` adds normalized diagnostics, canonical dependency facts, and two-stage source-map ownership. Executable plugins, custom functions, and custom importers remain outside this protocol's default trust boundary and require the separately gated `trusted-project-code mode` from ADR-012.

## Result metadata and source maps

`PRE-004` accepts only the exact normalized diagnostic shape: severity, optional bounded code, sanitized message, canonical local source URL, and nullable one-based line and column. Provider deprecations become warnings, provider order is preserved, and ANSI/control bytes are removed before the result crosses the host boundary. Compile failures may own those same diagnostics but can never own CSS or a partial result.

Dependency facts contain only a canonical local file URL and one of `import`, `use`, `forward`, or `reference`. They preserve first-success order and deduplicate by URL. The confined loader remains the authority for file bytes; metadata normalization does not grant filesystem access.

When both stages emit maps, composition parses only strict non-indexed Source Map v3 JSON. Every final ZigCSS mapping must target the one named intermediate CSS source. Each mapped segment is traced through the provider map with greatest-lower-bound lookup; generated or unmapped regions stay unmapped. UTF-16 columns, provider source content, source roots, and names are preserved. Unknown extensions, malformed VLQ data, invalid indices, duplicate intermediate sources, oversized maps, or either missing map reject the entire composition without returning a partial map.

## Internal Dart Sass adapter

`SASS-010` pins `sass` `1.101.0`/MIT and calls the modern asynchronous `compileStringAsync` API for both protocol syntaxes: `scss` maps to Dart Sass `scss`, while `sass` maps to its `indented` syntax. Expanded and compressed output, warnings, parse failures, cancellation ownership, and provider Source Map v3 bytes have exact regressions. The closed provider options map directly to Dart Sass's `charset`, `quietDeps`, and `verbose` booleans; colored alerts are always disabled so diagnostics remain deterministic. The pinned package requires Node.js 20.19.0 or newer; that future npm runtime floor is not a public package claim until `PRE-006` updates and validates every release surface.

Each entry still compiles under a stable non-file virtual URL, so Dart Sass never receives native entry-file or native load-path authority. Built-in `sass:` modules remain available. A filesystem load requires at least one explicit confined root. Entry-relative lookup runs only when the declared source URL is inside an explicit root; otherwise ordered load-path importers own lookup. Absolute `file:` URLs are admitted only when the confined resolver proves the resulting stylesheet belongs to those same roots. Network and unknown schemes, lexical or canonical escapes, links, special or unreadable files, unstable reads, invalid UTF-8, ambiguity, cycles, and exhausted limits fail without CSS.

The adapter reproduces Dart Sass's partial/full ambiguity groups, `.sass`/`.scss` before `.css`, explicit-extension behavior, directory indexes, and legacy `.import` precedence. `@use` and `@forward` loads are recorded as `reference` because Dart Sass's public importer context distinguishes only legacy `@import`; legacy loads retain `import`. Facts preserve first-success order and canonical local URLs. Imported diagnostics use their owned file identity, provider maps include source content for the entry and every dependency, and real Unicode provider maps pass the strict two-stage composer. The adapter deliberately lowers its ancestry ceiling to 32: a red measurement found that constructing Dart Sass's nested failure above its safe callback depth could amplify memory before the host deadline, so ZigCSS rejects earlier through `PRE-003`.

`quietDeps` follows Dart Sass ownership: ordered load-path dependencies may be silenced, while entry-relative warnings remain visible. `verbose` owns deprecation repetition and `charset` owns emitted UTF-8 markers; colored alerts remain disabled. Custom functions, package importers, user importers, and every executable extension point remain outside the default trust boundary.

`SASS-012` pins the MIT-licensed official Sass-spec revision `1b03109a6205c8cff146defeae8488094b147c88`, selected at the exact Dart Sass `1.101.0` tag timestamp. Its checksum-owned 80-case corpus contains 60 successes and 20 failures across SCSS and indented Sass. Every case matches the provider directly for CSS or terminal failure, diagnostics, and dependency order, then repeats identically with eight bounded workers. All 60 generated CSS results parse with independent recovery disabled and parse/emit idempotently through ZigCSS. A 1,001-warning regression proves the 1,000-diagnostic limit fails without CSS. The focused suites separately own protocol, source-map, cancellation, filesystem, ambiguity, cycle, encoding, and depth boundaries.

This closes the internal canonical-language conformance package, not public admission. `.scss` and `.sass` remain rejected by the public CLI until `PRE-005`, `PRE-006`, and per-row `PRE-008` product, package, platform, and consumer gates pass. This work does not make any preprocessor syntax available publicly.

## Internal Less renderer adapter

`LESS-010` pins `less` `4.6.7`/Apache-2.0 and calls its asynchronous programmatic `less.render` API. The adapter passes source bytes directly to the canonical parser and evaluator, owns exact expanded and compressed output, normalizes terminal errors, supports deterministic provider Source Map v3 output for the entry source, checks cancellation before and after provider evaluation, and returns no dependency facts at this stage. Its complete 15-package transitive and optional closure is lockfile-bound and license-reviewed. The package requires Node.js 18 or newer, remains development-only, and is excluded from the public npm fileset.

Less never receives the request's real entry filename. Rendering uses a stable virtual filename plus a per-request highest-priority file manager that rejects every asynchronous and synchronous load. This blocks adjacent and absolute imports, optional or inline imports, HTTP(S) imports, `data-uri`, image inspection functions, and any other provider file access; a suppressed optional import still fails after rendering because the attempted read is owned separately. Plain CSS imports remain canonical emitted CSS and do not cause provider I/O. Nonempty load paths remain unavailable until `LESS-011` routes all candidate bytes through `PRE-003`.

The adapter always sets `javascriptEnabled: false` and `disablePluginRule: true`. Inline JavaScript and `@plugin` fail with explicit CSS-free provider errors, while request options cannot inject plugins, functions, preprocessors, postprocessors, file managers, or other executable objects. Source maps include the exact request source content, replace only the virtual entry identity with the owned source URL, and omit provider-authored mapping annotations from CSS. Repeated, 12-way parallel, and real framed-host rendering are byte-deterministic.

This renderer checkpoint does not establish full Less support. Imports, load-path semantics, dependency/watch facts, the wider diagnostic and map surface, official/integration corpus differentials, packaging, platforms, batch/watch behavior, and public product admission remain `LESS-011`, `LESS-012`, `PRE-005`, `PRE-006`, and `PRE-008`. The public `.less` row remains unavailable and unverified.

## Confined local loader

`PRE-003` adds a provider-independent loader for concrete local candidates. It deliberately does **not** implement Sass partial/extension search, Less import rules, or Stylus lookup semantics. Each canonical adapter remains responsible for using its provider's real resolution semantics and must pass the resulting absolute candidate URL through this loader before returning bytes.

The loader accepts only absolute `file:` URLs under explicit regular directory roots. It rejects credentials, queries, fragments, encoded separators, non-local schemes, lexical or canonical root escapes, every symlink entry, missing/unreadable paths, directories, and other special files. It opens the canonical path read-only with no-follow behavior where the platform provides it, verifies regular-file identity and metadata before and after a bounded positional read, and fails if the path or bytes change during loading.

Each compilation owns one session. The default ceilings are 10 MiB per file, 40 MiB across reads, 4,096 unique files, 8,192 read attempts, and 64 ancestry levels; callers may lower but never raise the hard limits. Canonical ancestry is explicit and root-confined, so duplicate ancestry, candidate cycles, and excessive depth fail before bytes become a provider result. Successful reads return owned bytes and one canonical URL. Dependency facts are ordered by first successful load and deduplicated by canonical URL, while duplicate reads still consume read and byte budgets.

The pre-admission Dart Sass adapter consumes this loader for every dependency byte. The pre-admission Less renderer is connected without filesystem authority and must consume the same loader before imports can be enabled in `LESS-011`. These boundaries remain the file and result authority that `LESS-011` and `STYLUS-011` must consume. This work does not make any preprocessor syntax available publicly.
