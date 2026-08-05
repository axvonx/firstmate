#!/usr/bin/env bash
# tests/fm-browser-lib.test.sh - the per-task browser-session contract owned by
# bin/fm-browser-lib.sh: session-name derivation, the home-scoped ownership
# guard that decides what this home may reclaim, retirement of one session, and
# the bounded orphan sweep.
#
# Everything here is driven through the library's public functions and through
# the real bin/fm-teardown.sh, never by reading the implementation's source.
# Two layers:
#   - hermetic cases point FM_BROWSER_STATE_ROOT at the case directory and shim
#     chrome-devtools-axi and the bridge /health probe in a fakebin, so no case
#     can read or write the real ~/.chrome-devtools-axi, reach a real bridge, or
#     disturb another actor's browser;
#   - one death case launches a REAL named throwaway browser session, SIGKILLs
#     the simulated worker without any cleanup, and proves teardown reclaims the
#     detached bridge together with its chrome-devtools-mcp and Chrome children.
#     It runs against the real tool end to end, so it is also the case that
#     proves the real bridge answers the identity probe with its own session name.
#     That case skips cleanly when no browser can be launched.
#
# Session names are derived from a temp firstmate home, so every real session
# this file creates carries a digest unique to its own throwaway directory: it
# can never name, stop, or remove the shared default session, another firstmate
# home's session, or any other tool's session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-browser-lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-lib-tests)
BASE_PATH=$PATH
fm_git_identity fmtest fmtest@example.invalid

# Real sessions and long-lived helper processes this file started, so a failure
# midway still leaves no bridge running and no orphaned sleeper behind.
LIVE_SESSION_NAME=
LIVE_SESSION_HOME=
LIVE_BRIDGE_PIDS=
HELPER_PIDS=

browser_test_cleanup() {
  local p
  # A case may have narrowed PATH to prove the missing-CLI path; restore it so a
  # failure there can still stop a real session this file started.
  PATH=$BASE_PATH
  if [ -n "$LIVE_SESSION_NAME" ] && [ -n "$LIVE_SESSION_HOME" ] \
     && command -v chrome-devtools-axi >/dev/null 2>&1; then
    HOME="$LIVE_SESSION_HOME" CHROME_DEVTOOLS_AXI_SESSION="$LIVE_SESSION_NAME" \
      chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  # Backstop for a real bridge this file started whose session state is already
  # gone, so `stop` can no longer find it. A bridge is its own process-group
  # leader, and the identity check keeps a recycled pid from ever being hit.
  for p in $LIVE_BRIDGE_PIDS; do
    if kill -0 "$p" 2>/dev/null \
       && ps -o command= -p "$p" 2>/dev/null | grep -q chrome-devtools-axi-bridge; then
      kill -9 -"$p" 2>/dev/null || kill -9 "$p" 2>/dev/null || true
    fi
  done
  for p in $HELPER_PIDS; do
    kill -9 "$p" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap browser_test_cleanup EXIT

# --- fixtures ---------------------------------------------------------------

# make_browser_case <name>: a hermetic case directory with its own firstmate
# home, state dir, chrome-devtools-axi state root, and fakebin. Echoes the dir.
make_browser_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/root/sessions" "$dir/fakebin"
  printf '%s\n' "$dir"
}

# use_case_env <case-dir> [KEY=VAL ...]: point the library at this case's state
# root and fakebin, and install the /health stand-in every case needs, because a
# live bridge is identified by what it reports about itself and no case may reach
# a real one. Set as real environment rather than as an assignment prefix,
# because a prefix on a bash FUNCTION call persists after the call returns and
# would leak one case's PATH and state root into the next.
use_case_env() {
  local dir=$1 kv
  shift
  PATH="$dir/fakebin:$BASE_PATH"
  unset FM_FAKE_CDA_STOP FM_FAKE_CDA_EXIT FM_BROWSER_SWEEP_MAX FM_BROWSER_STOP_TIMEOUT
  export PATH
  export FM_BROWSER_STATE_ROOT="$dir/root"
  export FM_FAKE_CDA_LOG="$dir/cda.log"
  : > "$FM_FAKE_CDA_LOG"
  fm_test_fake_health_curl "$dir/fakebin" "$dir/health"
  for kv in "$@"; do
    export "${kv?}"
  done
}

# say_session_is <case-dir> <port> <session-or-body>: what the fake bridge on
# <port> reports for itself when the library probes it.
say_session_is() {
  fm_test_fake_health_answer "$1/health" "$2" "$3"
}

# install_cda_shim <case-dir>: a chrome-devtools-axi stand-in that records the
# session it was invoked for and simulates one stop outcome.
#   FM_FAKE_CDA_LOG   file receiving "<session>|<argv>" per invocation
#   FM_FAKE_CDA_STOP  kill (default) terminates the recorded bridge pid and
#                     removes the pid file; noop leaves the bridge running
#   FM_FAKE_CDA_EXIT  exit status (default 0)
install_cda_shim() {
  local case_dir=$1
  cat > "$case_dir/fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s|%s\n' "${CHROME_DEVTOOLS_AXI_SESSION:-}" "$*" >> "${FM_FAKE_CDA_LOG:-/dev/null}"
if [ "${1:-}" = stop ] && [ "${FM_FAKE_CDA_STOP:-kill}" = kill ]; then
  pidfile="${FM_BROWSER_STATE_ROOT:-}/sessions/${CHROME_DEVTOOLS_AXI_SESSION:-}/bridge.pid"
  if [ -f "$pidfile" ]; then
    pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$pidfile" | head -1)
    [ -z "$pid" ] || kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  fi
fi
exit "${FM_FAKE_CDA_EXIT:-0}"
SH
  chmod +x "$case_dir/fakebin/chrome-devtools-axi"
}

# make_session_dir <case-dir> <name> [pid] [port]: create a session state
# directory, with a bridge.pid naming <pid> and <port> when a pid is given. The
# port defaults to one nothing answers on, so a session is unidentifiable until a
# case says otherwise through say_session_is.
make_session_dir() {
  local case_dir=$1 name=$2 pid=${3:-} port=${4:-9999}
  mkdir -p "$case_dir/root/sessions/$name"
  [ -z "$pid" ] || printf '{"pid":%s,"port":%s}\n' "$pid" "$port" \
    > "$case_dir/root/sessions/$name/bridge.pid"
}

# start_helper_pid: a live process this file owns that PASSES the bridge
# identity check, so it stands in for a live bridge. Echoes its pid; the caller
# records it in HELPER_PIDS (this runs in a command substitution, so it cannot
# record it itself).
start_helper_pid() {
  fm_test_fake_bridge_pid "$TMP_ROOT/fake-bridge"
}

# start_bystander_pid: a live process this file owns that FAILS the bridge
# identity check, standing in for an unrelated process that inherited a recycled
# pid. Echoes its pid; the caller records it in HELPER_PIDS.
start_bystander_pid() {
  # stdout and stderr are closed off the job deliberately: a background child
  # holding this command substitution's pipe open would block the caller until
  # the child exited, which is the whole point of keeping it alive.
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# reaped_pid: echo a pid that is provably not running (started and reaped here).
reaped_pid() {
  local pid i=0
  while [ "$i" -lt 20 ]; do
    ( exit 0 ) &
    pid=$!
    wait "$pid" 2>/dev/null || true
    kill -0 "$pid" 2>/dev/null || { printf '%s\n' "$pid"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# repeat_char <count> <char>: a string of <count> copies of <char>.
repeat_char() {
  local n=$1 c=$2 out=''
  while [ "${#out}" -lt "$n" ]; do out="$out$c"; done
  printf '%s' "${out:0:$n}"
}

# assert_valid_session_name <name> <label>: the name must satisfy the charset,
# the length, and the not-all-dots rule chrome-devtools-axi itself enforces.
assert_valid_session_name() {
  local name=$1 label=$2
  [ -n "$name" ] || fail "$label: empty session name"
  [ "${#name}" -le 64 ] || fail "$label: session name is ${#name} characters, over the 64 limit: $name"
  case "$name" in
    *[!A-Za-z0-9._-]*) fail "$label: session name carries a character chrome-devtools-axi rejects: $name" ;;
  esac
  case "$name" in
    *[!.]*) : ;;
    *) fail "$label: session name is all dots, which chrome-devtools-axi rejects: $name" ;;
  esac
}

# --- session-name derivation ------------------------------------------------

test_session_name_is_deterministic_and_scoped_to_its_home() {
  local dir a b first second other
  dir=$(make_browser_case name-basics)
  a="$dir/home"
  b="$dir/other-home"
  mkdir -p "$b"

  first=$(fm_browser_session_name "$a" task-alpha) || fail "name-basics: derivation failed for a valid id"
  second=$(fm_browser_session_name "$a" task-alpha) || fail "name-basics: second derivation failed"
  [ "$first" = "$second" ] || fail "name-basics: derivation is not deterministic ($first vs $second)"
  assert_valid_session_name "$first" name-basics
  case "$first" in
    fm-*) : ;;
    *) fail "name-basics: name does not carry the firstmate marker: $first" ;;
  esac
  case "$first" in
    *task-alpha) : ;;
    *) fail "name-basics: a short task id was not carried verbatim: $first" ;;
  esac

  other=$(fm_browser_session_name "$b" task-alpha) || fail "name-basics: derivation failed for the second home"
  [ "$other" != "$first" ] || fail "name-basics: two homes derived one name for the same task id: $first"
  assert_valid_session_name "$other" name-basics-other
  pass "session names are deterministic per home and disjoint across homes"
}

test_long_ids_clamp_to_the_limit_and_stay_distinct() {
  local dir home long_a long_b name_a name_b shared
  dir=$(make_browser_case name-clamp)
  home="$dir/home"

  shared=$(repeat_char 50 q)
  long_a="$shared-alpha-tail-one"
  long_b="$shared-alpha-tail-two"
  name_a=$(fm_browser_session_name "$home" "$long_a") || fail "name-clamp: long id a was refused"
  name_b=$(fm_browser_session_name "$home" "$long_b") || fail "name-clamp: long id b was refused"
  assert_valid_session_name "$name_a" name-clamp-a
  assert_valid_session_name "$name_b" name-clamp-b
  [ "${#name_a}" -eq 64 ] \
    || fail "name-clamp: a clamped name should fill the 64-character budget, got ${#name_a} ($name_a)"
  [ "$name_a" != "$name_b" ] \
    || fail "name-clamp: two long ids sharing a 50-character prefix collided on $name_a"
  pass "over-long task ids clamp to exactly 64 characters and stay distinct"
}

test_no_two_task_ids_share_a_session_name() {
  local dir home id name names=''
  dir=$(make_browser_case name-injective)
  home="$dir/home"

  for id in \
    a \
    ab \
    a.b \
    task-1 \
    task-10 \
    "$(repeat_char 51 z)" \
    "$(repeat_char 52 z)" \
    "$(repeat_char 53 z)" \
    "$(repeat_char 64 z)" \
    "$(repeat_char 51 z)a" \
    "$(repeat_char 43 y)-one" \
    "$(repeat_char 43 y)-two" \
    "$(repeat_char 60 y)-one" \
    "$(repeat_char 60 y)-two"
  do
    name=$(fm_browser_session_name "$home" "$id") || fail "name-injective: a valid task id was refused: $id"
    assert_valid_session_name "$name" "name-injective ($id)"
    case "$names" in
      *"|$name|"*) fail "name-injective: two task ids derived the same session name: $name" ;;
    esac
    names="$names|$name|"
  done
  pass "distinct task ids, short and clamped alike, never share a session name"
}

test_underivable_inputs_return_failure_with_no_output() {
  local dir home out rc bad
  dir=$(make_browser_case name-invalid)
  home="$dir/home"

  for bad in '' '.hidden' 'a/b' 'a b' 'a;b' "a\$b" '..'; do
    rc=0
    out=$(fm_browser_session_name "$home" "$bad") || rc=$?
    [ "$rc" -ne 0 ] || fail "name-invalid: derivation accepted an unsafe task id: '$bad'"
    [ -z "$out" ] || fail "name-invalid: refused id '$bad' still printed '$out'"
  done

  rc=0
  out=$(fm_browser_session_name '' task-alpha) || rc=$?
  [ "$rc" -ne 0 ] || fail "name-invalid: derivation accepted an empty home"
  [ -z "$out" ] || fail "name-invalid: an empty home still printed '$out'"
  pass "an unsafe task id or a missing home yields failure and no session name"
}

# --- ownership guard --------------------------------------------------------

test_retire_refuses_every_name_this_home_does_not_own() {
  local dir home foreign_home name foreign over_long candidate
  dir=$(make_browser_case retire-refuse)
  home="$dir/home"
  foreign_home="$dir/foreign-home"
  mkdir -p "$foreign_home"
  install_cda_shim "$dir"
  use_case_env "$dir"

  name=$(fm_browser_session_name "$home" task-owned)
  foreign=$(fm_browser_session_name "$foreign_home" task-owned)
  over_long="$name$(repeat_char $((65 - ${#name})) x)"

  make_session_dir "$dir" "$foreign" 999999
  make_session_dir "$dir" default 999999
  make_session_dir "$dir" fm-brief-evidence 999999
  make_session_dir "$dir" fm-gpu-on 999999
  make_session_dir "$dir" "$over_long" 999999

  for candidate in '' default fm-brief-evidence fm-gpu-on "$foreign" "$over_long" 'fm-../escape'; do
    fm_browser_retire "$home" "$candidate" \
      || fail "retire-refuse: refusing '$candidate' must still return success"
    [ "$FM_BROWSER_RETIRED" = 0 ] \
      || fail "retire-refuse: reported reclaiming the foreign session '$candidate'"
  done

  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "retire-refuse: a foreign name reached the browser CLI:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  assert_present "$dir/root/sessions/$foreign" "retire-refuse: another home's session directory was removed"
  assert_present "$dir/root/sessions/default" "retire-refuse: the shared default session directory was removed"
  assert_present "$dir/root/sessions/fm-brief-evidence" "retire-refuse: a foreign bare-fm- session was removed"
  assert_present "$dir/root/sessions/fm-gpu-on" "retire-refuse: a foreign bare-fm- session was removed"
  assert_present "$dir/root/sessions/$over_long" "retire-refuse: an over-length name was acted on"
  pass "retirement refuses the default session, foreign fm- names, another home's sessions, and malformed names"
}

# --- retirement -------------------------------------------------------------

test_retire_reclaims_a_dead_session_without_touching_the_cli() {
  local dir home name dead
  dir=$(make_browser_case retire-dead)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"
  dead=$(reaped_pid) || fail "retire-dead: could not obtain a provably dead pid"

  name=$(fm_browser_session_name "$home" task-dead)
  make_session_dir "$dir" "$name" "$dead"

  fm_browser_retire "$home" "$name" > "$dir/out" 2> "$dir/err" \
    || fail "retire-dead: retirement returned failure"
  [ ! -s "$dir/out" ] || fail "retire-dead: retirement wrote to stdout:"$'\n'"$(cat "$dir/out")"
  [ ! -s "$dir/err" ] || fail "retire-dead: retirement wrote to stderr:"$'\n'"$(cat "$dir/err")"
  [ "$FM_BROWSER_RETIRED" = 1 ] || fail "retire-dead: a dead-pid session was not reported reclaimed"
  [ -z "$FM_BROWSER_ERROR" ] || fail "retire-dead: a quiet reclaim still reported an error: $FM_BROWSER_ERROR"
  assert_absent "$dir/root/sessions/$name" "retire-dead: the stale session directory survived"
  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "retire-dead: a dead bridge still cost a browser call:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  [ ! -s "$dir/health/requests.log" ] \
    || fail "retire-dead: a dead bridge was still probed:"$'\n'"$(cat "$dir/health/requests.log")"

  # Idempotent: a second pass has nothing to reclaim and still succeeds quietly.
  fm_browser_retire "$home" "$name" || fail "retire-dead: the repeat pass returned failure"
  [ "$FM_BROWSER_RETIRED" = 0 ] || fail "retire-dead: the repeat pass claimed a second reclaim"
  [ ! -s "$FM_FAKE_CDA_LOG" ] || fail "retire-dead: the repeat pass reached the browser CLI"
  pass "a session whose bridge is already dead reclaims with no browser call and repeats harmlessly"
}

test_retire_stops_a_live_bridge_for_exactly_its_own_session() {
  local dir home name pid lines
  dir=$(make_browser_case retire-live)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"
  pid=$(start_helper_pid); HELPER_PIDS="$HELPER_PIDS $pid"

  name=$(fm_browser_session_name "$home" task-live)
  make_session_dir "$dir" "$name" "$pid" 9301
  # The bridge on the port this session's record names identifies itself as this
  # session: positive identification, the only case that may be signalled.
  say_session_is "$dir" 9301 "$name"

  fm_browser_retire "$home" "$name" > "$dir/out" 2> "$dir/err" \
    || fail "retire-live: retirement returned failure"
  [ ! -s "$dir/out" ] || fail "retire-live: retirement wrote to stdout:"$'\n'"$(cat "$dir/out")"
  [ ! -s "$dir/err" ] || fail "retire-live: retirement wrote to stderr:"$'\n'"$(cat "$dir/err")"
  [ -z "$FM_BROWSER_ERROR" ] \
    || fail "retire-live: an identified bridge still reported an error: $FM_BROWSER_ERROR"
  [ "$FM_BROWSER_RETIRED" = 1 ] || fail "retire-live: a stopped bridge was not reported reclaimed"
  assert_grep "$name|stop" "$FM_FAKE_CDA_LOG" \
    "retire-live: the stop was not issued for this task's own session"
  lines=$(wc -l < "$FM_FAKE_CDA_LOG" | tr -d ' ')
  [ "$lines" = 1 ] \
    || fail "retire-live: expected exactly one browser call:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  assert_grep "127.0.0.1:9301/health" "$dir/health/requests.log" \
    "retire-live: the identity probe did not go to the port this session's own record names"
  assert_absent "$dir/root/sessions/$name" "retire-live: the session directory survived a successful stop"
  pass "a live bridge that reports this session is stopped under its own name and its state is reclaimed"
}

# The pid recorded for a dead session can be handed to a live bridge belonging to
# another session, another home, or the shared default session. Being a bridge is
# not being OUR bridge, and the browser CLI applies no such check: its stop
# signals whatever pid the record names, then SIGKILLs that pid's whole process
# group. So a bridge that does not identify itself as this session must be left
# strictly alone, and the refusal must be reported rather than swallowed.
test_retire_refuses_a_live_bridge_that_reports_another_session() {
  local dir home name foreign pid
  dir=$(make_browser_case retire-foreign-bridge)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"
  pid=$(start_helper_pid); HELPER_PIDS="$HELPER_PIDS $pid"

  name=$(fm_browser_session_name "$home" task-ours)
  foreign=$(fm_browser_session_name "$dir/other-home" task-theirs)
  make_session_dir "$dir" "$name" "$pid" 9302
  make_session_dir "$dir" "$foreign" "$pid" 9302
  # Our stale record names a pid the kernel has since handed to the bridge of a
  # different session, which is what answers on that port.
  say_session_is "$dir" 9302 "$foreign"

  fm_browser_retire "$home" "$name" > "$dir/out" 2> "$dir/err" \
    || fail "retire-foreign-bridge: a refusal must still return success"
  [ ! -s "$dir/out" ] || fail "retire-foreign-bridge: retirement wrote to stdout:"$'\n'"$(cat "$dir/out")"
  [ ! -s "$dir/err" ] || fail "retire-foreign-bridge: retirement wrote to stderr:"$'\n'"$(cat "$dir/err")"
  [ "$FM_BROWSER_RETIRED" = 0 ] || fail "retire-foreign-bridge: claimed a reclaim it refused to perform"
  [ -n "$FM_BROWSER_ERROR" ] || fail "retire-foreign-bridge: the refusal was silent"
  assert_contains "$FM_BROWSER_ERROR" "$pid" \
    "retire-foreign-bridge: the refusal does not name the pid it would have signalled"
  assert_contains "$FM_BROWSER_ERROR" "$name" \
    "retire-foreign-bridge: the refusal does not name the session it expected"
  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "retire-foreign-bridge: a foreign bridge was signalled:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  sleep 0.5
  kill -0 "$pid" 2>/dev/null || fail "retire-foreign-bridge: the foreign bridge was killed"
  assert_present "$dir/root/sessions/$name/bridge.pid" \
    "retire-foreign-bridge: our own state was removed on a refusal"
  assert_present "$dir/root/sessions/$foreign/bridge.pid" \
    "retire-foreign-bridge: the foreign session's state was removed"
  pass "a live bridge reporting another session is refused: no signal, nothing removed, and it is reported"
}

# An unanswerable probe is not a licence to guess in either direction: treating
# the bridge as ours would signal an unidentified process, and treating it as dead
# would delete the record that identifies whatever is still running.
test_retire_refuses_a_live_bridge_it_cannot_identify() {
  local dir home name pid answered
  dir=$(make_browser_case retire-unidentified)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"
  pid=$(start_helper_pid); HELPER_PIDS="$HELPER_PIDS $pid"

  name=$(fm_browser_session_name "$home" task-silent)
  make_session_dir "$dir" "$name" "$pid" 9303

  fm_browser_retire "$home" "$name" > "$dir/out" 2> "$dir/err" \
    || fail "retire-unidentified: a refusal must still return success"
  [ ! -s "$dir/out" ] || fail "retire-unidentified: retirement wrote to stdout:"$'\n'"$(cat "$dir/out")"
  [ ! -s "$dir/err" ] || fail "retire-unidentified: retirement wrote to stderr:"$'\n'"$(cat "$dir/err")"
  [ "$FM_BROWSER_RETIRED" = 0 ] || fail "retire-unidentified: claimed a reclaim it refused to perform"
  [ -n "$FM_BROWSER_ERROR" ] || fail "retire-unidentified: an unanswerable probe refused silently"
  assert_contains "$FM_BROWSER_ERROR" "$pid" \
    "retire-unidentified: the refusal does not name the pid it would have signalled"
  assert_contains "$FM_BROWSER_ERROR" "$name" \
    "retire-unidentified: the refusal does not name the session it expected"
  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "retire-unidentified: an unidentified bridge was signalled:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  sleep 0.5
  kill -0 "$pid" 2>/dev/null || fail "retire-unidentified: the unidentified process was killed"
  assert_present "$dir/root/sessions/$name/bridge.pid" \
    "retire-unidentified: the record identifying a live process was removed"

  # A well-formed answer that carries no session name is unanswerable too: there
  # is nothing in it to identify.
  say_session_is "$dir" 9303 '{"status":"ok"}'
  fm_browser_retire "$home" "$name" || fail "retire-unidentified: a session-less answer must still return success"
  [ "$FM_BROWSER_RETIRED" = 0 ] || fail "retire-unidentified: a session-less answer was treated as identification"
  [ -n "$FM_BROWSER_ERROR" ] || fail "retire-unidentified: a session-less answer refused silently"
  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "retire-unidentified: a session-less answer still reached the browser CLI"
  assert_present "$dir/root/sessions/$name/bridge.pid" \
    "retire-unidentified: a session-less answer still removed the bridge record"
  answered=$(wc -l < "$dir/health/requests.log" | tr -d ' ')
  [ "$answered" = 2 ] \
    || fail "retire-unidentified: expected one probe per retirement, saw $answered"
  pass "a live bridge whose probe cannot answer is refused just as loudly and just as completely"
}

# A session directory only reaches a reclaim because its bridge already died
# without cleaning up, and those directories outlive the pid numbers they name.
# An unrelated process that inherited the number must never be signalled, and
# the browser CLI is no protection: its stop signals whatever pid the record
# names before asking what that process is. So the recorded pid must be proven
# to be a bridge before anything is aimed at it.
test_retire_never_signals_a_recycled_pid() {
  local dir home name pid
  dir=$(make_browser_case retire-recycled)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"
  # A live process that is NOT a bridge: the recycled-pid case, exactly.
  pid=$(start_bystander_pid); HELPER_PIDS="$HELPER_PIDS $pid"

  name=$(fm_browser_session_name "$home" task-recycled)
  make_session_dir "$dir" "$name" "$pid"

  fm_browser_retire "$home" "$name" || fail "retire-recycled: retirement returned failure"
  sleep 0.5
  kill -0 "$pid" 2>/dev/null \
    || fail "retire-recycled: an unrelated process holding a recycled pid was killed"
  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "retire-recycled: the browser CLI was aimed at a recycled pid:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  [ "$FM_BROWSER_RETIRED" = 1 ] \
    || fail "retire-recycled: the stale directory behind a recycled pid was not reclaimed"
  [ -z "$FM_BROWSER_ERROR" ] \
    || fail "retire-recycled: a pid on an unrelated process should reclaim quietly, not report: $FM_BROWSER_ERROR"
  assert_absent "$dir/root/sessions/$name" "retire-recycled: the stale directory survived"
  pass "a recycled pid reads as dead: no signal, no browser call, and the stale directory is still reclaimed"
}

test_retire_never_orphans_a_bridge_that_survived_the_stop() {
  local dir home name pid
  dir=$(make_browser_case retire-survivor)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir" FM_FAKE_CDA_STOP=noop FM_FAKE_CDA_EXIT=1
  pid=$(start_helper_pid); HELPER_PIDS="$HELPER_PIDS $pid"

  name=$(fm_browser_session_name "$home" task-survivor)
  make_session_dir "$dir" "$name" "$pid" 9304
  say_session_is "$dir" 9304 "$name"

  fm_browser_retire "$home" "$name" || fail "retire-survivor: a failed stop must not fail retirement"
  [ "$FM_BROWSER_RETIRED" = 0 ] || fail "retire-survivor: reported reclaiming a bridge that is still running"
  assert_grep "$name|stop" "$FM_FAKE_CDA_LOG" \
    "retire-survivor: the identified bridge was never asked to stop, so the case proved nothing"
  assert_present "$dir/root/sessions/$name/bridge.pid" \
    "retire-survivor: the record identifying a live bridge was deleted"
  kill -0 "$pid" 2>/dev/null || fail "retire-survivor: the fixture bridge died, so the case proved nothing"
  pass "a bridge that survives the stop keeps its identifying record for the next sweep"
}

test_retire_is_a_silent_success_without_the_browser_cli() {
  local dir home name pid dead
  dir=$(make_browser_case retire-no-cli)
  home="$dir/home"
  use_case_env "$dir"
  pid=$(start_helper_pid); HELPER_PIDS="$HELPER_PIDS $pid"
  dead=$(reaped_pid) || fail "retire-no-cli: could not obtain a provably dead pid"
  # No chrome-devtools-axi stand-in, and a PATH with no chrome-devtools-axi
  # anywhere on it; the case's own fakebin stays first so the identity probe is
  # still answered from the fixture and never reaches a real port.
  PATH="$dir/fakebin:/usr/bin:/bin"

  name=$(fm_browser_session_name "$home" task-nocli-live)
  make_session_dir "$dir" "$name" "$pid" 9305
  say_session_is "$dir" 9305 "$name"
  fm_browser_retire "$home" "$name" \
    || fail "retire-no-cli: a missing browser CLI must not fail retirement"
  [ "$FM_BROWSER_RETIRED" = 0 ] || fail "retire-no-cli: claimed a reclaim with no browser CLI available"
  [ -z "$FM_BROWSER_ERROR" ] \
    || fail "retire-no-cli: an identified bridge with no CLI to stop it is a no-op, not an error: $FM_BROWSER_ERROR"
  assert_present "$dir/root/sessions/$name/bridge.pid" "retire-no-cli: a live bridge's record was deleted"

  # A dead bridge needs no CLI at all, so it still reclaims.
  name=$(fm_browser_session_name "$home" task-nocli-dead)
  make_session_dir "$dir" "$name" "$dead"
  fm_browser_retire "$home" "$name" || fail "retire-no-cli: dead-session cleanup returned failure"
  [ "$FM_BROWSER_RETIRED" = 1 ] || fail "retire-no-cli: a dead session was not reclaimed without the CLI"
  assert_absent "$dir/root/sessions/$name" "retire-no-cli: the stale directory survived"

  PATH=$BASE_PATH
  pass "retirement succeeds quietly when chrome-devtools-axi is not installed"
}

test_retire_tolerates_absent_and_unreadable_records() {
  local dir home name
  dir=$(make_browser_case retire-absent)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"

  # No session directory at all.
  name=$(fm_browser_session_name "$home" task-absent)
  fm_browser_retire "$home" "$name" || fail "retire-absent: an absent session must not fail retirement"
  [ "$FM_BROWSER_RETIRED" = 0 ] || fail "retire-absent: claimed a reclaim for a session that never existed"

  # A directory with no bridge.pid: nothing to stop, everything to clean up.
  name=$(fm_browser_session_name "$home" task-nopid)
  make_session_dir "$dir" "$name"
  fm_browser_retire "$home" "$name" || fail "retire-absent: a pid-less directory must not fail retirement"
  [ "$FM_BROWSER_RETIRED" = 1 ] || fail "retire-absent: a pid-less stale directory was not reclaimed"
  assert_absent "$dir/root/sessions/$name" "retire-absent: the pid-less directory survived"

  # A bridge.pid that does not parse is treated as no live bridge.
  name=$(fm_browser_session_name "$home" task-garbage)
  mkdir -p "$dir/root/sessions/$name"
  printf 'not json at all\n' > "$dir/root/sessions/$name/bridge.pid"
  fm_browser_retire "$home" "$name" || fail "retire-absent: a corrupt record must not fail retirement"
  [ "$FM_BROWSER_RETIRED" = 1 ] || fail "retire-absent: a corrupt-record directory was not reclaimed"
  assert_absent "$dir/root/sessions/$name" "retire-absent: the corrupt-record directory survived"

  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "retire-absent: no browser call was warranted:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  pass "an absent, pid-less, or corrupt session record is cleanup, never an error"
}

# --- orphan sweep -----------------------------------------------------------

test_sweep_reclaims_orphans_and_spares_every_living_task() {
  local dir home dead orphan by_key derived
  dir=$(make_browser_case sweep-basic)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"
  dead=$(reaped_pid) || fail "sweep-basic: could not obtain a provably dead pid"

  # A task whose durable record names the session explicitly.
  by_key=$(fm_browser_session_name "$home" task-recorded)
  fm_write_meta "$home/state/task-recorded.meta" \
    "window=firstmate:fm-task-recorded" "kind=ship" "browser_session=$by_key"
  make_session_dir "$dir" "$by_key" "$dead"

  # A task predating that key: only its record's own name identifies the session.
  derived=$(fm_browser_session_name "$home" task-derived)
  fm_write_meta "$home/state/task-derived.meta" \
    "window=firstmate:fm-task-derived" "kind=ship"
  make_session_dir "$dir" "$derived" "$dead"

  # A session with no owning task at all.
  orphan=$(fm_browser_session_name "$home" task-gone)
  make_session_dir "$dir" "$orphan" "$dead"

  fm_browser_sweep_orphans "$home" "$home/state" > "$dir/out" 2> "$dir/err" \
    || fail "sweep-basic: the sweep returned failure"
  [ ! -s "$dir/out" ] || fail "sweep-basic: the sweep wrote to stdout:"$'\n'"$(cat "$dir/out")"
  [ ! -s "$dir/err" ] || fail "sweep-basic: the sweep wrote to stderr:"$'\n'"$(cat "$dir/err")"
  [ "$FM_BROWSER_SWEEP_COUNT" = 1 ] \
    || fail "sweep-basic: expected exactly one reclaim, got $FM_BROWSER_SWEEP_COUNT"
  case "$FM_BROWSER_SWEEP_NAMES" in
    *"$orphan"*) : ;;
    *) fail "sweep-basic: the reclaimed session was not named: '$FM_BROWSER_SWEEP_NAMES'" ;;
  esac
  assert_absent "$dir/root/sessions/$orphan" "sweep-basic: the orphaned session directory survived"
  assert_present "$dir/root/sessions/$by_key" \
    "sweep-basic: reclaimed a session whose task records it explicitly"
  assert_present "$dir/root/sessions/$derived" \
    "sweep-basic: reclaimed a session whose task is known only by its own record's name"
  pass "the sweep reclaims a session with no owning task and spares every task still on record"
}

test_sweep_never_considers_another_homes_sessions() {
  local dir home other pid foreign
  dir=$(make_browser_case sweep-cross-home)
  home="$dir/home"
  other="$dir/other-home"
  mkdir -p "$other/state"
  install_cda_shim "$dir"
  use_case_env "$dir"
  pid=$(start_helper_pid); HELPER_PIDS="$HELPER_PIDS $pid"

  # The other home's task is live there and completely unknown here.
  foreign=$(fm_browser_session_name "$other" task-busy)
  make_session_dir "$dir" "$foreign" "$pid"
  make_session_dir "$dir" default "$pid"
  make_session_dir "$dir" fm-gputest "$pid"

  fm_browser_sweep_orphans "$home" "$home/state" > "$dir/out" 2> "$dir/err" \
    || fail "sweep-cross-home: the sweep returned failure"
  [ ! -s "$dir/out" ] || fail "sweep-cross-home: the sweep wrote to stdout:"$'\n'"$(cat "$dir/out")"
  [ ! -s "$dir/err" ] || fail "sweep-cross-home: the sweep wrote to stderr:"$'\n'"$(cat "$dir/err")"
  [ "$FM_BROWSER_SWEEP_COUNT" = 0 ] \
    || fail "sweep-cross-home: reclaimed $FM_BROWSER_SWEEP_COUNT session(s) it does not own"
  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "sweep-cross-home: a foreign session reached the browser CLI:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  assert_present "$dir/root/sessions/$foreign" "sweep-cross-home: another home's live session was removed"
  assert_present "$dir/root/sessions/default" "sweep-cross-home: the shared default session was removed"
  assert_present "$dir/root/sessions/fm-gputest" "sweep-cross-home: a foreign bare-fm- session was removed"
  kill -0 "$pid" 2>/dev/null || fail "sweep-cross-home: the fixture bridge died, so the case proved nothing"
  pass "a sweep never evaluates, stops, or removes a session belonging to another home or tool"
}

test_sweep_is_bounded_per_call_and_finishes_across_calls() {
  local dir home dead i total remaining
  dir=$(make_browser_case sweep-bounded)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir" FM_BROWSER_SWEEP_MAX=2
  dead=$(reaped_pid) || fail "sweep-bounded: could not obtain a provably dead pid"

  for i in 1 2 3 4 5; do
    make_session_dir "$dir" "$(fm_browser_session_name "$home" "task-orphan-$i")" "$dead"
  done

  total=0
  for i in 1 2 3; do
    fm_browser_sweep_orphans "$home" "$home/state" || fail "sweep-bounded: sweep $i returned failure"
    [ "$FM_BROWSER_SWEEP_COUNT" -le 2 ] \
      || fail "sweep-bounded: sweep $i reclaimed $FM_BROWSER_SWEEP_COUNT, over the configured bound"
    total=$((total + FM_BROWSER_SWEEP_COUNT))
  done
  [ "$total" = 5 ] || fail "sweep-bounded: expected 5 reclaims across three bounded sweeps, got $total"
  remaining=$(ls -A "$dir/root/sessions" 2>/dev/null)
  [ -z "$remaining" ] \
    || fail "sweep-bounded: sessions remain after the backlog drained:"$'\n'"$remaining"
  pass "the sweep acts on a bounded number of candidates per call and drains the backlog across calls"
}

test_sweep_reports_a_refusal_and_keeps_sweeping() {
  local dir home dead pid refused reclaimable
  dir=$(make_browser_case sweep-refusal)
  home="$dir/home"
  install_cda_shim "$dir"
  use_case_env "$dir"
  dead=$(reaped_pid) || fail "sweep-refusal: could not obtain a provably dead pid"
  pid=$(start_helper_pid); HELPER_PIDS="$HELPER_PIDS $pid"

  # An orphan whose recorded pid is on a live bridge that will not say which
  # session it is, and an ordinary stale orphan behind it in the same sweep.
  refused=$(fm_browser_session_name "$home" task-unidentified)
  make_session_dir "$dir" "$refused" "$pid" 9306
  reclaimable=$(fm_browser_session_name "$home" task-stale)
  make_session_dir "$dir" "$reclaimable" "$dead"

  fm_browser_sweep_orphans "$home" "$home/state" > "$dir/out" 2> "$dir/err" \
    || fail "sweep-refusal: the sweep returned failure"
  [ ! -s "$dir/out" ] || fail "sweep-refusal: the sweep wrote to stdout:"$'\n'"$(cat "$dir/out")"
  [ ! -s "$dir/err" ] || fail "sweep-refusal: the sweep wrote to stderr:"$'\n'"$(cat "$dir/err")"
  [ "$FM_BROWSER_SWEEP_COUNT" = 1 ] \
    || fail "sweep-refusal: expected exactly the reclaimable orphan, got $FM_BROWSER_SWEEP_COUNT"
  assert_contains "$FM_BROWSER_SWEEP_ERRORS" "$refused" \
    "sweep-refusal: the refusal was not reported: '$FM_BROWSER_SWEEP_ERRORS'"
  assert_contains "$FM_BROWSER_SWEEP_ERRORS" "$pid" \
    "sweep-refusal: the refusal does not name the pid it would have signalled"
  assert_absent "$dir/root/sessions/$reclaimable" \
    "sweep-refusal: one refusal stopped the sweep from reclaiming a stale orphan behind it"
  assert_present "$dir/root/sessions/$refused/bridge.pid" \
    "sweep-refusal: the refused session's record was removed anyway"
  [ ! -s "$FM_FAKE_CDA_LOG" ] \
    || fail "sweep-refusal: an unidentified bridge was signalled:"$'\n'"$(cat "$FM_FAKE_CDA_LOG")"
  kill -0 "$pid" 2>/dev/null || fail "sweep-refusal: the unidentified process was killed"
  pass "a sweep reports a bridge it refused to identify and still reclaims every other orphan"
}

# --- the death case: a real browser, a killed worker, real reclamation -------

# descendant_pids <pid>: the pid and every process descended from it, one per
# line, from one ps snapshot. A group listing is not enough: the bridge's Chrome
# runs in its own process group.
descendant_pids() {
  local root=$1
  ps -eo pid=,ppid= | awk -v root="$root" '
    { pid[NR] = $1; ppid[NR] = $2; n = NR }
    END {
      want[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) {
          if (!want[pid[i]] && want[ppid[i]]) { want[pid[i]] = 1; changed = 1 }
        }
      }
      for (i = 1; i <= n; i++) if (want[pid[i]]) print pid[i]
    }' | sort -u
}

all_pids_gone() {
  local p
  for p in $1; do
    if kill -0 "$p" 2>/dev/null; then return 1; fi
  done
  return 0
}

# Build the minimal real teardown fixture: a project clone with an origin and a
# task worktree whose work is already in the project's main, so teardown is
# allowed without --force. chrome-devtools-axi is deliberately NOT mocked here.
make_death_case_fixture() {  # <case-dir> <task-id>
  local case_dir=$1 id=$2 fakebin="$1/fakebin" head
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/home/projects" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$id" "$case_dir/wt" main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "task work"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$head"
  touch "$case_dir/home/state/.last-watcher-beat"
}

test_teardown_reclaims_the_browser_of_a_worker_killed_without_cleanup() {
  local dir home cda_root id name pidfile bridge_pid tree i rc out worker_pid
  command -v chrome-devtools-axi >/dev/null 2>&1 \
    || { echo "skip: chrome-devtools-axi not found (real browser death case)"; return 0; }

  dir=$(make_browser_case death-case)
  home="$dir/home"
  cda_root="$home/.chrome-devtools-axi"
  id=browser-death-x1
  make_death_case_fixture "$dir" "$id"
  # This case's fakebin deliberately carries no chrome-devtools-axi stand-in, so
  # rebuild PATH from the real one rather than inheriting a previous case's shim.
  PATH="$dir/fakebin:$BASE_PATH"
  name=$(fm_browser_session_name "$home" "$id") || fail "death-case: could not derive the session name"
  assert_valid_session_name "$name" death-case
  pidfile="$cda_root/sessions/$name/bridge.pid"

  # A simulated worker doing real browser work in the session fm-spawn would
  # have given it. HOME is redirected into the case directory so the real
  # chrome-devtools-axi keeps its whole state inside this fixture and can never
  # see, name, or touch the shared default session.
  HOME="$home" CHROME_DEVTOOLS_AXI_SESSION="$name" FM_DEATH_LOG="$dir/worker.log" \
    FM_DEATH_DONE="$dir/worker.done" \
    bash -c 'chrome-devtools-axi open https://example.com > "$FM_DEATH_LOG" 2>&1; : > "$FM_DEATH_DONE"; sleep 300' \
    >/dev/null 2>&1 &
  worker_pid=$!
  HELPER_PIDS="$HELPER_PIDS $worker_pid"
  LIVE_SESSION_NAME=$name
  LIVE_SESSION_HOME=$home

  # Wait for the browser call itself to RETURN, not merely for the bridge record
  # to appear. Killing the worker mid-call would leave its own browser-CLI child
  # running, and that child would start a replacement bridge after teardown had
  # already reclaimed the first one.
  i=0
  while [ "$i" -lt 900 ]; do
    [ -f "$dir/worker.done" ] && break
    kill -0 "$worker_pid" 2>/dev/null || break
    sleep 0.2
    i=$((i + 1))
  done
  if [ ! -f "$pidfile" ]; then
    kill -9 "$worker_pid" 2>/dev/null || true
    LIVE_SESSION_NAME=
    echo "skip: no browser could be launched here (real browser death case): $(head -3 "$dir/worker.log" 2>/dev/null | tr '\n' ' ')"
    return 0
  fi
  bridge_pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$pidfile" | head -1)
  [ -n "$bridge_pid" ] || fail "death-case: the browser recorded no bridge pid"
  LIVE_BRIDGE_PIDS="$LIVE_BRIDGE_PIDS $bridge_pid"
  kill -0 "$bridge_pid" 2>/dev/null \
    || fail "death-case: the bridge was not running after a page opened successfully"
  tree=$(descendant_pids "$bridge_pid")
  [ "$(printf '%s\n' "$tree" | wc -l | tr -d ' ')" -ge 2 ] \
    || fail "death-case: the bridge started no child processes, so the case proves nothing"

  # The worker dies with no cleanup at all. The bridge is a detached process
  # group, so it and its whole browser survive: this is the leak being closed.
  kill -9 "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
  sleep 1
  kill -0 "$bridge_pid" 2>/dev/null \
    || fail "death-case: the bridge died with its worker, so there is nothing for teardown to prove"

  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "browser_session=$name"

  rc=0
  out=$(HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BROWSER_STATE_ROOT="$cda_root" \
    PATH="$dir/fakebin:$BASE_PATH" "$TEARDOWN" "$id" 2>"$dir/teardown.err") || rc=$?
  expect_code 0 "$rc" "death-case: teardown failed"$'\n'"$(cat "$dir/teardown.err")"
  assert_contains "$out" "reclaimed browser session $name" \
    "death-case: teardown did not report reclaiming the dead worker's browser"

  i=0
  while [ "$i" -lt 150 ]; do
    all_pids_gone "$tree" && break
    sleep 0.1
    i=$((i + 1))
  done
  LIVE_SESSION_NAME=
  all_pids_gone "$tree" \
    || fail "death-case: browser processes survived teardown:"$'\n'"$(ps -o pid,ppid,command -p "$(printf '%s' "$tree" | tr '\n' ',')" 2>&1)"
  assert_absent "$cda_root/sessions/$name" "death-case: the session state directory was not reclaimed"
  pass "teardown reclaims the detached bridge, its browser children, and its state after its worker is killed"
}

test_session_name_is_deterministic_and_scoped_to_its_home
test_long_ids_clamp_to_the_limit_and_stay_distinct
test_no_two_task_ids_share_a_session_name
test_underivable_inputs_return_failure_with_no_output
test_retire_refuses_every_name_this_home_does_not_own
test_retire_reclaims_a_dead_session_without_touching_the_cli
test_retire_stops_a_live_bridge_for_exactly_its_own_session
test_retire_refuses_a_live_bridge_that_reports_another_session
test_retire_refuses_a_live_bridge_it_cannot_identify
test_retire_never_signals_a_recycled_pid
test_retire_never_orphans_a_bridge_that_survived_the_stop
test_retire_is_a_silent_success_without_the_browser_cli
test_retire_tolerates_absent_and_unreadable_records
test_sweep_reclaims_orphans_and_spares_every_living_task
test_sweep_never_considers_another_homes_sessions
test_sweep_is_bounded_per_call_and_finishes_across_calls
test_sweep_reports_a_refusal_and_keeps_sweeping
test_teardown_reclaims_the_browser_of_a_worker_killed_without_cleanup
