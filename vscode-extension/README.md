# zigcss VSCode Extension

> Experimental: this client is not published and does not bundle a ZigCSS binary. Its lockfile, tests, bundle, and pre-release VSIX contents are verified locally and in CI.

VSCode client prototype for ZigCSS Language Server Protocol development.

## Features

- **Compiler-backed diagnostics** - LSP 3.17 pull reports expose recoverable CSS diagnostics with codes and UTF-16 ranges
- **Full document synchronization** - Open documents and strictly versioned complete replacements share one owned server state
- **CSS-only activation** - The client does not register unavailable preprocessors or override their existing language integrations
- **Syntax-aware editing** - Hover, property completion, document/workspace symbols, definition, references, and rename use typed indexes rather than unrestricted text matching
- **Bounded open-document workspace** - Cross-file results cover currently open CSS documents in deterministic URI/source order; the server does not scan the filesystem or resolve an unopened project graph
- **Protocol stress coverage** - Real transcripts cover malformed-request recovery, Unicode ranges, a synchronized document above 1 MiB, close invalidation, and repeated leak-checked index lifecycles
- **Predictable binary discovery** - A configured absolute executable or bare PATH command is checked first; otherwise discovery checks an extension-local `bin` directory and absolute PATH entries without executing workspace-relative files

## Installation

### From Source

1. Build zigcss:
   ```bash
   git clone https://github.com/vyakymenko/zigcss.git
   cd zigcss
   zig build -Doptimize=ReleaseFast
   ```

2. Install and verify the extension dependencies:
   ```bash
   cd vscode-extension
   npm ci --ignore-scripts
   npm test
   npm run package:check
   ```

3. Press `F5` in VSCode to launch a new window with the extension loaded.

### Configuration

With the default empty path setting, the extension checks a future extension-local binary and then `zigcss` in absolute `PATH` directories. The current pre-release VSIX deliberately contains no binary, so a source build normally needs an explicit absolute path:

```json
{
  "zigcss.languageServerPath": "/path/to/zigcss/zig-out/bin/zigcss",
  "zigcss.languageServerArgs": ["--lsp"]
}
```

You may instead configure a bare command such as `zigcss` when it is in `PATH`. Relative paths containing `/` or `\\` are rejected; this prevents implicit execution from the workspace or current directory.

On Windows, use an absolute executable path when the binary is not in `Path`:

```json
{
  "zigcss.languageServerPath": "C:\\path\\to\\zigcss.exe"
}
```

## Requirements

- zigcss binary (built from source or installed)
- VS Code 1.91.0 or later
- Node.js 22 or later for source tests and local VSIX verification

## Development

```bash
npm ci --ignore-scripts
npm test
npm run build
npm run package:check
npm run watch  # For development with auto-recompilation
```

`package:check` builds a single bundled CommonJS entry, asks the pinned official `vsce` tool for the exact file list, creates a temporary pre-release VSIX, checks its ZIP signature and size, and removes generated output. It never publishes. To create a local VSIX intentionally, run `npm run build` followed by `npm exec -- vsce package --no-dependencies --pre-release`.

## License

MIT
