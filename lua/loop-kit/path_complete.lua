-- Project-root anchored path candidates for the detail inputs.
--
-- The plugin does not depend on nvim-cmp: single-line fields pass a
-- `customlist` to vim.ui.input and the touch editor sets a buffer-local
-- omnifunc. Both resolve paths against the project root, never the cwd.
local M = {}

local function is_absolute(lead)
  return lead:sub(1, 1) == "/"
    or lead:sub(1, 1) == "~"
    or lead:sub(1, 1) == "$"
    or lead:match("^%a:[/\\]") ~= nil
end

local function has_parent_segment(lead)
  for segment in lead:gmatch("[^/]+") do
    if segment == ".." then
      return true
    end
  end
  return false
end

--- List one directory level below `root`, filtered by the last path segment.
---
--- `lead` may keep a `./` prefix; it is preserved on every candidate so the
--- user's spelling survives completion. Parent segments (`..`), backslashes
--- and absolute inputs (unless `opts.allow_absolute`) never produce candidates.
---@param root string project root
---@param lead string current input
---@param opts? { allow_absolute?: boolean }
---@return string[]
function M.complete(root, lead, opts)
  opts = opts or {}
  if type(root) ~= "string" or root == "" then
    return {}
  end
  if type(lead) ~= "string" then
    lead = ""
  end
  if lead:find("\\", 1, true) or has_parent_segment(lead) then
    return {}
  end

  if is_absolute(lead) then
    if not opts.allow_absolute then
      return {}
    end
    local ok, candidates = pcall(vim.fn.getcompletion, lead, "file")
    if not ok or type(candidates) ~= "table" then
      return {}
    end
    table.sort(candidates)
    return candidates
  end

  local dot_prefix = ""
  local relative = lead
  if relative:sub(1, 2) == "./" then
    dot_prefix = "./"
    relative = relative:sub(3)
  end

  local dir_part, prefix = relative:match("^(.*/)([^/]*)$")
  if not dir_part then
    dir_part, prefix = "", relative
  end

  local base = root:gsub("/+$", "")
  local scan_dir = dir_part == "" and base or (base .. "/" .. dir_part)
  local show_hidden = prefix:sub(1, 1) == "."
  local results = {}

  local ok = pcall(function()
    for name, kind in vim.fs.dir(scan_dir, { depth = 1 }) do
      if name:sub(1, #prefix) == prefix and (show_hidden or name:sub(1, 1) ~= ".") then
        local candidate = dir_part .. name
        if kind == "directory" then
          candidate = candidate .. "/"
        end
        results[#results + 1] = dot_prefix .. candidate
      end
    end
  end)
  if not ok then
    return {}
  end

  table.sort(results)
  return results
end

local input_root = nil
local input_allow_absolute = true

--- `vim.ui.input` completion spec; remembers the root for the next input.
--- The customlist name must resolve to a global function, see below.
---@param root string
---@param opts? { allow_absolute?: boolean }
---@return string
function M.input_completion(root, opts)
  input_root = root
  input_allow_absolute = not opts or opts.allow_absolute ~= false
  return "customlist,v:lua.LoopKitPathComplete"
end

--- Buffer-local `omnifunc` for the touch acwrite buffer.
--- Each line is a single path, so the whole line is the completion word.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    return 0
  end
  local root = vim.b.loopkit_path_root
  if type(root) ~= "string" or root == "" then
    return {}
  end
  return M.complete(root, base or "", {
    allow_absolute = vim.b.loopkit_path_allow_absolute == true,
  })
end

--- Attach the project-root context and `omnifunc` to an edit buffer.
---@param buf integer
---@param root string
---@param opts? { allow_absolute?: boolean }
function M.attach_omnifunc(buf, root, opts)
  vim.b[buf].loopkit_path_root = root
  vim.b[buf].loopkit_path_allow_absolute = (opts and opts.allow_absolute) == true
  vim.bo[buf].omnifunc = "v:lua.LoopKitPathOmnifunc"
end

_G.LoopKitPathComplete = function(lead)
  if type(input_root) ~= "string" or input_root == "" then
    return {}
  end
  return M.complete(input_root, lead or "", { allow_absolute = input_allow_absolute })
end
_G.LoopKitPathOmnifunc = M.omnifunc

return M
