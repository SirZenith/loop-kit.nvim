-- Render-level checks for the acwrite edit buffer.
local edit = require("loop-kit.edit")

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("edit buffer", function()
  it("starts with the target content and markdown/acwrite options", function()
    local detail_buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, detail_buf)

    local ed = edit.open({
      root = "/tmp/loopkit-render-edit",
      task = { id = "#11" },
      target = { kind = "desc" },
      content = "第一行\n第二行\n",
      detail_buf = detail_buf,
      detail_win = win,
      notify = function() end,
      on_save = function(_, cb)
        cb(true)
      end,
      on_close = function() end,
    })

    eq({ "第一行", "第二行", "" }, lines(ed.buf))
    eq("acwrite", vim.bo[ed.buf].buftype)
    eq("markdown", vim.bo[ed.buf].filetype)
    eq(false, vim.bo[ed.buf].swapfile)
    eq(ed.buf, vim.api.nvim_win_get_buf(win))
    truthy(ed.name:find("loopkit://", 1, true))
    truthy(ed.name:find("%2311", 1, true))
  end)

  it("restores the detail buffer after a successful save", function()
    local detail_buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, detail_buf)
    local saved

    local ed = edit.open({
      root = "/tmp/loopkit-render-edit",
      task = { id = "#12" },
      target = { kind = "user_prompt" },
      content = "正文",
      detail_buf = detail_buf,
      detail_win = win,
      notify = function() end,
      ask = function() end,
      on_save = function(text, cb)
        saved = text
        cb(true)
      end,
      on_close = function() end,
    })

    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "新正文" })
    vim.cmd("write")

    eq("新正文", saved)
    truthy(ed.closed)
    eq(detail_buf, vim.api.nvim_win_get_buf(win))
  end)
end)
