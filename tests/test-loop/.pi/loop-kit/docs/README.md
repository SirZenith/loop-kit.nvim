# docs/ —— 实现文档（在途与已完成）

每个子目录是一个模块。实现文档从创建起就落在这里，文件名固定不变；条目完成只把
frontmatter 的 `status` 改为 `archived`，**不移动文件、不改 `doc` 字段、不产生独立的
归档提交**。因此同一模块目录按时间排列，同时包含在途与已完成的实现顺序。

## 内容

- 文件名 `<YYYY-mm-ddTHH-MM-SS>-<slug>.md`。
- 想了解某模块「正在做什么」：读 `status: spec` / `implementing` / `verifying` 的文档。
- 想了解某模块「做过什么、为什么这样做」：读 `status: archived` 的文档；最新的一篇通常
  最接近现状。
- 条目的 `doc` 字段指向这里的文件；`loop-cli show <id>` 可确认。
- 历史报告（设计或重构完成后的结论）同样收在这里。

## 模块

树状清单由人维护；目录行后接 `# 用途`，文件行后接一句内容摘要，不要用表格。

```text
docs/
  core/      # 核心编排器与生命周期
  gui/       # 本地 GUI / 交互层
  providers/ # 远端 provider 与同步
  misc/      # 尚未归模块的新文档（完成前应尽量归位）
```

## 兼容

迁移脚本 `scripts/migrate-docs-stable-paths.mts` 会把历史 `workspace/` 与 `archive/`
文档搬到本目录并改写 `doc` / 链接。旧路径的 `doc` 值仍可读，但新文档一律写
`<loopRoot>/docs/<模块>/`。
