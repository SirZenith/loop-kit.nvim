-- Editing and creation forms for LOOP tasks.
--
-- The module owns three concerns that stay free of the board UI:
--   * parsing/serialising the plain Markdown form format,
--   * turning parsed fields into exact loop-cli calls (diff against a baseline),
--   * an `acwrite` buffer whose `:write` submits through the CLI and keeps dirty
--     text when anything fails.
local util = require("loop-kit.util")

local M = {}

M.DEFAULT_TAG = "feat"
M.HEADER_PATTERN = "<!%-%-%s*loopkit:task%s*(.-)%s*%-%->"
M.META_PATTERN = "<!%-%-%s*loopkit:meta"

local META_KEYS = { tag = true, deps = true, doc = true }

--- Per-buffer form state. Cleared by BufWipeout.
local registry = {}
--- Buffer names (root + task id) so reopening focuses the existing form.
local by_key = {}

local function split_lines(text)
  if type(text) == "table" then
    local lines = {}
    for i, line in ipairs(text) do
      lines[i] = line
    end
    return lines
  end
  if text == nil or text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

local function normalize_root(root)
  local normalized = util.normalize_path(root) or tostring(root or "")
  if #normalized > 1 then
    normalized = normalized:gsub("/+$", "")
  end
  return normalized
end

local function encode_id(id)
  return (tostring(id):gsub("#", "%%23"))
end

local function dedupe(list)
  local out, seen = {}, {}
  for _, id in ipairs(list or {}) do
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function optional_text(value)
  if is_null(value) or value == "" then
    return nil
  end
  return value
end

local function deps_list(value)
  if is_null(value) then
    return {}
  end
  if type(value) == "string" then
    value = util.split(value, ",")
  end
  local out = {}
  for _, raw in ipairs(type(value) == "table" and value or {}) do
    local id = util.normalize_id(tostring(raw))
    if id then
      out[#out + 1] = id
    end
  end
  return dedupe(out)
end

local function same_list(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function validate_doc(path)
  if path == "" then
    return true
  end
  if path:find("[\r\n]") then
    return false, "不得包含换行"
  end
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" or path:match("^%a:[/\\]") then
    return false, "必须是仓库根相对路径"
  end
  for segment in path:gmatch("[^/\\]+") do
    if segment == ".." then
      return false, "不得包含 .."
    end
  end
  return true
end

local function format_errors(errors)
  local parts = {}
  for _, err in ipairs(errors or {}) do
    parts[#parts + 1] = string.format("第 %d 行：%s", err.line or 0, err.message or "错误")
  end
  return table.concat(parts, "；")
end

--- Defaults for a new task form.
function M.defaults()
  return {
    is_new = true,
    id = nil,
    title = "",
    tag = M.DEFAULT_TAG,
    deps = {},
    doc = nil,
    desc = "",
  }
end

--- Parse the Markdown form into fields plus line-numbered errors.
function M.parse(input)
  local lines = split_lines(input)
  local parsed = {
    id = nil,
    is_new = false,
    title = "",
    tag = "",
    deps = {},
    doc = nil,
    desc = "",
    errors = {},
    title_line = nil,
  }
  local function add_error(line, message)
    parsed.errors[#parsed.errors + 1] = { line = line, message = message }
  end

  local header
  for i, line in ipairs(lines) do
    local content = line:match(M.HEADER_PATTERN)
    if content then
      header = { line = i, content = content }
      break
    end
  end

  if not header then
    add_error(1, "缺少 <!-- loopkit:task --> 头")
  elseif header.content == "new" then
    parsed.is_new = true
  else
    local raw = header.content:match("^id%s*=%s*(.-)$")
    local id = raw and util.normalize_id(raw)
    if not id then
      add_error(header.line, "非法任务 id：" .. header.content)
    else
      parsed.id = id
    end
  end

  local header_line = header and header.line or 0

  -- Locate the single meta block. Content lines keep their real line numbers
  -- so validation can point at the offending line.
  local entries = {}
  local meta_start, meta_end
  for i = header_line + 1, #lines do
    local line = lines[i]
    local start_pos, start_finish = line:find(M.META_PATTERN)
    if start_pos then
      if meta_start then
        add_error(i, "重复的 meta 块")
      else
        meta_start = i
        local after = line:sub(start_finish + 1)
        local close_start = after:find("%-%->")
        if close_start then
          local inline = after:sub(1, close_start - 1)
          if inline:find("%S") then
            entries[#entries + 1] = { line = i, text = inline }
          end
          meta_end = i
        else
          if after:find("%S") then
            entries[#entries + 1] = { line = i, text = after }
          end
          local j = i + 1
          while j <= #lines do
            local close = lines[j]:find("%-%->")
            if close then
              local before = lines[j]:sub(1, close - 1)
              if before:find("%S") then
                entries[#entries + 1] = { line = j, text = before }
              end
              meta_end = j
              break
            end
            entries[#entries + 1] = { line = j, text = lines[j] }
            j = j + 1
          end
          if not meta_end then
            add_error(meta_start, "meta 块未闭合")
            meta_end = #lines
          end
        end
      end
    end
  end

  -- The first level-one heading outside the meta block is the title.
  local title_line
  for i = header_line + 1, #lines do
    local inside_meta = meta_start and i >= meta_start and i <= meta_end
    if not inside_meta then
      local heading = lines[i]:match("^#%s+(.*)$")
      if heading then
        title_line = i
        parsed.title_line = i
        parsed.title = util.trim(heading)
        break
      end
    end
  end

  if meta_start and (not title_line or meta_start < title_line) then
    add_error(meta_start, "meta 块必须位于一级标题之后")
  end

  if not title_line then
    local line = math.min(#lines, header_line + 1)
    if line < 1 then
      line = 1
    end
    add_error(line, "缺少一级标题")
  end

  local seen = {}
  for _, entry in ipairs(entries) do
    if entry.text:find("%S") then
      local key, value = entry.text:match("^%s*([%w_%-%.]+)%s*:%s*(.-)%s*$")
      if not key then
        add_error(entry.line, "无法解析 meta 行：" .. util.trim(entry.text))
      elseif not META_KEYS[key] then
        add_error(entry.line, "未知的 meta 键：" .. key)
      elseif seen[key] then
        add_error(entry.line, "重复的 meta 键：" .. key)
      else
        seen[key] = true
        if key == "tag" then
          parsed.tag = util.trim(value)
        elseif key == "doc" then
          local doc = util.trim(value)
          if doc == "" then
            parsed.doc = nil
          else
            local ok, reason = validate_doc(doc)
            if not ok then
              add_error(entry.line, "非法 doc 路径：" .. doc .. "（" .. reason .. "）")
            else
              parsed.doc = doc
            end
          end
        elseif key == "deps" then
          local deps = {}
          for _, raw in ipairs(util.split(value, ",")) do
            local item = util.trim(raw)
            if item ~= "" then
              local id = util.normalize_id(item)
              if not id then
                add_error(entry.line, "非法依赖 id：" .. item)
              else
                deps[#deps + 1] = id
              end
            end
          end
          parsed.deps = dedupe(deps)
        end
      end
    end
  end

  local desc_from = (meta_end or title_line or header_line) + 1
  local body = {}
  for i = desc_from, #lines do
    body[#body + 1] = lines[i]
  end
  while #body > 0 and not body[1]:find("%S") do
    table.remove(body, 1)
  end
  while #body > 0 and not body[#body]:find("%S") do
    table.remove(body)
  end
  parsed.desc = table.concat(body, "\n")

  return parsed
end

--- Serialise fields back into the Markdown form.
function M.serialize(fields)
  fields = fields or {}
  local deps = deps_list(fields.deps)
  local lines = {}
  if fields.is_new or fields.id == nil then
    lines[#lines + 1] = "<!-- loopkit:task new -->"
  else
    lines[#lines + 1] = "<!-- loopkit:task id=" .. fields.id .. " -->"
  end
  lines[#lines + 1] = "# " .. (optional_text(fields.title) or "")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<!-- loopkit:meta"
  lines[#lines + 1] = "tag: " .. (optional_text(fields.tag) or "")
  if #deps > 0 then
    lines[#lines + 1] = "deps: " .. table.concat(deps, ", ")
  end
  local doc = optional_text(fields.doc)
  if doc then
    lines[#lines + 1] = "doc: " .. doc
  end
  lines[#lines + 1] = "-->"
  lines[#lines + 1] = ""
  local desc = optional_text(fields.desc)
  if desc then
    for _, line in ipairs(vim.split(desc, "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\n")
end

--- Diff parsed fields against the loaded Task and return the CLI calls needed.
function M.plan(parsed, baseline)
  local plan = { ok = true, errors = {}, calls = {}, fields = nil }
  for _, err in ipairs(parsed.errors or {}) do
    plan.errors[#plan.errors + 1] = err
  end

  local title = util.trim(parsed.title or "")
  local tag = util.trim(parsed.tag or "")
  if title == "" then
    plan.errors[#plan.errors + 1] = {
      line = parsed.title_line or 1,
      message = "标题不能为空",
    }
  end
  if tag == "" then
    plan.errors[#plan.errors + 1] = { line = 1, message = "tag 不能为空" }
  end
  if #plan.errors > 0 then
    plan.ok = false
    return plan
  end

  local fields = {
    title = title,
    tag = tag,
    deps = deps_list(parsed.deps),
    doc = optional_text(parsed.doc),
    desc = optional_text(parsed.desc) or "",
  }
  plan.fields = fields

  local is_new = parsed.is_new or baseline == nil
  if is_new then
    local args = { "--title", title, "--tag", tag, "--origin", "human" }
    local stdin
    if #fields.deps > 0 then
      args[#args + 1] = "--deps"
      args[#args + 1] = table.concat(fields.deps, ", ")
    end
    if fields.doc then
      args[#args + 1] = "--doc"
      args[#args + 1] = fields.doc
    end
    if fields.desc ~= "" then
      args[#args + 1] = "--desc-file"
      args[#args + 1] = "-"
      stdin = fields.desc
    end
    plan.calls[1] = { command = "add", args = args, stdin = stdin }
    return plan
  end

  local id = parsed.id or baseline.id
  local base_deps = deps_list(baseline.deps)
  local base_doc = optional_text(baseline.doc)
  local base_title = optional_text(baseline.title) or ""
  local base_tag = optional_text(baseline.tag) or ""
  local base_desc = optional_text(baseline.desc) or ""

  local args = { id }
  local stdin
  if fields.title ~= base_title then
    args[#args + 1] = "--title"
    args[#args + 1] = fields.title
  end
  if fields.tag ~= base_tag then
    args[#args + 1] = "--tag"
    args[#args + 1] = fields.tag
  end
  if not same_list(fields.deps, base_deps) and #fields.deps > 0 then
    args[#args + 1] = "--deps"
    args[#args + 1] = table.concat(fields.deps, ", ")
  end
  if fields.doc and fields.doc ~= base_doc then
    args[#args + 1] = "--doc"
    args[#args + 1] = fields.doc
  end
  if fields.desc ~= base_desc then
    args[#args + 1] = "--desc-file"
    args[#args + 1] = "-"
    stdin = fields.desc
  end
  if #args > 1 then
    plan.calls[#plan.calls + 1] = { command = "edit", args = args, stdin = stdin }
  end

  -- Empty values are not representable through `edit`; the dedicated
  -- commands carry the clear semantics documented by loop-cli.
  if #fields.deps == 0 and #base_deps > 0 then
    plan.calls[#plan.calls + 1] = { command = "deps", args = { id, "--set", "" } }
  end
  if not fields.doc and base_doc then
    plan.calls[#plan.calls + 1] = { command = "doc", args = { id, "--clear" } }
  end

  return plan
end

--- Execute plan calls in order through a cli.Client.
function M.make_submit(client)
  return function(plan, done)
    local results = {}
    local index = 0
    local function step()
      index = index + 1
      local call = plan.calls[index]
      if not call then
        local last = results[#results]
        return done(true, last and last.data or nil, results)
      end
      client:run(call.command, call.args, { stdin = call.stdin }, function(res)
        results[#results + 1] = res
        if not res.ok then
          return done(false, res, results)
        end
        step()
      end)
    end
    step()
  end
end

function M.buffer_name(root, id)
  local base = normalize_root(root)
  return string.format("loopkit://%s/task/%s", base, encode_id(id))
end

function M.new_buffer_name(root, nonce)
  local base = normalize_root(root)
  return string.format("loopkit://%s/new/%s", base, tostring(nonce))
end

local function make_nonce()
  local now = (vim.uv and vim.uv.hrtime and vim.uv.hrtime()) or os.time()
  return string.format("%x%d", now, math.random(1000, 9999))
end

local function state_for(buf)
  return registry[buf]
end

function M.state(buf)
  return state_for(buf)
end

function M.is_dirty(buf)
  local state = state_for(buf)
  if not state then
    return false
  end
  if state.modified then
    return true
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].modified then
    return true
  end
  -- API edits (notably in headless tests) do not always set 'modified', so
  -- compare the text against what was loaded.
  local current = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return current ~= (state.original_text or "")
end

local function baseline_for_result(state, fields, result)
  local baseline = util.deepcopy(state.baseline or {})
  baseline.title = fields.title
  baseline.tag = fields.tag
  baseline.deps = util.deepcopy(fields.deps)
  baseline.doc = optional_text(fields.doc)
  baseline.desc = fields.desc
  if type(result) == "table" and result.id then
    baseline.id = result.id
  end
  return baseline
end

local function restore(state)
  if state.closed then
    return
  end
  state.closed = true

  local buf = state.buf
  if by_key[state.key] == buf then
    by_key[state.key] = nil
  end

  local win = state.detail_win
  -- Switching away from a modified acwrite buffer raises E37; discard the
  -- flag first because the form is going away either way.
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(function()
      vim.bo[buf].modified = false
    end)
  end
  if win and vim.api.nvim_win_is_valid(win) and state.detail_buf and vim.api.nvim_buf_is_valid(state.detail_buf) then
    pcall(vim.api.nvim_win_set_buf, win, state.detail_buf)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  registry[buf] = nil

  if state.on_closed then
    pcall(state.on_closed, state)
  end
end

--- Save the form buffer through the CLI. Success restores the detail buffer;
--- any failure leaves the buffer modified and untouched.
function M.save(buf, cb)
  local state = state_for(buf)
  if not state then
    if cb then
      cb(false, "表单已关闭")
    end
    return
  end
  if state.saving then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local parsed = M.parse(lines)
  local plan = M.plan(parsed, state.baseline)

  if not plan.ok then
    local message = format_errors(plan.errors)
    if state.on_error then
      pcall(state.on_error, plan.errors, state)
    end
    vim.notify("loop-kit 表单：" .. message, vim.log.levels.ERROR)
    if cb then
      cb(false, plan.errors)
    end
    return
  end

  if #plan.calls == 0 then
    state.modified = false
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
    end
    if state.on_saved then
      pcall(state.on_saved, plan.fields, nil, state)
    end
    if cb then
      cb(true, nil)
    end
    restore(state)
    return
  end

  state.saving = true
  state.submit(plan, function(ok, result, results)
    vim.schedule(function()
      if state.closed then
        return
      end
      state.saving = false
      if ok then
        state.modified = false
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modified = false
        end
        state.baseline = baseline_for_result(state, plan.fields, result)
        state.last_error = nil
        if state.on_saved then
          pcall(state.on_saved, plan.fields, result, state, results)
        end
        if cb then
          cb(true, result)
        end
        restore(state)
      else
        state.modified = true
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modified = true
        end
        local message = type(result) == "table" and result.message or tostring(result)
        state.last_error = message
        if state.on_error then
          pcall(state.on_error, result, state, results)
        end
        vim.notify("loop-kit 表单保存失败：" .. tostring(message), vim.log.levels.ERROR)
        if cb then
          cb(false, result)
        end
      end
    end)
  end)
end

--- Close the form, asking about unsaved changes first.
function M.cancel(buf, cb)
  local state = state_for(buf)
  if not state then
    if cb then
      cb(false)
    end
    return
  end

  if not M.is_dirty(buf) then
    restore(state)
    if cb then
      cb(true)
    end
    return
  end

  local items = { "保存", "放弃", "取消" }
  local prompt = "表单有未保存的修改，是否保存？"
  local answered = false
  local function answer(choice)
    if answered then
      return
    end
    answered = true
    if choice == "保存" then
      M.save(buf, function(ok)
        if cb then
          cb(ok)
        end
      end)
    elseif choice == "放弃" then
      restore(state)
      if cb then
        cb(true)
      end
    else
      if cb then
        cb(false)
      end
    end
  end

  local ask = state.ask or function(choices, text, done)
    vim.ui.select(choices, { prompt = text }, done)
  end
  ask(items, prompt, answer)
end

--- Open (or focus) the form buffer for `opts.task`, or a new task when absent.
---
--- opts: root, task, nonce, client, submit, ask, detail_buf, detail_win,
---       on_saved, on_error, on_closed.
function M.open(opts)
  opts = opts or {}
  local root = normalize_root(opts.root or vim.fn.getcwd())
  local task = opts.task
  local is_new = task == nil or opts.is_new == true
  local id = task and task.id or nil
  local key
  local name

  if is_new then
    local nonce = opts.nonce or make_nonce()
    key = "new:" .. root .. ":" .. nonce
    name = M.new_buffer_name(root, nonce)
  else
    key = "task:" .. root .. ":" .. tostring(id)
    name = M.buffer_name(root, id)
  end

  local existing = by_key[key]
  if existing and registry[existing] and vim.api.nvim_buf_is_valid(existing) then
    local state = registry[existing]
    if state.detail_win and vim.api.nvim_win_is_valid(state.detail_win) then
      pcall(vim.api.nvim_win_set_buf, state.detail_win, existing)
    end
    if M.is_dirty(existing) then
      M.cancel(existing)
    end
    return existing
  end

  local fields
  if is_new then
    fields = M.defaults()
  else
    fields = {
      id = task.id,
      title = task.title or "",
      tag = task.tag or "",
      deps = deps_list(task.deps),
      doc = optional_text(task.doc),
      desc = optional_text(task.desc) or "",
    }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local set_name = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not set_name then
    local old = vim.fn.bufnr(name)
    if old > 0 and old ~= buf then
      pcall(vim.api.nvim_buf_delete, old, { force = true })
    end
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = "markdown"

  local text = M.serialize(fields)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modified = false

  local win = opts.detail_win
  if not win or win == 0 then
    win = vim.api.nvim_get_current_win()
  end
  local detail_buf = opts.detail_buf or vim.api.nvim_win_get_buf(win)

  local state = {
    buf = buf,
    key = key,
    root = root,
    id = id,
    is_new = is_new,
    fields = fields,
    baseline = task and util.deepcopy(task) or nil,
    detail_buf = detail_buf,
    detail_win = win,
    submit = opts.submit or M.make_submit(opts.client),
    ask = opts.ask,
    on_saved = opts.on_saved,
    on_error = opts.on_error,
    on_closed = opts.on_closed,
    saving = false,
    modified = false,
    original_text = text,
    closed = false,
  }

  registry[buf] = state
  by_key[key] = buf

  vim.b[buf].loopkit_form = {
    id = id,
    is_new = is_new,
    root = root,
    key = key,
  }

  local group = vim.api.nvim_create_augroup("LoopKitForm" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      M.save(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      local current = registry[buf]
      if current then
        current.modified = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      local current = registry[buf]
      if current and by_key[current.key] == buf then
        by_key[current.key] = nil
      end
      registry[buf] = nil
    end,
  })

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_buf(win, buf)
  end

  return buf
end

return M
