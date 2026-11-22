local fake_cli = require("helpers.fake_cli")
local source_mod = require("loop-kit.source")
local state_mod = require("loop-kit.state")
local actions_mod = require("loop-kit.actions")

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
  truthy(done, "timed out waiting for the action")
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

local function ids(tasks)
  local out = {}
  for _, item in ipairs(tasks or {}) do
    out[#out + 1] = item.id
  end
  return out
end

local function full_argv(f, command, args)
  local argv = { fake_cli.fixture, "--project-root", f.root, "--json", command }
  for _, arg in ipairs(args or {}) do
    argv[#argv + 1] = arg
  end
  return argv
end

--- Build an action controller on top of a programmable fake CLI.
local function harness(opts)
  opts = opts or {}
  local f = fake_cli.new()
  local source = source_mod.new({ client = f:client(), root = f.root })
  local st = state_mod.new():get(f.root)
  local asked = {}
  local act = actions_mod.new({
    client = f:client(),
    source = source,
    state = st,
    confirm = { done = true, force_done = true, block = true, remove = true },
    ask = function(prompt, cb)
      asked[#asked + 1] = prompt
      cb(opts.answer ~= false)
    end,
    input = function(prompt, cb)
      asked[#asked + 1] = prompt
      cb(opts.reason)
    end,
    sync_after_write = false,
  })
  return f, source, st, act, asked
end

local function seed(source, st, tasks, kind)
  local source_info = { kind = kind or "local" }
  source.snapshot.source = source_info
  source.snapshot.tasks = tasks
  st:set_tasks(tasks)
end

describe("actions exact argv", function()
  it("claims with --json and an explicit project root, then refreshes the list", function()
    local f, source, st, act = harness()
    seed(source, st, { task("#12", "pending"), task("#13", "pending") })
    st:select("#12")
    f:respond("claim", { stdout = json(task("#12", "doing")) })
    f:respond("list", {
      stdout = json({
        source = { kind = "local" },
        tasks = { task("#12", "doing"), task("#13", "pending") },
        analysis = { outstandingCount = 2 },
      }),
    })

    local res = await(function(cb)
      act:claim("#12", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq("claim", res.action)
    eq("#12", res.id)
    eq(full_argv(f, "claim", { "#12" }), f:call(1).argv)
    eq(full_argv(f, "list", { "--no-sync" }), f:call(2).argv)
    eq("doing", st:selected().status)
    eq("#12", st:selected_id())
  end)

  it("sends --force only for force_done", function()
    local f, source, st, act, asked = harness()
    seed(source, st, { task("#12", "pending"), task("#13", "pending") })
    f:respond("done", { stdout = json(task("#12", "done")) })
    f:respond("list", {
      stdout = json({
        source = { kind = "local" },
        tasks = { task("#13", "pending") },
        analysis = {},
      }),
    })

    local res = await(function(cb)
      act:force_done("#12", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq("force_done", res.action)
    eq(full_argv(f, "done", { "#12", "--force" }), f:call(1).argv)
    match(asked[1] or "", "强制完成")
  end)

  it("blocks with a non-empty reason", function()
    local f, source, st, act = harness({ reason = "等待上游" })
    seed(source, st, { task("#12", "pending") })
    f:respond("block", { stdout = json(task("#12", "blocked")) })
    f:respond("list", {
      stdout = json({ source = { kind = "local" }, tasks = { task("#12", "blocked") }, analysis = {} }),
    })

    local res = await(function(cb)
      act:block("#12", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "block", { "#12", "--reason", "等待上游" }), f:call(1).argv)
    eq("blocked", st:selected().status)
  end)

  it("cancels block on an empty reason without spawning a process", function()
    local f, source, st, act = harness({ reason = "   " })
    seed(source, st, { task("#12", "pending") })

    local res = await(function(cb)
      act:block("#12", cb)
    end)

    falsy(res.ok)
    eq("cancelled", res.code)
    eq(0, f:call_count())
  end)
end)

describe("actions remove confirmation", function()
  it("does not spawn remove when the confirmation is declined", function()
    local f, source, st, act = harness({ answer = false })
    seed(source, st, { task("#10", "pending"), task("#12", "pending") })
    st:select("#12")

    local res = await(function(cb)
      act:remove("#12", cb)
    end)

    falsy(res.ok)
    eq("cancelled", res.code)
    eq(0, f:call_count())
    eq("#12", st:selected_id())
    eq({ "#10", "#12" }, ids(st.tasks))
  end)

  it("explains permanent deletion for a local source", function()
    local f, source, st, act, asked = harness()
    seed(source, st, { task("#10", "pending"), task("#12", "pending"), task("#13", "pending") })
    st:select("#12")
    f:respond("remove", { stdout = json({ id = "#12" }) })
    f:respond("list", {
      stdout = json({
        source = { kind = "local" },
        tasks = { task("#10", "pending"), task("#13", "pending") },
        analysis = {},
      }),
    })

    local res = await(function(cb)
      act:remove("#12", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    match(asked[1] or "", "永久删除")
    match(asked[1] or "", "依赖")
    eq(full_argv(f, "remove", { "#12" }), f:call(1).argv)
    -- deletion selects the next row (descending id order)
    eq("#10", st:selected_id())
    eq({ "#10", "#13" }, ids(st.tasks))
  end)

  it("explains moving a remote task out of the loop", function()
    local f, source, st, act, asked = harness()
    seed(source, st, { task("#10", "pending"), task("#12", "pending") }, "gitea")
    st:select("#12")
    f:respond("remove", { stdout = json({ id = "#12" }) })
    f:respond("list", {
      stdout = json({
        source = { kind = "gitea" },
        tasks = { task("#10", "pending") },
        analysis = {},
      }),
    })

    local res = await(function(cb)
      act:remove("#12", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    match(asked[1] or "", "移出循环")
    match(asked[1] or "", "保留")
    falsy((asked[1] or ""):find("永久删除", 1, true), "remote prompt must not promise deletion")
    eq("#10", st:selected_id())
  end)
end)

describe("actions failures preserve state", function()
  it("shows unfinished dependencies on a done gate rejection without forcing", function()
    local f, source, st, act = harness()
    local gate_tasks = {
      task("#12", "pending", { deps = { "#3", "#4" } }),
      task("#3", "done"),
      task("#4", "pending"),
    }
    seed(source, st, gate_tasks)
    st:select("#12")
    f:respond("done", { stderr = "依赖未完成: #4", exit = 4 })

    local res = await(function(cb)
      act:done("#12", cb)
    end)

    falsy(res.ok)
    eq("rejected", res.code)
    eq({ "#4" }, res.deps)
    match(res.message or "", "未完成依赖")
    eq(full_argv(f, "done", { "#12" }), f:call(1).argv)
    eq(1, f:call_count())
    for _, arg in ipairs(f:call(1).argv) do
      neq("--force", arg)
    end
    eq("#12", st:selected_id())
    eq("open", st.filter)
    eq({ "#12", "#3", "#4" }, ids(st.tasks))
  end)

  it("reports a remote conflict without retrying", function()
    local f, source, st, act = harness()
    seed(source, st, { task("#12", "pending") }, "gitea")
    st:select("#12")
    f:respond("done", { stderr = "conflict: updatedAt changed", exit = 4 })

    local res = await(function(cb)
      act:done("#12", cb)
    end)

    falsy(res.ok)
    eq("conflict", res.code)
    truthy(res.conflict)
    eq(1, f:call_count())
    eq("#12", st:selected_id())
  end)

  it("keeps snapshot, selection and filters after exit 5", function()
    local f, source, st, act = harness()
    local tasks = { task("#1", "pending"), task("#2", "doing"), task("#3", "pending") }
    seed(source, st, tasks, "gitea")
    st:set_filter("open")
    st:set_query("task")
    st:select("#2")
    local before = vim.deepcopy(st.tasks)
    f:respond("claim", { stderr = "network unreachable", exit = 5 })

    local res = await(function(cb)
      act:claim("#2", cb)
    end)

    falsy(res.ok)
    eq("remote", res.kind)
    eq(5, res.exit_code)
    eq(before, st.tasks)
    eq("#2", st:selected_id())
    eq("open", st.filter)
    eq("task", st.query)
    eq(1, f:call_count())
  end)
end)

describe("actions write queue", function()
  it("runs one write at a time per project in FIFO order", function()
    local st = state_mod.new():get("/proj/queue")
    local calls, pending = {}, {}
    local act = actions_mod.new({
      state = st,
      exec = function(command, args, _, cb)
        calls[#calls + 1] = { command, args }
        pending[#pending + 1] = cb
      end,
      confirm = { done = true, force_done = true, block = true, remove = true },
      ask = function(_, cb)
        cb(true)
      end,
      input = function(_, cb)
        cb("reason")
      end,
      sync_after_write = false,
    })
    local results = {}

    act:claim("#1", function(res)
      results[#results + 1] = res
    end)
    act:claim("#2", function(res)
      results[#results + 1] = res
    end)

    eq(1, #calls)
    eq("claim", calls[1][1])
    eq({ "#1" }, calls[1][2])
    eq(1, st:pending_count())
    truthy(st:is_writing())

    pending[1]({ ok = false, code = "exit", kind = "remote", exit_code = 5, message = "boom" })
    eq(2, #calls)
    eq({ "#2" }, calls[2][2])
    eq(1, #results)
    truthy(st:is_writing())

    pending[2]({ ok = false, code = "exit", kind = "remote", exit_code = 5, message = "boom" })
    falsy(st:is_writing())
    eq(0, st:pending_count())
    eq(2, #results)
    falsy(results[1].ok)
    falsy(results[2].ok)
  end)
end)
