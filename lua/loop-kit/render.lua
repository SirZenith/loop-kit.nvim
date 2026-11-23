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

  -- Selected cards keep the accent colours; unselected cards recede into the
  -- comment colour, and only the selected title uses the normal text colour.
  local id_hl = selected and "LoopKitId" or "LoopKitMuted"
  local title_hl = selected and "Normal" or "LoopKitMuted"
  local tag_hl = selected and "LoopKitTag" or "LoopKitMuted"

  -- Line 1: ╭─ #id  (space fill)  <icon> <status> ─╮
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
    local fill = string.rep(" ", width - head_w - id_w - suffix_w - tail_w)
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
  push(1, #head, id_end, id_hl)
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
  push(2, #"│ ", #"│ " + #shown_title, title_hl)
  push(2, #"│ " + #shown_title, #rows[2], border_hl)

  local segments = {}
  if tag ~= "" then
    segments[#segments + 1] = { text = tag, hl = tag_hl }
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

local DETAIL_CARD_MAX_WIDTH = 64
local DETAIL_CARD_MIN_WIDTH = 20
local DETAIL_CARD_GAP = 2

--- Split styled segments into rows of at most `width` display columns.
-- Rows break on spaces once past half width, otherwise on character
-- boundaries; every fragment keeps its source highlight group.
local function wrap_segments(segments, width)
  width = math.max(1, math.floor(tonumber(width) or 0))
  local cells = {}
  for _, segment in ipairs(segments or {}) do
    local text = (segment.text or ""):gsub("[\r\n]+", " ")
    local count = vim.fn.strchars(text)
    for index = 0, count - 1 do
      local char = vim.fn.strcharpart(text, index, 1)
      cells[#cells + 1] = {
        text = char,
        width = util.display_width(char),
        hl_group = segment.hl_group,
      }
    end
  end

  local function merge(row)
    local merged = {}
    for _, cell in ipairs(row) do
      local last = merged[#merged]
      if last and last.hl_group == cell.hl_group then
        last.text = last.text .. cell.text
      else
        merged[#merged + 1] = { text = cell.text, hl_group = cell.hl_group }
      end
    end
    return merged
  end

  local function row_width(list, count)
    local total = 0
    for index = 1, count or #list do
      total = total + list[index].width
    end
    return total
  end

  local rows, row, used = {}, {}, 0
  local function flush()
    while #row > 0 and row[#row].text == " " do
      table.remove(row)
    end
    rows[#rows + 1] = merge(row)
    row, used = {}, 0
  end

  for _, cell in ipairs(cells) do
    if cell.width == 0 then
      if #row > 0 then
        row[#row].text = row[#row].text .. cell.text
      else
        row[#row + 1] = cell
      end
    elseif used + cell.width > width then
      local space
      for index = #row, 1, -1 do
        if row[index].text == " " then
          space = index
          break
        end
      end
      if space and space > 1 and row_width(row, space - 1) > width / 2 then
        local tail = {}
        for index = space + 1, #row do
          tail[#tail + 1] = row[index]
        end
        local head = {}
        for index = 1, space - 1 do
          head[#head + 1] = row[index]
        end
        row = head
        flush()
        row, used = tail, row_width(tail)
        if used + cell.width > width and used > 0 then
          flush()
        end
      else
        flush()
      end
      row[#row + 1] = cell
      used = used + cell.width
    else
      row[#row + 1] = cell
      used = used + cell.width
    end
  end
  flush()
  if #rows == 0 then
    rows[1] = {}
  end
  return rows
end

--- Dependency segments: ids keep their own highlight, status icons use the
--- status colour, and missing tasks fall back to the bare id.
local function deps_segments(task, opts)
  local deps = task.deps
  if deps == nil or deps == vim.NIL or type(deps) ~= "table" or #deps == 0 then
    return { { text = "(none)" } }
  end

  local icons = vim.tbl_extend("force", M.icons, opts.icons or {})
  local segments = {}
  for index, dep in ipairs(deps) do
    local id = util.normalize_id(dep) or one_line(tostring(dep))
    segments[#segments + 1] = { text = id, hl_group = "LoopKitDetailId" }
    local by_id = opts.tasks_by_id
    local dep_task = by_id and (by_id[id] or by_id[dep])
    local status = dep_task and dep_task.status
    if type(status) == "string" and status ~= "" then
      status = status:lower()
      segments[#segments + 1] = { text = " " }
      segments[#segments + 1] = {
        text = icons[status] or "?",
        hl_group = status_hl(status),
      }
    end
    if index < #deps then
      segments[#segments + 1] = { text = ", " }
    end
  end
  return segments
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

  local function is_unset(value)
    return value == nil or value == vim.NIL or value == ""
  end

  local function seg(text, hl_group)
    return { { text = text or "", hl_group = hl_group } }
  end

  local cards = {}
  local current_card = nil

  local function card(title)
    current_card = { title = title, fields = {} }
    cards[#cards + 1] = current_card
  end

  local function field(key, segments, blocks)
    current_card.fields[#current_card.fields + 1] = {
      key = key,
      blocks = blocks or { segments or seg("") },
    }
  end

  local function path_field(key, value)
    if is_unset(value) then
      return field(key, seg("(未设置)", "LoopKitDetailMuted"))
    end
    return field(key, seg(one_line(tostring(value)), "LoopKitDetailPath"))
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

  -- Metadata is grouped into cards; a blank line separates one card from the
  -- next and the title above already separates the cards from the heading.

  local title = one_line(task.title)
  out.title_line = push("# " .. (title ~= "" and title or "(untitled)"))
  whole(out.title_line, "LoopKitDetailTitle")
  push("")

  card("状态信息")
  field("id", seg(util.normalize_id(task.id) or format_value(task.id), "LoopKitDetailId"))
  local status = type(task.status) == "string" and task.status:lower() or ""
  field("status", seg(format_value(task.status), status ~= "" and status_hl(status) or "LoopKitDetailMuted"))
  field("tag", seg(format_value(task.tag), "LoopKitDetailTag"))
  field("origin", seg(format_value(task.origin)))
  field("openAt", seg(format_value(task.openAt)))
  field("closedAt", seg(format_value(task.closedAt)))
  field("hash", seg(format_value(task.hash)))

  card("依赖与文档")
  field("deps", deps_segments(task, opts))
  path_field("doc", task.doc)
  path_field("docParent", task.docParent)

  card("提示词")
  path_field("specPrompt", task.specPrompt)
  path_field("researchPrompt", task.researchPrompt)
  path_field("codePrompt", task.codePrompt)
  path_field("verifyPrompt", task.verifyPrompt)
  path_field("docTaskSplitPrompt", task.docTaskSplitPrompt)

  card("执行信息")
  local flow = flow_text(task)
  field("flow", seg(flow or "(default)"))

  local touch = task.touch
  local touch_blocks
  if touch == nil or touch == vim.NIL then
    touch_blocks = { seg("unknown") }
  elseif type(touch) == "string" then
    if touch == "" then
      touch_blocks = { seg("(empty)") }
    else
      touch_blocks = { seg(one_line(touch), "LoopKitDetailPath") }
    end
  elseif type(touch) ~= "table" or #touch == 0 then
    touch_blocks = { seg("(empty)") }
  else
    touch_blocks = {}
    for _, path in ipairs(touch) do
      touch_blocks[#touch_blocks + 1] = seg(one_line(tostring(path)), "LoopKitDetailPath")
    end
  end
  field("touch", nil, touch_blocks)

  field("meta", seg(meta_text(task)))

  local private_desc = task.isPrivateDesc
  if private_desc == nil or private_desc == vim.NIL then
    private_desc = task.private
  end
  if private_desc == nil or private_desc == vim.NIL then
    field("isPrivateDesc", seg("(unset)", "LoopKitDetailMuted"))
  else
    field("isPrivateDesc", seg(private_desc == true and "true" or "false", "LoopKitDetailConstant"))
  end

  local analysis = opts.analysis
  if type(analysis) == "table" then
    card("决策说明")
    field("decide", seg(tostring(analysis.summary or "")))
    field("analysis", seg(""))
    field("outstanding", seg(tostring(tonumber(analysis.outstanding) or 0)))
    field("eligible", seg(tostring(analysis.eligible == true), "LoopKitDetailConstant"))
    field("blocked", seg(tostring(analysis.blocked == true), "LoopKitDetailConstant"))
    field("stuck", seg(tostring(analysis.stuck == true), "LoopKitDetailConstant"))
  end

  local width = tonumber(opts.width) or DETAIL_CARD_MAX_WIDTH
  width = math.min(DETAIL_CARD_MAX_WIDTH, math.max(DETAIL_CARD_MIN_WIDTH, math.floor(width)))

  local function render_card(spec)
    local inner = width - 4
    local key_width = 1
    for _, item in ipairs(spec.fields) do
      key_width = math.max(key_width, util.display_width(item.key))
    end
    local key_col = math.max(4, math.min(key_width, math.floor(inner * 0.45)))
    local value_col = math.max(1, inner - key_col - DETAIL_CARD_GAP)

    local title_text = util.truncate_display(spec.title, width - 5)
    local fill = math.max(0, width - 5 - util.display_width(title_text))
    local top_line = push("╭─ " .. title_text .. " " .. string.rep("─", fill) .. "╮")
    local title_col = #"╭─ "
    push_hl(top_line, 0, title_col, "LoopKitMuted")
    push_hl(top_line, title_col, title_col + #title_text, "LoopKitDetailSection")
    push_hl(top_line, title_col + #title_text, #(out.lines[top_line]), "LoopKitMuted")

    for _, item in ipairs(spec.fields) do
      local key_text = util.truncate_display(item.key, key_col)
      local key_cell = util.pad_display(key_text, key_col)
      local first_line = nil
      for _, block in ipairs(item.blocks) do
        for _, row in ipairs(wrap_segments(block, value_col)) do
          local pieces = {}
          for _, fragment in ipairs(row) do
            pieces[#pieces + 1] = fragment.text
          end
          local value_text = table.concat(pieces)
          local padding = math.max(0, value_col - util.display_width(value_text))
          local right_align = first_line == nil
          local left = right_align and key_cell or string.rep(" ", key_col)
          local pad = right_align and string.rep(" ", padding) or ""
          local value_part = right_align and value_text or util.pad_display(value_text, value_col)
          local line = push("│ " .. left .. "  " .. pad .. value_part .. " │")
          if right_align then
            first_line = line
            out.fields[item.key] = line
            push_hl(line, #"│ ", #"│ " + #key_text, "LoopKitDetailKey")
          end
          local col = #"│ " + #left + 2 + #pad
          for _, fragment in ipairs(row) do
            local text = fragment.text or ""
            if fragment.hl_group and text ~= "" then
              push_hl(line, col, col + #text, fragment.hl_group)
            end
            col = col + #text
          end
        end
      end
    end

    local bottom_line = push("╰" .. string.rep("─", width - 2) .. "╯")
    whole(bottom_line, "LoopKitMuted")
  end

  for index, spec in ipairs(cards) do
    if index > 1 then
      push("")
    end
    render_card(spec)
  end
  push("")

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
