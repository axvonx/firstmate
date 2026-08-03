#!/usr/bin/env bash
# fm-test-timing-aggregate.sh - collect every CI lane's timing JSON from a
# downloaded artifact tree and aggregate it, refusing to aggregate a partial
# fleet.
#
# Why this exists: the aggregate's whole job is to say when a lane is
# approaching its time budget. A collector that silently skips a lane turns the
# one number meant to warn us into the number hiding it, and it reads as
# coverage while providing none. This wrapper therefore accounts for every
# expected lane by name and fails loudly rather than aggregating what it
# happened to find.
#
# The concrete drop this guards against: actions/upload-artifact stores paths
# relative to the least common ancestor of everything it is given. A lane that
# uploads its timing JSON alongside diagnostics from a sibling directory (the
# Herdr lane does) gets its JSON nested one level deeper inside the artifact
# than a lane that uploads the JSON alone. A non-recursive glob over the
# download root matches the flat lanes and misses the nested one.
#
# Usage:
#   fm-test-timing-aggregate.sh [--ignore <artifact>]... \
#     <download-root> <out.json> <lane-artifact>...
#
# Arguments:
#   <download-root>   directory holding one subdirectory per downloaded
#                     artifact, as actions/download-artifact writes it WITHOUT
#                     `merge-multiple`. Per-artifact subdirectories are what
#                     make each lane individually accountable; merging them
#                     erases the identity this script checks.
#   <out.json>        aggregate timing JSON to write
#   <lane-artifact>   name of an artifact each lane job uploads, one argument
#                     per lane the workflow defines. Every one must be present
#                     and must contain a timing JSON.
#
# Options:
#   --ignore <artifact>  a downloaded artifact matching the lane naming
#                        convention that is deliberately not a lane. Needed for
#                        this job's own previously uploaded aggregate, which is
#                        present in the download when only this job is re-run.
#                        Repeatable.
#
# Exit status:
#   0    every expected lane was found and aggregated
#   1    a lane was missing, contributed no timing JSON, arrived unexpectedly,
#        or the aggregate reported a different lane count than was collected
#   2    usage error
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

die() { printf 'fm-test-timing-aggregate: %s\n' "$*" >&2; exit 2; }
annotate() { printf '::error::%s\n' "$*" >&2; }

IGNORED=()
while [ "$#" -gt 0 ]; do
  case $1 in
    --ignore)
      [ "$#" -ge 2 ] || die "--ignore requires an artifact name"
      IGNORED+=("$2")
      shift 2
      ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

[ "$#" -ge 3 ] || die "usage: fm-test-timing-aggregate.sh [--ignore <artifact>]... <download-root> <out.json> <lane-artifact>..."

DOWNLOAD_ROOT=$1
OUT=$2
shift 2
EXPECTED=("$@")

[ -d "$DOWNLOAD_ROOT" ] || die "download root not found: $DOWNLOAD_ROOT"

# Collect each expected lane's timing JSON by name. Searching beneath the
# lane's own artifact directory is what makes the depth of the JSON inside the
# artifact irrelevant, so a future upload that adds a sibling diagnostics path
# cannot quietly drop the lane.
inputs=()
failed=0
for lane in "${EXPECTED[@]}"; do
  lane_dir="$DOWNLOAD_ROOT/$lane"
  if [ ! -d "$lane_dir" ]; then
    annotate "timing lane '$lane' uploaded no artifact; refusing to aggregate a partial fleet"
    failed=1
    continue
  fi
  lane_inputs=()
  while IFS= read -r -d '' found; do
    lane_inputs+=("$found")
  done < <(find "$lane_dir" -type f -name 'fm-test-timing-*.json' -print0 | LC_ALL=C sort -z)
  if [ "${#lane_inputs[@]}" -eq 0 ]; then
    annotate "timing lane '$lane' contains no fm-test-timing-*.json; its artifact layout changed"
    failed=1
    continue
  fi
  inputs+=("${lane_inputs[@]}")
done

# An artifact matching the lane naming convention that nobody expected means a
# lane was added to the workflow without being added to this accounting, which
# is the same silent-omission defect seen from the other side.
while IFS= read -r -d '' dir; do
  name=$(basename "$dir")
  for known in "${EXPECTED[@]}" ${IGNORED[@]+"${IGNORED[@]}"}; do
    [ "$name" = "$known" ] && continue 2
  done
  annotate "unexpected timing artifact '$name' is not an accounted lane; add it to the aggregate's lane list"
  failed=1
done < <(find "$DOWNLOAD_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'fm-test-timing-*' -print0 | LC_ALL=C sort -z)

[ "$failed" -eq 0 ] || exit 1

summary=$("$ROOT/bin/fm-test-run.sh" --aggregate-json "$OUT" "${inputs[@]}" | tee /dev/stderr)

# The reported lane count is the number the humans read. Pin it against the
# lanes actually collected so a change inside the aggregator cannot reintroduce
# a silent omission downstream of this collection.
reported=$(printf '%s\n' "$summary" | sed -n 's/.*FM_TEST_AGGREGATE lanes=\([0-9][0-9]*\).*/\1/p' | head -n1)
if [ -z "$reported" ]; then
  annotate "aggregate produced no FM_TEST_AGGREGATE lane count to verify"
  exit 1
fi
if [ "$reported" -ne "${#EXPECTED[@]}" ]; then
  annotate "aggregate reported lanes=$reported but ${#EXPECTED[@]} lanes were expected"
  exit 1
fi

printf 'FM_TEST_TIMING_LANES ok lanes=%s\n' "$reported"
