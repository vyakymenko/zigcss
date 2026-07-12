# zigcss VSCode Extension

> Experimental: this client is not a stable editor package. CSS diagnostics and syntax-aware features use rebuilt compiler data, while protocol stress coverage and extension packaging remain incomplete.

VSCode client prototype for ZigCSS Language Server Protocol development.

## Features

- **Compiler-backed diagnostics** - LSP 3.17 pull reports expose recoverable CSS diagnostics with codes and UTF-16 ranges
- **Full document synchronization** - Open documents and strictly versioned complete replacements share one owned server state
- **Explicit format containment** - Removed and library-only stylesheet formats receive an unavailable-format diagnostic instead of CSS fallback
- **Syntax-aware editing** - Hover, property completion, document/workspace symbols, definition, references, and rename use typed indexes rather than unrestricted text matching
- **Bounded open-document workspace** - Cross-file results cover currently open CSS documents in deterministic URI/source order; the server does not scan the filesystem or resolve an unopened project graph

## Installation

### From Source

1. Build zigcss:
   ```bash
   git clone https://github.com/vyakymenko/zigcss.git
   cd zigcss
   zig build -Doptimize=ReleaseFast
   ```

2. Install the extension:
   ```bash
   cd vscode-extension
   npm install
   npm run compile
   ```

3. Press `F5` in VSCode to launch a new window with the extension loaded.

### Configuration

The extension can be configured in VSCode settings:

```json
{
  "zigcss.languageServerPath": "zigcss",
  "zigcss.languageServerArgs": ["--lsp"]
}
```

If `zigcss` is not in your PATH, provide the full path:

```json
{
  "zigcss.languageServerPath": "/path/to/zigcss/zig-out/bin/zigcss"
}
```

## Requirements

- zigcss binary (built from source or installed)
- VSCode 1.74.0 or later

## Development

```bash
npm install
npm run compile
npm run watch  # For development with auto-recompilation
```

## License

MIT
