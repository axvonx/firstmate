#!/usr/bin/env bash
# Contract tests for bin/fm-test-timing-aggregate.sh - the CI collector that
# feeds every lane's timing JSON into the aggregate.
#
# The aggregate exists to warn when a lane approaches its time budget, so a lane
# it silently omits is worse than no aggregate: it reads as coverage. These
# tests pin the two ways a lane has actually been lost - a timing JSON nested
# deeper inside its artifact than a flat glob reaches, and a lane added to the
# workflow but never accounted for here - as loud failures rather than a
# quietly smaller number.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COLLECTOR="$ROOT/bin/fm-test-timing-aggregate.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-timing-aggregate)

assert_present "$COLLECTOR" "bin/fm-test-timing-aggregate.sh is missing"
[ -x "$COLLECTOR" ] || fail "bin/fm-test-timing-aggregate.sh must be executable"

LANES=(
  fm-test-timing-portable-parallel-1
  fm-test-timing-portable-parallel-2
  fm-test-timing-herdr
)

# Build a download root in the shape actions/download-artifact writes WITHOUT
# merge-multiple: one directory per artifact. The Herdr lane's JSON is placed a
# level deeper because that lane uploads sibling diagnostics, which moves
# upload-artifact's least common ancestor up and nests the JSON. That nesting is
# the real-world condition that dropped the lane.
make_download_root() {  # <case> -> echoes the root
  local case_name=$1 root
  root="$TMP_ROOT/$case_name/download"
  mkdir -p "$root"
  local lane
  for lane in fm-test-timing-portable-parallel-1 fm-test-timing-portable-parallel-2; do
    mkdir -p "$root/$lane"
    printf '%s\n' '{}' >"$root/$lane/$lane.json"
  done
  mkdir -p "$root/fm-test-timing-herdr/fm-test" "$root/fm-test-timing-herdr/fm-herdr"
  printf '%s\n' '{}' >"$root/fm-test-timing-herdr/fm-test/fm-test-timing-herdr.json"
  printf '%s\n' 'log line' >"$root/fm-test-timing-herdr/fm-herdr/default-server.log"
  printf '%s' "$root"
}

# Stub bin/fm-test-run.sh so the tests never run the real suite. By default it
# reports the number of inputs it was handed as the lane count, which is what
# the collector cross-checks against the lanes it expected. FM_STUB_FORCED_LANES
# overrides that so a disagreeing aggregator can be exercised too.
install_stub() {  # <case> -> echoes the stubbed tree's collector
  local case_name=$1 dir
  dir="$TMP_ROOT/$case_name/tree"
  mkdir -p "$dir/bin"
  cp "$COLLECTOR" "$dir/bin/fm-test-timing-aggregate.sh"
  chmod +x "$dir/bin/fm-test-timing-aggregate.sh"
  cat >"$dir/bin/fm-test-run.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
shift          # --aggregate-json
out=$1; shift
mkdir -p "$(dirname "$out")"
printf '%s\n' '{"kind":"aggregate"}' >"$out"
printf 'FM_TEST_AGGREGATE lanes=%s total=0 failed=0 skipped_gate=0 critical_path_duration_ms=0 interrupted=false\n' \
  "${FM_STUB_FORCED_LANES:-$#}"
STUB
  chmod +x "$dir/bin/fm-test-run.sh"
  printf '%s' "$dir/bin/fm-test-timing-aggregate.sh"
}

run_collector() {  # <script> <root> <lane>... -> sets RUN_OUT RUN_RC
  local script=$1 root=$2
  shift 2
  set +e
  RUN_OUT=$("$script" --ignore fm-test-timing-aggregate \
    "$root" "$root/../out/fm-test-timing-aggregate.json" "$@" 2>&1)
  RUN_RC=$?
  set -e
}

# The regression this whole script exists for. A flat, non-recursive collection
# over the download root matches the two shallow lanes and misses the nested
# Herdr JSON, which is exactly how run 30772917079 reported 4 lanes for a
# 5-lane suite.
test_nested_lane_json_is_collected() {
  local root script
  root=$(make_download_root nested)
  script=$(install_stub nested)
  run_collector "$script" "$root" "${LANES[@]}"
  expect_code 0 "$RUN_RC" "every lane present must aggregate cleanly: $RUN_OUT"
  assert_contains "$RUN_OUT" "lanes=3" \
    "a timing JSON nested inside its artifact must still be collected"
  assert_contains "$RUN_OUT" "FM_TEST_TIMING_LANES ok" "collector must confirm the lane count"
  pass "a lane whose timing JSON is nested inside its artifact is still collected"
}

test_lane_contributing_no_json_fails_loudly() {
  local root script
  root=$(make_download_root emptied)
  rm "$root/fm-test-timing-herdr/fm-test/fm-test-timing-herdr.json"
  script=$(install_stub emptied)
  run_collector "$script" "$root" "${LANES[@]}"
  expect_code 1 "$RUN_RC" "a lane contributing no timing JSON must fail the step"
  assert_contains "$RUN_OUT" "::error" "a dropped lane must emit a GitHub error annotation"
  assert_contains "$RUN_OUT" "fm-test-timing-herdr" "the annotation must name the dropped lane"
  pass "a lane whose artifact no longer carries a timing JSON fails loudly"
}

test_missing_lane_artifact_fails_loudly() {
  local root script
  root=$(make_download_root missing)
  rm -rf "$root/fm-test-timing-herdr"
  script=$(install_stub missing)
  run_collector "$script" "$root" "${LANES[@]}"
  expect_code 1 "$RUN_RC" "a lane that uploaded nothing must fail rather than shrink the aggregate"
  assert_contains "$RUN_OUT" "fm-test-timing-herdr" "the annotation must name the absent lane"
  pass "a lane that uploaded no artifact at all fails rather than silently shrinking the aggregate"
}

# The same omission seen from the other side: a lane added to the workflow but
# never added to the collector's accounting would otherwise be ignored.
test_unaccounted_lane_artifact_fails_loudly() {
  local root script
  root=$(make_download_root unaccounted)
  mkdir -p "$root/fm-test-timing-brand-new"
  printf '%s\n' '{}' >"$root/fm-test-timing-brand-new/fm-test-timing-brand-new.json"
  script=$(install_stub unaccounted)
  run_collector "$script" "$root" "${LANES[@]}"
  expect_code 1 "$RUN_RC" "an unaccounted lane artifact must fail the step"
  assert_contains "$RUN_OUT" "fm-test-timing-brand-new" "the annotation must name the unaccounted lane"
  pass "a lane artifact nobody accounted for fails instead of being ignored"
}

# This job's own aggregate from a previous attempt is present in the download
# when only this job is re-run. It matches the lane naming convention but is not
# a lane, so it must not be mistaken for one.
test_ignored_self_artifact_is_not_a_lane() {
  local root script
  root=$(make_download_root selfartifact)
  mkdir -p "$root/fm-test-timing-aggregate"
  printf '%s\n' '{"kind":"aggregate"}' >"$root/fm-test-timing-aggregate/fm-test-timing-aggregate.json"
  script=$(install_stub selfartifact)
  run_collector "$script" "$root" "${LANES[@]}"
  expect_code 0 "$RUN_RC" "the job's own prior aggregate must not be counted as a lane: $RUN_OUT"
  assert_contains "$RUN_OUT" "lanes=3" "the prior aggregate must not inflate the lane count"
  pass "the job's own prior aggregate artifact is not mistaken for a lane"
}

# The collector cross-checks the number the humans actually read. If the
# aggregator itself ever reports fewer lanes than were collected, that is the
# same silent omission one layer down.
test_reported_lane_count_is_cross_checked() {
  local root script
  root=$(make_download_root underreport)
  script=$(install_stub underreport)
  # An assignment prefixing a function call persists in bash, so scope it by hand.
  export FM_STUB_FORCED_LANES=2
  run_collector "$script" "$root" "${LANES[@]}"
  unset FM_STUB_FORCED_LANES
  expect_code 1 "$RUN_RC" "a reported lane count below the expected lanes must fail"
  assert_contains "$RUN_OUT" "reported lanes=2" "the annotation must show the reported count"
  pass "an aggregate reporting fewer lanes than expected fails rather than being published"
}

test_usage_error_is_refused() {
  set +e
  RUN_OUT=$("$COLLECTOR" "$TMP_ROOT" 2>&1)
  RUN_RC=$?
  set -e
  expect_code 2 "$RUN_RC" "too few arguments must be a usage error"
  pass "an incomplete invocation is refused as a usage error"
}

test_nested_lane_json_is_collected
test_lane_contributing_no_json_fails_loudly
test_missing_lane_artifact_fails_loudly
test_unaccounted_lane_artifact_fails_loudly
test_ignored_self_artifact_is_not_a_lane
test_reported_lane_count_is_cross_checked
test_usage_error_is_refused
