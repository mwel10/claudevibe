#!/usr/bin/env bash
# SessionStart hook.
#
# Controleert bij elke sessiestart of een project-level .claude/settings.json
# of .claude/settings.local.json een allow-regel bevat die een globale
# deny-regel uit ~/.claude/settings.json kan verzwakken. De patronen komen
# runtime uit deny-regex.py, dus dit script onderhoudt zelf geen kopie meer
# van de deny-lijst: een uitbreiding tijdens een intake (0.4) werkt hier
# automatisch door.
#
# Kanttekening: een hook kan het interactieve /status-commando niet zelf
# aanroepen. Dit script is het dichtstbijzijnde technische alternatief; /status
# blijft de manuele check na elke wijziging aan een settings-bestand, zie A7
# in CLAUDE.md.

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
      WARNINGS+=("$FILE bevat een allow-regel die matcht met deny-patroon '$PATTERN' uit ~/.claude/settings.json.")
    fi
  done
}

check_file_for_overrides "$(pwd)/.claude/settings.json"
check_file_for_overrides "$(pwd)/.claude/settings.local.json"

if [ ! -f "$HOME/.claude/settings.json" ]; then
  WARNINGS+=("~/.claude/settings.json ontbreekt: de globale deny/ask-regels en hooks zijn niet actief in deze sessie.")
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  {
    echo "$(date -Iseconds) sessie in $(pwd)"
    for W in "${WARNINGS[@]}"; do
      echo "  - $W"
    done
  } >> "$WARN_LOG"

  echo "LET OP, mogelijke verzwakking van de guardrails in deze sessie:"
  for W in "${WARNINGS[@]}"; do
    echo "- $W"
  done
  echo "Controleer dit met /status (regel 'Setting sources') voordat je destructieve of gevoelige acties uitvoert, en meld het expliciet aan de gebruiker als een override actief blijkt."
fi

exit 0
