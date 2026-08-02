#!/usr/bin/env bash
# Tests for bin/fm-project-branch-cleanup.sh: the initialization step that keeps
# firstmate's trunk-based branch-cleanup chain fully armed by verifying, and
# setting when needed, the forge's delete-branch-on-merge behavior.
#
# Matrix:
#   (a) already on: reported, and no edit is attempted
#   (b) off: turned on, verified by re-read, and reported as enabled
#   (c) no administration rights: reported as blocked, exit 0, add still proceeds
#   (d) gh missing: reported as blocked, exit 0
#   (e) an edit that silently does not take is reported as blocked
#   (f) other allowed merge methods are reported, never changed
#   (g) usage and precondition errors exit 2, a nested directory included
#   (h) a fork clone arms its own repository, names the parent it leaves alone,
#       and says which head branches nothing in the chain deletes
#   (i) a gh warning on a zero exit is never parsed as repository data
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CLEANUP="$ROOT/bin/fm-project-branch-cleanup.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-branch-cleanup-tests)

# Build one case sandbox: a project clone plus a fakebin holding a gh mock whose
# behavior is driven by files the test writes, and which logs every invocation.
#
# The mock's view answer is read fresh from state/delete-on-merge on every call,
# so a successful edit can flip it exactly the way the real forge would. It
# answers for the clone's own repository and carries state/parent, the way gh
# reports a fork.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin" "$case_dir/state"
  fm_git_init_commit "$case_dir/project"
  printf 'an-org/a-repo\n' > "$case_dir/state/clone-repo"
  printf -- '-\n' > "$case_dir/state/parent"
  printf 'false\n' > "$case_dir/state/delete-on-merge"
  printf 'true\n' > "$case_dir/state/edit-ok"
  printf 'false\n' > "$case_dir/state/edit-applies"
  printf 'false\n' > "$case_dir/state/merge-commit"
  printf 'false\n' > "$case_dir/state/rebase-merge"
  : > "$case_dir/state/view-warning"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
state='$case_dir/state'
printf '%s\n' "\$*" >> "\$state/gh.log"
case "\${1:-} \${2:-}" in
  "repo view")
    [ -s "\$state/view-warning" ] && cat "\$state/view-warning" >&2
    printf '%s\t%s\t%s\t%s\t%s\n' \\
      "\$(cat "\$state/clone-repo")" \\
      "\$(cat "\$state/parent")" \\
      "\$(cat "\$state/delete-on-merge")" \\
      "\$(cat "\$state/merge-commit")" \\
      "\$(cat "\$state/rebase-merge")"
    exit 0
    ;;
  "repo edit")
    if [ "\$(cat "\$state/edit-ok")" != true ]; then
      echo 'HTTP 403: Resource not accessible by integration' >&2
      exit 1
    fi
    [ "\$(cat "\$state/edit-applies")" = true ] && printf 'true\n' > "\$state/delete-on-merge"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/state/gh.log"
  printf '%s\n' "$case_dir"
}

run_cleanup() {
  local case_dir=$1 rc=0; shift
  PATH="$case_dir/fakebin:$PATH" "$CLEANUP" "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  printf '%s\n' "$rc"
}

test_already_on_is_reported_without_editing() {
  local case_dir rc out
  case_dir=$(make_case already-on)
  printf 'true\n' > "$case_dir/state/delete-on-merge"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "already-on"
  assert_contains "$out" 'BRANCH_CLEANUP: already on for an-org/a-repo' \
    "already-on must report the verified setting"
  assert_no_grep 'repo edit' "$case_dir/state/gh.log" \
    "already-on must not attempt an edit"
  pass "a repository that already deletes merged branches is verified, not re-set"
}

test_off_is_turned_on_and_verified() {
  local case_dir rc out
  case_dir=$(make_case turn-on)
  printf 'true\n' > "$case_dir/state/edit-applies"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "turn-on"
  assert_contains "$out" 'BRANCH_CLEANUP: enabled for an-org/a-repo' \
    "turn-on must report the change"
  assert_grep 'repo edit an-org/a-repo --delete-branch-on-merge' "$case_dir/state/gh.log" \
    "turn-on must issue the delete-branch-on-merge edit"
  [ "$(grep -c 'repo view' "$case_dir/state/gh.log")" = 2 ] \
    || fail "turn-on must re-read the setting to verify the edit took"
  pass "a repository with the setting off is turned on and verified by re-read"
}

test_no_permission_reports_and_does_not_fail() {
  local case_dir rc out
  case_dir=$(make_case no-permission)
  printf 'false\n' > "$case_dir/state/edit-ok"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "no-permission must not fail the project add"
  assert_contains "$out" 'BRANCH_CLEANUP_BLOCKED: an-org/a-repo:' \
    "no-permission must name the repository it could not configure"
  assert_contains "$out" 'HTTP 403' \
    "no-permission must carry the forge's own reason"
  assert_not_contains "$out" 'BRANCH_CLEANUP: ' \
    "no-permission must not also claim success"
  pass "a repository the account cannot administer is reported, not failed"
}

test_missing_gh_reports_and_does_not_fail() {
  local case_dir rc out
  case_dir=$(make_case no-gh)
  rm -f "$case_dir/fakebin/gh"
  # A PATH holding only the tools the script legitimately needs - its own
  # interpreter included - so the gh lookup genuinely finds nothing.
  local tool
  for tool in bash git sed; do
    ln -sf "$(command -v "$tool")" "$case_dir/fakebin/$tool"
  done
  rc=0
  PATH="$case_dir/fakebin" "$CLEANUP" "$case_dir/project" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "missing gh must not fail the project add"
  assert_contains "$out" 'BRANCH_CLEANUP_BLOCKED:' "missing gh must be reported"
  assert_contains "$out" 'GitHub CLI (gh) is not installed' \
    "missing gh must name the missing tool"
  pass "a missing GitHub CLI is reported as a blocker, not a failure"
}

test_edit_that_does_not_take_is_blocked() {
  local case_dir rc out
  case_dir=$(make_case edit-no-effect)
  # edit exits 0 but never flips the setting: the re-read must catch it.

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "edit-no-effect"
  assert_contains "$out" 'BRANCH_CLEANUP_BLOCKED: an-org/a-repo: the setting did not take effect' \
    "a silently ineffective edit must not be reported as enabled"
  pass "an edit that exits clean without taking effect is reported as blocked"
}

test_other_merge_methods_are_reported_not_changed() {
  local case_dir rc out
  case_dir=$(make_case merge-methods)
  printf 'true\n' > "$case_dir/state/merge-commit"
  printf 'true\n' > "$case_dir/state/rebase-merge"
  printf 'true\n' > "$case_dir/state/edit-applies"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "merge-methods"
  assert_contains "$out" 'BRANCH_CLEANUP_INFO: an-org/a-repo also allows merge commits and rebase merges' \
    "other allowed merge methods must be surfaced"
  assert_no_grep 'enable-squash-merge' "$case_dir/state/gh.log" \
    "merge methods must never be changed by this step"
  assert_no_grep 'enable-merge-commit' "$case_dir/state/gh.log" \
    "merge methods must never be changed by this step"
  assert_no_grep 'enable-rebase-merge' "$case_dir/state/gh.log" \
    "merge methods must never be changed by this step"
  pass "a repository's other merge methods are reported and left alone"
}

test_fork_clone_arms_itself_and_reports_the_parent() {
  local case_dir rc out
  case_dir=$(make_case fork-clone)
  printf 'a-user/a-repo\n' > "$case_dir/state/clone-repo"
  printf 'an-org/a-repo\n' > "$case_dir/state/parent"
  printf 'true\n' > "$case_dir/state/edit-applies"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "fork-clone"
  assert_contains "$out" 'BRANCH_CLEANUP: enabled for a-user/a-repo' \
    "a fork clone must arm the repository it resolves to, which it can administer"
  assert_grep 'repo edit a-user/a-repo --delete-branch-on-merge' "$case_dir/state/gh.log" \
    "the edit must address the clone's own repository"
  assert_no_grep 'repo edit an-org/a-repo' "$case_dir/state/gh.log" \
    "a parent the account may not administer must never be edited"
  assert_contains "$out" 'BRANCH_CLEANUP_INFO: a-user/a-repo is a fork of an-org/a-repo' \
    "the fork shape must be reported so the parent is not mistaken for armed"
  assert_contains "$out" 'governed by the setting on an-org/a-repo, which this script does not change' \
    "the advisory must say who governs a pull request merged into the parent"
  assert_contains "$out" 'a head branch pushed to a-user/a-repo for a pull request merged into an-org/a-repo is deleted by neither that setting nor the gh --delete-branch flag' \
    "the relayed line must name the head branches that nothing deletes, scoped to the merges that leave them"
  assert_contains "$out" 'removed by hand until separate work lands' \
    "the relayed line must say who is left holding that cleanup"
  pass "a fork clone arms its own repository and reports the parent and the uncovered head branches"
}

test_gh_warning_on_success_is_not_parsed_as_data() {
  local case_dir rc out
  case_dir=$(make_case stderr-warning)
  printf 'true\n' > "$case_dir/state/edit-applies"
  printf 'warning: a note the CLI prints on a clean exit\n' > "$case_dir/state/view-warning"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "stderr-warning"
  assert_contains "$out" 'BRANCH_CLEANUP: enabled for an-org/a-repo' \
    "a warning beside a zero exit must not disturb the parsed repository"
  assert_not_contains "$out" 'warning: a note the CLI prints' \
    "a warning must never be reported as a repository or a reason"
  assert_grep 'repo edit an-org/a-repo --delete-branch-on-merge' "$case_dir/state/gh.log" \
    "the edit must address the repository, never the warning text"
  pass "a GitHub CLI warning on a zero exit is kept out of the parsed data"
}

test_usage_and_precondition_errors() {
  local case_dir rc
  case_dir=$(make_case usage)

  rc=$(run_cleanup "$case_dir")
  expect_code 2 "$rc" "no argument must be a usage error"

  rc=$(run_cleanup "$case_dir" "$case_dir/does-not-exist")
  expect_code 2 "$rc" "a missing path must be a precondition error"

  mkdir -p "$case_dir/not-a-repo"
  rc=$(run_cleanup "$case_dir" "$case_dir/not-a-repo")
  expect_code 2 "$rc" "a non-Git directory must be a precondition error"

  # A directory nested inside a clone is not a clone: projects live inside the
  # firstmate checkout, so accepting one would configure the fleet repository.
  mkdir -p "$case_dir/project/nested"
  rc=$(run_cleanup "$case_dir" "$case_dir/project/nested")
  expect_code 2 "$rc" "a directory below the working-tree root must be a precondition error"

  assert_no_grep 'repo view' "$case_dir/state/gh.log" \
    "a precondition error must not reach the forge"
  pass "usage and precondition errors exit 2 without touching the forge"
}

test_already_on_is_reported_without_editing
test_off_is_turned_on_and_verified
test_no_permission_reports_and_does_not_fail
test_missing_gh_reports_and_does_not_fail
test_edit_that_does_not_take_is_blocked
test_other_merge_methods_are_reported_not_changed
test_fork_clone_arms_itself_and_reports_the_parent
test_gh_warning_on_success_is_not_parsed_as_data
test_usage_and_precondition_errors
