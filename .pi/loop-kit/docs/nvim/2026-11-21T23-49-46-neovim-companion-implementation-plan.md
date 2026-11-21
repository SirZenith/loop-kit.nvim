---
task_id: "#1"
summary: "loop-kit.nvim 的完整实现计划：零依赖 tab 双栏看板、CLI 驱动的本地与远端任务读写、表单编辑、进阶字段与可拆分验收边界。"
module: nvim
tag: docs
status: archived
updated: 2026-11-21T23:49:46+08:00
verification_levels:
  - unit
  - fake-dom
  - render
deferred_levels:
  - manual
---

# loop-kit.nvim 实现计划

## 目标

在用户打开的项目中发现并读取根目录 `loop.config.json`，借助环境中的 `loop-cli` 解析
`loopRoot`、读取 LOOP 任务并执行受支持的修改，以 Neovim 原生的 tab 双栏界面提供任务
浏览、详情查看、编辑和流程辅助能力。

`.pi/loop-kit/TARGETS.md` 当前仍是待填写模板；本文件依据用户已确认的产品决策形成首期
基线，不虚构额外目标：

- 插件名与模块名分别为 `loop-kit.nvim` 与 `loop-kit`。
- 默认布局为独立 tab 中的左侧任务列表、右侧任务详情；浮动布局不是 v1 范围。
- 核心零运行时依赖，只使用 Neovim API；nui.nvim、telescope.nvim、
  render-markdown.nvim 等只能在后续作为可选增强，缺失时不影响核心功能。
- local、gitea、github、jira 与 lua 源均通过同一 CLI 适配层访问；允许尝试远端字段编辑，
  以 CLI 返回结果为准，不在插件中复制 provider 协议。
- v1 包含列表/详情、claim/done/block、字段编辑、新增任务、删除或移出循环、
  flow/private/touch/meta 以及 decide 推荐与阻塞解释。
- 所有 LOOP 数据写入只经过 `loop-cli`。不得由插件直接写 `LOOP.json`、
  `LOOP.remote.json` 或 `loop.meta.json`。
- 优先实现完整且可验收的 tab 双栏 v1；浮动布局、Telescope 扩展、lualine 组件属于后续
  增强，不进入本次拆分。

成功标准：用户可以在不离开 Neovim、不记忆 CLI 参数的情况下安全地完成日常 LOOP 任务
管理；长描述仍用普通 Markdown buffer 编辑；同步与远端错误不阻塞已有快照的浏览；失败
不会清空用户输入或静默覆盖远端更新。

## 现状与已确认契约

### 上游能力

- 当前环境为 Neovim 0.12.4；插件以 Neovim 0.10+ 为最低版本，使用 `vim.system`、
  `vim.fs`、`vim.json` 与 `vim.ui`。更低版本不在 v1 适配范围内。
- `loop-cli --version` 已可用，当前实测版本为 `0.1.0`。
- `loop-cli remove <id> [--json]` 已实现。local 源会删除条目并清理其他任务对它的依赖
  引用；远端源会摘除 `loop:todo` 准入标签、保留 issue，且操作幂等。插件不重复实现这些
  语义。
- 配置入口固定为项目根 `loop.config.json`。`loopRoot` 相对配置文件目录解析；
  `filePath` 相对 `loopRoot`；任务 `doc` 路径相对项目根。
- `loop-cli --project-root <root> --json paths` 返回权威的 `config` 与 `loopRoot` 绝对
  路径。插件自己读取配置仅用于发现 provider、CLI 路径与诊断，不另写一套路径解释器。
- CLI 路径优先级固定为：`setup.cli_path` → `$LOOP_BIN` → 配置 `cliPath` → PATH 中的
  `loop-cli`。配置中的相对 `cliPath` 相对配置文件目录解析。
- `list --json` 返回 `{ source, tasks, analysis }`；`show --json <id>` 返回 Task；
  `decide --json` 返回 `{ action, id, reason, ids }`。
- Task 至少包含 `id/title/status/tag/origin/openAt/closedAt/hash/doc/deps/desc`，并可能
  包含 `flow/isPrivateDesc/docParent/userPrompt/stagePrompt/touch/updatedAt` 等可选字段。
  未知字段必须保留在快照中，不得因 UI 暂不展示而丢弃或写回覆盖。
- 状态为 `pending/doing/done/blocked`；id 形如 `#12`。所有进程调用使用 argv 数组，绝不
  拼接 shell 字符串，因此 `#`、空格、引号和非 ASCII 文本不会经过 shell 再解释。
- `list --no-sync` 只读上次远端缓存；无缓存时可能报找不到 `LOOP.remote.json`。插件应把
  它视为“需要同步”的可恢复状态，而不是不可恢复的解析错误。
- `add`/`edit` 的 `--desc-file -` 已实测支持从 stdin 读取多行描述；`edit` 支持字段级
  title/desc/tag/deps/doc/status 等修改。本插件的表单不直接修改 status，统一走任务动作，
  避免绕过依赖门禁以及 closedAt/hash 语义。
- `flow`、`private`、`doc`、`meta`、`touch`、`deps` 均有独立 CLI 子命令。`touch` 的空数组
  非法；缺失/null/读取失败均表示 unknown，不能解释为“不写文件”。
- 写操作可能受依赖门禁、blocked 状态和远端乐观并发限制。退出码按 `0` 成功、`1` 用法、
  `2` 源、`3` 数据、`4` 业务拒绝或冲突、`5` 远端失败处理；业务失败不自动重试。

### 仓库现状

- 本仓库当前只有 LOOP 骨架，尚无插件代码；本文件是所有子任务的共同设计与验收依据。
- 上游 `remove` 不需要在本仓库再次实现。若用户环境中的旧 CLI 缺少该命令，Health 与动作
  错误应提示升级，而不是回退为直接修改 JSON。
- 没有现成 UI、测试或文档约束需要兼容。测试也保持零第三方运行时依赖，用 headless
  Neovim、纯 Lua 小型 runner 和 fake CLI 完成。

## 总体方案

### 架构与状态边界

采用“CLI 适配层 → 每项目快照 → 纯渲染/动作层 → buffer/window UI”的单向结构：

```text
:LoopKit / Lua API
  → config 发现项目根、读取配置、定位 CLI
  → cli 以 argv + vim.system 异步执行并解析 JSON/退出码
  → source 生成 paths/list/show/decide 请求，维护 generation
  → state 保存每个项目根的快照、筛选、排序、选中 id、busy 状态
  → render 把快照变成列表/详情行与高亮描述
  → ui 创建 tab、左右窗口和 buffer，绑定键位与生命周期
  → actions/form/advanced 把用户操作翻译回 cli
```

关键边界：

- `cli.lua` 不知道 UI；所有回调回到主循环时用 `vim.schedule`。
- `source.lua` 不操作 buffer；每次请求携带递增 generation，旧响应即使后到也不能覆盖新
  快照。
- `state.lua` 以规范化项目根为 key 保存独立状态；同一项目重复打开只聚焦既有看板，不创建
  第二套同步/写入队列。
- `render.lua` 尽量保持纯函数；列表行必须稳定保存“行号 → task id”映射，不能靠解析显示
  文本找回任务。
- `actions.lua` 串行执行同一项目的写操作，返回结构化成功/错误；不基于旧快照合并整份
  JSON。
- `form.lua` 负责表单解析、序列化、字段 diff 与 acwrite 生命周期；只有实际变化的字段进入
  CLI 参数。
- UI 只做事件绑定和状态展示。所有异步回调在执行前检查项目状态与窗口 generation，已关闭
  的看板不得被旧回调重绘。

### 项目发现与启动

项目根解析顺序：命令显式路径 → `setup.project_root` → 当前文件路径向上寻找
`loop.config.json` → cwd 向上寻找 → `$LOOP_PROJECT_ROOT` → cwd。路径经
`vim.fs.normalize` 与可用的 realpath 规范化；不存在或缺少配置时给出包含期望路径的错误。

启动流程：

1. 校验 CLI 可执行、`loop.config.json` 可读，并用 `paths --json` 获取权威路径。
2. 先执行 `list --json --no-sync`；成功后立即渲染。
3. `auto_sync = true` 时对远端源后台执行一次完整 `list --json`；local 源只读本地状态。
4. 无远端缓存时先渲染明确的“尚无缓存，正在同步/请执行 :LoopKit sync”状态，不显示伪造的
   空任务列表。
5. 同步完成后以新快照重绘；同步失败保留旧快照，并在 winbar 与 notify 中显示简洁原因。
6. 列表加载失败不阻止 `:LoopKit paths` 与 `:checkhealth loop-kit` 诊断。

插件不建立自己的持久任务缓存，避免形成第二个权威源；快照只存在内存中。

### 看板布局与导航

`:LoopKit` 默认新建一个普通 tab，并创建左右两个窗口：

- 左窗默认宽 38 列，列表为只读 `nofile` scratch buffer，启用 `cursorline` 与
  `winfixwidth`；窗口尺寸变化时保持可用，不抢占用户其它 tab。
- 右窗为只读 Markdown 详情 buffer，`filetype=markdown`，`swapfile=false`；只读状态通过
  `modifiable=false` 保证，展示时临时切换并在 `pcall` 后恢复。
- winbar 显示项目名、provider、open 数量、筛选条件与 syncing/writing/error 状态。
- 顶部帮助行只保留最关键键位；`?` 打开零依赖浮窗展示完整帮助。
- `q` 关闭当前看板 tab；已有关闭中的 tab、手动 `:tabclose`、`:q` 与 WinClosed 都走同一
  清理逻辑，释放 autocmd、状态引用与异步 generation。
- 详情中的 `doc` 可用 `o` 以 `:edit` 打开项目根相对路径；路径缺失时提示，不写死
  `.pi/loop-kit`。
- 表单在当前详情窗打开，保存或取消后恢复详情 buffer；新增表单使用独立临时名称。

列表默认筛选 `open`（pending/doing/blocked），支持 `open/all/pending/doing/blocked/done`。
默认按 doing、pending、blocked、done 分组，组内按数字 id 升序；组标题不计入任务映射。
关键字匹配 id/title/tag/desc，大小写不敏感。刷新与筛选后按 id 恢复选中；若被过滤则选择
最近的可见任务。

默认键位：

| 键位 | 行为 |
| --- | --- |
| `j/k`、`<CR>` | 原生移动；聚焦/打开当前任务详情 |
| `/`、`<Esc>` | 输入关键字筛选；清空关键字 |
| `s`、`S` | 循环状态筛选；直接显示全部 |
| `r`、`R` | 重新读取缓存/本地；完整同步 |
| `c`、`d`、`D`、`b` | claim；done；确认后强制 done；输入原因并 block |
| `e`、`a` | 编辑当前任务；新增任务 |
| `x` | 删除 local 任务或把远端任务移出循环，始终先确认 |
| `o` | 打开任务实现文档 |
| `F`、`P`、`T`、`M` | flow；private；touch；worktree meta |
| `n` | 获取 decide 推荐，有 next id 时跳转，否则显示原因 |
| `?`、`q` | 帮助；关闭 |

所有键位都可由 `setup({ keys = ... })` 覆盖或设为 `false` 禁用；不把全局键位写入用户
配置。

### 任务动作与写入队列

- claim/done/block/edit/add/remove/advanced 全部带 `--json` 和显式 `--project-root`。
- 同一项目同一时刻只有一个写进程。后续写请求进入 FIFO；切换筛选和只读刷新可以继续，
  但写完成前不以旧列表覆盖成功响应。
- 成功后使用返回的 Task 更新内存项，再重新读取列表以更新 analysis；远端后台完整同步。
  删除成功后选中相邻可见任务；新增成功后选中新 id。
- `done` 被依赖门禁拒绝时展示未完成依赖，不自动 force。`D` 是独立键位，确认文案明确
  “强制完成”。
- `block` 通过 `vim.ui.input` 获取非空 reason；空输入视为取消。
- `remove` 根据 source kind 显示不同确认：local 为“永久删除并清理依赖引用”，远端为
  “移出循环但保留远端 issue”。确认后才调用 `remove --json`。
- 远端冲突（exit 4 且信息指向 updatedAt/并发，或 CLI 明确返回冲突）不自动重试、不合并。
  保留 dirty 表单，提示用户同步后人工核对。
- 写失败保留当前选中、筛选和表单内容；stderr 经过去 token/控制字符清理后展示。

### 编辑与新增表单

采用 `buftype=acwrite` 的普通 buffer，`:w` 由 `BufWriteCmd` 接管。buffer 名分别形如
`loopkit://<root>/task/%2312` 与 `loopkit://<root>/new/<nonce>`。

格式：

```markdown
<!-- loopkit:task id=#12 -->
# 任务标题

<!-- loopkit:meta
tag: feature
deps: #3, #5
doc: loop/docs/example.md
-->

这里是描述 Markdown。

可以有多段、列表与代码块。
```

解析规则：

- 首个任务注释保存 id；新增表单使用 `<!-- loopkit:task new -->`。
- 第一个一级标题为 title，必填且单行；其余标题留在 desc 中，不被误认为表单字段。
- 唯一 `loopkit:meta` 注释块接受 `tag/deps/doc`；未知键、重复键、非法 id 与非法路径在调用
  CLI 前报错并给出行号。
- meta 块之后全部文本为 desc，保留内部换行和 Markdown 结构；不以字符串转义方式拼 CLI。
- deps 以逗号分隔并规范化成 `#n`；空值通过 `deps --set ''` 清除。doc 空值通过
  `doc --clear` 清除；新增时空 deps/doc 不发送。
- 以加载时的 Task 为 baseline 做 diff，只提交变化字段。title/tag 非空；desc 通过
  `--desc-file -` 与 `vim.system({ stdin = true })` 写入；其它未展示字段不发送。
- status、flow/private/touch/meta 不混入此表单，避免隐式绕过各自命令语义。
- 新增调用 `add --json --title ... --tag ... --origin human`，按需添加 deps/doc/desc。
- 保存成功后才设置 `modified=false`、更新 baseline 并恢复详情；失败保持 dirty，错误在
  表单上方用虚拟行或通知显示，不覆盖文本。
- 对 dirty 表单执行取消、关闭或重新打开时，用 `vim.ui.select` 提供保存/放弃/取消；放弃
  必须显式选择。
- 表单 buffer 禁用 render-markdown 自动附加，设置可识别的 `b:loopkit_form`；测试覆盖存在
  format-on-save 类 `BufWritePre` 时仍只由 `BufWriteCmd` 提交一次，且不直接落本地文件。

### 进阶字段与 decide

详情区除 title/status/tag/origin/openAt/closedAt/hash/deps/doc 外，增加只读区块：

- flow：档位名或 stage 列表；未设置显示“默认”。
- private：仅在有值时显示 true/false。
- touch：unknown 或逐行路径/glob；不把 null 显示成空数组。
- meta：branch/baseSha；未设置显示未配置。
- decide/analysis：outstandingCount、eligible、blocked、stuck 以及当前任务依赖状态。

交互：

- `F` 用 `vim.ui.select` 选择 full/research-only/quick/spec-impl/research-split/doc-to-tasks、
  自定义 stage 列表或清除。自定义输入逐段校验白名单与顺序，要求以 commit 收尾。
- `P` 明确选择开启或关闭，不通过无状态切换猜用户意图。
- `T` 提供 set/append/clear/import-doc。set/append 输入 JSON 字符串数组，以支持含空格路径；
  逐项要求非空、仓库根相对、无 `..` 和换行；空数组由 CLI 的非法语义提示并阻止提交。
- `M` 提供设置/清除。设置依次读取 branch 与完整 baseSha，二者必须同写；清除需要确认。
- `n` 调用 `decide --json --no-sync`，展示 action/id/reason/ids；action 为 next 且有 id 时
  选中任务，其它 action 只展示原因，不擅自 refill、claim 或启动循环。
- 单任务阻塞解释优先使用 `list --target <id> --json --no-sync` 的 analysis，加上依赖任务
  的当前状态；不重新发明调度规则。

### 命令、配置、公开 API 与事件

命令：

```vim
:LoopKit
:LoopKit open [path]
:LoopKit show #12
:LoopKit edit #12
:LoopKit add
:LoopKit sync
:LoopKit refresh
:LoopKit remove #12
:LoopKit decide
:LoopKit paths
:LoopKit health
:LoopKit close
```

`setup` 默认：

```lua
require("loop-kit").setup({
  cli_path = nil,
  project_root = nil,
  auto_sync = true,
  list_width = 38,
  default_filter = "open",
  sort = "status",
  icons = { pending = "○", doing = "◐", done = "●", blocked = "✕" },
  confirm = { done = true, force_done = true, block = true, remove = true },
  keys = {},
})
```

公开 Lua API 至少包含 `setup/open/close/refresh/sync/get_snapshot/get_task/edit/add/remove/
actions`。公开快照是副本或只读约定，调用者不能绕过 actions 修改权威状态。

自动命令事件：

- `User LoopKitUpdated`：`data = { root, snapshot }`。
- `User LoopKitAction`：`data = { root, id, action, ok, error }`。

高亮组均以 `default = true` 定义并链接到通用组：`LoopKitPending/Doing/Done/Blocked`、
`LoopKitId/Title/Tag/Muted/Header/Error/Selected`。插件不自带 colorscheme。

Health 检查：Neovim 版本、CLI 路径与 `--version`、配置可解析、`paths`、tokenEnv 是否存在
（只显示变量名与存在性）、`list --no-sync` 可用性、`remove --help` 能力。Health 不主动联网、
不打印 token，不把无缓存误报为配置损坏。

### 错误呈现

| 情况 | 用户可见行为 |
| --- | --- |
| CLI 不存在或版本/子命令过旧 | 显示实际解析路径，提示 `cli_path`、`$LOOP_BIN` 或升级 CLI |
| 配置缺失/不可读/非法 | 显示配置绝对路径和 CLI 诊断；允许执行 paths/health |
| tokenEnv 未设置 | 只显示变量名；保留缓存浏览 |
| 远端无缓存 | 显示待同步状态，不伪装成零任务 |
| exit 1 | 作为插件/CLI 契约错误，显示 argv 的安全摘要与用法错误 |
| exit 2/3 | 指向配置或 LOOP 数据，建议 `loop-cli validate`，不自动修复 |
| exit 4 依赖/blocked | 展示原因和未完成依赖；只有显式 force 动作可绕过允许的门禁 |
| exit 4 远端冲突 | 保留输入，要求同步并人工核对；绝不自动覆盖 |
| exit 5 | 显示网络/权限诊断，保留旧快照，可重试 sync |
| stdout 非 JSON | 报告 CLI 路径、退出码和截断 stdout/stderr，提示版本不匹配 |
| UI/JSON/窗口已关闭竞态 | 静默丢弃过期回调；真正错误进入 notify 与 health 调试信息 |

## 改动范围

以下路径均相对本仓库根；路径同时是建议的子任务写集边界。共同文件集中在最后的公开集成
任务，兄弟任务不得为了接线而修改别人的文件。

- `plugin/loop-kit.lua`：懒加载命令注册，仅由公开集成任务拥有。
- `lua/loop-kit/init.lua`：setup、公开 API、命令分发，仅由公开集成任务拥有。
- `lua/loop-kit/config.lua`：项目发现、配置与 CLI 路径解析。
- `lua/loop-kit/util.lua`：路径、id、表复制、安全文本等共享纯函数。
- `lua/loop-kit/cli.lua`：argv、异步进程、stdin、JSON 与结构化错误。
- `lua/loop-kit/source.lua`：paths/list/show/decide、缓存优先同步、generation。
- `lua/loop-kit/state.lua`：每项目快照、筛选、排序、选中和写队列状态。
- `lua/loop-kit/render.lua`：列表/详情纯渲染与行映射。
- `lua/loop-kit/highlights.lua`：默认高亮组。
- `lua/loop-kit/actions.lua`：claim/done/block/remove 与写队列。
- `lua/loop-kit/form.lua`：编辑/新增表单、字段 diff、acwrite 与 dirty 保护。
- `lua/loop-kit/advanced.lua`：flow/private/touch/meta。
- `lua/loop-kit/decide.lua`：推荐与阻塞解释视图模型。
- `lua/loop-kit/ui/board.lua`：tab 和窗口生命周期。
- `lua/loop-kit/ui/list.lua`：列表 buffer、导航与筛选键位。
- `lua/loop-kit/ui/detail.lua`：详情 buffer 与文档打开。
- `lua/loop-kit/ui/help.lua`：帮助浮窗。
- `lua/loop-kit/health.lua`：只读诊断。
- `syntax/loopkit.vim`：列表语法的轻量补充；无 syntax 时高亮仍可用。
- `tests/minimal_init.lua`、`tests/run.lua`、`tests/helpers/**`、`tests/fixtures/**`：测试基础
  设施、fake CLI 与固定 JSON，由核心基础任务一次建立，后续任务只新增自己名下的 spec。
- `tests/unit/**`、`tests/fake-dom/**`、`tests/render/**`、`tests/integration/**`：按下方验收
  标准中的具体文件划分，禁止多个子任务共同拥有同一个 spec。
- `README.md`、`doc/loop-kit.txt`：安装、命令、键位、provider 矩阵、故障排查与手工验收。
- `.gitea/workflows/nvim.yml`：headless Neovim 测试与 `git diff --check`。
- 后续非 v1：`lua/loop-kit/telescope.lua`、`lua/telescope/_extensions/loop_kit.lua`、浮动布局
  和 lualine 组件；本次不创建这些文件。

## 验收标准

### 单元测试

由 `nvim --headless -u tests/minimal_init.lua -l tests/run.lua -- --filter unit` 执行。

- `tests/unit/config_spec.lua`：显式根优先；从嵌套文件和 cwd 向上发现；相对 loopRoot 不
  由插件臆测，paths 返回值原样使用；相对 cliPath 正确解析；缺配置与不可执行 CLI 有稳定
  错误码/消息。
- `tests/unit/cli_spec.lua`：argv 中 `#12`、空格、中文和引号保持单参数；desc 只走 stdin；
  0/1/2/3/4/5 映射正确；JSON 数组/null/缺省可选字段不抛错；stdout 截断不泄露环境 token。
- `tests/unit/source_spec.lua`：无缓存错误可识别；旧 generation 不覆盖新快照；sync 失败保留
  旧 tasks；本地与远端 source 信息保留。
- `tests/unit/state_spec.lua`：筛选/分组/数字 id 排序稳定；刷新后按 id 恢复选中；被过滤后
  选择最近可见项；写请求 FIFO；不同项目根状态隔离。
- `tests/unit/render_spec.lua`：open 默认不含 done；行映射只指向任务行；长标题与多字节
  字符不破坏映射；desc 多段 Markdown 原样进入详情；touch 的 null 与空数组显示不同。
- `tests/unit/form_spec.lua`：表单 round-trip 保留多段 desc；只改 title 时 argv 不含
  desc/tag/deps/doc；空 deps/doc 使用各自 clear 命令；非法 meta 指出行号；新增默认值正确；
  表单不发送 status/flow/private/touch/meta。
- `tests/unit/advanced_spec.lua`：flow 白名单/stage 顺序与 commit 收尾；touch JSON 数组支持
  空格并拒绝绝对路径、`..`、换行与空数组；meta 要求 branch/baseSha 同时提供；private 是
  显式 on/off。
- `tests/unit/decide_spec.lua`：next 跳转 id；refill/stop/wait 只显示 reason；deps 状态与
  analysis 的 blocked/stuck 解释不重复调度逻辑。

### 假 DOM / 假 CLI 集成

这里的 fake-dom 以可编程 fake CLI 替代远端/文件系统，由
`... tests/run.lua -- --filter fake-dom` 执行。

- `tests/fixtures/fake-loop-cli` 记录 argv/stdin 到临时文件，按场景返回 JSON、退出码和
  stderr；不得依赖网络。
- `tests/fake-dom/cli_spec.lua`：所有公开动作生成精确 argv；多行 desc 字节可由 fake CLI 读回；
  永不出现 shell 拼接调用。
- `tests/fake-dom/actions_spec.lua`：claim/done/block/remove 成功刷新并保持合法选中；done 门禁
  不自动 force；只有 D 追加 `--force`；remove 前无确认不启动进程；local/远端确认文案不同；
  exit 4/5 不丢快照。
- `tests/fake-dom/form_spec.lua`：`:w` 只提交一次；失败保持 modified 与原文；冲突不自动重试；
  成功后 modified=false；dirty 取消分支完整；新增成功后选中新 id。
- `tests/fake-dom/advanced_spec.lua`：flow/private/touch/meta 分别调用对应子命令，不把字段塞进
  通用 edit；错误后不清空用户输入。
- `tests/fake-dom/decide_spec.lua`：无缓存/远端失败显示原因；next 只导航不自动 claim。

### 渲染测试

由 `... tests/run.lua -- --filter render` 在真实 headless Neovim buffer/window 中执行。

- `tests/render/board_spec.lua`：打开后为一个新 tab、左右两个窗口；重复 open 不重复建 tab；
  q/tabclose/WinClosed 清理 autocmd；旧异步回调不触碰已关闭窗口；调整 columns/lines 不报错。
- `tests/render/list_spec.lua`：353 行级固定夹具可导航（可用生成 fixture，不依赖真实远端）；
  状态组、筛选、关键字和选中高亮正确；空列表/无匹配/加载/错误四种状态可区分。
- `tests/render/detail_spec.lua`：详情只读且 filetype=markdown；依赖状态、flow/private/touch/
  meta 与 decide 区块按缺省规则显示；doc 打开相对项目根。
- `tests/render/form_spec.lua`：表单在详情窗打开，acwrite 可编辑；保存/取消恢复详情；
  BufWritePre 格式化钩子不会导致双提交或写普通文件；帮助浮窗可开关且不改变选中。

### 集成与文档

- `tests/integration/public_spec.lua`：从 `plugin/loop-kit.lua` 注册后的 `:LoopKit` 命令走到
  fake source/UI；所有子命令参数与 Lua API 一致；`User` 事件 data 完整；setup keys=false
  能禁用键位。
- `tests/integration/health_spec.lua`：缺 CLI、缺配置、缺 tokenEnv、无缓存、旧版无 remove
  五类诊断；健康检查不联网、不打印 token。
- `tests/integration/real_cli_spec.lua`：默认跳过；设置 `LOOP_KIT_REAL_CLI=1` 后，在临时目录
  创建 local 配置与 LOOP.json，用真实 CLI 完成 paths/add/list/edit/claim/done/block/remove，
  断言最终数据与插件快照一致，不修改开发者的真实 LOOP。
- `README.md` 与 `doc/loop-kit.txt` 覆盖安装、Neovim/CLI 要求、全部命令和默认键位、表单
  契约、远端冲突语义、local 删除与远端移出的区别、测试命令和已知边界。
- `.gitea/workflows/nvim.yml` 运行全部默认测试；README 描述的手工远端矩阵只作 deferred
  manual，不在 CI 访问真实服务。

### 手工验收（延后，不阻塞自动化完成）

- 在真实 local 项目：浏览、筛选、编辑多行 desc、新增、claim/done/block、remove，确认外部
  `loop-cli show/list` 与插件一致。
- 在 gitea 测试项目：无缓存启动、后台同步、字段编辑、meta/touch/flow/private、移出循环，
  确认 issue 保留且准入标签被摘除。
- 两个客户端同时编辑同一远端任务：后到者收到冲突，插件保留输入且不自动覆盖。
- 模拟无 token、网络断开、无权限、非法 LOOP 数据，核对提示与缓存可用性。
- github/jira/lua 仅在具备安全测试环境时执行同一矩阵；未实测项必须在 README provider
  矩阵标为未验证，不得声称全部通过。

## 建议拆分边界

为满足 doc-to-tasks 的 2–12 个 quick 子项与互斥写集要求，建议按以下顺序/依赖拆分。
这里是拆分指导，不要求子任务另建文档；它们继承本文件。

1. **core-foundation**：config/util/cli/source/state + 测试 runner、helpers、fixtures 及核心
   unit/fake-dom spec。独立可测，优先完成。
2. **render-model**：render/highlights + render/state 相关 unit 与纯渲染 spec。依赖 1 的状态
   形状，不修改核心文件。
3. **task-actions**：actions + actions fake-dom spec。依赖 1。
4. **task-form**：form + form unit/fake-dom/render spec。依赖 1、3。
5. **advanced-actions**：advanced/decide + 对应 unit/fake-dom spec。依赖 1、3。
6. **board-ui**：ui/board、ui/list、ui/detail、ui/help + board/list/detail render spec。依赖
   1–5，通过 lazy require 接入动作/表单/进阶接口，不修改它们。
7. **public-integration**：plugin 命令、init、health、syntax + public/health/real_cli integration
   spec。依赖 1–6，唯一负责最终接线。
8. **docs-ci**：README、help、Gitea workflow。依赖 7，只写文档与 CI，不改实现。

若拆分器合并或细分，仍须遵守：同一 spec/实现文件只能属于一个子项；需要共同修改同一
文件的工作必须合并；每项给出非空 touch，deps 只表达真实接口依赖。

## 实施顺序与完成定义

1. 核心契约与测试基础先行，避免 UI 反向决定 CLI/状态接口。
2. 纯渲染、动作、表单与进阶能力可以按依赖并行；每项先让其新增测试失败，再实现至通过。
3. board-ui 接入真实 buffer/window，public-integration 最后接命令和公开 API。
4. 每次子项验收至少运行其新增测试与已有 unit/fake-dom/render 回归；最终运行完整默认
   测试、`git diff --check` 与 real CLI local 冒烟（环境允许时）。
5. 文档与 CI 最后核对公开行为；代码行为与 README 不一致时先修实现或文档，不能仅改测试
   期望掩盖偏差。

v1 完成定义：默认测试全绿；公开命令/API、键位、表单和错误语义与文档一致；本地 real CLI
闭环通过；远端至少完成 gitea 手工矩阵或明确记录环境阻塞；没有把任何 LOOP 写操作绕过
CLI 的代码路径。

## 待确认决策

无。布局、远端编辑、零依赖、v1 功能范围和 remove 的上游实现均已由用户确认。

## 关联文档

- `.pi/loop-kit/TARGETS.md`（当前为模板，后续填写时不得静默缩小本文件已确认范围）。
- `.pi/loop-kit/workflow/doc-task-split.md`（子任务数量、quick、touch 与互斥写集标准）。
- 上游 `/home/luli/Developer/tools/loop-kit/docs/config.md`（配置与路径规则）。
- 上游 `/home/luli/Developer/tools/loop-kit/docs/providers.md`（provider 写语义、锁与远端冲突）。
- 上游 `crates/loop-cli/src/lib.rs`、`crates/loop-core/src/model.rs`、
  `crates/loop-core/src/provider/mod.rs`（CLI、Task 与 remove 契约）。
