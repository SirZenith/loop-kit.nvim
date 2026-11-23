-- Unit tests for the pure layout calculator used by multi-line card values.
local layout = require("loop-kit.layout")
local util = require("loop-kit.util")

local function rstrip(text)
  return (text:gsub(" +$", ""))
end

describe("layout.compute", function()
  it("wraps on character boundaries without losing characters", function()
    local lines = {
      "lua/with space/a.lua",
      "文档/详情窗/键值对卡片分组/实现方案/这是一个很长的中文路径文档.md",
      "mixed 中英文 and spaces/路径/file-name.lua",
    }
    for _, width in ipairs({ 12, 25, 31 }) do
      local rows = layout.compute(width, lines)
      local pieces = {}
      for _, row in ipairs(rows) do
        pieces[#pieces + 1] = rstrip(row)
        local content = rstrip(row)
        truthy(
          util.display_width(content) <= width or vim.fn.strchars(content) == 1,
          "rows must fit the width unless a single character is wider: " .. width
        )
      end
      eq(table.concat(lines), table.concat(pieces))
    end
  end)

  it("keeps every row at the available width", function()
    local lines = {
      "lua/with space/a.lua",
      "文档/详情窗/键值对卡片分组/实现方案/这是一个很长的中文路径文档.md",
    }
    for _, width in ipairs({ 12, 25, 31 }) do
      for _, row in ipairs(layout.compute(width, lines)) do
        eq(width, util.display_width(row))
      end
    end
  end)

  it("trims row tails instead of overflowing the width", function()
    local rows, width = layout.compute(5, { "abcd efghi" })
    eq(5, width)
    eq(2, #rows)
    for _, row in ipairs(rows) do
      eq(5, util.display_width(row))
    end

    local shrunk, shrunk_width = layout.compute(5, { "abcd efghi" }, { shrink = true })
    eq(5, shrunk_width)
    for _, row in ipairs(shrunk) do
      eq(5, util.display_width(row))
    end
  end)

  it("keeps every input element on its own set of rows", function()
    local rows = layout.compute(10, { "aaaaaa", "bbbbbb" })
    eq(2, #rows)
    eq("aaaaaa", rstrip(rows[1]))
    eq("bbbbbb", rstrip(rows[2]))
  end)

  it("pads left, right and center by display width", function()
    eq({ "ab        ", "中文      " }, (layout.compute(10, { "ab", "中文" })))
    eq({ "        ab", "      中文" }, (layout.compute(10, { "ab", "中文" }, { align = "right" })))
    eq({ "    ab    ", "   中文   " }, (layout.compute(10, { "ab", "中文" }, { align = "center" })))
  end)

  it("falls back to left alignment for unknown values", function()
    eq(
      { "ab        ", "中文      " },
      (layout.compute(10, { "ab", "中文" }, { align = "middle" }))
    )
  end)

  it("shrinks to the widest wrapped row when requested", function()
    local lines = { "abc", "abcdefg" }
    local wide, wide_width = layout.compute(20, lines)
    local narrow, narrow_width = layout.compute(20, lines, { shrink = true })

    eq(20, wide_width)
    eq(7, narrow_width)
    for _, row in ipairs(wide) do
      eq(20, util.display_width(row))
    end
    eq(2, #narrow)
    for _, row in ipairs(narrow) do
      eq(7, util.display_width(row))
    end
    eq(rstrip(wide[1]), rstrip(narrow[1]))
    eq(rstrip(wide[2]), rstrip(narrow[2]))
  end)

  it("returns the clamped available width by default", function()
    local rows, width = layout.compute(20, { "abc" })
    eq(20, width)
    eq("abc                 ", rows[1])
  end)

  it("handles empty input and empty rows", function()
    local rows, width = layout.compute(5, {})
    eq(0, #rows)
    eq(5, width)

    local empty = layout.compute(5, { "" })
    eq(1, #empty)
    eq("     ", empty[1])

    local shrunk = layout.compute(5, { "" }, { shrink = true })
    eq(1, #shrunk)
    eq(1, util.display_width(shrunk[1]))
  end)

  it("clamps widths of nil and non-positive values to one", function()
    local nil_width = layout.compute(nil, { "abc" })
    eq(1, util.display_width(nil_width[1]))
    eq("abc", table.concat({ nil_width[1], nil_width[2], nil_width[3] }))

    eq(1, util.display_width(layout.compute(0, { "abc" })[1]))
    eq(1, util.display_width(layout.compute(-4, { "abc" })[1]))
  end)

  it("gives an over-wide single character its own row without extra blanks", function()
    local rows = layout.compute(1, { "中" })
    eq(1, #rows)
    eq("中", rows[1])
    eq(2, util.display_width(rows[1]))
  end)
end)
