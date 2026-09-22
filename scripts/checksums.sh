#!/usr/bin/env bash
# Generate or check SHA256SUMS over the files the README actually installs.
#
#   scripts/checksums.sh            rewrite SHA256SUMS
#   scripts/checksums.sh --check    fail if SHA256SUMS is stale or the list drifted
#
# What this buys, stated plainly, because the addendum asks the question and a
# checksum file is easy to oversell. It gives an installer a way to confirm that
# what arrived over the network is byte-for-byte what a given tag contains, so a
# truncated download, a proxy rewriting a file, or a half-finished install stops
# being silent. Pinning the install to a tag rather than to a moving branch is
# the other half: `main` changes under installers, a tag does not.
#
# What it does not buy: authenticity. SHA256SUMS lives in the same tree as the
# files it covers, so anyone able to write that tree can rewrite both. It is a
# defence against transport and drift, not against a compromised account. The
# thing that would close that gap is a signed tag, and that needs a key this
# repository does not have yet. Say so rather than letting the word "checksum"
# imply more than it carries.
#
# The file list is not maintained here by hand. It is derived from the install
# block in README.md, so the set that is checksummed cannot drift away from the
# set that is installed — which is the failure this repository keeps finding in
# its own checks: measuring one thing and reporting another.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SUMS="SHA256SUMS"

# Every $BASE/... path the install block fetches, plus the agent definitions,
# which the README fetches through a shell loop rather than by literal path.
list_files() {
  # SHA256SUMS is excluded on purpose: the verified-install block fetches it,
  # but a checksum file cannot contain its own hash, and a list derived from
  # the README would otherwise quietly include it and never verify.
  grep -oE '\$BASE/[a-zA-Z0-9._/-]+' README.md \
    | sed 's|\$BASE/||' \
    | grep -v '^agents/$' \
    | grep -v '^SHA256SUMS$' \
    | sort -u

  # for A in intake-scout threat-modeller ...; do curl ... "$BASE/agents/$A.md"
  sed -n 's/^for A in \(.*\); do$/\1/p' README.md \
    | tr ' ' '\n' \
    | grep -v '^$' \
    | sed 's|^|agents/|; s|$|.md|' \
    | sort -u
}

FILES=$(list_files)

if [ -z "$FILES" ]; then
  echo "checksums.sh: no files could be derived from the install block in README.md." >&2
  echo "That means this script is checksumming nothing, which is worse than not running." >&2
  exit 1
fi

MISSING=""
while IFS= read -r F; do
  [ -n "$F" ] || continue
  [ -f "$F" ] || MISSING="$MISSING $F"
done <<< "$FILES"

if [ -n "$MISSING" ]; then
  echo "checksums.sh: the install block names files that do not exist:$MISSING" >&2
  echo "Either the README or the repository is wrong; this is the 404 failure one step earlier." >&2
  exit 1
fi

# shasum on macOS, sha256sum on most Linux. Both emit and accept the same format.
if command -v sha256sum >/dev/null 2>&1; then
  HASH="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH="shasum -a 256"
else
  echo "checksums.sh: neither sha256sum nor shasum is available." >&2
  exit 1
fi

generate() {
  # shellcheck disable=SC2086
  while IFS= read -r F; do
    [ -n "$F" ] && $HASH "$F"
  done <<< "$FILES"
}

if [ "${1:-}" = "--check" ]; then
  if [ ! -f "$SUMS" ]; then
    echo "checksums.sh: $SUMS is missing." >&2
    exit 1
  fi
  CURRENT=$(generate)
  if [ "$CURRENT" = "$(cat "$SUMS")" ]; then
    echo "$SUMS is current: $(printf '%s\n' "$FILES" | grep -c .) files."
    exit 0
  fi
  echo "checksums.sh: $SUMS does not match the working tree." >&2
  echo "A shipped file changed without the checksums being regenerated, or the" >&2
  echo "install block in README.md gained or lost a file. Run scripts/checksums.sh." >&2
  diff <(printf '%s\n' "$CURRENT") "$SUMS" >&2 || true
  exit 1
fi

generate > "$SUMS"
echo "wrote $SUMS: $(grep -c . "$SUMS") files."
