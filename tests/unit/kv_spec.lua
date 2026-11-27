local kv = require("loop-kit.kv")

local TARGETS = table.concat({
  "# 功能集需求",
  "",
  "- `not-a-tag`",
  "",
  "# 任务分类（tag）",
  "",
  "- `feature`：新增功能",
  "- `bugfix`：缺陷修复",
  "- `custom`：自定义",
  "",
  "# 其他",
  "",
  "- `ignored`：不属于 tag",
}, "\n")

describe("kv.parse_tags", function()
  it("only collects backticked list items from the tag section", function()
    eq({ "feature", "bugfix", "custom" }, kv.parse_tags(TARGETS))
  end)

  it("returns an empty list for content without the section", function()
    eq({}, kv.parse_tags("# 功能集需求\n\n- `feature`\n"))
  end)

  it("tolerates non-string content", function()
    eq({}, kv.parse_tags(nil))
  end)
end)

describe("kv.tag_values", function()
  it("reads TARGETS.md from the loop root", function()
    local tmp = require("helpers.tmp")
    local dir = tmp.dir("kv-tags")
    local file = io.open(dir .. "/TARGETS.md", "w")
    file:write(TARGETS)
    file:close()
    eq({ "feature", "bugfix", "custom" }, kv.tag_values(dir))
  end)

  it("falls back to the builtin tags when the file is missing", function()
    local tmp = require("helpers.tmp")
    local dir = tmp.dir("kv-tags-missing")
    eq(kv.FALLBACK_TAGS, kv.tag_values(dir))
  end)
end)

describe("kv.config_tags", function()
  local tmp = require("helpers.tmp")

  local function write_config(body)
    local dir = tmp.dir("kv-cfg-tags")
    local path = dir .. "/loop.config.json"
    tmp.write(path, body)
    return path
  end

  it("returns the configured tag names", function()
    local path = write_config([[
{"version":1,"tags":[
  {"name":"feature","description":"新增功能"},
  {"name":"bugfix"}
]}
]])
    eq({ "feature", "bugfix" }, kv.config_tags(path))
  end)

  it("returns nil when the file is missing", function()
    local dir = tmp.dir("kv-cfg-tags-missing")
    eq(nil, kv.config_tags(dir .. "/loop.config.json"))
    eq(nil, kv.config_tags(nil))
  end)

  it("returns nil for malformed json", function()
    eq(nil, kv.config_tags(write_config("{not json")))
  end)

  it("returns nil when tags is not a list", function()
    eq(nil, kv.config_tags(write_config([[{"tags":{"name":"feature"}}]])))
    eq(nil, kv.config_tags(write_config([[{"tags":"feature"}]])))
  end)

  it("returns nil for an empty tags array", function()
    eq(nil, kv.config_tags(write_config([[{"tags":[]}]])))
  end)

  it("returns nil when an entry has no usable name", function()
    eq(nil, kv.config_tags(write_config([[{"tags":[{"description":"x"}]}]])))
    eq(nil, kv.config_tags(write_config([[{"tags":[{"name":1}]}]])))
  end)

  it("rejects names outside the kebab-case pattern", function()
    for _, name in ipairs({ "Feature", "a_b", "-lead", "", "a.b" }) do
      local path = write_config('{"tags":[{"name":"' .. name .. '"}]}')
      eq(nil, kv.config_tags(path), name)
    end
  end)

  it("accepts kebab-case names", function()
    local path = write_config([[{"tags":[{"name":"a"},{"name":"a-b--c"}]}]])
    eq({ "a", "a-b--c" }, kv.config_tags(path))
  end)
end)

local function tasks()
  return {
    { id = "#1", title = "一", status = "done", deps = {} },
    { id = "#2", title = "二", status = "pending", deps = { "#1" } },
    { id = "#3", title = "三", status = "pending", deps = { "#2" } },
    { id = "#4", title = "四", status = "pending", deps = {} },
  }
end

describe("kv.would_cycle", function()
  it("rejects the task itself", function()
    eq(true, kv.would_cycle(tasks(), "#2", "#2"))
  end)

  it("rejects a direct dependency that already depends on the task", function()
    eq(true, kv.would_cycle(tasks(), "#2", "#3"))
  end)

  it("rejects a transitive cycle", function()
    local list = tasks()
    list[1].deps = { "#3" }
    eq(true, kv.would_cycle(list, "#2", "#1"))
  end)

  it("accepts unrelated tasks and existing valid dependencies", function()
    eq(false, kv.would_cycle(tasks(), "#2", "#1"))
    eq(false, kv.would_cycle(tasks(), "#2", "#4"))
  end)
end)

describe("kv.dependency_candidates", function()
  it("excludes the task itself and cycle-forming candidates", function()
    local result = kv.dependency_candidates(tasks(), "#2")
    local ids = {}
    for _, item in ipairs(result.selectable) do
      ids[#ids + 1] = item.id
    end
    eq({ "#1", "#4" }, ids)
    eq(2, result.hidden)
  end)
end)

describe("kv.deps_arg", function()
  it("joins ids with commas", function()
    eq("#1,#4", kv.deps_arg({ "#1", "#4" }))
  end)

  it("returns an empty string for an empty list", function()
    eq("", kv.deps_arg({}))
  end)
end)

describe("kv.touch_paths", function()
  it("trims, drops blanks and dedupes in order", function()
    eq(
      { "lua/a.lua", "tests/a_spec.lua", "doc/a.txt" },
      kv.touch_paths({ " lua/a.lua ", "", "tests/a_spec.lua", "lua/a.lua", "doc/a.txt" })
    )
  end)
end)
