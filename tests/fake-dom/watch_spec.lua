-- Fake-DOM tests for board auto refresh (file watcher + FocusGained).
local tmp = require("helpers.tmp")
local state_mod = require("loop-kit.state")
local source_mod = require("loop-kit.source")
local board_mod = require("loop-kit.ui.board")

vim.o.hidden = true

local TASKS = {
  { id = "#1", title = "Alpha", status = "pending", tag = "feat", desc = "old description" },
}

local function contains(buf, needle)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function loop_root(files)
  local dir = tmp.dir("watch-loop")
  for name, content in pairs(files or {}) do
    tmp.write(tmp.join(dir, name), content)
  end
  return dir
end

local function open_board(overrides)
  overrides = vim.deepcopy(overrides or {})
  local tasks = overrides.tasks or vim.deepcopy(TASKS)
  local kind = overrides.kind or "local"
  overrides.tasks = nil
  overrides.kind = nil

  local root = tmp.dir("watch-board")
  local calls = { list = 0, sync = 0 }
  local run = function(argv, _, cb)
    if argv[1] == "list" then
      calls.list = calls.list + 1
      if argv[2] == nil then
        calls.sync = calls.sync + 1
      end
      cb({
        ok = true,
        data = {
          source = { kind = kind, provider = kind },
          tasks = vim.deepcopy(tasks),
          analysis = { outstandingCount = #tasks },
        },
      })
      return
    end
    cb({ ok = false, code = "unsupported", message = "unexpected " .. tostring(argv[1]) })
  end

  local updates = 0
  local original_updated = overrides.on_updated
  overrides.on_updated = function(...)
    updates = updates + 1
    if original_updated then
      original_updated(...)
    end
  end

  local opts = vim.tbl_extend("force", {
    root = root,
    source = source_mod.new({ run = run, root = root }),
    state = state_mod.new():get(root),
    auto_sync = false,
    notify = function() end,
  }, overrides)

  local board = board_mod.open(opts)
  vim.wait(2000, function()
    return board.loaded or board.load_error ~= nil
  end, 10)
  board:select("#1")
  board:draw()

  return board, {
    root = root,
    tasks = tasks,
    calls = calls,
    updates = function()
      return updates
    end,
  }
end

describe("board auto refresh on file changes", function()
  it("reloads the list and detail from the cache", function()
    local board, ctx = open_board()
    eq("pending", board.state.tasks[1].status)
    truthy(contains(board.detail_buf, "old description"))

    ctx.tasks[1].status = "doing"
    ctx.tasks[1].desc = "fresh description"
    board:_watch_changed()

    eq("doing", board.state.tasks[1].status)
    eq("#1", board.state:selected_id(), "selection survives the refresh")
    truthy(contains(board.detail_buf, "fresh description"))
  end)

  it("does not redraw or emit updates when the data is unchanged", function()
    local board, ctx = open_board()
    local before_updates = ctx.updates()
    local before_calls = ctx.calls.list

    board:_watch_changed()

    eq(before_calls + 1, ctx.calls.list, "the watcher still reads the cache")
    eq(before_updates, ctx.updates(), "unchanged data must not emit on_updated")
  end)

  it("skips the refresh while an edit is open", function()
    local board, ctx = open_board()
    board.editing = { buf = 1 }
    local before = ctx.calls.list

    board:_watch_changed()

    eq(before, ctx.calls.list)
    board.editing = nil
  end)

  it("skips the refresh while a sync is in flight", function()
    local board, ctx = open_board()
    board.syncing = true
    local before = ctx.calls.list

    board:_watch_changed()

    eq(before, ctx.calls.list)
    board.syncing = false
  end)

  it("only starts a watcher when watch is enabled and the directory exists", function()
    local dir = loop_root({ ["LOOP.json"] = "{}" })
    local board = open_board({ watch = true, watch_interval = 200, loop_root = dir })
    truthy(board._watch, "watch=true must create a watcher")
    board:close()
    eq(nil, board._watch, "close() must stop the watcher")

    local off = open_board({ watch = false, loop_root = dir })
    eq(nil, off._watch)
    off:close()

    local missing = open_board({ watch = true, loop_root = tmp.join(tmp.dir("watch-missing"), "nope") })
    eq(nil, missing._watch, "a missing loop root must not start a timer")
    missing:close()
  end)

  it("picks up real file changes on the timer", function()
    local dir = loop_root({ ["LOOP.json"] = "v1" })
    local board, ctx = open_board({ watch = true, watch_interval = 200, loop_root = dir })
    local watcher = board._watch
    truthy(watcher, "watcher must be running")
    truthy(vim.wait(2000, function()
      return watcher._baseline ~= nil
    end, 10), "the first tick must establish a baseline")
    local before = ctx.calls.list

    ctx.tasks[1].status = "done"
    ctx.tasks[1].desc = "timer refresh"
    tmp.write(tmp.join(dir, "LOOP.json"), "v2-with-a-different-size")

    local ok = vim.wait(3000, function()
      return ctx.calls.list > before
    end, 20)
    truthy(ok, "the timer did not request a refresh")
    eq("done", board.state.tasks[1].status)
    board:close()
  end)
end)

describe("board sync on focus", function()
  it("refreshes once per throttle window when sync_on_focus is enabled", function()
    local board, ctx = open_board({ sync_on_focus = true })
    board._focus_at = nil
    local before = ctx.calls.list

    board:_on_focus()
    eq(before + 1, ctx.calls.list)

    board:_on_focus()
    eq(before + 1, ctx.calls.list, "a second focus within 2s is throttled")
    board:close()
  end)

  it("does nothing when sync_on_focus is disabled", function()
    local board, ctx = open_board({ sync_on_focus = false })
    board._focus_at = nil
    local before = ctx.calls.list

    board:_on_focus()

    eq(before, ctx.calls.list)
    board:close()
  end)

  it("runs a background sync after rendering the cache for remote sources", function()
    local board, ctx = open_board({ sync_on_focus = true, kind = "gitea" })
    board._focus_at = nil
    local before = ctx.calls.sync

    board:_on_focus()

    local ok = vim.wait(2000, function()
      return ctx.calls.sync > before
    end, 10)
    truthy(ok, "remote focus must schedule a full sync")
    board:close()
  end)
end)
