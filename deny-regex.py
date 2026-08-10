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
"""
import json
import os
import re
import sys


def main():
    tool_filter = None
    if "--tool" in sys.argv:
        idx = sys.argv.index("--tool")
        tool_filter = sys.argv[idx + 1]

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

    deny = data.get("permissions", {}).get("deny", [])
    for entry in deny:
        match = re.match(r"^([A-Za-z]+)\((.*)\)$", entry)
        if not match:
            continue
        tool, inner = match.group(1), match.group(2)
        if tool_filter and tool != tool_filter:
            continue
        pattern = re.escape(inner).replace(r"\*", ".*")
        print(pattern)


if __name__ == "__main__":
    main()
