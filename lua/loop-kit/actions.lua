-- Task mutations (claim/done/force-done/block/remove) plus the per-project
-- serial write queue.
--
-- Every write goes through loop-cli with an explicit --project-root and --json.
-- Writes for one project are queued through `state:enqueue`, so at most one
-- write process runs at a time and later requests run FIFO.
--
-- Successful writes apply the returned Task to the in-memory snapshot and then
-- re-read the list (cache only) to refresh `analysis`. Failures leave the
-- snapshot, filter, query and selection untouched.
local util = require("loop-kit.util")

local M = {}

local noop = function() end

local function default_ask(prompt, cb, opts)
  require("loop-kit.ui.confirm").boolean(prompt, cb, opts)
end

local function default_input(prompt, cb)
  vim.ui.input({ prompt = prompt }, function(value)
    cb(value)
  end)
end

local DEFAULT_CONFIRM = {
  done = true,
  force_done = true,
  block = true,
  remove = true,
}

local Actions = {}
Actions.__index = Actions

--- Create an action controller for one project.
--- opts:
---   client, source, state (required), root
---   ask(prompt, cb)     confirmation UI, cb(boolean)
---   input(prompt, cb)   text input UI, cb(string|nil)
---   confirm = { done, force_done, block, remove } booleans
---   exec(command, args, opts, cb)  injectable CLI runner; defaults to client:run
---   reload(cb)          list refresh; defaults to source:list({ no_sync = true })
---   sync_after_write    background full sync for remote sources (default true)
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Actions)
  self.source = opts.source
  self.state = assert(opts.state, "loop-kit.actions: state is required")
  self.client = opts.client or (self.source and self.source.client)
  self.root = opts.root or (self.client and self.client.project_root)
  self.loop_root = opts.loop_root
  if self.client and self.root and (not self.client.project_root or self.client.project_root == "") then
    self.client.project_root = self.root
  end
  self.ask = opts.ask or default_ask
  self.input = opts.input or default_input
  self.notify = opts.notify or noop
  self.confirm = vim.tbl_extend("force", DEFAULT_CONFIRM, opts.confirm or {})
  self.sync_after_write = opts.sync_after_write ~= false
  self.on_result = opts.on_result
  self.exec = opts.exec or function(command, args, run_opts, cb)
    assert(self.client, "loop-kit.actions: client or exec is required")
    return self.client:run(command, args, run_opts, cb)
  end
  self.reload = opts.reload or function(cb)
    if not self.source then
      cb(nil)
      return
    end
    self.source:list({ no_sync = true }, cb)
  end
  return self
end

function Actions:_settle(res, cb)
  if type(self.on_result) == "function" and type(res) == "table" then
    pcall(self.on_result, res)
  end
  if cb then
    cb(res)
  end
end

function Actions:_invalid(action, id, message)
  return {
    ok = false,
    action = action,
    id = id,
    code = "invalid",
    kind = "usage",
    message = message or "任务 id 不合法",
  }
end

function Actions:_source_kind()
  local snapshot = self.source and self.source.snapshot
  local source = snapshot and snapshot.source
  if type(source) == "table" and type(source.kind) == "string" then
    return source.kind
  end
  return nil
end

local function remove_prompt(id, kind)
  if kind == "local" then
    return string.format("永久删除任务 %s 并清理其他任务对它的依赖引用？", id)
  end
  if kind ~= nil then
    return string.format("将任务 %s 移出循环（摘除 loop:todo 准入标签，保留远端 issue）？", id)
  end
  return string.format(
    "删除或移出任务 %s？local 会永久删除并清理依赖引用，远端只移出循环并保留 issue。",
    id
  )
end

local function task_from_response(data)
  if type(data) ~= "table" then
    return nil
  end
  if type(data.id) == "string" then
    return data
  end
  if type(data.task) == "table" and type(data.task.id) == "string" then
    return data.task
  end
  return nil
end

--- Apply a returned Task to the in-memory list without dropping unknown fields.
function Actions:_merge_task(task)
  local tasks = util.deepcopy(self.state.tasks)
  for index, existing in ipairs(tasks) do
    if existing.id == task.id then
      tasks[index] = vim.tbl_extend("force", existing, task)
      self.state:set_tasks(tasks)
      return
    end
  end
  tasks[#tasks + 1] = util.deepcopy(task)
  self.state:set_tasks(tasks)
end

function Actions:_drop_task(id)
  local tasks = util.deepcopy(self.state.tasks)
  for index = #tasks, 1, -1 do
    if tasks[index].id == id then
      table.remove(tasks, index)
    end
  end
  self.state:set_tasks(tasks)
end

--- Neighbouring visible id used after a deletion.
function Actions:_neighbour(id)
  local ids = {}
  for _, task in ipairs(self.state:visible_tasks()) do
    ids[#ids + 1] = task.id
  end
  for index, visible in ipairs(ids) do
    if visible == id then
      return ids[index + 1] or ids[index - 1]
    end
  end
  return nil
end

function Actions:_unfinished_deps(id)
  local found = nil
  for _, task in ipairs(self.state.tasks) do
    if task.id == id then
      found = task
      break
    end
  end
  if not found or type(found.deps) ~= "table" then
    return {}
  end

  local status = {}
  for _, task in ipairs(self.state.tasks) do
    status[task.id] = task.status
  end

  local out = {}
  for _, dep in ipairs(found.deps) do
    local dep_id = util.normalize_id(type(dep) == "string" and dep or nil)
    if dep_id and status[dep_id] ~= "done" then
      out[#out + 1] = dep_id
    end
  end
  return out
end

local CONFLICT_HINTS = { "updatedAt", "conflict", "concurrent", "冲突", "并发" }

local function looks_like_conflict(message)
  if type(message) ~= "string" then
    return false
  end
  for _, hint in ipairs(CONFLICT_HINTS) do
    if message:find(hint, 1, true) then
      return true
    end
  end
  return false
end

function Actions:_failure(action, id, res, extra)
  res = res or {}
  extra = extra or {}
  local out = {
    ok = false,
    action = action,
    id = id,
    code = res.code or "exit",
    kind = res.kind,
    exit_code = res.exit_code,
    message = res.message or "写操作失败",
    error = res,
  }

  if res.exit_code == 4 then
    local message = tostring(res.message or "")
    if action == "done" and not extra.force then
      local deps = self:_unfinished_deps(id)
      if #deps > 0 then
        out.code = "rejected"
        out.rejected = "deps"
        out.deps = deps
        out.message = out.message .. "\n未完成依赖：" .. table.concat(deps, ", ")
      elseif looks_like_conflict(message) then
        out.code = "conflict"
        out.conflict = true
        out.message = out.message .. "\n远端任务已更新：请同步后人工核对，不会自动重试。"
      else
        out.code = "rejected"
        out.rejected = "gate"
      end
    elseif looks_like_conflict(message) then
      out.code = "conflict"
      out.conflict = true
      out.message = out.message .. "\n远端任务已更新：请同步后人工核对，不会自动重试。"
    end
  end

  return out
end

--- Refresh the list after a write. The returned Task is re-applied last so a
--- stale cached list cannot drop the successful response.
function Actions:_refresh(action, id, task, neighbour, cb)
  if not self.source then
    if action == "remove" then
      self.state:refresh()
      if neighbour then
        self.state:select(neighbour)
      end
    end
    cb(nil)
    return
  end

  self.reload(function(res)
    if res and res.ok and type(res.tasks) == "table" then
      local tasks = util.deepcopy(res.tasks)
      if action == "remove" then
        for index = #tasks, 1, -1 do
          if tasks[index].id == id then
            table.remove(tasks, index)
          end
        end
      end
      if task and task.id then
        local merged = false
        for index, existing in ipairs(tasks) do
          if existing.id == task.id then
            tasks[index] = vim.tbl_extend("force", existing, task)
            merged = true
            break
          end
        end
        if not merged then
          tasks[#tasks + 1] = util.deepcopy(task)
        end
      end
      self.state:set_tasks(tasks)
    end

    if action == "remove" then
      self.state:refresh()
      if neighbour then
        self.state:select(neighbour)
      end
    end
    cb(res)
  end)
end

function Actions:_maybe_sync()
  if not self.sync_after_write or not self.source or not self.source.sync then
    return
  end
  local kind = self:_source_kind()
  if kind and kind ~= "local" then
    self.source:sync(noop)
  end
end

function Actions:_submit(action, id, command, args, extra, cb)
  self.state:enqueue(function(finish)
    local finished = false
    local function done(result)
      if finished then
        return
      end
      finished = true
      local ok, err = pcall(cb, result)
      finish()
      if not ok then
        error(err, 0)
      end
    end

    local run_opts = {}
    if type(extra) == "table" and extra.stdin ~= nil then
      run_opts.stdin = extra.stdin
    end
    local ok, err = pcall(self.exec, command, args, run_opts, function(res)
      if finished then
        return
      end
      if not res or not res.ok then
        done(self:_failure(action, id, res, extra))
        return
      end

      local task = task_from_response(res.data)
      if action == "remove" then
        local neighbour = self:_neighbour(id)
        self:_drop_task(id)
        self:_refresh(action, id, nil, neighbour, function(list_res)
          self:_maybe_sync()
          done({
            ok = true,
            action = action,
            id = id,
            task = task,
            removed = true,
            selected = self.state:selected_id(),
            snapshot = self.source and self.source.snapshot or nil,
            response = res,
            list = list_res,
          })
        end)
        return
      end

      if task then
        self:_merge_task(task)
      end
      self:_refresh(action, id, task, nil, function(list_res)
        self:_maybe_sync()
        done({
          ok = true,
          action = action,
          id = id,
          task = task or (self.state:selected()),
          selected = self.state:selected_id(),
          snapshot = self.source and self.source.snapshot or nil,
          response = res,
          list = list_res,
        })
      end)
    end)

    if not ok then
      done({
        ok = false,
        action = action,
        id = id,
        code = "spawn",
        kind = "unknown",
        message = "无法启动 loop-cli：" .. tostring(err),
      })
    end
  end)
end

function Actions:claim(id, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("claim", id), cb)
    return
  end
  self:_submit("claim", id, "claim", { id }, {}, function(res)
    self:_settle(res, cb)
  end)
end

--- Complete a task. `opts.force = true` (or `force_done`) adds --force; done
--- never forces on its own when the dependency gate rejects it.
function Actions:done(id, opts, cb)
  if type(opts) == "function" then
    opts, cb = {}, opts
  end
  opts = opts or {}
  cb = cb or noop
  local force = opts.force == true
  local action = force and "force_done" or "done"
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid(action, id), cb)
    return
  end

  local function start()
    local args = { id }
    if force then
      args[#args + 1] = "--force"
    end
    self:_submit(action, id, "done", args, { force = force }, function(res)
      self:_settle(res, cb)
    end)
  end

  if self.confirm[action] then
    local prompt
    if force then
      prompt = string.format("强制完成任务 %s（忽略未完成依赖与门禁）？", id)
    else
      prompt = string.format("完成任务 %s？", id)
    end
    self.ask(prompt, function(confirmed)
      if confirmed then
        start()
        return
      end
      self:_settle({ ok = false, action = action, id = id, code = "cancelled", message = "已取消" }, cb)
    end)
    return
  end

  start()
end

function Actions:force_done(id, cb)
  return self:done(id, { force = true }, cb)
end

--- Block a task with a non-empty reason; an empty input cancels.
function Actions:block(id, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("block", id), cb)
    return
  end

  self.input(string.format("阻塞 %s 的原因：", id), function(value)
    local reason = util.trim(value)
    if not reason or reason == "" then
      self:_settle({
        ok = false,
        action = "block",
        id = id,
        code = "cancelled",
        message = "已取消：阻塞原因不能为空",
      }, cb)
      return
    end
    self:_submit("block", id, "block", { id, "--reason", reason }, { reason = reason }, function(res)
      self:_settle(res, cb)
    end)
  end)
end

--- Move a blocked task back to pending (blocked → pending).
function Actions:unblock(id, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("unblock", id), cb)
    return
  end

  local task = nil
  for _, item in ipairs(self.state.tasks) do
    if item.id == id then
      task = item
      break
    end
  end
  if not task then
    self:_settle(self:_invalid("unblock", id, "未找到任务 " .. id), cb)
    return
  end
  if task.status ~= "blocked" then
    self:_settle(self:_invalid("unblock", id,
      string.format("条目 %s 当前状态是 %s，不是 blocked", id, tostring(task.status))), cb)
    return
  end

  self:_submit("unblock", id, "edit", { id, "--status", "pending" }, {}, function(res)
    self:_settle(res, cb)
  end)
end

--- Remove a local task or move a remote task out of the loop. Always asks
--- first, with wording that matches the source kind.
function Actions:remove(id, opts, cb)
  if type(opts) == "function" then
    opts, cb = {}, opts
  end
  opts = opts or {}
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("remove", id), cb)
    return
  end

  local function start()
    self:_submit("remove", id, "remove", { id }, { source_kind = self:_source_kind() }, function(res)
      self:_settle(res, cb)
    end)
  end

  if not self.confirm.remove then
    start()
    return
  end

  self.ask(remove_prompt(id, self:_source_kind()), function(confirmed)
    if confirmed then
      start()
      return
    end
    self:_settle({ ok = false, action = "remove", id = id, code = "cancelled", message = "已取消" }, cb)
  end, { default = 2 })
end

local function normalize_text(text)
  if text == nil then
    return ""
  end
  return tostring(text)
end

--- Rename a task through a single-line edit.
function Actions:edit_title(id, title, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("edit", id), cb)
    return
  end
  if type(title) ~= "string" or title == "" then
    self:_settle(self:_invalid("edit", id, "任务标题不允许为空"), cb)
    return
  end
  self:_submit("edit", id, "edit", { id, "--title", title }, {}, function(res)
    self:_settle(res, cb)
  end)
end

--- Replace the task description through stdin.
function Actions:edit_desc(id, text, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("edit", id), cb)
    return
  end
  self:_submit("edit", id, "edit", { id, "--desc-file", "-" }, { stdin = normalize_text(text) }, function(res)
    self:_settle(res, cb)
  end)
end

--- Replace the user prompt through stdin.
function Actions:edit_user_prompt(id, text, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("edit", id), cb)
    return
  end
  self:_submit("edit", id, "edit", { id, "--user-prompt-file", "-" }, { stdin = normalize_text(text) }, function(res)
    self:_settle(res, cb)
  end)
end

--- Toggle whether the task description may be sent to external judges.
function Actions:set_is_private_desc(id, value, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("private", id), cb)
    return
  end
  self:_submit("private", id, "private", { id, value == true and "--on" or "--off" }, {}, function(res)
    self:_settle(res, cb)
  end)
end

--- Create or replace a single stage prompt through stdin.
function Actions:set_stage_prompt(id, stage, text, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("edit", id), cb)
    return
  end
  if type(stage) ~= "string" or stage == "" then
    self:_settle(self:_invalid("edit", id, "阶段名不能为空"), cb)
    return
  end
  self:_submit("edit", id, "edit", { id, "--stage-prompt-file", stage .. "=-" }, { stdin = normalize_text(text) }, function(res)
    self:_settle(res, cb)
  end)
end

--- Remove one stage prompt entry.
function Actions:delete_stage_prompt(id, stage, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("edit", id), cb)
    return
  end
  if type(stage) ~= "string" or stage == "" then
    self:_settle(self:_invalid("edit", id, "阶段名不能为空"), cb)
    return
  end
  self:_submit("edit", id, "edit", { id, "--stage-prompt", stage .. "=" }, {}, function(res)
    self:_settle(res, cb)
  end)
end

--- Rename a stage prompt entry in one loop-cli edit call.
function Actions:rename_stage_prompt(id, old, new, content, cb)
  cb = cb or noop
  id = util.normalize_id(id)
  if not id then
    self:_settle(self:_invalid("edit", id), cb)
    return
  end
  if type(old) ~= "string" or old == "" or type(new) ~= "string" or new == "" then
    self:_settle(self:_invalid("edit", id, "阶段名不能为空"), cb)
    return
  end
  self:_submit("edit", id, "edit", {
    id,
    "--stage-prompt-file",
    new .. "=-",
    "--stage-prompt",
    old .. "=",
  }, { stdin = normalize_text(content) }, function(res)
    self:_settle(res, cb)
  end)
end

--- Add a new task (title + tag are both required by loop-cli).
function Actions:add_task(title, tag, cb)
  cb = cb or noop
  if type(title) ~= "string" or title == "" then
    self:_settle(self:_invalid("add", nil, "任务标题不允许为空"), cb)
    return
  end
  if type(tag) ~= "string" or tag == "" then
    self:_settle(self:_invalid("add", nil, "分类 tag 不能为空"), cb)
    return
  end
  local edit = require("loop-kit.edit")
  if not edit.valid_tag(self.root, tag, self.loop_root) then
    local choices = table.concat(edit.tag_list(self.root, self.loop_root), " / ")
    self:_settle(self:_invalid("add", nil, "分类 tag 无效：" .. tag .. "；可选 " .. choices), cb)
    return
  end
  self:_submit("add", nil, "add", { "--title", title, "--tag", tag, "--json" }, {}, function(res)
    self:_settle(res, cb)
  end)
end

return M
