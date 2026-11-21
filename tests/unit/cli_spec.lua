local fake_cli = require("helpers.fake_cli")

local function json(tbl)
  return vim.json.encode(tbl)
end

describe("cli argv construction", function()
  it("passes ids, spaces, quotes and non-ASCII as single argv entries", function()
    local f = fake_cli.new()
    local client = f:client()
    f:respond("show", { stdout = json({ id = "#12", title = "标题" }) })

    local res = client:run_sync("show", { "#12", "a b", "中文", 'he said "hi"' })
    truthy(res.ok, "expected success, got " .. vim.inspect(res))

    local call = f:call(1)
    eq({
      fake_cli.fixture,
      "--project-root",
      f.root,
      "--json",
      "show",
      "#12",
      "a b",
      "中文",
      'he said "hi"',
    }, call.argv)
  end)

  it("sends multi-line descriptions only through stdin", function()
    local f = fake_cli.new()
    local client = f:client()
    f:respond("edit", { stdout = json({ id = "#12" }) })
    local desc = "第一段\n\n- `a` 与 \"b\"\n- 结束\n"

    local res = client:run_sync("edit", { "#12", "--desc-file", "-" }, { stdin = desc })
    truthy(res.ok, "expected success, got " .. vim.inspect(res))

    local call = f:call(1)
    eq(desc, call.stdin)
    for _, arg in ipairs(call.argv) do
      falsy(arg:find("\n", 1, true), "description text leaked into argv: " .. vim.inspect(arg))
    end
    eq("--desc-file", call.argv[#call.argv - 1])
    eq("-", call.argv[#call.argv])
  end)
end)

describe("cli structured exit codes", function()
  local cases = {
    { exit = 0, ok = true },
    { exit = 1, kind = "usage" },
    { exit = 2, kind = "source" },
    { exit = 3, kind = "data" },
    { exit = 4, kind = "rejected" },
    { exit = 5, kind = "remote" },
    { exit = 42, kind = "unknown" },
  }

  for _, case in ipairs(cases) do
    it("maps exit " .. case.exit, function()
      local f = fake_cli.new()
      local client = f:client()
      f:respond("show", {
        stdout = json({ id = "#1" }),
        stderr = "boom-" .. case.exit .. "\n",
        exit = case.exit,
      })

      local res = client:run_sync("show", { "#1" })
      if case.ok then
        truthy(res.ok)
        eq(0, res.exit_code)
        eq("#1", res.data.id)
      else
        falsy(res.ok)
        eq("exit", res.code)
        eq(case.kind, res.kind)
        eq(case.exit, res.exit_code)
        match(res.message, "boom%-" .. case.exit)
      end
    end)
  end

  it("marks a missing remote cache as a recoverable no_cache result", function()
    local f = fake_cli.new()
    local client = f:client()
    f:respond("list", {
      stderr = "loop-cli: 未找到任务文件 /p/.pi/loop-kit/LOOP.remote.json（由 loop.config.json 的 filePath 指定，相对 loopRoot）\n",
      exit = 2,
    })

    local res = client:run_sync("list", { "--no-sync" })
    falsy(res.ok)
    eq("no_cache", res.code)
    eq("source", res.kind)
    truthy(res.recoverable)
    match(res.message, "LOOP%.remote%.json")
  end)

  it("keeps ordinary exit 2 failures as plain source errors", function()
    local f = fake_cli.new()
    local client = f:client()
    f:respond("list", { stderr = "loop-cli: 配置损坏\n", exit = 2 })

    local res = client:run_sync("list", { "--no-sync" })
    eq("exit", res.code)
    eq("source", res.kind)
    falsy(res.recoverable)
  end)
end)

describe("cli JSON handling", function()
  it("decodes arrays, null and tasks with missing optional fields", function()
    local f = fake_cli.new()
    local client = f:client()

    f:respond("show", { stdout = "[1,2,3]" })
    local array = client:run_sync("show", { "#1" })
    truthy(array.ok)
    eq({ 1, 2, 3 }, array.data)

    f:respond("show", { stdout = "null" })
    local null = client:run_sync("show", { "#1" })
    truthy(null.ok)
    eq(vim.NIL, null.data)

    f:respond("show", { stdout = json({ id = "#1", title = "only required" }) })
    local sparse = client:run_sync("show", { "#1" })
    truthy(sparse.ok)
    eq("#1", sparse.data.id)
    eq(nil, sparse.data.desc)
    eq(nil, sparse.data.deps)
  end)

  it("reports non-JSON stdout with cli path and exit code", function()
    local f = fake_cli.new()
    local client = f:client()
    f:respond("show", { stdout = "not json at all\n" })

    local res = client:run_sync("show", { "#1" })
    falsy(res.ok)
    eq("json", res.code)
    eq("protocol", res.kind)
    match(res.message, "not json at all")
    match(res.message, vim.pesc(fake_cli.fixture))
    match(res.message, "exit 0")
  end)

  it("truncates stdout and redacts environment tokens", function()
    local f = fake_cli.new()
    local token = "S3CR3T_TOKEN_VALUE_1234567890"
    local client = f:client({ DEMO_TOKEN = token })
    f:respond("show", {
      stdout = string.rep(token .. " ", 1000),
      stderr = "stderr " .. token .. "\n",
    })

    local res = client:run_sync("show", { "#1" })
    falsy(res.ok)
    eq("json", res.code)
    falsy(res.message:find(token, 1, true), "token leaked in message")
    falsy(res.stdout:find(token, 1, true), "token leaked in stdout")
    falsy(res.stderr:find(token, 1, true), "token leaked in stderr")
    match(res.message, "%[REDACTED%]")
    truthy(#res.stdout < 3000, "stdout was not truncated: " .. #res.stdout)
  end)
end)
