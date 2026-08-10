#!/usr/bin/env bash
# PreToolUse hook op Bash.
# Blokkeert commando's die overeenkomen met een Bash-deny-regel uit
# ~/.claude/settings.json. Patronen worden runtime afgeleid via
# deny-regex.py: dit script onderhoudt zelf geen patronenlijst meer, dus een
# wijziging in de deny-lijst tijdens een intake (0.4) werkt direct door.
#
# Extra patronen die niet in de settings.json-syntax passen (zoals de
# fork-bomb hieronder) staan apart en expliciet gelabeld, zodat ze zichtbaar
# blijven in plaats van stilzwijgend te verdwijnen.
#
# Exit code 2 = blokkeer de tool call, stderr wordt teruggegeven aan Claude.
# Exit code 0 = commando mag door.

set -euo pipefail

LIB="$HOME/.claude/hooks/lib/deny-regex.py"

INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))" 2>/dev/null || echo "")

if [ -z "$CMD" ]; then
  exit 0
fi

LOWER_CMD=$(echo "$CMD" | tr '[:upper:]' '[:lower:]')

# Patronen afgeleid van de Bash-deny-regels in settings.json.
DERIVED_PATTERNS=()
if [ -f "$LIB" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && DERIVED_PATTERNS+=("$line")
  done < <(python3 "$LIB" --tool Bash 2>/dev/null || true)
fi

# Patronen die niet als settings.json deny-regel uit te drukken zijn.
EXTRA_PATTERNS=(
  ":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\};:"   # fork bomb
)

for PATTERN in "${DERIVED_PATTERNS[@]}" "${EXTRA_PATTERNS[@]}"; do
  if echo "$LOWER_CMD" | grep -qE "$PATTERN"; then
    echo "Geblokkeerd door check-destructive.sh: commando matcht deny-patroon '$PATTERN' (afgeleid van settings.json of expliciet toegevoegd)." >&2
    echo "Vraag expliciete bevestiging aan de gebruiker voordat je een alternatief voorstelt." >&2
    exit 2
  fi
done

exit 0
