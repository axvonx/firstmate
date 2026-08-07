# Worker credential delivery verification

Audience: maintainer verification.

This record supports four active guarantees for the credentials a crewmate reaches:

1. A worker gets its firstmate home's `.env` credentials even when nothing on the machine sets them, and gets them byte-exact.
2. A credential the home does not declare is genuinely absent for the worker, rather than being satisfied from somewhere else.
3. A home whose own `.env` delivers no worker credential reads its primary's, announced on stderr, and its own file wins whenever it actually delivers one.
4. No credential value is printed on any path, including when the file cannot be parsed.

[`docs/configuration.md`](../configuration.md#worker-credentials-env) owns the operator-facing contract, `bin/fm-worker-env-lib.sh` owns the parser and eligibility rules, and `bin/fm-worker-env-exec.sh` owns the delivery mechanism.
Task chronology stays outside this record.

## Environment

Recorded 2026-08-07 on macOS 26.5.2 (Darwin 25.5.0, arm64) with GNU bash 5.3.15, zsh 5.9, fish 4.8.1, tmux 3.7b, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).

## Why the delivery test is end to end

The mechanism cannot be verified from a unit test of the loader, and this is empirical rather than cautious.
The first implementation sourced the loader into the crewmate's pane shell, in the same way `fm-spawn.sh` delivers `GOTMPDIR`.
It passed every unit test and failed completely in the first real spawn: worker panes on this machine run fish, under both herdr and tmux, and fish cannot parse a POSIX shell library.

```sh
fish -c '. bin/fm-worker-env-lib.sh'
```

```
~/firstmate/bin/fm-worker-env-lib.sh (line 62): Unexpected ')' found, expecting '}'
    PATH|HOME|SHELL|USER|LOGNAME|IFS|ENV|BASH_ENV) return 0 ;;
                                                 ^
```

`tests/fm-worker-env-spawn-e2e.test.sh` therefore drives the real `bin/fm-spawn.sh` into a real pane and pins the scratch server's `default-shell` to fish wherever fish exists.
It also points the pane shell at an empty `XDG_CONFIG_HOME`, without which the "the key is gone" cases would measure the operator's own shell configuration instead of firstmate's delivery.

## Delivery, ablation, inheritance, and the empty-home case

A real crewmate spawn takes its worktree from `treehouse get`, so the suite needs tmux and treehouse and prints `skip:` without them - read the first line before reading the run as a proof.
CI runs it in the real-Herdr lane, the only lane that installs the pinned Treehouse build (`bin/fm-test-run.sh` maps it to that family for exactly that reason).

```sh
bash tests/fm-worker-env-spawn-e2e.test.sh
```

```
ok - fm-spawn.sh: a worker has its credentials with the machine-wide values cleared
ok - fm-spawn.sh: a credential absent from .env is absent for the worker, not silently substituted
ok - fm-spawn.sh: a home with no .env still spawns, with no credentials and no error
ok - fm-spawn.sh: a home with no .env of its own reads its primary's, and says so
ok - fm-spawn.sh: a local .env that delivers nothing does not suppress the fallback
ok - fm-spawn.sh: a home's own .env wins over its primary's, with no fallback announced
ok - fm-spawn.sh: before cleanup an ambient copy still satisfies a key .env does not declare (why launchctl must be cleared)
```

The first case is the delivery guarantee: the scratch tmux server is started under `env -i`, so the pane can inherit no credential from anywhere, and the worker still reports its key present and byte-exact.
The second is the ablation: with the same cleared environment and the key removed from `.env`, the worker reports it absent.

The fourth, fifth, and sixth cover the secondmate path, where the home has no `.env` of its own and nothing seeds one while its crewmate briefs still carry the inherited narrowing.
The fourth spawns with `FM_PUBLIC_FOLLOWUP_PRIMARY_HOME` set - the environment a secondmate's own crewmate spawn runs in - and checks three things at once: the primary's credentials arrive byte-exact, the spawn names the primary's `.env` path on stderr without printing any value, and `FMX_PAIRING_TOKEN` still does not cross, because that token is the primary home's relay consent.

The fifth and sixth are the delivery gate, ablated in both directions, because the gate is what decides which file the spawn loads.
The fifth gives the home a `.env` that exists and delivers nothing - X mode's documented shape, holding only `FMX_PAIRING_TOKEN`, and then a comment-only file - and requires that neither suppresses the fallback: the worker still ends up with the primary's credentials, the fallback is still announced, and the local file's relay token still does not cross.
The sixth writes a local `.env` that really exports a name and requires the opposite: it wins whole, a name only the primary declares does not appear, and nothing is announced.
Which file won is proven by giving the local and primary files the same name with different invented fake values; the pane probe reports only a match token, so no value is printed by either side of the comparison.

The last case records the boundary of the ablation rather than an aspiration.
While a machine-wide copy of a name is still set, that copy does satisfy a key `.env` no longer declares, so the ablation guarantee holds only once those copies are actually cleared.

The suite carries `FM_GATE_REFUSE_BYPASS` across its own `env -i` barrier.
That barrier exists to strip credentials, and without the test-harness bypass the suite would refuse to spawn at all while firstmate validates itself from a no-mistakes gate worktree - which is exactly where it has to keep proving delivery.

## Parser and eligibility rules

```sh
bash tests/fm-worker-env-lib.test.sh
```

```
ok - fm-worker-env-lib.sh: a home's credentials reach the worker in bash and zsh
ok - fm-worker-env-lib.sh: FM_/FMX_ configuration stays with the home, not its workers
ok - fm-worker-env-lib.sh: a .env cannot rewrite the shell it loads into
ok - fm-worker-env-lib.sh: a .env cannot redirect the interpreters the worker starts
ok - fm-worker-env-lib.sh: only a heap-size NODE_OPTIONS value crosses, and a refusal names no value
ok - fm-worker-env-lib.sh: the exportable count is exactly what a worker would get
ok - fm-worker-env-lib.sh: the delivering .env is resolved once, for every caller
ok - fm-worker-env-lib.sh: no credential value is printed, on any path
ok - fm-worker-env-lib.sh: the declared .env value wins over a stale ambient copy
ok - fm-worker-env-lib.sh: an absent .env loads nothing and reports no error
```

The interpreter case is the same rule as the shell one, one level down: `GIT_SSH_COMMAND`, `PERL5LIB`, `PYTHONSTARTUP`, `RUBYOPT`, and `ZDOTDIR` redirect what a worker runs in every project it touches, and a `.env` is now read by every future worker, so one appended line would persist across lanes.
`NODE_OPTIONS` is the one name where refusing it and allowing it are both wrong - the documented long-run practice sets `--max-old-space-size` deliberately, while `--require=<file>` in the same variable loads a file into every node process - so its VALUE is allowlisted token by token, and a refusal names `NODE_OPTIONS` without printing what it refused.

The count case exists because `bin/fm-brief.sh` has to know whether a home's `.env` would give a worker anything before it tells that worker its variables are simply there.
It asks this library rather than re-deriving the rules, so an X-mode-only `.env` holding just `FMX_PAIRING_TOKEN` counts zero and the brief says nothing about a file the worker never received.

The resolution case is the same question one level up, and it has one owner because three places used to answer it separately: the file a spawn loads, the paragraph a brief renders about where credentials live, and the sentence a brief writes about where a missing one should have come from.
`fm_worker_env_resolve` returns the local `.env` when that file delivers at least one worker credential, the primary home's when it does not and the primary's does, and the local path with origin `none` when neither delivers - never a primary that would supply nothing, because announcing such a fallback is the same misleading claim in a different place.

Every case runs under both bash and zsh.
That is not redundancy: an earlier revision held the refused-name list in a string and looped over it unquoted, which bash word-splits and zsh does not, so under zsh the loop matched nothing and exported `PATH` straight out of the file while bash correctly refused it.
One interpreter could not see the defect.

The no-print guarantee is why the file is parsed here rather than sourced.
`set -a; . file` hands the file to the shell, and a shell reports a syntax error by echoing the offending line - which is a credential value, printed into the pane an agent reads and therefore into a model provider's transcript.
This parser reports an unusable line by line number only.

## Mutation checks

Each guarantee was confirmed to be load-bearing by breaking it and observing the failure.
Every row whose failing case names a brief is a case in `tests/fm-brief.test.sh`, because the claim it protects is one a generated brief makes rather than one the loader keeps; every other row is a case in the two suites above.

| Mutation | Failing case |
| --- | --- |
| Remove the wrapper from `bin/fm-spawn.sh` | `with machine-wide values cleared, the worker had no credential at all` |
| Drop the `FM_*`/`FMX_*` exclusion | `a crewmate was handed X mode's relay consent token` |
| Allow `PATH` through the refused-name list | `a .env rewrote the worker's PATH` |
| Echo each exported name and value | `the loader printed a credential value it loaded successfully` |
| Report an unusable line by content instead of number | `the skip diagnostic did not identify which lines were unusable` |
| Remove the primary-home fallback from `bin/fm-spawn.sh` | `a home with no .env of its own got no credential from its primary - every secondmate lane would be stranded` |
| Drop the interpreter-level refusals | `a .env could replace the transport git authenticates over` |
| Allow `NODE_OPTIONS` by name instead of by value | `a NODE_OPTIONS value carrying --require reached the worker` |
| Gate the brief's location paragraph on the file existing | `brief promised loaded variables for a .env that puts nothing into a worker's environment` |
| Leave the unset-key sentence unnarrowed | `narrowed brief did not scope the unset-key trigger to the keys the vault holds` |
| Resolve on the local `.env` existing instead of delivering | `an X-mode-only local .env suppressed the fallback, so an X-mode lane's workers had no credentials` |
| Name a local `.env` when the primary's is the file being loaded | `brief blamed a local .env for a credential its worker gets from the primary's` |
