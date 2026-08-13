# Native CLI contract

The ZigCSS source-built binary owns one combined command for CSS, SCSS, indented Sass, Less, and Stylus. Run `zig-out/bin/zigcss --help` for the authoritative option list.

CSS enters the stable native compile facade. SCSS, indented Sass, Less, and Stylus enter self-contained native Zig parser/evaluators, then their complete generated CSS passes through the same recovery-disabled core. The root JavaScript launcher only locates and invokes the binary; it hosts no language semantics. The public npm release candidate `0.4.0-rc.3` predates this five-language surface, so this page describes the green source snapshot rather than an installed public release.

## Inputs and native frontends

| Syntax | Selection | Engine |
|---|---|---|
| CSS | default or `--syntax css` | Native ZigCSS core |
| SCSS | explicit `--syntax scss` | Native Zig Sass-family frontend |
| Indented Sass | explicit `--syntax sass` | Native Zig Sass-family frontend |
| Less | explicit `--syntax less` | Native Zig Less frontend |
| Stylus | explicit `--syntax stylus` | Native Zig Stylus frontend |

Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 are development-only reference oracles. They do not run during compilation and do not enter production dependencies, archives, installed packages, or runtime SBOM closure.

CSS Modules, CSS-in-JS, PostCSS-like inputs, and Tailwind-like inputs do not fall back to CSS. They remain explicit unavailable-format errors.

## Options

| Option | Behavior |
|---|---|
| input `-` | Read one bounded UTF-8 input from stdin. Preprocessor stdin needs an explicit `--syntax`. |
| `-o`, `--output <path or ->` | Write one output file, select stdout with `-`, or name the destination directory with `--output-dir`. |
| `--output-dir` | Enable explicit multi-input output planning. It requires multiple inputs and `-o`. |
| `--syntax <css or scss or sass or less or stylus>` | Select the input grammar explicitly. A file extension and explicit syntax must agree. |
| `--load-path <directory>` | Add a confined preprocessor import root. It is repeatable, ordered, and unavailable for native CSS. |
| `--minify` | Emit compact whitespace; this remains independent of `--optimize`. |
| `--optimize` | Run the closed verified ZigCSS optimizer after native preprocessing. |
| `--source-map` | For the four native preprocessor frontends, compose their mappings with the ZigCSS core into one deterministic inline map. It cannot be combined with `--optimize`. Native CSS map output remains unavailable. |
| `--watch` | Recompile one input when the entry or an owned confined dependency changes. |
| `--profile` | Native CSS only: report public compile stages and requested-memory metrics. |
| `--lsp` | Native CSS only: start the experimental language server. |
| `-V`, `--version` | Print the package-synchronized version. |
| `-h`, `--help` | Print the combined five-language contract. |

Every boolean or valued option may appear at most once. Help and version must be used alone. Stdin may appear only as the sole input; watch requires one file; multiple files require `--output-dir`; batch output cannot be stdout. Unknown or incompatible options fail rather than becoming no-ops.

## Streams and exit status

With no `-o`, one file or stdin emits CSS to stdout. `-o -` selects stdout explicitly. Informational text and CSS use stdout; warnings, diagnostics, watch status, and usage errors use stderr.

| Status | Meaning |
|---|---|
| `0` | Successful compilation or informational command |
| `1` | Compilation, native frontend, generated-CSS, read, write, or operational failure |
| `2` | Invalid syntax selection, unknown option, missing value, or incoherent stream/batch/watch configuration |

The JavaScript launcher preserves exact native exit codes and re-raises POSIX termination signals. Native cancellation terminates bounded work and cannot return partial CSS.

## Import and execution boundary

File compilation automatically confines the entry directory. Each `--load-path` adds another explicit root. The resolver rejects lexical or canonical escapes, symbolic links, special files, unstable reads, invalid UTF-8, cycles, excess ancestry, and resource exhaustion. Network schemes and ambient package discovery are disabled.

The native contract does not enable project plugins, custom functions, custom importers, Less JavaScript, Stylus evaluator hooks, or arbitrary executable project code. Matching a development oracle does not grant those extension points implicitly.

## Batch execution

Mixed CSS/preprocessor batches are accepted in argument order. Worker count is bounded by the input count, available CPUs, and a process cap of eight. Each task owns its native compiler result. The first failure closes the queue; already-running tasks finish safely, unclaimed tasks never open, and no output commit begins unless every compilation succeeded.

Unique input stems become `<stem>.css`. Colliding stems receive a deterministic 16-digit digest of the normalized working-directory-relative path. Final basenames have a 128-byte ceiling. Results and diagnostics are committed or rendered in original argument order, independent of scheduling.

## Watch behavior

Watch mode hashes one owned entry snapshot and uses result dependency facts to track native confined imports. It supports all five syntaxes. New, changed, missing, and recovered dependencies trigger one recompilation. A failed attempt keeps the last successful dependency set and retains the last successful output.

Dependency polling uses the same confined roots as compilation. Remote URLs, protocol-relative URLs, absolute unowned paths, query/fragment aliases, links, and excessive dependency sets are not opened. Cancellation stops polling and native frontend work without one extra compile.

## Output safety

Before reading inputs, the CLI rejects destinations that resolve to an input and duplicate final destinations, including relative aliases, symlinks, and hard links. Each file is written to a unique temporary neighbor, synced, and atomically renamed only after a complete valid result exists. Compilation failures therefore create no partial CSS or output directory.

An operational failure while committing a later batch file can leave earlier files committed; output files are individually atomic, not one multi-file filesystem transaction.

## Native optimizer and profiling boundaries

`--optimize` admits exactly the verified order-preserving pass preset and repeats parse-transform-emit to a bounded byte-stable fixed point. Experimental extraction, compatibility rewriting, custom-property resolution, logical-to-physical conversion, and reorder authority are absent.

Native CSS `--profile` reports one monotonic public compile total, actual stage intervals, and allocator-requested byte metrics. It does not claim RSS or operating-system memory. Profiling is not yet exposed across the native preprocessor bridge, so preprocessor requests reject that flag rather than report an incomplete number.

- [Format compatibility](/guide/format-compatibility)
- [Current status](/guide/status)
- [CSS compatibility](/guide/css-compatibility)
- [Build from source](/guide/build-from-source)
