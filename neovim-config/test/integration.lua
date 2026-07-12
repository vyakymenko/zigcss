local function expect(condition, message)
  if not condition then error(message, 2) end
end

local bufnr = vim.api.nvim_get_current_buf()
expect(vim.bo[bufnr].filetype == 'css', 'fixture was not detected as CSS')
expect(vim.wait(10000, function()
  return #vim.lsp.get_clients({ name = 'zigcss', bufnr = bufnr }) == 1
end, 20), 'ZigCSS LSP did not attach within 10 seconds')

local clients = vim.lsp.get_clients({ name = 'zigcss', bufnr = bufnr })
expect(#clients == 1, 'expected exactly one attached ZigCSS client')
local client = clients[1]
local capabilities = client.server_capabilities

expect(client.name == 'zigcss', 'unexpected client name')
expect(client.offset_encoding == 'utf-16', 'server did not negotiate UTF-16')
expect(type(client.config.cmd) == 'table', 'resolved command is not an argument vector')
expect(client.config.cmd[1] == vim.fs.normalize(vim.env.ZIGCSS_LSP_PATH), 'wrong executable')
expect(client.config.cmd[2] == '--lsp' and client.config.cmd[3] == nil, 'wrong server arguments')
expect(vim.bo[bufnr].omnifunc == 'v:lua.vim.lsp.omnifunc', 'completion omnifunc was not attached')

expect(type(capabilities.textDocumentSync) == 'table', 'missing sync capability')
expect(capabilities.textDocumentSync.openClose == true, 'open/close sync is not advertised')
expect(capabilities.textDocumentSync.change == 1, 'full-document sync is not advertised')
expect(type(capabilities.diagnosticProvider) == 'table', 'missing pull diagnostics')
expect(capabilities.diagnosticProvider.identifier == 'zigcss', 'wrong diagnostic identifier')
expect(capabilities.diagnosticProvider.interFileDependencies == false, 'inter-file diagnostics were advertised')
expect(capabilities.diagnosticProvider.workspaceDiagnostics == false, 'workspace diagnostics were advertised')

local supported = {
  'textDocument/diagnostic',
  'textDocument/hover',
  'textDocument/completion',
  'textDocument/documentSymbol',
  'workspace/symbol',
  'textDocument/definition',
  'textDocument/references',
  'textDocument/rename',
}
for _, method in ipairs(supported) do
  expect(client:supports_method(method), 'expected advertised method: ' .. method)
end

local unsupported = {
  'textDocument/declaration',
  'textDocument/implementation',
  'textDocument/signatureHelp',
  'textDocument/codeAction',
  'textDocument/formatting',
  'textDocument/rangeFormatting',
}
for _, method in ipairs(unsupported) do
  expect(not client:supports_method(method), 'unexpected advertised method: ' .. method)
end

local diagnostics = client:request_sync('textDocument/diagnostic', {
  textDocument = { uri = vim.uri_from_bufnr(bufnr) },
}, 5000, bufnr)
expect(type(diagnostics) == 'table' and diagnostics.err == nil, 'diagnostic request failed')
expect(type(diagnostics.result) == 'table', 'diagnostic request returned no report')
expect(diagnostics.result.kind == 'full', 'diagnostic report is not full')
expect(type(diagnostics.result.items) == 'table' and #diagnostics.result.items == 0, 'valid CSS produced diagnostics')

local hover = client:request_sync('textDocument/hover', {
  textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  position = { line = 0, character = 6 },
}, 5000, bufnr)
expect(type(hover) == 'table' and hover.err == nil, 'hover request failed')
expect(type(hover.result) == 'table', 'hover returned no result')
expect(type(hover.result.contents) == 'table', 'hover contents are malformed')
expect(type(hover.result.contents.value) == 'string', 'hover markdown is missing')
expect(hover.result.contents.value:find('**color**', 1, true) ~= nil, 'wrong hover result')

client:stop(false)
expect(vim.wait(5000, function() return client:is_stopped() end, 20), 'client did not stop cleanly')
print('NEOVIM_SMOKE_PASS version=' .. tostring(vim.version()) .. ' capabilities=8 unsupported=6 diagnostic=full hover=color')
vim.cmd('qa!')
