# zigcss VSCode Extension

> Experimental: this client is not a stable editor package. CSS diagnostics use the rebuilt public compiler, while syntax-aware editor features and extension packaging remain incomplete.

VSCode client prototype for ZigCSS Language Server Protocol development.

## Features

- **Compiler-backed diagnostics** - LSP 3.17 pull reports expose recoverable CSS diagnostics with codes and UTF-16 ranges
- **Full document synchronization** - Open documents and strictly versioned complete replacements share one owned server state
- **Explicit format containment** - Removed and library-only stylesheet formats receive an unavailable-format diagnostic instead of CSS fallback
- **Prototype language activation** - Hover, completion, symbols, and navigation are not advertised until their syntax-aware implementations are complete

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
