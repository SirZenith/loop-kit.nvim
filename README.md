# loop-kit.nvim

在 Neovim 里浏览与操作 LOOP 任务的零依赖看板。插件只直接读取项目根目录的
`loop.config.json` 用于发现项目与 CLI；任务数据的所有读取与写入都通过 `loop-cli`
完成。打开一个独立的 tab，左侧是任务列表，右侧是只读 Markdown 详情，常用动作
（claim/done/block、编辑、新增、移出循环、flow/private/touch/meta、decide）都有
默认键位。

- 零运行时依赖：只用 Neovim API，不需要 nui.nvim、telescope.nvim 或
  render-markdown.nvim。
- 不直接写 LOOP 数据：插件永远不读写 `LOOP.json`、`LOOP.remote.json` 或
  `loop.meta.json`，也不解析 provider 协议。
- 插件不自建磁盘缓存：快照只存在内存里；首次渲染用 `loop-cli list --no-sync`
  读取 CLI 自己的缓存。
- 远端失败不清空已有快照：同步或写入失败时保留上一次可浏览的数据。

## 要求

| 项目 | 要求 |
| --- | --- |
| Neovim | 0.10 或更新版本（使用 `vim.system`、`vim.fs`、`vim.json`、`vim.uv`） |
| loop-cli | 0.1.0 或更新版本；需要 `remove` 子命令（旧版会用健康检查提示升级） |
| 项目 | 根目录有可读的 `loop.config.json`（`version` 为 `1`，`loopRoot` 非空） |

CLI 可执行文件查找顺序固定为：`setup.cli_path` → `$LOOP_BIN` → 配置里的
`cliPath` → `PATH` 中的 `loop-cli`。配置中的相对 `cliPath` 相对配置文件目录解析。

项目根解析顺序：命令显式路径 → `setup.project_root` → 当前文件向上查找
`loop.config.json` → 当前工作目录向上查找 → `$LOOP_PROJECT_ROOT` → 当前工作目录。
最终以 `loop-cli --project-root <root> --json paths` 返回的 `config` / `loopRoot`
为准。

## 安装

用 lazy.nvim：

```lua
{
  "https://git.dispersion.cc/Dispersion/loop-kit.nvim.git",
  cmd = "LoopKit",
  config = function()
    require("loop-kit").setup()
  end,
}
```

用 Neovim 0.12+ 自带的 `vim.pack`（0.10/0.11 请使用 lazy.nvim 或 vim-plug）：

```lua
vim.pack.add({ "https://git.dispersion.cc/Dispersion/loop-kit.nvim.git" })
require("loop-kit").setup()
```

用 vim-plug：

```vim
Plug 'https://git.dispersion.cc/Dispersion/loop-kit.nvim.git'
```

`plugin/loop-kit.lua` 只注册 `:LoopKit` 命令，不加载看板；不调用 `setup()`
时使用下方默认值。仓库没有 colorscheme，所有高亮组都用 `default = true`
链接到通用组，可被用户配置或主题覆盖。

## 快速开始

```vim
:LoopKit
```

第一次打开时：

1. 定位项目根与 `loop-cli`，用 `paths --json` 校验路径；
2. 先执行 `list --json --no-sync`，成功后立即渲染缓存；
3. `auto_sync = true` 且源为远端时，后台执行一次完整 `list --json`；
4. 远端还没有缓存时显示“尚无缓存，正在同步”的状态，不显示成空列表；
5. 同步失败保留旧快照，并在 winbar 与通知里显示原因。

`:LoopKit` 会复用同一项目的已有看板，不会为同一项目开第二个 tab。

## 命令

| 命令 | 行为 |
| --- | --- |
| `:LoopKit` / `:LoopKit open [path]` | 打开或聚焦当前项目的看板 |
| `:LoopKit show #12` | 打开看板，选中任务并聚焦详情窗 |
| `:LoopKit edit #12` | 选中任务并按光标位置进入字段编辑 |
| `:LoopKit add` | 依次输入标题与 tag 后新增任务 |
| `:LoopKit sync` | 完整执行 `loop-cli list`（远端源会访问网络） |
| `:LoopKit refresh` | 只读取缓存/本地状态，不联网 |
| `:LoopKit remove #12` | 确认后删除 local 任务或把远端任务移出循环 |
| `:LoopKit decide` | 请求 decide 推荐；有 next id 时选中，否则只显示原因 |
| `:LoopKit paths` | 只读显示 `loop-cli paths` 的权威路径 |
| `:LoopKit health` | 在分屏里显示与 `:checkhealth loop-kit` 相同的诊断结果 |
| `:LoopKit close` | 关闭当前看板 tab |

`:LoopKit` 的子命令名大小写不敏感。

## 默认键位

| 键位 | 行为 |
| --- | --- |
| `j` / `k`、`<Down>` / `<Up>` | 上下移动（数字前缀表示重复，如 `3j`） |
| `gg` / `G` | 跳到首个 / 最后一个任务 |
| `<C-u>` / `<C-d>` | 向上 / 向下半页 |
| `<C-b>` / `<C-f>` | 向上 / 向下一页 |
| `<CR>` | 聚焦当前任务的详情窗 |
| `/` | 输入关键字（匹配 id/title/tag/desc，大小写不敏感） |
| `<Esc>` | 清除关键字 |
| `s` / `A` | 循环状态筛选（open → all → pending → doing → blocked → done）/ 直接显示全部 |
| `S` | 循环排序（id_desc → id_asc → closed_desc → closed_asc → status） |
| `r` / `R` | 读取缓存（`--no-sync`）/ 完整同步 |
| `c` | claim 当前任务 |
| `d` | done（受依赖门禁约束） |
| `D` | 确认后强制 done（显式追加 `--force`） |
| `b` | 输入非空原因并 block |
| `e` | 编辑光标处的字段（标题/描述/提示词/阶段名） |
| `a` | 新建任务（输入标题与分类 tag） |
| `x` | 删除或移出当前任务（始终先确认） |
| `o` | 用 `:edit` 打开任务的 `doc`（相对项目根解析） |
| `F` / `P` / `T` / `M` | flow / private / touch / worktree meta |
| `n` | decide 推荐 |
| `?` | 打开/关闭帮助浮窗 |
| `q` | 关闭看板 tab |

默认筛选是 `open`（pending/doing/blocked），默认按数字 id 降序平铺。按 `S` 可在
`id_desc → id_asc → closed_desc → closed_asc → status` 之间切换；`status` 模式按
doing → pending → blocked → done 分组。详情窗里也可使用 `q`、`?`、`o`、`e`。

详情窗开头的键值对按类型分为四组，组内连续排列：状态信息（`id`、`status`、
`tag`、`origin`、`openAt`、`closedAt`、`hash`）、依赖与文档（`deps`、`doc`、
`docParent`）、提示词（`specPrompt`、`researchPrompt`、`codePrompt`、`verifyPrompt`、
`docTaskSplitPrompt`）与执行信息（`flow`、`touch`、`meta`、`isPrivateDesc`）。组与组
之间插入 Markdown 分隔线 `---`（前后各留一个空行）；第一组前与最后一组后不加分隔线，
因此 decide/analysis 块开头仍只有单条 `---`，不出现连续分隔线。

同一项目的写操作串行执行（FIFO）；切换筛选和只读刷新不会被写请求阻塞，但写完成前
不会用旧列表覆盖成功响应。写失败保留当前选中、筛选与编辑内容。

## 配置

```lua
require("loop-kit").setup({
  cli_path = nil,          -- 覆盖 loop-cli 路径
  project_root = nil,      -- 覆盖项目根
  auto_sync = true,        -- 打开/刷新时是否后台完整同步（仅远端源访问网络）
  list_width = 38,         -- 左窗宽度
  default_filter = "open", -- open/all/pending/doing/blocked/done
  sort = "id_desc",        -- id_desc/id_asc/closed_desc/closed_asc/status/title
  show_winbar = true,      -- 左窗是否显示 winbar（右窗始终显示）
  show_hint = true,        -- 左窗是否显示顶部键位提示行
  icons = { pending = "○", doing = "◐", done = "●", blocked = "✕" },
  confirm = { done = true, force_done = true, block = true, remove = true },
  keys = {},               -- lhs → 动作名；false 表示禁用
})
```

`keys` 会覆盖默认键位，例如：

```lua
require("loop-kit").setup({
  keys = {
    q = false,                 -- 禁用 q
    ["<C-s>"] = "sync",        -- 新增键位
    ["<CR>"] = "open_detail",  -- 改绑已有键位
  },
})
```

可用动作名与默认键位表中的行为一致：`move_up`、`move_down`、`move_first`、`move_last`、
`move_half_up`、`move_half_down`、`move_page_up`、`move_page_down`、`open_detail`、
`filter_prompt`、`clear_query`、`cycle_filter`、`filter_all`、`cycle_sort`、`refresh`、`sync`、
`claim`、`done`、`force_done`、`block`、`edit`、`add`、`remove`、`open_doc`、
`flow`、`private`、`touch`、`meta`、`decide`、`help`、`close`。插件不写任何全局
键位。

## 字段级编辑

`e` 按当前窗口与光标位置选择目标；列表窗始终编辑 `desc`。详情窗使用
`render.detail` 的字段锚点（不做 Markdown 扫描）：

- 标题 / 阶段标题 → 单行 input。
- 描述 / 用户提示词 / 阶段正文 → `buftype=acwrite` 的 Markdown buffer。
- “各阶段提示词”的空位 → 先输入阶段名。
- `isPrivateDesc` → 直接切换开关：当前为 `true` 时发送 `private --off`，否则
  发送 `private --on`，不打开编辑 buffer。
- “# 阻塞原因”标题与正文 → 只读；按 `e` 提示“阻塞原因不可直接编辑，请按 b 重新设置”。
- 其它元数据与 analysis → 拒绝，并提示“该行暂不支持编辑”。

编辑 buffer 名为 `loopkit://<root>/edit/<encoded-id>/<target>[/<stage>]`
（`#` 编码为 `%23`），设置 `filetype=markdown`、`swapfile=false`。`:w` 由
`BufWriteCmd` 从 stdin 交给 `loop-cli`，不写本地文件；失败保留 dirty 并提示。
normal 模式 `<Esc>` / `<C-c>` 退出：干净时直接关闭，dirty 时询问
“放弃未保存的修改？”（放弃修改 / 继续编辑）。编辑期间列表显示静态信息栏，
其它任务动作被忽略；`?` 仍可打开帮助，`q` 先退出编辑。

路径字段（`doc`、`docParent` 与 5 个 `*Prompt`）的单行输入以项目根为基准补全：
输入裸相对路径（如 `lua/lo`）即可列出候选，目录候选带 `/`，`./` 前缀保留，
绝对路径也可补全；补全只是候选，不阻止自由输入。`touch` 的多行编辑 buffer
设置 buffer-local `omnifunc`，在行内按 `<C-x><C-o>` 触发；`../` 可用于向上
导航，候选会改写为仓库相对路径，越出项目根的路径不列出，保存时仍拒绝绝对
路径与 `..` 段。补全不依赖 nvim-cmp；若用户的 `vim.ui.input`
覆盖忽略 `completion`，单行补全自然降级为无补全。

阶段名规则：

- 内建 `research` / `spec` / `json-task-split` / `doc-task-split` /
  `decision-question` / `impl` / `verify` / `commit`，或非空且含 `.` 的外部名；
  空白、含空格或其它未知名称拒绝。
- 新建重名 → 询问是否直接编辑已有阶段；改名撞名 → 拒绝并保持编辑。
- 阶段名改为空 → 确认后删除整条。
- 删除发送 `--stage-prompt <stage>=`；改名发送
  `--stage-prompt-file <new>=-` 与 `--stage-prompt <old>=`。

`a` 依次输入标题与分类 `tag`（默认 `feature`）。tag 必须属于
`<loopRoot>/TARGETS.md` 的「任务分类（tag）」集合（解析失败回退
`feature`/`bugfix`/`refactor`/`ux`/`visual`/`docs`/`chore`），然后执行
`add --title T --tag X --json`；任一步取消或 tag 非法都不调用 CLI。

编辑只提交当前字段，不发送 `status`/`flow`/`touch`/`meta`；`isPrivateDesc`
走 `private --on`/`--off`，其余字段各有独立命令。

## provider 矩阵与写入语义

插件把 `local`、`gitea`、`github`、`jira` 都交给同一个 CLI 适配层，不复制 provider
协议；配置校验接受这四个 provider 值，实际能力以已安装的 `loop-cli` 为准。
下表列出支持的 provider 及其写入方式：

| provider | 说明 |
| --- | --- |
| `local` | 本地文件驱动闭环 |
| `gitea` | 通过同一 CLI 适配层操作 Gitea issue |
| `github` | 通过同一 CLI 适配层操作 GitHub issue |
| `jira` | 通过同一 CLI 适配层操作 Jira issue |

### 远端冲突

- 写操作可能因远端乐观并发（`updatedAt` 变化）被拒绝（CLI 退出码 `4`，且信息指向
  并发/冲突）。插件不自动重试、不合并、不覆盖。
- 冲突时保留 dirty 编辑内容和用户输入，提示先同步再人工核对。
- `done` 被依赖门禁拒绝时展示未完成依赖，不自动 force；只有 `D`（确认后）会追加
  `--force`。
- 退出码 `5`（网络/权限等远端失败）只显示诊断并保留旧快照，可重试 `:LoopKit sync`。

### local 删除与远端移出

- `x` 总是先确认，且确认文案按源类型区分。
- `local`：`loop-cli remove` 会永久删除条目，并从其他任务的依赖中清理对该 id 的引用。
- 远端（gitea/github/jira）：`loop-cli remove` 只摘除 `loop:todo` 准入标签并保留
  远端 issue，操作幂等。
- 插件不重新实现这些语义，也不直接修改任何 JSON；旧版 CLI 缺少 `remove` 时由健康
  检查提示升级。

## 事件与公开 API

公开 Lua API：

```lua
local loop = require("loop-kit")

loop.setup(opts)
loop.open(opts)          -- 返回 board, created
loop.close(opts)         -- opts.all 关闭全部
loop.refresh(opts)       -- 默认读缓存；opts.sync = true 时完整同步
loop.sync(opts)
loop.get_snapshot(root)  -- 快照副本
loop.get_task(id, root)  -- 任务副本
loop.edit(id, opts)
loop.add(opts)
loop.remove(id, opts)
loop.actions(root)       -- 该项目的动作控制器
loop.decide(opts)
loop.paths(opts, cb)
loop.health(opts)
loop.defaults()
loop.reset()
```

返回的快照与任务都是副本/只读约定；调用者不能借它绕过动作层修改权威状态。

自动命令：

- `User LoopKitUpdated`：`data = { root, snapshot }`。
- `User LoopKitAction`：`data = { root, id, action, ok, error }`（用户取消不触发）。

高亮组：`LoopKitPending`、`LoopKitDoing`、`LoopKitDone`、`LoopKitBlocked`、
`LoopKitId`、`LoopKitTitle`、`LoopKitTag`、`LoopKitMuted`、`LoopKitHeader`、
`LoopKitError`、`LoopKitSelected`（任务列表选中行，链接 `Visual`）、
`LoopKitPickerSelected`（多选界面选中标记，链接 `CursorLineNr`），以及详情窗的
`LoopKitDetailTitle`、
`LoopKitDetailSection`、`LoopKitDetailKey`、`LoopKitDetailValue`、`LoopKitDetailPath`、
`LoopKitDetailMuted`、`LoopKitDetailId`、`LoopKitDetailTag`。
它们默认链接到 `Comment`、`Identifier`、`Title`、`Special`、`String`、`Visual` 等
内置组；打开看板时会自动定义，无需调用 `setup()`。

## 健康检查与故障排查

```vim
:checkhealth loop-kit
:LoopKit health
```

检查项：Neovim 版本、`loop.config.json` 是否可解析、CLI 路径是否可执行、
`--version`、`paths`、`tokenEnv` 是否设置（只显示变量名，从不打印值）、
`list --no-sync` 是否可读、CLI 是否支持 `remove`。健康检查始终使用 `--no-sync`，
不访问网络。

常见情况：

| 情况 | 行为 |
| --- | --- |
| 找不到 CLI | 显示实际解析路径，提示设置 `cli_path`、`$LOOP_BIN` 或安装/升级 CLI |
| 配置缺失/非法 | 显示配置绝对路径；仍可执行 `:LoopKit paths` 与健康检查 |
| `tokenEnv` 未设置 | 只显示变量名；已有缓存仍可浏览 |
| 远端无缓存 | 提示先同步，不伪装成零任务 |
| 退出码 1 | CLI/插件契约或用法错误，显示安全的 argv 摘要 |
| 退出码 2/3 | 指向配置或 LOOP 数据，建议 `loop-cli validate`，不自动修复 |
| 退出码 4 | 依赖/blocked 或远端冲突，见上文 |
| 退出码 5 | 网络/权限诊断，保留旧快照 |
| stdout 不是 JSON | 报告 CLI 路径、退出码与截断后的输出，提示版本不匹配 |
| 看板/窗口已关闭 | 丢弃过期异步回调，不重绘已关闭窗口 |

## 已知边界

- v1 只有 tab 双栏布局；浮动布局、Telescope 扩展与 lualine 组件不在本版范围。
- 插件不自建磁盘缓存或离线队列；远端源的完整同步需要 CLI 与网络可用。
- 不实现任何 provider 协议、依赖门禁或冲突合并逻辑，全部以 CLI 返回为准。
- `touch` 的 null（unknown）与空数组（显式空集合）在 UI 中显示不同；空数组会被
  CLI 拒绝。
- `loop-cli 0.1.0` 是当前实测版本；更旧版本可能缺少 `remove` 或 `--no-sync`。

## 开发文档

测试、provider 验证状态和手工验收流程见 [DEV.md](DEV.md)。
