#!/usr/bin/env bash
# SessionStart hook.
#
# Three jobs.
#
# 1. Check whether a project-level .claude/settings.json or
#    .claude/settings.local.json contains an allow rule that could weaken a
#    global deny rule from ~/.claude/settings.json. Patterns come from
#    deny-regex.py at runtime, so this script keeps no copy of the deny list:
#    an addition made during an intake (0.4) reaches this check automatically.
#
# 2. Check that the guardrail itself is actually installed and working. An
#    earlier release documented curl install URLs that returned 404, and
#    `curl -o` without --fail happily wrote the string "404: Not Found" into
#    each hook. The hooks stayed present, executable, and completely inert for
#    weeks. A guardrail that cannot detect its own absence is not a guardrail,
#    so that case is now checked explicitly at every session start.
#
# 3. Check the subagent definitions A9 relies on: that the shared set in
#    ~/.claude/agents is installed at all, and that no definition, user-level
#    or project-level, gives itself a permission mode that cannot ask before a
#    destructive action. A subagent's tool scope lives in its own frontmatter
#    rather than in settings.json, so nothing else looks at it.
#
# Known limit: a hook cannot invoke the interactive /status command itself.
# This script is the closest technical alternative; /status remains the
# manual check to run after editing any settings file, see A7 in CLAUDE.md.

set -euo pipefail

HOOK_DIR="$HOME/.claude/hooks"
LIB="$HOOK_DIR/lib/deny-regex.py"
WARN_LOG="$HOME/.claude/logs/settings-warnings.log"
mkdir -p "$(dirname "$WARN_LOG")"

WARNINGS=()

# --- 1. Is the guardrail itself intact? --------------------------------------

for HOOK in check-destructive.sh log-tool-call.sh verify-settings.sh \
            require-intake.sh record-agent-run.sh scope-untrusted.sh; do
  F="$HOOK_DIR/$HOOK"
  if [ ! -f "$F" ]; then
    WARNINGS+=("$F is missing: that part of the guardrail is not running.")
    continue
  fi
  if [ ! -x "$F" ]; then
    WARNINGS+=("$F is not executable: the hook cannot run.")
  fi
  # A hook that is a downloaded error page, or is implausibly short, is inert.
  if head -c 200 "$F" | grep -qiE '404|not found|<html'; then
    WARNINGS+=("$F does not look like a script, it looks like a downloaded error page. Reinstall it with 'curl --fail'.")
  elif [ "$(wc -c < "$F" | tr -d ' ')" -lt 100 ]; then
    WARNINGS+=("$F is suspiciously small ($(wc -c < "$F" | tr -d ' ') bytes) and is probably not the real hook.")
  fi
done

if [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
  WARNINGS+=("$HOME/.claude/CLAUDE.md is missing: the instruction layer is not loaded in this session.")
elif head -c 200 "$HOME/.claude/CLAUDE.md" | grep -qiE '404|not found|<html'; then
  WARNINGS+=("$HOME/.claude/CLAUDE.md looks like a downloaded error page rather than the instructions. Reinstall it with 'curl --fail'.")
fi

if [ ! -f "$LIB" ]; then
  WARNINGS+=("$LIB is missing: check-destructive.sh cannot derive its patterns and will block every Bash call until this is fixed.")
fi

# --- 2. Load the deny patterns ------------------------------------------------

DENY_PATTERNS=()
ASK_PATTERNS=()
if [ -f "$LIB" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && DENY_PATTERNS+=("$line")
  done < <(python3 "$LIB" 2>/dev/null || true)
  # An allow rule in a project neutralises an ask rule exactly as effectively as
  # it neutralises a deny rule, and until now only the deny half was compared
  # against anything. A standing project approval for, say, copying a file into
  # ~/.claude/hooks is a permanent hole in the confirmation the ask rules exist
  # to create, and it is invisible precisely because it lives in a file nobody
  # rereads.
  while IFS= read -r line; do
    [ -n "$line" ] && ASK_PATTERNS+=("$line")
  done < <(python3 "$LIB" --list ask 2>/dev/null || true)
fi

# bash 3.2, which macOS ships, treats an empty array as unset under `set -u`,
# so every expansion below uses the ${A[@]+"${A[@]}"} form. Without it this
# script aborted on any machine where the pattern list came back empty, and a
# SessionStart hook that aborts fails silently.
if [ ${#DENY_PATTERNS[@]} -eq 0 ]; then
  WARNINGS+=("No deny patterns could be derived from ~/.claude/settings.json: the deny list is empty, unreadable, or malformed.")
fi

# The settings path is passed as an argument rather than pasted into the
# program text. It is derived from the working directory, so a directory whose
# name contains a quote would break the program and make this check pass
# silently, and one containing a quote followed by Python would run it, in a
# hook that fires at every session start. B2 forbids building a query by
# concatenation and says it applies to OS commands; a `python3 -c` program is
# one. record-agent-run.sh already does it this way.
READ_ALLOW_PY=$(cat <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        allow = json.load(f).get('permissions', {}).get('allow', [])
    print('\n'.join(r for r in allow if isinstance(r, str)))
except Exception:
    pass
PY
)

check_file_for_overrides() {
  local FILE="$1"
  [ -f "$FILE" ] || return 0

  local ALLOW_BLOCK
  ALLOW_BLOCK=$(python3 -c "$READ_ALLOW_PY" "$FILE" 2>/dev/null || echo "")

  [ -z "$ALLOW_BLOCK" ] && return 0

  for PATTERN in ${DENY_PATTERNS[@]+"${DENY_PATTERNS[@]}"}; do
    if echo "$ALLOW_BLOCK" | grep -qiE "$PATTERN"; then
      WARNINGS+=("$FILE contains an allow rule matching deny pattern '$PATTERN' from ~/.claude/settings.json.")
    fi
  done

  # The path comparison is deliberately tool-blind, because the point of the
  # ask rules on ~/.claude is that a Bash rule writing the same file bypasses
  # an Edit rule entirely. The cost of that is a false positive on a rule that
  # merely runs something at a gated path, and a warning that is always on is a
  # warning that gets clicked away, so a matching Bash rule is only reported
  # when it also looks like it writes. The list errs towards warning.
  local MATCHED WRITERS
  for PATTERN in ${ASK_PATTERNS[@]+"${ASK_PATTERNS[@]}"}; do
    MATCHED=$(echo "$ALLOW_BLOCK" | grep -iE "$PATTERN" || true)
    [ -z "$MATCHED" ] && continue
    WRITERS=$(echo "$MATCHED" | grep -viE '^Bash\(' || true)
    WRITERS="$WRITERS
$(echo "$MATCHED" | grep -iE '^Bash\(.*(cp |mv |tee |chmod|curl|wget|install |ln |sed -i|dd |truncate|>)' || true)"
    [ -z "$(printf '%s' "$WRITERS" | tr -d '[:space:]')" ] && continue
    WARNINGS+=("$FILE contains an allow rule matching ask pattern '$PATTERN' from ~/.claude/settings.json, so the confirmation that rule exists to create never happens in this project. The rule: $(printf '%s' "$WRITERS" | tr -s '\n' ' ' | sed 's/^ *//')")
  done
}

check_file_for_overrides "$(pwd)/.claude/settings.json"
check_file_for_overrides "$(pwd)/.claude/settings.local.json"

if [ ! -f "$HOME/.claude/settings.json" ]; then
  WARNINGS+=("~/.claude/settings.json is missing: the global deny/ask rules and hooks are not active in this session.")
else
  # Can a session actually open the baseline's own files?
  #
  # ~/.claude/CLAUDE.md is loaded into context at session start, outside the
  # permission system, so the instructions are present regardless. Opening it
  # as a file is a separate question, and so are the subagent definitions and
  # the hooks: all of them lie outside every project directory, so a Read on
  # them prompts in the default mode and is refused outright in dontAsk mode.
  # An approval given in one project is written to that project's own
  # .claude/settings.local.json and does not travel, which is exactly how this
  # went unnoticed: the projects where it had been approved worked, and every
  # new one silently did not.
  # Two questions, not one. Can a session open the four files the baseline
  # itself needs, and does the allow list reach further than those four? An
  # earlier version of this check asked only the first, and was satisfied by
  # Read(~/.claude/**) — the exact over-broad rule A7 spends a paragraph
  # warning against, because it also hands every session the transcripts of
  # every other project under ~/.claude/projects/. A check that passes on the
  # configuration its own document forbids is checking the less important half.
  #
  # Both questions are answered by probing: each allow rule is turned into a
  # match pattern and tested against one representative path per file that
  # must be reachable, and against paths that must not be.
  BASELINE_PY=$(cat <<'PY'
import json, os, sys
from fnmatch import fnmatch

home = sys.argv[1]
prefixes = ('~/', '//' + home.lstrip('/') + '/', home + '/')

needed = [
    ('Read(~/.claude/CLAUDE.md)',    '.claude/CLAUDE.md'),
    ('Read(~/.claude/settings.json)', '.claude/settings.json'),
    ('Read(~/.claude/agents/**)',    '.claude/agents/example.md'),
    ('Read(~/.claude/hooks/**)',     '.claude/hooks/example.sh'),
]
forbidden = [
    '.claude/projects/other-project/session.jsonl',
    '.claude/logs/tool-calls.log',
    '.claude/sessions/state.json',
    '.claude/.credentials.json',
]

try:
    with open(os.path.join(home, '.claude', 'settings.json')) as f:
        allow = json.load(f).get('permissions', {}).get('allow', [])
    patterns = []
    for rule in allow:
        if not isinstance(rule, str):
            continue
        if not rule.startswith('Read(') or not rule.endswith(')'):
            continue
        path = rule[5:-1]
        for prefix in prefixes:
            if path.startswith(prefix):
                # ** and * both become fnmatch's *, which spans separators.
                patterns.append((rule, path[len(prefix):].replace('**', '*')))
                break
    missing = [r for r, probe in needed
               if not any(fnmatch(probe, p) for _, p in patterns)]
    wide = sorted({rule for rule, p in patterns
                   for probe in forbidden if fnmatch(probe, p)})
except Exception:
    pass
else:
    if missing:
        print('W:~/.claude/settings.json is missing these permissions.allow '
              'rules: ' + ', '.join(missing) + '. The instructions are still '
              'loaded into this session, but opening those files will be '
              'blocked in every project that has not approved it locally.')
    if wide:
        print('W:~/.claude/settings.json has a Read rule reaching past the '
              "baseline's own files: " + ', '.join(wide) + '. That also grants '
              'every session the transcripts of every other project under '
              '~/.claude/projects/, plus the logs and session state. Narrow it '
              'to the four paths named in A7.')
    print('OK')
PY
)

  BASELINE_REPORT=$(python3 -c "$BASELINE_PY" "$HOME" 2>/dev/null || true)

  # The last line is OK only if the program reached its end. Anything else,
  # including no output at all because python3 is missing or died, is an
  # unverified answer and warns rather than passing quietly.
  if [ "$(printf '%s\n' "$BASELINE_REPORT" | tail -n 1)" != "OK" ]; then
    WARNINGS+=("The permissions.allow list in ~/.claude/settings.json could not be checked, so it is unverified whether this session can open the baseline's own files or whether the rules reach further than they should.")
  else
    while IFS= read -r LINE; do
      case "$LINE" in
        W:*) WARNINGS+=("${LINE#W:}") ;;
      esac
    done <<< "$BASELINE_REPORT"
  fi
fi

# --- 3. Are the subagent definitions present and sound? -----------------------
#
# A9 makes subagents the default way of working, and a subagent's tool scope
# lives in its own frontmatter rather than in settings.json. Two things are
# worth catching at session start: the shared definitions silently not being
# installed, and a definition that hands itself a permission mode nothing can
# interrupt. A project-level file wins over a user-level one with the same
# name, so both directories are checked.

if [ ! -d "$HOME/.claude/agents" ]; then
  WARNINGS+=("$HOME/.claude/agents is missing: the shared subagent definitions from A9 are not available in this session.")
fi

for DIR in "$HOME/.claude/agents" "$(pwd)/.claude/agents"; do
  [ -d "$DIR" ] || continue
  for F in "$DIR"/*.md; do
    [ -f "$F" ] || continue
    if head -c 200 "$F" | grep -qiE '404|not found|<html'; then
      WARNINGS+=("$F looks like a downloaded error page rather than a subagent definition. Reinstall it with 'curl --fail'.")
      continue
    fi
    if grep -qE '^permissionMode:[[:space:]]*(bypassPermissions|dontAsk)' "$F"; then
      WARNINGS+=("$F sets permissionMode to bypassPermissions or dontAsk, which A9 forbids: that subagent cannot ask before a destructive action.")
    fi
  done
done

# --- 4. What do enabled plugins contribute? -----------------------------------
#
# A7 and A9 name two places a hook or a subagent definition can come from, user
# level and project level, and the checks above look at exactly those two. There
# is a third. A plugin enabled in settings.json can carry its own hooks, its own
# subagent definitions and its own MCP servers, it arrives from a marketplace
# repository that nothing here reviews, and it is not pinned. That a plugin
# declares only skills today says nothing about its next version. This check
# reports the executable surface a plugin actually contributes, so an update
# that adds a hook becomes visible at the next session start instead of never.

PLUGIN_PY=$(cat <<'PY'
import glob
import json
import os
import sys

home = sys.argv[1]
cache = os.path.join(home, '.claude', 'plugins', 'cache')

enabled = {}
for path in sys.argv[2:]:
    try:
        with open(path) as f:
            for key, value in (json.load(f).get('enabledPlugins') or {}).items():
                if value:
                    enabled.setdefault(key, path)
    except Exception:
        continue


def installed_copies(name):
    # The key is plugin@marketplace, the cache is marketplace/plugin/version.
    # Both orders are tried rather than relying on the spelling of one key.
    left, _, right = name.partition('@')
    found = []
    for pattern in (os.path.join(cache, right, left, '*'),
                    os.path.join(cache, left, right, '*')):
        for root in glob.glob(pattern):
            manifest = os.path.join(root, '.claude-plugin', 'plugin.json')
            if os.path.isfile(manifest):
                found.append((root, manifest))
    return found


for name in sorted(enabled):
    copies = installed_copies(name)
    if not copies:
        print('W:the plugin %s is enabled in %s, but no installed copy of it '
              'could be found, so what it contributes to this session could not '
              'be established.' % (name, enabled[name]))
        continue
    for root, manifest in copies:
        try:
            with open(manifest) as f:
                data = json.load(f)
        except Exception:
            print('W:the manifest of plugin %s could not be read, so what it '
                  'contributes could not be established.' % name)
            continue
        contributes = []
        for key, label in (('hooks', 'hooks'),
                           ('agents', 'subagent definitions'),
                           ('mcpServers', 'MCP servers')):
            if data.get(key) and label not in contributes:
                contributes.append(label)
        for entry, label in (('hooks', 'hooks'),
                             ('agents', 'subagent definitions')):
            if os.path.isdir(os.path.join(root, entry)) and label not in contributes:
                contributes.append(label)
        if (os.path.isfile(os.path.join(root, '.mcp.json'))
                and 'MCP servers' not in contributes):
            contributes.append('MCP servers')
        if contributes:
            print('W:plugin %s version %s contributes %s. Those act in every '
                  'session and are not covered by the checks above, which look '
                  'only at ~/.claude/agents and at this project. Read them '
                  'before trusting this session, as A9 says for an unexpected '
                  '.claude/agents.'
                  % (name, data.get('version', 'unknown'),
                     ' and '.join(contributes)))
print('OK')
PY
)

PLUGIN_REPORT=$(python3 -c "$PLUGIN_PY" "$HOME" \
  "$HOME/.claude/settings.json" \
  "$(pwd)/.claude/settings.json" \
  "$(pwd)/.claude/settings.local.json" 2>/dev/null || true)

if [ "$(printf '%s\n' "$PLUGIN_REPORT" | tail -n 1)" != "OK" ]; then
  WARNINGS+=("The enabled plugins could not be checked, so it is unverified whether one of them contributes hooks, subagent definitions or MCP servers to this session.")
else
  while IFS= read -r LINE; do
    case "$LINE" in
      W:*) WARNINGS+=("${LINE#W:}") ;;
    esac
  done <<< "$PLUGIN_REPORT"
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  {
    echo "$(date -Iseconds) session in $(pwd)"
    for W in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
      echo "  - $W"
    done
  } >> "$WARN_LOG"

  echo "WARNING, possible weakening of the guardrails in this session:"
  for W in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
    echo "- $W"
  done
  echo "Verify this with /status (the 'Setting sources' line) before performing any destructive or sensitive action, and tell the user explicitly if an override turns out to be active."
fi

exit 0
