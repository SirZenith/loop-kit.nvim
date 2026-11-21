-- Optional end-to-end smoke test against a real loop-cli.
--
-- Skipped by default. Enable with LOOP_KIT_REAL_CLI=1. Everything happens in a
-- throwaway temp directory with a local provider, so the developer's real
-- LOOP is never touched and no network call is made.
local tmp = require("helpers.tmp")
local util = require("loop-kit.util")

local enabled = vim.env.LOOP_KIT_REAL_CLI == "1"

local function json(tbl)
  return vim.json.encode(tbl)
end

local function real_cli()
  local bin = vim.env.LOOP_BIN
  if not bin or bin == "" then
    bin = vim.fn.exepath("loop-cli")
  end
  if not bin or bin == "" then
    return nil
  end
  return bin
end

describe("integration: real loop-cli local roundtrip", function()
  if not enabled then
    it("skips unless LOOP_KIT_REAL_CLI=1", function()
      truthy(true)
    end)
    return
  end

  it("completes paths/add/list/edit/claim/done/block/remove in a temp project", function()
    local bin = real_cli()
    truthy(bin, "LOOP_KIT_REAL_CLI=1 but loop-cli is not available")

    local root = tmp.dir("realcli")
    tmp.write(
      root .. "/loop.config.json",
      json({
        version = 1,
        provider = "local",
        loopRoot = "loop",
        filePath = "LOOP.json",
      }) .. "\n"
    )
    tmp.write(
      root .. "/loop/LOOP.json",
      json({ version = 1, tasks = {} }) .. "\n"
    )

    local cli = require("loop-kit.cli")
    local client = cli.new({ path = bin, project_root = root })

    local paths_res = client:run_sync("paths")
    truthy(paths_res.ok, vim.inspect(paths_res))
    eq(root .. "/loop.config.json", paths_res.data.config)

    local desc = "第一段\n\n- 多行\n- 中文 \"quoted\"\n"
    local add_res = client:run_sync(
      "add",
      { "--title", "Real task", "--tag", "feat", "--origin", "human", "--desc-file", "-" },
      { stdin = desc }
    )
    truthy(add_res.ok, vim.inspect(add_res))
    local id = add_res.data.id
    truthy(id and id:match("^#%d+$"), "expected a task id, got " .. tostring(id))

    local list_res = client:run_sync("list")
    truthy(list_res.ok, vim.inspect(list_res))
    local found = nil
    for _, task in ipairs(list_res.data.tasks or {}) do
      if task.id == id then
        found = task
      end
    end
    truthy(found, "added task missing from list")
    -- loop-cli preserves the body but normalises the trailing newline.
    eq(desc:gsub("\n+$", ""), (found.desc or ""):gsub("\n+$", ""))
    truthy((found.desc or ""):find("第一段", 1, true), "desc body must be preserved")
    truthy((found.desc or ""):find("- 中文 \"quoted\"", 1, true), "desc lines must be preserved")

    local edit_res = client:run_sync("edit", { id, "--title", "Real task edited" })
    truthy(edit_res.ok, vim.inspect(edit_res))
    eq("Real task edited", edit_res.data.title)

    local claim_res = client:run_sync("claim", { id })
    truthy(claim_res.ok, vim.inspect(claim_res))
    eq("doing", claim_res.data.status)

    local done_res = client:run_sync("done", { id })
    truthy(done_res.ok, vim.inspect(done_res))
    eq("done", done_res.data.status)

    local blocked_add = client:run_sync("add", { "--title", "Blocked task", "--tag", "fix", "--origin", "human" })
    truthy(blocked_add.ok, vim.inspect(blocked_add))
    local blocked_id = blocked_add.data.id

    local block_res = client:run_sync("block", { blocked_id, "--reason", "等待上游" })
    truthy(block_res.ok, vim.inspect(block_res))
    eq("blocked", block_res.data.status)

    local remove_res = client:run_sync("remove", { blocked_id })
    truthy(remove_res.ok, vim.inspect(remove_res))

    local final_res = client:run_sync("list")
    truthy(final_res.ok, vim.inspect(final_res))
    local ids = {}
    for _, task in ipairs(final_res.data.tasks or {}) do
      ids[task.id] = task
    end
    eq(nil, ids[blocked_id], "removed task must be gone")
    eq("done", ids[id].status)

    -- The plugin's snapshot must agree with the final CLI state.
    local source_mod = require("loop-kit.source")
    local source = source_mod.new({ client = client, root = util.normalize_root(root) })
    local done_loading, snapshot = false, nil
    source:list({}, function(res)
      snapshot = res
      done_loading = true
    end)
    vim.wait(10000, function()
      return done_loading
    end, 20)
    truthy(snapshot and snapshot.ok, "snapshot reload failed")
    local snapshot_ids = {}
    for _, task in ipairs(source.snapshot.tasks or {}) do
      snapshot_ids[task.id] = task
    end
    eq("done", snapshot_ids[id].status)
    eq(nil, snapshot_ids[blocked_id])
  end)
end)
