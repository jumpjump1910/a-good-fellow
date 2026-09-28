# a-good-fellow

Agent-agnostic skills that discuss, review, and fix GitHub PRs and issues on your
behalf. The skills are plain [SKILL.md](https://agentskills.io) folders, so they work
in Claude Code, Codex, Cursor, and any agent that reads the same format; a cron job
runs them headlessly every 30 minutes.

Works for any user on macOS and Linux: no hardcoded usernames or paths (everything
lives under your `$HOME`), and the scripts run on stock macOS bash 3.2 / BSD userland
as well as GNU/Linux.

## What it does, every 30 minutes

1. **process-prs** — walks every open PR involving you before notification backlog can
   consume the run's time or context:
   - *Your PRs*: judges unresolved comments from Copilot/reviewers; real issues get
     fixed and pushed, then the thread gets a reply and is resolved.
   - *Others' PRs*: pulls the code locally and reviews it against your gist's review
     standards. Only critical issues block approval; everything else the standards
     catch (direction, reuse, duplication, waste) is reported as non-blocking
     findings. No generic summaries or style nits. A clean PR gets a short, concrete review rationale
     (or an approval when you're a requested reviewer); a bare `LGTM` is reserved for
     extremely simple, unambiguous changes. Current markers and your legacy approvals
     pinned to the current HEAD prevent needless re-review.
2. **fix-assigned-issues** — takes open issues assigned to you, fixes them on a
   `good-fellow/issue-N` branch in an isolated clone/worktree, and opens a PR
   (via **create-pr**).
3. **join-discussions** — finds Discussions that @mention you and posts a substantive
   reply.
4. **reply-notifications** — runs last, triages ordinary unread notifications, and
   uses owner-sweep receipts to mark only work actually covered as read.

Your standing preferences (language, tone, review taste, repo scope) live in a
personal gist file `good-fellow-instruction.md`, cached at
`~/.good-fellow/instruction.md` and applied to every task. A shell preflight checks
the gist and this repository every 48 hours by default, outside model context; the
30-minute sweeps therefore spend no tokens polling for updates.

## The skills

| Skill | Runs | Purpose |
|---|---|---|
| [`onboard`](skills/onboard/SKILL.md) | manual, once per machine | install, authenticate, schedule |
| [`process-prs`](skills/process-prs/SKILL.md) | every sweep | fix feedback on your PRs, review others' |
| [`fix-assigned-issues`](skills/fix-assigned-issues/SKILL.md) | every sweep | fix issues assigned to you, open PRs |
| [`join-discussions`](skills/join-discussions/SKILL.md) | every sweep | answer Discussions that @mention you |
| [`reply-notifications`](skills/reply-notifications/SKILL.md) | every sweep | final triage and receipt-aware cleanup |
| [`create-pr`](skills/create-pr/SKILL.md) | helper + manual | commit, sync onto the current base, push, open a PR |
| [`check-status`](skills/check-status/SKILL.md) | manual | health of the automation |
| [`sync-instructions`](skills/sync-instructions/SKILL.md) | manual | pull/edit/push your instruction gist |

The four **sweep** skills are what the cron job runs, in the order listed, and they are
built to need no human at all: no prompts, no confirmations, no "please do this part
yourself". Obstacles are resolved by rules the agent can apply alone — recover leftover
state, retry once, or skip and let the next tick try again — and safety comes from
operations that fail safely rather than from asking first. `create-pr` is called by
`fix-assigned-issues` to ship a fix, and is equally usable on its own.

Reviews fail closed: each PR gets a fresh complete conversation snapshot, clean
verdicts require explicit diff/call-path/test evidence, and a bundled guard rechecks
HEAD, comments, reviews, threads, draft/open state, and CI immediately before posting.
New feedback invalidates an older clean marker even when no new commit was pushed.
CI/mergeability and GitHub's synthetic merge commit remain live gates but are excluded
from durable review identity, so their background recomputation cannot trigger a
duplicate review. Repositories with no HEAD or test-merge checks are treated as having
no CI gate rather than waiting forever.
When a completed clean review is blocked only by CI or mergeability, the sweep leaves
a visible HEAD-bound waiting review instead of hiding the result in local state; that
marker prevents duplicate review while the same gate remains.
The full PR inventory uses a persistent fair queue and processes PRs one at a time.
After each item, the next deep item starts only when the review-time floor still fits;
otherwise the untouched tail stays queued rather than being bulk-skipped. Interrupted
work is handed off only with matching HEAD and guarded state. A malformed cursor is
ignored and replaced on the next advance; malformed handoff entries are reported and
skipped without disabling healthy queue rows. Owner sweeps emit
short-lived coverage receipts; the final notification pass clears routed inbox entries
only when that work was covered or fresh GitHub state proves it is no longer actionable.

The three **manual** skills are for you, and none of them belongs in the cron job.
`onboard` is the only one that changes machine setup. `/check-status` reads the lock,
the crontab, and `~/.good-fellow/logs/`, then names the specific fix for whatever it
finds — a stuck lock holding up every tick, expired Claude or GitHub credentials, runs
hitting the time limit, cron not firing at all (on macOS, usually Full Disk Access), or
a runner generated before a fix landed — and it changes nothing without asking.
`/sync-instructions` pulls your instruction gist into the local cache or pushes edits
back, diffing before it overwrites either side so a local edit is never silently lost,
and creates the gist if you don't have one yet. Scheduled maintenance can safely pull
remote-only changes, but leaves local-only or conflicting edits for this manual skill.

Every skill obeys [`docs/conventions.md`](docs/conventions.md) — the shared rules on
instruction handling, untrusted input, workspace isolation, the bot marker,
idempotence, and unattended discipline.

## Install

There is deliberately **no install script** — the repo is just skills and docs, and
your agent does the setup itself. Clone it anywhere, then run the onboard skill from
whichever agent you use.

```bash
git clone <this-repo> ~/a-good-fellow
cd ~/a-good-fellow
```

Onboarding is **interactive by design** — it may show you a GitHub device-login code
to enter on your phone. If no instruction gist exists, it automatically drafts one
from durable preferences evidenced in available conversation history (falling back to
conservative engineering defaults), creates the secret gist, and shows you the result
for later refinement. The agent will need to create symlinks,
write `~/.good-fellow/run-good-fellow.sh`, and edit your crontab; approve those when
prompted.

### Onboard with Claude Code

```bash
claude
```

Then, in the session:

> Run the onboard skill in skills/onboard/SKILL.md

Once it finishes, the skills are symlinked into `~/.claude/skills/`. **Restart the
CLI** — a session that was already running when the skills were installed does not
know about them, so `/onboard` will come back as an unrecognized command. After the
restart the slash commands work: `/onboard`, `/process-prs`, `/fix-assigned-issues`,
and so on.

### Onboard with Codex

```bash
codex
```

Then, in the session:

> Run the onboard skill in skills/onboard/SKILL.md

Codex will ask for approval before writing files and editing the crontab — accept
those steps. Afterwards the skills live in `~/.codex/skills/`; restart the session so
they are picked up. This repo's [AGENTS.md](AGENTS.md) also tells Codex which skill to
use for what whenever you work inside the repo.

### Onboard with Cursor or another agent

Any agent that reads `SKILL.md` folders works the same way — open the agent in the
repo directory and give it the same instruction:

> Run the onboard skill in skills/onboard/SKILL.md

The skill auto-detects installed agents by their home directories (`~/.claude`,
`~/.codex`, `~/.cursor`) and installs into each one's `skills/` directory; tell it
about any other agent you use and it will install there too.

### What onboarding actually does

- symlinks the skills into the skill directory of every agent installed on the
  machine (`~/.claude/skills/`, `~/.codex/skills/`, `~/.cursor/skills/`, ...);
- checks `gh auth status`, and if needed walks you through the device-code login
  (built for remote machines: it shows you the URL + one-time code and waits);
- finds your `good-fellow-instruction.md` gist, or drafts one from available history
  and conservative defaults and uploads it automatically;
- verifies a headless agent CLI is authenticated for the scheduled runs — claude via
  `~/.claude/.credentials.json` or `CLAUDE_CODE_OAUTH_TOKEN` in `~/.good-fellow/env`
  (from `claude setup-token`); codex via `~/.codex/auth.json` (from `codex login`);
  or cursor-agent;
- materializes a versioned deployment (runtime + matching version runner) under
  `~/.good-fellow/` so a sweep cannot observe a source checkout while it is edited;
- atomically updates `deployment-current` and the stable launcher at
  `~/.good-fellow/run-good-fellow.sh`, then installs the 30-minute cron job (on macOS,
  cron may need Full Disk Access for scheduled runs).
- installs a deterministic maintenance preflight that stays offline between checks,
  then every 48 hours compares the instruction gist and source upstream without model
  tokens. It conflict-safely refreshes the gist cache and fast-forwards a private
  managed source under `~/.good-fellow/source` without touching your checkout, then
  uses that same scheduled agent run to publish an updated immutable deployment. Set
  `GOOD_FELLOW_SYNC_INTERVAL_SECONDS=4147200` in
  `~/.good-fellow/env` if you prefer a 48-day interval.

The agent that onboards you and the agent that runs the sweeps need not be the same:
the runner auto-detects claude → codex → cursor-agent at each tick, and
`GOOD_FELLOW_AGENT=codex` in `~/.good-fellow/env` pins it to one.

Already set up this machine and just want the latest changes? See
[Upgrading an already-onboarded machine](#upgrading-an-already-onboarded-machine)
below — a `git pull` alone is not enough.

## Upgrading an already-onboarded machine

`git pull` is necessary but **not sufficient**:

```bash
cd ~/a-good-fellow && git pull
```

- **Covered by the pull**: every interactively installed skill, plus
  `docs/conventions.md` and `AGENTS.md`. Agent skill directories are symlinks *into*
  this repo, so interactive sessions see the update after restart.
- **Not covered**: a **newly added skill** has no symlink on that machine yet, so the
  agent cannot see it; `~/.good-fellow/run-good-fellow.sh` is a **generated copy**;
  and scheduled sweeps deliberately use an **immutable versioned deployment** rather
  than the mutable checkout. None of those refresh from `git pull` alone.

So after pulling, re-run the onboard skill — it is idempotent and doubles as the
upgrade path. On a machine that is already onboarded the slash command works:

```
/onboard
```

(If the session predates the install and does not recognize it, restart the agent, or
ask it to "run the onboard skill in skills/onboard/SKILL.md".) It refreshes the
symlinks (adding any new skills), materializes a fresh deployment, atomically updates
the pointer/launcher, leaves an existing crontab entry alone, and re-runs the smoke
test.
Then **restart the agent session** so newly added skills appear as slash commands.

Two notes: scheduled synchronization never changes your checkout and preserves a
dirty/diverged managed source or instruction conflict instead of overwriting it; use
`/sync-instructions` to merge the latter. `/check-status` flags a runner that predates
recent fixes, which is a good way to tell whether a machine still needs this.

## Layout

```
skills/              one folder per skill (SKILL.md format, agent-agnostic)
docs/conventions.md  shared rules: gist instructions, untrusted-input boundary,
                     worktree isolation, bot marker, idempotence
```

Anything that must exist as a file on a machine (launcher, deployment pointer, and
versioned runtime/runner pairs) is generated per-machine by the onboard skill, not
versioned here. Runtime state (instruction cache, deployments, PR cursor/handoff,
worktrees, logs, lock, launcher, optional env file) lives in `~/.good-fellow/`, outside
this repo.

## Safety properties

- **Your checkouts are never touched.** Work happens in fresh clones under `~` or in
  `git worktree`s under `~/.good-fellow/worktrees/`; against your existing working
  trees only `worktree add/remove/prune` and read-only git commands are permitted.
- **PR/issue content is treated as data, not instructions** — imperatives inside
  untrusted content are never executed, and untrusted strings are never interpolated
  into shell commands (PRs are addressed by number).
- **Idempotent**: a marker authored by the authenticated user prevents duplicate
  replies and re-reviews; copied marker text from other participants is never trusted.
- **Bounded**: single-instance lock plus a 25-minute timeout per run; never
  force-pushes, closes, or merges anything; the only PR-state mutation is approving a
  clean PR you were asked to review.

## Manual use

Each skill also works standalone in an interactive session: `/check-status`,
`/sync-instructions`, `/process-prs`, `/fix-assigned-issues`, `/create-pr`, and so
on. After onboarding, a one-off full sweep:

```bash
~/.good-fellow/run-good-fellow.sh
```

Dry run (auth/lock/CLI checks only): `GOOD_FELLOW_DRY_RUN=1 ~/.good-fellow/run-good-fellow.sh`
