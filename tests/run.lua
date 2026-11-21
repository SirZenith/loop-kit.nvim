-- Zero-dependency test runner.
--
--   nvim --headless -u tests/minimal_init.lua -l tests/run.lua [-- --filter unit]
--
-- Filters: unit / fake-dom / render. Without a filter all three groups run
-- (render may be empty until the UI task lands).
local paths = require("helpers.paths")
local t = require("helpers.t")
local tmp = require("helpers.tmp")

t.setup()

local function parse_filter()
  local args = vim.deepcopy(_G.arg or {})
  local filter
  local i = 1
  while i <= #args do
    local value = args[i]
    if value == "--filter" then
      filter = args[i + 1]
      i = i + 2
    elseif type(value) == "string" and value:sub(1, 9) == "--filter=" then
      filter = value:sub(10)
      i = i + 1
    else
      i = i + 1
    end
  end
  return filter
end

local groups = {
  ["unit"] = "tests/unit",
  ["fake-dom"] = "tests/fake-dom",
  ["render"] = "tests/render",
}

local order = { "unit", "fake-dom", "render" }

local function spec_files(dir)
  local files = {}
  for name in vim.fs.dir(paths.root .. "/" .. dir) do
    if name:sub(-9) == "_spec.lua" then
      files[#files + 1] = paths.root .. "/" .. dir .. "/" .. name
    end
  end
  table.sort(files)
  return files
end

local filter = parse_filter()
local selected = {}
if filter and filter ~= "" and filter ~= "all" then
  if not groups[filter] then
    io.stderr:write("unknown --filter: " .. tostring(filter) .. "\n")
    vim.cmd("cquit 2")
  end
  selected = { filter }
else
  selected = order
end

for _, group in ipairs(selected) do
  local dir = groups[group]
  if vim.uv.fs_stat(paths.root .. "/" .. dir) then
    for _, file in ipairs(spec_files(dir)) do
      t.current_file = file:sub(#paths.root + 2)
      local ok, err = xpcall(function()
        dofile(file)
      end, debug.traceback)
      if not ok then
        t.registry[#t.registry + 1] = {
          name = "load " .. t.current_file,
          fn = function()
            error(err, 0)
          end,
          file = t.current_file,
        }
      end
    end
  end
end

local passed, failed = 0, 0
local failures = {}

for index, test in ipairs(t.registry) do
  local ok, err = xpcall(test.fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.write(string.format("ok %d - %s\n", index, test.name))
  else
    failed = failed + 1
    io.write(string.format("not ok %d - %s\n", index, test.name))
    failures[#failures + 1] = { test = test, err = err }
  end
end

io.write(string.format("\n%d passed, %d failed, %d total\n", passed, failed, passed + failed))

for _, failure in ipairs(failures) do
  io.write(string.format("\n--- FAIL: %s (%s)\n%s\n", failure.test.name, failure.test.file, failure.err))
end

tmp.cleanup()

if failed > 0 then
  vim.cmd("cquit 1")
end

vim.cmd("quit")
