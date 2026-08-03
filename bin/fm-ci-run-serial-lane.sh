#!/usr/bin/env bash
# fm-ci-run-serial-lane.sh - run one portable serial CI half under an explicit
# time budget and report a budget overrun as itself.
#
# Why this exists: a job that exceeds `timeout-minutes` is reported by GitHub as
# CANCELLED, which `gh pr checks` renders as a plain `fail`. A timeout is then
# indistinguishable from a real test failure at the surface most people read,
# and the lane's timing artifact is lost precisely when the timing is the thing
# being asked for. Bounding the suite here instead means an overrun is an
# ordinary step failure carrying a named annotation, and bin/fm-test-run.sh's
# interrupt handler still writes the per-script durations it measured.
#
# Usage:
#   fm-ci-run-serial-lane.sh <lane>
#
# Arguments:
#   <lane>  portable-serial-1 | portable-serial-2 | portable-serial
#
# Environment:
#   FM_SERIAL_BUDGET_SECONDS  hard bound for the suite, in seconds (default 780).
#                             Keep it below the job's timeout-minutes so this
#                             bound, not the job cancellation, is what fires.
#   RUNNER_TEMP               CI scratch directory (default: a local ./.fm-ci-tmp,
#                             which .gitignore keeps out of `git status`)
#
# Exit status:
#   0    the lane passed
#   1    the lane failed, or exceeded FM_SERIAL_BUDGET_SECONDS (annotated)
#   2    usage error
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

die() {
  printf 'fm-ci-run-serial-lane: %s\n' "$*" >&2
  exit 2
}

[ "$#" -eq 1 ] || die "usage: fm-ci-run-serial-lane.sh <lane>"
LANE=$1
case "$LANE" in
  portable-serial|portable-serial-1|portable-serial-2) ;;
  *) die "unsupported lane '$LANE' (expected a portable serial lane)" ;;
esac

BUDGET=${FM_SERIAL_BUDGET_SECONDS:-780}
case "$BUDGET" in
  ''|*[!0-9]*|0) die "FM_SERIAL_BUDGET_SECONDS must be a positive integer, got '$BUDGET'" ;;
esac

TMP_BASE=${RUNNER_TEMP:-$ROOT/.fm-ci-tmp}
OUT_DIR="$TMP_BASE/fm-test"
JSON_PATH="$OUT_DIR/fm-test-timing-$LANE.json"
mkdir -p "$OUT_DIR"

command -v timeout >/dev/null 2>&1 || die "coreutils timeout is required to bound the lane"

# --kill-after is a backstop only: fm-test-run.sh handles TERM by flushing its
# partial timing artifact, so the grace window is what makes that flush land.
rc=0
timeout --kill-after=30s "$BUDGET" \
  bin/fm-test-run.sh --lane "$LANE" --json "$JSON_PATH" || rc=$?

# Failures recorded in the flushed artifact before the stop, or "unknown" when
# no readable artifact landed. The annotation must never claim "no assertion
# failed" on a run where assertions DID fail: that is a false statement in the
# surface someone reads under time pressure.
failed_before_stop() {
  [ -s "$JSON_PATH" ] || { printf 'unknown\n'; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  python3 - "$JSON_PATH" <<'PY' 2>/dev/null || printf 'unknown\n'
import json, sys
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
    print(int((doc.get("summary") or {}).get("failed")))
except Exception:
    print("unknown")
PY
}

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  if [ "$BUDGET" -ge 60 ]; then
    budget_text="$((BUDGET / 60))m"
  else
    budget_text="${BUDGET}s"
  fi
  failed=$(failed_before_stop)
  case "$failed" in
    0) verdict='No assertion failed in the scripts that completed before the stop.' ;;
    unknown) verdict='No timing artifact was readable, so whether any assertion failed before the stop is UNKNOWN - read the step log.' ;;
    *) verdict="WARNING: $failed script(s) had ALREADY FAILED before the stop, so this run carries real test failures as well - fix those too." ;;
  esac
  printf '::error title=Serial lane %s exceeded its time budget::' "$LANE"
  printf 'The suite ran past its %s budget and was stopped. ' "$budget_text"
  printf 'The step failure itself is a TIME BUDGET OVERRUN, not a test result. '
  printf '%s ' "$verdict"
  printf 'Download the %s timing artifact for the ' "fm-test-timing-$LANE"
  printf 'per-script durations measured before the stop, then rebalance the '
  printf 'serial halves in bin/fm-test-run.sh or raise the budget deliberately.\n'
  printf 'fm-ci-run-serial-lane: lane %s exceeded %ss (failures before stop: %s)\n' \
    "$LANE" "$BUDGET" "$failed" >&2
  exit 1
fi

exit "$rc"
