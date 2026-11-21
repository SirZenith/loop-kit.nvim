local decide = require("loop-kit.decide")

local function task(id, status, overrides)
  return vim.tbl_extend("force", {
    id = id,
    title = "task " .. id,
    status = status,
    tag = "feat",
    desc = "",
  }, overrides or {})
end

describe("decide view model", function()
  it("describes a next decision with its id", function()
    local view = decide.view({
      action = "next",
      id = "#6",
      reason = "doing 优先",
      ids = { "#6" },
    })
    eq("next", view.action)
    eq("#6", view.id)
    eq("doing 优先", view.reason)
    eq({ "#6" }, view.ids)
    match(view.message, "next")
    match(view.message, "#6")
    match(view.message, "doing 优先")
  end)

  it("describes refill without navigating", function()
    local view = decide.view({
      action = "refill",
      reason = "循环已清空",
      ids = {},
    })
    eq("refill", view.action)
    truthy(view.message:find("refill", 1, true), view.message)
    truthy(view.message:find("循环已清空", 1, true), view.message)
    falsy(view.navigated)
  end)

  it("describes stop with its reason", function()
    local view = decide.view({ action = "stop", reason = "有 doing 条目", ids = { "#4" } })
    truthy(view.message:find("stop", 1, true), view.message)
    truthy(view.message:find("有 doing 条目", 1, true), view.message)
    truthy(view.message:find("#4", 1, true), view.message)
  end)

  it("describes wait with its reason", function()
    local view = decide.view({ action = "wait", reason = "候选被在飞条目挡住", ids = {} })
    truthy(view.message:find("wait", 1, true), view.message)
    truthy(view.message:find("在飞条目", 1, true), view.message)
  end)

  it("does not invent navigation for unknown actions", function()
    local view = decide.view({ action = "mystery", reason = "?" })
    truthy(view.message:find("mystery", 1, true), view.message)
    falsy(view.navigated)
  end)
end)

describe("decide blocking explanation", function()
  local target = task("#6", "pending", { deps = { "#2", "#4" } })
  local dep_doing = task("#2", "doing")
  local dep_done = task("#4", "done")

  it("reports blocked deps together with their current status", function()
    local analysis = {
      target = "#6",
      outstandingCount = 2,
      eligible = {},
      blocked = { { task = target, unmet = { "#2" } } },
      stuck = {},
    }

    local out = decide.explain(analysis, target, { target, dep_doing, dep_done })

    truthy(out.blocked, out.summary)
    falsy(out.eligible)
    falsy(out.stuck)
    eq(2, out.outstanding)
    eq({ "#2" }, out.unmet)
    eq({ { id = "#2", status = "doing" }, { id = "#4", status = "done" } }, out.deps)
    truthy(out.summary:find("#2", 1, true), out.summary)
    truthy(out.summary:find("doing", 1, true), out.summary)
  end)

  it("reports an eligible pending task", function()
    local analysis = {
      target = "#6",
      outstandingCount = 1,
      eligible = { target },
      blocked = {},
      stuck = {},
    }

    local out = decide.explain(analysis, target, { target })
    truthy(out.eligible, out.summary)
    falsy(out.blocked)
    truthy(out.summary:find("可开始", 1, true), out.summary)
  end)

  it("reports a stuck doing task without claiming it", function()
    local doing = task("#6", "doing")
    local analysis = {
      target = "#6",
      outstandingCount = 1,
      eligible = { doing },
      blocked = {},
      stuck = { doing },
    }

    local out = decide.explain(analysis, doing, { doing })
    truthy(out.stuck, out.summary)
    truthy(out.summary:find("正在执行", 1, true), out.summary)
  end)

  it("falls back to the task deps when analysis has no entry", function()
    local out = decide.explain(nil, target, { target, dep_doing, dep_done })
    eq({ "#2" }, out.unmet)
    eq("doing", out.deps[1].status)
    falsy(out.blocked)
  end)
end)
