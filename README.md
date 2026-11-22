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
| `:LoopKit edit #12` | 打开该任务的编辑表单 |
| `:LoopKit add` | 打开新增任务表单 |
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
| `j` / `k`、`<Down>` / `<Up>` | 上下移动 |
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
| `e` / `a` | 编辑当前任务 / 新增任务 |
| `x` | 删除或移出当前任务（始终先确认） |
| `o` | 用 `:edit` 打开任务的 `doc`（相对项目根解析） |
| `F` / `P` / `T` / `M` | flow / private / touch / worktree meta |
| `n` | decide 推荐 |
| `?` | 打开/关闭帮助浮窗 |
| `q` | 关闭看板 tab |

默认筛选是 `open`（pending/doing/blocked），默认按数字 id 降序平铺。按 `S` 可在
`id_desc → id_asc → closed_desc → closed_asc → status` 之间切换；`status` 模式按
doing → pending → blocked → done 分组。详情窗里也可使用 `q`、`?`、`o`、`e`。

同一项目的写操作串行执行（FIFO）；切换筛选和只读刷新不会被写请求阻塞，但写完成前
不会用旧列表覆盖成功响应。写失败保留当前选中、筛选与表单内容。

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

可用动作名与默认键位表中的行为一致：`move_up`、`move_down`、`open_detail`、
`filter_prompt`、`clear_query`、`cycle_filter`、`filter_all`、`cycle_sort`、`refresh`、`sync`、
`claim`、`done`、`force_done`、`block`、`edit`、`add`、`remove`、`open_doc`、
`flow`、`private`、`touch`、`meta`、`decide`、`help`、`close`。插件不写任何全局
键位。

## 表单格式契约

`e` / `a` 在详情窗打开 `buftype=acwrite` 的 Markdown buffer，`:w` 由
`BufWriteCmd` 接管，捕获后走 `loop-cli`，不会写本地文件。buffer 名形如
`loopkit://<root>/task/%2312` 与 `loopkit://<root>/new/<nonce>`。

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

规则：

- 首个任务注释保存 id；新增表单使用 `<!-- loopkit:task new -->`。
- 第一个一级标题是 `title`，必填且单行；其余标题留在 desc 中，不会被当成字段。
- 唯一的 `loopkit:meta` 注释块接受 `tag` / `deps` / `doc`。未知键、重复键、
  非法 id 与非法路径在调用 CLI 前报错并标出行号。`doc` 必须是仓库根相对路径，
  不得以 `/`、盘符开头，也不得包含 `..` 或换行。
- meta 块之后的全部文本是 desc（没有 meta 块时从一级标题之后开始），保留多段
  与 Markdown 结构。
- deps 用逗号分隔并规范化为 `#n`；清空用 `deps --set ''`，清空 doc 用
  `doc --clear`。新增时为空则不发送对应参数。
- 以打开时的任务为 baseline 做字段 diff，只提交实际变化的字段；desc 通过
  `--desc-file -` 从 stdin 写入，不经过 shell。
- 表单不发送 `status`、`flow`、`private`、`touch`、`meta`；这些字段各有独立命令
  （`d`/`D`/`b` 与 `F`/`P`/`T`/`M`），避免绕过依赖门禁与 closedAt/hash 语义。
- 保存成功后才清除 `modified`、更新 baseline 并恢复详情；失败保持 dirty 与原文。
  对 dirty 表单执行取消、关闭或重新打开时会询问保存/放弃/取消，放弃必须显式选择。
- 表单 buffer 设置 `b:loopkit_form`；即使存在 format-on-save 一类 `BufWritePre`
  钩子，也只通过 `BufWriteCmd` 提交一次。

## provider 矩阵与写入语义

插件把 `local`、`gitea`、`github`、`jira` 都交给同一个 CLI 适配层，不复制 provider
协议；配置校验接受这四个 provider 值，实际能力以已安装的 `loop-cli` 为准。
下表只记录本仓库**实际验证**过的范围，未验证项不声称通过：

| provider | 状态 | 说明 |
| --- | --- | --- |
| `local` | 已验证 | `LOOP_KIT_REAL_CLI=1` 下的临时项目集成测试覆盖 paths/add/list/edit/claim/done/block/remove |
| `gitea` | 未验证 | 逻辑走同一 CLI 适配层；需要在测试 issue 仓库上执行下方手工矩阵 |
| `github` | 未验证 | 同上；需要独立测试环境 |
| `jira` | 未验证 | 同上；需要独立测试环境 |

### 远端冲突

- 写操作可能因远端乐观并发（`updatedAt` 变化）被拒绝（CLI 退出码 `4`，且信息指向
  并发/冲突）。插件不自动重试、不合并、不覆盖。
- 冲突时保留 dirty 表单和用户输入，提示先同步再人工核对。
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
`LoopKitError`、`LoopKitSelected`，以及详情窗的 `LoopKitDetailTitle`、
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

## 测试

测试零第三方依赖，使用 headless Neovim、纯 Lua runner 与可编程 fake CLI。
默认分组按顺序运行 `unit` → `fake-dom` → `render` → `integration`：

```bash
# 全部默认测试（integration 中的 real CLI 用例默认跳过）
nvim --headless -u tests/minimal_init.lua -l tests/run.lua

# 单个分组
nvim --headless -u tests/minimal_init.lua -l tests/run.lua -- --filter unit
nvim --headless -u tests/minimal_init.lua -l tests/run.lua -- --filter fake-dom
nvim --headless -u tests/minimal_init.lua -l tests/run.lua -- --filter render
nvim --headless -u tests/minimal_init.lua -l tests/run.lua -- --filter integration

# 真实 CLI 的 local 冒烟测试：在临时目录创建配置与 LOOP.json，不碰开发者真实数据
LOOP_KIT_REAL_CLI=1 nvim --headless -u tests/minimal_init.lua -l tests/run.lua -- --filter integration

# 空白字符检查
git diff --check
```

- `unit`：纯函数与契约（argv、路径、状态、表单 diff 等）。
- `fake-dom`：用 `tests/fixtures/fake-loop-cli` 记录 argv/stdin，断言精确命令与失败分支。
- `render`：在真实 headless buffer/window 中验证布局、导航、筛选与表单生命周期。
- `integration`：公开命令/API、健康检查与可选的真实 local CLI 闭环。
- `LOOP_KIT_REAL_CLI=1` 才会运行真实 CLI 用例；未设置时该用例显示为 skip。

CI（`.gitea/workflows/nvim.yml`）在 Ubuntu runner 上安装固定版本的 Neovim，
运行上面的默认测试与 `git diff --check`，不访问任何真实 LOOP 服务。

## 已知边界

- v1 只有 tab 双栏布局；浮动布局、Telescope 扩展与 lualine 组件不在本版范围。
- 插件不自建磁盘缓存或离线队列；远端源的完整同步需要 CLI 与网络可用。
- 不实现任何 provider 协议、依赖门禁或冲突合并逻辑，全部以 CLI 返回为准。
- 远端写操作的真实行为尚未在本仓库的自动化测试中覆盖（见 provider 矩阵）；
  gitea/github/jira 需要按下列手工矩阵验证后才能声明通过。
- `touch` 的 null（unknown）与空数组（显式空集合）在 UI 中显示不同；空数组会被
  CLI 拒绝。
- 未在 Windows 上验证；插件只使用跨平台 Neovim API，但仍以 macOS/Linux 实测为准。
- `loop-cli 0.1.0` 是当前实测版本；更旧版本可能缺少 `remove` 或 `--no-sync`。

### 手工验收矩阵（deferred，不阻塞自动化）

1. local 项目：浏览、筛选、编辑多段 desc、新增、claim/done/block/remove，确认外部
   `loop-cli show/list` 与插件一致。
2. gitea 测试项目：无缓存启动、后台同步、字段编辑、flow/private/touch/meta、
   移出循环，确认 issue 保留且 `loop:todo` 标签被摘除。
3. 两个客户端同时编辑同一远端任务：后到者收到冲突，插件保留输入且不自动覆盖。
4. 模拟无 token、断网、无权限、非法 LOOP 数据，核对提示与旧快照可用性。
5. github/jira 仅在具备安全测试环境时执行同一矩阵，结果补入上表。
