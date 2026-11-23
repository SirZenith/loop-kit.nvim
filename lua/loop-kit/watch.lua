-- Lightweight signature watcher for the local loop cache files.
--
-- It only answers "did something change?"; callers decide how to reload. The
-- timer is unref'd so it never keeps Neovim alive on its own.
local M = {}

M.DEFAULT_INTERVAL = 1000
M.MIN_INTERVAL = 200

local Watch = {}
Watch.__index = Watch

--- The three cache files loop-cli writes under the loop root.
function M.files(dir)
  if type(dir) ~= "string" or dir == "" then
    return {}
  end
  return {
    vim.fs.joinpath(dir, "LOOP.json"),
    vim.fs.joinpath(dir, "LOOP.remote.json"),
    vim.fs.joinpath(dir, "loop.meta.json"),
  }
end

--- Build a comparable signature; missing files are part of it so creation and
--- deletion both change the result.
--- opts: stat(path) -> uv.fs_stat-like table or nil.
function M.signature(paths, stat)
  stat = stat or vim.uv.fs_stat
  local parts = {}
  for index, path in ipairs(paths or {}) do
    local ok, entry = pcall(stat, path)
    if not ok or not entry then
      parts[index] = tostring(path) .. "|missing"
    else
      local mtime = entry.mtime or {}
      parts[index] = table.concat({
        tostring(path),
        tostring(mtime.sec or 0),
        tostring(mtime.nsec or 0),
        tostring(entry.size or 0),
      }, "|")
    end
  end
  return table.concat(parts, "\n")
end

--- Create a watcher.
--- opts: paths, interval (ms), on_change(watcher), stat, new_timer, schedule,
--- start (false to defer starting).
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Watch)
  self.paths = opts.paths or {}
  local interval = tonumber(opts.interval) or M.DEFAULT_INTERVAL
  if interval < M.MIN_INTERVAL then
    interval = M.MIN_INTERVAL
  end
  self.interval = interval
  self.on_change = opts.on_change
  self.timer = nil
  self._baseline = nil
  self._stat = opts.stat or function(path)
    return vim.uv.fs_stat(path)
  end
  self._new_timer = opts.new_timer or function()
    return vim.uv.new_timer()
  end
  self._schedule = opts.schedule or vim.schedule_wrap
  if opts.start ~= false then
    self:start()
  end
  return self
end

--- Compare the current signature with the previous one; fires on change.
--- The first call only establishes the baseline.
function Watch:tick()
  local signature = M.signature(self.paths, self._stat)
  local baseline = self._baseline
  self._baseline = signature
  if baseline == nil or signature == baseline then
    return false
  end
  if self.on_change then
    self.on_change(self)
  end
  return true
end

--- Start (or restart) the polling timer.
function Watch:start()
  if self.timer then
    return self
  end
  self._baseline = nil
  local timer = self._new_timer()
  self.timer = timer
  local wrapped = self._schedule(function()
    if not self.timer then
      return
    end
    self:tick()
  end)
  pcall(timer.start, timer, self.interval, self.interval, wrapped)
  pcall(timer.unref, timer)
  return self
end

--- Stop and release the timer. Safe to call repeatedly.
function Watch:stop()
  local timer = self.timer
  self.timer = nil
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
  return self
end

return M
