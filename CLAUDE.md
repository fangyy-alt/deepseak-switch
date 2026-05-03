# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中工作时提供指导。

## 用户角色
使用的用户是一个产品经理，对于技术开发方面的内容不太了解，对话时不要使用非常专业的技术语言，尽量使用生活化语言进行描述。涉及到相关的技术内容时，最好附带上一些解释说明。

## 仓库简介

一个用于在 Anthropic 和 DeepSeek 兼容端点之间切换 Claude Code API 后端的单脚本工具（`switch-deepseek.sh`），支持安全回滚。两份 `.md` 文件为设计文档（规格说明和技术文档），非交付产物。

## 运行脚本

```bash
./switch-deepseek.sh status    # 查看当前状态（只读）
./switch-deepseek.sh switch    # 将 settings.json 切换为 DeepSeek 配置
./switch-deepseek.sh restore   # 从备份恢复
```

**依赖：** 必须安装 `jq`。

## 关键文件

| 文件 | 用途 |
|------|------|
| `switch-deepseek.sh` | 交付产物 — 全部逻辑均在此文件中 |
| `~/.claude/settings.json` | 脚本唯一修改的文件 |
| `~/.claude/settings.json.deepseek-switch.backup` | 首次 `switch` 时创建的唯一备份 |
| `~/.claude/deepseek-key` | DeepSeek API 密钥（运行时读取，永不提交） |

## 硬编码常量（脚本顶部）

- `DEEPSEEK_BASE_URL` — `https://api.deepseek.com/anthropic`
- `DEEPSEEK_MODEL` — `DeepSeek-V4-pro[1m]`
- 使用的认证字段：`ANTHROPIC_AUTH_TOKEN`（非 `ANTHROPIC_API_KEY`）

## 设计约束

**仅做字段级 patch，绝不整文件模板替换。** `switch` 使用 `jq` 仅更新 `env` 中的三个字段（`ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`ANTHROPIC_AUTH_TOKEN`）。其他所有字段（`statusLine`、`hooks`、`permissions`、`enabledPlugins`、代理变量、顶层 `model`、`ANTHROPIC_DEFAULT_*`）均原样保留。

**单备份文件，绝不覆盖。** 备份保存的是首次切换前的原始配置。后续 `switch` 调用会跳过重复备份并给出警告。`restore` 执行完整文件替换 — 不做字段级合并。

**仅使用原子写入。** 所有写入都通过临时文件 + `mv` 替换完成。禁止直接原地编辑或使用 `sed`/`grep` 方式修改 JSON。

**三态检测。** `status` 根据 `ANTHROPIC_BASE_URL` 和 `ANTHROPIC_MODEL` 是否匹配硬编码常量，输出 `claude-like`、`deepseek-like` 或 `unknown`。此判定仅作参考 — 不会阻止任何命令执行。

**不扩大范围。** 此脚本必须保持为单文件工具。不得添加：多 provider、数据库状态、MCP 处理、代理接管、交互式菜单或 `~/.claude.json` 修改。
