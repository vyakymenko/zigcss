-- Convenience entry point after installing lsp/zigcss.lua on 'runtimepath'.
-- Neovim 0.11+ provides vim.lsp.config and vim.lsp.enable directly.

if vim.fn.has('nvim-0.11.7') ~= 1 then
  error('ZigCSS requires Neovim 0.11.7 or later')
end

vim.lsp.enable('zigcss')
