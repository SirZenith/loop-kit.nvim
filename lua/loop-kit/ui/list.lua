-- List pane: renders the task list, owns navigation and status notices.
--
-- The pane is a read-only scratch buffer. `draw` renders the current state
-- groups through the pure renderer; `notice` replaces the list with one of the
-- four distinguishable placeholder states (loading/empty/no match/error).
local render = require("loop-kit.render")

local M = {}
local List = {}
List.__index = List

local ns = vim.api.nvim_create_namespace("loop-kit-ui-list")

local NOTICE_HINTS = {
  loading = "正在读取 loop-cli 缓存",
  empty = "当前项目还没有任务，按 a 新建",
  no_match = "调整筛选或按 / 修改关键字",
  error = "检查 loop-cli 配置后按 r / R 重试",
}

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function set_readonly_lines(buf, lines)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  return ok, err
end

--- Create a list pane.
--- opts: state (required), buf, win, icons, on_select(id), setup (default true).
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, List)
  self.state = assert(opts.state, "loop-kit.ui.list: state is required")
  self.buf = opts.buf or vim.api.nvim_create_buf(false, true)
  self.win = opts.win
  self.icons = opts.icons
  self.sort = opts.sort
  self.on_select = opts.on_select
  self.hint = nil
  self.rendered = nil
  self.notice_kind = nil

  if opts.setup ~= false then
    vim.bo[self.buf].buftype = "nofile"
    vim.bo[self.buf].bufhidden = "hide"
    vim.bo[self.buf].swapfile = false
    vim.bo[self.buf].modifiable = false
    pcall(function()
      vim.bo[self.buf].filetype = "loopkit"
    end)
  end

  return self
end

function List:is_valid()
  return valid_buf(self.buf)
end

local function apply_highlights(buf, rendered)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for line, hl in pairs(rendered.line_hl or {}) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl, line - 1, 0, -1)
  end
end

--- Show a one-line key hint above the rows (and above notices).
function List:set_hint(text)
  self.hint = text
  return self
end

local function shift_rendered(rendered, offset)
  local line_map, id_to_line, line_hl = {}, {}, {}
  for line, id in pairs(rendered.line_map) do
    line_map[line + offset] = id
  end
  for id, line in pairs(rendered.id_to_line) do
    id_to_line[id] = line + offset
  end
  for line, hl in pairs(rendered.line_hl) do
    line_hl[line + offset] = hl
  end
  rendered.line_map, rendered.id_to_line, rendered.line_hl = line_map, id_to_line, line_hl
  if rendered.selected_line then
    rendered.selected_line = rendered.selected_line + offset
  end
  for _, group in ipairs(rendered.groups or {}) do
    for _, key in ipairs({ "header_line", "first_line", "last_line" }) do
      if group[key] then
        group[key] = group[key] + offset
      end
    end
  end
end

local function place_cursor(self, line)
  if not valid_win(self.win) or not line then
    return
  end
  pcall(function()
    vim.api.nvim_win_set_cursor(self.win, { line, 0 })
  end)
end

--- Render the current state; returns the renderer result.
function List:draw(opts)
  opts = opts or {}
  if not valid_buf(self.buf) then
    return nil
  end
  local rendered = render.list(self.state:groups(), {
    icons = self.icons,
    selected_id = self.state:selected_id(),
    sort = self.sort,
  })
  if self.hint and self.hint ~= "" then
    table.insert(rendered.lines, 1, "")
    table.insert(rendered.lines, 1, self.hint)
    shift_rendered(rendered, 2)
    rendered.line_hl[1] = "LoopKitMuted"
  end
  self.rendered = rendered
  self.notice_kind = nil
  set_readonly_lines(self.buf, rendered.lines)
  apply_highlights(self.buf, rendered)
  place_cursor(self, rendered.selected_line)
  return rendered
end

--- Show a distinguishable placeholder instead of task rows.
--- kind: loading | empty | no_match | error.
function List:notice(kind, text)
  if not valid_buf(self.buf) then
    return nil
  end
  local hint = NOTICE_HINTS[kind]
  local lines = {}
  if self.hint and self.hint ~= "" then
    lines[#lines + 1] = self.hint
    lines[#lines + 1] = ""
  end
  local text_line = #lines + 1
  lines[text_line] = text or kind or ""
  if hint then
    lines[#lines + 1] = ""
    lines[#lines + 1] = hint
  end
  self.rendered = nil
  self.notice_kind = kind
  set_readonly_lines(self.buf, lines)
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  if self.hint and self.hint ~= "" then
    pcall(vim.api.nvim_buf_add_highlight, self.buf, ns, "LoopKitMuted", 0, 0, -1)
  end
  local hl = kind == "error" and "LoopKitError" or "LoopKitMuted"
  pcall(vim.api.nvim_buf_add_highlight, self.buf, ns, hl, text_line - 1, 0, -1)
  return lines
end

function List:visible_ids()
  local ids = {}
  for _, task in ipairs(self.state:visible_tasks()) do
    ids[#ids + 1] = task.id
  end
  return ids
end

function List:selected_task()
  return self.state:selected()
end

--- Move the selection by `delta` visible rows and redraw.
function List:move(delta)
  delta = tonumber(delta) or 1
  local ids = self:visible_ids()
  if #ids == 0 then
    return nil
  end

  local current = self.state:selected_id()
  local index = nil
  for i, id in ipairs(ids) do
    if id == current then
      index = i
      break
    end
  end
  if not index then
    index = 1
  else
    index = math.max(1, math.min(#ids, index + delta))
  end

  local id = ids[index]
  self.state:select(id)
  self:draw()
  if self.on_select then
    self.on_select(id)
  end
  return id
end

--- Select a task by id when it is visible; redraw and notify.
function List:select_id(id)
  if not self.state:select(id) then
    return false
  end
  self:draw()
  if self.on_select then
    self.on_select(self.state:selected_id())
  end
  return true
end

--- Task under the buffer cursor, or the current selection.
function List:cursor_task()
  if valid_win(self.win) and self.rendered then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, self.win)
    if ok then
      local id = self.rendered.line_map[cursor[1]]
      if id then
        return self.state:selected()
      end
    end
  end
  return self.state:selected()
end

function List:focus()
  if valid_win(self.win) then
    pcall(vim.api.nvim_set_current_win, self.win)
  end
end

return M
