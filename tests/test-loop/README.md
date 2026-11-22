# test-loop 测试夹具

这是一个 **local provider** 的 LOOP 项目，专门用于手工测试 `loop-kit.nvim` 的列表、详情、新建、编辑与高级字段操作。

## 打开方式

```sh
cd temp/test-loop
nvim            # 然后执行 :LoopKit
```

也可以在仓库根目录执行：

```sh
LOOP_PROJECT_ROOT=temp/test-loop nvim +LoopKit
```

## 任务覆盖

` .pi/loop-kit/LOOP.json ` 中的 13 条任务覆盖了 `LOOP.schema.json` 的 task 字段与主要取值：

| 覆盖点 | 条目 |
| --- | --- |
| 全部可选字段（doc / docParent / 5 个 prompt / userPrompt / stagePrompt / touch） | `#1` |
| 四种状态 `pending` / `doing` / `done` / `blocked` | `#1`–`#4`、`#12` |
| 三种 `origin`：`human` / `refill` / `split` | `#1`、`#2`、`#3` |
| `closedAt` / `hash` 已填写 | `#3`、`#12` |
| 可空字段显式 `null` | `#9` |
| 缺失可选字段的兜底 | `#10` |
| `deps`：`null` / 单条 / 多条 / 空数组 | `#1`、`#2`、`#3`、`#11` |
| `touch`：glob 数组 / 精确路径 / `null` / 缺失键 | `#1`、`#2`、`#3`、`#8` |
| `flow`：六个内置档位全覆盖 | `#1`、`#2`、`#3`、`#4`、`#7`、`#8` |
| `flow`：自定义名称（`flows` 表） | `#5`、`#13` |
| `flow`：显式 stage 数组 | `#6` |
| `flow`：`null` / 缺失 | `#9`、`#10` |
| `stagePrompt`：多键 / 单键 / `null` | `#1`、`#11`、`#9` |
| 七种 `tag` 全覆盖 | `feature` `bugfix` `refactor` `ux` `visual` `docs` `chore` |

## 引用文件

`doc` / `docParent` / 各 prompt 字段指向本目录下真实存在的文件：

- `docs/impl/`、`docs/research/`、`docs/reference/`
- `prompts/`

## 未覆盖的字段

`loop.meta.json` 里的 `blockedReason`、`isPrivateDesc`、`branch`、`baseSha` 只对远端源（gitea/github/jira）生效；local provider 的 `loop-cli private` / `loop-cli meta` 会明确拒绝。若要测试这些字段的渲染与 `P` / `M` 动作，需要一个配置为远端 provider 的独立夹具。

## 校验

```sh
loop-cli --project-root . validate
loop-cli --project-root . --json list --no-sync
```
