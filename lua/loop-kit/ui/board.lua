-- Board UI: one tab, a list pane on the left and a detail pane on the right.
--
-- The board owns the tab/window lifecycle and all keymaps. Actions, field
-- edits and advanced views are required lazily so opening the board (or running the
-- render tests) never depends on the write paths. Async callbacks are guarded
-- by a per-board request generation and a `closed` flag; stale responses never
-- redraw a closed board.
local util = require("loop-kit.util")
local list_ui = require("loop-kit.ui.list")
local detail_ui = require("loop-kit.ui.detail")
local help_ui = require("loop-kit.ui.help")
local edit_ui = require("loop-kit.edit")
local kv = require("loop-kit.kv")
local picker = require("loop-kit.ui.picker")

-- Define the default links as soon as the board is loaded: users are not
-- required to call setup(), and extmarks resolve hl_group names eagerly.
require("loop-kit.highlights").setup()

local M = {}

local OPEN_STATUS = { pending = true, doing = true, blocked = true }
local FILTER_ORDER = { "open", "all", "pending", "doing", "blocked", "done" }
local HINT = "j/k 移动 · <CR> 详情 · / 筛选 · s/A 筛选 · S 排序 · r/R 刷新 · o doc · ? 帮助 · q 关闭"

local DEFAULT_KEYS = {
  j = "move_down",
  k = "move_up",
  ["<Down>"] = "move_down",
  ["<Up>"] = "move_up",
  ["<CR>"] = "open_detail",
  ["/"] = "filter_prompt",
  ["<Esc>"] = "clear_query",
  s = "cycle_filter",
  A = "filter_all",
  S = "cycle_sort",
  r = "refresh",
  R = "sync",
  c = "claim",
  d = "done",
  D = "force_done",
  b = "block",
  e = "edit",
  a = "add",
  x = "remove",
  o = "open_doc",
  F = "flow",
  P = "private",
  T = "touch",
  M = "meta",
  n = "decide",
  ["?"] = "help",
  q = "close",
}

M.DEFAULT_KEYS = DEFAULT_KEYS
M.config = {
  list_width = 38,
  default_filter = "open",
  sort = "id_desc",
  auto_sync = true,
  show_winbar = true,
  show_hint = true,
  keys = {},
}

local active = {}
local next_id = 0

local Board = {}
Board.__index = Board

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

--- Configure defaults for later `M.open` calls.
function M.setup(opts)
  if type(opts) == "table" then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end
  return M
end

--- Board currently owning `root`, or nil.
function M.get(root)
  local key = util.normalize_root(root)
  return key and active[key] or nil
end

local function merge_keys(...)
  local keys = {}
  for _, source in ipairs({ ... }) do
    if type(source) == "table" then
      for lhs, action in pairs(source) do
        keys[lhs] = action
      end
    end
  end
  return keys
end

function Board:_notify(message)
  if message == nil or message == "" then
    return
  end
  if self.opts.notify then
    self.opts.notify(message)
    return
  end
  pcall(vim.notify, "[loop-kit] " .. tostring(message), vim.log.levels.WARN)
end

--- Build client/source/state, using injected dependencies when given.
function Board:_ensure_deps()
  local state_mod = require("loop-kit.state")
  M._states = M._states or state_mod.new()

  self.state = self.opts.state or M._states:get(self.root)
  self.client = self.opts.client
  self.source = self.opts.source

  if not self.client and not self.source then
    local ok, resolved = pcall(function()
      return require("loop-kit.config").resolve({ project_root = self.root })
    end)
    if not ok then
      self.load_error = tostring(resolved)
    elseif resolved and resolved.error then
      local err = resolved.error
      self.load_error = err.message or err.code or "配置不可用"
    else
      self.config = resolved
      self.provider = resolved and resolved.provider
      if resolved and resolved.cli_path then
        local cli = require("loop-kit.cli")
        self.client = cli.new({ path = resolved.cli_path, project_root = self.root })
      else
        self.load_error = "未找到可用的 loop-cli"
      end
    end
  end

  if not self.source then
    if self.client then
      local source_mod = require("loop-kit.source")
      self.source = source_mod.new({ client = self.client, root = self.root })
    elseif not self.load_error then
      self.load_error = "未找到可用的 loop-cli"
    end
  end

  if self.state then
    local default_filter = self.opts.default_filter or M.config.default_filter
    if default_filter and #(self.state.tasks or {}) == 0 and (self.state.query or "") == "" then
      -- Fresh state: honour the configured default filter.
      self.state.filter = default_filter
    end
    if self.state.set_sort then
      self.state:set_sort(self.opts.sort or M.config.sort)
    end
    self.loaded = #(self.state.tasks or {}) > 0
  end
end

function Board:_create_ui()
  vim.cmd("tabnew")
  self.tabpage = vim.api.nvim_get_current_tabpage()

  local list_buf = vim.api.nvim_create_buf(false, true)
  local detail_buf = vim.api.nvim_create_buf(false, true)
  local list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(list_win, list_buf)

  vim.cmd("vsplit")
  local detail_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(detail_win, detail_buf)

  self.list_buf, self.detail_buf = list_buf, detail_buf
  self.list_win, self.detail_win = list_win, detail_win

  local width = tonumber(self.opts.list_width or M.config.list_width) or 38
  width = math.max(10, math.min(width, math.max(10, vim.o.columns - 20)))
  pcall(vim.api.nvim_win_set_width, list_win, width)
  self.width = width

  local function configure(win, cursorline)
    pcall(function()
      vim.wo[win].winfixwidth = win == list_win
      vim.wo[win].cursorline = cursorline
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].wrap = win == detail_win
    end)
  end
  configure(list_win, true)
  configure(detail_win, false)

  self.list = list_ui.new({
    state = self.state,
    buf = list_buf,
    win = list_win,
    icons = self.opts.icons or M.config.icons,
    sort = self.opts.sort or M.config.sort,
    on_select = function()
      self:_draw_detail()
    end,
  })
  self.list:set_hint(HINT)
  local show_hint = self.opts.show_hint
  if show_hint == nil then
    show_hint = M.config.show_hint
  end
  self.show_hint = show_hint ~= false
  if not self.show_hint then
    self.list:set_hint(nil)
  end
  local show_winbar = self.opts.show_winbar
  if show_winbar == nil then
    show_winbar = M.config.show_winbar
  end
  self.show_winbar = show_winbar ~= false
  self.detail = detail_ui.new({
    root = self.root,
    buf = detail_buf,
    win = detail_win,
    opener = self.opts.open_doc,
    notify = function(message)
      self:_notify(message)
    end,
  })

  pcall(vim.api.nvim_set_current_win, list_win)
end

local function bind_action(self, buf, lhs, action)
  if action == false or action == nil then
    return
  end
  pcall(vim.keymap.set, "n", lhs, function()
    self:handle(action)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "LoopKit " .. tostring(action),
  })
end

function Board:_bind_keys()
  if valid_buf(self.list_buf) then
    for lhs, action in pairs(self.keys) do
      bind_action(self, self.list_buf, lhs, action)
    end
  end
  if valid_buf(self.detail_buf) then
    for _, lhs in ipairs({ "q", "?", "o", "e" }) do
      local action = self.keys[lhs]
      if action ~= nil then
        bind_action(self, self.detail_buf, lhs, action)
      end
    end
  end
end

function Board:_register_autocmds()
  local augroup = vim.api.nvim_create_augroup("LoopKitBoard" .. self.id, { clear = true })
  self.augroup = augroup

  local function teardown()
    vim.schedule(function()
      self:_teardown()
    end)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = { tostring(self.list_win), tostring(self.detail_win) },
    callback = teardown,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    pattern = tostring(vim.api.nvim_tabpage_get_number(self.tabpage)),
    callback = function()
      self:_teardown({ skip_tab = true })
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      self:_resize()
    end,
  })
end

function Board:_resize()
  if self.closed then
    return
  end
  if valid_win(self.list_win) then
    local max_width = math.max(10, vim.o.columns - 20)
    pcall(vim.api.nvim_win_set_width, self.list_win, math.min(self.width, max_width))
  end
end

function Board:is_open()
  return not self.closed
    and valid_tab(self.tabpage)
    and valid_buf(self.list_buf)
    and valid_buf(self.detail_buf)
end

function Board:focus()
  if not self:is_open() then
    return false
  end
  pcall(vim.api.nvim_set_current_tabpage, self.tabpage)
  if self.list then
    self.list:focus()
  end
  return true
end

function Board:_teardown(opts)
  opts = opts or {}
  if self.closed then
    return
  end
  self.closed = true
  self._request = (self._request or 0) + 1

  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if self._help_open then
    help_ui.close()
    self._help_open = false
  end

  if not opts.skip_tab and valid_tab(self.tabpage) then
    local number = vim.api.nvim_tabpage_get_number(self.tabpage)
    pcall(vim.cmd, "silent tabclose " .. number)
  end

  for _, buf in ipairs({ self.list_buf, self.detail_buf }) do
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  if active[self.root] == self then
    active[self.root] = nil
  end

  self.list = nil
  self.detail = nil
  self.source = nil
  self.state = nil
  self.actions = nil
  self.advanced = nil
  self.decide = nil
end

function Board:close()
  self:_teardown()
end

function Board:winbar()
  local source = self.source and self.source.snapshot and self.source.snapshot.source or {}
  local provider = self.provider or source.provider or source.kind or source.name or "local"
  local name = vim.fs.basename(self.root) or self.root
  local open_count = 0
  if self.state then
    for _, task in ipairs(self.state.tasks or {}) do
      if OPEN_STATUS[task.status] then
        open_count = open_count + 1
      end
    end
  end

  local parts = {
    "LoopKit",
    name,
    provider,
    "open " .. open_count,
    "filter " .. ((self.state and self.state.filter) or "open"),
    "sort " .. ((self.state and self.state.sort) or "id_desc"),
  }
  if self.state and self.state.query and self.state.query ~= "" then
    parts[#parts + 1] = "query " .. self.state.query
  end

  local flags = {}
  if self.loading then
    flags[#flags + 1] = "loading"
  end
  if self.syncing then
    flags[#flags + 1] = "syncing"
  end
  if self.state and self.state:is_writing() then
    flags[#flags + 1] = "writing"
  end
  if self.load_error then
    flags[#flags + 1] = "error"
  end
  if #flags > 0 then
    parts[#parts + 1] = table.concat(flags, "|")
  end

  return table.concat(parts, " · ")
end

function Board:_update_winbar()
  local text = self:winbar():gsub("%%", "%%%%")
  if valid_win(self.list_win) and self.show_winbar ~= false then
    pcall(function()
      vim.wo[self.list_win].winbar = text
    end)
  end
  if valid_win(self.detail_win) then
    pcall(function()
      vim.wo[self.detail_win].winbar = text
    end)
  end
end

function Board:_list_state()
  if not self.state then
    return "error", "加载失败：" .. (self.load_error or "状态不可用")
  end
  if self.loading then
    return "loading", "加载中…正在读取 loop-cli。"
  end
  if not self.loaded and self.load_error then
    return "error", "加载失败：" .. self.load_error
  end
  if not self.loaded then
    return "loading", "加载中…正在读取 loop-cli。"
  end

  if #self.state:visible_tasks() > 0 then
    return nil
  end
  if #(self.state.tasks or {}) == 0 then
    return "empty", "（无任务）当前项目还没有任务。"
  end
  local query = self.state.query or ""
  local suffix = query ~= "" and string.format("，关键字 “%s”", query) or ""
  return "no_match", string.format("（无匹配）筛选 %s 下没有任务%s。", self.state.filter or "all", suffix)
end

function Board:_draw_detail()
  if self.editing then
    return
  end
  if self.closed or not self.detail or not valid_buf(self.detail_buf) then
    return
  end
  if valid_win(self.detail_win) then
    local ok, current = pcall(vim.api.nvim_win_get_buf, self.detail_win)
    if ok and current ~= self.detail_buf then
      pcall(vim.api.nvim_win_set_buf, self.detail_win, self.detail_buf)
    end
  end

  local task = self.state and self.state:selected()
  if not task then
    self.detail:placeholder("未选择任务")
    return
  end

  local by_id = {}
  for _, item in ipairs(self.state.tasks or {}) do
    by_id[item.id] = item
  end
  local analysis = self.source and self.source.snapshot and self.source.snapshot.analysis or nil
  self.detail:render(task, by_id, analysis, self.state.tasks)
end

function Board:draw()
  if self.closed or not self.list then
    return
  end
  self:_update_winbar()
  if self.editing then
    return
  end
  local kind, text = self:_list_state()
  if kind then
    self.list:notice(kind, text)
  else
    self.list:draw()
  end
  self:_draw_detail()
end

--- Refresh from cache (default) or run an explicit sync.
function Board:refresh(opts)
  opts = opts or {}
  if self.closed then
    return false
  end
  if not self.source then
    self.loaded = false
    self.loading = false
    self.load_error = self.load_error or "没有可用的 loop-cli"
    self:draw()
    return false
  end

  self._request = (self._request or 0) + 1
  local request = self._request
  if not self.loaded then
    self.loading = true
  end
  self.syncing = true
  self.load_error = nil
  self:_update_winbar()

  local function done(res)
    if self.closed or self._request ~= request then
      return
    end
    self.syncing = false
    self.loading = false
    res = res or { ok = false, message = "loop-cli 无响应" }
    if res.ok then
      self.loaded = true
      self.load_error = nil
      self.state:set_snapshot(res)
    elseif res.code ~= "stale" then
      self.load_error = res.message or "刷新失败"
    end
    self:draw()
    if opts.after then
      pcall(opts.after, self)
    end
    if self.opts.on_updated then
      pcall(self.opts.on_updated, self, self.source and self.source.snapshot)
    end
    if opts.then_sync and not self.closed and (res.ok or res.code == "no_cache" or res.no_cache) then
      local kind = self.source and self.source.snapshot.source and self.source.snapshot.source.kind
      if kind ~= "local" then
        vim.schedule(function()
          if not self.closed then
            self:sync()
          end
        end)
      end
    end
  end

  if opts.sync then
    self.source:sync(done)
  else
    self.source:list({ no_sync = opts.no_sync ~= false }, done)
  end
  return true
end

function Board:sync()
  return self:refresh({ sync = true })
end

function Board:set_filter(filter)
  if self.closed or not self.state then
    return
  end
  self.state:set_filter(filter)
  self:draw()
end

function Board:set_sort(sort)
  if self.closed or not self.state then
    return
  end
  self.state:set_sort(sort)
  self:draw()
end

function Board:set_query(query)
  if self.closed or not self.state then
    return
  end
  self.state:set_query(query)
  self:draw()
end

function Board:select(id)
  if self.closed or not self.list then
    return false
  end
  local ok = self.list:select_id(id)
  if ok then
    self.list:focus()
  end
  return ok
end

function Board:toggle_help()
  self._help_open = help_ui.toggle({ keys = self.keys, parent = self.list_win })
  return self._help_open
end

function Board:_prompt_query()
  local input = self.opts.input or function(prompt, cb)
    vim.ui.input({ prompt = prompt, default = self.state.query or "" }, cb)
  end
  input("筛选关键字（空=清除）: ", function(value)
    if self.closed then
      return
    end
    self:set_query(value or "")
  end)
end

function Board:_selected_id()
  local id = self.state and self.state:selected_id()
  if not id then
    self:_notify("未选择任务")
    return nil
  end
  return id
end

function Board:_ensure_actions()
  if self.actions then
    return self.actions
  end
  self.actions = require("loop-kit.actions").new({
    client = self.client,
    source = self.source,
    state = self.state,
    root = self.root,
    loop_root = self.config and self.config.loop_root_hint,
    ask = self.opts.ask,
    input = self.opts.input,
    confirm = self.opts.confirm,
    sync_after_write = self.opts.sync_after_write,
    on_result = self.opts.on_action,
    notify = function(message)
      self:_notify(message)
    end,
  })
  return self.actions
end

function Board:_ensure_advanced()
  if self.advanced then
    return self.advanced
  end
  self.advanced = require("loop-kit.advanced").new({
    source = self.source,
    state = self.state,
    client = self.client,
    root = self.root,
    select = self.opts.select,
    ask = self.opts.ask,
    input = self.opts.input,
    notify = function(message)
      self:_notify(message)
    end,
  })
  return self.advanced
end

function Board:_ensure_decide()
  if self.decide then
    return self.decide
  end
  self.decide = require("loop-kit.decide").new({
    source = self.source,
    state = self.state,
    client = self.client,
    root = self.root,
  })
  return self.decide
end

function Board:_after(res)
  if self.closed then
    return
  end
  if res and res.ok == false and res.code ~= "cancelled" then
    self.load_error = res.message or "操作失败"
    self:_notify(res.message)
  end
  self:draw()
end

local function stage_prompts(task)
  local prompts = task and task.stagePrompt
  if type(prompts) ~= "table" then
    return {}
  end
  return prompts
end

local function stage_content(task, stage)
  return stage_prompts(task)[stage] or ""
end

--- Ask a multiple-choice question. Injected `edit_ask` keeps tests simple;
--- `form_ask` (boolean confirm) is accepted as a legacy alias.
function Board:_edit_ask(prompt, options, cb)
  if self.opts.edit_ask then
    return self.opts.edit_ask(prompt, options, cb)
  end
  if self.opts.form_ask then
    return self.opts.form_ask(prompt, function(confirmed)
      if confirmed then
        cb(options[1])
      else
        cb(nil)
      end
    end)
  end
  vim.ui.select(options, { prompt = prompt, format_item = tostring }, function(choice)
    cb(choice)
  end)
end

--- Prompt for one line. Injected `input` keeps the `_prompt_query` signature.
function Board:_edit_input(prompt, default, cb)
  if self.opts.edit_input then
    return self.opts.edit_input(prompt, default, cb)
  end
  if self.opts.input then
    return self.opts.input(prompt, cb)
  end
  vim.ui.input({ prompt = prompt, default = default }, cb)
end

function Board:_edit_focus_for(target)
  if target.kind == "title" then
    return { field = "title_line" }
  end
  if target.kind == "desc" then
    return { field = "desc" }
  end
  if target.kind == "user_prompt" then
    return { field = "userPrompt" }
  end
  if target.kind == "stage_content" or target.kind == "stage_rename" then
    return { field = "stagePrompt." .. tostring(target.stage) }
  end
  if target.kind == "touch"
    or target.kind == "tag"
    or target.kind == "deps"
    or target.kind == "doc"
    or target.kind == "docParent"
    or target.kind == "specPrompt"
    or target.kind == "researchPrompt"
    or target.kind == "codePrompt"
    or target.kind == "verifyPrompt"
    or target.kind == "docTaskSplitPrompt"
    or target.kind == "flow"
  then
    return { field = target.kind }
  end
  return nil
end

function Board:_focus_section(focus)
  if not focus or not self.detail or not self.detail.rendered then
    return
  end
  local line
  if focus.field == "title_line" then
    line = self.detail.rendered.title_line or self.detail.rendered.fields.title_line
  else
    line = self.detail.rendered.fields[focus.field]
  end
  if not line then
    return
  end
  if valid_win(self.detail_win) then
    pcall(vim.api.nvim_win_set_cursor, self.detail_win, { line, 0 })
    pcall(vim.api.nvim_set_current_win, self.detail_win)
  end
end

function Board:_edit_target()
  local task = self.state and self.state:selected()
  if not task then
    self:_notify("未选择任务")
    return nil
  end

  local win = vim.api.nvim_get_current_win()
  if win == self.list_win then
    return { kind = "desc" }, task
  end
  if win ~= self.detail_win then
    self:_notify("请在列表或详情窗内使用 e")
    return nil
  end
  if not self.detail or not self.detail.rendered then
    self:_notify("没有可编辑的详情内容")
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(self.detail_win)[1]
  return edit_ui.target_at(self.detail.rendered, line), task
end

function Board:_begin_edit(target, task, content, is_new)
  if self.editing then
    self:_notify("正在编辑，请先 :w 或 <Esc>")
    return
  end
  local ed = edit_ui.open({
    root = self.root,
    task = task,
    target = target,
    content = content or "",
    detail_buf = self.detail_buf,
    detail_win = self.detail_win,
    ask = function(prompt, options, cb)
      self:_edit_ask(prompt, options, cb)
    end,
    notify = function(message)
      self:_notify(message)
    end,
    on_save = function(text, cb)
      self:_save_edit(text, cb)
    end,
    on_close = function(reason)
      self:_after_edit_close(reason)
    end,
  })
  self.editing = {
    buf = ed.buf,
    handle = ed,
    target = target,
    task_id = task.id,
    is_new = is_new == true,
  }
  self._edit_focus = nil
  self.list:show_edit({
    id = task.id,
    title = task.title,
    target_label = edit_ui.target_label(target),
  })
  self:_update_winbar()
end

function Board:_after_edit_close(reason)
  local ed = self.editing
  self.editing = nil
  if self.list then
    self.list:clear_edit()
  end
  if ed then
    self:select(ed.task_id)
  end
  if reason == "saved" then
    local focus = self._edit_focus
    self._edit_focus = nil
    self:draw()
    self:_focus_section(focus)
    self:refresh({
      no_sync = true,
      after = function()
        self:_focus_section(focus)
      end,
    })
  else
    self._edit_focus = nil
    self:draw()
  end
end

function Board:_save_edit(text, cb)
  local ed = self.editing
  if not ed then
    cb(false, "编辑状态已结束")
    return
  end
  local target = ed.target
  local id = ed.task_id
  local function done(res)
    if res and res.ok then
      self._edit_focus = self:_edit_focus_for(target)
      cb(true)
    else
      cb(false, (res and res.message) or "保存失败")
    end
  end
  local actions = self:_ensure_actions()
  if target.kind == "desc" then
    actions:edit_desc(id, text, done)
  elseif target.kind == "user_prompt" then
    actions:edit_user_prompt(id, text, done)
  elseif target.kind == "stage_content" then
    actions:set_stage_prompt(id, target.stage, text, done)
  elseif target.kind == "touch" then
    local advanced = require("loop-kit.advanced")
    local paths = kv.touch_paths(vim.split(text, "\n", { plain = true }))
    for _, path in ipairs(paths) do
      local ok, err = advanced.valid_touch_path(path)
      if not ok then
        cb(false, err)
        return
      end
    end
    self:_ensure_advanced():set_touch(id, paths, done)
  else
    cb(false, "该目标不支持编辑")
  end
end

function Board:_edit_title(task)
  self:_edit_input("任务标题: ", task.title, function(value)
    if value == nil or self.closed then
      return
    end
    value = tostring(value)
    if value == "" then
      self:_notify("任务标题不允许为空")
      return
    end
    if value == task.title then
      return
    end
    self:_ensure_actions():edit_title(task.id, value, function(res)
      self:_after(res)
      if res and res.ok then
        self:select(task.id)
        self:draw()
        self:_focus_section({ field = "title_line" })
      end
    end)
  end)
end

function Board:_edit_stage_new(task)
  self:_edit_input("阶段名: ", "", function(value)
    if value == nil or self.closed then
      return
    end
    value = tostring(value)
    if value == "" then
      self:_notify("阶段名不能为空")
      return
    end
    if not edit_ui.is_valid_stage(value) then
      self:_notify("无效的阶段名：可用内建阶段 "
        .. table.concat(edit_ui.BUILTIN_STAGES, " / ")
        .. "，或包含 \".\" 且不含空白的外部名")
      return
    end
    local prompts = stage_prompts(task)
    if prompts[value] ~= nil then
      self:_edit_ask("该阶段已存在，是否直接编辑其内容？", { "编辑该阶段", "取消" }, function(choice)
        if choice ~= "编辑该阶段" then
          return
        end
        self:_begin_edit({ kind = "stage_content", stage = value }, task, stage_content(task, value), false)
      end)
      return
    end
    self:_begin_edit({ kind = "stage_content", stage = value }, task, "", true)
  end)
end

function Board:_edit_stage_rename(task, stage)
  local content = stage_content(task, stage)
  self:_edit_input("阶段名: ", stage, function(value)
    if value == nil or self.closed then
      return
    end
    value = tostring(value)
    if value == stage then
      return
    end
    if value == "" then
      self:_edit_ask("删除该阶段提示词条目？", { "删除", "取消" }, function(choice)
        if choice ~= "删除" then
          return
        end
        self:_ensure_actions():delete_stage_prompt(task.id, stage, function(res)
          self:_after(res)
          if res and res.ok then
            self:select(task.id)
            self:draw()
            self:_focus_section({ field = "stagePrompt" })
          end
        end)
      end)
      return
    end
    if stage_prompts(task)[value] ~= nil then
      self:_notify("已有同名条目，改名失败")
      return
    end
    if not edit_ui.is_valid_stage(value) then
      self:_notify("无效的阶段名：可用内建阶段 "
        .. table.concat(edit_ui.BUILTIN_STAGES, " / ")
        .. "，或包含 \".\" 且不含空白的外部名")
      return
    end
    self:_ensure_actions():rename_stage_prompt(task.id, stage, value, content, function(res)
      self:_after(res)
      if res and res.ok then
        self:select(task.id)
        self:draw()
        self:_focus_section({ field = "stagePrompt." .. value })
      end
    end)
  end)
end

local function same_set(left, right)
  left = left or {}
  right = right or {}
  if #left ~= #right then
    return false
  end
  local seen = {}
  for _, value in ipairs(left) do
    seen[value] = (seen[value] or 0) + 1
  end
  for _, value in ipairs(right) do
    if (seen[value] or 0) == 0 then
      return false
    end
    seen[value] = seen[value] - 1
  end
  return true
end

function Board:_edit_tag(task)
  local loop_root = self.config and self.config.loop_root_hint
  picker.select_one({
    items = kv.tag_values(loop_root),
    current = task.tag,
    prompt = "分类 tag",
    select = self.opts.select,
    on_choice = function(value)
      if value == nil or self.closed or value == task.tag then
        return
      end
      self:_ensure_advanced():set_tag(task.id, value, function(res)
        self:_after(res)
        if res and res.ok then
          self:select(task.id)
          self:draw()
          self:_focus_section({ field = "tag" })
        end
      end)
    end,
  })
end

function Board:_edit_deps(task)
  local tasks = (self.state and self.state.tasks) or {}
  local candidates = kv.dependency_candidates(tasks, task.id)
  local current = {}
  local current_list = {}
  for _, dep in ipairs(type(task.deps) == "table" and task.deps or {}) do
    local id = kv.normalize_id(dep) or tostring(dep)
    if not current[id] then
      current[id] = true
      current_list[#current_list + 1] = id
    end
  end

  local items = {}
  local kept = {}
  for _, candidate in ipairs(candidates.selectable) do
    kept[candidate.id] = true
    local label = candidate.id
    if candidate.status ~= nil and candidate.status ~= "" then
      label = label .. " " .. tostring(candidate.status)
    end
    if candidate.title ~= nil and candidate.title ~= "" then
      label = label .. " " .. tostring(candidate.title)
    end
    items[#items + 1] = {
      value = candidate.id,
      label = label,
      selected = current[candidate.id] == true,
    }
  end
  for _, id in ipairs(current_list) do
    if not kept[id] then
      items[#items + 1] = {
        value = id,
        label = id .. "（不在当前列表）",
        selected = true,
      }
    end
  end

  local multi = self.opts.multi or picker.multi
  multi({
    items = items,
    title = "依赖 · " .. tostring(task.id),
    hidden = candidates.hidden,
    on_confirm = function(values)
      if self.closed then
        return
      end
      if same_set(values, current_list) then
        return
      end
      self:_ensure_advanced():set_deps(task.id, values, function(res)
        self:_after(res)
        if res and res.ok then
          self:select(task.id)
          self:draw()
          self:_focus_section({ field = "deps" })
        end
      end)
    end,
  })
end

function Board:_edit_prompt(task, field)
  local current = task[field]
  if type(current) ~= "string" then
    current = ""
  end
  local labels = {
    doc = "实现文档路径: ",
    docParent = "父条目: ",
    specPrompt = "spec 提示词: ",
    researchPrompt = "调研提示词: ",
    codePrompt = "实现提示词: ",
    verifyPrompt = "验收提示词: ",
    docTaskSplitPrompt = "文档拆分提示词: ",
  }
  self:_edit_input(labels[field] or (field .. ": "), current, function(value)
    if value == nil or self.closed then
      return
    end
    value = tostring(value)
    if value == current then
      return
    end
    local advanced = self:_ensure_advanced()
    local function done(res)
      self:_after(res)
      if res and res.ok then
        self:select(task.id)
        self:draw()
        self:_focus_section({ field = field })
      end
    end
    if field == "doc" then
      advanced:set_doc(task.id, value, done)
    else
      advanced:set_prompt(task.id, field, value, done)
    end
  end)
end

function Board:_edit_flow(task)
  local advanced = self:_ensure_advanced()
  advanced:list_flows(function(flows)
    if self.closed then
      return
    end
    if not flows then
      -- The flow list is best-effort: fall back to the builtin names.
      flows = { builtin = vim.deepcopy(require("loop-kit.advanced").FLOWS), custom = {} }
      self:_notify("读取流程列表失败，使用内置流程")
    end
    local adv = require("loop-kit.advanced")
    local items = adv.flow_items(flows)
    items[#items + 1] = adv.CUSTOM_FLOW
    items[#items + 1] = adv.CLEAR_FLOW
    picker.select_one({
      items = items,
      current = task.flow,
      prompt = "流程",
      select = self.opts.select,
      on_choice = function(choice)
        if choice == nil or self.closed then
          return
        end
        local function done(res)
          self:_after(res)
          if res and res.ok then
            self:select(task.id)
            self:draw()
            self:_focus_section({ field = "flow" })
          end
        end
        if choice == adv.CLEAR_FLOW then
          return advanced:set_flow(task.id, "", done)
        end
        if choice == adv.CUSTOM_FLOW then
          return self:_edit_input("stage 列表（逗号分隔，必须以 commit 收尾）：", "", function(raw)
            if raw == nil or self.closed then
              return
            end
            local stages = adv.split_stages(raw)
            local ok, value = adv.validate_stages(stages)
            if not ok then
              self:_notify(value)
              return
            end
            advanced:set_flow(task.id, table.concat(value, ","), done)
          end)
        end
        if choice == task.flow then
          return
        end
        advanced:set_flow(task.id, choice, done)
      end,
    })
  end)
end

function Board:_edit_touch(task)
  local paths = type(task.touch) == "table" and task.touch or {}
  local content = {}
  for _, path in ipairs(paths) do
    content[#content + 1] = tostring(path)
  end
  self:_begin_edit({ kind = "touch" }, task, table.concat(content, "\n"), false)
end

function Board:_start_edit()
  if self.closed then
    return
  end
  if self.editing then
    self:_notify("正在编辑，请先 :w 或 <Esc>")
    return
  end
  local target, task = self:_edit_target()
  if not target then
    return
  end
  if target.kind == "readonly" then
    self:_notify(target.message or "该行暂不支持编辑")
    return
  end
  if target.kind == "title" then
    return self:_edit_title(task)
  end
  if target.kind == "tag" then
    return self:_edit_tag(task)
  end
  if target.kind == "deps" then
    return self:_edit_deps(task)
  end
  if target.kind == "flow" then
    return self:_edit_flow(task)
  end
  if target.kind == "touch" then
    return self:_edit_touch(task)
  end
  if target.kind == "doc"
    or target.kind == "docParent"
    or target.kind == "specPrompt"
    or target.kind == "researchPrompt"
    or target.kind == "codePrompt"
    or target.kind == "verifyPrompt"
    or target.kind == "docTaskSplitPrompt"
  then
    return self:_edit_prompt(task, target.kind)
  end
  if target.kind == "stage_new" then
    return self:_edit_stage_new(task)
  end
  if target.kind == "stage_rename" then
    return self:_edit_stage_rename(task, target.stage)
  end
  if target.kind == "desc" then
    return self:_begin_edit(target, task, task.desc or "", false)
  end
  if target.kind == "user_prompt" then
    return self:_begin_edit(target, task, task.userPrompt or "", false)
  end
  if target.kind == "stage_content" then
    return self:_begin_edit(target, task, stage_content(task, target.stage), false)
  end
  self:_notify("该行暂不支持编辑")
end

function Board:_add_task()
  self:_edit_input("新任务标题: ", "", function(title)
    if title == nil or self.closed then
      return
    end
    title = tostring(title)
    if title == "" then
      self:_notify("任务标题不允许为空")
      return
    end
    self:_edit_input("分类 tag: ", "feature", function(tag)
      if tag == nil or self.closed then
        return
      end
      tag = tostring(tag)
      if tag == "" then
        self:_notify("分类 tag 不能为空")
        return
      end
      local loop_root = self.config and self.config.loop_root_hint
      if not edit_ui.valid_tag(self.root, tag, loop_root) then
        self:_notify("分类 tag 无效：" .. tag .. "；可选 " .. table.concat(edit_ui.tag_list(self.root, loop_root), " / "))
        return
      end
      self:_ensure_actions():add_task(title, tag, function(res)
        if not res or not res.ok then
          self:_after(res)
          return
        end
        if res.task and res.task.id then
          self:select(res.task.id)
        end
        self:draw()
      end)
    end)
  end)
end

function Board:_open_doc()
  local task = self.state and self.state:selected()
  if not task then
    self:_notify("未选择任务")
    return
  end
  self.detail:open_doc(task)
end

function Board:_decide_now()
  self:_ensure_decide():run(function(view)
    if self.closed then
      return
    end
    if not view or view.ok == false then
      self:_notify((view and view.message) or "decide 失败")
      return
    end
    if view.action == "next" and view.id then
      self:select(view.id)
      self:_notify((view.message or "") .. "（已选择 " .. view.id .. "）")
    else
      self:_notify(view.message or ("decide: " .. tostring(view.action)))
    end
  end)
end

local ACTIONS = {
  move_down = function(self)
    self.list:move(1)
  end,
  move_up = function(self)
    self.list:move(-1)
  end,
  open_detail = function(self)
    if valid_win(self.detail_win) then
      pcall(vim.api.nvim_set_current_win, self.detail_win)
    end
  end,
  filter_prompt = function(self)
    self:_prompt_query()
  end,
  clear_query = function(self)
    self:set_query("")
  end,
  cycle_filter = function(self)
    local current = self.state.filter or "open"
    local index = 1
    for i, value in ipairs(FILTER_ORDER) do
      if value == current then
        index = i
        break
      end
    end
    self:set_filter(FILTER_ORDER[(index % #FILTER_ORDER) + 1])
  end,
  filter_all = function(self)
    self:set_filter("all")
  end,
  cycle_sort = function(self)
    local order = require("loop-kit.state").SORT_MODES
    local current = self.state.sort or "id_desc"
    local index = 0
    for i, value in ipairs(order) do
      if value == current then
        index = i
        break
      end
    end
    self:set_sort(order[(index % #order) + 1])
  end,
  refresh = function(self)
    self:refresh({ no_sync = true })
  end,
  sync = function(self)
    self:sync()
  end,
  claim = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_actions():claim(id, function(res)
        self:_after(res)
      end)
    end
  end,
  done = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_actions():done(id, {}, function(res)
        self:_after(res)
      end)
    end
  end,
  force_done = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_actions():force_done(id, function(res)
        self:_after(res)
      end)
    end
  end,
  block = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_actions():block(id, function(res)
        self:_after(res)
      end)
    end
  end,
  remove = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_actions():remove(id, {}, function(res)
        self:_after(res)
      end)
    end
  end,
  edit = function(self)
    self:_start_edit()
  end,
  add = function(self)
    self:_add_task()
  end,
  open_doc = function(self)
    self:_open_doc()
  end,
  flow = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_advanced():flow(id, function(res)
        self:_after(res)
      end)
    end
  end,
  private = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_advanced():private(id, function(res)
        self:_after(res)
      end)
    end
  end,
  touch = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_advanced():touch(id, function(res)
        self:_after(res)
      end)
    end
  end,
  meta = function(self)
    local id = self:_selected_id()
    if id then
      self:_ensure_advanced():meta(id, function(res)
        self:_after(res)
      end)
    end
  end,
  decide = function(self)
    self:_decide_now()
  end,
  help = function(self)
    self:toggle_help()
  end,
  close = function(self)
    self:close()
  end,
}

--- Run an action name ("refresh", "close", ...) or a bound key ("q", "j").
function Board:handle(action)
  if self.closed or action == nil or action == false then
    return
  end
  if type(action) == "function" then
    return action(self)
  end

  local name = action
  if ACTIONS[name] == nil then
    local mapped = self.keys[name]
    if mapped == false or mapped == nil then
      return
    end
    name = mapped
  end

  if type(name) == "function" then
    return name(self, action)
  end

  if self.editing then
    if name == "help" then
      return ACTIONS.help(self)
    end
    if name == "close" then
      return self.editing.handle:request_close()
    end
    self:_notify("正在编辑，请先 :w 或 <Esc>")
    return
  end

  local handler = ACTIONS[name]
  if handler then
    return handler(self)
  end
end

--- Open (or focus) the board for a project.
--- opts: root/project_root, client, source, state, config, keys, list_width,
---       default_filter, auto_sync, auto_refresh, icons, notify, ask, input,
---       confirm, select, open_doc, edit_ask, edit_input, form_ask (legacy).
--- Returns board, created (false when an existing board was focused).
function M.open(opts)
  opts = opts or {}
  local root = util.normalize_root(opts.root or opts.project_root or vim.fn.getcwd())
  assert(root, "loop-kit.ui.board: root is required")

  local existing = active[root]
  if existing and existing:is_open() then
    existing:focus()
    return existing, false
  end

  next_id = next_id + 1
  local self = setmetatable({}, Board)
  self.id = next_id
  self.root = root
  self.opts = opts
  self.closed = false
  self._request = 0
  self.loaded = false
  self.loading = false
  self.syncing = false
  self.load_error = nil
  self.editing = nil
  self.keys = merge_keys(DEFAULT_KEYS, M.config.keys, opts.keys)
  self.provider = opts.provider

  self:_ensure_deps()
  self:_create_ui()
  self:_bind_keys()
  self:_register_autocmds()

  active[root] = self
  self:draw()

  if self.source and opts.auto_refresh ~= false then
    local auto_sync = opts.auto_sync
    if auto_sync == nil then
      auto_sync = M.config.auto_sync
    end
    if auto_sync then
      -- Render the cache first, then let a full sync land in the background.
      self:refresh({ no_sync = true, then_sync = true })
    else
      self:refresh({ no_sync = true })
    end
  end

  return self, true
end

return M
