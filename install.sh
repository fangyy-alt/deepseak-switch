#!/bin/bash
set -euo pipefail

# ============================================================
# DeepSeek 配置切换工具 — 一键启动脚本
# ============================================================

PORT=8080
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

echo ""
echo "  DeepSeek 配置切换工具"
echo "  ─────────────────────"
echo ""

# ── 1. 检查 Python3 ──────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    error "未找到 Python3。请先安装：https://www.python.org/downloads/"
fi
info "Python3 已就绪：$(python3 --version)"

# ── 2. 检查 jq ───────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    warn "未找到 jq，正在尝试自动安装..."
    if command -v brew &>/dev/null; then
        brew install jq
        info "jq 安装完成"
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y jq
        info "jq 安装完成"
    else
        error "无法自动安装 jq。请手动安装后重试：\n  Mac: brew install jq\n  Linux: sudo apt install jq"
    fi
else
    info "jq 已就绪"
fi

# ── 3. 安装 Flask ────────────────────────────────────────────
if ! python3 -c "import flask" &>/dev/null; then
    warn "未找到 Flask，正在安装..."
    python3 -m pip install flask --quiet
    info "Flask 安装完成"
else
    info "Flask 已就绪"
fi

# ── 4. 检查 DeepSeek 密钥文件 ────────────────────────────────
DEEPSEEK_KEY_FILE="$HOME/.claude/deepseek-key"
if [ ! -f "$DEEPSEEK_KEY_FILE" ]; then
    warn "未找到 DeepSeek 密钥文件：$DEEPSEEK_KEY_FILE"
    echo ""
    echo "  请输入你的 DeepSeek API Key（输入后按回车）："
    echo "  （Key 以 sk- 开头，可在 https://platform.deepseek.com 获取）"
    echo ""
    read -r -p "  API Key: " user_key
    if [ -z "$user_key" ]; then
        warn "未输入 API Key，切换功能将无法使用（可稍后手动写入 $DEEPSEEK_KEY_FILE）"
    else
        mkdir -p "$HOME/.claude"
        printf '%s' "$user_key" > "$DEEPSEEK_KEY_FILE"
        chmod 600 "$DEEPSEEK_KEY_FILE"
        info "API Key 已保存到 $DEEPSEEK_KEY_FILE"
    fi
else
    info "DeepSeek 密钥已就绪"
fi

# ── 5. 检查端口是否被占用 ─────────────────────────────────────
if lsof -iTCP:"$PORT" -sTCP:LISTEN &>/dev/null 2>&1; then
    warn "端口 $PORT 已被占用，尝试停止旧进程..."
    lsof -iTCP:"$PORT" -sTCP:LISTEN -t | xargs kill -9 2>/dev/null || true
    sleep 1
fi

# ── 6. 启动服务 ──────────────────────────────────────────────
echo ""
info "正在启动 Web 服务（端口 $PORT）..."

cd "$SCRIPT_DIR"
python3 app.py &
APP_PID=$!

# 等待服务就绪（最多 10 秒）
for i in $(seq 1 20); do
    if curl -s "http://127.0.0.1:$PORT/" &>/dev/null; then
        break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        error "服务启动失败，请检查 app.py 是否正常"
    fi
    sleep 0.5
done

info "服务已启动：http://127.0.0.1:$PORT"

# ── 7. 打开浏览器 ────────────────────────────────────────────
echo ""
if command -v open &>/dev/null; then
    open "http://127.0.0.1:$PORT"
    info "已自动打开浏览器"
elif command -v xdg-open &>/dev/null; then
    xdg-open "http://127.0.0.1:$PORT"
    info "已自动打开浏览器"
else
    warn "请手动打开浏览器，访问：http://127.0.0.1:$PORT"
fi

echo ""
echo "  ─────────────────────────────────────────"
echo "  服务运行中，按 Ctrl+C 可停止"
echo "  ─────────────────────────────────────────"
echo ""

# 等待用户中断
trap "echo ''; info '服务已停止'; kill $APP_PID 2>/dev/null || true; exit 0" INT TERM
wait "$APP_PID"
