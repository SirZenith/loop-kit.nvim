-- loop-cli process client: argv construction, execution and error decoding.
local util = require("loop-kit.util")

local M = {}

local KINDS = {
  [1] = "usage",
  [2] = "source",
  [3] = "data",
  [4] = "rejected",
  [5] = "remote",
}

local function kind_for(code)
  return KINDS[code] or "unknown"
end

local function has_arg(args, needle)
  for _, arg in ipairs(args) do
    if arg == needle then
      return true
    end
  end
  return false
end

local function is_no_cache(command, args, stderr)
  return command == "list"
    and has_arg(args, "--no-sync")
    and type(stderr) == "string"
    and stderr:find("LOOP.remote.json", 1, true) ~= nil
end

local Client = {}
Client.__index = Client

--- Create a client.
--- opts: path (required), project_root, cwd, env, timeout, executable.
function M.new(opts)
  opts = opts or {}
  assert(type(opts.path) == "string" and opts.path ~= "", "loop-kit.cli: path is required")
  local self = setmetatable({}, Client)
  self.path = opts.path
  self.project_root = opts.project_root
  self.cwd = opts.cwd
  self.env = opts.env
  self.timeout = opts.timeout
  self._secrets = util.secret_values(vim.env, opts.env)
  return self
end

--- Build argv. `command` becomes the first loop-cli subcommand.
function Client:build(command, args, opts)
  opts = opts or {}
  local argv = { self.path }
  if self.project_root and self.project_root ~= "" then
    argv[#argv + 1] = "--project-root"
    argv[#argv + 1] = self.project_root
  end
  if opts.json ~= false then
    argv[#argv + 1] = "--json"
  end
  argv[#argv + 1] = command
  for _, arg in ipairs(args or {}) do
    argv[#argv + 1] = arg
  end
  return argv
end

function Client:_success(command, argv, res, opts)
  local stdout = res.stdout or ""
  local stderr = res.stderr or ""
  local result = {
    ok = true,
    command = command,
    argv = argv,
    exit_code = res.code or 0,
    stdout = stdout,
    stderr = stderr,
  }
  if res.signal and res.signal ~= 0 then
    result.signal = res.signal
  end

  local parse = opts.parse
  if parse == nil then
    parse = opts.json ~= false
  end
  if not parse then
    return result
  end

  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok then
    return {
      ok = false,
      code = "json",
      kind = "protocol",
      command = command,
      argv = argv,
      exit_code = res.code or 0,
      message = string.format(
        "%s 返回非 JSON 输出（exit %d）：%s",
        self.path,
        res.code or 0,
        util.truncate(util.sanitize_text(stdout, self._secrets), 2000)
      ),
      stdout = util.truncate(util.sanitize_text(stdout, self._secrets), 2000),
      stderr = util.truncate(util.sanitize_text(stderr, self._secrets), 2000),
    }
  end
  result.data = decoded
  return result
end

function Client:_failure(command, argv, res, opts)
  local stdout = util.truncate(util.sanitize_text(res.stdout or "", self._secrets), 2000)
  local stderr = util.truncate(util.sanitize_text(res.stderr or "", self._secrets), 2000)
  local exit_code = res.code or 0
  local failure = {
    ok = false,
    command = command,
    argv = argv,
    exit_code = exit_code,
    stdout = stdout,
    stderr = stderr,
  }

  if is_no_cache(command, opts.args, stderr) then
    failure.code = "no_cache"
    failure.kind = "source"
    failure.recoverable = true
    failure.message = "远端缓存尚未同步：" .. stderr
    return failure
  end

  failure.code = "exit"
  failure.kind = kind_for(exit_code)
  local detail = stderr
  if detail == "" then
    detail = stdout
  end
  if detail == "" then
    detail = "(no output)"
  end
  failure.message = string.format("%s 执行失败（exit %d）：%s", self.path, exit_code, detail)
  return failure
end

function Client:_result(command, argv, res, opts)
  if res.code == 0 then
    return self:_success(command, argv, res, opts)
  end
  return self:_failure(command, argv, res, opts)
end

local function system_opts(self, opts)
  local sys_opts = {}
  if self.cwd then
    sys_opts.cwd = self.cwd
  end
  if self.env then
    sys_opts.env = self.env
  end
  if opts.stdin then
    sys_opts.stdin = opts.stdin
  end
  local timeout = opts.timeout or self.timeout
  if timeout then
    sys_opts.timeout = timeout
  end
  return sys_opts
end

--- Run loop-cli synchronously. Returns the result table.
function Client:run_sync(command, args, opts)
  opts = opts or {}
  args = args or {}
  local argv = self:build(command, args, opts)
  local done, result = false, nil

  local handle = self:run(command, args, opts, function(res)
    result = res
    done = true
  end)

  vim.wait(opts.wait or 30000, function()
    return done
  end, 5)

  if not done then
    if handle and type(handle.kill) == "function" then
      pcall(handle.kill, handle, 15)
    end
    return {
      ok = false,
      code = "spawn",
      kind = "unknown",
      command = command,
      argv = argv,
      exit_code = nil,
      message = "loop-cli 未在超时内结束：" .. table.concat(argv, " "),
    }
  end
  return result
end

--- Run loop-cli asynchronously; `cb` is always invoked through vim.schedule.
function Client:run(command, args, opts, cb)
  opts = opts or {}
  args = args or {}
  opts.args = args
  local argv = self:build(command, args, opts)
  local sys_opts = system_opts(self, opts)

  local ok, handle = pcall(vim.system, argv, sys_opts, function(res)
    vim.schedule(function()
      cb(self:_result(command, argv, res, opts))
    end)
  end)

  if not ok then
    vim.schedule(function()
      cb({
        ok = false,
        code = "spawn",
        kind = "unknown",
        command = command,
        argv = argv,
        message = "无法启动 loop-cli：" .. tostring(handle),
      })
    end)
    return nil
  end

  return handle
end

return M
