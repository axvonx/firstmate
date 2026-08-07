#!/usr/bin/env bash
# tests/fm-worker-env-lib.test.sh - the contract owned by
# bin/fm-worker-env-lib.sh: which names from a firstmate home's .env reach a
# worker's environment, which are refused, and what the loader is allowed to
# print while deciding.
#
# Why this file exists at all: credentials used to be set machine-wide with
# `launchctl setenv`, so a worker got them by inheritance and nothing had to
# work. They now come from one per-home .env that bin/fm-worker-env-exec.sh
# loads around every worker launch, which means this loader is the only thing
# standing between a worker and having no credentials - and, in the other
# direction, between a worker and holding the home's X-mode relay token.
#
# The delivery mechanism itself is proven end to end, in a real pane, by
# tests/fm-worker-env-spawn-e2e.test.sh. This file is the parser and the policy.
#
# Everything is driven by sourcing the library and calling its public function
# against synthetic files. No case reads the implementation's source, and no
# case touches a real .env: every value here is an obvious invented fake, so a
# failure diff can never print a real credential.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-env-tests)
LIB="$ROOT/bin/fm-worker-env-lib.sh"

# Every value in this suite is one of these. None is a credential shape that any
# real service would accept, so nothing here can become a leak if it is echoed
# by a failing assertion.
FAKE_A=fake-value-alpha-not-a-real-key
FAKE_B=fake-value-bravo-not-a-real-key

# Run one probe in a clean child shell so a case cannot inherit another case's
# exports, and so the parent's own environment is never modified by the loader.
#   probe <shell> <env-file> <script>
# <script> runs after the load with the loaded variables in scope; its stdout is
# the probe's stdout, and the loader's stderr is folded in so diagnostics can be
# asserted on.
probe() {
  local shell=$1 env_file=$2 script=$3 runner
  runner="$TMP_ROOT/probe.$$.sh"
  {
    printf '. %s\n' "$(printf '%q' "$LIB")"
    printf 'fm_worker_env_load %s\n' "$(printf '%q' "$env_file")"
    printf '%s\n' "$script"
  } > "$runner"
  env -i HOME="$HOME" PATH="$PATH" "$shell" "$runner" 2>&1
  rm -f "$runner"
}

# Report whether a name arrived, never what it holds.
# shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
SET_REPORT='for k in OPENAI_API_KEY ANTHROPIC_API_KEY HF_TOKEN FMX_PAIRING_TOKEN FM_CHECK_INTERVAL PATH_MARKER; do
  eval "v=\${$k:-}"
  if [ -n "$v" ]; then echo "$k=set"; else echo "$k=unset"; fi
done'

write_env() {
  cat > "$1"
}

# The wrapper that sources this library runs under bash, but every case runs
# under zsh too, because a real defect found here was invisible in one shell: a
# name list looped over unquoted, which bash word-splits and zsh does not, so
# under zsh the loop matched nothing and exported PATH straight out of the file
# while bash correctly refused it. One interpreter is not enough to see that.
LOADER_SHELLS="bash zsh"

test_credentials_reach_the_worker() {
  local envfile out shell
  envfile="$TMP_ROOT/basic.env"
  write_env "$envfile" <<EOF
# comment line

OPENAI_API_KEY=$FAKE_A
export ANTHROPIC_API_KEY="$FAKE_B"
HF_TOKEN='$FAKE_A'
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    out=$(probe "$shell" "$envfile" "$SET_REPORT")
    assert_contains "$out" "OPENAI_API_KEY=set" "$shell: a plain assignment did not reach the worker"
    assert_contains "$out" "ANTHROPIC_API_KEY=set" "$shell: an exported assignment did not reach the worker"
    assert_contains "$out" "HF_TOKEN=set" "$shell: a single-quoted assignment did not reach the worker"

    # The quoting the file uses must not survive into the value: a key wrapped in
    # the quotes it was written with authenticates as garbage, which is the
    # confusing half-working failure this parser exists to avoid.
    # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
    out=$(probe "$shell" "$envfile" '[ "$ANTHROPIC_API_KEY" = "'"$FAKE_B"'" ] && echo dq-ok
[ "$HF_TOKEN" = "'"$FAKE_A"'" ] && echo sq-ok')
    assert_contains "$out" "dq-ok" "$shell: double quotes were left in the exported value"
    assert_contains "$out" "sq-ok" "$shell: single quotes were left in the exported value"
  done
  pass "fm-worker-env-lib.sh: a home's credentials reach the worker in bash and zsh"
}

# The .env a home keeps is also where X mode's FMX_PAIRING_TOKEN lives. That
# token is the relay consent and thread binding for public replies as the
# captain, and AGENTS.md section 14 reserves it to the one home holding it.
# Loading the file wholesale would hand every crewmate the ability to post in
# public, which is a larger grant than any worker is meant to have.
test_firstmate_namespace_stays_with_the_home() {
  local envfile out shell
  envfile="$TMP_ROOT/namespace.env"
  write_env "$envfile" <<EOF
OPENAI_API_KEY=$FAKE_A
FMX_PAIRING_TOKEN=$FAKE_B
FM_CHECK_INTERVAL=30
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    out=$(probe "$shell" "$envfile" "$SET_REPORT")
    assert_contains "$out" "OPENAI_API_KEY=set" \
      "$shell: excluding firstmate's namespace also dropped an ordinary credential"
    assert_contains "$out" "FMX_PAIRING_TOKEN=unset" \
      "$shell: a crewmate was handed X mode's relay consent token"
    assert_contains "$out" "FM_CHECK_INTERVAL=unset" \
      "$shell: firstmate's own configuration namespace leaked into a worker"
  done
  pass "fm-worker-env-lib.sh: FM_/FMX_ configuration stays with the home, not its workers"
}

# A .env now reaches an interactive shell, which makes it a new way to change
# what that shell resolves and executes rather than only what it authenticates
# with. These names are refused outright instead of being trusted.
test_shell_hijacking_names_are_refused() {
  local envfile out shell
  envfile="$TMP_ROOT/hijack.env"
  write_env "$envfile" <<EOF
PATH=/definitely/not/a/real/bin
DYLD_INSERT_LIBRARIES=/definitely/not/a/real/lib.dylib
LD_PRELOAD=/definitely/not/a/real/preload.so
BASH_ENV=/definitely/not/a/real/rc
PROMPT_COMMAND=echo hijacked
OPENAI_API_KEY=$FAKE_A
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
    out=$(probe "$shell" "$envfile" 'case "$PATH" in */definitely/not/a/real/bin*) echo "PATH=hijacked" ;; *) echo "PATH=intact" ;; esac
for k in DYLD_INSERT_LIBRARIES LD_PRELOAD BASH_ENV PROMPT_COMMAND; do
  eval "v=\${$k:-}"
  if [ -n "$v" ]; then echo "$k=set"; else echo "$k=unset"; fi
done
[ -n "${OPENAI_API_KEY:-}" ] && echo "OPENAI_API_KEY=set"')
    assert_contains "$out" "PATH=intact" "$shell: a .env rewrote the worker's PATH"
    assert_contains "$out" "DYLD_INSERT_LIBRARIES=unset" "$shell: a .env could inject a dynamic library"
    assert_contains "$out" "LD_PRELOAD=unset" "$shell: a .env could preload a library"
    assert_contains "$out" "BASH_ENV=unset" "$shell: a .env could point the shell at its own rc"
    assert_contains "$out" "PROMPT_COMMAND=unset" "$shell: a .env could run a command at every prompt"
    assert_contains "$out" "OPENAI_API_KEY=set" \
      "$shell: refusing shell-hijacking names also dropped the credential beside them"
  done
  pass "fm-worker-env-lib.sh: a .env cannot rewrite the shell it loads into"
}

# The single hardest requirement: this runs in the pane the agent reads, and
# everything in that pane is sent to a model provider. A malformed line is
# exactly the case where a naive loader prints a value - `set -a; . file` hands
# the file to the shell, and the shell reports a syntax error by echoing the
# offending line, which IS the credential.
test_no_value_is_ever_printed() {
  local envfile out shell
  envfile="$TMP_ROOT/malformed.env"
  write_env "$envfile" <<EOF
OPENAI_API_KEY=$FAKE_A
this line has no equals sign and holds $FAKE_B
9NOT_A_NAME=$FAKE_B
bad-name-with-dashes=$FAKE_B
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
    out=$(probe "$shell" "$envfile" 'echo "loaded=${OPENAI_API_KEY:+yes}"')
    assert_contains "$out" "loaded=yes" \
      "$shell: unusable lines stopped the usable credential beside them from loading"
    assert_not_contains "$out" "$FAKE_B" \
      "$shell: the loader printed the contents of a line it could not parse"
    assert_not_contains "$out" "$FAKE_A" \
      "$shell: the loader printed a credential value it loaded successfully"
    # Diagnosable without being readable: line numbers, not content.
    assert_contains "$out" "skipped unusable line(s)" \
      "$shell: a malformed .env was silently ignored, leaving nothing to debug"
    assert_contains "$out" " 2 3 4" \
      "$shell: the skip diagnostic did not identify which lines were unusable"
  done

  # A well-formed file is completely silent: no summary, no count, no name.
  envfile="$TMP_ROOT/clean.env"
  write_env "$envfile" <<EOF
OPENAI_API_KEY=$FAKE_A
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    out=$(probe "$shell" "$envfile" 'true')
    [ -z "$out" ] || fail "$shell: loading a clean .env printed something into the worker's pane: $out"
  done
  pass "fm-worker-env-lib.sh: no credential value is printed, on any path"
}

# .env is the declared source of truth and the ambient copy is the one being
# retired, so a stale machine-wide value must not silently shadow the file.
test_declared_value_wins_over_ambient() {
  local envfile out shell
  envfile="$TMP_ROOT/override.env"
  write_env "$envfile" <<EOF
OPENAI_API_KEY=$FAKE_A
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    out=$(OPENAI_API_KEY=stale-ambient-value-not-a-real-key "$shell" -c \
      ". $(printf '%q' "$LIB"); fm_worker_env_load $(printf '%q' "$envfile"); [ \"\$OPENAI_API_KEY\" = '$FAKE_A' ] && echo declared-wins || echo ambient-wins" 2>&1)
    assert_contains "$out" "declared-wins" \
      "$shell: a stale ambient credential shadowed the home's declared value"
  done
  pass "fm-worker-env-lib.sh: the declared .env value wins over a stale ambient copy"
}

# A home with no .env is the ordinary case for a fresh install and for every
# secondmate home, so it must be a silent no-op rather than an error that would
# make fm-spawn look broken. A worker missing a key it needs reports that itself.
test_absent_file_is_not_an_error() {
  local out shell
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    out=$(probe "$shell" "$TMP_ROOT/definitely-absent.env" 'echo "rc=$?"')
    assert_contains "$out" "rc=0" "$shell: an absent .env was treated as a failure"
    assert_not_contains "$out" "skipped" "$shell: an absent .env produced a diagnostic"
  done
  pass "fm-worker-env-lib.sh: an absent .env loads nothing and reports no error"
}

test_credentials_reach_the_worker
test_firstmate_namespace_stays_with_the_home
test_shell_hijacking_names_are_refused
test_no_value_is_ever_printed
test_declared_value_wins_over_ambient
test_absent_file_is_not_an_error
