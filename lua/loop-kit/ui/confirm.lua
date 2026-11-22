-- Floating confirmation dialog.
--
-- The prompt is plain text; the options live in a single horizontal button
-- row at the bottom. `h` / `l` (and <Left> / <Right>) move the selection,
-- <CR> confirms, <Esc> / `q` cancels. The model and layout are pure functions
-- so the geometry can be tested without a real window.
--
-- Zero dependencies: the float mirrors the picker/help windows (scratch
-- buffer, minimal style, rounded border) and highlights the active button
-- with the shared `LoopKitSelected` group.
local M = {}

local ns = vim.api.nvim_create_namespace("loop-kit-ui-confirm")
local SELECTED_HL = "LoopKitSelected"
local DEFAULT_TITLE = " 确认 "

--- The single live confirm, if any. Opening a new one cancels the old one so
--- keystrokes cannot land in a stale window.
local active = nil

local function normalize_option(option)
  if type(option) == "table" then
    local label = option.label
    if label == nil then
      label = option.value
    end
    local value = option.value
    if value == nil then
      value = label
    end
    return {
      label = label == nil and "" or tostring(label),
      value = value,
    }
  end
  return { label = tostring(option), value = option }
end

--- Build the pure model. `options` entries are strings or { label, value }.
function M.new_model(opts)
  opts = opts or {}
  local options = {}
  for _, option in ipairs(opts.options or {}) do
    options[#options + 1] = normalize_option(option)
  end

  local count = #options
  local cursor
  if count == 0 then
    cursor = 0
  else
    cursor = math.floor(tonumber(opts.default) or 1)
    if cursor < 1 then
      cursor = 1
    elseif cursor > count then
      cursor = count
    end
  end

  return {
    prompt = opts.prompt == nil and "" or tostring(opts.prompt),
    options = options,
    cursor = cursor,
  }
end

--- Move the cursor by `delta`, wrapping at both ends.
function M.move(model, delta)
  local count = #model.options
  if count == 0 then
    model.cursor = 0
    return 0
  end
  model.cursor = ((model.cursor - 1 + (delta or 0)) % count) + 1
  return model.cursor
end

--- Return the selected value and its 1-based index.
function M.current(model)
  local option = model.options[model.cursor]
  if not option then
    return nil, model.cursor
  end
  return option.value, model.cursor
end

local function wrap_line(line, inner)
  local wrapped = {}
  local current = {}
  local width = 0
  for index = 0, vim.fn.strchars(line) - 1 do
    local char = vim.fn.strcharpart(line, index, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if width + char_width > inner and #current > 0 then
      wrapped[#wrapped + 1] = table.concat(current)
      current = {}
      width = 0
    end
    current[#current + 1] = char
    width = width + char_width
  end
  wrapped[#wrapped + 1] = table.concat(current)
  return wrapped
end

local function wrap_prompt(prompt, inner)
  local lines = {}
  for paragraph in (prompt .. "\n"):gmatch("(.-)\n") do
    vim.list_extend(lines, wrap_line(paragraph, inner))
  end
  return lines
end

local function button_label(option)
  return "[ " .. option.label .. " ]"
end

local function button_width(model)
  local width = 0
  for index, option in ipairs(model.options) do
    if index > 1 then
      width = width + 2
    end
    width = width + vim.fn.strdisplaywidth(button_label(option))
  end
  return width
end

--- Render the model as text lines plus the byte spans of each button.
---
--- `spans` entries are { row, col, end_col, index } where `row` is 0-based and
--- `col` / `end_col` are 0-based byte offsets into that line.
function M.lines(model, width)
  width = math.max(6, math.floor(tonumber(width) or 40))
  local inner = math.max(1, width - 4)
  local lines = wrap_prompt(model.prompt, inner)

  local row = #lines + 1 -- 0-based index of the button row: one blank line follows the prompt
  local parts = {}
  local spans = {}
  local col = 0
  for index, option in ipairs(model.options) do
    local label = button_label(option)
    spans[index] = { row = row, col = col, end_col = col + #label, index = index }
    parts[#parts + 1] = label
    col = col + #label
    if index < #model.options then
      parts[#parts + 1] = "  "
      col = col + 2
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = table.concat(parts)
  return lines, spans
end

local function resolve_width(model, requested)
  if requested then
    return math.max(6, math.floor(tonumber(requested) or 0))
  end
  local columns = vim.o.columns or 80
  local width = math.min(72, math.max(28, columns - 10))
  return math.max(width, button_width(model) + 4)
end

--- Open the confirm float.
---
--- opts = { prompt, options, default?, title?, width?,
---          on_select = fun(value, index), on_cancel = fun() }
--- Exactly one callback runs, after the window and its focus are restored.
function M.open(opts)
  opts = opts or {}
  local model = M.new_model({
    prompt = opts.prompt,
    options = opts.options,
    default = opts.default,
  })
  local width = resolve_width(model, opts.width)
  local lines = M.lines(model, width)
  local height = #lines

  if active and active:is_open() then
    active:cancel()
  end

  local prev_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local columns = vim.o.columns or 80
  local screen_lines = vim.o.lines or 24
  local row = math.max(0, math.floor((screen_lines - height) / 2) - 1)
  local col = math.max(0, math.floor((columns - width) / 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = opts.title or DEFAULT_TITLE,
    title_pos = "center",
    focusable = true,
    noautocmd = true,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  local finished = false
  local augroup
  local handle = {
    buf = buf,
    win = win,
    model = model,
    width = width,
  }

  local function restore_focus()
    if prev_win and vim.api.nvim_win_is_valid(prev_win) then
      if vim.api.nvim_get_current_win() ~= prev_win then
        pcall(vim.api.nvim_set_current_win, prev_win)
      end
    end
  end

  local function teardown()
    if active == handle then
      active = nil
    end
    if augroup then
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
      augroup = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local function finish(kind)
    if finished then
      return
    end
    finished = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    teardown()
    restore_focus()
    if kind == "select" then
      local value, index = M.current(model)
      if opts.on_select then
        opts.on_select(value, index)
      end
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function draw()
    if finished or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local new_lines, spans = M.lines(model, width)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    local span = spans[model.cursor]
    if span then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, span.row, span.col, {
        end_col = span.end_col,
        hl_group = SELECTED_HL,
        priority = 100,
      })
    end
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, span and span.row + 1 or 1), 0 })
  end

  local function step(delta)
    M.move(model, delta)
    draw()
  end

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "loop-kit: " .. desc,
    })
  end

  handle.is_open = function()
    return not finished and vim.api.nvim_win_is_valid(win)
  end

  --- Silent close: no callback (used when the caller takes over).
  handle.close = function()
    if finished then
      return
    end
    finished = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    teardown()
    restore_focus()
  end

  --- Close and run `on_cancel` (skipped if already finished).
  handle.cancel = function()
    finish("cancel")
  end

  handle.select = function()
    finish("select")
  end

  handle.current = function()
    return M.current(model)
  end

  map("h", function()
    step(-1)
  end, "confirm previous option")
  map("<Left>", function()
    step(-1)
  end, "confirm previous option")
  map("l", function()
    step(1)
  end, "confirm next option")
  map("<Right>", function()
    step(1)
  end, "confirm next option")
  map("<CR>", function()
    finish("select")
  end, "confirm selection")
  map("<Esc>", function()
    finish("cancel")
  end, "cancel confirm")
  map("q", function()
    finish("cancel")
  end, "cancel confirm")

  augroup = vim.api.nvim_create_augroup("LoopKitConfirmWin" .. win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      if finished then
        return
      end
      finished = true
      if active == handle then
        active = nil
      end
      restore_focus()
      if opts.on_cancel then
        opts.on_cancel()
      end
    end,
  })

  draw()
  active = handle
  return handle
end

--- Generic prompt: cb(value, index); cancellation passes nil.
function M.ask(prompt, opts, cb)
  opts = opts or {}
  return M.open({
    prompt = prompt,
    options = opts.options or { "确认", "取消" },
    default = opts.default,
    title = opts.title,
    width = opts.width,
    on_select = function(value, index)
      cb(value, index)
    end,
    on_cancel = function()
      cb(nil)
    end,
  })
end

--- Boolean confirm. Cancellation maps to `false`; `opts.default` 2 selects
--- the cancel button (used by destructive callers).
function M.boolean(prompt, cb, opts)
  opts = opts or {}
  return M.open({
    prompt = prompt,
    options = {
      { label = "确认", value = true },
      { label = "取消", value = false },
    },
    default = opts.default or 1,
    title = opts.title,
    width = opts.width,
    on_select = function(value)
      cb(value == true)
    end,
    on_cancel = function()
      cb(false)
    end,
  })
end

--- Choice prompt with vim.ui.select-compatible semantics: the selected string
--- (or the option's `value`) is passed through, cancellation passes nil.
function M.choice(prompt, options, cb, opts)
  opts = opts or {}
  return M.open({
    prompt = prompt,
    options = options,
    default = opts.default,
    title = opts.title,
    width = opts.width,
    on_select = function(value)
      cb(value)
    end,
    on_cancel = function()
      cb(nil)
    end,
  })
end

return M
