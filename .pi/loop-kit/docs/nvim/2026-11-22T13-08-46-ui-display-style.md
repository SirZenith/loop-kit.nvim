---
task_id: "#10"
summary: "双栏看板显示样式调整：左窗两行任务、排序轮换与高亮；右窗元数据、描述与提示词分区。"
module: nvim
tag: ux
status: done
updated: 2026-11-22T13:08:46+08:00
verification_levels:
  - unit
  - fake-dom
  - render
deferred_levels:
  - manual
---

# UI 显示样式调整

## 目标

在不改变 loop-cli 数据读写与任务流程的前提下，调整 tab 双栏界面的信息密度与可读性：
左窗突出任务 ID、状态和标题，右窗把任务字段、决策说明与长文本分区展示。

## 左窗

- 每个任务使用两行：第一行 `┌ <id> · <icon> <status> · <tag>`，第二行 `└ <title>`。
  标签为空时省略最后的 ` · <tag>`。
- `┌ ` 与 `└ ` 前缀使用注释色；状态图标和状态名共用任务状态色；标题使用普通文本色。
- 相邻任务之间插入一行空白；分组模式下同组任务之间也保留空白。
- 默认按任务 ID 降序；`S` 依次轮换 `id_desc → id_asc → closed_desc → closed_asc → status`。
  ID 与关闭时间排序为平铺列表；关闭时间为空时排在末尾，相同时间按 ID 升序。
- 新增 `show_winbar` 与 `show_hint` 配置，默认显示，可分别隐藏左窗 winbar 和按键提示行。
- 原 `S = filter_all` 调整为 `A = filter_all`；`s` 仍循环任务筛选。

## 右窗

- 保持整个缓冲区为 Markdown，通过 extmark 对指定字节范围叠加高亮，不限制 Markdown
  自身的解析与高亮。
- 元数据区补充 `docParent`、`specPrompt`、`researchPrompt`、`codePrompt`、`verifyPrompt`、
  `docTaskSplitPrompt`；未设置的路径显示 `(未设置)`。
- `decide` 与 `analysis` 位于元数据末尾，之前用 `---` 分隔；`analysis` 的四项结论使用
  缩进子列表展示。
- `任务描述`、`用户提示词`、`各阶段提示词` 分别作为一级标题；标题后和内容后各保留
  一行空白。阶段提示词用二级标题区分阶段，不额外添加“补充要求”子标题。
- 描述正文继续交给 Markdown 渲染；空内容显示 `暂无内容`。
- 插件加载时注册默认高亮链接，并在 `ColorScheme` 后重新应用。主要链接：
  `LoopKitPending=Comment`、`LoopKitDoing=WarningMsg`、`LoopKitDone=String`、
  `LoopKitBlocked=Constant`；字段键、空值和列表前缀使用 `Comment`。

## 验收

- `nvim --headless -u tests/minimal_init.lua -l tests/run.lua`
  → `207 passed, 0 failed, 207 total`。
- `git diff --check` 通过。
- `loop-cli validate` 通过：共 10 条，未完成 1，可开始 1。
- 覆盖两行列表、平铺与分组排序、关闭时间空值、提示行与 winbar 显隐、右窗字段分区、
  decide/analysis 位置与子列表、默认高亮链接。

## 未包含

本次仅调整显示与交互默认值，不新增提示词编辑功能，也不改变 loop-cli 的任务数据结构。
