---
task_id: "#33"
summary: "标签解析迁移：优先 loop.config.json 顶层 tags，回退 TARGETS.md 小节与内置 7 项；单一入口 + 双文件 mtime 缓存"
module: nvim
tag: refactor
status: spec
updated: 2026-11-27
verification_levels: [unit]
deferred_levels: []
---

# 标签解析迁移：优先 loop.config.json 的 tags

## 目标

对齐上游 loop-kit #378：LOOP 条目的 `tag` 取值集合按三级来源解析——
显式 `loop.config.json` 顶层 `tags` → `TARGETS.md` 的「任务分类（tag）」小节 →
内置 7 项（`feature`/`bugfix`/`refactor`/`ux`/`visual`/`docs`/`chore`）。
本插件用纯 Lua 实现该链（不依赖 `loop-cli tags`），所有 UI 入口走同一解析函数；
修改 config 或 TARGETS.md 后缓存即时失效。本仓库自身配置同步迁移到 config tags。

## 现状

- `lua/loop-kit/kv.lua:7` `M.FALLBACK_TAGS`（内置 7 项）；`:42` `M.parse_tags(content)`
  只扫 H1（`^#%s*`）且标题含「任务分类」的小节，收集反引号列表项；`:64`
  `M.tag_values(loop_root)` 只读 `<loop_root>/TARGETS.md`，解析为空回退内置。
- `lua/loop-kit/edit.lua:140` `M.DEFAULT_TAGS`；`:146` 私有 `read_json(path)`、`:158`
  `loop_root_dir(root, hint)`（已能读 `root/loop.config.json` 的 `loopRoot`）；`:177`
  `M.tag_list(root, loop_root_hint)` 仅按 TARGETS.md mtime 缓存，miss 时调
  `kv.tag_values`；`:196` `M.valid_tag` 遍历 `tag_list` 做成员匹配。
- `lua/loop-kit/ui/board.lua:1184` `_edit_tag` 直接调 `kv.tag_values(loop_root)`，
  绕过 `edit.tag_list` 的缓存，也看不到 config tags——是第二个入口。
- `lua/loop-kit/actions.lua:678-681` 新建任务校验走 `edit.valid_tag`，失败时错误消息
  已列出可选集合（`table.concat(edit.tag_list(...), " / ")`）。
- 本仓库 `loop.config.json` 无 `tags` 字段；`.pi/loop-kit/TARGETS.md:19-29` 有
  「# 任务分类（tag）」小节；`.pi/loop-kit/schema/loop.config.schema.json` 与
  `tests/test-loop/.pi/loop-kit/schema/loop.config.schema.json`（两文件内容相同）
  均无 `tags` 定义。
- 文档旧行为描述：`README.md:256-259`、`doc/loop-kit.txt:189-191`（「tag 须属于
  TARGETS.md 的『任务分类（tag）』集合，解析失败回退内置」）。
- 测试：`tests/unit/kv_spec.lua` 覆盖 `parse_tags`/`tag_values`；
  `tests/unit/edit_spec.lua` 尚未覆盖 `tag_list`/`valid_tag`。

上游参考（外部仓库，仅作语义依据）：`D:/Developer/tools/loop-kit/loop/docs/core/2026-11-27T10-13-11-tag-loop-config-json.md`、`crates/loop-core/src/config.rs`、`loop/schema/loop.config.schema.json:141-165`。

## 方案

### 解析链与接口

1. **`kv.lua` 新增 `M.config_tags(config_path)`**：`io.open` + `pcall(vim.json.decode)`
   读 config；取 `.tags`，必须是数组、长度 ≥ 1、每个元素为 table 且 `name` 是匹配
   `^[a-z0-9][a-z0-9%-]*$` 的字符串（与上游 pattern 一致，Lua 模式 `-` 需转义为 `%-`）。
   文件缺失 / JSON 非法 / 结构任一不合法 → 返回 `nil`（视为未配置，走下一级）。
   合法时返回 `name` 字符串数组（`description` 仅文档用途，不进解析结果）。
2. **`edit.tag_list(root, loop_root_hint)` 实现三级链**（复用现有 `loop_root_dir`）：
   - config 路径 = `root .. "/loop.config.json"`（`root` 为空时跳过 config 级）；
   - `kv.config_tags(cfg)` 非 nil → 用之（严格集合）；
   - 否则 `kv.tag_values(dir)`（TARGETS.md 小节 → 内置）。
   解析结果永远是「生效集合」，`valid_tag` 维持成员匹配语义：显式与回退来源都
   不放行任意 tag，错误消息沿用 actions.lua 现有的可选集合提示。
3. **缓存改为组合 stamp**：`tag_cache` 的 key 改为 config 路径，stamp 为
   `cfg_mtime .. "|" .. targets_mtime`（各自 `sec:nsec`，文件缺失记 `missing`）。
   任一文件变动即失效重解析，满足「改 tags 立即生效」。
4. **单一入口**：`board.lua:_edit_tag` 改为
   `require("loop-kit.edit").tag_list(self.root, self.config and self.config.loop_root_hint)`，
   删除对 `kv.tag_values` 的直调；`actions.lua` 已走 `edit.*`，无需逻辑改动
   （仅在确认无误后从改动范围剔除）。
5. `kv.FALLBACK_TAGS` / `kv.parse_tags` / `kv.tag_values` 行为不变，继续承担
   TARGETS 级与内置回退。

### 配置与 schema

- 两份 `loop.config.schema.json`（`.pi/loop-kit/schema/` 与 `tests/test-loop/` 下）
  的 `properties` 增加 `tags`：`type: array`、`minItems: 1`、items 为 object、
  `required: ["name"]`、`properties.name` 带 pattern `^[a-z0-9][a-z0-9-]*$`、
  `properties.description` 为 string、`additionalProperties: false`。
- 本仓库 `loop.config.json` 增加 `tags`：7 个内置 name + 中文 description
  （沿用 TARGETS.md 现注释文案）；`.pi/loop-kit/TARGETS.md` 删除
  「# 任务分类（tag）」小节（19-29 行）——单一事实源收敛到 config。
- 文档：`README.md` 与 `doc/loop-kit.txt` 的 tag 段落改写为三级解析说明
  （config 优先，TARGETS 小节与内置为回退）。

## 改动范围

- `lua/loop-kit/kv.lua`
- `lua/loop-kit/edit.lua`
- `lua/loop-kit/actions.lua`
- `lua/loop-kit/ui/board.lua`
- `tests/unit/kv_spec.lua`
- `tests/unit/edit_spec.lua`
- `.pi/loop-kit/schema/loop.config.schema.json`
- `tests/test-loop/.pi/loop-kit/schema/loop.config.schema.json`
- `loop.config.json`
- `.pi/loop-kit/TARGETS.md`
- `README.md`
- `doc/loop-kit.txt`

## 验收标准

- [单测] `kv.config_tags` 解析规则 —— `tests/unit/kv_spec.lua` 用临时目录写
  fixture：合法 tags 返回 name 数组；文件缺失、JSON 非法、`tags` 非数组、空数组、
  元素缺 `name`、`name` 含大写/下划线/前导 `-` 均返回 `nil`。
- [单测] `edit.tag_list` 来源优先级 —— `tests/unit/edit_spec.lua` 临时目录同时准备
  config tags 与 TARGETS 小节时返回 config 值；config 非法/缺失时返回 TARGETS 值；
  两者皆无时返回内置 7 项（与 `kv.FALLBACK_TAGS` 相等）。
- [单测] 缓存双文件失效 —— `tests/unit/edit_spec.lua`：连续两次调用命中缓存
  （可用桩/改写文件前后比对）；改写 config 或 TARGETS 任一新内容后再次调用返回新值。
- [单测] `edit.valid_tag` 严格成员匹配 —— `tests/unit/edit_spec.lua`：生效集合外的
  tag（含回退情形）返回 false，集合内返回 true。
- [单测] board 单一入口 —— `tests/unit/` 内断言 `_edit_tag` 不再直调 `kv.tag_values`
  （以 stub `edit.tag_list` 计数或 grep 级测试均可，取项目现有风格）。
- [单测] schema 同步 —— `tests/unit/` 用 `vim.json.decode` 读两份
  `loop.config.schema.json`，断言 `properties.tags.minItems == 1` 且 items 含
  `name` pattern 与 `additionalProperties == false`，两份文件该子树一致。
- [单测] 全量回归 —— `nvim --headless -u tests/minimal_init.lua -l tests/run.lua`
  全绿，且 `git diff --check` 通过。

## 待确认决策

无。条目 desc 已定：config 优先、严格成员校验、本仓库删 TARGETS 小节迁到 config。

## 关联文档

无（无 knowledge/ 与 docs/ 引用；上游语义依据为外部仓库文件，已在「现状」注明路径）。
