-- Unit tests for the loop data file watcher.
local watch = require("loop-kit.watch")

local function join(...)
  return vim.fs.joinpath(...)
end

local function entry(sec, nsec, size)
  return { mtime = { sec = sec, nsec = nsec }, size = size }
end

local function fake_stat(entries)
  return function(path)
    return entries[path]
  end
end

local function fake_timer()
  local timer = { starts = {}, stopped = 0, closed = 0, unreffed = 0, callback = nil }
  function timer:start(timeout, repeat_ms, callback)
    self.starts[#self.starts + 1] = { timeout = timeout, repeat_ms = repeat_ms }
    self.callback = callback
  end
  function timer:stop()
    self.stopped = self.stopped + 1
  end
  function timer:close()
    self.closed = self.closed + 1
  end
  function timer:unref()
    self.unreffed = self.unreffed + 1
  end
  return timer
end

describe("watch.files", function()
  it("lists the three loop cache files under the loop root", function()
    local dir = join("/tmp", "project", ".pi", "loop-kit")
    eq({
      join(dir, "LOOP.json"),
      join(dir, "LOOP.remote.json"),
      join(dir, "loop.meta.json"),
    }, watch.files(dir))
  end)
end)

describe("watch.signature", function()
  local paths = { "/data/LOOP.json", "/data/LOOP.remote.json" }

  it("is stable while the files are untouched", function()
    local stat = fake_stat({ ["/data/LOOP.json"] = entry(10, 5, 100) })
    eq(watch.signature(paths, stat), watch.signature(paths, stat))
  end)

  it("changes when mtime seconds change", function()
    local stat = fake_stat({ ["/data/LOOP.json"] = entry(10, 5, 100) })
    local before = watch.signature(paths, stat)
    stat = fake_stat({ ["/data/LOOP.json"] = entry(11, 5, 100) })
    neq(before, watch.signature(paths, stat))
  end)

  it("changes when mtime nanoseconds change", function()
    local stat = fake_stat({ ["/data/LOOP.json"] = entry(10, 5, 100) })
    local before = watch.signature(paths, stat)
    stat = fake_stat({ ["/data/LOOP.json"] = entry(10, 6, 100) })
    neq(before, watch.signature(paths, stat))
  end)

  it("changes when file size changes", function()
    local stat = fake_stat({ ["/data/LOOP.json"] = entry(10, 5, 100) })
    local before = watch.signature(paths, stat)
    stat = fake_stat({ ["/data/LOOP.json"] = entry(10, 5, 101) })
    neq(before, watch.signature(paths, stat))
  end)

  it("changes when a watched file appears or disappears", function()
    local stat = fake_stat({})
    local before = watch.signature(paths, stat)
    stat = fake_stat({ ["/data/LOOP.json"] = entry(10, 5, 100) })
    local present = watch.signature(paths, stat)
    neq(before, present)
    stat = fake_stat({})
    eq(before, watch.signature(paths, stat))
  end)
end)

describe("watch.new", function()
  it("defaults to a 1000ms interval and clamps to 200ms", function()
    eq(1000, watch.new({ paths = {}, start = false }).interval)
    eq(200, watch.new({ paths = {}, interval = 50, start = false }).interval)
    eq(500, watch.new({ paths = {}, interval = 500, start = false }).interval)
  end)

  it("only establishes a baseline on the first tick", function()
    local entries = { ["/data/LOOP.json"] = entry(1, 0, 10) }
    local calls = 0
    local watcher = watch.new({
      paths = { "/data/LOOP.json" },
      start = false,
      stat = fake_stat(entries),
      on_change = function()
        calls = calls + 1
      end,
    })

    watcher:tick()
    eq(0, calls, "first tick must not fire")

    entries["/data/LOOP.json"] = entry(2, 0, 10)
    watcher:tick()
    eq(1, calls)

    watcher:tick()
    eq(1, calls, "an unchanged signature must not fire again")

    entries["/data/LOOP.json"] = entry(2, 0, 20)
    watcher:tick()
    eq(2, calls)
  end)
end)

describe("watch timers", function()
  it("starts the timer with the configured interval and unrefs it", function()
    local timer = fake_timer()
    local watcher = watch.new({
      paths = {},
      interval = 300,
      start = false,
      new_timer = function()
        return timer
      end,
      schedule = function(fn)
        return fn
      end,
    })
    watcher:start()
    eq(1, #timer.starts)
    eq(300, timer.starts[1].timeout)
    eq(300, timer.starts[1].repeat_ms)
    eq(1, timer.unreffed)
    watcher:stop()
  end)

  it("stops and closes the timer once, and ticks stop after stop()", function()
    local timer = fake_timer()
    local calls = 0
    local entries = { ["/data/LOOP.json"] = entry(1, 0, 10) }
    local watcher = watch.new({
      paths = { "/data/LOOP.json" },
      start = false,
      stat = fake_stat(entries),
      on_change = function()
        calls = calls + 1
      end,
      new_timer = function()
        return timer
      end,
      schedule = function(fn)
        return fn
      end,
    })

    watcher:start()
    timer.callback() -- baseline
    eq(0, calls)

    entries["/data/LOOP.json"] = entry(2, 0, 10)
    timer.callback()
    eq(1, calls)

    watcher:stop()
    eq(1, timer.stopped)
    eq(1, timer.closed)

    timer.callback()
    eq(1, calls, "no callback after stop()")

    watcher:stop()
    eq(1, timer.stopped, "stop() is idempotent")
  end)
end)

