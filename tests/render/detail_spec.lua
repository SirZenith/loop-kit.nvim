-- Render tests for the board detail pane.
local detail_ui = require("loop-kit.ui.detail")
local util = require("loop-kit.util")
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
  isPrivateDesc = true,
  touch = { "lua/loop-kit/ui/detail.lua" },
  meta = { branch = "main", baseSha = "abc123" },
  blockedReason = "Reason one.\nReason two.",
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
    win = overrides.win,
    width = overrides.width,
    opener = overrides.opener,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
  })
  return detail, buf, notifications, root
end

local function line_with(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return nil
end

local function card_start(lines, title)
  for index, line in ipairs(lines) do
    if line:find("╭─ " .. title, 1, true) == 1 then
      return index
    end
  end
end

describe("ui.detail: readonly markdown view", function()
  it("renders fields in grouped cards with a clamped width", function()
    local detail, buf = make_detail({ width = 50 })
    local tasks_by_id = { ["#2"] = DEP }
    local rendered = detail:render(TASK, tasks_by_id)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")

    truthy(rendered)
    eq(nil, line_with(lines, "决策说明"), "no analysis means no decide card")
    eq("markdown", vim.bo[buf].filetype)
    eq(false, vim.bo[buf].modifiable, "detail stays readonly")
    eq(false, vim.bo[buf].swapfile)

    eq("# Ship the detail pane", lines[1])
    truthy(card_start(lines, "状态信息"))
    truthy(card_start(lines, "依赖与文档"))
    truthy(card_start(lines, "提示词"))
    truthy(card_start(lines, "执行信息"))
    eq(nil, line_with(lines, "---"), "no markdown rules remain")
    truthy(text:find("#2 ●", 1, true), "dependency status icon missing")
    truthy(text:find("spec > impl > commit", 1, true))
    truthy(text:find("lua/loop-kit/ui/detail.lua", 1, true))
    truthy(text:find("branch=main baseSha=abc123", 1, true))
    truthy(lines[rendered.fields.isPrivateDesc]:find("true", 1, true))

    local private_value_hl
    for _, range in ipairs(rendered.highlights) do
      if
        range.line == rendered.fields.isPrivateDesc
        and lines[range.line]:sub(range.col_start + 1, range.col_end) == "true"
      then
        private_value_hl = range.hl_group
      end
    end
    eq("LoopKitDetailConstant", private_value_hl, "boolean value uses the Constant group")

    for _, line in ipairs(lines) do
      local first = line:sub(1, 1)
      if first == "│" or first == "╭" or first == "╰" then
        eq(50, util.display_width(line), line)
      end
    end

    truthy(rendered.fields.isPrivateDesc > rendered.fields.meta, "isPrivateDesc follows meta")
    eq("# 阻塞原因", line_with(lines, "# 阻塞原因"))
    eq("Reason one.", lines[rendered.fields.blockedReason_content])
    eq("Reason two.", lines[rendered.fields.blockedReason_content + 1])
    truthy(rendered.fields.blockedReason < rendered.fields.desc, "blocked reason precedes desc")
    for _, range in ipairs(rendered.highlights) do
      if range.line == rendered.fields.desc_content then
        neq("LoopKitDetailMuted", range.hl_group, "right-pane description keeps markdown colours")
      end
    end
    match(table.concat(lines, "\n"), "First line%.\nSecond line%.")
  end)

  it("renders prompt paths, description and prompt sections with highlights", function()
    local detail, buf = make_detail({ width = 50 })
    local task = vim.tbl_extend("force", TASK, {
      docParent = "docs/parent.md",
      specPrompt = "prompts/spec.md",
      researchPrompt = "prompts/research.md",
      codePrompt = "prompts/code.md",
      verifyPrompt = "prompts/verify.md",
      docTaskSplitPrompt = "prompts/split.md",
      userPrompt = "先保证兼容。",
      stagePrompt = { verify = "跑全量测试。", spec = "先写文档。" },
      desc = "",
    })

    local rendered = detail:render(task, { ["#2"] = DEP })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    truthy(line_with(lines, "docs/parent.md"))
    truthy(line_with(lines, "prompts/spec.md"))
    truthy(line_with(lines, "prompts/research.md"))
    truthy(line_with(lines, "prompts/code.md"))
    truthy(line_with(lines, "prompts/verify.md"))
    truthy(line_with(lines, "prompts/split.md"))
    eq("# 任务描述", line_with(lines, "# 任务描述"))
    eq("暂无内容", lines[rendered.fields.desc_content])
    eq("# 用户提示词", line_with(lines, "# 用户提示词"))
    eq("先保证兼容。", lines[rendered.fields.userPrompt_content])
    eq("# 各阶段提示词", line_with(lines, "# 各阶段提示词"))
    eq("## spec", line_with(lines, "## spec"))
    eq("先写文档。", lines[rendered.fields["stagePrompt.spec.content"]])
    eq("## verify", line_with(lines, "## verify"))
    eq("跑全量测试。", lines[rendered.fields["stagePrompt.verify.content"]])

    truthy(#rendered.highlights > 0, "detail returns highlight ranges")
    local ns = vim.api.nvim_get_namespaces()["loop-kit-ui-detail"]
    truthy(ns, "detail namespace exists")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    truthy(#marks > 0, "highlight ranges are applied as extmarks")
  end)

  it("places the decide/analysis block in its own card", function()
    local detail, buf = make_detail({ width = 50 })
    local analysis = {
      target = "#5",
      outstandingCount = 2,
      eligible = {},
      blocked = { { id = "#5", unmet = { "#2" } } },
      stuck = {},
    }
    local rendered = detail:render(TASK, { ["#2"] = DEP }, analysis, { TASK, DEP })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local decide_card = card_start(lines, "决策说明")
    truthy(decide_card)
    eq("", lines[decide_card - 1], "cards are separated by one blank line")
    eq("╰", vim.fn.strcharpart(lines[decide_card - 2], 0, 1))

    truthy(rendered.fields.decide > rendered.fields.isPrivateDesc)
    truthy(rendered.fields.analysis > rendered.fields.decide)
    truthy(rendered.fields.desc > rendered.fields.analysis, "description follows the cards")
    local decide_rows = {}
    for index = rendered.fields.decide, rendered.fields.analysis - 1 do
      local row = lines[index]
      decide_rows[#decide_rows + 1] = row:sub(#"│ " + 1, -#(" │") - 1)
    end
    local decide_text = table.concat(decide_rows):gsub("%s+", "")
    truthy(decide_text:find("#5", 1, true))
    truthy(decide_text:find("未完成2项", 1, true))
    truthy(decide_text:find("未满足依赖", 1, true))
    truthy(lines[rendered.fields.outstanding]:find("outstanding", 1, true))
    truthy(lines[rendered.fields.outstanding]:find("2", 1, true))
    truthy(lines[rendered.fields.eligible]:find("false", 1, true))
    truthy(lines[rendered.fields.blocked]:find("true", 1, true))
    truthy(lines[rendered.fields.stuck]:find("false", 1, true))
    eq(false, vim.bo[buf].modifiable)
  end)

  it("colours card borders muted and titles as sections", function()
    local detail, buf = make_detail({ width = 50 })
    detail:render(TASK)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ns = vim.api.nvim_get_namespaces()["loop-kit-ui-detail"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

    local muted_top, muted_bottom, titles = 0, 0, 0
    for _, mark in ipairs(marks) do
      local row, details = mark[2], mark[4]
      local line = lines[row + 1] or ""
      local first = vim.fn.strcharpart(line, 0, 1)
      if first == "╭" and details.hl_group == "LoopKitMuted" then
        muted_top = muted_top + 1
      elseif first == "╭" and details.hl_group == "LoopKitDetailSection" then
        titles = titles + 1
      elseif first == "╰" then
        eq("LoopKitMuted", details.hl_group, "the bottom border is muted")
        muted_bottom = muted_bottom + 1
      end
    end

    truthy(muted_top >= 4, "every card top border is muted")
    eq(4, muted_bottom, "every card bottom border is muted")
    eq(4, titles, "every card title uses the section group")
  end)

  it("re-renders with the current pane width", function()
    local detail, buf = make_detail({ width = 50 })
    detail:render(TASK)
    local wide = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(50, util.display_width(wide[3]))

    detail.width = 30
    detail:rerender()
    local narrow = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(30, util.display_width(narrow[3]))

    detail:render(nil)
    eq(nil, detail:rerender(), "nothing to re-render without a task")
  end)

  it("falls back to a placeholder without a task without becoming editable", function()
    local detail, buf = make_detail()
    detail:render(nil)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq("# 未选择任务", lines[1])
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
