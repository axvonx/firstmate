#!/usr/bin/env bash
# Tests for the worktree OWNERSHIP record - bin/fm-worktree-owner-lib.sh and the
# operator path back from a refusal, bin/fm-worktree-claim.sh.
#
# Why the record exists: a treehouse pool slot is reusable, so a task's recorded
# worktree can outlive its tenancy in it. bin/fm-teardown.sh's landed-work check
# answers "has THIS task's work landed" and passes correctly on a stale record,
# which is how cleanup reset a live lane's checkout on 2026-08-04. The record
# answers the other question - "does this task still occupy this worktree".
#
# Coverage here is the record's own contract plus the claim path; the refusal's
# effect on cleanup lives with cleanup, in tests/fm-teardown.test.sh.
#
# Matrix:
#   (a) write then verify with the same identity        -> ACCEPT
#   (b) a different task's record in the slot           -> REFUSE, names the task
#   (c) a different home's record in the slot           -> REFUSE, names the home
#   (d) a different token for the same task             -> REFUSE (slot reissued)
#   (e) no record at all                                -> REFUSE
#   (f) no token on the task's side                     -> REFUSE
#   (g) a truncated / non-v1 record                     -> REFUSE
#   (h) the record is invisible to git and unstageable  -> no dirty worktree
#   (i) another task's metadata naming the same worktree -> reported as a conflict
#   (j) claim without --confirm                          -> shows evidence, writes nothing
#   (k) claim --confirm                                  -> record written, meta updated
#   (l) claim over another task's record                 -> REFUSE, never overwritten
#   (m) claim while a second task records the worktree   -> REFUSE
#   (n) claim a worktree the task already returned        -> REFUSE, names the rerun
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-owner-lib.sh disable=SC1091
. "$ROOT/bin/fm-worktree-owner-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CLAIM="$ROOT/bin/fm-worktree-claim.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-owner-tests)

# A case dir with a project, a worktree of it, a home, and a state dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/other-home"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1 id=${2:-task-x1}
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

run_claim() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$CLAIM" "$@"
}

test_matching_identity_is_accepted() {
  local case_dir token
  case_dir=$(make_case accept)
  token=$(fm_worktree_owner_mint)
  fm_worktree_owner_write "$case_dir/home" task-x1 "$case_dir/wt" "$token" \
    || fail "accept: could not write the ownership record"
  fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" "$token" \
    || fail "accept: a record written for this task did not verify: $FM_WORKTREE_OWNER_REASON"
  pass "a worktree written for a task verifies as that task's"
}

test_another_tasks_record_is_refused_by_name() {
  local case_dir token
  case_dir=$(make_case other-task)
  token=$(fm_worktree_owner_mint)
  fm_worktree_owner_write "$case_dir/home" live-lane-b "$case_dir/wt" "$token" \
    || fail "other-task: could not write the ownership record"
  ! fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" "$token" \
    || fail "other-task: another task's record verified as ours"
  assert_contains "$FM_WORKTREE_OWNER_REASON" "names task live-lane-b, not task-x1" \
    "other-task: the reason did not name the disagreeing task"
  pass "a slot reissued to another task refuses and names that task"
}

test_another_homes_record_is_refused_by_name() {
  local case_dir token
  case_dir=$(make_case other-home)
  token=$(fm_worktree_owner_mint)
  fm_worktree_owner_write "$case_dir/other-home" task-x1 "$case_dir/wt" "$token" \
    || fail "other-home: could not write the ownership record"
  ! fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" "$token" \
    || fail "other-home: another home's record verified as ours"
  assert_contains "$FM_WORKTREE_OWNER_REASON" "names home" \
    "other-home: the reason did not name the disagreeing home"
  pass "a slot held by a sibling firstmate home refuses and names that home"
}

test_a_later_spawns_token_is_refused() {
  local case_dir first second
  case_dir=$(make_case token-mismatch)
  first=$(fm_worktree_owner_mint)
  second=$(fm_worktree_owner_mint)
  [ "$first" != "$second" ] || fail "token-mismatch: minted tokens collided"
  fm_worktree_owner_write "$case_dir/home" task-x1 "$case_dir/wt" "$second" \
    || fail "token-mismatch: could not write the ownership record"
  ! fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" "$first" \
    || fail "token-mismatch: a stale token verified"
  assert_contains "$FM_WORKTREE_OWNER_REASON" "ownership token does not match" \
    "token-mismatch: the reason did not name the token"
  pass "the same task id with a different spawn's token still refuses"
}

test_absent_record_is_refused() {
  local case_dir
  case_dir=$(make_case absent)
  ! fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" \
    aaaaaaaabbbbbbbbccccccccdddddddd \
    || fail "absent: a worktree with no record verified"
  assert_contains "$FM_WORKTREE_OWNER_REASON" "no ownership record at" \
    "absent: the reason did not say the record was missing"
  pass "a worktree carrying no ownership record refuses"
}

test_missing_task_token_is_refused() {
  local case_dir token
  case_dir=$(make_case no-task-token)
  token=$(fm_worktree_owner_mint)
  fm_worktree_owner_write "$case_dir/home" task-x1 "$case_dir/wt" "$token" \
    || fail "no-task-token: could not write the ownership record"
  # A record written before ownership proof existed has no token to match with,
  # so even a perfectly good record in the slot cannot be tied to it.
  ! fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" "" \
    || fail "no-task-token: a task with no recorded token verified"
  assert_contains "$FM_WORKTREE_OWNER_REASON" "no worktree ownership token" \
    "no-task-token: the reason did not say the task's token was missing"
  pass "a task record with no ownership token refuses rather than passing"
}

test_malformed_record_is_refused() {
  local case_dir record
  case_dir=$(make_case malformed)
  record=$(fm_worktree_owner_record_path "$case_dir/wt") \
    || fail "malformed: could not resolve the record path"
  printf 'fm-task-owner v1\ntask=task-x1\n' > "$record"
  ! fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" \
    aaaaaaaabbbbbbbbccccccccdddddddd \
    || fail "malformed: an incomplete record verified"
  assert_contains "$FM_WORKTREE_OWNER_REASON" "incomplete" \
    "malformed: the reason did not say the record was incomplete"
  printf 'fm-task-owner v99\n' > "$record"
  ! fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" \
    aaaaaaaabbbbbbbbccccccccdddddddd \
    || fail "malformed: a future-version record verified"
  pass "an unreadable ownership record refuses instead of being read as consent"
}

test_record_never_dirties_or_enters_a_commit() {
  local case_dir token staged
  case_dir=$(make_case invisible)
  token=$(fm_worktree_owner_mint)
  fm_worktree_owner_write "$case_dir/home" task-x1 "$case_dir/wt" "$token" \
    || fail "invisible: could not write the ownership record"
  [ -z "$(git -C "$case_dir/wt" status --porcelain)" ] \
    || fail "invisible: the ownership record dirtied the worktree"
  git -C "$case_dir/wt" add -A
  staged=$(git -C "$case_dir/wt" diff --cached --name-only)
  [ -z "$staged" ] || fail "invisible: 'git add -A' staged the ownership record: $staged"
  pass "the ownership record neither dirties a worktree nor can be committed"
}

test_conflicting_task_metadata_is_reported() {
  local case_dir found
  case_dir=$(make_case conflict)
  write_task_meta "$case_dir" task-x1
  write_task_meta "$case_dir" live-lane-b
  found=$(fm_worktree_owner_conflicting_task "$case_dir/home/state" task-x1 "$case_dir/wt") \
    || fail "conflict: a second task recording the same worktree was not reported"
  [ "$found" = live-lane-b ] || fail "conflict: reported '$found', expected live-lane-b"
  rm -f "$case_dir/home/state/live-lane-b.meta"
  ! fm_worktree_owner_conflicting_task "$case_dir/home/state" task-x1 "$case_dir/wt" >/dev/null \
    || fail "conflict: a lone task was reported as conflicting with itself"
  pass "two tasks' records naming one worktree are reported as a conflict"
}

test_claim_without_confirm_writes_nothing() {
  local case_dir out rc record
  case_dir=$(make_case claim-dry)
  write_task_meta "$case_dir"
  record=$(fm_worktree_owner_record_path "$case_dir/wt")

  set +e
  out=$(run_claim "$case_dir" task-x1 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "claim-dry: an unconfirmed claim must not report success"
  assert_contains "$out" "Nothing was written." "claim-dry: did not say nothing was written"
  assert_contains "$out" "--confirm" "claim-dry: did not state the confirming command"
  assert_contains "$out" "fm/task-x1" "claim-dry: did not show the worktree's branch as evidence"
  assert_absent "$record" "claim-dry: an unconfirmed claim wrote the ownership record"
  assert_no_grep worktree_token "$case_dir/home/state/task-x1.meta" \
    "claim-dry: an unconfirmed claim recorded a token"
  pass "a claim without --confirm shows the evidence and writes nothing"
}

test_claim_with_confirm_establishes_ownership() {
  local case_dir out token
  case_dir=$(make_case claim-confirm)
  write_task_meta "$case_dir"

  out=$(run_claim "$case_dir" task-x1 --confirm 2>&1) \
    || fail "claim-confirm: the claim failed: $out"
  assert_contains "$out" "claimed: task task-x1" "claim-confirm: did not report the claim"
  token=$(grep '^worktree_token=' "$case_dir/home/state/task-x1.meta" | cut -d= -f2-)
  [ -n "$token" ] || fail "claim-confirm: no token was recorded for the task"
  fm_worktree_owner_verify "$case_dir/home" task-x1 "$case_dir/wt" "$token" \
    || fail "claim-confirm: the claimed worktree does not verify: $FM_WORKTREE_OWNER_REASON"
  # Claiming twice must converge, not accumulate token lines.
  run_claim "$case_dir" task-x1 --confirm >/dev/null 2>&1 \
    || fail "claim-confirm: a second claim failed"
  [ "$(grep -c '^worktree_token=' "$case_dir/home/state/task-x1.meta")" = 1 ] \
    || fail "claim-confirm: repeated claims accumulated token lines"
  pass "a confirmed claim establishes ownership that cleanup can verify"
}

test_claim_never_overwrites_another_tasks_record() {
  local case_dir out rc token
  case_dir=$(make_case claim-foreign)
  write_task_meta "$case_dir"
  token=$(fm_worktree_owner_mint)
  fm_worktree_owner_write "$case_dir/home" live-lane-b "$case_dir/wt" "$token" \
    || fail "claim-foreign: could not seed the foreign record"

  set +e
  out=$(run_claim "$case_dir" task-x1 --confirm 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "claim-foreign: claiming another lane's worktree must refuse"
  assert_contains "$out" "already carries an ownership record for task live-lane-b" \
    "claim-foreign: refusal did not name the current owner"
  fm_worktree_owner_verify "$case_dir/home" live-lane-b "$case_dir/wt" "$token" \
    || fail "claim-foreign: the foreign record was altered"
  pass "a claim never overwrites another lane's ownership record"
}

test_claim_refuses_while_two_tasks_record_the_worktree() {
  local case_dir out rc
  case_dir=$(make_case claim-conflict)
  write_task_meta "$case_dir" task-x1
  write_task_meta "$case_dir" live-lane-b

  set +e
  out=$(run_claim "$case_dir" task-x1 --confirm 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "claim-conflict: claiming a doubly-recorded worktree must refuse"
  assert_contains "$out" "also recorded as task live-lane-b's worktree" \
    "claim-conflict: refusal did not name the conflicting task"
  pass "a claim refuses while two tasks record the same worktree"
}

test_claim_refuses_a_worktree_the_task_already_returned() {
  local case_dir out rc record
  case_dir=$(make_case claim-returned)
  write_task_meta "$case_dir" task-x1
  # What cleanup records the moment its worktree return succeeds. The pool may
  # already have reissued the slot, so a claim here would put a stale claim on
  # someone else's worktree and re-arm a cleanup that deliberately skips it.
  printf 'worktree_returned=1\n' >> "$case_dir/home/state/task-x1.meta"
  record=$(fm_worktree_owner_record_path "$case_dir/wt")

  set +e
  out=$(run_claim "$case_dir" task-x1 --confirm 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "claim-returned: claiming an already-returned worktree must refuse"
  assert_contains "$out" "already returned worktree" \
    "claim-returned: refusal did not say the worktree had gone back to the pool"
  assert_contains "$out" "rerun bin/fm-teardown.sh task-x1" \
    "claim-returned: refusal stated no way to finish the cleanup"
  assert_absent "$record" "claim-returned: the refused claim still wrote an ownership record"
  pass "a claim refuses a worktree this task already returned to the pool"
}

test_matching_identity_is_accepted
test_another_tasks_record_is_refused_by_name
test_another_homes_record_is_refused_by_name
test_a_later_spawns_token_is_refused
test_absent_record_is_refused
test_missing_task_token_is_refused
test_malformed_record_is_refused
test_record_never_dirties_or_enters_a_commit
test_conflicting_task_metadata_is_reported
test_claim_without_confirm_writes_nothing
test_claim_with_confirm_establishes_ownership
test_claim_never_overwrites_another_tasks_record
test_claim_refuses_while_two_tasks_record_the_worktree
test_claim_refuses_a_worktree_the_task_already_returned
