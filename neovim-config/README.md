# ZigCSS Neovim integration

> Experimental: this configuration launches the ZigCSS 0.6.0-rc.2 language server. It does not install or bundle a native binary, scan the filesystem, or enable preprocessor filetypes.

The checked-in configuration uses Neovim's built-in LSP configuration API. It does not depend on the deprecated `require('lspconfig').zigcss.setup()` framework or require `nvim-lspconfig`.

## Requirements

- Neovim 0.11.7 or later; CI smoke-tests the exact 0.11.7 minimum and current 0.12.4 release
- A trusted ZigCSS 0.6.0-rc.2 executable built from this source tree

## Install

Copy the runtime configuration into Neovim's `lsp` directory:

```bash
config_home="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
mkdir -p "$config_home/lsp"
cp neovim-config/lsp/zigcss.lua "$config_home/lsp/zigcss.lua"
```

Then enable it from `init.lua`:

```lua
vim.lsp.enable('zigcss')
```

Neovim activates the client only for the `css` filetype. A `.git` ancestor becomes the workspace root when present; single CSS files also work. ZigCSS indexes only synchronized open documents and never turns the workspace root into permission to crawl files.

## Executable discovery

The configuration searches at most 1,024 absolute `PATH` directories for `zigcss` and gives Neovim the verified absolute executable path. Empty and relative `PATH` entries are ignored; Windows lookup also bounds and validates `PATHEXT`. To select a source build explicitly, set `ZIGCSS_LSP_PATH` before starting Neovim:

```bash
export ZIGCSS_LSP_PATH=/absolute/path/to/zigcss/zig-out/bin/zigcss
nvim styles.css
```

An explicit value must be an absolute regular executable file, is limited to 65,536 characters, and fails closed without falling back when invalid. Relative and workspace-local paths are not executed implicitly. The command is exactly:

```text
/absolute/path/to/zigcss --lsp
```

## Validated capabilities

The headless integration tests open a real CSS buffer in Neovim 0.11.7 and 0.12.4, launch the real command, verify UTF-16/full-document synchronization, check the advertised capability table, and complete a property-hover request before a clean shutdown.

| Capability | Current behavior |
|---|---|
| Pull diagnostics | Recoverable compiler diagnostics for the open CSS document |
| Hover | Typed property and indexed CSS symbol information |
| Completion | Closed property-name completion in declaration-name positions; `<C-x><C-o>` uses the configured omnifunc |
| Document/workspace symbols | Syntax-aware symbols over currently open CSS documents |
| Definition | Custom properties and keyframes; class/ID definitions deliberately return no fabricated stylesheet location |
| References and rename | Syntax-aware open-document results with bounded, safe CSS identifier serialization |

Declaration, implementation, signature help, code actions, formatting, workspace diagnostics, and filesystem-backed project loading are not advertised. SCSS, Sass, Less, Stylus, PostCSS, CSS-in-JS, and `.module.css` do not attach through this configuration.

Use Neovim's standard LSP commands and capability-aware mappings. Useful checks include:

```vim
:checkhealth vim.lsp
:lua vim.lsp.buf.hover()
:lua vim.lsp.buf.definition()
:lua vim.lsp.buf.references()
:lua vim.lsp.buf.rename()
:lua vim.lsp.buf.document_symbol()
```

## Reproduce the checked integration

Build ZigCSS, install the pinned Neovim version, and run:

```bash
zig build
NVIM=/absolute/path/to/nvim npm run test:neovim
```

The test uses isolated XDG directories and does not read or modify the user's Neovim configuration.

## License

MIT
