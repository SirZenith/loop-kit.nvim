-- Zero-dependency help float listing the default keymap.
--
-- The float is a scratch buffer and owns a single global window/buffer pair.
-- Toggling it never touches the board selection or the list cursor.
local M = {}

local state = { buf = nil, win = nil, augroup = nil }

M.KEY_LINES = {
  { "j / k", "上下移动（数字前缀表示重复，如 3j）" },
  { "gg / G", "跳到首个 / 最后一个任务" },
  { "<C-u> / <C-d>", "向上 / 向下半页" },
  { "<C-b> / <C-f>", "向上 / 向下一页" },
  { "<CR>", "跳到详情窗口" },
  { "/", "关键字筛选（id/title/tag/desc）" },
  { "<Esc>", "清除关键字" },
  { "s / A", "循环筛选 / 显示全部" },
  { "S", "循环排序（id/closed/status）" },
  { "r / R", "刷新缓存 / 同步远端" },
  { "c / d / D", "认领 / 完成 / 强制完成" },
  { "b", "阻塞（需填写原因）" },
  { "u", "解除阻塞（blocked → pending，直接执行）" },
  { "e", "编辑光标处的字段（标题/描述/提示词/阶段/tag/deps/doc/flow/写集/isPrivateDesc）" },
  { "a", "新建任务（标题 + 分类 tag）" },
  { ":w / <Esc>", "编辑中保存 / 放弃（normal 模式）" },
  { "x", "移除任务（总是确认）" },
  { "o", "打开当前任务的 doc" },
  { "F / P / T / M", "flow / private / touch / meta" },
  { "n", "decide 建议" },
  { "? / q", "帮助 / 关闭看板" },
}

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function close_state()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.buf, state.win, state.augroup = nil, nil, nil
end

function M.close()
  close_state()
end

--- Lines shown in the float. `keys` may override the last hint line.
function M.lines(keys)
  local lines = {
    "LoopKit 键位（默认键位，可在 setup({ keys = ... }) 中覆盖或设为 false）",
    "",
  }
  for _, item in ipairs(M.KEY_LINES) do
    lines[#lines + 1] = string.format("  %-14s %s", item[1], item[2])
  end
  local custom = {}
  if type(keys) == "table" then
    for lhs, action in pairs(keys) do
      if action ~= false and type(action) == "string" then
        local default = false
        for _, item in ipairs(M.KEY_LINES) do
          if item[1]:find(lhs, 1, true) then
            default = true
            break
          end
        end
        if not default then
          custom[#custom + 1] = string.format("  %-14s %s", lhs, action)
        end
      end
    end
  end
  if #custom > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "自定义"
    table.sort(custom)
    vim.list_extend(lines, custom)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "按 q、<Esc> 或 ? 关闭帮助"
  return lines
end

--- Open the help float (no-op when already open).
--- opts: keys, parent (window id).
function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    pcall(vim.api.nvim_set_current_win, state.win)
    return true
  end

  local lines = M.lines(opts.keys)
  local width = 46
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 4)
  end
  width = math.min(width, math.max(20, vim.o.columns - 4))
  local height = math.min(#lines, math.max(5, vim.o.lines - 6))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "loopkit-help"

  local parent = opts.parent
  if not parent or not vim.api.nvim_win_is_valid(parent) then
    parent = vim.api.nvim_get_current_win()
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " LoopKit 帮助 ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  state.buf, state.win = buf, win
  state.augroup = vim.api.nvim_create_augroup("LoopKitHelp" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    pattern = tostring(win),
    callback = function()
      if state.win == win then
        state.buf, state.win, state.augroup = nil, nil, nil
      end
    end,
  })

  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function()
      M.close()
    end, { buffer = buf, nowait = true, silent = true })
  end

  return true
end

--- Toggle the float; returns true when it is open afterwards.
function M.toggle(opts)
  if M.is_open() then
    M.close()
    return false
  end
  M.open(opts)
  return true
end

return M
