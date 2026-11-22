local state_mod = require("loop-kit.state")

local function task(id, status, overrides)
  return vim.tbl_extend("force", {
    id = id,
    title = "task " .. id,
    status = status,
    tag = "feat",
    desc = "",
  }, overrides or {})
end

local function ids(tasks)
  local out = {}
  for _, item in ipairs(tasks) do
    out[#out + 1] = item.id
  end
  return out
end

local function sample()
  return {
    task("#10", "pending"),
    task("#2", "pending"),
    task("#3", "doing"),
    task("#1", "blocked"),
    task("#11", "pending"),
    task("#12", "done"),
  }
end

describe("state filtering, grouping and sorting", function()
  it("filters open tasks and defaults to flat descending numeric id order", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("open")
    st:set_tasks(sample())

    eq({ "#11", "#10", "#3", "#2", "#1" }, ids(st:visible_tasks()))

    local groups = st:groups()
    eq(1, #groups)
    eq(nil, groups[1].status)
    eq({ "#11", "#10", "#3", "#2", "#1" }, ids(groups[1].tasks))
  end)

  it("groups by doing/pending/blocked/done when status sort is selected", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("open")
    st:set_tasks(sample())
    st:set_sort("status")

    eq({ "#3", "#2", "#10", "#11", "#1" }, ids(st:visible_tasks()))

    local groups = st:groups()
    eq({ "doing", "pending", "blocked" }, { groups[1].status, groups[2].status, groups[3].status })
    eq({ "#3" }, ids(groups[1].tasks))
    -- numeric id order, not lexicographic string order
    eq({ "#2", "#10", "#11" }, ids(groups[2].tasks))
    eq({ "#1" }, ids(groups[3].tasks))
  end)

  it("includes done tasks with the all filter", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("all")
    st:set_tasks(sample())

    eq({ "#12", "#11", "#10", "#3", "#2", "#1" }, ids(st:visible_tasks()))
    st:set_sort("status")
    eq({ "#3", "#2", "#10", "#11", "#1", "#12" }, ids(st:visible_tasks()))
    local groups = st:groups()
    eq({ "doing", "pending", "blocked", "done" }, {
      groups[1].status,
      groups[2].status,
      groups[3].status,
      groups[4].status,
    })
    eq({ "#12" }, ids(groups[4].tasks))
  end)

  it("sorts flat lists by numeric id and closed timestamp", function()
    local st = state_mod.new():get("/proj/sort")
    st:set_filter("all")
    st:set_tasks({
      task("#1", "done", { closedAt = "2026.1.3 10:00:00" }),
      task("#2", "done", { closedAt = nil }),
      task("#3", "done", { closedAt = "2026.1.1 10:00:00" }),
      task("#10", "done", { closedAt = "2026.1.2 10:00:00" }),
    })

    st:set_sort("id_asc")
    eq({ "#1", "#2", "#3", "#10" }, ids(st:visible_tasks()))
    st:set_sort("id_desc")
    eq({ "#10", "#3", "#2", "#1" }, ids(st:visible_tasks()))
    st:set_sort("closed_asc")
    eq({ "#3", "#10", "#1", "#2" }, ids(st:visible_tasks()))
    st:set_sort("closed_desc")
    eq({ "#1", "#10", "#3", "#2" }, ids(st:visible_tasks()))

    local groups = st:groups()
    eq(1, #groups)
    eq(nil, groups[1].status)
  end)

  it("matches keywords against id, title, tag and desc case-insensitively", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("all")
    st:set_tasks({
      task("#1", "pending", { title = "Fix Render", tag = "ui" }),
      task("#2", "pending", { title = "other", desc = "包含 中文 描述" }),
      task("#3", "pending", { title = "third", tag = "CLI" }),
    })

    st:set_query("render")
    eq({ "#1" }, ids(st:visible_tasks()))

    st:set_query("中文")
    eq({ "#2" }, ids(st:visible_tasks()))

    st:set_query("cli")
    eq({ "#3" }, ids(st:visible_tasks()))

    st:set_query("")
    eq({ "#3", "#2", "#1" }, ids(st:visible_tasks()))
  end)
end)

describe("state selection", function()
  it("restores the selected id after a refresh", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("all")
    st:set_tasks(sample())
    truthy(st:select("#10"))
    eq("#10", st:selected_id())

    local refreshed = sample()
    refreshed[1].title = "renamed"
    st:set_tasks(refreshed)

    eq("#10", st:selected_id())
    eq("renamed", st:selected().title)
  end)

  it("selects the nearest visible task when the current one is filtered out", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("all")
    st:set_tasks({
      task("#1", "pending"),
      task("#2", "done"),
      task("#3", "pending"),
      task("#4", "done"),
    })
    st:select("#3")

    st:set_filter("done")
    eq({ "#4", "#2" }, ids(st:visible_tasks()))
    eq("#4", st:selected_id())
  end)

  it("clears the selection when nothing is visible", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("all")
    st:set_tasks({ task("#1", "pending") })
    st:select("#1")

    st:set_filter("done")
    eq({}, st:visible_tasks())
    eq(nil, st:selected_id())
    eq(nil, st:selected())
  end)

  it("ignores attempts to select a hidden task", function()
    local st = state_mod.new():get("/proj/a")
    st:set_filter("open")
    st:set_tasks(sample())

    falsy(st:select("#12"))
    st:select("#3")
    eq("#3", st:selected_id())
  end)
end)

describe("state write queue", function()
  it("runs writes FIFO and one at a time", function()
    local st = state_mod.new():get("/proj/a")
    local started = {}
    local dones = {}

    local function enqueue(name)
      st:enqueue(function(done)
        started[#started + 1] = name
        dones[#dones + 1] = done
      end)
    end

    enqueue("A")
    enqueue("B")
    enqueue("C")

    eq({ "A" }, started)
    eq(2, st:pending_count())
    truthy(st:is_writing())

    dones[1]()
    eq({ "A", "B" }, started)
    eq(1, st:pending_count())
    truthy(st:is_writing())

    dones[2]()
    eq({ "A", "B", "C" }, started)
    eq(0, st:pending_count())
    truthy(st:is_writing())

    dones[3]()
    falsy(st:is_writing())
    eq(0, st:pending_count())
  end)

  it("ignores a second completion callback for the same write", function()
    local st = state_mod.new():get("/proj/a")
    local started = {}
    local done_first

    st:enqueue(function(done)
      started[#started + 1] = "A"
      done_first = done
    end)
    st:enqueue(function()
      started[#started + 1] = "B"
    end)

    done_first()
    done_first()
    eq({ "A", "B" }, started)
  end)
end)

describe("state isolation", function()
  it("keeps snapshots and queues isolated per normalized project root", function()
    local manager = state_mod.new()
    local a = manager:get("/proj/a")
    local b = manager:get("/proj/b")

    neq(a, b)

    a:set_tasks({ task("#1", "pending") })
    b:set_tasks({ task("#9", "done") })

    eq({ "#1" }, ids(a:visible_tasks()))
    eq({}, ids(b:visible_tasks()))

    local started = {}
    a:enqueue(function(done)
      started[#started + 1] = "a"
      done()
    end)
    b:enqueue(function()
      started[#started + 1] = "b"
    end)

    eq({ "a", "b" }, started)
    eq(0, b:pending_count())
  end)

  it("normalizes trailing slashes and duplicate separators to one state", function()
    local manager = state_mod.new()
    local a = manager:get("/proj/a")
    local same = manager:get("/proj//a/")
    eq(a, same)
  end)
end)
