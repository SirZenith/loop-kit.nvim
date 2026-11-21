local fake_cli = require("helpers.fake_cli")
local form = require("loop-kit.form")

local function json(tbl)
  return vim.json.encode(tbl)
end

local function task(overrides)
  return vim.tbl_extend("force", {
    id = "#12",
    title = "标题",
    status = "doing",
    tag = "feat",
    deps = {},
    doc = nil,
    desc = "",
  }, overrides or {})
end

local function wait_for(predicate, message)
  vim.wait(5000, predicate, 10)
  truthy(predicate(), message or "timed out waiting for form submission")
end

--- Drop dirty marks left behind by a previous test so the window can switch.
local function clear_modified()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(function()
        vim.bo[buf].modified = false
      end)
    end
  end
end

--- Open a form for `baseline` (or a new task) in the current window.
local function open(opts)
  clear_modified()
  local f = opts.fake
  return form.open({
    client = f:client(),
    root = f.root,
    task = opts.task,
    ask = opts.ask,
    on_saved = opts.on_saved,
    on_error = opts.on_error,
  })
end

local function replace_title(buf, title)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "# " .. title })
end

describe("form fake CLI writes", function()
  it("submits a changed title exactly once", function()
    local f = fake_cli.new()
    f:respond("edit", { stdout = json(task({ title = "更新后" })) })

    local saved, modified_at_save
    local buf
    buf = open({
      fake = f,
      task = task(),
      on_saved = function(fields, result)
        saved = result
        modified_at_save = vim.bo[buf].modified
      end,
    })
    eq(buf, vim.api.nvim_get_current_buf())
    replace_title(buf, "更新后")

    vim.cmd("write")
    wait_for(function()
      return saved ~= nil
    end)

    eq(1, f:call_count())
    eq({
      fake_cli.fixture,
      "--project-root",
      f.root,
      "--json",
      "edit",
      "#12",
      "--title",
      "更新后",
    }, f:call(1).argv)
    eq("", f:call(1).stdin)
    eq(false, modified_at_save)
    eq(0, vim.fn.filereadable("loopkit://" .. f.root .. "/task/%2312"))
  end)

  it("keeps the dirty text when the CLI rejects the write", function()
    local f = fake_cli.new()
    f:respond("edit", { stderr = "updatedAt conflict\n", exit = 4 })

    local failed
    local buf = open({
      fake = f,
      task = task(),
      on_error = function(err)
        failed = err
      end,
    })
    replace_title(buf, "保留我")

    vim.cmd("write")
    wait_for(function()
      return failed ~= nil
    end)

    eq(1, f:call_count())
    truthy(vim.api.nvim_buf_is_valid(buf))
    truthy(vim.bo[buf].modified)
    eq("# 保留我", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("restores the detail buffer after a successful save", function()
    local f = fake_cli.new()
    f:respond("edit", { stdout = json(task({ title = "保存后" })) })
    clear_modified()
    local detail = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, detail)

    local saved
    local buf = open({
      fake = f,
      task = task(),
      on_saved = function()
        saved = true
      end,
    })
    replace_title(buf, "保存后")

    vim.cmd("write")
    wait_for(function()
      return saved == true
    end)

    eq(detail, vim.api.nvim_get_current_buf())
  end)

  it("adds a task and reports the new id", function()
    local f = fake_cli.new()
    f:respond("add", {
      stdout = json(task({ id = "#99", title = "新任务", status = "pending" })),
    })

    local saved
    local buf = open({
      fake = f,
      on_saved = function(fields, result)
        saved = result
      end,
    })
    replace_title(buf, "新任务")

    vim.cmd("write")
    wait_for(function()
      return saved ~= nil
    end)

    eq(1, f:call_count())
    eq({
      fake_cli.fixture,
      "--project-root",
      f.root,
      "--json",
      "add",
      "--title",
      "新任务",
      "--tag",
      "feat",
      "--origin",
      "human",
    }, f:call(1).argv)
    eq("#99", saved.id)
  end)
end)

describe("form dirty protection", function()
  local function dirty_form(f, answer)
    local f_ = f
    f_:respond("edit", { stdout = json(task({ title = "保存" })) })
    local saved
    local buf = open({
      fake = f_,
      task = task(),
      ask = function(items, prompt, cb)
        eq({ "保存", "放弃", "取消" }, items)
        match(prompt, "未保存")
        cb(answer)
      end,
      on_saved = function()
        saved = true
      end,
    })
    replace_title(buf, "改动")
    return buf, function()
      return saved
    end
  end

  it("discards only after an explicit choice", function()
    local f = fake_cli.new()
    local buf, saved = dirty_form(f, "放弃")
    local closed
    form.cancel(buf, function(value)
      closed = value
    end)

    wait_for(function()
      return closed == true
    end)
    eq(0, f:call_count())
    eq(nil, saved())
  end)

  it("saves when the user chooses save", function()
    local f = fake_cli.new()
    local buf, saved = dirty_form(f, "保存")
    form.cancel(buf)

    wait_for(function()
      return saved() == true
    end)
    eq(1, f:call_count())
  end)

  it("keeps the form open when the user chooses cancel", function()
    local f = fake_cli.new()
    local buf, saved = dirty_form(f, "取消")
    local closed
    form.cancel(buf, function(value)
      closed = value
    end)

    vim.wait(100)
    eq(false, closed)
    truthy(vim.api.nvim_buf_is_valid(buf))
    eq(buf, vim.api.nvim_get_current_buf())
    eq(0, f:call_count())
    eq(nil, saved())
    vim.bo[buf].modified = false
  end)
end)
