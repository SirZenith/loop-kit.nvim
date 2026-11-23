---
task_id: "#25"
summary: 任务列表新增可配置 card 显示样式：四行卡片、CJK 截断、选中态用边框换色，compact 保持不变
module: nvim
tag: ux
status: archived
updated: 2026-11-23
verification_levels: [unit, render]
deferred_levels: [manual]
---

# 任务列表 card 显示样式

## 目标

在不改变 loop-cli 数据读写、详情窗和键位行为的前提下，为左窗任务列表增加第二种显示样式
`card`，并允许用户通过 `setup()` 配置在 `compact`（现有两行样式，默认）与 `card` 之间切换。

`card` 需要满足：

- 每张卡片固定四行，宽度跟随列表窗口实际宽度；中文/全角字符按显示宽度对齐与截断。
- 首行在左右边框内展示任务 id 与状态；状态图标和状态名使用该任务状态的高亮色。
- 第二行展示标题，第三行展示 `tag · origin · flow` 类型信息。
- 卡片之间不留空行；分组标题前仍保留一个空行。
- 选中态不使用整行背景色，而是把该卡片整圈边框换成特殊色；未选中卡片边框使用注释色。

## 现状

左窗列表渲染集中在 `lua/loop-kit/render.lua` 的 `M.list(groups, opts)`（`:96`），当前只有
两行紧凑样式：

- 任务首行 `┌ <id> · <icon> <status>[ · tag]`，次行 `└ <title>`
  （`render.lua:181-187`）。
- 相邻任务之间插入空行（`render.lua:169-171`，判断上一行是否属于任务）。
- 分组标题 `Label (n)` 使用 `LoopKitHeader`，标题前插入空行（`render.lua:149-156`）。
- 选中任务对任务的所有行设置 `line_hl = "LoopKitSelected"`，并记录
  `selected_line`（`render.lua:211-216`）。
- 高亮区间以 `{line, col_start, col_end, hl_group}` 形式返回（`render.lua:111-118`），
  由 `lua/loop-kit/ui/list.lua` 的 `apply_highlights` 转成 extmark。

调用链与配置面：

| 位置 | 现状 |
| --- | --- |
| `lua/loop-kit/init.lua:24-49` | `defaults()` 维护 UI 默认值（`list_width`、`show_hint`、`icons` 等） |
| `lua/loop-kit/init.lua:58-75` | `M.setup()` 合并默认值后把 UI 选项转发给 `board.setup` |
| `lua/loop-kit/init.lua:78-95` | `M.reset()` 重复同一组转发 |
| `lua/loop-kit/init.lua:219-228` | `open()` 对部分选项做 `opts.x or M._config.x` 回退 |
| `lua/loop-kit/ui/board.lua:63-71` | 看板级 `M.config` 默认值 |
| `lua/loop-kit/ui/board.lua:196-199` | 列表窗口宽度钳制到 `[10, columns-20]`，缓存到 `self.width` |
| `lua/loop-kit/ui/board.lua:214-223` | `list_ui.new` 接收 `icons`、`sort`、`on_select` 等 |
| `lua/loop-kit/ui/list.lua:38-62` | `List.new` 保存图标等选项 |
| `lua/loop-kit/ui/list.lua:130-145` | `List:draw` 调用 `render.list`，处理后追加提示行 |
| `lua/loop-kit/ui/board.lua:314-320` | 窗口尺寸变化时只调整列表窗口宽度 |

辅助能力缺口：`lua/loop-kit/util.lua` 没有按显示宽度计算/截断/补齐的函数；`render.lua` 目前
默认标题单行化后不再按宽度裁剪，超长标题由窗口 `wrap=false` 直接截断。

任务数据没有「开始时间」与「阶段完成度」，因此卡片第三行只使用真实存在的字段
（`tag`、`origin`、`flow`），不展示无法从数据推导的耗时或步数进度。

## 方案

### 1. 配置项

新增 `display_style`，取值 `"compact"`（默认）或 `"card"`：

- `lua/loop-kit/init.lua` 的 `defaults()` 增加 `display_style = "compact"`。
- `M.setup()` 与 `M.reset()` 转发 `display_style = M._config.display_style`。
- `open()` 使用 `display_style = opts.display_style or M._config.display_style`。
- `lua/loop-kit/ui/board.lua` 的 `M.config` 增加同名默认值，`create_ui()` 在
  `list_ui.new` 中传入 `style = self.opts.display_style or M.config.display_style`。
- `ui.list` 原样保存 `style`，在 `draw()` 中传给 `render.list`。
- 非法值在 `render.list` 中统一回退 `compact`（等价于旧行为），不抛错。

### 2. 显示宽度工具

在 `lua/loop-kit/util.lua` 增加三个纯函数，供 `render.lua` 与测试共用：

```lua
--- 终端显示宽度：控制字符 0，CJK/全角 2，其余 1。
function M.display_width(text)

--- 按显示宽度截断，超出时以单个 `…` 收尾；不拆分 UTF-8 字符。
function M.truncate_display(text, limit)

--- 用空格补齐到指定显示宽度；已超宽则原样返回。
function M.pad_display(text, width)
```

宽字符判定覆盖常见区间：`0x1100-0x115F`、`0x2E80-0xA4CF`、`0xAC00-0xD7A3`、
`0xF900-0xFAFF`、`0xFE30-0xFE6F`、`0xFF00-0xFF60`、`0xFFE0-0xFFE6`、
`0x1F300-0x1FAFF`、`0x20000-0x3FFFD`。实现使用标准库 `utf8.codes`，不依赖窗口或 tabstop，
保证 headless 测试结果稳定。

### 3. `render.list` 拆分样式

把现有两行渲染抽成局部函数，`M.list` 只负责遍历、行映射、空行与选中记录：

```lua
local function compact_rows(task, icons)  -- 返回 rows, ranges_by_row
local function card_rows(task, icons, width, selected)  -- 返回 rows, ranges_by_row
```

`M.list` 新增选项：

```lua
function M.list(groups, opts)
  opts = opts or {}
  local icons = opts.icons or M.icons
  local style = opts.style == "card" and "card" or "compact"
  local width = math.max(12, tonumber(opts.width) or 38)
  ...
```

- `width` 仅用于 `card`；`compact` 输出必须与现在逐字节一致。
- 每个任务的每一行都写入 `line_map`；`id_to_line` 仍指向该任务首行。
- `ranges` 改为按行累加：`card_rows` 返回的区间带行内下标，`M.list` 换算成绝对行号。
- 空行规则：`compact` 保留任务间空行；`card` 在任务之间不插空行，但分组标题前的空行保留。
- 选中：`out.selected_line` 始终指向任务首行；`compact` 继续设置 `line_hl`，
  `card` 不设置整行高亮，改由 `card_rows` 通过边框色表达。

### 4. 卡片布局

设列表窗口宽度为 `W`（`W = max(12, 列表窗口宽度)`），卡片总宽即 `W` 个显示单元。

```text
╭─ #232                     ◐ doing ─╮
│ 产出跨包公共 API 支持矩阵并取代…  │
│ feat · human · full                │
╰──────────────────────────────────────╯
```

- 首行：`"╭─ " + id + 填充 + icon + " " + status + "╮"`。
  - id 用 `LoopKitId`；`icon + " " + status` 用 `status_hl(status)`；其余边框字符用边框色。
  - 有状态标签时填充空格（如样例）；空间不足时先裁 id，再退化为 `╭─ <id> ────╮`。
- 第二行：`"│ " + 标题 + 补齐空格 + " │"`；标题先 `one_line`，再按 `W - 4` 显示宽度
  用 `…` 截断；标题文本使用 `LoopKitTitle`。
- 第三行：`"│ " + meta + 补齐空格 + " │"`；meta 由以下片段用 ` · ` 连接：
  - `tag`：为空则省略，使用 `LoopKitTag`；
  - `origin`：为空按 `human`；
  - `flow`：字符串取其名，表显示 `custom`，空值/`default` 显示 `auto`；
  - origin 与 flow 使用 `LoopKitMuted`；放不下时从右往左整段丢弃，最后再截断。
- 第四行：`"╰" + 重复 "─" (W - 2) + "╯"`。
- 边框（首尾行全部、第二/三行的前后 `│` 与空格）统一使用边框色：
  - 选中卡片：`LoopKitCardSelected`（新增，`link = "Special"`）；
  - 未选中卡片：`LoopKitMuted`（`link = "Comment"`）。

`card_rows(task, icons, width, selected)` 内部先确定 `border_hl`，再逐段产出区间；边框区间与
内容区间不重叠，避免同优先级 extmark 的覆盖顺序问题。

### 5. UI 层与窗口宽度

`lua/loop-kit/ui/list.lua`：

- `M.new(opts)` 保存 `self.style = opts.style` 与 `self.width = opts.width`（测试用固定宽度）。
- `List:draw()` 计算实际宽度并在调用 `render.list` 时传入：

```lua
local width = self.width
if self.win and vim.api.nvim_win_is_valid(self.win) then
  width = vim.api.nvim_win_get_width(self.win)
end
rendered = render.list(state:groups(), { ..., style = self.style, width = width })
```

`lua/loop-kit/ui/board.lua` 的 `_resize()` 在宽度确实变化且已有 `self.list` 时补一次
`self:draw()`，让卡片随终端缩放宽窄重新截断。

### 6. 高亮

`lua/loop-kit/highlights.lua` 的 `M.links` 增加：

```lua
LoopKitCardSelected = "Special",
```

既保持 `LoopKitTag` 的语义独立，也允许用户只覆盖卡片选中边框。`LoopKitMuted` 已链接
`Comment`，未选中边框无需新增组。

## 改动范围

lua/loop-kit/render.lua
lua/loop-kit/util.lua
lua/loop-kit/init.lua
lua/loop-kit/highlights.lua
lua/loop-kit/ui/list.lua
lua/loop-kit/ui/board.lua
README.md
doc/loop-kit.txt
tests/unit/util_spec.lua
tests/unit/render_spec.lua
tests/render/list_spec.lua
tests/render/board_spec.lua
tests/integration/public_spec.lua

## 验收标准

- 单测：`tests/unit/util_spec.lua` 覆盖 `display_width`（ASCII、CJK、emoji、组合字符）、
  `truncate_display`（边界 0/1、恰好等于上限、超宽时含 `…`、不拆分字符）、
  `pad_display`（补齐与超宽原样返回）。
- 单测：`tests/unit/render_spec.lua` 覆盖 `card` 四行内容与区间：
  - 首行 id/状态图标/状态名/边框各段高亮正确；
  - 第三行 tag 为空、flow 为字符串/表/空值三种分支；
  - 平铺时相邻卡片之间无空行，`status` 分组时空行仅出现在分组标题前；
  - 选中卡片不产生 `LoopKitSelected` 的 `line_hl`，四行边框区间均为
    `LoopKitCardSelected`；未选中卡片同一批区间均为 `LoopKitMuted`；
  - 选中卡片的 id/状态/标题/tag 区间与未选中时一致；
  - 超长 CJK 标题每行显示宽度等于 `W`，末段以 `…` 收尾；
  - `W = 12` 时仍能产出合法四行，不越界；
  - `style` 缺省/非法值输出与现有 `compact` 完全一致。
- 渲染比对：`tests/render/list_spec.lua` 用 `list_ui.new({ ..., style = "card", width = 40 })`
  检查 buffer 行序、卡片相邻无空行、光标落在卡片首行，以及选中卡片边框 extmark 的
  `hl_group`；`tests/render/board_spec.lua` 验证 `display_style` 通过 `board.setup` 生效。
- 单测（集成用例）：`tests/integration/public_spec.lua` 断言 `defaults()` 含
  `display_style == "compact"`，且 `setup({ display_style = "card" })` 后配置为 `card`。
- 全量：`nvim --headless -u tests/minimal_init.lua -l tests/run.lua` 全部通过；
  `git diff --check` 无输出；`loop-cli validate` 通过。
- 文档：README 与 `doc/loop-kit.txt` 补充 `display_style` 配置示例、card 布局、
  选中边框颜色与 `LoopKitCardSelected → Special` 的说明。

## 待确认决策

无。

## 关联文档

无。
