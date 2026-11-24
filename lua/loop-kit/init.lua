-- Public Lua API and :LoopKit command dispatch.
local config = require("loop-kit.config")
local cli_mod = require("loop-kit.cli")
local util = require("loop-kit.util")
local health_mod = require("loop-kit.health")
local source_mod = require("loop-kit.source")
local board = require("loop-kit.ui.board")

local M = {}

local SUBCOMMANDS = {
  "open",
  "show",
  "edit",
  "add",
  "sync",
  "refresh",
  "remove",
  "unblock",
  "decide",
  "paths",
  "health",
  "close",
}

local function defaults()
  return {
    cli_path = nil,
    project_root = nil,
    auto_sync = true,
    watch = true,
    watch_interval = 1000,
    sync_on_focus = true,
    list_width = 38,
    detail_width = 80,
    default_filter = "open",
    sort = "id_desc",
    show_winbar = true,
    show_hint = true,
    display_style = "compact",
    icons = {
      pending = "○",
      doing = "◐",
      done = "●",
      blocked = "✕",
    },
    confirm = {
      done = true,
      force_done = true,
      block = true,
      remove = true,
    },
    keys = {},
  }
end

M._config = defaults()
M._boards = {}

--- The default configuration (a fresh copy).
function M.defaults()
  return vim.deepcopy(defaults())
end

--- User setup; deep-merges into the defaults and forwards UI options.
function M.setup(opts)
  opts = opts or {}
  M._config = vim.tbl_deep_extend("force", defaults(), opts)
  if M._config.display_style ~= "card" then
    M._config.display_style = "compact"
  end
  board.setup({
    list_width = M._config.list_width,
    detail_width = M._config.detail_width,
    default_filter = M._config.default_filter,
    sort = M._config.sort,
    show_winbar = M._config.show_winbar,
    show_hint = M._config.show_hint,
    display_style = M._config.display_style,
    auto_sync = M._config.auto_sync,
    watch = M._config.watch,
    watch_interval = M._config.watch_interval,
    sync_on_focus = M._config.sync_on_focus,
    icons = M._config.icons,
    keys = M._config.keys,
  })
  return M._config
end

--- Return to defaults and drop every tracked board.
function M.reset()
  for root in pairs(M._boards) do
    M._boards[root] = nil
  end
  M._config = defaults()
  board.setup({
    list_width = M._config.list_width,
    detail_width = M._config.detail_width,
    default_filter = M._config.default_filter,
    sort = M._config.sort,
    show_winbar = M._config.show_winbar,
    show_hint = M._config.show_hint,
    display_style = M._config.display_style,
    auto_sync = M._config.auto_sync,
    watch = M._config.watch,
    watch_interval = M._config.watch_interval,
    sync_on_focus = M._config.sync_on_focus,
    icons = M._config.icons,
    keys = M._config.keys,
  })
  return M._config
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.ERROR)
end

local function emit(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    modeline = false,
    data = data,
  })
end

local function emit_updated(root, snapshot)
  if not snapshot then
    return
  end
  emit("LoopKitUpdated", {
    root = root,
    snapshot = util.deepcopy(snapshot),
  })
end

local function emit_action(root, res)
  if type(res) ~= "table" or type(res.action) ~= "string" then
    return
  end
  if res.code == "cancelled" then
    return
  end
  emit("LoopKitAction", {
    root = root,
    id = res.id,
    action = res.action,
    ok = res.ok == true,
    error = res.ok == true and nil or (res.message or res.code),
  })
end

local function normalize_root(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  return util.normalize_root(root)
end

local function root_arg(opts)
  if type(opts) == "string" then
    return normalize_root(opts)
  end
  if type(opts) == "table" then
    return normalize_root(opts.root or opts.project_root or opts.path)
  end
  return nil
end

local function find_board(root)
  if not root then
    return nil
  end
  local instance = M._boards[normalize_root(root)]
  if instance and not instance.closed and instance:is_open() then
    return instance
  end
  return nil
end

--- Resolve a project root and its CLI client from setup/opts.
local function resolve(opts)
  local resolved, err = config.resolve({
    explicit_root = opts.root or opts.path,
    project_root = M._config.project_root,
    cwd = opts.cwd,
    env = opts.env,
    setup_cli_path = M._config.cli_path,
    executable = opts.executable,
    path_lookup = opts.path_lookup,
  })
  if not resolved then
    return nil, nil, err
  end
  return resolved, resolved.cli_path, nil
end

--- Open (or focus) the board for a project; returns board, created.
function M.open(opts)
  if type(opts) == "string" then
    opts = { path = opts }
  end
  opts = opts or {}

  local root, resolved, err

  if opts.source then
    root = normalize_root(opts.root or opts.project_root or opts.source.root or vim.fn.getcwd())
    if not root then
      notify("无法确定项目根目录")
      return nil, false
    end
    resolved = { root = root, provider = opts.provider }
  else
    local resolved_cfg, cli_path, resolve_err = resolve(opts)
    resolved, err = resolved_cfg, resolve_err
    if not resolved then
      local message = (err and err.message) or "找不到项目配置（loop.config.json）"
      notify(message)
      return nil, false
    end
    root = normalize_root(resolved.root)
    if not cli_path then
      cli_path = resolved.cli_path
    end
    if not opts.client and cli_path then
      opts.client = cli_mod.new({
        path = cli_path,
        project_root = root,
        cwd = opts.cwd,
        env = opts.env or vim.env,
      })
    end
  end

  opts.root = root
  opts.project_root = nil
  opts.path = nil
  opts.list_width = opts.list_width or M._config.list_width
  opts.detail_width = opts.detail_width or M._config.detail_width
  opts.default_filter = opts.default_filter or M._config.default_filter
  opts.sort = opts.sort or M._config.sort
  if opts.show_winbar == nil then
    opts.show_winbar = M._config.show_winbar
  end
  if opts.show_hint == nil then
    opts.show_hint = M._config.show_hint
  end
  opts.display_style = opts.display_style or M._config.display_style
  opts.icons = opts.icons or M._config.icons
  opts.confirm = opts.confirm or M._config.confirm
  opts.keys = opts.keys or M._config.keys
  if opts.auto_sync == nil then
    opts.auto_sync = M._config.auto_sync
  end
  if opts.watch == nil then
    opts.watch = M._config.watch
  end
  if opts.watch_interval == nil then
    opts.watch_interval = M._config.watch_interval
  end
  if opts.sync_on_focus == nil then
    opts.sync_on_focus = M._config.sync_on_focus
  end
  opts.loop_root = opts.loop_root or (resolved and resolved.loop_root_hint)
  opts.on_action = opts.on_action or function(res)
    emit_action(root, res)
  end
  opts.on_updated = opts.on_updated or function(_board, snapshot)
    emit_updated(root, snapshot)
  end

  local instance, created = board.open(opts)
  if instance then
    M._boards[root] = instance
  end
  return instance, created
end

--- Close one board or all of them. opts: all, root.
function M.close(opts)
  if type(opts) == "table" and opts.all then
    for root, instance in pairs(M._boards) do
      if not instance.closed then
        instance:close()
      end
      M._boards[root] = nil
    end
    return true
  end

  local root = root_arg(opts)
  if root then
    local instance = find_board(root)
    if instance then
      instance:close()
      M._boards[root] = nil
      return true
    end
    return false
  end

  local tab = vim.api.nvim_get_current_tabpage()
  for board_root, instance in pairs(M._boards) do
    if not instance.closed and instance.tabpage == tab then
      instance:close()
      M._boards[board_root] = nil
      return true
    end
  end
  return false
end

local function ensure_board(opts)
  opts = opts or {}
  local root = root_arg(opts) or normalize_root(vim.fn.getcwd())
  local instance = find_board(root)
  if instance then
    return instance
  end
  instance = M.open(opts)
  return instance
end

--- Read from the cache (default) or run an explicit sync.
function M.refresh(opts)
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  if type(opts) == "table" and opts.sync then
    instance:sync()
  else
    instance:refresh({ no_sync = true })
  end
  return instance
end

--- Force a full `loop-cli list` (may touch the network for remote providers).
function M.sync(opts)
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  instance:sync()
  return instance
end

--- Copy of the source snapshot for a project.
function M.get_snapshot(root)
  local instance = find_board(root or vim.fn.getcwd())
  if not instance or not instance.source then
    return nil
  end
  local snapshot = instance.source.snapshot
  return {
    root = snapshot.root,
    source = util.deepcopy(snapshot.source),
    tasks = util.deepcopy(snapshot.tasks),
    analysis = util.deepcopy(snapshot.analysis),
    paths = util.deepcopy(snapshot.paths),
    decide = util.deepcopy(snapshot.decide),
    last_task = util.deepcopy(snapshot.last_task),
    loaded = snapshot.loaded,
    state = snapshot.state,
    error = util.deepcopy(snapshot.error),
    syncing = snapshot.syncing,
    generation = snapshot.generation,
  }
end

--- One task from the current snapshot (or the last `show` result).
function M.get_task(id, root)
  local instance = find_board(root or vim.fn.getcwd())
  if not instance or not instance.source then
    return nil
  end
  local normalized = util.normalize_id(id)
  local snapshot = instance.source.snapshot
  if normalized then
    for _, task in ipairs(snapshot.tasks or {}) do
      if task.id == normalized then
        return util.deepcopy(task)
      end
    end
    local last = snapshot.last_task
    if last and last.id == normalized then
      return util.deepcopy(last)
    end
  end
  return nil
end

--- The action controller for a project (created lazily by the board).
function M.actions(root)
  local instance = find_board(root or vim.fn.getcwd())
  if not instance then
    return nil
  end
  return instance:_ensure_actions()
end

--- Show a task: open the board, select and focus the detail pane.
function M.show(id, opts)
  if type(id) == "table" then
    opts, id = id, id.id
  end
  opts = opts or {}
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  if id then
    instance:select(util.normalize_id(id))
  end
  instance:handle("open_detail")
  return instance
end

--- Edit the field under the cursor (opens the board first).
function M.edit(id, opts)
  if type(id) == "table" then
    opts, id = id, id.id
  end
  opts = opts or {}
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  if id then
    instance:select(util.normalize_id(id))
  end
  instance:handle("edit")
  return instance
end

--- Add a new task (collects title and tag, then calls loop-cli add).
function M.add(opts)
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  instance:handle("add")
  return instance
end

--- Remove a task (asks for confirmation according to setup.confirm).
function M.remove(id, opts)
  if type(id) == "table" then
    opts, id = id, id.id
  end
  opts = opts or {}
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  if id then
    instance:select(util.normalize_id(id))
  end
  instance:handle("remove")
  return instance
end

--- Move a blocked task back to pending (blocked → pending, no confirmation).
function M.unblock(id, opts)
  if type(id) == "table" then
    opts, id = id, id.id
  end
  opts = opts or {}
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  if id ~= nil and id ~= "" then
    local normalized = util.normalize_id(id)
    if not normalized then
      notify("任务 id 不合法：" .. tostring(id))
      return nil
    end
    if not instance:select(normalized) then
      notify(string.format("未找到任务 %s（可能被当前筛选隐藏）", normalized))
      return nil
    end
  end
  instance:handle("unblock")
  return instance
end

--- Ask the scheduler for the next action and select it when applicable.
function M.decide(opts)
  local instance = ensure_board(opts)
  if not instance then
    return nil
  end
  instance:handle("decide")
  return instance
end

--- Resolve paths through loop-cli. `opts` may be omitted.
function M.paths(opts, cb)
  if type(opts) == "function" then
    opts, cb = {}, opts
  end
  opts = opts or {}
  cb = cb or function() end

  local instance = find_board(root_arg(opts) or vim.fn.getcwd())
  if instance and instance.source then
    instance.source:paths(function(res)
      cb(res)
    end)
    return
  end

  local root, cli_path, err = resolve(opts)
  if not root then
    cb({ ok = false, code = "config", message = (err and err.message) or "找不到项目配置" })
    return
  end
  local client = opts.client
  if not client and cli_path then
    client = cli_mod.new({
      path = cli_path,
      project_root = normalize_root(root.root),
      cwd = opts.cwd,
      env = opts.env or vim.env,
    })
  end
  if not client then
    cb({ ok = false, code = "config", message = "找不到可执行的 loop-cli" })
    return
  end
  source_mod.new({ client = client, root = normalize_root(root.root) }):paths(cb)
end

--- Run health checks. Without opts the result is also shown in a split.
function M.health(opts)
  if opts then
    opts.cli_path = opts.cli_path or M._config.cli_path
    return health_mod.run(opts)
  end
  local result = health_mod.run({ cli_path = M._config.cli_path, project_root = M._config.project_root })
  health_mod.show(result)
  return result
end

local function normalize_subcommand(value)
  if type(value) ~= "string" then
    return ""
  end
  return value:lower()
end

--- :LoopKit dispatcher. `args` is the raw argument string, `fargs` the split
--- list supplied by nvim_create_user_command.
function M.command(args, fargs)
  local parts = fargs
  if not parts or #parts == 0 then
    parts = type(args) == "string" and vim.split(util.trim(args), "%s+", { trimempty = true }) or {}
  end

  local sub = normalize_subcommand(parts[1])
  if sub == "" then
    return M.open({})
  elseif sub == "open" then
    return M.open(parts[2] and { path = parts[2] } or {})
  elseif sub == "show" then
    return M.show(parts[2])
  elseif sub == "edit" then
    return M.edit(parts[2])
  elseif sub == "add" then
    return M.add()
  elseif sub == "sync" then
    return M.sync()
  elseif sub == "refresh" then
    return M.refresh()
  elseif sub == "remove" then
    return M.remove(parts[2])
  elseif sub == "unblock" then
    return M.unblock(parts[2])
  elseif sub == "decide" then
    return M.decide()
  elseif sub == "paths" then
    return M.paths({}, function(res)
      if res and res.ok then
        notify("loop-kit paths：" .. vim.inspect(res.paths or {}), vim.log.levels.INFO)
      else
        notify("paths 失败：" .. tostring((res and (res.message or res.code)) or "无响应"))
      end
    end)
  elseif sub == "health" then
    return M.health()
  elseif sub == "close" then
    return M.close()
  end

  notify("未知的 :LoopKit 子命令：" .. tostring(parts[1]))
  return nil
end

function M.complete(arglead)
  local matches = {}
  for _, name in ipairs(SUBCOMMANDS) do
    if arglead == "" or name:sub(1, #arglead) == arglead then
      matches[#matches + 1] = name
    end
  end
  return matches
end

return M
