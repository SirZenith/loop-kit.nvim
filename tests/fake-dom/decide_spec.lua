local fake_cli = require("helpers.fake_cli")
local source_mod = require("loop-kit.source")
local state_mod = require("loop-kit.state")
local decide_mod = require("loop-kit.decide")

local function json(tbl)
  return vim.json.encode(tbl)
end

local function await(run)
  local done, result = false, nil
  run(function(res)
    result = res
    done = true
  end)
  vim.wait(5000, function()
    return done
  end, 10)
  truthy(done, "timed out waiting for decide")
  return result
end

local function task(id, status, overrides)
  return vim.tbl_extend("force", {
    id = id,
    title = "task " .. id,
    status = status,
    tag = "feat",
    desc = "",
  }, overrides or {})
end

local function full_argv(f, command, args)
  local argv = { fake_cli.fixture, "--project-root", f.root, "--json", command }
  for _, arg in ipairs(args or {}) do
    argv[#argv + 1] = arg
  end
  return argv
end

local function harness()
  local f = fake_cli.new()
  local source = source_mod.new({ client = f:client(), root = f.root })
  local st = state_mod.new():get(f.root)
  local decide = decide_mod.new({ source = source, state = st })
  return f, source, st, decide
end

local function seed(source, st, tasks)
  source.snapshot.source = { kind = "remote" }
  source.snapshot.tasks = tasks
  st:set_tasks(tasks)
end

describe("decide navigation", function()
  it("asks decide without syncing and selects a next id", function()
    local f, source, st, decide = harness()
    seed(source, st, { task("#4", "pending"), task("#6", "doing") })
    st:select("#4")
    f:respond("decide", {
      stdout = json({ action = "next", id = "#6", reason = "doing 优先", ids = { "#6" } }),
    })

    local res = await(function(cb)
      decide:run(cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq("next", res.action)
    eq("#6", res.id)
    eq("#6", st:selected_id())
    truthy(res.navigated, vim.inspect(res))
    eq(full_argv(f, "decide", { "--no-sync" }), f:call(1).argv)
    -- decide must never claim or refill on its own
    eq(1, f:call_count())
  end)

  it("does not navigate when next has no id", function()
    local f, source, st, decide = harness()
    seed(source, st, { task("#4", "pending") })
    st:select("#4")
    f:respond("decide", {
      stdout = json({ action = "next", id = vim.NIL, reason = "候选为空", ids = {} }),
    })

    local res = await(function(cb)
      decide:run(cb)
    end)

    truthy(res.ok, vim.inspect(res))
    falsy(res.navigated)
    eq("#4", st:selected_id())
    eq(1, f:call_count())
  end)

  it("only reports a refill recommendation", function()
    local f, source, st, decide = harness()
    seed(source, st, { task("#4", "pending") })
    st:select("#4")
    f:respond("decide", {
      stdout = json({ action = "refill", id = vim.NIL, reason = "循环已清空", ids = {} }),
    })

    local res = await(function(cb)
      decide:run(cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq("refill", res.action)
    falsy(res.navigated)
    eq("#4", st:selected_id())
    eq(1, f:call_count())
    truthy(res.message:find("循环已清空", 1, true), res.message)
  end)

  it("only reports stop and wait reasons", function()
    local f, source, st, decide = harness()
    seed(source, st, { task("#4", "doing") })
    st:select("#4")
    f:respond("decide", {
      stdout = json({ action = "stop", id = vim.NIL, reason = "有 doing 条目", ids = { "#4" } }),
    })

    local stopped = await(function(cb)
      decide:run(cb)
    end)
    truthy(stopped.ok, vim.inspect(stopped))
    eq("stop", stopped.action)
    falsy(stopped.navigated)
    truthy(stopped.message:find("#4", 1, true), stopped.message)

    local f2, source2, st2, decide2 = harness()
    seed(source2, st2, { task("#4", "doing") })
    f2:respond("decide", {
      stdout = json({ action = "wait", id = vim.NIL, reason = "被在飞条目挡住", ids = {} }),
    })
    local waited = await(function(cb)
      decide2:run(cb)
    end)
    truthy(waited.ok, vim.inspect(waited))
    eq("wait", waited.action)
    truthy(waited.message:find("在飞条目", 1, true), waited.message)
    eq(1, f2:call_count())
  end)
end)

describe("decide failures", function()
  it("surfaces a cache/source failure without touching the selection", function()
    local f, source, st, decide = harness()
    seed(source, st, { task("#4", "pending") })
    st:select("#4")
    f:respond("decide", { exit = 2, stderr = "LOOP.remote.json 缺失" })

    local res = await(function(cb)
      decide:run(cb)
    end)

    falsy(res.ok)
    eq("exit", res.code)
    eq("source", res.kind)
    truthy(res.message:find("LOOP.remote.json", 1, true), res.message)
    eq("#4", st:selected_id())
    eq(1, f:call_count())
  end)
end)

describe("decide single-task explanation", function()
  it("uses list --target and adds dependency statuses", function()
    local f, source, st, decide = harness()
    local target = task("#6", "pending", { deps = { "#2", "#4" } })
    local dep_doing = task("#2", "doing")
    local dep_done = task("#4", "done")
    seed(source, st, { target, dep_doing, dep_done })
    f:respond("list", {
      stdout = json({
        source = { kind = "remote" },
        tasks = { target, dep_doing, dep_done },
        analysis = {
          target = "#6",
          outstandingCount = 2,
          eligible = {},
          blocked = { { task = target, unmet = { "#2" } } },
          stuck = {},
        },
      }),
    })

    local res = await(function(cb)
      decide:explain("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq("#6", res.id)
    truthy(res.blocked, vim.inspect(res))
    eq({ "#2" }, res.unmet)
    eq("doing", res.deps[1].status)
    eq(2, res.outstanding)
    eq(full_argv(f, "list", { "--no-sync", "--target", "#6" }), f:call(1).argv)
    eq(1, f:call_count())
  end)

  it("returns the underlying list failure", function()
    local f, source, st, decide = harness()
    seed(source, st, { task("#6", "pending") })
    f:respond("list", { exit = 3, stderr = "LOOP.json 损坏" })

    local res = await(function(cb)
      decide:explain("#6", cb)
    end)

    falsy(res.ok)
    eq("data", res.kind)
    eq(1, f:call_count())
  end)
end)
