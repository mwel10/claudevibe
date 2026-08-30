#!/usr/bin/env bash
# PreToolUse and PostToolUse hook on Edit and Write.
#
# A9 says the Part 0 intake is the first thing that happens in a new project.
# An instruction cannot make that happen, so this hook makes the intake a
# condition for writing code: the first Edit or Write in a project that has
# neither a "## Project addendum: security scope" nor an intake-scout receipt
# becomes a permission prompt, with the reason attached.
#
# It asks rather than denies, deliberately. A deny invites a session to look for
# a route around it, and the session is the party least able to judge whether
# skipping the intake is fine. An ask cannot be answered by the session at all:
# it lands with the user, which is where the decision in 0.4 was always supposed
# to sit.
#
# It asks once per project per session. The PostToolUse half records that a
# write actually went through, which only happens if the user approved, so a
# refusal leaves no marker and the next write asks again.
#
# Never gated, on purpose:
#   - the project's own CLAUDE.md, since writing the addendum is the way out;
#   - anything outside the project directory, so scratch files and this
#     configuration itself stay out of the way;
#   - $HOME and ~/.claude, which are not projects.
#
# Fails closed. If it cannot work out the state of the project it asks, rather
# than waving the write through on a broken check.

set -uo pipefail

RECEIPTS="$HOME/.claude/logs/agent-receipts"
MARKERS="$HOME/.claude/logs/intake-gate"

INPUT=$(cat)

ask() {
  # $1 = reason
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": sys.argv[1],
    }
}))
PY
  exit 0
}

# Paths are resolved to their physical form here, in the same pass that reads
# them. Without that, a file path arrives unresolved while `git rev-parse
# --show-toplevel` returns a resolved one, so the "is this file inside the
# project" test fails on any machine where the path crosses a symlink. On macOS
# that is every path under /tmp and /var, and the gate would have switched
# itself off without saying anything.
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, os, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}


def real(p):
    return os.path.realpath(p) if p else ""


print(d.get("hook_event_name") or "")
print(real(d.get("cwd")))
print(d.get("session_id") or "")
print(real(ti.get("file_path") or ti.get("notebook_path")))
' 2>/dev/null)

if [ -z "$PARSED" ]; then
  ask "The intake gate could not read this tool call, so it cannot tell whether this project has had its Part 0 intake. Check ~/.claude/hooks/require-intake.sh before continuing."
fi

EVENT=$(printf '%s\n' "$PARSED" | sed -n '1p')
CWD=$(printf '%s\n' "$PARSED" | sed -n '2p')
SESSION=$(printf '%s\n' "$PARSED" | sed -n '3p')
FILE=$(printf '%s\n' "$PARSED" | sed -n '4p')

[ -n "$FILE" ] || exit 0

# --- Which project does this write belong to? --------------------------------

# A new file's parent directories may not exist yet, so walk up to the nearest
# one that does before asking git anything.
DIR=$(dirname "$FILE")
while [ -n "$DIR" ] && [ "$DIR" != "/" ] && [ ! -d "$DIR" ]; do
  DIR=$(dirname "$DIR")
done
[ -d "$DIR" ] || DIR="$CWD"
[ -d "$DIR" ] || exit 0

PROJECT=$(cd "$DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
[ -n "$PROJECT" ] || PROJECT="$CWD"
[ -n "$PROJECT" ] || exit 0
PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd -P)
[ -n "$PROJECT" ] || exit 0

# --- The exemptions ----------------------------------------------------------

case "$PROJECT" in
  "$HOME"|"$HOME/.claude"|"$HOME/.claude/"*) exit 0 ;;
esac

case "$FILE" in
  "$PROJECT"/*) : ;;                  # inside the project, keep checking
  *) exit 0 ;;                        # scratch files, /tmp, ~/.claude
esac

case "$FILE" in
  "$PROJECT/CLAUDE.md"|"$PROJECT/.claude/CLAUDE.md") exit 0 ;;
esac

# --- Has the intake already happened? ----------------------------------------

for F in "$PROJECT/CLAUDE.md" "$PROJECT/.claude/CLAUDE.md"; do
  [ -f "$F" ] || continue
  if grep -qF '## Project addendum: security scope' "$F"; then
    exit 0
  fi
done

SLUG=$(printf '%s' "$PROJECT" | sed 's/[^A-Za-z0-9._-]/_/g')

if [ -f "$RECEIPTS/$SLUG/intake-scout.json" ]; then
  exit 0
fi

MARKER="$MARKERS/$SLUG.$SESSION"

# --- PostToolUse: the write went through, so the user approved ---------------

if [ "$EVENT" = "PostToolUse" ]; then
  mkdir -p "$MARKERS" 2>/dev/null || exit 0
  : > "$MARKER" 2>/dev/null || true
  exit 0
fi

# --- PreToolUse: ask once per project per session -----------------------------

[ -n "$SESSION" ] && [ -f "$MARKER" ] && exit 0

ask "This project has no '## Project addendum: security scope' in its CLAUDE.md and no intake-scout receipt, so the Part 0 intake has not been done here yet. A9 asks for intake-scout to run and the addendum to be written before code is changed. Approve this write to continue anyway, in which case the gate stays quiet for the rest of this session; decline to run the intake first. Project: $PROJECT"
