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
  local ids, seen = {}, {}
  for line = 1, #out.lines do
    local id = out.line_map[line]
    if id and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
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
    local st = new_state()
    st:set_sort("status")
    local out = render.list(st:groups())

    local doing = out.id_to_line["#3"]
    truthy(doing, "doing task row missing")
    match(out.lines[doing], "#3", "id missing from first row")
    match(out.lines[doing], "◐", "doing icon missing")
    match(out.lines[doing], "cli", "tag missing from first row")
    match(out.lines[doing + 1], "third", "title missing from second row")

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
    local st = new_state()
    st:set_sort("status")
    local out = render.list(st:groups())

    eq({ "#3", "#2", "#10", "#11", "#1" }, mapped_ids(out))
    eq(10, vim.tbl_count(out.line_map))

    for id, line in pairs(out.id_to_line) do
      eq(id, out.line_map[line], "id_to_line must agree with line_map")
      match(out.lines[line], id, "first row must carry its id")
    end
  end)

  it("survives long and multi-byte titles without breaking the map", function()
    local long = string.rep("很长的标题", 80)
    local out = render.list(new_state({
      task("#1", "doing", { title = long }),
      task("#2", "pending", { title = string.rep("wide ", 200) }),
    }):groups())

    eq(4, vim.tbl_count(out.line_map))
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

describe("render.list card style", function()
  local util = require("loop-kit.util")

  local function card_state(tasks)
    return new_state(tasks or {
      task("#1", "pending", { title = "Alpha task", tag = "feat" }),
      task("#2", "doing", { title = "Beta doing", tag = "fix" }),
      task("#3", "done", { title = "Gamma done", tag = "chore" }),
    }, "all")
  end

  local function card(opts)
    opts = opts or {}
    return render.list(card_state(opts.tasks):groups(), {
      style = "card",
      width = opts.width or 40,
      selected_id = opts.selected_id,
    })
  end

  it("renders a four-line card with a status header", function()
    local out = card({ selected_id = "#2", width = 40 })

    eq(12, #out.lines)
    local first = out.lines[out.id_to_line["#2"]]
    eq("╭─ #2" .. string.rep(" ", 24) .. " ◐ doing ─╮", first)
    eq(nil, first:sub(#"╭─ #2" + 1, #"╭─ #2" + 24):find("─", 1, true), "the id/status gap is filled with spaces")
    for offset = 0, 3 do
      eq(40, util.display_width(out.lines[out.id_to_line["#2"] + offset]))
    end
  end)

  it("puts the truncated title and the meta line inside the box", function()
    local out = card({ selected_id = "#2" })
    local line = out.id_to_line["#2"]

    eq("│ " .. "Beta doing" .. string.rep(" ", 26) .. " │", out.lines[line + 1])
    eq("│ " .. "fix · human · auto" .. string.rep(" ", 18) .. " │", out.lines[line + 2])
    eq("╰" .. string.rep("─", 38) .. "╯", out.lines[line + 3])
  end)

  it("maps every card row to its task and drops blank separators", function()
    local out = card({ selected_id = "#1" })

    eq("#1", out.line_map[1])
    eq("#1", out.line_map[2])
    eq("#1", out.line_map[3])
    eq("#1", out.line_map[4])
    eq("#2", out.line_map[5])
    eq(1, out.id_to_line["#1"])
    eq("#1", out.line_map[out.selected_line])
    eq(nil, out.line_hl[out.selected_line])
  end)

  local function line_ranges(out, line)
    local list = {}
    for _, range in ipairs(out.ranges) do
      if range.line == line then
        list[#list + 1] = range
      end
    end
    table.sort(list, function(a, b)
      return a.col_start < b.col_start
    end)
    return list
  end

  local function owners(out, line)
    local map = {}
    for _, range in ipairs(line_ranges(out, line)) do
      for col = range.col_start + 1, range.col_end do
        map[col] = range.hl_group
      end
    end
    return map
  end

  local function assert_border(out, line, border, content)
    local text = out.lines[line]
    local map = owners(out, line)
    for col = 1, #text do
      local group = map[col]
      truthy(group, "uncovered byte at column " .. col .. " of line " .. line)
      if not (content and content[group]) then
        eq(border, group, "column " .. col .. " of line " .. line .. " must use " .. border)
      end
    end
  end

  it("highlights the whole border in the selected colour", function()
    local out = card({ selected_id = "#2" })
    local selected_line = out.id_to_line["#2"]
    local muted_line = out.id_to_line["#1"]

    assert_border(out, selected_line, "LoopKitCardSelected", {
      LoopKitId = true,
      LoopKitDoing = true,
    })
    assert_border(out, selected_line + 3, "LoopKitCardSelected")
    assert_border(out, muted_line, "LoopKitMuted", {
      LoopKitId = true,
      LoopKitPending = true,
    })
    assert_border(out, muted_line + 3, "LoopKitMuted")

    -- The vertical frame of the title and meta rows is border too.
    for offset = 1, 2 do
      local map = owners(out, selected_line + offset)
      for col = 1, #"│ " do
        eq("LoopKitCardSelected", map[col])
      end
      for col = #map - 1, #map do
        eq("LoopKitCardSelected", map[col])
      end
    end

    local status_seen = false
    for _, group in pairs(owners(out, selected_line)) do
      if group == "LoopKitDoing" then
        status_seen = true
      end
    end
    truthy(status_seen, "the status segment must keep its status colour")
  end)

  it("colours id, status, title and tag of a selected card", function()
    local out = card({ selected_id = "#2" })
    local line = out.id_to_line["#2"]

    eq("LoopKitId", owners(out, line)[#"╭─ " + 1], "selected id keeps its colour")
    eq("LoopKitDoing", owners(out, line)[out.lines[line]:find("◐ doing", 1, true)], "status keeps its colour")
    eq("Normal", owners(out, line + 1)[#"│ " + 1], "selected title uses the normal text colour")
    eq("LoopKitTag", owners(out, line + 2)[#"│ " + 1], "selected tag keeps its colour")
  end)

  it("mutes id, tag and title of unselected cards", function()
    local out = card({ selected_id = "#2" })
    local line = out.id_to_line["#1"]

    eq("LoopKitMuted", owners(out, line)[#"╭─ " + 1], "unselected id is muted")
    eq("LoopKitPending", owners(out, line)[out.lines[line]:find("○ pending", 1, true)], "status keeps its colour")
    eq("LoopKitMuted", owners(out, line + 1)[#"│ " + 1], "unselected title is muted")
    eq("LoopKitMuted", owners(out, line + 2)[#"│ " + 1], "unselected tag is muted")
  end)

  it("labels the meta line for string, table and default flows", function()
    local function meta(overrides)
      local tasks = {
        task("#5", "doing", vim.tbl_extend("force", {
          title = "Flow task",
          tag = "fix",
          origin = "human",
        }, overrides or {})),
      }
      local out = render.list(card_state(tasks):groups(), { style = "card", width = 40 })
      return out.lines[out.id_to_line["#5"] + 2]
    end

    local function boxed(text)
      return "│ " .. util.pad_display(text, 36) .. " │"
    end

    eq(boxed("fix · human · quick"), meta({ flow = "quick" }))
    eq(boxed("fix · human · custom"), meta({ flow = { "#1", "#2" } }))
    eq(boxed("fix · human · auto"), meta({}))
    eq(boxed("human · auto"), meta({ tag = "" }))
  end)

  it("keeps blank lines only before group headers in card mode", function()
    local st = card_state({
      task("#1", "pending", { title = "Alpha", tag = "feat" }),
      task("#2", "doing", { title = "Beta", tag = "fix" }),
      task("#3", "pending", { title = "Gamma", tag = "ui" }),
    })
    st:set_sort("status")
    local out = render.list(st:groups(), { style = "card", width = 40 })

    local blanks = {}
    for index, line in ipairs(out.lines) do
      if line == "" then
        blanks[#blanks + 1] = index
      end
    end
    local expected = {}
    for index, group in ipairs(out.groups) do
      if index > 1 then
        expected[#expected + 1] = group.header_line - 1
        eq("", out.lines[group.header_line - 1])
      end
      eq(nil, out.line_map[group.header_line])
    end
    eq(table.concat(expected, ","), table.concat(blanks, ","))

    local line = out.id_to_line["#1"]
    for offset = 0, 3 do
      eq("#1", out.line_map[line + offset])
    end
    eq("#3", out.line_map[line + 4], "cards of one group must not be separated")
  end)

  it("truncates long CJK titles with one ellipsis at the card width", function()
    local out = render.list(card_state({
      task("#9", "doing", { title = string.rep("超长中文标题", 8), tag = "feat" }),
    }):groups(), { style = "card", width = 24 })
    local line = out.id_to_line["#9"]

    for offset = 0, 3 do
      eq(24, util.display_width(out.lines[line + offset]))
    end
    truthy(out.lines[line + 1]:find("…", 1, true), "the title must end in an ellipsis")
    eq(1, select(2, out.lines[line + 1]:gsub("…", "")))
  end)

  it("keeps content range geometry identical on selected and unselected cards", function()
    local function snapshot(selected_id)
      local out = card({ selected_id = selected_id })
      local base = out.id_to_line["#2"]
      local got = {}
      for _, range in ipairs(out.ranges) do
        if range.line >= base and range.line <= base + 2 then
          got[#got + 1] = string.format("%d:%d:%d", range.line - base, range.col_start, range.col_end)
        end
      end
      return got
    end

    local unselected = snapshot(nil)
    local selected = snapshot("#2")
    eq(table.concat(unselected, "|"), table.concat(selected, "|"))
  end)

  it("falls back to compact rows for unknown styles", function()
    local compact = render.list(card_state():groups(), { width = 40 })
    local unknown = render.list(card_state():groups(), { style = "gallery", width = 40 })

    eq(table.concat(compact.lines, "\n"), table.concat(unknown.lines, "\n"))
  end)

  it("keeps four valid rows in a narrow card", function()
    local out = card({ width = 12 })
    local line = out.id_to_line["#1"]

    for offset = 0, 3 do
      eq(12, util.display_width(out.lines[line + offset]))
    end
  end)
end)

describe("render.detail", function()
  local util = require("loop-kit.util")

  local function card_bounds(out, title)
    local start
    for index, line in ipairs(out.lines) do
      if line:sub(1, #"╭─ ") == "╭─ " and line:find(title, 1, true) then
        start = index
        break
      end
    end
    truthy(start, "card " .. title .. " not found")
    local stop = start
    while stop < #out.lines and out.lines[stop]:find("╰", 1, true) == nil do
      stop = stop + 1
    end
    return start, stop
  end

  local function card_titles(out)
    local titles = {}
    for _, line in ipairs(out.lines) do
      local title = line:match("^╭─ ([^ ]+)")
      if title then
        titles[#titles + 1] = title
      end
    end
    return titles
  end

  local function slice_display(text, start_col, width)
    local pieces, col = {}, 0
    local count = vim.fn.strchars(text)
    for index = 0, count - 1 do
      local char = vim.fn.strcharpart(text, index, 1)
      local char_width = util.display_width(char)
      if col >= start_col and col + char_width <= start_col + width then
        pieces[#pieces + 1] = char
      end
      col = col + char_width
    end
    return table.concat(pieces)
  end

  local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
  end

  it("renders deps and doc with explicit empty values", function()
    local out = render.detail(task("#7", "doing", {
      deps = { "#2", "#5" },
      doc = ".pi/loop-kit/docs/nvim/plan.md",
      desc = "hello",
    }))

    local rendered = table.concat(out.lines, "\n")
    truthy(rendered:find("#2, #5", 1, true), "deps missing")
    truthy(rendered:find(".pi/loop-kit/docs/nvim/plan.md", 1, true), "doc missing")

    local empty = render.detail(task("#8", "pending"))
    local text = table.concat(empty.lines, "\n")
    match(text, "N/A", "empty deps must be explicit")
    match(text, "N/A", "missing doc must be explicit")
  end)

  it("marks dependency status with icons and status colours", function()
    local out = render.detail(task("#7", "doing", {
      deps = { "#2", "#3", "#4", "#5", "#9" },
    }), {
      tasks_by_id = {
        ["#2"] = task("#2", "pending"),
        ["#3"] = task("#3", "doing"),
        ["#4"] = task("#4", "done"),
        ["#5"] = task("#5", "blocked"),
      },
    })

    local line_no = out.fields.deps
    truthy(out.lines[line_no]:find("#2 ○, #3 ◐, #4 ●, #5 ✕, #9", 1, true), out.lines[line_no])
    local text = table.concat(out.lines, "\n")
    falsy(text:find("(pending)", 1, true), "dep state text must not be rendered")
    falsy(text:find("(done)", 1, true), "dep state text must not be rendered")

    local marks = {}
    for _, range in ipairs(out.highlights) do
      if range.line == line_no then
        local value = out.lines[line_no]:sub(range.col_start + 1, range.col_end)
        if value == "○" or value == "◐" or value == "●" or value == "✕" then
          marks[#marks + 1] = value .. "=" .. range.hl_group
        end
      end
    end
    eq({ "○=LoopKitPending", "◐=LoopKitDoing", "●=LoopKitDone", "✕=LoopKitBlocked" }, marks)
  end)

  it("renders missing or empty touch as N/A", function()
    local null_touch = render.detail(task("#1", "pending", { touch = vim.NIL }))
    match(table.concat(null_touch.lines, "\n"), "touch%s+N/A")

    local missing_touch = render.detail(task("#2", "pending"))
    match(table.concat(missing_touch.lines, "\n"), "touch%s+N/A")

    local empty_touch = render.detail(task("#3", "pending", { touch = {} }))
    local empty_text = table.concat(empty_touch.lines, "\n")
    match(empty_text, "touch%s+N/A")
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

  it("applies defaults for flow, isPrivateDesc and meta fields", function()
    local out = render.detail(task("#5", "doing"))
    local text = table.concat(out.lines, "\n")
    truthy(text:find("flow", 1, true))
    truthy(text:find("N/A", 1, true), "flow defaults to N/A")
    truthy(text:find("N/A", 1, true), "isPrivateDesc defaults to N/A")
    truthy(out.fields.isPrivateDesc > out.fields.meta, "isPrivateDesc must follow meta")

    local with_fields = render.detail(task("#6", "doing", {
      flow = { "research", "spec", "commit" },
      isPrivateDesc = false,
      meta = { branch = "main", baseSha = "abc123" },
    }))
    local fields_text = table.concat(with_fields.lines, "\n")
    truthy(fields_text:find("research > spec > commit", 1, true))
    truthy(with_fields.lines[with_fields.fields.isPrivateDesc]:find("false", 1, true))
    truthy(fields_text:find("branch=main baseSha=abc123", 1, true))
    truthy(with_fields.fields.isPrivateDesc > with_fields.fields.meta)
  end)

  it("highlights boolean values with the Constant group", function()
    local out = render.detail(task("#8", "doing", { isPrivateDesc = false }), {
      analysis = { summary = "ok", outstanding = 0, eligible = true, blocked = false, stuck = true },
    })

    local function hl_for(field, value)
      for _, range in ipairs(out.highlights) do
        if range.line == out.fields[field] then
          local line = out.lines[range.line]
          if line:sub(range.col_start + 1, range.col_end) == value then
            return range.hl_group
          end
        end
      end
    end

    eq("LoopKitDetailConstant", hl_for("isPrivateDesc", "false"))
    eq("LoopKitDetailConstant", hl_for("eligible", "true"))
    eq("LoopKitDetailConstant", hl_for("blocked", "false"))
    eq("LoopKitDetailConstant", hl_for("stuck", "true"))
  end)

  it("keeps unset booleans muted instead of Constant", function()
    local out = render.detail(task("#9", "doing"))
    local hl
    for _, range in ipairs(out.highlights) do
      if range.line == out.fields.isPrivateDesc then
        hl = range.hl_group
      end
    end
    eq("LoopKitDetailMuted", hl)
  end)

  it("draws grouped cards without rules, separated by a single blank line", function()
    local out = render.detail(task("#7", "doing", {
      deps = { "#2" },
      doc = "docs/plan.md",
      docParent = "docs/parent.md",
      specPrompt = "prompts/spec.md",
      researchPrompt = "prompts/research.md",
      codePrompt = "prompts/code.md",
      verifyPrompt = "prompts/verify.md",
      docTaskSplitPrompt = "prompts/split.md",
    }), { analysis = { summary = "ok", outstanding = 0, eligible = {}, blocked = {}, stuck = {} } })
    local lines = out.lines
    local f = out.fields

    -- No rule before the first group: title, blank, then the first card border.
    eq(4, f.id)
    eq("", lines[2])
    eq({ "状态信息", "依赖与文档", "提示词", "执行信息", "决策说明" }, card_titles(out))
    falsy(table.concat(lines, "\n"):find("---", 1, true), "rules must be gone")

    local groups = {
      { "id", "status", "tag", "origin", "openAt", "closedAt", "hash" },
      { "deps", "doc", "docParent" },
      { "specPrompt", "researchPrompt", "codePrompt", "verifyPrompt", "docTaskSplitPrompt" },
      { "flow", "touch", "meta", "isPrivateDesc" },
      { "decide", "analysis", "outstanding", "eligible", "blocked", "stuck" },
    }
    local titles = { "状态信息", "依赖与文档", "提示词", "执行信息", "决策说明" }
    local previous_stop
    for index, group in ipairs(groups) do
      local start, stop = card_bounds(out, titles[index])
      if previous_stop then
        eq(previous_stop + 2, start, "cards are separated by one blank line")
      end
      previous_stop = stop
      for position = 2, #group do
        eq(f[group[position - 1]] + 1, f[group[position]], group[position] .. " must stay inside its card")
      end
    end

    eq("", lines[previous_stop + 1])
    eq("# 任务描述", lines[previous_stop + 2])
  end)

  it("clamps the card width to 80 columns and follows narrow panes", function()
    local function border_width(pane)
      local out = render.detail(task("#7", "doing"), { width = pane })
      local line = out.lines[3]
      truthy(line:find("╭", 1, true) == 1, "expected a card border")
      return util.display_width(line)
    end

    eq(80, border_width(120))
    eq(50, border_width(50))
    eq(30, border_width(30))
    eq(20, border_width(10))
    eq(80, util.display_width(render.detail(task("#7", "doing")).lines[3]))
  end)

  it("left-aligns keys and right-aligns single-line values", function()
    local out = render.detail(task("#8", "doing", { hash = "abc123" }), { width = 50 })
    local start, stop = card_bounds(out, "状态信息")
    for line = start, stop do
      eq(50, util.display_width(out.lines[line]), out.lines[line])
    end
    for line = start + 1, stop - 1 do
      eq("│ ", vim.fn.strcharpart(out.lines[line], 0, 2))
      eq("│", vim.fn.strcharpart(out.lines[line], vim.fn.strchars(out.lines[line]) - 1, 1))
    end

    local hash_line = out.lines[out.fields.hash]
    eq("│ hash", vim.fn.strcharpart(hash_line, 0, 6))
    truthy(hash_line:find("abc123 │", 1, true), "value must end one space before the border: " .. hash_line)
  end)

  it("wraps long values across rows without ellipsis or lost characters", function()
    local doc = "文档/详情窗/键值对卡片分组/实现方案/这是一个很长的中文路径文档.md"
    local out = render.detail(task("#9", "doing", { doc = doc }), { width = 40 })
    local start, stop = card_bounds(out, "依赖与文档")
    local value_start = 2 + 9 + 2 -- deps/doc/docParent share a 9-column key column
    local value_width = (40 - 4) - 9 - 2
    local doc_line = out.fields.doc
    local next_anchor = out.fields.docParent
    truthy(doc_line and next_anchor and next_anchor > doc_line)

    local pieces = {}
    for line = doc_line, next_anchor - 1 do
      truthy(line >= start and line <= stop, "doc rows stay inside their card")
      local slice = slice_display(out.lines[line], value_start, value_width)
      falsy(slice:find("…", 1, true), "values must not be truncated")
      pieces[#pieces + 1] = trim(slice)
    end
    eq(doc, table.concat(pieces))
    truthy(#pieces > 1, "the long path must wrap")

    local first_slice = slice_display(out.lines[doc_line], value_start, value_width)
    truthy(first_slice:sub(1, 1) == " ", "first wrapped row is right aligned")
    for line = doc_line + 1, next_anchor - 1 do
      local slice = slice_display(out.lines[line], value_start, value_width)
      truthy(slice:sub(1, 1) ~= " ", "continuation rows start at the value column")
    end
  end)

  it("keeps dependency ids highlighted after wrapping", function()
    local deps = {}
    for index = 1, 20 do
      deps[index] = "#" .. (100 + index)
    end
    local out = render.detail(task("#7", "doing", { deps = deps }), { width = 30 })
    local start, stop = card_bounds(out, "依赖与文档")
    local ids = {}
    for _, range in ipairs(out.highlights) do
      if range.line >= start and range.line <= stop and range.hl_group == "LoopKitDetailId" then
        ids[#ids + 1] = out.lines[range.line]:sub(range.col_start + 1, range.col_end)
      end
    end
    eq(20, #ids)
    eq("#101", ids[1])
    eq("#120", ids[#ids])
  end)

  it("keeps path highlights and renders analysis as a card", function()
    local unset = render.detail(task("#8", "pending"))
    local doc_hl
    for _, range in ipairs(unset.highlights) do
      if range.line == unset.fields.doc then
        doc_hl = range.hl_group
      end
    end
    eq("LoopKitDetailMuted", doc_hl)
    truthy(unset.lines[unset.fields.doc]:find("N/A", 1, true))

    local touch = render.detail(task("#4", "pending", {
      touch = { "lua/a.lua", "tests/b_spec.lua" },
    }))
    local first = touch.fields.touch
    truthy(touch.lines[first]:find("lua/a.lua", 1, true))
    truthy(touch.lines[first + 1]:find("tests/b_spec.lua", 1, true))
    local path_marks = 0
    for _, range in ipairs(touch.highlights) do
      if range.hl_group == "LoopKitDetailPath" and range.line >= first and range.line <= first + 1 then
        path_marks = path_marks + 1
      end
    end
    eq(2, path_marks)

    local analysis = render.detail(task("#8", "doing"), {
      analysis = { summary = "ok", outstanding = 2, eligible = true, blocked = false, stuck = true },
    })
    truthy(analysis.fields.decide)
    truthy(analysis.lines[analysis.fields.decide]:find("ok", 1, true))
    truthy(analysis.lines[analysis.fields.outstanding]:find("2", 1, true))
    falsy(table.concat(analysis.lines, "\n"):find("  - outstanding", 1, true))
  end)

  it("wraps multi-line touch paths through the layout calculator", function()
    local paths = {
      "lua/with space/and more/x.lua",
      "tests/unit/layout_spec.lua",
    }
    local out = render.detail(task("#4", "pending", { touch = paths }), { width = 40 })
    local first = out.fields.touch
    truthy(first, "touch field missing")
    local meta = out.fields.meta
    truthy(meta and meta > first, "touch rows must precede the meta field")

    -- 执行信息 keys max out at "isPrivateDesc" (13): inner = 36, so key_col = 13
    -- and value_col = 36 - 13 - 2 = 21, with the value starting at column 17.
    local value_start, value_width = 17, 21
    local pieces = {}
    for line = first, meta - 1 do
      eq(40, util.display_width(out.lines[line]), "every touch row fills the card")
      local content = trim(slice_display(out.lines[line], value_start, value_width))
      pieces[#pieces + 1] = content

      local marks = {}
      for _, range in ipairs(out.highlights) do
        if range.line == line and range.hl_group == "LoopKitDetailPath" then
          marks[#marks + 1] = out.lines[line]:sub(range.col_start + 1, range.col_end)
        end
      end
      eq(1, #marks, "every wrapped touch row carries one path highlight")
      eq(content, marks[1], "path highlights must not cover padding spaces")
    end
    eq(table.concat(paths), table.concat(pieces))
    eq("lua/with space/and mo", pieces[1], "wrapping must not drop spaces")
    truthy(#pieces > #paths, "the long paths must wrap")
  end)

  it("keeps touch rows inside the card when a space lands on the wrap boundary", function()
    local path = "lua/abcdefghijklmnop qrstuvwxyz0123456789a"
    local out = render.detail(task("#4", "pending", { touch = { path } }), { width = 40 })
    local first = out.fields.touch
    local meta = out.fields.meta
    truthy(first and meta and meta > first, "touch rows must precede the meta field")

    local rows = 0
    for line = first, meta - 1 do
      eq(40, util.display_width(out.lines[line]), "wrapped touch row must fill the card")
      local marks = 0
      for _, range in ipairs(out.highlights) do
        if range.line == line and range.hl_group == "LoopKitDetailPath" then
          marks = marks + 1
        end
      end
      eq(1, marks, "every wrapped touch row carries one path highlight")
      rows = rows + 1
    end
    truthy(rows > 1, "the path must wrap")
  end)

  it("renders blockedReason as a readonly section before the description", function()
    local reason = "需要确认接口\n第二行原因"
    local out = render.detail(task("#7", "blocked", {
      desc = "任务描述正文",
      blockedReason = reason,
    }))
    local text = table.concat(out.lines, "\n")
    match(text, "# 阻塞原因")
    truthy(text:find(reason, 1, true), "blockedReason must be copied verbatim")
    truthy(out.fields.blockedReason < out.fields.desc)
    eq("需要确认接口", out.lines[out.fields.blockedReason_content])
    eq("第二行原因", out.lines[out.fields.blockedReason_content + 1])

    local without = render.detail(task("#8", "blocked"))
    eq(nil, without.fields.blockedReason, "empty blockedReason must not add a section")
    falsy(table.concat(without.lines, "\n"):find("# 阻塞原因", 1, true))
  end)
end)

describe("loop-kit highlights", function()
  local links = {
    LoopKitPending = "Comment",
    LoopKitDoing = "WarningMsg",
    LoopKitDone = "String",
    LoopKitBlocked = "Constant",
    LoopKitId = "Identifier",
    LoopKitTitle = "Title",
    LoopKitTag = "Special",
    LoopKitMuted = "Comment",
    LoopKitHeader = "Label",
    LoopKitError = "ErrorMsg",
    LoopKitSelected = "Visual",
    LoopKitCardSelected = "Special",
    LoopKitPickerSelected = "CursorLineNr",
  }

  it("defines default-linked groups without shipping a colorscheme", function()
    highlights.setup()

    for name, link in pairs(links) do
      local hl = vim.api.nvim_get_hl(0, { name = name, link = true })
      eq(link, hl.link, name .. " must link to " .. link)
      eq(true, hl.default, name .. " must be defined with default=true")
    end
  end)

  it("links the detail boolean value group to Constant", function()
    highlights.setup()

    local hl = vim.api.nvim_get_hl(0, { name = "LoopKitDetailConstant", link = true })
    eq("Constant", hl.link)
    eq(true, hl.default)
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
