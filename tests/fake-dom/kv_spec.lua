-- Fake-DOM tests for key/value field editing: single/multi pickers, prompts,
-- touch buffers and readonly hints.
local fake_cli = require("helpers.fake_cli")
local state_mod = require("loop-kit.state")
local source_mod = require("loop-kit.source")
local board_mod = require("loop-kit.ui.board")
local advanced_mod = require("loop-kit.advanced")

vim.o.hidden = true

local TASKS = {
  {
    id = "#11",
    title = "看板编辑",
    status = "pending",
    tag = "feature",
    origin = "human",
    openAt = "2026-11-22T16:13:17+08:00",
    desc = "旧描述",
    deps = { "#10", "#99" },
    flow = "quick",
    touch = { "lua/a.lua", "tests/a_spec.lua" },
  },
  { id = "#10", title = "基础", status = "done", deps = {} },
  { id = "#12", title = "依赖回环", status = "pending", deps = { "#11" } },
}

local function json(value)
  return vim.json.encode(value)
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
    watch = false,
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

local function put_cursor(board, line)
  vim.api.nvim_set_current_win(board.detail_win)
  vim.api.nvim_win_set_cursor(board.detail_win, { line, 0 })
end

describe("tag editing", function()
  it("offers TARGETS tags with the current value marked", function()
    local captured
    local board = open_board({
      select = function(items, opts, _cb)
        captured = { items = items, opts = opts }
      end,
    })
    put_cursor(board, board.detail.rendered.fields.tag)
    board:handle("edit")

    truthy(captured)
    local found
    for _, item in ipairs(captured.items) do
      if item.value == "feature" then
        found = item
      end
    end
    truthy(found, "current tag must be listed")
    match(captured.opts.format_item(found), "（当前）")
  end)

  it("does not write when the current tag is selected", function()
    local board, fake = open_board({
      select = function(_, _, cb)
        cb({ value = "feature" })
      end,
    })
    local baseline = fake:call_count()
    put_cursor(board, board.detail.rendered.fields.tag)
    board:handle("edit")

    eq(baseline, fake:call_count())
    eq(nil, board.editing)
  end)
end)

describe("deps editing", function()
  it("hides cycle-forming candidates and preselects current deps", function()
    local captured
    local board = open_board({
      multi = function(opts)
        captured = opts
      end,
    })
    put_cursor(board, board.detail.rendered.fields.deps)
    board:handle("edit")

    truthy(captured)
    eq(2, captured.hidden) -- self plus #12, which already depends on #11
    local by_id = {}
    for _, item in ipairs(captured.items) do
      by_id[item.value] = item
    end
    eq(true, by_id["#10"].selected)
    truthy(by_id["#99"], "ghost dependency stays listed")
    eq(true, by_id["#99"].selected)
    eq(nil, by_id["#12"], "cycle candidate must be hidden")
  end)

  it("writes the confirmed dependency set", function()
    local captured
    local board, fake = open_board({
      multi = function(opts)
        captured = opts
      end,
    })
    fake:respond("deps", { stdout = json({ task = { id = "#11", title = "看板编辑", status = "pending" } }) })
    put_cursor(board, board.detail.rendered.fields.deps)
    board:handle("edit")

    captured.on_confirm({ "#10" })
    wait_for(function()
      return find_call(fake, "deps") ~= nil
    end)
    local call = find_call(fake, "deps")
    truthy(vim.tbl_contains(call.argv, "--set"))
    truthy(vim.tbl_contains(call.argv, "#10"))
  end)

  it("does not write when the dependency set is unchanged", function()
    local captured
    local board, fake = open_board({
      multi = function(opts)
        captured = opts
      end,
    })
    local baseline = fake:call_count()
    put_cursor(board, board.detail.rendered.fields.deps)
    board:handle("edit")

    captured.on_confirm({ "#99", "#10" })
    eq(baseline, fake:call_count())
    eq(nil, board.editing)
  end)

  it("clears deps with an explicit empty --set value", function()
    local captured
    local board, fake = open_board({
      multi = function(opts)
        captured = opts
      end,
    })
    fake:respond("deps", { stdout = json({ task = { id = "#11", title = "看板编辑", status = "pending" } }) })
    put_cursor(board, board.detail.rendered.fields.deps)
    board:handle("edit")

    captured.on_confirm({})
    wait_for(function()
      return find_call(fake, "deps") ~= nil
    end)
    local call = find_call(fake, "deps")
    eq("#11", call.argv[6])
    eq("--set", call.argv[7])
    eq("", call.argv[8])
  end)
end)

describe("flow editing", function()
  local function flow_payload(extra)
    return json(vim.tbl_extend("force", {
      builtin = { "full", "quick" },
      custom = { mine = { "research", "spec", "impl", "verify", "commit" } },
    }, vim.tbl_extend("force", {
      id = "#11",
      title = "看板编辑",
      status = "pending",
    }, extra or {})))
  end

  local function flow_writes(fake)
    local writes = {}
    for _, call in ipairs(fake:calls()) do
      if call.argv[5] == "flow" and vim.tbl_contains(call.argv, "#11") then
        writes[#writes + 1] = call
      end
    end
    return writes
  end

  it("offers builtin, custom, custom-stage and clear candidates", function()
    local captured
    local board, fake = open_board({
      select = function(items, _, _cb)
        captured = items
      end,
    })
    fake:respond("flow", { stdout = flow_payload() })
    put_cursor(board, board.detail.rendered.fields.flow)
    board:handle("edit")

    wait_for(function()
      return captured ~= nil
    end)
    eq("full", captured[1].value)
    eq("quick", captured[2].value)
    eq("mine", captured[3].value)
    eq(advanced_mod.CUSTOM_FLOW, captured[4].value)
    eq(advanced_mod.CLEAR_FLOW, captured[5].value)
  end)

  it("hides the custom flow currently in use", function()
    local captured, captured_opts
    local board, fake = open_board({
      select = function(items, opts, _cb)
        captured, captured_opts = items, opts
      end,
    })
    for _, item in ipairs(board.state.tasks) do
      if item.id == "#11" then
        item.flow = "mine"
      end
    end
    board:draw()
    fake:respond("flow", { stdout = flow_payload({ flow = "mine" }) })
    put_cursor(board, board.detail.rendered.fields.flow)
    board:handle("edit")

    wait_for(function()
      return captured ~= nil
    end)
    local values = {}
    for _, item in ipairs(captured) do
      values[#values + 1] = item.value
    end
    eq({ "full", "quick", advanced_mod.CUSTOM_FLOW, advanced_mod.CLEAR_FLOW }, values)
    for _, item in ipairs(captured) do
      falsy(captured_opts.format_item(item):find("（当前）", 1, true))
    end
  end)

  it("does not append the custom stage list currently in use", function()
    local captured, captured_opts
    local board, fake = open_board({
      select = function(items, opts, _cb)
        captured, captured_opts = items, opts
      end,
    })
    local stages = { "research", "spec", "impl", "verify", "commit" }
    for _, item in ipairs(board.state.tasks) do
      if item.id == "#11" then
        item.flow = stages
      end
    end
    board:draw()
    fake:respond("flow", { stdout = flow_payload({ flow = stages }) })
    put_cursor(board, board.detail.rendered.fields.flow)
    board:handle("edit")

    wait_for(function()
      return captured ~= nil
    end)
    local values = {}
    for _, item in ipairs(captured) do
      values[#values + 1] = item.value
    end
    eq({ "full", "quick", "mine", advanced_mod.CUSTOM_FLOW, advanced_mod.CLEAR_FLOW }, values)
    for _, item in ipairs(captured) do
      falsy(captured_opts.format_item(item):find("（当前）", 1, true))
    end
  end)

  it("falls back to builtin flows and notifies when --list fails", function()
    local captured
    local board, fake, _, notifications = open_board({
      select = function(items, _, _cb)
        captured = items
      end,
    })
    fake:respond("flow", { exit = 1, stderr = "boom\n" })
    put_cursor(board, board.detail.rendered.fields.flow)
    board:handle("edit")

    wait_for(function()
      return captured ~= nil
    end)
    eq(#advanced_mod.FLOWS + 2, #captured)
    eq(advanced_mod.FLOWS[1], captured[1].value)
    eq(advanced_mod.CUSTOM_FLOW, captured[#captured - 1].value)
    eq(advanced_mod.CLEAR_FLOW, captured[#captured].value)
    truthy(table.concat(notifications, "\n"):find("读取流程列表失败", 1, true))
  end)

  it("does not write when the current flow is selected", function()
    local picked = false
    local board, fake = open_board({
      select = function(_, _, cb)
        picked = true
        cb({ value = "quick" })
      end,
    })
    fake:respond("flow", { stdout = flow_payload() })
    put_cursor(board, board.detail.rendered.fields.flow)
    board:handle("edit")

    wait_for(function()
      return picked
    end)
    eq(0, #flow_writes(fake))
    eq(nil, board.editing)
  end)

  it("rejects an invalid custom stage list without writing", function()
    local board, fake, _, notifications = open_board({
      select = function(_, _, cb)
        cb({ value = advanced_mod.CUSTOM_FLOW })
      end,
      edit_input = function(_, _, cb)
        cb("impl,spec,commit")
      end,
    })
    fake:respond("flow", { stdout = flow_payload() })
    put_cursor(board, board.detail.rendered.fields.flow)
    board:handle("edit")

    wait_for(function()
      return table.concat(notifications, "\n"):find("顺序", 1, true) ~= nil
    end)
    eq(0, #flow_writes(fake))
    eq(nil, board.editing)
  end)
end)

describe("readonly rows", function()
  it("notifies without writing", function()
    local board, fake, _, notifications = open_board()
    local baseline = fake:call_count()
    put_cursor(board, board.detail.rendered.fields.origin)
    board:handle("edit")

    eq(baseline, fake:call_count())
    truthy(#notifications > 0)
    truthy(notifications[1]:find("origin", 1, true) or notifications[1] ~= "")
  end)
end)

describe("doc editing", function()
  it("does nothing when the input is cancelled", function()
    local board, fake = open_board({
      edit_input = function(_, _, cb)
        cb(nil)
      end,
    })
    local baseline = fake:call_count()
    put_cursor(board, board.detail.rendered.fields.doc)
    board:handle("edit")

    eq(baseline, fake:call_count())
    eq(nil, board.editing)
  end)

  it("writes a new doc path through loop-cli", function()
    local board, fake, st = open_board({
      edit_input = function(_, _, cb)
        cb("docs/new.md")
      end,
    })
    fake:respond("doc", {
      stdout = json({ task = { id = "#11", title = "看板编辑", status = "pending", doc = "docs/new.md" } }),
    })
    put_cursor(board, board.detail.rendered.fields.doc)
    board:handle("edit")

    wait_for(function()
      return find_call(fake, "doc") ~= nil
    end)
    local call = find_call(fake, "doc")
    eq("#11", call.argv[6])
    truthy(vim.tbl_contains(call.argv, "--path"))
    truthy(vim.tbl_contains(call.argv, "docs/new.md"))
    wait_for(function()
      for _, item in ipairs(st.tasks) do
        if item.id == "#11" then
          return item.doc == "docs/new.md"
        end
      end
      return false
    end)
  end)
end)

describe("touch editing", function()
  it("saves a multi-line buffer as --set paths", function()
    local board, fake = open_board()
    fake:respond("touch", { stdout = json({ task = { id = "#11", title = "看板编辑", status = "pending" } }) })
    put_cursor(board, board.detail.rendered.fields.touch)
    board:handle("edit")

    truthy(board.editing)
    local buf = board.editing.buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " lua/a.lua ", "", "tests/a_spec.lua", "lua/a.lua" })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)

    wait_for(function()
      return find_call(fake, "touch") ~= nil
    end)
    local call = find_call(fake, "touch")
    truthy(vim.tbl_contains(call.argv, "--set"))
    truthy(vim.fn.index(call.argv, "lua/a.lua") > 0)
    truthy(vim.fn.index(call.argv, "tests/a_spec.lua") > 0)
  end)

  it("keeps the buffer dirty on an invalid path", function()
    local board, fake, _, notifications = open_board()
    local baseline = fake:call_count()
    put_cursor(board, board.detail.rendered.fields.touch)
    board:handle("edit")

    local buf = board.editing.buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/abs.lua" })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)

    eq(baseline, fake:call_count())
    truthy(board.editing ~= nil)
    eq(true, vim.bo[buf].modified)
    truthy(table.concat(notifications, "\n"):find("绝对", 1, true) ~= nil)
    -- Leave no dirty scratch buffer behind for the headless runner.
    vim.bo[buf].modified = false
  end)
end)
