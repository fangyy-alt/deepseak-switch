# DeepSeek 配置切换工具

在 Claude Code 的 Anthropic 接口和 DeepSeek 接口之间一键切换，带可视化 Web 界面。

## 快速开始

### macOS / Linux

打开终端，粘贴以下命令：

```bash
git clone https://github.com/fangyy-alt/deepseak-switch.git
cd deepseak-switch
bash install.sh
```

### Windows

Windows 需要先安装 [Git for Windows](https://git-scm.com/download/win)（安装时一路默认即可）。

安装完成后，打开「Git Bash」（在开始菜单中搜索），粘贴以下命令：

```bash
git clone https://github.com/fangyy-alt/deepseak-switch.git
cd deepseak-switch
bash install.sh
```

> **注意：** 请使用 Git Bash 运行，不要用 PowerShell 或命令提示符（cmd），否则脚本无法执行。

---

脚本会自动完成：
- 检查并安装所需依赖（Flask、jq）
- 引导你输入 DeepSeek API Key
- 启动本地 Web 服务
- 自动打开浏览器

浏览器打开后即可使用，无需其他操作。

## 使用前提

- 已安装 [Claude Code](https://claude.ai/code)（需要存在 `~/.claude/settings.json`）
- 有 DeepSeek API Key（可在 [platform.deepseek.com](https://platform.deepseek.com) 注册获取）

## 手动停止

在终端按 `Ctrl+C` 即可停止服务。

## 功能说明

| 操作 | 效果 |
|------|------|
| 切换到 DeepSeek | 将 Claude Code 的 API 请求转发到 DeepSeek |
| 恢复原始配置 | 还原切换前的配置（首次切换时自动备份） |

切换只修改 `~/.claude/settings.json` 中的三个字段，不影响其他配置。

## 也可以用命令行（macOS / Linux / Git Bash）

```bash
./switch-deepseek.sh status    # 查看当前状态
./switch-deepseek.sh switch    # 切换到 DeepSeek
./switch-deepseek.sh restore   # 恢复原始配置
```
