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

# Every probe below builds a fixture under mktemp -d, and several hold a copy of
# the real settings.json and CLAUDE.md. Left behind, each run adds another copy
# of files A7 says may one day carry an env block. They are removed on exit,
# including on interrupt. Deletion is depth-first through find rather than a
# recursive force remove: it is narrower, and it is not a command this
# repository's own deny rules would have to make an exception for.
# The list lives in a file rather than an array. scratch is called as $(scratch),
# which runs it in a subshell, so anything it appends to a shell variable is
# discarded the moment it returns: the first version of this cleanup registered
# nothing and removed nothing, while looking exactly like it worked.
TMPLIST=$(mktemp)
cleanup() {
  local D
  while IFS= read -r D; do
    case "$D" in
      /*/*) [ -d "$D" ] && find "$D" -depth -delete 2>/dev/null || true ;;
    esac
  done < "$TMPLIST"
  rm -f "$TMPLIST" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

scratch() {
  local D
  D=$(mktemp -d)
  printf '%s\n' "$D" >> "$TMPLIST"
  printf '%s' "$D"
}

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
GATE_HOME=$(scratch)
GATE_PROJ=$(scratch)
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
GATE_LINK="$(scratch)/link"
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
ALLOW_HOME=$(scratch)
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
if not sys.argv[3:]:
    # The empty case doubles as the fixture for the ask and deny presence
    # check, so it has to be a settings file that is missing those too.
    data["permissions"]["ask"] = []
    data["permissions"]["deny"] = []
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

ALLOW_OUT=$(allow_case)
case "$ALLOW_OUT" in
  *"permissions.ask"*) ok "the check names the ask rules that gate writing the guardrail when they are absent" ;;
  *) bad "settings.json can lose the ask rules on ~/.claude and nothing says so, while both documents describe them as active" ;;
esac

ALLOW_OUT=$(allow_case "Read(~/.claude/CLAUDE.md)" "Read(~/.claude/settings.json)" \
                       "Read(~/.claude/agents/**)" "Read(~/.claude/hooks/**)")
case "$ALLOW_OUT" in
  *"every web search asks again"*)
    ok "a settings file with the four Read rules but no WebSearch is reported" ;;
  *) bad "WebSearch can drop out of the allow list with nothing saying so, and the search prompt comes back one update later" ;;
esac

ALLOW_OUT=$(allow_case "Read(~/.claude/CLAUDE.md)" "Read(~/.claude/settings.json)" \
                       "Read(~/.claude/agents/**)" "Read(~/.claude/hooks/**)" "WebSearch")
if [ -z "$ALLOW_OUT" ]; then
  ok "allow-list check is quiet on the four rules it asks for"
else
  bad "allow-list check warns about the configuration it documents as correct, so it cannot be satisfied:"
  echo "$ALLOW_OUT" | sed 's/^/          /'
fi

echo "Project overrides"
# What a project settings file asks for, and what it can actually do, in both
# directions. Those are different lists: an allow rule cannot beat a deny or
# ask rule, because rule type is resolved before settings source. Each of these
# probes exists because a review found the previous comparison silent on it:
# it matched rule text, so a wider project rule covering a gated path slipped
# through while the exact one was caught; it listed the commands that write, so
# every command it had not thought of passed; it could not tell a malformed file
# from an empty one; and it never looked at defaultMode, which switches off
# every ask rule at once. HOME and the working directory are both redirected.
OVR_HOME=$(scratch)
OVR_PROJ=$(scratch)
mkdir -p "$OVR_HOME/.claude/hooks/lib" "$OVR_HOME/.claude/agents" "$OVR_PROJ/.claude"
cp "$HOOK_DIR"/*.sh "$OVR_HOME/.claude/hooks/" 2>/dev/null || true
cp "$HOOK_DIR/lib/deny-regex.py" "$OVR_HOME/.claude/hooks/lib/" 2>/dev/null || true
cp "$CLAUDE_DIR/agents"/*.md "$OVR_HOME/.claude/agents/" 2>/dev/null || true
cp "$CLAUDE_DIR/CLAUDE.md" "$OVR_HOME/.claude/CLAUDE.md" 2>/dev/null || true

STRIP_PLUGINS_PY=$(cat <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
data.pop("enabledPlugins", None)
with open(sys.argv[2], "w") as f:
    json.dump(data, f, indent=2)
PYEOF
)
python3 -c "$STRIP_PLUGINS_PY" "$CLAUDE_DIR/settings.json" \
  "$OVR_HOME/.claude/settings.json" 2>/dev/null || true

override() { # $1 = the contents of the project settings file
  printf '%s' "$1" > "$OVR_PROJ/.claude/settings.local.json"
  (cd "$OVR_PROJ" && HOME="$OVR_HOME" bash "$OVR_HOME/.claude/hooks/verify-settings.sh" 2>&1 || true)
}

expect_override() { # $1 = substring wanted or "" for silence, $2 = ok, $3 = fail
  local OUT
  OUT=$(override "$4")
  if [ -z "$1" ]; then
    if [ -z "$OUT" ]; then ok "$2"; else bad "$3"; echo "$OUT" | sed 's/^/          /'; fi
    return
  fi
  case "$OUT" in
    *"$1"*) ok "$2" ;;
    *)      bad "$3" ;;
  esac
}

expect_override "" \
  "a project that takes nothing away raises no override warning" \
  "the override check warns about a project settings file with nothing worth reporting" \
  '{"permissions":{"allow":["Bash(npm test)"]}}'

expect_override "which covers what" \
  "an allow rule covering a gated path is reported even though it never names it" \
  "a wider allow rule goes unreported while the exact one is reported, which is backwards" \
  '{"permissions":{"allow":["Edit(~/.claude/**)"]}}'

expect_override "reaches a path that" \
  "a shell rule writing into a gated directory is reported" \
  "a shell command writing into a gated directory is invisible to the check that guards it" \
  '{"permissions":{"allow":["Bash(touch ~/.claude/hooks/x.sh)"]}}'

expect_override "" \
  "a shell rule that only reads a gated path stays silent" \
  "a read-only command at a gated path warns, and a warning that is always on gets clicked away" \
  '{"permissions":{"allow":["Bash(cat ~/.claude/hooks/x.sh)"]}}'

expect_override "reaches a path that" \
  "a read-only command with a redirection into a gated path is still reported" \
  "echo or cat with a > into a gated path counts as read-only, so the hook that enforces everything else can be overwritten by a rule nobody reads" \
  '{"permissions":{"allow":["Bash(echo x > ~/.claude/hooks/check-destructive.sh)"]}}'

expect_override "reaches a path that" \
  "a gated path spelled with \$HOME is recognised" \
  "a rule written with \$HOME instead of ~ matches nothing, so the spelling decides whether the check works" \
  '{"permissions":{"allow":["Bash(cp a $HOME/.claude/hooks/)"]}}'

expect_override "no command specified" \
  "a bare Bash allow rule is reported" \
  "an allow rule of just Bash, which permits every shell command there is, is the one form the check cannot see" \
  '{"permissions":{"allow":["Bash"]}}'

expect_override "which covers what" \
  "a bare tool name is treated as the widest rule it is" \
  "an allow rule of just Edit is treated as matching nothing, so the broadest rule in the language passes" \
  '{"permissions":{"allow":["Edit"]}}'

expect_override "additionalDirectories" \
  "a project granting additionalDirectories is reported" \
  "additionalDirectories grants writing as well as reading and no check mentions it" \
  '{"permissions":{"allow":[],"additionalDirectories":["~/.claude"]}}'

expect_override "reaches a path that" \
  "find with -delete is not treated as a read-only command" \
  "find is on the read-only list although -delete and -exec both write" \
  '{"permissions":{"allow":["Bash(find ~/.claude/hooks -name x -delete)"]}}'

expect_override "defaultMode" \
  "a project defaultMode that switches off every ask rule is reported" \
  "a project can set defaultMode to bypassPermissions and no check mentions it" \
  '{"permissions":{"defaultMode":"bypassPermissions","allow":[]}}'

expect_override "registers hooks of its own" \
  "a project registering its own hooks is reported" \
  "a project can register hooks that run in every session with nothing looking at them" \
  '{"permissions":{"allow":[]},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"x"}]}]}}'

expect_override "could not be parsed" \
  "an unreadable project settings file is reported rather than read as empty" \
  "a malformed project settings file is indistinguishable from one with nothing to report" \
  'not json at all'

echo "Web tools"
# Searching is allowed outright, through permissions.allow, because a question
# in front of every search is one that gets answered without being read. What is
# still asked is the fetch, in every context, because the model chooses its URL.
# Both directions are probed: a hook that asks about everything and a hook that
# asks about nothing are equally useless, and only one of them is obvious.
web() { # $1 = tool name, $2 = agent_type or empty
  if [ -n "$2" ]; then
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","agent_id":"selftest","agent_type":"%s","tool_input":{}}' "$1" "$2"
  else
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "$1"
  fi | bash "$HOOK_DIR/scope-untrusted.sh" 2>/dev/null
}

WEB_OUT=$(web WebFetch "")
case "$WEB_OUT" in
  *'"permissionDecision":"ask"'*|*'"permissionDecision": "ask"'*)
    ok "a fetch from the main conversation asks first" ;;
  *) bad "a fetch is waved through, so a page can name the next address to call with nothing in front of it" ;;
esac

# The hook no longer reads agent_type, so this cannot fail while the probe above
# passes. It stays as a regression guard: if context sensitivity ever comes back,
# this is the case that must not become an allow, because that subagent can read
# the filesystem and a fetch is how what it read would leave the machine.
WEB_OUT=$(web WebFetch untrusted-reader)
case "$WEB_OUT" in
  *'"permissionDecision":"ask"'*|*'"permissionDecision": "ask"'*)
    ok "a fetch asks regardless of which context calls it" ;;
  *) bad "a fetch inside a subagent is allowed, so context sensitivity has come back in the one place it must not" ;;
esac

WEB_OUT=$(web WebSearch "")
if [ -z "$WEB_OUT" ]; then
  ok "a search reaches no decision from this hook, so the allow rule governs it"
else
  bad "the hook still answers for WebSearch, which is the question that was removed for being asked too often"
fi

WEB_OUT=$(printf 'not json' | bash "$HOOK_DIR/scope-untrusted.sh" 2>/dev/null || true)
case "$WEB_OUT" in
  *'"permissionDecision":"ask"'*|*'"permissionDecision": "ask"'*)
    ok "the fetch hook fails closed on unreadable input" ;;
  *) bad "the fetch hook stays silent when it cannot read its own input, so the call proceeds unchecked" ;;
esac

# The hook no longer parses anything, so a machine with no working python3 must
# still get an answer out of it. The earlier version printed its fail-closed
# reply with the same interpreter whose absence that reply existed to cover.
NOPY=$(scratch)
printf '#!/bin/sh\nexit 1\n' > "$NOPY/python3"
chmod +x "$NOPY/python3"
WEB_OUT=$(printf '{"tool_name":"WebFetch"}' \
  | PATH="$NOPY:$PATH" bash "$HOOK_DIR/scope-untrusted.sh" 2>/dev/null || true)
case "$WEB_OUT" in
  *'"permissionDecision":"ask"'*) ok "the fetch hook still asks when python3 cannot run" ;;
  *) bad "with no working python3 the fetch hook emits nothing, so the call proceeds unchecked" ;;
esac

# Searching is only frictionless while the allow rule is there, and the update
# flow deliberately never overwrites settings.json. This used to be a grep for
# the string anywhere in the file, which would have passed just as happily with
# WebSearch sitting in deny — a check printing a conclusion it had not measured,
# which is the failure this repository has now made four times. It parses.
SEARCH_RULE_PY=$(cat <<'PYEOF'
import json, sys
perm = json.load(open(sys.argv[1])).get("permissions", {})


def has(name):
    return "WebSearch" in [r for r in perm.get(name, []) if isinstance(r, str)]


sys.exit(0 if has("allow") and not has("ask") and not has("deny") else 1)
PYEOF
)
if python3 -c "$SEARCH_RULE_PY" "$CLAUDE_DIR/settings.json" 2>/dev/null; then
  ok "WebSearch is in permissions.allow and in neither ask nor deny"
else
  bad "WebSearch is not allowed outright in settings.json, so every search asks again"
fi

echo "Plugins"
# There is a third source of hooks, subagent definitions and MCP servers beside
# user level and project level, and until now nothing looked at it. A plugin
# that ships only skills today can ship a hook in its next version, from a
# marketplace repository that is not pinned and not reviewed here.
PLUG_HOME=$(scratch)
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
