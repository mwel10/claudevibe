#!/usr/bin/env bash
# SessionStart hook.
#
# Checks at the start of every session whether a project-level
# .claude/settings.json or .claude/settings.local.json contains an allow
# rule that could weaken a global deny rule from ~/.claude/settings.json.
# Patterns come from deny-regex.py at runtime, so this script no longer
# keeps its own copy of the deny list: an addition made during an intake
# (0.4) reaches this check automatically.
#
# Known limit: a hook cannot invoke the interactive /status command itself.
# This script is the closest technical alternative; /status remains the
# manual check to run after editing any settings file, see A7 in CLAUDE.md.

set -euo pipefail

LIB="$HOME/.claude/hooks/lib/deny-regex.py"
WARN_LOG="$HOME/.claude/logs/settings-warnings.log"
mkdir -p "$(dirname "$WARN_LOG")"

WARNINGS=()

DENY_PATTERNS=()
if [ -f "$LIB" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && DENY_PATTERNS+=("$line")
  done < <(python3 "$LIB" 2>/dev/null || true)
fi

check_file_for_overrides() {
  local FILE="$1"
  [ -f "$FILE" ] || return 0

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

  for PATTERN in "${DENY_PATTERNS[@]}"; do
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
    for W in "${WARNINGS[@]}"; do
      echo "  - $W"
    done
  } >> "$WARN_LOG"

  echo "WARNING, possible weakening of the guardrails in this session:"
  for W in "${WARNINGS[@]}"; do
    echo "- $W"
  done
  echo "Verify this with /status (the 'Setting sources' line) before performing any destructive or sensitive action, and tell the user explicitly if an override turns out to be active."
fi

exit 0
