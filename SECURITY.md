# Reporting a security issue

This repository ships a security baseline that other people install into their
own `~/.claude/`. A flaw here does not sit still in a repository: it changes what
a language model with tool access is permitted to do on someone else's machine.
So it is worth reporting, and worth reporting privately first.

## How

Use **[private vulnerability reporting](https://github.com/mwel10/claudevibe/security/advisories/new)**
on this repository. That opens a draft advisory only the maintainer can see. It
needs no email address from either of us.

Please do not open a public issue for something that would let an installed copy
be weakened, until there is a fix or we have agreed there does not need to be
one.

## What counts

The interesting failures in a project like this are rarely memory-safety bugs.
They look like this:

- A way to make a hook inert, or to make it report success on a configuration it
  was written to catch. This repository has shipped that failure four times and
  documents each one in the README; a fifth is a real finding, not a nitpick.
- A way for a project-level file — settings, an agent definition, a plugin — to
  take away a protection the documents say holds.
- A path by which an installer ends up with something other than what the tag
  they installed contains.
- Text in `global-CLAUDE.md` or `agents/*.md` that steers a model into an unsafe
  action. These files are prompt surface by construction, which is recorded as a
  threat in the project addendum rather than treated as an accident.
- Anything the documents claim is enforced that turns out to be advisory. An
  overstatement in `A7`, the README or the addendum is a security defect here,
  because the whole artifact is a set of claims about what holds.

## What is already known

These are recorded as open items in `CLAUDE.md` and do not need a report. A
concrete attack against one of them does.

- Tags are not signed. `SHA256SUMS` and a pinned install cover transport and
  drift, not authenticity: anyone able to write the tree can rewrite both.
- Hooks only see what passes through Claude Code. A file edited in an editor, a
  command run in another terminal, or anything a script does after it starts,
  meets none of this layer.
- `Bash(curl …)`, `Bash(wget …)` and an MCP-provided fetch reach the network
  without passing the fetch prompt.
- The Bash branch of the project-settings comparison matches text, so a command
  reaching a gated path through a variable, a `cd` or a called script is not
  seen.

## What to expect

This is maintained by one person alongside other work. Expect acknowledgement
within five working days, and an honest answer about timing rather than an
optimistic one. If something is not going to be fixed, that will be said plainly
and written into the open items, not left quiet.

## Versions

The latest tag and `main` are the supported versions. There is no backporting;
if a fix matters, it lands on `main` and gets a new tag.

## Verifying what you installed

```bash
VER=v1.0.0
BASE=https://raw.githubusercontent.com/mwel10/claudevibe/$VER
STAGE=$(mktemp -d)
curl --fail --remove-on-error -sSL -o "$STAGE/SHA256SUMS" "$BASE/SHA256SUMS"
```

Fetch the files into `$STAGE` with the same relative paths, then:

```bash
cd "$STAGE" && shasum -a 256 -c SHA256SUMS
```

The README's "Verified install" block does this end to end.
