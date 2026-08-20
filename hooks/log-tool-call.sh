#!/usr/bin/env bash
# PostToolUse hook on all tools ("*").
# Fulfils A5 (tool-call logging) mechanically: this logs independent of
# whether Claude accurately reports what it did within the session itself.

set -euo pipefail

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/tool-calls.log"

INPUT=$(cat)
TIMESTAMP=$(date -Iseconds)
TOOL=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_name', 'unknown'))" 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('cwd', ''))" 2>/dev/null || echo "")

echo "$TIMESTAMP tool=$TOOL cwd=$CWD" >> "$LOG_FILE"

exit 0
