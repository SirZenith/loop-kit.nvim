# knowledge 文档规范

本文件既是规范也是模板：`loop/knowledge/<域>/<slug>.md` 的调研知识文档必须以 YAML 头开始，
让 `search_loop_knowledge` 只读文件头即可返回可靠摘要，也让索引生成器无需猜测。

## 文档头

```yaml
---
summary: 单行、≤120 字、无 Markdown，写「对象 + 结论」
domain: pi
tags: [node, runtime, engines]
updated: 2026-11-16
source: https://nodejs.org/api/
---
```

| 字段 | 必填 | 语义 |
| --- | --- | --- |
| `summary` | 是 | 唯一摘要事实源；单行、≤120 字、不含 Markdown；写「对象 + 结论」 |
| `domain` | 是 | 与所在目录名一致（如 `loop/knowledge/pi/` → `pi`） |
| `tags` | 是 | 行内列表，可为 `[]`；用于检索打分 |
| `updated` | 是 | `YYYY-MM-DD`；内容有实质修改时刷新 |
| `source` | 否 | 外部一手来源（URL 或文档名） |

不要求实现文档头的 `task_id` / `status` / `verification_levels`：调研知识没有条目生命周期，
也不单独验收。

```md
---
summary: Node 运行时下限由 pi 包 engines 约束
domain: pi
tags: [node, runtime]
updated: 2026-11-16
---

# Node 运行时下限

正文……
```

## 摘要规则

- 只写结论与对象，不写「本文调研了……」；`summary` 与索引 README 的 `#` 注释同源。
- 保持单行：换行、制表符会破坏树形索引与搜索输出。
- 需要 Markdown 强调时用普通文字；`search_loop_knowledge` 返回的是纯文本摘要。

## 索引与校验（维护者，不要求调研者执行）

- `loop/knowledge/README.md` 是生成物：改完文档后运行
  `node scripts/gen-knowledge-index.mts`，不要手改。
- `node scripts/gen-knowledge-index.mts --check` 与 `pi/test/unit/docs-consistency.test.ts`
  会拒绝「头不合法」或「README 与生成结果不一致」的提交。
- 存量文档由一次性脚本 `node scripts/migrate-knowledge-headers.mts --apply` 补头；
  脚本默认 dry-run，已有头的文件会被跳过。
