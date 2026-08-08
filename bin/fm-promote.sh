#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement). That message is the
# only ship contract a promoted crewmate ever receives, and it keeps the scout
# brief, which carries no definition of done - so the instructions must STATE the
# delivery mode's definition of done rather than defer to one the worker does not
# have. It is also the only document that owns its first action, which is the
# reset, not the branch. The mode comes from the task's own meta, as in
# fm-teardown.sh and fm-merge-local.sh, so the contract stated is the project's
# real one: a no-mistakes project runs on from the implementation commit into the
# pipeline instead of reporting and waiting there, while direct-PR and local-only
# do not, and handing any of them the wrong one misdirects the whole task.
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE='not recorded in meta, so resolve it from data/projects.md'

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "delivery mode: $MODE - the crewmate keeps the scout brief, which carries no definition of done, so state that mode's own one in the instructions instead of deferring to a document it does not have"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; finish by that delivery mode definition of done, stated here in full>'"
