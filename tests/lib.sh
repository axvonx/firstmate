#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- browser-session safety seam --------------------------------------------
#
# bin/fm-browser-lib.sh reclaims a task's chrome-devtools-axi session under
# $HOME/.chrome-devtools-axi by default, and many suites drive the real
# fm-teardown.sh and fm-watch.sh. Point every suite at a throwaway root instead,
# for the same reason the wedge-alarm recorder is installed in
# tests/wake-helpers.sh: it is impossible to forget, because sourcing this
# harness installs it, so no test - present or future - can stop a browser the
# developer or a live crewmate is using. A suite that seeds its own sessions
# still sets FM_BROWSER_STATE_ROOT per case, and that value wins.
# The path is DERIVED AND NEVER CREATED, because pointing the library at a root
# that does not exist is already the whole seam: retirement no-ops on a missing
# session directory and the sweep no-ops on a missing sessions/ directory. A
# mktemp here would leak one empty directory per run for every suite that
# installs its own EXIT trap and so never reaches fm_test_cleanup. It is still
# registered for removal, so a suite that does seed sessions under the inherited
# root cleans them up when it does call fm_test_cleanup.
if [ -z "${FM_BROWSER_STATE_ROOT:-}" ]; then
  _fm_browser_root="${TMPDIR:-/tmp}/fm-browser-root.$$"
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then trap fm_test_cleanup EXIT; fi
  FM_TEST_CLEANUP_DIRS+=("$_fm_browser_root")
  export FM_BROWSER_STATE_ROOT="$_fm_browser_root/.chrome-devtools-axi"
fi

# fm_test_fake_bridge_pid <dir> [session] - start a long-lived process this suite
# owns that stands in for a live bridge, and echo its pid. bin/fm-browser-lib.sh
# identifies a recorded pid in two parts: `ps -p <pid> -o command=` must name a
# chrome-devtools-axi-bridge - the same test chrome-devtools-axi itself applies, so
# a plain sleep stands in for a DEAD bridge rather than a live one - and the
# process's own environment must carry CHROME_DEVTOOLS_AXI_SESSION. This helper
# runs a script whose own path carries the bridge name, and puts <session> in that
# process's environment exactly as the real tool does at launch.
# Pass no session to get a bridge whose environment carries none, which is the
# refusal case the library reports as "none"; the variable is unset explicitly so
# an ambient value in the suite's own environment cannot leak into it.
# The stand-in runs under node where node exists, because that is what a real
# bridge runs under and because macOS hides the environment of a platform-signed
# interpreter such as /bin/sh even from its own user - a shell stand-in would read
# as "unreadable" there and prove the wrong thing. The shell form is the fallback
# for a host with no node, where /proc/<pid>/environ answers regardless.
# The caller kills the returned pid; it exits on its own within ~5 minutes.
fm_test_fake_bridge_pid() {
  local dir=$1 session=${2:-} script node_bin pid i=0
  mkdir -p "$dir"
  script="$dir/chrome-devtools-axi-bridge"
  if [ ! -x "$script" ]; then
    node_bin=$(command -v node 2>/dev/null) || node_bin=
    if [ -n "$node_bin" ]; then
      # An ABSOLUTE interpreter path, never `#!/usr/bin/env node`: env is itself a
      # platform binary, so a stand-in caught during that first exec would look
      # like a bridge with an unreadable environment and prove the wrong thing.
      printf '#!%s\nsetTimeout(function () { process.exit(0); }, 300000);\n' "$node_bin" > "$script"
    else
      cat > "$script" <<'SH'
#!/bin/sh
i=0
while [ "$i" -lt 600 ]; do
  sleep 0.5
  i=$((i + 1))
done
SH
    fi
    chmod +x "$script"
  fi
  # stdout and stderr are closed off the job deliberately: a background child
  # holding a caller's command substitution open would block it until the child
  # exited, which is the opposite of the point.
  if [ -n "$session" ]; then
    CHROME_DEVTOOLS_AXI_SESSION="$session" "$script" >/dev/null 2>&1 &
  else
    ( unset CHROME_DEVTOOLS_AXI_SESSION; exec "$script" ) >/dev/null 2>&1 &
  fi
  pid=$!
  # Return only once the process is actually identifiable, so a caller can drive
  # retirement immediately: until the exec completes, the pid still carries the
  # forking shell's command line and none of the environment asked for here.
  while [ "$i" -lt 100 ]; do
    if ps -p "$pid" -o command= 2>/dev/null | grep -q chrome-devtools-axi-bridge; then
      [ -n "$session" ] || break
      if fm_test_pid_environ "$pid" | grep -q "^CHROME_DEVTOOLS_AXI_SESSION=$session$"; then
        break
      fi
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

# fm_test_pid_environ <pid> - the process's environment, one VAR=value per line,
# by the same two readers bin/fm-browser-lib.sh uses. For fixture readiness only.
fm_test_pid_environ() {
  local pid=$1
  if [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null
  else
    ps eww -p "$pid" -o command= 2>/dev/null | tr ' ' '\n'
  fi
}

# fm_test_fake_blind_ps <fakebin> - install a ps stand-in that still answers the
# pid-is-a-bridge question but reports NO environment, so a suite can drive the
# library's "environment cannot be read" refusal without another user's process.
# Only meaningful where the library reads environments through ps: a host with
# /proc/<pid>/environ never consults ps for that, so a case using this must skip
# itself there (fm_test_ps_reads_environments below).
fm_test_fake_blind_ps() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = eww ] || [ "$arg" = e ]; then
    exit 0
  fi
done
for real in /bin/ps /usr/bin/ps; do
  [ -x "$real" ] && exec "$real" "$@"
done
exit 127
SH
  chmod +x "$fakebin/ps"
}

# fm_test_ps_reads_environments - true when this host identifies a process's
# environment through ps rather than /proc, which is what fm_test_fake_blind_ps
# can intercept.
fm_test_ps_reads_environments() {
  [ ! -r "/proc/$$/environ" ]
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
