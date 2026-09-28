#!/usr/bin/env bash
# Persist a bounded review handoff against one exact PR snapshot.
set -Eeuo pipefail

export GH_PROMPT_DISABLED=1
export NO_COLOR=1

HANDOFF_LIB="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)/lib.sh"
[ -f "$HANDOFF_LIB" ] && [ ! -L "$HANDOFF_LIB" ] || { printf 'pr-handoff: lib.sh is missing or unsafe\n' >&2; exit 64; }
LIB_TOOL='pr-handoff'
. "$HANDOFF_LIB"

STATE_DIR="${GOOD_FELLOW_STATE_DIR:-$HOME/.good-fellow}"
MAX_PAYLOAD_BYTES=1048576
MAGIC='good-fellow-pr-handoff-v1'
TAB=$(printf '\t')
TEMP_FILE=''
PAYLOAD_COPY=''
QUEUE_RAW=''
QUEUE_ONE=''
QUEUE_TWO=''

cleanup() {
  [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
  [ -z "$PAYLOAD_COPY" ] || rm -f "$PAYLOAD_COPY"
  [ -z "$QUEUE_RAW" ] || rm -f "$QUEUE_RAW"
  [ -z "$QUEUE_ONE" ] || rm -f "$QUEUE_ONE"
  [ -z "$QUEUE_TWO" ] || rm -f "$QUEUE_TWO"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

usage() {
  printf '%s\n' \
    'usage: pr-handoff.sh save OWNER REPO NUMBER SNAPSHOT_FILE PHASE PAYLOAD_FILE' \
    '       pr-handoff.sh match OWNER REPO NUMBER SNAPSHOT_FILE' \
    '       pr-handoff.sh payload OWNER REPO NUMBER' \
    '       pr-handoff.sh clear OWNER REPO NUMBER' \
    '       pr-handoff.sh show' \
    '       pr-handoff.sh reviewing-key' \
    '       pr-handoff.sh queue-rows' \
    '       pr-handoff.sh prune' >&2
  exit 64
}

validate_token() {
  case "$1" in ''|*[!0-9a-f]*) die 'state token must be lowercase hexadecimal' ;; esac
  [ "${#1}" -eq 64 ] || die 'state token must be 64 characters'
}

validate_phase() {
  case "$1" in reviewing|reviewed) ;; *) die 'phase must be reviewing or reviewed' ;; esac
}

ensure_state_dir() {
  if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || die 'state directory must be a real directory'
  else
    umask 077
    mkdir -p "$STATE_DIR"
  fi
}

handoff_path() {
  printf '%s/process-prs-handoff-%s-%s-%s-%s-%s.state\n' \
    "$STATE_DIR" "${#1}" "$1" "${#2}" "$2" "$3"
}

snapshot_values() {
  local snapshot=$1
  # The snapshot is a caller-owned private temp file with no concurrent writer;
  # the guard re-validates the 13-line format and each field's shape per read.
  validate_regular_file "$snapshot" 'snapshot file'
  SNAPSHOT_HEAD=$("$GUARD" head "$snapshot")
  SNAPSHOT_BASE=$("$GUARD" base "$snapshot")
  SNAPSHOT_TOKEN=$("$GUARD" token "$snapshot")
  SNAPSHOT_LEGACY_TOKEN=$("$GUARD" legacy-token "$snapshot")
  validate_oid "$SNAPSHOT_HEAD" 'snapshot head'
  validate_oid "$SNAPSHOT_BASE" 'snapshot base'
  validate_token "$SNAPSHOT_TOKEN"
  validate_token "$SNAPSHOT_LEGACY_TOKEN"
}

verify_snapshot_target() {
  local status
  if "$GUARD" verify-external "$1" "$2" "$3" "$4" >/dev/null; then
    return 0
  else
    status=$?
  fi
  # Live external state drifted from the caller's snapshot. This says nothing
  # about the stored handoff, so it must not be conflated with the stale-handoff
  # exit 3: the caller recaptures a fresh snapshot and retries.
  [ "$status" -eq 3 ] && {
    printf 'pr-handoff: snapshot no longer matches live external state; recapture and retry\n' >&2
    return 5
  }
  printf 'pr-handoff: unable to verify snapshot target/freshness\n' >&2
  return 75
}

read_line() {
  # Stop before the arbitrary binary payload so BSD sed never decodes it.
  sed -n "$2"'p;'"$2"'q' "$1"
}

load_handoff() {
  local file=$1 actual_size
  validate_regular_file "$file" 'handoff file'
  STORED_MAGIC=$(read_line "$file" 1)
  STORED_OWNER=$(read_line "$file" 2)
  STORED_REPO=$(read_line "$file" 3)
  STORED_NUMBER=$(read_line "$file" 4)
  STORED_HEAD=$(read_line "$file" 5)
  STORED_BASE=$(read_line "$file" 6)
  STORED_TOKEN=$(read_line "$file" 7)
  STORED_PHASE=$(read_line "$file" 8)
  STORED_SIZE=$(read_line "$file" 9)
  [ "$STORED_MAGIC" = "$MAGIC" ] || die 'invalid handoff format'
  validate_target "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER"
  validate_oid "$STORED_HEAD" 'stored head'
  validate_oid "$STORED_BASE" 'stored base'
  validate_token "$STORED_TOKEN"
  validate_phase "$STORED_PHASE"
  case "$STORED_SIZE" in ''|*[!0-9]*) die 'invalid stored payload size' ;; esac
  [ "$STORED_SIZE" -le "$MAX_PAYLOAD_BYTES" ] || die 'stored payload exceeds 1 MiB'
  actual_size=$(tail -n +10 "$file" | wc -c | tr -d ' ')
  [ "$actual_size" = "$STORED_SIZE" ] || die 'stored payload size mismatch'
}

# Collection modes must remain usable when one state file is truncated or corrupt.
# Validate in a subshell first because load_handoff's targeted modes intentionally
# fail hard; a single bad collection entry is instead ignored with a visible warning.
load_handoff_for_scan() {
  local file=$1
  if ! (load_handoff "$file") >/dev/null 2>&1; then
    printf 'pr-handoff: ignoring invalid state file %s\n' "$file" >&2
    return 1
  fi
  load_handoff "$file"
}

require_key_match() {
  [ "$STORED_OWNER" = "$1" ] && [ "$STORED_REPO" = "$2" ] && [ "$STORED_NUMBER" = "$3" ] ||
    die 'handoff key does not match file contents'
}

capture_queue_rows() {
  local output=$1 file repo_url record api_number api_state api_repo api_url author html_url draft extra status
  : > "$output"
  for file in "$STATE_DIR"/process-prs-handoff-*.state; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    load_handoff_for_scan "$file" || continue
    repo_url="https://api.github.com/repos/$STORED_OWNER/$STORED_REPO"
    if record=$(gh api "repos/$STORED_OWNER/$STORED_REPO/pulls/$STORED_NUMBER" --jq '
      [(.number|tostring),.state,(.base.repo.full_name // ""),.url,
       (.user.login // ""),.html_url,((.draft // false)|tostring)] | @tsv'); then
      :
    else
      # One unreachable PR (deleted/private repo, transient API failure) must
      # not abort the whole sweep. Skip this row; the state file stays for a
      # later tick or manual reconciliation, and the per-PR guard still
      # protects any mutation downstream.
      printf 'pr-handoff: unable to capture PR for %s/%s#%s; skipping its queue row\n' \
        "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER" >&2
      continue
    fi
    IFS=$'\t' read -r api_number api_state api_repo api_url author html_url draft extra <<EOF
$record
EOF
    [ -z "${extra:-}" ] || die 'malformed PR response'
    [ "$api_number" = "$STORED_NUMBER" ] || die 'PR response number mismatch'
    [ "$api_repo" = "$STORED_OWNER/$STORED_REPO" ] || die 'PR response repository mismatch'
    [ "$api_url" = "$repo_url/pulls/$STORED_NUMBER" ] || die 'PR response API URL mismatch'
    [ "$html_url" = "https://github.com/$STORED_OWNER/$STORED_REPO/pull/$STORED_NUMBER" ] ||
      die 'PR response HTML URL mismatch'
    case "$draft" in true|false) ;; *) die 'PR response has invalid draft state' ;; esac
    case "$api_state" in
      open) printf '%s\t%s\t%s\t%s\t%s\n' \
        "$repo_url" "$STORED_NUMBER" "$author" "$html_url" "$draft" >> "$output" ;;
      closed)
        # Fold pruning into the capture: the row is authoritative proof the PR
        # closed, so a separate prune pass (one more REST call per handoff
        # every tick) is unnecessary.
        printf 'pr-handoff: pruning handoff for closed %s/%s#%s\n' \
          "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER" >&2
        [ -f "$file" ] && [ ! -L "$file" ] && find "$file" -type f -delete
        ;;
      *) die 'PR response has invalid state' ;;
    esac
  done
}

normalize_queue_rows() {
  LC_ALL=C sort -t "$TAB" -k1,1 -k2,2n "$1" | validate_dedupe_rows
}

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
GUARD="$SCRIPT_DIR/pr-review-guard.sh"
[ -f "$GUARD" ] && [ ! -L "$GUARD" ] && [ -x "$GUARD" ] || die 'pr-review-guard.sh is missing or unsafe'

mode=${1:-}
case "$mode" in
  save)
    [ "$#" -eq 7 ] || usage
    validate_target "$2" "$3" "$4"
    validate_phase "$6"
    validate_regular_file "$7" 'payload file'
    payload_size=$(wc -c < "$7" | tr -d ' ')
    case "$payload_size" in ''|*[!0-9]*) die 'invalid payload size' ;; esac
    [ "$payload_size" -le "$MAX_PAYLOAD_BYTES" ] || die 'payload exceeds 1 MiB'
    umask 077
    PAYLOAD_COPY=$(mktemp "${TMPDIR:-/tmp}/good-fellow-pr-handoff-payload.XXXXXX")
    dd if="$7" of="$PAYLOAD_COPY" bs=65536 2>/dev/null
    cmp -s "$7" "$PAYLOAD_COPY" || { printf 'pr-handoff: payload changed while copying\n' >&2; exit 3; }
    copied_size=$(wc -c < "$PAYLOAD_COPY" | tr -d ' ')
    [ "$copied_size" = "$payload_size" ] || { printf 'pr-handoff: payload changed while copying\n' >&2; exit 3; }
    snapshot_values "$5"
    verify_snapshot_target "$2" "$3" "$4" "$5"
    ensure_state_dir
    file=$(handoff_path "$2" "$3" "$4")
    if [ -e "$file" ] || [ -L "$file" ]; then
      load_handoff "$file"
      require_key_match "$2" "$3" "$4"
    fi
    umask 077
    TEMP_FILE=$(mktemp "$STATE_DIR/process-prs-handoff.XXXXXX")
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$MAGIC" "$2" "$3" "$4" "$SNAPSHOT_HEAD" "$SNAPSHOT_BASE" \
      "$SNAPSHOT_TOKEN" "$6" "$payload_size" > "$TEMP_FILE"
    dd if="$PAYLOAD_COPY" bs=65536 2>/dev/null >> "$TEMP_FILE"
    actual_size=$(tail -n +10 "$TEMP_FILE" | wc -c | tr -d ' ')
    [ "$actual_size" = "$payload_size" ] || die 'payload changed while saving'
    chmod 600 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$file"
    TEMP_FILE=''
    ;;
  match)
    [ "$#" -eq 5 ] || usage
    validate_target "$2" "$3" "$4"
    file=$(handoff_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 1; fi
    load_handoff "$file"
    require_key_match "$2" "$3" "$4"
    snapshot_values "$5"
    verify_snapshot_target "$2" "$3" "$4" "$5"
    if [ "$STORED_HEAD" != "$SNAPSHOT_HEAD" ] ||
       [ "$STORED_BASE" != "$SNAPSHOT_BASE" ]; then
      exit 3
    fi
    if [ "$STORED_TOKEN" = "$SNAPSHOT_TOKEN" ] ||
       [ "$STORED_TOKEN" = "$SNAPSHOT_LEGACY_TOKEN" ]; then
      printf '%s\n' "$STORED_PHASE"
    else
      # A token-schema migration and a real external-state delta are intentionally
      # indistinguishable here. The skill must compare the saved complete ledger
      # with the fresh snapshot before rebinding or discarding this handoff.
      printf '%s-migrate\n' "$STORED_PHASE"
    fi
    ;;
  payload)
    [ "$#" -eq 4 ] || usage
    validate_target "$2" "$3" "$4"
    file=$(handoff_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 1; fi
    load_handoff "$file"
    require_key_match "$2" "$3" "$4"
    tail -n +10 "$file"
    ;;
  clear)
    [ "$#" -eq 4 ] || usage
    validate_target "$2" "$3" "$4"
    file=$(handoff_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 0; fi
    validate_regular_file "$file" 'handoff file'
    find "$file" -type f -delete
    ;;
  show)
    [ "$#" -eq 1 ] || usage
    for file in "$STATE_DIR"/process-prs-handoff-*.state; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      load_handoff_for_scan "$file" || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER" "$STORED_HEAD" \
        "$STORED_BASE" "$STORED_TOKEN" "$STORED_PHASE" "$STORED_SIZE"
    done
    ;;
  reviewing-key)
    [ "$#" -eq 1 ] || usage
    # Serial ownership allows at most one reviewing handoff. Duplicates mean a
    # crashed or misbehaving earlier run; fail-open by keeping the newest file
    # and deleting the rest, or one bad tick would wedge every future sweep.
    reviewing_newest=''
    for file in "$STATE_DIR"/process-prs-handoff-*.state; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      load_handoff_for_scan "$file" || continue
      [ "$STORED_PHASE" = reviewing ] || continue
      if [ -z "$reviewing_newest" ]; then
        reviewing_newest=$file
      elif [ "$file" -nt "$reviewing_newest" ]; then
        printf 'pr-handoff: deleting duplicate reviewing handoff (serial ownership violated): %s\n' "$reviewing_newest" >&2
        find "$reviewing_newest" -type f -delete
        reviewing_newest=$file
      else
        printf 'pr-handoff: deleting duplicate reviewing handoff (serial ownership violated): %s\n' "$file" >&2
        find "$file" -type f -delete
      fi
    done
    if [ -n "$reviewing_newest" ]; then
      load_handoff "$reviewing_newest"
      printf '%s\t%s\n' "https://api.github.com/repos/$STORED_OWNER/$STORED_REPO" "$STORED_NUMBER"
    fi
    ;;
  queue-rows)
    [ "$#" -eq 1 ] || usage
    umask 077
    QUEUE_RAW=$(mktemp "${TMPDIR:-/tmp}/good-fellow-pr-handoff-queue.XXXXXX")
    QUEUE_ONE=$(mktemp "${TMPDIR:-/tmp}/good-fellow-pr-handoff-queue.XXXXXX")
    QUEUE_TWO=$(mktemp "${TMPDIR:-/tmp}/good-fellow-pr-handoff-queue.XXXXXX")
    capture_queue_rows "$QUEUE_RAW"
    normalize_queue_rows "$QUEUE_RAW" > "$QUEUE_ONE"
    capture_queue_rows "$QUEUE_RAW"
    normalize_queue_rows "$QUEUE_RAW" > "$QUEUE_TWO"
    cmp -s "$QUEUE_ONE" "$QUEUE_TWO" || {
      printf 'pr-handoff: PR state changed between queue captures\n' >&2
      exit 3
    }
    cat "$QUEUE_ONE"
    ;;
  prune)
    [ "$#" -eq 1 ] || usage
    for file in "$STATE_DIR"/process-prs-handoff-*.state; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      load_handoff_for_scan "$file" || continue
      if pr_state=$(gh api "repos/$STORED_OWNER/$STORED_REPO/pulls/$STORED_NUMBER" --jq .state 2>/dev/null); then
        case "$pr_state" in
          open) ;;
          closed) find "$file" -type f -delete ;;
          *) printf 'pr-handoff: unknown PR state; preserving %s\n' "$file" >&2 ;;
        esac
      else
        printf 'pr-handoff: unable to reconcile %s; preserving it\n' "$file" >&2
      fi
    done
    ;;
  *) usage ;;
esac
