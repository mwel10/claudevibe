# Claudevibe

This repository ships the security baseline itself: the instructions in
`global-CLAUDE.md`, the permission rules in `settings.json`, the hooks in
`hooks/`, and the subagent definitions in `agents/`. Other people install it
into their own `~/.claude/`, so a change here reaches every installer.

The baseline applies to work in this repository like anywhere else. The one
thing worth stating explicitly: the files here are the source of what enforces
it elsewhere, so the ordinary rule about not weakening a guardrail applies to
the guardrail's own source, not only to its installed copy.

## Project addendum: security scope

- **Purpose / users:** A distributable security baseline for Claude Code, not an
  application. Installed by anyone who runs the curl block in the README, and by
  the maintainer, whose own `~/.claude/` is the install target. No runtime, no
  server, no database.
- **Exposure:** Public internet, one direction. Public GitHub repository
  `mwel10/claudevibe`, fetched over HTTPS from `main`. Nothing listens; the
  exposure is distribution rather than traffic.
- **Data categories:** None in the artifact. No secrets, no personal data, no
  credentials. The installed copy produces local data on each user's machine:
  `~/.claude/logs/tool-calls.log`, `~/.claude/logs/settings-warnings.log`, and
  receipts under `~/.claude/logs/agent-receipts/` that store up to 1000
  characters of a subagent's own answer. That last field can contain whatever
  the agent was reading, so an `untrusted-reader` run over a document holding
  personal data lands that text in a log file.
- **ASVS level (and why):** 3. Row 3 of 0.5 applies on two clauses: compromise
  confers control over the permission surface of every session on every
  installed machine, and the maintainer's own environment is a single point of
  failure for everything else built with it. Row 2 also applies. Read level 3
  here as a standard of care for what exists — integrity of distribution, review
  before shipping, no secrets, evidence that a control works — rather than as a
  web-application checklist, most of which does not apply.
- **Threat modelling method (and why):** STRIDE over the distribution chain,
  which is the real attack surface: spoofing the source, tampering with a hook
  in transit or at rest, repudiation where the tool-call log cannot reconstruct
  what happened, and elevation of privilege as the end state of each. Plus a
  PHANTOM-B pass, on the strict reading not triggered, because nothing here
  calls a model. The strict reading is wrong: this artifact *is* the control set
  for a language model with tool access, distributed to other people, which is
  the subject A8 already applies those prompts to. LINDDUN not triggered, no
  personal data is processed; revisit if the receipt `summary` field grows.
- **Identity provider / auth model:** None in the artifact. The only identity
  that matters is the GitHub account that controls what installers receive.
- **Environments and how they are separated:** None. `main` is production for
  installers, with no tag, release or version pin in the install instructions.
  `self-test.sh` redirects `HOME` to a temporary directory for its probes and
  removes those on exit, but its final check runs `verify-settings.sh` under the
  real `HOME`, and the deny-pattern and intake-gate checks read the real
  settings and working directory, so a project settings file in the current
  directory can change what it reports.
- **Credentials and where secrets come from:** The project needs none and reads
  none. Deny rules cover `.env`, `*/secrets/**`, `*/.aws/**`, `*id_rsa*`,
  `~/.claude/.credentials.json` and `~/.claude.json`. The allow list grants a
  standing `Read` on four `~/.claude` paths in *every* project, which is a real
  widening: a session opened for unrelated work can open the baseline, the
  subagent definitions, the hooks and `settings.json`. That last one is why the
  file must never carry an `env` secret or an `apiKeyHelper` value. The subprocess limit in A7
  applies throughout: these rules stop Claude's own file tools, not a script
  that opens the file directly.
- **Destructive actions in this project:** Not data loss. The destructive act is
  shipping a weakened or inert guardrail: removing a deny rule, widening
  `allow`, dropping a `hooks` registration, making a hook exit 0 where it should
  block, widening `tools:` or adding `permissionMode:` in `agents/*.md`, and
  renaming any file whose path appears in the README install URLs or in the
  `hooks` block. `git push` to `main` is an immediate deploy to every installer
  with no rollback point.
- **What the session-start check does and does not see:** it compares a project
  settings file against the global rules by capability rather than by spelling,
  and it separates what a project asks for from what it can do. An allow rule
  covering a gated path is reported as intent only: rules are evaluated deny,
  then ask, then allow across every settings source, so a project allow rule
  cannot override a global one. What acts regardless, and is reported as such,
  is a project's own hooks, agent definitions and MCP servers, a Bash rule
  reaching a gated path, `defaultMode` and `additionalDirectories`. A file it
  cannot parse is reported rather than read as empty. The Bash branch is different in kind and is a heuristic: it compares
  the text of a command against the gated paths after normalising quoting and
  `$HOME`, so a command reaching a path through a variable, a `cd` or a script it
  calls is not seen, and three deny rules beginning with a glob are not compared
  against shell rules at all. Beyond that it sees nothing that is not a tool
  call, per the boundary in A7.
- **Approval gate and how it is enforced:** Weak, and mostly not enforced.
  `Bash(git push*)` is in `ask` and force-push in `deny`, so a push *through
  Claude Code* prompts. Nothing else holds: `.github/` contains only
  `FUNDING.yml`, so no CI runs `self-test.sh` on a pull request and nothing
  blocks a merge; `.git/hooks/` holds only samples, so there is no pre-commit
  check; there is no reviewer. The effective gate is the maintainer remembering
  to run `self-test.sh`, which is exactly the boundary A7 warns about.
- **MCP servers / external tools and their scope:** No MCP servers. External
  endpoints are `raw.githubusercontent.com` and `api.github.com`, read-only, for
  install and update. `WebSearch` is allowed outright in every
  context, because a question before every search was answered without being
  read and buried the prompt that mattered; A9's arrangement for searching is
  therefore advisory. `scope-untrusted.sh` asks before every `WebFetch`, in
  every context including a read-only subagent, per call rather than per
  domain, because the model chooses the URL. `Bash(curl)` and an MCP-provided
  fetch reach the same page and meet no check.
- **Subagents used in this project and the tool scope of each (see A9):** Five,
  all read-only, none setting `permissionMode`, none setting `model:`.
  `intake-scout`, `threat-modeller` and `security-reviewer` hold Read, Grep and
  Glob; `dependency-checker` and `untrusted-reader` add WebFetch and WebSearch.
  No Bash, no Edit, no Write anywhere.
- **AI/ML models called at runtime and what data reaches them:** None. No code
  here calls a model. The Python is standard library only.
- **What each model can reach (tools, credentials, data, irreversible
  actions):** Not applicable to the artifact, and inverted for its effect: this
  repository *defines* what a model may reach on every installed machine.
- **PHANTOM-B pass:** 2026-09-03. P: every file in `global-CLAUDE.md` and
  `agents/` is text designed to steer a model, shipped over HTTPS from a moving
  branch with no signature, landing at `~/.claude/CLAUDE.md` where it is loaded
  in every session — a prompt injection channel with the highest available
  privilege. Control: none adequate today, see the OPEN item on distribution
  integrity. A: the advisory half depends on the model choosing to comply;
  control: the hooks, which is the point of A7. O: the blast radius of a hostile
  or merely broken release is the full permission surface of every installer,
  with no version to roll back to; control: `self-test.sh` catches broken, not
  hostile. Re-passed 2026-09-22 after searching was allowed outright: what an
  untrusted web result can now reach without a check is the main conversation,
  which holds Edit, Write and Bash, where before it reached a read-only
  subagent. Accepted deliberately, because a prompt before every search was
  answered without being read and buried the fetch prompt; the control that
  remains is that `WebFetch`, where the model picks the destination, asks per
  call in every context and is named in `permissions.ask` as well as in the
  hook. Nothing covers `Bash(curl)` or an MCP-provided fetch. N: `log-tool-call.sh` records that a Bash call occurred, not what it
  did; keeping arguments out is defensible under B2, and is hereby a recorded
  decision rather than an implicit one. M: no CI, no secrets scanning, no
  `.gitignore`, no SBOM, no AIBOM — the prompt this repository's own state fails.
  H and T: build-time only, unanswerable until there is an AIBOM. B: not
  applicable.
- **Tool-call logging destination:** `~/.claude/logs/tool-calls.log`, written by
  `log-tool-call.sh`; timestamp, tool name and working directory only.
- **Scanners, SBOM, and AIBOM in the pipeline:** None. `.github/` contains only
  `FUNDING.yml`.
- **OPEN: distribution integrity.** Installers fetch from `main` with no
  checksum, no signature and no tag. `self-test.sh` is a consistency check, not
  an authenticity one: it derives its expectations from the same `settings.json`
  it validates, so it cannot detect that a deny rule was removed upstream. Are
  tagged releases with published checksums and a pinned-commit install
  acceptable? This is the most important open item on the list.
- **OPEN: approval gate.** Are branch protection and required status checks
  configured on GitHub? Are commits signed? Neither is visible from the working
  tree.
- **OPEN: vulnerability intake (B13).** No `SECURITY.md`, no disclosure policy,
  no contact route, while the README invites pull requests.
- **OPEN: AIBOM (B12).** The README says the repository is vibe-coded but names
  no model or version, so an issue traced to a session cannot be reproduced.
- **OPEN: writing this repository's own source.** The `ask` rules cover the
  *installed* copies under `~/.claude/`. Editing `hooks/`, `agents/` and
  `settings.json` in this working tree is gated by nothing, and a change here is
  what eventually reaches every installer.
- **OPEN: log retention.** Nothing prunes `~/.claude/logs/`, and receipts retain
  up to 1000 characters of agent output indefinitely.
- **OPEN: platform contract monitoring.** The hooks depend on Claude Code JSON
  field names (`agent_type`, `last_assistant_message`, `hook_event_name`,
  `permissionDecision`). `record-agent-run.sh` and `log-tool-call.sh` swallow
  errors and exit 0, so a rename degrades them silently. How is that noticed?
- **OPEN: audience.** How many people have installed this, and is it meant to be
  depended on by others? The answer decides whether release signing is
  proportionate or overkill.
- **Last reviewed:** 2026-09-22
