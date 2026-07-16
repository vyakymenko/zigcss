# ZigCSS canonical preprocessor host

Status: internal `PRE-002` through `PRE-004` and `SASS-010` boundary. SCSS, indented Sass, Less, and Stylus are still publicly unavailable. The production registry connects the exact Dart Sass adapter only for internal admission work; Less and Stylus still have no implementation. No provider becomes a public format until its remaining adapter, product, packaging, and graduation gates pass.

## Wire contract

`zigcss-preprocessor-v1` is a one-request-per-process protocol. Standard input contains exactly one frame followed by EOF. Standard output contains exactly one terminal frame. Any stderr byte is an operational failure.

A frame is a four-byte unsigned big-endian payload length followed by that many UTF-8 JSON bytes. Zero-length, truncated, oversized, malformed, second, or trailing frames fail. Request and response objects use exact field sets; unknown fields fail rather than being ignored.

The compile request contains the protocol name, a bounded opaque request ID, the literal `compile` operation, an exact provider ID, its matching syntax, source text, a null or absolute local file source URL, and the closed common options `style`, `sourceMap`, and `loadPaths`. Provider ownership is fixed:

| Provider ID | Syntaxes | Accepted package baseline | Internal stage |
|---|---|---|---|
| `dart-sass` | `scss`, `sass` | `sass` `1.101.0` | `SASS-010`; compile only, imports fail closed |
| `less` | `less` | `less` `4.6.7` | Not connected |
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

The host core imports no networking or child-process modules and performs no dynamic imports. The production provider registry is closed and version-bound; Dart Sass is a static exact dependency and no provider is discovered from user input or ambient paths. Provider source bytes are framed stdin data and are never command arguments or shell text.

`PRE-003` adds canonical local-path confinement before providers may load dependencies. `PRE-004` adds normalized diagnostics, canonical dependency facts, and two-stage source-map ownership. Executable plugins, custom functions, and custom importers remain outside this protocol's default trust boundary and require the separately gated `trusted-project-code mode` from ADR-012.

## Result metadata and source maps

`PRE-004` accepts only the exact normalized diagnostic shape: severity, optional bounded code, sanitized message, canonical local source URL, and nullable one-based line and column. Provider deprecations become warnings, provider order is preserved, and ANSI/control bytes are removed before the result crosses the host boundary. Compile failures may own those same diagnostics but can never own CSS or a partial result.

Dependency facts contain only a canonical local file URL and one of `import`, `use`, `forward`, or `reference`. They preserve first-success order and deduplicate by URL. The confined loader remains the authority for file bytes; metadata normalization does not grant filesystem access.

When both stages emit maps, composition parses only strict non-indexed Source Map v3 JSON. Every final ZigCSS mapping must target the one named intermediate CSS source. Each mapped segment is traced through the provider map with greatest-lower-bound lookup; generated or unmapped regions stay unmapped. UTF-16 columns, provider source content, source roots, and names are preserved. Unknown extensions, malformed VLQ data, invalid indices, duplicate intermediate sources, oversized maps, or either missing map reject the entire composition without returning a partial map.

## Internal Dart Sass adapter

`SASS-010` pins `sass` `1.101.0`/MIT and calls the modern asynchronous `compileStringAsync` API for both protocol syntaxes: `scss` maps to Dart Sass `scss`, while `sass` maps to its `indented` syntax. Expanded and compressed output, warnings, parse failures, cancellation ownership, and provider Source Map v3 bytes have exact regressions. The pinned package requires Node.js 20.19.0 or newer; that future npm runtime floor is not a public package claim until `PRE-006` updates and validates every release surface.

This stage deliberately compiles each entry under a stable non-file virtual URL. Built-in `sass:` modules remain available, while every other importer callback and every nonempty load-path request fails without CSS. This prevents Dart Sass's normal entry-relative filesystem importer from bypassing `PRE-003`. `SASS-011` must replace the rejecting importer with the confined loader, normalize loaded dependencies and full provider options, and connect two-stage map ownership; `SASS-012` must then pass the pinned corpus and direct canonical differential gate. Until those packages and product graduation pass, `.scss` and `.sass` remain rejected by the public CLI.

## Confined local loader

`PRE-003` adds a provider-independent loader for concrete local candidates. It deliberately does **not** implement Sass partial/extension search, Less import rules, or Stylus lookup semantics. Each canonical adapter remains responsible for using its provider's real resolution semantics and must pass the resulting absolute candidate URL through this loader before returning bytes.

The loader accepts only absolute `file:` URLs under explicit regular directory roots. It rejects credentials, queries, fragments, encoded separators, non-local schemes, lexical or canonical root escapes, every symlink entry, missing/unreadable paths, directories, and other special files. It opens the canonical path read-only with no-follow behavior where the platform provides it, verifies regular-file identity and metadata before and after a bounded positional read, and fails if the path or bytes change during loading.

Each compilation owns one session. The default ceilings are 10 MiB per file, 40 MiB across reads, 4,096 unique files, 8,192 read attempts, and 64 ancestry levels; callers may lower but never raise the hard limits. Canonical ancestry is explicit and root-confined, so duplicate ancestry, candidate cycles, and excessive depth fail before bytes become a provider result. Successful reads return owned bytes and one canonical URL. Dependency facts are ordered by first successful load and deduplicated by canonical URL, while duplicate reads still consume read and byte budgets.

Only the pre-admission Dart Sass compile adapter is connected. These boundaries establish the file and result authority that `SASS-011`, `LESS-011`, and `STYLUS-011` must consume. This work does not make any preprocessor syntax available publicly.
