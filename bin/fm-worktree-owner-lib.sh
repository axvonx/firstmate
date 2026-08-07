#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_WORKTREE_OWNER_* are output globals for sourcing callers.
# fm-worktree-owner-lib.sh - the worktree OWNERSHIP record: proof that a task
# still occupies the worktree its metadata points at.
#
# Why this exists. A treehouse pool slot is reusable. When a task's worktree is
# returned, the same path is handed to the next lane, so a task's recorded
# worktree= can outlive the task's tenancy in it. Every landed-work check in
# bin/fm-teardown.sh answers "has THIS task's work landed"; none of them asks
# "does this task still occupy this worktree". A recycled slot makes those two
# different questions, and answering only the first - correctly - is how
# teardown reset a live lane's checkout and terminated its session on
# 2026-08-04. This library owns the second question.
#
# The record. bin/fm-spawn.sh writes one file per spawned worktree, and
# bin/fm-teardown.sh verifies it before anything destructive touches that
# worktree. It is deliberately NOT a branch comparison: two lanes can share a
# base, and a returned slot is reset to the default branch, so a branch match
# proves nothing. The record names the home, the task, the worktree, and a
# per-spawn token that no coincidence can reproduce.
#
# Where it lives: inside the worktree's own git directory, at
# <absolute-git-dir>/fm-task-owner - for a treehouse pool slot that is
# <project>/.git/worktrees/<slot>/fm-task-owner. That location is deliberate,
# and the alternatives were measured (docs/verification/worktree-ownership.md):
#   - git never reports it, so it cannot dirty a checkout, and `git add -A`
#     cannot stage it into a crewmate's commit.
#   - `treehouse return --force` runs `git clean -fd`, which removes untracked
#     files but NOT files listed in .git/info/exclude. So an excluded marker in
#     the worktree root would SURVIVE the return into the next occupant's slot,
#     which is the stale-claim hazard this record exists to remove, and an
#     unexcluded one would be committable. The git directory sidesteps both:
#     teardown removes the record itself, right before the return.
#
# Format (v1), one key=value per line after the version line:
#   fm-task-owner v1
#   home=<absolute firstmate home>
#   task=<task id>
#   worktree=<absolute physical worktree path>
#   token=<per-spawn token>
#
# Every field must agree for ownership to be proven. Disagreement, absence, and
# unreadability all REFUSE: a record that cannot be read is not a record that
# says yes. bin/fm-worktree-claim.sh is the operator path back from a refusal.

# Guard against double-sourcing (teardown and spawn both source several libs).
[ -n "${FM_WORKTREE_OWNER_LIB_SOURCED:-}" ] && return 0
FM_WORKTREE_OWNER_LIB_SOURCED=1

FM_WORKTREE_OWNER_FILE=fm-task-owner
FM_WORKTREE_OWNER_VERSION="fm-task-owner v1"

# Outputs of fm_worktree_owner_read / fm_worktree_owner_verify.
FM_WORKTREE_OWNER_HOME=
FM_WORKTREE_OWNER_TASK=
FM_WORKTREE_OWNER_WORKTREE=
FM_WORKTREE_OWNER_TOKEN=
FM_WORKTREE_OWNER_REASON=

# fm_worktree_owner_canonical_dir <dir>: physical path of an existing directory.
fm_worktree_owner_canonical_dir() {
  local dir=$1
  [ -n "$dir" ] || return 1
  [ -d "$dir" ] || return 1
  ( CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P )
}

# fm_worktree_owner_record_path <worktree>: absolute path of the ownership
# record for <worktree>. Fails when <worktree> is not an inspectable git
# worktree, because there is then nowhere to keep a record and nothing to prove.
fm_worktree_owner_record_path() {  # <worktree>
  local worktree=$1 git_dir
  [ -n "$worktree" ] || return 1
  [ -d "$worktree" ] || return 1
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -d "$git_dir" ] || return 1
  printf '%s/%s\n' "$git_dir" "$FM_WORKTREE_OWNER_FILE"
}

# fm_worktree_owner_mint: a per-spawn token, 32 lowercase hex chars. Uniqueness
# is what makes the record unforgeable by coincidence, so prefer real randomness
# and fall back only to values that still differ between two spawns on one
# machine. Same shape as bin/fm-pending-reply-lib.sh's correlation ids.
fm_worktree_owner_mint() {
  local raw='' hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 16 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    hex=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" \
      | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=${hex:0:32}
  fi
  raw=$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-32)
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw"
}

# fm_worktree_owner_token_valid <token>: a token must be a single non-empty
# line of safe characters, so it can never smuggle a newline into the record.
fm_worktree_owner_token_valid() {  # <token>
  case "${1:-}" in
    '') return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_worktree_owner_write <home> <task-id> <worktree> <token>: record this
# task's tenancy of <worktree>, replacing whatever the slot's previous occupant
# left behind. Writes through a temp file so a reader never sees half a record.
fm_worktree_owner_write() {  # <home> <task-id> <worktree> <token>
  local home=$1 task=$2 worktree=$3 token=$4 record home_abs wt_abs tmp
  fm_worktree_owner_token_valid "$token" || return 1
  [ -n "$task" ] || return 1
  home_abs=$(fm_worktree_owner_canonical_dir "$home") || return 1
  wt_abs=$(fm_worktree_owner_canonical_dir "$worktree") || return 1
  record=$(fm_worktree_owner_record_path "$worktree") || return 1
  tmp="$record.tmp.$$"
  {
    printf '%s\n' "$FM_WORKTREE_OWNER_VERSION"
    printf 'home=%s\n' "$home_abs"
    printf 'task=%s\n' "$task"
    printf 'worktree=%s\n' "$wt_abs"
    printf 'token=%s\n' "$token"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

# fm_worktree_owner_read <worktree>: load the record into the
# FM_WORKTREE_OWNER_* variables. Non-zero when there is no readable v1 record;
# FM_WORKTREE_OWNER_REASON then says why.
fm_worktree_owner_read() {  # <worktree>
  local worktree=$1 record line first
  FM_WORKTREE_OWNER_HOME=
  FM_WORKTREE_OWNER_TASK=
  FM_WORKTREE_OWNER_WORKTREE=
  FM_WORKTREE_OWNER_TOKEN=
  FM_WORKTREE_OWNER_REASON=
  if ! record=$(fm_worktree_owner_record_path "$worktree"); then
    FM_WORKTREE_OWNER_REASON="worktree ${worktree:-<missing>} is not an inspectable git worktree, so its ownership cannot be read"
    return 1
  fi
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    FM_WORKTREE_OWNER_REASON="no ownership record at $record"
    return 1
  fi
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    FM_WORKTREE_OWNER_REASON="ownership record $record is not a plain file"
    return 1
  fi
  first=$(head -1 "$record" 2>/dev/null) || first=
  if [ "$first" != "$FM_WORKTREE_OWNER_VERSION" ]; then
    FM_WORKTREE_OWNER_REASON="ownership record $record is not a $FM_WORKTREE_OWNER_VERSION record"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      home=*)     FM_WORKTREE_OWNER_HOME=${line#home=} ;;
      task=*)     FM_WORKTREE_OWNER_TASK=${line#task=} ;;
      worktree=*) FM_WORKTREE_OWNER_WORKTREE=${line#worktree=} ;;
      token=*)    FM_WORKTREE_OWNER_TOKEN=${line#token=} ;;
    esac
  done < "$record"
  if [ -z "$FM_WORKTREE_OWNER_HOME" ] || [ -z "$FM_WORKTREE_OWNER_TASK" ] \
    || [ -z "$FM_WORKTREE_OWNER_WORKTREE" ] || [ -z "$FM_WORKTREE_OWNER_TOKEN" ]; then
    FM_WORKTREE_OWNER_REASON="ownership record $record is incomplete"
    return 1
  fi
}

# fm_worktree_owner_verify <home> <task-id> <worktree> <token>: prove <worktree>
# still belongs to <task-id>. Every disagreement names the identity that
# disagreed, because "cleanup refused" without that is unactionable.
fm_worktree_owner_verify() {  # <home> <task-id> <worktree> <token>
  local home=$1 task=$2 worktree=$3 token=$4 home_abs wt_abs record
  FM_WORKTREE_OWNER_REASON=
  if ! home_abs=$(fm_worktree_owner_canonical_dir "$home"); then
    FM_WORKTREE_OWNER_REASON="firstmate home ${home:-<missing>} cannot be resolved, so ownership cannot be proven"
    return 1
  fi
  if ! wt_abs=$(fm_worktree_owner_canonical_dir "$worktree"); then
    FM_WORKTREE_OWNER_REASON="worktree ${worktree:-<missing>} cannot be resolved, so ownership cannot be proven"
    return 1
  fi
  if ! fm_worktree_owner_token_valid "$token"; then
    record=$(fm_worktree_owner_record_path "$worktree" 2>/dev/null || printf '%s' '<unresolvable>')
    FM_WORKTREE_OWNER_REASON="this task's record carries no worktree ownership token (it predates ownership proof), so the worktree at $record cannot be matched to it"
    return 1
  fi
  fm_worktree_owner_read "$worktree" || return 1
  if [ "$FM_WORKTREE_OWNER_TASK" != "$task" ]; then
    FM_WORKTREE_OWNER_REASON="the worktree's ownership record names task $FM_WORKTREE_OWNER_TASK, not $task"
    return 1
  fi
  if [ "$FM_WORKTREE_OWNER_HOME" != "$home_abs" ]; then
    FM_WORKTREE_OWNER_REASON="the worktree's ownership record names home $FM_WORKTREE_OWNER_HOME, not $home_abs"
    return 1
  fi
  if [ "$FM_WORKTREE_OWNER_WORKTREE" != "$wt_abs" ]; then
    FM_WORKTREE_OWNER_REASON="the worktree's ownership record was written for $FM_WORKTREE_OWNER_WORKTREE, not $wt_abs"
    return 1
  fi
  if [ "$FM_WORKTREE_OWNER_TOKEN" != "$token" ]; then
    FM_WORKTREE_OWNER_REASON="the worktree's ownership token does not match this task's recorded token, so the slot was reissued after this task last held it"
    return 1
  fi
}

# fm_worktree_owner_remove <worktree>: drop the record. Called when the worktree
# stops belonging to the task, so a returned slot carries no stale claim.
fm_worktree_owner_remove() {  # <worktree>
  local record
  record=$(fm_worktree_owner_record_path "$1" 2>/dev/null) || return 0
  rm -f "$record"
}

# fm_worktree_owner_conflicting_task <state-dir> <task-id> <worktree>: the id of
# another task in the SAME home whose metadata records this worktree, if any.
# The ownership record is the primary proof; this is the check that also covers
# records written before ownership proof existed, and it is the exact shape of
# the 2026-08-04 incident - two tasks' metadata naming one pool slot.
fm_worktree_owner_conflicting_task() {  # <state-dir> <task-id> <worktree>
  local state=$1 task=$2 worktree=$3 meta other other_wt wt_abs other_abs
  [ -d "$state" ] || return 1
  wt_abs=$(fm_worktree_owner_canonical_dir "$worktree") || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    other=$(basename "$meta" .meta)
    [ "$other" != "$task" ] || continue
    other_wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$other_wt" ] || continue
    other_abs=$(fm_worktree_owner_canonical_dir "$other_wt") || continue
    if [ "$other_abs" = "$wt_abs" ]; then
      printf '%s\n' "$other"
      return 0
    fi
  done
  return 1
}
