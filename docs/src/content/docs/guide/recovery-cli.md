# npm CLI contract

The ZigCSS 0.5 development launcher owns one combined command for CSS, SCSS, indented Sass, Less, and Stylus. Run `zigcss --help` for the authoritative installed-package option list.

The launcher routes CSS directly to the native Zig executable. Canonical preprocessor inputs enter a bounded Node host, then their generated CSS passes through the same native compile boundary before output. The public npm release candidate `0.4.0-rc.3` predates this five-language surface; this page describes the green source snapshot.

## Inputs and providers

| Syntax | Detection | Engine |
|---|---|---|
| CSS | `.css` or `--syntax css` | Native ZigCSS |
| SCSS | `.scss` or `--syntax scss` | Dart Sass 1.101.0 |
| Indented Sass | `.sass` or `--syntax sass` | Dart Sass 1.101.0 |
| Less | `.less` or `--syntax less` | Less 4.6.7 |
| Stylus | `.styl` or `--syntax stylus` | Stylus 0.64.0 |

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
| `--optimize` | Run the closed verified ZigCSS optimizer after canonical preprocessing. |
| `--source-map` | For preprocessors, compose the provider and ZigCSS maps into one deterministic inline map. It cannot be combined with `--optimize`. Native CSS map output remains unavailable. |
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
| `1` | Compilation, provider, generated-CSS, read, write, or operational failure |
| `2` | Invalid syntax selection, unknown option, missing value, or incoherent stream/batch/watch configuration |

The npm launcher preserves exact native exit codes and re-raises POSIX termination signals. Provider cancellation terminates bounded work and cannot return partial CSS.

## Import and execution boundary

File compilation automatically confines the entry directory. Each `--load-path` adds another explicit root. The resolver rejects lexical or canonical escapes, symbolic links, special files, unstable reads, invalid UTF-8, cycles, excess ancestry, and resource exhaustion. Network schemes and ambient package discovery are disabled.

The default contract does not enable project plugins, custom functions, custom importers, Less JavaScript, Stylus evaluator hooks, or arbitrary executable project code. Canonical language semantics do not grant those extension points implicitly.

## Batch execution

Mixed CSS/preprocessor batches are accepted in argument order. Worker count is bounded by the input count, available CPUs, and a process cap of eight. Each task owns its result and provider session. The first failure closes the queue; already-running tasks finish safely, unclaimed tasks never open, and no output commit begins unless every compilation succeeded.

Unique input stems become `<stem>.css`. Colliding stems receive a deterministic 16-digit digest of the normalized working-directory-relative path. Final basenames have a 128-byte ceiling. Results and diagnostics are committed or rendered in original argument order, independent of scheduling.

## Watch behavior

Watch mode hashes one owned entry snapshot and uses result dependency facts to track canonical local imports. It supports all five syntaxes. New, changed, missing, and recovered dependencies trigger one recompilation. A failed attempt keeps the last successful dependency set and retains the last successful output.

Dependency polling uses the same confined roots as compilation. Remote URLs, protocol-relative URLs, absolute unowned paths, query/fragment aliases, links, and excessive dependency sets are not opened. Cancellation stops polling and provider work without one extra compile.

## Output safety

Before reading inputs, the CLI rejects destinations that resolve to an input and duplicate final destinations, including relative aliases, symlinks, and hard links. Each file is written to a unique temporary neighbor, synced, and atomically renamed only after a complete valid result exists. Compilation failures therefore create no partial CSS or output directory.

An operational failure while committing a later batch file can leave earlier files committed; output files are individually atomic, not one multi-file filesystem transaction.

## Native optimizer and profiling boundaries

`--optimize` admits exactly the verified order-preserving pass preset and repeats parse-transform-emit to a bounded byte-stable fixed point. Experimental extraction, compatibility rewriting, custom-property resolution, logical-to-physical conversion, and reorder authority are absent.

Native CSS `--profile` reports one monotonic public compile total, actual stage intervals, and allocator-requested byte metrics. It does not claim RSS or operating-system memory. Profiling is not yet composed across the JavaScript provider host, so preprocessor requests reject that flag rather than report an incomplete number.

- [Format compatibility](/guide/format-compatibility)
- [Current status](/guide/status)
- [CSS compatibility](/guide/css-compatibility)
- [Build from source](/guide/build-from-source)
