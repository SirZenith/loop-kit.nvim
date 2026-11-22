---
task_id: "#15"
summary: 为单行路径字段与 touch 多行编辑增加项目根锚定的路径补全
module: nvim
tag: feature
status: archived
updated: 2026-11-22
verification_levels: [unit, fake-dom]
doc_ref:
  - .pi/loop-kit/docs/nvim/2026-11-22T16-13-41-kv-field-editing.md
  - .pi/loop-kit/docs/nvim/2026-11-22T15-18-00-per-field-edit-mode.md
---

## 目标

`loop/TARGETS.md` 的功能集仍待填写；本条目属于 Neovim 伴侣插件的编辑体验补强：让详情里的路径型字段可以直接选路径，而不是纯手输。覆盖两类编辑入口：

1. 单行路径字段：`doc`、`docParent`、`specPrompt`、`researchPrompt`、`codePrompt`、`verifyPrompt`、`docTaskSplitPrompt`。
2. `touch` 字段的 acwrite 多行编辑 buffer。

统一使用项目根（`loop.config.json` 所在目录，即 `Board.root`）作为补全基准，不依赖 Neovim 的当前工作目录。补全只提供候选，不阻止自由输入、新建文件或手动输入项目根外路径。

非目标：

- `T` 快捷键的 JSON 数组形式 `touch` 编辑（`advanced.lua` 的 `touch` 命令）不增加补全。
- 不接管或配置用户的 nvim-cmp / cmp-path；插件自身不新增运行时依赖。
- 不实现递归扫描、glob 展开或路径存在性校验。

## 现状

### 单行字段

- `lua/loop-kit/ui/board.lua:736-744` `Board:_edit_input(prompt, default, cb)` 直接调用 `vim.ui.input({ prompt = prompt, default = default }, cb)`，没有 `completion`。
- `lua/loop-kit/ui/board.lua:1132-1168` `Board:_edit_prompt(task, field)` 处理 7 个路径字段：

  | field | 提示语 | 语义 |
  | --- | --- | --- |
  | `doc` | `实现文档路径: ` | 实现文档路径 |
  | `docParent` | `父条目: ` | 父级参考文档路径（不是任务 id） |
  | `specPrompt` | `spec 提示词: ` | 提示词覆盖文件路径 |
  | `researchPrompt` | `调研提示词: ` | 提示词覆盖文件路径 |
  | `codePrompt` | `实现提示词: ` | 提示词覆盖文件路径 |
  | `verifyPrompt` | `验收提示词: ` | 提示词覆盖文件路径 |
  | `docTaskSplitPrompt` | `文档拆分提示词: ` | 提示词覆盖文件路径 |

- 保存仍走 `advanced:set_doc`（`lua/loop-kit/advanced.lua:643`）或 `advanced:set_prompt`（`lua/loop-kit/advanced.lua:659`）；本条目不改 CLI 参数或校验。

### touch 多行编辑

- `lua/loop-kit/ui/board.lua:1245-1253` `Board:_edit_touch(task)` 把 `task.touch` 用换行拼成正文，交给 `_begin_edit({ kind = "touch" }, ...)`。
- `lua/loop-kit/edit.lua:340-368` `M.open(opts)` 创建 `loopkit://<root>/edit/<id>/<target>` 的 acwrite buffer，设置 `buftype=acwrite`、`bufhidden=wipe`、`filetype=markdown`，没有设置 `omnifunc`。
- 保存时 `board.lua:880-923` 的 `_save_edit` 按行拆分，经 `kv.touch_paths` 和 `advanced.valid_touch_path` 校验后调用 `advanced:set_touch`。

### 路径语义

- `lua/loop-kit/util.lua:13-24` `util.absolute_path(base, path)`：绝对路径原样规范化，相对路径按 `base` 解析。
- `lua/loop-kit/ui/detail.lua:145-161` `resolve_doc(root, doc)` 用同一规则解析 `doc`。
- `.pi/loop-kit/schema/LOOP.schema.json` 与 `.pi/loop-kit/schema/loop.meta.schema.json` 约定：
  - `doc`：绝对路径原样；相对路径按项目根解析。
  - `docParent`：父级参考文档路径，同样按项目根解析。
  - 5 个 prompt 字段：提示词覆盖文件路径，按项目根解析。
  - `touch`：非空仓库相对路径/glob 数组；不允许绝对路径，也不允许 `.` / `..` 段。
- `lua/loop-kit/advanced.lua:110-132` `M.valid_touch_path` 会去掉开头的 `./`，并拒绝绝对路径、盘符、反斜杠、`.`、`..` 段和换行。

### 为什么不能直接用 cmp-path

- cmp-path 默认只识别 `./`、`../`、`~/`、`$ENV/` 和绝对路径；裸相对路径（如 `lua/loop-kit`）不会生成候选。
- cmp-path 用 `vim.fn.expand('#<bufnr>:p:h')` 推断目录。编辑 buffer 的名字是 `loopkit://...`，展开结果是 `loopkit:/...` 这类不存在的路径，最终 `fs_scandir` 返回 `ENOENT`，候选为空。
- 单行字段走 `vim.ui.input`，完全不经过 nvim-cmp，cmp-path 无法覆盖。
- 该插件不应要求用户修改 cmp-path 配置；因此在本插件内提供不依赖 nvim-cmp 的补全。

## 方案

### 新增 `lua/loop-kit/path_complete.lua`

一个无运行时依赖的路径候选模块，负责“列出当前层 + 前缀过滤”，并提供两个入口：

```lua
---@param root string 项目根
---@param lead string 当前输入
---@param opts? { allow_absolute?: boolean }
---@return string[]
function M.complete(root, lead, opts) end

--- vim.ui.input 的 completion 字符串；同时设置本次输入的根上下文
---@return string "customlist,v:lua.LoopKitPathComplete"
function M.input_completion(root, opts) end

--- acwrite buffer 的 omnifunc
function M.omnifunc(findstart, base) end

--- 给编辑 buffer 挂上路径上下文与 omnifunc
function M.attach_omnifunc(buf, root, opts) end
```

补全规则：

| 输入 | 结果 |
| --- | --- |
| `""` | 项目根下一层条目；目录带 `/`，隐藏项默认不列出 |
| `lu` | `lua/` |
| `lua/lo` | `lua/loop-kit/` |
| `lua/loop-kit/ui/bo` | `lua/loop-kit/ui/board.lua` |
| `./lua/` | `./lua/loop-kit/`（保留用户输入的 `./` 前缀） |
| `../` 或含 `..` 段 | 不返回候选；允许用户继续手输 |
| 绝对路径 / `~/` / `$ENV/` | `allow_absolute=true` 时委托 `vim.fn.getcompletion(lead, "file")`；否则返回 `{}` |
| 不存在的目录 | `{}`，不抛错 |

实现要点：

- 只扫描当前层：`vim.fs.dir(scan_dir, { depth = 1 })`，用 `pcall` 包住迭代，目录不存在时静默返回空表。
- `lead` 按最后一个 `/` 分为 `dir_part` 与 `prefix`；只在 `dir_part` 下匹配 `prefix`。
- 目录候选追加 `/`，文件候选不加。
- 隐藏项仅在当前段以 `.` 开头时返回。
- 保留候选中的空格；不 trim 用户输入，避免破坏文件名。
- 候选统一使用 `/`；含 `\` 的输入不补全，交给用户手输。
- 排序后返回，保证测试和展示稳定。
- 绝对路径分支只对 `doc` / `docParent` / prompt 字段开启；`touch` 固定 `allow_absolute=false`，与 `valid_touch_path` 的约束一致。

`vim.ui.input` 的 `customlist` 只能调用全局可寻址的 Vimscript 函数，Lua 模块函数需绑定到 `_G`：

```lua
local input_root, input_allow_absolute = nil, true

function M.input_completion(root, opts)
  input_root = root
  input_allow_absolute = not opts or opts.allow_absolute ~= false
  return "customlist,v:lua.LoopKitPathComplete"
end

function M.omnifunc(findstart, base)
  if findstart == 1 then
    return 0 -- touch 一行就是一个路径，整行作为补全起点
  end
  local root = vim.b.loopkit_path_root
  if not root or root == "" then
    return {}
  end
  return M.complete(root, base or "", {
    allow_absolute = vim.b.loopkit_path_allow_absolute == true,
  })
end

function M.attach_omnifunc(buf, root, opts)
  vim.b[buf].loopkit_path_root = root
  vim.b[buf].loopkit_path_allow_absolute = (opts and opts.allow_absolute) == true
  vim.bo[buf].omnifunc = "v:lua.LoopKitPathOmnifunc"
end

_G.LoopKitPathComplete = function(lead)
  if not input_root then
    return {}
  end
  return M.complete(input_root, lead, { allow_absolute = input_allow_absolute })
end
_G.LoopKitPathOmnifunc = M.omnifunc
```

注意：`v:lua.require("loop-kit.path_complete").complete` 不能作为 `customlist` 函数名；必须使用上述全局函数。模块级输入上下文只服务于“打开单行输入后立即触发”的场景；同一时间只会有一个 `vim.ui.input`，最后设置者生效即可。

### 单行字段接线

- 扩展 `Board:_edit_input` 接受第 4 个参数 `input_opts`：

  ```lua
  function Board:_edit_input(prompt, default, cb, input_opts)
    if self.opts.edit_input then
      return self.opts.edit_input(prompt, default, cb, input_opts)
    end
    if self.opts.input then
      return self.opts.input(prompt, default, cb)
    end
    vim.ui.input(
      vim.tbl_extend("force", { prompt = prompt, default = default }, input_opts or {}),
      cb
    )
  end
  ```

- 新增 `Board:_edit_path_input(prompt, default, cb)`，用 `path_complete.input_completion(self.root, { allow_absolute = true })` 生成 `completion`。
- `Board:_edit_prompt` 改用 `_edit_path_input`；`_edit_title`、`_edit_tag`、`_edit_deps` 等非路径字段继续走原来的 `_edit_input`，不传 `completion`。
- 现有测试注入的 `edit_input` 是 3 参数函数；Lua 会忽略多余实参，因此保持兼容。新增测试可以声明第 4 个参数检查 `completion`。
- 若用户的 `vim.ui.input` 被 dressing / noice / telescope-ui-select 等覆盖且忽略 `completion`，补全能力自然降级为无补全，不影响保存。

### touch buffer 接线

- 在 `edit.M.open` 完成 `vim.bo[buf].filetype` 设置后，对 `opts.target.kind == "touch"` 调用：

  ```lua
  if opts.target and opts.target.kind == "touch" then
    path_complete.attach_omnifunc(buf, opts.root, { allow_absolute = false })
  end
  ```

- 补全触发方式为 Neovim 原生 `<C-x><C-o>`（omni completion）；不新增按键映射，避免与用户配置冲突。
- `findstart=1` 返回 0，使整行作为一个补全词，天然支持带空格的文件名。
- `base` 为空时列出项目根下一层；输入 `lua/` 后列出 `lua/` 下一层。

### 边界

- 不涉及 `lua/loop-kit/advanced.lua` 的 `touch` 命令（`T` 快捷键 JSON 数组编辑）。
- `tests/run.lua` 会自动发现新增的 `*_spec.lua`，无需改测试入口。
- `README.md` 与 `doc/loop-kit.txt` 的路径字段说明补充 `<C-x><C-o>` 触发方式。

### 不采用的方案

| 方案 | 不采用原因 |
| --- | --- |
| 只给 `vim.ui.input` 传 `completion="file"` | 基于 Neovim 当前工作目录，不是项目根；无法保证 `doc` / prompt 的解析基准 |
| 让用户改 cmp-path 的 `get_cwd` | 需要用户配置；cmp-path 仍只支持 `./`、`../` 等前缀，裸相对路径无效；单行 `vim.ui.input` 仍覆盖不到 |
| 在插件内调用 `cmp.setup.buffer` 注入 path source | 侵入用户补全配置，且仍然解决不了 `loopkit://` 的 cwd 问题与裸相对路径限制 |
| 为 `touch` 复用单行输入 | 丢失多行编辑能力，改动保存路径与交互，收益低 |

## 改动范围

- `lua/loop-kit/path_complete.lua`
- `lua/loop-kit/ui/board.lua`
- `lua/loop-kit/edit.lua`
- `tests/unit/path_complete_spec.lua`
- `tests/fake-dom/edit_spec.lua`
- `README.md`
- `doc/loop-kit.txt`

## 验收标准

- [单测] `tests/unit/path_complete_spec.lua`：空输入返回项目根下一层，目录带 `/`，隐藏项默认不出现；`lu` 只返回 `lua/`；`lua/lo` 返回 `lua/loop-kit/`；`./lua/` 保留 `./` 前缀；`../` 返回空表；`allow_absolute=false` 时绝对路径返回空表；`allow_absolute=true` 时绝对路径返回非空候选；不存在的目录返回空表且不报错；带空格的文件名原样返回。
- [单测] `tests/unit/path_complete_spec.lua`：设置当前 buffer 的 `vim.b.loopkit_path_root` 后，`M.omnifunc(1, nil)` 返回 `0`；`M.omnifunc(2, "lua/lo")` 返回 `lua/loop-kit/`；`vim.bo[buf].omnifunc` 经 `attach_omnifunc` 后为 `v:lua.LoopKitPathOmnifunc`。
- [假 DOM] `tests/fake-dom/edit_spec.lua`：对 `doc`、`docParent`、`specPrompt`、`researchPrompt`、`codePrompt`、`verifyPrompt`、`docTaskSplitPrompt` 逐个把光标放到对应行并触发 `edit`，注入的 `edit_input(prompt, default, cb, opts)` 收到的 `opts.completion` 均为 `customlist,v:lua.LoopKitPathComplete`。
- [假 DOM] `tests/fake-dom/edit_spec.lua`：编辑 `title` 时 `edit_input` 不收到 `completion`（第 4 参数为 `nil` 或没有 `completion` 字段）。
- [假 DOM] `tests/fake-dom/edit_spec.lua`：把光标放到 `touch` 行触发 `edit` 后，编辑 buffer 满足 `vim.bo[buf].omnifunc == "v:lua.LoopKitPathOmnifunc"`、`vim.b[buf].loopkit_path_root == board.root`、`vim.b[buf].loopkit_path_allow_absolute == false`；`<C-x><C-o>` 所需的上下文已就绪。
- [假 DOM] `tests/fake-dom/advanced_spec.lua`：`T` 快捷键的 JSON `touch` 编辑保持原行为，仍只调用一次 `vim.ui.input` 并接受 JSON 数组字符串，不因本改动新增补全参数。
- [单测] 既有 `tests/unit/edit_spec.lua`、`tests/unit/kv_spec.lua` 以及完整 `nvim --headless -u tests/minimal_init.lua -l tests/run.lua` 全部通过。

## 待确认决策

无。已确认：`T` 快捷键的 JSON `touch` 编辑不增加补全；`touch` 只补全仓库相对路径；单行 `doc` / `docParent` / prompt 字段允许绝对路径。

## 关联文档

- `.pi/loop-kit/docs/nvim/2026-11-22T16-13-41-kv-field-editing.md`：字段级编辑的基线设计，定义了哪些字段走单行输入、哪些走 acwrite buffer。
- `.pi/loop-kit/docs/nvim/2026-11-22T15-18-00-per-field-edit-mode.md`：光标定位与字段编辑入口的来源。
- `README.md`：字段编辑与 `T` / `e` 键的现有用户说明，实施后需要补充路径补全触发方式。

VERIFICATION_LEVELS: unit,fake-dom
