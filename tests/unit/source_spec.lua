local source_mod = require("loop-kit.source")

local function task(id, overrides)
  return vim.tbl_extend("force", {
    id = id,
    title = "task " .. id,
    status = "pending",
    tag = "feat",
    desc = "",
  }, overrides or {})
end

--- Build a source with an injectable transport so ordering is deterministic.
local function harness()
  local requests = {}
  local source = source_mod.new({
    root = "/proj",
    run = function(argv, opts, cb)
      requests[#requests + 1] = { argv = argv, opts = opts, cb = cb }
      return #requests
    end,
  })
  return source, requests
end

local function collect()
  local results = {}
  return results, function(res)
    results[#results + 1] = res
  end
end

describe("source list cache handling", function()
  it("treats a missing --no-sync cache as a recoverable needs_sync state", function()
    local source, requests = harness()
    local results, cb = collect()

    source:list({ no_sync = true }, cb)
    eq({ "list", "--no-sync" }, requests[1].argv)

    requests[1].cb({
      ok = false,
      code = "no_cache",
      kind = "source",
      exit_code = 2,
      message = "尚未缓存",
    })

    eq("needs_sync", source.snapshot.state)
    falsy(source.snapshot.loaded)
    eq({}, source.snapshot.tasks)
    truthy(results[1].no_cache)
    eq("no_cache", results[1].code)
  end)

  it("does not let an old generation overwrite a newer snapshot", function()
    local source, requests = harness()
    local results, cb = collect()

    source:list({}, cb)
    source:list({}, cb)
    eq(2, #requests)

    -- Newer response arrives first.
    requests[2].cb({
      ok = true,
      data = { source = { kind = "local" }, tasks = { task("#2") }, analysis = {} },
    })
    -- Older response arrives late and must be dropped.
    requests[1].cb({
      ok = true,
      data = { source = { kind = "local" }, tasks = { task("#1") }, analysis = {} },
    })

    eq(1, #source.snapshot.tasks)
    eq("#2", source.snapshot.tasks[1].id)
    eq(2, source.snapshot.generation)
    truthy(results[2].stale, "expected the late response to be marked stale")
    eq("#2", source.snapshot.tasks[1].id)
  end)

  it("keeps the previous tasks when a background sync fails", function()
    local source, requests = harness()

    source:list({ no_sync = true }, function() end)
    requests[1].cb({
      ok = true,
      data = {
        source = { kind = "gitea", location = "https://gitea.example/api/v1" },
        tasks = { task("#3") },
        analysis = { outstandingCount = 1 },
      },
    })
    eq("#3", source.snapshot.tasks[1].id)

    source:sync(function() end)
    truthy(source.snapshot.syncing, "sync should mark the snapshot as syncing")
    requests[2].cb({
      ok = false,
      code = "exit",
      kind = "remote",
      exit_code = 5,
      message = "network down",
    })

    eq("#3", source.snapshot.tasks[1].id)
    eq("ready", source.snapshot.state)
    truthy(source.snapshot.error)
    falsy(source.snapshot.syncing)
  end)

  it("preserves local and remote source descriptors verbatim", function()
    local source, requests = harness()

    source:list({}, function() end)
    local remote = { kind = "gitea", location = "https://gitea.example/api/v1", repo = "a/b" }
    requests[1].cb({
      ok = true,
      data = { source = remote, tasks = {}, analysis = { blocked = {} } },
    })
    eq(remote, source.snapshot.source)

    source:list({}, function() end)
    local local_source = { kind = "local", location = "/proj/loop/LOOP.json" }
    requests[2].cb({
      ok = true,
      data = { source = local_source, tasks = {}, analysis = {} },
    })
    eq(local_source, source.snapshot.source)
  end)
end)

describe("source request contracts", function()
  it("uses paths output verbatim instead of resolving loopRoot itself", function()
    local source, requests = harness()
    local results, cb = collect()

    source:paths(cb)
    eq({ "paths" }, requests[1].argv)

    requests[1].cb({
      ok = true,
      data = { config = "/proj/loop.config.json", loopRoot = "/weird/../shared" },
    })

    eq("/weird/../shared", source.snapshot.paths.loopRoot)
    eq("/proj/loop.config.json", source.snapshot.paths.config)
    eq("/weird/../shared", results[1].paths.loopRoot)
  end)

  it("builds list filters and show/decide requests with explicit ids", function()
    local source, requests = harness()

    source:list({ no_sync = true, status = "pending", target = "#12" }, function() end)
    eq({ "list", "--no-sync", "--status", "pending", "--target", "#12" }, requests[1].argv)

    source:show("#12", function() end)
    eq({ "show", "#12" }, requests[2].argv)
    requests[2].cb({ ok = true, data = task("#12") })
    eq("#12", source.snapshot.last_task.id)

    source:decide({ no_sync = true }, function() end)
    eq({ "decide", "--no-sync" }, requests[3].argv)
    requests[3].cb({
      ok = true,
      data = { action = "next", id = "#2", reason = "go", ids = { "#2" } },
    })
    eq("#2", source.snapshot.decide.id)
  end)
end)
