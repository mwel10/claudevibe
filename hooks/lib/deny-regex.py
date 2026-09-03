#!/usr/bin/env python3
"""
The single source of truth for "risky patterns" is permissions.deny in
~/.claude/settings.json. This script reads that list and turns each rule
into a regex fragment: the tool prefix (Bash(...), Read(...), Edit(...)) is
stripped, the rest is regex-escaped, and '*' becomes '.*'.

Used by check-destructive.sh and verify-settings.sh, so a change to the
deny list during an intake (0.4) automatically propagates to both hooks.
Neither script keeps its own pattern list anymore.

Usage:
  deny-regex.py              all deny rules, one regex per line on stdout
  deny-regex.py --tool Bash  only rules whose tool prefix is "Bash"
  deny-regex.py --list ask   read permissions.ask instead of permissions.deny

The --list flag exists because an allow rule in a project can neutralise an
ask rule just as effectively as a deny rule, and only the deny half was ever
compared against anything. The default stays "deny", so every existing caller
keeps its current behaviour.
"""
import json
import os
import re
import sys


def main():
    # A flag given as the last argument used to raise IndexError, which every
    # caller swallows, and an empty ask list warns about nothing at all: the
    # whole comparison would have gone silently inert.
    def flag(name, default=None):
        if name not in sys.argv:
            return default
        idx = sys.argv.index(name) + 1
        if idx >= len(sys.argv):
            sys.exit("%s needs a value" % name)
        return sys.argv[idx]

    tool_filter = flag("--tool")

    list_name = flag("--list", "deny")
    if list_name not in ("deny", "ask"):
        sys.exit("--list takes deny or ask")

    settings_path = os.environ.get(
        "CLAUDE_GLOBAL_SETTINGS", os.path.expanduser("~/.claude/settings.json")
    )
    try:
        with open(settings_path) as f:
            data = json.load(f)
    except Exception:
        # No settings.json, no crash: the calling hook handles this itself
        # (verify-settings.sh already warns separately when the file is
        # missing).
        return

    home = os.path.expanduser("~")
    rules = data.get("permissions", {}).get(list_name, [])
    seen = set()
    for entry in rules:
        match = re.match(r"^([A-Za-z]+)\((.*)\)$", entry)
        if not match:
            continue
        tool, inner = match.group(1), match.group(2)
        if tool_filter and tool != tool_filter:
            continue
        # A rule written with a tilde has to match a rule written out in full,
        # or the comparison misses the case it exists for: a project approval
        # that spells the path as /Users/you/.claude/hooks/ is not caught by a
        # pattern that only knows "~/.claude/hooks/". Claude Code accepts both
        # spellings, so both are emitted.
        variants = [inner]
        if inner.startswith("~/"):
            rest = inner[2:]
            variants.append(home + "/" + rest)
            variants.append("//" + home.lstrip("/") + "/" + rest)
        for variant in variants:
            pattern = re.escape(variant).replace(r"\*", ".*")
            if pattern not in seen:
                seen.add(pattern)
                print(pattern)


if __name__ == "__main__":
    main()
