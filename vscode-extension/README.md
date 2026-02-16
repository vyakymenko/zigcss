# zcss VSCode Extension

VSCode extension for zcss Language Server Protocol support.

## Features

- **Real-time diagnostics** - Get instant feedback on CSS parsing errors
- **Hover information** - See CSS property descriptions and value types
- **Code completion** - Autocomplete for common CSS properties
- **Multi-format support** - Works with CSS, SCSS, SASS, LESS, and Stylus files

## Installation

### From Source

1. Build zcss:
   ```bash
   git clone https://github.com/vyakymenko/zcss.git
   cd zcss
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
  "zcss.languageServerPath": "zcss",
  "zcss.languageServerArgs": ["--lsp"]
}
```

If `zcss` is not in your PATH, provide the full path:

```json
{
  "zcss.languageServerPath": "/path/to/zcss/zig-out/bin/zcss"
}
```

## Requirements

- zcss binary (built from source or installed)
- VSCode 1.74.0 or later

## Development

```bash
npm install
npm run compile
npm run watch  # For development with auto-recompilation
```

## License

MIT
