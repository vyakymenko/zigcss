# ZigCSS canonical preprocessor host

Status: internal `PRE-002` boundary. SCSS, indented Sass, Less, and Stylus are still publicly unavailable. The production registry recognizes their accepted provider IDs but deliberately contains no provider implementation until each adapter package lands and passes its own admission gates.

## Wire contract

`zigcss-preprocessor-v1` is a one-request-per-process protocol. Standard input contains exactly one frame followed by EOF. Standard output contains exactly one terminal frame. Any stderr byte is an operational failure.

A frame is a four-byte unsigned big-endian payload length followed by that many UTF-8 JSON bytes. Zero-length, truncated, oversized, malformed, second, or trailing frames fail. Request and response objects use exact field sets; unknown fields fail rather than being ignored.

The compile request contains the protocol name, a bounded opaque request ID, the literal `compile` operation, an exact provider ID, its matching syntax, source text, a null or absolute local file source URL, and the closed common options `style`, `sourceMap`, and `loadPaths`. Provider ownership is fixed:

| Provider ID | Syntaxes | Accepted package baseline |
|---|---|---|
| `dart-sass` | `scss`, `sass` | `sass` `1.101.0` |
| `less` | `less` | `less` `4.6.7` |
| `stylus` | `stylus` | `stylus` `0.64.0` |

A success contains complete CSS, a nullable source map, ordered diagnostics, and ordered dependencies. A failure contains only a bounded code and sanitized message—never CSS, a partial result, a stack, or an internal filesystem error. Request IDs must match across the exchange.

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
| Load-path entries | 64, with path confinement deferred to `PRE-003` before imports are enabled |
| Diagnostics / dependencies | 1,000 / 4,096 |

The outer supervisor validates and frames the request before spawn, executes the current absolute Node runtime with the absolute regular non-symlink host file, sets `shell: false`, strips `PATH`, `HOME`, `NODE_OPTIONS`, and `NODE_PATH`, and the child deletes any OS-injected environment key before provider loading. It bounds every stream and resolves only after the child has closed. Timeout, overflow, stderr, nonzero exit, signal, malformed response, extra response, and request-ID mismatch terminate or reject the process without returning CSS.

## Trust boundary

The host core imports no networking or child-process modules and performs no dynamic imports. The production provider registry is closed and version-bound; it does not discover packages from user input or ambient paths. Provider source bytes are framed stdin data and are never command arguments or shell text.

`PRE-003` will add canonical local-path confinement before providers may load dependencies. `PRE-004` will complete normalized diagnostics, dependency facts, and two-stage source-map ownership. Executable plugins, custom functions, and custom importers remain outside this protocol's default trust boundary and require the separately gated `trusted-project-code mode` from ADR-012.
