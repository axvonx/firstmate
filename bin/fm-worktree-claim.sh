#!/usr/bin/env bash
# fm-worktree-claim.sh - re-establish a task's WORKTREE OWNERSHIP record, so
# cleanup that refused for want of one can run.
#
# When to use it. bin/fm-teardown.sh refuses to touch a worktree it cannot prove
# is still the task's own, because a treehouse pool slot is reusable and a task's
# recorded worktree can outlive its tenancy in it. Records written before
# ownership proof existed carry no token, so they refuse. That refusal is
# correct and must not be bypassed with --force, which authorizes discarding
# THIS task's work and never authorizes resetting a slot that now holds another
# lane. This script is the way through: it re-checks what a machine can check,
# shows what only a person can check, and writes the record on confirmation.
#
# What it verifies for you:
#   - the task has a metadata record naming an existing, inspectable worktree
#   - no other task in the same home records that same worktree
#   - the worktree does not already carry another home's or task's ownership
#     record (that is a proven foreign occupant, and is never overwritten here)
# What only you can verify: that the agent and the work in that worktree are
# this task's. Run without --confirm to see the evidence, then confirm.
#
# Usage: fm-worktree-claim.sh <task-id> [--confirm]
#   FM_HOME selects the home whose task this is, exactly as for fm-teardown.sh.
#   Without --confirm nothing is written and the exit status is non-zero.
#   With --confirm the ownership record is written into the worktree and
#   worktree_token= is recorded in state/<task-id>.meta.
#
# bin/fm-worktree-owner-lib.sh owns the record's location, format, and
# verification; this script only writes what that library defines.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-worktree-owner-lib.sh
. "$SCRIPT_DIR/fm-worktree-owner-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  ''|-h|--help) usage; exit 0 ;;
esac
ID=$1
shift
CONFIRM=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm) CONFIRM=1 ;;
    *) echo "error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if ! fm_task_id_path_safe "$ID"; then
  echo "error: invalid task id $ID" >&2
  exit 2
fi
# Fail closed before any fleet mutation: a claim re-arms a cleanup that would
# reset a worktree and terminate what runs in it, so a no-mistakes gate agent
# must no more be able to claim one than to tear one down
# (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: no record for task $ID at $META" >&2
  exit 1
}
WT=$(fm_meta_get "$META" worktree)
[ -n "$WT" ] || { echo "error: task $ID records no worktree" >&2; exit 1; }
[ -d "$WT" ] || {
  echo "error: task $ID's recorded worktree $WT does not exist; there is nothing to claim" >&2
  exit 1
}
if ! RECORD=$(fm_worktree_owner_record_path "$WT"); then
  echo "error: $WT is not an inspectable git worktree, so ownership cannot be recorded there" >&2
  exit 1
fi
HOME_ABS=$(fm_worktree_owner_canonical_dir "$FM_HOME") || {
  echo "error: firstmate home $FM_HOME cannot be resolved" >&2
  exit 1
}

# A second task in this home naming the same worktree is the exact shape of the
# recycled-slot incident. Claiming would pick a winner by assertion; refuse.
if OTHER=$(fm_worktree_owner_conflicting_task "$STATE" "$ID" "$WT"); then
  echo "REFUSED: worktree $WT is also recorded as task $OTHER's worktree." >&2
  echo "Two tasks cannot both own one pool slot. Work out which one actually occupies it and correct the other's record before claiming." >&2
  exit 1
fi

# An existing record naming someone else is proof of a foreign occupant, not a
# gap in the proof. Never overwrite it.
if fm_worktree_owner_read "$WT"; then
  if [ "$FM_WORKTREE_OWNER_TASK" != "$ID" ] || [ "$FM_WORKTREE_OWNER_HOME" != "$HOME_ABS" ]; then
    echo "REFUSED: worktree $WT already carries an ownership record for task $FM_WORKTREE_OWNER_TASK in home $FM_WORKTREE_OWNER_HOME." >&2
    echo "That is another lane's worktree. Do not claim it, and do not clean up task $ID against it - correct task $ID's recorded worktree instead." >&2
    exit 1
  fi
fi

BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<unreadable>')
DIRTY=$(git -C "$WT" status --porcelain 2>/dev/null | head -5 || true)
WINDOW=$(fm_meta_get "$META" window)
EXISTING=$(fm_meta_get "$META" worktree_token)

if [ "$CONFIRM" != 1 ]; then
  echo "Task $ID would claim ownership of:"
  echo "  worktree:        $WT"
  echo "  its branch:      $BRANCH"
  echo "  recorded window: ${WINDOW:-<none>}"
  echo "  ownership record to write: $RECORD"
  if [ -n "$EXISTING" ]; then
    echo "  note: this task already records a worktree token; claiming replaces it."
  fi
  if [ -n "$DIRTY" ]; then
    echo "  uncommitted changes present in that worktree:"
    printf '    %s\n' "$DIRTY"
  fi
  echo
  echo "Checked already: no other task in this home records this worktree, and it carries no other task's ownership record."
  echo "Only you can check the rest: that the agent and the work in that worktree are task $ID's, not another lane's."
  echo "If it is, confirm with:"
  if [ "$FM_HOME" = "$FM_ROOT" ]; then
    echo "  bin/fm-worktree-claim.sh $ID --confirm"
  else
    echo "  FM_HOME=$FM_HOME bin/fm-worktree-claim.sh $ID --confirm"
  fi
  echo "Nothing was written."
  exit 1
fi

TOKEN=$(fm_worktree_owner_mint) || { echo "error: could not mint an ownership token" >&2; exit 1; }
fm_worktree_owner_write "$FM_HOME" "$ID" "$WT" "$TOKEN" || {
  echo "error: could not write the ownership record at $RECORD" >&2
  exit 1
}
TMP="$META.claim.$$"
{
  grep -v '^worktree_token=' "$META" || true
  printf 'worktree_token=%s\n' "$TOKEN"
} > "$TMP" || { rm -f "$TMP"; echo "error: could not stage the updated record for $ID" >&2; exit 1; }
mv -f "$TMP" "$META" || { rm -f "$TMP"; echo "error: could not update the record for $ID" >&2; exit 1; }
echo "claimed: task $ID now owns worktree $WT (record $RECORD)"
