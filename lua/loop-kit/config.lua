-- Project discovery, config reading and CLI resolution.
local util = require("loop-kit.util")

local M = {}

local PROVIDERS = { ["local"] = true, gitea = true, github = true, jira = true }
local CONFIG_FILE = "loop.config.json"

local function canonical(path)
  local normalized = util.normalize_path(path)
  if not normalized then
    return nil
  end
  return vim.uv.fs_realpath(normalized) or normalized
end

local function default_executable(path)
  return vim.fn.executable(path) == 1
end

local function default_path_lookup(name)
  local found = vim.fn.exepath(name)
  if not found or found == "" then
    return nil
  end
  return found
end

--- Read and minimally validate `<root>/loop.config.json`.
--- Returns (config, nil) or (nil, error).
function M.read_config(root)
  local config_path = util.normalize_path(root .. "/" .. CONFIG_FILE)
  local fd = io.open(config_path, "rb")  if not fd then
    return nil, {
      code = "config_missing",
      path = config_path,
      message = "找不到项目配置 " .. config_path .. "（loop.config.json 是 LOOP 的唯一入口）",
    }
  end

  local content = fd:read("*a")
  fd:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, {
      code = "config_invalid",
      path = config_path,
      message = "无法解析 " .. config_path .. "：" .. tostring(decoded),
    }
  end

  if decoded.version ~= 1 then
    return nil, {
      code = "config_invalid",
      path = config_path,
      message = "配置 " .. config_path .. " 的 version 必须为 1",
    }
  end

  if type(decoded.provider) ~= "string" or not PROVIDERS[decoded.provider] then
    return nil, {
      code = "config_invalid",
      path = config_path,
      message = "配置 " .. config_path .. " 的 provider 无效：" .. tostring(decoded.provider),
    }
  end

  if type(decoded.loopRoot) ~= "string" or util.trim(decoded.loopRoot) == "" then
    return nil, {
      code = "config_invalid",
      path = config_path,
      message = "配置 " .. config_path .. " 缺少有效的 loopRoot",
    }
  end

  return decoded
end

local function resolve_root(opts, env)
  if opts.explicit_root and opts.explicit_root ~= "" then
    return util.normalize_path(opts.explicit_root)
  end
  if opts.project_root and opts.project_root ~= "" then
    return util.normalize_path(opts.project_root)
  end

  local file = opts.file
  if file == nil then
    local ok, name = pcall(vim.api.nvim_buf_get_name, 0)
    if ok and name and name ~= "" then
      file = name
    end
  end
  if file and file ~= "" then
    local found = util.find_upward(file, CONFIG_FILE)
    if found then
      return found
    end
  end

  local cwd = opts.cwd or vim.fn.getcwd()
  local found = util.find_upward(cwd, CONFIG_FILE)
  if found then
    return found
  end

  if type(env.LOOP_PROJECT_ROOT) == "string" and env.LOOP_PROJECT_ROOT ~= "" then
    return util.normalize_path(env.LOOP_PROJECT_ROOT)
  end

  return util.normalize_path(cwd)
end

local function cli_error(path, source, executable)
  if path and not executable(path) then
    path = canonical(path)
    return nil, {
      code = "cli_not_executable",
      path = path,
      source = source,
      message = "loop-cli 不可执行：" .. tostring(path) .. "（来源：" .. source .. "）",
    }
  end
  return nil, {
    code = "cli_not_found",
    message = "找不到可执行的 loop-cli：请设置 setup.cli_path、$LOOP_BIN 或配置 cliPath",
  }
end

local function resolve_cli(opts, env, root, cfg, executable, path_lookup)
  local cwd = opts.cwd or vim.fn.getcwd()

  -- 1. setup.cli_path
  if opts.setup_cli_path and opts.setup_cli_path ~= "" then
    local path = util.absolute_path(cwd, opts.setup_cli_path)
    if executable(path) then
      return canonical(path), "setup"
    end
    return cli_error(path, "setup", executable)
  end

  -- 2. $LOOP_BIN
  if type(env.LOOP_BIN) == "string" and env.LOOP_BIN ~= "" then
    local path = util.absolute_path(cwd, env.LOOP_BIN)
    if executable(path) then
      return canonical(path), "env"
    end
    return cli_error(path, "env", executable)
  end

  -- 3. config.cliPath (relative to the config directory)
  if type(cfg.cliPath) == "string" and cfg.cliPath ~= "" then
    local path = util.absolute_path(root, cfg.cliPath)
    if executable(path) then
      return canonical(path), "config"
    end
    return cli_error(path, "config", executable)
  end

  -- 4. PATH
  local path = path_lookup("loop-cli")
  if not path or path == "" then
    return cli_error(nil, "path", executable)
  end
  path = util.normalize_path(path)
  if executable(path) then
    return canonical(path), "path"
  end
  return cli_error(path, "path", executable)
end

--- Resolve the project root, config and CLI path.
--- Returns (cfg, nil) or (nil, error). Error.code is one of
--- config_missing / config_invalid / cli_not_found / cli_not_executable.
function M.resolve(opts)
  opts = opts or {}
  local env = opts.env or vim.env
  local executable = opts.executable or default_executable
  local path_lookup = opts.path_lookup or default_path_lookup

  local root = resolve_root(opts, env)
  if not root then
    return nil, {
      code = "config_missing",
      message = "无法确定项目根目录（loop.config.json 所在目录）",
    }
  end
  root = canonical(root)

  local cfg, err = M.read_config(root)
  if not cfg then
    return nil, err
  end

  local cli_path, cli_source = resolve_cli(opts, env, root, cfg, executable, path_lookup)
  if not cli_path then
    return nil, cli_source
  end

  return {
    root = root,
    config_path = canonical(root .. "/" .. CONFIG_FILE),
    config = cfg,
    provider = cfg.provider,
    loop_root_hint = canonical(util.absolute_path(root, cfg.loopRoot) or cfg.loopRoot),
    cli_path = canonical(cli_path),
    cli_source = cli_source,
  }
end

M.CONFIG_FILE = CONFIG_FILE
M.find_root = function(start)
  return util.find_upward(start, CONFIG_FILE)
end

return M
