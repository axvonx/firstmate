#!/usr/bin/env bash
# Verify, and set when needed, the GitHub "delete branch on merge" setting for a
# project clone, so firstmate's trunk-based branch-cleanup chain is never left
# half-armed.
#
# The chain is: squash merge (bin/fm-pr-merge.sh) -> forge deletes the remote
# branch -> the local upstream reads [gone] -> bin/fm-fleet-sync.sh prunes the
# local branch, and bin/fm-teardown.sh deletes the task branch after its
# landed-work test. Only the forge step lives outside this repo, and with it off
# both remote branches and their locals accumulate while every script still
# reports success.
#
# Usage: fm-project-branch-cleanup.sh <project-path>
#
# The setting is armed on the repository the clone's origin remote points at, and
# only on that one. When the clone is a fork, the parent is never edited, because
# plenty of parents cannot be administered by the account that cloned them.
# GitHub deletes only a head branch that lives in the repository the pull request
# merged into, which is what the fork advisory below reports, so an operator
# reading only the relayed lines still learns what that leaves uncovered.
#
# Exactly one result line is printed to stdout:
#   BRANCH_CLEANUP: already on for <owner/repo>
#   BRANCH_CLEANUP: enabled for <owner/repo>
#   BRANCH_CLEANUP_BLOCKED: <owner/repo|path>: <reason>
# and, when the clone is a fork, or the repository's merge posture is worth
# knowing, one advisory line each:
#   BRANCH_CLEANUP_INFO: <owner/repo> is a fork of <owner/repo>; a pull request
#   merged into the parent is governed by the setting on the parent, which this
#   script does not change; a head branch pushed to the fork for a pull request
#   merged into the parent is deleted by neither that setting nor the gh
#   --delete-branch flag, so it has to be removed by hand until separate work
#   lands
#   BRANCH_CLEANUP_INFO: <owner/repo> allows squash merges and also allows
#   <methods>; squash-only merges are a separate decision and are not changed
#   here
#   BRANCH_CLEANUP_INFO: <owner/repo> does not allow squash merges, which
#   bin/fm-pr-merge.sh uses by default; <what it does allow>; merge methods are a
#   separate decision and are not changed here
#
# A missing gh, a missing, unreachable, or non-GitHub origin remote, and a lack
# of administration rights are all reported as BRANCH_CLEANUP_BLOCKED and still
# exit 0: plenty of repositories cannot be configured by the account that clones
# them (a read-only upstream reached through a fork, for example), and that must
# never fail adding the project. Exit 2 is reserved for a usage or precondition
# error - a missing argument or a path that is not the root of a Git working tree.
#
# This script never changes a repository's allowed merge methods. Turning a
# repository squash-only is a stronger change than branch cleanup and belongs
# behind its own explicit decision, so it is reported and left alone.
set -eu

usage() {
  echo "usage: fm-project-branch-cleanup.sh <project-path>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
PROJ=$1
case "$PROJ" in
  -*) usage ;;
esac

[ -d "$PROJ" ] || { echo "error: $PROJ is not a directory" >&2; exit 2; }
# The path must be a clone's own root, not merely somewhere inside a Git working
# tree. Projects live under the firstmate checkout, so a half-made or empty
# projects/<name> would otherwise satisfy a plain rev-parse and send every
# lookup below to the fleet repository's own remotes.
PROJ_TOP=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) || PROJ_TOP=
PROJ_ABS=$(cd "$PROJ" && pwd -P) || PROJ_ABS=
[ -n "$PROJ_TOP" ] && [ -n "$PROJ_ABS" ] \
  && [ "$(cd "$PROJ_TOP" 2>/dev/null && pwd -P)" = "$PROJ_ABS" ] \
  || { echo "error: $PROJ is not the root of a Git working tree" >&2; exit 2; }

blocked() {
  printf 'BRANCH_CLEANUP_BLOCKED: %s: %s\n' "$1" "$2"
  exit 0
}

# First line of a captured CLI error, trimmed, so one diagnostic line stays one
# line. A silent failure yields a generic reason rather than an empty one.
first_error_line() {
  local line
  line=$(printf '%s\n' "$1" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}')
  printf '%s' "${line:-the GitHub CLI failed without a message}"
}

gh_run() {
  GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

command -v gh >/dev/null 2>&1 \
  || blocked "$PROJ" "the GitHub CLI (gh) is not installed"

# gh's stdout is parsed as data, so its stderr is kept in a file of its own: a
# warning printed alongside a zero exit must never be read back as a repository
# name, and a failure must still carry the CLI's own reason.
GH_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-project-branch-cleanup.XXXXXX" 2>/dev/null) \
  || blocked "$PROJ" "a temporary file for the GitHub CLI's diagnostics could not be created"
trap 'rm -f "$GH_ERR"' EXIT

gh_in_project() {
  ( cd "$PROJ" && gh_run "$@" ) 2>"$GH_ERR"
}

gh_error() {
  first_error_line "$(cat "$GH_ERR" 2>/dev/null || true)"
}

# The target is pinned to the clone's origin remote and never left to gh's own
# base-repository resolution, because gh derives that base from the remote
# layout: it ranks upstream above github above origin, and `gh repo fork --clone`
# additionally writes remote.upstream.gh-resolved=base. So in an origin=fork with
# upstream=parent layout an unpinned `gh repo view` answers for the parent, and
# then the edit below would touch a repository this script promises never to
# touch, the fork advisory would never fire because the resolved parent is not
# itself a fork, and the success line would name the parent while the fork the
# rest of the chain tracks stayed unarmed. A tool must not infer intent from
# remote layout. origin is the remote bin/fm-fleet-sync.sh fetches and prunes
# against, and the project-management skill already requires it for both armed
# delivery modes, so naming it adds no precondition.
ORIGIN_URL=$(git -C "$PROJ" remote get-url origin 2>/dev/null) || ORIGIN_URL=
[ -n "$ORIGIN_URL" ] \
  || blocked "$PROJ" "the clone has no origin remote, so there is no repository to configure"

# One read of the fields this script decides on, answered for origin, so a
# non-GitHub or unreachable remote fails here with the CLI's own reason instead
# of being guessed at.
VIEW_FIELDS=nameWithOwner,parent,deleteBranchOnMerge,squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed
VIEW_QUERY='[.nameWithOwner, (if .parent then (.parent.owner.login // "") + "/" + (.parent.name // "") else "-" end), (.deleteBranchOnMerge|tostring), (.squashMergeAllowed|tostring), (.mergeCommitAllowed|tostring), (.rebaseMergeAllowed|tostring)] | @tsv'

read_settings() {
  gh_in_project repo view "$ORIGIN_URL" --json "$VIEW_FIELDS" -q "$VIEW_QUERY"
}

if ! view=$(read_settings); then
  blocked "$PROJ" "$(gh_error)"
fi
# Tab is IFS whitespace, so an empty field would collapse into its neighbour and
# shift every value after it; the query emits "-" for a repository with no
# parent rather than an empty field.
IFS=$'\t' read -r REPO PARENT ON SQUASH_OK MERGE_OK REBASE_OK <<EOF
$view
EOF
[ -n "${REPO:-}" ] \
  || blocked "$PROJ" "the GitHub CLI did not report a repository for this clone"

# The advisories are printed for every outcome that identified the repository, so
# a blocked cleanup still tells the captain what the posture is.
report_fork_parent() {
  case "${PARENT:-}" in
    ?*/?*) ;;
    *) return 0 ;;
  esac
  printf 'BRANCH_CLEANUP_INFO: %s is a fork of %s; a pull request merged into %s is governed by the setting on %s, which this script does not change; a head branch pushed to %s for a pull request merged into %s is deleted by neither that setting nor the gh --delete-branch flag, so it has to be removed by hand until separate work lands\n' \
    "$REPO" "$PARENT" "$PARENT" "$PARENT" "$REPO" "$PARENT"
}

report_merge_methods() {
  local methods='' allowed
  if [ "${MERGE_OK:-}" = true ]; then
    methods="merge commits"
  fi
  if [ "${REBASE_OK:-}" = true ]; then
    methods="${methods:+$methods and }rebase merges"
  fi
  # bin/fm-pr-merge.sh merges with --squash by default, so a repository that
  # disallows squash merges fails at merge time, and initialization is the
  # cheapest place to learn it. That posture is reported on its own line rather
  # than as an "also", which would claim the squash method the repository does not
  # have.
  if [ "${SQUASH_OK:-}" != true ]; then
    allowed="it reports no other merge method either"
    [ -z "$methods" ] || allowed="it allows $methods"
    printf 'BRANCH_CLEANUP_INFO: %s does not allow squash merges, which bin/fm-pr-merge.sh uses by default; %s; merge methods are a separate decision and are not changed here\n' \
      "$REPO" "$allowed"
    return 0
  fi
  [ -n "$methods" ] || return 0
  printf 'BRANCH_CLEANUP_INFO: %s allows squash merges and also allows %s; squash-only merges are a separate decision and are not changed here\n' \
    "$REPO" "$methods"
}
report_fork_parent
report_merge_methods

if [ "${ON:-}" = true ]; then
  printf 'BRANCH_CLEANUP: already on for %s\n' "$REPO"
  exit 0
fi

if ! gh_in_project repo edit "$REPO" --delete-branch-on-merge >/dev/null; then
  blocked "$REPO" "$(gh_error)"
fi

# Verify rather than trust the edit's exit status: the setting is what matters,
# and a re-read is the only evidence that it took.
if ! view=$(read_settings); then
  blocked "$REPO" "the setting could not be confirmed: $(gh_error)"
fi
IFS=$'\t' read -r _ _ ON _ _ _ <<EOF
$view
EOF
[ "${ON:-}" = true ] \
  || blocked "$REPO" "the setting did not take effect"

printf 'BRANCH_CLEANUP: enabled for %s\n' "$REPO"
