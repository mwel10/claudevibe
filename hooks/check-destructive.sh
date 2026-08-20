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
#
# This hook fails closed. If it cannot derive its patterns it blocks rather
# than allowing, because a guardrail that silently degrades to a no-op is
# worse than one that is loudly broken. See the "broken install" note in the
# README: an earlier version failed open and nobody noticed for weeks.

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

# Fail closed: no patterns means the guardrail is not working, not that the
# command is safe. ${A[@]+"${A[@]}"} is required because bash 3.2, which is
# what macOS ships, treats an empty array as unset under `set -u`.
if [ ${#DERIVED_PATTERNS[@]} -eq 0 ]; then
  echo "Blocked by check-destructive.sh: could not derive any deny pattern." >&2
  echo "Either $LIB is missing or unreadable, or permissions.deny in ~/.claude/settings.json has no Bash rules." >&2
  echo "The destructive-command guardrail is therefore NOT active. Tell the user this explicitly, and do not work around it by retrying or by using a different tool." >&2
  exit 2
fi

# Patterns that can't be expressed as a settings.json deny rule.
EXTRA_PATTERNS=(
  ":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\};:"   # fork bomb
)

for PATTERN in ${DERIVED_PATTERNS[@]+"${DERIVED_PATTERNS[@]}"} ${EXTRA_PATTERNS[@]+"${EXTRA_PATTERNS[@]}"}; do
  if echo "$LOWER_CMD" | grep -qE "$PATTERN"; then
    echo "Blocked by check-destructive.sh: command matches deny pattern '$PATTERN' (derived from settings.json or added explicitly)." >&2
    echo "Ask the user for explicit confirmation before proposing an alternative." >&2
    exit 2
  fi
done

exit 0
