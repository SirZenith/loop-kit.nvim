-- Integration tests for plugin registration, :LoopKit dispatch and the public
-- Lua API. Everything runs against the programmable fake CLI or an injected
-- source; no network and no real loop-cli is involved.
local loopkit = require("loop-kit")
local fake_cli = require("helpers.fake_cli")
local tmp = require("helpers.tmp")
local paths = require("helpers.paths")
local source_mod = require("loop-kit.source")
local util = require("loop-kit.util")

local TASKS = {
  { id = "#1", title = "Alpha pending", status = "pending", tag = "feat", desc = "alpha" },
  { id = "#2", title = "Beta doing", status = "doing", tag = "fix", desc = "beta" },
  { id = "#3", title = "Gamma blocked", status = "blocked", tag = "feat", desc = "gamma" },
  { id = "#4", title = "Delta done", status = "done", tag = "chore", desc = "delta" },
}

local function json(tbl)
  return vim.json.encode(tbl)
end

local function has_arg(argv, value)
  for _, arg in ipairs(argv or {}) do
    if arg == value then
      return true
    end
  end
  return false
end

local function project(provider)
  local root = tmp.dir("public")
  tmp.write(
    root .. "/loop.config.json",
    json({
      version = 1,
      provider = provider or "local",
      loopRoot = "loop",
      filePath = "LOOP.json",
    }) .. "\n"
  )
  return root
end

local function respond_list(f, tasks, kind)
  f:respond("list", {
    stdout = json({
      source = { kind = kind or "local", location = f.root .. "/loop/LOOP.json" },
      tasks = tasks or TASKS,
      analysis = { outstandingCount = 3 },
    }),
  })
end

local function wait_for(predicate)
  local ok = vim.wait(5000, predicate, 10)
  truthy(ok, "timed out waiting for condition")
  return predicate()
end

local function capture(pattern)
  local group = vim.api.nvim_create_augroup("LoopKitSpec" .. tostring(vim.uv.hrtime()), { clear = true })
  local events = {}
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = pattern,
    callback = function(ev)
      events[#events + 1] = ev.data
    end,
  })
  return events, function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

local function close_all()
  pcall(loopkit.close, { all = true })
  loopkit.reset()
end

describe("plugin registration and defaults", function()
  it("registers :LoopKit from plugin/ and exposes the documented API", function()
    dofile(paths.root .. "/plugin/loop-kit.lua")

    local commands = vim.api.nvim_get_commands({})
    truthy(commands.LoopKit, "expected :LoopKit to be registered")

    for _, name in ipairs({
      "setup",
      "open",
      "close",
      "refresh",
      "sync",
      "get_snapshot",
      "get_task",
      "edit",
      "add",
      "remove",
      "actions",
      "command",
      "paths",
      "health",
    }) do
      eq("function", type(loopkit[name]), "expected loop-kit." .. name)
    end
  end)

  it("setup applies the documented defaults", function()
    local cfg = loopkit.defaults()
    eq(nil, cfg.cli_path)
    eq(nil, cfg.project_root)
    eq(true, cfg.auto_sync)
    eq(38, cfg.list_width)
    eq("open", cfg.default_filter)
    eq("id_desc", cfg.sort)
    eq(true, cfg.show_winbar)
    eq(true, cfg.show_hint)
    eq("compact", cfg.display_style)
    eq("○", cfg.icons.pending)
    eq("◐", cfg.icons.doing)
    eq("●", cfg.icons.done)
    eq("✕", cfg.icons.blocked)
    eq(true, cfg.confirm.done)
    eq(true, cfg.confirm.force_done)
    eq(true, cfg.confirm.block)
    eq(true, cfg.confirm.remove)
    eq({}, cfg.keys)
  end)
end)

describe("public API against the fake CLI", function()
  it("opens the board, renders the cache first and emits LoopKitUpdated", function()
    local f = fake_cli.new()
    respond_list(f)
    local root = project()
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false })

    local updated, stop_capture = capture("LoopKitUpdated")
    local board = loopkit.open({ root = root, env = f:env() })
    truthy(board, "expected a board")
    wait_for(function()
      return board.loaded
    end)

    local first = f:call(1)
    truthy(first, "expected one loop-cli call")
    truthy(has_arg(first.argv, "list"), "expected list")
    truthy(has_arg(first.argv, "--no-sync"), "the first read must use the cache only")

    local snapshot = loopkit.get_snapshot(root)
    truthy(snapshot, "expected a snapshot")
    eq(util.normalize_root(root), snapshot.root)
    eq(4, #snapshot.tasks)
    eq("Alpha pending", loopkit.get_task("#1", root).title)

    truthy(#updated >= 1, "expected LoopKitUpdated")
    local event = updated[#updated]
    eq(util.normalize_root(root), event.root)
    eq(4, #event.snapshot.tasks)

    -- The public snapshot is a copy, never the authoritative table.
    snapshot.tasks[1].title = "mutated"
    eq("Alpha pending", loopkit.get_task("#1", root).title)

    stop_capture()
    close_all()
  end)

  it("honours setup keys=false and forwards setup keys", function()
    local f = fake_cli.new()
    respond_list(f)
    local root = project()
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false, keys = { q = false, s = "sync" } })

    local board = loopkit.open({ root = root, env = f:env() })
    wait_for(function()
      return board.loaded
    end)

    local bound = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(board.list_buf, "n")) do
      bound[map.lhs] = true
    end
    falsy(bound.q, "q must be disabled by setup.keys.q = false")
    truthy(bound.s, "s must stay bound")

    close_all()
  end)

  it("applies setup.sort to the rendered order", function()
    local f = fake_cli.new()
    respond_list(f, {
      { id = "#1", title = "Zulu task", status = "pending", tag = "feat", desc = "z" },
      { id = "#2", title = "Alpha task", status = "pending", tag = "feat", desc = "a" },
    })
    local root = project()
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false, sort = "title" })

    local board = loopkit.open({ root = root, env = f:env() })
    wait_for(function()
      return board.loaded
    end)

    local lines = vim.api.nvim_buf_get_lines(board.list_buf, 0, -1, false)
    local function index_of(needle)
      for index, line in ipairs(lines) do
        if line:find(needle, 1, true) then
          return index
        end
      end
    end
    local alpha, zulu = index_of("Alpha task"), index_of("Zulu task")
    truthy(alpha and zulu, "both tasks must be rendered")
    truthy(alpha < zulu, "sort=title must order Alpha before Zulu")

    close_all()
  end)

  it("forwards setup.display_style to the list", function()
    local root = project()
    local run = function(_argv, _opts, cb)
      vim.schedule(function()
        cb({ ok = true, data = { source = { kind = "local" }, tasks = TASKS } })
      end)
      return nil
    end
    local source = source_mod.new({ run = run, root = util.normalize_root(root) })
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false, display_style = "card" })
    eq("card", require("loop-kit.ui.board").config.display_style)

    local board = loopkit.open({ root = root, source = source })
    wait_for(function()
      return board.loaded
    end)

    eq("card", board.list.style)
    local lines = vim.api.nvim_buf_get_lines(board.list_buf, 0, -1, false)
    local has_card = false
    for _, line in ipairs(lines) do
      if line:find("╭─ #", 1, true) then
        has_card = true
        break
      end
    end
    truthy(has_card, "setup.display_style=card must render card borders")

    close_all()
  end)

  it("falls back to compact rows for an invalid display_style", function()
    local root = project()
    local run = function(_argv, _opts, cb)
      vim.schedule(function()
        cb({ ok = true, data = { source = { kind = "local" }, tasks = TASKS } })
      end)
      return nil
    end
    local source = source_mod.new({ run = run, root = util.normalize_root(root) })
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false, display_style = "gallery" })
    eq("compact", loopkit.defaults().display_style)

    local board = loopkit.open({ root = root, source = source, display_style = "gallery" })
    wait_for(function()
      return board.loaded
    end)

    local lines = vim.api.nvim_buf_get_lines(board.list_buf, 0, -1, false)
    local compact = false
    for _, line in ipairs(lines) do
      if line:find("┌ #", 1, true) then
        compact = true
        break
      end
    end
    truthy(compact, "an invalid display_style must fall back to compact rows")

    close_all()
  end)

  it("dispatches every :LoopKit subcommand to the Lua API", function()
    local calls = {}
    local originals = {}
    local function stub(name, ret)
      originals[name] = loopkit[name]
      loopkit[name] = function(...)
        calls[#calls + 1] = { name = name, args = { ... } }
        return ret
      end
    end

    stub("open", "board")
    stub("show", "board")
    stub("edit", "board")
    stub("add", "board")
    stub("sync", "board")
    stub("refresh", "board")
    stub("remove", "board")
    stub("decide", "board")
    stub("paths", "paths")
    stub("health", "health")
    stub("close", "closed")

    loopkit.command("", {})
    loopkit.command("open", { "open" })
    loopkit.command("open /tmp/other", { "open", "/tmp/other" })
    loopkit.command("show #12", { "show", "#12" })
    loopkit.command("edit #12", { "edit", "#12" })
    loopkit.command("add", { "add" })
    loopkit.command("sync", { "sync" })
    loopkit.command("refresh", { "refresh" })
    loopkit.command("remove #12", { "remove", "#12" })
    loopkit.command("decide", { "decide" })
    loopkit.command("paths", { "paths" })
    loopkit.command("health", { "health" })
    loopkit.command("close", { "close" })

    local names = {}
    for _, call in ipairs(calls) do
      names[#names + 1] = call.name
    end
    eq({
      "open",
      "open",
      "open",
      "show",
      "edit",
      "add",
      "sync",
      "refresh",
      "remove",
      "decide",
      "paths",
      "health",
      "close",
    }, names)
    eq("/tmp/other", calls[3].args[1].path)
    eq("#12", calls[4].args[1])
    eq("#12", calls[5].args[1])
    eq("#12", calls[9].args[1])
    eq("function", type(calls[11].args[2]), ":LoopKit paths must report its result")

    for name, fn in pairs(originals) do
      loopkit[name] = fn
    end
  end)

  it("runs paths and health through the public API", function()
    local root = project()
    local f = fake_cli.new()
    f:respond("paths", {
      stdout = json({ config = root .. "/loop.config.json", loopRoot = root .. "/loop" }),
    })
    f:respond("--version", { stdout = "loop-cli 0.1.0\n" })
    f:respond("list", { stdout = json({ source = { kind = "local" }, tasks = {} }) })
    f:respond("remove", { stdout = "Usage: loop-cli remove <id>\n" })

    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false })

    local paths_done, paths_res = false, nil
    loopkit.paths({ root = root, env = f:env() }, function(res)
      paths_res = res
      paths_done = true
    end)
    wait_for(function()
      return paths_done
    end)
    truthy(paths_res.ok, vim.inspect(paths_res))
    eq(root .. "/loop", paths_res.paths.loopRoot)

    local health = loopkit.health({ root = root, env = f:env(), cli_path = fake_cli.fixture })
    truthy(health, "expected health result")
    truthy(#health.checks >= 5)
    falsy(health.ok == false, "healthy project must not report errors: " .. vim.inspect(health.checks))

    close_all()
  end)
end)

describe("startup sync sequencing", function()
  it("reads the cache first, shows pending sync instead of an empty list and then syncs", function()
    local root = project("gitea")
    local calls = {}
    local run = function(argv, _opts, cb)
      calls[#calls + 1] = vim.deepcopy(argv)
      if has_arg(argv, "--no-sync") then
        vim.schedule(function()
          cb({
            ok = false,
            code = "no_cache",
            kind = "source",
            recoverable = true,
            message = "远端缓存尚未同步",
          })
        end)
      else
        vim.defer_fn(function()
          cb({
            ok = true,
            data = {
              source = { kind = "gitea" },
              tasks = { TASKS[1], TASKS[2] },
              analysis = { outstandingCount = 2 },
            },
          })
        end, 40)
      end
      return nil
    end

    local source = source_mod.new({ run = run, root = util.normalize_root(root) })
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = true })

    local board = loopkit.open({ root = root, source = source })
    vim.wait(30, function()
      return #calls >= 1
    end, 5)
    vim.wait(20)

    local text = table.concat(vim.api.nvim_buf_get_lines(board.list_buf, 0, -1, false), "\n")
    falsy(text:find("（无任务）", 1, true), "no cache must not look like an empty list")
    truthy(board.syncing or not board.loaded, "sync must still be in flight")

    wait_for(function()
      return board.loaded
    end)

    eq(2, #calls)
    truthy(has_arg(calls[1], "list"))
    truthy(has_arg(calls[1], "--no-sync"))
    truthy(has_arg(calls[2], "list"))
    falsy(has_arg(calls[2], "--no-sync"), "the background sync must be a full list")
    eq(2, #loopkit.get_snapshot(root).tasks)

    close_all()
  end)

  it("keeps the previous snapshot when a later sync fails", function()
    local root = project("gitea")
    local calls = {}
    local fail = false
    local run = function(argv, _opts, cb)
      calls[#calls + 1] = vim.deepcopy(argv)
      if has_arg(argv, "--no-sync") then
        vim.schedule(function()
          cb({
            ok = true,
            data = { source = { kind = "gitea" }, tasks = TASKS, analysis = { outstandingCount = 4 } },
          })
        end)
      else
        vim.schedule(function()
          if fail then
            cb({ ok = false, code = "exit", kind = "remote", message = "网络断开" })
          else
            cb({
              ok = true,
              data = { source = { kind = "gitea" }, tasks = TASKS, analysis = { outstandingCount = 4 } },
            })
          end
        end)
      end
      return nil
    end

    local source = source_mod.new({ run = run, root = util.normalize_root(root) })
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = true })

    local board = loopkit.open({ root = root, source = source })
    wait_for(function()
      return board.loaded
    end)

    fail = true
    loopkit.sync({ root = root })
    vim.wait(5000, function()
      return not board.syncing
    end, 10)

    truthy(board.loaded, "a failed sync must keep the rendered snapshot")
    eq(4, #loopkit.get_snapshot(root).tasks)
    truthy(board.load_error, "the failure must be surfaced")

    close_all()
  end)
end)

describe("public action controller", function()
  it("emits LoopKitAction when a mutation succeeds", function()
    local f = fake_cli.new()
    respond_list(f)
    f:respond("claim", {
      stdout = json({
        id = "#1",
        title = "Alpha pending",
        status = "doing",
        tag = "feat",
        desc = "alpha",
      }),
    })
    local root = project()
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false })

    local board = loopkit.open({ root = root, env = f:env() })
    wait_for(function()
      return board.loaded
    end)

    local events, stop_capture = capture("LoopKitAction")
    local actions = loopkit.actions(root)
    truthy(actions, "expected actions")

    local finished, result = false, nil
    actions:claim("#1", function(res)
      result = res
      finished = true
    end)
    wait_for(function()
      return finished
    end)

    truthy(result.ok, vim.inspect(result))
    truthy(#events >= 1, "expected LoopKitAction")
    local event = events[#events]
    eq(util.normalize_root(root), event.root)
    eq("#1", event.id)
    eq("claim", event.action)
    eq(true, event.ok)
    eq(nil, event.error)

    stop_capture()
    close_all()
  end)

  it("emits LoopKitAction with ok=false and the error on failure", function()
    local f = fake_cli.new()
    respond_list(f)
    f:respond("claim", { exit = 4, stderr = "依赖未完成：#2\n" })
    local root = project()
    loopkit.reset()
    loopkit.setup({ cli_path = fake_cli.fixture, auto_sync = false })

    local board = loopkit.open({ root = root, env = f:env() })
    wait_for(function()
      return board.loaded
    end)

    local events, stop_capture = capture("LoopKitAction")
    local actions = loopkit.actions(root)
    local finished, result = false, nil
    actions:claim("#1", function(res)
      result = res
      finished = true
    end)
    wait_for(function()
      return finished
    end)

    falsy(result.ok)
    truthy(#events >= 1)
    local event = events[#events]
    eq("#1", event.id)
    eq("claim", event.action)
    eq(false, event.ok)
    match(event.error or "", "依赖未完成")

    stop_capture()
    close_all()
  end)
end)
