local maximum_path_length = 65536
local maximum_path_entries = 1024
local maximum_path_extensions = 64

local function is_absolute(path)
  if vim.fn.has('win32') == 1 then
    return path:match('^%a:[/\\]') ~= nil or path:match('^[/\\][/\\]') ~= nil
  end
  return path:sub(1, 1) == '/'
end

local function join_path(directory, name)
  local final = directory:sub(-1)
  if final == '/' or final == '\\' then return directory .. name end
  return directory .. (vim.fn.has('win32') == 1 and '\\' or '/') .. name
end

local function require_executable(path, source)
  if #path > maximum_path_length or path:find('\0', 1, true) ~= nil then
    error(source .. ' exceeds its limit or contains NUL')
  end
  if not is_absolute(path) then
    error(source .. ' must resolve to an absolute path')
  end

  local normalized = vim.fs.normalize(path, { expand_env = false })
  local stat = vim.uv.fs_stat(normalized)
  if stat == nil or stat.type ~= 'file' or vim.fn.executable(normalized) ~= 1 then
    error(source .. ' is not a regular executable file: ' .. normalized)
  end
  return normalized
end

local function usable_executable(path)
  if #path > maximum_path_length or not is_absolute(path) then return nil end
  local normalized = vim.fs.normalize(path, { expand_env = false })
  local stat = vim.uv.fs_stat(normalized)
  if stat == nil or stat.type ~= 'file' or vim.fn.executable(normalized) ~= 1 then
    return nil
  end
  return normalized
end

local function executable_names()
  if vim.fn.has('win32') ~= 1 then return { 'zigcss' } end

  local names = {}
  local seen = {}
  local path_extensions = vim.env.PATHEXT or '.COM;.EXE;.BAT;.CMD'
  for extension in (path_extensions .. ';'):gmatch('(.-);') do
    extension = vim.trim(extension)
    local key = extension:upper()
    if #names < maximum_path_extensions and
      extension:match('^%.[%w]+$') ~= nil and
      not seen[key]
    then
      seen[key] = true
      table.insert(names, 'zigcss' .. extension)
    end
  end
  if #names == 0 then return { 'zigcss.exe' } end
  return names
end

local function search_absolute_path()
  local separator = vim.fn.has('win32') == 1 and ';' or ':'
  local names = executable_names()
  local entries = 0
  for raw_directory in ((vim.env.PATH or '') .. separator):gmatch('(.-)' .. separator) do
    if entries >= maximum_path_entries then break end
    entries = entries + 1
    local directory = vim.trim(raw_directory)
    directory = directory:match('^"(.*)"$') or directory
    if #directory <= maximum_path_length and is_absolute(directory) then
      for _, name in ipairs(names) do
        local executable = usable_executable(join_path(directory, name))
        if executable ~= nil then return executable end
      end
    end
  end
  return nil
end

local function server_command()
  local configured = vim.env.ZIGCSS_LSP_PATH
  if configured ~= nil and configured ~= '' then
    return require_executable(configured, 'ZIGCSS_LSP_PATH')
  end

  local discovered = search_absolute_path()
  if discovered == nil then
    error('zigcss was not found in an absolute PATH directory; set ZIGCSS_LSP_PATH to an absolute executable path')
  end
  return discovered
end

---@type vim.lsp.Config
return {
  cmd = { server_command(), '--lsp' },
  filetypes = { 'css' },
  root_markers = { '.git' },
  workspace_required = false,
  on_attach = function(client, bufnr)
    if client:supports_method('textDocument/completion') then
      vim.bo[bufnr].omnifunc = 'v:lua.vim.lsp.omnifunc'
    end
  end,
}
