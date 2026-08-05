# shellcheck shell=bash
# Shared per-task browser-session machinery for chrome-devtools-axi.
# Usage: . bin/fm-browser-lib.sh   (sourced; defines functions only)
#
# WHY THIS EXISTS
# chrome-devtools-axi has one shared "default" session unless
# CHROME_DEVTOOLS_AXI_SESSION names another, and a named session gets its OWN
# bridge process, OWN port and OWN on-disk state. Without a per-task name every
# crewmate, and the captain, drive one browser: one worker's cleanup blanks
# another's page, and "chrome-devtools-axi stop" SIGTERM-then-SIGKILLs the whole
# detached process group, taking every actor's Chrome with it. This lib gives
# each task a private session and is the ONE owner of how those sessions are
# named, which of them this home may reclaim, and how a reclaim is performed.
# Callers: bin/fm-spawn.sh (names it and puts it on the launch command),
# bin/fm-teardown.sh (retires it), bin/fm-watch.sh (sweeps orphans).
#
# SESSION NAME FORMAT
#   fm-<home8>-<taskpart>, at most 64 characters, always matching
#   /^[A-Za-z0-9._-]{1,64}$/ and never all-dots (it always starts with "fm-").
#   home8 is the first 8 lowercase hex characters of sha256 over the RESOLVED
#   realpath of the FM_HOME argument, so it is fixed width.
#   Budget arithmetic: 64 - 3 ("fm-") - 8 (home8) - 1 (separator) = 52
#   characters for taskpart.
#     - id length <= 51: taskpart is the task id VERBATIM. No character
#       substitution is ever needed, because fm_task_id_path_safe
#       (bin/fm-pr-lib.sh) already restricts a firstmate task id to
#       [A-Za-z0-9._-] with no leading dot, a strict subset of
#       chrome-devtools-axi's own validateSessionName charset. The only real
#       transformation this rule performs is length.
#     - id length >= 52: taskpart is "${id:0:43}" + "-" + hash8(id), exactly
#       43 + 1 + 8 = 52 characters, so a clamped name is exactly 64.
#   The truncation width is 43 and not some shorter figure BECAUSE the hashed
#   taskpart must fill the budget exactly: the verbatim branch can produce any
#   taskpart length up to 51, so only a hashed length of exactly 52 keeps the
#   two branches disjoint. A narrower truncation would put the hashed branch
#   inside the verbatim branch's length range and quietly void the argument
#   below.
#   Collision resistance by construction, not by luck: the verbatim branch
#   yields a taskpart of length <= 51 and the hashed branch a taskpart of
#   length exactly 52, so the two branches are DISJOINT BY LENGTH and a long id
#   can never collide with a short one whatever characters it contains. The
#   verbatim branch is the identity map, hence injective. Two long ids collide
#   only when they share both their first 43 characters and a full 8-hex sha256
#   prefix - a 2^-32 event among long ids that already share a 43-character
#   prefix inside one home. That is the strength firstmate already ships and has
#   already had reviewed for the cmux and zellij home tags, where a collision
#   has a strictly worse consequence, so it is accepted here rather than
#   answered with a wider hash and a bespoke fallback.
#
# WHY NOT fm_backend_hometag() (bin/fm-backend-hometag-lib.sh) - do not "fix"
# this back. Two disqualifiers: its width is unbounded for a secondmate
# ("2ndmate-<registry id>-<8hex>") and cannot be fitted into the hard 64-char
# budget, and it hashes realpath(FM_ROOT) rather than FM_HOME, so two homes
# sharing one code root through an FM_HOME override - the exact arrangement
# AGENTS.md section 2 describes - would produce the same tag. FM_HOME is the
# correct identity here because FM_HOME owns the state dir the sweep's authority
# derives from. Also do not reuse fm-spawn's window label $W ("fm-$ID"): it is
# an unclamped backend label and would emit an over-length, invalid session name
# for a long id.
#
# OWNERSHIP RULE
# The ownership marker is the computed prefix "fm-<home8>-", i.e. firstmate's
# literal "fm-" tag PLUS this home's 8-hex identity, and it is the complete
# authority to reclaim. A session is reclaimable by a given home if and only if
# its name (a) matches /^[A-Za-z0-9._-]{1,64}$/ and (b) begins with that home's
# exact "fm-<home8>-" prefix. Everything else is foreign and is never stopped,
# never removed, never touched: a human's session, another tool's session, the
# shared "default" session, and another firstmate home's sessions all fail the
# test identically.
# A bare "fm-" prefix is NOT a sufficient marker: real machines already carry
# fm-brief-evidence, fm-gpu-on, fm-gpu-off and fm-gputest under
# ~/.chrome-devtools-axi/sessions/, none of them created by firstmate, and a
# bare-"fm-" sweep would have killed them. The home digest is what makes the
# marker unique to firstmate-the-tool-in-this-home rather than to a
# two-character string.
# The guard lives in exactly one place, fm_browser_retire, so every reclaim path
# (teardown, secondmate child cleanup, watcher sweep) is covered by one
# implementation. Two consequences that must be preserved: an EMPTY name fails
# the guard, because an empty CHROME_DEVTOOLS_AXI_SESSION resolves to the shared
# DEFAULT session whose stop kills the captain's and every worker's browser; and
# a hand-edited or corrupt browser_session= value in a meta file also fails the
# guard rather than aiming the kill wherever it points. This mirrors the
# empty-target refusal fm_backend_tmux_kill already carries for the same reason.
# The home is always an EXPLICIT argument, never the ambient FM_HOME, so a
# parent tearing down a secondmate home derives and refuses against that CHILD
# home's identity.
#
# PID IDENTITY RULE - a recorded pid is POSITIVELY IDENTIFIED, never trusted
# A pid is an identifier the operating system reuses, so trusting a recorded one
# is assuming a fact nobody verified. A session directory reaches a reclaim only
# because its bridge already died without cleaning up, and those directories can
# be days old, so the pid recorded in bridge.pid may by then belong to a process
# the kernel handed the same number. chrome-devtools-axi is no protection:
# stopBridge() SIGTERMs whatever pid the file names before any identity question
# is asked - isBridgeProcess only decides whether to escalate to a process-GROUP
# SIGKILL - so invoking it on a recycled pid kills a bystander, silently, and
# reports a successful reclaim. Firstmate now drives that path automatically from
# every teardown and from the watcher sweep, and this machinery exists precisely
# to stop one task acting on another's browser, so accepting a recycled pid would
# leave exactly the failure it removes, reachable by coincidence rather than by a
# bug.
# Identification is therefore in two parts, and both must pass before anything is
# aimed at the pid:
#   1. `ps -p <pid> -o command=` names a chrome-devtools-axi-bridge, the test the
#      CLI itself uses. It proves the pid is A bridge and never WHICH one: every
#      bridge is spawned as `node .../chrome-devtools-axi-bridge.js` with neither
#      the session name nor the port anywhere in its argv.
#   2. that running process's OWN ENVIRONMENT names this session in
#      CHROME_DEVTOOLS_AXI_SESSION. spawnBridgeProcess (dist/src/client.js) puts
#      the session name into the bridge's environment at launch and nothing
#      changes it afterwards, so the process carries its own identity for as long
#      as it lives. Verified against every live bridge on this machine: each one's
#      environment names exactly the session directory whose bridge.pid records
#      it.
# The environment is read from /proc/<pid>/environ where that exists and is
# readable, and from `ps eww -p <pid> -o command=` otherwise, which is what macOS
# uses. Neither adds a dependency, because part 1 already needs ps. Both readers
# are same-user only, and that is CORRECT rather than a limitation to work around:
# a bridge this user cannot inspect is not this home's bridge and must be refused.
# macOS additionally hides the environment of a platform-signed binary, so a
# bridge running under such an interpreter would read as unreadable and be
# refused; a real bridge runs under the node chrome-devtools-axi itself requires,
# whose environment ps reports normally, which is how every live bridge on this
# machine was confirmed to name its own session.
# Reading the PROCESS rather than asking the bridge over HTTP is deliberate, and
# it is the difference between reclaiming the primary leak and leaking it forever.
# A bridge whose chrome-devtools-mcp child has died or hung keeps running, and its
# /health then answers 503 with no session name for the rest of its life, because
# bridge.js gates that route on client.listTools(). An HTTP identity check could
# therefore never reclaim the exact case this machinery exists for, while the
# process environment still names the session perfectly.
# For a pid that is alive AND a bridge there are exactly four outcomes, and none
# of them is a silent guess:
#   - the environment names the EXPECTED session: positively identified as ours,
#     so its bridge is stopped and its directory reclaimed.
#   - the environment names a DIFFERENT session: a foreign bridge. REFUSED.
#   - the environment carries NO CHROME_DEVTOOLS_AXI_SESSION: the observed value
#     is reported as the marker "none". REFUSED.
#   - the environment CANNOT BE READ: the observed value is reported as the marker
#     "unreadable". REFUSED.
# Every refusal sends no signal, removes no state directory, and reports one line
# naming the pid, the expected session, and the observed value, so the two cases
# with no name to report still say which of them happened.
# A wrong answer in either direction is worse than a refusal, so there is no
# fall-through that treats an unidentified bridge as live and none that treats it
# as dead.
# The refusal is LOUD BUT NEVER BLOCKING. fm_browser_retire records it in
# FM_BROWSER_ERROR and the sweep accumulates one line per refusal in
# FM_BROWSER_SWEEP_ERRORS; each caller surfaces those through its own existing
# reporting channel - teardown on stderr, the watcher in its triage log - and
# then carries on. Retirement is cleanup, not a gate: a refusal must never block,
# refuse, or fail an otherwise-successful teardown, because teardown always
# running is the whole point of this machinery, and it must never wedge the
# watcher.
# The ordinary paths are unchanged, because only a live bridge needs identifying:
# a pid that is not alive, and a live pid that is not a bridge at all (the
# recycled number), both read as DEAD, are never signalled, and their stale
# directories are still reclaimed quietly with zero process cost. Refusing those
# would leak state for no safety gain.
#
# WHY THIS LIB REMOVES SESSION STATE DIRECTORIES ITSELF
# chrome-devtools-axi never does: stopBridge() reads the pid file and returns
# false having acted on nothing when that file is missing or its pid is dead
# (dist/src/client.js), which is exactly why dozens of stale session directories
# accumulate. A dead-pid directory therefore reclaims with zero process cost.
# Conversely, if any live bridge pid survives the stop attempt nothing is
# changed, so the pid file that identifies a live bridge is never deleted out
# from under it and the next sweep retries. That re-read asks only "is anything
# still alive here", not "is it ours": a bridge whose identity cannot be
# confirmed after the stop keeps its record too, because removing it would orphan
# whatever is still running.
#
# PORT-COLLISION POLICY: DO NOTHING. This is deliberate, not an oversight.
# chrome-devtools-axi hashes a session name into 9225..10224, so two names can
# land on one port - but that fails closed rather than cross-talking:
# checkBridgeHealth is called with the expected session, a bridge reporting a
# different session name is rejected, and the colliding spawn dies with a
# distinct EADDRINUSE sentinel exit code and an error that names the fix
# ("Set a distinct CHROME_DEVTOOLS_AXI_PORT for this session..."). One loud,
# self-describing, single-worker failure is not the silent sharing this design
# removes. Recovery is already routed too: a crewmate that cannot start its
# browser hits its brief's blocked: protocol and escalates, and firstmate can
# respawn the task under a different id or set CHROME_DEVTOOLS_AXI_PORT for that
# one task. Firstmate therefore never sets CHROME_DEVTOOLS_AXI_PORT and never
# allocates a port; a port registry would be a control plane over another tool's
# namespace for a problem that has not occurred.
#
# ACCEPTED RESIDUALS
#   - A live bridge that cannot be positively identified is never reclaimed by
#     this home, and that does NOT self-heal: its state directory stays and every
#     teardown or sweep that reaches it refuses again and reports again. Reaching
#     it takes a pid recycled onto another actor's bridge, a bridge owned by
#     another user, a bridge under an interpreter whose environment this OS hides,
#     or a bridge launched by hand with no session in its environment, and in the
#     first three a signal would land on a process that is not provably ours,
#     which is worse than the leak. A dead or hung chrome-devtools-mcp
#     child is NOT in this class: such a bridge's environment still names its
#     session, so it is identified and reclaimed like any other.
#   - Two homes whose FM_HOME realpaths collide in 8 hex (2^-32).
#   - Moving a home changes its digest, so sessions named under the old digest
#     become unsweepable by anyone - the same accepted limitation
#     bin/fm-backend-hometag-lib.sh already documents, and strictly safer than
#     the opposite failure direction.
#
# ENV KNOBS
#   FM_BROWSER_STATE_ROOT   default "$HOME/.chrome-devtools-axi"; the
#                           chrome-devtools-axi state root. Test override; it
#                           agrees with the CLI because Node's os.homedir()
#                           reads $HOME on POSIX.
#   FM_BROWSER_STOP_TIMEOUT default 5; seconds allowed for one stop invocation.
#   FM_BROWSER_SWEEP_MAX    default 3; candidates acted on per sweep call.

# Out-globals, initialized at file scope so a set -u caller may read them before
# the first call (precedent: the FM_PR_RETIRE_* block in bin/fm-pr-lib.sh).
# FM_BROWSER_ERROR carries one fm_browser_retire refusal for the caller to
# report; FM_BROWSER_SWEEP_ERRORS carries one newline-separated line per refusal
# across a whole sweep, because a sweep retires many sessions and each retire
# call resets FM_BROWSER_ERROR.
FM_BROWSER_RETIRED=0
FM_BROWSER_ERROR=
FM_BROWSER_SWEEP_COUNT=0
FM_BROWSER_SWEEP_NAMES=
FM_BROWSER_SWEEP_ERRORS=

# --- internal helpers ------------------------------------------------------

# fm_browser_hash8 <string> - print 8 lowercase hex characters of sha256 over
# the string, with the shasum / sha256sum / cksum three-way fallback shape
# bin/fm-backend-hometag-lib.sh uses.
fm_browser_hash8() {  # <string>
  local s=${1-}
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$s" | cksum | awk '{printf "%08x\n", $1}'
  fi
}

# fm_browser_home8 <fm-home> - this home's fixed-width 8-hex identity: hash8 of
# the resolved realpath, falling back to the literal argument when it cannot be
# resolved (the fm_backend_hometag shape).
fm_browser_home8() {  # <fm-home>
  local home=${1-} resolved
  resolved=$(cd "$home" 2>/dev/null && pwd -P) || resolved=$home
  [ -n "$resolved" ] || resolved=$home
  fm_browser_hash8 "$resolved"
}

# fm_browser_is_bridge_pid <pid> - true only when the running process is
# actually a chrome-devtools-axi bridge, by the same command-line test
# chrome-devtools-axi's own isBridgeProcess applies. See the PID IDENTITY rule in
# the header: this is part 1 of two, and on its own it proves only that the pid
# is A bridge, never that it is THIS session's.
fm_browser_is_bridge_pid() {  # <pid>
  local pid=${1-}
  [ -n "$pid" ] || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'chrome-devtools-axi-bridge'
}

# fm_browser_json_number <file> <key> - print the first numeric value the file
# records for the JSON key, or nothing. The bridge writes bridge.pid as
# {"pid":<n>,"port":<n>} (dist/src/bridge.js), and this lib reads the pid from it;
# the port is never needed, because identity comes from the process itself.
fm_browser_json_number() {  # <file> <key>
  local file=${1-} key=${2-} val
  [ -f "$file" ] || return 0
  val=$(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$file" 2>/dev/null | head -1) || val=
  case "$val" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$val"
}

# fm_browser_pid_session <pid> - print the session name the running process
# itself carries in CHROME_DEVTOOLS_AXI_SESSION, rc 0. rc 1 with no output when
# the environment was read and carries no such variable, rc 2 with no output when
# the environment cannot be read at all. Part 2 of the PID IDENTITY rule: it asks
# the process what it IS, rather than asking a browser whether it feels well, so a
# bridge whose chrome-devtools-mcp child died is still identified and still
# reclaimed.
# /proc/<pid>/environ is preferred where it exists, because it is NUL separated
# and exact; `ps eww -p <pid> -o command=` is the fallback and is what macOS uses,
# where it prints nothing at all for a pid whose environment it will not report.
fm_browser_pid_session() {  # <pid>
  local pid=${1-} dump session
  case "$pid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  if [ -r "/proc/$pid/environ" ]; then
    dump=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || dump=
  else
    dump=$(ps eww -p "$pid" -o command= 2>/dev/null | tr ' ' '\n') || dump=
  fi
  [ -n "$dump" ] || return 2
  session=$(printf '%s\n' "$dump" \
    | sed -n 's/^CHROME_DEVTOOLS_AXI_SESSION=\(.*\)$/\1/p' | head -1)
  [ -n "$session" ] || return 1
  printf '%s\n' "$session"
}

# fm_browser_live_pid <pidfile> <expected-session> - decide, for one session's
# bridge record, whether anything is alive there and whether it is positively
# THIS session's bridge.
# Prints "<pid> <observed>" for every live bridge, where <observed> is the session
# its own environment names, or the marker "none" when that environment carries no
# session, or the marker "unreadable" when it cannot be read. The rc says what the
# caller must do, because the four outcomes of the PID IDENTITY rule are not
# interchangeable:
#   rc 0 with a line     - alive, a chrome-devtools-axi bridge, and it names
#                          <expected-session>: positively ours, so it may be
#                          signalled.
#   rc 0 with no output  - nothing live to act on: no record, an unparseable
#                          record, a pid that is gone, or a live pid that is not a
#                          bridge at all (a recycled number).
#   rc 2 with a line     - a live bridge that is NOT positively ours. The observed
#                          field says which of the three refusal cases it is.
# A markerless comparison would be ambiguous, so the rc of the environment read
# gates the decision before any string is compared: a bridge whose environment
# says the literal "none" can never be mistaken for an unreadable one.
# A caller that only needs "is anything still alive here" can ignore the rc and
# test stdout for emptiness, because every live case prints a line.
fm_browser_live_pid() {  # <pidfile> <expected-session>
  local pidfile=${1-} expected=${2-} pid observed env_rc=0
  [ -n "$pidfile" ] || return 0
  [ -f "$pidfile" ] || return 0
  pid=$(fm_browser_json_number "$pidfile" pid)
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  fm_browser_is_bridge_pid "$pid" || return 0
  observed=$(fm_browser_pid_session "$pid") || env_rc=$?
  case "$env_rc" in
    0) ;;
    1) observed=none ;;
    *) observed=unreadable ;;
  esac
  printf '%s %s\n' "$pid" "$observed"
  [ "$env_rc" = 0 ] || return 2
  [ -n "$expected" ] || return 2
  [ "$observed" = "$expected" ] || return 2
  return 0
}

# fm_browser_state_root - the chrome-devtools-axi state root this lib reads.
fm_browser_state_root() {
  printf '%s\n' "${FM_BROWSER_STATE_ROOT:-${HOME-}/.chrome-devtools-axi}"
}

# --- public API ------------------------------------------------------------

# fm_browser_session_name <fm-home> <task-id>
# Print this home's session name for the task on one line, rc 0. Pure
# derivation: no filesystem writes and no CLI. rc 1 with EMPTY stdout when
# fm-home is empty, task-id is empty, task-id starts with '.', or task-id
# contains any character outside [A-Za-z0-9._-].
fm_browser_session_name() {  # <fm-home> <task-id>
  local home=${1-} id=${2-} home8 taskpart
  local LC_ALL=C
  [ -n "$home" ] || return 1
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  home8=$(fm_browser_home8 "$home")
  if [ "${#id}" -le 51 ]; then
    taskpart=$id
  else
    # 43 + 1 + 8 = 52, the exact taskpart budget; ${id:0:43} is Bash 3.2 safe.
    taskpart="${id:0:43}-$(fm_browser_hash8 "$id")"
  fi
  printf 'fm-%s-%s\n' "$home8" "$taskpart"
}

# fm_browser_retire <fm-home> <session-name>
# Reclaim one session this home owns. Always rc 0, never writes stdout or
# stderr, never exits: it is cleanup, not a gate, and must never abort a caller
# running under set -e. Sets FM_BROWSER_RETIRED to 1 when it actually reclaimed
# something, 0 otherwise, and FM_BROWSER_ERROR to one line the caller is expected
# to report when a live bridge could not be positively identified as this session
# (see the PID IDENTITY rule above); FM_BROWSER_ERROR is empty on every other
# outcome, and both are reset on entry.
# Refuses with no action when the name is empty, fails
# /^[A-Za-z0-9._-]{1,64}$/, or does not begin with this home's exact
# "fm-<home8>-" prefix (see OWNERSHIP RULE above - that guard is what keeps a
# corrupt or absent recorded value from resolving to the shared default
# session). A session directory that is absent, a bridge.pid that is missing,
# dead, or naming a recycled pid now on an unrelated process, and a missing
# chrome-devtools-axi binary are all ordinary silent no-ops, not errors.
fm_browser_retire() {  # <fm-home> <session-name>
  local home=${1-} name=${2-} prefix root dir pidfile live pid observed
  local stop_timeout live_rc
  FM_BROWSER_RETIRED=0
  FM_BROWSER_ERROR=
  local LC_ALL=C
  [ -n "$home" ] || return 0
  [ -n "$name" ] || return 0
  case "$name" in
    *[!A-Za-z0-9._-]*) return 0 ;;
  esac
  [ "${#name}" -le 64 ] || return 0
  prefix="fm-$(fm_browser_home8 "$home")-"
  case "$name" in
    "$prefix"*) ;;
    *) return 0 ;;
  esac

  root=$(fm_browser_state_root)
  dir="$root/sessions/$name"
  pidfile="$dir/bridge.pid"
  [ -d "$dir" ] || return 0

  # Nothing may be aimed at the recorded pid until the process itself says which
  # session it belongs to. A refusal reports both session values and stops here:
  # no signal, no removal.
  live_rc=0
  live=$(fm_browser_live_pid "$pidfile" "$name") || live_rc=$?
  pid=${live%% *}
  observed=${live#* }
  if [ "$live_rc" != 0 ]; then
    FM_BROWSER_ERROR="refused to retire browser session $name: live bridge pid $pid reports session=$observed, expected session=$name, so no signal was sent and nothing was removed"
    return 0
  fi

  if [ -n "$pid" ] && command -v chrome-devtools-axi >/dev/null 2>&1; then
    stop_timeout=${FM_BROWSER_STOP_TIMEOUT:-5}
    # One-command assignment prefix, never an export, and the bare binary name
    # so a test can shim it. Bounded through the same four-way fallback
    # gh_bounded uses in bin/fm-bearings-snapshot.sh, degrading to unbounded.
    if command -v timeout >/dev/null 2>&1; then
      CHROME_DEVTOOLS_AXI_SESSION=$name timeout "$stop_timeout" chrome-devtools-axi stop >/dev/null 2>&1 || true
    elif command -v gtimeout >/dev/null 2>&1; then
      CHROME_DEVTOOLS_AXI_SESSION=$name gtimeout "$stop_timeout" chrome-devtools-axi stop >/dev/null 2>&1 || true
    elif command -v perl >/dev/null 2>&1; then
      CHROME_DEVTOOLS_AXI_SESSION=$name perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$stop_timeout" chrome-devtools-axi stop >/dev/null 2>&1 || true
    else
      CHROME_DEVTOOLS_AXI_SESSION=$name chrome-devtools-axi stop >/dev/null 2>&1 || true
    fi
  fi

  # Re-read: only reclaim the directory once no live pid remains, so a bridge
  # that survived the stop keeps the pid file that identifies it and the next
  # sweep retries instead of orphaning it. Every live outcome prints a line, so
  # this asks only whether anything is still alive - an identity refusal here is
  # not reported a second time, because the signal already went to a pid that WAS
  # positively identified above.
  live=$(fm_browser_live_pid "$pidfile" "$name") || true
  [ -z "$live" ] || return 0
  rm -rf "$dir" 2>/dev/null || true
  [ -d "$dir" ] || FM_BROWSER_RETIRED=1
  return 0
}

# fm_browser_sweep_orphans <fm-home> <state-dir>
# Reclaim this home's per-task sessions whose owning task no longer exists.
# Always rc 0, never writes stdout or stderr (in the watcher, stdout belongs
# exclusively to wake()). Sets FM_BROWSER_SWEEP_COUNT (integer),
# FM_BROWSER_SWEEP_NAMES (space-prefixed list of reclaimed names, empty when
# none), and FM_BROWSER_SWEEP_ERRORS (one newline-separated line per identity
# refusal, empty when none) for the caller to report and move on: a refusal is
# never allowed to wedge a sweep or shorten it. Its only write outside the browser
# state root is the one-line rotation cursor described below.
# A session is an orphan for this home if and only if it passes the ownership
# prefix AND is absent from the live set. The live set is built from this home's
# own state dir only and is the union, over every existing <state-dir>/*.meta,
# of that meta's browser_session= value and the name derived from the meta's
# basename. The derived half is load-bearing rather than belt-and-braces: the
# Orca abort-cleanup record and every task predating this change carry no
# browser_session= key, and deriving a name for a task that never had a session
# is a harmless no-op. state/<id>.meta presence is the authoritative and cheap
# "the task exists" test and needs no grace period: fm-spawn closes the meta
# write before the launch command is even assembled, and fm-teardown removes the
# meta last, long after it has already retired the session.
# Bounded: at most FM_BROWSER_SWEEP_MAX candidates are acted on per call and the
# rest wait for the next sweep. Filesystem-only unless a bridge is actually
# alive. Reads browser_session= with an inline grep rather than sourcing
# bin/fm-backend.sh so the lib never depends on a caller's sourcing order.
# ROTATED, and that is what keeps the bound from becoming starvation. An identity
# refusal leaves its candidate in place, so it is still a candidate next time,
# while the directory scan order is stable: without rotation a handful of
# permanently unidentifiable sessions would fill the budget from the head of the
# scan on every single call and no orphan behind them would ever be examined
# again, which for a session whose task is gone means its bridge leaks forever
# because this sweep is its only reclaim path. So the name of the last candidate
# acted on is kept in <state-dir>/.last-browser-sweep-cursor - the same
# .last-* watcher-internal marker pattern .last-browser-sweep itself uses - and
# the scan resumes AFTER it, wrapping to the head once for the ones before it.
# Every candidate is therefore reached within a bounded number of calls whatever
# the refusals do, and the per-call cost stays capped. A cursor that cannot be
# written or no longer exists costs nothing but that call's rotation.
fm_browser_sweep_orphans() {  # <fm-home> <state-dir>
  local home=${1-} state_dir=${2-} root prefix meta id val d name max
  local cursor_file cursor pass skipping last='' done_names=''
  local seen='' acted=0 nl=$'\n'
  local LC_ALL=C
  FM_BROWSER_SWEEP_COUNT=0
  FM_BROWSER_SWEEP_NAMES=
  FM_BROWSER_SWEEP_ERRORS=
  [ -n "$home" ] || return 0
  [ -n "$state_dir" ] || return 0
  root=$(fm_browser_state_root)
  [ -d "$root/sessions" ] || return 0
  prefix="fm-$(fm_browser_home8 "$home")-"

  # Live set. nullglob is off and set -u is on, so guard each glob expansion
  # exactly as recorded_windows does in bin/fm-watch.sh.
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    val=$(grep "^browser_session=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -n "$val" ]; then
      case "$seen" in
        *"|$val|"*) ;;
        *) seen="$seen|$val|" ;;
      esac
    fi
    id=$(basename "$meta" .meta)
    val=$(fm_browser_session_name "$home" "$id" 2>/dev/null) || val=
    if [ -n "$val" ]; then
      case "$seen" in
        *"|$val|"*) ;;
        *) seen="$seen|$val|" ;;
      esac
    fi
  done

  max=${FM_BROWSER_SWEEP_MAX:-3}
  case "$max" in
    ''|*[!0-9]*) max=3 ;;
  esac
  cursor_file="$state_dir/.last-browser-sweep-cursor"
  cursor=$(head -1 "$cursor_file" 2>/dev/null || true)
  case "$cursor" in
    *[!A-Za-z0-9._-]*) cursor= ;;
  esac

  # Pass 1 walks past the cursor and acts on what follows it; pass 2 wraps to the
  # head for the ones before it. done_names keeps one candidate from being acted
  # on twice in a single call, and a cursor whose directory is gone simply leaves
  # pass 1 with nothing to do.
  for pass in 1 2; do
    [ "$acted" -lt "$max" ] || break
    skipping=0
    if [ "$pass" = 1 ] && [ -n "$cursor" ]; then
      skipping=1
    fi
    for d in "$root"/sessions/*/; do
      [ -d "$d" ] || continue
      [ "$acted" -lt "$max" ] || break
      name=$(basename "$d")
      if [ "$skipping" = 1 ]; then
        if [ "$name" = "$cursor" ]; then
          skipping=0
        fi
        continue
      fi
      case "$name" in
        "$prefix"*) ;;
        *) continue ;;
      esac
      case "$seen" in
        *"|$name|"*) continue ;;
      esac
      case "$done_names" in
        *"|$name|"*) continue ;;
      esac
      acted=$((acted + 1))
      done_names="$done_names|$name|"
      last=$name
      fm_browser_retire "$home" "$name"
      if [ "$FM_BROWSER_RETIRED" = 1 ]; then
        FM_BROWSER_SWEEP_COUNT=$((FM_BROWSER_SWEEP_COUNT + 1))
        FM_BROWSER_SWEEP_NAMES="$FM_BROWSER_SWEEP_NAMES $name"
      fi
      if [ -n "$FM_BROWSER_ERROR" ]; then
        FM_BROWSER_SWEEP_ERRORS="$FM_BROWSER_SWEEP_ERRORS${FM_BROWSER_SWEEP_ERRORS:+$nl}$FM_BROWSER_ERROR"
      fi
    done
  done
  if [ -n "$last" ]; then
    printf '%s\n' "$last" > "$cursor_file" 2>/dev/null || true
  fi
  return 0
}
