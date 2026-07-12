local config_root = assert(
  vim.env.ZIGCSS_NEOVIM_CONFIG_ROOT,
  'ZIGCSS_NEOVIM_CONFIG_ROOT is required'
)
local smoke_script = assert(
  vim.env.ZIGCSS_NEOVIM_SMOKE_SCRIPT,
  'ZIGCSS_NEOVIM_SMOKE_SCRIPT is required'
)

vim.opt.runtimepath:prepend(config_root)
vim.cmd('filetype on')
vim.lsp.enable('zigcss')

vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    vim.schedule(function()
      local ok, message = xpcall(function()
        dofile(smoke_script)
      end, debug.traceback)
      if not ok then
        vim.api.nvim_err_writeln('ZigCSS Neovim smoke failure: ' .. message)
        vim.cmd('cquit 1')
      end
    end)
  end,
})
