-- Render tests for the board tab, window lifecycle and keymap wiring.
local board = require("loop-kit.ui.board")
local help = require("loop-kit.ui.help")
local state_mod = require("loop-kit.state")
local source_mod = require("loop-kit.source")
local fake_cli = require("helpers.fake_cli")

local TASKS = {
  { id = "#1", title = "Alpha pending", status = "pending", tag = "feat", desc = "alpha" },
  { id = "#2", title = "Beta doing", status = "doing", tag = "fix", desc = "beta" },
  { id = "#3", title = "Gamma blocked", status = "blocked", tag = "feat", desc = "gamma" },
  { id = "#4", title = "Delta done", status = "done", tag = "chore", desc = "delta" },
}

local function has_arg(argv, value)
  for _, arg in ipairs(argv or {}) do
    if arg == value then
      return true
    end
  end
  return false
end

local function key_lhs(buf)
  local out = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    out[map.lhs] = true
  end
  return out
end

local function open_board(overrides)
  overrides = overrides or {}
  local fake = fake_cli.new()
  fake:respond("list", {
    stdout = vim.json.encode({
      source = { kind = "gitea", provider = "gitea" },
      tasks = TASKS,
    }),
  })

  local client = fake:client()
  local state = overrides.state or state_mod.new():get(fake.root)
  local source = overrides.source or source_mod.new({ client = client, root = fake.root })
  local notifications = {}
  local opts = {
    root = fake.root,
    client = client,
    source = source,
    state = state,
    auto_sync = false,
    auto_refresh = overrides.auto_refresh ~= false,
    keys = overrides.keys,
    show_winbar = overrides.show_winbar,
    show_hint = overrides.show_hint,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
  }

  local instance, created = board.open(opts)
  if opts.auto_refresh then
    vim.wait(5000, function()
      return instance.loaded or instance.load_error ~= nil
    end, 10)
  end
  return instance, fake, state, notifications, opts, created
end

local function close_board(instance)
  if instance and instance:is_open() then
    instance:close()
  end
end

describe("ui.board: tab and window lifecycle", function()
  it("opens one tab with a list and a readonly markdown detail window", function()
    local tabs_before = #vim.api.nvim_list_tabpages()
    local b = open_board()

    eq(tabs_before + 1, #vim.api.nvim_list_tabpages(), "exactly one new tab")
    eq(2, #vim.api.nvim_tabpage_list_wins(b.tabpage), "two windows")
    eq(b.list_buf, vim.api.nvim_win_get_buf(b.list_win))
    eq(b.detail_buf, vim.api.nvim_win_get_buf(b.detail_win))

    eq("nofile", vim.bo[b.list_buf].buftype)
    eq(true, vim.wo[b.list_win].winfixwidth)
    eq(true, vim.wo[b.list_win].cursorline)
    eq(38, vim.api.nvim_win_get_width(b.list_win))

    eq("markdown", vim.bo[b.detail_buf].filetype)
    eq("Comment", vim.api.nvim_get_hl(0, { name = "LoopKitMuted", link = true }).link)
    eq("Comment", vim.api.nvim_get_hl(0, { name = "LoopKitDetailMuted", link = true }).link)
    eq(false, vim.bo[b.detail_buf].swapfile)
    eq(false, vim.bo[b.detail_buf].modifiable)

    local hint = vim.api.nvim_buf_get_lines(b.list_buf, 0, 1, false)[1]
    match(hint, "j/k", "top help line keeps the key hint")
    match(hint, "帮助")

    close_board(b)
  end)

  it("focuses the existing board instead of opening a second tab", function()
    local b, _, _, _, opts = open_board()
    local tabs = #vim.api.nvim_list_tabpages()

    local again, created = board.open(opts)
    truthy(again == b, "same board instance")
    eq(false, created)
    eq(tabs, #vim.api.nvim_list_tabpages(), "no duplicate tab")

    close_board(b)
  end)

  it("shares one cleanup path for q, :tabclose and WinClosed", function()
    local tabs_before = #vim.api.nvim_list_tabpages()

    local b = open_board()
    local augroup = b.augroup
    b:handle("q")
    vim.wait(5000, function()
      return not b:is_open()
    end, 10)
    falsy(vim.api.nvim_tabpage_is_valid(b.tabpage), "tab closed by q")
    eq(tabs_before, #vim.api.nvim_list_tabpages())
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = augroup })
    falsy(ok and #autocmds > 0, "autocmds released")

    b = open_board()
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(b.tabpage))
    vim.wait(5000, function()
      return not b:is_open()
    end, 10)
    falsy(vim.api.nvim_tabpage_is_valid(b.tabpage), "tab closed by tabclose")

    b = open_board()
    vim.api.nvim_win_close(b.list_win, true)
    vim.wait(5000, function()
      return not b:is_open()
    end, 10)
    falsy(vim.api.nvim_tabpage_is_valid(b.tabpage), "WinClosed runs the same cleanup")
    eq(tabs_before, #vim.api.nvim_list_tabpages())
  end)

  it("drops a stale refresh callback after the board closed", function()
    local fake = fake_cli.new()
    local pending = {}
    local stub = {
      snapshot = { source = { kind = "local" } },
      list = function(_, _, cb)
        pending[#pending + 1] = cb
      end,
      sync = function(_, cb)
        pending[#pending + 1] = cb
      end,
    }

    local b = board.open({
      root = fake.root,
      client = fake:client(),
      source = stub,
      state = state_mod.new():get(fake.root),
      auto_sync = false,
      auto_refresh = true,
      notify = function() end,
    })
    eq(1, #pending, "initial refresh is in flight")
    local tabpage = b.tabpage
    b:close()

    local ok, err = pcall(pending[1], {
      ok = true,
      tasks = { { id = "#99", title = "late", status = "pending" } },
      source = { kind = "local" },
    })
    truthy(ok, err)
    falsy(vim.api.nvim_tabpage_is_valid(tabpage), "closed board stays closed")
    falsy(b:is_open())
  end)

  it("survives resizing without touching a closed window", function()
    local columns, lines = vim.o.columns, vim.o.lines
    local b = open_board()

    local ok, err = pcall(function()
      vim.o.columns = math.max(columns, 120)
      vim.o.lines = math.max(lines, 40)
      vim.cmd("doautocmd <nomodeline> VimResized")
      b:draw()
    end)
    pcall(function()
      vim.o.columns = columns
      vim.o.lines = lines
    end)
    truthy(ok, tostring(err))

    close_board(b)
  end)
end)

describe("ui.board: help, keymaps and filtering", function()
  it("toggles the help float without changing the selection", function()
    local b, _, state = open_board()
    local selected = state:selected_id()
    eq("#3", selected)

    b:handle("help")
    truthy(help.is_open(), "help float is open")
    eq(selected, state:selected_id(), "selection unchanged")
    eq(selected, b.list:selected_task().id)

    b:handle("help")
    falsy(help.is_open(), "help float is closed")
    eq(selected, state:selected_id())

    close_board(b)
  end)

  it("binds every default key locally and honours setup overrides", function()
    local b = open_board()
    local lhs = key_lhs(b.list_buf)
    for _, key in ipairs({ "j", "k", "<CR>", "/", "s", "S", "A", "r", "R", "c", "d", "D", "b", "e", "a", "x", "o", "F", "P", "T", "M", "n", "?", "q" }) do
      truthy(lhs[key], "missing default key " .. key)
    end
    close_board(b)

    local overridden = open_board({ keys = { q = false, ["<F2>"] = "help", j = "move_up" } })
    lhs = key_lhs(overridden.list_buf)
    eq(nil, lhs["q"], "false disables the default key")
    eq(true, lhs["<F2>"], "custom key is bound")
    eq(true, lhs["j"], "action override keeps the key bound")
    close_board(overridden)
  end)

  it("can hide the list winbar and hint line", function()
    local b = open_board({ show_winbar = false, show_hint = false })

    eq("", vim.wo[b.list_win].winbar)
    match(vim.wo[b.detail_win].winbar, "LoopKit", "detail keeps its winbar")
    local first = vim.api.nvim_buf_get_lines(b.list_buf, 0, 1, false)[1]
    match(first, "┌ #3", "hint line is gone, task row is first")

    close_board(b)
  end)

  it("applies setup() key and width overrides to later boards", function()
    local saved = board.config
    board.setup({ keys = { q = false, ["<F3>"] = "help" }, list_width = 30 })

    local b = open_board()
    local lhs = key_lhs(b.list_buf)
    eq(nil, lhs["q"], "setup can disable a default key")
    truthy(lhs["<F3>"], "setup can add a key")
    eq(30, vim.api.nvim_win_get_width(b.list_win), "setup list_width applies")
    close_board(b)

    board.config = saved
  end)

  it("cycles filters, applies keywords and reports status in the winbar", function()
    local b, _, state = open_board()
    local bar = b:winbar()
    match(bar, vim.pesc(vim.fs.basename(b.root)), "project name")
    match(bar, "gitea", "provider")
    match(bar, "open 3", "open count")
    match(bar, "filter open")
    match(bar, "sort id_desc")

    eq("id_desc", state.sort)
    b:handle("cycle_sort")
    eq("id_asc", state.sort)
    b:handle("cycle_sort")
    eq("closed_desc", state.sort)
    b:handle("cycle_sort")
    eq("closed_asc", state.sort)
    b:handle("cycle_sort")
    eq("status", state.sort)
    b:handle("cycle_sort")
    eq("id_desc", state.sort, "sort cycle wraps")
    match(b:winbar(), "sort id_desc")

    b:set_filter("done")
    eq("done", state.filter)
    eq({ "#4" }, (function()
      local ids = {}
      for _, task in ipairs(state:visible_tasks()) do
        ids[#ids + 1] = task.id
      end
      return ids
    end)())
    match(b:winbar(), "filter done")

    b:handle("cycle_filter")
    eq("open", state.filter, "done wraps back to open")
    b:handle("filter_all")
    eq("all", state.filter)

    b:set_query("DELTA")
    eq({ "#4" }, (function()
      local ids = {}
      for _, task in ipairs(state:visible_tasks()) do
        ids[#ids + 1] = task.id
      end
      return ids
    end)())
    match(b:winbar(), "query DELTA")

    b:handle("clear_query")
    eq("", state.query)

    b.load_error = "boom"
    b:draw()
    match(b:winbar(), "error")
    b.load_error = nil

    b.syncing = true
    b:draw()
    match(b:winbar(), "syncing")
    b.syncing = false

    state._running = true
    b:draw()
    match(b:winbar(), "writing")
    state._running = false

    close_board(b)
  end)

  it("uses cache-only refresh for r and a full sync for R", function()
    local b, fake = open_board()
    local first = fake:call_count()
    truthy(has_arg(fake:call(first).argv, "--no-sync"), "initial read is cache-only")

    b:handle("refresh")
    fake:wait_for(function()
      return fake:call_count() > first
    end)
    vim.wait(5000, function()
      return not b.syncing
    end, 10)
    local refresh_call = fake:call(fake:call_count())
    truthy(has_arg(refresh_call.argv, "list"))
    truthy(has_arg(refresh_call.argv, "--no-sync"), "r stays on the cache")

    local before_sync = fake:call_count()
    b:handle("sync")
    fake:wait_for(function()
      return fake:call_count() > before_sync
    end)
    vim.wait(5000, function()
      return not b.syncing
    end, 10)
    local sync_call = fake:call(fake:call_count())
    truthy(has_arg(sync_call.argv, "list"))
    falsy(has_arg(sync_call.argv, "--no-sync"), "R performs a full sync")

    close_board(b)
  end)
end)

describe("ui.board: range navigation", function()
  local function twenty_tasks()
    local tasks = {}
    for index = 1, 20 do
      tasks[#tasks + 1] = {
        id = "#" .. index,
        title = "Task " .. index,
        status = "pending",
        tag = "feat",
        desc = "task " .. index,
      }
    end
    return tasks
  end

  it("binds the range keys and honours a j/k count", function()
    local b, _, state = open_board({ auto_refresh = false })
    state:set_filter("all")
    state:set_tasks(twenty_tasks())
    b.list:draw()

    local lhs = key_lhs(b.list_buf)
    for _, key in ipairs({ "gg", "G", "<C-U>", "<C-B>", "<C-D>", "<C-F>" }) do
      truthy(lhs[key], "missing range key " .. key)
    end

    local ids = b.list:visible_ids()
    eq(20, #ids)

    vim.api.nvim_set_current_win(b.list_win)
    vim.cmd("normal gg")
    eq(ids[1], state:selected_id(), "gg selects the first task")

    vim.cmd("normal G")
    eq(ids[#ids], state:selected_id(), "G selects the last task")

    vim.cmd("normal gg")
    vim.cmd("normal 3j")
    eq(ids[4], state:selected_id(), "3j moves three rows down")

    vim.cmd("normal 2k")
    eq(ids[2], state:selected_id(), "2k moves two rows up")

    close_board(b)
  end)

  it("moves by half and full pages through the default keys", function()
    local b, _, state = open_board({ auto_refresh = false })
    state:set_filter("all")
    state:set_tasks(twenty_tasks())
    b.list:draw()

    local ids = b.list:visible_ids()
    local page = b.list:page_rows()
    eq(
      math.max(1, vim.api.nvim_win_get_height(b.list_win) - 2),
      page,
      "page size follows the list window height"
    )
    local half = math.max(1, math.floor(page / 2))

    b:handle("gg")
    eq(ids[1], state:selected_id())

    b:handle("<C-d>")
    eq(ids[1 + half], state:selected_id(), "<C-d> moves half a page down")

    b:handle("<C-u>")
    eq(ids[1], state:selected_id(), "<C-u> moves half a page up")

    b:handle("<C-f>")
    eq(ids[1 + page], state:selected_id(), "<C-f> moves a full page down")

    b:handle("<C-b>")
    eq(ids[1], state:selected_id(), "<C-b> moves a full page up")

    close_board(b)
  end)
end)
