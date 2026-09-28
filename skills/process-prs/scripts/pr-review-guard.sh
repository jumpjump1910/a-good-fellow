#!/usr/bin/env bash
# Snapshot a pull request's review-visible state and fail closed if it changes
# before a good-fellow comment or approval is submitted.
set -Eeuo pipefail

export GH_PROMPT_DISABLED=1
export NO_COLOR=1

GUARD_SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
GUARD_LIB="$GUARD_SCRIPT_DIR/lib.sh"
[ -f "$GUARD_LIB" ] && [ ! -L "$GUARD_LIB" ] || { printf 'pr-review-guard: lib.sh is missing or unsafe\n' >&2; exit 64; }
LIB_TOOL='pr-review-guard'
. "$GUARD_LIB"

VERIFY_TEMP=''
SUBMIT_SNAPSHOT_TEMP=''
SUBMIT_BODY_TEMP=''
SNAPSHOT_CORE_TEMP=''
SNAPSHOT_ERR_TEMP=''
BODY_VERDICT=''

cleanup() {
  [ -z "$VERIFY_TEMP" ] || rm -f "$VERIFY_TEMP"
  [ -z "$SUBMIT_SNAPSHOT_TEMP" ] || rm -f "$SUBMIT_SNAPSHOT_TEMP"
  [ -z "$SUBMIT_BODY_TEMP" ] || rm -f "$SUBMIT_BODY_TEMP"
  [ -z "$SNAPSHOT_CORE_TEMP" ] || rm -f "$SNAPSHOT_CORE_TEMP"
  [ -z "$SNAPSHOT_ERR_TEMP" ] || rm -f "$SNAPSHOT_ERR_TEMP"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

usage() {
  cat >&2 <<'EOF'
usage:
  pr-review-guard.sh snapshot OWNER REPO NUMBER
  pr-review-guard.sh head SNAPSHOT_FILE
  pr-review-guard.sh base SNAPSHOT_FILE
  pr-review-guard.sh token SNAPSHOT_FILE
  pr-review-guard.sh legacy-token SNAPSHOT_FILE
  pr-review-guard.sh ledger SNAPSHOT_FILE
  pr-review-guard.sh ci-clean SNAPSHOT_FILE
  pr-review-guard.sh threads-clean SNAPSHOT_FILE
  pr-review-guard.sh verify-external OWNER REPO NUMBER SNAPSHOT_FILE
  pr-review-guard.sh submit-comment OWNER REPO NUMBER SNAPSHOT_FILE BODY_FILE
  pr-review-guard.sh submit-approve OWNER REPO NUMBER SNAPSHOT_FILE BODY_FILE
EOF
  exit 64
}

enforce_stop_epoch() {
  local stop now_epoch
  stop=${GOOD_FELLOW_RUN_STOP_AT_EPOCH:-}
  [ -n "$stop" ] || return 0
  case "$stop" in 0|0[0-9]*|*[!0-9]*) die 'invalid GOOD_FELLOW_RUN_STOP_AT_EPOCH' ;; esac
  now_epoch=$(date +%s)
  if [ "$now_epoch" -ge "$stop" ]; then
    printf 'pr-review-guard: run is in cleanup/reporting reserve; submission deferred\n' >&2
    return 4
  fi
  return 0
}

validate_snapshot_file() {
  local lines
  validate_regular_file "$1" 'snapshot file'
  lines=$(wc -l < "$1" | tr -d ' ')
  [ "$lines" -eq 13 ] || die "snapshot must contain exactly 13 lines, found $lines"
}

QUERY='query($o:String!,$r:String!,$n:Int!){
  viewer{login}
  repository(owner:$o,name:$r){
    nameWithOwner
    pullRequest(number:$n){
      id number state isDraft title body createdAt updatedAt lastEditedAt author{login}
      baseRefName baseRefOid headRefName headRefOid mergeable mergeStateStatus reviewDecision
      assignees(first:100){totalCount pageInfo{hasNextPage} nodes{login}}
      commits(last:1){nodes{commit{
        oid committedDate
        statusCheckRollup{
          state
          contexts(first:100){
            totalCount pageInfo{hasNextPage}
            nodes{
              __typename
              ... on CheckRun{name status conclusion detailsUrl databaseId
                checkSuite{databaseId workflowRun{databaseId event runAttempt updatedAt workflow{name}}}}
              ... on StatusContext{context state targetUrl}
            }
          }
        }
      }}}
      potentialMergeCommit{
        oid committedDate parents(first:2){totalCount pageInfo{hasNextPage} nodes{oid}}
        statusCheckRollup{
          state
          contexts(first:100){
            totalCount pageInfo{hasNextPage}
            nodes{
              __typename
              ... on CheckRun{name status conclusion detailsUrl databaseId
                checkSuite{databaseId workflowRun{databaseId event runAttempt updatedAt workflow{name}}}}
              ... on StatusContext{context state targetUrl}
            }
          }
        }
      }
      reviewRequests(first:100){
        totalCount pageInfo{hasNextPage}
        nodes{requestedReviewer{
          __typename
          ... on User{login}
          ... on Team{slug organization{login}}
        }}
      }
      reviews(first:100){
        totalCount pageInfo{hasNextPage}
        nodes{id author{login} state submittedAt updatedAt lastEditedAt isMinimized body commit{oid}}
      }
      comments(first:100){
        totalCount pageInfo{hasNextPage}
        nodes{id author{login} createdAt updatedAt lastEditedAt isMinimized body
          reactionGroups{content viewerHasReacted}}
      }
      reviewThreads(first:100){
        totalCount pageInfo{hasNextPage}
        nodes{
          id isResolved isOutdated path line originalLine startLine originalStartLine resolvedBy{login}
          comments(first:100){
            totalCount pageInfo{hasNextPage}
            nodes{id author{login} createdAt updatedAt lastEditedAt isMinimized body commit{oid} originalCommit{oid}
              reactionGroups{content viewerHasReacted}}
          }
        }
      }
      dismissalEvents: timelineItems(itemTypes:[REVIEW_DISMISSED_EVENT],first:100){
        pageInfo{hasNextPage}
        nodes{... on ReviewDismissedEvent{
          id createdAt dismissalMessage previousReviewState actor{login}
          review{id author{login} state body commit{oid}}
        }}
      }
      requestEvents: timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT,REVIEW_REQUEST_REMOVED_EVENT],first:100){
        pageInfo{hasNextPage}
        nodes{
          __typename
          ... on ReviewRequestedEvent{id createdAt requestedReviewer{... on User{login}}}
          ... on ReviewRequestRemovedEvent{id createdAt requestedReviewer{... on User{login}}}
        }
      }
    }
  }
}'

# gh embeds gojq, so this adds no external jq dependency. The first five lines
# are fixed metadata, lines six through eight are machine approval predicates, line
# nine is the stable external-state token (a sha-256 digest), line ten is the
# complete review ledger, line eleven is the pre-stable-token digest accepted
# only for migration, and line twelve is the external item index: one
# `kind|id|author|created|updated` entry per stable conversation item, so a token
# mismatch can name exactly which comment/review/thread changed instead of leaving
# the caller to guess that only HEAD moved. Line thirteen lists the node IDs of
# every issue/thread comment the viewer has not marked seen (👀), excluding the
# viewer's own marker posts and minimized comments, or `-` when none remain; a
# clean outcome refuses while any remain, because approving past a comment that
# was never judged is exactly how a user's own open concern got overridden. The
# token inputs deliberately strip the viewer's own
# good-fellow:v1 marker reviews/comments so posting a marker does not invalidate
# its own token; snapshot_state hashes those filtered captures before writing the
# file, so only the digests exist on lines nine/eleven and the sole readable PR
# JSON is the complete ledger on line ten (the `ledger` subcommand). The index
# covers the same filtered items as the token, so the viewer's own marker posts
# never appear as changes.
FILTER='
.data.viewer.login as $viewer |
.data.repository as $repo |
$repo.pullRequest as $pr |
if $pr == null then error("pull request not found")
elif $pr.state != "OPEN" then error("pull request is not open")
elif $pr.isDraft then error("pull request is a draft")
elif $pr.assignees.pageInfo.hasNextPage then error("assignees exceed 100")
elif $pr.reviewRequests.pageInfo.hasNextPage then error("review requests exceed 100")
elif $pr.reviews.pageInfo.hasNextPage then error("reviews exceed 100")
elif $pr.comments.pageInfo.hasNextPage then error("issue comments exceed 100")
elif $pr.reviewThreads.pageInfo.hasNextPage then error("review threads exceed 100")
elif ([ $pr.reviewThreads.nodes[] | select(.comments.pageInfo.hasNextPage) ] | length) > 0 then error("a review thread exceeds 100 comments")
elif $pr.dismissalEvents.pageInfo.hasNextPage then error("review dismissal events exceed 100")
elif $pr.requestEvents.pageInfo.hasNextPage then error("review request events exceed 100")
elif (($pr.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.hasNextPage // false)) then error("check contexts exceed 100")
elif (($pr.potentialMergeCommit.statusCheckRollup.contexts.pageInfo.hasNextPage // false)) then error("merge-commit check contexts exceed 100")
elif (($pr.potentialMergeCommit.parents.pageInfo.hasNextPage // false)) then error("test-merge commit has more than two parents")
elif $pr.commits.nodes[0].commit.oid != $pr.headRefOid then error("head commit changed while snapshotting")
else
  ({
    schema:2,
    viewer:$viewer,
    repository:$repo.nameWithOwner,
    pullRequest:{
      id:$pr.id,
      number:$pr.number,
      state:$pr.state,
      isDraft:$pr.isDraft,
      title:$pr.title,
      body:$pr.body,
      createdAt:$pr.createdAt,
      updatedAt:$pr.updatedAt,
      lastEditedAt:$pr.lastEditedAt,
      author:($pr.author.login // null),
      baseRefName:$pr.baseRefName,
      baseRefOid:$pr.baseRefOid,
      headRefName:$pr.headRefName,
      headRefOid:$pr.headRefOid,
      mergeable:$pr.mergeable,
      mergeStateStatus:$pr.mergeStateStatus,
      reviewDecision:$pr.reviewDecision,
      assignees:([ $pr.assignees.nodes[].login ] | sort),
      commit:(
        $pr.commits.nodes[0].commit |
        {
          oid:.oid,
          committedDate:.committedDate,
          checks:(
            if .statusCheckRollup == null then null
            else {
              state:.statusCheckRollup.state,
              contexts:([
                .statusCheckRollup.contexts.nodes[] |
                if .__typename == "CheckRun" then
                  {type:.__typename,name:.name,status:.status,conclusion:.conclusion,url:.detailsUrl,databaseId:.databaseId,checkSuiteId:(.checkSuite.databaseId // null),workflowRunId:(.checkSuite.workflowRun.databaseId // null),workflowEvent:(.checkSuite.workflowRun.event // null),workflowRunAttempt:(.checkSuite.workflowRun.runAttempt // null),workflowRunUpdatedAt:(.checkSuite.workflowRun.updatedAt // null),workflow:(.checkSuite.workflowRun.workflow.name // null)}
                else
                  {type:.__typename,name:.context,status:.state,conclusion:null,url:.targetUrl}
                end
              ] | sort_by(.type,.name,.url))
            }
            end
          )
        }
      ),
      potentialMergeCommit:(
        if $pr.potentialMergeCommit == null then null
        else ($pr.potentialMergeCommit | {
          oid:.oid,
          committedDate:.committedDate,
          parents:([.parents.nodes[].oid] | sort),
          checks:(
            if .statusCheckRollup == null then null
            else {
              state:.statusCheckRollup.state,
              contexts:([
                .statusCheckRollup.contexts.nodes[] |
                if .__typename == "CheckRun" then
                  {type:.__typename,name:.name,status:.status,conclusion:.conclusion,url:.detailsUrl,databaseId:.databaseId,checkSuiteId:(.checkSuite.databaseId // null),workflowRunId:(.checkSuite.workflowRun.databaseId // null),workflowEvent:(.checkSuite.workflowRun.event // null),workflowRunAttempt:(.checkSuite.workflowRun.runAttempt // null),workflowRunUpdatedAt:(.checkSuite.workflowRun.updatedAt // null),workflow:(.checkSuite.workflowRun.workflow.name // null)}
                else
                  {type:.__typename,name:.context,status:.state,conclusion:null,url:.targetUrl}
                end
              ] | sort_by(.type,.name,.url))
            }
            end
          )
        })
        end
      ),
      reviewRequests:([
        $pr.reviewRequests.nodes[].requestedReviewer |
        {type:.__typename,login:(.login // null),slug:(.slug // null),organization:(.organization.login // null)}
      ] | sort_by(.type,.login,.slug,.organization)),
      reviews:([
        $pr.reviews.nodes[] |
        {id,author:(.author.login // null),state,submittedAt,updatedAt,lastEditedAt,isMinimized,body,commit:(.commit.oid // null)}
      ] | sort_by(.id)),
      comments:([
        $pr.comments.nodes[] |
        {id,author:(.author.login // null),createdAt,updatedAt,lastEditedAt,isMinimized,body,
         seen:(([.reactionGroups[] | select(.content == "EYES" and .viewerHasReacted)] | length) > 0)}
      ] | sort_by(.id)),
      reviewThreads:([
        $pr.reviewThreads.nodes[] |
        {
          id,isResolved,isOutdated,path,line,originalLine,startLine,originalStartLine,
          resolvedBy:(.resolvedBy.login // null),
          comments:([
            .comments.nodes[] |
            {id,author:(.author.login // null),createdAt,updatedAt,lastEditedAt,isMinimized,body,commit:(.commit.oid // null),originalCommit:(.originalCommit.oid // null),
             seen:(([.reactionGroups[] | select(.content == "EYES" and .viewerHasReacted)] | length) > 0)}
          ] | sort_by(.id))
        }
      ] | sort_by(.id)),
      reviewDismissals:([
        $pr.dismissalEvents.nodes[] |
        {id,createdAt,dismissalMessage,previousReviewState,actor:(.actor.login // null),review:{id:.review.id,author:(.review.author.login // null),state:.review.state,body:.review.body,commit:(.review.commit.oid // null)}}
      ] | sort_by(.id))
    }
  }) as $full |
  (
    $full
    | .pullRequest.updatedAt = null
    | .pullRequest.reviewDecision = null
    | .pullRequest.mergeStateStatus = null
    | .pullRequest.commit.checks = null
    | .pullRequest.potentialMergeCommit.checks = null
    | .pullRequest.reviewRequests = []
    | .pullRequest.reviews |= map(select((.author != $viewer) or (((.body // "") | contains("good-fellow:v1")) | not)))
    | .pullRequest.comments |= map(select((.author != $viewer) or (((.body // "") | contains("good-fellow:v1")) | not)))
    | .pullRequest.reviewThreads |= map(.comments |= map(select((.author != $viewer) or (((.body // "") | contains("good-fellow:v1")) | not))))
    | .pullRequest.comments |= map(.seen = false)
    | .pullRequest.reviewThreads |= map(.comments |= map(.seen = false))
  ) as $legacy_external |
  (
    $legacy_external
    | .pullRequest.mergeable = null
    | .pullRequest.potentialMergeCommit = null
  ) as $external |
  ([
    $pr.headRefOid,
    $pr.baseRefOid,
    $viewer,
    (
      # A direct request stands if it is live, or if GitHub silently consumed it
      # when the viewer submitted a marker-bearing review (no removal event is
      # emitted then). An explicit un-request leaves ReviewRequestRemovedEvent
      # and clears the request for good.
      (([ $pr.reviewRequests.nodes[].requestedReviewer | select(.__typename == "User" and .login == $viewer) ] | length) > 0)
      or
      (
        ([ $pr.requestEvents.nodes[] | select(.__typename == "ReviewRequestedEvent" and (.requestedReviewer.login // "") == $viewer) | .createdAt ] | max // "") as $lastRequested |
        ([ $pr.requestEvents.nodes[] | select(.__typename == "ReviewRequestRemovedEvent" and (.requestedReviewer.login // "") == $viewer) | .createdAt ] | max // "") as $lastRemoved |
        ($lastRequested != "") and ($lastRequested > $lastRemoved) and
        (([ $pr.reviews.nodes[] | select(
          (.author.login // "") == $viewer and
          ((.body // "") | contains("good-fellow:v1")) and
          .submittedAt >= $lastRequested
        ) ] | length) > 0)
      )
    ),
    ($pr.author.login // ""),
    (
      $pr.mergeable == "MERGEABLE" and
      $pr.potentialMergeCommit != null and
      $pr.potentialMergeCommit.parents.totalCount == 2 and
      # baseRefOid lags the live base ref between PR syncs, while GitHub builds
      # the test merge against the current base tip — requiring the exact pair
      # {baseRefOid, headRefOid} fails closed forever on any PR whose base
      # advanced. The merge commit comes from this PR object, so requiring the
      # PR head as one of its two parents is the binding that matters.
      (([ $pr.potentialMergeCommit.parents.nodes[].oid ] | map(select(. == $pr.headRefOid)) | length) == 1) and
      (
        (
          $pr.commits.nodes[0].commit.statusCheckRollup == null and
          $pr.potentialMergeCommit.statusCheckRollup == null
        ) or
        (
          (($pr.commits.nodes[0].commit.statusCheckRollup == null) or ($pr.commits.nodes[0].commit.statusCheckRollup.state == "SUCCESS")) and
          $pr.potentialMergeCommit.statusCheckRollup != null and
          $pr.potentialMergeCommit.statusCheckRollup.state == "SUCCESS"
        )
      )
    ),
    (([ $pr.reviewThreads.nodes[] | select(.isResolved == false) ] | length) == 0),
    (
      ([ $pr.dismissalEvents.nodes[] | select(
        (.review.author.login // "") == $viewer and
        (.review.commit.oid // "") == $pr.headRefOid and
        .previousReviewState == "APPROVED" and
        ((.review.body // "") | contains("good-fellow:v1")) and
        ((.review.body // "") | contains("action=approve"))
      ) | .createdAt ] | max // "") as $lastDismissal |
      ([ $pr.reviews.nodes[] | select((.author.login // "") == $viewer and .state == "APPROVED" and (.commit.oid // "") == $pr.headRefOid) | .submittedAt ] | max // "") as $lastApproval |
      ($lastDismissal == "" or $lastApproval > $lastDismissal)
    ),
    $external,
    $full,
    $legacy_external,
    (
      $pr.mergeable == "MERGEABLE" and
      $pr.potentialMergeCommit != null and
      $pr.potentialMergeCommit.parents.totalCount == 2 and
      # baseRefOid lags the live base ref between PR syncs, while GitHub builds
      # the test merge against the current base tip — requiring the exact pair
      # {baseRefOid, headRefOid} fails closed forever on any PR whose base
      # advanced. The merge commit comes from this PR object, so requiring the
      # PR head as one of its two parents is the binding that matters.
      (([ $pr.potentialMergeCommit.parents.nodes[].oid ] | map(select(. == $pr.headRefOid)) | length) == 1) and
      $pr.potentialMergeCommit.statusCheckRollup == null and
      $pr.commits.nodes[0].commit.statusCheckRollup != null and
      $pr.commits.nodes[0].commit.statusCheckRollup.state == "SUCCESS"
    ),
    (
      [
        $pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? |
        select(.__typename == "CheckRun") |
        select((.checkSuite.databaseId // 0) > 0 and (.checkSuite.workflowRun.databaseId // 0) > 0) |
        "\(.checkSuite.databaseId):\(.checkSuite.workflowRun.databaseId)"
      ] | unique | sort |
      if length == 0 then "-" else join(",") end
    ),
    (
      $external.pullRequest as $x |
      [
        "pr|\($x.id)|\($x.author // "-")|\($x.createdAt)|\($x.lastEditedAt // "-")",
        ($x.reviews[] | "review|\(.id)|\(.author // "-")|\(.submittedAt // "-")|\(.lastEditedAt // .updatedAt // "-")"),
        ($x.comments[] | "comment|\(.id)|\(.author // "-")|\(.createdAt)|\(.lastEditedAt // .updatedAt // "-")"),
        ($x.reviewThreads[] |
          "thread|\(.id)|\(.resolvedBy // "-")|resolved=\(.isResolved)|outdated=\(.isOutdated)",
          (.comments[] | "thread-comment|\(.id)|\(.author // "-")|\(.createdAt)|\(.lastEditedAt // .updatedAt // "-")")),
        ($x.reviewDismissals[] | "dismissal|\(.id)|\(.actor // "-")|\(.createdAt)|-")
      ] | map(gsub("\\s"; "_")) | sort | join(" ")
    ),
    (
      $full.pullRequest as $f |
      [
        ($f.comments[], $f.reviewThreads[].comments[]) |
        select(.seen | not) |
        select(.isMinimized | not) |
        select((.author != $viewer) or (((.body // "") | contains("good-fellow:v1")) | not)) |
        .id
      ] | sort | if length == 0 then "-" else join(",") end
    )
  ] | .[])
end'

snapshot_state() {
  local owner=$1 repo=$2 number=$3 lines head base strict_clean fallback_eligible pairs
  local rest pair suite_id run_id run_filter run_record got_run got_suite event run_status conclusion run_head association_count
  local qualifying_count=0 qualifying_clean=true ci_clean=false

  [ -z "$SNAPSHOT_CORE_TEMP" ] || rm -f "$SNAPSHOT_CORE_TEMP"
  umask 077
  SNAPSHOT_CORE_TEMP=$(mktemp "${TMPDIR:-/tmp}/good-fellow-pr-core.XXXXXX")
  SNAPSHOT_ERR_TEMP=$(mktemp "${TMPDIR:-/tmp}/good-fellow-pr-core-err.XXXXXX")
  if gh api graphql -f query="$QUERY" -f o="$owner" -f r="$repo" -F n="$number" --jq "$FILTER" > "$SNAPSHOT_CORE_TEMP" 2> "$SNAPSHOT_ERR_TEMP"; then
    cat "$SNAPSHOT_ERR_TEMP" >&2
  else
    cat "$SNAPSHOT_ERR_TEMP" >&2
    # Overflowing a bounded connection is a durable property of the PR, not a
    # transient failure: report it distinctly (exit 7) so the queue can advance
    # past the PR instead of retrying it forever and starving the tail.
    if grep -q 'exceed 100' "$SNAPSHOT_ERR_TEMP"; then
      printf 'pr-review-guard: pull request exceeds bounded snapshot capacity\n' >&2
      return 7
    fi
    printf 'pr-review-guard: unable to capture pull request state\n' >&2
    return 75
  fi

  lines=$(wc -l < "$SNAPSHOT_CORE_TEMP" | tr -d ' ')
  [ "$lines" -eq 15 ] || die "internal snapshot must contain exactly 15 lines, found $lines"
  head=$(sed -n '1p' "$SNAPSHOT_CORE_TEMP")
  base=$(sed -n '2p' "$SNAPSHOT_CORE_TEMP")
  strict_clean=$(sed -n '6p' "$SNAPSHOT_CORE_TEMP")
  fallback_eligible=$(sed -n '12p' "$SNAPSHOT_CORE_TEMP")
  pairs=$(sed -n '13p' "$SNAPSHOT_CORE_TEMP")
  validate_oid "$head" 'snapshot head'
  validate_oid "$base" 'snapshot base'
  case "$strict_clean" in true|false) ;; *) die 'invalid strict CI predicate' ;; esac
  case "$fallback_eligible" in true|false) ;; *) die 'invalid HEAD CI fallback predicate' ;; esac

  ci_clean=$strict_clean
  # A pull_request Actions run can publish its checks on the PR HEAD even though
  # it executes in the merge-ref event context. Commit rollups alone cannot
  # distinguish that run from a stale push run on the same SHA, so the fallback
  # requires the workflow-run API to bind the check suite to this PR/head/base.
  if [ "$strict_clean" = false ] && [ "$fallback_eligible" = true ] && [ "$pairs" != - ]; then
    rest=$pairs
    while [ -n "$rest" ]; do
      case "$rest" in
        *,*) pair=${rest%%,*}; rest=${rest#*,} ;;
        *) pair=$rest; rest='' ;;
      esac
      suite_id=${pair%%:*}
      run_id=${pair#*:}
      case "$suite_id" in ''|*[!0-9]*) die 'invalid check suite database ID' ;; esac
      case "$run_id" in ''|*[!0-9]*) die 'invalid workflow run database ID' ;; esac
      [ "$pair" = "$suite_id:$run_id" ] || die 'invalid check suite/workflow run pair'

      run_filter='[
        (.id | tostring),
        (.check_suite_id | tostring),
        (.event // "-"),
        (.status // "-"),
        (.conclusion // "-"),
        (.head_sha // "-"),
        ([ (.pull_requests // [])[] | select(
          .number == '"$number"' and
          .head.sha == "'"$head"'" and
          .base.sha == "'"$base"'"
        ) ] | length | tostring)
      ] | @tsv'
      if run_record=$(gh api "repos/$owner/$repo/actions/runs/$run_id" --jq "$run_filter"); then
        :
      else
        printf 'pr-review-guard: unable to verify workflow run %s\n' "$run_id" >&2
        return 75
      fi
      IFS=$'\t' read -r got_run got_suite event run_status conclusion run_head association_count <<< "$run_record"
      case "$got_run" in ''|*[!0-9]*) die 'invalid workflow run response ID' ;; esac
      case "$got_suite" in ''|*[!0-9]*) die 'invalid workflow run check suite ID' ;; esac
      case "$association_count" in ''|*[!0-9]*) die 'invalid workflow run pull request association count' ;; esac
      [ "$got_run" = "$run_id" ] || die 'workflow run response ID mismatch'
      [ "$got_suite" = "$suite_id" ] || die 'workflow run check suite mismatch'

      if [ "$event" = pull_request ] && [ "$run_head" = "$head" ] && [ "$association_count" -gt 0 ]; then
        qualifying_count=$((qualifying_count + 1))
        if [ "$run_status" != completed ] || [ "$conclusion" != success ]; then
          qualifying_clean=false
        fi
      fi
    done
    if [ "$qualifying_count" -gt 0 ] && [ "$qualifying_clean" = true ]; then
      ci_clean=true
    fi
  fi

  # Emit the 13-line snapshot. The filtered token inputs on internal lines 9/11
  # are reduced to their sha-256 digests here so the only readable PR JSON in
  # the file is the complete ledger on line 10 — a consumer can no longer grab
  # a filtered capture by mistake. Internal lines 12/13 feed only the CI
  # fallback above; internal lines 14/15 become the item index and unseen list
  # on lines 12/13.
  local out_line line_no=0
  while IFS= read -r out_line; do
    line_no=$((line_no + 1))
    case "$line_no" in
      6) printf '%s\n' "$ci_clean" ;;
      9|11) digest_string "$out_line" ;;
      12|13) ;;
      *) printf '%s\n' "$out_line" ;;
    esac
  done < "$SNAPSHOT_CORE_TEMP"
}

snapshot_line() {
  local snapshot=$1 wanted=$2 line='' current=0
  validate_snapshot_file "$snapshot"
  while IFS= read -r line; do
    current=$((current + 1))
    if [ "$current" -eq "$wanted" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$snapshot"
  die "snapshot is missing line $wanted"
}

snapshot_head() {
  local value
  value=$(snapshot_line "$1" 1)
  validate_oid "$value" 'snapshot head'
  printf '%s\n' "$value"
}

snapshot_base() {
  local value
  value=$(snapshot_line "$1" 2)
  validate_oid "$value" 'snapshot base'
  printf '%s\n' "$value"
}

digest_string() {
  local token
  if command -v sha256sum >/dev/null 2>&1; then
    token=$(printf '%s' "$1" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    token=$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')
  else
    die 'sha256sum or shasum is required'
  fi
  case "$token" in ''|*[!0-9a-f]*) die 'invalid state token' ;; esac
  [ "${#token}" -eq 64 ] || die 'invalid state token'
  printf '%s\n' "$token"
}

# Lines 9/11 hold digests written by snapshot_state; validate shape and echo.
snapshot_stored_token() {
  local value
  value=$(snapshot_line "$1" "$2")
  case "$value" in ''|*[!0-9a-f]*) die 'invalid state token' ;; esac
  [ "${#value}" -eq 64 ] || die 'invalid state token'
  printf '%s\n' "$value"
}

snapshot_token() {
  snapshot_stored_token "$1" 9
}

snapshot_legacy_token() {
  snapshot_stored_token "$1" 11
}

snapshot_ledger() {
  # The complete, unfiltered review ledger. This is the only capture safe for
  # idempotence and marker checks; lines 9/11 strip the viewer's own markers.
  snapshot_line "$1" 10
}

# Print, to stderr, every reason the stable state differs between two snapshots.
# A HEAD move and a new comment both change the token; naming each item keeps a
# caller from restarting only the code review and missing later conversation.
describe_external_change() {
  local old=$1 new=$2 old_head old_base new_head new_base old_index new_index listed
  old_head=$(snapshot_head "$old"); new_head=$(snapshot_head "$new")
  old_base=$(snapshot_base "$old"); new_base=$(snapshot_base "$new")
  [ "$old_head" = "$new_head" ] || printf 'pr-review-guard: changed: HEAD %s -> %s\n' "$old_head" "$new_head" >&2
  [ "$old_base" = "$new_base" ] || printf 'pr-review-guard: changed: base %s -> %s\n' "$old_base" "$new_base" >&2
  old_index=$(snapshot_line "$old" 12)
  new_index=$(snapshot_line "$new" 12)
  # The indexes go through stdin, not `-v`: a single exec argument is capped at
  # 128 KiB, and an E2BIG exit would replace this function's exit-3 contract.
  listed=$(printf '%s\n%s\n' "$old_index" "$new_index" | LC_ALL=C awk '
    NR == 1 { old = $0; next }
    NR == 2 { new = $0; next }
    END {
      n = split(old, o, " "); for (i = 1; i <= n; i++) { split(o[i], f, "|"); seen[o[i]] = 1; oid[f[2]] = 1 }
      m = split(new, w, " ")
      for (i = 1; i <= m; i++) {
        split(w[i], f, "|"); nid[f[2]] = 1
        if (w[i] in seen) continue
        printf "pr-review-guard: changed: %s %s %s by %s at %s\n", (f[2] in oid ? "edited" : "new"), f[1], f[2], f[3], f[4]
      }
      for (i = 1; i <= n; i++) {
        split(o[i], f, "|")
        if (!(f[2] in nid)) printf "pr-review-guard: changed: removed %s %s by %s\n", f[1], f[2], f[3]
      }
    }')
  if [ -n "$listed" ]; then
    printf '%s\n' "$listed" >&2
  elif [ "$(snapshot_token "$old")" != "$(snapshot_token "$new")" ]; then
    printf 'pr-review-guard: changed: other stable PR fields (title, assignees, or minimized items)\n' >&2
  fi
  printf 'pr-review-guard: restart this PR from the fresh snapshot and judge every changed item above\n' >&2
}

# CI and synthetic merge state are live gates. Callers that need a clean
# outcome read the freshly captured predicates after this stable-state check.
verify_external_state() {
  local owner=$1 repo=$2 number=$3 baseline=$4 status
  local old_head old_base old_token new_head new_base new_token
  old_head=$(snapshot_head "$baseline")
  old_base=$(snapshot_base "$baseline")
  old_token=$(snapshot_token "$baseline")
  umask 077
  VERIFY_TEMP=$(mktemp "${TMPDIR:-/tmp}/good-fellow-pr-state.XXXXXX")
  if snapshot_state "$owner" "$repo" "$number" > "$VERIFY_TEMP"; then
    :
  else
    status=$?
    printf 'pr-review-guard: unable to refresh pull request external state\n' >&2
    return "$status"
  fi
  new_head=$(snapshot_head "$VERIFY_TEMP")
  new_base=$(snapshot_base "$VERIFY_TEMP")
  new_token=$(snapshot_token "$VERIFY_TEMP")
  if [ "$old_head" = "$new_head" ] && [ "$old_base" = "$new_base" ] &&
     [ "$old_token" = "$new_token" ]; then
    printf 'fresh\n'
    return 0
  fi
  printf 'pr-review-guard: pull request external state changed during review\n' >&2
  describe_external_change "$baseline" "$VERIFY_TEMP"
  return 3
}

validate_body() {
  local snapshot=$1 body=$2 action=$3 head base token verdict marker count total=0 all_markers first_line last_line
  validate_regular_file "$body" 'review body file'
  head=$(snapshot_head "$snapshot")
  base=$(snapshot_base "$snapshot")
  token=$(snapshot_token "$snapshot")
  BODY_VERDICT=''
  for verdict in clean concern waiting; do
    marker="<!-- good-fellow:v1 reviewed=$head base=$base state=$token action=$action verdict=$verdict -->"
    count=$(grep -Fxc "$marker" "$body" || true)
    total=$((total + count))
    [ "$count" -eq 1 ] && BODY_VERDICT=$verdict
  done
  [ "$total" -eq 1 ] || die 'review body must contain exactly one guarded marker'
  all_markers=$(awk '{ text=$0; while ((pos=index(text,"good-fellow:v1")) > 0) { count++; text=substr(text,pos+14) } } END { print count+0 }' "$body")
  [ "$all_markers" -eq 1 ] || die 'review body must contain no other good-fellow marker text'
  marker="<!-- good-fellow:v1 reviewed=$head base=$base state=$token action=$action verdict=$BODY_VERDICT -->"
  first_line=$(awk 'NF { print; exit }' "$body")
  last_line=$(awk 'NF { line=$0 } END { print line }' "$body")
  [ "$last_line" = "$marker" ] || die 'guarded marker must be the final non-empty line'
  if [ "$BODY_VERDICT" = clean ]; then
    case "$first_line" in LGTM*) ;; *) die 'clean review body must begin with LGTM' ;; esac
  else
    case "$first_line" in LGTM*) die 'concern/waiting body must not begin with LGTM' ;; esac
  fi
}

copy_submit_inputs() {
  validate_regular_file "$1" 'snapshot file'
  validate_regular_file "$2" 'review body file'
  umask 077
  SUBMIT_SNAPSHOT_TEMP=$(mktemp "${TMPDIR:-/tmp}/good-fellow-submit-state.XXXXXX")
  SUBMIT_BODY_TEMP=$(mktemp "${TMPDIR:-/tmp}/good-fellow-submit-body.XXXXXX")
  cp "$1" "$SUBMIT_SNAPSHOT_TEMP"
  cp "$2" "$SUBMIT_BODY_TEMP"
  cmp -s "$1" "$SUBMIT_SNAPSHOT_TEMP" || die 'snapshot changed while being copied'
  cmp -s "$2" "$SUBMIT_BODY_TEMP" || die 'review body changed while being copied'
  chmod 600 "$SUBMIT_SNAPSHOT_TEMP" "$SUBMIT_BODY_TEMP"
}

mode=${1:-}
case "$mode" in
  snapshot)
    [ "$#" -eq 4 ] || usage
    validate_target "$2" "$3" "$4"
    snapshot_state "$2" "$3" "$4"
    ;;
  head)
    [ "$#" -eq 2 ] || usage
    snapshot_head "$2"
    ;;
  base)
    [ "$#" -eq 2 ] || usage
    snapshot_base "$2"
    ;;
  token)
    [ "$#" -eq 2 ] || usage
    snapshot_token "$2"
    ;;
  legacy-token)
    [ "$#" -eq 2 ] || usage
    snapshot_legacy_token "$2"
    ;;
  ledger)
    [ "$#" -eq 2 ] || usage
    snapshot_ledger "$2"
    ;;
  ci-clean)
    [ "$#" -eq 2 ] || usage
    snapshot_line "$2" 6
    ;;
  threads-clean)
    [ "$#" -eq 2 ] || usage
    snapshot_line "$2" 7
    ;;
  verify-external)
    [ "$#" -eq 5 ] || usage
    validate_target "$2" "$3" "$4"
    verify_external_state "$2" "$3" "$4" "$5"
    ;;
  submit-comment|submit-approve)
    [ "$#" -eq 6 ] || usage
    validate_target "$2" "$3" "$4"
    if enforce_stop_epoch; then :; else status=$?; exit "$status"; fi
    copy_submit_inputs "$5" "$6"
    if [ "$mode" = submit-approve ]; then action=approve; else action=comment; fi
    validate_body "$SUBMIT_SNAPSHOT_TEMP" "$SUBMIT_BODY_TEMP" "$action"
    # Review coverage is bound to HEAD/base/external conversation state. CI and
    # GitHub's synthetic merge commit are deliberately live gates, not durable
    # review identity: they may change while a waiting comment is being posted.
    if verify_external_state "$2" "$3" "$4" "$SUBMIT_SNAPSHOT_TEMP" >/dev/null; then
      :
    else
      status=$?
      exit "$status"
    fi
    head=$(snapshot_head "$VERIFY_TEMP")
    if [ "$mode" = submit-approve ]; then
      viewer=$(snapshot_line "$VERIFY_TEMP" 3)
      requested=$(snapshot_line "$VERIFY_TEMP" 4)
      author=$(snapshot_line "$VERIFY_TEMP" 5)
      ci_clean=$(snapshot_line "$VERIFY_TEMP" 6)
      threads_clean=$(snapshot_line "$VERIFY_TEMP" 7)
      dismissal_clear=$(snapshot_line "$VERIFY_TEMP" 8)
      [ "$viewer" != "$author" ] || die 'cannot approve a pull request authored by the viewer'
      [ "$requested" = true ] || die 'viewer is not a directly requested reviewer'
      [ "$BODY_VERDICT" = clean ] || die 'approval requires verdict=clean'
      [ "$ci_clean" = true ] || die 'CI is not conclusively successful'
      [ "$threads_clean" = true ] || die 'one or more review threads are unresolved'
      [ "$dismissal_clear" = true ] || die 'a current-head approval was dismissed and not superseded'
    elif [ "$BODY_VERDICT" = clean ]; then
      requested=$(snapshot_line "$VERIFY_TEMP" 4)
      ci_clean=$(snapshot_line "$VERIFY_TEMP" 6)
      threads_clean=$(snapshot_line "$VERIFY_TEMP" 7)
      dismissal_clear=$(snapshot_line "$VERIFY_TEMP" 8)
      [ "$requested" = false ] || die 'directly requested clean review must use submit-approve'
      [ "$ci_clean" = true ] || die 'clean comment requires conclusively successful CI'
      [ "$threads_clean" = true ] || die 'clean comment requires all review threads resolved'
      [ "$dismissal_clear" = true ] || die 'clean comment cannot override a current-head dismissed approval'
    fi
    # Approval (always clean) and a clean comment both assert nothing is left open.
    if [ "$BODY_VERDICT" = clean ]; then
      unseen=$(snapshot_line "$VERIFY_TEMP" 13)
      [ "$unseen" = - ] || die "clean outcome requires every comment judged and marked seen; unseen: $unseen"
    fi
    if enforce_stop_epoch; then :; else status=$?; exit "$status"; fi
    # No GitHub or code reads are allowed between the successful verification
    # above and this mutation. Approvals are pinned to the reviewed commit.
    if [ "$mode" = submit-comment ]; then
      if gh api -X POST "repos/$2/$3/pulls/$4/reviews" \
        -f event=COMMENT -f commit_id="$head" -F "body=@$SUBMIT_BODY_TEMP" --silent; then
        printf 'commented on %s at %s\n' "$2/$3#$4" "$head"
        :
      else
        printf 'pr-review-guard: submission outcome is indeterminate; reconcile read-only and do not retry blindly\n' >&2
        exit 75
      fi
    else
      if gh api -X POST "repos/$2/$3/pulls/$4/reviews" \
        -f event=APPROVE -f commit_id="$head" -F "body=@$SUBMIT_BODY_TEMP" --silent; then
        printf 'approved %s at %s\n' "$2/$3#$4" "$head"
      else
        printf 'pr-review-guard: submission outcome is indeterminate; reconcile read-only and do not retry blindly\n' >&2
        exit 75
      fi
    fi
    ;;
  *) usage ;;
esac
