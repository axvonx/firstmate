#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# How recently a pipeline step must have LOGGED for that alone to prove it is
# advancing. Deliberately far above the pane-silence threshold and calibrated
# against measurement rather than taste: on 2026-08-03 this fleet's live
# activity ages reached 445s and gaps between an agent's own progress lines in
# real step logs reached 1213s, so anything near the 240s pane bound would
# simply reproduce the false alarm this predicate exists to remove.
FM_STEP_ACTIVITY_FRESH_SECS=${FM_STEP_ACTIVITY_FRESH_SECS:-1800}

# The hard ceiling on how long a step may go without logging even while its
# agent process is still alive. A live process is evidence of work but not proof
# of progress - a hung agent is also a live process - so tier 2 below must
# expire, or suppression would become a permanent blind spot, which is strictly
# worse than the false alarm. Set well past any single legitimate silent tool
# call (the pipeline's own steps run 10-55 minutes end to end).
FM_STEP_STALL_MAX_SECS=${FM_STEP_STALL_MAX_SECS:-7200}

# How many CONFIRMED-progress absorbs one window may collect before supervision
# surfaces one long-running notice and starts the count again. This is the end of
# the absorb ladder, and it must exist: a counter that never terminates would let
# a run that keeps advancing without ever finishing stay invisible for as long as
# it likes. The arithmetic: an absorb can happen at most once per
# FM_STALE_ESCALATE_SECS per window, so at that 240s default 15 absorbs is a
# first human glance at roughly one hour, then roughly hourly after that. An
# hours-long run deserves exactly that one glance, because progressing and
# finishing are different things, and only a human can decide the run has been
# advancing for longer than the work is worth. The notice is NOT a wedge report
# and says so in its own words, so it can never be confused with the
# no-progress escalation ladder.
FM_STEP_PROGRESS_SURFACE_COUNT=${FM_STEP_PROGRESS_SURFACE_COUNT:-15}

# 0 if crew <id>'s own pipeline run shows it is GETTING ANYWHERE, from the
# `activity: <N>s`, `activity-id: <hash>` and `step-agent: alive|gone` fields
# bin/fm-crew-state.sh emits out of `axi status`.
#
# This is the question crew_is_provably_working cannot answer. That predicate is
# a boolean about the current step's STATE, so a run whose step froze still
# reads `working` forever, and the wedge ladder escalated on pane silence alone.
#
# WHY LAST-ACTIVITY ALONE IS NOT ENOUGH - the trap to avoid re-entering. That
# field is the one that sounds like it means "is it working", and it does not:
# it tracks the agent's LOG LINES. A step that begins with a long tool call - a
# build, a full test suite, an install - logs its opening line and then goes
# quiet for minutes while doing exactly what it should. Measured 2026-08-03 on
# mkt-pr40-takeover's test step: last_activity read 6m18s old while that run's
# gate worktree was writing build output 2 minutes old. It was compiling. It was
# fine. Judging that on log recency alone calls a healthy build wedged.
#
# AND WHY RECENCY IS NOT CHANGE - the second half of the same trap. A fresh age
# only says the agent wrote something recently, not that it got anywhere: a
# retry/backoff loop, or a fix round re-entering the same failure, keeps logging
# at a healthy cadence forever. So tier 1 requires the log MESSAGE to differ from
# the one seen at the previous observation, through the activity-id digest, and
# the previous digest is remembered in the caller's per-window memo file. A memo
# file that does not exist yet is a first observation and counts as changed; an
# absent digest, or a caller that supplies no memo path at all, cannot show
# change and therefore cannot absorb an agent-run step through tier 1.
#
# THAT CHANGE REQUIREMENT IS SCOPED TO ITS PURPOSE, which is catching a looping
# AGENT. A step with no subprocess agent - the ci monitor, which polls checks for
# up to the tool's whole ci timeout - cannot loop that way, and its progress
# markers are fixed strings that repeat verbatim between observations. It also
# has no pid, so tier 2 can never absorb it. Requiring changed text there would
# escalate the canonical legitimate absorb case (a run sitting on a static pane
# waiting for CI) every STALE_ESCALATE_SECS, so a step that reports it has no
# agent is read on recency alone.
#
# THAT LICENCE NEEDS THE POSITIVE READING `step-agent: none`, and an ABSENT
# step-agent field must never substitute for it. The two mean opposite things: a
# reader that read the pid column and found it empty knows there is no agent,
# while a reader that could not read the column knows nothing. Publishing
# nothing for both, and trusting absence, would mean one rendering change - the
# pid losing its quotes, against a column that is an INTEGER - silently moved
# every agent-run step onto the recency-only path and disabled the agent-loop
# guard fleet-wide, with no alarm. So absence falls back to requiring a changed
# digest, and tier 2 stays unavailable to it: an uncertain reading escalates.
#
# So the decision is two-tiered, and escalates only when BOTH are negative:
#   tier 1  the step logged within FM_STEP_ACTIVITY_FRESH_SECS AND either logged
#           something DIFFERENT from last time or reports `step-agent: none`
#           -> advancing
#   tier 2  the step's agent process is still alive AND the silence has not yet
#           reached FM_STEP_STALL_MAX_SECS -> advancing
# Tier 2 covers exactly the quiet-build case, and also the healthy step that
# legitimately logs one identical line twice, so tier 1's change requirement
# cannot escalate a working run on its own. Tier 2's ceiling is what keeps a
# genuinely hung agent escalating rather than being suppressed forever, and the
# recency-only path stays bounded the same way any absorb does: a monitor whose
# age grows past FM_STEP_ACTIVITY_FRESH_SECS has no tier 2 to fall back on, so it
# escalates.
#
# Neither tier bounds how MANY times one window may be absorbed, on purpose: an
# advancing run is not a wedge and must not be reported as one. That total is
# bounded by the callers instead, through FM_STEP_PROGRESS_SURFACE_COUNT, which
# surfaces one long-running notice and starts over.
#
# Rejected alternatives, so they are not retried: `active_for` and the steps[]
# table's duration_ms both measure elapsed time, so they climb for a frozen step
# and cannot indicate progress at all; filesystem recency in the gate worktree
# is the strongest signal but needs a path this reader does not have, and the
# build output a naive filter would exclude was the very evidence that settled
# the measurement above.
#
# Fails to 1 on every uncertain reading - no run attributed, a run read from
# anything but an authoritative run-step (crew-authored status-log prose can say
# whatever it likes, including the word `activity:`), a terminal or
# coarsely-attributed run, no activity reading, an unparseable age, an
# unreadable agent-pid column, an unchanged digest on a step whose agent is not
# alive - so a missing answer escalates exactly as before rather than silently
# suppressing a real wedge. Costs one bounded fm-crew-state.sh read, so callers
# run it only at escalation time, never every poll.
crew_step_is_advancing() {  # <id> [activity-memo-file]
  local id=$1 memo=${2:-} line src age digest prev agent changed=no
  [ -n "$id" ] || return 1
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) return 1 ;; esac
  src=${line#*source: }
  src=${src%% *}
  [ "$src" = run-step ] || return 1
  case "$line" in
    *"activity: "*) ;;
    *) return 1 ;;
  esac
  age=${line#*activity: }
  age=${age%% *}
  age=${age%s}
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  # Change detection. The memo is refreshed on every observation that carries a
  # digest, including one that does not absorb, so the next comparison is always
  # against the most recent reading.
  case "$line" in
    *"activity-id: "*)
      digest=${line#*activity-id: }
      digest=${digest%% *}
      ;;
    *) digest='' ;;
  esac
  if [ -n "$digest" ] && [ -n "$memo" ]; then
    prev=$(cat "$memo" 2>/dev/null || true)
    [ "$prev" = "$digest" ] || changed=yes
    printf '%s' "$digest" > "$memo" 2>/dev/null || true
  fi
  # An empty agent means the field was not published at all, which says only
  # that the reading is unavailable - never that no agent exists. Only the
  # explicit `none` says that.
  case "$line" in
    *"step-agent: "*)
      agent=${line#*step-agent: }
      agent=${agent%% *}
      ;;
    *) agent='' ;;
  esac
  # Tier 1: a NEW log line is progress on its own, and so is any recent log line
  # from a step that REPORTS it has no agent to loop. Written as an if rather
  # than `test && return`, whose non-zero list status would abort a future caller
  # that adds set -e.
  if [ "$age" -lt "$FM_STEP_ACTIVITY_FRESH_SECS" ] \
    && { [ "$changed" = yes ] || [ "$agent" = none ]; }; then
    return 0
  fi
  # Tier 2: a quiet but live agent, bounded.
  [ "$agent" = alive ] || return 1
  [ "$age" -lt "$FM_STEP_STALL_MAX_SECS" ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
