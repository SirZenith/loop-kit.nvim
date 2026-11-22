-- Field pickers: a single-select wrapper over vim.ui.select and a floating
-- multi-select. The selection model is pure (`new_model`, `move`, `toggle`,
-- `result`) so it can be unit tested without a UI.
local M = {}

local ns = vim.api.nvim_create_namespace("loop-kit-ui-picker")
local MARK_SELECTED = "▣"
local MARK_UNSELECTED = "▢"
local SELECTED_HL = "LoopKitSelected"

--- Build a selection model.
--- items: array of { value, label, selected } or bare values.
function M.new_model(items)
  local model = { items = {}, cursor = 1 }
  for _, item in ipairs(items or {}) do
    if type(item) == "table" then
      model.items[#model.items + 1] = {
        value = item.value,
        label = tostring(item.label or item.value),
        selected = item.selected == true,
      }
    else
      model.items[#model.items + 1] = {
        value = item,
        label = tostring(item),
        selected = false,
      }
    end
  end
  if #model.items == 0 then
    model.cursor = 0
  end
  return model
end

--- Move the cursor by `delta`, wrapping at both ends.
function M.move(model, delta)
  local count = #model.items
  if count == 0 then
    model.cursor = 0
    return 0
  end
  local cursor = model.cursor
  if cursor < 1 or cursor > count then
    cursor = 1
  end
  cursor = ((cursor - 1 + delta) % count) + 1
  model.cursor = cursor
  return cursor
end

--- Toggle the item at `index` (defaults to the cursor).
function M.toggle(model, index)
  index = index or model.cursor
  local item = model.items[index]
  if not item then
    return nil
  end
  item.selected = not item.selected
  return item.selected
end

--- Selected values in candidate order.
function M.result(model)
  local values = {}
  for _, item in ipairs(model.items or {}) do
    if item.selected then
      values[#values + 1] = item.value
    end
  end
  return values
end

function M.selected_count(model)
  return #M.result(model)
end

--- Selection marker for a checkbox: filled when selected, hollow otherwise.
function M.marker(selected)
  return selected and MARK_SELECTED or MARK_UNSELECTED
end

--- One display line for a multi-select item: `> ▣ label` on the cursor row.
function M.item_line(item, is_cursor)
  return string.format("%s %s %s", is_cursor and ">" or " ", M.marker(item.selected), item.label)
end

--- Display lines plus selected-marker highlight ranges for a multi model.
--- The marker starts after the one-column cursor prefix and a space.
function M.multi_lines(model)
  local lines, marks = {}, {}
  for index, item in ipairs(model.items) do
    lines[#lines + 1] = M.item_line(item, index == model.cursor)
    if item.selected then
      marks[#marks + 1] = {
        line = index,
        col_start = 2,
        col_end = 2 + #MARK_SELECTED,
        hl_group = SELECTED_HL,
      }
    end
  end
  return lines, marks
end

--- Single choice with a `（当前）` marker. Selecting the current value is a
--- no-op; the current value is appended when it is not among the candidates.
--- opts: { items, current, prompt, select?, on_choice(value|nil) }
function M.select_one(opts)
  opts = opts or {}
  local entries = {}
  local seen = {}
  for _, item in ipairs(opts.items or {}) do
    local value, label
    if type(item) == "table" then
      value, label = item.value, item.label or item.value
    else
      value, label = item, item
    end
    if value ~= nil and not seen[value] then
      seen[value] = true
      entries[#entries + 1] = { value = value, label = tostring(label) }
    end
  end
  if opts.current ~= nil and not seen[opts.current] then
    entries[#entries + 1] = { value = opts.current, label = tostring(opts.current) }
    seen[opts.current] = true
  end

  local select = opts.select or vim.ui.select
  select(entries, {
    prompt = opts.prompt,
    format_item = function(item)
      if item.value == opts.current then
        return item.label .. "（当前）"
      end
      return item.label
    end,
  }, function(item)
    if opts.on_choice then
      opts.on_choice(item and item.value or nil)
    end
  end)
end

--- Floating multi-select. Space toggles, j/k and <C-n>/<C-p> move, Enter
--- confirms, Esc/q cancels.
--- opts: { items, title?, hidden?, width?, height?, on_confirm(values),
---         on_cancel?() }
function M.multi(opts)
  opts = opts or {}
  local model = M.new_model(opts.items)
  local hidden = opts.hidden or 0
  local width = opts.width or math.min(72, math.max(36, vim.o.columns - 10))
  local height = opts.height
  if height == nil then
    height = math.min(math.max(#model.items + 3, 4), math.max(4, vim.o.lines - 8))
  end
  local row = math.max(1, math.floor((vim.o.lines - height) / 2))
  local col = math.max(1, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = opts.title or "选择依赖",
  })

  local closed = false
  local handle = { model = model, buf = buf, win = win }

  local function draw()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines, marks = M.multi_lines(model)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Space 切换 · Enter 确认 · Esc 取消"
    if hidden > 0 then
      lines[#lines + 1] = string.format("已隐藏 %d 项（自身或循环依赖）", hidden)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    for _, mark in ipairs(marks) do
      pcall(
        vim.api.nvim_buf_add_highlight,
        buf,
        ns,
        mark.hl_group,
        mark.line - 1,
        mark.col_start,
        mark.col_end
      )
    end
    if vim.api.nvim_win_is_valid(win) then
      local cursor = math.max(1, model.cursor)
      pcall(vim.api.nvim_win_set_cursor, win, { cursor, 0 })
    end
  end

  function handle:close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  function handle:confirm()
    if closed then
      return
    end
    local values = M.result(model)
    self:close()
    if opts.on_confirm then
      opts.on_confirm(values)
    end
  end

  function handle:cancel()
    if closed then
      return
    end
    self:close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  function handle:is_open()
    return not closed
  end

  local keys = {
    ["<Space>"] = function()
      M.toggle(model)
      draw()
    end,
    ["j"] = function()
      M.move(model, 1)
      draw()
    end,
    ["k"] = function()
      M.move(model, -1)
      draw()
    end,
    ["<C-n>"] = function()
      M.move(model, 1)
      draw()
    end,
    ["<C-p>"] = function()
      M.move(model, -1)
      draw()
    end,
    ["<CR>"] = function()
      handle:confirm()
    end,
    ["<Esc>"] = function()
      handle:cancel()
    end,
    ["q"] = function()
      handle:cancel()
    end,
  }
  for lhs, fn in pairs(keys) do
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  draw()
  return handle
end

return M
