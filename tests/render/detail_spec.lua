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
    eq("- isPrivateDesc: true", line_with(lines, "- isPrivateDesc:"))
    eq("- touch:", line_with(lines, "- touch:"))
    truthy(line_with(lines, "  - lua/loop-kit/ui/detail.lua"))
    eq("- meta: branch=main baseSha=abc123", line_with(lines, "- meta:"))
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
    local detail, buf = make_detail()
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

    eq("- docParent: docs/parent.md", line_with(lines, "- docParent:"))
    eq("- specPrompt: prompts/spec.md", line_with(lines, "- specPrompt:"))
    eq("- researchPrompt: prompts/research.md", line_with(lines, "- researchPrompt:"))
    eq("- codePrompt: prompts/code.md", line_with(lines, "- codePrompt:"))
    eq("- verifyPrompt: prompts/verify.md", line_with(lines, "- verifyPrompt:"))
    eq("- docTaskSplitPrompt: prompts/split.md", line_with(lines, "- docTaskSplitPrompt:"))
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

  it("places the decide/analysis block after metadata behind a rule", function()
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

    local meta_line = rendered.fields.meta
    local private_line = rendered.fields.isPrivateDesc
    eq(meta_line + 1, private_line)
    eq("", lines[private_line + 1])
    eq("---", lines[private_line + 2])
    eq("", lines[private_line + 3])
    eq(private_line + 4, rendered.fields.decide)
    eq(rendered.fields.decide + 1, rendered.fields.analysis)
    truthy(rendered.fields.desc > rendered.fields.analysis, "description follows the metadata block")

    local decide_line = line_with(lines, "- decide:")
    truthy(decide_line)
    match(decide_line, "#5")
    match(decide_line, "未完成 2 项")
    match(decide_line, "未满足依赖")
    eq("- analysis:", line_with(lines, "- analysis:"))
    eq("  - outstanding: 2", lines[rendered.fields.analysis + 1])
    eq("  - eligible: false", lines[rendered.fields.analysis + 2])
    eq("  - blocked: true", lines[rendered.fields.analysis + 3])
    eq("  - stuck: false", lines[rendered.fields.analysis + 4])
    truthy(rendered.fields.decide)
    truthy(rendered.fields.analysis)
    eq(false, vim.bo[buf].modifiable)
  end)

  it("separates key/value groups with rules without doubling the decide rule", function()
    local detail, buf = make_detail()
    local analysis = { target = "#5", outstandingCount = 0, eligible = {}, blocked = {}, stuck = {} }
    local rendered = detail:render(TASK, { ["#2"] = DEP }, analysis, { TASK, DEP })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local f = rendered.fields

    -- Group boundaries: hash | deps | specPrompt | flow, then the decide block.
    eq(f.hash + 4, f.deps)
    eq(f.docParent + 4, f.specPrompt)
    eq(f.docTaskSplitPrompt + 4, f.flow)
    eq(f.isPrivateDesc + 4, f.decide)

    local rules = {}
    for index, line in ipairs(lines) do
      if line == "---" then
        rules[#rules + 1] = index
        eq("", lines[index - 1], "rule must be preceded by a blank line")
        eq("", lines[index + 1], "rule must be followed by a blank line")
      end
    end
    eq(4, #rules, "three group rules plus the decide rule")
    for index = 2, #rules do
      truthy(rules[index] - rules[index - 1] > 2, "rules must not be duplicated")
    end
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
