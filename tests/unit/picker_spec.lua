local picker = require("loop-kit.ui.picker")

describe("picker model", function()
  it("toggles only the chosen item", function()
    local model = picker.new_model({ { value = "#1", selected = true }, { value = "#2" } })
    eq(false, picker.toggle(model, 1))
    eq(true, picker.toggle(model, 2))
    eq({ "#2" }, picker.result(model))
  end)

  it("moves with wrapping", function()
    local model = picker.new_model({ "#1", "#2", "#3" })
    eq(1, model.cursor)
    eq(2, picker.move(model, 1))
    eq(3, picker.move(model, 1))
    eq(1, picker.move(model, 1))
    eq(3, picker.move(model, -1))
  end)

  it("returns selected values in candidate order", function()
    local model = picker.new_model({
      { value = "#3", selected = true },
      { value = "#1", selected = false },
      { value = "#2", selected = true },
    })
    eq({ "#3", "#2" }, picker.result(model))
    eq(2, picker.selected_count(model))
  end)
end)

describe("picker.select_one", function()
  it("marks the current value and appends it when missing", function()
    local seen
    picker.select_one({
      items = { "feature", "bugfix" },
      current = "custom",
      select = function(items, opts, cb)
        seen = { items = items, opts = opts }
        cb(items[#items])
      end,
      on_choice = function(value)
        seen.chosen = value
      end,
    })
    eq(3, #seen.items)
    eq("custom", seen.items[3].value)
    eq("custom（当前）", seen.opts.format_item(seen.items[3]))
    eq("feature", seen.opts.format_item(seen.items[1]))
    eq("custom", seen.chosen)
  end)

  it("reports cancellation as nil", function()
    local chosen = "unset"
    picker.select_one({
      items = { "feature" },
      current = "feature",
      select = function(_, _, cb)
        cb(nil)
      end,
      on_choice = function(value)
        chosen = value
      end,
    })
    eq(nil, chosen)
  end)
end)

describe("picker.multi markers", function()
  it("shows ▢ / ▣ and highlights only the selected markers", function()
    local handle = picker.multi({
      items = {
        { value = "#3", label = "#3 done", selected = true },
        { value = "#1", label = "#1 pending" },
        { value = "#2", label = "#2 doing", selected = true },
      },
      title = "依赖",
    })
    local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, 3, false)
    eq("> ▣ #3 done", lines[1])
    eq("  ▢ #1 pending", lines[2])
    eq("  ▣ #2 doing", lines[3])

    local marks = vim.api.nvim_buf_get_extmarks(handle.buf, -1, 0, -1, { details = true })
    local highlighted = {}
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].hl_group then
        highlighted[#highlighted + 1] = { line = mark[2], col = mark[3], hl_group = mark[4].hl_group }
      end
    end
    eq({ { line = 0, col = 2, hl_group = "LoopKitPickerSelected" },
         { line = 2, col = 2, hl_group = "LoopKitPickerSelected" } }, highlighted)
    handle:close()
  end)

  it("keeps the marker column aligned for plain and decorated items", function()
    local model = picker.new_model({ "plain", { value = "decorated", label = "decorated label" } })
    model.items[1].selected = true
    local lines = picker.multi_lines(model)
    eq("> ▣ plain", lines[1])
    eq("  ▢ decorated label", lines[2])
  end)
end)
