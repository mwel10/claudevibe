# Safe vibe coding: a CLAUDE.md for people who aren't programmers

I'm not a programmer. I do enjoy vibe coding with Claude — describing what I
want and letting it build. What I didn't enjoy was the nagging feeling that I
had no idea whether what came out was safe.

So I built a `CLAUDE.md`, plus a small set of `settings.json` permissions and
hooks that back it up. Together they turn "please be careful" into rules
Claude actually applies and rules Claude technically cannot skip, and they
make Claude ask me the right questions before it starts, instead of finding
out afterwards that my API key ended up in a public repository.

## What it does

### The instructions: `global-CLAUDE.md`

The file has three parts.

**Part 0 — Project intake.** Before writing code, Claude reads the repository
for what it can determine on its own, then asks a short set of questions: what
this is, who can reach it, what data it touches, where secrets come from, and
whether the thing being built calls a language model itself. It derives the
appropriate security level and threat modelling method from those answers
rather than asking me to pick one, proposes it, and lets me override. The
answers get written into the project's own `CLAUDE.md` so the questions aren't
asked twice.

**Part A — Agent security.** How Claude is allowed to operate. Don't reuse a
credential beyond its task. Ask again before anything destructive, even if I
said "go ahead" earlier. Treat GitHub issues, dependency metadata, and MCP
server responses as untrusted input rather than instructions. Keep tool calls
visible. It ends by turning the PHANTOM-B prompts back on the session itself,
since Claude Code is a language model with tool access and fails in the same
ways as anything else built on one. It also makes delegating to a subagent the
default rather than the exception, and says which one runs when, so the intake
and the review don't depend on me remembering they exist.

**Part B — Secure software development.** What the code has to look like. No
hardcoded secrets, no `.env` in git, no string concatenation in queries, no
hand-rolled crypto. The OWASP Top 10 as a checklist per feature. Rules for
dependencies, scanning, SBOMs, and what to do about a known vulnerability. It
also keeps an AI Bill of Materials: which model built the code and which
models, if any, the application calls at runtime, since a third-party model
endpoint is a dependency and a data flow like any other. It ends with a
handover format, so every delivery comes with a short note on what was
covered and what wasn't.

### Threat modelling the LLM parts: PHANTOM-B

Most of what I build with Claude now calls a language model itself, and STRIDE
doesn't prompt well for that. It asks about spoofing and tampering across a
trust boundary; it has nothing to say about a model that confidently invents a
package name, or that treats a comment in a fetched web page as an
instruction.

So section B5.1 adds [PHANTOM-B](https://shostack.org/), Adam Shostack's
STRIDE analog for LLMs. Eight prompts: **P**rompt injection,
**H**allucination, **A**nthropomorphization, **N**on-explainability,
**T**raining issues, **O**ver-reliance, **M**issing security engineering,
**B**iases. Walk them over each model or agent component and ask whether the
system has one or more of each.

Three things about how it's wired in here:

- **It doesn't replace STRIDE, and the intake says so.** PHANTOM-B covers the
  LLM subset. The front end, the data store, the pipeline, and the boundaries
  between them stay STRIDE's job. The decision table in 0.5 now returns both
  when the project calls a model.
- **PHANTOM-B deliberately names threats and not controls**, which is the
  right call for a framework and a gap for me. So the table in B5.1 carries a
  third column mapping each prompt to the rule in this file that answers it,
  and a pass that produces threats without a named control for each counts as
  unfinished.
- **The over-reliance prompt comes first.** Prompt injection is unsolvable at
  the model level today, so the file treats it as an architectural given
  rather than something to filter. The question that decides the damage is
  what the output can reach without a deterministic check in front of it, and
  with which credential. If the honest answer to "what if this output is
  entirely chosen by an attacker" is unacceptable, no amount of prompt
  hardening fixes it.

PHANTOM-B is version 1.0, July 2026, and licensed CC-BY. The eight prompts are
Shostack's; the mapping column and the intake wiring are mine.

### The enforcement: `settings.json` and `hooks/`

`CLAUDE.md` is advisory. Claude reads it and follows it as intent, but a long
vibe-coding session can lose track of an instruction, or read it differently
the tenth time than the first. So Part A also ships as things Claude Code
enforces mechanically, before a tool call runs, regardless of what the
conversation says:

- **`settings.json`** — `permissions.deny` and `permissions.ask` block or
  gate the actions Part A names as sensitive: git force-push, dropping or
  truncating a database, reading `.env` or a secrets directory.
- **`hooks/check-destructive.sh`** (`PreToolUse` on Bash) — a pattern-level
  backstop for the same rules, independent of how the model interprets the
  command.
- **`hooks/log-tool-call.sh`** (`PostToolUse`, every tool) — logs every tool
  call to `~/.claude/logs/tool-calls.log`, so there is a record even if a
  session's own summary of what it did is incomplete.
- **`hooks/record-agent-run.sh`** (`SubagentStop`) — writes a receipt when one
  of the subagents finishes: which agent, which project, which commit, and a
  hash of `git diff HEAD`. That last field is what makes a receipt evidence
  rather than a sticker, since it stops matching the moment the code changes.
- **`hooks/require-intake.sh`** (`PreToolUse` and `PostToolUse` on `Edit` and
  `Write`) — turns the intake into a precondition for writing code. See below.
- **`hooks/verify-settings.sh`** (`SessionStart`) — checks, at the start of
  every session, whether a project's own `.claude/settings.json` or
  `.claude/settings.local.json` contains an `allow` rule that could weaken
  one of the global `deny` rules, and raises an active warning in the
  session if so.
- **`hooks/self-test.sh`** — not a hook, but the thing that tells you the
  hooks are real. Run it by hand: it checks the install and then verifies that
  a destructive command is actually blocked and a harmless one is not.
- **`hooks/lib/deny-regex.py`** — the single source of the patterns the two
  hooks above use. Both derive their patterns from `permissions.deny` in
  `settings.json` at runtime rather than keeping their own copy, so adding a
  destructive action during an intake (0.4) only means editing
  `settings.json`; the hooks pick it up automatically.

`check-destructive.sh` fails closed. If it cannot derive its patterns it
blocks the command and says so, rather than allowing it through. A guardrail
that quietly degrades into a no-op is worse than one that is loudly broken,
which is not a hypothetical here.

This layer has two known limits, both documented in A7 of `global-CLAUDE.md`
rather than left implicit: a `deny` rule on `Read`/`Edit` stops Claude's own
file tools but not a subprocess that opens the file directly, and a hook
cannot invoke the interactive `/status` command, so confirming which settings
sources are actually active after an edit stays a manual step.

### The delegation: `agents/`

`CLAUDE.md` says what should happen and `settings.json` blocks what shouldn't.
Neither of them remembers to *do* a step. That is what the subagent definitions
in `agents/` are for. Claude Code loads every file in `~/.claude/agents/` in
every project, so the intake, the threat model, the security review and the
dependency check are present in a new project without me setting anything up,
and section A9 of `global-CLAUDE.md` says when each one runs.

- **`intake-scout`** — reads a new project and drafts the Part 0 addendum
  before any code is written, so the intake doesn't depend on me remembering
  there is one.
- **`threat-modeller`** — the STRIDE, LINDDUN and PHANTOM-B passes B5 asks
  for, with a named control per threat.
- **`security-reviewer`** — the explicit review B9 requires, in place of the
  colleague I don't have.
- **`dependency-checker`** — B7 and B10 applied to a package before it lands,
  including confirming the name exists on the registry rather than in the
  model's memory.
- **`untrusted-reader`** — everything A3 calls untrusted gets read here, in a
  context with no shell, no write tools, and no credential.

That last one does the real work. Prompt injection can't be filtered, so the
only question that decides the damage is what an attacker-controlled output can
reach. Reading a GitHub issue inside a subagent that holds nothing means the
answer is one read-only context, and then it ends.

Each definition declares its tool scope in its own frontmatter, and none of
them may set `permissionMode` to `bypassPermissions` or `dontAsk`.
`verify-settings.sh` checks that at every session start, for a project's own
`.claude/agents/` as well as the shared set, because a repository can ship a
definition that silently overrides one of mine — the same override problem the
hook already watches for in `settings.json`.

### Gating the one step I actually forget

Having the agents available doesn't make them run. You can't force a language
model to call a tool, so the move is the same one the over-reliance prompt
describes: stop trying to steer the choice, and make the outcome unreachable
without evidence that the choice was made.

That is what the intake gate does. `record-agent-run.sh` writes a receipt every
time a subagent finishes. `require-intake.sh` sits on `Edit` and `Write`, and
when the project has neither a `## Project addendum: security scope` nor an
`intake-scout` receipt, it turns the first write into a permission prompt with
the reason attached. The intake stops being a habit and becomes a condition for
writing code in that directory.

It asks rather than blocks, deliberately. A block invites a session to route
around it, and the session is the party least able to judge whether skipping the
intake is fine this once. A prompt can't be answered by the session at all — it
lands with me, which is where the approval gate in 0.4 was always supposed to
sit. Two things are never gated, or the gate would eat itself: the project's own
`CLAUDE.md`, since writing the addendum is the way out, and anything outside the
project directory. One approval quiets it for that session; the written addendum
quiets it permanently.

Building it turned up the failure mode this repository is named for. On macOS,
`/tmp` and `/var` are symlinks, so the file path arriving at the hook and the
project path coming back from `git rev-parse --show-toplevel` disagreed, the
"is this file inside the project" test never matched, and the gate silently
allowed everything. It looked installed. It was inert. The probe that caught it
is now five checks inside `self-test.sh`, and like the destructive-command
check they test both directions: the gate has to ask without an addendum *and*
stay quiet with one, because a hook that asks about everything and a hook that
asks about nothing are equally useless and only one of them is obvious.

### When the guardrail was broken

Worth writing down, because the failure is more instructive than the fix.

The hook scripts used to sit in the root of this repository, while the install
instructions below downloaded them from `hooks/`. Those URLs returned 404. The
command was `curl -o` without `--fail`, so curl wrote the response body —
the fourteen characters `404: Not Found` — into each hook file and exited
successfully. The files existed. They were executable. They were the right
names in the right places. Every one of them was inert.

The effect, on my own machine, for several weeks: `check-destructive.sh` exited
127 instead of 2, which Claude Code reads as "allowed", so the destructive-
command backstop passed everything through. `log-tool-call.sh` never ran, so
`~/.claude/logs/` was never even created and there was no tool-call record at
all. `verify-settings.sh` never ran, so nothing warned me — including nothing
warning me that the hooks were broken. The `permissions.deny` rules in
`settings.json` kept working throughout, since Claude Code enforces those
itself, so the damage was bounded. The layer built to back them up was not
there.

Four things were wrong, and all four had to be fixed:

- **The paths.** The scripts now live at `hooks/` and `hooks/lib/`, matching
  the documented URLs.
- **The install.** `curl --fail` refuses to write a file on an HTTP error. A
  download that silently substitutes an error page for a security control is
  the supply chain problem in miniature.
- **The silence.** `verify-settings.sh` now checks the guardrail itself at
  every session start: are the hooks present, executable, plausibly a script
  rather than a downloaded error page, and can the deny patterns still be
  derived? It also no longer aborts on an empty pattern array under bash 3.2,
  which is what macOS ships and which had been making the script exit
  silently before it printed anything.
- **The missing proof.** There was no way to ask "is this working" and get an
  answer based on behaviour. `hooks/self-test.sh` is that answer: it feeds a
  destructive command and a harmless one to the hook and checks that the first
  is blocked and the second is not. Presence was the only thing ever verified,
  and presence was exactly what the broken install had.

`check-destructive.sh` also fails closed now. If it cannot derive its patterns
it blocks and says so, instead of the earlier behaviour of exiting nonzero in a
way Claude Code read as approval.

The general lesson, and the reason A8 of `global-CLAUDE.md` exists: a control
that cannot detect its own absence is not a control. Test that a guardrail
blocks something, not that its file is present.

## Installation

Every `curl` below uses `--fail`. That is not decoration. Without it, curl
writes the body of an HTTP error into the target file and exits successfully,
which is how this repository once shipped four hook scripts that each
contained the words `404: Not Found` and did nothing at all. See "When the
guardrail was broken" for the full account.

```bash
BASE=https://raw.githubusercontent.com/mwel10/claudevibe/main
mkdir -p ~/.claude/hooks/lib ~/.claude/agents
curl --fail -sSL -o ~/.claude/CLAUDE.md                  "$BASE/global-CLAUDE.md"
curl --fail -sSL -o ~/.claude/settings.json              "$BASE/settings.json"
curl --fail -sSL -o ~/.claude/hooks/check-destructive.sh "$BASE/hooks/check-destructive.sh"
curl --fail -sSL -o ~/.claude/hooks/log-tool-call.sh     "$BASE/hooks/log-tool-call.sh"
curl --fail -sSL -o ~/.claude/hooks/verify-settings.sh   "$BASE/hooks/verify-settings.sh"
curl --fail -sSL -o ~/.claude/hooks/require-intake.sh    "$BASE/hooks/require-intake.sh"
curl --fail -sSL -o ~/.claude/hooks/record-agent-run.sh  "$BASE/hooks/record-agent-run.sh"
curl --fail -sSL -o ~/.claude/hooks/self-test.sh         "$BASE/hooks/self-test.sh"
curl --fail -sSL -o ~/.claude/hooks/lib/deny-regex.py    "$BASE/hooks/lib/deny-regex.py"
for A in intake-scout threat-modeller security-reviewer dependency-checker untrusted-reader; do
  curl --fail -sSL -o ~/.claude/agents/$A.md             "$BASE/agents/$A.md"
done
chmod +x ~/.claude/hooks/*.sh
```

There is deliberately no `set -e` there, so that pasting it into a terminal
cannot leave your shell in a state where the next failing command closes it.
Each line stands alone, `--fail` stops any of them writing a file on an HTTP
error, `-sS` prints the error if one occurs, and the next step catches
anything that did not arrive.

Then prove it works, rather than checking that the files are there:

```bash
bash ~/.claude/hooks/self-test.sh
```

That is the step that matters, and it is the one this repository previously
did not have. It checks that each installed file is a real file rather than a
downloaded error page, that the hooks are executable, that the deny patterns
still derive from `settings.json`, that the subagent definitions are installed
and none of them bypasses the permission prompts, and then it feeds a
destructive command and a harmless command to the hook and confirms that the
first is blocked and the second is not. It does the same in both directions for
the intake gate, in a redirected `HOME` so it never touches real receipts.

Both halves of that last check are needed. `check-destructive.sh` now fails
closed, so a completely broken install blocks *everything*; a test that only
asked "did it block something" would pass on exactly the install you most need
to catch. The guardrail has to discriminate, so the self-test checks that it
does.

It ends with a line saying all checks passed, or a list of what is wrong, and
exits nonzero on failure so you can put it in a shell profile or a cron job.
Run it after installing, after editing `settings.json`, after adding a subagent
definition, and alongside `/status` in a Claude Code session to confirm which
setting sources are active.

Adjust the paths if you lay the repository out differently — what matters is
that `settings.json` lands at `~/.claude/settings.json` and the hook scripts
stay executable at the paths `settings.json` points to.

### Upgrading from a broken install

Your hooks are almost certainly inert. Check with one command:

```bash
head -c 20 ~/.claude/hooks/check-destructive.sh
```

If that prints `404: Not Found`, every hook is a stub, nothing has been
blocked or logged since you installed, and `~/.claude/logs/` probably does not
exist. Re-run the install commands above, which overwrite the stubs, then run
`bash ~/.claude/hooks/self-test.sh` and confirm it reports all checks passed.

Your `permissions.deny` rules in `settings.json` were unaffected throughout,
because Claude Code enforces those itself rather than through a hook. What was
missing is the backstop, the tool-call log, and the warning that any of it was
missing.

The rename of `global-CLAUDE.md` to `CLAUDE.md` is deliberate. Two levels are
in play: the global file applies everywhere, and each project also gets its
own `CLAUDE.md` in the project directory, where Claude records that project's
intake answers under a `## Project addendum: security scope` heading. The
global file tells Claude what to ask; the project file remembers the answers.
Keeping the repository copy under a different name avoids the confusion of
two files with the same name and different jobs — and stops Claude from
treating this repository's own root file as a project addendum when you work
on the repository itself.

If you see a `CLAUDE.md` in the root of this repository, that is the addendum
for this repository as a project, not the file to download.

## What it's based on

The rules aren't invented. They map to CIS Controls v8 §16.1–16.14, the OWASP
Top 10, the OWASP Application Security Verification Standard, NIST CSF
PR.PS-06 and ID.AM-08, CycloneDX's ML-BOM extension for the AI Bill of
Materials, and PHANTOM-B 1.0 for the LLM threat prompts. The agent-security half is shaped by real incidents
involving coding agents — Devin/Sliver, Replit, Amazon Q, RoguePilot,
PocketOS, and the Mastra npm compromise — where the failure was credential
scope, untrusted input, or a destructive call that nobody confirmed. The
enforcement layer follows Claude Code's own permissions and hooks reference
at code.claude.com/docs.

## What it doesn't do

PHANTOM-B is analysis, and nothing enforces it. No hook can check that a
threat model was done, or done honestly. The only evidence it happened is the
dated record in the project addendum and the line in the handover note, which
is why the file asks for both and asks Claude to say explicitly when a prompt
was considered and found not to apply — so "not relevant" and "not looked at"
don't end up looking the same.

`global-CLAUDE.md` on its own is still instructions, not enforcement — it
makes the safe path the default and gets the right questions asked, but
nothing in the file itself technically prevents a mistake. That's what
`settings.json` and `hooks/` are for, and they only cover part of Part A: the
tool-call level. They don't touch Part B. Nothing here runs a SAST scanner,
checks a CVE score, or writes an SBOM — for that, put a real pipeline in
front of the code, as B9 through B11 describe. And the enforcement layer
has the two limits named above: it doesn't stop a subprocess from reading a
file a deny rule was meant to protect, and it can't check its own settings
sources without a manual `/status`.

The subagents have the same shape of limit, and it's worth being precise about
where it now falls, because the intake gate moved it. What is mechanical: the
definitions exist and are real files, none of them can skip a permission prompt,
a finished subagent leaves a receipt, and the Part 0 intake is a condition for
writing code in a project. What is not: the other four agents. Nothing makes the
security review, the threat model or the dependency check happen — those rows in
the A9 trigger table are instructions like the rest of `CLAUDE.md`. That's why
A9 asks Claude to say out loud when it decides not to delegate, since a step
silently skipped and a step correctly judged unnecessary otherwise look
identical.

Two things the gate specifically does not prove. A receipt says a subagent ran,
not that it ran well: an agent that reads nothing and reports nothing leaves the
same receipt as one that did the work, which is why its answer is stored in the
receipt and why the review still has to be read. And the gate watches Claude
Code's own `Edit` and `Write`, so a file changed in another editor, or written
by a script the session started, goes past it untouched.

It also isn't a substitute for someone who knows what they're doing looking
at your code. It raises the floor. It doesn't replace the ceiling.

## Adapting it

It's written for how I work: solo, no team review, mostly small projects. If
you work differently, the parts most worth editing are the ASVS decision
table in 0.5, the scanning requirements in B9 — annual penetration tests and
monthly DAST scans make sense for some projects and are overkill for others —
and the destructive-action list.

The subagents in `agents/` are meant to be edited too. Adding one means adding
its file and a row to the trigger table in A9; the only rules that hold for all
of them are the tool scope in the frontmatter and the ban on a permission mode
that cannot ask, and `verify-settings.sh` enforces the second one whatever you
name the agent.

That last one now lives in one place: `permissions.deny` in `settings.json`.
Editing A2 in `global-CLAUDE.md` records the reasoning and keeps the project
addendum accurate, but the pattern itself only needs to go into
`settings.json` — `hooks/check-destructive.sh` and `hooks/verify-settings.sh`
pick it up automatically through `hooks/lib/deny-regex.py`, so there's no
second list to remember to update.

Suggestions and pull requests are welcome, particularly from people who have
found gaps in it.

## Licence

MIT.
