---
name: check-status
description: Report the health of the good-fellow automation - whether a sweep is running right now, whether the 30-minute cron job is installed and firing, what the recent runs did, and why they failed or were skipped. Diagnoses stuck locks, expired credentials, timeouts, and blocked writes. Use when the user asks about cron job status, whether the bot is running, why nothing happened, or to check on the automation.
---

# Check Status

Read-only health check of the good-fellow automation. Read `docs/conventions.md`
(repo root of this skill) first.

**Do not change anything without asking.** Every remediation below is a suggestion to
put in front of the user; only act after they say so. The one exception is reading
logs and process state, which is always safe.

This skill is diagnostic, so unlike the sweeps it may ask questions — but it must never
*block* on one. If it is running with no user present (e.g. someone added it to a
schedule), print the findings and the recommended commands and exit; do not wait, and
do not remediate on your own.

Lead the report with a one-line verdict — healthy / running now / degraded / not
running at all — then the supporting detail.

## 1. Is a sweep running right now?

```bash
cat ~/.good-fellow/.lock.pid 2>/dev/null
ps -o pid,lstart,etime,cmd -p "$(cat ~/.good-fellow/.lock.pid 2>/dev/null)" 2>/dev/null
```

- Holder alive → a sweep is in flight; report its elapsed time and which log file it
  is writing (`ls -t ~/.good-fellow/logs/*.log | head -1`).
- Pidfile present but the process is gone → a crashed run left the pidfile. Harmless
  on the flock path (the lock died with the process); note it and move on.
- On macOS the lock is a directory: check `~/.good-fellow/.lock.d/pid` instead.

Compare the elapsed time against `MAX_RUNTIME` (1500s default). A run older than that
should have been killed by `timeout`; if it wasn't, `timeout`/`gtimeout` is missing on
this machine and the runner is unbounded — worth flagging.

## 2. Is the schedule installed and firing?

```bash
crontab -l 2>/dev/null | grep -n 'run-good-fellow'
ls -lt ~/.good-fellow/logs/ | head -10
```

Every tick writes a log, so the newest log timestamp tells you when cron last fired.
Judge against the schedule (`7,37 * * * *` → at most ~30 minutes old):

- No crontab entry → onboarding never finished the schedule step. Suggest `/onboard`.
- Entry present but no logs at all → cron is not executing the job. Usual causes: on
  macOS, `cron` lacks Full Disk Access (System Settings → Privacy & Security); on any
  OS, the crontab `PATH` does not contain `gh` or the agent CLI, or the runner is not
  executable (`test -x ~/.good-fellow/run-good-fellow.sh`).
- Newest log much older than one tick → cron stopped firing; check the system cron
  service and whether the crontab was rewritten by another tool.

## 3. What did recent runs do?

```bash
for f in $(ls -t ~/.good-fellow/logs/*.log | head -12); do echo "== $f"; tail -5 "$f"; done
```

Classify each run by its final line:

| Log line | Meaning |
|---|---|
| `done (status 0)` | clean run |
| `previous run still going (holder N, Ns); skipping this tick` | normal only if a real run was in flight |
| `ERROR: lock stuck for Ns ... reclaiming` | a leaked holder was cleaned up; the run then proceeded |
| `hit the Ns timeout` | the sweep ran out of time; work rolls to the next tick |
| `<agent> hit a usage quota; falling back to <other>` | the preferred CLI was out of quota; this tick continued on the next authenticated agent |
| `<agent> hit a usage quota; Ns left is too little to restart` | the quota hit too late in the tick to rerun; work rolls to the next tick |
| `FATAL: gh not logged in` | GitHub credentials gone |
| `FATAL: no authenticated agent CLI` | agent credentials gone |
| `missing/invalid good-fellow deployment` | launcher pointer or selected deployment is absent/corrupt |
| `invalid GOOD_FELLOW_AGENT` | bad agent override in `~/.good-fellow/env` or cron environment |
| `invalid GOOD_FELLOW_*` / `must be at least` | malformed runtime/review-budget configuration |
| `maintenance: ... preserving ...` | a source or instruction conflict was detected and left untouched |
| `maintenance: source_updated=<sha>` | source fast-forwarded; the same run should republish the deployment |
| `done (status N)` with N≠0 | the agent itself errored — read the body of that log |

## 4. Red flags worth calling out

Resolve the selected version runner first:

```bash
DEPLOY_DIR=$(cat ~/.good-fellow/deployment-current 2>/dev/null)
VERSION_RUNNER="$DEPLOY_DIR/run-good-fellow.sh"
```

- **Consecutive skips.** Several ticks in a row ending in `skipping this tick` with the
  same holder PID means a leaked process is holding the lock and nothing is running.
  The runner self-heals after `2×MAX_RUNTIME+300s`, so if you see this *and* the age
  is below that threshold, it is genuinely still working; above it, the reclaim logic
  should have fired — if it didn't, the version runner predates that fix. Verify with
  `grep -c STALE_AFTER "$VERSION_RUNNER"` and suggest re-running
  `/onboard` to regenerate it.
- **Missing `--add-dir`.** `grep -c 'add-dir' "$VERSION_RUNNER"` → 0
  means unattended sweeps cannot write to `~/<repo>` or `~/.good-fellow/worktrees/`,
  so runs fail silently with nobody to approve the prompt. Suggest regenerating the
  runner.
- **Runner predates review-safety fixes.** The runner is stale if it lacks
  the `deployment-current` launcher protocol. Read the regular pointer, require it to
  name `~/.good-fellow/deploy-*`, and require that deployment to carry a
  `runtime-version` stamp file — onboard writes the deployed commit there exactly so
  freshness is one comparison. A missing stamp means the deployment predates the
  stamping protocol and is stale; when the local repository is available, a stamp
  differing from its current HEAD means the deployment lags it (report which commit
  is deployed rather than guessing severity). Also require the deployment's
  `runtime/skills`, `runtime/docs`, and executable `pr-queue.sh`, `pr-handoff.sh`,
  `pr-review-guard.sh`, `pr-inventory.sh`, and `notification-receipts.sh`. Two
  content checks remain because they are security boundaries, not version probes:
  the Claude command must include `--disable-slash-commands` and not allow the
  global `Skill` tool, and the Codex command must use the deployment's paired
  `CODEX_HOME` — missing isolation flags can bypass the immutable runtime through
  interactive skill symlinks. Any failure means the scheduled code is stale or
  incomplete: suggest re-running `/onboard`. Do not grep the runtime for
  fix-specific strings; that list rots with every rename.
- **Repeated timeouts.** Consistently hitting the limit means the workload no longer
  fits in one tick. Suggest raising `GOOD_FELLOW_MAX_RUNTIME` in `~/.good-fellow/env`
  or narrowing scope in the instruction gist. Current runners clamp values at or above
  the 30-minute cadence to 1799 seconds with a warning so an older `1800` setting does
  not brick the schedule.
- **Credential expiry.** Claude OAuth refresh tokens expire roughly monthly; a run of
  `FATAL` lines starting on one date usually means a re-login is due
  (`claude setup-token`, then update `~/.good-fellow/env`).
- **Model quota.** Repeated `done (status 1)` a couple of seconds into each tick, with
  a `reached your ... limit` line in the body, is a usage quota rather than an auth
  failure — `gh auth status` and the agent credentials will both look fine. Current
  runners rotate to the next authenticated CLI when this happens, so a quota that
  still stalls every tick means one of: no second agent is authenticated, the run
  pinned `GOOD_FELLOW_AGENT` (an explicit pin deliberately outranks the fallback), or
  the deployed runner predates the fallback. Suggest pinning a model that still has
  budget (`ANTHROPIC_MODEL=claude-opus-5` in `~/.good-fellow/env`, which the runner
  exports) and re-running `/onboard` if the runner is the stale part.
- **Stale worktrees.** `ls ~/.good-fellow/worktrees/` piling up means runs are dying
  before cleanup. First exclude intentional ones: paths printed by
  `<repo-root>/skills/fix-assigned-issues/scripts/issue-stage.sh staged-workspaces`
  hold staged in-progress issue work and must not be pruned. Beyond those, leftovers
  stay in place deliberately after failures, but a large backlog is a signal — offer
  to prune with `git worktree prune` per repo.
- **Malformed queue state.** `pr-queue: ignoring malformed cursor` or
  `pr-handoff: ignoring invalid state file` is recoverable: healthy rows continue and
  the next cursor advance replaces a bad cursor. Report the affected path; repeated
  warnings for the same handoff mean the corrupt file should be inspected and removed.
- **Deployment buildup.** Current onboarding retains the three newest real
  `~/.good-fellow/deploy-*` directories. More than three after a successful onboarding
  indicates an older publisher or a cleanup failure.
- **Maintenance freshness.** Read `~/.good-fellow/maintenance-last-check` as an epoch
  and compare it with the current time and `GOOD_FELLOW_SYNC_INTERVAL_SECONDS`
  (172800 by default). A missing/overdue stamp means the deployed runner predates the
  maintenance gate or GitHub checks keep failing. If
  `~/.good-fellow/maintenance-source-updated` names a source commit different from
  the selected deployment's `runtime-version`, the source fast-forward succeeded but
  republishing did not; suggest `/onboard`. Report local/gist conflict messages from
  recent logs and suggest `/sync-instructions` rather than overwriting either side.

## 5. Is work moving fairly?

The PR sweep persists its last completed item here:

```bash
cat ~/.good-fellow/process-prs.cursor 2>/dev/null
HANDOFF_TOOL="$DEPLOY_DIR/runtime/skills/process-prs/scripts/pr-handoff.sh"
"$HANDOFF_TOOL" show
"$HANDOFF_TOOL" reviewing-key
"$HANDOFF_TOOL" queue-rows
for f in ~/.good-fellow/process-prs-handoff-*.state; do
  [ -f "$f" ] || continue
  ls -lT "$f" 2>/dev/null || ls -l --time-style=long-iso "$f" 2>/dev/null
done
gh api /notifications --paginate --jq '.[] | [.reason,.repository.full_name,.subject.type,.subject.url,.updated_at] | @tsv' | sort | uniq -c
```

Compare the cursor across recent successful ticks and correlate it with each log's
per-PR outcomes. A moving cursor means round-robin progress even when one run cannot
finish the inventory. There is no item-count quota: after each completed PR, another
deep item should start whenever `GOOD_FELLOW_MIN_REVIEW_SECONDS` still fits. An
unchanged cursor is expected only when the current item has a valid, changing handoff,
was left untouched due to that review-time floor, or the run failed before classifying
it. Report the effective review floor from `~/.good-fellow/env` or the version-runner
default.

Use `show`; never parse handoff internals. At most one `reviewing` handoff may exist,
because partial work holds the cursor and must resume before later deep work; if two
appear, `reviewing-key` self-heals by keeping the newest and deleting the rest, so a
persisting pair means the deployed runtime predates that fix. A `reviewing` handoff
plus an unchanged cursor across several sufficiently long successful ticks means work
is stuck. For `reviewed` handoffs there is exactly one staleness rule: a `reviewed`
handoff is healthy while a guarded outcome has not yet been safely attempted or
confirmed, and stale once its PR's gates have settled or its queue row recurred
without a confirmed outcome/clear — a completed clean review awaiting CI or
mergeability should instead show a visible gate-waiting marker and no retained
handoff. A valid open handoff must appear in `queue-rows` even if GitHub search no
longer lists that PR; otherwise continuation state has become orphaned from
scheduling.
Routed `review_requested`, `assign`, and Discussion
notifications may remain unread only while their open item still needs its owner
sweep; a large pile of closed, merged, draft, unassigned, or no-longer-requested
items means the final receipt-aware cleanup did not run.

## 6. What the automation actually accomplished

Logs say whether runs succeeded; GitHub says whether they were useful. Sample the
recent output by searching for the marker:

```bash
gh search prs --state=open --involves=@me --json repository,number,url --limit 20
```

Then for a few of those, check whether a comment/review authored by the authenticated
login carries `<!-- good-fellow:v1 -->` and when. Ignore marker-looking text authored
by anyone else. Report a short tally (PRs reviewed, threads resolved, issues picked
up) rather than dumping raw JSON.

## 7. Report

One-line verdict, then: current run (if any), schedule and last fire time, the last
few runs with outcomes, queue/cursor movement, routed-notification backlog, red flags
with the specific suggested fix, and recent GitHub activity. Keep it short enough to
read at a glance; no raw log dumps unless something failed, in which case include the
relevant excerpt.
