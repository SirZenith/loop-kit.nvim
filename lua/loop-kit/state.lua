-- Per-project UI state: filter/query, derived tasks, selection and write queue.
local util = require("loop-kit.util")

local M = {}

local GROUP_ORDER = { "doing", "pending", "blocked", "done" }
local OPEN_STATUS = { pending = true, doing = true, blocked = true }

local function matches(task, filter, query)
  if filter == "open" then
    if not OPEN_STATUS[task.status] then
      return false
    end
  elseif filter and filter ~= "all" and filter ~= "" then
    if task.status ~= filter then
      return false
    end
  end
  if query == nil or query == "" then
    return true
  end
  local needle = query:lower()
  local fields = { task.id, task.title, task.tag, task.desc }
  for _, field in ipairs(fields) do
    if type(field) == "string" and field:lower():find(needle, 1, true) then
      return true
    end
  end
  return false
end

local State = {}
State.__index = State

function State:_visible()
  local visible = {}
  for _, task in ipairs(self.tasks) do
    if matches(task, self.filter, self.query) then
      visible[#visible + 1] = task
    end
  end

  local order = {}
  for index, status in ipairs(GROUP_ORDER) do
    order[status] = index
  end

  table.sort(visible, function(a, b)
    local ga = order[a.status] or (#GROUP_ORDER + 1)
    local gb = order[b.status] or (#GROUP_ORDER + 1)
    if ga ~= gb then
      return ga < gb
    end
    if ga == #GROUP_ORDER + 1 and a.status ~= b.status then
      return tostring(a.status) < tostring(b.status)
    end
    return util.compare_ids(a.id, b.id) < 0
  end)

  return visible
end

local function contains_id(list, id)
  for _, task in ipairs(list) do
    if task.id == id then
      return true
    end
  end
  return false
end

--- Re-pick a selection after the visible set changed.
--- `previous` is the visible id order before the change.
function State:_restore(previous)
  local visible = self:_visible()
  local visible_ids = {}
  for _, task in ipairs(visible) do
    visible_ids[#visible_ids + 1] = task.id
  end

  if self._selected_id and contains_id(visible, self._selected_id) then
    return
  end

  local chosen = nil
  local anchor = nil
  if self._selected_id then
    for index, id in ipairs(previous or {}) do
      if id == self._selected_id then
        anchor = index
        break
      end
    end
  end

  if anchor then
    local seen = {}
    for _, id in ipairs(visible_ids) do
      seen[id] = true
    end
    for index = anchor - 1, 1, -1 do
      if seen[previous[index]] then
        chosen = previous[index]
        break
      end
    end
    if not chosen then
      for index = anchor + 1, #previous do
        if seen[previous[index]] then
          chosen = previous[index]
          break
        end
      end
    end
  end

  self._selected_id = chosen or visible_ids[1]
end

function State:_ids()
  local ids = {}
  for _, task in ipairs(self:_visible()) do
    ids[#ids + 1] = task.id
  end
  return ids
end

function State:set_filter(filter)
  local previous = self:_ids()
  self.filter = filter or "open"
  self:_restore(previous)
  return self
end

function State:set_query(query)
  local previous = self:_ids()
  self.query = query or ""
  self:_restore(previous)
  return self
end

function State:set_tasks(tasks)
  local previous = self:_ids()
  self.tasks = util.deepcopy(tasks or {})
  self:_restore(previous)
  return self
end

function State:set_snapshot(snapshot)
  if not snapshot then
    return self
  end
  return self:set_tasks(snapshot.tasks)
end

function State:visible_tasks()
  return self:_visible()
end

function State:groups()
  local visible = self:_visible()
  local index = {}
  local extras = {}
  for _, status in ipairs(GROUP_ORDER) do
    index[status] = { status = status, tasks = {} }
  end

  for _, task in ipairs(visible) do
    local group = index[task.status]
    if not group then
      group = { status = task.status, tasks = {} }
      index[task.status] = group
      extras[#extras + 1] = group
    end
    group.tasks[#group.tasks + 1] = task
  end

  local ordered = {}
  for _, status in ipairs(GROUP_ORDER) do
    local group = index[status]
    if #group.tasks > 0 then
      ordered[#ordered + 1] = group
    end
  end
  for _, group in ipairs(extras) do
    ordered[#ordered + 1] = group
  end
  return ordered
end

--- Select a visible task. Selecting a hidden id is a no-op.
--- Returns true when the selection was applied.
function State:select(id)
  id = util.normalize_id(id)
  if not id then
    return false
  end
  if contains_id(self:_visible(), id) then
    self._selected_id = id
    return true
  end
  return false
end

function State:selected_id()
  return self._selected_id
end

function State:selected()
  if not self._selected_id then
    return nil
  end
  for _, task in ipairs(self:_visible()) do
    if task.id == self._selected_id then
      return task
    end
  end
  return nil
end

--- Re-evaluate the selection against the current data.
function State:refresh()
  self:_restore(self:_ids())
  return self
end

--- FIFO serial writer: one task mutation at a time per project.
function State:enqueue(fn)
  self._queue[#self._queue + 1] = fn
  self:_pump()
end

function State:_pump()
  if self._running then
    return
  end
  local fn = table.remove(self._queue, 1)
  if not fn then
    return
  end
  self._running = true
  local finished = false
  fn(function()
    if finished then
      return
    end
    finished = true
    self._running = false
    self:_pump()
  end)
end

function State:pending_count()
  return #self._queue
end

function State:is_writing()
  return self._running
end

local Manager = {}
Manager.__index = Manager

function M.new()
  return setmetatable({ _states = {} }, Manager)
end

function Manager:get(root)
  local key = util.normalize_root(root) or root or ""
  local st = self._states[key]
  if not st then
    st = setmetatable({
      root = key,
      filter = "open",
      query = "",
      tasks = {},
      _selected_id = nil,
      _queue = {},
      _running = false,
    }, State)
    self._states[key] = st
  end
  return st
end

return M
