# CI checks-green reading verification

Audience: maintainer verification.

This record supports the current guarantee in `bin/fm-crew-state.sh` that a pull request is never reported as passing while its checks have not concluded.
It also records the one trigger that firstmate's layer cannot detect, so a future maintainer does not rebuild a workaround for it here.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## What the gate reads

`no-mistakes axi status` cannot distinguish "still waiting on checks" from "checks green, waiting on merge": for a repo where merge is left to the captain, both read as `ci,running`.
The transition is recorded only in the ci step's own log text, which `nm_ci_checks_state` reads through `axi logs --step ci --run <id>`.

## Marker census

Run on 2026-08-03 against no-mistakes v1.41.2 (867d64d), over the real run logs on this machine:

```sh
cat ~/.no-mistakes/logs/*/ci.log \
  | grep -oE "no CI checks reported[^\"]{0,60}|CI checks passed|CI checks running[^\"]{0,40}|checks failed[^\"]{0,40}" \
  | sort | uniq -c | sort -rn
```

Observed output:

```
  41 all CI checks passed - still monitoring until merged or clos
  40 CI checks running, waiting for results...
  10 no CI checks reported yet, waiting for checks to register...
   4 no CI checks reported - still monitoring until merged or closed
```

## The absent-checks marker is not terminal

`no CI checks reported - still monitoring until merged or closed` states that no check could be enumerated.
All four occurrences were inspected with `grep -B3 -A3`.
None is followed by a pass; each is followed by one of `CI checks running, waiting for results...` (run `01KZ1YVW3CPE8A1GABQDJXTZNV`, where checks registered only after the marker), `PR has been closed` (`01KZ0S73WYZREZE8F9ZB0SH1C9`), or `error: context canceled` (`01KZ0S4N755Y2A64XE9DMMP076`, `01KZ1YVASZT62YF0NG35PS0V8B`).

That marker previously mapped to `green`, which reported the PR to the captain as `checks green: PR ready for review`.
It now maps to `not-ready`, and an indeterminate reading while the ci step is monitoring is held as working rather than surfaced.

## Regression coverage

`tests/fm-crew-state.test.sh` pins all three readings through the helper's own output:

- `test_ci_monitoring_no_checks_never_surfaces_green`
- `test_ci_ready_done_log_with_absent_checks_stays_working`
- `test_ci_ready_done_log_with_indeterminate_ci_stays_working`

Each was confirmed to fail against the pre-fix helper with `state: done` and pass after it.

## Bounded limitation: a required job that never runs is not visible here

A required job can fail to be triggered at all, for example when a conflicted branch stops the forge computing a merge commit, so no `pull_request` event fires.
The remaining unrelated checks are green and the pull request presents as passing.

This misread is upstream in no-mistakes' own ci step, not in how firstmate queries check state.
The ci step emits the bare aggregate `all CI checks passed - still monitoring until merged or closed` and never names the checks it saw, so the log firstmate reads carries no evidence that distinguishes a complete required set from whichever checks happened to exist.
Requiring the expected job by name is therefore not implementable from this log, and firstmate does not work around it at this layer.
