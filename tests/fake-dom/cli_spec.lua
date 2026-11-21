local fake_cli = require("helpers.fake_cli")
local source_mod = require("loop-kit.source")

local function json(tbl)
  return vim.json.encode(tbl)
end

local function await(fn)
  local done, result = false, nil
  fn(function(res)
    result = res
    done = true
  end)
  vim.wait(5000, function()
    return done
  end, 10)
  if not done then
    error("timed out waiting for fake loop-cli")
  end
  return result
end

local function full_argv(f, command, args)
  local argv = { fake_cli.fixture, "--project-root", f.root, "--json", command }
  for _, arg in ipairs(args or {}) do
    argv[#argv + 1] = arg
  end
  return argv
end

describe("fake CLI request contracts", function()
  it("runs paths and stores its output verbatim", function()
    local f = fake_cli.new()
    f:respond("paths", {
      stdout = json({ config = f.root .. "/loop.config.json", loopRoot = "/weird/../shared" }),
    })
    local source = source_mod.new({ client = f:client(), root = f.root })

    local res = await(function(cb)
      source:paths(cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "paths", {}), f:call(1).argv)
    eq("/weird/../shared", res.paths.loopRoot)
    eq("/weird/../shared", source.snapshot.paths.loopRoot)
  end)

  it("runs list with no-sync/status/target flags in a stable order", function()
    local f = fake_cli.new()
    f:respond("list", {
      stdout = json({
        source = { kind = "local", location = f.root .. "/loop/LOOP.json" },
        tasks = { { id = "#12", title = "t", status = "pending", tag = "feat", desc = "" } },
        analysis = { outstandingCount = 1 },
      }),
    })
    local source = source_mod.new({ client = f:client(), root = f.root })

    local res = await(function(cb)
      source:list({ no_sync = true, status = "pending", target = "#12" }, cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "list", { "--no-sync", "--status", "pending", "--target", "#12" }), f:call(1).argv)
    eq("#12", res.tasks[1].id)
  end)

  it("runs show with the id kept as one argv entry", function()
    local f = fake_cli.new()
    f:respond("show", { stdout = json({ id = "#12", title = "中文 标题" }) })
    local source = source_mod.new({ client = f:client(), root = f.root })

    local res = await(function(cb)
      source:show("#12", cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "show", { "#12" }), f:call(1).argv)
    eq("中文 标题", res.task.title)
  end)

  it("runs decide with no-sync", function()
    local f = fake_cli.new()
    f:respond("decide", {
      stdout = json({ action = "next", id = "#2", reason = "go", ids = { "#2" } }),
    })
    local source = source_mod.new({ client = f:client(), root = f.root })

    local res = await(function(cb)
      source:decide({ no_sync = true }, cb)
    end)

    truthy(res.ok, vim.inspect(res))
    eq(full_argv(f, "decide", { "--no-sync" }), f:call(1).argv)
    eq("next", res.decision.action)
  end)
end)

describe("fake CLI stdin and byte fidelity", function()
  it("round-trips a multi-line description through stdin", function()
    local f = fake_cli.new()
    f:respond("add", { stdout = json({ id = "#9", title = "新任务" }) })
    local client = f:client()
    local desc = "第一段\n\n- 项目 `a`\n- \"quoted\" path\n\n结尾\n"

    local res = client:run_sync("add", {
      "--title",
      "新任务",
      "--tag",
      "feat",
      "--desc-file",
      "-",
    }, { stdin = desc })

    truthy(res.ok, vim.inspect(res))
    eq(desc, f:call(1).stdin)
    local argv = f:call(1).argv
    for _, arg in ipairs(argv) do
      falsy(arg:find("\n", 1, true), "description leaked into argv")
    end
  end)

  it("never shell-concatenates special characters", function()
    local f = fake_cli.new()
    f:respond("show", { stdout = json({ id = "#12" }) })
    local client = f:client()

    local special = { "#12", "space arg", 'double"quote', "中文参数", "$(echo pwned)", "a;b|c" }
    local res = client:run_sync("show", special)
    truthy(res.ok, vim.inspect(res))

    local argv = f:call(1).argv
    local prefix = { fake_cli.fixture, "--project-root", f.root, "--json", "show" }
    eq(#prefix + #special, #argv)
    for index, value in ipairs(prefix) do
      eq(value, argv[index])
    end
    for index, value in ipairs(special) do
      eq(value, argv[#prefix + index])
    end
  end)
end)
