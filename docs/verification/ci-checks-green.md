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
  | grep -oE "no CI checks reported[^\"]{0,60}|all CI checks passed[^\"]{0,40}|CI checks running[^\"]{0,40}|checks failed[^\"]{0,40}" \
  | sort | uniq -c | sort -rn
```

Observed output:

```
  41 all CI checks passed - still monitoring until merged or clos
  40 CI checks running, waiting for results...
  10 no CI checks reported yet, waiting for checks to register...
   4 no CI checks reported - still monitoring until merged or closed
```

The two active-monitor counts are a snapshot: every later run appends to this corpus, so a re-run reports higher totals for the pass and the running marker while the marker set itself is unchanged.
The `{0,40}` bound is what truncates the recorded pass line at `clos`.

## The absent-checks marker is not terminal

`no CI checks reported - still monitoring until merged or closed` states that no check could be enumerated.
All four occurrences were inspected with `grep -B3 -A3`.
None is followed by a pass; each is followed by one of `CI checks running, waiting for results...` (run `01KZ1YVW3CPE8A1GABQDJXTZNV`, where checks registered only after the marker), `PR has been closed` (`01KZ0S73WYZREZE8F9ZB0SH1C9`), or `error: context canceled` (`01KZ0S4N755Y2A64XE9DMMP076`, `01KZ1YVASZT62YF0NG35PS0V8B`).

That marker previously mapped to `green`, which reported the PR to the captain as `checks green: PR ready for review`.
It now maps to `not-ready`, and an indeterminate reading while the ci step is monitoring is held as working rather than surfaced.

## What reports checks green, and what does not

Two readings of an attributed run report a PR as passing.
The first is the affirmative ci-step log marker above.
The second is the run's own terminal `outcome: checks-passed`, which `bin/fm-crew-state.sh` maps to `state: done` with the detail `checks green: PR ready for review`.
Both rest on the same upstream aggregate, so both carry the bounded limitation recorded below.

A crew's own `done: PR <url> checks green` status line is neither of those: it is a claim about CI, not a reading of it.
While a run is attributed and still working, that claim never surfaces the PR as ready on its own.
The helper previously carried a path that did exactly that: a checks-green status line was emitted as `state: done` with `source: status-log` while the attributed run read working.
That override was removed rather than guarded, because on every reachable path it surfaced an uncorroborated claim.
Inside the ci-monitor phase it was already redundant, since an affirmative green reading sets the run state to done earlier with its own detail; outside that phase, and under coarse attribution where no run id exists to read a log for, it had no CI reading to corroborate it at all.

The behavior change is confined to the uncorroborated claim: such a crew now stays working until a CI reading confirms it, and both genuine green readings are untouched.

## Residual: with no run attributed, the crew's word stands

The bound above is narrower than "a crew's claim is never taken at face value", and the difference is deliberate.
When no run can be attributed at all, and the crew's endpoint is readable with an exact idle verdict, the no-run fallback (script header section 4) reports the status log's last line as-is, so a `done: PR <url> checks green` line does surface as `state: done` with `source: status-log`.
That happens when the bounded `axi status` call returns nothing, when `no-mistakes` is not on PATH, or when the run has aged out of the runs list.

This is not the defect that was removed above.
There a run was attributed, so corroboration was available and was skipped; here there is no run to corroborate against, because none was found.
The same fallback is how pre-validation crews, direct-PR crews, scouts, and secondmates report completion at all, so suppressing it would mean a crew whose run aged out, or whose bounded status call timed out, could never report a finished PR.
The claim is therefore taken at face value in exactly one condition - no run attributed - and never while an attributed run is still working.

## Regression coverage

`tests/fm-crew-state.test.sh` pins every reading through the helper's own output:

- `test_ci_monitoring_no_checks_never_surfaces_green`
- `test_ci_ready_done_log_with_absent_checks_stays_working`
- `test_ci_ready_done_log_with_indeterminate_ci_stays_working`
- `test_ci_ready_done_log_without_ci_reading_stays_working`
- `test_coarse_run_does_not_probe_other_branch_ci_log`
- `test_ci_monitoring_checks_green_surfaces_done` and `test_top_level_ci_checks_green_surfaces_done`, which pin that a real green reading still surfaces

The first three were confirmed to fail against the pre-marker-fix helper with `state: done` and pass after it.
The next two were each run against the helper as it stood before the override was removed, and both reported the uncorroborated claim as ready:

```
state: done · source: status-log · PR https://github.com/o/r/pull/2 checks green · run still monitoring PR
state: done · source: status-log · PR https://github.com/o/r/pull/4 checks green · run still monitoring PR
```

The first is the non-ci-phase run at its review step, the second the coarse-attribution fixture.
Both now report `state: working` with `source: run-step`.

## Bounded limitation: a required job that never runs is not visible here

A required job can fail to be triggered at all, for example when a conflicted branch stops the forge computing a merge commit, so no `pull_request` event fires.
The remaining unrelated checks are green and the pull request presents as passing.

This misread is upstream in no-mistakes' own ci step, not in how firstmate queries check state.
The ci step emits the bare aggregate `all CI checks passed - still monitoring until merged or closed` and never names the checks it saw, so the log firstmate reads carries no evidence that distinguishes a complete required set from whichever checks happened to exist.
Requiring the expected job by name is therefore not implementable from this log, and firstmate does not work around it at this layer.

This limitation reaches firstmate through both affirmative readings named above, and the terminal `outcome: checks-passed` is where it usually lands: by the time the run is terminal the ci step has already emitted that bare pass, so the outcome inherits it.
An audit of false-green vectors has to cover both, not the ci-log marker alone.
