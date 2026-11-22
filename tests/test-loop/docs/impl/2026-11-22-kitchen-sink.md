# 全字段示例实现文档

这条文档由 `#1` 的 `doc` 字段引用，用于验证插件详情面板、文档打开动作与编辑回填。

## 目标

- 覆盖 `LOOP.schema.json` 中 task 的全部可选字段。
- 保持插件零运行时依赖。

## 验收

1. `:LoopKit` 打开后能看到 13 条任务。
2. `#1` 详情显示 tag、origin、openAt、closedAt、hash、deps、doc、flow、touch。
3. 编辑 `#1` 的 tag / deps / doc / desc 后写回成功。

```sh
loop-cli --project-root . validate
```
