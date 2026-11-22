local advanced = require("loop-kit.advanced")

local function list_contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

describe("advanced flow choices", function()
  it("offers every named flow in the documented order", function()
    eq({
      "full",
      "research-only",
      "quick",
      "spec-impl",
      "research-split",
      "doc-to-tasks",
    }, advanced.FLOWS)
  end)

  it("uses the CLI stage order", function()
    eq({
      "research",
      "spec",
      "json-task-split",
      "doc-task-split",
      "decision-question",
      "impl",
      "verify",
      "commit",
    }, advanced.STAGE_ORDER)
  end)
end)

describe("advanced custom stage validation", function()
  it("accepts a whitelisted, ordered list ending in commit", function()
    local ok, stages = advanced.validate_stages({ "research", "spec", "impl", "verify", "commit" })
    truthy(ok, stages)
    eq({ "research", "spec", "impl", "verify", "commit" }, stages)
  end)

  it("accepts a minimal research + commit list", function()
    local ok, stages = advanced.validate_stages({ "research", "commit" })
    truthy(ok, stages)
    eq({ "research", "commit" }, stages)
  end)

  it("rejects an unknown stage outside the whitelist", function()
    local ok, message = advanced.validate_stages({ "research", "deploy", "commit" })
    falsy(ok)
    match(message, "未知 stage")
    match(message, "deploy")
  end)

  it("rejects stages that are out of order", function()
    local ok, message = advanced.validate_stages({ "impl", "spec", "commit" })
    falsy(ok)
    match(message, "顺序")
  end)

  it("rejects duplicate stages", function()
    local ok, message = advanced.validate_stages({ "research", "spec", "spec", "commit" })
    falsy(ok)
    match(message, "重复")
  end)

  it("rejects a list that does not end in commit", function()
    local ok, message = advanced.validate_stages({ "research", "spec", "impl", "verify" })
    falsy(ok)
    match(message, "commit")
  end)

  it("rejects a list with only commit", function()
    local ok, message = advanced.validate_stages({ "commit" })
    falsy(ok)
    match(message, "commit")
  end)

  it("rejects an empty list", function()
    local ok, message = advanced.validate_stages({})
    falsy(ok)
    match(message, "至少")
  end)

  it("splits user input on commas and trims each stage", function()
    eq({ "research", "spec", "commit" }, advanced.split_stages(" research , spec,commit , "))
    eq({}, advanced.split_stages("  ,  "))
  end)
end)

describe("advanced touch path input", function()
  it("decodes a JSON string array and preserves paths containing spaces", function()
    local parsed = advanced.parse_touch('["lua/with space/a.lua", "tests/a_spec.lua"]')
    truthy(parsed.ok, parsed.message)
    eq({ "lua/with space/a.lua", "tests/a_spec.lua" }, parsed.paths)
  end)

  it("normalizes a leading ./ segment", function()
    local parsed = advanced.parse_touch('["vague text", "./lua/a.lua"]')
    truthy(parsed.ok, parsed.message)
    eq({ "vague text", "lua/a.lua" }, parsed.paths)
  end)

  it("rejects malformed JSON", function()
    local parsed = advanced.parse_touch("lua/a.lua")
    falsy(parsed.ok)
    match(parsed.message, "JSON")
  end)

  it("rejects a JSON object instead of an array", function()
    local parsed = advanced.parse_touch('{"path":"lua/a.lua"}')
    falsy(parsed.ok)
    match(parsed.message, "数组")
  end)

  it("rejects an empty array with the CLI illegal semantics", function()
    local parsed = advanced.parse_touch("[]")
    falsy(parsed.ok)
    match(parsed.message, "空数组")
  end)

  it("rejects non-string entries", function()
    local parsed = advanced.parse_touch('["lua/a.lua", 3]')
    falsy(parsed.ok)
    match(parsed.message, "字符串")
  end)

  it("rejects blank entries", function()
    local parsed = advanced.parse_touch('["lua/a.lua", "   "]')
    falsy(parsed.ok)
    match(parsed.message, "为空")
  end)

  it("rejects absolute paths", function()
    local parsed = advanced.parse_touch('["/etc/passwd"]')
    falsy(parsed.ok)
    match(parsed.message, "绝对路径")

    local win = advanced.parse_touch('["C:/tmp/a.lua"]')
    falsy(win.ok)
    match(win.message, "绝对路径")
  end)

  it("rejects .. and . path segments", function()
    local up = advanced.parse_touch('["lua/../secret.lua"]')
    falsy(up.ok)
    match(up.message, "%.%.")

    local dot = advanced.parse_touch('["lua/./a.lua"]')
    falsy(dot.ok)
    match(dot.message, "段")
  end)

  it("rejects paths containing newlines", function()
    local parsed = advanced.parse_touch('["lua/a.lua\\nlua/b.lua"]')
    falsy(parsed.ok)
    match(parsed.message, "换行")
  end)
end)

describe("advanced worktree meta validation", function()
  local sha40 = string.rep("a", 40)
  local sha64 = string.rep("0123456789abcdef", 4)

  it("accepts a branch with a full lowercase baseSha", function()
    local ok, meta = advanced.validate_meta("feature/nvim-ui", sha40)
    truthy(ok, meta)
    eq("feature/nvim-ui", meta.branch)
    eq(sha40, meta.base_sha)

    local ok64 = advanced.validate_meta("feature/x", sha64)
    truthy(ok64)
  end)

  it("requires both branch and baseSha", function()
    local ok1, msg1 = advanced.validate_meta("feature/x", nil)
    falsy(ok1)
    match(msg1, "baseSha")

    local ok2, msg2 = advanced.validate_meta(nil, sha40)
    falsy(ok2)
    match(msg2, "branch")
  end)

  it("rejects a blank branch", function()
    local ok, message = advanced.validate_meta("   ", sha40)
    falsy(ok)
    match(message, "不能为空")
  end)

  it("rejects branches with whitespace, .. or a leading dash", function()
    falsy(advanced.validate_meta("feature x", sha40))
    falsy(advanced.validate_meta("feature/../x", sha40))
    falsy(advanced.validate_meta("-force", sha40))
  end)

  it("rejects short or uppercase sha values", function()
    local ok1, msg1 = advanced.validate_meta("feature/x", "abc123")
    falsy(ok1)
    match(msg1, "40 或 64")

    local ok2, msg2 = advanced.validate_meta("feature/x", string.rep("A", 40))
    falsy(ok2)
    match(msg2, "小写")
  end)
end)

describe("advanced touch path helper", function()
  it("checks single paths without JSON", function()
    truthy(advanced.valid_touch_path("lua/a.lua"))
    falsy(advanced.valid_touch_path(""))
    falsy(advanced.valid_touch_path("/abs.lua"))
    falsy(advanced.valid_touch_path("a/../b.lua"))
    falsy(advanced.valid_touch_path("a\nb.lua"))
  end)

  it("keeps only documented flows in the choice list", function()
    truthy(list_contains(advanced.FLOWS, "quick"))
    truthy(list_contains(advanced.FLOWS, "doc-to-tasks"))
  end)
end)

describe("advanced flow listing", function()
  it("parses builtin and custom flows from flow --list payload", function()
    local flows = advanced.flow_payload({
      builtin = { "full", "quick" },
      custom = { mine = { "spec", "impl", "commit" } },
    })
    eq({ "full", "quick" }, flows.builtin)
    eq({ mine = { "spec", "impl", "commit" } }, flows.custom)
    eq({ "full", "quick", "mine" }, advanced.flow_items(flows))
  end)

  it("accepts custom flows as an array of {name, stages}", function()
    local flows = advanced.flow_payload({
      builtin = { "quick" },
      custom = { { name = "mine", stages = { "impl", "commit" } } },
    })
    eq({ "quick", "mine" }, advanced.flow_items(flows))
  end)

  it("falls back to builtin names when the payload is unusable", function()
    local flows = advanced.flow_payload(nil)
    eq(advanced.FLOWS, flows.builtin)
    eq({}, flows.custom)
  end)
end)

describe("advanced field setters", function()
  local function make_advanced()
    local calls = {}
    local instance = advanced.new({
      source = { client = {}, root = "/tmp/kv", snapshot = {} },
      state = {
        tasks = {},
        enqueue = function(_, fn)
          fn(function() end)
        end,
        set_tasks = function(_, list)
          return list
        end,
      },
      exec = function(command, args, _, cb)
        calls[#calls + 1] = { command = command, args = args }
        cb({ ok = true, data = { tasks = {} } })
      end,
      reload = function(cb)
        cb({ ok = true, tasks = {} })
      end,
    })
    return instance, calls
  end

  it("sets tag through edit", function()
    local instance, calls = make_advanced()
    instance:set_tag("#12", "bugfix", function() end)
    eq("edit", calls[1].command)
    eq({ "#12", "--tag", "bugfix" }, calls[1].args)
  end)

  it("sets and clears deps", function()
    local instance, calls = make_advanced()
    instance:set_deps("#12", { "#1", "#2" }, function() end)
    eq({ "#12", "--set", "#1,#2" }, calls[1].args)
    instance:set_deps("#12", {}, function() end)
    eq({ "#12", "--set", "" }, calls[2].args)
  end)

  it("sets and clears doc", function()
    local instance, calls = make_advanced()
    instance:set_doc("#12", "docs/x.md", function() end)
    eq("doc", calls[1].command)
    eq({ "#12", "--path", "docs/x.md" }, calls[1].args)
    instance:set_doc("#12", "", function() end)
    eq({ "#12", "--clear" }, calls[2].args)
  end)

  it("sets prompts with their kebab-case flags", function()
    local instance, calls = make_advanced()
    instance:set_prompt("#12", "docTaskSplitPrompt", "拆分", function() end)
    eq({ "#12", "--doc-task-split-prompt", "拆分" }, calls[1].args)
    instance:set_prompt("#12", "specPrompt", "", function() end)
    eq({ "#12", "--spec-prompt", "" }, calls[2].args)
  end)

  it("rejects unknown prompt fields", function()
    local instance, calls = make_advanced()
    local result
    instance:set_prompt("#12", "nope", "x", function(res)
      result = res
    end)
    eq(0, #calls)
    eq("invalid", result.code)
  end)

  it("sets and clears flow", function()
    local instance, calls = make_advanced()
    instance:set_flow("#12", "quick", function() end)
    eq("flow", calls[1].command)
    eq({ "#12", "--flow", "quick" }, calls[1].args)
    instance:set_flow("#12", "", function() end)
    eq({ "#12", "--clear" }, calls[2].args)
  end)

  it("sets and clears touch", function()
    local instance, calls = make_advanced()
    instance:set_touch("#12", { "lua/a.lua", "tests/a_spec.lua" }, function() end)
    eq("touch", calls[1].command)
    eq({ "#12", "--set", "lua/a.lua", "tests/a_spec.lua" }, calls[1].args)
    instance:set_touch("#12", {}, function() end)
    eq({ "#12", "--clear" }, calls[2].args)
  end)
end)
