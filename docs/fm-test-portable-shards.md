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

The split is a pinned assignment table in `list_portable_serial_pinned` plus a stable CRC of the basename for everything not pinned.
The pinned table is longest-processing-time over the measured heavyweights, which carry ~1043 s of the lane's ~1174 s; the hash spreads the remaining small scripts.

Hashing the basename puts new scripts in both halves, so growth is shared rather than piling onto one half.
A stale balance only skews wall clock; it cannot drop a script, because both halves are computed from the same residual and the coverage guard proves they partition it.

Counts below are as of this commit; durations are the per-script measurements from the 2026-08-02 CI artifact, applied to the current assignment.

| Lane | Script count | Measured duration |
|---|---:|---:|
| `portable-serial-1` | 32 | ~577 s |
| `portable-serial-2` | 39 | ~592 s |
| imbalance | | ~16 s (1.3%) |

The 577 s / 592 s figures are the sums of the 45 rows in the per-script table below (576.5 s and 592.3 s exactly).
26 of the 71 residual scripts are not in that table (12 in half 1, 14 in half 2), and they break down as:

- **25 measured, ~5 s in total across both halves.** The 2026-08-02 artifact timed them; they are the sub-second tail, and subtracting the ~1169 s of listed rows from the artifact's 1174 s lane total leaves the same ~5 s. They are excluded from the 577/592 sums, so each half's true cost is a couple of seconds higher.
- **1 unmeasured.** `tests/fm-ci-run-serial-lane.test.sh`, added by this change, in half 1. The artifact covered 70 scripts and the residual is now 71.

So the uncertainty in the split is one new script plus ~5 s of known sub-second work - not 26 scripts of unknown cost.

Re-derive both columns from a recent `fm-test-timing-portable-serial-*` artifact when rebalancing.

#### This split resets the clock, it does not stop it

The lane grows by roughly 1.4 scripts and 30 s per day, measured over the twelve-day trend below.
Splitting it halves the rate each half sees, to about 15 s per day, but the growth does not stop and neither half has a rebalance trigger.
Against the 780 s budget:

- half 1: (780 - 577) / 15 = **~13.5 days**
- half 2: (780 - 592) / 15 = **~12.5 days**

So this buys roughly **13 days** of headroom from 2026-08-02, putting the projected first overrun around **2026-08-15**.
The hash changes *which* half trips and stops one half absorbing everything, but both halves now approach the budget together, so the next remedy is a third host or a real speedup - not another rebalance.
Do not read the current 1.3% imbalance as durable headroom.

#### Half assignment as of this commit

Durations are the 2026-08-02 CI artifact (PR1 / PR2 columns); the `half` column is recomputed from `list_portable_serial_pinned` plus `portable_serial_half_for` in `bin/fm-test-run.sh` and supersedes any earlier copy of this table.
21 of these 45 rows changed half in the CRC rebalance.

Provenance, so a reader knows which figures were checked rather than carried forward:

| Figure | Source |
|---|---|
| `half` column, all 45 rows | recomputed from the lane listings on this commit and diffed against them (0 mismatches) |
| counts 32 / 39 / 71, unlisted 12 / 14 | counted from `--list --lane portable-serial{,-1,-2}` on this commit |
| 576.5 s / 592.3 s per-half sums | summed from the PR1 column of this table |
| trip-day arithmetic and 2026-08-15 | derived from those sums, shown inline above |
| PR1 / PR2 per-script durations, ~5 s tail, 1174 s / 1185 s lane totals, growth rate | carried from the 2026-08-02 CI artifact, not re-measured here |

| # | script | PR1 | PR2 | half |
|--:|---|--:|--:|:--:|
| 1 | fm-pr-check-security.test.sh | 205.6s | 210.2s | 1 |
| 2 | fm-watch-triage.test.sh | 127.3s | 128.9s | 2 |
| 3 | fm-watcher-lock.test.sh | 98.6s | 99.2s | 2 |
| 4 | fm-secondmate-harness.test.sh | 88.3s | 88.8s | 1 |
| 5 | fm-bearings-snapshot.test.sh | 61.9s | 61.9s | 2 |
| 6 | fm-claude-stop-autoarm.test.sh | 60.5s | 60.6s | 2 |
| 7 | fm-procevent.test.sh | 48.5s | 48.6s | 1 |
| 8 | fm-vendor-auth-probe.test.sh | 42.8s | 42.8s | 1 |
| 9 | fm-spawn-dispatch-profile.test.sh | 41.5s | 41.6s | 1 |
| 10 | fm-session-start.test.sh | 38.8s | 41.6s | 2 |
| 11 | fm-afk-inject-e2e.test.sh | 33.7s | 33.7s | 2 |
| 12 | fm-secondmate-safety.test.sh | 24.8s | 24.9s | 2 |
| 13 | fm-wake-queue.test.sh | 24.2s | 23.7s | 1 |
| 14 | fm-public-followup.test.sh | 23.7s | 24.2s | 1 |
| 15 | fm-teardown.test.sh | 23.6s | 23.7s | 2 |
| 16 | fm-bootstrap.test.sh | 22.5s | 22.8s | 2 |
| 17 | fm-pi-watch-extension.test.sh | 17.1s | 16.9s | 1 |
| 18 | fm-backend.test.sh | 16.5s | 16.5s | 1 |
| 19 | fm-daemon.test.sh | 15.5s | 15.5s | 2 |
| 20 | fm-fleet-sync.test.sh | 15.1s | 15.0s | 2 |
| 21 | fm-busy-adapter-wiring.test.sh | 14.1s | 14.1s | 1 |
| 22 | fm-kimi-harness.test.sh | 12.7s | 12.7s | 1 |
| 23 | fm-secondmate-sync.test.sh | 12.5s | 12.5s | 2 |
| 24 | fm-backend-orca.test.sh | 12.3s | 12.4s | 2 |
| 25 | fm-pending-reply.test.sh | 7.6s | 7.7s | 1 |
| 26 | fm-tangle-guard.test.sh | 7.3s | 7.3s | 1 |
| 27 | fm-secondmate-liveness.test.sh | 6.9s | 6.9s | 2 |
| 28 | fm-turnend-guard.test.sh | 6.2s | 6.2s | 1 |
| 29 | fm-fleet-snapshot-view.test.sh | 6.1s | 6.2s | 2 |
| 30 | fm-herdr-session-cleanup.test.sh | 5.0s | 5.0s | 1 |
| 31 | fm-secondmate-lifecycle-e2e.test.sh | 4.9s | 4.9s | 2 |
| 32 | fm-spawn-worktree-settle.test.sh | 4.6s | 4.6s | 1 |
| 33 | fm-backend-zellij.test.sh | 4.3s | 4.4s | 1 |
| 34 | fm-startup-memory-budget.test.sh | 4.3s | 4.4s | 2 |
| 35 | fm-wake-daemon-lifecycle-e2e.test.sh | 4.3s | 4.3s | 1 |
| 36 | fm-watch-checkpoint.test.sh | 4.0s | 4.0s | 2 |
| 37 | fm-shared-captain-inheritance.test.sh | 3.6s | 3.6s | 2 |
| 38 | fm-guard-stale-banner.test.sh | 3.0s | 3.1s | 2 |
| 39 | fm-backlog-handoff.test.sh | 2.9s | 2.9s | 2 |
| 40 | fm-gate-refuse.test.sh | 2.9s | 2.9s | 2 |
| 41 | fm-backend-cmux.test.sh | 2.4s | 2.4s | 2 |
| 42 | fm-send-secondmate-marker.test.sh | 2.2s | 2.2s | 2 |
| 43 | fm-update.test.sh | 2.0s | 2.0s | 2 |
| 44 | fm-afk-return.test.sh | 1.1s | 1.1s | 1 |
| 45 | fm-teardown-endpoint-safety.test.sh | 1.1s | 1.1s | 1 |

Lane totals on that artifact: PR1 1174 s, PR2 1185 s.
The 26 scripts not listed are unmeasured or sub-second; `tests/fm-ci-run-serial-lane.test.sh`, added by this change, lands in half 1.
Regenerate the `half` column with `bin/fm-test-run.sh --list --lane portable-serial-1` and `--lane portable-serial-2`.

Twelve-day trend behind the growth rate, three CI runs sampled per day, median wall / script count: day -11 13.4m/53, day -10 14.4m/56, day -9 14.1m/59, day -8 15.0m/59, day -7 14.8m/61, day -6 16.3m/61, day -5 16.5m/63, day -4 16.9m/63, day -3 17.5m/62, day -2 18.2m/67, day -1 19.0m/69, day 0 19.4m/69.

### Time budget

Each serial half runs under `bin/fm-ci-run-serial-lane.sh`, which bounds the suite with `FM_SERIAL_BUDGET_SECONDS` below the job's `timeout-minutes`.
An overrun then surfaces as an ordinary step failure with a named annotation instead of a job cancellation, which GitHub reports as `cancelled` and `gh pr checks` renders as an indistinguishable `fail`.
`bin/fm-test-run.sh` flushes a partial timing artifact on `INT`/`TERM` and marks it `"interrupted": true`, so an overrun still ships the per-script durations measured before the stop.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It additionally verifies that `portable-serial-1` and `portable-serial-2` partition `portable-serial` exactly, so a rebalance can neither duplicate nor drop a script.

## Timing artifacts

Portable shards, each portable serial half, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1/2 | 15 | Each measured half is about ten minutes, so this is a hang tripwire with roughly 50% headroom. `FM_SERIAL_BUDGET_SECONDS` (780) trips first, inside the step. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
For the serial halves the job cap is the outer backstop only: the in-step budget above is what a normal overrun hits, because a job cancellation is the failure mode this lane deliberately avoids.
