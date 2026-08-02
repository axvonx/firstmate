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
#   (j) an origin=fork with upstream=parent layout is read and armed on origin,
#       never on the upstream parent
#   (k) a repository that disallows the default squash merge is reported
#   (l) a read that fails is blocked against the project path, before any edit
#   (m) a clone with no origin remote is blocked, not failed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CLEANUP="$ROOT/bin/fm-project-branch-cleanup.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-branch-cleanup-tests)

# Build one case sandbox: a project clone with an origin remote, plus a fakebin
# holding a gh mock whose behavior is driven by files the test writes, and which
# logs every invocation.
#
# The mock answers per repository, the way the forge does. state/origin-repo names
# the repository origin resolves to, and the state files describe that one; any
# other repository is answered only from a canned line under state/other-repos,
# so a case can give a second repository a different posture. A view or edit that
# names no repository is refused, because a call that leaves the target to gh's
# remote-layout resolution is exactly the defect the pin exists to prevent.
#
# The origin answer's delete-on-merge is read fresh on every call, so a successful
# edit can flip it exactly the way the real forge would, and state/parent is
# carried the way gh reports a fork.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin" "$case_dir/state/other-repos"
  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" remote add origin 'https://github.com/an-org/a-repo.git'
  printf 'an-org/a-repo\n' > "$case_dir/state/origin-repo"
  printf -- '-\n' > "$case_dir/state/parent"
  printf 'false\n' > "$case_dir/state/delete-on-merge"
  printf 'true\n' > "$case_dir/state/view-ok"
  printf 'true\n' > "$case_dir/state/edit-ok"
  printf 'false\n' > "$case_dir/state/edit-applies"
  printf 'true\n' > "$case_dir/state/squash-merge"
  printf 'false\n' > "$case_dir/state/merge-commit"
  printf 'false\n' > "$case_dir/state/rebase-merge"
  : > "$case_dir/state/view-warning"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
state='$case_dir/state'
printf '%s\n' "\$*" >> "\$state/gh.log"

# owner/repo for an explicit gh repository argument, empty when the argument is
# absent or is a flag.
repo_key() {
  local arg=\${1:-} key
  case "\$arg" in
    ''|-*) printf '%s' ''; return 0 ;;
  esac
  key=\${arg#https://github.com/}
  key=\${key%.git}
  printf '%s' "\$key"
}

target=\$(repo_key "\${3:-}")
case "\${1:-} \${2:-}" in
  "repo view"|"repo edit")
    if [ -z "\$target" ]; then
      echo "error: gh \$1 \$2 named no repository, so gh would resolve one from the remote layout" >&2
      exit 1
    fi
    ;;
esac
case "\${1:-} \${2:-}" in
  "repo view")
    if [ "\$(cat "\$state/view-ok")" != true ]; then
      echo 'HTTP 401: Bad credentials (https://api.github.com/graphql)' >&2
      exit 1
    fi
    [ -s "\$state/view-warning" ] && cat "\$state/view-warning" >&2
    if [ "\$target" != "\$(cat "\$state/origin-repo")" ]; then
      other="\$state/other-repos/\$(printf '%s' "\$target" | tr / %)"
      if [ -f "\$other" ]; then
        cat "\$other"
        exit 0
      fi
      echo "HTTP 404: Could not resolve to a Repository named \$target" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \\
      "\$(cat "\$state/origin-repo")" \\
      "\$(cat "\$state/parent")" \\
      "\$(cat "\$state/delete-on-merge")" \\
      "\$(cat "\$state/squash-merge")" \\
      "\$(cat "\$state/merge-commit")" \\
      "\$(cat "\$state/rebase-merge")"
    exit 0
    ;;
  "repo edit")
    if [ "\$target" != "\$(cat "\$state/origin-repo")" ]; then
      echo "HTTP 403: Must have admin rights to Repository \$target" >&2
      exit 1
    fi
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

# Point the clone's origin at <owner/repo> and make the mock answer for it, so a
# case can move origin without the two drifting apart.
set_origin() {
  local case_dir=$1 repo=$2
  git -C "$case_dir/project" remote set-url origin "https://github.com/$repo.git"
  printf '%s\n' "$repo" > "$case_dir/state/origin-repo"
}

# Give a repository other than origin its own answer: <owner/repo> plus the
# parent, delete-on-merge, squash, merge-commit, and rebase fields the script
# reads.
set_other_repo() {
  local case_dir=$1 repo=$2 line=$3
  printf '%s\n' "$line" > "$case_dir/state/other-repos/$(printf '%s' "$repo" | tr / %)"
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
  assert_contains "$out" 'BRANCH_CLEANUP_INFO: an-org/a-repo allows squash merges and also allows merge commits and rebase merges' \
    "the advisory must name the verified squash posture alongside the other allowed methods"
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
  set_origin "$case_dir" a-user/a-repo
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

test_upstream_parent_layout_is_read_and_armed_on_origin() {
  local case_dir rc out
  case_dir=$(make_case fork-upstream-layout)
  # The layout gh resolves the wrong way round on its own: origin is the fork the
  # rest of the chain pushes to and prunes against, upstream is the parent, and gh
  # ranks upstream first. The parent answers with the setting already on, so a
  # read that drifted there would report success while the fork stayed unarmed.
  set_origin "$case_dir" a-user/a-repo
  git -C "$case_dir/project" remote add upstream 'https://github.com/an-org/a-repo.git'
  set_other_repo "$case_dir" an-org/a-repo "$(printf 'an-org/a-repo\t-\ttrue\ttrue\tfalse\tfalse')"
  printf 'an-org/a-repo\n' > "$case_dir/state/parent"
  printf 'true\n' > "$case_dir/state/edit-applies"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "fork-upstream-layout"
  assert_grep 'repo view https://github.com/a-user/a-repo' "$case_dir/state/gh.log" \
    "the read must be pinned to the origin remote"
  assert_no_grep 'repo view https://github.com/an-org/a-repo' "$case_dir/state/gh.log" \
    "an upstream parent must never be the repository this step reads"
  assert_no_grep 'repo edit an-org/a-repo' "$case_dir/state/gh.log" \
    "a parent the account may not administer must never be edited"
  assert_grep 'repo edit a-user/a-repo --delete-branch-on-merge' "$case_dir/state/gh.log" \
    "the edit must address the repository origin points at"
  assert_contains "$out" 'BRANCH_CLEANUP: enabled for a-user/a-repo' \
    "the armed repository must be the one the prune chain tracks"
  assert_not_contains "$out" 'already on for an-org/a-repo' \
    "the parent's posture must never be reported as this clone's result"
  assert_contains "$out" 'BRANCH_CLEANUP_INFO: a-user/a-repo is a fork of an-org/a-repo' \
    "the fork advisory must still fire, which it cannot if the parent is resolved instead"
  pass "an origin=fork with upstream=parent layout is read and armed on origin alone"
}

test_squash_disallowed_is_reported() {
  local case_dir rc out
  case_dir=$(make_case no-squash)
  printf 'false\n' > "$case_dir/state/squash-merge"
  printf 'true\n' > "$case_dir/state/merge-commit"
  printf 'true\n' > "$case_dir/state/edit-applies"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "no-squash"
  assert_contains "$out" 'BRANCH_CLEANUP_INFO: an-org/a-repo does not allow squash merges' \
    "a repository that cannot take the default merge method must be surfaced at initialization"
  assert_contains "$out" 'it allows merge commits' \
    "the advisory must name the methods the repository does allow"
  assert_not_contains "$out" 'also allows' \
    "squash must not be implied as available when the repository disallows it"
  assert_contains "$out" 'BRANCH_CLEANUP: enabled for an-org/a-repo' \
    "the merge posture is advisory and must not hold up arming branch cleanup"
  assert_no_grep 'enable-squash-merge' "$case_dir/state/gh.log" \
    "merge methods must never be changed by this step"
  pass "a repository that disallows the default squash merge is reported, not changed"
}

test_failed_read_is_blocked_against_the_project_path() {
  local case_dir rc out
  case_dir=$(make_case view-blocked)
  printf 'false\n' > "$case_dir/state/view-ok"

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "a read that fails must not fail the project add"
  assert_contains "$out" "BRANCH_CLEANUP_BLOCKED: $case_dir/project:" \
    "a read that never named the repository must be labelled with the project path"
  assert_contains "$out" 'HTTP 401' \
    "the blocker must carry the forge's own reason"
  assert_not_contains "$out" 'BRANCH_CLEANUP: ' \
    "a failed read must not also claim success"
  assert_not_contains "$out" 'BRANCH_CLEANUP_INFO: ' \
    "no posture can be advised about a repository that was never read"
  assert_no_grep 'repo edit' "$case_dir/state/gh.log" \
    "a failed read must never be followed by an edit"
  pass "a read the forge refuses is reported against the project path, before any edit"
}

test_missing_origin_remote_is_blocked() {
  local case_dir rc out
  case_dir=$(make_case no-origin)
  git -C "$case_dir/project" remote remove origin

  rc=$(run_cleanup "$case_dir" "$case_dir/project")
  out=$(cat "$case_dir/stdout")

  expect_code 0 "$rc" "a clone with no origin must not fail the project add"
  assert_contains "$out" "BRANCH_CLEANUP_BLOCKED: $case_dir/project: the clone has no origin remote" \
    "a clone with no origin must be reported against the project path"
  assert_no_grep 'repo view' "$case_dir/state/gh.log" \
    "with no origin to name there is nothing to ask the forge about"
  pass "a clone with no origin remote is reported as a blocker, not guessed at"
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
test_upstream_parent_layout_is_read_and_armed_on_origin
test_squash_disallowed_is_reported
test_failed_read_is_blocked_against_the_project_path
test_missing_origin_remote_is_blocked
test_gh_warning_on_success_is_not_parsed_as_data
test_usage_and_precondition_errors
