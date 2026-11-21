local form = require("loop-kit.form")

local root = "/tmp/loopkit-form-render"

local function task(overrides)
  return vim.tbl_extend("force", {
    id = "#12",
    title = "标题",
    status = "doing",
    tag = "feat",
    deps = { "#3" },
    doc = nil,
    desc = "第一段\n\n第二段",
  }, overrides or {})
end

local function clear_modified()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(function()
        vim.bo[buf].modified = false
      end)
    end
  end
end

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "详情" })
  return buf
end

local function wait_for(predicate, message)
  vim.wait(5000, predicate, 10)
  truthy(predicate(), message or "timed out")
end

--- Open a form whose submit callback succeeds synchronously.
local function open(opts)
  opts = opts or {}
  clear_modified()
  local detail = scratch()
  vim.api.nvim_win_set_buf(0, detail)
  local state = {
    detail = detail,
    submitted = {},
    saved = nil,
    failed = nil,
    submit_calls = 0,
  }

  state.buf = form.open({
    root = root,
    task = opts.task,
    nonce = "n1",
    detail_buf = detail,
    detail_win = 0,
    ask = opts.ask,
    submit = function(plan, done)
      state.submit_calls = state.submit_calls + 1
      state.submitted[#state.submitted + 1] = plan
      done(true, { id = opts.saved_id or "#12", title = "标题" })
    end,
    on_saved = function(fields, result)
      state.saved = { fields = fields, result = result }
    end,
    on_error = function(err)
      state.failed = err
    end,
  })

  return state
end

describe("form buffers", function()
  it("opens an editable acwrite buffer in the detail window", function()
    local s = open({ task = task() })

    eq(s.buf, vim.api.nvim_get_current_buf())
    eq("acwrite", vim.bo[s.buf].buftype)
    eq("markdown", vim.bo[s.buf].filetype)
    truthy(vim.bo[s.buf].modifiable)
    truthy(vim.b[s.buf].loopkit_form)
    match(vim.api.nvim_buf_get_name(s.buf), "loopkit:///tmp/loopkit%-form%-render/task/%%2312$")
  end)

  it("submits only through BufWriteCmd and never writes a real file", function()
    local s = open({ task = task() })
    local name = vim.api.nvim_buf_get_name(s.buf)
    local format_calls = 0
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = s.buf,
      callback = function()
        format_calls = format_calls + 1
      end,
    })

    vim.api.nvim_buf_set_lines(s.buf, 1, 2, false, { "# 修改" })
    vim.cmd("write")
    wait_for(function()
      return s.saved ~= nil
    end)

    eq(1, s.submit_calls)
    eq(0, vim.fn.filereadable(name))
    eq(0, format_calls)
    eq(s.detail, vim.api.nvim_get_current_buf())
  end)

  it("restores the detail buffer on cancel without changes", function()
    local s = open({ task = task() })
    local closed

    form.cancel(s.buf, function(value)
      closed = value
    end)

    wait_for(function()
      return closed == true
    end)
    eq(0, s.submit_calls)
    eq(s.detail, vim.api.nvim_get_current_buf())
  end)
end)

describe("form dirty choices", function()
  local function ask(answer)
    return function(items, prompt, cb)
      eq({ "保存", "放弃", "取消" }, items)
      match(prompt, "未保存")
      cb(answer)
    end
  end

  it("discards after choosing discard", function()
    local s = open({ task = task(), ask = ask("放弃") })
    vim.api.nvim_buf_set_lines(s.buf, 1, 2, false, { "# 丢弃" })

    form.cancel(s.buf)

    wait_for(function()
      return s.detail == vim.api.nvim_get_current_buf()
    end)
    eq(0, s.submit_calls)
  end)

  it("saves after choosing save", function()
    local s = open({ task = task(), ask = ask("保存") })
    vim.api.nvim_buf_set_lines(s.buf, 1, 2, false, { "# 保存" })

    form.cancel(s.buf)

    wait_for(function()
      return s.saved ~= nil
    end)
    eq(1, s.submit_calls)
    eq(s.detail, vim.api.nvim_get_current_buf())
  end)

  it("stays open after choosing cancel", function()
    local s = open({ task = task(), ask = ask("取消") })
    vim.api.nvim_buf_set_lines(s.buf, 1, 2, false, { "# 继续编辑" })
    local closed

    form.cancel(s.buf, function(value)
      closed = value
    end)

    vim.wait(100)
    eq(false, closed)
    eq(s.buf, vim.api.nvim_get_current_buf())
    eq(0, s.submit_calls)
  end)
end)

describe("form new buffers", function()
  it("uses a nonce name and restores the detail after saving", function()
    local s = open({ saved_id = "#42" })
    match(vim.api.nvim_buf_get_name(s.buf), "loopkit:///tmp/loopkit%-form%-render/new/n1$")

    vim.api.nvim_buf_set_lines(s.buf, 1, 2, false, { "# 新任务" })
    vim.cmd("write")
    wait_for(function()
      return s.saved ~= nil
    end)

    eq(1, s.submit_calls)
    eq("#42", s.saved.result.id)
    eq("add", s.submitted[1].calls[1].command)
    eq(s.detail, vim.api.nvim_get_current_buf())
  end)
end)
