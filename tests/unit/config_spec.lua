local tmp = require("helpers.tmp")
local paths = require("helpers.paths")
local config = require("loop-kit.config")

local FIXTURE = paths.fixtures_dir .. "/fake-loop-cli"

local function real(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Create a project root with a loop.config.json.
local function project(cfg, extra_files)
  local root = tmp.dir("cfg")
  tmp.write(root .. "/loop.config.json", vim.json.encode(cfg) .. "\n")
  if extra_files then
    for name, body in pairs(extra_files) do
      tmp.write(root .. "/" .. name, body)
    end
  end
  return root
end

local function base_cfg(overrides)
  return vim.tbl_extend("force", {
    version = 1,
    provider = "local",
    loopRoot = "loop",
    filePath = "LOOP.json",
  }, overrides or {})
end

local function resolve(opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    setup_cli_path = FIXTURE,
    cwd = tmp.dir("cwd"),
    env = {},
    executable = function(p)
      return vim.fn.executable(p) == 1
    end,
    path_lookup = function()
      return nil
    end,
  })
  return config.resolve(opts)
end

describe("config project discovery", function()
  it("prefers the explicit root over setup/cwd roots", function()
    local explicit = project(base_cfg())
    local other = project(base_cfg())

    local cfg, err = resolve({ explicit_root = explicit, project_root = other, cwd = other })
    eq(nil, err)
    eq(real(explicit), cfg.root)
  end)

  it("discovers the root by walking up from the current file", function()
    local root = project(base_cfg())
    local nested = root .. "/a/b/c/d.lua"
    tmp.write(nested, "-- file\n")

    local cfg, err = resolve({ file = nested })
    eq(nil, err)
    eq(real(root), cfg.root)
    eq(real(root .. "/loop.config.json"), cfg.config_path)
  end)

  it("discovers the root by walking up from cwd", function()
    local root = project(base_cfg())
    local nested = root .. "/a/b"
    vim.fn.mkdir(nested, "p")

    local cfg, err = resolve({ cwd = nested })
    eq(nil, err)
    eq(real(root), cfg.root)
  end)

  it("keeps loopRoot relative to the config directory as a hint", function()
    local root = project(base_cfg({ loopRoot = "loop" }))
    local cfg, err = resolve({ explicit_root = root })
    eq(nil, err)
    eq(real(root .. "/loop"), cfg.loop_root_hint)
    -- The raw config value stays available and is not rewritten.
    eq("loop", cfg.config.loopRoot)
  end)

  it("does not invent a loopRoot when the config uses an absolute path", function()
    local root = project(base_cfg({ loopRoot = "/elsewhere/shared-loop" }))
    local cfg, err = resolve({ explicit_root = root })
    eq(nil, err)
    eq("/elsewhere/shared-loop", cfg.loop_root_hint)
  end)

  it("reports a stable error when the config is missing", function()
    local empty = tmp.dir("empty")
    local cfg, err = resolve({ explicit_root = empty })
    eq(nil, cfg)
    eq("config_missing", err.code)
    match(err.message, "loop%.config%.json")
    eq(real(empty .. "/loop.config.json"), err.path)
  end)

  it("reports a stable error for unreadable JSON", function()
    local root = tmp.dir("badjson")
    tmp.write(root .. "/loop.config.json", "{not json")
    local cfg, err = resolve({ explicit_root = root })
    eq(nil, cfg)
    eq("config_invalid", err.code)
    match(err.message, "loop%.config%.json")
  end)

  it("rejects unknown providers before any CLI call", function()
    local root = project(base_cfg({ provider = "bogus" }))
    local cfg, err = resolve({ explicit_root = root })
    eq(nil, cfg)
    eq("config_invalid", err.code)
    match(err.message, "provider")
  end)
end)

describe("config CLI resolution", function()
  it("resolves a relative cliPath against the config directory", function()
    local root = project(base_cfg({ cliPath = "bin/loop-cli" }), {
      ["bin/loop-cli"] = "#!/bin/sh\nexit 0\n",
    })
    tmp.chmod(root .. "/bin/loop-cli", 493)

    local cfg, err = resolve({ explicit_root = root, setup_cli_path = false })
    eq(nil, err)
    eq(real(root .. "/bin/loop-cli"), cfg.cli_path)
    eq("config", cfg.cli_source)
  end)

  it("honours the documented priority setup -> LOOP_BIN -> cliPath -> PATH", function()
    local root = project(base_cfg({ cliPath = "bin/loop-cli" }), {
      ["bin/loop-cli"] = "#!/bin/sh\nexit 0\n",
      ["bin/env-cli"] = "#!/bin/sh\nexit 0\n",
      ["bin/setup-cli"] = "#!/bin/sh\nexit 0\n",
    })
    for _, name in ipairs({ "loop-cli", "env-cli", "setup-cli" }) do
      tmp.chmod(root .. "/bin/" .. name, 493)
    end

    local cfg = resolve({ explicit_root = root, setup_cli_path = root .. "/bin/setup-cli" })
    eq(real(root .. "/bin/setup-cli"), cfg.cli_path)
    eq("setup", cfg.cli_source)

    cfg = resolve({
      explicit_root = root,
      setup_cli_path = false,
      env = { LOOP_BIN = root .. "/bin/env-cli" },
    })
    eq(real(root .. "/bin/env-cli"), cfg.cli_path)
    eq("env", cfg.cli_source)

    cfg = resolve({ explicit_root = root, setup_cli_path = false, env = {} })
    eq(real(root .. "/bin/loop-cli"), cfg.cli_path)
    eq("config", cfg.cli_source)

    local bare = project(base_cfg(), {
      ["bin/env-cli"] = "#!/bin/sh\nexit 0\n",
    })
    tmp.chmod(bare .. "/bin/env-cli", 493)
    cfg = resolve({
      explicit_root = bare,
      setup_cli_path = false,
      env = {},
      path_lookup = function(name)
        eq("loop-cli", name)
        return bare .. "/bin/env-cli"
      end,
    })
    eq(real(bare .. "/bin/env-cli"), cfg.cli_path)
    eq("path", cfg.cli_source)
  end)

  it("reports a stable error when the configured CLI is not executable", function()
    local root = project(base_cfg({ cliPath = "bin/loop-cli" }), {
      ["bin/loop-cli"] = "# not executable\n",
    })
    local cfg, err = resolve({ explicit_root = root, setup_cli_path = false })
    eq(nil, cfg)
    eq("cli_not_executable", err.code)
    match(err.message, "bin/loop%-cli")
    eq(real(root .. "/bin/loop-cli"), err.path)
  end)

  it("reports a stable error when no CLI can be found", function()
    local root = project(base_cfg())
    local cfg, err = resolve({ explicit_root = root, setup_cli_path = false })
    eq(nil, cfg)
    eq("cli_not_found", err.code)
    match(err.message, "cli_path")
    match(err.message, "LOOP_BIN")
  end)
end)
