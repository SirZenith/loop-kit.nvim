-- decide projection view model.
--
-- `n` asks the scheduler (`decide --json --no-sync`) for the next action. Only
-- `next` with an id navigates; refill/stop/wait are reported verbatim and the
-- plugin never refills, claims or starts a loop on its own.
local util = require("loop-kit.util")

local M = {}

local function as_id(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

--- Turn a decide payload into display fields.
--- Returns { action, id, reason, ids, message }.
function M.view(decision)
  decision = decision or {}
  local action = decision.action
  local id = as_id(decision.id)
  local reason = decision.reason or ""
  local ids = {}
  if type(decision.ids) == "table" then
    for _, item in ipairs(decision.ids) do
      ids[#ids + 1] = item
    end
  end

  local view = {
    action = action,
    id = id,
    reason = reason,
    ids = ids,
    navigated = false,
  }

  if action == "next" then
    if id then
      view.message = string.format("推荐 next：%s（%s）", id, reason)
    else
      view.message = string.format("推荐 next，但没有可跳转的任务（%s）", reason)
    end
  elseif action == "refill" or action == "stop" or action == "wait" then
    local suffix = #ids > 0 and string.format("；候选：%s", table.concat(ids, ", ")) or ""
    view.message = string.format("%s：%s%s", action, reason, suffix)
  else
    view.message = string.format("未知 decide 动作：%s（%s）", tostring(action), reason)
  end

  return view
end

local function task_map(tasks)
  local map = {}
  for _, item in ipairs(tasks or {}) do
    if type(item) == "table" and item.id then
      map[item.id] = item
    end
  end
  return map
end

local function contains_id(list, id)
  if type(list) ~= "table" or not id then
    return false
  end
  for _, item in ipairs(list) do
    local item_id = item
    if type(item) == "table" then
      item_id = item.id or (item.task and item.task.id)
    end
    if item_id == id then
      return true
    end
  end
  return false
end

--- Explain one task using `list --target` analysis plus dependency statuses.
--- Never re-derives scheduling rules: `analysis` is authoritative for
--- eligible/blocked/stuck, dependencies only add human-readable statuses.
function M.explain(analysis, task, tasks)
  local id = (task and task.id) or (analysis and analysis.target)
  local map = task_map(tasks)

  local deps = {}
  if task and type(task.deps) == "table" then
    for _, dep in ipairs(task.deps) do
      local dep_id = util.normalize_id(type(dep) == "string" and dep or nil)
      if dep_id then
        local dep_task = map[dep_id]
        deps[#deps + 1] = {
          id = dep_id,
          status = dep_task and dep_task.status or "missing",
        }
      end
    end
  end

  local unmet = {}
  if analysis and type(analysis.blocked) == "table" then
    for _, entry in ipairs(analysis.blocked) do
      local entry_id = type(entry) == "table"
          and (entry.task and entry.task.id or entry.id)
        or nil
      if entry_id == id and type(entry.unmet) == "table" then
        for _, dep in ipairs(entry.unmet) do
          unmet[#unmet + 1] = dep
        end
      end
    end
  end
  if #unmet == 0 then
    for _, dep in ipairs(deps) do
      if dep.status ~= "done" then
        unmet[#unmet + 1] = dep.id
      end
    end
  end

  local out = {
    id = id,
    outstanding = (analysis and analysis.outstandingCount) or 0,
    eligible = contains_id(analysis and analysis.eligible, id),
    blocked = contains_id(analysis and analysis.blocked, id),
    stuck = contains_id(analysis and analysis.stuck, id),
    unmet = unmet,
    deps = deps,
  }

  local parts = {
    string.format("%s：未完成 %d 项", tostring(id or "?"), out.outstanding),
  }
  if out.stuck then
    parts[#parts + 1] = "正在执行（stuck doing）"
  elseif out.blocked then
    parts[#parts + 1] = "被依赖阻塞"
  elseif out.eligible then
    parts[#parts + 1] = "可开始"
  end
  if #unmet > 0 then
    local labels = {}
    for _, dep in ipairs(unmet) do
      local dep_task = map[dep]
      labels[#labels + 1] = string.format("%s（%s）", dep, dep_task and dep_task.status or "missing")
    end
    parts[#parts + 1] = "未满足依赖：" .. table.concat(labels, "、")
  end
  out.summary = table.concat(parts, "；")

  return out
end

local Decide = {}
Decide.__index = Decide

--- opts: source, state, client.
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Decide)
  self.source = assert(opts.source, "loop-kit.decide: source is required")
  self.state = opts.state
  self.client = opts.client or self.source.client
  self.root = opts.root or (self.client and self.client.project_root) or self.source.root
  return self
end

local function failure(action, id, res)
  res = res or {}
  return {
    ok = false,
    action = action,
    id = id,
    code = res.code or "exit",
    kind = res.kind,
    exit_code = res.exit_code,
    message = res.message or "读取 decide 失败",
    error = res,
  }
end

--- Ask for the next action, selecting a `next` id when one is returned.
function Decide:run(cb)
  cb = cb or function() end
  self.source:decide({ no_sync = true }, function(res)
    res = res or {}
    if not res.ok then
      cb(failure("decide", nil, res))
      return
    end

    local decision = res.decision or res.data or {}
    local view = M.view(decision)
    view.ok = true
    view.decision = decision

    if view.action == "next" and view.id then
      local selected = self.state and self.state:select(view.id) or false
      view.navigated = selected and true or false
      view.selected = selected and view.id or nil
      if not selected then
        view.message = view.message .. "\n该任务不在当前筛选中，未跳转"
      end
    end

    cb(view)
  end)
end

--- Explain a single task from cache-only list analysis.
function Decide:explain(id, cb)
  cb = cb or function() end
  id = util.normalize_id(id)
  if not id then
    cb({
      ok = false,
      action = "explain",
      code = "invalid",
      kind = "usage",
      message = "任务 id 不合法",
    })
    return
  end

  self.source:list({ no_sync = true, target = id }, function(res)
    res = res or {}
    if not res.ok then
      cb(failure("explain", id, res))
      return
    end

    local tasks = res.tasks or {}
    if #tasks == 0 and self.state then
      tasks = self.state.tasks
    end
    local task = nil
    for _, item in ipairs(tasks) do
      if item.id == id then
        task = item
        break
      end
    end

    local analysis = res.analysis or self.source.snapshot.analysis
    local out = M.explain(analysis, task, tasks)
    out.ok = true
    out.action = "explain"
    out.analysis = analysis
    cb(out)
  end)
end

return M
