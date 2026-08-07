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
#   . <root>/bin/fm-worker-env-lib.sh && fm_worker_env_exportable_count <home>/.env
#
# The second form answers "would a worker get anything from this file?" without
# loading it, and is how bin/fm-brief.sh keeps a generated brief's claim about
# where credentials live tied to this file's own eligibility rules.
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
# 3. It refuses to export names that would rewrite the shell it is loading into,
#    and the interpreters that shell starts. A `.env` reaching a worker is a
#    fleet-wide input read by every future worker, so it is a new path for PATH,
#    DYLD_INSERT_LIBRARIES, or BASH_ENV to redirect what the worker executes -
#    and GIT_SSH_COMMAND, PERL5LIB, PYTHONSTARTUP, RUBYOPT, and ZDOTDIR do the
#    same one level down. Those names are rejected outright rather than trusted
#    to be well-meaning. NODE_OPTIONS is the one name where both outright answers
#    are wrong, so its VALUE is allowlisted instead; see
#    fm_worker_env_value_refused.
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
#
# The last group is the interpreter-level equivalent of the first, and belongs
# here for the same reason: GIT_SSH_COMMAND redirects git-over-ssh exactly the
# way BASH_ENV redirects the shell, and PERL5LIB, PYTHONSTARTUP, RUBYOPT, and
# ZDOTDIR each hand an interpreter or a login shell a file of someone else's
# choosing, in every project a worker touches rather than in one command.
fm_worker_env_forbidden() {
  case "$1" in
    PATH|HOME|SHELL|USER|LOGNAME|IFS|ENV|BASH_ENV) return 0 ;;
    PS1|PS2|PS4|PROMPT_COMMAND|SHELLOPTS|BASHOPTS) return 0 ;;
    GLOBIGNORE|CDPATH|LD_PRELOAD|LD_LIBRARY_PATH) return 0 ;;
    DYLD_*) return 0 ;;
    GIT_SSH_COMMAND|PERL5LIB|PYTHONSTARTUP|RUBYOPT|ZDOTDIR) return 0 ;;
  esac
  return 1
}

# fm_worker_env_value_refused <name> <value> - true when the name is eligible but
# THIS VALUE would redirect what an interpreter loads.
#
# NODE_OPTIONS is the one name where refusing it outright and allowing it
# outright are both wrong. This machine's documented long-run practice sets
# --max-old-space-size deliberately, so a blanket refusal breaks a real workflow,
# while allowing the name wholesale leaves `--require=/tmp/x.js` - and `--import`
# and `--experimental-loader` - free to load a file into every node process a
# worker starts. Allowlisting the VALUE is neither of those policy calls: it is a
# mechanical check that every token is the one option that names no file.
fm_worker_env_value_refused() {
  case "$1" in
    NODE_OPTIONS)
      fm_worker_env_node_options_allowed "$2" && return 1
      return 0
      ;;
  esac
  return 1
}

# fm_worker_env_node_options_allowed <value> - true when every
# whitespace-separated token is --max-old-space-size=<digits>, so anything
# carrying --require, --import, --experimental-loader, or any other option is
# refused as a whole rather than filtered down. Tokens are split by hand rather
# than by an unquoted expansion, for the reason recorded above: word splitting
# differs between bash and zsh, and this file runs under both.
fm_worker_env_node_options_allowed() {
  local rest=${1:-} token size
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 0
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      --max-old-space-size=*) size=${token#--max-old-space-size=} ;;
      *) return 1 ;;
    esac
    case "$size" in
      ''|*[!0-9]*) return 1 ;;
    esac
  done
}

# fm_worker_env_each <env-file> <action> - walk the file once and run
# `<action> <name> <value>` for every assignment eligible to cross into a worker.
#
# The parse, the FM_*/FMX_* exclusion, the refused names, and the refused values
# live here and nowhere else. A second caller that only wants to know WHETHER a
# file would give a worker anything (bin/fm-brief.sh, deciding whether to tell a
# worker its credentials are already in its environment) asks through this walker
# rather than re-deriving the rules and drifting from what a worker really gets.
#
# <action> is the only thing that ever receives a value; nothing in this library
# writes one anywhere, so a caller outside it passes an action that counts.
#
# Tolerates the same shapes as bin/fm-x-lib.sh's fmx_env_get: a leading
# `export `, surrounding whitespace, and one layer of matching single or double
# quotes. Later assignments win, matching that reader and dotenv convention.
# Returns 0 for an absent or unreadable file: a home with no `.env` is the
# ordinary case, not an error, and a worker that needs a key it did not get
# reports the missing credential itself.
#
# Prints nothing at all on the happy path. Unusable lines are summarized on
# stderr by line number, and a refused value by the NAME it was declared for, so
# a malformed or rejected file is diagnosable without any of its content being
# echoed.
fm_worker_env_each() {
  local file=${1:-} action=${2:-} line key val bad="" refused="" lineno=0
  [ -n "$file" ] && [ -n "$action" ] || return 0
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
    if fm_worker_env_value_refused "$key" "$val"; then
      refused="$refused $key"
      continue
    fi
    "$action" "$key" "$val"
  done < "$file"
  if [ -n "$bad" ]; then
    echo "fm-worker-env: skipped unusable line(s) in $file:$bad" >&2
  fi
  if [ -n "$refused" ]; then
    echo "fm-worker-env: refused the declared value for name(s) in $file:$refused" >&2
  fi
  return 0
}

# The action fm_worker_env_load walks with. Separate so the walker never has to
# know whether its caller wants the value or only the count.
# shellcheck disable=SC2329 # Invoked indirectly as fm_worker_env_each's action.
fm_worker_env_export_pair() {
  export "$1=$2"
}

# fm_worker_env_load <env-file> - export every eligible KEY=VALUE from the file.
# The contract above is this function's contract; it is the walker's only
# value-consuming caller, and bin/fm-worker-env-exec.sh's only entry point.
fm_worker_env_load() {
  fm_worker_env_each "${1:-}" fm_worker_env_export_pair
}

FM_WORKER_ENV_COUNT=0

# shellcheck disable=SC2329 # Invoked indirectly as fm_worker_env_each's action.
fm_worker_env_count_pair() {
  FM_WORKER_ENV_COUNT=$((FM_WORKER_ENV_COUNT + 1))
}

# fm_worker_env_exportable_count <env-file> - how many names this file would put
# into a worker's environment. Prints a count and nothing else: never a name,
# never a value, and no diagnostic, because the caller is generating a document
# rather than launching a worker. A file that declares only FM_*/FMX_* names, or
# only refused ones, counts zero - which is the question bin/fm-brief.sh has to
# answer before telling a worker its variables are simply there.
fm_worker_env_exportable_count() {
  FM_WORKER_ENV_COUNT=0
  fm_worker_env_each "${1:-}" fm_worker_env_count_pair 2>/dev/null
  printf '%s\n' "$FM_WORKER_ENV_COUNT"
}
