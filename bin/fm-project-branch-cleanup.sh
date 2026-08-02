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
# Exactly one result line is printed to stdout:
#   BRANCH_CLEANUP: already on for <owner/repo>
#   BRANCH_CLEANUP: enabled for <owner/repo>
#   BRANCH_CLEANUP_BLOCKED: <owner/repo|path>: <reason>
# and, when the repository also allows merge commits or rebase merges, one
# advisory line:
#   BRANCH_CLEANUP_INFO: <owner/repo> also allows <methods>; squash-only merges
#   are a separate decision and are not changed here
#
# A missing gh, an unreachable or non-GitHub remote, and a lack of administration
# rights are all reported as BRANCH_CLEANUP_BLOCKED and still exit 0: plenty of
# repositories cannot be configured by the account that clones them (a read-only
# upstream reached through a fork, for example), and that must never fail adding
# the project. Exit 2 is reserved for a usage or precondition error - a missing
# argument or a path that is not a Git working tree.
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
git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "error: $PROJ is not a Git working tree" >&2; exit 2; }

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

# One read of the fields this script decides on. gh resolves the repository from
# the clone's own remotes, so a non-GitHub or missing remote fails here with the
# CLI's own reason instead of being guessed at.
VIEW_FIELDS=nameWithOwner,deleteBranchOnMerge,mergeCommitAllowed,rebaseMergeAllowed
VIEW_QUERY='[.nameWithOwner, (.deleteBranchOnMerge|tostring), (.mergeCommitAllowed|tostring), (.rebaseMergeAllowed|tostring)] | @tsv'

read_settings() {
  ( cd "$PROJ" && gh_run repo view --json "$VIEW_FIELDS" -q "$VIEW_QUERY" ) 2>&1
}

if ! view=$(read_settings); then
  blocked "$PROJ" "$(first_error_line "$view")"
fi
IFS=$'\t' read -r REPO ON MERGE_OK REBASE_OK <<EOF
$view
EOF
[ -n "${REPO:-}" ] \
  || blocked "$PROJ" "the GitHub CLI did not report a repository for this clone"

# The advisory is printed for every outcome that identified the repository, so a
# blocked cleanup still tells the captain what the merge posture is.
report_merge_methods() {
  local methods=
  if [ "${MERGE_OK:-}" = true ]; then
    methods="merge commits"
  fi
  if [ "${REBASE_OK:-}" = true ]; then
    methods="${methods:+$methods and }rebase merges"
  fi
  [ -n "$methods" ] || return 0
  printf 'BRANCH_CLEANUP_INFO: %s also allows %s; squash-only merges are a separate decision and are not changed here\n' \
    "$REPO" "$methods"
}
report_merge_methods

if [ "$ON" = true ]; then
  printf 'BRANCH_CLEANUP: already on for %s\n' "$REPO"
  exit 0
fi

if ! edit=$( ( cd "$PROJ" && gh_run repo edit "$REPO" --delete-branch-on-merge ) 2>&1 ); then
  blocked "$REPO" "$(first_error_line "$edit")"
fi

# Verify rather than trust the edit's exit status: the setting is what matters,
# and a re-read is the only evidence that it took.
if ! view=$(read_settings); then
  blocked "$REPO" "the setting could not be confirmed: $(first_error_line "$view")"
fi
IFS=$'\t' read -r _ ON _ _ <<EOF
$view
EOF
[ "$ON" = true ] \
  || blocked "$REPO" "the setting did not take effect"

printf 'BRANCH_CLEANUP: enabled for %s\n' "$REPO"
