#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. Promotion must also hand the crewmate the ship contract, because it holds
# the scout brief and nothing else: a ship instruction that defers to "the
# definition of done for this delivery mode" would otherwise point at a document
# that worker does not possess. bin/fm-brief.sh is the single owner of that
# definition - which for a no-mistakes project runs on from the implementation
# commit into the pipeline rather than reporting and waiting there - so the
# printed next steps re-scaffold the brief for the new kind and keep the scout
# one beside it, instead of restating the contract here in a second place.
# The instructions then cover the crossover fm-brief.sh cannot know about:
# inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, and implement.
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
if [ -n "$PROJ" ]; then PROJ_Q=$(printf '%q' "$PROJ"); else PROJ_Q='<project>'; fi
HOME_Q=$(printf '%q' "$FM_HOME")
BRIEF_Q=$(printf '%q' "$DATA/$ID/brief.md")
SCOUT_BRIEF_Q=$(printf '%q' "$DATA/$ID/brief-scout.md")
echo "promoted $ID to ship (teardown protection restored)"
echo "the crewmate still holds the scout contract only, so give it the ship one before sending work:"
echo "next: mv $BRIEF_Q $SCOUT_BRIEF_Q && FM_HOME=$HOME_Q bin/fm-brief.sh $ID $PROJ_Q   # this project delivery mode's own definition of done; then replace {TASK}"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: your brief has been replaced with this project ship contract - re-read it in full and follow its Definition of done to the end; review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement>'"
