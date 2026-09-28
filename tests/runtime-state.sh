#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
QUEUE="$ROOT/skills/process-prs/scripts/pr-queue.sh"
HANDOFF="$ROOT/skills/process-prs/scripts/pr-handoff.sh"
GUARD="$ROOT/skills/process-prs/scripts/pr-review-guard.sh"
RECEIPTS="$ROOT/skills/reply-notifications/scripts/notification-receipts.sh"
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/good-fellow-runtime-test.XXXXXX")

cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/good-fellow-runtime-test.*) find "$TEMP_ROOT" -depth -delete ;;
    *) printf 'unsafe test temp path: %s\n' "$TEMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'runtime-state test failed: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

# A malformed cursor is advisory state: ordering restarts deterministically and the
# next successful advance will replace it.
queue_state="$TEMP_ROOT/queue-state"
mkdir -p "$queue_state"
printf 'not-a-valid-cursor\n' > "$queue_state/process-prs.cursor"
inventory="$TEMP_ROOT/inventory.tsv"
printf '%s\n' \
  $'https://api.github.com/repos/acme/app\t1\tauthor\thttps://github.com/acme/app/pull/1\tfalse' \
  $'https://api.github.com/repos/acme/app\t2\tauthor\thttps://github.com/acme/app/pull/2\tfalse' \
  > "$inventory"
ordered=$(GOOD_FELLOW_STATE_DIR="$queue_state" "$QUEUE" order "$inventory" 2> "$TEMP_ROOT/queue.err")
assert_eq "$(printf '%s\n' "$ordered" | sed -n '1p')" \
  $'https://api.github.com/repos/acme/app\t1\tauthor\thttps://github.com/acme/app/pull/1\tfalse'
grep -F 'ignoring malformed cursor' "$TEMP_ROOT/queue.err" >/dev/null || fail 'missing cursor recovery warning'

# Collection operations skip one corrupt handoff instead of bricking the sweep or
# the status command that is meant to diagnose it.
handoff_state="$TEMP_ROOT/handoff-state"
mkdir -p "$handoff_state"
printf 'truncated\n' > "$handoff_state/process-prs-handoff-bad.state"
for mode in show reviewing-key queue-rows prune; do
  GOOD_FELLOW_STATE_DIR="$handoff_state" "$HANDOFF" "$mode" \
    > "$TEMP_ROOT/handoff-$mode.out" 2> "$TEMP_ROOT/handoff-$mode.err" ||
    fail "handoff $mode rejected the complete collection"
done
grep -F 'ignoring invalid state file' "$TEMP_ROOT/handoff-show.err" >/dev/null ||
  fail 'missing corrupt handoff warning'

# Draft PRs intentionally advance without receipts; reject an implementation that
# accidentally records draft coverage.
proof=$(printf '%064d' 0 | tr 0 a)
set +e
GOOD_FELLOW_STATE_DIR="$TEMP_ROOT/receipt-state" \
  "$RECEIPTS" record pr https://api.github.com/repos/acme/app 1 1 \
  2026-08-19T00:00:00Z - draft - "$proof" \
  > "$TEMP_ROOT/receipt.out" 2> "$TEMP_ROOT/receipt.err"
receipt_status=$?
set -e
assert_eq "$receipt_status" 64
grep -F 'invalid covered outcome' "$TEMP_ROOT/receipt.err" >/dev/null ||
  fail 'draft receipt failed for the wrong reason'

receipt_state="$TEMP_ROOT/receipt-prune"
mkdir -p "$receipt_state"
old_receipt="$receipt_state/notification-receipts-old-pr-acme-app-1-1.tsv"
new_receipt="$receipt_state/notification-receipts-new-pr-acme-app-1-2.tsv"
printf 'old\n' > "$old_receipt"
printf 'new\n' > "$new_receipt"
touch -t 202001010000 "$old_receipt"
GOOD_FELLOW_STATE_DIR="$receipt_state" "$RECEIPTS" prune
[ ! -e "$old_receipt" ] || fail 'old receipt survived the one-day prune window'
[ -f "$new_receipt" ] || fail 'fresh receipt was pruned'

# Stub only the GitHub transport. The guard still parses and validates its real
# snapshot/body formats. The second capture changes full CI state while preserving
# stable external state, proving waiting submissions do not spin on active CI.
stub_bin="$TEMP_ROOT/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${STUB_MODE:-waiting}" = receipt ]; then
  if [ "${1:-}" = api ] && [ "${2:-}" = /notifications/threads/1 ]; then
    printf '2026-08-19T00:00:00Z\t-\n'
    exit 0
  fi
  printf 'unexpected receipt gh invocation\n' >&2
  exit 64
fi

if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  if [ "${STUB_MODE:-waiting}" = overflow ]; then
    printf 'gh: reviews exceed 100\n' >&2
    exit 1
  fi
  count=0
  [ ! -f "$STUB_COUNT_FILE" ] || count=$(cat "$STUB_COUNT_FILE")
  count=$((count + 1))
  printf '%s\n' "$count" > "$STUB_COUNT_FILE"
  ci=false
  if [ "${STUB_MODE:-waiting}" = approval ] && [ "$count" -ge 2 ]; then ci=true; fi
  stable='{"pullRequest":{"stable":"same"}}'
  index='pr|PR_1|author|2026-08-19T00:00:00Z|-'
  unseen=-
  if [ "${STUB_MODE:-waiting}" = unseen ]; then ci=true; unseen=IC_open; fi
  if [ "${STUB_MODE:-waiting}" = drift ]; then
    stable="{\"pullRequest\":{\"stable\":$count}}"
  fi
  if [ "${STUB_MODE:-waiting}" = conversation ] && [ "$count" -ge 2 ]; then
    stable='{"pullRequest":{"stable":"commented"}}'
    index="comment|IC_late|human|2026-08-19T00:00:07Z|2026-08-19T00:00:07Z $index"
  fi
  printf '%s\n' \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    reviewer \
    true \
    author \
    "$ci" \
    true \
    true \
    "$stable" \
    "{\"pullRequest\":{\"ciVersion\":$count}}" \
    "{\"pullRequest\":{\"legacyMergeVersion\":$count}}" \
    false \
    - \
    "$index" \
    "$unseen"
  exit 0
fi

if [ "${1:-}" = api ]; then
  printf '%s\n' "$*" >> "$STUB_POST_LOG"
  exit 0
fi

printf 'unexpected gh invocation\n' >&2
exit 64
GH_STUB
chmod +x "$stub_bin/gh"
export PATH="$stub_bin:$PATH"
export STUB_COUNT_FILE="$TEMP_ROOT/gh-count"
export STUB_POST_LOG="$TEMP_ROOT/gh-posts"

# A declined Issue is covered only through the explicit owner-sweep outcome, and
# only when it carries the decline comment's id: cleanup independently re-fetches
# and re-verifies that exact comment rather than trusting the aggregate subject
# digest alone. The receipt helper must accept and round-trip both the outcome and
# the comment id so final notification cleanup can consume the exact commented
# subject/version without causing duplicate comments.
export STUB_MODE=receipt
declined_receipt_state="$TEMP_ROOT/declined-receipt-state"
GOOD_FELLOW_STATE_DIR="$declined_receipt_state" GOOD_FELLOW_RUN_STARTED_AT_EPOCH=test-declined \
  "$RECEIPTS" record issue https://api.github.com/repos/acme/app 1 1 \
  2026-08-19T00:00:00Z - declined 42 "$proof"
declined_row=$(GOOD_FELLOW_STATE_DIR="$declined_receipt_state" \
  "$RECEIPTS" lookup issue https://api.github.com/repos/acme/app 1 1 \
  2026-08-19T00:00:00Z -)
assert_eq "$(printf '%s\n' "$declined_row" | cut -f7)" declined
assert_eq "$(printf '%s\n' "$declined_row" | cut -f8)" 42

# A `declined` receipt with no comment id is not independently reverifiable, so it
# must be rejected at record time rather than accepted as silent coverage.
set +e
GOOD_FELLOW_STATE_DIR="$TEMP_ROOT/declined-no-comment-state" GOOD_FELLOW_RUN_STARTED_AT_EPOCH=test-declined-bad \
  "$RECEIPTS" record issue https://api.github.com/repos/acme/app 1 1 \
  2026-08-19T00:00:00Z - declined - "$proof" \
  > "$TEMP_ROOT/declined-no-comment.out" 2> "$TEMP_ROOT/declined-no-comment.err"
declined_no_comment_status=$?
set -e
assert_eq "$declined_no_comment_status" 64
grep -F 'declined outcome requires a comment id' "$TEMP_ROOT/declined-no-comment.err" >/dev/null ||
  fail 'declined receipt without a comment id failed for the wrong reason'

make_marker_body() {
  local snapshot=$1 action=$2 verdict=$3 output=$4 first_line=$5
  local head base token
  head=$("$GUARD" head "$snapshot")
  base=$("$GUARD" base "$snapshot")
  token=$("$GUARD" token "$snapshot")
  printf '%s\n\n<!-- good-fellow:v1 reviewed=%s base=%s state=%s action=%s verdict=%s -->\n' \
    "$first_line" "$head" "$base" "$token" "$action" "$verdict" > "$output"
}

export STUB_MODE=waiting
printf '0\n' > "$STUB_COUNT_FILE"
: > "$STUB_POST_LOG"
waiting_snapshot="$TEMP_ROOT/waiting.snapshot"
waiting_body="$TEMP_ROOT/waiting.body"
"$GUARD" snapshot owner repo 1 > "$waiting_snapshot"
make_marker_body "$waiting_snapshot" comment waiting "$waiting_body" \
  '当前 HEAD 审查完成；CI 仍在运行，因此暂不批准。'
"$GUARD" verify-external owner repo 1 "$waiting_snapshot" > "$TEMP_ROOT/waiting.verify"
grep -Fx fresh "$TEMP_ROOT/waiting.verify" >/dev/null || fail 'stable verify rejected CI-only drift'
"$GUARD" submit-comment owner repo 1 "$waiting_snapshot" "$waiting_body" \
  > "$TEMP_ROOT/waiting.submit"
grep -F 'event=COMMENT' "$STUB_POST_LOG" >/dev/null || fail 'waiting comment was not submitted'

# Clean gates are evaluated from the fresh capture, not the stale baseline. This
# baseline is CI=false and the submission capture is CI=true.
export STUB_MODE=approval
printf '0\n' > "$STUB_COUNT_FILE"
: > "$STUB_POST_LOG"
approval_snapshot="$TEMP_ROOT/approval.snapshot"
approval_body="$TEMP_ROOT/approval.body"
"$GUARD" snapshot owner repo 1 > "$approval_snapshot"
assert_eq "$("$GUARD" ci-clean "$approval_snapshot")" false
make_marker_body "$approval_snapshot" approve clean "$approval_body" \
  'LGTM — 已检查当前 HEAD 的关键行为与失败边界。'
"$GUARD" submit-approve owner repo 1 "$approval_snapshot" "$approval_body" \
  > "$TEMP_ROOT/approval.submit"
grep -F 'event=APPROVE' "$STUB_POST_LOG" >/dev/null || fail 'fresh clean approval was not submitted'

# An approval asserts every comment was judged. One the viewer never marked seen
# (here the user's own open concern) blocks it even with green CI and threads.
export STUB_MODE=unseen
printf '0\n' > "$STUB_COUNT_FILE"
: > "$STUB_POST_LOG"
unseen_snapshot="$TEMP_ROOT/unseen.snapshot"
unseen_body="$TEMP_ROOT/unseen.body"
"$GUARD" snapshot owner repo 1 > "$unseen_snapshot"
make_marker_body "$unseen_snapshot" approve clean "$unseen_body" \
  'LGTM — 已检查当前 HEAD 的关键行为与失败边界。'
set +e
"$GUARD" submit-approve owner repo 1 "$unseen_snapshot" "$unseen_body" \
  > "$TEMP_ROOT/unseen.out" 2> "$TEMP_ROOT/unseen.err"
unseen_status=$?
set -e
assert_eq "$unseen_status" 64
grep -F 'unseen: IC_open' "$TEMP_ROOT/unseen.err" >/dev/null || fail 'unseen comment did not block approval'
[ ! -s "$STUB_POST_LOG" ] || fail 'approval was submitted past an unseen comment'

# A handoff written with the previous token schema remains resumable while its
# HEAD/base and legacy external state still match the captured snapshot.
export STUB_MODE=waiting
printf '0\n' > "$STUB_COUNT_FILE"
legacy_snapshot="$TEMP_ROOT/legacy.snapshot"
"$GUARD" snapshot owner repo 1 > "$legacy_snapshot"
legacy_token=$("$GUARD" legacy-token "$legacy_snapshot")
legacy_head=$("$GUARD" head "$legacy_snapshot")
legacy_base=$("$GUARD" base "$legacy_snapshot")
legacy_payload='{}'
legacy_size=${#legacy_payload}
legacy_state="$TEMP_ROOT/legacy-state"
mkdir -p "$legacy_state"
legacy_file="$legacy_state/process-prs-handoff-5-owner-4-repo-1.state"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  good-fellow-pr-handoff-v1 owner repo 1 "$legacy_head" "$legacy_base" \
  "$legacy_token" reviewed "$legacy_size" "$legacy_payload" > "$legacy_file"
legacy_phase=$(GOOD_FELLOW_STATE_DIR="$legacy_state" "$HANDOFF" match owner repo 1 "$legacy_snapshot")
assert_eq "$legacy_phase" reviewed

migrate_state="$TEMP_ROOT/migrate-state"
mkdir -p "$migrate_state"
migrate_file="$migrate_state/process-prs-handoff-5-owner-4-repo-1.state"
migrate_token=$(printf '%064d' 0 | tr 0 c)
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  good-fellow-pr-handoff-v1 owner repo 1 "$legacy_head" "$legacy_base" \
  "$migrate_token" reviewed "$legacy_size" "$legacy_payload" > "$migrate_file"
migrate_phase=$(GOOD_FELLOW_STATE_DIR="$migrate_state" "$HANDOFF" match owner repo 1 "$legacy_snapshot")
assert_eq "$migrate_phase" reviewed-migrate

# A conversation item posted between snapshot and submission must be named in
# the exit-3 diagnostics, so a restart cannot attribute the token change to a HEAD
# move alone and skip the new comment. HEAD is unchanged here on purpose.
export STUB_MODE=conversation
printf '0\n' > "$STUB_COUNT_FILE"
: > "$STUB_POST_LOG"
conversation_snapshot="$TEMP_ROOT/conversation.snapshot"
conversation_body="$TEMP_ROOT/conversation.body"
"$GUARD" snapshot owner repo 1 > "$conversation_snapshot"
make_marker_body "$conversation_snapshot" comment waiting "$conversation_body" \
  '当前 HEAD 审查完成；CI 仍在运行，因此暂不批准。'
set +e
"$GUARD" submit-comment owner repo 1 "$conversation_snapshot" "$conversation_body" \
  > "$TEMP_ROOT/conversation.out" 2> "$TEMP_ROOT/conversation.err"
conversation_status=$?
set -e
assert_eq "$conversation_status" 3
grep -Fx 'pr-review-guard: changed: new comment IC_late by human at 2026-08-19T00:00:07Z' \
  "$TEMP_ROOT/conversation.err" >/dev/null || fail 'late comment was not named on exit 3'
! grep -F 'changed: HEAD' "$TEMP_ROOT/conversation.err" >/dev/null ||
  fail 'unchanged HEAD was reported as changed'
[ ! -s "$STUB_POST_LOG" ] || fail 'stale-conversation review was submitted'
export STUB_MODE=waiting

# The snapshot lines 9/11 are digests: the only PR JSON in the file is the
# complete ledger on line 10.
sed -n '9p;11p' "$legacy_snapshot" | grep -Ex '[0-9a-f]{64}' | wc -l | grep -Fx 2 >/dev/null ||
  fail 'token lines are not stored as digests'
"$GUARD" ledger "$legacy_snapshot" | grep -F '"pullRequest"' >/dev/null ||
  fail 'ledger line lost its JSON'

# Live drift between capturing a snapshot and matching it must return 5
# (recapture and retry), never 3 (clear the handoff): the handoff itself was
# not judged.
export STUB_MODE=drift
printf '0\n' > "$STUB_COUNT_FILE"
drift_snapshot="$TEMP_ROOT/drift.snapshot"
"$GUARD" snapshot owner repo 1 > "$drift_snapshot"
drift_head=$("$GUARD" head "$drift_snapshot")
drift_base=$("$GUARD" base "$drift_snapshot")
drift_token=$("$GUARD" token "$drift_snapshot")
drift_state="$TEMP_ROOT/drift-state"
mkdir -p "$drift_state"
drift_file="$drift_state/process-prs-handoff-5-owner-4-repo-1.state"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  good-fellow-pr-handoff-v1 owner repo 1 "$drift_head" "$drift_base" \
  "$drift_token" reviewed "$legacy_size" "$legacy_payload" > "$drift_file"
set +e
GOOD_FELLOW_STATE_DIR="$drift_state" "$HANDOFF" match owner repo 1 "$drift_snapshot" \
  > "$TEMP_ROOT/drift.out" 2> "$TEMP_ROOT/drift.err"
drift_status=$?
set -e
assert_eq "$drift_status" 5
grep -F 'recapture and retry' "$TEMP_ROOT/drift.err" >/dev/null ||
  fail 'drift did not ask for a recapture'

# A durably over-capacity PR reports exit 7 so the queue can advance past it
# instead of retrying forever.
export STUB_MODE=overflow
set +e
"$GUARD" snapshot owner repo 1 > "$TEMP_ROOT/overflow.snapshot" 2> "$TEMP_ROOT/overflow.err"
overflow_status=$?
set -e
assert_eq "$overflow_status" 7
grep -F 'bounded snapshot capacity' "$TEMP_ROOT/overflow.err" >/dev/null ||
  fail 'overflow was not reported distinctly'
export STUB_MODE=waiting

# Duplicate reviewing handoffs self-heal: the newest file wins, the older one
# is deleted with a warning, and the sweep keeps running.
dup_state="$TEMP_ROOT/dup-reviewing"
mkdir -p "$dup_state"
dup_old="$dup_state/process-prs-handoff-5-owner-4-repo-1.state"
dup_new="$dup_state/process-prs-handoff-5-owner-4-repi-2.state"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  good-fellow-pr-handoff-v1 owner repo 1 "$legacy_head" "$legacy_base" \
  "$legacy_token" reviewing "$legacy_size" "$legacy_payload" > "$dup_old"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  good-fellow-pr-handoff-v1 owner repi 2 "$legacy_head" "$legacy_base" \
  "$legacy_token" reviewing "$legacy_size" "$legacy_payload" > "$dup_new"
touch -t 202001010000 "$dup_old"
dup_key=$(GOOD_FELLOW_STATE_DIR="$dup_state" "$HANDOFF" reviewing-key 2> "$TEMP_ROOT/dup.err")
assert_eq "$dup_key" $'https://api.github.com/repos/owner/repi\t2'
[ ! -e "$dup_old" ] || fail 'older duplicate reviewing handoff survived'
[ -f "$dup_new" ] || fail 'newest reviewing handoff was deleted'
grep -F 'serial ownership violated' "$TEMP_ROOT/dup.err" >/dev/null ||
  fail 'missing duplicate reviewing warning'

# Exercise the exact runner embedded in onboard with legacy 1800-second settings.
# Stubbed CLIs keep this test offline while proving both values clamp and the run
# still reaches its dry-run sentinel.
runner_home="$TEMP_ROOT/runner-home"
runner_deploy="$runner_home/.good-fellow/candidate"
mkdir -p "$runner_deploy/runtime/skills" "$runner_deploy/runtime/docs" \
  "$runner_home/.local/bin"
runner="$runner_deploy/run-good-fellow.sh"
awk '/^# good-fellow version runner — generated by the onboard skill\.$/ {
       print "#!/usr/bin/env bash"; print; emit=1; next
     }
     emit && /^```$/ {exit}
     emit {print}' "$ROOT/skills/onboard/SKILL.md" > "$runner"
cat > "$runner_home/.local/bin/gh" <<'GH_AUTH_STUB'
#!/usr/bin/env bash
exit 0
GH_AUTH_STUB
cat > "$runner_home/.local/bin/claude" <<'CLAUDE_STUB'
#!/usr/bin/env bash
printf 'good-fellow dry run ok.\n'
CLAUDE_STUB
chmod +x "$runner" "$runner_home/.local/bin/gh" "$runner_home/.local/bin/claude"
runner_output=$(HOME="$runner_home" CLAUDE_CODE_OAUTH_TOKEN=test \
  GOOD_FELLOW_DRY_RUN=1 GOOD_FELLOW_MAX_RUNTIME=1800 \
  GOOD_FELLOW_MIN_REVIEW_SECONDS=1800 "$runner" 2>&1)
printf '%s\n' "$runner_output" | grep -F 'clamping to 1799' >/dev/null ||
  fail 'legacy max runtime was not clamped'
printf '%s\n' "$runner_output" | grep -F 'clamping to 1679' >/dev/null ||
  fail 'oversized review floor was not clamped'
printf '%s\n' "$runner_output" | grep -Fx 'good-fellow dry run ok.' >/dev/null ||
  fail 'clamped runner did not reach the dry-run sentinel'
printf '%s\n' "$runner_output" | grep -F 'done (status 0)' >/dev/null ||
  fail 'clamped runner did not finish cleanly'

# A usage quota on the preferred CLI must rotate to the next authenticated agent
# within the same tick, because the sweep is re-entrant and the quota rejection cost
# almost none of the budget. Reuse the runner home, swapping in stubs per case.
mkdir -p "$runner_home/.codex"
printf '{"stub":true}\n' > "$runner_home/.codex/auth.json"
cat > "$runner_home/.local/bin/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
printf 'good-fellow dry run ok.\n'
CODEX_STUB
cat > "$runner_home/.local/bin/claude" <<'CLAUDE_QUOTA_STUB'
#!/usr/bin/env bash
printf "You've reached your Fable limit. Switch to another model, or manage usage credits.\n"
exit 1
CLAUDE_QUOTA_STUB
chmod +x "$runner_home/.local/bin/codex" "$runner_home/.local/bin/claude"

quota_output=$(HOME="$runner_home" CLAUDE_CODE_OAUTH_TOKEN=test \
  GOOD_FELLOW_DRY_RUN=1 "$runner" 2>&1)
printf '%s\n' "$quota_output" | grep -F 'falling back to codex' >/dev/null ||
  fail 'quota on the preferred CLI did not fall back'
printf '%s\n' "$quota_output" | grep -Fx 'good-fellow dry run ok.' >/dev/null ||
  fail 'fallback agent did not reach the dry-run sentinel'
printf '%s\n' "$quota_output" | grep -F 'done (status 0)' >/dev/null ||
  fail 'fallback run did not finish cleanly'
[ ! -e "$runner_home/.good-fellow/.agent-output" ] ||
  fail 'agent output capture leaked after the run'

# An explicit agent pin is the user's choice and outranks the fallback.
pinned_status=0
pinned_output=$(HOME="$runner_home" CLAUDE_CODE_OAUTH_TOKEN=test GOOD_FELLOW_AGENT=claude \
  GOOD_FELLOW_DRY_RUN=1 "$runner" 2>&1) || pinned_status=$?
assert_eq "$pinned_status" 1
printf '%s\n' "$pinned_output" | grep -F 'falling back' >/dev/null &&
  fail 'a pinned agent was rotated away'
printf '%s\n' "$pinned_output" | grep -F 'done (status 1)' >/dev/null ||
  fail 'pinned quota failure did not surface its status'

# Too little of the tick left to restart: report and roll forward, never half-run.
short_status=0
short_output=$(HOME="$runner_home" CLAUDE_CODE_OAUTH_TOKEN=test \
  GOOD_FELLOW_DRY_RUN=1 GOOD_FELLOW_MAX_RUNTIME=200 GOOD_FELLOW_MIN_REVIEW_SECONDS=190 \
  "$runner" 2>&1) || short_status=$?
assert_eq "$short_status" 1
printf '%s\n' "$short_output" | grep -F 'too little to restart' >/dev/null ||
  fail 'late quota did not report the exhausted tick budget'
printf '%s\n' "$short_output" | grep -F 'falling back' >/dev/null &&
  fail 'late quota started a fallback it could not finish'

# Any other agent error stays put: only a quota is safe and useful to retry elsewhere.
cat > "$runner_home/.local/bin/claude" <<'CLAUDE_ERROR_STUB'
#!/usr/bin/env bash
printf 'unexpected internal error\n' >&2
exit 1
CLAUDE_ERROR_STUB
chmod +x "$runner_home/.local/bin/claude"
error_status=0
error_output=$(HOME="$runner_home" CLAUDE_CODE_OAUTH_TOKEN=test \
  GOOD_FELLOW_DRY_RUN=1 "$runner" 2>&1) || error_status=$?
assert_eq "$error_status" 1
printf '%s\n' "$error_output" | grep -F 'falling back' >/dev/null &&
  fail 'a non-quota failure triggered an agent rotation'

# Run the exact deployment-retention block from onboard against controlled names.
for suffix in 1 2 3 4 5; do
  mkdir -p "$runner_home/.good-fellow/deploy-$suffix"
done
retention="$TEMP_ROOT/retention.sh"
awk '/^KEEP_DEPLOYMENTS=3$/ {emit=1}
     emit && /^```$/ {exit}
     emit {print}' "$ROOT/skills/onboard/SKILL.md" > "$retention"
HOME="$runner_home" bash "$retention"
deploy_count=0
for retained in "$runner_home/.good-fellow"/deploy-*; do
  [ -d "$retained" ] && [ ! -L "$retained" ] || continue
  deploy_count=$((deploy_count + 1))
done
assert_eq "$deploy_count" 3
[ -d "$runner_home/.good-fellow/deploy-3" ] || fail 'retention removed a newest deployment'
[ -d "$runner_home/.good-fellow/deploy-4" ] || fail 'retention removed a newest deployment'
[ -d "$runner_home/.good-fellow/deploy-5" ] || fail 'retention removed a newest deployment'

# Periodic maintenance runs outside model context, updates a remote-only gist change,
# preserves a true two-sided conflict, stays offline before its deadline, and
# fast-forwards a clean source checkout.
MAINTENANCE="$ROOT/skills/onboard/scripts/maintenance-check.sh"
maintenance_state="$TEMP_ROOT/maintenance-state"
maintenance_bin="$TEMP_ROOT/maintenance-bin"
maintenance_gist="$TEMP_ROOT/maintenance-gist.md"
maintenance_calls="$TEMP_ROOT/maintenance-gh-calls"
mkdir -p "$maintenance_state" "$maintenance_bin"
printf 'old preference\n' > "$maintenance_state/instruction.md"
printf 'old preference\n' > "$maintenance_state/instruction.remote"
printf 'remote preference\n' > "$maintenance_gist"
: > "$maintenance_calls"
cat > "$maintenance_bin/gh" <<'GH_MAINTENANCE_STUB'
#!/usr/bin/env bash
set -Eu
printf '%s\n' "$*" >> "$STUB_MAINTENANCE_CALLS"
if [ "${1:-}" = api ]; then
  printf 'gist-id\n'
elif [ "${1:-}" = gist ] && [ "${2:-}" = view ]; then
  cp "$STUB_MAINTENANCE_GIST" /dev/stdout
else
  exit 64
fi
GH_MAINTENANCE_STUB
chmod +x "$maintenance_bin/gh"

maintenance_output=$(PATH="$maintenance_bin:$PATH" \
  STUB_MAINTENANCE_CALLS="$maintenance_calls" \
  STUB_MAINTENANCE_GIST="$maintenance_gist" \
  GOOD_FELLOW_STATE_DIR="$maintenance_state" \
  GOOD_FELLOW_SYNC_INTERVAL_SECONDS=1 "$MAINTENANCE" "$TEMP_ROOT/no-source")
printf '%s\n' "$maintenance_output" | grep -F 'instruction cache updated from gist' >/dev/null ||
  fail 'maintenance did not update a remote-only gist change'
assert_eq "$(cat "$maintenance_state/instruction.md")" 'remote preference'
assert_eq "$(cat "$maintenance_state/instruction.remote")" 'remote preference'

printf 'local preference\n' > "$maintenance_state/instruction.md"
printf 'new remote preference\n' > "$maintenance_gist"
printf '0\n' > "$maintenance_state/maintenance-last-check"
maintenance_output=$(PATH="$maintenance_bin:$PATH" \
  STUB_MAINTENANCE_CALLS="$maintenance_calls" \
  STUB_MAINTENANCE_GIST="$maintenance_gist" \
  GOOD_FELLOW_STATE_DIR="$maintenance_state" \
  GOOD_FELLOW_SYNC_INTERVAL_SECONDS=1 "$MAINTENANCE" "$TEMP_ROOT/no-source")
printf '%s\n' "$maintenance_output" | grep -F 'both changed; preserving local copy' >/dev/null ||
  fail 'maintenance overwrote or missed a two-sided instruction conflict'
assert_eq "$(cat "$maintenance_state/instruction.md")" 'local preference'

calls_before=$(wc -l < "$maintenance_calls" | tr -d ' ')
PATH="$maintenance_bin:$PATH" \
  STUB_MAINTENANCE_CALLS="$maintenance_calls" \
  STUB_MAINTENANCE_GIST="$maintenance_gist" \
  GOOD_FELLOW_STATE_DIR="$maintenance_state" \
  GOOD_FELLOW_SYNC_INTERVAL_SECONDS=999999 "$MAINTENANCE" "$TEMP_ROOT/no-source" \
  > "$TEMP_ROOT/maintenance-not-due.out"
grep -F 'not due' "$TEMP_ROOT/maintenance-not-due.out" >/dev/null ||
  fail 'maintenance did not honor its offline interval'
assert_eq "$(wc -l < "$maintenance_calls" | tr -d ' ')" "$calls_before"

source_remote="$TEMP_ROOT/source-remote.git"
source_seed="$TEMP_ROOT/source-seed"
source_checkout="$TEMP_ROOT/source-checkout"
git init --bare -q "$source_remote"
git clone -q "$source_remote" "$source_seed"
git -C "$source_seed" -c user.name=test -c user.email=test@example.com \
  commit --allow-empty -m first >/dev/null
git -C "$source_seed" push -q -u origin HEAD:main
git -C "$source_remote" symbolic-ref HEAD refs/heads/main
git clone -q "$source_remote" "$source_checkout"
original_source_head=$(git -C "$source_checkout" rev-parse HEAD)
git -C "$source_seed" -c user.name=test -c user.email=test@example.com \
  commit --allow-empty -m second >/dev/null
git -C "$source_seed" push -q origin HEAD:main
expected_source_head=$(git -C "$source_seed" rev-parse HEAD)
printf '0\n' > "$maintenance_state/maintenance-last-check"
printf 'new remote preference\n' > "$maintenance_state/instruction.md"
printf 'new remote preference\n' > "$maintenance_state/instruction.remote"
maintenance_deploy="$maintenance_state/deploy-test"
mkdir -p "$maintenance_deploy"
printf '%s\n' "$original_source_head" > "$maintenance_deploy/runtime-version"
printf '%s\n' "$maintenance_deploy" > "$maintenance_state/deployment-current"
PATH="$maintenance_bin:$PATH" \
  STUB_MAINTENANCE_CALLS="$maintenance_calls" \
  STUB_MAINTENANCE_GIST="$maintenance_gist" \
  GOOD_FELLOW_STATE_DIR="$maintenance_state" \
  GOOD_FELLOW_SYNC_INTERVAL_SECONDS=1 "$MAINTENANCE" "$source_checkout" \
  > "$TEMP_ROOT/maintenance-source.out"
assert_eq "$(git -C "$source_checkout" rev-parse HEAD)" "$original_source_head"
assert_eq "$(git -C "$maintenance_state/source" rev-parse HEAD)" "$expected_source_head"
assert_eq "$(cat "$maintenance_state/maintenance-source-updated")" "$expected_source_head"
grep -F "source_updated=$expected_source_head" "$TEMP_ROOT/maintenance-source.out" >/dev/null ||
  fail 'maintenance did not report the source fast-forward'

printf 'runtime state tests passed\n'
