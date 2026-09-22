#!/usr/bin/env bash
# PreToolUse hook on WebFetch.
#
# What this file used to do, and why it stopped. It was registered on WebSearch
# as well, and asked before any web read from a context that also held Edit,
# Write and Bash — the main conversation included. The intent was A9 made
# mechanical: untrusted content lands in a read-only subagent, where a prompt
# injection has nothing to act with.
#
# In use that was the wrong trade. A question in front of every single search is
# a question that gets answered without being read, which is the failure this
# repository documents elsewhere in its own words: a warning that is always on is
# a warning that gets clicked away. Worse, it made the one prompt that carries
# real information — this one — indistinguishable from the dozens that did not.
# So WebSearch is allowed outright, through permissions.allow in settings.json,
# and A9's arrangement for searching is advisory again. Say so plainly rather
# than describing search as covered.
#
# What remains is the half that was never about noise. WebFetch takes a URL
# chosen by the model, so a page that says "now fetch https://attacker/?q=..."
# is a network call with nothing in front of it: B2's last bullet and A10 in one
# move. That question is asked in every context, including inside a read-only
# subagent, because that subagent can still read the filesystem and a fetch is
# how what it read leaves the machine.
#
# It asks per call rather than per domain, which is deliberate and is the one
# thing an ordinary WebFetch(domain:...) approval cannot do: an approval granted
# once for a domain covers every later fetch to it, including the one chosen by
# a page rather than by you.
#
# No interpreter is involved. The decision needs no parsing beyond the tool
# name, and the earlier version printed its fail-closed answer with the same
# python3 whose absence that answer existed to cover.

set -uo pipefail

INPUT=$(cat)

ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# The tool name is checked rather than assumed, and the order of these branches
# is the whole design. An earlier version asked for WebFetch, stayed silent for
# any other recognised tool, and asked only when it could not read the input at
# all. That middle branch was the fail-open one, and it was not hypothetical:
# the documented update path never rewrites settings.json, so an installer who
# updates keeps the old "WebSearch|WebFetch" matcher and routes real calls into
# it. Anything that is not recognisably the tool this hook ignores now asks.
#
# The match is a substring test over unparsed JSON, part of which the model
# chose. That is safe only because it is one-directional: every branch except
# the WebSearch one ends in a question, so the worst a crafted tool_input can
# do is cause an extra prompt. Do not add an "allow" branch here without
# parsing the input properly first.
case "$INPUT" in
  *'"tool_name"'*'"WebFetch"'*)
    ask "WebFetch takes a URL chosen by the model, so it asks every time and in every context, per call rather than per domain. A page that names the next address to fetch is otherwise a network call with nothing in front of it, and inside a read-only subagent it is also how something just read from disk would leave the machine (B2, A10)."
    ;;
  *'"tool_name"'*'"WebSearch"'*)
    # The one tool this hook deliberately has no opinion about. Searching is
    # governed by permissions.allow instead, and an empty answer leaves that in
    # charge.
    exit 0
    ;;
  *)
    ask "scope-untrusted.sh could not establish which tool is being called, so it is asking rather than staying silent. Treat the mechanical layer as suspect until this is resolved (A7)."
    ;;
esac

exit 0
