#!/usr/bin/env bash
# SessionStart hook.
#
# Three jobs.
#
# 1. Check what a project settings file takes away. An allow rule weakens a
#    global deny or ask rule whenever its own glob covers what that rule gates,
#    a Bash rule reaching a gated path bypasses a rule on Edit entirely, and a
#    defaultMode of acceptEdits or bypassPermissions switches off every ask rule
#    at once. All three are compared against the rules in ~/.claude/settings.json
#    as derived by deny-regex.py at runtime, so this script keeps no copy and an
#    addition made during an intake (0.4) reaches the check automatically.
#
# 2. Check that the guardrail itself is actually installed and working. An
#    earlier release documented curl install URLs that returned 404, and
#    `curl -o` without --fail happily wrote the string "404: Not Found" into
#    each hook. The hooks stayed present, executable, and completely inert for
#    weeks. A guardrail that cannot detect its own absence is not a guardrail,
#    so that case is now checked explicitly at every session start.
#
# 3. Check the subagent definitions A9 relies on, and what an enabled plugin
#    contributes, since a plugin is a third source of hooks and definitions
#    beside the user and project levels: that the shared set in
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

# The project root, not the working directory. A session started in a
# subdirectory has a $(pwd) with no .claude in it, and every check keyed on that
# path then reads nothing and reports nothing: the project settings file, the
# project agent definitions and the project half of the plugin check all skipped
# in silence, while Claude Code itself was loading them from the root.
# require-intake.sh already resolves this properly; two hooks did not inherit it.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT=$(pwd)
PROJECT_ROOT=$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P) || PROJECT_ROOT=$(pwd)


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
if [ -f "$LIB" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && DENY_PATTERNS+=("$line")
  done < <(python3 "$LIB" 2>/dev/null || true)
fi

# bash 3.2, which macOS ships, treats an empty array as unset under `set -u`,
# so every expansion below uses the ${A[@]+"${A[@]}"} form. Without it this
# script aborted on any machine where the pattern list came back empty, and a
# SessionStart hook that aborts fails silently.
if [ ${#DENY_PATTERNS[@]} -eq 0 ]; then
  WARNINGS+=("No deny patterns could be derived from ~/.claude/settings.json: the deny list is empty, unreadable, or malformed.")
fi

# What a project settings file can take away, and whether it does.
#
# This used to compare the text of a project's allow rules against regex
# fragments of the global rules. That catches a project rule spelling the exact
# gated path and misses a wider one covering it, which is the wrong way round:
# Edit(~/.claude/**) contains no literal "~/.claude/hooks/" and so slipped past
# the rule guarding the hooks. It also enumerated the commands that write, which
# is enumerating badness, and it could not tell "no allow rules" from "this file
# could not be parsed", so a malformed settings file passed in silence. And it
# never looked at defaultMode, which switches off every ask rule at once, more
# completely than any allow rule can.
#
# So the comparison is on capabilities now. Each global rule carries a
# representative path it gates; a project allow rule weakens it when that rule's
# own glob matches that path, whether or not it names it. A Bash rule is judged
# separately, because a shell command reaching a gated path bypasses a rule on
# Edit entirely, and it is reported unless its command is one of a short list
# that cannot write.
#
# Paths and settings files are passed as arguments; nothing is pasted into the
# program text (B2, applied to OS commands).
PROJECT_PY=$(cat <<'PYEOF'
import json
import os
import re
import sys
from fnmatch import fnmatchcase

home = sys.argv[1]

FILE_TOOLS = {'Read', 'Edit', 'Write', 'NotebookEdit'}

# Commands that cannot modify a file. Anything absent is reported, which is the
# inverse of the previous version: that one listed the commands that write, and
# every command it had not thought of passed in silence. `bash` is deliberately
# absent. Running a script that lives in a gated directory is exactly the
# channel a rule on Edit cannot see.
READ_ONLY_COMMANDS = {
    # find writes with -delete and -exec; less and more run shell
    # escapes with !command. Neither belongs on a read-only list.
    'cat', 'head', 'tail', 'wc', 'grep', 'egrep', 'fgrep',
    'rg', 'ls', 'stat', 'file', 'diff', 'cmp', 'md5', 'shasum',
    'sha256sum', 'echo', 'printf', 'true', 'test',
}

WEAKENING_MODES = {'acceptEdits', 'bypassPermissions'}

# A read-only command stops being read-only the moment the shell is asked to do
# something with its output or to run a second command. `echo kwaad >
# check-destructive.sh` is `echo`, and it overwrites the hook that enforces
# everything else. So the command is only treated as harmless when its first
# word is read-only AND it contains none of these.
SHELL_CONSTRUCTS = ('>', '|', ';', '&', '`', '$(', '\n')


def expand(path):
    if path.startswith('~/'):
        return home + '/' + path[2:]
    if path.startswith('//'):
        return '/' + path[2:]
    for prefix in ('$HOME/', '${HOME}/'):
        if path.startswith(prefix):
            return home + '/' + path[len(prefix):]
    return path


def as_pattern(path):
    # ** and * both become fnmatch's *, which spans separators: the comparison
    # over-matches rather than under-matches, which is the safe direction.
    return expand(path).replace('**', '*')


def matches(probe, pattern):
    if not probe or not pattern:
        return False
    # Both spellings. A case-insensitive filesystem is the normal case on
    # macOS, and comparing case-sensitively there is how the intake gate once
    # switched itself off.
    return (fnmatchcase(probe, pattern)
            or fnmatchcase(probe.lower(), pattern.lower()))


def normalise(command):
    """Make a shell rule comparable to a path, as far as text allows.

    This stays a heuristic and is documented as one. It removes the quoting and
    the redundant separators that hid a gated path from a substring test, but a
    command can always reach a path this cannot see: through a variable it sets
    itself, a cd, a symlink, or a script it calls. The file-tool branch above
    compares capabilities; this branch compares spellings, and the difference is
    stated rather than glossed.
    """
    text = command.replace('"', '').replace("'", '')
    text = text.replace('${HOME}', home).replace('$HOME', home)
    while '/./' in text:
        text = text.replace('/./', '/')
    while '//' in text:
        text = text.replace('//', '/')
    return text


def parse(rule):
    match = re.match(r'^([A-Za-z]+)\((.*)\)$', rule)
    if match:
        return match.group(1), match.group(2)
    # A rule with no specifier is the tool itself: Edit, or Bash, allows
    # everything that tool can do. It used to parse to an empty path, which
    # matched no probe and no stem, so the broadest rule in the language was
    # the one form this check could not see at all.
    return rule, '**'


gated = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        gated.append(json.loads(line))
    except Exception:
        pass

if not gated:
    print('W:no deny or ask rules could be derived from ~/.claude/settings.json, '
          'so no project settings file was compared against anything.')

for path in sys.argv[2:]:
    if not os.path.isfile(path):
        continue
    try:
        with open(path) as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            raise ValueError('not an object')
    except Exception as exc:
        print('W:%s could not be parsed (%s), so it is unverified whether it '
              'weakens the global rules.' % (path, exc.__class__.__name__))
        continue

    permissions = data.get('permissions')
    permissions = permissions if isinstance(permissions, dict) else {}

    mode = permissions.get('defaultMode')
    if mode in WEAKENING_MODES:
        print('W:%s sets defaultMode to %s, which switches off every ask rule '
              'in this project at once, including the ones guarding the '
              "guardrail's own files. That is broader than any allow rule."
              % (path, mode))

    extra = permissions.get('additionalDirectories')
    if extra:
        print('W:%s sets additionalDirectories to %s. A7 names that as the '
              'instrument that grants writing as well as reading, and it is '
              'outside the allow and ask lists entirely, so nothing else here '
              'reports it.' % (path, extra))

    if data.get('mcpServers') or os.path.isfile(
            os.path.join(os.path.dirname(os.path.dirname(path)), '.mcp.json')):
        print('W:%s belongs to a project that brings its own MCP servers. Their '
              'responses are untrusted input under A3 and their scope is not '
              'covered by anything in this file.' % path)

    if data.get('hooks'):
        print('W:%s registers hooks of its own. They run in every session in '
              'this project alongside the ones from ~/.claude/settings.json, '
              'and nothing here reviews them. Read them before trusting this '
              'session.' % path)

    allow = permissions.get('allow')
    allow = [r for r in allow if isinstance(r, str)] if isinstance(allow, list) else []

    for rule in allow:
        tool, inner = parse(rule)

        if tool in FILE_TOOLS:
            pattern = as_pattern(inner)
            covered = []
            for record in gated:
                if record.get('tool') != tool:
                    continue
                candidates = record.get('probes') or [record.get('probe', '')]
                if any(matches(probe, pattern) for probe in candidates):
                    covered.append('%s(%s) in the %s list'
                                   % (record['tool'], record['path'],
                                      record['list']))
            if covered:
                # One warning per allow rule, not one per rule it covers: the
                # wider the project rule, the more global rules it swallows, and
                # a burst of near-identical lines is how a real finding gets
                # skimmed past.
                print('W:%s allows %s, which covers what %s gates. An allow '
                      'rule does not have to name the gated path to take it '
                      'away; it only has to match it.'
                      % (path, rule, ', '.join(covered)))
            continue

        if tool != 'Bash':
            continue

        command = inner
        if command == '**':
            print('W:%s allows Bash with no command specified, which is every '
                  'shell command in this project, including any that writes '
                  'into the directories the global ask rules gate.' % path)
            continue
        first = ''
        for token in command.split():
            if '=' in token and not token.startswith('-'):
                continue
            first = os.path.basename(token)
            break

        reported = False
        for record in gated:
            if record.get('tool') not in FILE_TOOLS:
                continue
            # The variants already carry every spelling deny-regex.py knows
            # about: ~/, the expanded home, //, $HOME and ${HOME}. Expanding
            # them again here, and the command with them, is what made this
            # miss a rule written with a tilde, which is the spelling a person
            # actually types.
            hit = False
            haystack = normalise(command)
            for variant in record.get('variants', []):
                stem = normalise(variant).split('*')[0].rstrip('/')
                if len(stem) > 1 and stem in haystack:
                    hit = True
                    break
            harmless = (first in READ_ONLY_COMMANDS
                        and not any(c in command for c in SHELL_CONSTRUCTS))
            if not hit or harmless:
                continue
            print('W:%s allows the shell command %s, which reaches a path that '
                  '%s(%s) in the global %s list gates. A shell rule is not '
                  'stopped by a rule on Edit or Read, so that confirmation never '
                  'happens in this project. Remove the standing approval, or '
                  'answer the question each time.'
                  % (path, rule, record['tool'], record['path'], record['list']))
            reported = True
            break

        if reported:
            continue

        for record in gated:
            if record.get('tool') != 'Bash':
                continue
            fragment = re.escape(record['path']).replace(r'\*', '.*')
            if re.search(fragment, command, re.IGNORECASE):
                print('W:%s allows %s, which matches Bash(%s) in the global %s '
                      'list.' % (path, rule, record['path'], record['list']))

print('OK')
PYEOF
)

GATED_JSON=""
if [ -f "$LIB" ]; then
  GATED_JSON=$(python3 "$LIB" --format json 2>/dev/null || true)
  GATED_JSON="$GATED_JSON
$(python3 "$LIB" --list ask --format json 2>/dev/null || true)"
fi

PROJECT_REPORT=$(printf '%s\n' "$GATED_JSON" | python3 -c "$PROJECT_PY" "$HOME" \
  "$PROJECT_ROOT/.claude/settings.json" "$PROJECT_ROOT/.claude/settings.local.json" 2>/dev/null || true)

# A missing terminal OK means no verdict was reached, which is not the same as
# nothing to report and must not read like it.
if [ "$(printf '%s\n' "$PROJECT_REPORT" | tail -n 1)" != "OK" ]; then
  WARNINGS+=("The project settings files could not be checked, so it is unverified whether this project weakens the global deny or ask rules.")
else
  while IFS= read -r LINE; do
    case "$LINE" in
      W:*) WARNINGS+=("${LINE#W:}") ;;
    esac
  done <<< "$PROJECT_REPORT"
fi

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
from fnmatch import fnmatchcase

home = sys.argv[1]
prefixes = ('~/', '//' + home.lstrip('/') + '/', home + '/')

needed = [
    ('Read(~/.claude/CLAUDE.md)',    '.claude/CLAUDE.md'),
    ('Read(~/.claude/settings.json)', '.claude/settings.json'),
    ('Read(~/.claude/agents/**)',    '.claude/agents/example.md'),
    ('Read(~/.claude/hooks/**)',     '.claude/hooks/example.sh'),
]

# The rules that gate writing the guardrail itself, and the two files next to
# settings.json that hold tokens. These are checked for presence because the
# documented update flow deliberately leaves settings.json alone: an installer
# who does not merge them by hand ends up running an install that both
# documents describe and the machine does not have.
REQUIRED_ASK = [
    'Edit(~/.claude/hooks/**)', 'Write(~/.claude/hooks/**)',
    'Edit(~/.claude/agents/**)', 'Write(~/.claude/agents/**)',
    'Edit(~/.claude/settings.json)', 'Write(~/.claude/settings.json)',
    'Edit(~/.claude/CLAUDE.md)', 'Write(~/.claude/CLAUDE.md)',
]
REQUIRED_DENY = [
    'Read(~/.claude/.credentials.json)', 'Read(~/.claude.json)',
]
forbidden = [
    '.claude/projects/other-project/session.jsonl',
    '.claude/logs/tool-calls.log',
    '.claude/sessions/state.json',
    '.claude/.credentials.json',
]

try:
    with open(os.path.join(home, '.claude', 'settings.json')) as f:
        permissions = json.load(f).get('permissions', {})
    allow = permissions.get('allow', [])
    ask = [r for r in permissions.get('ask', []) if isinstance(r, str)]
    deny = [r for r in permissions.get('deny', []) if isinstance(r, str)]
    missing_ask = [r for r in REQUIRED_ASK if r not in ask]
    missing_deny = [r for r in REQUIRED_DENY if r not in deny]
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
    def covers(probe, pattern):
        # Case-sensitively and case-insensitively both: a case-insensitive
        # filesystem is the normal case on macOS, and comparing only one way
        # there is how the intake gate once switched itself off.
        return (fnmatchcase(probe, pattern)
                or fnmatchcase(probe.lower(), pattern.lower()))

    missing = [r for r, probe in needed
               if not any(covers(probe, p) for _, p in patterns)]
    wide = sorted({rule for rule, p in patterns
                   for probe in forbidden if covers(probe, p)})
except Exception:
    pass
else:
    if missing:
        print('W:~/.claude/settings.json is missing these permissions.allow '
              'rules: ' + ', '.join(missing) + '. The instructions are still '
              'loaded into this session, but opening those files will be '
              'blocked in every project that has not approved it locally.')
    if missing_ask:
        print('W:~/.claude/settings.json is missing these permissions.ask '
              'rules: ' + ', '.join(missing_ask) + '. Writing the hooks, the '
              'subagent definitions or the settings themselves then happens '
              'without a confirmation, and whoever writes those decides what '
              'every later session may do. Updating leaves settings.json alone '
              'on purpose, so these have to be merged by hand.')
    if missing_deny:
        print('W:~/.claude/settings.json is missing these permissions.deny '
              'rules: ' + ', '.join(missing_deny) + '. Those are the files next '
              'to settings.json that hold tokens.')
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

for DIR in "$HOME/.claude/agents" "$PROJECT_ROOT/.claude/agents"; do
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
    # A project definition wins over a user one with the same name, so a
    # repository can replace a shared subagent without saying so. A9 says to
    # read an unexpected .claude/agents before trusting the session; this is
    # the case where the file is not unexpected but its contents are.
    if [ "$DIR" != "$HOME/.claude/agents" ] \
       && [ -f "$HOME/.claude/agents/$(basename "$F")" ]; then
      WARNINGS+=("$F replaces the shared subagent definition of the same name for this project. Read it before trusting this session (A9).")
    fi
    if ! grep -qE '^tools:' "$F"; then
      WARNINGS+=("$F declares no tools: line, which is an unbounded scope by another name (A9).")
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
  "$PROJECT_ROOT/.claude/settings.json" \
  "$PROJECT_ROOT/.claude/settings.local.json" 2>/dev/null || true)

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
  # The session is told first. Appending to the log came first before, and a
  # log directory that could not be written aborted the script under set -e,
  # so the one run that most needed to say something said nothing at all.
  echo "WARNING, possible weakening of the guardrails in this session:"
  for W in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
    echo "- $W"
  done
  echo "Verify this with /status (the 'Setting sources' line) before performing any destructive or sensitive action, and tell the user explicitly if an override turns out to be active."

  {
    echo "$(date -Iseconds) session in $PROJECT_ROOT"
    for W in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
      echo "  - $W"
    done
  } >> "$WARN_LOG" 2>/dev/null || true
fi

exit 0
