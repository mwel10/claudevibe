#!/usr/bin/env bash
# SubagentStop hook.
#
# Writes a receipt every time one of the A9 subagents finishes: which agent, in
# which project, when, against which commit, and against which working tree.
#
# The tree fingerprint is the part that matters. A receipt that only records a
# timestamp says "a review happened once", which stops being true the moment the
# code changes. A receipt bound to `git diff HEAD` expires by itself: change a
# line and the receipt no longer matches the tree it was written for. That is
# what lets a later gate distinguish evidence from decoration.
#
# A receipt proves that an agent ran. It cannot prove that it ran well, so the
# first part of the agent's own answer is stored alongside it, to leave
# something a human can actually look at. See "What it doesn't do" in the
# README.
#
# This hook never blocks anything. It only records.

set -uo pipefail

RECEIPTS="$HOME/.claude/logs/agent-receipts"
INPUT=$(cat)

PYCODE=$(cat <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

RECEIPTS = sys.argv[1]

# Only the agents A9 defines. Explore, Plan and general-purpose runs are not
# evidence of anything the intake or the review depends on.
TRACKED = {
    "intake-scout",
    "threat-modeller",
    "security-reviewer",
    "dependency-checker",
    "untrusted-reader",
}

try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

agent = (data.get("agent_type") or "").strip()
if agent not in TRACKED:
    sys.exit(0)

cwd = data.get("cwd") or os.getcwd()


def git(*args):
    try:
        out = subprocess.run(
            ("git", "-C", cwd) + args,
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return out.stdout


project = (git("rev-parse", "--show-toplevel") or "").strip() or cwd
head = (git("rev-parse", "HEAD") or "").strip() or None
diff = git("diff", "HEAD")
diff_sha = hashlib.sha256(diff.encode()).hexdigest() if diff is not None else None

slug = "".join(c if c.isalnum() or c in "._-" else "_" for c in project)
target_dir = os.path.join(RECEIPTS, slug)
os.makedirs(target_dir, exist_ok=True)

summary = (data.get("last_assistant_message") or "").strip()

receipt = {
    "agent": agent,
    "agent_id": data.get("agent_id"),
    "project": project,
    "cwd": cwd,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "git_head": head,
    "diff_sha256": diff_sha,
    "summary": summary[:1000],
    "summary_truncated": len(summary) > 1000,
}

path = os.path.join(target_dir, agent + ".json")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(receipt, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
)

printf '%s' "$INPUT" | python3 -c "$PYCODE" "$RECEIPTS" 2>/dev/null

exit 0
