# 开发指南

本文档面向 loop-kit.nvim 的开发者与验收人员，记录测试、provider 验证状态和手工验收流程。

## Provider 验证状态

| provider | 状态 | 说明 |
| --- | --- | --- |
| `local` | 已验证 | `LOOP_KIT_REAL_CLI=1` 下的临时项目集成测试覆盖 paths/add/list/edit/claim/done/block/remove |
| `gitea` | 未验证 | 逻辑走同一 CLI 适配层；需要在测试 issue 仓库上执行下方手工矩阵 |
| `github` | 未验证 | 同上；需要独立测试环境 |
| `jira` | 未验证 | 同上；需要独立测试环境 |

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

- `unit`：纯函数与契约（argv、路径、状态、字段目标解析、命令拼装等）。
- `fake-dom`：用 `tests/fixtures/fake-loop-cli` 记录 argv/stdin，断言精确命令与失败分支。
- `render`：在真实 headless buffer/window 中验证布局、导航、筛选与编辑 buffer 生命周期。
- `integration`：公开命令/API、健康检查与可选的真实 local CLI 闭环。
- `LOOP_KIT_REAL_CLI=1` 才会运行真实 CLI 用例；未设置时该用例显示为 skip。

CI（`.gitea/workflows/nvim.yml`）在 Ubuntu runner 上安装固定版本的 Neovim，
运行上面的默认测试与 `git diff --check`，不访问任何真实 LOOP 服务。

## 验证边界

- 远端写操作的真实行为尚未在本仓库的自动化测试中覆盖（见 provider 矩阵）；
  gitea/github/jira 需要按下列手工矩阵验证后才能声明通过。
- 未在 Windows 上验证；插件只使用跨平台 Neovim API，但仍以 macOS/Linux 实测为准。

## 手工验收矩阵（deferred，不阻塞自动化）

1. local 项目：浏览、筛选、编辑多段 desc、新增、claim/done/block/remove，确认外部
   `loop-cli show/list` 与插件一致。
2. gitea 测试项目：无缓存启动、后台同步、字段编辑、flow/private/touch/meta、
   移出循环，确认 issue 保留且 `loop:todo` 标签被摘除。
3. 两个客户端同时编辑同一远端任务：后到者收到冲突，插件保留输入且不自动覆盖。
4. 模拟无 token、断网、无权限、非法 LOOP 数据，核对提示与旧快照可用性。
5. github/jira 仅在具备安全测试环境时执行同一矩阵，结果补入上表。
