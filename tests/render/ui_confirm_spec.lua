-- Render-level checks for the floating confirm component.
local confirm = require("loop-kit.ui.confirm")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function hl_marks(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.hl_group then
      out[#out + 1] = {
        row = mark[2],
        col = mark[3],
        end_col = details.end_col,
        hl_group = details.hl_group,
      }
    end
  end
  return out
end

local function spans_for(handle)
  local _, spans = confirm.lines(handle.model, handle.width)
  return spans
end

local function noop() end

describe("confirm float", function()
  it("opens a rounded, focusable float sized to the rendered lines", function()
    local handle = confirm.open({
      prompt = "完成任务 #21？",
      options = { "确认", "取消" },
      on_select = noop,
      on_cancel = noop,
    })

    local cfg = vim.api.nvim_win_get_config(handle.win)
    eq("minimal", cfg.style)
    eq("╭", cfg.border[1])
    eq("╯", cfg.border[5])
    eq(true, cfg.focusable)
    eq("center", cfg.title_pos)

    local lines = confirm.lines(handle.model, handle.width)
    eq(#lines, vim.api.nvim_win_get_height(handle.win))
    eq(vim.api.nvim_get_current_win(), handle.win)
    eq(false, vim.wo[handle.win].wrap)
    eq(false, vim.wo[handle.win].cursorline)
    eq("wipe", vim.bo[handle.buf].bufhidden)
    eq(false, vim.bo[handle.buf].swapfile)
    eq(lines, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))

    handle:close()
  end)

  it("moves the highlight with h/l and wraps around", function()
    local handle = confirm.open({
      prompt = "删除该阶段提示词条目？",
      options = { "删除", "取消" },
      on_select = noop,
      on_cancel = noop,
    })
    local spans = spans_for(handle)

    local marks = hl_marks(handle.buf)
    eq(1, #marks)
    eq({ row = spans[1].row, col = spans[1].col, end_col = spans[1].end_col, hl_group = "LoopKitSelected" },
      marks[1])

    feed("l")
    marks = hl_marks(handle.buf)
    eq(1, #marks)
    eq({ row = spans[2].row, col = spans[2].col, end_col = spans[2].end_col, hl_group = "LoopKitSelected" },
      marks[1])

    feed("h")
    marks = hl_marks(handle.buf)
    eq({ row = spans[1].row, col = spans[1].col, end_col = spans[1].end_col, hl_group = "LoopKitSelected" },
      marks[1])

    handle:close()
  end)

  it("confirms with <CR> exactly once and restores the previous window", function()
    local selected, cancelled = {}, 0
    local prev_win = vim.api.nvim_get_current_win()
    local handle = confirm.open({
      prompt = "完成任务 #21？",
      options = { "确认", "取消" },
      on_select = function(value, index)
        selected[#selected + 1] = { value, index }
      end,
      on_cancel = function()
        cancelled = cancelled + 1
      end,
    })

    feed("<CR>")

    eq({ { "确认", 1 } }, selected)
    eq(0, cancelled)
    eq(false, handle:is_open())
    eq(prev_win, vim.api.nvim_get_current_win())
  end)

  it("cancels with q and <Esc>", function()
    local cancelled, selected = 0, 0
    local handle = confirm.open({
      prompt = "继续？",
      options = { "确认", "取消" },
      on_select = function()
        selected = selected + 1
      end,
      on_cancel = function()
        cancelled = cancelled + 1
      end,
    })
    feed("q")
    eq(1, cancelled)
    eq(0, selected)
    eq(false, handle:is_open())

    handle = confirm.open({
      prompt = "继续？",
      options = { "确认", "取消" },
      on_select = function()
        selected = selected + 1
      end,
      on_cancel = function()
        cancelled = cancelled + 1
      end,
    })
    feed("<Esc>")
    eq(2, cancelled)
    eq(0, selected)
    eq(false, handle:is_open())
  end)

  it("cancels exactly once when the window is closed externally", function()
    local cancelled, selected = 0, 0
    local handle = confirm.open({
      prompt = "继续？",
      options = { "确认", "取消" },
      on_select = function()
        selected = selected + 1
      end,
      on_cancel = function()
        cancelled = cancelled + 1
      end,
    })

    vim.api.nvim_win_close(handle.win, true)

    eq(1, cancelled)
    eq(0, selected)
    eq(false, handle:is_open())
  end)

  it("cancels the previous confirm when a new one opens", function()
    local first_cancel = 0
    local first = confirm.open({
      prompt = "第一个？",
      options = { "确认", "取消" },
      on_select = noop,
      on_cancel = function()
        first_cancel = first_cancel + 1
      end,
    })
    local first_win = first.win

    local second = confirm.open({
      prompt = "第二个？",
      options = { "确认", "取消" },
      on_select = noop,
      on_cancel = noop,
    })

    eq(1, first_cancel)
    eq(false, vim.api.nvim_win_is_valid(first_win))
    eq(true, second:is_open())
    second:close()
  end)
end)

describe("confirm helpers", function()
  it("maps boolean cancellation to false and confirms to true", function()
    local result = "unset"
    confirm.boolean("完成任务？", function(value)
      result = value
    end)
    feed("<CR>")
    eq(true, result)

    result = "unset"
    confirm.boolean("删除任务？", function(value)
      result = value
    end, { default = 2 })
    feed("<CR>")
    eq(false, result)

    result = "unset"
    confirm.boolean("删除任务？", function(value)
      result = value
    end)
    feed("q")
    eq(false, result)
  end)

  it("maps choice cancellation to nil and passes strings through", function()
    local result = "unset"
    confirm.choice("选择操作", { "删除", "取消" }, function(value)
      result = value
    end)
    feed("q")
    eq(nil, result)

    result = "unset"
    confirm.choice("选择操作", { "删除", "取消" }, function(value)
      result = value
    end)
    feed("<CR>")
    eq("删除", result)

    result = "unset"
    confirm.choice("选择操作", { "删除", "取消" }, function(value)
      result = value
    end)
    feed("l<CR>")
    eq("取消", result)
  end)
end)
