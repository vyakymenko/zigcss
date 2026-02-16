# Language Server Protocol (LSP) Support

zcss includes a full LSP server implementation for editor integration, providing real-time diagnostics, hover information, and code completion.

## Starting the LSP Server

```bash
zcss --lsp
```

The LSP server communicates via JSON-RPC over stdin/stdout, following the Language Server Protocol specification.

## Supported LSP Features

### Diagnostics

Real-time error and warning reporting for CSS parsing issues:

- Syntax errors
- Invalid property values
- Missing selectors
- Parse errors with position information

### Hover Information

Hover support for CSS properties with descriptions and value types:

- Property descriptions
- Value type information
- Browser compatibility (when available)

### Code Completion

Code completion for common CSS properties:

- Property names
- Property values
- Selectors

### Text Document Sync

Full support for document open, change, and close events:

- Document synchronization
- Incremental updates
- Efficient change tracking

## Editor Integration

### VSCode

**Option 1: Use the VSCode Extension (Recommended)**

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

**Option 2: Manual Configuration**

Add to your `.vscode/settings.json`:

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

### Neovim

**Using nvim-lspconfig:**

```lua
use {
  'neovim/nvim-lspconfig',
  config = function()
    require('lspconfig').zcss.setup({
      cmd = {'zcss', '--lsp'},
      filetypes = {'css', 'scss', 'sass', 'less', 'stylus'},
    })
  end
}
```

**Features:**
- Diagnostics with `[d` / `]d` navigation
- Hover information with `K`
- Code completion
- Go to definition with `gd`
- Find references with `gr`

### Other Editors

The LSP server can be integrated with any editor that supports LSP:

- **Vim**: Use with `vim-lsp` or `coc.nvim`
- **Emacs**: Use with `lsp-mode` or `eglot`
- **Sublime Text**: Use with `LSP` package
- **Atom**: Use with `atom-languageclient`

All integrations use the standard LSP protocol via `zcss --lsp`.

## Supported File Types

- CSS (`.css`)
- SCSS (`.scss`)
- SASS (`.sass`)
- LESS (`.less`)
- Stylus (`.styl`)
- PostCSS (`.postcss`)

## Next Steps

- [Installation](/guide/installation) — Install zcss
- [Quick Start](/guide/quick-start) — Learn the basics
