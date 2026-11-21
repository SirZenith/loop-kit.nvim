-- Health diagnostics for loop-kit. Everything here is read-only and offline:
-- probes run loop-cli without syncing, never print token values and never
-- treat a missing remote cache as a broken configuration.
local config = require("loop-kit.config")
local util = require("loop-kit.util")

local M = {}

local function json_decode(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if ok then
    return decoded
  end
  return nil
end

local function default_executable(path)
  return type(path) == "string" and vim.fn.executable(path) == 1
end

local function default_path_lookup(name)
  local found = vim.fn.exepath(name)
  if found == "" then
    return nil
  end
  return found
end

local function default_run(argv, opts)
  local ok, res = pcall(vim.system, argv, {
    env = opts.env,
    cwd = opts.cwd,
    timeout = opts.timeout or 5000,
  })
  if not ok or type(res) ~= "table" then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  -- Neovim 0.12 returns a SystemObj when on_exit is omitted; wait for it.
  if type(res.wait) == "function" then
    local waited, value = pcall(res.wait, res, opts.timeout or 5000)
    if waited and type(value) == "table" then
      res = value
    end
  end
  return res
end

local function probe(opts, argv)
  if type(opts.run) == "function" then
    local ok, res = pcall(opts.run, argv)
    if ok and type(res) == "table" then
      return res
    end
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  return default_run(argv, opts)
end

local function cli_argv(opts, root, command, args)
  local argv = { opts.cli_path }
  if root then
    argv[#argv + 1] = "--project-root"
    argv[#argv + 1] = root
  end
  argv[#argv + 1] = "--json"
  argv[#argv + 1] = command
  for _, arg in ipairs(args or {}) do
    argv[#argv + 1] = arg
  end
  return argv
end

local function has_arg(argv, value)
  for _, arg in ipairs(argv or {}) do
    if arg == value then
      return true
    end
  end
  return false
end

local function add(checks, name, status, message)
  checks[#checks + 1] = { name = name, status = status, message = message }
end

local function secrets_of(opts)
  local list = {}
  for _, value in ipairs(util.secret_values(vim.env, opts.env)) do
    list[#list + 1] = value
  end
  -- Token variables that happen to be unset locally may still leak through a
  -- probe's stderr; never echo them even when the env value is empty.
  local cfg = opts._config
  if cfg and type(cfg.tokenEnv) == "string" and cfg.tokenEnv ~= "" then
    local value = opts.env and opts.env[cfg.tokenEnv]
    if type(value) == "string" and value ~= "" then
      list[#list + 1] = value
    end
  end
  return list
end

local function sanitize(opts, text)
  if type(text) ~= "string" then
    return text
  end
  return util.sanitize_text(text, opts._secrets or {})
end

--- Run all health checks.
--- opts: root, cli_path, env, cwd, executable, path_lookup, run
function M.run(opts)
  opts = opts or {}
  local env = opts.env or vim.env
  local cwd = opts.cwd or vim.fn.getcwd()
  local executable = opts.executable or default_executable
  local path_lookup = opts.path_lookup or default_path_lookup

  local root = opts.root
  if root == nil or root == "" then
    root = config.find_root(cwd) or cwd
  end
  root = util.normalize_root(root) or root
  opts.root = root
  opts.env = env

  local checks = {}
  local result = { ok = true, root = root, checks = checks }

  -- 1. Neovim.
  if vim.fn.has("nvim-0.10") == 1 then
    add(checks, "neovim", "ok", "Neovim " .. tostring(vim.version()))
  else
    add(checks, "neovim", "error", "需要 Neovim 0.10 或更新版本")
  end

  -- 2. Config.
  local cfg, cfg_err = config.read_config(root)
  opts._config = cfg
  opts._secrets = secrets_of(opts)
  if cfg then
    add(checks, "config", "ok", string.format("%s（provider=%s）", root .. "/" .. config.CONFIG_FILE, tostring(cfg.provider)))
  else
    local message = (cfg_err and cfg_err.message) or "找不到 loop.config.json"
    add(checks, "config", "error", sanitize(opts, message))
  end

  -- 3. CLI executable.
  local cli_path = opts.cli_path
  if cli_path == nil or cli_path == "" then
    cli_path = type(env.LOOP_BIN) == "string" and env.LOOP_BIN ~= "" and env.LOOP_BIN or nil
  end
  if not cli_path and cfg and type(cfg.cliPath) == "string" and cfg.cliPath ~= "" then
    cli_path = util.absolute_path(root, cfg.cliPath)
  end
  if not cli_path then
    cli_path = path_lookup("loop-cli")
  end
  cli_path = cli_path or "loop-cli"
  opts.cli_path = cli_path
  result.cli_path = cli_path

  local cli_ok = executable(cli_path) == true
  if cli_ok then
    add(checks, "cli", "ok", cli_path)
  else
    add(checks, "cli", "error", "找不到可执行文件：" .. tostring(cli_path))
  end

  local function skipped(name, why)
    add(checks, name, "error", why)
  end

  -- 4. CLI version (a runnable binary may still be too old).
  if cli_ok then
    local res = probe(opts, { cli_path, "--version" })
    if (res.code or 0) == 0 then
      local version = util.trim(tostring(res.stdout or res.stderr or ""))
      add(checks, "version", "ok", version ~= "" and sanitize(opts, version) or "loop-cli")
    else
      add(checks, "version", "error", sanitize(opts, string.format("%s 无法响应 --version，请升级 loop-cli", cli_path)))
    end
  else
    skipped("version", "loop-cli 不可用，跳过 --version 探测")
  end

  local cfg_ok = cfg ~= nil

  -- 5. Resolved paths.
  if not cli_ok then
    skipped("paths", "loop-cli 不可用，跳过 paths 探测")
  elseif not cfg_ok then
    skipped("paths", "配置无效，跳过 paths 探测")
  else
    local res = probe(opts, cli_argv(opts, root, "paths"))
    if (res.code or 0) == 0 then
      local data = json_decode(res.stdout)
      if data and data.loopRoot then
        add(checks, "paths", "ok", tostring(data.loopRoot))
      else
        add(checks, "paths", "warn", "paths 输出无法解析")
      end
    else
      add(checks, "paths", "error", sanitize(opts, res.stderr ~= "" and res.stderr or res.stdout))
    end
  end

  -- 6. Token (name only, never the value).
  if cfg then
    local token_env = cfg.tokenEnv
    if type(token_env) ~= "string" or token_env == "" then
      add(checks, "token", "ok", "未配置 tokenEnv（provider=" .. tostring(cfg.provider) .. "）")
    else
      local value = env[token_env]
      if type(value) == "string" and value ~= "" then
        add(checks, "token", "ok", "已设置环境变量 " .. token_env)
      else
        add(checks, "token", "warn", "未设置环境变量 " .. token_env)
      end
    end
  else
    add(checks, "token", "error", "缺少配置，无法检查 tokenEnv")
  end

  -- 7. Cache read (always --no-sync: health never touches the network).
  if not cli_ok then
    skipped("list", "loop-cli 不可用，跳过 list 探测")
  elseif not cfg_ok then
    skipped("list", "配置无效，跳过 list 探测")
  else
    local res = probe(opts, cli_argv(opts, root, "list", { "--no-sync" }))
    if (res.code or 0) == 0 then
      local data = json_decode(res.stdout)
      local count = data and data.tasks and #data.tasks or 0
      add(checks, "list", "ok", string.format("缓存可读（%d 个任务）", count))
    else
      local stderr = tostring(res.stderr or "")
      if stderr:find("LOOP.remote.json", 1, true) or stderr:find("缓存", 1, true) then
        add(checks, "list", "warn", "远端缓存尚未同步，请运行 :LoopKit sync")
      else
        add(checks, "list", "error", sanitize(opts, stderr ~= "" and stderr or res.stdout))
      end
    end
  end

  -- 8. remove support: read `remove --help`; older CLIs only warn.
  if not cli_ok then
    skipped("remove", "loop-cli 不可用，跳过 remove 探测")
  elseif not cfg_ok then
    skipped("remove", "配置无效，跳过 remove 探测")
  else
    local res = probe(opts, cli_argv(opts, root, "remove", { "--help" }))
    local text = tostring((res.stdout or "") .. (res.stderr or ""))
    if (res.code or 0) == 0 then
      add(checks, "remove", "ok", "支持 remove 子命令")
    elseif text:lower():find("unrecognized", 1, true) or text:lower():find("unknown", 1, true) then
      add(checks, "remove", "warn", "当前 loop-cli 不支持 remove（升级后可用）")
    else
      add(checks, "remove", "warn", sanitize(opts, "remove 探测失败，可能是旧版本 loop-cli"))
    end
  end

  for _, check in ipairs(checks) do
    if check.status == "error" then
      result.ok = false
    end
  end

  return result
end

--- Render a health result as plain lines (used by :LoopKit health).
function M.lines(result)
  local lines = { "loop-kit health", "" }
  for _, check in ipairs(result and result.checks or {}) do
    lines[#lines + 1] = string.format("  [%s] %s: %s", check.status, check.name, check.message or "")
  end
  return lines
end

--- Show a health result in a scratch buffer.
function M.show(result)
  local lines = M.lines(result)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "loopkithealth"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

--- `:checkhealth loop-kit` entry point (Neovim calls `require(...).check()`).
function M.check(opts)
  return M.checkhealth(opts)
end

--- `:checkhealth loop-kit` entry point.
function M.checkhealth(opts)
  local result = M.run(opts or {})
  vim.health.start("loop-kit")
  for _, check in ipairs(result.checks) do
    local message = string.format("%s: %s", check.name, check.message or "")
    if check.status == "ok" then
      vim.health.ok(message)
    elseif check.status == "warn" then
      vim.health.warn(message)
    else
      vim.health.error(message)
    end
  end
  return result
end

return M
