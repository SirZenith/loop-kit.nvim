local render = require("loop-kit.render")
local state_mod = require("loop-kit.state")
local highlights = require("loop-kit.highlights")

local function task(id, status, overrides)
  return vim.tbl_extend("force", {
    id = id,
    title = "task " .. id,
    status = status,
    tag = "feat",
    desc = "",
  }, overrides or {})
end

local function sample()
  return {
    task("#10", "pending"),
    task("#2", "pending", { title = "second", tag = "ui" }),
    task("#3", "doing", { title = "third", tag = "cli" }),
    task("#1", "blocked"),
    task("#11", "pending"),
    task("#12", "done", { title = "finished" }),
  }
end

local function new_state(tasks, filter)
  local st = state_mod.new():get("/proj/render")
  st:set_filter(filter or "open")
  st:set_tasks(tasks or sample())
  return st
end

local function mapped_ids(out)
  local ids = {}
  for line = 1, #out.lines do
    if out.line_map[line] then
      ids[#ids + 1] = out.line_map[line]
    end
  end
  return ids
end

local function find_line(lines, needle)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return index, line
    end
  end
  return nil
end

describe("render.list", function()
  it("renders grouped rows with status icons, ids, titles and tags", function()
    local out = render.list(new_state():groups())

    local doing = out.id_to_line["#3"]
    truthy(doing, "doing task row missing")
    match(out.lines[doing], "third", "title missing from row")
    match(out.lines[doing], "cli", "tag missing from row")
    match(out.lines[doing], "◐", "doing icon missing")

    local pending = out.id_to_line["#2"]
    match(out.lines[pending], "○", "pending icon missing")

    local blocked = out.id_to_line["#1"]
    match(out.lines[blocked], "✕", "blocked icon missing")

    local header = find_line(out.lines, "Doing")
    truthy(header, "group header missing")
    falsy(out.line_map[header], "group header must not be in the line map")
    eq("LoopKitHeader", out.line_hl[header])
  end)

  it("keeps the default open filter free of done tasks", function()
    local out = render.list(new_state():groups())

    eq(nil, find_line(out.lines, "#12"), "done task leaked into open view")
    eq(nil, find_line(out.lines, "Done"), "done group header leaked into open view")
    for _, id in ipairs(mapped_ids(out)) do
      neq("#12", id)
    end
  end)

  it("orders each group by numeric id and maps every task row once", function()
    local out = render.list(new_state():groups())

    eq({ "#3", "#2", "#10", "#11", "#1" }, mapped_ids(out))
    eq(5, vim.tbl_count(out.line_map))

    for id, line in pairs(out.id_to_line) do
      eq(id, out.line_map[line], "id_to_line must agree with line_map")
      match(out.lines[line], id, "row text must carry its id")
    end
  end)

  it("survives long and multi-byte titles without breaking the map", function()
    local long = string.rep("很长的标题", 80)
    local out = render.list(new_state({
      task("#1", "doing", { title = long }),
      task("#2", "pending", { title = string.rep("wide ", 200) }),
    }):groups())

    eq(2, vim.tbl_count(out.line_map))
    eq("#1", out.line_map[out.id_to_line["#1"]])
    eq("#2", out.line_map[out.id_to_line["#2"]])
    truthy(find_line(out.lines, long), "full long title must be rendered")
  end)

  it("exposes the selected row without disturbing the mapping", function()
    local out = render.list(new_state():groups(), { selected_id = "#2" })

    eq("#2", out.line_map[out.selected_line])
    eq("LoopKitSelected", out.line_hl[out.selected_line])
  end)
end)

describe("render.detail", function()
  it("renders deps and doc with explicit empty values", function()
    local out = render.detail(task("#7", "doing", {
      deps = { "#2", "#5" },
      doc = ".pi/loop-kit/docs/nvim/plan.md",
      desc = "hello",
    }))

    local rendered = table.concat(out.lines, "\n")
    truthy(rendered:find("deps: #2, #5", 1, true), "deps missing")
    truthy(rendered:find("doc: .pi/loop-kit/docs/nvim/plan.md", 1, true), "doc missing")

    local empty = render.detail(task("#8", "pending"))
    local text = table.concat(empty.lines, "\n")
    match(text, "deps: %(none%)", "empty deps must be explicit")
    match(text, "doc: %(none%)", "missing doc must be explicit")
  end)

  it("distinguishes unknown touch from an empty touch array", function()
    local null_touch = render.detail(task("#1", "pending", { touch = vim.NIL }))
    match(table.concat(null_touch.lines, "\n"), "touch: unknown")

    local missing_touch = render.detail(task("#2", "pending"))
    match(table.concat(missing_touch.lines, "\n"), "touch: unknown")

    local empty_touch = render.detail(task("#3", "pending", { touch = {} }))
    local empty_text = table.concat(empty_touch.lines, "\n")
    match(empty_text, "touch: %(empty%)")
    falsy(empty_text:find("unknown", 1, true), "empty array must not read as unknown")

    local paths = render.detail(task("#4", "pending", { touch = { "lua/**", "tests/*.lua" } }))
    local path_text = table.concat(paths.lines, "\n")
    match(path_text, "lua/[*][*]")
    match(path_text, "tests/[*].lua")
  end)

  it("keeps multi-paragraph markdown descriptions verbatim", function()
    local desc = table.concat({
      "first paragraph 中文",
      "",
      "```lua",
      "local x = 1",
      "```",
      "",
      "- item one",
      "- item two",
    }, "\n")

    local out = render.detail(task("#9", "doing", { desc = desc }))
    local text = table.concat(out.lines, "\n")
    truthy(text:find(desc, 1, true), "description must be copied without rewrapping")
  end)

  it("applies defaults for flow, private and meta fields", function()
    local out = render.detail(task("#5", "doing"))
    local text = table.concat(out.lines, "\n")
    match(text, "flow: %(default%)")
    match(text, "meta: %(unset%)")
    eq(nil, text:find("private:", 1, true), "private is only rendered when set")

    local with_fields = render.detail(task("#6", "doing", {
      flow = { "research", "spec", "commit" },
      isPrivateDesc = false,
      meta = { branch = "main", baseSha = "abc123" },
    }))
    local fields_text = table.concat(with_fields.lines, "\n")
    match(fields_text, "flow: research > spec > commit")
    match(fields_text, "private: false")
    match(fields_text, "meta: branch=main baseSha=abc123")
  end)
end)

describe("loop-kit highlights", function()
  local links = {
    LoopKitPending = "Comment",
    LoopKitDoing = "Constant",
    LoopKitDone = "String",
    LoopKitBlocked = "WarningMsg",
    LoopKitId = "Identifier",
    LoopKitTitle = "Title",
    LoopKitTag = "Special",
    LoopKitMuted = "Comment",
    LoopKitHeader = "Label",
    LoopKitError = "ErrorMsg",
    LoopKitSelected = "Visual",
  }

  it("defines default-linked groups without shipping a colorscheme", function()
    highlights.setup()

    for name, link in pairs(links) do
      local hl = vim.api.nvim_get_hl(0, { name = name, link = true })
      eq(link, hl.link, name .. " must link to " .. link)
      eq(true, hl.default, name .. " must be defined with default=true")
    end
  end)

  it("never overrides a user definition and is safe to call twice", function()
    vim.api.nvim_set_hl(0, "LoopKitTitle", { fg = 0x123456 })

    highlights.setup()
    highlights.setup()

    local hl = vim.api.nvim_get_hl(0, { name = "LoopKitTitle" })
    eq(0x123456, hl.fg, "user highlight must win over default=true")

    vim.api.nvim_set_hl(0, "LoopKitTitle", { link = "Title", default = true })
  end)
end)
