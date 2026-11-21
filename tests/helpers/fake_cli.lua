-- Helpers around tests/fixtures/fake-loop-cli.
local tmp = require("helpers.tmp")
local paths = require("helpers.paths")

local M = {}
M.__index = M
M.fixture = paths.fixtures_dir .. "/fake-loop-cli"

local function split_nul(content)
  local out = {}
  local i = 1
  while true do
    local j = content:find("\0", i, true)
    if not j then
      break
    end
    out[#out + 1] = content:sub(i, j - 1)
    i = j + 1
  end
  return out
end

function M.new()
  local root = tmp.dir("fakecli")
  local state = root .. "/state"
  vim.fn.mkdir(state, "p")
  tmp.chmod(M.fixture, 493)
  return setmetatable({ root = root, state = state }, M)
end

function M:respond(cmd, response)
  response = response or {}
  if response.stdout ~= nil then
    tmp.write(self.state .. "/out." .. cmd, response.stdout)
  end
  if response.stderr ~= nil then
    tmp.write(self.state .. "/err." .. cmd, response.stderr)
  end
  if response.exit ~= nil then
    tmp.write(self.state .. "/exit." .. cmd, tostring(response.exit))
  end
end

function M:env(extra)
  local env = { FAKE_CLI_STATE = self.state }
  return vim.tbl_extend("force", env, extra or {})
end

function M:client(opts)
  opts = opts or {}
  local cli = require("loop-kit.cli")
  -- Accept either `{ env = {...} }` or a bare env table.
  local extra = opts.env
  if extra == nil then
    extra = {}
    for key, value in pairs(opts) do
      if key ~= "project_root" and key ~= "cwd" then
        extra[key] = value
      end
    end
  end
  return cli.new({
    path = M.fixture,
    project_root = opts.project_root or self.root,
    env = self:env(extra),
    cwd = opts.cwd or self.root,
  })
end

function M:call_count()
  local count = 0
  for _, name in ipairs(tmp.list(self.state)) do
    if name:sub(1, 5) == "argv." then
      count = count + 1
    end
  end
  return count
end

function M:call(seq)
  seq = seq or 1
  local prefix = self.state .. "/"
  local argv_file = prefix .. "argv." .. seq
  local stdin_file = prefix .. "stdin." .. seq
  local cwd_file = prefix .. "cwd." .. seq
  if not tmp.exists(argv_file) then
    return nil
  end
  return {
    seq = seq,
    argv = split_nul(tmp.read(argv_file)),
    stdin = tmp.exists(stdin_file) and tmp.read(stdin_file) or "",
    cwd = tmp.exists(cwd_file) and tmp.read(cwd_file):gsub("\n$", "") or nil,
  }
end

function M:calls()
  local calls = {}
  for seq = 1, self:call_count() do
    calls[#calls + 1] = self:call(seq)
  end
  return calls
end

function M:wait_for(predicate, timeout)
  local ok = vim.wait(timeout or 5000, predicate, 10)
  if not ok then
    error("timed out waiting for condition", 2)
  end
end

return M
