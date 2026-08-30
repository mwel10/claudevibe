#!/usr/bin/env bash
# Verifies that the guardrail is installed AND actually working.
#
# Run this after installing, after editing settings.json, and any time you
# want to know that the mechanical layer is real rather than merely present.
# Exit 0 = everything passed. Exit 1 = at least one check failed.
#
# The reason this exists: an earlier release shipped install URLs that 404'd,
# and `curl -o` without --fail wrote the error body into each hook. Every file
# was present, executable, correctly named, and inert. Checking that a file
# exists proves nothing. This checks that a destructive command is blocked and
# that a harmless one is not.

set -uo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOK_DIR="$CLAUDE_DIR/hooks"
PASS=0
FAIL=0

ok()  { echo "  ok    $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "Files"
for F in "$CLAUDE_DIR/CLAUDE.md" "$CLAUDE_DIR/settings.json" \
         "$HOOK_DIR/check-destructive.sh" "$HOOK_DIR/log-tool-call.sh" \
         "$HOOK_DIR/verify-settings.sh" "$HOOK_DIR/lib/deny-regex.py"; do
  SHORT="${F#$HOME/}"
  if [ ! -f "$F" ]; then
    bad "$SHORT is missing"
  elif head -c 200 "$F" | grep -qiE '404|not found|<html'; then
    bad "$SHORT looks like a downloaded error page, not the real file. Reinstall with 'curl --fail'."
  elif [ "$(wc -c < "$F" | tr -d ' ')" -lt 100 ]; then
    bad "$SHORT is only $(wc -c < "$F" | tr -d ' ') bytes and is probably not the real file"
  else
    ok "$SHORT"
  fi
done

echo "Permissions"
for F in "$HOOK_DIR"/*.sh; do
  [ -f "$F" ] || continue
  if [ -x "$F" ]; then ok "${F#$HOME/} is executable"
  else bad "${F#$HOME/} is not executable, run: chmod +x ~/.claude/hooks/*.sh"; fi
done

echo "Deny patterns"
COUNT=$(python3 "$HOOK_DIR/lib/deny-regex.py" --tool Bash 2>/dev/null | grep -c . || true)
if [ "${COUNT:-0}" -gt 0 ]; then ok "$COUNT Bash deny patterns derived from settings.json"
else bad "no Bash deny patterns could be derived, check permissions.deny in settings.json"; fi

echo "Behaviour"
# These strings are handed to the hook on stdin as JSON. Nothing executes them.
probe() {
  printf '{"tool_input":{"command":"%s"}}' "$1" \
    | bash "$HOOK_DIR/check-destructive.sh" >/dev/null 2>&1
  echo $?
}
BLOCKED=$(probe "truncate table demo")
ALLOWED=$(probe "echo hello")

if [ "$BLOCKED" = "2" ]; then ok "destructive command is blocked"
else bad "destructive command was NOT blocked (exit $BLOCKED, expected 2)"; fi

# This second check matters because the hook fails closed: a completely broken
# install blocks everything, so "it blocked something" proves nothing on its
# own. The guardrail has to discriminate between the two.
if [ "$ALLOWED" = "0" ]; then
  ok "harmless command is allowed through"
elif [ "$ALLOWED" = "2" ]; then
  bad "harmless command was blocked too. The hook is failing closed, which means it cannot derive its patterns. Check that ~/.claude/hooks/lib/deny-regex.py and settings.json are intact."
else
  bad "the hook itself did not run (exit $ALLOWED). It is not a working script, so nothing is being checked at all."
fi

echo "Subagents"
# A9: the shared definitions are what makes the intake, threat model, review
# and dependency check available in a new project without setting anything up.
# A missing directory is the failure mode that looks like nothing at all.
if [ -d "$CLAUDE_DIR/agents" ]; then
  N=$(ls -1 "$CLAUDE_DIR/agents"/*.md 2>/dev/null | grep -c . || true)
  if [ "${N:-0}" -gt 0 ]; then ok "$N subagent definitions in ~/.claude/agents"
  else bad "~/.claude/agents exists but holds no .md definitions"; fi
  if grep -rlE '^permissionMode:[[:space:]]*(bypassPermissions|dontAsk)' "$CLAUDE_DIR/agents" >/dev/null 2>&1; then
    bad "a subagent definition sets permissionMode to bypassPermissions or dontAsk, which A9 forbids"
  else
    ok "no subagent definition bypasses the permission prompts"
  fi
else
  bad "~/.claude/agents is missing, the shared subagent definitions are not installed"
fi

echo "Session-start check"
OUT=$(bash "$HOOK_DIR/verify-settings.sh" 2>&1 || true)
if [ -z "$OUT" ]; then ok "verify-settings.sh reports no warnings"
else bad "verify-settings.sh reports:"; echo "$OUT" | sed 's/^/          /'; fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All $PASS checks passed. The guardrail is installed and working."
  exit 0
fi
echo "$FAIL of $((PASS + FAIL)) checks failed. The mechanical layer is not fully active."
echo "Re-run the install commands in the README, making sure every curl uses --fail."
exit 1
