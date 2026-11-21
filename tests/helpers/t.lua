-- Tiny zero-dependency test registry used by tests/run.lua.
local M = {}

M.registry = {}
M.current_file = "<unknown>"

local function record(name, fn)
  M.registry[#M.registry + 1] = { name = name, fn = fn, file = M.current_file }
end

local function format(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  local ok, rendered = pcall(vim.inspect, value)
  return ok and rendered or tostring(value)
end

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      string.format(
        "%sexpected %s, got %s",
        message and (message .. ": ") or "",
        format(expected),
        format(actual)
      ),
      2
    )
  end
end

function M.neq(unexpected, actual, message)
  if vim.deep_equal(unexpected, actual) then
    error(
      string.format(
        "%sdid not expect %s",
        message and (message .. ": ") or "",
        format(unexpected)
      ),
      2
    )
  end
end

function M.truthy(value, message)
  if not value then
    error((message or "expected truthy value") .. ", got " .. format(value), 2)
  end
end

function M.falsy(value, message)
  if value then
    error((message or "expected falsy value") .. ", got " .. format(value), 2)
  end
end

function M.match(value, pattern, message)
  if type(value) ~= "string" or not value:find(pattern) then
    error(
      string.format(
        "%sexpected %s to match %s",
        message and (message .. ": ") or "",
        format(value),
        format(pattern)
      ),
      2
    )
  end
end

function M.fail(message)
  error(message or "test failed", 2)
end

function M.spy(impl)
  local calls = {}
  local fn = function(...)
    calls[#calls + 1] = { ... }
    if impl then
      return impl(...)
    end
  end
  return fn, calls
end

function M.setup()
  _G.describe = function(name, fn)
    if not name or name == "" then
      error("describe needs a name")
    end
    local saved = M.current_file
    fn()
    M.current_file = saved
  end
  _G.it = record
  _G.eq = M.eq
  _G.neq = M.neq
  _G.truthy = M.truthy
  _G.falsy = M.falsy
  _G.match = M.match
  _G.fail = M.fail
  _G.spy = M.spy
end

return M
