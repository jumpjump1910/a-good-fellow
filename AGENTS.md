# Agent guide

This repository is a set of agent-agnostic skills that handle GitHub PRs, issues,
notifications, and discussions on the user's behalf.

## Language for this repository's own changes

Write Git commit messages and PR titles and descriptions for `a-good-fellow` in
English. This rule applies only when `a-good-fellow` itself is the repository being
changed. When a good-fellow skill reviews or contributes to another repository, follow
that repository's established language and the conversation's language guidance; do
not force English on its commits, PRs, code reviews, or replies.

Before executing any skill here, read `docs/conventions.md` — it defines the
untrusted-input boundary, workspace isolation rules, the `<!-- good-fellow:v1 -->`
marker, and idempotence requirements. Also read `~/.good-fellow/instruction.md`
(the user's standing instructions, cached from their gist) and apply it to every
GitHub task.

Skills (each in `skills/<name>/SKILL.md`):

- `onboard` — interactive setup: skill installation, gh login, instruction gist,
  headless auth, generated cron runner. Start here on a fresh machine.
- `reply-notifications` — final sweep: reply where warranted and reconcile routed
  notifications against owner-sweep receipts/current state.
- `join-discussions` — reply to Discussions that @mention the user.
- `fix-assigned-issues` — fix assigned issues and open PRs.
- `create-pr` — commit, sync onto the current base, push, and open a PR from a
  working tree with changes.
- `process-prs` — fix feedback on the user's PRs (any fix — a comment to address, a
  bug, a CI failure — on a release PR whose head is a shared branch such as `dev` is
  made on a new branch cut from the latest `dev` and shipped as a separate PR into
  `dev` via `create-pr`, never pushed to the head directly; a reported race is fixed as
  its whole class, not one interleaving); review others' PRs (every critical issue of
  a HEAD in one comment, grouped by the invariant they break; otherwise a concise,
  concrete rationale, with bare `LGTM` only for extremely simple changes; fail closed on incomplete evidence or stale state,
  approve only when clean and review was requested, leave a visible HEAD-bound
  waiting outcome when external gates block approval, and persist fair round-robin
  progress plus HEAD/state-bound handoffs across bounded runs).
- `check-status` — read-only health check: is a sweep running, is cron firing, what
  did recent runs do, and what specifically to fix when they didn't.
- `sync-instructions` — pull the instruction gist to the local cache, or edit and
  push it back; diffs before overwriting either side.

Only `onboard` and `sync-instructions` change the user's instructions or machine
setup; `check-status` never changes anything without asking.

The scheduled entry point is `~/.good-fellow/run-good-fellow.sh` (cron, every 30
minutes) — a stable launcher that atomically selects a versioned runtime/runner pair
via `~/.good-fellow/deployment-current`. Before invoking a model, its deterministic
maintenance gate stays offline until the configured interval (48 hours by default),
then conflict-safely refreshes the instruction cache and cleanly fast-forwards a
private managed source without touching the user's checkout. Onboard generates these
machine-local files from `skills/onboard/SKILL.md`; they are not versioned here.
