#!/usr/bin/env bash
# PreToolUse hook on Bash.
# Blocks commands that match a Bash deny rule from ~/.claude/settings.json.
# Patterns are derived at runtime via deny-regex.py: this script no longer
# keeps its own pattern list, so a change to the deny list during an intake
# (0.4) takes effect immediately.
#
# Extra patterns that don't fit the settings.json syntax (such as the fork
# bomb below) live separately and are explicitly labelled, so they stay
# visible instead of silently disappearing.
#
# Exit code 2 = block the tool call, stderr is returned to Claude.
# Exit code 0 = command is allowed through.

set -euo pipefail

LIB="$HOME/.claude/hooks/lib/deny-regex.py"

INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))" 2>/dev/null || echo "")

if [ -z "$CMD" ]; then
  exit 0
fi

LOWER_CMD=$(echo "$CMD" | tr '[:upper:]' '[:lower:]')

# Patterns derived from the Bash deny rules in settings.json.
DERIVED_PATTERNS=()
if [ -f "$LIB" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && DERIVED_PATTERNS+=("$line")
  done < <(python3 "$LIB" --tool Bash 2>/dev/null || true)
fi

# Patterns that can't be expressed as a settings.json deny rule.
EXTRA_PATTERNS=(
  ":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\};:"   # fork bomb
)

for PATTERN in "${DERIVED_PATTERNS[@]}" "${EXTRA_PATTERNS[@]}"; do
  if echo "$LOWER_CMD" | grep -qE "$PATTERN"; then
    echo "Blocked by check-destructive.sh: command matches deny pattern '$PATTERN' (derived from settings.json or added explicitly)." >&2
    echo "Ask the user for explicit confirmation before proposing an alternative." >&2
    exit 2
  fi
done

exit 0
