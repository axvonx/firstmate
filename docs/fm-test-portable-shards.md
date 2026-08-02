# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.

### Why CI splits it in two

These scripts are serial with respect to peers on the same machine: they take watcher locks, start AFK daemons and tmux servers, and drive poll migration through shared paths.
Two CI jobs are two hosts, so that contention does not apply across them.
CI therefore runs `portable-serial-1` and `portable-serial-2` on separate runners, each still strictly serial internally, which halves the lane's wall clock without relaxing the isolation contract that keeps these scripts out of the parallel shards.
Running `--lane portable-serial` locally still executes the whole remainder on one machine.

The split is a pinned heavy list in `list_portable_serial_heavy` plus an automatic remainder.
Five scripts carry half the lane, so every other script - including every newly added one - lands in `portable-serial-2` without maintenance.
A stale balance only skews wall clock; it cannot drop a script, because both halves are computed from the same residual.

| Lane | Script count | Measured duration (2026-08-02 CI) |
|---|---:|---:|
| `portable-serial-1` | 5 | ~582 s |
| `portable-serial-2` | 65 | ~592 s |
| imbalance | | ~10 s |

### Time budget

Each serial half runs under `bin/fm-ci-run-serial-lane.sh`, which bounds the suite with `FM_SERIAL_BUDGET_SECONDS` below the job's `timeout-minutes`.
An overrun then surfaces as an ordinary step failure with a named annotation instead of a job cancellation, which GitHub reports as `cancelled` and `gh pr checks` renders as an indistinguishable `fail`.
`bin/fm-test-run.sh` flushes a partial timing artifact on `INT`/`TERM` and marks it `"interrupted": true`, so an overrun still ships the per-script durations measured before the stop.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It additionally verifies that `portable-serial-1` and `portable-serial-2` partition `portable-serial` exactly, so a rebalance can neither duplicate nor drop a script.

## Timing artifacts

Portable shards, the portable serial lane, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial | 20 | The serial remainder needs a larger hang tripwire. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
