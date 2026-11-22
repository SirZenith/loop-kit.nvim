local fake_cli = require("helpers.fake_cli")
local source_mod = require("loop-kit.source")
local state_mod = require("loop-kit.state")
local advanced_mod = require("loop-kit.advanced")

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

--- Build an advanced controller on top of a programmable fake CLI.
--- opts.pick selects the option label (or nil to cancel); opts.inputs is a
--- queue for vim.ui.input prompts; opts.answer decides confirmations.
local function harness(opts)
  opts = opts or {}
  local f = fake_cli.new()
  local source = source_mod.new({ client = f:client(), root = f.root })
  local st = state_mod.new():get(f.root)
  local asked = {}
  local inputs = vim.deepcopy(opts.inputs or {})
  local adv = advanced_mod.new({
    source = source,
    state = st,
    select = function(items, select_opts, cb)
      asked[#asked + 1] = select_opts and select_opts.prompt or ""
      local pick = opts.pick
      if type(pick) == "function" then
        pick = pick(items)
      end
      if pick == nil then
        cb(nil)
        return
      end
      for _, item in ipairs(items) do
        if item == pick then
          cb(item)
          return
        end
      end
      error("select option not found: " .. tostring(pick))
    end,
    input = function(prompt, cb)
      asked[#asked + 1] = prompt
      cb(table.remove(inputs, 1))
    end,
    ask = function(prompt, cb)
      asked[#asked + 1] = prompt
      cb(opts.answer ~= false)
    end,
  })
  return f, source, st, adv, asked
end

local function seed(source, st, tasks, kind)
  source.snapshot.source = { kind = kind or "local" }
  source.snapshot.tasks = tasks
  st:set_tasks(tasks)
end

local function list_response(tasks)
  return json({ source = { kind = "local" }, tasks = tasks, analysis = {} })
end

-- `flow --list` and the following write share one command name; this payload
-- satisfies both the flow-list decoder and the task decoder.
local function flow_response(extra)
  return json(vim.tbl_extend("force", {
    builtin = advanced_mod.FLOWS,
    custom = {},
  }, task("#6", "pending", extra)))
end

describe("advanced flow", function()
  it("sets a named flow through the flow subcommand", function()
    local f, source, st, adv = harness({ pick = "quick" })
    seed(source, st, { task("#6", "pending") })
    f:respond("flow", { stdout = flow_response({ flow = "quick" }) })
    f:respond("list", { stdout = list_response({ task("#6", "pending", { flow = "quick" }) }) })

    local res = await(function(cb)
      adv:flow("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq("flow", res.action)
    eq(full_argv(f, "flow", { "--list", "--no-sync" }), f:call(1).argv)
    eq(full_argv(f, "flow", { "#6", "--flow", "quick" }), f:call(2).argv)
    eq(full_argv(f, "list", { "--no-sync" }), f:call(3).argv)
    eq("quick", st.tasks[1].flow)
  end)

  it("sends a validated custom stage list as one --flow value", function()
    local f, source, st, adv = harness({
      pick = advanced_mod.CUSTOM_FLOW,
      inputs = { " research, spec ,impl,verify,commit " },
    })
    seed(source, st, { task("#6", "pending") })
    f:respond("flow", { stdout = flow_response() })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:flow("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(
      full_argv(f, "flow", { "#6", "--flow", "research,spec,impl,verify,commit" }),
      f:call(2).argv
    )
  end)

  it("rejects an invalid custom stage list without spawning a process", function()
    local f, source, st, adv = harness({
      pick = advanced_mod.CUSTOM_FLOW,
      inputs = { "impl,spec,commit" },
    })
    seed(source, st, { task("#6", "pending") })
    f:respond("flow", { stdout = flow_response() })

    local res = await(function(cb)
      adv:flow("#6", cb)
    end)

    falsy(res.ok)
    eq("invalid", res.code)
    eq(1, f:call_count())
    eq(full_argv(f, "flow", { "--list", "--no-sync" }), f:call(1).argv)
    eq("impl,spec,commit", res.input)
    match(res.message, "顺序")
  end)

  it("clears a flow through --clear", function()
    local f, source, st, adv = harness({ pick = advanced_mod.CLEAR_FLOW })
    seed(source, st, { task("#6", "pending", { flow = "quick" }) })
    f:respond("flow", { stdout = flow_response() })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:flow("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "flow", { "--list", "--no-sync" }), f:call(1).argv)
    eq(full_argv(f, "flow", { "#6", "--clear" }), f:call(2).argv)
  end)

  it("cancels without spawning when the picker is dismissed", function()
    local f, source, st, adv = harness({ pick = nil })
    seed(source, st, { task("#6", "pending") })
    f:respond("flow", { stdout = flow_response() })

    local res = await(function(cb)
      adv:flow("#6", cb)
    end)

    falsy(res.ok)
    eq("cancelled", res.code)
    eq(1, f:call_count())
    eq(full_argv(f, "flow", { "--list", "--no-sync" }), f:call(1).argv)
  end)
end)

describe("advanced private", function()
  it("turns the private marker on explicitly", function()
    local f, source, st, adv = harness({ pick = advanced_mod.PRIVATE_ON })
    seed(source, st, { task("#6", "pending") })
    f:respond("private", { stdout = json(task("#6", "pending", { isPrivateDesc = true })) })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:private("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "private", { "#6", "--on" }), f:call(1).argv)
  end)

  it("turns the private marker off explicitly", function()
    local f, source, st, adv = harness({ pick = advanced_mod.PRIVATE_OFF })
    seed(source, st, { task("#6", "pending", { isPrivateDesc = true }) })
    f:respond("private", { stdout = json(task("#6", "pending")) })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:private("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "private", { "#6", "--off" }), f:call(1).argv)
  end)
end)

describe("advanced touch", function()
  it("sets a JSON array and keeps paths containing spaces intact", function()
    local f, source, st, adv = harness({
      pick = advanced_mod.TOUCH_SET,
      inputs = { '["lua/with space/a.lua", "tests/a_spec.lua"]' },
    })
    seed(source, st, { task("#6", "pending") })
    f:respond("touch", {
      stdout = json({ id = "#6", action = "set", touch = { "lua/with space/a.lua" }, total = 1 }),
    })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:touch("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(
      full_argv(f, "touch", { "#6", "--set", "lua/with space/a.lua", "tests/a_spec.lua" }),
      f:call(1).argv
    )
    eq("set", res.payload.action)
  end)

  it("appends to an existing touch set", function()
    local f, source, st, adv = harness({
      pick = advanced_mod.TOUCH_APPEND,
      inputs = { '["tests/unit/advanced_spec.lua"]' },
    })
    seed(source, st, { task("#6", "pending", { touch = { "lua/loop-kit/advanced.lua" } }) })
    f:respond("touch", { stdout = json({ id = "#6", action = "append", touch = {}, total = 2 }) })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:touch("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(
      full_argv(f, "touch", { "#6", "--append", "tests/unit/advanced_spec.lua" }),
      f:call(1).argv
    )
  end)

  it("clears and imports through their dedicated flags", function()
    local f, source, st, adv = harness({ pick = advanced_mod.TOUCH_CLEAR })
    seed(source, st, { task("#6", "pending", { touch = { "lua/loop-kit/advanced.lua" } }) })
    f:respond("touch", { stdout = json({ id = "#6", action = "clear", touch = vim.NIL, total = 0 }) })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local cleared = await(function(cb)
      adv:touch("#6", cb)
    end)
    truthy(cleared.ok, vim.inspect(cleared))
    eq(full_argv(f, "touch", { "#6", "--clear" }), f:call(1).argv)

    local f2, source2, st2, adv2 = harness({ pick = advanced_mod.TOUCH_IMPORT })
    seed(source2, st2, { task("#6", "pending") })
    f2:respond("touch", { stdout = json({ id = "#6", action = "import", touch = {}, total = 1 }) })
    f2:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local imported = await(function(cb)
      adv2:touch("#6", cb)
    end)
    truthy(imported.ok, vim.inspect(imported))
    eq(full_argv(f2, "touch", { "#6", "--import-doc" }), f2:call(1).argv)
  end)

  it("blocks an empty array before spawning a process", function()
    local f, source, st, adv = harness({
      pick = advanced_mod.TOUCH_SET,
      inputs = { "[]" },
    })
    seed(source, st, { task("#6", "pending") })

    local res = await(function(cb)
      adv:touch("#6", cb)
    end)

    falsy(res.ok)
    eq("invalid", res.code)
    eq(0, f:call_count())
    eq("[]", res.input)
    match(res.message, "空数组")
  end)

  it("blocks an absolute path and keeps the raw input", function()
    local raw = '["/etc/passwd"]'
    local f, source, st, adv = harness({ pick = advanced_mod.TOUCH_SET, inputs = { raw } })
    seed(source, st, { task("#6", "pending") })

    local res = await(function(cb)
      adv:touch("#6", cb)
    end)

    falsy(res.ok)
    eq("invalid", res.code)
    eq(0, f:call_count())
    eq(raw, res.input)
    match(res.message, "绝对路径")
  end)
end)

describe("advanced worktree meta", function()
  local sha = string.rep("abcdef01", 5)

  it("writes branch and baseSha together", function()
    local f, source, st, adv = harness({
      pick = advanced_mod.META_SET,
      inputs = { "feature/nvim-ui", sha },
    })
    seed(source, st, { task("#6", "pending") })
    f:respond("meta", { stdout = json({ id = "#6", branch = "feature/nvim-ui", baseSha = sha }) })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:meta("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(
      full_argv(f, "meta", { "#6", "--branch", "feature/nvim-ui", "--base-sha", sha }),
      f:call(1).argv
    )
    eq("feature/nvim-ui", res.payload.branch)
  end)

  it("requires a baseSha and preserves the branch input", function()
    local f, source, st, adv = harness({
      pick = advanced_mod.META_SET,
      inputs = { "feature/nvim-ui", nil },
    })
    seed(source, st, { task("#6", "pending") })

    local res = await(function(cb)
      adv:meta("#6", cb)
    end)

    falsy(res.ok)
    eq(0, f:call_count())
    eq("feature/nvim-ui", res.input.branch)
    match(res.message, "baseSha")
  end)

  it("clears only after confirmation", function()
    local f, source, st, adv = harness({ pick = advanced_mod.META_CLEAR })
    seed(source, st, { task("#6", "pending") })
    f:respond("meta", { stdout = json({ id = "#6", branch = vim.NIL, baseSha = vim.NIL }) })
    f:respond("list", { stdout = list_response({ task("#6", "pending") }) })

    local res = await(function(cb)
      adv:meta("#6", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "meta", { "#6", "--clear" }), f:call(1).argv)

    local f2, source2, st2, adv2 = harness({ pick = advanced_mod.META_CLEAR, answer = false })
    seed(source2, st2, { task("#6", "pending") })
    local declined = await(function(cb)
      adv2:meta("#6", cb)
    end)
    falsy(declined.ok)
    eq("cancelled", declined.code)
    eq(0, f2:call_count())
  end)
end)

describe("advanced failure handling", function()
  it("keeps the snapshot and selection on a remote failure", function()
    local f, source, st, adv = harness({ pick = "quick" })
    seed(source, st, { task("#5", "pending"), task("#6", "pending") })
    st:select("#6")
    f:respond("flow", { exit = 5, stderr = "远程写入失败" })

    local res = await(function(cb)
      adv:flow("#6", cb)
    end)

    falsy(res.ok)
    eq("exit", res.code)
    eq("remote", res.kind)
    eq({ "#5", "#6" }, ids(st.tasks))
    eq("#6", st:selected_id())
    eq(2, f:call_count())
    eq(full_argv(f, "flow", { "--list", "--no-sync" }), f:call(1).argv)
  end)
end)
