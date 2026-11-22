-- Fake-DOM tests for the field edit lifecycle: acwrite saves, failure handling,
-- <Esc> discard confirmation, simple inputs and the two-step add flow.
local fake_cli = require("helpers.fake_cli")
local state_mod = require("loop-kit.state")
local source_mod = require("loop-kit.source")
local board_mod = require("loop-kit.ui.board")
local edit = require("loop-kit.edit")

vim.o.hidden = true

local TASKS = {
  {
    id = "#11",
    title = "看板编辑",
    status = "pending",
    tag = "feature",
    origin = "human",
    desc = "旧描述\n第二行",
    userPrompt = "旧提示词",
    stagePrompt = { spec = "旧阶段正文" },
    flow = "quick",
    touch = {},
  },
}

local function json(value)
  return vim.json.encode(value)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
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

local function wait_for(predicate)
  local ok = vim.wait(5000, predicate, 10)
  truthy(ok, "timed out waiting for condition")
end

local function find_call(fake, command)
  for _, call in ipairs(fake:calls()) do
    if call.argv[5] == command then
      return call
    end
  end
end

local function make_editor(overrides)
  vim.cmd("silent! enew!")
  local detail_buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, detail_buf)
  local saves, asked, closed = {}, {}, nil
  local opts = vim.tbl_extend("force", {
    root = "/tmp/loopkit-edit-fake",
    task = { id = "#1" },
    target = { kind = "desc" },
    content = "第一行\n第二行",
    detail_buf = detail_buf,
    detail_win = win,
    notify = function() end,
    ask = function(prompt, options, cb)
      asked[#asked + 1] = { prompt = prompt, options = options, cb = cb }
    end,
    on_save = function(text, cb)
      saves[#saves + 1] = text
      cb(true)
    end,
    on_close = function(reason)
      closed = reason
    end,
  }, overrides or {})
  local ed = edit.open(opts)
  return ed, {
    saves = saves,
    asked = asked,
    closed = function()
      return closed
    end,
  }
end

describe("field edit save", function()
  it("saves the description through stdin", function()
    local board, fake, state = open_board()
    local task = state:selected()
    fake:respond("edit", { stdout = json(vim.tbl_extend("force", task, { desc = "新描述" })) })

    board:_begin_edit({ kind = "desc" }, task, task.desc, false)
    local ed = board.editing.handle
    truthy(ed)
    eq("acwrite", vim.bo[ed.buf].buftype)
    eq("markdown", vim.bo[ed.buf].filetype)
    eq("旧描述\n第二行", table.concat(lines(ed.buf), "\n"))

    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "新描述" })
    vim.cmd("write")
    wait_for(function()
      return board.editing == nil
    end)

    local call = find_call(fake, "edit")
    truthy(call)
    truthy(vim.tbl_contains(call.argv, "--desc-file"))
    truthy(vim.tbl_contains(call.argv, "-"))
    eq("edit", call.argv[5])
    eq("新描述", call.stdin)
  end)

  it("saves the user prompt through stdin", function()
    local board, fake, state = open_board()
    local task = state:selected()
    fake:respond("edit", { stdout = json(vim.tbl_extend("force", task, { userPrompt = "新提示词" })) })

    board:_begin_edit({ kind = "user_prompt" }, task, task.userPrompt, false)
    local ed = board.editing.handle
    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "新提示词" })
    vim.cmd("write")
    wait_for(function()
      return board.editing == nil
    end)

    local call = find_call(fake, "edit")
    truthy(call)
    truthy(vim.tbl_contains(call.argv, "--user-prompt-file"))
    eq("新提示词", call.stdin)
  end)

  it("saves one stage prompt through stdin", function()
    local board, fake, state = open_board()
    local task = state:selected()
    fake:respond("edit", { stdout = json(task) })

    board:_begin_edit({ kind = "stage_content", stage = "spec" }, task, "旧阶段正文", false)
    local ed = board.editing.handle
    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "新阶段正文" })
    vim.cmd("write")
    wait_for(function()
      return board.editing == nil
    end)

    local call = find_call(fake, "edit")
    truthy(call)
    truthy(vim.tbl_contains(call.argv, "--stage-prompt-file"))
    truthy(vim.tbl_contains(call.argv, "spec=-"))
    eq("新阶段正文", call.stdin)
  end)

  it("keeps the buffer dirty and notifies when saving fails", function()
    local board, fake, state, notifications = open_board()
    local task = state:selected()
    fake:respond("edit", { exit = 2, stderr = "boom\n" })

    board:_begin_edit({ kind = "desc" }, task, task.desc, false)
    local ed = board.editing.handle
    local buf = ed.buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "不会保存" })
    vim.cmd("write")
    wait_for(function()
      return #notifications > 0
    end)

    eq(board.editing.handle.buf, buf)
    truthy(vim.bo[buf].modified)
    eq(buf, vim.api.nvim_win_get_buf(board.detail_win))
    truthy(#notifications > 0)
  end)
end)

describe("field edit discard", function()
  it("closes immediately when the buffer is clean", function()
    local ed, state = make_editor()
    ed:request_close()
    eq("discard", state.closed())
    eq(0, #state.saves)
    eq(0, #state.asked)
  end)

  it("asks before discarding dirty content", function()
    local ed, state = make_editor()
    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "改动" })
    eq(true, vim.bo[ed.buf].modified)

    ed:request_close()
    eq(1, #state.asked)
    truthy(state.asked[1].prompt:find("放弃", 1, true))

    state.asked[1].cb("继续编辑")
    eq(nil, state.closed())
    eq(ed.buf, vim.api.nvim_get_current_buf())

    ed:request_close()
    state.asked[2].cb("放弃修改")
    eq("discard", state.closed())
    eq(0, #state.saves)
  end)
end)

describe("simple field input", function()
  it("does nothing when input is cancelled", function()
    local input_calls = {}
    local board, fake = open_board({
      edit_input = function(prompt, _, cb)
        input_calls[#input_calls + 1] = prompt
        cb(nil)
      end,
    })
    local baseline = fake:call_count()
    vim.api.nvim_set_current_win(board.detail_win)
    vim.api.nvim_win_set_cursor(board.detail_win, { board.detail.rendered.title_line, 0 })
    board:handle("edit")

    eq(1, #input_calls)
    eq(nil, board.editing)
    eq(baseline, fake:call_count())
  end)

  it("rejects an empty title", function()
    local board, fake, _, notifications = open_board({
      edit_input = function(_, _, cb)
        cb("")
      end,
    })
    local baseline = fake:call_count()
    vim.api.nvim_set_current_win(board.detail_win)
    vim.api.nvim_win_set_cursor(board.detail_win, { board.detail.rendered.title_line, 0 })
    board:handle("edit")

    truthy(#notifications > 0)
    truthy(notifications[1]:find("任务标题不允许为空", 1, true))
    eq(nil, board.editing)
    eq(baseline, fake:call_count())
  end)

  it("rejects an empty stage name", function()
    local board, fake, _, notifications = open_board({
      edit_input = function(_, _, cb)
        cb("")
      end,
    })
    local baseline = fake:call_count()
    vim.api.nvim_set_current_win(board.detail_win)
    vim.api.nvim_win_set_cursor(board.detail_win, { board.detail.rendered.fields.stagePrompt, 0 })
    board:handle("edit")

    truthy(#notifications > 0)
    truthy(notifications[1]:find("阶段名不能为空", 1, true))
    eq(baseline, fake:call_count())
  end)

  it("asks before editing an existing stage", function()
    local prompts = {}
    local board, fake = open_board({
      edit_input = function(_, _, cb)
        cb("spec")
      end,
      edit_ask = function(prompt, _, cb)
        prompts[#prompts + 1] = prompt
        cb(nil)
      end,
    })
    local baseline = fake:call_count()
    vim.api.nvim_set_current_win(board.detail_win)
    vim.api.nvim_win_set_cursor(board.detail_win, { board.detail.rendered.fields.stagePrompt, 0 })
    board:handle("edit")

    truthy(#prompts > 0)
    truthy(prompts[1]:find("该阶段已存在", 1, true))
    eq(nil, board.editing)
    eq(baseline, fake:call_count())
  end)
end)

describe("new task input", function()
  it("collects title and tag before calling add", function()
    local board, fake = open_board()
    local answers = { "新任务", "bugfix" }
    board.opts.edit_input = function(_, _, cb)
      cb(table.remove(answers, 1))
    end
    fake:respond("add", {
      stdout = json({ id = "#99", title = "新任务", status = "pending", tag = "bugfix" }),
    })
    local baseline = fake:call_count()

    board:handle("add")
    wait_for(function()
      return fake:call_count() > baseline
    end)

    local calls = fake:calls()
    local call = calls[baseline + 1]
    truthy(call)
    eq("add", call.argv[5])
    truthy(vim.tbl_contains(call.argv, "--title"))
    truthy(vim.tbl_contains(call.argv, "--tag"))
    truthy(vim.tbl_contains(call.argv, "新任务"))
    truthy(vim.tbl_contains(call.argv, "bugfix"))
    truthy(vim.tbl_contains(call.argv, "--json"))
  end)

  it("rejects an unknown tag without calling add", function()
    local board, fake, _, notifications = open_board()
    local answers = { "新任务", "bug" }
    board.opts.edit_input = function(_, _, cb)
      cb(table.remove(answers, 1))
    end
    local baseline = fake:call_count()

    board:handle("add")

    eq(baseline, fake:call_count())
    truthy(table.concat(notifications, "\n"):find("分类 tag 无效", 1, true))
  end)

  it("stops when either step is cancelled", function()
    local board, fake = open_board()
    local baseline = fake:call_count()
    board.opts.edit_input = function(_, _, cb)
      cb(nil)
    end
    board:handle("add")
    eq(baseline, fake:call_count())

    local answers = { "新任务", nil }
    board.opts.edit_input = function(_, _, cb)
      cb(table.remove(answers, 1) or nil)
    end
    board:handle("add")
    eq(baseline, fake:call_count())
  end)
end)

describe("path field completion", function()
  local PATH_FIELDS = {
    "doc",
    "docParent",
    "specPrompt",
    "researchPrompt",
    "codePrompt",
    "verifyPrompt",
    "docTaskSplitPrompt",
  }

  it("passes a project-root customlist to every path field input", function()
    local seen = {}
    local board = open_board({
      edit_input = function(_, _, cb, opts)
        seen[#seen + 1] = opts or {}
        cb(nil)
      end,
    })
    vim.api.nvim_set_current_win(board.detail_win)
    for _, field in ipairs(PATH_FIELDS) do
      local line = board.detail.rendered.fields[field]
      truthy(line, "missing detail line for " .. field)
      vim.api.nvim_win_set_cursor(board.detail_win, { line, 0 })
      board:handle("edit")
    end

    eq(#PATH_FIELDS, #seen)
    for index, opts in ipairs(seen) do
      eq(
        "customlist,v:lua.LoopKitPathComplete",
        opts and opts.completion,
        "field " .. PATH_FIELDS[index]
      )
    end
  end)

  it("does not attach completion to the title input", function()
    local seen = {}
    local board = open_board({
      edit_input = function(_, _, cb, opts)
        seen[#seen + 1] = opts or {}
        cb(nil)
      end,
    })
    vim.api.nvim_set_current_win(board.detail_win)
    vim.api.nvim_win_set_cursor(board.detail_win, { board.detail.rendered.title_line, 0 })
    board:handle("edit")

    eq(1, #seen)
    falsy(seen[1] and seen[1].completion)
  end)

  it("attaches repository-relative omnifunc context to touch buffers", function()
    local board, _, state = open_board()
    local task = state:selected()
    vim.api.nvim_set_current_win(board.detail_win)
    vim.api.nvim_win_set_cursor(board.detail_win, { board.detail.rendered.fields.touch, 0 })
    board:handle("edit")

    truthy(board.editing, "touch edit did not start")
    local buf = board.editing.handle.buf
    eq("v:lua.LoopKitPathOmnifunc", vim.bo[buf].omnifunc)
    eq(board.root, vim.b[buf].loopkit_path_root)
    eq(false, vim.b[buf].loopkit_path_allow_absolute)
    eq(0, require("loop-kit.path_complete").omnifunc(1, nil))

    board.editing.handle:request_close()
  end)
end)
