本文件描述「实现文档」的标准（默认标准；项目可在 `loop/workflow/spec.md` 覆盖）。

把调研结论与本项目实际情况结合，确定**怎么做**，并固化为可据以实现与验收的功能文档。

# 文档头（YAML frontmatter，必写）

文档第一段必须是 YAML 头（两行 `---` 包住），正文从 H1 开始：

> 若当前会话提供 pi-wingman `file-read` 的 `read_frontmatter`，先读 header（返回原始 header 与 `body_start_line`），再决定是否用 `read` 读全文；无 header 时工具会失败，直接 `read` 即可。

```markdown
---
task_id: "#21"
summary: 板级外设人工验收手册：#21 的 9 项真机/人工检查、判据与参数回写
module: agent-keyboard
tag: manual
status: spec
updated: 2026-11-03
verification_levels: [unit, fake-dom]
deferred_levels: [device, manual]
archive_ref:
  - loop/docs/agent-keyboard/2026-11-03T03-01-23-item-3.md
knowledge_ref:
  - loop/knowledge/firmware/kb04-02-peripheral-validation.md
doc_ref:
  - docs/peripheral-verification-log.md
---
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `task_id` | 是 | **必须加双引号**（`#` 在 YAML 里是注释符），值取条目 id，如 `"#21"` |
| `summary` | 是 | 单行、≤120 字、无 Markdown；写「对象 + 结论」，让读者能决定要不要读全文 |
| `module` | 是 | 与正文模块一致（kebab-case），取自编排器给定的文档路径 |
| `tag` | 是 | 条目分类（feature / chore / manual…），取自条目 |
| `status` | 是 | `spec` / `implementing` / `archived` / `obsolete`；spec 阶段写 `spec` |
| `updated` | 是 | `YYYY-MM-DD`；spec 阶段=创建日，归档/改稿时刷新 |
| `verification_levels` | 是 | 行内列表，取值 `unit` / `fake-dom` / `render`；无则 `[]` |
| `deferred_levels` | 否 | 行内列表，取值 `device` / `manual`；缺省等价 `[]` |
| `archive_ref` | 否 | 只列 `docs/` 下的实现文档 |
| `knowledge_ref` | 否 | 只列 `knowledge/` 下的调研文档 |
| `doc_ref` | 否 | 其它项目文档（`docs/`、`resources/` 等） |

硬约束：

- `task_id` 必须带双引号；引用路径一律**仓库根相对**（含循环数据目录前缀，默认 `loop/…`），
  不用 `../`、不写绝对路径、不写裸文件名。
- header 与正文 `## 关联文档` 必须是**同一集合**：header 只放路径（机器索引），正文补「为什么引用」。
- 缺 header 的旧文档视为旧格式，读者照常读全文；不要为此批量迁移。

# 参考知识源：`knowledge/`（重要）

循环数据目录的 `knowledge/` 存放项目外、将来可复用的知识（历次调研沉淀），是**确定实现
方式的首要参考**：

- **先查再设计**：用 `search_loop_knowledge` 按需求关键词检索（返回路径与摘要），命中后完整阅读
  相关文档；有相关文档时，不要凭印象重做调研。
- **以既有结论为基础**：有相关文档时，`## 方案` 必须建立在它之上并引用具体文档，而不是另起一套。
- **标注冲突与更新**：与最新调研或代码现状冲突时说明差异与取舍；必要时更新对应文档
  （保留原结论的来由）。
- 有引用时，knowledge 文档必须列入 `## 关联文档`；已在其中的结论改为引用，避免长篇复述。
- 本轮 prompt 可能附带调研员的最终回复：它是补充线索，与 knowledge 文档或代码冲突时
  以可核实来源为准；只提炼相关结论，不要整段抄进文档。

# 文档位置与命名

- 路径：循环数据目录的 `docs/<模块>/<YYYY-mm-ddTHH-MM-SS>-<slug>.md`
  （`loopRoot` 用 `loop-cli paths` 取）。模块名与时间戳由编排器给定，沿用提示词里的路径。
- `<slug>`：概括性短描述，小写英文短横线分隔。
- 模块清单见 `docs/README.md`；用途是让同一模块的文档聚在一起，拿不准就开新模块，
  不要塞进 `misc`。

# 必含小节（中文）

- `## 目标` —— 要达成的用户可见结果，引用 `TARGETS.md` 相关准则。
- `## 现状` —— 相关代码/界面现状，列出文件路径。
- `## 方案` —— 实现方式与取舍；如做过调研，记录备选方案与选择理由。
- `## 改动范围` —— 本任务可能改到的文件路径 glob，供并发调度判定是否互相覆盖（格式见「改动范围（touch set）」）。
- `## 验收标准` —— 可验证条目，**每条以验证手段档位开头标注**（见下）。
- `## 待确认决策` —— 本阶段无法替用户决定的取舍；每项写成 `- [D1] … [待确认]` 并给出 2–4 个候选方案（没有就写「无」）。后续 `decision-question` 阶段据此向用户确认并写回。
- `## 关联文档` —— 引用的 `knowledge/<域>/` 与 `docs/` 文档（有 knowledge 引用时必须列入；没有产出就留空，不要为凑数引用无关文档）；与文档头的 `archive_ref` / `knowledge_ref` / `doc_ref` 同一集合，正文补一句「为什么引用」。

# 改动范围（touch set）

`## 改动范围` 是必写小节，是**人读来源 + spec 种子输入**：运行时调度、冲突守卫、
verifier 视野与提交门禁只读条目 `touch` 字段，不再从本文档回退解析。spec 成功产出文档后，
仅当条目尚无 `touch` 时把本清单解析结果写入任务；已有值不覆盖，文档不一致只告警。格式：

- 每行一个路径 glob，仓库根相对，用 `/` 分隔；可放在反引号里，也可写成 `-` / `*` 列表。
- `*` 不跨目录，`**` 跨任意目录；`?` 匹配单个非 `/` 字符。
- 大小写敏感；先归一化反斜杠再匹配。
- 示例：

  ```markdown
  ## 改动范围

  - `pi/src/path-glob.ts`
  - `pi/resources/workflow/spec.md`
  - `pi/test/unit/**/*.test.ts`
  ```

- 确实无法确定时写 `unknown`，不要留空或猜一个空文件列表：空节按 `unknown` 处理，
  并发调度会退化成串行（安全方向）。
- 编排器与 coder 用 `loop-cli touch <id> --set <路径...>`（或 `--append` / `--clear`）维护
  条目级写集；可用 `loop-cli touch <id> --import-doc` 一次性回填。本清单只是**人读来源 +
  spec 种子输入**，此后以条目 `touch` 字段为准（旧的「运行时从文档回退」与「追加到文档」
  用法均已移除）。

# 验收标准与验证手段档位

`## 验收标准` 是后续写测试与验收的**唯一依据**，每条都必须在写文档时说清「用什么手段验证」。
目的是堵住把「人工核对」当成免验证退路的做法。

- 档位名固定五个（定义见 `docs/workflow.md` 的「测试与验证档位」）：**单测** / **假 DOM** / **渲染比对** / **真机** / **人工**。
- **标注不出档位的条目不得写进本节**——先设法变成可验证的断言（优先把「看起来只能人工」
  的判断降级为几何 / DOM 断言）；实在不能就走拆分。
- **单测 / 假 DOM / 渲染比对** 档必须写明**具体断言位置与比对对象**（哪个测试文件、什么假件、
  断言什么），不能只写「通过测试」。
- 文档头的 `verification_levels` 只写自动档（unit / fake-dom / render）；**真机 / 人工** 属于延后验收，
  写进 `deferred_levels`（上例 YAML 头即如此）。两者由编排器从机器行回写，不一致时以机器行为准。
- **真机 / 人工** 档：**不写进本轮验收标准**。若本轮尚未开始实现，给出拆项契约
  `SPLIT: impl+manual`（见「拆项契约」）；若实现已在本轮完成，写进 `DEFERRED_LEVELS`。

标注示例：

```markdown
## 验收标准

- [单测] 已完整可见时原地不动 —— 断言于 test/<模块>.test.ts
- [假 DOM] 展开期间内容长高时等到过渡结束 —— 假件：可触发的 transitionend
- [渲染比对] 分组顺序不因改动改变 —— renderToStaticMarkup 逐字节比对（待确认可用）
- [真机] 窄屏下目标不被底栏压住 —— 需真实浏览器（`SPLIT: impl+manual`）
- [人工] 视觉上不出现跳变 —— 需人工核对（`SPLIT: impl+manual`）
```

# 拆项契约（交由编排器执行）

当 spec 判定「实现尚未开始、且验收必须真机/人工」时，在最终回复给出唯一合法值：

    SPLIT: impl+manual

此时 `VERIFICATION_LEVELS` 必须全是自动档、`DEFERRED_LEVELS` 必须非空。编排器会确定性执行：

- `doc-to-tasks` 的文档路径由条目 `doc` 固定：直接在该处创建，不输出 `MODULE`、不做 `git mv`；
  文档已存在时该阶段在开跑时即被冻结跳过。`docParent` 只读参考，缺失只告警。
- 建**实现子项**：`origin: split`、继承 `tag`、`flow: spec-impl`、`deps: []`，立即可被拾取；
  `doc` 指向本篇，由它完成实现与自动档验收。
- 建**人工验收子项**：`status: blocked`、`deps: []`（复用依赖反转模型）。
- 原条目：`status: blocked`、`deps: [实现子项, 人工验收子项]`；两者都 done 后 unblock，
  只归档 + done（finalize-only），**不重跑 spec、不再次拆项**。

不要用散文清单代替 `SPLIT` 行；缺该行时沿用旧行为（本轮不实现，直接拆人工验收）。

以上三条路径统称**依赖反转模型**：人工条目永不被自动循环拾取，等待方向永远是「原条目 → 人工条目」。
**你不改 `status`**。

# 边界

- **缺少功能文档，禁止开始写测试或实现。**
- 只确定实现方式并固化文档：**不实现需求、不改 `status`、不提交**（独立提交
  `docs(planning): add feature spec for <slug>` 由编排器执行）。
- 目标是对项目较大范围的重构时，另行把实现方式与架构精简地写成 `docs/<模块>/<时间戳>-<slug>.md`。
- 不手改 header 的 `status` / `task_id` / `module` / `verification_levels` / `deferred_levels`：
  由编排器按机器行回写；写完只确认与机器行一致。
- 不执行 `git push` 或任何远程写操作。

# 输出契约

最终回复必须包含机器行（编排器据此决定流程与是否拆项）：

    VERIFICATION_LEVELS: unit,fake-dom,render
    DEFERRED_LEVELS: device,manual
    SPLIT: impl+manual

`VERIFICATION_LEVELS` 只列**本轮能自动执行**的档位（`unit`=单测、`fake-dom`=假 DOM、
`render`=渲染比对）；其中出现 `device` / `manual` → 编排器按「需人工验收」拆创建即 blocked 的
人工条目，本轮不实现。该行缺失或无法识别 → 视为 spec 违约：直接 blocked 并要求修正 spec，
**不拆**人工条目。

需要真机 / 人工验收的部分写进 `DEFERRED_LEVELS`（只接受 `device`、`manual`；省略即无）：
实现已在本轮完成时，自动档验收通过后编排器会拆出一条**创建即 blocked、`deps` 为空**的人工验收
条目；原条目改为 blocked 并依赖它，人工验收 `done` 后 unblock，只归档 + done（finalize-only，
不重跑实现）。

`SPLIT` 只在「实现尚未开始且需要真机/人工验收」时出现，唯一合法值是 `impl+manual`；
契约不合法或重复拆项会被编排器直接 block。
