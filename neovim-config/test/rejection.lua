local config_root = assert(
  vim.env.ZIGCSS_NEOVIM_CONFIG_ROOT,
  'ZIGCSS_NEOVIM_CONFIG_ROOT is required'
)

vim.opt.runtimepath:prepend(config_root)
vim.env.ZIGCSS_LSP_PATH = './workspace/zigcss'
local ok, message = pcall(function()
  vim.lsp.enable('zigcss')
  local _ = vim.lsp.config.zigcss
end)
if ok then
  vim.api.nvim_err_writeln('relative ZIGCSS_LSP_PATH unexpectedly enabled ZigCSS')
  vim.cmd('cquit 1')
end
if tostring(message):find('must resolve to an absolute path', 1, true) == nil then
  vim.api.nvim_err_writeln('unexpected relative-path rejection: ' .. tostring(message))
  vim.cmd('cquit 1')
end
print('NEOVIM_REJECTION_PASS relative-path-failed-closed')
vim.cmd('qa!')
