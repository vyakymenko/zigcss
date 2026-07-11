# Recovery CLI

The current command-line interface is experimental. Run `zigcss --help` for its authoritative option list.

## Available options

| Option | Behavior |
|---|---|
| `-o`, `--output <path>` | Write one output file, or name the destination directory with `--output-dir`. |
| `--output-dir` | Enable explicit multi-input output planning. It requires multiple inputs and `-o`. |
| `--minify` | Emit compact whitespace without running AST transforms. |
| `--watch` | Recompile one input when its content changes. |
| `--profile` | Print stage timings. |
| `--lsp` | Start the experimental language server. |
| `-h`, `--help` | Print the current contract. |

## Explicitly unavailable

`--optimize`, `--source-map`, `--autoprefix`, `--browsers`, and `--critical-*` fail with an explanation. They are not accepted no-ops.

The recovery CLI also rejects legacy preprocessor and alternate-format extensions. Those adapters are experimental internals until each language has a compatibility decision, strict unsupported-syntax diagnostics, and dedicated evidence.

## Output safety

Before reading and compiling inputs, the CLI plans destinations and rejects paths that resolve to an input, including relative aliases, symlinks, and hard links. It also rejects duplicate batch destinations.

- [Current status](/guide/status)
- [Build from source](/guide/build-from-source)
