-- Integration tests for `:checkhealth loop-kit` / :LoopKit health.
-- Every CLI probe is injected: these tests never spawn a process, never touch
-- the network and never read a token value.
local health = require("loop-kit.health")
local fake_cli = require("helpers.fake_cli")
local tmp = require("helpers.tmp")

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

local function project(overrides)
  local root = tmp.dir("health")
  local cfg = vim.tbl_extend("force", {
    version = 1,
    provider = "local",
    loopRoot = "loop",
    filePath = "LOOP.json",
  }, overrides or {})
  tmp.write(root .. "/loop.config.json", json(cfg) .. "\n")
  return root
end

local function check(result, name)
  for _, item in ipairs(result.checks or {}) do
    if item.name == name then
      return item
    end
  end
  error("missing health check: " .. name)
end

local function assert_no_secret(result, secret)
  local text = table.concat(health.lines(result), "\n")
  falsy(text:find(secret, 1, true), "health output must not print token values")
end

--- opts with a fake executable and an injected probe runner.
local function opts(root, run, overrides)
  return vim.tbl_extend("force", {
    root = root,
    cli_path = fake_cli.fixture,
    env = {},
    cwd = root,
    executable = function(path)
      return path == fake_cli.fixture
    end,
    path_lookup = function()
      return nil
    end,
    run = run,
  }, overrides or {})
end

local function healthy(argv)
  if has_arg(argv, "--version") then
    return { code = 0, stdout = "loop-cli 0.1.0\n", stderr = "" }
  end
  if has_arg(argv, "paths") then
    return {
      code = 0,
      stdout = json({ config = "/tmp/p/loop.config.json", loopRoot = "/tmp/p/loop" }),
      stderr = "",
    }
  end
  if has_arg(argv, "list") then
    return {
      code = 0,
      stdout = json({ source = { kind = "local" }, tasks = {} }),
      stderr = "",
    }
  end
  if has_arg(argv, "remove") then
    return { code = 0, stdout = "Usage: loop-cli remove <id>\n", stderr = "" }
  end
  return { code = 0, stdout = "", stderr = "" }
end

describe("health diagnostics", function()
  it("reports a fully configured project as healthy", function()
    local root = project({ tokenEnv = "LOOP_KIT_SPEC_TOKEN" })
    local env = { LOOP_KIT_SPEC_TOKEN = "super-secret-value" }
    local result = health.run(opts(root, healthy, { env = env }))

    truthy(result.ok, vim.inspect(result.checks))
    eq("ok", check(result, "neovim").status)
    eq("ok", check(result, "cli").status)
    eq("ok", check(result, "version").status)
    match(check(result, "version").message, "loop%-cli 0%.1%.0")
    eq("ok", check(result, "config").status)
    eq("ok", check(result, "paths").status)
    eq("ok", check(result, "token").status)
    eq("ok", check(result, "list").status)
    eq("ok", check(result, "remove").status)
    assert_no_secret(result, "super-secret-value")
    match(check(result, "token").message, "LOOP_KIT_SPEC_TOKEN")
  end)

  it("flags a missing CLI without crashing", function()
    local root = project()
    local result = health.run(opts(root, healthy, {
      cli_path = "/nonexistent/loop-cli",
      executable = function()
        return false
      end,
    }))

    eq("error", check(result, "cli").status)
    eq("error", check(result, "version").status)
    eq("error", check(result, "paths").status)
    eq("error", check(result, "list").status)
    eq("error", check(result, "remove").status)
    falsy(result.ok)
  end)

  it("flags a missing config but still probes the CLI", function()
    local root = tmp.dir("empty")
    local result = health.run(opts(root, healthy))

    eq("error", check(result, "config").status)
    eq("ok", check(result, "cli").status)
    eq("error", check(result, "paths").status)
    falsy(result.ok)
  end)

  it("warns about a missing tokenEnv and only prints the variable name", function()
    local root = project({ tokenEnv = "LOOP_KIT_SPEC_MISSING" })
    local result = health.run(opts(root, healthy, { env = {} }))

    local token = check(result, "token")
    eq("warn", token.status)
    match(token.message, "LOOP_KIT_SPEC_MISSING")
    truthy(result.ok, "a missing token is recoverable, not a hard error")
  end)

  it("treats a missing remote cache as recoverable and never syncs", function()
    local root = project({ provider = "gitea", baseURL = "https://example.test/api", repo = "a/b", tokenEnv = "T" })
    local calls = {}
    local run = function(argv)
      calls[#calls + 1] = vim.deepcopy(argv)
      if has_arg(argv, "list") then
        return {
          code = 2,
          stdout = "",
          stderr = "Error: 找不到 LOOP.remote.json\n",
        }
      end
      return healthy(argv)
    end

    local result = health.run(opts(root, run, { env = { T = "secret-token" } }))
    local list = check(result, "list")
    eq("warn", list.status)
    match(list.message, "sync")
    truthy(result.ok, "a missing cache must not be reported as broken config")

    for _, argv in ipairs(calls) do
      if has_arg(argv, "list") then
        truthy(has_arg(argv, "--no-sync"), "health must never run a network sync")
      end
      falsy(has_arg(argv, "sync"), "health must never run a network sync")
    end
  end)

  it("warns when the CLI has no remove subcommand", function()
    local root = project()
    local run = function(argv)
      if has_arg(argv, "remove") then
        return { code = 1, stdout = "", stderr = "unrecognized subcommand 'remove'\n" }
      end
      return healthy(argv)
    end

    local result = health.run(opts(root, run))
    eq("warn", check(result, "remove").status)
    truthy(result.ok, "an old CLI is a warning, not a broken project")
  end)

  it("flags a CLI that cannot answer --version as an upgrade error", function()
    local root = project()
    local run = function(argv)
      if has_arg(argv, "--version") then
        return { code = 1, stdout = "", stderr = "error: unexpected argument '--version'\n" }
      end
      return healthy(argv)
    end

    local result = health.run(opts(root, run))
    eq("error", check(result, "version").status)
    match(check(result, "version").message, "升级")
    falsy(result.ok)
  end)

  it("exposes check() for :checkhealth and keeps it injectable", function()
    local root = project()
    eq("function", type(health.check))
    local result = health.check(opts(root, healthy))
    truthy(result, "check() must return the health result")
    eq("ok", check(result, "version").status)
    eq("ok", check(result, "config").status)
  end)

  it("does not print token values when a probe echoes the environment", function()
    local root = project({ tokenEnv = "LOOP_KIT_SPEC_ECHO" })
    local env = { LOOP_KIT_SPEC_ECHO = "echoed-secret-12345" }
    local run = function(argv)
      local res = healthy(argv)
      if has_arg(argv, "paths") then
        res.stderr = "token=echoed-secret-12345"
      end
      return res
    end

    local result = health.run(opts(root, run, { env = env }))
    assert_no_secret(result, "echoed-secret-12345")
  end)
end)
