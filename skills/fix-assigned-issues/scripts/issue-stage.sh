#!/usr/bin/env bash
# Persist an in-progress issue fix across sweep runs, bound to the issue's
# updated_at so a resume never continues on top of a changed issue.
set -Eeuo pipefail

export GH_PROMPT_DISABLED=1
export NO_COLOR=1

STAGE_LIB="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)/../../process-prs/scripts/lib.sh"
[ -f "$STAGE_LIB" ] && [ ! -L "$STAGE_LIB" ] || { printf 'issue-stage: lib.sh is missing or unsafe\n' >&2; exit 64; }
LIB_TOOL='issue-stage'
. "$STAGE_LIB"

STATE_DIR="${GOOD_FELLOW_STATE_DIR:-$HOME/.good-fellow}"
MAX_NOTES_BYTES=65536
MAGIC='good-fellow-issue-stage-v1'
TEMP_FILE=''
NOTES_COPY=''

cleanup() {
  [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
  [ -z "$NOTES_COPY" ] || rm -f "$NOTES_COPY"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

usage() {
  printf '%s\n' \
    'usage: issue-stage.sh save OWNER REPO NUMBER UPDATED_AT BASE_OID WORKSPACE_PATH NOTES_FILE' \
    '       issue-stage.sh match OWNER REPO NUMBER UPDATED_AT' \
    '       issue-stage.sh notes OWNER REPO NUMBER' \
    '       issue-stage.sh clear OWNER REPO NUMBER' \
    '       issue-stage.sh show' \
    '       issue-stage.sh staged-workspaces' \
    '       issue-stage.sh prune' >&2
  exit 64
}

validate_issue_target() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*) die 'invalid owner' ;; esac
  case "$2" in ''|*[!A-Za-z0-9_.-]*) die 'invalid repository' ;; esac
  case "$3" in ''|0|*[!0-9]*) die 'invalid issue number' ;; esac
}

validate_updated_at() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) die 'updated_at must be an ISO8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)' ;;
  esac
}

validate_workspace_path() {
  case "$1" in "$HOME"/?*) ;; *) die 'workspace path must live under $HOME' ;; esac
  case "/$1/" in */../*|*$'\n'*) die 'workspace path must not contain .. or newlines' ;; esac
}

validate_count() {
  case "$1" in ''|*[!0-9]*) die 'invalid resume count' ;; esac
}

ensure_state_dir() {
  if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || die 'state directory must be a real directory'
  else
    umask 077
    mkdir -p "$STATE_DIR"
  fi
}

stage_path() {
  printf '%s/fix-issues-stage-%s-%s-%s-%s-%s.state\n' \
    "$STATE_DIR" "${#1}" "$1" "${#2}" "$2" "$3"
}

read_line() {
  # Stop before the arbitrary notes payload so BSD sed never decodes it.
  sed -n "$2"'p;'"$2"'q' "$1"
}

load_stage() {
  local file=$1 actual_size
  validate_regular_file "$file" 'stage file'
  STORED_MAGIC=$(read_line "$file" 1)
  STORED_OWNER=$(read_line "$file" 2)
  STORED_REPO=$(read_line "$file" 3)
  STORED_NUMBER=$(read_line "$file" 4)
  STORED_UPDATED=$(read_line "$file" 5)
  STORED_BASE=$(read_line "$file" 6)
  STORED_WORKSPACE=$(read_line "$file" 7)
  STORED_COUNT=$(read_line "$file" 8)
  STORED_SIZE=$(read_line "$file" 9)
  [ "$STORED_MAGIC" = "$MAGIC" ] || die 'invalid stage format'
  validate_issue_target "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER"
  validate_updated_at "$STORED_UPDATED"
  validate_oid "$STORED_BASE" 'stored base'
  validate_workspace_path "$STORED_WORKSPACE"
  validate_count "$STORED_COUNT"
  case "$STORED_SIZE" in ''|*[!0-9]*) die 'invalid stored notes size' ;; esac
  [ "$STORED_SIZE" -le "$MAX_NOTES_BYTES" ] || die 'stored notes exceed 64 KiB'
  actual_size=$(tail -n +10 "$file" | wc -c | tr -d ' ')
  [ "$actual_size" = "$STORED_SIZE" ] || die 'stored notes size mismatch'
}

# Collection modes must remain usable when one state file is truncated or
# corrupt: a single bad entry is ignored with a visible warning instead of
# wedging every future sweep.
load_stage_for_scan() {
  local file=$1
  if ! (load_stage "$file") >/dev/null 2>&1; then
    printf 'issue-stage: ignoring invalid state file %s\n' "$file" >&2
    return 1
  fi
  load_stage "$file"
}

require_key_match() {
  [ "$STORED_OWNER" = "$1" ] && [ "$STORED_REPO" = "$2" ] && [ "$STORED_NUMBER" = "$3" ] ||
    die 'stage key does not match file contents'
}

mode=${1:-}
case "$mode" in
  save)
    [ "$#" -eq 8 ] || usage
    validate_issue_target "$2" "$3" "$4"
    validate_updated_at "$5"
    validate_oid "$6" 'base'
    validate_workspace_path "$7"
    [ -d "$7" ] || die 'workspace path does not exist'
    validate_regular_file "$8" 'notes file'
    notes_size=$(wc -c < "$8" | tr -d ' ')
    case "$notes_size" in ''|*[!0-9]*) die 'invalid notes size' ;; esac
    [ "$notes_size" -le "$MAX_NOTES_BYTES" ] || die 'notes exceed 64 KiB'
    umask 077
    NOTES_COPY=$(mktemp "${TMPDIR:-/tmp}/good-fellow-issue-stage-notes.XXXXXX")
    dd if="$8" of="$NOTES_COPY" bs=65536 2>/dev/null
    cmp -s "$8" "$NOTES_COPY" || { printf 'issue-stage: notes changed while copying\n' >&2; exit 3; }
    ensure_state_dir
    file=$(stage_path "$2" "$3" "$4")
    count=0
    if [ -e "$file" ] || [ -L "$file" ]; then
      load_stage "$file"
      require_key_match "$2" "$3" "$4"
      count=$((STORED_COUNT + 1))
    fi
    umask 077
    TEMP_FILE=$(mktemp "$STATE_DIR/fix-issues-stage.XXXXXX")
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$MAGIC" "$2" "$3" "$4" "$5" "$6" "$7" "$count" "$notes_size" > "$TEMP_FILE"
    dd if="$NOTES_COPY" bs=65536 2>/dev/null >> "$TEMP_FILE"
    actual_size=$(tail -n +10 "$TEMP_FILE" | wc -c | tr -d ' ')
    [ "$actual_size" = "$notes_size" ] || die 'notes changed while saving'
    chmod 600 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$file"
    TEMP_FILE=''
    ;;
  match)
    [ "$#" -eq 5 ] || usage
    validate_issue_target "$2" "$3" "$4"
    validate_updated_at "$5"
    file=$(stage_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 1; fi
    load_stage "$file"
    require_key_match "$2" "$3" "$4"
    # A moved updated_at means the issue changed since staging (new comments,
    # edits, reassignment): the saved plan may no longer apply, so the caller
    # must discard the stage and start over from the live issue.
    [ "$STORED_UPDATED" = "$5" ] || exit 3
    printf '%s\t%s\t%s\n' "$STORED_COUNT" "$STORED_BASE" "$STORED_WORKSPACE"
    ;;
  notes)
    [ "$#" -eq 4 ] || usage
    validate_issue_target "$2" "$3" "$4"
    file=$(stage_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 1; fi
    load_stage "$file"
    require_key_match "$2" "$3" "$4"
    tail -n +10 "$file"
    ;;
  clear)
    [ "$#" -eq 4 ] || usage
    validate_issue_target "$2" "$3" "$4"
    file=$(stage_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 0; fi
    validate_regular_file "$file" 'stage file'
    find "$file" -type f -delete
    ;;
  show)
    [ "$#" -eq 1 ] || usage
    for file in "$STATE_DIR"/fix-issues-stage-*.state; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      load_stage_for_scan "$file" || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER" "$STORED_UPDATED" \
        "$STORED_BASE" "$STORED_WORKSPACE" "$STORED_COUNT"
    done
    ;;
  staged-workspaces)
    [ "$#" -eq 1 ] || usage
    for file in "$STATE_DIR"/fix-issues-stage-*.state; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      load_stage_for_scan "$file" || continue
      printf '%s\n' "$STORED_WORKSPACE"
    done
    ;;
  prune)
    [ "$#" -eq 1 ] || usage
    for file in "$STATE_DIR"/fix-issues-stage-*.state; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      load_stage_for_scan "$file" || continue
      if [ ! -d "$STORED_WORKSPACE" ]; then
        printf 'issue-stage: pruning stage with missing workspace for %s/%s#%s\n' \
          "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER" >&2
        find "$file" -type f -delete
        continue
      fi
      if issue_state=$(gh api "repos/$STORED_OWNER/$STORED_REPO/issues/$STORED_NUMBER" --jq .state 2>/dev/null); then
        case "$issue_state" in
          open) ;;
          closed)
            # Deleting the stage demotes the workspace to an ordinary leftover;
            # the skill's normal recovery then removes it.
            printf 'issue-stage: pruning stage for closed %s/%s#%s\n' \
              "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER" >&2
            find "$file" -type f -delete
            ;;
          *) printf 'issue-stage: unknown issue state; preserving %s\n' "$file" >&2 ;;
        esac
      else
        printf 'issue-stage: unable to reconcile %s; preserving it\n' "$file" >&2
      fi
    done
    ;;
  *) usage ;;
esac
