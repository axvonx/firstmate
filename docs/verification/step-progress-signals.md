# Pipeline step progress signals verification

Audience: maintainer verification.

This record supports two current guarantees.
First, `bin/fm-crew-state.sh` attributes a no-mistakes run that the pipeline currently owns, even though its head is unknown to the crew's worktree.
Second, `crew_step_is_advancing` in `bin/fm-classify-lib.sh` decides whether a silent pipeline step is advancing or frozen, and its two thresholds are set from the measurements below rather than from taste.
Task-specific chronology, temporary paths, and delivery transcripts remain in private reports or PR evidence.

All observations were taken on 2026-08-03 against no-mistakes v1.41.2 (867d64d).

## A running fix round hides its head from the crew worktree

`no-mistakes axi status`, run inside a crew worktree whose branch has an active run, emits a `branch_sync` block:

```
run:
  head: 29bcdbf1
branch_sync:
  state: pipeline_owned
  local:
    head: b63807c7548ee606908161b6b2ed8139891560ec
  pipeline:
    run: "01KZ57JGY4B1R07XXMG3DWKD66"
    submitted_head: b63807c7548ee606908161b6b2ed8139891560ec
    current_head: 29bcdbf167bfdeb32903a064eae7e800d7d00885
```

The pipeline commits in its own gate worktree, so its head is not merely ahead of the crew worktree; it is absent from that worktree's object store:

```sh
git -C <crew worktree> rev-parse --verify '29bcdbf1^{commit}'
```

```
fatal: Needed a single revision
```

A head comparison therefore cannot resolve the run head at all, and every lane mid-fix-round read `state: unknown · source: none`.
`submitted_head` equal to `local.head`, for the run being reported, is what re-establishes code identity without letting a stale run bind.

A worktree whose branch has no run of its own receives another branch's run for display and **no** `branch_sync` block, so the block's presence is itself branch-scoped evidence.

## Progress fields on an active step

A running run carries an `active_steps` block that a terminal run does not:

```
active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
  review,fixing,1h7m,"25s ago: log: Round 4. Reviewing `29bcdbf`.","90709",fix 3
```

`last_activity` renders as a compact duration whose unit components are dropped when unused: `13s`, `59m50s`, and at the hour boundary `1h0m`, with the seconds component gone.
Summing every `<number><unit>` pair parses all three forms; a string that yields no pair is rejected rather than read as a fresh age.

The duration is also not always the first thing in the field, because the field carries prefixes.
Once step silence passes the tool's own `step_quiet_warning` (10m on this machine's `~/.no-mistakes/config.yaml`), the same field renders with a `quiet` prefix while the duration still reports the true age:

```
active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
  test,running,12m30s,"quiet 10m4s ago: log: running the suite","90709",
```

The parser therefore DERIVES the duration by its own pattern wherever it appears in the row, taking the first `<number><unit>...` group followed by ` ago:`, which is the suffix that distinguishes it from `active_for`.
It deliberately does not enumerate known prefixes, and it deliberately does not read the `quiet` marker as a signal: the marker only restates that the age has passed a threshold this reader measures itself, and any future prefix would silently blind an enumerating parser the same way an opening-quote anchor did.

`agent_pid` is a live local process:

```sh
ps -o command= -p 40534
```

```
claude -p --verbose --output-format stream-json --json-schema ...
```

It is populated only while a SUBPROCESS AGENT runs the step.
Across this machine's recorded step results, every `completed`, `pending`, `failed` and `skipped` row had it cleared and only the `running` row carried a value, and no `ci` monitor row has ever carried one at all, because that step polls checks rather than running an agent.
So its absence is ordinary and must not be read as a wedge; it means either no agent yet or a step kind that has none.

## Why last activity alone is not sufficient

`last_activity` tracks the agent's log lines, not its work.
A step that opens with a long tool call logs one line and then goes quiet while working.
Measured on the `mkt-pr40-takeover` test step: `last_activity` read `6m18s ago` while that run's gate worktree was writing build output two minutes old.
The step was compiling and was healthy.

Observed silence, for threshold calibration:

- live activity ages reached 445s while a step was demonstrably working;
- gaps between an agent's own timestamped progress lines in real step logs reached 1213s.

`FM_STEP_ACTIVITY_FRESH_SECS` is 1800s, clearing both with margin, because anything near the 240s pane bound reproduces the false escalation this check exists to remove.
`FM_STEP_STALL_MAX_SECS` is 7200s and bounds the live-agent tier, because a hung agent is also a live process and an unbounded tier would convert a false alarm into a permanent blind spot.

`active_for` and the `steps[]` table's `duration_ms` were both rejected as progress signals: they measure elapsed time, so they keep climbing for a frozen step.

## Why recency is not change either

A fresh `last_activity` age proves the agent wrote something recently, not that the run got anywhere.
The rendered field carries both halves of the evidence:

```
active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
  review,fixing,1h7m,"25s ago: log: Round 4. Reviewing `29bcdbf`.","90709",fix 3
```

A step that re-enters the same failure re-renders the same message with a fresh age indefinitely, which is exactly the looping case `.agents/skills/stuck-crewmate-recovery/SKILL.md` names as genuine wedging.
So the message half, everything after `<duration> ago:` up to the quote that closes the field, is digested and published as `activity-id`, and the freshness tier requires that digest to differ from the previous observation's.
The digest deliberately excludes `active_for` and the duration, both of which climb on every read and would make every digest differ.

Change detection alone is still not enough, for the opposite reason: a fix round that logs `Round 1`, `Round 2`, `Round 3` has changing text on every observation while getting nowhere.
Two content-independent bounds cover that.
The no-progress escalation count is not cleared by an intervening absorb, so `demand-deep-inspection` stays reachable for a lane that only sometimes looks busy.
And `FM_STEP_PROGRESS_SURFACE_COUNT` bounds the absorbs themselves: because an absorb can happen at most once per `FM_STALE_ESCALATE_SECS` per pane, its default of 15 puts a first human glance at roughly one hour at the 240s bound, then roughly hourly.
That notice is worded as long-running rather than wedged, because the lane is healthy; it exists because progressing and finishing are different things, and only a human can judge that a run has been advancing for longer than the work is worth.

## Where change detection does not apply

The changed-digest rule exists to catch a looping AGENT, so it is scoped to steps that have one.
A `ci` monitor publishes no `agent_pid`, and its own progress markers are fixed strings that repeat verbatim between observations:

```
all CI checks passed - still monitoring until merged or closed
no CI checks reported - still monitoring until merged or closed
```

Requiring changed text there would escalate the canonical legitimate absorb case, a run sitting on a static pane waiting for CI, every `FM_STALE_ESCALATE_SECS` for as long as the tool's own `ci_timeout` allows.
So where no step agent is published at all, log recency alone reads as advancing.
The absence of the field is the discriminator: `step-agent: gone` means an agent existed and its process died, and that still has to prove change.
The recency-only path stays bounded, because such a step has no live-agent tier to fall back on once its age passes `FM_STEP_ACTIVITY_FRESH_SECS`, and because the `FM_STEP_PROGRESS_SURFACE_COUNT` ladder counts its absorbs like any other.

## Regression pointers

- `tests/fm-crew-state.test.sh` pins pipeline-owned attribution, its stale-submitted-head and wrong-run rejections, the duration parsing including prefixed renderings, agent-pid liveness publication, the absence of a step-agent field for an agentless step, and the activity digest (stable for identical text, different for changed text).
- `tests/fm-watch-triage.test.sh` pins both escalation directions through the watcher: an advancing step, a quiet-but-live agent, and an agentless step logging recently are absorbed, while a stopped activity age, an unchanged activity message with a dead agent, and a live agent past the stall ceiling all escalate.
- `tests/fm-watch-triage.test.sh` also pins the two bounds: an absorb no longer clears the no-progress count, and a lane that keeps changing its log text without progressing surfaces one long-running notice per `FM_STEP_PROGRESS_SURFACE_COUNT` absorbs.
- `tests/fm-daemon.test.sh` pins the same recheck and the same absorb ladder in away mode.
