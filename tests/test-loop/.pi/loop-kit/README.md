# 循环数据目录说明

本目录默认落在项目根 `.pi/loop-kit/`，由项目根 `loop.config.json` 的 `loopRoot` 字段指向；改 `loopRoot` 需同时移动目录。

## 怎么跑起来

- `/loop-init`：在本项目铺开骨架（已存在则跳过，`--force` 才覆盖）。
- `/loop-install`：安装用户级 agent profile（已存在不覆盖，`--force` 才刷新）。
- `/loop on`：开始自动循环；缺省只跑到清空，加 `--with-refill` 清空后继续补货。
- `/loop status` / `/loop off`：查看进度 / 中断。
- `/loop-next`：手动推进一条；`/loop-refill`：手动补货一轮。
- `/loop-unblock <id>`：解除指定条目的阻塞（blocked → pending，仅 local 源）。

## 运行期文件

这些文件由 `loop-cli` 读写，**不要手改**（写入口只有 CLI）：

- `LOOP.json`：计划入口。**格式唯一定义**（`LOOP.schema.json` 是规范，机器事实标准在
  `crates/loop-core/src/model.rs`），项目不得覆盖。写入口是 `loop-cli`
  （`add` / `claim` / `done` / `block` / `edit` / `doc`）。
- `loop.meta.json`：条目级附加信息（`doc`、`desc`、`deps`、`blockedReason` 等），由 CLI 维护。
- `TARGETS.md`：推导本项目需求的基本准则——当前最重要的用户体验与功能目标。提出新需求时
  先读它；与其它产品/设计文档冲突时以它为准。
- `schema/loop.config.schema.json`：LOOP 源配置的规范。配置文件本身是项目根的
  `loop.config.json`（**不在本目录**），声明本目录位置与 LOOP 源
  （`provider` = `local` / `gitea` / `github` / `jira` 及参数）。
- `workflow/`：九篇可覆盖的流程标准（`research.md` / `knowledge.md` / `spec.md` / `code.md` /
  `verify.md` / `refill.md` / `manual.md` / `doc-task-split.md` / `decision-question.md`）；另可放 `judge.md`
  （可选，流程判定准则，内容会随判定请求发给外部 `judge` 服务，别写敏感信息）。
  `knowledge` 是 `research` 的附属标准，调研派发时与之一并注入。**均可选、可自定义**：
  缺失时插件使用内置默认。判定、测试、提交、受阻这些环节已由编排器代码实现，不再读文件。
- `.gitignore`：忽略远端快照等机器产物。

## 文档子目录

三处文档都按主题再分一级子目录，文件名一律 `<YYYY-mm-ddTHH-MM-SS>-<slug>.md`
（`knowledge/` 沿用不带时间戳的短标题）。

- `docs/<模块>/`：**实现文档**，同时包含在途与已完成条目；完成只翻 `status`，不移动。
  索引见 [`docs/README.md`](docs/README.md)。
- `knowledge/<域>/`：调研沉淀、可供未来复用的知识。索引见
  [`knowledge/README.md`](knowledge/README.md)。

条目 `doc` 字段是**相对仓库根**的路径，只经 `loop-cli doc <id> --path <路径>` 写入。

## 命名与文档状态约定

- 新实现文档：`docs/<模块>/<时间戳>-<slug>.md`。模块由 spec 阶段判定（kebab-case），
  拿不准就开新模块，别塞进 `misc`。
- 新实现文档必须带 YAML 头（`task_id` / `summary` / `module` / `tag` / `status` / `updated` /
  `verification_levels`，可选 `deferred_levels` 与三类引用），详见 `workflow/spec.md`；
  引用路径一律**仓库根相对**（含 `loop/` 前缀）。
- 完成时：编排器把文档头的 `status` 改为 `archived` 并刷新 `updated`，与实现一起进
  同一个 finalize 提交；**不移动文件、不改 `doc` 字段、不产生独立归档提交**。
  header 读写失败只告警，不阻断 `done`。
- 历史遗留的 `workspace/` / `archive/` 前缀 `doc` 仍可读，完成时同样不移动。
- 索引文件由人维护；机器真源始终是 `LOOP.json` 里的条目状态。
- 各子目录 `README.md` 里的文档清单用树状文件列表（`text` 代码块）书写，不要用表格：
  目录行后接 `# 用途`，文件行后接一句内容摘要。
