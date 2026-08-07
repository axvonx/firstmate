# Worker credential delivery verification

Audience: maintainer verification.

This record supports three active guarantees for the credentials a crewmate reaches:

1. A worker gets its firstmate home's `.env` credentials even when nothing on the machine sets them, and gets them byte-exact.
2. A credential the home does not declare is genuinely absent for the worker, rather than being satisfied from somewhere else.
3. No credential value is printed on any path, including when the file cannot be parsed.

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

## Delivery, ablation, and the empty-home case

```sh
bash tests/fm-worker-env-spawn-e2e.test.sh
```

```
ok - fm-spawn.sh: a worker has its credentials with the machine-wide values cleared
ok - fm-spawn.sh: a credential absent from .env is absent for the worker, not silently substituted
ok - fm-spawn.sh: a home with no .env still spawns, with no credentials and no error
ok - fm-spawn.sh: before cleanup an ambient copy still satisfies a key .env does not declare (why launchctl must be cleared)
```

The first case is the delivery guarantee: the scratch tmux server is started under `env -i`, so the pane can inherit no credential from anywhere, and the worker still reports its key present and byte-exact.
The second is the ablation: with the same cleared environment and the key removed from `.env`, the worker reports it absent.

The fourth case records the boundary of the second rather than an aspiration.
While a machine-wide copy of a name is still set, that copy does satisfy a key `.env` no longer declares, so the ablation guarantee holds only once those copies are actually cleared.

## Parser and eligibility rules

```sh
bash tests/fm-worker-env-lib.test.sh
```

```
ok - fm-worker-env-lib.sh: a home's credentials reach the worker in bash and zsh
ok - fm-worker-env-lib.sh: FM_/FMX_ configuration stays with the home, not its workers
ok - fm-worker-env-lib.sh: a .env cannot rewrite the shell it loads into
ok - fm-worker-env-lib.sh: no credential value is printed, on any path
ok - fm-worker-env-lib.sh: the declared .env value wins over a stale ambient copy
ok - fm-worker-env-lib.sh: an absent .env loads nothing and reports no error
```

Every case runs under both bash and zsh.
That is not redundancy: an earlier revision held the refused-name list in a string and looped over it unquoted, which bash word-splits and zsh does not, so under zsh the loop matched nothing and exported `PATH` straight out of the file while bash correctly refused it.
One interpreter could not see the defect.

The no-print guarantee is why the file is parsed here rather than sourced.
`set -a; . file` hands the file to the shell, and a shell reports a syntax error by echoing the offending line - which is a credential value, printed into the pane an agent reads and therefore into a model provider's transcript.
This parser reports an unusable line by line number only.

## Mutation checks

Each guarantee was confirmed to be load-bearing by breaking it and observing the failure.

| Mutation | Failing case |
| --- | --- |
| Remove the wrapper from `bin/fm-spawn.sh` | `with machine-wide values cleared, the worker had no credential at all` |
| Drop the `FM_*`/`FMX_*` exclusion | `a crewmate was handed X mode's relay consent token` |
| Allow `PATH` through the refused-name list | `a .env rewrote the worker's PATH` |
| Echo each exported name and value | `the loader printed a credential value it loaded successfully` |
| Report an unusable line by content instead of number | `the skip diagnostic did not identify which lines were unusable` |
