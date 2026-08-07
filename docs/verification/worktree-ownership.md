# Worktree ownership verification

Audience: maintainer verification.

This record supports three active guarantees for the worktree ownership record:

1. Cleanup refuses a worktree it cannot prove is still the task's, and names the identity that disagreed.
2. Cleanup of a genuinely still-owned worktree is unaffected, so the proof is a guard and not an off switch.
3. The record is invisible to git, so it can neither dirty a crewmate's checkout nor be committed, and it does not survive into the next occupant's slot.

[`bin/fm-worktree-owner-lib.sh`](../../bin/fm-worktree-owner-lib.sh) owns the record's location, format, and comparison; [`bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s header owns the refusal's scope and exemptions; [`docs/architecture.md`](../architecture.md#project-modes-are-explicit) owns the mechanism boundary.
Incident chronology stays outside this record.

## Environment

Recorded 2026-08-07 on Darwin 25.5.0 (arm64) with GNU bash 5.3.15, git 2.55.0, Treehouse v2.1.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
Every probe below runs against a scratch repository with its own Treehouse pool root, never a live pool.

## Why the record lives in the git directory

Three candidate locations were measured, because the choice decides both whether the record can leak into a commit and whether a stale claim can survive into the next occupant's slot.
`treehouse return --force` is the operation that recycles a slot, and what it does and does not delete is the deciding fact.

```sh
git init -q -b main "$SB/scratchrepo"
git -C "$SB/scratchrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'max_trees = 2\nroot = "%s"\n' "$SB/pool" > "$SB/scratchrepo/treehouse.toml"
WT=$( cd "$SB/scratchrepo" && treehouse get --lease --lease-holder probe )
GD=$(git -C "$WT" rev-parse --absolute-git-dir)
: > "$WT/untracked-plain"
: > "$WT/untracked-excluded"
printf 'untracked-excluded\n' >> "$(git -C "$WT" rev-parse --git-path info/exclude)"
: > "$GD/fm-task-owner"
git -C "$WT" status --porcelain
git -C "$WT" add -A && git -C "$WT" diff --cached --name-only
( cd "$SB/scratchrepo" && treehouse return --force "$WT" )
```

```
--- git sees (status --porcelain):
?? untracked-plain
--- git add -A stages:
untracked-plain
--- present before treehouse return --force:
  /pool/.treehouse/scratchrepo-f1aac9/1/scratchrepo/untracked-plain
  /pool/.treehouse/scratchrepo-f1aac9/1/scratchrepo/untracked-excluded
  /private/tmp/fm-th-probe.70uSPH/scratchrepo/.git/worktrees/scratchrepo/fm-task-owner
--- present after treehouse return --force:
  /pool/.treehouse/scratchrepo-f1aac9/1/scratchrepo/untracked-excluded
  /private/tmp/fm-th-probe.70uSPH/scratchrepo/.git/worktrees/scratchrepo/fm-task-owner
```

Three facts follow, and together they select the git directory:

- A plain untracked marker in the worktree root is reported by `git status` and is staged by `git add -A`, so it can dirty a checkout and can reach a crewmate's commit.
- `treehouse return --force` removes that plain untracked file but NOT the one listed in `.git/info/exclude`, so an excluded marker survives the return into the next occupant's slot - the stale-claim hazard the record exists to remove.
- A file under the worktree's own git directory is invisible to `git status` and unreachable by `git add -A`, and survives the return exactly as the excluded marker does.

The git directory therefore removes the commit and dirty-checkout hazards outright, and `bin/fm-teardown.sh` closes the survival hazard itself by removing the record immediately before the return and restoring it if the return fails.
`tests/fm-worktree-owner.test.sh` pins the git-invisibility half of this as a regression.

## Ownership refusal, both directions

The pair below is an ablation on one variable.
Both cases build the same task with work that has genuinely landed on a remote, so the landed-work check passes exactly as it did in the incident; the only difference is whether the worktree's ownership record names this task or another lane.

```sh
bash tests/fm-teardown.test.sh
```

```
ok - a recycled worktree slot is refused, and the live lane is left running
ok - an owned worktree with identical landed work still tears down (the guard is not an off switch)
ok - a returned pool slot carries no stale ownership claim
ok - a failed worktree return restores the ownership record instead of trapping the rerun
ok - an older record with no ownership token refuses and names the operator's way out
ok - discard authority does not extend to a worktree that is no longer the task's
ok - a scout's scratch worktree is scratch for the scout, not for whoever holds the slot now
ok - a worktree recorded by two tasks is refused and the conflicting task is named
ok - a worktree owned by another firstmate home is refused
```

The refusing cases assert more than the word `REFUSED`: their fixture logs every `treehouse` and `tmux` invocation, and the assertion is that the log is empty and the task's records and worktree are still present.
A refusal that printed correctly but still returned the worktree would fail these.

## The record's own contract and the operator path back

```sh
bash tests/fm-worktree-owner.test.sh
```

```
ok - a worktree written for a task verifies as that task's
ok - a slot reissued to another task refuses and names that task
ok - a slot held by a sibling firstmate home refuses and names that home
ok - the same task id with a different spawn's token still refuses
ok - a worktree carrying no ownership record refuses
ok - a task record with no ownership token refuses rather than passing
ok - an unreadable ownership record refuses instead of being read as consent
ok - the ownership record neither dirties a worktree nor can be committed
ok - two tasks' records naming one worktree are reported as a conflict
ok - a claim without --confirm shows the evidence and writes nothing
ok - a confirmed claim establishes ownership that cleanup can verify
ok - a claim never overwrites another lane's ownership record
ok - a claim refuses while two tasks record the same worktree
```
