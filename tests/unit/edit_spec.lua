-- Unit tests for loop-kit.edit: target resolution, stage validation and the
-- loop-cli argument assembly used by the field edit actions.
local render = require("loop-kit.render")
local edit = require("loop-kit.edit")
local actions_mod = require("loop-kit.actions")
local state_mod = require("loop-kit.state")
local kv = require("loop-kit.kv")
local paths = require("helpers.paths")

local function make_task(overrides)
  local task = {
    id = "#11",
    title = "看板编辑",
    status = "pending",
    tag = "feature",
    origin = "human",
    openAt = "2026-11-22T10:00:00+08:00",
    desc = "第一行\n第二行",
    userPrompt = "请实现\n细节",
    stagePrompt = {
      spec = "阶段正文\n更多正文",
      ["a.b"] = "外部阶段",
    },
    flow = "quick",
    isPrivateDesc = false,
    blockedReason = "第一行原因\n第二行原因",
    touch = { "lua/loop-kit/edit.lua" },
  }
  for key, value in pairs(overrides or {}) do
    task[key] = value
  end
  return task
end

describe("edit.target_at", function()
  it("maps title, desc and user prompt anchors", function()
    local task = make_task()
    local rendered = render.detail(task, { tasks_by_id = { [task.id] = task } })
    local fields = rendered.fields

    eq({ kind = "title" }, edit.target_at(rendered, rendered.title_line))
    eq({ kind = "desc" }, edit.target_at(rendered, fields.desc))
    eq({ kind = "desc" }, edit.target_at(rendered, fields.desc_content))
    eq({ kind = "desc" }, edit.target_at(rendered, fields.desc_content + 1))
    eq({ kind = "user_prompt" }, edit.target_at(rendered, fields.userPrompt))
    eq({ kind = "user_prompt" }, edit.target_at(rendered, fields.userPrompt_content))
  end)

  it("maps stage headings to rename and body lines to content", function()
    local task = make_task()
    local rendered = render.detail(task, { tasks_by_id = { [task.id] = task } })
    local fields = rendered.fields
    local heading = fields["stagePrompt.spec"]

    eq({ kind = "stage_new" }, edit.target_at(rendered, fields.stagePrompt))
    eq({ kind = "stage_rename", stage = "spec" }, edit.target_at(rendered, heading))
    eq({ kind = "stage_content", stage = "spec" }, edit.target_at(rendered, heading + 1))
    eq(
      { kind = "stage_content", stage = "spec" },
      edit.target_at(rendered, fields["stagePrompt.spec.content"])
    )
    eq(
      { kind = "stage_rename", stage = "a.b" },
      edit.target_at(rendered, fields["stagePrompt.a.b"])
    )
  end)

  it("marks metadata and analysis lines readonly", function()
    local task = make_task()
    local rendered = render.detail(task, {
      tasks_by_id = { [task.id] = task },
      analysis = { summary = "先做 #11", outstanding = 1, eligible = true },
    })
    local fields = rendered.fields

    for _, line in ipairs({
      fields.id,
      fields.status,
      fields.blockedReason,
      fields.blockedReason_content,
      fields.meta,
      fields.decide,
      fields.analysis,
    }) do
      local target = edit.target_at(rendered, line)
      eq("readonly", target.kind)
      truthy(target.message and target.message ~= "", "readonly lines need a hint")
    end
  end)

  it("maps key/value metadata lines to their own editors", function()
    local task = make_task()
    local rendered = render.detail(task, { tasks_by_id = { [task.id] = task } })
    local fields = rendered.fields

    for _, name in ipairs(edit.KV_FIELDS) do
      eq({ kind = name }, edit.target_at(rendered, fields[name]))
    end
    eq({ kind = "isPrivateDesc" }, edit.target_at(rendered, fields.isPrivateDesc))
    truthy(fields.isPrivateDesc > fields.meta, "isPrivateDesc follows meta")
    eq({ kind = "touch" }, edit.target_at(rendered, fields.touch))
    -- Continuation rows (additional touch paths) belong to the touch field.
    local multi = make_task({ touch = { "lua/loop-kit/edit.lua", "tests/unit/edit_spec.lua" } })
    local multi_rendered = render.detail(multi, { tasks_by_id = { [multi.id] = multi } })
    eq({ kind = "touch" }, edit.target_at(multi_rendered, multi_rendered.fields.touch + 1))
  end)

  it("explains lifecycle-only lines", function()
    local task = make_task()
    local rendered = render.detail(task, { tasks_by_id = { [task.id] = task } })
    local fields = rendered.fields

    for _, line in ipairs({ fields.origin, fields.openAt, fields.closedAt, fields.hash }) do
      local target = edit.target_at(rendered, line)
      eq("readonly", target.kind)
      truthy(target.message and target.message ~= "", "lifecycle lines need a hint")
    end
  end)

  it("maps empty placeholders to their editable targets", function()
    local task = make_task({ desc = "", userPrompt = "" })
    task.stagePrompt = nil
    local rendered = render.detail(task, { tasks_by_id = { [task.id] = task } })
    local fields = rendered.fields

    eq({ kind = "desc" }, edit.target_at(rendered, fields.desc_content))
    eq({ kind = "user_prompt" }, edit.target_at(rendered, fields.userPrompt_content))
    eq({ kind = "stage_new" }, edit.target_at(rendered, fields.stagePrompt_content))
  end)

  it("returns nil without a render", function()
    eq(nil, edit.target_at(nil, 1))
  end)
end)

describe("edit.is_valid_stage", function()
  it("accepts builtin stages and dotted external names", function()
    for _, name in ipairs(edit.BUILTIN_STAGES) do
      truthy(edit.is_valid_stage(name), name .. " should be valid")
    end
    truthy(edit.is_valid_stage("a.b"))
  end)

  it("rejects empty, spaced and non-dotted names", function()
    falsy(edit.is_valid_stage(""))
    falsy(edit.is_valid_stage("spec "))
    falsy(edit.is_valid_stage("阶段"))
    falsy(edit.is_valid_stage("a b.c"))
  end)
end)

describe("actions stage edit arguments", function()
  local function new_actions()
    local calls = {}
    local task = make_task()
    local state = state_mod.new():get("/tmp/loopkit-edit-unit-" .. tostring(math.random(1e8)))
    state:set_tasks({ task })
    state:select(task.id)
    local actions = actions_mod.new({
      root = "/tmp/loopkit-edit-unit",
      state = state,
      source = {
        snapshot = nil,
        list = function(_, cb)
          if cb then
            cb({ ok = true, tasks = { task } })
          end
        end,
      },
      ask = function(_, cb)
        cb(true)
      end,
      input = function(_, cb)
        cb("x")
      end,
      notify = function() end,
      reload = function(cb)
        if cb then
          cb({ ok = true, tasks = { task } })
        end
      end,
      exec = function(command, args, opts, cb)
        calls[#calls + 1] = { command = command, args = args, opts = opts }
        cb({ ok = true, data = task })
      end,
    })
    return actions, calls
  end

  it("renames a stage in one edit call", function()
    local actions, calls = new_actions()
    local done = false
    actions:rename_stage_prompt("#11", "spec", "new.spec", "旧内容", function()
      done = true
    end)
    eq(true, done)
    eq(1, #calls)
    eq("edit", calls[1].command)
    eq({
      "#11",
      "--stage-prompt-file",
      "new.spec=-",
      "--stage-prompt",
      "spec=",
    }, calls[1].args)
    eq("旧内容", calls[1].opts.stdin)
  end)

  it("toggles isPrivateDesc through the private command", function()
    local actions, calls = new_actions()
    local done = false
    actions:set_is_private_desc("#11", true, function()
      done = true
    end)
    eq(true, done)
    eq(1, #calls)
    eq("private", calls[1].command)
    eq({ "#11", "--on" }, calls[1].args)

    actions:set_is_private_desc("#11", false, function() end)
    eq(2, #calls)
    eq("private", calls[2].command)
    eq({ "#11", "--off" }, calls[2].args)
  end)

  it("deletes a stage with an empty assignment", function()
    local actions, calls = new_actions()
    local done = false
    actions:delete_stage_prompt("#11", "spec", function()
      done = true
    end)
    eq(true, done)
    eq(1, #calls)
    eq({ "#11", "--stage-prompt", "spec=" }, calls[1].args)
  end)

  it("rejects an unknown tag without calling loop-cli", function()
    local actions, calls = new_actions()
    local result
    actions:add_task("新任务", "bug", function(res)
      result = res
    end)
    eq(0, #calls)
    truthy(result)
    eq("invalid", result.code)
    truthy(result.message:find("分类 tag 无效", 1, true))
  end)
end)

describe("edit.tag_list", function()
  local function write_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local fd = assert(io.open(path, "w"))
    fd:write(content)
    fd:close()
  end

  it("reads the tag section and falls back to builtins", function()
    local root = vim.fn.tempname()
    write_file(root .. "/loop.config.json", [[{"loopRoot":".pi/loop-kit"}]])
    write_file(
      root .. "/.pi/loop-kit/TARGETS.md",
      "# 任务分类（tag）\n\n- `feature`：新增\n- `custom`：自定义\n\n# 其它\n\n- `ignored`：不是 tag\n"
    )

    local tags = edit.tag_list(root)
    truthy(vim.tbl_contains(tags, "feature"))
    truthy(vim.tbl_contains(tags, "custom"))
    falsy(vim.tbl_contains(tags, "ignored"))
    truthy(edit.valid_tag(root, "custom"))
    falsy(edit.valid_tag(root, "bugfix"))

    local fallback_root = vim.fn.tempname()
    truthy(edit.valid_tag(fallback_root, "feature"))
    falsy(edit.valid_tag(fallback_root, "custom"))
  end)
end)

local function write_text(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

local function tags_json(names)
  local entries = {}
  for _, name in ipairs(names) do
    entries[#entries + 1] = string.format('{"name":%q}', name)
  end
  return '{"version":1,"provider":"local","loopRoot":".loop","tags":['
    .. table.concat(entries, ",")
    .. "]}"
end

local function targets_md(names)
  local lines = { "# 任务分类（tag）", "" }
  for _, name in ipairs(names) do
    lines[#lines + 1] = "- `" .. name .. "`"
  end
  return table.concat(lines, "\n") .. "\n"
end

describe("edit.tag_list sources", function()
  it("prefers config tags over the TARGETS section", function()
    local root = vim.fn.tempname()
    write_text(root .. "/loop.config.json", tags_json({ "feature", "custom" }))
    write_text(root .. "/.loop/TARGETS.md", targets_md({ "feature", "targets-only" }))
    eq({ "feature", "custom" }, edit.tag_list(root))
  end)

  it("falls back to the TARGETS section when config tags are unusable", function()
    local root = vim.fn.tempname()
    write_text(root .. "/loop.config.json", '{"version":1,"loopRoot":".loop","tags":[]}')
    write_text(root .. "/.loop/TARGETS.md", targets_md({ "feature", "custom" }))
    eq({ "feature", "custom" }, edit.tag_list(root))
  end)

  it("falls back to builtins when neither source is usable", function()
    local root = vim.fn.tempname()
    eq(kv.FALLBACK_TAGS, edit.tag_list(root))
  end)
end)

describe("edit.tag_list cache", function()
  local base_sec = os.time() - 100

  it("invalidates when loop.config.json changes", function()
    local root = vim.fn.tempname()
    local cfg = root .. "/loop.config.json"
    write_text(cfg, tags_json({ "one" }))
    write_text(root .. "/.loop/TARGETS.md", targets_md({ "target" }))
    vim.uv.fs_utime(cfg, base_sec, base_sec)
    eq({ "one" }, edit.tag_list(root))

    write_text(cfg, tags_json({ "two" }))
    vim.uv.fs_utime(cfg, base_sec, base_sec)
    eq({ "one" }, edit.tag_list(root), "unchanged mtime keeps the cache")

    vim.uv.fs_utime(cfg, base_sec + 5, base_sec + 5)
    eq({ "two" }, edit.tag_list(root), "config change invalidates the cache")
  end)

  it("invalidates when TARGETS.md changes", function()
    local root = vim.fn.tempname()
    write_text(root .. "/loop.config.json", '{"version":1,"loopRoot":".loop"}')
    local targets = root .. "/.loop/TARGETS.md"
    write_text(targets, targets_md({ "alpha" }))
    vim.uv.fs_utime(targets, base_sec, base_sec)
    eq({ "alpha" }, edit.tag_list(root))

    write_text(targets, targets_md({ "beta" }))
    vim.uv.fs_utime(targets, base_sec, base_sec)
    eq({ "alpha" }, edit.tag_list(root), "unchanged mtime keeps the cache")

    vim.uv.fs_utime(targets, base_sec + 5, base_sec + 5)
    eq({ "beta" }, edit.tag_list(root), "TARGETS change invalidates the cache")
  end)
end)

describe("edit.valid_tag strictness", function()
  it("only accepts members of the effective set", function()
    local root = vim.fn.tempname()
    write_text(root .. "/loop.config.json", tags_json({ "custom" }))
    truthy(edit.valid_tag(root, "custom"))
    falsy(edit.valid_tag(root, "feature"))

    local fallback = vim.fn.tempname()
    truthy(edit.valid_tag(fallback, "chore"))
    falsy(edit.valid_tag(fallback, "custom"))
  end)
end)

describe("board tag entry", function()
  it("uses edit.tag_list instead of reading TARGETS directly", function()
    local fd = assert(io.open(paths.root .. "/lua/loop-kit/ui/board.lua", "r"))
    local source = fd:read("*a")
    fd:close()

    local start = source:find("function Board:_edit_tag", 1, true)
    local stop = source:find("function Board:_edit_deps", 1, true)
    truthy(start and stop and stop > start, "_edit_tag block should exist")

    local body = source:sub(start, stop - 1)
    falsy(body:find("kv.tag_values", 1, true), "tag picker must not bypass edit.tag_list")
    truthy(body:find("edit_ui.tag_list", 1, true), "tag picker should call edit.tag_list")
  end)
end)

describe("loop.config schema tags", function()
  local function load(path)
    local fd = assert(io.open(path, "r"))
    local body = fd:read("*a")
    fd:close()
    return vim.json.decode(body)
  end

  local files = {
    paths.root .. "/.pi/loop-kit/schema/loop.config.schema.json",
    paths.root .. "/tests/test-loop/.pi/loop-kit/schema/loop.config.schema.json",
  }

  it("declares the tags shape identically in both copies", function()
    local first = load(files[1]).properties.tags
    truthy(first, "schema should declare properties.tags")
    eq("array", first.type)
    eq(1, first.minItems)
    eq("object", first.items.type)
    eq(false, first.items.additionalProperties)
    eq({ "name" }, first.items.required)
    eq("^[a-z0-9][a-z0-9-]*$", first.items.properties.name.pattern)
    eq("string", first.items.properties.description.type)
    eq(first, load(files[2]).properties.tags)
  end)
end)
