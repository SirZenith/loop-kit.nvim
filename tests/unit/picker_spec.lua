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
