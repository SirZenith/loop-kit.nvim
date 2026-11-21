-- Shared pure helpers: paths, ids, table copies and safe text.
local M = {}

--- Normalize a filesystem path without requiring it to exist.
function M.normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.normalize(path)
end

--- Resolve `path` against `base` unless it is already absolute.
function M.absolute_path(base, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return M.normalize_path(path)
  end
  if not base or base == "" then
    return M.normalize_path(path)
  end
  return M.normalize_path(base .. "/" .. path)
end

--- Canonical key for a project root. Uses realpath when available so a
--- symlinked project keeps a single state/queue.
function M.normalize_root(path)
  local normalized = M.normalize_path(path)
  if not normalized then
    return nil
  end
  local real = vim.uv.fs_realpath(normalized)
  if real then
    normalized = vim.fs.normalize(real)
  end
  if #normalized > 1 then
    normalized = normalized:gsub("/+$", "")
  end
  return normalized
end

--- Walk from `start` (file or directory) up to the filesystem root looking
--- for `filename`. Returns the containing directory, or nil.
function M.find_upward(start, filename)
  local path = M.normalize_path(start)
  if not path then
    return nil
  end

  local stat = vim.uv.fs_stat(path)
  local dir
  if stat and stat.type == "directory" then
    dir = path
  else
    dir = vim.fs.dirname(path)
  end

  while dir and dir ~= "" do
    if vim.uv.fs_stat(dir .. "/" .. filename) then
      return dir
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

--- "#12" or "12" -> "#12"; anything else -> nil.
function M.normalize_id(id)
  if type(id) ~= "string" then
    return nil
  end
  local trimmed = id:match("^%s*(.-)%s*$")
  local digits = trimmed:match("^#(%d+)$") or trimmed:match("^(%d+)$")
  if not digits then
    return nil
  end
  return "#" .. tostring(tonumber(digits))
end

function M.task_number(id)
  local normalized = M.normalize_id(id)
  if not normalized then
    return nil
  end
  return tonumber(normalized:sub(2))
end

--- Stable id comparator: numeric ids first, lexicographic as fallback.
function M.compare_ids(a, b)
  local na = M.task_number(a)
  local nb = M.task_number(b)
  if na and nb then
    if na == nb then
      return 0
    end
    return na < nb and -1 or 1
  end
  if na then
    return -1
  end
  if nb then
    return 1
  end
  if a == b then
    return 0
  end
  return a < b and -1 or 1
end

function M.trim(value)
  if type(value) ~= "string" then
    return value
  end
  return value:match("^%s*(.-)%s*$")
end

function M.split(value, separator)
  local out = {}
  if type(value) ~= "string" or value == "" then
    return out
  end
  separator = separator or ","
  local start = 1
  while true do
    local first, last = value:find(separator, start, true)
    if not first then
      out[#out + 1] = value:sub(start)
      break
    end
    out[#out + 1] = value:sub(start, first - 1)
    start = last + 1
  end
  return out
end

function M.deepcopy(value, seen)
  if type(value) ~= "table" or value == vim.NIL then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[M.deepcopy(key, seen)] = M.deepcopy(item, seen)
  end
  return copy
end

local function looks_secret(key)
  local upper = key:upper()
  for _, part in ipairs({ "TOKEN", "SECRET", "PASSWORD", "PASSWD", "APIKEY", "API_KEY", "CREDENTIAL", "PRIVATE_KEY", "PRIVATEKEY" }) do
    if upper:find(part, 1, true) then
      return true
    end
  end
  return false
end

--- Environment values that must never reach a notification or log.
function M.secret_values(...)
  local envs = { ... }
  local secrets = {}
  local seen = {}
  for _, env in ipairs(envs) do
    if type(env) == "table" then
      for key, value in pairs(env) do
        if
          type(key) == "string"
          and type(value) == "string"
          and #value >= 6
          and looks_secret(key)
          and not seen[value]
        then
          seen[value] = true
          secrets[#secrets + 1] = value
        end
      end
    end
  end
  table.sort(secrets, function(a, b)
    return #a > #b
  end)
  return secrets
end

--- Strip ANSI/control bytes that could corrupt a UI line, and redact secrets.
function M.sanitize_text(text, secrets)
  if type(text) ~= "string" then
    return text
  end
  text = text:gsub("\27%[[%d;?]*%a", "")
  text = text:gsub("\r", "")
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "?")
  for _, secret in ipairs(secrets or {}) do
    if secret ~= "" then
      text = text:gsub(vim.pesc(secret), "[REDACTED]")
    end
  end
  return text
end

function M.truncate(text, max)
  if type(text) ~= "string" then
    return text
  end
  if #text <= max then
    return text
  end
  return text:sub(1, max) .. "… [truncated]"
end

return M
