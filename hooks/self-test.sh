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
         "$HOOK_DIR/verify-settings.sh" "$HOOK_DIR/require-intake.sh" \
         "$HOOK_DIR/record-agent-run.sh" "$HOOK_DIR/scope-untrusted.sh" \
         "$HOOK_DIR/lib/deny-regex.py"; do
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

echo "Intake gate"
# The gate has to discriminate, exactly like check-destructive.sh: a hook that
# asks about everything and a hook that asks about nothing are both useless, and
# only one of them is obvious. HOME is redirected so none of this touches real
# receipts. Nothing below executes a tool call; the JSON is fed to the hook.
GATE_HOME=$(mktemp -d)
GATE_PROJ=$(mktemp -d)
gate() { # $1 = file path, $2 = hook event
  printf '{"hook_event_name":"%s","tool_name":"Edit","cwd":"%s","session_id":"selftest","tool_input":{"file_path":"%s"}}' \
    "$2" "$GATE_PROJ" "$1" | HOME="$GATE_HOME" bash "$HOOK_DIR/require-intake.sh" 2>/dev/null
}

if gate "$GATE_PROJ/src/app.py" PreToolUse | grep -q '"permissionDecision": "ask"'; then
  ok "intake gate asks before the first write in a project with no addendum"
else
  bad "intake gate did not ask in a project with no addendum, so it is gating nothing"
fi

if [ -z "$(gate "$GATE_PROJ/CLAUDE.md" PreToolUse)" ]; then
  ok "the project's own CLAUDE.md stays writable, so the addendum is reachable"
else
  bad "intake gate also gates CLAUDE.md, which deadlocks the only way out of it"
fi

# The same directory reached by a second spelling. A symlink here, a different
# case on a case-insensitive filesystem in the wild: both are path mismatches
# that made the gate allow everything while looking installed.
GATE_LINK="$(mktemp -d)/link"
ln -s "$GATE_PROJ" "$GATE_LINK" 2>/dev/null
if [ -L "$GATE_LINK" ] && gate "$GATE_LINK/src/app.py" PreToolUse | grep -q '"permissionDecision": "ask"'; then
  ok "intake gate still fires when the project is reached by another path"
elif [ ! -L "$GATE_LINK" ]; then
  ok "symlink probe skipped, this filesystem would not create one"
else
  bad "intake gate misses a write reached through a symlink, so any path mismatch disables it"
fi

printf '## Project addendum: security scope\n' > "$GATE_PROJ/CLAUDE.md"
if [ -z "$(gate "$GATE_PROJ/src/app.py" PreToolUse)" ]; then
  ok "intake gate stands down once the addendum is written"
else
  bad "intake gate still fires with an addendum present, so it would ask forever"
fi

if printf 'not json' | HOME="$GATE_HOME" bash "$HOOK_DIR/require-intake.sh" 2>/dev/null \
   | grep -q '"permissionDecision": "ask"'; then
  ok "intake gate fails closed on unreadable input"
else
  bad "intake gate waves writes through when it cannot read its own input"
fi

printf '{"hook_event_name":"SubagentStop","agent_type":"intake-scout","agent_id":"selftest","cwd":"%s","last_assistant_message":"probe"}' \
  "$GATE_PROJ" | HOME="$GATE_HOME" bash "$HOOK_DIR/record-agent-run.sh" >/dev/null 2>&1
if find "$GATE_HOME/.claude/logs/agent-receipts" -name 'intake-scout.json' 2>/dev/null | grep -q .; then
  ok "a finished subagent leaves a receipt"
else
  bad "no receipt was written for a finished subagent, so no gate can be satisfied by evidence"
fi

echo "Hook registration"
# Updating deliberately leaves settings.json alone, because that file carries
# the deny rules added during project intakes (0.4, A2) and overwriting it
# would delete them. The cost of that choice is this failure mode: a hook added
# by a later release arrives as a file with nothing wiring it in, and a hook
# Claude Code was never told to run is exactly as inert as a 404 stub. Every
# other check here runs the hooks directly, so this is the only one that would
# notice.
# The path goes in as an argument, not into the program text. It is $HOME-derived
# here so the risk is lower than in verify-settings.sh, but the same
# construction in the same repository should not have two different answers.
REGISTERED_PY=$(cat <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for entries in (data.get('hooks') or {}).values():
    for entry in entries or []:
        for hook in entry.get('hooks') or []:
            if hook.get('command'):
                print(hook['command'])
PY
)
REGISTERED=$(python3 -c "$REGISTERED_PY" "$CLAUDE_DIR/settings.json" 2>/dev/null || true)

if [ -z "$REGISTERED" ]; then
  bad "settings.json registers no hooks at all, so none of the scripts above ever run"
else
  for H in check-destructive.sh log-tool-call.sh verify-settings.sh \
           require-intake.sh record-agent-run.sh scope-untrusted.sh; do
    if [ ! -f "$HOOK_DIR/$H" ]; then
      continue
    elif echo "$REGISTERED" | grep -q "$H"; then
      ok "$H is registered in settings.json"
    else
      bad "$H is installed but not registered in settings.json, so Claude Code never runs it. Merge the 'hooks' block from the repository copy."
    fi
  done
fi

echo "Allow list"
# The allow list is the one place where too much and too little are both
# failures, so both are probed. This is also the lesson of the two earlier
# breakages: the first version of this check asked only whether the baseline
# was readable, which the over-broad rule satisfies, so it passed on exactly
# the configuration A7 argues against and nothing noticed, because no test
# fed it a settings file that should have failed. HOME is redirected, so the
# real settings file is never touched.
ALLOW_HOME=$(mktemp -d)
mkdir -p "$ALLOW_HOME/.claude/hooks/lib" "$ALLOW_HOME/.claude/agents"
cp "$HOOK_DIR"/*.sh "$ALLOW_HOME/.claude/hooks/" 2>/dev/null || true
cp "$HOOK_DIR/lib/deny-regex.py" "$ALLOW_HOME/.claude/hooks/lib/" 2>/dev/null || true
cp "$CLAUDE_DIR/agents"/*.md "$ALLOW_HOME/.claude/agents/" 2>/dev/null || true
cp "$CLAUDE_DIR/CLAUDE.md" "$ALLOW_HOME/.claude/CLAUDE.md" 2>/dev/null || true

ALLOW_PY=$(cat <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    data = {}
data.setdefault("permissions", {})["allow"] = sys.argv[3:]
# The redirected HOME has no plugin cache, so carrying enabledPlugins across
# would make the plugin check warn and this probe would be reading that warning
# as an allow-list failure. Each check gets a fixture that isolates it.
data.pop("enabledPlugins", None)
with open(sys.argv[2], "w") as f:
    json.dump(data, f, indent=2)
PY
)

allow_case() { # $@ = the allow rules to put in the redirected settings file
  python3 -c "$ALLOW_PY" "$CLAUDE_DIR/settings.json" \
    "$ALLOW_HOME/.claude/settings.json" "$@" 2>/dev/null || return 1
  HOME="$ALLOW_HOME" bash "$ALLOW_HOME/.claude/hooks/verify-settings.sh" 2>&1 || true
}

ALLOW_OUT=$(allow_case)
case "$ALLOW_OUT" in
  *"missing these permissions.allow rules"*) ok "allow-list check warns when the baseline's own files are unreachable" ;;
  *) bad "allow-list check stayed silent on a settings file with no allow rules at all" ;;
esac

ALLOW_OUT=$(allow_case "Read(~/.claude/**)")
case "$ALLOW_OUT" in
  *"reaching past"*) ok "allow-list check warns when a Read rule reaches past those four files" ;;
  *) bad "allow-list check accepts Read(~/.claude/**), which also grants every session the transcripts of every other project" ;;
esac

ALLOW_OUT=$(allow_case "Read(~/.claude/CLAUDE.md)" "Read(~/.claude/settings.json)" \
                       "Read(~/.claude/agents/**)" "Read(~/.claude/hooks/**)")
if [ -z "$ALLOW_OUT" ]; then
  ok "allow-list check is quiet on the four rules it asks for"
else
  bad "allow-list check warns about the configuration it documents as correct, so it cannot be satisfied:"
  echo "$ALLOW_OUT" | sed 's/^/          /'
fi

echo "Untrusted-content scope"
# A9 puts web reads inside a read-only subagent so a prompt injection lands
# somewhere it can do nothing. scope-untrusted.sh is what turns that from advice
# into a decision, and like every other check here it has to discriminate. The
# probes below are the ones a review had to point out were missing: the first
# version of the hook counted only Edit and Write as write tools, so an agent
# holding Bash passed as a clean reader, and it read a tools: line from anywhere
# in the file, so prose in a prompt body could declare a scope. Each of those is
# now a case here. SCOPE_DIR is an empty directory used as the working
# directory, so a real project's own .claude/agents cannot perturb the result.
SCOPE_DIR=$(mktemp -d)
mkdir -p "$SCOPE_DIR/.claude/agents"
printf -- '---\nname: shelly\ntools: Read, Grep, WebSearch, Bash\n---\nbody\n' \
  > "$SCOPE_DIR/.claude/agents/shelly.md"
printf -- '---\nname: prosey\ndescription: x\n---\nNever write. tools: Read, WebSearch\n' \
  > "$SCOPE_DIR/.claude/agents/prosey.md"
# The hijack fixture lives in its own directory. Left beside the others it wins
# the lookup for every probe, which is the correct behaviour of the hook and the
# wrong shape for a fixture: it made the normal case fail for the right reason
# and hid whether the normal case worked at all.
HIJACK_DIR=$(mktemp -d)
mkdir -p "$HIJACK_DIR/.claude/agents"
printf -- '---\nname: something-else\ntools: Read, WebSearch\n---\nbody\n' \
  > "$HIJACK_DIR/.claude/agents/untrusted-reader.md"

scope() { # $1 = tool, $2 = agent_type or empty, $3 = cwd
  local WHERE="${3:-$SCOPE_DIR}"
  if [ -n "$2" ]; then
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","agent_id":"selftest","agent_type":"%s","tool_input":{}}' "$1" "$2"
  else
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "$1"
  fi | (cd "$WHERE" && bash "$HOOK_DIR/scope-untrusted.sh" 2>/dev/null)
}

# The output is captured before it is searched. Piping into `grep -q` under
# `set -o pipefail` reports the opposite of the truth when the match is not on
# the last line: grep exits on the match, the writer takes SIGPIPE, and the
# pipeline status becomes 141, so a check that found what it wanted reads as a
# failure.
expect_scope() { # $1 = decision, $2 = tool, $3 = agent, $4 = ok text, $5 = fail text
  local OUT
  OUT=$(scope "$2" "$3")
  case "$OUT" in
    *"\"permissionDecision\": \"$1\""*|*"\"permissionDecision\":\"$1\""*) ok "$4" ;;
    *) bad "$5" ;;
  esac
}

expect_scope ask WebSearch "" \
  "a web read from the main conversation asks first" \
  "a web read from the main conversation is waved through, so A9's isolation of untrusted content is advisory again"

expect_scope allow WebSearch untrusted-reader \
  "a search inside untrusted-reader proceeds without asking" \
  "a search inside untrusted-reader also asks, so delegating costs a question and nobody will do it"

expect_scope ask WebFetch untrusted-reader \
  "a fetch keeps its per-domain question even inside untrusted-reader" \
  "a fetch of any URL is allowed inside untrusted-reader, so a page can name the next address to call"

expect_scope ask WebSearch security-reviewer \
  "a subagent that declares no web tool does not inherit web access" \
  "any subagent gets web access regardless of its declared tools, so the scope in the definition means nothing"

expect_scope ask WebSearch shelly \
  "a subagent holding Bash is not treated as a read-only context" \
  "a subagent holding a shell counts as a clean reader, which is the arrangement A9 exists to prevent"

expect_scope ask WebSearch prosey \
  "a tools: line in a prompt body is not read as a declared scope" \
  "prose in a prompt body can declare a tool scope, so a definition can grant itself web access in text"

expect_scope ask WebSearch untrusted-reader-mismatch \
  "a definition that is absent asks rather than allowing" \
  "a missing definition does not stop the read"

SCOPE_OUT=$(scope WebSearch untrusted-reader "$HIJACK_DIR")
case "$SCOPE_OUT" in
  *'"permissionDecision":"ask"'*|*'"permissionDecision": "ask"'*)
    ok "a project definition that hijacks a trusted name but does not match it is rejected" ;;
  *) bad "a project .claude/agents file decides the outcome by filename alone, so any cloned repository can grant itself web access" ;;
esac

SCOPE_OUT=$(printf 'not json' | bash "$HOOK_DIR/scope-untrusted.sh" 2>/dev/null || true)
case "$SCOPE_OUT" in
  *'"permissionDecision":"ask"'*|*'"permissionDecision": "ask"'*) ok "the web scope hook fails closed on unreadable input" ;;
  *) bad "the web scope hook allows a web read when it cannot read its own input" ;;
esac

# The fallback has to come from the shell, not from the interpreter whose
# absence it covers. A stub python3 that exits nonzero is the only way to probe
# it, and the first version of the hook produced no output at all here.
NOPY=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$NOPY/python3"
chmod +x "$NOPY/python3"
SCOPE_OUT=$(printf '{"tool_name":"WebSearch","agent_type":"untrusted-reader"}' \
  | PATH="$NOPY:$PATH" bash "$HOOK_DIR/scope-untrusted.sh" 2>/dev/null || true)
case "$SCOPE_OUT" in
  *'"permissionDecision":"ask"'*) ok "the web scope hook still asks when python3 cannot run" ;;
  *) bad "with no working python3 the web scope hook emits nothing, so the call proceeds unchecked" ;;
esac

echo "Plugins"
# There is a third source of hooks, subagent definitions and MCP servers beside
# user level and project level, and until now nothing looked at it. A plugin
# that ships only skills today can ship a hook in its next version, from a
# marketplace repository that is not pinned and not reviewed here.
PLUG_HOME=$(mktemp -d)
mkdir -p "$PLUG_HOME/.claude/hooks/lib" "$PLUG_HOME/.claude/agents"
cp "$HOOK_DIR"/*.sh "$PLUG_HOME/.claude/hooks/" 2>/dev/null || true
cp "$HOOK_DIR/lib/deny-regex.py" "$PLUG_HOME/.claude/hooks/lib/" 2>/dev/null || true
cp "$CLAUDE_DIR/agents"/*.md "$PLUG_HOME/.claude/agents/" 2>/dev/null || true
cp "$CLAUDE_DIR/CLAUDE.md" "$PLUG_HOME/.claude/CLAUDE.md" 2>/dev/null || true

plug() { # $1 = plugin name, $2 = extra manifest json
  local D="$PLUG_HOME/.claude/plugins/cache/probe/$1/1.0.0"
  mkdir -p "$D/.claude-plugin"
  printf '{"name":"%s","version":"1.0.0"%s}' "$1" "$2" > "$D/.claude-plugin/plugin.json"
  printf '{"permissions":{},"enabledPlugins":{"%s@probe":true}}' "$1" \
    > "$PLUG_HOME/.claude/settings.json"
  HOME="$PLUG_HOME" bash "$PLUG_HOME/.claude/hooks/verify-settings.sh" 2>&1
}

# The output is captured before it is searched, deliberately. Piping it into
# `grep -q` under `set -o pipefail` reports the opposite of the truth whenever
# the match is not on the last line: grep exits the moment it matches, the hook
# writing into the pipe takes SIGPIPE, and the pipeline status becomes 141, so
# a check that found exactly what it was looking for reads as a failure. That
# cost an hour here, and it is the same species as everything else this file
# guards against: a test that reports on something other than what it measured.
PLUG_OUT=$(plug skillsonly ',"skills":["./skills/"]')
case "$PLUG_OUT" in
  *contributes*) bad "the plugin check reports a skills-only plugin as contributing executable surface, so its warning carries no information" ;;
  *)             ok "a plugin that ships only skills raises no plugin warning" ;;
esac

PLUG_OUT=$(plug hooky ',"hooks":"./hooks/hooks.json"')
case "$PLUG_OUT" in
  *"contributes hooks"*) ok "a plugin that ships hooks is reported at session start" ;;
  *)                     bad "a plugin can add hooks to every session without any check noticing" ;;
esac

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
