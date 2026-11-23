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

--- Render tasks into two-line display rows.
---
--- groups: list from `state:groups()` — `{ { status =, tasks = { ... } }, ... }`
--- opts: { icons =, selected_id =, flat =, presorted =, sort = }
---
--- Returns:
---   lines        display strings, 1-based
---   line_map     [line] = task id, only for task rows (never headers/blanks)
---   id_to_line   [task id] = first (top) line
---   line_hl      [line] = LoopKit highlight group name
---   ranges       [n] = { line, col_start, col_end, hl_group } for segment styling
---   groups       [n] = { status, header_line, first_line, last_line, tasks = ids }
---   selected_line first line of `opts.selected_id`, when visible
local function status_hl(status)
  local name = type(status) == "string" and status:lower() or ""
  if name == "doing" then
    return "LoopKitDoing"
  elseif name == "done" then
    return "LoopKitDone"
  elseif name == "blocked" then
    return "LoopKitBlocked"
  end
  return "LoopKitPending"
end

--- Two-line compact rows for one task; ranges are relative to the card rows.
local function compact_rows(task, icons)
  local rows, ranges = {}, {}
  local function push(row, start_col, end_col, hl_group)
    ranges[#ranges + 1] = {
      row = row,
      col_start = start_col,
      col_end = end_col,
      hl_group = hl_group,
    }
  end

  local id = util.normalize_id(task.id) or tostring(task.id or "")
  local status = type(task.status) == "string" and task.status:lower() or "pending"
  local icon = icons[status] or "?"
  local title = one_line(task.title)
  if title == "" then
    title = "(untitled)"
  end
  local tag = type(task.tag) == "string" and one_line(task.tag) or ""

  local top_prefix = "┌ "
  local bottom_prefix = "└ "
  local first = string.format("%s%s · %s %s", top_prefix, id, icon, status)
  if tag ~= "" then
    first = first .. " · " .. tag
  end
  rows[1] = first
  rows[2] = bottom_prefix .. title

  push(1, 0, #top_prefix, "LoopKitMuted")
  local col = #top_prefix
  push(1, col, col + #id, "LoopKitId")
  col = col + #id + #" · "
  push(1, col, col + #icon, status_hl(status))
  col = col + #icon + #" "
  push(1, col, col + #status, status_hl(status))
  if tag ~= "" then
    col = col + #status + #" · "
    push(1, col, col + #tag, "LoopKitTag")
  end
  push(2, 0, #bottom_prefix, "LoopKitMuted")

  return rows, ranges
end

--- Human-readable flow label used on the card meta line.
local function flow_label(flow)
  if type(flow) == "table" then
    return "custom"
  end
  if flow == nil or flow == vim.NIL or flow == "" or flow == "default" then
    return "auto"
  end
  return one_line(tostring(flow))
end

--- Four-line card rows for one task; ranges are relative to the card rows.
local function card_rows(task, icons, width, selected)
  local rows, ranges = {}, {}
  local border_hl = selected and "LoopKitCardSelected" or "LoopKitMuted"
  local function push(row, start_col, end_col, hl_group)
    if end_col > start_col then
      ranges[#ranges + 1] = {
        row = row,
        col_start = start_col,
        col_end = end_col,
        hl_group = hl_group,
      }
    end
  end

  local id = util.normalize_id(task.id) or tostring(task.id or "")
  local status = type(task.status) == "string" and task.status:lower() or "pending"
  local icon = icons[status] or "?"
  local title = one_line(task.title)
  if title == "" then
    title = "(untitled)"
  end
  local tag = type(task.tag) == "string" and one_line(task.tag) or ""
  local origin = type(task.origin) == "string" and one_line(task.origin) or ""
  if origin == "" then
    origin = "human"
  end

  -- Line 1: ╭─ #id ────── <icon> <status> ─╮
  local head = "╭─ "
  local status_text = icon .. " " .. status
  local suffix = " " .. status_text
  local tail = " ─╮"
  local id_text = id
  local head_w = util.display_width(head)
  local id_w = util.display_width(id_text)
  local suffix_w = util.display_width(suffix)
  local tail_w = util.display_width(tail)

  local line1
  local id_end = #head + #id_text
  local border_start, border_end
  local status_start, status_end
  if head_w + id_w + suffix_w + tail_w + 1 <= width then
    local fill = string.rep("─", width - head_w - id_w - suffix_w - tail_w)
    line1 = head .. id_text .. fill .. suffix .. tail
    border_start = #head + #id_text + #fill
    border_end = border_start + 1
    status_start = border_start + 1
    status_end = status_start + #suffix
  else
    -- Too narrow for the status block: keep the id and a plain border.
    id_text = util.truncate_display(id, math.max(1, width - head_w - 2))
    id_end = #head + #id_text
    id_w = util.display_width(id_text)
    local fill = string.rep("─", math.max(0, width - head_w - id_w - 2))
    line1 = head .. id_text .. " " .. fill .. "╮"
    border_start = id_end
    border_end = #line1
  end

  push(1, 0, #head, border_hl)
  push(1, #head, id_end, "LoopKitId")
  if border_start > id_end then
    push(1, id_end, border_start, border_hl)
  end
  push(1, border_start, border_end, border_hl)
  if status_start then
    push(1, status_start, status_end, status_hl(status))
    push(1, status_end, #line1, border_hl)
  end
  rows[1] = line1

  -- Lines 2 and 3: title and tag · origin · flow, padded inside the box.
  local inner = math.max(1, width - 4)
  local shown_title = util.truncate_display(title, inner)
  rows[2] = "│ " .. util.pad_display(shown_title, inner) .. " │"
  push(2, 0, #"│ ", border_hl)
  push(2, #"│ ", #"│ " + #shown_title, "LoopKitTitle")
  push(2, #"│ " + #shown_title, #rows[2], border_hl)

  local segments = {}
  if tag ~= "" then
    segments[#segments + 1] = { text = tag, hl = "LoopKitTag" }
  end
  segments[#segments + 1] = { text = origin, hl = "LoopKitMuted" }
  local flow = flow_label(task.flow)
  if flow ~= "" then
    segments[#segments + 1] = { text = flow, hl = "LoopKitMuted" }
  end

  local function join_text(parts)
    local texts = {}
    for index, segment in ipairs(parts) do
      texts[index] = segment.text
    end
    return table.concat(texts, " · ")
  end

  local meta = join_text(segments)
  while util.display_width(meta) > inner and #segments > 1 do
    table.remove(segments)
    meta = join_text(segments)
  end
  if #segments == 1 and util.display_width(meta) > inner then
    segments[1].text = util.truncate_display(segments[1].text, inner)
    meta = segments[1].text
  end

  rows[3] = "│ " .. util.pad_display(meta, inner) .. " │"
  push(3, 0, #"│ ", border_hl)
  local meta_end = #"│ " + #meta
  local byte_col = #"│ "
  for index, segment in ipairs(segments) do
    local start_col = byte_col
    local end_col = math.min(start_col + #segment.text, meta_end)
    push(3, start_col, end_col, segment.hl)
    byte_col = start_col + #segment.text
    if index < #segments then
      byte_col = byte_col + #" · "
    end
  end
  push(3, meta_end, #rows[3], border_hl)

  -- Line 4: bottom border.
  rows[4] = "╰" .. string.rep("─", math.max(0, width - 2)) .. "╯"
  push(4, 0, #rows[4], border_hl)

  return rows, ranges
end

function M.list(groups, opts)
  opts = opts or {}
  local icons = vim.tbl_extend("force", M.icons, opts.icons or {})
  local selected = util.normalize_id(opts.selected_id) or opts.selected_id
  local style = opts.style == "card" and "card" or "compact"
  local width = math.max(12, math.floor(tonumber(opts.width) or 38))

  local out = {
    lines = {},
    line_map = {},
    id_to_line = {},
    line_hl = {},
    ranges = {},
    groups = {},
    selected_line = nil,
  }

  local function push_range(line, start_col, end_col, hl_group)
    out.ranges[#out.ranges + 1] = {
      line = line,
      col_start = start_col,
      col_end = end_col,
      hl_group = hl_group,
    }
  end

  local flat = opts.flat
  if flat == nil then
    flat = #(groups or {}) == 1 and groups[1].status == nil
  end

  local ordered_groups = sorted_groups(groups)
  if flat then
    local tasks = {}
    for _, group in ipairs(groups or {}) do
      for _, task in ipairs(group.tasks or {}) do
        tasks[#tasks + 1] = task
      end
    end
    ordered_groups = { { status = nil, tasks = tasks } }
  end

  for _, group in ipairs(ordered_groups) do
    local tasks = {}
    for _, task in ipairs(group.tasks or {}) do
      tasks[#tasks + 1] = task
    end
    if not opts.presorted and opts.sort ~= "title" then
      table.sort(tasks, function(a, b)
        return util.compare_ids(a.id, b.id) < 0
      end)
    end

    if #tasks > 0 then
      local header_line = nil
      if not flat then
        if #out.lines > 0 then
          out.lines[#out.lines + 1] = ""
        end

        header_line = #out.lines + 1
        out.lines[header_line] = string.format("%s (%d)", label(group.status), #tasks)
        out.line_hl[header_line] = "LoopKitHeader"
      end

      local record = {
        status = flat and nil or group.status,
        header_line = header_line,
        first_line = #out.lines + 1,
        last_line = nil,
        tasks = {},
      }
      out.groups[#out.groups + 1] = record

      for _, task in ipairs(tasks) do
        local id = util.normalize_id(task.id) or tostring(task.id or "")
        local is_selected = selected ~= nil and selected == id
        if style ~= "card" and #out.lines > 0 and out.line_map[#out.lines] then
          out.lines[#out.lines + 1] = ""
        end

        local rows, row_ranges
        if style == "card" then
          rows, row_ranges = card_rows(task, icons, width, is_selected)
        else
          rows, row_ranges = compact_rows(task, icons)
        end

        local line = #out.lines + 1
        for index, text in ipairs(rows) do
          out.lines[line + index - 1] = text
          out.line_map[line + index - 1] = id
        end
        out.id_to_line[id] = line
        record.tasks[#record.tasks + 1] = id

        for _, range in ipairs(row_ranges) do
          push_range(line + range.row - 1, range.col_start, range.col_end, range.hl_group)
        end

        if is_selected then
          out.selected_line = line
          if style ~= "card" then
            out.line_hl[line] = "LoopKitSelected"
            out.line_hl[line + 1] = "LoopKitSelected"
          end
        end
      end

      record.last_line = #out.lines
    end
  end

  return out
end

--- Render the dependency list, annotating each known task with its status icon
--- (coloured by the status) and falling back to the bare id when the task is
--- missing. Returns the display text and 0-based byte ranges into it.
local function deps_text(task, opts)
  local deps = task.deps
  if deps == nil or deps == vim.NIL or type(deps) ~= "table" or #deps == 0 then
    return "(none)", {}
  end

  local icons = vim.tbl_extend("force", M.icons, opts.icons or {})
  local parts = {}
  local ranges = {}
  local col = 0
  for index, dep in ipairs(deps) do
    local id = util.normalize_id(dep) or one_line(tostring(dep))
    local by_id = opts.tasks_by_id
    local dep_task = by_id and (by_id[id] or by_id[dep])
    local status = dep_task and dep_task.status
    local value = id
    if type(status) == "string" and status ~= "" then
      status = status:lower()
      local icon = icons[status] or "?"
      value = id .. " " .. icon
      ranges[#ranges + 1] = {
        col_start = col + #id + 1,
        col_end = col + #id + 1 + #icon,
        hl_group = status_hl(status),
      }
    end
    parts[#parts + 1] = value
    col = col + #value
    if index < #deps then
      col = col + #", "
    end
  end
  return table.concat(parts, ", "), ranges
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
--- opts: { tasks_by_id = { ["#2"] = task } } annotates dependency statuses
--- with their status icon; "icons" overrides the default icon table.
---
--- Returns `{ lines, fields, title_line }` where `fields` maps a metadata key
--- (id/status/deps/doc/touch/...) to the line that starts it.
function M.detail(task, opts)
  opts = opts or {}
  task = task or {}

  local out = { lines = {}, fields = {}, highlights = {}, title_line = nil }

  local function push(text)
    out.lines[#out.lines + 1] = text
    return #out.lines
  end

  local function push_hl(line, start_col, end_col, hl_group)
    out.highlights[#out.highlights + 1] = {
      line = line,
      col_start = start_col,
      col_end = end_col,
      hl_group = hl_group,
    }
  end

  local function whole(line, hl_group)
    push_hl(line, 0, #(out.lines[line] or ""), hl_group)
  end

  local function push_block(text, hl_group)
    local first_line = nil
    local start = 1
    while true do
      local newline = text:find("\n", start, true)
      local line_text = newline and text:sub(start, newline - 1) or text:sub(start)
      local line = push(line_text)
      if hl_group then
        whole(line, hl_group)
      end
      first_line = first_line or line
      if not newline then
        break
      end
      start = newline + 1
    end
    return first_line
  end

  local function end_block()
    if #out.lines > 0 and out.lines[#out.lines] ~= "" then
      push("")
    end
  end

  local function field(key, value, value_hl)
    local text = value == "" and string.format("- %s:", key) or string.format("- %s: %s", key, value)
    local line = push(text)
    out.fields[key] = line
    push_hl(line, 0, 2, "LoopKitDetailKey")
    push_hl(line, 2, 2 + #key, "LoopKitDetailKey")
    if value_hl then
      push_hl(line, 2 + #key + 2, #(out.lines[line]), value_hl)
    end
    return line
  end

  local function subfield(key, value, value_hl)
    local line = push(string.format("  - %s: %s", key, value))
    out.fields[key] = line
    push_hl(line, 2, 4, "LoopKitDetailKey")
    push_hl(line, 4, 4 + #key, "LoopKitDetailKey")
    if value_hl then
      push_hl(line, 6 + #key, #(out.lines[line]), value_hl)
    end
    return line
  end

  local function is_unset(value)
    return value == nil or value == vim.NIL or value == ""
  end

  local function path_field(key, value)
    if is_unset(value) then
      return field(key, "(未设置)", "LoopKitDetailMuted")
    end
    return field(key, one_line(tostring(value)), "LoopKitDetailPath")
  end

  local function section(key, heading)
    if #out.lines > 0 and out.lines[#out.lines] ~= "" then
      push("")
    end
    local line = push(heading)
    out.fields[key] = line
    whole(line, "LoopKitDetailSection")
    push("")
    return line
  end

  local function muted_block(key, text)
    local line = push(text)
    out.fields[key] = line
    whole(line, "LoopKitDetailMuted")
    return line
  end

  -- Key/value groups read better with a Markdown rule between them. The
  -- title already separates the metadata from the heading, so no rule is
  -- emitted before the first group or after the last one.
  local function group_rule()
    if #out.lines > 0 and out.lines[#out.lines] ~= "" then
      push("")
    end
    push("---")
    push("")
  end

  local title = one_line(task.title)
  out.title_line = push("# " .. (title ~= "" and title or "(untitled)"))
  whole(out.title_line, "LoopKitDetailTitle")
  push("")

  field("id", util.normalize_id(task.id) or format_value(task.id), "LoopKitDetailId")
  local status = type(task.status) == "string" and task.status:lower() or ""
  field("status", format_value(task.status), status ~= "" and status_hl(status) or "LoopKitDetailMuted")
  field("tag", format_value(task.tag), "LoopKitDetailTag")
  field("origin", format_value(task.origin))
  field("openAt", format_value(task.openAt))
  field("closedAt", format_value(task.closedAt))
  field("hash", format_value(task.hash))

  group_rule()
  local deps_value, deps_ranges = deps_text(task, opts)
  local deps_line = field("deps", deps_value)
  local deps_value_col = 2 + #"deps" + 2
  for _, range in ipairs(deps_ranges) do
    push_hl(deps_line, deps_value_col + range.col_start, deps_value_col + range.col_end, range.hl_group)
  end
  path_field("doc", task.doc)
  path_field("docParent", task.docParent)

  group_rule()
  path_field("specPrompt", task.specPrompt)
  path_field("researchPrompt", task.researchPrompt)
  path_field("codePrompt", task.codePrompt)
  path_field("verifyPrompt", task.verifyPrompt)
  path_field("docTaskSplitPrompt", task.docTaskSplitPrompt)

  group_rule()
  local flow = flow_text(task)
  field("flow", flow or "(default)")

  local touch = task.touch
  if touch == nil or touch == vim.NIL then
    field("touch", "unknown")
  elseif type(touch) == "string" then
    if touch == "" then
      field("touch", "(empty)")
    else
      field("touch", one_line(touch), "LoopKitDetailPath")
    end
  elseif type(touch) ~= "table" or #touch == 0 then
    field("touch", "(empty)")
  else
    out.fields.touch = push("- touch:")
    push_hl(out.fields.touch, 0, #"- touch:", "LoopKitDetailKey")
    for _, path in ipairs(touch) do
      local line = push("  - " .. one_line(tostring(path)))
      push_hl(line, 0, 4, "LoopKitDetailKey")
      push_hl(line, 4, #(out.lines[line]), "LoopKitDetailPath")
    end
  end

  field("meta", meta_text(task))

  local private_desc = task.isPrivateDesc
  if private_desc == nil or private_desc == vim.NIL then
    private_desc = task.private
  end
  if private_desc == nil or private_desc == vim.NIL then
    field("isPrivateDesc", "(unset)", "LoopKitDetailMuted")
  else
    field("isPrivateDesc", private_desc == true and "true" or "false", "LoopKitDetailConstant")
  end

  local analysis = opts.analysis
  if type(analysis) == "table" then
    push("")
    push("---")
    push("")
    field("decide", tostring(analysis.summary or ""))
    field("analysis", "")
    subfield("outstanding", tonumber(analysis.outstanding) or 0)
    subfield("eligible", tostring(analysis.eligible == true), "LoopKitDetailConstant")
    subfield("blocked", tostring(analysis.blocked == true), "LoopKitDetailConstant")
    subfield("stuck", tostring(analysis.stuck == true), "LoopKitDetailConstant")
  end

  local blocked_reason = task.blockedReason
  if type(blocked_reason) == "string" and blocked_reason ~= "" then
    section("blockedReason", "# 阻塞原因")
    out.fields.blockedReason_content = push_block(blocked_reason)
    end_block()
  end

  section("desc", "# 任务描述")
  local desc = task.desc
  if type(desc) == "string" and desc ~= "" then
    out.fields.desc_content = push_block(desc)
  else
    muted_block("desc_content", "暂无内容")
  end
  end_block()

  section("userPrompt", "# 用户提示词")
  local user_prompt = task.userPrompt
  if type(user_prompt) == "string" and user_prompt ~= "" then
    out.fields.userPrompt_content = push_block(user_prompt)
  else
    muted_block("userPrompt_content", "暂无内容")
  end
  end_block()

  section("stagePrompt", "# 各阶段提示词")
  local stage_prompt = task.stagePrompt
  if type(stage_prompt) ~= "table" or stage_prompt == vim.NIL or next(stage_prompt) == nil then
    muted_block("stagePrompt_content", "暂无内容")
    end_block()
  else
    local stage_order = {
      "research",
      "spec",
      "json-task-split",
      "doc-task-split",
      "decision-question",
      "impl",
      "verify",
      "commit",
    }
    local rank = {}
    for index, name in ipairs(stage_order) do
      rank[name] = index
    end
    local keys = {}
    for key in pairs(stage_prompt) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      local ra, rb = rank[a], rank[b]
      if ra and rb then
        return ra < rb
      elseif ra then
        return true
      elseif rb then
        return false
      end
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      local line = push("## " .. one_line(tostring(key)))
      out.fields["stagePrompt." .. tostring(key)] = line
      whole(line, "LoopKitDetailSection")
      push("")
      local value = stage_prompt[key]
      if type(value) == "string" and value ~= "" then
        out.fields["stagePrompt." .. tostring(key) .. ".content"] = push_block(value)
      else
        muted_block("stagePrompt." .. tostring(key) .. ".content", "暂无内容")
      end
      end_block()
    end
  end

  return out
end

return M
