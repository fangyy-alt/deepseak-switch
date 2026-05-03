#!/bin/bash
set -euo pipefail

# ============================================================
# Constants
# ============================================================

SETTINGS_FILE="$HOME/.claude/settings.json"
BACKUP_FILE="$HOME/.claude/settings.json.deepseek-switch.backup"

DEEPSEEK_BASE_URL="https://api.deepseek.com/anthropic"
DEEPSEEK_MODEL="DeepSeek-V4-pro[1m]"
DEEPSEEK_KEY_FILE="$HOME/.claude/deepseek-key"

# ============================================================
# Utility functions
# ============================================================

die() {
    echo "错误: $*" >&2
    exit 1
}

warn() {
    echo "警告: $*" >&2
}

validate_json() {
    local file="$1"
    local label="$2"
    if ! jq empty "$file" 2>/dev/null; then
        die "$label JSON 格式无效: $file"
    fi
}

check_file_readable() {
    local file="$1"
    local label="$2"
    if [ ! -f "$file" ]; then
        die "$label 不存在: $file"
    fi
    if [ ! -r "$file" ]; then
        die "$label 不可读: $file"
    fi
}

# ============================================================
# State detection
# ============================================================

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

# ============================================================
# Auth token resolution
# ============================================================

get_auth_token() {
    if [ ! -f "$DEEPSEEK_KEY_FILE" ]; then
        die "密钥文件不存在: $DEEPSEEK_KEY_FILE"
    fi
    local token
    token=$(tr -d '[:space:]' < "$DEEPSEEK_KEY_FILE")
    if [ -z "$token" ]; then
        die "密钥文件为空: $DEEPSEEK_KEY_FILE"
    fi
    echo "$token"
}

# ============================================================
# Atomic write helper
# ============================================================

atomic_write() {
    local src="$1"
    local dst="$2"
    local label="$3"

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/deepseek-switch.XXXXXXXX") || die "临时文件创建失败"

    # Ensure cleanup on error/exit
    trap 'rm -f "$tmp"' EXIT

    cp "$src" "$tmp" || die "临时文件写入失败: $label"
    mv "$tmp" "$dst" || die "文件替换失败: $label"

    # Remove trap after success
    trap - EXIT
}

# ============================================================
# cmd_status
# ============================================================

cmd_status() {
    echo "=== DeepSeek 切换状态 ==="
    echo ""

    # Settings file
    echo "主配置文件: $SETTINGS_FILE"
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "状态:         未找到配置文件"
        echo ""
        echo "备份文件:     $BACKUP_FILE"
        if [ -f "$BACKUP_FILE" ]; then
            echo "备份状态:     存在 ($(wc -c < "$BACKUP_FILE" | tr -d ' ') bytes)"
        else
            echo "备份状态:     不存在"
        fi
        return 0
    fi
    echo "状态:         存在"

    # Validate JSON
    if ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
        echo "JSON 状态:    格式无效"
        echo ""
        echo "备份文件:     $BACKUP_FILE"
        if [ -f "$BACKUP_FILE" ]; then
            echo "备份状态:     存在 ($(wc -c < "$BACKUP_FILE" | tr -d ' ') bytes)"
        else
            echo "备份状态:     不存在"
        fi
        return 0
    fi

    # Detect state
    local state
    state=$(detect_state)
    echo "整体状态:     $state"
    echo ""

    # Field summary
    local val

    val=$(jq -r '.env.ANTHROPIC_BASE_URL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_BASE_URL:              $val"

    val=$(jq -r '.env.ANTHROPIC_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_MODEL:                 $val"

    if jq -e '.env | has("ANTHROPIC_AUTH_TOKEN")' "$SETTINGS_FILE" >/dev/null 2>&1; then
        echo "  ANTHROPIC_AUTH_TOKEN:            已设置"
    else
        echo "  ANTHROPIC_AUTH_TOKEN:            未设置"
    fi

    if jq -e '.env | has("ANTHROPIC_API_KEY")' "$SETTINGS_FILE" >/dev/null 2>&1; then
        echo "  ANTHROPIC_API_KEY:               已设置"
    else
        echo "  ANTHROPIC_API_KEY:               未设置"
    fi

    val=$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_DEFAULT_HAIKU_MODEL:   $val"

    val=$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_DEFAULT_SONNET_MODEL:  $val"

    val=$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "未设置"' "$SETTINGS_FILE")
    echo "  ANTHROPIC_DEFAULT_OPUS_MODEL:    $val"

    val=$(jq -r '.model // "未设置"' "$SETTINGS_FILE")
    echo "  top-level model:                 $val"

    echo ""

    # Backup status
    echo "备份文件:     $BACKUP_FILE"
    if [ -f "$BACKUP_FILE" ]; then
        echo "备份状态:     存在 ($(wc -c < "$BACKUP_FILE" | tr -d ' ') bytes)"
    else
        echo "备份状态:     不存在"
    fi
}

# ============================================================
# cmd_switch
# ============================================================

cmd_switch() {
    # Pre-checks
    check_file_readable "$SETTINGS_FILE" "Settings file"
    validate_json "$SETTINGS_FILE" "Settings file"

    # Validate top-level is object
    local top_type
    top_type=$(jq -r 'type' "$SETTINGS_FILE")
    if [ "$top_type" != "object" ]; then
        die "Settings file 根节点不是对象 (type=$top_type): $SETTINGS_FILE"
    fi

    # Validate env (if exists) is object
    if jq -e 'has("env")' "$SETTINGS_FILE" >/dev/null 2>&1; then
        local env_type
        env_type=$(jq -r '.env | type' "$SETTINGS_FILE")
        if [ "$env_type" != "object" ]; then
            die "env 字段不是对象 (type=$env_type)，无法安全切换: $SETTINGS_FILE"
        fi
    fi

    # Resolve auth token
    local auth_token
    auth_token=$(get_auth_token)

    # Always backup current state before switching, so restore goes back to exact pre-switch state.
    # Exception: if already deepseek-like, skip backup to preserve the last non-deepseek backup.
    local current_state
    current_state=$(detect_state)
    if [ "$current_state" = "deepseek-like" ]; then
        warn "当前已是 DeepSeek 配置，跳过备份: $BACKUP_FILE"
    else
        cp "$SETTINGS_FILE" "$BACKUP_FILE" || die "备份创建失败: $BACKUP_FILE"
        echo "已备份当前配置: $BACKUP_FILE"
    fi

    # Generate new config via jq patch
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/deepseek-switch.XXXXXXXX") || die "临时文件创建失败"
    trap 'rm -f "$tmp"' EXIT

    jq \
        --arg base_url "$DEEPSEEK_BASE_URL" \
        --arg model "$DEEPSEEK_MODEL" \
        --arg token "$auth_token" \
        '
        if has("env") then . else .env = {} end
        | .env.ANTHROPIC_BASE_URL = $base_url
        | .env.ANTHROPIC_MODEL = $model
        | .env.ANTHROPIC_AUTH_TOKEN = $token
        ' "$SETTINGS_FILE" > "$tmp" || die "配置 patch 失败"

    # Validate output
    validate_json "$tmp" "生成的新配置"

    # Atomic replace
    mv "$tmp" "$SETTINGS_FILE" || die "文件替换失败: $SETTINGS_FILE"
    trap - EXIT

    echo "切换完成: 已切换到 DeepSeek 配置"
    echo ""

    # Show new state
    cmd_status
}

# ============================================================
# cmd_restore
# ============================================================

cmd_restore() {
    # Pre-checks
    check_file_readable "$BACKUP_FILE" "Backup file"
    validate_json "$BACKUP_FILE" "Backup file"

    # Restore by copying backup over settings.json
    atomic_write "$BACKUP_FILE" "$SETTINGS_FILE" "restore"

    echo "恢复完成: 已从备份恢复原始配置"
    echo ""

    # Show new state
    cmd_status
}

# ============================================================
# Main entry point
# ============================================================

print_usage() {
    echo "用法: $0 <command>"
    echo ""
    echo "命令:"
    echo "  status    查看当前配置状态"
    echo "  switch    切换到 DeepSeek 配置"
    echo "  restore   从备份恢复原始配置"
    exit 1
}

main() {
    if [ $# -eq 0 ]; then
        print_usage
    fi

    case "$1" in
        status)   cmd_status ;;
        switch)   cmd_switch ;;
        restore)  cmd_restore ;;
        -h|--help|help) print_usage ;;
        *)        echo "未知命令: $1" >&2; print_usage ;;
    esac
}

main "$@"
