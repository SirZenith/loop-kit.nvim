-- Render tests for the board detail pane.
local detail_ui = require("loop-kit.ui.detail")
local tmp = require("helpers.tmp")

local TASK = {
  id = "#5",
  title = "Ship the detail pane",
  status = "pending",
  tag = "feat",
  origin = "human",
  openAt = "2026-11-21T10:00:00+08:00",
  closedAt = nil,
  hash = nil,
  deps = { "#2" },
  doc = "docs/nvim/plan.md",
  flow = { "spec", "impl", "commit" },
  private = true,
  touch = { "lua/loop-kit/ui/detail.lua" },
  meta = { branch = "main", baseSha = "abc123" },
  desc = "First line.\nSecond line.",
}

local DEP = { id = "#2", title = "Dependency", status = "done" }

local function make_detail(overrides)
  overrides = overrides or {}
  local root = overrides.root or tmp.dir("detailrender")
  local buf = vim.api.nvim_create_buf(false, true)
  local notifications = {}
  local detail = detail_ui.new({
    root = root,
    buf = buf,
    opener = overrides.opener,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
  })
  return detail, buf, notifications, root
end

local function line_with(lines, prefix)
  for _, line in ipairs(lines) do
    if line:sub(1, #prefix) == prefix then
      return line
    end
  end
  return nil
end

describe("ui.detail: readonly markdown view", function()
  it("renders fields, dependency status, flow, touch and meta", function()
    local detail, buf = make_detail()
    local tasks_by_id = { ["#2"] = DEP }
    local rendered = detail:render(TASK, tasks_by_id)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    truthy(rendered)
    eq(nil, line_with(lines, "- decide:"), "no analysis means no decide block")
    eq("markdown", vim.bo[buf].filetype)
    eq(false, vim.bo[buf].modifiable, "detail stays readonly")
    eq(false, vim.bo[buf].swapfile)

    eq("# Ship the detail pane", lines[1])
    eq("- deps: #2 (done)", line_with(lines, "- deps:"))
    eq("- flow: spec > impl > commit", line_with(lines, "- flow:"))
    eq("- private: true", line_with(lines, "- private:"))
    eq("- touch:", line_with(lines, "- touch:"))
    truthy(line_with(lines, "  - lua/loop-kit/ui/detail.lua"))
    eq("- meta: branch=main baseSha=abc123", line_with(lines, "- meta:"))
    match(table.concat(lines, "\n"), "First line%.\nSecond line%.")
  end)

  it("appends the decide/analysis block when analysis is provided", function()
    local detail, buf = make_detail()
    local analysis = {
      target = "#5",
      outstandingCount = 2,
      eligible = {},
      blocked = { { id = "#5", unmet = { "#2" } } },
      stuck = {},
    }
    local rendered = detail:render(TASK, { ["#2"] = DEP }, analysis, { TASK, DEP })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local decide_line = line_with(lines, "- decide:")
    truthy(decide_line)
    match(decide_line, "#5")
    match(decide_line, "未完成 2 项")
    match(decide_line, "未满足依赖")
    eq(
      "- analysis: outstanding=2 eligible=false blocked=true stuck=false",
      line_with(lines, "- analysis:")
    )
    truthy(rendered.fields.decide)
    truthy(rendered.fields.analysis)
    eq(false, vim.bo[buf].modifiable)
  end)

  it("falls back to a placeholder without a task without becoming editable", function()
    local detail, buf = make_detail()
    detail:render(nil)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq("未选择任务", lines[1])
    eq(false, vim.bo[buf].modifiable)
  end)

  it("resolves doc paths relative to the project root and opens them", function()
    local opened = {}
    local detail, _, notifications, root = make_detail({
      opener = function(path)
        opened[#opened + 1] = path
      end,
    })
    detail:render(TASK)

    local ok, path = detail:open_doc(TASK)
    truthy(ok)
    eq(root .. "/docs/nvim/plan.md", path)
    eq({ root .. "/docs/nvim/plan.md" }, opened)
    eq(0, #notifications)
  end)

  it("reports missing and unsafe doc values instead of opening them", function()
    local opened = {}
    local detail, _, notifications = make_detail({
      opener = function(path)
        opened[#opened + 1] = path
      end,
    })

    local ok, reason = detail:open_doc({ id = "#9", title = "no doc" })
    falsy(ok)
    match(reason, "doc")
    eq(0, #opened)

    local no_newline = { id = "#9", title = "bad", doc = "docs/\nplan.md" }
    ok, reason = detail:open_doc(no_newline)
    falsy(ok)
    match(reason, "换行")
    eq(0, #opened)

    eq(2, #notifications)
  end)
end)
