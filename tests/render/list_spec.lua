-- Render tests for the board list pane.
local list_ui = require("loop-kit.ui.list")
local state_mod = require("loop-kit.state")

local FIXTURE = {
  { id = "#1", title = "Alpha pending", status = "pending", tag = "feat", desc = "first item" },
  { id = "#2", title = "Beta doing", status = "doing", tag = "fix", desc = "second item" },
  { id = "#3", title = "Gamma blocked", status = "blocked", tag = "feat", desc = "Alpha in description" },
  { id = "#4", title = "Delta done", status = "done", tag = "chore", desc = "last item" },
  { id = "#7", title = "Epsilon pending", status = "pending", tag = "docs", desc = "docs only" },
}

local function make_list()
  local state = state_mod.new():get("/tmp/loopkit-list-render")
  state:set_filter("all")
  state:set_tasks(FIXTURE)
  local buf = vim.api.nvim_create_buf(false, true)
  return list_ui.new({ state = state, buf = buf, setup = false }), state, buf
end

local function buffer_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function contains(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function visible_ids(state)
  local ids = {}
  for _, task in ipairs(state:visible_tasks()) do
    ids[#ids + 1] = task.id
  end
  return ids
end

describe("ui.list: fixed fixture", function()
  it("renders status groups, icons and the selected row", function()
    local list, state, buf = make_list()
    state:set_sort("status")
    state:select("#2")
    local rendered = list:draw()
    local lines = buffer_lines(buf)

    truthy(contains(lines, "Doing (1)"), "doing group header")
    truthy(contains(lines, "Pending (2)"), "pending group header")
    truthy(contains(lines, "Blocked (1)"), "blocked group header")
    truthy(contains(lines, "Done (1)"), "done group header")
    truthy(contains(lines, "┌ #2 · ◐ doing · fix"), "doing first row")
    truthy(contains(lines, "└ Beta doing"), "doing second row")
    truthy(contains(lines, "┌ #1 · ○ pending · feat"), "pending first row")

    eq("#2", state:selected_id())
    eq("#2", rendered.line_map[rendered.selected_line])
    eq("LoopKitSelected", rendered.line_hl[rendered.selected_line])
    eq(nil, rendered.line_map[1], "group headers are not task rows")
  end)

  it("uses a flat two-line list by default", function()
    local list, _, buf = make_list()
    list:draw()
    local lines = buffer_lines(buf)

    falsy(contains(lines, "Doing (1)"), "flat list has no status header")
    truthy(contains(lines, "┌ #7 · ○ pending · docs"), "first task first row")
    truthy(contains(lines, "└ Epsilon pending"), "first task second row")
    local first = nil
    for index, line in ipairs(lines) do
      if line:find("┌ #7", 1, true) then
        first = index
      end
    end
    truthy(first, "first task is present")
    eq("", lines[first + 2], "one blank line between adjacent tasks")
    match(lines[first + 3], "^┌ #4", "next task follows the blank line")
  end)

  it("returns per-segment highlight ranges for two-line rows", function()
    local list, _, _ = make_list()
    local rendered = list:draw()

    local groups = {}
    for _, range in ipairs(rendered.ranges) do
      groups[range.hl_group] = true
    end
    truthy(groups.LoopKitMuted, "prefix range")
    truthy(groups.LoopKitId, "id range")
    truthy(groups.LoopKitPending, "pending status range")
    truthy(groups.LoopKitDoing, "doing status range")
    truthy(groups.LoopKitTag, "tag range")

    local id_line = rendered.id_to_line["#2"]
    eq("#2", rendered.line_map[id_line + 1], "second line maps to the same task")
    local title_ranges = {}
    for _, range in ipairs(rendered.ranges) do
      if range.line == id_line + 1 then
        title_ranges[#title_ranges + 1] = range
      end
    end
    eq(1, #title_ranges, "title text stays in the normal text colour")
    eq("LoopKitMuted", title_ranges[1].hl_group)
    eq(0, title_ranges[1].col_start)
    eq(#"└ ", title_ranges[1].col_end)
  end)

  it("navigates visible rows and clamps at both ends", function()
    local list, state = make_list()
    list:draw()

    eq({ "#7", "#4", "#3", "#2", "#1" }, visible_ids(state))

    eq("#4", list:move(1))
    eq("#3", list:move(1))
    eq("#1", list:move(10), "clamps at the last row")
    eq("#2", list:move(-1))
    eq("#7", list:move(-10), "clamps at the first row")
    eq("#7", state:selected_id())
  end)

  it("narrows by filter, keyword and tag without changing the fixture", function()
    local list, state = make_list()

    state:set_filter("pending")
    eq({ "#7", "#1" }, visible_ids(state))

    state:set_query("ALPHA")
    eq({ "#1" }, visible_ids(state), "case-insensitive title match")

    state:set_filter("all")
    state:set_query("alpha in description")
    eq({ "#3" }, visible_ids(state), "desc match")

    state:set_query("DOCS")
    eq({ "#7" }, visible_ids(state), "tag match")

    eq(5, #state.tasks, "filtering never mutates the fixture")
  end)

  it("keeps loading, empty, no-match and error states distinguishable", function()
    local list, _, buf = make_list()
    local seen = {}

    list:notice("loading", "加载中…正在读取 loop-cli。")
    seen.loading = table.concat(buffer_lines(buf), "\n")
    eq("loading", list.notice_kind)

    list:notice("empty", "（无任务）当前项目还没有任务。")
    seen.empty = table.concat(buffer_lines(buf), "\n")
    eq("empty", list.notice_kind)

    list:notice("no_match", "（无匹配）筛选 open 下没有任务。")
    seen.no_match = table.concat(buffer_lines(buf), "\n")
    eq("no_match", list.notice_kind)

    list:notice("error", "加载失败：loop-cli 不存在")
    seen.error = table.concat(buffer_lines(buf), "\n")
    eq("error", list.notice_kind)

    neq(seen.loading, seen.empty)
    neq(seen.loading, seen.no_match)
    neq(seen.loading, seen.error)
    neq(seen.empty, seen.no_match)
    neq(seen.empty, seen.error)
    neq(seen.no_match, seen.error)
    match(seen.error, "加载失败")
  end)

  it("returns to task rows after a notice", function()
    local list, _, buf = make_list()
    list:notice("empty", "（无任务）")
    list:draw()
    eq(nil, list.notice_kind)
    truthy(contains(buffer_lines(buf), "#2"), "task id is back")
    truthy(contains(buffer_lines(buf), "Beta doing"), "task title is back")
  end)

  it("shows and clears the edit info panel", function()
    local list, _, buf = make_list()
    list:draw()
    local before = table.concat(buffer_lines(buf), "\n")

    list:show_edit({ id = "#11", title = "看板编辑", target_label = "任务描述" })
    local shown = buffer_lines(buf)
    eq("", shown[1])
    eq("", shown[#shown])
    truthy(contains(shown, "编辑中 · #11 看板编辑"))
    truthy(contains(shown, "目标：任务描述"))
    truthy(contains(shown, ":w 保存并应用 · <Esc> 放弃（normal 模式）"))
    eq("edit", list.notice_kind)

    list:clear_edit()
    list:draw()
    eq(nil, list.notice_kind)
    eq(before, table.concat(buffer_lines(buf), "\n"))
    truthy(contains(buffer_lines(buf), "Beta doing"))
  end)
end)
