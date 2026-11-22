-- Fake-DOM tests for board behaviour while a field edit is active.
local fake_cli = require("helpers.fake_cli")
local state_mod = require("loop-kit.state")
local source_mod = require("loop-kit.source")
local board_mod = require("loop-kit.ui.board")

vim.o.hidden = true

local TASKS = {
  {
    id = "#11",
    title = "看板编辑",
    status = "pending",
    tag = "feature",
    origin = "human",
    desc = "旧描述",
    userPrompt = "旧提示词",
    stagePrompt = { spec = "旧阶段正文" },
    flow = "quick",
    isPrivateDesc = false,
    touch = {},
  },
}

local function json(value)
  return vim.json.encode(value)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function contains(buf, needle)
  for _, line in ipairs(lines(buf)) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function open_board(overrides)
  local fake = fake_cli.new()
  fake:respond("list", {
    stdout = json({ source = { kind = "local", provider = "local" }, tasks = vim.deepcopy(TASKS) }),
  })
  local client = fake:client()
  local state = state_mod.new():get(fake.root)
  local source = source_mod.new({ client = client, root = fake.root })
  local notifications = {}
  local opts = vim.tbl_extend("force", {
    root = fake.root,
    client = client,
    source = source,
    state = state,
    auto_sync = false,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
  }, overrides or {})
  local board = board_mod.open(opts)
  vim.wait(5000, function()
    return board.loaded or board.load_error ~= nil
  end, 10)
  board:select("#11")
  board:draw()
  return board, fake, state, notifications
end

describe("board edit mode", function()
  it("keeps the edit buffer and shows the info bar on draw", function()
    local board, _, state = open_board()
    local task = state:selected()
    board:_begin_edit({ kind = "desc" }, task, task.desc, false)
    local edit_buf = board.editing.handle.buf

    board:draw()

    eq(edit_buf, vim.api.nvim_win_get_buf(board.detail_win))
    truthy(contains(board.list_buf, "编辑中"))
    truthy(contains(board.list_buf, "目标：任务描述"))
    truthy(contains(board.list_buf, ":w 保存并应用"))
  end)

  it("ignores task actions while editing", function()
    local board, fake, state, notifications = open_board()
    local task = state:selected()
    board:_begin_edit({ kind = "desc" }, task, task.desc, false)
    local baseline = fake:call_count()

    board:handle("done")
    board:handle("remove")
    board:handle("claim")

    eq(baseline, fake:call_count())
    truthy(#notifications > 0)
    truthy(notifications[1]:find("正在编辑", 1, true))
    truthy(board.editing ~= nil)
  end)

  it("closes a clean edit on quit instead of the board", function()
    local board, fake, state = open_board()
    local task = state:selected()
    board:_begin_edit({ kind = "desc" }, task, task.desc, false)
    eq(false, board.closed)

    board:handle("close")

    eq(nil, board.editing)
    eq(false, board.closed)
    eq(board.detail_buf, vim.api.nvim_win_get_buf(board.detail_win))
    truthy(vim.tbl_contains(lines(board.list_buf), ""))
  end)

  it("returns to the touch field after a multi-line save", function()
    local board, fake, state = open_board()
    fake:respond("touch", {
      stdout = json({ task = { id = "#11", title = "看板编辑", status = "pending" } }),
    })
    local task = state:selected()
    board:_begin_edit({ kind = "touch" }, task, "lua/a.lua", false)
    local edit_buf = board.editing.handle.buf
    vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, { "lua/a.lua", "tests/a_spec.lua" })
    vim.api.nvim_buf_call(edit_buf, function()
      vim.cmd("write")
    end)

    vim.wait(5000, function()
      return board.editing == nil
    end, 10)
    eq(board.detail_buf, vim.api.nvim_win_get_buf(board.detail_win))
    eq(board.detail.rendered.fields.touch, vim.api.nvim_win_get_cursor(board.detail_win)[1])
  end)

  it("toggles isPrivateDesc when e is pressed on its line", function()
    local board, fake, state = open_board()
    fake:respond("private", {
      stdout = json({ task = { id = "#11", title = "看板编辑", status = "pending", isPrivateDesc = true } }),
    })
    local task = state:selected()
    local before = fake:call_count()
    vim.api.nvim_set_current_win(board.detail_win)
    vim.api.nvim_win_set_cursor(board.detail_win, { board.detail.rendered.fields.isPrivateDesc, 0 })

    board:_start_edit()

    vim.wait(5000, function()
      return fake:call_count() > before and state:selected().isPrivateDesc == true
    end, 10)
    local call = fake:call(before + 1)
    truthy(vim.tbl_contains(call.argv, "private"))
    truthy(vim.tbl_contains(call.argv, "#11"))
    truthy(vim.tbl_contains(call.argv, "--on"))
    falsy(vim.tbl_contains(call.argv, "--off"))
    eq(true, state:selected().isPrivateDesc)
    eq(board.detail.rendered.fields.isPrivateDesc, vim.api.nvim_win_get_cursor(board.detail_win)[1])
  end)
end)
