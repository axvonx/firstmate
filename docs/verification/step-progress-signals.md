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

`agent_pid` is a live local process:

```sh
ps -o command= -p 40534
```

```
claude -p --verbose --output-format stream-json --json-schema ...
```

It is populated only while a step runs.
Across this machine's recorded step results, every `completed`, `pending`, `failed` and `skipped` row had it cleared and only the `running` row carried a value, so its absence is ordinary and must not be read as a wedge.

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

## Regression pointers

- `tests/fm-crew-state.test.sh` pins pipeline-owned attribution, its stale-submitted-head and wrong-run rejections, the duration parsing, and agent-pid liveness publication.
- `tests/fm-watch-triage.test.sh` pins both escalation directions through the watcher: an advancing step and a quiet-but-live agent are absorbed, while a stopped activity age and a live agent past the stall ceiling still escalate.
