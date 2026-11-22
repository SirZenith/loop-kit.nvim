-- Pure model/layout checks for the floating confirm component.
local confirm = require("loop-kit.ui.confirm")

local function bytes(text)
  return #text
end

describe("confirm model", function()
  it("normalizes string and { label, value } options", function()
    local model = confirm.new_model({
      prompt = "继续？",
      options = { "确认", { label = "放弃修改", value = false }, { value = "raw" } },
    })
    eq("继续？", model.prompt)
    eq({
      { label = "确认", value = "确认" },
      { label = "放弃修改", value = false },
      { label = "raw", value = "raw" },
    }, model.options)
    eq(1, model.cursor)
  end)

  it("clamps the default cursor to 1..n", function()
    local opts = { prompt = "p", options = { "a", "b" } }
    eq(1, confirm.new_model(vim.tbl_extend("force", opts, { default = 0 })).cursor)
    eq(1, confirm.new_model(vim.tbl_extend("force", opts, { default = -3 })).cursor)
    eq(2, confirm.new_model(vim.tbl_extend("force", opts, { default = 2 })).cursor)
    eq(2, confirm.new_model(vim.tbl_extend("force", opts, { default = 99 })).cursor)
  end)

  it("wraps the cursor at both ends", function()
    local model = confirm.new_model({ prompt = "p", options = { "a", "b", "c" } })
    eq(1, model.cursor)
    eq(3, confirm.move(model, -1))
    eq(2, confirm.move(model, -1))
    eq(1, confirm.move(model, -1))
    eq(2, confirm.move(model, 1))
    eq(3, confirm.move(model, 1))
    eq(1, confirm.move(model, 1))
  end)

  it("reports the current value and index", function()
    local model = confirm.new_model({
      prompt = "p",
      options = { { label = "保留", value = 1 }, { label = "删除", value = 2 } },
      default = 2,
    })
    local value, index = confirm.current(model)
    eq(2, value)
    eq(2, index)
  end)
end)

describe("confirm lines", function()
  it("wraps a CJK prompt by display width and appends the button row", function()
    local model = confirm.new_model({
      prompt = "是否确认删除当前任务？",
      options = { "确认", "取消" },
    })
    local lines = confirm.lines(model, 20)

    -- 1-column padding on both sides leaves 18 display columns = 9 CJK glyphs
    eq({
      " 是否确认删除当前任",
      " 务？",
      "",
      " [ 确认 ]  [ 取消 ]",
    }, lines)
  end)

  it("reports byte spans for every button", function()
    local model = confirm.new_model({
      prompt = "继续？",
      options = { "确认", "取消" },
    })
    local lines, spans = confirm.lines(model, 40)

    eq(3, #lines)
    -- width 40 -> 24 spare columns over margin + gap + margin -> 8 / 8 / 8
    local margin, gap = 8, 8
    local first = "[ 确认 ]"
    eq({ row = 2, col = margin, end_col = margin + bytes(first), index = 1 }, spans[1])
    eq({
      row = 2,
      col = margin + bytes(first) + gap,
      end_col = margin + bytes(first) + gap + bytes("[ 取消 ]"),
      index = 2,
    }, spans[2])
    eq(lines[3], string.rep(" ", margin) .. first .. string.rep(" ", gap) .. "[ 取消 ]")
  end)

  it("includes both window margins in the even distribution", function()
    local model = confirm.new_model({
      prompt = "p",
      options = { "a", "b", "c" },
    })
    local lines, spans = confirm.lines(model, 40)
    local row = lines[#lines]

    -- inset 38 columns, 23 spare over margin + 2 gaps + margin -> 6 / 6 / 5 / 6
    eq(7, spans[1].col) -- 1 column padding + 6 column margin
    eq(33, vim.fn.strdisplaywidth(row))
    eq(7, 40 - vim.fn.strdisplaywidth(row))
    eq(18, vim.fn.strdisplaywidth(row:sub(1, spans[2].col)))
    eq(28, vim.fn.strdisplaywidth(row:sub(1, spans[3].col)))
  end)

  it("falls back to packed two-space gaps when the row cannot be spread", function()
    local model = confirm.new_model({
      prompt = "p",
      options = { "确认", "取消" },
    })
    local lines = confirm.lines(model, 20)
    eq(" [ 确认 ]  [ 取消 ]", lines[#lines])
  end)

  it("insets every rendered line by one column on each side", function()
    local model = confirm.new_model({ prompt = "第一行\n\n第二行", options = { "好", "取消" } })
    local lines = confirm.lines(model, 40)

    eq(" 第一行", lines[1])
    eq(" 第二行", lines[3])
    eq("", lines[4])
    eq(" ", lines[5]:sub(1, 1))
    for index, line in ipairs(lines) do
      assert(vim.fn.strdisplaywidth(line) <= 38, "line " .. index .. " exceeds the inset width")
    end
  end)

  it("keeps byte offsets aligned with the rendered CJK button row", function()
    local model = confirm.new_model({
      prompt = "删除该阶段提示词条目？",
      options = { "删除", "取消" },
    })
    local lines, spans = confirm.lines(model, 30)
    local row = lines[#lines]

    local selected = row:sub(spans[2].col + 1, spans[2].end_col)
    eq("[ 取消 ]", selected)
    -- width 30 -> 14 spare columns over margin/gap/margin -> 5 / 4 / 5
    eq(vim.fn.strdisplaywidth("[ 删除 ]") + 5 + 4, vim.fn.strdisplaywidth(row:sub(1, spans[2].col)))
  end)

  it("handles multi-line prompts", function()
    local model = confirm.new_model({ prompt = "第一行\n第二行", options = { "好" } })
    eq({ " 第一行", " 第二行", "", string.rep(" ", 17) .. "[ 好 ]" }, confirm.lines(model, 40))
  end)
end)
