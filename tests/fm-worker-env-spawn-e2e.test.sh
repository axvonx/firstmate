#!/usr/bin/env bash
# tests/fm-worker-env-spawn-e2e.test.sh - end-to-end proof that a real
# bin/fm-spawn.sh delivers a firstmate home's .env credentials into a real
# worker's environment, driven through the verified tmux backend.
#
# This exists because the claim it checks cannot be verified by reading code.
# Credentials used to be set machine-wide with `launchctl setenv`, so every
# process on the machine inherited them and a worker had them whether or not
# firstmate did anything. Once those machine-wide values are cleared, the pane
# export added in bin/fm-spawn.sh is the ONLY thing putting a credential in front
# of a worker - and if it does not work, every lane loses its keys at the same
# moment. "The .env is loaded" asserted from the source is exactly the class of
# claim this repository has shipped wrong before.
#
# The simulation of "launchctl cleared" is the whole point of the setup: the
# scratch tmux SERVER is started from an environment with the credential names
# removed, so the pane cannot inherit them from anywhere. A tmux server keeps the
# environment it was first started with, so this has to be a server of our own.
#
# Isolation: TMUX_TMPDIR points at a scratch directory, which gives this suite
# its own tmux server on its own socket. It can neither see nor disturb the
# fleet's real session or any sibling lane's window.
#
# The pane SHELL is the reason this is an end-to-end test and not a unit test of
# the loader. The first implementation sourced a POSIX shell library into the
# pane, which reads correctly and passes any unit test, and which failed
# completely the first time it met a real pane: the panes on this machine run
# fish, under herdr and tmux alike, and fish cannot parse that library. Only a
# real spawn into a real pane catches that, so the suite pins the scratch
# server's shell to fish wherever fish exists.
#
# No real credential is used, read, or printed. Every value here is an invented
# fake, and the pane probe reports only whether a NAME is set.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-worker-env-spawn-e2e)
# A tmux socket is a UNIX socket, whose path is capped near 104 bytes, and the
# suite's own temp root plus tmux's `tmux-<uid>/default` suffix overruns that.
# The scratch server therefore gets a deliberately short directory of its own.
TMUX_TMPDIR=$(mktemp -d /tmp/fmwe.XXXXXX)
export TMUX_TMPDIR
fm_git_identity fmtest fmtest@example.invalid

# Pin the scratch server's pane shell to the shell that actually broke the first
# implementation, so the regression this suite exists for stays reachable. A host
# without fish still gets full coverage of the delivery guarantee under whatever
# shell it does have - the point of the wrapper is that the shell stops mattering.
PANE_SHELL=$(command -v fish 2>/dev/null || true)
TMUX_CONF="$TMUX_TMPDIR/tmux.conf"
if [ -n "$PANE_SHELL" ]; then
  printf 'set -g default-shell %s\n' "$PANE_SHELL" > "$TMUX_CONF"
else
  : > "$TMUX_CONF"
fi

# An empty config directory for the pane shell, so this suite tests firstmate's
# delivery rather than the operator's dotfiles. That is not hygiene alone: this
# machine's own ~/.config/fish/secrets.fish exports five of the same credential
# names into every fish shell, so without this the "the key is gone" cases would
# quietly measure that file instead and pass for the wrong reason.
SCRATCH_XDG="$TMP_ROOT/xdg"
mkdir -p "$SCRATCH_XDG/fish"

# The names this machine's home keeps in .env. Used as NAMES only.
CRED_A=OPENAI_API_KEY
CRED_B=HF_TOKEN
FAKE_A=fake-openai-value-not-a-real-key
FAKE_B=fake-hf-value-not-a-real-key

# Kill the scratch tmux server however this run ends, so no pane outlives it.
scratch_cleanup() {
  tmux kill-server >/dev/null 2>&1 || true
  [ -n "${TMUX_TMPDIR:-}" ] && rm -rf "$TMUX_TMPDIR"
  fm_test_cleanup
}
trap scratch_cleanup EXIT

# Start the scratch server ourselves, before any spawn, for two reasons. It is
# what pins default-shell to fish, since the tmux adapter calls a bare `tmux` and
# there is no seam to pass a config file through. And a tmux server keeps the
# environment it was started with and hands that to every pane, so starting it
# under `env -i` is what makes "the machine-wide credentials are cleared" true
# for every case below rather than something each case has to arrange. The
# session name matches the one fm_backend_tmux_container_ensure looks for, so the
# spawn reuses this server instead of creating another.
env -i HOME="$HOME" PATH="$PATH" TERM=xterm TMUX_TMPDIR="$TMUX_TMPDIR" \
  XDG_CONFIG_HOME="$SCRATCH_XDG" \
  tmux -f "$TMUX_CONF" new-session -d -s firstmate \
  || fail "could not start the scratch tmux server"

PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit -qm initial

# The worker: reports which NAMES are set, never a value. Written once and used
# by every case, so no case can quietly probe something different.
PROBE="$TMP_ROOT/probe.sh"
cat > "$PROBE" <<EOF
#!/bin/sh
report=\$1
{
  for k in $CRED_A $CRED_B FMX_PAIRING_TOKEN; do
    eval "v=\\\${\$k:-}"
    if [ -n "\$v" ]; then echo "\$k=set"; else echo "\$k=unset"; fi
  done
  # Correctness, not just presence: a value mangled by the parser would
  # authenticate as garbage, which is worse than being absent.
  if [ "\${$CRED_A:-}" = "$FAKE_A" ]; then echo "$CRED_A=exact"; fi
} > "\$report".tmp
mv "\$report".tmp "\$report"
EOF
chmod +x "$PROBE"

# Run one spawn in a scratch home and return the worker's report.
#   spawn_and_report <case> <env-file-content|->
# The pane's environment comes from the `env -i` server started above, so no
# credential can arrive by inheritance from the suite's own shell; a case that
# wants an ambient credential back puts it on the server with `tmux setenv`.
spawn_and_report() {
  local case_name=$1 env_content=$2; shift 2
  local home id report waited
  home="$TMP_ROOT/home-$case_name"
  id="wenv$case_name"
  report="$TMP_ROOT/report-$case_name"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$home/projects"
  printf 'trivial worker-env e2e brief: nothing to do.\n' > "$home/data/$id/brief.md"
  if [ "$env_content" != "-" ]; then
    printf '%s' "$env_content" > "$home/.env"
    chmod 600 "$home/.env"
  fi

  env -i HOME="$HOME" PATH="$PATH" TERM=xterm TMUX_TMPDIR="$TMUX_TMPDIR" \
    XDG_CONFIG_HOME="$SCRATCH_XDG" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "sh $PROBE $report" \
    > "$TMP_ROOT/spawn-$case_name.out" 2> "$TMP_ROOT/spawn-$case_name.err" \
    || fail "$case_name: fm-spawn.sh failed"$'\n'"--- stderr ---"$'\n'"$(cat "$TMP_ROOT/spawn-$case_name.err")"

  waited=0
  while [ ! -f "$report" ] && [ "$waited" -lt 100 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [ -f "$report" ] || fail "$case_name: the worker never reported"$'\n'"--- pane ---"$'\n'"$(tmux capture-pane -p -t "fm-$id" 2>&1)"
  cat "$report"
}

# The delivery guarantee. With the credential names absent from the environment
# that starts the tmux server - the state the machine is about to be in - the
# worker still has its key, and has it byte-exact.
test_worker_has_credentials_with_machine_wide_values_cleared() {
  local out
  out=$(spawn_and_report cleared \
    "$CRED_A=$FAKE_A
$CRED_B='$FAKE_B'
FMX_PAIRING_TOKEN=fake-pairing-token-not-a-real-token
")
  assert_contains "$out" "$CRED_A=set" \
    "with machine-wide values cleared, the worker had no credential at all - every lane would be stranded"
  assert_contains "$out" "$CRED_B=set" \
    "a second declared credential did not reach the worker"
  assert_contains "$out" "$CRED_A=exact" \
    "the credential reached the worker mangled, which authenticates as garbage"
  # The home's relay consent is not a worker credential (AGENTS.md section 14).
  assert_contains "$out" "FMX_PAIRING_TOKEN=unset" \
    "the worker was handed X mode's relay token along with its credentials"
  pass "fm-spawn.sh: a worker has its credentials with the machine-wide values cleared"
}

# The ablation. Same cleared environment, but the key is not in .env. The worker
# must simply not have it - so it reports a missing credential per its brief -
# rather than being quietly satisfied from somewhere else.
test_missing_key_is_missing_not_silently_satisfied() {
  local out
  out=$(spawn_and_report ablated \
    "$CRED_B=$FAKE_B
")
  assert_contains "$out" "$CRED_A=unset" \
    "a credential removed from .env still reached the worker - something else is silently supplying it"
  assert_contains "$out" "$CRED_B=set" \
    "ablating one credential also removed the one left in the file"
  pass "fm-spawn.sh: a credential absent from .env is absent for the worker, not silently substituted"
}

# A home with no .env at all is the fresh-install and secondmate-home case. The
# spawn must still succeed and the worker must simply have no credentials, rather
# than the spawn failing and taking the task with it.
test_home_without_env_still_spawns() {
  local out
  out=$(spawn_and_report noenv -)
  assert_contains "$out" "$CRED_A=unset" \
    "a home with no .env somehow produced a credential"
  pass "fm-spawn.sh: a home with no .env still spawns, with no credentials and no error"
}

# The honest limitation, asserted rather than assumed: while the machine-wide
# values are still set, an ambient copy DOES satisfy a key that .env no longer
# declares. That is the pre-cleanup state, and it is exactly why the ablation
# guarantee above is conditional on those values actually being cleared.
test_ambient_copy_still_wins_before_cleanup() {
  local out
  tmux setenv -g "$CRED_A" stale-ambient-value-not-a-real-key
  out=$(spawn_and_report ambient "$CRED_B=$FAKE_B
")
  tmux setenv -gu "$CRED_A"
  assert_contains "$out" "$CRED_A=set" \
    "the pre-cleanup state changed: an ambient credential no longer reaches a worker"
  assert_not_contains "$out" "$CRED_A=exact" \
    "the ambient value was reported as the declared one, so the probe cannot tell them apart"
  pass "fm-spawn.sh: before cleanup an ambient copy still satisfies a key .env does not declare (why launchctl must be cleared)"
}

test_worker_has_credentials_with_machine_wide_values_cleared
test_missing_key_is_missing_not_silently_satisfied
test_home_without_env_still_spawns
test_ambient_copy_still_wins_before_cleanup
