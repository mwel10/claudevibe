#!/usr/bin/env bash
# SessionStart hook.
#
# Two jobs.
#
# 1. Check whether a project-level .claude/settings.json or
#    .claude/settings.local.json contains an allow rule that could weaken a
#    global deny rule from ~/.claude/settings.json. Patterns come from
#    deny-regex.py at runtime, so this script keeps no copy of the deny list:
#    an addition made during an intake (0.4) reaches this check automatically.
#
# 2. Check that the guardrail itself is actually installed and working. An
#    earlier release documented curl install URLs that returned 404, and
#    `curl -o` without --fail happily wrote the string "404: Not Found" into
#    each hook. The hooks stayed present, executable, and completely inert for
#    weeks. A guardrail that cannot detect its own absence is not a guardrail,
#    so that case is now checked explicitly at every session start.
#
# Known limit: a hook cannot invoke the interactive /status command itself.
# This script is the closest technical alternative; /status remains the
# manual check to run after editing any settings file, see A7 in CLAUDE.md.

set -euo pipefail

HOOK_DIR="$HOME/.claude/hooks"
LIB="$HOOK_DIR/lib/deny-regex.py"
WARN_LOG="$HOME/.claude/logs/settings-warnings.log"
mkdir -p "$(dirname "$WARN_LOG")"

WARNINGS=()

# --- 1. Is the guardrail itself intact? --------------------------------------

for HOOK in check-destructive.sh log-tool-call.sh verify-settings.sh; do
  F="$HOOK_DIR/$HOOK"
  if [ ! -f "$F" ]; then
    WARNINGS+=("$F is missing: that part of the guardrail is not running.")
    continue
  fi
  if [ ! -x "$F" ]; then
    WARNINGS+=("$F is not executable: the hook cannot run.")
  fi
  # A hook that is a downloaded error page, or is implausibly short, is inert.
  if head -c 200 "$F" | grep -qiE '404|not found|<html'; then
    WARNINGS+=("$F does not look like a script, it looks like a downloaded error page. Reinstall it with 'curl --fail'.")
  elif [ "$(wc -c < "$F" | tr -d ' ')" -lt 100 ]; then
    WARNINGS+=("$F is suspiciously small ($(wc -c < "$F" | tr -d ' ') bytes) and is probably not the real hook.")
  fi
done

if [ ! -f "$LIB" ]; then
  WARNINGS+=("$LIB is missing: check-destructive.sh cannot derive its patterns and will block every Bash call until this is fixed.")
fi

# --- 2. Load the deny patterns ------------------------------------------------

DENY_PATTERNS=()
if [ -f "$LIB" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && DENY_PATTERNS+=("$line")
  done < <(python3 "$LIB" 2>/dev/null || true)
fi

# bash 3.2, which macOS ships, treats an empty array as unset under `set -u`,
# so every expansion below uses the ${A[@]+"${A[@]}"} form. Without it this
# script aborted on any machine where the pattern list came back empty, and a
# SessionStart hook that aborts fails silently.
if [ ${#DENY_PATTERNS[@]} -eq 0 ]; then
  WARNINGS+=("No deny patterns could be derived from ~/.claude/settings.json: the deny list is empty, unreadable, or malformed.")
fi

check_file_for_overrides() {
  local FILE="$1"
  [ -f "$FILE" ] || return 0
  [ ${#DENY_PATTERNS[@]} -gt 0 ] || return 0

  local ALLOW_BLOCK
  ALLOW_BLOCK=$(python3 -c "
import json, sys
try:
    with open('$FILE') as f:
        data = json.load(f)
    allow = data.get('permissions', {}).get('allow', [])
    print('\n'.join(allow))
except Exception:
    pass
" 2>/dev/null || echo "")

  [ -z "$ALLOW_BLOCK" ] && return 0

  for PATTERN in ${DENY_PATTERNS[@]+"${DENY_PATTERNS[@]}"}; do
    if echo "$ALLOW_BLOCK" | grep -qiE "$PATTERN"; then
      WARNINGS+=("$FILE contains an allow rule matching deny pattern '$PATTERN' from ~/.claude/settings.json.")
    fi
  done
}

check_file_for_overrides "$(pwd)/.claude/settings.json"
check_file_for_overrides "$(pwd)/.claude/settings.local.json"

if [ ! -f "$HOME/.claude/settings.json" ]; then
  WARNINGS+=("~/.claude/settings.json is missing: the global deny/ask rules and hooks are not active in this session.")
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  {
    echo "$(date -Iseconds) session in $(pwd)"
    for W in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
      echo "  - $W"
    done
  } >> "$WARN_LOG"

  echo "WARNING, possible weakening of the guardrails in this session:"
  for W in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
    echo "- $W"
  done
  echo "Verify this with /status (the 'Setting sources' line) before performing any destructive or sensitive action, and tell the user explicitly if an override turns out to be active."
fi

exit 0
