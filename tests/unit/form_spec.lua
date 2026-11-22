local form = require("loop-kit.form")

local function task(overrides)
  return vim.tbl_extend("force", {
    id = "#12",
    title = "标题",
    status = "doing",
    tag = "feat",
    deps = { "#3", "#5" },
    doc = "loop/docs/example.md",
    desc = "第一段\n\n- 列表\n- 结束",
  }, overrides or {})
end

local function parsed_task(overrides)
  local baseline = task(overrides)
  return form.parse(form.serialize(baseline))
end

local function has_arg(args, needle)
  for _, arg in ipairs(args) do
    if arg == needle then
      return true
    end
  end
  return false
end

describe("form parse and serialize", function()
  it("round-trips multi-paragraph descriptions", function()
    local baseline = task()
    local parsed = form.parse(form.serialize(baseline))

    eq({}, parsed.errors)
    eq("#12", parsed.id)
    eq("标题", parsed.title)
    eq("feat", parsed.tag)
    eq({ "#3", "#5" }, parsed.deps)
    eq("loop/docs/example.md", parsed.doc)
    eq(baseline.desc, parsed.desc)
  end)

  it("normalizes JSON null fields without concatenating userdata", function()
    local baseline = task({ doc = vim.NIL, deps = vim.NIL, desc = vim.NIL })
    local text = form.serialize(baseline)

    falsy(text:find("doc:", 1, true), "null doc is omitted")
    falsy(text:find("deps:", 1, true), "null deps are omitted")
    local parsed = form.parse(text)
    eq({}, parsed.errors)
    eq(nil, parsed.doc)
    eq({}, parsed.deps)
    eq("", parsed.desc)

    local plan = form.plan(parsed, baseline)
    truthy(plan.ok)
    eq(0, #plan.calls)
  end)

  it("keeps headings after the title inside the description", function()
    local parsed = form.parse({
      "<!-- loopkit:task id=#12 -->",
      "# 标题",
      "",
      "## 小节",
      "",
      "正文",
    })

    eq({}, parsed.errors)
    eq("标题", parsed.title)
    eq("## 小节\n\n正文", parsed.desc)
  end)
end)

describe("form field diff", function()
  it("only sends a changed title", function()
    local parsed = parsed_task({ title = "新标题" })
    local plan = form.plan(parsed, task())

    truthy(plan.ok)
    eq(1, #plan.calls)
    eq("edit", plan.calls[1].command)
    eq({ "#12", "--title", "新标题" }, plan.calls[1].args)
    falsy(has_arg(plan.calls[1].args, "--desc-file"))
    falsy(has_arg(plan.calls[1].args, "--tag"))
    falsy(has_arg(plan.calls[1].args, "--deps"))
    falsy(has_arg(plan.calls[1].args, "--doc"))
  end)

  it("sends descriptions through --desc-file stdin", function()
    local parsed = parsed_task({ desc = "新的第一段\n\n新的第二段" })
    local plan = form.plan(parsed, task())

    eq(1, #plan.calls)
    eq({ "#12", "--desc-file", "-" }, plan.calls[1].args)
    eq("新的第一段\n\n新的第二段", plan.calls[1].stdin)
    for _, arg in ipairs(plan.calls[1].args) do
      falsy(arg:find("\n", 1, true), "description leaked into argv")
    end
  end)

  it("sends changed deps and doc through edit", function()
    local parsed = parsed_task({ deps = { "#7" }, doc = "loop/docs/other.md" })
    local plan = form.plan(parsed, task())

    truthy(plan.ok)
    eq(1, #plan.calls)
    eq("edit", plan.calls[1].command)
    eq({
      "#12",
      "--deps",
      "#7",
      "--doc",
      "loop/docs/other.md",
    }, plan.calls[1].args)
  end)

  it("clears empty deps and doc through their own commands", function()
    local baseline = task()
    local parsed = form.parse({
      "<!-- loopkit:task id=#12 -->",
      "# 标题",
      "",
      "<!-- loopkit:meta",
      "tag: feat",
      "-->",
      "",
      "第一段",
      "",
      "- 列表",
      "- 结束",
    })

    local plan = form.plan(parsed, baseline)
    truthy(plan.ok)
    eq(2, #plan.calls)
    eq("deps", plan.calls[1].command)
    eq({ "#12", "--set", "" }, plan.calls[1].args)
    eq("doc", plan.calls[2].command)
    eq({ "#12", "--clear" }, plan.calls[2].args)
  end)

  it("does not send status, flow, private, touch or meta", function()
    local baseline = task({
      flow = "quick",
      isPrivateDesc = true,
      touch = { "lua/loop-kit/form.lua" },
      meta = { branch = "main" },
    })
    local parsed = parsed_task({ title = "新标题" })
    local plan = form.plan(parsed, baseline)

    eq(1, #plan.calls)
    for _, forbidden in ipairs({ "--status", "--flow", "--private", "--touch", "--meta" }) do
      falsy(has_arg(plan.calls[1].args, forbidden), "unexpected field " .. forbidden)
    end
    eq("edit", plan.calls[1].command)
  end)
end)

describe("form new tasks", function()
  it("starts with a new header and sensible defaults", function()
    local defaults = form.defaults()
    eq("", defaults.title)
    eq("feat", defaults.tag)
    eq({}, defaults.deps)
    eq(nil, defaults.doc)
    eq("", defaults.desc)

    local text = form.serialize(defaults)
    match(text, "<!%-%- loopkit:task new %-%->")
    local parsed = form.parse(text)
    truthy(parsed.is_new)
    eq(nil, parsed.id)
  end)

  it("adds with --origin human and omits empty fields", function()
    local parsed = form.parse({
      "<!-- loopkit:task new -->",
      "# 新任务",
      "",
      "<!-- loopkit:meta",
      "tag: fix",
      "-->",
      "",
    })

    local plan = form.plan(parsed, nil)
    truthy(plan.ok)
    eq(1, #plan.calls)
    eq("add", plan.calls[1].command)
    eq({ "--title", "新任务", "--tag", "fix", "--origin", "human" }, plan.calls[1].args)
    falsy(has_arg(plan.calls[1].args, "--deps"))
    falsy(has_arg(plan.calls[1].args, "--doc"))
    falsy(has_arg(plan.calls[1].args, "--desc-file"))
  end)
end)

describe("form validation", function()
  it("reports unknown meta keys with their line number", function()
    local parsed = form.parse({
      "<!-- loopkit:task id=#12 -->",
      "# 标题",
      "",
      "<!-- loopkit:meta",
      "tag: feat",
      "bogus: nope",
      "-->",
      "",
      "描述",
    })

    eq(1, #parsed.errors)
    eq(6, parsed.errors[1].line)
    match(parsed.errors[1].message, "未知")
    match(parsed.errors[1].message, "bogus")
  end)

  it("reports duplicate meta keys with their line number", function()
    local parsed = form.parse({
      "<!-- loopkit:task id=#12 -->",
      "# 标题",
      "",
      "<!-- loopkit:meta",
      "tag: feat",
      "tag: fix",
      "-->",
    })

    eq(1, #parsed.errors)
    eq(6, parsed.errors[1].line)
    match(parsed.errors[1].message, "重复")
  end)

  it("reports invalid dependency ids", function()
    local parsed = form.parse({
      "<!-- loopkit:task id=#12 -->",
      "# 标题",
      "",
      "<!-- loopkit:meta",
      "deps: #3, nope",
      "-->",
    })

    eq(1, #parsed.errors)
    eq(5, parsed.errors[1].line)
    match(parsed.errors[1].message, "依赖")
  end)

  it("reports illegal doc paths", function()
    local parsed = form.parse({
      "<!-- loopkit:task id=#12 -->",
      "# 标题",
      "",
      "<!-- loopkit:meta",
      "doc: ../secret.md",
      "-->",
    })

    eq(1, #parsed.errors)
    eq(5, parsed.errors[1].line)
    match(parsed.errors[1].message, "doc")
  end)

  it("requires a title and rejects CLI calls while invalid", function()
    local parsed = form.parse({
      "<!-- loopkit:task id=#12 -->",
      "",
      "<!-- loopkit:meta",
      "tag: feat",
      "-->",
      "",
      "只有描述",
    })

    truthy(#parsed.errors >= 1)
    local plan = form.plan(parsed, task())
    falsy(plan.ok)
    truthy(#plan.errors >= 1)
    eq(0, #plan.calls)
  end)
end)

describe("form buffer names", function()
  it("encodes task ids and nonce-based new buffers", function()
    eq("loopkit:///proj/task/%2312", form.buffer_name("/proj", "#12"))
    eq("loopkit:///proj/new/abc123", form.new_buffer_name("/proj", "abc123"))
  end)
end)
