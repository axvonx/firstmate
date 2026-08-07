#!/usr/bin/env bash
# fm-worker-env-lib.sh - load a firstmate home's .env credentials into a shell.
#
# Sourced by bin/fm-worker-env-exec.sh, which bin/fm-spawn.sh puts in front of
# every crewmate launch command, so the agent and every child it starts inherit
# the home's credentials without any value ever appearing on a command line, in
# the pane text, in `ps` output, or in a metadata record.
#
# Usage:
#   . <root>/bin/fm-worker-env-lib.sh && fm_worker_env_load <home>/.env
#
# Deliberately NOT sourced into a crewmate's pane shell, though that was the
# first design: pane shells are whatever login shell the operator runs, this
# machine's are fish, and fish cannot parse this file at all. The wrapper program
# is what makes the mechanism shell-agnostic.
#
# Why this exists: credentials used to be set machine-wide with `launchctl
# setenv`, so every GUI process on the machine inherited them and a crewmate got
# them by accident. They now live in one mode-600 gitignored `.env` per firstmate
# home, which no long-lived tmux/herdr daemon inherits, so a pane shell has to be
# told. Without this step, clearing the launchctl values strands every worker at
# once.
#
# Three properties this function is responsible for, in priority order.
#
# 1. It never prints a credential value, on any path. `.env` is parsed here
#    rather than sourced, because `set -a; . .env` hands the file to bash as
#    shell, and bash reports a syntax error by echoing the offending line - which
#    is a credential value, printed into the pane the agent reads. A line this
#    parser cannot use is reported by LINE NUMBER only, never by content.
#
# 2. It refuses to export firstmate's own namespace. `.env` is also where a home
#    keeps FMX_PAIRING_TOKEN, which is X mode's relay consent and thread binding.
#    That token authorizes posting in public as the captain, and AGENTS.md
#    section 14 reserves it to the one home that holds it, so handing it to every
#    crewmate would be a real escalation of what a worker can do. Any FM_* or
#    FMX_* name is therefore skipped: `.env` carries third-party credentials for
#    workers plus firstmate's own configuration, and only the former crosses into
#    a worker. fm-spawn sets the FM_* variables a worker legitimately needs on
#    the launch command itself, so nothing is lost by skipping them here.
#
# 3. It refuses to export names that would rewrite the shell it is loading into.
#    A `.env` reaching a worker's interactive shell is a new path for PATH,
#    DYLD_INSERT_LIBRARIES, or BASH_ENV to redirect what the worker executes, so
#    those names are rejected outright rather than trusted to be well-meaning.
#
# `.env` wins over an already-set value. During the migration a key can be in
# both `.env` and the ambient environment, and the ambient copy is the one being
# retired; letting a stale ambient value silently shadow the declared one is the
# exact confusion this change removes.

# Every construct below is plain POSIX shell that behaves identically in bash,
# zsh, and dash, and no unquoted parameter expansion is relied on for word
# splitting. An earlier revision kept the name list below in a string and looped
# over it unquoted; bash word-split it and zsh did not, so under zsh the loop
# compared the whole string once, matched nothing, and exported PATH straight out
# of the file. A `case` pattern has no such difference. The wrapper that sources
# this runs under bash, but keeping the library shell-neutral costs nothing and
# removes a class of defect that only shows up in one interpreter.

# fm_worker_env_forbidden <name> - true when <name> must not be exported,
# because exporting it changes what the shell resolves, loads, or executes
# rather than what a command authenticates with.
fm_worker_env_forbidden() {
  case "$1" in
    PATH|HOME|SHELL|USER|LOGNAME|IFS|ENV|BASH_ENV) return 0 ;;
    PS1|PS2|PS4|PROMPT_COMMAND|SHELLOPTS|BASHOPTS) return 0 ;;
    GLOBIGNORE|CDPATH|LD_PRELOAD|LD_LIBRARY_PATH) return 0 ;;
    DYLD_*) return 0 ;;
  esac
  return 1
}

# fm_worker_env_load <env-file> - export every eligible KEY=VALUE from the file.
#
# Tolerates the same shapes as bin/fm-x-lib.sh's fmx_env_get: a leading
# `export `, surrounding whitespace, and one layer of matching single or double
# quotes. Later assignments win, matching that reader and dotenv convention.
# Returns 0 for an absent or unreadable file: a home with no `.env` is the
# ordinary case, not an error, and a worker that needs a key it did not get
# reports the missing credential itself.
#
# Prints nothing at all on the happy path. Skipped and unusable lines are
# summarized on stderr by count and line number so a malformed file is
# diagnosable without any of its content being echoed.
fm_worker_env_load() {
  local file=${1:-} line key val bad="" lineno=0
  [ -n "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      export[[:space:]]*)
        line=${line#export}
        line=${line#"${line%%[![:space:]]*}"}
        ;;
    esac
    case "$line" in
      *=*) ;;
      *) bad="$bad $lineno"; continue ;;
    esac
    key=${line%%=*}
    key=${key%"${key##*[![:space:]]}"}
    val=${line#*=}
    val=${val#"${val%%[![:space:]]*}"}
    case "$key" in
      [A-Za-z_]*) ;;
      *) bad="$bad $lineno"; continue ;;
    esac
    case "$key" in
      *[!A-Za-z0-9_]*) bad="$bad $lineno"; continue ;;
    esac
    case "$key" in
      FM_*|FMX_*) continue ;;
    esac
    fm_worker_env_forbidden "$key" && continue
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    export "$key=$val"
  done < "$file"
  if [ -n "$bad" ]; then
    echo "fm-worker-env: skipped unusable line(s) in $file:$bad" >&2
  fi
  return 0
}
