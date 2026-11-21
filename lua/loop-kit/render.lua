-- Pure rendering: snapshot/state rows in, display lines and a stable
-- line-number -> task id map out. No buffer or window access happens here.
local util = require("loop-kit.util")

local M = {}

M.icons = { pending = "○", doing = "◐", done = "●", blocked = "✕" }

local GROUP_ORDER = { "doing", "pending", "blocked", "done" }
local GROUP_LABEL = {
  doing = "Doing",
  pending = "Pending",
  blocked = "Blocked",
  done = "Done",
}

local function label(status)
  local known = GROUP_LABEL[status]
  if known then
    return known
  end
  local text = tostring(status or "")
  if text == "" then
    return ""
  end
  return text:sub(1, 1):upper() .. text:sub(2)
end

local function one_line(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("[\r\n]", " "))
end

local function format_value(value)
  if value == nil or value == vim.NIL then
    return "(none)"
  end
  if type(value) == "string" then
    return one_line(value)
  end
  return one_line(tostring(value))
end

--- Order groups by the canonical status order; unknown statuses keep their
--- relative order at the end.
local function sorted_groups(groups)
  local rank = {}
  for index, status in ipairs(GROUP_ORDER) do
    rank[status] = index
  end

  local ordered = {}
  for _, group in ipairs(groups or {}) do
    ordered[#ordered + 1] = group
  end

  table.sort(ordered, function(a, b)
    local ra = rank[a.status] or (#GROUP_ORDER + 1)
    local rb = rank[b.status] or (#GROUP_ORDER + 1)
    if ra ~= rb then
      return ra < rb
    end
    return tostring(a.status) < tostring(b.status)
  end)

  return ordered
end

--- Render grouped tasks into display lines.
---
--- groups: list from `state:groups()` — `{ { status =, tasks = { ... } }, ... }`
--- opts: { icons =, selected_id = }
---
--- Returns:
---   lines        display strings, 1-based
---   line_map     [line] = task id, only for task rows (never headers/blanks)
---   id_to_line   [task id] = line
---   line_hl      [line] = LoopKit highlight group name
---   groups       [n] = { status, header_line, first_line, last_line, tasks = ids }
---   selected_line line of `opts.selected_id`, when visible
function M.list(groups, opts)
  opts = opts or {}
  local icons = vim.tbl_extend("force", M.icons, opts.icons or {})
  local selected = util.normalize_id(opts.selected_id) or opts.selected_id

  local out = {
    lines = {},
    line_map = {},
    id_to_line = {},
    line_hl = {},
    groups = {},
    selected_line = nil,
  }

  for _, group in ipairs(sorted_groups(groups)) do
    local tasks = {}
    for _, task in ipairs(group.tasks or {}) do
      tasks[#tasks + 1] = task
    end
    table.sort(tasks, function(a, b)
      return util.compare_ids(a.id, b.id) < 0
    end)

    if #tasks > 0 then
      if #out.lines > 0 then
        out.lines[#out.lines + 1] = ""
      end

      local header_line = #out.lines + 1
      out.lines[header_line] = string.format("%s (%d)", label(group.status), #tasks)
      out.line_hl[header_line] = "LoopKitHeader"

      local record = {
        status = group.status,
        header_line = header_line,
        first_line = header_line + 1,
        last_line = header_line + #tasks,
        tasks = {},
      }
      out.groups[#out.groups + 1] = record

      for _, task in ipairs(tasks) do
        local id = util.normalize_id(task.id) or tostring(task.id or "")
        local text = string.format("%s %s %s", icons[task.status] or "?", id, one_line(task.title))
        if type(task.tag) == "string" and task.tag ~= "" then
          text = text .. " [" .. one_line(task.tag) .. "]"
        end

        local line = #out.lines + 1
        out.lines[line] = text
        out.line_map[line] = id
        out.id_to_line[id] = line
        out.line_hl[line] = "LoopKit" .. label(task.status)
        record.tasks[#record.tasks + 1] = id

        if selected ~= nil and selected == id then
          out.selected_line = line
          out.line_hl[line] = "LoopKitSelected"
        end
      end
    end
  end

  return out
end

local function deps_text(task, opts)
  local deps = task.deps
  if deps == nil or deps == vim.NIL or type(deps) ~= "table" or #deps == 0 then
    return "(none)"
  end

  local parts = {}
  for _, dep in ipairs(deps) do
    local id = util.normalize_id(dep) or one_line(tostring(dep))
    local by_id = opts.tasks_by_id
    local dep_task = by_id and (by_id[id] or by_id[dep])
    if dep_task and dep_task.status then
      parts[#parts + 1] = string.format("%s (%s)", id, dep_task.status)
    else
      parts[#parts + 1] = id
    end
  end
  return table.concat(parts, ", ")
end

local function flow_text(task)
  local flow = task.flow
  if flow == nil or flow == vim.NIL or flow == "" or flow == "default" then
    return nil
  end
  if type(flow) == "table" then
    local stages = {}
    for _, stage in ipairs(flow) do
      stages[#stages + 1] = one_line(tostring(stage))
    end
    if #stages == 0 then
      return nil
    end
    return table.concat(stages, " > ")
  end
  return one_line(tostring(flow))
end

local function meta_text(task)
  local meta = task.meta
  if meta == nil or meta == vim.NIL or type(meta) ~= "table" or (meta.branch == nil and meta.baseSha == nil) then
    return "(unset)"
  end
  return string.format(
    "branch=%s baseSha=%s",
    format_value(meta.branch),
    format_value(meta.baseSha)
  )
end

--- Render a task detail as Markdown lines.
---
--- opts: { tasks_by_id = { ["#2"] = task } } annotates dependency statuses.
---
--- Returns `{ lines, fields, title_line }` where `fields` maps a metadata key
--- (id/status/deps/doc/touch/...) to the line that starts it.
function M.detail(task, opts)
  opts = opts or {}
  task = task or {}

  local out = { lines = {}, fields = {}, title_line = nil }

  local function push(text)
    out.lines[#out.lines + 1] = text
    return #out.lines
  end

  local function field(key, value)
    out.fields[key] = push(string.format("- %s: %s", key, value))
  end

  local title = one_line(task.title)
  out.title_line = push("# " .. (title ~= "" and title or "(untitled)"))
  push("")

  field("id", util.normalize_id(task.id) or format_value(task.id))
  field("status", format_value(task.status))
  field("tag", format_value(task.tag))
  field("origin", format_value(task.origin))
  field("openAt", format_value(task.openAt))
  field("closedAt", format_value(task.closedAt))
  field("hash", format_value(task.hash))
  field("deps", deps_text(task, opts))
  field("doc", format_value(task.doc))

  local flow = flow_text(task)
  field("flow", flow or "(default)")

  local private = task.isPrivateDesc
  if private == nil then
    private = task.private
  end
  if private ~= nil and private ~= vim.NIL then
    field("private", private and "true" or "false")
  end

  local touch = task.touch
  if touch == nil or touch == vim.NIL then
    field("touch", "unknown")
  elseif type(touch) == "string" then
    if touch == "" then
      field("touch", "(empty)")
    else
      field("touch", one_line(touch))
    end
  elseif type(touch) ~= "table" or #touch == 0 then
    field("touch", "(empty)")
  else
    out.fields.touch = push("- touch:")
    for _, path in ipairs(touch) do
      push("  - " .. one_line(tostring(path)))
    end
  end

  field("meta", meta_text(task))

  local desc = task.desc
  if type(desc) == "string" and desc ~= "" then
    push("")
    out.fields.desc = #out.lines + 1
    local start = 1
    while true do
      local first, last = desc:find("\n", start, true)
      if not first then
        out.lines[#out.lines + 1] = desc:sub(start)
        break
      end
      out.lines[#out.lines + 1] = desc:sub(start, first - 1)
      start = last + 1
    end
  end

  return out
end

return M
