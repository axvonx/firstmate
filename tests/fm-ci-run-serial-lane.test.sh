#!/usr/bin/env bash
# Contract tests for bin/fm-ci-run-serial-lane.sh - the CI wrapper that bounds a
# portable serial half and reports a budget overrun as a budget overrun rather
# than as a failing test.
#
# The wrapper's whole reason to exist is that a job cancellation is rendered as a
# plain `fail` by `gh pr checks`, so these tests pin the distinguishing output.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-ci-run-serial-lane.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-serial-lane)

assert_present "$RUNNER" "bin/fm-ci-run-serial-lane.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-ci-run-serial-lane.sh must be executable"

command -v timeout >/dev/null 2>&1 || { echo "skip: coreutils timeout not found"; exit 0; }

# Run the wrapper against a stub bin/fm-test-run.sh so the tests never execute
# the real suite. The stub lives in a copied tree so ROOT resolution still works.
run_wrapper() {  # <case> <lane> <budget> <stub-body> -> sets RUN_OUT RUN_RC
  local case_name=$1 lane=$2 budget=$3 stub=$4 dir
  dir="$TMP_ROOT/$case_name"
  mkdir -p "$dir/bin"
  cp "$RUNNER" "$dir/bin/fm-ci-run-serial-lane.sh"
  chmod +x "$dir/bin/fm-ci-run-serial-lane.sh"
  printf '%s\n' "$stub" >"$dir/bin/fm-test-run.sh"
  chmod +x "$dir/bin/fm-test-run.sh"
  set +e
  RUN_OUT=$(cd "$dir" && RUNNER_TEMP="$dir/tmp" FM_SERIAL_BUDGET_SECONDS="$budget" \
    ./bin/fm-ci-run-serial-lane.sh "$lane" 2>&1)
  RUN_RC=$?
  set -e
}

test_unsupported_lane_is_refused() {
  run_wrapper bad-lane portable-parallel-1 60 '#!/usr/bin/env bash
exit 0'
  expect_code 2 "$RUN_RC" "an unsupported lane must be refused before running anything"
  assert_contains "$RUN_OUT" "unsupported lane" "refusal names the bad lane"
  pass "an unsupported lane is refused without running the suite"
}

test_malformed_budget_is_refused() {
  run_wrapper bad-budget portable-serial-1 notanumber '#!/usr/bin/env bash
exit 0'
  expect_code 2 "$RUN_RC" "a non-numeric budget must be refused"
  assert_contains "$RUN_OUT" "FM_SERIAL_BUDGET_SECONDS" "refusal names the budget variable"
  pass "a malformed time budget is refused rather than silently defaulted"
}

test_passing_lane_passes_through() {
  run_wrapper pass portable-serial-1 60 '#!/usr/bin/env bash
echo "FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=5"
exit 0'
  expect_code 0 "$RUN_RC" "a passing lane must exit 0"
  case "$RUN_OUT" in
    *"::error"*) fail "a passing lane must not emit an error annotation: $RUN_OUT" ;;
  esac
  pass "a passing lane exits 0 with no overrun annotation"
}

test_real_test_failure_is_not_relabelled_as_a_timeout() {
  run_wrapper realfail portable-serial-2 60 '#!/usr/bin/env bash
echo "FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0 duration_ms=5"
exit 1'
  expect_code 1 "$RUN_RC" "a failing lane must exit 1"
  case "$RUN_OUT" in
    *"exceeded its time budget"*)
      fail "a genuine test failure must not be reported as a budget overrun: $RUN_OUT" ;;
  esac
  pass "a genuine test failure is not relabelled as a time-budget overrun"
}

test_budget_overrun_is_annotated_as_a_timeout() {
  # A 1s budget against a stub that outlives it: the wrapper must convert the
  # kill into a named annotation instead of an anonymous failure.
  run_wrapper overrun portable-serial-1 1 '#!/usr/bin/env bash
sleep 30
exit 0'
  expect_code 1 "$RUN_RC" "an overrun must fail the step (exit 1), not pass"
  assert_contains "$RUN_OUT" "::error" "an overrun must emit a GitHub error annotation"
  assert_contains "$RUN_OUT" "exceeded its time budget" "annotation must name the overrun"
  assert_contains "$RUN_OUT" "TIME BUDGET OVERRUN" "annotation must separate itself from a test failure"
  assert_contains "$RUN_OUT" "portable-serial-1" "annotation must name the lane"
  pass "a time-budget overrun is annotated as an overrun, not as a failing test"
}

# The overrun annotation is read under time pressure, so it must describe the
# real result. Claiming "no assertion failed" on a run where assertions DID fail
# would send the reader looking for a balance problem instead of a broken test.
stub_that_flushes_then_hangs() {  # <failed-count>
  cat <<STUB
#!/usr/bin/env bash
json=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --json) json=\$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\$(dirname "\$json")"
printf '%s\n' '{"interrupted": true, "summary": {"total": 3, "failed": $1, "skipped_gate": 0, "duration_ms": 1000}, "scripts": []}' >"\$json"
sleep 30
STUB
}

test_overrun_without_failures_says_no_assertion_failed() {
  run_wrapper overrun-clean portable-serial-1 1 "$(stub_that_flushes_then_hangs 0)"
  expect_code 1 "$RUN_RC" "an overrun must fail the step"
  assert_contains "$RUN_OUT" "No assertion failed" \
    "with zero recorded failures the annotation may say no assertion failed"
  pass "an overrun with no recorded failures says so"
}

test_overrun_with_failures_does_not_claim_no_assertion_failed() {
  run_wrapper overrun-dirty portable-serial-2 1 "$(stub_that_flushes_then_hangs 2)"
  expect_code 1 "$RUN_RC" "an overrun must fail the step"
  case "$RUN_OUT" in
    *"No assertion failed"*)
      fail "annotation must not claim no assertion failed when 2 scripts failed: $RUN_OUT" ;;
  esac
  assert_contains "$RUN_OUT" "ALREADY FAILED" "annotation must surface the recorded failures"
  assert_contains "$RUN_OUT" "2 script" "annotation must count the recorded failures"
  pass "an overrun with recorded failures reports them instead of denying them"
}

test_overrun_without_artifact_reports_unknown() {
  run_wrapper overrun-noartifact portable-serial-1 1 '#!/usr/bin/env bash
sleep 30'
  expect_code 1 "$RUN_RC" "an overrun must fail the step"
  case "$RUN_OUT" in
    *"No assertion failed"*)
      fail "annotation must not assert a clean result with no artifact to read: $RUN_OUT" ;;
  esac
  assert_contains "$RUN_OUT" "UNKNOWN" "annotation must admit it could not read the artifact"
  pass "an overrun with no readable artifact reports the failure count as unknown"
}

test_unsupported_lane_is_refused
test_malformed_budget_is_refused
test_passing_lane_passes_through
test_real_test_failure_is_not_relabelled_as_a_timeout
test_budget_overrun_is_annotated_as_a_timeout
test_overrun_without_failures_says_no_assertion_failed
test_overrun_with_failures_does_not_claim_no_assertion_failed
test_overrun_without_artifact_reports_unknown
