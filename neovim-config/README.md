# zigcss Neovim Integration

> Experimental: the ZigCSS language server shares the legacy parser and is not a stable editor contract. Non-CSS adapters are retained only as prototypes.

Neovim configuration for ZigCSS Language Server Protocol development.

## Requirements

- Neovim 0.5.0 or later
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) plugin
- zigcss binary (built from source)

## Installation

### Using Packer

Add to your `plugins.lua` or `init.lua`:

```lua
use {
  'neovim/nvim-lspconfig',
  config = function()
    require('lspconfig').zigcss.setup({
      cmd = {'zigcss', '--lsp'},
      filetypes = {'css', 'scss', 'sass', 'less', 'stylus'},
    })
  end
}
```

### Manual Setup

1. Copy `init.lua` to your Neovim config directory:
   ```bash
   cp neovim-config/init.lua ~/.config/nvim/lua/zigcss.lua
   ```

2. Require it in your Neovim config:
   ```lua
   require('zigcss')
   ```

### Configuration

The configuration includes:
- **Diagnostics** - Real-time error and warning reporting
- **Hover** - Hover information for CSS properties
- **Completion** - Code completion for CSS properties
- **Key mappings** - Standard LSP keybindings

### Customization

You can customize the setup by modifying the configuration:

```lua
require('lspconfig').zigcss.setup({
  cmd = {'/path/to/zigcss', '--lsp'},
  filetypes = {'css', 'scss'},
  settings = {
    -- Add custom settings here
  },
  on_attach = function(client, bufnr)
    -- Custom keybindings or setup
  end,
})
```

## Key Mappings

- `K` - Hover information
- `gd` - Go to definition
- `gr` - Find references
- `<space>rn` - Rename symbol
- `<space>ca` - Code actions
- `[d` / `]d` - Navigate diagnostics
- `<space>f` - Format document

## License

MIT
