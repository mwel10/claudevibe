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
  truncating a database, reading `.env` or a secrets directory. It also gates
  writing to the guardrail's own files, since whoever can rewrite a hook
  decides what every later session may do. Its short `permissions.allow` list
  does the opposite job, for four files only: the baseline's own instructions,
  settings, subagent definitions and hooks live outside every project
  directory, so without a user-level rule each new project has to be asked
  about them one at a time. See "Why there is an allow list" below.
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
- **`hooks/scope-untrusted.sh`** (`PreToolUse` on `WebSearch` and `WebFetch`) —
  allows a search without a question only inside a subagent whose own
  definition declares nothing beyond read-only tools, and asks everywhere else,
  the main conversation included. A fetch always asks, because its destination
  is chosen by the model. See "Why a web read asks" below.
- **`hooks/verify-settings.sh`** (`SessionStart`) — checks, at the start of
  every session, whether a project's own `.claude/settings.json` or
  `.claude/settings.local.json` takes away something a global `deny` or `ask`
  rule gates, and raises an active warning if so. It compares capabilities
  rather than spellings: an allow rule counts when its glob covers a gated
  path whether or not it names it, a shell rule reaching that path counts
  unless its command cannot write, and `defaultMode` counts because it
  switches off every `ask` rule at once. It also reports what an enabled
  plugin contributes, because a plugin is a third source of hooks and
  subagent definitions that the other checks never looked at.
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

#### Why there is an allow list

The instructions are never the problem. `~/.claude/CLAUDE.md` is loaded into
context when a session starts, outside the permission system entirely, so it is
present in every project no matter what the permissions say. Opening it *as a
file* is a different act, and it fails in a way that is easy to misread as the
instructions not arriving at all.

The reason is that the baseline's own files sit outside every project
directory. A `Read` on `~/.claude/CLAUDE.md`, on `~/.claude/agents/`, or on the
hooks is therefore an access beyond the working directory: a prompt in the
default mode, and a flat refusal in `dontAsk` mode, which auto-denies anything
not matched by an `allow` rule. `intake-scout` consulting the baseline, or a
session checking whether a hook is the real one, runs straight into it.

What makes this look like a mystery rather than a permission is where the
approval goes. Choosing "Yes, and don't ask again" writes the rule to
`.claude/settings.local.json` at the root of that git repository, or to the
working directory outside git. It never reaches user settings, and there is no
option to redirect it. So the projects where you once approved it keep working,
every new project silently does not, and the difference lives in files you have
no reason to look at.

Hence the allow list, deliberately kept to four paths and one tool. It is not
widened to `Read(~/.claude/**)`, because `~/.claude/projects/` holds the full
transcript of every session in every other project, and handing that to each
new session answers the least-privilege question in A1 backwards.
`permissions.additionalDirectories` is not used either: it grants writing as
well as reading. No web tool is in the list at all: `scope-untrusted.sh` decides those, and why
a permission rule is the wrong instrument for them is the next section.

The mirror image of that question is writing. Reading `~/.claude/hooks/` is a
convenience; writing it decides what every future session is allowed to do, and
`require-intake.sh` deliberately exempts everything outside the project
directory, so nothing was watching those writes at all. The hooks, the agent
definitions, `settings.json` and `CLAUDE.md` are therefore in `ask`. Not in
`deny`, because `deny` would push ordinary maintenance into a shell command,
which is the one channel with no check on it — and that is also the honest limit
of these rules: an `ask` on `Edit` and `Write` does not see a `cp` or a
`curl -o` writing the same file.

#### Why a web read asks

A9 says untrusted content is read inside a subagent on purpose: if a page turns
out to be a prompt injection, it lands in a read-only context holding no shell
and no write tool, and the damage stops there. That was advice, and advice is
carried out by the party least able to judge whether skipping it is fine this
once.

It can be enforced, because a `PreToolUse` hook is told which context it is
running in. Claude Code sets `agent_type` only for a subagent call, so
`scope-untrusted.sh` can tell a web read in the main conversation, which also
holds `Edit`, `Write` and `Bash`, from one inside a subagent.

The read-only test is an allowlist, and it is worth saying why, because the
first version got it wrong in a way nothing caught. That version asked whether
the agent declared `Edit`, `Write` or `NotebookEdit`. An agent declaring `Bash`
passed as a clean reader, so attacker-controlled text could land in a context
holding a shell — the exact arrangement A9 exists to prevent — and `Task` and
every future MCP write tool would have passed too. An agent now qualifies only
when *every* tool it declares is one of `Read`, `Grep`, `Glob`, `WebFetch` and
`WebSearch`.

A fetch is treated differently from a search, and this is the second thing the
first version had backwards. `WebSearch` takes a query; the destination is not
chosen by anyone. `WebFetch` takes a URL, so allowing it unconditionally inside
a reader turns a page that says "now fetch `https://attacker/?q=…`" into a
network call with nothing in front of it, which is B2's last bullet and A10 in
one move. A fetch therefore keeps its ordinary per-domain question in every
context, including the reader.

The rule is deliberately not a list of agent names. It is A9's "read-only unless
it must write" read back out of the file that states it, which means a new
reader agent needs no edit to the hook, and an agent that later gains `Edit` or
`Bash` stops being trusted with the web in the same movement instead of quietly
keeping a privilege granted under different circumstances. The scope is read
from the frontmatter block only, and the definition has to name itself, so a
`tools:` line in a prompt body is prose and a project file cannot be graded for
an agent it is not.

`WebSearch` is therefore not in `permissions.allow`. It was, briefly, and that
was the wrong instrument: a permission rule cannot distinguish which context
calls a tool, so it would have granted the main conversation exactly what A9
wants kept out of it. Approving the prompt is always available; the point is
that the moment becomes visible.

#### What the web scope hook does not cover

`scope-untrusted.sh` is registered on `WebSearch` and `WebFetch`, and those are
the two tools it sees. `Bash(curl …)`, `Bash(wget …)` and a fetch provided by an
MCP server pull the same page into the same context and meet no scope check at
all. This is the A7 subprocess limit again, in a second place: a rule about a
tool is not a rule about an act. Say so rather than describing the property as
if it held for web reading in general, and if it has to hold regardless of the
route, the place for it is a deny rule on the Bash side or a network policy, not
this hook.

The comparison in `verify-settings.sh` has a matching seam. Its file-tool branch
compares capabilities, as described above. Its Bash branch compares text: it
normalises quoting, `$HOME` and redundant separators, and then asks whether a
gated path appears in the command. A command can always reach a path that test
cannot see, through a variable it sets itself, a `cd`, a symlink, or a script it
calls. Three deny rules that begin with a glob — `*/secrets/**`, `*/.aws/**`,
`*id_rsa*` — have no fixed stem to look for at all and are not compared against
Bash rules. The branch is a heuristic and is documented as one.

#### Why a plugin is inspected

A7 and A9 name two places a hook or a subagent definition can come from, user
level and project level, and every check here looked at exactly those two. There
is a third. A plugin enabled in `settings.json` can carry its own hooks, its own
subagent definitions and its own MCP servers; plugin hooks are merged into the
same execution as the ones in `settings.json`; and it arrives from a marketplace
repository that nothing here reviews, pinned only by a version field its author
controls. The documentation is blunt about the trust model: a plugin can run
arbitrary code with your privileges.

That a plugin ships only skills today says nothing about its next version, so
the check reports the executable surface a plugin actually contributes rather
than passing judgement on the plugin. A skills-only plugin stays silent, which
is what keeps the warning worth reading when it does appear.

#### Why the comparison is not a text match

A project can take away what a global rule gates, and the check that notices
used to compare the *text* of a project's allow rules against the global ones.
That is the wrong way round in the most literal sense: `Edit(~/.claude/hooks/**)`
was caught, and `Edit(~/.claude/**)` — which covers it, and more — was not,
because it contains no literal `~/.claude/hooks/`. The wider and more
consequential the project rule, the more certainly it passed.

So each global rule now carries a representative path it gates, and a project
allow rule counts when its own glob matches that path. Three other things follow
from the same shift, and each was a silence before:

- A `Bash` rule reaching a gated path bypasses a rule on `Edit` entirely, so it
  is reported unless its command is one of a short list that cannot write. The
  earlier version listed the commands that *do* write, which meant `touch`,
  `tar -x`, `git checkout` and everything else nobody thought of passed
  quietly. A read-only command also stops being one the moment a redirection or
  a second command appears, so `echo x > check-destructive.sh` is reported even
  though `echo` is on the list. `bash` is deliberately not on that list at all:
  running a script that lives in the gated directory is exactly the channel the
  rule cannot see.
- A `defaultMode` of `acceptEdits` or `bypassPermissions` switches off every
  `ask` rule in a project at once, more completely than any allow rule, and
  nothing had ever looked at it.
- A project settings file that cannot be parsed used to produce an empty list of
  rules, which read exactly like a project that weakens nothing.

`verify-settings.sh` checks at session start that the four rules are still
there, so a settings file restored from an older copy announces itself instead
of quietly reintroducing the problem. It also warns when a `Read` rule reaches
past those four. The first version of that check did not: it asked only whether
the baseline was readable, which `Read(~/.claude/**)` satisfies, so it passed on
the exact configuration the paragraph above argues against. That is the third
time a check in this repository verified presence rather than correctness, after
the path comparison in the intake gate and the 404 stubs, which is why every
check now has to be probed in both directions before it counts as installed.

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

Building it reproduced the failure this repository is named for, twice, in the
same afternoon. The gate compared the file path arriving in the tool call
against the project path coming back from `git rev-parse --show-toplevel`, as
strings. First those disagreed because `/tmp` and `/var` are symlinks on macOS.
Then, once that was fixed, they disagreed again on a real repository because
the directory is called `Claudevibe` on disk while everything types
`claudevibe`, and a case-insensitive filesystem is happy to answer to both. Each
time, the "is this file inside the project" test never matched, and each time
the gate allowed every write while looking perfectly installed.

The fix in both cases is to stop comparing spellings. Directories are now
compared by identity, with `-ef`, which asks the filesystem whether two paths
are the same directory instead of whether two strings are the same text. The
probes that caught it are six checks inside `self-test.sh`, and like the
destructive-command check they test both directions: the gate has to ask
without an addendum *and* stay quiet with one, and it has to keep firing when
the project is reached by a second path. A hook that asks about everything and
a hook that asks about nothing are equally useless, and only one of them is
obvious.

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
curl --fail --remove-on-error -sSL -o ~/.claude/CLAUDE.md                  "$BASE/global-CLAUDE.md"
curl --fail --remove-on-error -sSL -o ~/.claude/settings.json              "$BASE/settings.json"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/check-destructive.sh "$BASE/hooks/check-destructive.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/log-tool-call.sh     "$BASE/hooks/log-tool-call.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/verify-settings.sh   "$BASE/hooks/verify-settings.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/require-intake.sh    "$BASE/hooks/require-intake.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/record-agent-run.sh  "$BASE/hooks/record-agent-run.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/scope-untrusted.sh   "$BASE/hooks/scope-untrusted.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/self-test.sh         "$BASE/hooks/self-test.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/lib/deny-regex.py    "$BASE/hooks/lib/deny-regex.py"
for A in intake-scout threat-modeller security-reviewer dependency-checker untrusted-reader; do
  curl --fail --remove-on-error -sSL -o ~/.claude/agents/$A.md             "$BASE/agents/$A.md"
done
chmod +x ~/.claude/hooks/*.sh
```

There is deliberately no `set -e` there, so that pasting it into a terminal
cannot leave your shell in a state where the next failing command closes it.
Each line stands alone, `-sS` prints the error if one occurs, and the next step
catches anything that did not arrive.

The two flags in front do different jobs, and both are needed. `--fail` covers
the case this repository already got wrong: the server answers 404, and without
it curl writes the error body into the file and exits successfully.
`--remove-on-error` covers the case it does not. If the server answers 200 and
the connection dies halfway through, curl exits with an error and leaves a
truncated file behind, which `--fail` has no opinion about. A half-written hook
is worse than a missing one, because bash runs whatever it was given: a
`check-destructive.sh` cut off before its pattern loop exits 0 and approves
everything, which is the original failure wearing a different hat.
`--remove-on-error` deletes the partial file instead.

It needs curl 7.83.0 or newer, which is May 2022, so anything current has it.
If your curl reports the option as unknown, drop it and rely on `--fail` plus
the self-test below, which checks file sizes and actual blocking behaviour and
would catch a truncated hook anyway.

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

### Updating

Everything installed above can be overwritten safely except one file.
`~/.claude/settings.json` is the file you are supposed to have changed. Sections
0.4 and A2 tell you to add every destructive action found during a project
intake to its `permissions.deny` list, so on any machine that has done a few
intakes it has drifted from the copy in this repository, deliberately. An update
that overwrites it deletes your own rules and says nothing, and you find out
when something gets through that you had specifically blocked.

Two things follow from that, and the second is easy to miss. The update below
leaves `settings.json` alone, so any rule a later release *adds* to it never
reaches you: the `permissions.allow` block that makes the baseline's own files
readable, the `ask` rules that gate writing the hooks, and the `deny` rules on
the two files next to `settings.json` that hold tokens are all in that category.
`verify-settings.sh` now checks for each of them at session start and says which
are missing, so the merge is a prompted step rather than a silent divergence,
but it is still a merge you do by hand.

So update the instructions, the hooks and the subagent definitions, and leave
`settings.json` out of it:

```bash
BASE=https://raw.githubusercontent.com/mwel10/claudevibe/main
curl --fail --remove-on-error -sSL -o ~/.claude/CLAUDE.md                  "$BASE/global-CLAUDE.md"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/check-destructive.sh "$BASE/hooks/check-destructive.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/log-tool-call.sh     "$BASE/hooks/log-tool-call.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/verify-settings.sh   "$BASE/hooks/verify-settings.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/require-intake.sh    "$BASE/hooks/require-intake.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/record-agent-run.sh  "$BASE/hooks/record-agent-run.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/scope-untrusted.sh   "$BASE/hooks/scope-untrusted.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/self-test.sh         "$BASE/hooks/self-test.sh"
curl --fail --remove-on-error -sSL -o ~/.claude/hooks/lib/deny-regex.py    "$BASE/hooks/lib/deny-regex.py"
for A in intake-scout threat-modeller security-reviewer dependency-checker untrusted-reader; do
  curl --fail --remove-on-error -sSL -o ~/.claude/agents/$A.md             "$BASE/agents/$A.md"
done
chmod +x ~/.claude/hooks/*.sh
```

Then read what changed in `settings.json` upstream instead of taking it:

```bash
UPSTREAM=$(mktemp)
curl --fail --remove-on-error -sSL -o "$UPSTREAM" "$BASE/settings.json"
diff ~/.claude/settings.json "$UPSTREAM"
```

A fixed path such as `/tmp/upstream.json` would follow a symlink already sitting
there, which is why that is an `mktemp`.

Three kinds of change turn up in that diff and they are not equally optional.
A new `deny` pattern is a judgement call, and yours are quite possibly already
stricter. A new entry under `hooks` is not a judgement call, and neither are the
`permissions.allow` block and the `ask` rules on `~/.claude`: those are what
make the baseline's own files readable and gate writing them, and
`verify-settings.sh` names each one it cannot find at session start. When a
release adds a hook, the script arrives with the update above and nothing wires
it into `settings.json` for you, and a hook Claude Code was never told to run is
as inert as one of the 404 stubs. Merge any `hooks` block the diff shows.

Then confirm it, the same way as after a first install:

```bash
bash ~/.claude/hooks/self-test.sh
```

The self-test has a check for exactly this: it reads the `hooks` block in
`settings.json` and reports any installed hook that is not registered there.
That check exists because skipping `settings.json` on an update is the right
call for your deny rules and creates this specific hole, and every other check
in the file runs the hooks directly, so none of them would notice.

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

A receipt also does not prove much on its own. It says a subagent ran, not that
it ran well: an agent that reads nothing and reports nothing leaves the same
receipt as one that did the work, which is why its answer is stored in the
receipt and why the review still has to be read.

### The boundary every hook shares

This is the limit worth understanding before trusting any of it, because it
applies to the deny rules, the destructive-command backstop, the tool-call log
and the intake gate alike. **Hooks only see what goes through Claude Code.**

A hook fires on a tool call. Anything that isn't one is invisible to the whole
layer. Edit a file in your IDE and no intake gate runs. Commit from a second
terminal tab, or from your editor's git panel, and nothing inspects that commit.
Run a script from a shell you opened yourself and every command inside it is
past the destructive-command check before it starts, because Claude Code never
saw it. Even inside a session, a shell script that Claude starts is one tool
call: what the script then does to your files and your repository is its own
business, and the log records the invocation rather than the consequences.

None of that is a bug to be fixed. It is the shape of the mechanism. A hook is
an interceptor on one program's tool calls, so it can only ever cover the work
that flows through that program.

Two things follow. Treat the layer as a floor under work done with Claude Code,
not as a property of your repository: the same repository edited by hand has
none of these guarantees, and the receipts, warnings and logs will quietly say
nothing rather than say so. And when it matters that a rule holds regardless of
who or what is acting, put it where the rule lives for everyone, in a pre-commit
hook, in branch protection, in CI, or in file permissions. Those see the commit
from the IDE. This layer never will.

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
