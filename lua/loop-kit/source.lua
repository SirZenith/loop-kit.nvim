-- Authoritative source of truth: fetches loop-cli data and holds a snapshot.
local M = {}

local Source = {}
Source.__index = Source

local function as_callback(value)
  if type(value) == "function" then
    return value
  end
  return function() end
end

local function new_snapshot(root)
  return {
    root = root,
    source = nil,
    tasks = {},
    analysis = nil,
    paths = nil,
    decide = nil,
    last_task = nil,
    generation = 0,
    loaded = false,
    state = "idle",
    error = nil,
    syncing = false,
  }
end

--- Create a source.
--- opts: client (loop-kit.cli client), root, run (injectable argv runner).
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Source)
  self.client = opts.client
  self.root = opts.root or (opts.client and opts.client.project_root)
  self.snapshot = new_snapshot(self.root)
  self._gen = { list = 0, paths = 0, decide = 0, show = {} }

  if opts.run then
    self._run = opts.run
  elseif opts.client then
    self._run = function(argv, run_opts, cb)
      local command = argv[1]
      local args = {}
      for index = 2, #argv do
        args[#args + 1] = argv[index]
      end
      opts.client:run(command, args, run_opts, cb)
    end
  else
    error("loop-kit.source: client or run is required")
  end

  return self
end

function Source:_stale(channel, generation)
  return {
    ok = false,
    stale = true,
    code = "stale",
    channel = channel,
    generation = generation,
  }
end

function Source:_list(opts, cb)
  opts = opts or {}
  cb = as_callback(cb)
  local args = { "list" }
  if opts.no_sync then
    args[#args + 1] = "--no-sync"
  end
  if type(opts.status) == "string" and opts.status ~= "" then
    args[#args + 1] = "--status"
    args[#args + 1] = opts.status
  end
  if type(opts.target) == "string" and opts.target ~= "" then
    args[#args + 1] = "--target"
    args[#args + 1] = opts.target
  end

  self._gen.list = self._gen.list + 1
  local generation = self._gen.list
  self.snapshot.generation = generation
  self.snapshot.syncing = true

  self._run(args, {}, function(res)
    if generation ~= self._gen.list then
      cb(self:_stale("list", generation))
      return
    end

    self.snapshot.syncing = false
    if res.ok then
      local data = res.data or {}
      if data.source ~= nil then
        self.snapshot.source = data.source
      end
      if data.tasks ~= nil then
        self.snapshot.tasks = data.tasks
      end
      if data.analysis ~= nil then
        self.snapshot.analysis = data.analysis
      end
      self.snapshot.loaded = true
      self.snapshot.state = "ready"
      self.snapshot.error = nil
      res.tasks = self.snapshot.tasks
      res.source = self.snapshot.source
      res.analysis = self.snapshot.analysis
      cb(res)
      return
    end

    self.snapshot.error = res
    if res.code == "no_cache" then
      res.no_cache = true
      self.snapshot.state = "needs_sync"
    elseif self.snapshot.loaded then
      self.snapshot.state = "ready"
    else
      self.snapshot.state = "error"
    end
    cb(res)
  end)
end

--- List items. opts: no_sync, status, target.
function Source:list(opts, cb)
  if type(opts) == "function" then
    opts, cb = {}, opts
  end
  self:_list(opts or {}, cb)
end

--- Explicit sync: plain `list` without --no-sync.
function Source:sync(cb)
  self:_list({}, cb)
end

--- Fetch resolved paths without overlaying them onto config.
function Source:paths(cb)
  cb = as_callback(cb)
  self._gen.paths = self._gen.paths + 1
  local generation = self._gen.paths

  self._run({ "paths" }, {}, function(res)
    if generation ~= self._gen.paths then
      cb(self:_stale("paths", generation))
      return
    end
    if res.ok and res.data ~= nil then
      self.snapshot.paths = res.data
      res.paths = res.data
    end
    cb(res)
  end)
end

--- Show one task.
function Source:show(id, cb)
  cb = as_callback(cb)
  local generation = (self._gen.show[id] or 0) + 1
  self._gen.show[id] = generation

  self._run({ "show", id }, {}, function(res)
    if generation ~= self._gen.show[id] then
      cb(self:_stale("show", generation))
      return
    end
    if res.ok and res.data ~= nil then
      self.snapshot.last_task = res.data
      res.task = res.data
    end
    cb(res)
  end)
end

--- Ask the scheduler for the next action.
function Source:decide(opts, cb)
  if type(opts) == "function" then
    opts, cb = {}, opts
  end
  opts = opts or {}
  cb = as_callback(cb)
  local args = { "decide" }
  if opts.no_sync then
    args[#args + 1] = "--no-sync"
  end

  self._gen.decide = self._gen.decide + 1
  local generation = self._gen.decide

  self._run(args, {}, function(res)
    if generation ~= self._gen.decide then
      cb(self:_stale("decide", generation))
      return
    end
    if res.ok and res.data ~= nil then
      self.snapshot.decide = res.data
      res.decision = res.data
    end
    cb(res)
  end)
end

return M
