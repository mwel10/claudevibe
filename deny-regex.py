#!/usr/bin/env python3
"""
Enige bron van waarheid voor "risicovolle patronen" is permissions.deny in
~/.claude/settings.json. Dit script leest die lijst uit en zet elke regel om
in een regex-fragment: de tool-prefix (Bash(...), Read(...), Edit(...)) wordt
gestript, de rest wordt regex-escaped, en '*' wordt '.*'.

Gebruikt door check-destructive.sh en verify-settings.sh, zodat een wijziging
aan de deny-lijst tijdens een intake (0.4) automatisch in beide hooks
doorwerkt. Geen van beide scripts onderhoudt nog een eigen patronenlijst.

Gebruik:
  deny-regex.py              alle deny-regels, een regex per regel op stdout
  deny-regex.py --tool Bash  alleen regels waarvan de tool-prefix "Bash" is
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
        # Geen settings.json, geen crash: de aanroepende hook handelt dit
        # zelf af (verify-settings.sh waarschuwt al apart als het bestand
        # ontbreekt).
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
