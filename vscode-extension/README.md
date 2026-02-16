# zigcss VSCode Extension

VSCode extension for zigcss Language Server Protocol support.

## Features

- **Real-time diagnostics** - Get instant feedback on CSS parsing errors
- **Hover information** - See CSS property descriptions and value types
- **Code completion** - Autocomplete for common CSS properties
- **Multi-format support** - Works with CSS, SCSS, SASS, LESS, and Stylus files

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
