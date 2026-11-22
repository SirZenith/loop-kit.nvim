-- Detail pane: read-only markdown view of the selected task.
--
-- Writes temporarily flip `modifiable`, then restore it under pcall so a
-- failed write never leaves the buffer editable. `open_doc` resolves the task
-- doc relative to the project root and delegates the actual `:edit` to an
-- injectable opener.
local render = require("loop-kit.render")
local util = require("loop-kit.util")

local M = {}
local Detail = {}
Detail.__index = Detail

local PLACEHOLDER = "未选择任务"
local ns = vim.api.nvim_create_namespace("loop-kit-ui-detail")

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function write_lines(buf, lines)
  if not valid_buf(buf) then
    return false, "detail buffer 已失效"
  end
  pcall(function()
    vim.bo[buf].modifiable = true
  end)
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  pcall(function()
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end)
  return ok, err
end

local function apply_highlights(buf, rendered)
  if not valid_buf(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not rendered then
    return
  end
  for _, range in ipairs(rendered.highlights or {}) do
    local line_text = rendered.lines[range.line] or ""
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, range.line - 1, range.col_start, {
      end_col = math.min(range.col_end, #line_text),
      hl_group = range.hl_group,
      priority = 200,
    })
  end
end

--- Create a detail pane.
--- opts: root, buf, win, opener(path), notify(message), setup (default true).
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Detail)
  self.root = opts.root
  self.buf = opts.buf or vim.api.nvim_create_buf(false, true)
  self.win = opts.win
  self.opener = opts.opener
  self.notify = opts.notify
  self.rendered = nil
  self.task = nil

  if opts.setup ~= false then
    vim.bo[self.buf].buftype = "nofile"
    vim.bo[self.buf].bufhidden = "hide"
    vim.bo[self.buf].swapfile = false
    vim.bo[self.buf].modifiable = false
    pcall(function()
      vim.bo[self.buf].filetype = "markdown"
    end)
  end

  return self
end

--- Render `task` (or clear when nil). Returns the renderer result.
--- `analysis` (from `list`/`decide`) appends a decide/analysis block when set.
function Detail:render(task, tasks_by_id, analysis, tasks)
  self.task = task
  if not task then
    return self:placeholder(PLACEHOLDER)
  end
  local explain = nil
  if analysis and type(analysis) == "table" then
    explain = require("loop-kit.decide").explain(analysis, task, tasks or {})
  end
  local rendered = render.detail(task, { tasks_by_id = tasks_by_id, analysis = explain })
  if explain then
    rendered.analysis = explain
  end
  self.rendered = rendered
  local ok = write_lines(self.buf, rendered.lines)
  if not ok then
    return nil
  end
  apply_highlights(self.buf, rendered)
  return rendered
end

function Detail:placeholder(text)
  self.task = nil
  self.rendered = nil
  local rendered = {
    lines = { "# " .. (text or PLACEHOLDER), "", "从上方的任务列表选择一条任务。" },
    highlights = {},
  }
  rendered.highlights[1] = {
    line = 1,
    col_start = 0,
    col_end = #rendered.lines[1],
    hl_group = "LoopKitDetailTitle",
  }
  rendered.highlights[2] = {
    line = 3,
    col_start = 0,
    col_end = #rendered.lines[3],
    hl_group = "LoopKitDetailMuted",
  }
  write_lines(self.buf, rendered.lines)
  apply_highlights(self.buf, rendered)
  return nil
end

function Detail:is_readonly()
  if not valid_buf(self.buf) then
    return true
  end
  return vim.bo[self.buf].modifiable == false
end

function Detail:doc_line()
  return self.rendered and self.rendered.fields and self.rendered.fields.doc or nil
end

--- Resolve a task doc path relative to the project root.
--- Returns absolute path or nil, reason.
function M.resolve_doc(root, doc)
  if type(doc) ~= "string" then
    return nil, "任务没有 doc 字段"
  end
  local trimmed = util.trim(doc)
  if not trimmed or trimmed == "" then
    return nil, "任务没有 doc 字段"
  end
  if trimmed:find("[\r\n]") then
    return nil, "doc 路径不能包含换行"
  end
  local absolute = util.absolute_path(root, trimmed)
  if not absolute then
    return nil, "无法解析 doc 路径"
  end
  return absolute
end

--- Open the doc for `task` (defaults to the rendered task).
--- Returns ok, path-or-reason.
function Detail:open_doc(task)
  task = task or self.task
  local absolute, reason = M.resolve_doc(self.root, task and task.doc)
  if not absolute then
    if self.notify then
      self.notify(reason)
    end
    return false, reason
  end

  if valid_win(self.win) then
    pcall(vim.api.nvim_set_current_win, self.win)
  end

  local opener = self.opener or function(path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end

  local ok, err = pcall(opener, absolute)
  if not ok then
    local message = "打开 doc 失败：" .. tostring(err)
    if self.notify then
      self.notify(message)
    end
    return false, message
  end
  return true, absolute
end

return M
