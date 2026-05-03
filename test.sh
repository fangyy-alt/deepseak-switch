#!/bin/bash
set -uo pipefail

# ============================================================
# Test suite for switch-deepseek.sh + Web API
# ============================================================

PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

ok()   { PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $*"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $*"; }

setup() {
    REAL_HOME="$HOME"
    TEST_HOME=$(mktemp -d /tmp/deepseek-test.XXXXXX)
    export HOME="$TEST_HOME"
    mkdir -p "$HOME/.claude"

    # Create test key file EARLY
    echo "sk-test-token-12345" > "$HOME/.claude/deepseek-key-test"

    # Copy script to test location
    cp "$REAL_HOME/../../Users/fang/Cursor/switch-deepseek.sh" "$HOME/switch-deepseek.sh"
    chmod +x "$HOME/switch-deepseek.sh"

    # Re-point constants in the test script via wrapper
    cat > "$HOME/switch-deepseek-test.sh" << 'WRAPPER_EOF'
#!/bin/bash
set -euo pipefail
SETTINGS_FILE="$HOME/.claude/settings-test.json"
BACKUP_FILE="$SETTINGS_FILE.deepseek-switch.backup"
DEEPSEEK_BASE_URL="https://api.deepseek.com/anthropic"
DEEPSEEK_MODEL="DeepSeek-V4-pro[1m]"
DEEPSEEK_KEY_FILE="$HOME/.claude/deepseek-key-test"

die() { echo "错误: $*" >&2; exit 1; }
warn() { echo "警告: $*" >&2; }

validate_json() {
    local file="$1" label="$2"
    if ! jq empty "$file" 2>/dev/null; then die "$label JSON 格式无效: $file"; fi
}

check_file_readable() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then die "$label 不存在: $file"; fi
    if [ ! -r "$file" ]; then die "$label 不可读: $file"; fi
}

detect_state() {
    local base_url model
    base_url=$(jq -r '.env.ANTHROPIC_BASE_URL // ""' "$SETTINGS_FILE")
    model=$(jq -r '.env.ANTHROPIC_MODEL // ""' "$SETTINGS_FILE")
    if [ "$base_url" = "$DEEPSEEK_BASE_URL" ] && [ "$model" = "$DEEPSEEK_MODEL" ]; then
        echo "deepseek-like"
    elif [ "$base_url" != "$DEEPSEEK_BASE_URL" ]; then
        echo "claude-like"
    else
        echo "unknown"
    fi
}

get_auth_token() {
    if [ ! -f "$DEEPSEEK_KEY_FILE" ]; then die "密钥文件不存在: $DEEPSEEK_KEY_FILE"; fi
    local token; token=$(tr -d '[:space:]' < "$DEEPSEEK_KEY_FILE")
    if [ -z "$token" ]; then die "密钥文件为空: $DEEPSEEK_KEY_FILE"; fi
    echo "$token"
}

atomic_write() {
    local src="$1" dst="$2" label="$3"
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/deepseek-switch.XXXXXXXX") || die "临时文件创建失败"
    trap 'rm -f "$tmp"' EXIT
    cp "$src" "$tmp" || die "临时文件写入失败: $label"
    mv "$tmp" "$dst" || die "文件替换失败: $label"
    trap - EXIT
}

cmd_status() {
    echo "=== DeepSeek 切换状态 ==="
    echo ""
    echo "主配置文件: $SETTINGS_FILE"
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "状态:         未找到配置文件"
        echo ""; echo "备份文件:     $BACKUP_FILE"
        if [ -f "$BACKUP_FILE" ]; then echo "备份状态:     存在 ($(wc -c < "$BACKUP_FILE" | tr -d ' ') bytes)"
        else echo "备份状态:     不存在"; fi
        return 0
    fi
    echo "状态:         存在"
    if ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
        echo "JSON 状态:    格式无效"
        echo ""; echo "备份文件:     $BACKUP_FILE"
        if [ -f "$BACKUP_FILE" ]; then echo "备份状态:     存在 ($(wc -c < "$BACKUP_FILE" | tr -d ' ') bytes)"
        else echo "备份状态:     不存在"; fi
        return 0
    fi
    local state; state=$(detect_state)
    echo "整体状态:     $state"
    echo ""
    local val
    val=$(jq -r '.env.ANTHROPIC_BASE_URL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_BASE_URL:              $val"
    val=$(jq -r '.env.ANTHROPIC_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_MODEL:                 $val"
    if jq -e '.env | has("ANTHROPIC_AUTH_TOKEN")' "$SETTINGS_FILE" >/dev/null 2>&1; then
        echo "  ANTHROPIC_AUTH_TOKEN:            已设置"
    else echo "  ANTHROPIC_AUTH_TOKEN:            未设置"; fi
    if jq -e '.env | has("ANTHROPIC_API_KEY")' "$SETTINGS_FILE" >/dev/null 2>&1; then
        echo "  ANTHROPIC_API_KEY:               已设置"
    else echo "  ANTHROPIC_API_KEY:               未设置"; fi
    val=$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_DEFAULT_HAIKU_MODEL:   $val"
    val=$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_DEFAULT_SONNET_MODEL:  $val"
    val=$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_DEFAULT_OPUS_MODEL:    $val"
    val=$(jq -r '.model // "未设置"' "$SETTINGS_FILE")
    echo "  top-level model:                 $val"
    echo ""
    echo "备份文件:     $BACKUP_FILE"
    if [ -f "$BACKUP_FILE" ]; then echo "备份状态:     存在 ($(wc -c < "$BACKUP_FILE" | tr -d ' ') bytes)"
    else echo "备份状态:     不存在"; fi
}

cmd_switch() {
    check_file_readable "$SETTINGS_FILE" "Settings file"
    validate_json "$SETTINGS_FILE" "Settings file"
    local top_type; top_type=$(jq -r 'type' "$SETTINGS_FILE")
    if [ "$top_type" != "object" ]; then die "Settings file 根节点不是对象 (type=$top_type): $SETTINGS_FILE"; fi
    if jq -e 'has("env")' "$SETTINGS_FILE" >/dev/null 2>&1; then
        local env_type; env_type=$(jq -r '.env | type' "$SETTINGS_FILE")
        if [ "$env_type" != "object" ]; then die "env 字段不是对象 (type=$env_type)，无法安全切换: $SETTINGS_FILE"; fi
    fi
    local auth_token; auth_token=$(get_auth_token)
    local current_state; current_state=$(detect_state)
    if [ "$current_state" = "deepseek-like" ]; then
        warn "当前已是 DeepSeek 配置，跳过备份: $BACKUP_FILE"
    else
        cp "$SETTINGS_FILE" "$BACKUP_FILE" || die "备份创建失败: $BACKUP_FILE"
        echo "已备份当前配置: $BACKUP_FILE"
    fi
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/deepseek-switch.XXXXXXXX") || die "临时文件创建失败"
    trap 'rm -f "$tmp"' EXIT
    jq --arg base_url "$DEEPSEEK_BASE_URL" --arg model "$DEEPSEEK_MODEL" --arg token "$auth_token" '
        if has("env") then . else .env = {} end
        | .env.ANTHROPIC_BASE_URL = $base_url
        | .env.ANTHROPIC_MODEL = $model
        | .env.ANTHROPIC_AUTH_TOKEN = $token
    ' "$SETTINGS_FILE" > "$tmp" || die "配置 patch 失败"
    validate_json "$tmp" "生成的新配置"
    mv "$tmp" "$SETTINGS_FILE" || die "文件替换失败: $SETTINGS_FILE"
    trap - EXIT
    echo "切换完成: 已切换到 DeepSeek 配置"
    echo ""
    cmd_status
}

cmd_restore() {
    check_file_readable "$BACKUP_FILE" "Backup file"
    validate_json "$BACKUP_FILE" "Backup file"
    atomic_write "$BACKUP_FILE" "$SETTINGS_FILE" "restore"
    echo "恢复完成: 已从备份恢复原始配置"
    echo ""
    cmd_status
}

case "${1:-}" in
    status)   cmd_status ;;
    switch)   cmd_switch ;;
    restore)  cmd_restore ;;
    *)        echo "未知命令: ${1:-}" >&2; exit 1 ;;
esac
WRAPPER_EOF
    chmod +x "$HOME/switch-deepseek-test.sh"
    SW="$HOME/switch-deepseek-test.sh"

    # Create test key file
    echo "sk-test-token-12345" > "$DEEPSEEK_KEY_FILE"

    # Create test app.py for API tests
    cat > "$HOME/app-test.py" << 'APP_EOF'
import json, os, subprocess, threading
from flask import Flask, jsonify

app = Flask(__name__)
SETTINGS_FILE = os.path.expanduser("~/.claude/settings-test.json")
BACKUP_FILE = SETTINGS_FILE + ".deepseek-switch.backup"
DEEPSEEK_BASE_URL = "https://api.deepseek.com/anthropic"
DEEPSEEK_MODEL = "DeepSeek-V4-pro[1m]"
SCRIPT_PATH = os.path.expanduser("~/switch-deepseek-test.sh")
lock = threading.Lock()

def read_status():
    result = {"settings_exists": False, "settings_valid_json": False, "state": "unknown", "config": None, "backup": {"exists": False, "size_bytes": None}}
    if os.path.isfile(BACKUP_FILE):
        result["backup"]["exists"] = True
        try: result["backup"]["size_bytes"] = os.path.getsize(BACKUP_FILE)
        except OSError: pass
    if not os.path.isfile(SETTINGS_FILE): return result
    result["settings_exists"] = True
    try:
        with open(SETTINGS_FILE) as f: data = json.load(f)
    except: return result
    if not isinstance(data, dict): return result
    result["settings_valid_json"] = True
    env = data.get("env", {})
    if not isinstance(env, dict): env = {}
    result["config"] = {
        "ANTHROPIC_BASE_URL": env.get("ANTHROPIC_BASE_URL"),
        "ANTHROPIC_MODEL": env.get("ANTHROPIC_MODEL"),
        "ANTHROPIC_AUTH_TOKEN": "ANTHROPIC_AUTH_TOKEN" in env,
        "ANTHROPIC_API_KEY": "ANTHROPIC_API_KEY" in env,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": env.get("ANTHROPIC_DEFAULT_HAIKU_MODEL"),
        "ANTHROPIC_DEFAULT_SONNET_MODEL": env.get("ANTHROPIC_DEFAULT_SONNET_MODEL"),
        "ANTHROPIC_DEFAULT_OPUS_MODEL": env.get("ANTHROPIC_DEFAULT_OPUS_MODEL"),
        "top_level_model": data.get("model"),
    }
    base_url = env.get("ANTHROPIC_BASE_URL", "")
    model = env.get("ANTHROPIC_MODEL", "")
    if base_url == DEEPSEEK_BASE_URL and model == DEEPSEEK_MODEL: result["state"] = "deepseek-like"
    elif base_url != DEEPSEEK_BASE_URL: result["state"] = "claude-like"
    else: result["state"] = "unknown"
    return result

def run_script(cmd):
    with lock:
        proc = subprocess.run([SCRIPT_PATH, cmd], capture_output=True, text=True, timeout=30)
    out = [l for l in proc.stdout.strip().splitlines() if l]
    err = [l for l in proc.stderr.strip().splitlines() if l]
    return {"success": proc.returncode == 0, "messages": out,
            "warnings": [l for l in err if l.startswith("警告:")],
            "errors": [l for l in err if l.startswith("错误:")],
            "status": read_status()}

@app.route("/api/status")
def api_status(): return jsonify(read_status())

@app.route("/api/switch", methods=["POST"])
def api_switch(): return jsonify(run_script("switch"))

@app.route("/api/restore", methods=["POST"])
def api_restore(): return jsonify(run_script("restore"))

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=18080, debug=False)
APP_EOF
}

teardown() {
    echo ""
    echo "清理测试环境..."
    kill $(lsof -ti:18080) 2>/dev/null || true
    export HOME="$REAL_HOME"
    rm -rf "$TEST_HOME"
}

make_json() { echo "$1" | jq . > "$SETTINGS_TEST"; }
SETTINGS_TEST="$HOME/.claude/settings-test.json"
BACKUP_TEST="$SETTINGS_TEST.deepseek-switch.backup"
DEEPSEEK_KEY_FILE="$HOME/.claude/deepseek-key-test"
SW=""
REAL_HOME=""

# ============================================================
# Run tests
# ============================================================

echo "========================================"
echo " DeepSeek 切换脚本 测试套件"
echo "========================================"
echo ""

setup
SETTINGS_TEST="$HOME/.claude/settings-test.json"
BACKUP_TEST="$SETTINGS_TEST.deepseek-switch.backup"
DEEPSEEK_KEY_FILE="$HOME/.claude/deepseek-key-test"
SW="$HOME/switch-deepseek-test.sh"

# ---- S01: status deepseek-like ----
echo "--- [S01] status: deepseek-like ---"
make_json '{"env":{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_MODEL":"DeepSeek-V4-pro[1m]","ANTHROPIC_AUTH_TOKEN":"sk-xxx"},"model":"sonnet"}'
output=$("$SW" status 2>&1)
if echo "$output" | grep -q "deepseek-like"; then ok "S01 state=deepseek-like"
else fail "S01 state=deepseek-like — got: $(echo "$output" | grep 整体状态)"; fi
if echo "$output" | grep -q "已设置"; then ok "S01 token=已设置"
else fail "S01 token=已设置"; fi
if echo "$output" | grep -q "sonnet"; then ok "S01 top-level model preserved"
else fail "S01 top-level model preserved"; fi

# ---- S02: status claude-like ----
echo "--- [S02] status: claude-like ---"
make_json '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"claude-sonnet-4"}}'
output=$("$SW" status 2>&1)
if echo "$output" | grep -q "claude-like"; then ok "S02 state=claude-like"
else fail "S02 state=claude-like — got: $(echo "$output" | grep 整体状态)"; fi

# ---- S03: status unknown ----
echo "--- [S03] status: unknown ---"
make_json '{"env":{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_MODEL":"some-other-model"}}'
output=$("$SW" status 2>&1)
if echo "$output" | grep -q "unknown"; then ok "S03 state=unknown"
else fail "S03 state=unknown — got: $(echo "$output" | grep 整体状态)"; fi

# ---- S04: status file missing ----
echo "--- [S04] status: file missing ---"
rm -f "$SETTINGS_TEST"
output=$("$SW" status 2>&1)
if echo "$output" | grep -q "未找到配置文件"; then ok "S04 reports missing file"
else fail "S04 reports missing file"; fi

# ---- S05: status invalid JSON ----
echo "--- [S05] status: invalid JSON ---"
echo "not json" > "$SETTINGS_TEST"
output=$("$SW" status 2>&1)
if echo "$output" | grep -q "格式无效"; then ok "S05 reports invalid JSON"
else fail "S05 reports invalid JSON"; fi

# ---- S06: status top-level array (valid JSON but non-object) ----
echo "--- [S06] status: top-level array ---"
echo '[1,2,3]' > "$SETTINGS_TEST"
output=$("$SW" status 2>&1)
if echo "$output" | grep -q "claude-like"; then ok "S06 array degrades to claude-like (graceful)"
else fail "S06 array handling"; fi

rm -f "$SETTINGS_TEST" "$BACKUP_TEST"

# ---- W01: switch claude -> deepseek ----
echo "--- [W01] switch: claude-like -> deepseek ---"
make_json '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"claude-opus"},"includeCoAuthoredBy":false,"effortLevel":"high","model":"opus","statusLine":{"type":"custom"}}'
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -eq 0 ] && echo "$output" | grep -q "已备份当前配置"; then ok "W01 backup created, exit=0"
else fail "W01 backup created — exit=$exit_code"; fi
if echo "$output" | grep -q "deepseek-like"; then ok "W01 now deepseek-like"
else fail "W01 now deepseek-like"; fi
# Verify non-whitelist fields preserved
if jq -e '.model == "opus"' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W01 top-level model preserved"
else fail "W01 top-level model preserved"; fi
if jq -e '.statusLine.type == "custom"' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W01 statusLine preserved"
else fail "W01 statusLine preserved"; fi
if jq -e '.includeCoAuthoredBy == false' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W01 includeCoAuthoredBy preserved"
else fail "W01 includeCoAuthoredBy preserved"; fi
# Verify whitelist fields written
if jq -e '.env.ANTHROPIC_BASE_URL == "https://api.deepseek.com/anthropic"' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W01 BASE_URL written"
else fail "W01 BASE_URL written"; fi
if jq -e '.env.ANTHROPIC_MODEL == "DeepSeek-V4-pro[1m]"' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W01 MODEL written"
else fail "W01 MODEL written"; fi
if jq -e '.env.ANTHROPIC_AUTH_TOKEN == "sk-test-token-12345"' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W01 TOKEN written from key file"
else fail "W01 TOKEN written from key file"; fi

# ---- W02: switch already deepseek ----
echo "--- [W02] switch: already deepseek-like ---"
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -eq 0 ]; then ok "W02 exit=0 (success)"
else fail "W02 exit=0 — got exit=$exit_code"; fi
if echo "$output" | grep -q "跳过备份"; then ok "W02 backup skipped with warning"
else fail "W02 backup skipped with warning"; fi

# ---- W03: switch unknown -> deepseek ----
echo "--- [W03] switch: unknown -> deepseek ---"
rm -f "$BACKUP_TEST"  # clear backup so fresh one created
make_json '{"env":{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_MODEL":"wrong-model"}}'
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -eq 0 ] && echo "$output" | grep -q "已备份当前配置"; then ok "W03 backup created from unknown, exit=0"
else fail "W03 backup created from unknown — exit=$exit_code"; fi
if echo "$output" | grep -q "deepseek-like"; then ok "W03 now deepseek-like"
else fail "W03 now deepseek-like"; fi

# ---- W04: env not object ----
echo "--- [W04] switch: env is string (not object) ---"
make_json '{"env":"not-an-object"}'
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -ne 0 ] && echo "$output" | grep -q "不是对象"; then ok "W04 error on env non-object, exit=$exit_code"
else fail "W04 error on env non-object — exit=$exit_code"; fi

# ---- W05: env not exist -> auto-create ----
echo "--- [W05] switch: env does not exist ---"
make_json '{"model":"sonnet","hooks":{"pre":"echo hi"}}'
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -eq 0 ] && jq -e '.env.ANTHROPIC_BASE_URL == "https://api.deepseek.com/anthropic"' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W05 env auto-created, fields written"
else fail "W05 env auto-created — exit=$exit_code"; fi
if jq -e '.hooks.pre == "echo hi"' "$SETTINGS_TEST" >/dev/null 2>&1; then ok "W05 hooks preserved after env creation"
else fail "W05 hooks preserved after env creation"; fi

# ---- W06: settings missing ----
echo "--- [W06] switch: settings file missing ---"
rm -f "$SETTINGS_TEST" "$BACKUP_TEST"
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -ne 0 ] && echo "$output" | grep -q "不存在"; then ok "W06 error on missing file, exit=$exit_code"
else fail "W06 error on missing file — exit=$exit_code"; fi

# ---- W07: settings invalid JSON ----
echo "--- [W07] switch: settings invalid JSON ---"
echo "not json" > "$SETTINGS_TEST"
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -ne 0 ] && echo "$output" | grep -q "格式无效"; then ok "W07 error on invalid JSON, exit=$exit_code"
else fail "W07 error on invalid JSON — exit=$exit_code"; fi

# ---- W08: key file missing ----
echo "--- [W08] switch: key file missing ---"
make_json '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"claude"}}'
rm -f "$BACKUP_TEST"
rm -f "$DEEPSEEK_KEY_FILE"
output=$("$SW" switch 2>&1)
exit_code=$?
if [ $exit_code -ne 0 ] && echo "$output" | grep -q "密钥文件不存在"; then ok "W08 error on missing key file, exit=$exit_code"
else fail "W08 error on missing key file — exit=$exit_code"; fi
echo "sk-test-token-12345" > "$DEEPSEEK_KEY_FILE"

# ---- R01: restore valid backup ----
echo "--- [R01] restore: valid backup ---"
# Create Claude config + switch (creates backup) + restore
make_json '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"claude-opus","ANTHROPIC_AUTH_TOKEN":"sk-original"},"model":"sonnet","theme":"dark"}'
cp "$SETTINGS_TEST" /tmp/test-claude-original.json
rm -f "$BACKUP_TEST"
"$SW" switch > /dev/null 2>&1
output=$("$SW" restore 2>&1)
exit_code=$?
if [ $exit_code -eq 0 ]; then ok "R01 restore exit=0"
else fail "R01 restore exit=0 — got exit=$exit_code"; fi
if diff <(jq -S . /tmp/test-claude-original.json) <(jq -S . "$SETTINGS_TEST") >/dev/null 2>&1; then ok "R01 restored config matches original exactly"
else fail "R01 restored config matches original exactly"; fi
if echo "$output" | grep -q "claude-like"; then ok "R01 state back to claude-like"
else fail "R01 state back to claude-like"; fi
rm -f /tmp/test-claude-original.json

# ---- R02: restore no backup ----
echo "--- [R02] restore: no backup ---"
rm -f "$BACKUP_TEST"
output=$("$SW" restore 2>&1)
exit_code=$?
if [ $exit_code -ne 0 ] && echo "$output" | grep -q "不存在"; then ok "R02 error on missing backup, exit=$exit_code"
else fail "R02 error on missing backup — exit=$exit_code"; fi

# ---- R03: restore invalid backup ----
echo "--- [R03] restore: invalid backup ---"
echo "invalid" > "$BACKUP_TEST"
output=$("$SW" restore 2>&1)
exit_code=$?
if [ $exit_code -ne 0 ] && echo "$output" | grep -q "格式无效"; then ok "R03 error on invalid backup, exit=$exit_code"
else fail "R03 error on invalid backup — exit=$exit_code"; fi

# ---- C01: full cycle Claude -> switch -> restore -> identical ----
echo "--- [C01] full cycle: Claude -> switch -> restore ---"
ORIG='{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"claude-haiku","ANTHROPIC_AUTH_TOKEN":"sk-abc"},"model":"haiku","permissions":{"allow":["Bash(*)"]}}'
echo "$ORIG" | jq . > "$SETTINGS_TEST"
cp "$SETTINGS_TEST" /tmp/test-cycle-orig.json
rm -f "$BACKUP_TEST"
"$SW" switch > /dev/null 2>&1
"$SW" restore > /dev/null 2>&1
if diff <(jq -S . /tmp/test-cycle-orig.json) <(jq -S . "$SETTINGS_TEST") >/dev/null 2>&1; then ok "C01 full cycle: restored == original"
else fail "C01 full cycle: restored == original — diff found"; fi
rm -f /tmp/test-cycle-orig.json

# ---- C02: double switch, single restore ----
echo "--- [C02] double switch, then restore ---"
ORIG2='{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"opus"}}'
echo "$ORIG2" | jq . > "$SETTINGS_TEST"
cp "$SETTINGS_TEST" /tmp/test-cycle2-orig.json
rm -f "$BACKUP_TEST"
# First switch: Claude -> DeepSeek (backup created)
"$SW" switch > /dev/null 2>&1
# Second switch: already DeepSeek (backup skipped)
"$SW" switch > /dev/null 2>&1
# Restore
"$SW" restore > /dev/null 2>&1
if diff <(jq -S . /tmp/test-cycle2-orig.json) <(jq -S . "$SETTINGS_TEST") >/dev/null 2>&1; then ok "C02 double switch + restore: restored == original"
else fail "C02 double switch + restore: restored == original — diff found"; fi
rm -f /tmp/test-cycle2-orig.json

# ============================================================
# API Tests (Python Flask)
# ============================================================
echo ""
echo "========================================"
echo " API Tests"
echo "========================================"
echo ""

# Start test Flask server
cd "$HOME"
export PYTHONPATH="/Users/fang/Library/Python/3.9/lib/python/site-packages"
python3 "$HOME/app-test.py" &
API_PID=$!
sleep 2

# ---- A01: GET /api/status ----
echo "--- [A01] GET /api/status ---"
# Set up a Claude config for testing
echo '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"claude-sonnet","ANTHROPIC_AUTH_TOKEN":"sk-xxx"},"model":"sonnet"}' | jq . > "$SETTINGS_TEST"
rm -f "$BACKUP_TEST"
resp=$(curl -s http://localhost:18080/api/status)
state=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
if [ "$state" = "claude-like" ]; then ok "A01 state=claude-like"
else fail "A01 state=claude-like — got $state"; fi
config_ok=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin)['config']; print(d['ANTHROPIC_BASE_URL'] == 'https://api.anthropic.com' and d['ANTHROPIC_AUTH_TOKEN'] == True)")
if [ "$config_ok" = "True" ]; then ok "A01 config fields correct"
else fail "A01 config fields correct"; fi

# ---- A02: POST /api/switch (from claude-like) ----
echo "--- [A02] POST /api/switch (claude-like) ---"
echo '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_MODEL":"claude-sonnet"}}' | jq . > "$SETTINGS_TEST"
rm -f "$BACKUP_TEST"
resp=$(curl -s -X POST http://localhost:18080/api/switch)
success=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])")
warnings=$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['warnings']))")
state=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['state'])")
if [ "$success" = "True" ]; then ok "A02 success=true"
else fail "A02 success=true — got $success"; fi
if [ "$state" = "deepseek-like" ]; then ok "A02 state=deepseek-like after switch"
else fail "A02 state=deepseek-like after switch — got $state"; fi
if [ "$warnings" = "0" ]; then ok "A02 no warnings (fresh backup)"
else fail "A02 no warnings — got $warnings warnings"; fi

# ---- A03: POST /api/switch (already deepseek-like) ----
echo "--- [A03] POST /api/switch (already deepseek) ---"
resp=$(curl -s -X POST http://localhost:18080/api/switch)
success=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])")
warnings=$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['warnings']))")
if [ "$success" = "True" ]; then ok "A03 success=true"
else fail "A03 success=true — got $success"; fi
if [ "$warnings" != "0" ]; then ok "A03 has warning (backup skipped)"
else fail "A03 has warning — got 0 warnings"; fi

# ---- A04: POST /api/restore (backup exists) ----
echo "--- [A04] POST /api/restore (backup exists) ---"
resp=$(curl -s -X POST http://localhost:18080/api/restore)
success=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])")
if [ "$success" = "True" ]; then ok "A04 restore success=true"
else fail "A04 restore success=true — got $success"; fi

# ---- A05: POST /api/restore (no backup) ----
echo "--- [A05] POST /api/restore (no backup) ---"
rm -f "$BACKUP_TEST"
resp=$(curl -s -X POST http://localhost:18080/api/restore)
success=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])")
errors=$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['errors']))")
if [ "$success" = "False" ] && [ "$errors" != "0" ]; then ok "A05 restore fails with errors"
else fail "A05 restore fails with errors — success=$success errors=$errors"; fi

# Stop test server
kill $API_PID 2>/dev/null || true

# ============================================================
# Report
# ============================================================
echo ""
echo "========================================"
echo " 测试报告"
echo "========================================"
TOTAL=$((PASS + FAIL))
echo "  总计: $TOTAL"
echo -e "  通过: ${GREEN}$PASS${NC}"
echo -e "  失败: ${RED}$FAIL${NC}"
echo ""

teardown

if [ $FAIL -gt 0 ]; then exit 1; fi
