# Safe vibe coding: a CLAUDE.md for people who aren't programmers

I'm not a programmer. I do enjoy vibe coding with Claude — describing what I
want and letting it build. What I didn't enjoy was the nagging feeling that I
had no idea whether what came out was safe.

So I built a `CLAUDE.md` that answers that. It's the result of my own
experience, some research, and a lot of back-and-forth with Claude itself. It
turns "please be careful" into a set of rules Claude actually applies, and it
makes Claude ask me the right questions before it starts, instead of finding
out afterwards that my API key ended up in a public repository.

## What it does

The file has three parts.

**Part 0 — Project intake.** Before writing code, Claude reads the repository
for what it can determine on its own, then asks a short set of questions: what
this is, who can reach it, what data it touches, where secrets come from. It
derives the appropriate security level and threat modelling method from those
answers rather than asking me to pick one, proposes it, and lets me override.
The answers get written into the project's own `CLAUDE.md` so the questions
aren't asked twice.

**Part A — Agent security.** How Claude is allowed to operate. Don't reuse a
credential beyond its task. Ask again before anything destructive, even if I
said "go ahead" earlier. Treat GitHub issues, dependency metadata, and MCP
server responses as untrusted input rather than instructions. Keep tool calls
visible.

**Part B — Secure software development.** What the code has to look like. No
hardcoded secrets, no `.env` in git, no string concatenation in queries, no
hand-rolled crypto. The OWASP Top 10 as a checklist per feature. Rules for
dependencies, scanning, SBOMs, and what to do about a known vulnerability. It
ends with a handover format, so every delivery comes with a short note on what
was covered and what wasn't.

## Installation

The policy file is `global-CLAUDE.md` in this repository. Install it as
`~/.claude/CLAUDE.md`, which is where Claude reads it from in every session.

```bash
mkdir -p ~/.claude
curl -o ~/.claude/CLAUDE.md https://raw.githubusercontent.com/mwel10/claudevibe/main/global-CLAUDE.md
```

The rename is deliberate. Two levels are in play: the global file applies
everywhere, and each project also gets its own `CLAUDE.md` in the project
directory, where Claude records that project's intake answers under a
`## Project addendum: security scope` heading. The global file tells Claude
what to ask; the project file remembers the answers. Keeping the repository
copy under a different name avoids the confusion of two files with the same
name and different jobs — and stops Claude from treating this repository's own
root file as a project addendum when you work on the repository itself.

If you see a `CLAUDE.md` in the root of this repository, that is the addendum
for this repository as a project, not the file to download.

## What it's based on

The rules aren't invented. They map to CIS Controls v8 §16.1–16.14, the OWASP
Top 10, the OWASP Application Security Verification Standard, and NIST CSF
PR.PS-06 and ID.AM-08. The agent-security half is shaped by real incidents
involving coding agents — Devin/Sliver, Replit, Amazon Q, RoguePilot,
PocketOS, and the Mastra npm compromise — where the failure was credential
scope, untrusted input, or a destructive call that nobody confirmed.

## What it doesn't do

Worth being clear about this. A `CLAUDE.md` is instructions, not enforcement.
It makes the safe path the default and gets the right questions asked, but it
does not technically prevent anything. If a mistake would be genuinely
expensive, put a real control in front of it: a protected branch, a permission
boundary, credentials that simply don't have the access in question. The file
itself says as much — it asks whether your approval gates are technically
enforced or just written down.

It also isn't a substitute for someone who knows what they're doing looking at
your code. It raises the floor. It doesn't replace the ceiling.

## Adapting it

It's written for how I work: solo, no team review, mostly small projects. If
you work differently, the parts of `global-CLAUDE.md` most worth editing are
the ASVS decision table in 0.5, the destructive-action list in A2, and the
scanning requirements in B9 — annual penetration tests and monthly DAST scans
make sense for some projects and are overkill for others.

Suggestions and pull requests are welcome, particularly from people who have
found gaps in it.

## Licence

MIT.
