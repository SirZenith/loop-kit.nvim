-- Temporary filesystem helpers shared by the specs.
local M = {}

local created = {}

function M.dir(prefix)
  local path = vim.fn.tempname()
  if prefix then
    path = path .. "-" .. prefix
  end
  vim.fn.mkdir(path, "p")
  created[#created + 1] = path
  return vim.fs.normalize(path)
end

function M.join(...)
  return vim.fs.joinpath(...)
end

function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "wb"))
  fd:write(content)
  fd:close()
  return path
end

function M.read(path)
  local fd = assert(io.open(path, "rb"))
  local content = fd:read("*a")
  fd:close()
  return content
end

function M.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

function M.list(dir)
  local names = {}
  local ok, iter = pcall(vim.fs.dir, dir)
  if not ok then
    return names
  end
  for name in iter do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.chmod(path, mode)
  vim.uv.fs_chmod(path, mode)
  return path
end

function M.executable_script(path, body)
  M.write(path, "#!/bin/sh\n" .. body .. "\n")
  M.chmod(path, 493) -- 0755
  return path
end

function M.cleanup()
  for _, path in ipairs(created) do
    pcall(vim.fn.delete, path, "rf")
  end
  created = {}
end

return M
