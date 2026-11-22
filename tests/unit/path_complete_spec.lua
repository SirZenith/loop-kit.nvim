-- Unit tests for loop-kit.path_complete: project-root anchored path listing,
-- the vim.ui.input customlist entry point and the acwrite omnifunc context.
local tmp = require("helpers.tmp")
local path_complete = require("loop-kit.path_complete")

local function make_root()
  local root = tmp.dir("path-complete")
  vim.fn.mkdir(root .. "/lua/loop-kit/ui", "p")
  tmp.write(root .. "/lua/loop-kit/ui/board.lua", "")
  tmp.write(root .. "/lua/loop-kit/edit.lua", "")
  tmp.write(root .. "/README.md", "")
  tmp.write(root .. "/file with space.txt", "")
  tmp.write(root .. "/.hidden", "")
  vim.fn.mkdir(root .. "/lib", "p")
  return root
end

local function make_nested_root()
  local parent = tmp.dir("path-complete-parent")
  local root = parent .. "/project"
  vim.fn.mkdir(root .. "/lua/loop-kit/ui", "p")
  tmp.write(root .. "/lua/loop-kit/ui/board.lua", "")
  tmp.write(root .. "/lua/loop-kit/edit.lua", "")
  tmp.write(root .. "/README.md", "")
  tmp.write(root .. "/file with space.txt", "")
  tmp.write(root .. "/.hidden", "")
  vim.fn.mkdir(root .. "/lib", "p")
  vim.fn.mkdir(parent .. "/sibling", "p")
  return root
end

describe("path_complete.complete", function()
  it("lists the project root's first level with directories suffixed", function()
    local root = make_root()
    eq(
      { "README.md", "file with space.txt", "lib/", "lua/" },
      path_complete.complete(root, "")
    )
  end)

  it("filters the current segment by prefix", function()
    local root = make_root()
    eq({ "lua/" }, path_complete.complete(root, "lu"))
    eq({ "lua/loop-kit/" }, path_complete.complete(root, "lua/lo"))
    eq({ "lua/loop-kit/ui/board.lua" }, path_complete.complete(root, "lua/loop-kit/ui/bo"))
  end)

  it("keeps a leading ./ prefix", function()
    local root = make_root()
    eq({ "./lua/loop-kit/" }, path_complete.complete(root, "./lua/"))
  end)

  it("lists parent directories when parent segments are allowed", function()
    local root = make_nested_root()
    eq(
      { "../project/", "../sibling/" },
      path_complete.complete(root, "../", { allow_absolute = true })
    )
    eq({ "../sibling/" }, path_complete.complete(root, "../si", { allow_absolute = true }))
  end)

  it("rejects parent segments unless allow_absolute is true", function()
    local root = make_nested_root()
    eq({}, path_complete.complete(root, "../si"))
    eq({}, path_complete.complete(root, "../si", { allow_absolute = false }))
  end)

  it("lists paths through a parent segment when allowed", function()
    local root = make_root()
    eq(
      { "lua/../lib/" },
      path_complete.complete(root, "lua/../lib", { allow_absolute = true })
    )
    eq({}, path_complete.complete(root, "lua/../lib"))
  end)

  it("returns nothing for absolute paths unless allowed", function()
    local root = make_root()
    eq({}, path_complete.complete(root, root .. "/lu"))
    eq({}, path_complete.complete(root, root .. "/lu", { allow_absolute = false }))
    truthy(#path_complete.complete(root, root .. "/lu", { allow_absolute = true }) > 0)
    eq(
      { root .. "/lua/" },
      path_complete.complete(root, root .. "/lu", { allow_absolute = true })
    )
  end)

  it("returns nothing for a missing directory without raising", function()
    local root = make_root()
    eq({}, path_complete.complete(root, "missing/"))
  end)

  it("preserves spaces in file names", function()
    local root = make_root()
    eq({ "file with space.txt" }, path_complete.complete(root, "file "))
  end)

  it("hides dotfiles unless the segment starts with a dot", function()
    local root = make_root()
    falsy(vim.tbl_contains(path_complete.complete(root, ""), ".hidden"))
    eq({ ".hidden" }, path_complete.complete(root, ".h"))
  end)

  it("normalizes parent segments for repository-relative completion", function()
    local root = make_root()
    eq(
      { "lib/" },
      path_complete.complete(root, "lua/../lib", {
        allow_parent = true,
        normalize_parent = true,
      })
    )
    eq(
      { "lua/loop-kit/edit.lua" },
      path_complete.complete(root, "lua/loop-kit/ui/../ed", {
        allow_parent = true,
        normalize_parent = true,
      })
    )
  end)

  it("does not let normalized completion escape the project root", function()
    local root = make_nested_root()
    eq(
      {},
      path_complete.complete(root, "../si", {
        allow_parent = true,
        normalize_parent = true,
      })
    )
  end)

  it("returns nothing for backslash input", function()
    local root = make_root()
    eq({}, path_complete.complete(root, "lua\\lo"))
  end)
end)

describe("path_complete.attach_omnifunc", function()
  it("wires buffer-local context and the omni completion entry point", function()
    local root = make_root()
    local buf = vim.api.nvim_create_buf(false, true)
    path_complete.attach_omnifunc(buf, root, {
      allow_absolute = false,
      allow_parent = true,
      normalize_parent = true,
    })

    eq("v:lua.LoopKitPathOmnifunc", vim.bo[buf].omnifunc)
    eq(root, vim.b[buf].loopkit_path_root)
    eq(false, vim.b[buf].loopkit_path_allow_absolute)
    eq(true, vim.b[buf].loopkit_path_allow_parent)
    eq(true, vim.b[buf].loopkit_path_normalize_parent)

    vim.api.nvim_set_current_buf(buf)
    eq(0, path_complete.omnifunc(1, nil))
    eq({ "lua/loop-kit/" }, path_complete.omnifunc(2, "lua/lo"))
    eq({ "lib/" }, path_complete.omnifunc(2, "lua/../lib"))
    eq({}, path_complete.omnifunc(2, root .. "/lu"))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("path_complete.input_completion", function()
  it("returns a customlist spec backed by a global function", function()
    local root = make_root()
    eq(
      "customlist,v:lua.LoopKitPathComplete",
      path_complete.input_completion(root, { allow_absolute = true })
    )
    eq({ "lua/loop-kit/" }, _G.LoopKitPathComplete("lua/lo"))
    eq({ root .. "/lua/" }, _G.LoopKitPathComplete(root .. "/lu"))

    path_complete.input_completion(root, { allow_absolute = false })
    eq({}, _G.LoopKitPathComplete(root .. "/lu"))
  end)

  it("allows parent segments in single-line inputs", function()
    local root = make_nested_root()
    path_complete.input_completion(root, { allow_absolute = true })
    eq({ "../sibling/" }, _G.LoopKitPathComplete("../si"))

    path_complete.input_completion(root, { allow_absolute = false })
    eq({}, _G.LoopKitPathComplete("../si"))
  end)
end)
