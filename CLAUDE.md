# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single shell script tool (`switch-deepseek.sh`) for switching Claude Code's API backend between Anthropic and a DeepSeek-compatible endpoint, with safe rollback. The two `.md` files are design documents (spec and technical doc), not deliverables.

## Running the script

```bash
./switch-deepseek.sh status    # inspect current state (read-only)
./switch-deepseek.sh switch    # patch settings.json to DeepSeek config
./switch-deepseek.sh restore   # restore from backup
```

**Dependency:** `jq` must be installed.

## Key files

| File | Purpose |
|------|---------|
| `switch-deepseek.sh` | The deliverable — all logic lives here |
| `~/.claude/settings.json` | Only file the script modifies |
| `~/.claude/settings.json.deepseek-switch.backup` | Single backup created on first `switch` |
| `~/.claude/deepseek-key` | DeepSeek API token (read at runtime, never committed) |

## Hard-coded constants (top of script)

- `DEEPSEEK_BASE_URL` — `https://api.deepseek.com/anthropic`
- `DEEPSEEK_MODEL` — `DeepSeek-V4-pro[1m]`
- Auth field used: `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`)

## Design constraints

**Patch-only, never template-replace.** `switch` uses `jq` to update only three `env` fields (`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_AUTH_TOKEN`). All other fields (`statusLine`, `hooks`, `permissions`, `enabledPlugins`, proxy vars, top-level `model`, `ANTHROPIC_DEFAULT_*`) are preserved untouched.

**Single backup, never overwritten.** The backup captures the pre-switch original. Subsequent `switch` calls skip re-backup with a warning. `restore` does a full file replacement — no field-level merge.

**Atomic writes only.** Every write goes through a temp file + `mv` replacement. Direct in-place editing or `sed`/`grep`-based JSON mutation is forbidden.

**Three-state detection.** `status` reports `claude-like`, `deepseek-like`, or `unknown` based on `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` matching the hardcoded constants. This is advisory only — it never blocks execution.

**No scope creep.** This script must stay a single-file tool. Do not add: multiple providers, database state, MCP handling, proxy takeover, interactive menus, or `~/.claude.json` modifications.
