import json
import os
import subprocess
import threading

from flask import Flask, jsonify, render_template

app = Flask(__name__)

# Constants — mirror switch-deepseek.sh
SETTINGS_FILE = os.path.expanduser("~/.claude/settings.json")
BACKUP_FILE = SETTINGS_FILE + ".deepseek-switch.backup"
DEEPSEEK_BASE_URL = "https://api.deepseek.com/anthropic"
DEEPSEEK_MODEL = "DeepSeek-V4-pro[1m]"
SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "switch-deepseek.sh")

operation_lock = threading.Lock()


def read_status():
    """Read settings.json directly and return status dict."""
    result = {
        "settings_exists": False,
        "settings_valid_json": False,
        "state": "unknown",
        "config": None,
        "backup": {
            "exists": False,
            "size_bytes": None,
        },
    }

    # Backup info
    if os.path.isfile(BACKUP_FILE):
        result["backup"]["exists"] = True
        try:
            result["backup"]["size_bytes"] = os.path.getsize(BACKUP_FILE)
        except OSError:
            pass

    # Settings file
    if not os.path.isfile(SETTINGS_FILE):
        return result

    result["settings_exists"] = True

    try:
        with open(SETTINGS_FILE, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return result

    if not isinstance(data, dict):
        return result

    result["settings_valid_json"] = True

    env = data.get("env", {})
    if not isinstance(env, dict):
        env = {}

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

    # State detection — same logic as shell script
    base_url = env.get("ANTHROPIC_BASE_URL", "")
    model = env.get("ANTHROPIC_MODEL", "")
    if base_url == DEEPSEEK_BASE_URL and model == DEEPSEEK_MODEL:
        result["state"] = "deepseek-like"
    elif base_url != DEEPSEEK_BASE_URL:
        result["state"] = "claude-like"
    else:
        result["state"] = "unknown"

    return result


def run_script(command):
    """Run switch-deepseek.sh with the given command, return result dict."""
    with operation_lock:
        proc = subprocess.run(
            [SCRIPT_PATH, command],
            capture_output=True,
            text=True,
            timeout=30,
        )

    stdout_lines = [line for line in proc.stdout.strip().splitlines() if line]
    stderr_lines = [line for line in proc.stderr.strip().splitlines() if line]

    warnings = [line for line in stderr_lines if line.startswith("警告:")]
    errors = [line for line in stderr_lines if line.startswith("错误:")]

    status = read_status()

    return {
        "success": proc.returncode == 0,
        "messages": stdout_lines,
        "warnings": warnings,
        "errors": errors,
        "status": status,
    }


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    return jsonify(read_status())


@app.route("/api/switch", methods=["POST"])
def api_switch():
    return jsonify(run_script("switch"))


@app.route("/api/restore", methods=["POST"])
def api_restore():
    return jsonify(run_script("restore"))


@app.errorhandler(Exception)
def handle_error(e):
    return jsonify({"success": False, "errors": [str(e)]}), 500


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080, debug=False)
