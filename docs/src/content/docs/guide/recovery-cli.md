# Recovery CLI

The current command-line interface is experimental. Run `zigcss --help` for its authoritative option list.

## Available options

| Option | Behavior |
|---|---|
| `-o`, `--output <path>` | Write one output file, or name the destination directory with `--output-dir`. |
| `--output-dir` | Enable explicit multi-input output planning. It requires multiple inputs and `-o`. |
| `--minify` | Emit compact whitespace; this is independent of `--optimize`. |
| `--optimize` | Run the closed verified cleanup/semantic preset to a bounded byte-stable fixed point. |
| `--watch` | Recompile one input when its content changes. |
| `--profile` | Print stage timings. |
| `--lsp` | Start the experimental language server. |
| `-h`, `--help` | Print the current contract. |

## Explicitly unavailable

`--source-map`, `--autoprefix`, `--browsers`, and `--critical-*` fail with an explanation. They are not accepted no-ops.

`--optimize` does not call the inherited optimizer. It admits exactly seven verified order-preserving passes, grants only cleanup and semantic-rewrite authority, and repeats parse-transform-emit under a 32-round bound until two consecutive outputs are byte-identical. Experimental passes, compatibility rewriting, extraction, custom-property resolution, logical-to-physical conversion, and reorder authority are absent. A validation, allocation, reparse, or convergence failure writes no CSS.

The library has a verified target-prefix pass for a pinned eight-feature subset, but the recovery CLI does not yet carry its strict target query or authorization contract. The rejected flags cannot reach the inherited autoprefixer or the rebuilt pass.

The library also has two experimental conservative extraction passes over complete class/ID inventories. They require explicit experimental and extraction policy grants, and are not wired to `--optimize` or `--critical-*`; rejected CLI requests cannot reach the inherited or rebuilt implementations.

The recovery CLI also rejects legacy preprocessor and alternate-format extensions. Those adapters are experimental internals until each language has a compatibility decision, strict unsupported-syntax diagnostics, and dedicated evidence.

## Output safety

Before reading and compiling inputs, the CLI plans destinations and rejects paths that resolve to an input, including relative aliases, symlinks, and hard links. It also rejects duplicate batch destinations.

Valid inputs are parsed completely before emission. Structured parser diagnostics include the input name, line, column, and code; failed single or batch compilation writes no partial CSS. Optimized fixed-point rounds are reparsed without recovery before any final write.

- [Current status](/guide/status)
- [CSS compatibility](/guide/css-compatibility)
- [Build from source](/guide/build-from-source)
