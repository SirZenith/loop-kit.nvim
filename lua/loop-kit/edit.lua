-- Field-level editing: turns the detail window into a single-target acwrite
-- buffer. This module owns buffer lifecycle only; Board owns the edit state
-- machine and Actions owns the loop-cli calls.
local M = {}

local kv = require("loop-kit.kv")
local path_complete = require("loop-kit.path_complete")

local BUILTIN_STAGES = {
  "research",
  "spec",
  "json-task-split",
  "doc-task-split",
  "decision-question",
  "impl",
  "verify",
  "commit",
}

local BUILTIN = {}
for _, name in ipairs(BUILTIN_STAGES) do
  BUILTIN[name] = true
end

M.BUILTIN_STAGES = BUILTIN_STAGES

-- Key/value fields that open their own editor.
local KV_FIELDS = {
  "tag",
  "deps",
  "doc",
  "docParent",
  "specPrompt",
  "researchPrompt",
  "codePrompt",
  "verifyPrompt",
  "docTaskSplitPrompt",
  "flow",
  "isPrivateDesc",
}

M.KV_FIELDS = KV_FIELDS

-- Fields that render as anchors but are not editable in this feature.
local READONLY_FIELDS = {
  {
    name = "id",
    message = "任务 id 不可编辑",
  },
  {
    name = "status",
    message = "状态由 c / d / b 修改",
  },
  {
    name = "origin",
    message = "来源由 origin:* 标签维护",
  },
  {
    name = "openAt",
    message = "开始时间由生命周期维护",
  },
  {
    name = "closedAt",
    message = "结束时间由生命周期维护",
  },
  {
    name = "hash",
    message = "提交由 done --hash 维护",
  },
  {
    name = "blockedReason",
    message = "阻塞原因不可直接编辑，请按 b 重新设置",
  },
  {
    name = "blockedReason_content",
    message = "阻塞原因不可直接编辑，请按 b 重新设置",
  },
  {
    name = "meta",
    message = "该行暂不支持编辑",
  },
  {
    name = "decide",
    message = "该行暂不支持编辑",
  },
  {
    name = "analysis",
    message = "该行暂不支持编辑",
  },
  {
    name = "outstanding",
    message = "该行暂不支持编辑",
  },
  {
    name = "eligible",
    message = "该行暂不支持编辑",
  },
  {
    name = "blocked",
    message = "该行暂不支持编辑",
  },
  {
    name = "stuck",
    message = "该行暂不支持编辑",
  },
}

local DEFAULT_READONLY_MESSAGE = "该行暂不支持编辑"

local LABELS = {
  title = "任务标题",
  desc = "任务描述",
  user_prompt = "用户提示词",
  stage_new = "新建阶段提示词",
  tag = "任务分类",
  deps = "依赖",
  doc = "实现文档",
  docParent = "父条目",
  specPrompt = "spec 提示词",
  researchPrompt = "调研提示词",
  codePrompt = "实现提示词",
  verifyPrompt = "验收提示词",
  docTaskSplitPrompt = "文档拆分提示词",
  flow = "流程",
  isPrivateDesc = "不可外发标记",
  touch = "写集",
}

--- Whether `name` is a valid stage key (builtin or dotted external name).
function M.is_valid_stage(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  if name:find("%s") then
    return false
  end
  return BUILTIN[name] == true or name:find(".", 1, true) ~= nil
end

M.DEFAULT_TAGS = vim.deepcopy(kv.FALLBACK_TAGS)

local tag_cache = {}

local function read_json(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function loop_root_dir(root, hint)
  if type(hint) == "string" and hint ~= "" then
    return hint
  end
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local cfg = read_json(root .. "/loop.config.json")
  local rel = cfg and cfg.loopRoot
  if type(rel) == "string" and rel ~= "" then
    if rel:sub(1, 1) == "/" then
      return rel
    end
    return root .. "/" .. rel
  end
  return root .. "/.pi/loop-kit"
end

local function file_stamp(path)
  if type(path) ~= "string" then
    return "missing"
  end
  local stat = vim.uv and vim.uv.fs_stat and vim.uv.fs_stat(path) or nil
  if not stat then
    return "missing"
  end
  return tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec)
end

--- Effective tag candidates: explicit `loop.config.json` `tags`, then
--- `<loopRoot>/TARGETS.md`, then the builtins. The cache key is the config
--- path and its stamp covers both files, so editing either one takes effect
--- immediately.
function M.tag_list(root, loop_root_hint)
  local dir = loop_root_dir(root, loop_root_hint)
  local cfg_path = (type(root) == "string" and root ~= "") and (root .. "/loop.config.json") or nil
  local targets_path = dir and (dir .. "/TARGETS.md") or nil
  if not cfg_path and not dir then
    return M.DEFAULT_TAGS
  end

  local stamp = file_stamp(cfg_path) .. "|" .. file_stamp(targets_path)
  local key = tostring(cfg_path or targets_path) .. "|" .. tostring(dir)
  local cached = tag_cache[key]
  if cached and cached.stamp == stamp then
    return cached.tags
  end

  local tags = cfg_path and kv.config_tags(cfg_path) or nil
  if not tags then
    tags = kv.tag_values(dir)
  end
  tag_cache[key] = { stamp = stamp, tags = tags }
  return tags
end

--- Whether `tag` belongs to the project's configured tag set.
function M.valid_tag(root, tag, loop_root_hint)
  if type(tag) ~= "string" or tag == "" then
    return false
  end
  for _, candidate in ipairs(M.tag_list(root, loop_root_hint)) do
    if candidate == tag then
      return true
    end
  end
  return false
end

--- Human readable label for an edit target.
function M.target_label(target)
  if type(target) ~= "table" then
    return ""
  end
  if target.kind == "stage_rename" then
    return "阶段名 · " .. tostring(target.stage)
  end
  if target.kind == "stage_content" then
    return "阶段提示词 · " .. tostring(target.stage)
  end
  return LABELS[target.kind] or tostring(target.kind or "")
end

--- Map a detail render result + cursor line to an edit target.
-- Returns nil when there is no render (nothing to edit), otherwise a target
-- table. `{ kind = "readonly" }` means the line is known but not editable.
function M.target_at(rendered, line)
  if type(rendered) ~= "table" or type(rendered.fields) ~= "table" then
    return nil
  end
  if type(line) ~= "number" then
    return nil
  end
  local fields = rendered.fields
  local anchors = {}
  local function add(ln, target)
    if type(ln) == "number" then
      anchors[#anchors + 1] = { line = ln, target = target }
    end
  end

  add(rendered.title_line or fields.title_line, { kind = "title" })
  for _, name in ipairs(KV_FIELDS) do
    add(fields[name], { kind = name })
  end
  add(fields.touch, { kind = "touch" })
  for _, spec in ipairs(READONLY_FIELDS) do
    add(fields[spec.name], { kind = "readonly", message = spec.message })
  end
  add(fields.desc, { kind = "desc" })
  add(fields.desc_content, { kind = "desc" })
  add(fields.userPrompt, { kind = "user_prompt" })
  add(fields.userPrompt_content, { kind = "user_prompt" })
  add(fields.stagePrompt, { kind = "stage_new" })
  add(fields.stagePrompt_content, { kind = "stage_new" })

  for field, ln in pairs(fields) do
    if field:match("^stagePrompt%.") and field ~= "stagePrompt_content" then
      local stage = field:match("^stagePrompt%.(.+)%.content$")
      if stage then
        add(ln, { kind = "stage_content", stage = stage })
      else
        stage = field:match("^stagePrompt%.(.+)$")
        if stage then
          add(ln, { kind = "stage_rename", stage = stage })
        end
      end
    end
  end

  table.sort(anchors, function(a, b)
    return a.line < b.line
  end)

  local chosen = nil
  for _, anchor in ipairs(anchors) do
    if anchor.line <= line then
      chosen = anchor
    else
      break
    end
  end
  if not chosen then
    return { kind = "readonly", message = DEFAULT_READONLY_MESSAGE }
  end

  local target = chosen.target
  if target.kind == "stage_rename" then
    if line == chosen.line then
      return { kind = "stage_rename", stage = target.stage }
    end
    return { kind = "stage_content", stage = target.stage }
  end
  if target.kind == "stage_content" then
    return { kind = "stage_content", stage = target.stage }
  end
  return { kind = target.kind, message = target.message }
end

local function encode_id(id)
  return tostring(id or ""):gsub("#", "%%23")
end

local function target_slug(target)
  if target.kind == "stage_rename" or target.kind == "stage_content" then
    return target.kind .. "/" .. tostring(target.stage)
  end
  return tostring(target.kind)
end

local function split_lines(text)
  if text == nil or text == "" then
    return { "" }
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function default_ask(prompt, options, cb, ask_opts)
  require("loop-kit.ui.confirm").choice(prompt, options, cb, ask_opts)
end

-- Open editors keyed by buffer name, so re-entering the same target focuses
-- the existing buffer.
local registry = {}

--- Open an acwrite buffer for `opts.target` in the detail window.
-- opts = { root, task, target, content, detail_buf, detail_win, ask, notify,
--          on_save(text, cb), on_close(reason) }
function M.open(opts)
  opts = opts or {}
  local root = opts.root or ""
  local task = opts.task or {}
  local target = opts.target or { kind = "desc" }
  local name = "loopkit://"
    .. root
    .. "/edit/"
    .. encode_id(task.id)
    .. "/"
    .. target_slug(target)

  local existing = registry[name]
  if existing and not existing.closed and valid_buf(existing.buf) then
    if valid_win(opts.detail_win) then
      pcall(vim.api.nvim_win_set_buf, opts.detail_win, existing.buf)
      pcall(vim.api.nvim_set_current_win, opts.detail_win)
    end
    return existing
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, split_lines(opts.content))
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if target.kind == "touch" then
    path_complete.attach_omnifunc(buf, root, {
      allow_absolute = false,
      allow_parent = true,
      normalize_parent = true,
    })
  end

  if valid_win(opts.detail_win) then
    pcall(vim.api.nvim_win_set_buf, opts.detail_win, buf)
    pcall(vim.api.nvim_set_current_win, opts.detail_win)
  end

  local ed = {
    buf = buf,
    name = name,
    target = target,
    task = task,
    saving = false,
    closed = false,
  }

  local function done(success, err)
    ed.saving = false
    if ed.closed then
      return
    end
    if success then
      pcall(function()
        vim.bo[buf].modified = false
      end)
      ed:close("saved")
      return
    end
    if opts.notify then
      opts.notify(err or "保存失败")
    end
  end

  function ed:is_dirty()
    if not valid_buf(self.buf) then
      return false
    end
    return vim.bo[self.buf].modified == true
  end

  function ed:save()
    if self.closed or self.saving then
      return
    end
    self.saving = true
    local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    local called = false
    local function cb(success, err)
      if called then
        return
      end
      called = true
      done(success, err)
    end
    local ok, err = pcall(opts.on_save, text, cb)
    if not ok then
      cb(false, "保存失败：" .. tostring(err))
    end
  end

  function ed:close(reason)
    if self.closed then
      return
    end
    self.closed = true
    registry[name] = nil
    -- Discarding may close a dirty buffer while 'hidden' is off; clear the
    -- flag first so switching back to the detail buffer cannot raise E37.
    if valid_buf(self.buf) then
      pcall(function()
        vim.bo[self.buf].modified = false
      end)
    end
    if valid_win(opts.detail_win) and valid_buf(opts.detail_buf) then
      local ok, current = pcall(vim.api.nvim_win_get_buf, opts.detail_win)
      if ok and current == self.buf then
        pcall(vim.api.nvim_win_set_buf, opts.detail_win, opts.detail_buf)
      end
    end
    if valid_buf(self.buf) then
      pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    end
    if opts.on_close then
      opts.on_close(reason)
    end
  end

  function ed:request_close()
    if self.closed or self.saving then
      return
    end
    if not self:is_dirty() then
      self:close("discard")
      return
    end
    local ask = opts.ask or default_ask
    ask("放弃未保存的修改？", { "放弃修改", "继续编辑" }, function(choice)
      if choice == "放弃修改" then
        self:close("discard")
      end
    end, { default = 2 })
  end

  registry[name] = ed

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      ed:save()
    end,
    desc = "loop-kit: save field edit",
  })
  vim.keymap.set("n", "<Esc>", function()
    ed:request_close()
  end, { buffer = buf, nowait = true, silent = true, desc = "loop-kit: 放弃编辑" })
  vim.keymap.set("n", "<C-c>", function()
    ed:request_close()
  end, { buffer = buf, nowait = true, silent = true, desc = "loop-kit: 放弃编辑" })

  return ed
end

return M
