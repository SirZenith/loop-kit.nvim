-- Pure layout calculator for multi-line card values.
--
-- `compute` wraps every input line at character boundaries, pads each row to
-- the target width, and returns the flat row list plus the viewport width.
-- No buffer or window access happens here.
local util = require("loop-kit.util")

local M = {}

local ALIGNMENTS = { left = true, right = true, center = true }

local function clamp_width(value)
  local width = tonumber(value)
  if not width or width ~= width then
    width = 1
  end
  width = math.floor(width)
  if width < 1 then
    width = 1
  end
  return width
end

--- Wrap one line at character boundaries (never inside a character).
local function wrap_line(text, width)
  local rows = {}
  local row = {}
  local used = 0
  local count = vim.fn.strchars(text)
  for index = 0, count - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    local char_width = util.display_width(char)
    if char_width == 0 then
      -- Zero-width characters stick to the previous cell.
      if #row > 0 then
        row[#row] = row[#row] .. char
      else
        row[1] = char
      end
    elseif used + char_width > width and #row > 0 then
      rows[#rows + 1] = table.concat(row)
      row = { char }
      used = char_width
    else
      row[#row + 1] = char
      used = used + char_width
    end
  end
  rows[#rows + 1] = table.concat(row)
  return rows
end

--- Trim trailing ASCII spaces so every row fits the available width.
local function trim_row_tails(rows)
  for index = 1, #rows do
    rows[index] = (rows[index]:gsub(" +$", ""))
  end
end

--- Lay out a list of independent line units inside `available_width`.
--
-- opts.align: "left" (default) | "right" | "center".
-- opts.shrink: shrink the viewport to the widest wrapped row (default false).
-- Returns the flat padded rows and the final viewport width.
function M.compute(available_width, lines, opts)
  opts = opts or {}
  local width = clamp_width(available_width)
  if type(lines) ~= "table" then
    lines = {}
  end

  local rows = {}
  for _, line in ipairs(lines) do
    local text = type(line) == "string" and line or tostring(line or "")
    local wrapped = wrap_line(text, width)
    trim_row_tails(wrapped)
    for _, row in ipairs(wrapped) do
      rows[#rows + 1] = row
    end
  end

  local target = width
  if opts.shrink then
    target = 1
    for _, row in ipairs(rows) do
      target = math.max(target, util.display_width(row))
    end
  end

  local align = opts.align
  if not ALIGNMENTS[align] then
    align = "left"
  end
  for index, row in ipairs(rows) do
    local pad = target - util.display_width(row)
    if pad > 0 then
      if align == "right" then
        rows[index] = string.rep(" ", pad) .. row
      elseif align == "center" then
        local left = math.floor(pad / 2)
        rows[index] = string.rep(" ", left) .. row .. string.rep(" ", pad - left)
      else
        rows[index] = row .. string.rep(" ", pad)
      end
    end
  end

  return rows, target
end

return M
