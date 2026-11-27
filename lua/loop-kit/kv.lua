-- Pure helpers for editing key/value task fields.
--
-- Everything here is free of buffer/window access so the models stay unit
-- testable; the board and picker layers do the drawing.
local M = {}

M.FALLBACK_TAGS = {
  "feature",
  "bugfix",
  "refactor",
  "ux",
  "visual",
  "docs",
  "chore",
}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Normalize a task id to `#N` form. Returns nil when the value is not an id.
function M.normalize_id(value)
  if type(value) == "number" then
    return "#" .. tostring(math.floor(value))
  end
  if type(value) ~= "string" then
    return nil
  end
  local digits = value:match("^%s*#?(%d+)%s*$")
  if not digits then
    return nil
  end
  return "#" .. digits
end

local function id_number(id)
  local digits = tostring(id or ""):match("#?(%d+)")
  return tonumber(digits) or math.huge
end

--- Extract tags from the `任务分类（tag）` section of TARGETS.md content.
function M.parse_tags(content)
  local tags = {}
  if type(content) ~= "string" then
    return tags
  end
  local in_section = false
  for line in (content .. "\n"):gmatch("(.-)\n") do
    local heading = line:match("^#%s*(.+)$")
    if heading ~= nil then
      in_section = heading:find("任务分类", 1, true) ~= nil
    elseif in_section then
      local tag = line:match("^%s*[-*]%s*`([^`]+)`")
      if tag ~= nil and tag ~= "" then
        tags[#tags + 1] = tag
      end
    end
  end
  return tags
end

--- Read tag candidates from `<loop_root>/TARGETS.md`, falling back to the
--- built-in list when the file or its tag section is unusable.
function M.tag_values(loop_root)
  local root = trim(loop_root)
  if root ~= "" then
    local path = root .. "/TARGETS.md"
    local file = io.open(path, "r")
    if file then
      local ok, content = pcall(file.read, file, "*a")
      file:close()
      if ok and type(content) == "string" then
        local tags = M.parse_tags(content)
        if #tags > 0 then
          return tags
        end
      end
    end
  end
  return vim.deepcopy(M.FALLBACK_TAGS)
end

--- Accepted tag names: kebab-case ASCII, same pattern as the upstream schema.
local TAG_NAME_PATTERN = "^[a-z0-9][a-z0-9%-]*$"

--- Read explicit tag names from a `loop.config.json` file.
---
--- Only a non-empty array of `{ name = "<kebab-case>" }` entries is
--- accepted; `description` is documentation-only and ignored. Missing file,
--- invalid JSON or an unusable shape all return nil so callers fall back to
--- TARGETS.md and then the builtins.
function M.config_tags(config_path)
  if type(config_path) ~= "string" or config_path == "" then
    return nil
  end
  local file = io.open(config_path, "r")
  if not file then
    return nil
  end
  local ok, content = pcall(file.read, file, "*a")
  file:close()
  if not ok or type(content) ~= "string" then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, content)
  if not decoded_ok or type(decoded) ~= "table" then
    return nil
  end
  local entries = decoded.tags
  if type(entries) ~= "table" or not vim.islist(entries) or #entries == 0 then
    return nil
  end
  local names = {}
  for _, entry in ipairs(entries) do
    if type(entry) ~= "table" then
      return nil
    end
    local name = entry.name
    if type(name) ~= "string" or not name:match(TAG_NAME_PATTERN) then
      return nil
    end
    names[#names + 1] = name
  end
  return names
end

--- Build `{ ["#1"] = { "#2" } }` from a task list.
local function dep_map(tasks)
  local map = {}
  for _, task in ipairs(tasks or {}) do
    local id = M.normalize_id(task.id)
    if id then
      local deps = {}
      if type(task.deps) == "table" then
        for _, dep in ipairs(task.deps) do
          local normalized = M.normalize_id(dep)
          if normalized then
            deps[#deps + 1] = normalized
          end
        end
      end
      map[id] = deps
    end
  end
  return map
end

--- Would making `candidate` a dependency of `id` introduce a cycle?
function M.would_cycle(tasks, id, candidate)
  local target = M.normalize_id(id)
  local next_id = M.normalize_id(candidate)
  if target == nil or next_id == nil then
    return false
  end
  if target == next_id then
    return true
  end
  local map = dep_map(tasks)
  local seen = {}
  local stack = { next_id }
  while #stack > 0 do
    local current = table.remove(stack)
    if current == target then
      return true
    end
    if not seen[current] then
      seen[current] = true
      for _, dep in ipairs(map[current] or {}) do
        stack[#stack + 1] = dep
      end
    end
  end
  return false
end

--- Split dependencies into selectable candidates and the hidden count.
--- Hidden entries are the current task itself and candidates that would form
--- a dependency cycle.
function M.dependency_candidates(tasks, id)
  local target = M.normalize_id(id)
  local selectable = {}
  local hidden = 0
  for _, task in ipairs(tasks or {}) do
    local task_id = M.normalize_id(task.id)
    if task_id ~= nil then
      if task_id == target or M.would_cycle(tasks, target, task_id) then
        hidden = hidden + 1
      else
        selectable[#selectable + 1] = {
          id = task_id,
          title = task.title,
          status = task.status,
        }
      end
    end
  end
  table.sort(selectable, function(a, b)
    return id_number(a.id) < id_number(b.id)
  end)
  return { selectable = selectable, hidden = hidden }
end

--- Comma-separated argument for `deps --set`; empty list becomes "".
function M.deps_arg(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    if type(value) == "string" and value ~= "" then
      out[#out + 1] = value
    end
  end
  return table.concat(out, ",")
end

--- Normalize multi-line touch content: trim, drop blanks, dedupe in order.
function M.touch_paths(lines)
  local paths = {}
  local seen = {}
  for _, line in ipairs(lines or {}) do
    local value = trim(line)
    if value ~= "" and not seen[value] then
      seen[value] = true
      paths[#paths + 1] = value
    end
  end
  return paths
end

return M
