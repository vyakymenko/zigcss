# Recovery CLI

The current command-line interface is experimental. Run `zigcss --help` for its authoritative option list.

All supported CSS modes delegate to one public `zigcss.compile` call site. The CLI owns arguments, path safety, file I/O, diagnostic rendering, and writes, while parsing, verified optimization, and emission remain inside the same owned library contract used by Zig consumers.

## Available options

| Option | Behavior |
|---|---|
| input `-` | Read one bounded CSS input from stdin and report its source as `<stdin>`. It cannot participate in batch or watch mode. |
| `-o`, `--output <path or ->` | Write one output file, select stdout with `-`, or name the destination directory with `--output-dir`. |
| `--output-dir` | Enable explicit multi-input output planning. It requires multiple inputs and `-o`. |
| `--syntax css` | Select the only supported stable syntax explicitly; CSS is also the default. Other values fail as usage errors. |
| `--minify` | Emit compact whitespace; this is independent of `--optimize`. |
| `--optimize` | Run the closed verified cleanup/semantic preset to a bounded byte-stable fixed point. |
| `--watch` | Recompile one input when its content or a direct local relative CSS import changes. |
| `--profile` | Print one end-to-end public compile-call timing; accurate internal stage and allocator metrics belong to `PROF-010`. |
| `--lsp` | Start the experimental language server. |
| `-V`, `--version` | Print the package-synchronized version to stdout. |
| `-h`, `--help` | Print the current contract. |

Every boolean or valued option may appear at most once. Help and version must be used alone. Stdin may appear once and only as the sole input; `--watch` requires a file, `--profile` requires one input, and batch output cannot be stdout. No option is silently ignored.

## Streams and exit status

With no `-o`, one file or stdin emits CSS to stdout. `-o -` requests stdout explicitly; `-o <path>` writes a file. Help/version and successful compilation exit `0`. Parser/transform diagnostics and operational read/write failures exit `1`. Missing input or values, unknown/duplicate/unavailable flags, unsupported syntax, and incoherent stream/batch/watch combinations exit `2`. Informational text and CSS use stdout; warnings, diagnostics, and usage errors use stderr. The npm launcher inherits all three streams, propagates exact native exit codes, and re-raises POSIX termination signals.

## Explicitly unavailable

`--source-map`, `--autoprefix`, `--browsers`, and `--critical-*` fail with an explanation. They are not accepted no-ops.

`--optimize` does not call the inherited optimizer. It admits exactly seven verified order-preserving passes, grants only cleanup and semantic-rewrite authority, and repeats parse-transform-emit under a 32-round bound until two consecutive outputs are byte-identical. Experimental passes, compatibility rewriting, extraction, custom-property resolution, logical-to-physical conversion, and reorder authority are absent. A validation, allocation, reparse, or convergence failure writes no CSS.

The library has a verified target-prefix pass for a pinned eight-feature subset, but the recovery CLI does not yet carry its strict target query or authorization contract. The rejected flags cannot reach the inherited autoprefixer or the rebuilt pass.

The library also has two experimental conservative extraction passes over complete class/ID inventories. They require explicit experimental and extraction policy grants, and are not wired to `--optimize` or `--critical-*`; rejected CLI requests cannot reach the inherited or rebuilt implementations.

The recovery CLI also rejects legacy preprocessor and alternate-format extensions. Those adapters are experimental internals until each language has a compatibility decision, strict unsupported-syntax diagnostics, and dedicated evidence.

## Watch behavior

The watcher reads and hashes the root file once per poll and passes those exact bytes into the public compile facade; it does not reopen the source during the same attempt. After a successful parse, owned dependency evidence supplies an ordered set of direct `@import` specifiers. Unique local relative paths are resolved from the root stylesheet directory and content-hashed. Query and fragment suffixes are excluded from the filesystem path. Scheme-bearing, remote, protocol-relative, origin-absolute, and filesystem-absolute URLs are not opened by watch mode. Imports are reported facts rather than inlined compilation inputs, so dependency changes trigger a root recompilation without changing CSS semantics.

The root fingerprint is recorded before every compile attempt. An unchanged read error, parser/transform diagnostic, or output failure is therefore reported once and waits for a real root/dependency transition instead of looping twice per second. A failed parse cannot produce new dependency evidence, so the watcher conservatively retains the last successfully parsed dependency set. Duplicate imports resolving to the same platform path are polled once; missing or temporarily unreadable dependencies remain tracked and their creation or recovery counts as a change.

## Batch execution

Multi-input compilation uses a mutex-protected dynamic work index rather than static input chunks. Worker count is the smaller of the input count, detected CPU count, and an explicit process-local cap of eight. Each task owns a separate allocator that remains alive through result cleanup; workers do not concurrently allocate result data through the CLI's planning allocator.

The first observed read, compile, or diagnostic failure closes the queue. Work already running completes because the public compile call has no unsafe asynchronous interruption point, while unclaimed tasks are marked cancelled and never opened. Every started worker is joined even if a later thread cannot be created. Only an all-successful joined batch reaches the commit loop, which visits tasks in original argument order for atomic writes and status messages. Failure diagnostics are likewise rendered by input order, independent of scheduling. This preserves the no-output-on-compile-failure contract while keeping CLI-012's documented per-destination limitation for operational failures during the later commit loop.

## Output safety

Before reading and compiling inputs, the CLI plans file destinations and rejects paths that resolve to an input, including relative aliases, symlinks, and hard links. It also rejects duplicate final destinations. The `-` stream sentinel is never treated as a filesystem path.

Every file destination is written through a temporary file in its parent directory and atomically replaced only after the complete CSS result is ready. Missing parents are created at that commit point; a failed parse or transform therefore creates no output directory. Existing destination symlinks and hard links are replaced rather than followed, and a failed write or rename removes its temporary file while preserving the old destination. Existing regular-file permissions are retained.

Batch naming is deterministic and independent of argument order. A unique input stem becomes `<stem>.css`; colliding stems receive a 16-digit lowercase hash of the normalized working-directory-relative input path. Final basenames are limited to 128 bytes, with `zigcss-<hash>.css` used when a stem would exceed the bound. The final canonical/inode collision check remains authoritative, including the unlikely case of a hash collision. Each destination is atomic, but the batch is not a multi-file transaction: an operational failure while committing a later file can leave earlier files committed.

Valid inputs are parsed completely before emission. Structured parser diagnostics include the input name, line, column, and code; failed single or batch compilation writes no partial CSS. Optimized fixed-point rounds are reparsed without recovery before any final write.

- [Current status](/guide/status)
- [CSS compatibility](/guide/css-compatibility)
- [Build from source](/guide/build-from-source)
