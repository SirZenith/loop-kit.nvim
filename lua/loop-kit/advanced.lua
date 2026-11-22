-- Advanced field actions: flow / private / touch / worktree meta.
--
-- Every write goes through `loop-cli` (with --json and an explicit
-- --project-root) and reuses the per-project serial write queue. Validation
-- happens before spawning a process so the UI can keep the user's raw input
-- when something is rejected.
local util = require("loop-kit.util")

local M = {}

M.FLOWS = {
  "full",
  "research-only",
  "quick",
  "spec-impl",
  "research-split",
  "doc-to-tasks",
}

-- Canonical stage order (crates/loop-core/src/model.rs TaskStage::ALL).
M.STAGE_ORDER = {
  "research",
  "spec",
  "json-task-split",
  "doc-task-split",
  "decision-question",
  "impl",
  "verify",
  "commit",
}

local STAGE_INDEX = {}
for index, stage in ipairs(M.STAGE_ORDER) do
  STAGE_INDEX[stage] = index
end

M.CUSTOM_FLOW = "自定义 stage 列表…"
M.CLEAR_FLOW = "清除（回到默认）"

M.PRIVATE_ON = "开启（含不可外发信息）"
M.PRIVATE_OFF = "关闭"

M.TOUCH_SET = "设定（覆盖）"
M.TOUCH_APPEND = "追加"
M.TOUCH_CLEAR = "清除回 unknown"
M.TOUCH_IMPORT = "从实现文档回填"

M.META_SET = "设置 branch/baseSha"
M.META_CLEAR = "清除"

local function trim(value)
  return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

--- Split a comma separated stage list, dropping empty segments.
function M.split_stages(text)
  local out = {}
  for raw in tostring(text or ""):gmatch("[^,]+") do
    local part = trim(raw)
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

--- Validate a custom stage list against the CLI whitelist and order.
--- Returns true, stages or false, message.
function M.validate_stages(stages)
  if type(stages) ~= "table" or #stages < 2 then
    return false, "stage 列表至少需要两个阶段（含 commit）"
  end

  local seen = {}
  local previous = 0
  for _, stage in ipairs(stages) do
    if type(stage) ~= "string" or stage == "" then
      return false, "stage 不能为空"
    end
    local order = STAGE_INDEX[stage]
    if not order then
      return false, string.format(
        '未知 stage "%s"（可用：%s）',
        stage,
        table.concat(M.STAGE_ORDER, ", ")
      )
    end
    if seen[stage] then
      return false, string.format("stage 不能重复：%s", stage)
    end
    seen[stage] = true
    if order <= previous then
      return false, string.format(
        "stage 顺序非法：%s（必须按 %s 且不重复）",
        table.concat(stages, ","),
        table.concat(M.STAGE_ORDER, ",")
      )
    end
    previous = order
  end

  if stages[#stages] ~= "commit" then
    return false, "stage 列表必须以 commit 收尾"
  end
  return true, stages
end

--- Validate one repository-relative touch path.
--- Returns true, normalized path or false, message.
function M.valid_touch_path(path)
  if type(path) ~= "string" then
    return false, "写集路径必须是字符串"
  end
  local value = trim(path)
  if value == "" then
    return false, "写集路径不能为空"
  end
  if value:find("[\r\n]") then
    return false, "写集路径不能包含换行：" .. value
  end
  while value:sub(1, 2) == "./" do
    value = value:sub(3)
  end
  if value:sub(1, 1) == "/" or value:sub(1, 1) == "\\" or value:match("^%a:[/\\]") then
    return false, "只接受仓库根相对路径（不能是绝对路径）：" .. value
  end
  for segment in value:gmatch("[^/\\]+") do
    if segment == ".." or segment == "." then
      return false, "写集路径不能包含 . 或 .. 段：" .. value
    end
  end
  return true, value
end

--- Parse a JSON string array for `touch --set/--append`.
--- Returns { ok = true, paths = {...} } or { ok = false, message = ... }.
function M.parse_touch(text)
  local raw = tostring(text or "")
  if trim(raw) == "" then
    return { ok = false, message = "请输入 JSON 字符串数组（例如 [\"lua/a.lua\"]）" }
  end

  local decoded_ok, decoded = pcall(vim.json.decode, raw)
  if not decoded_ok then
    return { ok = false, message = "写集输入必须是有效的 JSON 字符串数组：" .. tostring(decoded) }
  end
  if type(decoded) ~= "table" or not vim.islist(decoded) then
    return { ok = false, message = "写集输入必须是 JSON 字符串数组" }
  end
  if vim.tbl_isempty(decoded) then
    return {
      ok = false,
      message = "空数组不能代表「不写文件」；要清除写集请选择「清除」",
    }
  end

  local paths = {}
  for _, item in ipairs(decoded) do
    if type(item) ~= "string" then
      return { ok = false, message = "写集数组的每一项都必须是字符串" }
    end
    local valid, value = M.valid_touch_path(item)
    if not valid then
      return { ok = false, message = value }
    end
    paths[#paths + 1] = value:gsub("^%./", "")
  end
  return { ok = true, paths = paths }
end

--- Validate branch + baseSha together (both are written/cleared as a pair).
--- Returns true, { branch, base_sha } or false, message.
function M.validate_meta(branch, sha)
  local branch_value = trim(branch)
  local sha_value = trim(sha)

  if branch_value == "" then
    return false, "branch 不能为空（branch 与 baseSha 必须同时提供）"
  end
  if sha_value == "" then
    return false, "baseSha 不能为空（需要完整 40 或 64 位小写 hex）"
  end
  if branch_value:find("%s") then
    return false, "branch 不能包含空白字符"
  end
  if branch_value:find("..", 1, true) then
    return false, 'branch 不能包含 ".."'
  end
  if branch_value:sub(1, 1) == "-" then
    return false, 'branch 不能以 "-" 开头'
  end
  if not (sha_value:len() == 40 or sha_value:len() == 64) then
    return false, "baseSha 必须是 40 或 64 位小写 hex"
  end
  if sha_value:find("%X") or sha_value:find("%u") then
    return false, "baseSha 必须是 40 或 64 位小写 hex（不能包含大写或非 hex 字符）"
  end
  return true, { branch = branch_value, base_sha = sha_value }
end

local function task_from_response(data)
  if type(data) ~= "table" then
    return nil
  end
  if type(data.task) == "table" and type(data.task.id) == "string" then
    return data.task
  end
  if type(data.id) == "string" and (data.title ~= nil or data.status ~= nil) then
    return data
  end
  return nil
end

local Advanced = {}
Advanced.__index = Advanced

local function default_select(items, opts, cb)
  vim.ui.select(items, opts, cb)
end

local function default_input(prompt, opts, cb)
  vim.ui.input(vim.tbl_extend("force", { prompt = prompt }, opts or {}), cb)
end

local function default_ask(prompt, cb)
  vim.ui.select({ "确认", "取消" }, { prompt = prompt }, function(choice)
    cb(choice == "确认")
  end)
end

local function default_notify(message)
  vim.notify(message, vim.log.levels.INFO)
end

--- opts: source, state, client, root, select, input, ask, notify, exec, reload.
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Advanced)
  self.source = assert(opts.source, "loop-kit.advanced: source is required")
  self.state = assert(opts.state, "loop-kit.advanced: state is required")
  self.client = opts.client or self.source.client
  self.root = opts.root or (self.client and self.client.project_root) or self.source.root
  self.select = opts.select or default_select
  self.input = opts.input or default_input
  self.ask = opts.ask or default_ask
  self.notify = opts.notify or default_notify

  if opts.exec then
    self.exec = opts.exec
  elseif self.client then
    self.exec = function(command, args, run_opts, cb)
      self.client:run(command, args, run_opts, cb)
    end
  else
    error("loop-kit.advanced: client or exec is required")
  end

  if opts.reload then
    self.reload = opts.reload
  else
    self.reload = function(cb)
      self.source:list({ no_sync = true }, cb)
    end
  end
  return self
end

function Advanced:_invalid(cb, action, id, message)
  cb({
    ok = false,
    action = action,
    id = id,
    code = "invalid",
    kind = "usage",
    message = message,
  })
end

function Advanced:_cancel(cb, action, id, message, extra)
  local out = {
    ok = false,
    action = action,
    id = id,
    code = "cancelled",
    message = message or "已取消",
  }
  for key, value in pairs(extra or {}) do
    out[key] = value
  end
  cb(out)
end

function Advanced:_failure(action, id, res, extra)
  res = res or {}
  local out = {
    ok = false,
    action = action,
    id = id,
    code = res.code or "exit",
    kind = res.kind,
    exit_code = res.exit_code,
    message = res.message or "写操作失败",
    error = res,
  }
  for key, value in pairs(extra or {}) do
    if out[key] == nil then
      out[key] = value
    end
  end
  return out
end

function Advanced:_refresh(action, id, payload, cb)
  self.reload(function(list_res)
    list_res = list_res or {}
    local task = task_from_response(payload)
    if list_res.ok then
      local tasks = util.deepcopy(list_res.tasks or {})
      if task then
        local replaced = false
        for index, item in ipairs(tasks) do
          if item.id == task.id then
            tasks[index] = vim.tbl_extend("force", item, task)
            replaced = true
            break
          end
        end
        if not replaced then
          tasks[#tasks + 1] = task
        end
      end
      self.state:set_tasks(tasks)
    end
    cb({
      ok = true,
      action = action,
      id = id,
      payload = payload,
      task = task,
      list = list_res,
      snapshot = self.source.snapshot,
    })
  end)
end

function Advanced:_submit(action, id, command, args, extra, cb)
  extra = extra or {}
  self.state:enqueue(function(finish)
    local finished = false
    local function complete(res)
      if finished then
        return
      end
      finished = true
      if not res.ok then
        local out = self:_failure(action, id, res, extra)
        finish()
        cb(out)
        return
      end
      self:_refresh(action, id, res.data, function(out)
        out.response = res
        finish()
        cb(out)
      end)
    end

    local ok, err = pcall(self.exec, command, args, {}, complete)
    if not ok then
      complete({
        ok = false,
        code = "spawn",
        kind = "spawn",
        message = "无法启动 loop-cli：" .. tostring(err),
      })
    end
  end)
end

--- Best-effort lookup of the current flow for `id` (menu filtering).
function Advanced:_current_flow(id)
  local lists = {
    self.state and self.state.tasks,
    self.source and self.source.snapshot and self.source.snapshot.tasks,
  }
  for index = 1, #lists do
    for _, task in ipairs(lists[index] or {}) do
      if task.id == id then
        return task.flow
      end
    end
  end
end

--- Choose a named flow, a custom stage list, or clear the explicit flow.
function Advanced:flow(id, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "flow", id, "任务 id 不合法")
  end
  self:list_flows(function(flows)
    if not flows then
      self.notify("读取流程列表失败，使用内置流程")
      flows = { builtin = vim.deepcopy(M.FLOWS), custom = {} }
    end
    local items = M.flow_items(flows, self:_current_flow(id))
    items[#items + 1] = M.CUSTOM_FLOW
    items[#items + 1] = M.CLEAR_FLOW
    self.select(items, { prompt = "流程" }, function(choice)
      if choice == nil then
        return self:_cancel(cb, "flow", id)
      end
      if choice == M.CLEAR_FLOW then
        return self:_submit("flow", id, "flow", { id, "--clear" }, {}, cb)
      end
      if choice == M.CUSTOM_FLOW then
        return self.input(
          "stage 列表（逗号分隔，必须以 commit 收尾）：",
          function(raw)
            if raw == nil then
              return self:_cancel(cb, "flow", id)
            end
            local stages = M.split_stages(raw)
            local ok, value = M.validate_stages(stages)
            if not ok then
              return cb({
                ok = false,
                action = "flow",
                id = id,
                code = "invalid",
                kind = "usage",
                message = value,
                input = raw,
              })
            end
            self:_submit(
              "flow",
              id,
              "flow",
              { id, "--flow", table.concat(value, ",") },
              { input = raw },
              cb
            )
          end
        )
      end
      self:_submit("flow", id, "flow", { id, "--flow", choice }, { input = choice }, cb)
    end)
  end)
end

--- Explicitly turn the "contains non-shareable info" marker on or off.
function Advanced:private(id, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "private", id, "任务 id 不合法")
  end
  self.select({ M.PRIVATE_ON, M.PRIVATE_OFF }, { prompt = "不可外发标记" }, function(choice)
    if choice == nil then
      return self:_cancel(cb, "private", id)
    end
    local flag = choice == M.PRIVATE_ON and "--on" or "--off"
    self:_submit("private", id, "private", { id, flag }, {}, cb)
  end)
end

--- Set / append / clear / import the task-level write scope.
function Advanced:touch(id, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "touch", id, "任务 id 不合法")
  end
  local items = { M.TOUCH_SET, M.TOUCH_APPEND, M.TOUCH_CLEAR, M.TOUCH_IMPORT }
  self.select(items, { prompt = "写集" }, function(choice)
    if choice == nil then
      return self:_cancel(cb, "touch", id)
    end
    if choice == M.TOUCH_CLEAR then
      return self:_submit("touch", id, "touch", { id, "--clear" }, {}, cb)
    end
    if choice == M.TOUCH_IMPORT then
      return self:_submit("touch", id, "touch", { id, "--import-doc" }, {}, cb)
    end

    self.input(
      '写集 JSON 字符串数组（例如 ["lua/a.lua", "tests/a_spec.lua"]）：',
      function(raw)
        if raw == nil then
          return self:_cancel(cb, "touch", id)
        end
        local parsed = M.parse_touch(raw)
        if not parsed.ok then
          return cb({
            ok = false,
            action = "touch",
            id = id,
            code = "invalid",
            kind = "usage",
            message = parsed.message,
            input = raw,
          })
        end
        local flag = choice == M.TOUCH_SET and "--set" or "--append"
        local args = { id, flag }
        vim.list_extend(args, parsed.paths)
        self:_submit("touch", id, "touch", args, { input = raw }, cb)
      end
    )
  end)
end

--- Write branch + full baseSha together, or clear both after confirmation.
function Advanced:meta(id, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "meta", id, "任务 id 不合法")
  end
  self.select({ M.META_SET, M.META_CLEAR }, { prompt = "worktree meta" }, function(choice)
    if choice == nil then
      return self:_cancel(cb, "meta", id)
    end
    if choice == M.META_CLEAR then
      return self.ask(
        string.format("清除 %s 的 worktree meta（branch 与 baseSha 同清）？", id),
        function(yes)
          if not yes then
            return self:_cancel(cb, "meta", id)
          end
          self:_submit("meta", id, "meta", { id, "--clear" }, {}, cb)
        end
      )
    end

    self.input("branch：", function(branch)
      if branch == nil then
        return self:_cancel(cb, "meta", id)
      end
      self.input("完整 baseSha（40 或 64 位小写 hex）：", function(sha)
        if sha == nil then
          return self:_cancel(
            cb,
            "meta",
            id,
            "已取消：branch 与 baseSha 必须同时写入",
            { input = { branch = branch } }
          )
        end
        local ok, value = M.validate_meta(branch, sha)
        if not ok then
          return cb({
            ok = false,
            action = "meta",
            id = id,
            code = "invalid",
            kind = "usage",
            message = value,
            input = { branch = branch, base_sha = sha },
          })
        end
        self:_submit(
          "meta",
          id,
          "meta",
          { id, "--branch", value.branch, "--base-sha", value.base_sha },
          { input = value },
          cb
        )
      end)
    end)
  end)
end

--- Normalize `flow --list` output into { builtin = {...}, custom = {name=stages} }.
function M.flow_payload(payload)
  payload = type(payload) == "table" and payload or {}
  local builtin = {}
  if type(payload.builtin) == "table" then
    for _, name in ipairs(payload.builtin) do
      if type(name) == "string" and name ~= "" then
        builtin[#builtin + 1] = name
      end
    end
  end
  if #builtin == 0 then
    builtin = vim.deepcopy(M.FLOWS)
  end
  local custom = {}
  local raw = payload.custom
  if type(raw) == "table" then
    if #raw > 0 then
      for _, entry in ipairs(raw) do
        if type(entry) == "table" and entry.name ~= nil then
          custom[tostring(entry.name)] = entry.stages or {}
        elseif type(entry) == "string" then
          custom[entry] = {}
        end
      end
    else
      for name, stages in pairs(raw) do
        custom[tostring(name)] = stages
      end
    end
  end
  return { builtin = builtin, custom = custom }
end

--- True when `name` is a user-defined (custom) named flow.
function M.is_custom_flow(flows, name)
  if type(name) ~= "string" then
    return false
  end
  return type(flows) == "table"
    and type(flows.custom) == "table"
    and flows.custom[name] ~= nil
end

--- Flow names in a stable order: builtin first, then custom names sorted.
--- The custom flow passed as `current` is omitted from the choice list.
function M.flow_items(flows, current)
  local items = {}
  for _, name in ipairs(flows and flows.builtin or {}) do
    items[#items + 1] = name
  end
  local custom = {}
  for name in pairs(flows and flows.custom or {}) do
    custom[#custom + 1] = name
  end
  table.sort(custom)
  for _, name in ipairs(custom) do
    if name ~= current then
      items[#items + 1] = name
    end
  end
  return items
end

--- Read builtin and custom flows. cb({builtin,custom}, err).
function Advanced:list_flows(cb)
  self.exec("flow", { "--list", "--no-sync" }, {}, function(res)
    if not res or not res.ok then
      return cb(nil, res)
    end
    cb(M.flow_payload(res.data), res)
  end)
end

--- Set `tag` through `edit <id> --tag`.
function Advanced:set_tag(id, value, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "tag", id, "任务 id 不合法")
  end
  self:_submit("tag", id, "edit", { id, "--tag", tostring(value) }, { value = value }, cb)
end

--- Replace `deps` with `deps <id> --set a,b` (`--set ''` clears it).
function Advanced:set_deps(id, values, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "deps", id, "任务 id 不合法")
  end
  local list = {}
  for _, value in ipairs(values or {}) do
    list[#list + 1] = tostring(value)
  end
  local arg = table.concat(list, ",")
  self:_submit("deps", id, "deps", { id, "--set", arg }, { deps = list }, cb)
end

--- Set or clear `doc` (`doc <id> --path` / `--clear`).
function Advanced:set_doc(id, value, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "doc", id, "任务 id 不合法")
  end
  value = tostring(value or "")
  if value == "" then
    return self:_submit("doc", id, "doc", { id, "--clear" }, { value = "" }, cb)
  end
  self:_submit("doc", id, "doc", { id, "--path", value }, { value = value }, cb)
end

local PROMPT_FLAGS = {
  docParent = "--doc-parent",
  specPrompt = "--spec-prompt",
  researchPrompt = "--research-prompt",
  codePrompt = "--code-prompt",
  verifyPrompt = "--verify-prompt",
  docTaskSplitPrompt = "--doc-task-split-prompt",
}

M.PROMPT_FLAGS = PROMPT_FLAGS

--- Set a string field through `edit <id> --<flag>`; an empty string clears it.
function Advanced:set_prompt(id, field, value, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "prompt", id, "任务 id 不合法")
  end
  local flag = PROMPT_FLAGS[field]
  if not flag then
    return self:_invalid(cb, "prompt", id, "未知的字段：" .. tostring(field))
  end
  value = tostring(value or "")
  self:_submit("prompt", id, "edit", { id, flag, value }, { field = field, value = value }, cb)
end

--- Set `flow` from a raw name or comma-separated stage list; empty clears it.
function Advanced:set_flow(id, value, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "flow", id, "任务 id 不合法")
  end
  value = tostring(value or "")
  if value == "" then
    return self:_submit("flow", id, "flow", { id, "--clear" }, { value = "" }, cb)
  end
  self:_submit("flow", id, "flow", { id, "--flow", value }, { value = value }, cb)
end

--- Replace `touch` with `touch <id> --set ...` (`--clear` for an empty list).
function Advanced:set_touch(id, paths, cb)
  id = util.normalize_id(id)
  if not id then
    return self:_invalid(cb, "touch", id, "任务 id 不合法")
  end
  local list = {}
  for _, path in ipairs(paths or {}) do
    list[#list + 1] = tostring(path)
  end
  if #list == 0 then
    return self:_submit("touch", id, "touch", { id, "--clear" }, { paths = list }, cb)
  end
  local args = { id, "--set" }
  vim.list_extend(args, list)
  self:_submit("touch", id, "touch", args, { paths = list }, cb)
end

return M
