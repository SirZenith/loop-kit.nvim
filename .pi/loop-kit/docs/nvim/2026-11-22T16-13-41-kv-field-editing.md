---
task_id: "#12"
summary: 键值字段分级编辑：tag/flow 单选、deps 多选、路径输入、touch 多行编辑，只读字段给出提示。
module: nvim
tag: feature
status: archived
updated: 2026-11-22
verification_levels: [unit, fake-dom]
doc_ref: .pi/loop-kit/docs/nvim/2026-11-22T15-18-00-per-field-edit-mode.md
---

# 键值字段编辑：单选、多选与多行 touch

## 目标

在 #11 提供的字段级编辑模式之上，把详情窗口中的键值对字段变成可编辑入口：

- 用户把光标放在某个元数据行按 `e` 时，打开与该字段语义匹配的编辑器，而不是编辑任务描述；
- 可选值字段只能从候选里选，路径字段允许自由输入，`touch` 以每行一个路径的多行文本编辑；
- 写入仍然只经 `loop-cli`，并复用现有串行写队列，保证与 claim/done/block 等动作不会并发写文件。

`TARGETS.md` 目前只有「任务分类（tag）」小节是实际内容，其余小节仍是模板占位符；本条目只引用其中
的 tag 集合，不新增产品目标。

## 现状

- #11（`#11`，pending）已规划并将在本条目之前落地：
  - 新增 `lua/loop-kit/edit.lua`：单目标 acwrite buffer、`M.target_at(rendered, cursor_line)` 纯函数、
    `title` / `stage_new` / `stage_rename`（简单输入）与 `desc` / `user_prompt` / `stage_content`
    （buffer）目标；
  - `lua/loop-kit/ui/board.lua` 增加编辑态（`self.editing`）与 `e` 的目标分派；
  - 元数据行与 decide/analysis 区域在 #11 中统一返回 `readonly`，只提示“该行暂不支持编辑”。
- `lua/loop-kit/render.lua:330-429` 的 `M.detail` 已把每个字段的行号写入 `out.fields`：
  `tag`、`origin`、`openAt`、`closedAt`、`hash`、`deps`、`doc`、`docParent`、`specPrompt`、
  `researchPrompt`、`codePrompt`、`verifyPrompt`、`docTaskSplitPrompt`、`flow`、`private`、`touch`、
  `meta`；`touch` 非空时 `fields.touch` 指向 `- touch:` 行，其后的 `  - <path>` 子行不入表。
- `lua/loop-kit/advanced.lua` 已实现 flow/private/touch/meta 的写入：`M.FLOWS` 是硬编码的 6 个内置档位
  （`advanced.lua:13-21`），`M.STAGE_ORDER` 为 8 个内建阶段（`advanced.lua:23-32`），
  `M.split_stages`（`advanced.lua:56`）与 `M.validate_stages`（`advanced.lua:69`）已覆盖“逗号分隔、
  末项必须是 commit、内建阶段严格递增”的规则；`M.new` 接受注入的 `select` / `input` / `ask` / `notify`，
  所有写入经 `_submit` → `state:enqueue` → `_refresh`。
- `lua/loop-kit/ui/board.lua:638-657` 的 `Board:_ensure_advanced()` 只注入了
  `select` / `ask` / `input` / `notify`，没有多选入口，也没有 `loopRoot` 或 `config`。
- `lua/loop-kit/cli.lua` 的 `Client:build` 统一在子命令前加全局 `--json`；`flow --list --json` 无需任务 id。
- `loop-cli` 的写入能力边界（已核对 0.1.0）：
  - `edit --tag/--deps/--doc/--doc-parent/--spec-prompt/--research-prompt/--code-prompt/--verify-prompt/
    --doc-task-split-prompt`；
  - `deps <id> --set 'a,b'`（`--set ''` 清空）、`doc <id> --path|--clear`、
    `flow <id> --flow <名|stage,stage>|--clear`、`touch <id> --set <路径...>|--clear`；
  - `origin`、`openAt`、`closedAt`、`hash` 没有任何 edit 入口：远端 origin 由 `origin:*` 标签派生，
    时间由 issue 的 created_at/closed_at 派生，hash 只由 `done --hash` 设置。
- `crates/loop-core/src/validate.rs:539-562` 只在整份文件加载/写回时校验自依赖与环；
  `crates/loop-core/src/provider/remote.rs:1600-1611` 的 `set_deps` 只 patch meta，**不校验环**。
  因此循环依赖必须在 UI 侧提前排除，不能依赖 CLI 兜底。

## 方案

### 模块划分

- `lua/loop-kit/kv.lua`（新增）：纯函数与无副作用读取。
  - `M.parse_tags(content)`：从 `# 任务分类（tag）` 小节收集形如 `- \`tag\`` 的列表项；
    `edit.lua` 的 `tag_list`（带 mtime 缓存）在缓存失效时直接调用 `kv.tag_values`，
    解析与回退只有一份实现；
  - `M.tag_values(loop_root)`：读取 `<loop_root>/TARGETS.md`，失败或空结果回退
    `feature/bugfix/refactor/ux/visual/docs/chore`；
  - `M.would_cycle(tasks, id, candidate)`：沿 `candidate` 的 deps 做 DFS，判断是否能回到 `id`；
  - `M.dependency_candidates(tasks, id)`：返回可选择项与隐藏计数；
  - `M.touch_paths(lines)`：多行文本 → 去空白、丢空行、保序去重；
  - `M.deps_arg(list)`：逗号连接；空列表返回 `""`。
- `lua/loop-kit/ui/picker.lua`（新增）：单选与多选 UI。
  - `M.select_one(opts)`：包装 `vim.ui.select`，用 `format_item` 给当前值加 `(当前)` 标记；
    当前值不在候选时置顶追加，选中它等同“不修改”；
  - `M.multi(opts)`：浮窗多选；状态模型（`new_model` / `move` / `toggle` / `result`）与绘制分离，
    便于单测；键位 `<Space>` 切换、`j`/`k` 与 `<C-n>`/`<C-p>` 移动、`<CR>` 确认、`<Esc>`/`q` 取消；
    底部显示 `已隐藏 N 项（自身或循环依赖）`。
- `lua/loop-kit/edit.lua`（#11 新增，本条目扩展）：
  - `target_at` 按字段返回各自的 kind（`tag`/`deps`/`doc`/`docParent`/各 prompt/`flow`）
    与更细的 `readonly` 目标；
  - 增加 `touch` 多行 buffer 目标，内容为每行一个路径。
- `lua/loop-kit/advanced.lua`（扩展）：新增 `set_tag` / `set_deps` / `set_doc` / `set_prompt` /
  `list_flows` / `set_touch`，并把 `flow` 改为动态候选；保留现有 `FLOWS` 作为离线回退。
- `lua/loop-kit/ui/board.lua`（扩展）：`e` 按目标分派到单选、多选、简单输入、touch buffer 或只读提示；
  给 `Advanced` 注入 `multi`、`loop_root` 与带预填的 `input`。
- `lua/loop-kit/ui/help.lua`、`doc/loop-kit.txt`：说明元数据行 `e` 的字段级行为与只读字段。

不新增依赖，不修改 `render.lua` 的字段顺序或高亮。

### 字段 → 编辑器映射

| `fields` 键 | 目标 | 编辑器 | 写入命令 |
| --- | --- | --- | --- |
| `tag` | `tag` | 单选 | `edit <id> --tag <v>` |
| `deps` | `deps` | 多选 | `deps <id> --set 'a,b'` / `--set ''` |
| `doc` | `doc` | 简单输入 | `doc <id> --path <v>` / `--clear` |
| `docParent` | `docParent` | 简单输入 | `edit <id> --doc-parent <v>` |
| `specPrompt` | `specPrompt` | 简单输入 | `edit <id> --spec-prompt <v>` |
| `researchPrompt` | `researchPrompt` | 简单输入 | `edit <id> --research-prompt <v>` |
| `codePrompt` | `codePrompt` | 简单输入 | `edit <id> --code-prompt <v>` |
| `verifyPrompt` | `verifyPrompt` | 简单输入 | `edit <id> --verify-prompt <v>` |
| `docTaskSplitPrompt` | `docTaskSplitPrompt` | 简单输入 | `edit <id> --doc-task-split-prompt <v>` |
| `flow` | `flow` | 单选 + 自定义 | `flow <id> --flow <名\|stage,stage>` / `--clear` |
| `touch` | `touch`（多行 buffer） | 多行文本 | `touch <id> --set <p...>` / `--clear` |
| `origin` | `readonly` | — | 提示“由 origin:* 标签维护” |
| `openAt` / `closedAt` | `readonly` | — | 提示“由 issue 时间戳或生命周期维护” |
| `hash` | `readonly` | — | 提示“由 done --hash 在完成时设置” |
| `status` | `readonly` | — | 提示“用 c / d / b 修改” |
| `id` / `private` / `meta` / decide / analysis | `readonly` | — | 提示“该行暂不支持编辑” |

### 单选

- `tag`：候选来自 `kv.tag_values(config.loop_root_hint)`；当前 tag 不在候选时置顶追加。
  选中当前值视为无修改，不发写命令。
- `flow`：先调用 `Advanced:list_flows()`，渲染为内置名 + 自定义 flow 名（可附带 stage 序列标签），
  再加 `M.CUSTOM_FLOW`（“自定义 stage 列表…”）与 `M.CLEAR_FLOW`（“清除（回到默认）”）。
  - `--list` 失败（离线/旧版 CLI）时回退到 `M.FLOWS` 并 `notify` 一次；
  - 选内置名或自定义 flow 名 → `flow <id> --flow <name>`；
  - 选“自定义” → `input` 输入逗号分隔列表，`M.split_stages` + `M.validate_stages` 就地校验，
    通过后传规范化后的逗号串（`table.concat(validated, ",")`，去掉空白；原始输入仅用于错误消息）
    给 `--flow`（CLI 会归一成档位名或 stage 数组，与 UI 行为一致）；
  - 选“清除” → `flow <id> --clear`；
  - 当前值不在候选（例如已是自定义 stage 数组）时置顶追加只读项，选中即无修改。

### 多选（deps）

- 候选来源：`state.tasks` 中除自身以外的任务，按 id 升序；每行显示 `#id 状态 标题`。
- 先排除不可选任务，再计算隐藏计数：
  - 自身永远隐藏（自依赖）；
  - 若 `kv.would_cycle(tasks, id, candidate)` 为真则隐藏（直接或传递依赖回自身）。
- 当前 deps 中不在 `state.tasks` 里的 id 必须保留为已选中的“幽灵项”，不能因为不在候选而丢弃；
  标签写作 `#id（不在当前列表）`。
- 浮窗返回完整选中集合；空集合 → `deps <id> --set ''`，非空 → 逗号连接后的单个 argv。
- 与当前集合相同则视为无修改。

### 路径输入

- `doc` 与 6 个提示词路径字段都用 `input`，提示文案包含字段名，默认值预填当前路径（空则空）。
- 直接调用 `vim.ui.input`；取消（`nil`）不发命令。
- 输入值原样交给 CLI：`doc` 由 `canonical_doc_path` 归一为项目内相对路径或项目外绝对路径；
  其余字段同样归一。UI 不做存在性校验。
- 空串 → `doc --clear`；提示词字段传空串（远端写 Null、本地写 `""`，渲染均显示未设置）。

### touch 多行 buffer

- 复用 #11 的 acwrite 编辑 buffer，buffer 名增加 `/touch` 后缀；内容为当前路径逐行拼接。
- `:w` 时 `kv.touch_paths` 处理：逐行 trim、丢弃空行、保序去重。
- 每条路径先用 `advanced.valid_touch_path` 预检；非法路径就地报错并保持 buffer 脏（不关闭、不发命令）。
- 空列表 → `touch <id> --clear`；否则 `touch <id> --set <p1> <p2> ...`（每个路径一个 argv）。
- `<Esc>` 的脏确认、保存失败保留文本等行为完全沿用 #11 的 buffer 生命周期。

### 只读字段

- `target_at` 对只读行返回 `{ kind = "readonly", message = ... }`。
- Board 只 `notify` 对应提示，不进入编辑态、不改 buffer。
- `origin` / `openAt` / `closedAt` / `hash` 的提示要说明真实来源（标签、issue 时间戳、`done --hash`），
  避免用户误以为功能缺失。

### 保存与刷新

- 所有写入统一走 `Advanced:_submit`：`state:enqueue` 串行、成功 merge task、`reload` 刷新列表；
  `sync_after_write` 对远端仍由现有 `_maybe_sync` 处理。
- 保存成功后重新渲染详情并把光标放回触发字段所在行（通过 `fields[field]`）；
  `touch` 放回 `fields.touch`。
- 失败时沿用 `_failure` 的结构；`readonly` 与“无修改”都返回 `ok = true` 或 `cancelled`，不触发错误染色。

### 错误处理

- 单选/多选/输入取消 → 静默返回，不写文件。
- `flow` 自定义列表非法 → 停在输入阶段并显示 `M.validate_stages` 的错误文案，允许重试。
- `touch` 路径非法 → 停在 buffer 内，保留用户文本。
- `--list` 拉取失败只回退候选，不阻塞编辑。
- CLI 返回 exit 4/5 → 沿用 `_failure` 与 Board 的现有通知路径。

## 改动范围

```
lua/loop-kit/kv.lua
lua/loop-kit/ui/picker.lua
lua/loop-kit/edit.lua
lua/loop-kit/advanced.lua
lua/loop-kit/ui/board.lua
lua/loop-kit/ui/help.lua
doc/loop-kit.txt
tests/unit/kv_spec.lua
tests/unit/picker_spec.lua
tests/unit/advanced_spec.lua
tests/unit/edit_spec.lua
tests/fake-dom/kv_spec.lua
tests/fake-dom/board_spec.lua
```

## 验收标准

> 注：`edit.target_at` 返回逐字段 kind（而非统一的 `kv`）；自定义 flow 传给 CLI 的是
> `validate_stages` 规范化后的逗号串。

- [单测] `tests/unit/kv_spec.lua`：`parse_tags` 只收集 `# 任务分类（tag）` 到下一个一级标题之间的反引号
  列表项；缺文件、空集合、小节缺失都回退内置 7 项；当前 tag 不在候选时 `select_one` 的候选末尾包含它。
- [单测] `tests/unit/kv_spec.lua`：`would_cycle` 对自身、直接依赖、A→B→C 传递依赖返回真，对无关任务与
  已存在的合法依赖返回假；`dependency_candidates` 的隐藏计数与返回项一致，且当前 deps 中的幽灵 id
  仍出现在选中集合里。
- [单测] `tests/unit/kv_spec.lua`：`deps_arg({"#1","#2"}) == "#1,#2"`，空列表为 `""`；
  `touch_paths` 去空行、trim、保序去重，且保留含空格的路径。
- [单测] `tests/unit/picker_spec.lua`：多选模型 `toggle` 只翻转当前行、`move` 在首尾环绕、
  `result` 按候选顺序返回选中值；隐藏计数不参与选中结果。
- [单测] `tests/unit/advanced_spec.lua`：`list_flows` 解析 `{builtin, custom}` 并可由 `flow_items`
  拼出“内置 + 自定义 + 自定义 stage + 清除”的候选；`--list` 失败时 Board 回退 `M.FLOWS` 并提示；
  `flow` 选择自定义输入 `"research, impl, commit"` 时传给 CLI 的是规范化后的逗号串，非法列表不产生写调用。
- [单测] `tests/unit/advanced_spec.lua`：`set_tag` 生成 `edit <id> --tag <v>`；
  `set_deps` 生成 `deps <id> --set 'a,b'`，空集合为 `--set ""`；`set_doc` 空串走 `--clear`、
  非空走 `--path`；`set_prompt` 空串仍带 flag 与空值；`set_touch` 空列表走 `--clear`，
  非空时每个路径一个 argv。Board 在 tag/flow 选中当前值、deps 集合未变化时不发写命令。
- [单测] `tests/unit/edit_spec.lua`：`target_at` 把上表 11 个可编辑字段映射为各自的字段 kind
  （`touch` 为多行 buffer），把 `origin/openAt/closedAt/hash/status/id/private/meta` 与
  decide/analysis 映射为 `readonly` 并带非空 message；`- touch:` 行与其子行都归入 `touch` buffer。
- [假 DOM] `tests/fake-dom/kv_spec.lua`：在 tag 行按 `e` 调用注入的 `select`，候选中包含当前值并带
  当前标记；在 deps 行按 `e` 调用注入的 `multi`，参数里隐藏计数等于被排除任务数、已选集合等于当前 deps；
  在 `origin` 行按 `e` 只 `notify`，不启动写队列；`flow` 行的候选含内置、自定义 flow、
  “自定义 stage”与“清除”，`--list` 失败时回退内置并提示，选择当前 flow 或输入非法自定义
  stage 列表时不写。
- [假 DOM] `tests/fake-dom/kv_spec.lua`：`doc` 输入取消不发命令；输入新路径产生
  `doc <id> --path <v>` 并刷新；`touch` buffer 写入两行路径后保存产生
  `touch <id> --set <p1> <p2>`；写入绝对路径时保留 buffer 脏并显示错误，且写队列为空。
- [假 DOM] `tests/fake-dom/board_spec.lua`：touch 编辑期间除 help/quit 外的动作键 no-op 并提示
  “正在编辑”；保存成功后回到详情 buffer，光标落在 `fields.touch` 行。
- [单测] 回归：`nvim --headless -u tests/minimal_init.lua -l tests/run.lua` 与 `git diff --check` 全绿。

## 待确认决策

无（规划阶段已确认：origin/openAt/closedAt/hash 只读并提示；deps 隐藏自身与环候选并显示隐藏数；
tag 解析 TARGETS.md 且回退内置集合；本条目从 #11 拆出并依赖 #11）。

## 关联文档

- `.pi/loop-kit/docs/nvim/2026-11-22T15-18-00-per-field-edit-mode.md`：#11 的编辑模式骨架、`target_at`
  与 acwrite buffer 是本条目的直接前置，接口以该文档为准。
