#!/usr/bin/env bash
# fm-worker-env-exec.sh - run a worker's launch command with its firstmate
# home's .env credentials loaded.
#
# Usage: fm-worker-env-exec.sh <env-file> -- <command> [args...]
#        <command> may begin with NAME=value assignments, which are applied to
#        the command's environment exactly as a shell prefix would.
#
# bin/fm-spawn.sh puts this in front of every crewmate launch command. It exists
# because a worker's credentials must not depend on what shell the operator's
# panes happen to run.
#
# The first attempt at this sourced bin/fm-worker-env-lib.sh into the pane shell,
# the way fm-spawn delivers GOTMPDIR. That is wrong here, and measurably so: the
# panes on this machine run fish (herdr and tmux alike), fish cannot parse a
# POSIX shell library, and the load failed outright in a real spawn. A pane shell
# is whatever login shell the operator uses, so nothing typed into it may assume
# shell syntax beyond a bare command line. This is a program instead, and a
# program runs the same under fish, zsh, and bash.
#
# It is also why the values are not simply put on the launch command as
# assignment prefixes, which would work everywhere: that would print every
# credential into the pane text the agent reads and into `ps`. Nothing here ever
# writes a value anywhere. bin/fm-worker-env-lib.sh owns the parse and the rules
# about which names are eligible.
#
# `exec env "$@"` is what preserves the assignment prefixes fm-spawn has already
# built into the launch command (CHROME_DEVTOOLS_AXI_SESSION, FM_HOME for a
# secondmate, and so on): `env` applies leading NAME=value arguments itself, so
# wrapping the command does not change what it ends up with. `exec` keeps the
# process tree the same shape the backend and the turn-end guards expect - the
# agent remains the pane's own child, with no wrapper left in between.
#
# Failure is loud rather than silent: a missing env file is fine (a home need not
# have one, and a worker that lacks a key reports the missing credential itself),
# but a malformed invocation exits non-zero without running anything, so a broken
# wrapper can never be mistaken for a worker that simply had no credentials.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 3 ]; then
  echo "usage: fm-worker-env-exec.sh <env-file> -- <command> [args...]" >&2
  exit 2
fi

ENV_FILE=$1
shift
if [ "$1" != "--" ]; then
  echo "fm-worker-env-exec.sh: expected -- after the env file, got: $1" >&2
  exit 2
fi
shift

# shellcheck source=bin/fm-worker-env-lib.sh
. "$SCRIPT_DIR/fm-worker-env-lib.sh"
fm_worker_env_load "$ENV_FILE"

exec env "$@"
