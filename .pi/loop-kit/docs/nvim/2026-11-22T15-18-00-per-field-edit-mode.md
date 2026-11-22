---
task_id: "#11"
summary: "看板按光标位置的字段级编辑模式：标题/阶段名走简单输入，描述与提示词走 acwrite 编辑 buffer；移除整表单。"
module: nvim
tag: feature
status: archived
updated: 2026-11-22
verification_levels: [unit, fake-dom, render]
deferred_levels: [manual]
doc_ref: .pi/loop-kit/docs/nvim/2026-11-22T13-08-46-ui-display-style.md
---

# 看板按光标位置的字段级编辑模式

## 目标

让 `e` 在任务列表与任务详情窗口中按光标位置编辑「当前指向的那一段内容」，而不是整份表单：
大段 Markdown 内容（任务描述、用户提示词、单个阶段提示词）进入整窗编辑 buffer，单行内容
（任务标题、阶段名）走输入框。借此把「看内容 → 改这一段」的路径缩到最短，并保持零运行时依赖、
所有写入仍经 `loop-cli edit`。

`.pi/loop-kit/TARGETS.md` 的功能集与体验准则尚未填写，本条以「新增功能（tag: feature）」处理。

## 现状

- `lua/loop-kit/ui/board.lua`
  - `DEFAULT_KEYS` 中 `e = "edit"`、`a = "add"`（23-53 行）。
  - `Board:_bind_keys`（256-270 行）：列表 buffer 绑定全部键位；详情 buffer 仅绑定 `q ? o e`。
  - `Board:_draw_detail`（461-483 行）：每次 draw 都会把 `self.detail_buf` 强制 `nvim_win_set_buf`
    回详情窗口；编辑期间任何 refresh/draw 都会顶掉编辑 buffer。
  - `Board:_open_form`（690 行起）与 `ACTIONS.edit`（831-836 行）/`ACTIONS.add`（837-839 行）
    都调用 `require("loop-kit.form").open`。
- `lua/loop-kit/form.lua`（837 行）：整表单 acwrite buffer，覆盖 title/tag/deps/doc/desc；
  已有可复用的生命周期——`BufWriteCmd → M.save`、失败保留脏文本、成功 `restore(state)` 换回
  `detail_buf`、`registry`/`by_key` 去重、`TextChanged/TextChangedI` 置脏。
- `lua/loop-kit/render.lua` `M.detail`（272-519 行）返回 `{lines, fields, title_line, highlights}`，
  行号齐全：`title_line`、`desc`/`desc_content`、`userPrompt`/`userPrompt_content`、`stagePrompt`
  （空时另有 `stagePrompt_content` 占位行）、`stagePrompt.<阶段>`、`stagePrompt.<阶段>.content`。
- `lua/loop-kit/ui/detail.lua`：只读 nofile buffer，写入时临时翻转 `modifiable`；`self.rendered`
  保存最近一次渲染结果。
- `lua/loop-kit/ui/list.lua`：`draw()` 支持注入 `hint`（整体下移 2 行）；`cursor_task()` 当前
  直接返回 `state:selected()`。
- `lua/loop-kit/actions.lua`：只有 claim/done/force_done/block/remove，写入经
  `state:enqueue` 串行队列；`_refresh` 负责 reload 并应用 `_merge_task`；`_failure` 已能区分
  exit 4。没有字段编辑入口。
- `lua/loop-kit/cli.lua`：`Client:run(command, args, opts, cb)` 支持 `opts.stdin`，配合
  `--desc-file -` / `--user-prompt-file -` / `--stage-prompt-file 阶段=-` 传大段文本。
- loop-cli 侧能力已核对（`/home/luli/Developer/tools/loop-kit`）：
  - `edit --stage-prompt` 按 key 合并，trim 后为空即删除该键，删空则整体清除
    （`crates/loop-cli/src/lib.rs:1505-1535`，测试 `s334_edit_stage_prompt_merges_and_deletes`）。
  - 阶段名：内建 `research / spec / json-task-split / doc-task-split / decision-question / impl /
    verify / commit`，或外部名（非空、含 `.`、无空白，`crates/loop-core/src/model.rs:258-288`）。
  - 空标题 CLI 不拦，须由 UI 校验。
  - 一次调用只能有一个 stdin 源，因此每次保存只写一个内容块。

## 方案

### 模块划分

新增 `lua/loop-kit/edit.lua`，单一职责：**把 detail 窗口临时切成一个单目标 acwrite 编辑 buffer**，
不管任务变更逻辑。Board 负责「编辑态」状态机与目标定位；`actions.lua` 负责组装并执行
`loop-cli edit`。删除 `lua/loop-kit/form.lua`。

```
Board (编辑态 + 目标定位 + 简单输入流程)
  └─ edit.lua   : buffer 生命周期 / :w / <Esc> / 列表侧信息条
       └─ actions.lua : edit_title / edit_desc / edit_user_prompt /
                        upsert_stage_prompt / rename_stage_prompt / delete_stage_prompt
            └─ cli.run("edit", args, { stdin = ... })
```

### 编辑目标模型

用一张表描述目标，避免字符串散落：

```lua
-- 简单输入（input）
{ kind = "title" }
{ kind = "stage_new" }                        -- 输入阶段名 → 可能进入 stage_content
{ kind = "stage_rename", stage = "spec" }     -- 输入新阶段名

-- 编辑 buffer（acwrite）
{ kind = "desc" }
{ kind = "user_prompt" }
{ kind = "stage_content", stage = "spec" }
```

每个目标有 `label`（用于列表信息条与 buffer 名），如「任务描述」「用户提示词」「阶段提示词 · spec」。

### 光标位置 → 编辑目标

- **列表窗口按 `e`**：`{ kind = "desc" }`，目标任务为 `state:selected()`；进入编辑模式后
  `nvim_set_current_win(detail_win)`。
- **详情窗口按 `e`**：用 `detail.rendered` 的 `fields` 行号 + 光标行计算，**不扫描 Markdown 标题**
  （正文自身可能含 `#`）：
  - 光标行 == `title_line` → `title`。
  - 在 `# 任务描述` 区间 → `desc`。
  - 在 `# 用户提示词` 区间 → `user_prompt`。
  - 光标行 == 某个 `stagePrompt.<阶段>` 行 → `stage_rename`。
  - 在某个阶段条目的正文区（该 `## <阶段>` 行之后、下一个 `##` 或缓冲末尾之前）→ `stage_content`。
  - 其余情况（元数据行、decide/analysis、`# 各阶段提示词` 标题行及其与首个阶段之间的空行、
    空集合时的 `stagePrompt_content` 占位行）→ 已确认决策：
    - `# 各阶段提示词` 章节标题及其尾部区域 → `stage_new`；
    - **元数据区与 decide/analysis → `readonly`**：不进入编辑，提示「该行暂不支持编辑」。
      其中 tag/deps/doc/提示词路径/flow/touch 的字段级编辑由后续条目 `#12` 提供，
      origin/openAt/closedAt/hash 由 `#12` 标注为只读并说明来源。
- 区间计算集中为 `Board:_edit_target()`（纯函数拆到 `edit.lua` 的 `M.target_at(rendered, cursor_line)`
  便于单测）：先按字段行号排序得到所有「锚点行」，取不大于光标行的最后一个锚点，再按锚点类型
  决定目标。无选中任务或 `rendered` 缺失时 no-op 并通知。

### 简单编辑模式（vim.ui.input）

统一经 Board 注入的 `input`（缺省 `vim.ui.input`），便于测试：

- `title`：`default = task.title`。`nil` → 取消；`""` → 通知「任务标题不允许为空」，不发起编辑；
  与原标题相同 → 无操作。
- `stage_new`：提示输入阶段名。`nil` → 取消；`""` → 通知「阶段名不能为空」；
  名称不合法 → 通知可用阶段与外部名规则；与现有阶段同名 → `ask` 二次确认「该阶段已存在，
  是否直接编辑其内容？」确认则进入该阶段的 `stage_content`，取消则中止。
  通过后以空内容进入 `stage_content`（此时**不调用 CLI**，仅记录 `is_new`；只有 `:w` 才写入）。
- `stage_rename`：`default = 当前阶段名`。`nil` → 取消；与当前名相同 → 无操作；
  与其它阶段同名 → 通知「已有同名条目，改名失败」；`""` → `ask` 二次确认「删除该阶段提示词条目？」，
  确认后走 `delete_stage_prompt`；合法新名 → `rename_stage_prompt`（一次 `edit` 调用携带
  `--stage-prompt-file 新名=-`（stdin 为原内容）+ `--stage-prompt 旧名=`）。

阶段名校验规则与 loop-cli 对齐：内建 8 名，或 `非空 && 含 "." && 无空白`。

### 编辑模式（acwrite buffer）

`edit.lua` `M.open(opts)`：`opts = { root, task, target, content, detail_buf, detail_win, list_buf,
on_save(text, cb), on_close(reason) }`。

- 新建 scratch buffer：`buftype=acwrite`、`bufhidden=wipe`、`swapfile=false`、`filetype=markdown`；
  内容为被编辑目标**当前内容**（新建阶段时为空）。
- buffer 名：`loopkit://<root>/edit/<id>/<target>[/<stage>]`（id 中 `#` 编码为 `%23`）；
  同一目标任务重复进入时聚焦已有 buffer。
- `nvim_win_set_buf(detail_win, buf)` 并聚焦；进入时清空撤销历史之外不做额外加工。
- `BufWriteCmd` → `on_save(当前全文, cb)`；保存中置 `saving`，重复 `:w` 直接忽略。
  成功：`modified=false` → 关闭编辑态；失败：保持 buffer 与脏文本，通知错误。
- normal 模式 `<Esc>`：未脏直接放弃；**已修改则弹二次确认**（`ask`，选项「放弃修改 / 继续编辑」）。
  放弃不调用 CLI。
- 关闭时恢复：`nvim_win_set_buf(detail_win, detail_buf)`、删除编辑 buffer、清空 Board 编辑态、
  恢复列表正常渲染；保存成功由 Board 触发 `refresh({ no_sync = true })`。

### 编辑模式下的列表窗口

编辑期间列表不渲染任务列表，改为一个静态信息视图（复用 `List:draw` 的 hint 注入之外的独立路径，
新增 `List:show_edit(info)` / `List:clear_edit()`，内部仍走同一 scratch buffer 与临时 `modifiable`
翻转）：

```
编辑中 · #11 看板按光标位置的字段级编辑模式
目标：任务描述
:w 保存并应用 · <Esc> 放弃（normal 模式）
```

内容固定三行 + 首尾空行；`info = { id, title, target_label }`。期间列表的导航/动作键位不响应
（见下）。

### Board 编辑态

`self.editing = { buf, target, task_id, is_new }`（`nil` 表示非编辑态）。

- `Board:handle(action)` 在 `self.editing` 非空时，除 `help`/`quit` 外一律 no-op + 通知
  「正在编辑，请先 :w 或 <Esc>」；`quit` 在脏时先走放弃确认。
- `Board:draw()` 与 `_draw_detail()`：编辑态下跳过 `_draw_detail` 的 buffer 还原与 detail 渲染，
  列表走 `show_edit`。后台 `refresh`/`sync` 完成时更新 `state` 但**不**重绘编辑窗口；保存成功后
  以最新 `state` 重绘。
- `on_select` 在编辑态不切换任务；编辑目标在会话开始时快照 `task_id`，后续选中变化不影响。
- 保存/删除成功后选中该任务，详情重渲染，光标移到对应小节的标题行（`title`/`desc`/
  `userPrompt`/`stagePrompt.<新名>`）。

### 动作层（actions.lua）

新增方法，全部复用 `state:enqueue` 与 `_refresh`/`_failure`：

- `edit_title(id, title, cb)` → `edit <id> --title <title>`
- `edit_desc(id, text, cb)` → `edit <id> --desc-file -`（stdin=text）
- `edit_user_prompt(id, text, cb)` → `edit <id> --user-prompt-file -`
- `set_stage_prompt(id, stage, text, cb)` → `edit <id> --stage-prompt-file <stage>=-`
- `delete_stage_prompt(id, stage, cb)` → `edit <id> --stage-prompt <stage>=`
- `rename_stage_prompt(id, old, new, content, cb)` → 一次调用携带
  `--stage-prompt-file <new>=-` 与 `--stage-prompt <old>=`
- `add_task(title, tag, cb)` → `add --title <title> --tag <tag> --json`；`--tag` 为 CLI 必填，
  新建流程须同时收集 tag（见下）。

所有大段文本一律走 stdin，避免命令行转义与长度问题。

### 新建任务

`a` 改为两步简单输入：先 `input({ prompt = "新任务标题" })`（取消即中止，空串提示），
再 `input({ prompt = "分类 tag", default = "feature" })`（取消即中止，空串提示，取值须属于
`.pi/loop-kit/TARGETS.md` 的 tag 集合）。两步都完成后 `add_task`，随后选中新任务。
`form.lua` 及其 require 全部移除；`init.lua` 的 `M.add`/`M.edit` 注释同步更新，
`M.edit(id)` 保持「选中并按当前光标位置发起编辑」的语义。

## 改动范围

- `lua/loop-kit/ui/board.lua`
- `lua/loop-kit/ui/list.lua`
- `lua/loop-kit/ui/detail.lua`
- `lua/loop-kit/ui/help.lua`
- `lua/loop-kit/edit.lua`
- `lua/loop-kit/actions.lua`
- `lua/loop-kit/init.lua`
- `lua/loop-kit/form.lua`
- `doc/loop-kit.txt`
- `tests/unit/*.lua`
- `tests/fake-dom/*.lua`
- `tests/render/*.lua`

## 验收标准

- [单测] `tests/unit/edit_spec.lua`：`target_at(rendered, line)` 对标题行、desc 标题与正文、
  userPrompt 标题与正文、`# 各阶段提示词` 标题、阶段 `##` 行、阶段正文分别返回上表目标；
  元数据行与 decide/analysis 行返回 `readonly` 且不进入编辑；空 desc/userPrompt 的「暂无内容」行
  归入对应目标；空阶段集合的占位行归入 `stage_new`。
- [单测] `tests/unit/edit_spec.lua`：阶段名校验接受 8 个内建名与 `a.b`，拒绝 `""`、`"spec "`、
  `"阶段"`、`"a b.c"`。
- [单测] `tests/unit/edit_spec.lua`：`stage_rename` 参数组装为一次调用，含 `--stage-prompt-file <new>=-`
  与 `--stage-prompt <old>=`；`delete_stage_prompt` 组装为 `--stage-prompt <stage>=`。
- [假 DOM] `tests/fake-dom/edit_spec.lua`：desc/userPrompt/stage 保存分别产生
  `edit <id> --desc-file -`、`--user-prompt-file -`、`--stage-prompt-file <stage>=-`，stdin 为 buffer
  全文；失败时不关闭 buffer 且保持 `modified=true`，错误经 `notify` 暴露。
- [假 DOM] `tests/fake-dom/edit_spec.lua`：`<Esc>` 未脏直接关闭且无 CLI 调用；脏时调用注入的 `ask`，
  选「继续编辑」不关闭。
- [假 DOM] `tests/fake-dom/edit_spec.lua`：简单输入取消（nil）不产生任何 CLI 调用；空标题提示
  「任务标题不允许为空」；空阶段名提示「阶段名不能为空」；新建同名阶段触发二次确认。
- [假 DOM] `tests/fake-dom/board_spec.lua`：编辑态下 `Board:draw()` 不把 detail_buf 换回详情窗口，
  列表显示编辑信息条；编辑态下 `c/d/x` 等动作 no-op。
- [假 DOM] `tests/fake-dom/form_spec.lua`：移除（随 form.lua 删除）；`a` 新建依次收集标题与 tag，
  调用 `add --title <标题> --tag <分类>`；任一步取消都不产生 CLI 调用。
- [渲染比对] `tests/render/edit_spec.lua`：编辑 buffer 初始内容与目标任务字段逐行一致，
  `buftype=acwrite`、`filetype=markdown`；保存成功后 detail_win 恢复原 detail_buf。
- [渲染比对] `tests/render/list_spec.lua`：`List:show_edit` 输出三行信息（任务 id+标题、目标、
  键位提示），`clear_edit` 后恢复原任务列表渲染。
- 回归：`nvim --headless -u tests/minimal_init.lua -l tests/run.lua` 全绿；`git diff --check` 通过；
  `loop-cli validate` 通过。

## 待确认决策

无（已确认：整表单移除、阶段名自由输入+校验、脏时 `<Esc>` 二次确认）。
元数据区与 decide/analysis 在 #11 中只提示不可编辑；字段级编辑拆分到依赖本条的 `#12`。
`a` 新建原为「只输入标题」，因 `loop-cli add --tag` 为必填，补充为「标题 + tag 两步输入」，
tag 默认 `feature`。

## 关联文档

- `.pi/loop-kit/docs/nvim/2026-11-22T13-08-46-ui-display-style.md`：detail 渲染的行布局与 `fields`
  行号约定，本条目标定位直接依赖。
- `.pi/loop-kit/docs/nvim/2026-11-21T23-49-46-neovim-companion-implementation-plan.md`：看板总体结构、
  `form.lua` 的原始设计（本次被替换）。
