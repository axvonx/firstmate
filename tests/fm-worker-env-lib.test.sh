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

# Ask how many names a file would give a worker, without loading it. Same clean
# child shell as probe, and the same folded stderr, so a case can assert that
# asking the question prints nothing else.
#   probe_count <shell> <env-file>
probe_count() {
  local shell=$1 env_file=$2 runner
  runner="$TMP_ROOT/probe-count.$$.sh"
  {
    printf '. %s\n' "$(printf '%q' "$LIB")"
    printf 'fm_worker_env_exportable_count %s\n' "$(printf '%q' "$env_file")"
  } > "$runner"
  env -i HOME="$HOME" PATH="$PATH" "$shell" "$runner" 2>&1
  rm -f "$runner"
}

# Ask which file will actually deliver a home's worker credentials. Echoes
# "<origin> <path>", the two answers every caller of this library reads.
#   probe_resolve <shell> <home> [primary-home]
probe_resolve() {
  local shell=$1 home=$2 primary=${3:-} runner
  runner="$TMP_ROOT/probe-resolve.$$.sh"
  {
    printf '. %s\n' "$(printf '%q' "$LIB")"
    printf 'fm_worker_env_resolve %s %s\n' "$(printf '%q' "$home")" "$(printf '%q' "$primary")"
    # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there
    printf 'printf "%%s %%s\\n" "$FM_WORKER_ENV_ORIGIN" "$FM_WORKER_ENV_FILE"\n'
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

# The interpreter-level half of the same rule. A worker's shell is not the only
# thing a .env can redirect: GIT_SSH_COMMAND replaces the transport git
# authenticates over, and PERL5LIB, PYTHONSTARTUP, RUBYOPT, and ZDOTDIR each hand
# an interpreter or a login shell a file to load, in every project the worker
# touches. A .env is now read by every future worker, so one appended line would
# persist across lanes.
#
# Every one of those names has a strictly stronger sibling, and a list holding
# only the weaker one refuses nothing in practice - which is why each sibling is
# asserted here beside it. PYTHONPATH reaches every python run where
# PYTHONSTARTUP only fires interactively, PERL5OPT injects `-M<module>` into
# every perl run where PERL5LIB only adds a search path, and RUBYLIB and
# NODE_PATH are the same shape one interpreter over. The GIT_CONFIG_* family is
# the sharpest of them in a rule about credentials: GIT_CONFIG_COUNT with
# GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> sets arbitrary config on every git
# call, so it can install a credential.helper that hands the worker's git
# credentials to a program of the file's choosing. It is refused by prefix, and
# the enumerated members are asserted so the prefix cannot silently match
# nothing.
test_interpreter_hijacking_names_are_refused() {
  local envfile out shell name
  envfile="$TMP_ROOT/interpreter.env"
  write_env "$envfile" <<EOF
GIT_SSH_COMMAND=/definitely/not/a/real/ssh
GIT_CONFIG=/definitely/not/a/real/gitconfig
GIT_CONFIG_GLOBAL=/definitely/not/a/real/gitconfig-global
GIT_CONFIG_SYSTEM=/definitely/not/a/real/gitconfig-system
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=credential.helper
GIT_CONFIG_VALUE_0=/definitely/not/a/real/credential-helper
PERL5LIB=/definitely/not/a/real/perl5
PERL5OPT=-M/definitely/not/a/real/module
PYTHONSTARTUP=/definitely/not/a/real/startup.py
PYTHONPATH=/definitely/not/a/real/pythonpath
RUBYOPT=-r/definitely/not/a/real/hook
RUBYLIB=/definitely/not/a/real/rubylib
NODE_PATH=/definitely/not/a/real/node_modules
ZDOTDIR=/definitely/not/a/real/zdotdir
OPENAI_API_KEY=$FAKE_A
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
    out=$(probe "$shell" "$envfile" 'for k in GIT_SSH_COMMAND GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 PERL5LIB PERL5OPT PYTHONSTARTUP PYTHONPATH RUBYOPT RUBYLIB NODE_PATH ZDOTDIR; do
  eval "v=\${$k:-}"
  if [ -n "$v" ]; then echo "$k=set"; else echo "$k=unset"; fi
done
[ -n "${OPENAI_API_KEY:-}" ] && echo "OPENAI_API_KEY=set"')
    assert_contains "$out" "GIT_SSH_COMMAND=unset" "$shell: a .env could replace the transport git authenticates over"
    assert_contains "$out" "GIT_CONFIG=unset" "$shell: a .env could replace the config file every git call reads"
    assert_contains "$out" "GIT_CONFIG_GLOBAL=unset" "$shell: a .env could replace the worker's global git config"
    assert_contains "$out" "GIT_CONFIG_SYSTEM=unset" "$shell: a .env could replace the system git config"
    # The count/key/value trio is the exfiltration path: it needs no file at all.
    for name in GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0; do
      assert_contains "$out" "$name=unset" \
        "$shell: a .env could set a credential.helper on every git call through $name"
    done
    assert_contains "$out" "PERL5LIB=unset" "$shell: a .env could inject a perl library path"
    assert_contains "$out" "PERL5OPT=unset" "$shell: a .env could load a module into every perl run"
    assert_contains "$out" "PYTHONSTARTUP=unset" "$shell: a .env could run a file at every python startup"
    assert_contains "$out" "PYTHONPATH=unset" "$shell: a .env could prepend an import path to every python run"
    assert_contains "$out" "RUBYOPT=unset" "$shell: a .env could require a file into every ruby process"
    assert_contains "$out" "RUBYLIB=unset" "$shell: a .env could prepend a load path to every ruby process"
    assert_contains "$out" "NODE_PATH=unset" "$shell: a .env could prepend a module path to every node process"
    assert_contains "$out" "ZDOTDIR=unset" "$shell: a .env could point a login shell at its own rc directory"
    assert_contains "$out" "OPENAI_API_KEY=set" \
      "$shell: refusing interpreter-hijacking names also dropped the credential beside them"
  done
  pass "fm-worker-env-lib.sh: a .env cannot redirect the interpreters the worker starts"
}

# NODE_OPTIONS is the one name where refusing it and allowing it are both wrong:
# this machine's documented long-run practice sets --max-old-space-size
# deliberately, while `--require=<file>` in the same variable loads a file into
# every node process the worker starts. The VALUE is allowlisted instead, which
# is a mechanical check rather than a policy call - and a refusal is reported by
# NAME only, because printing the value is the leak this whole change is about.
test_node_options_value_is_allowlisted() {
  local envfile out shell bad_value
  envfile="$TMP_ROOT/node-allowed.env"
  write_env "$envfile" <<EOF
NODE_OPTIONS=--max-old-space-size=8192
OPENAI_API_KEY=$FAKE_A
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
    out=$(probe "$shell" "$envfile" 'echo "node=${NODE_OPTIONS:-unset}"')
    assert_contains "$out" "node=--max-old-space-size=8192" \
      "$shell: the heap-size shape this machine actually uses was refused"
    assert_not_contains "$out" "refused" "$shell: an allowlisted NODE_OPTIONS value produced a diagnostic"
  done

  # Every token must qualify, so a permitted token cannot smuggle a loader in
  # beside it, and a non-numeric size is not a size.
  envfile="$TMP_ROOT/node-refused.env"
  write_env "$envfile" <<EOF
NODE_OPTIONS=--max-old-space-size=8192 --require=/definitely/not/a/real/hook.js
OPENAI_API_KEY=$FAKE_A
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
    out=$(probe "$shell" "$envfile" 'echo "node=${NODE_OPTIONS:-unset}"
[ -n "${OPENAI_API_KEY:-}" ] && echo "OPENAI_API_KEY=set"')
    assert_contains "$out" "node=unset" \
      "$shell: a NODE_OPTIONS value carrying --require reached the worker"
    assert_contains "$out" "OPENAI_API_KEY=set" \
      "$shell: refusing a NODE_OPTIONS value also dropped the credential beside it"
    # Diagnosable by name, never by value: the refused value is the thing a
    # worker's pane must not carry.
    assert_contains "$out" "NODE_OPTIONS" "$shell: a refused NODE_OPTIONS value was rejected silently"
    assert_not_contains "$out" "/definitely/not/a/real/hook.js" \
      "$shell: the refusal diagnostic printed the value it refused"
  done

  for bad_value in --import=/definitely/not/a/real/loader.mjs \
    --experimental-loader=/definitely/not/a/real/loader.mjs \
    --max-old-space-size=not-a-number; do
    write_env "$envfile" <<EOF
NODE_OPTIONS=$bad_value
EOF
    for shell in $LOADER_SHELLS; do
      command -v "$shell" >/dev/null 2>&1 || continue
      # shellcheck disable=SC2016  # a script for the CHILD shell: it must expand there, not here
      out=$(probe "$shell" "$envfile" 'echo "node=${NODE_OPTIONS:-unset}"')
      assert_contains "$out" "node=unset" \
        "$shell: NODE_OPTIONS=$bad_value was allowed through the value allowlist"
    done
  done
  pass "fm-worker-env-lib.sh: only a heap-size NODE_OPTIONS value crosses, and a refusal names no value"
}

# bin/fm-brief.sh has to know whether a home's .env would put ANY name into a
# worker's environment before it tells that worker its variables are simply
# there. Asking here rather than re-deriving the rules is what keeps the brief's
# claim and the loader's behavior from drifting apart, so the count must follow
# every exclusion the loader applies - and must print a number and nothing else.
test_exportable_count_follows_the_same_eligibility_rules() {
  local envfile out shell
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue

    envfile="$TMP_ROOT/count-two.env"
    write_env "$envfile" <<EOF
# comment
OPENAI_API_KEY=$FAKE_A
export ANTHROPIC_API_KEY="$FAKE_B"
EOF
    out=$(probe_count "$shell" "$envfile")
    [ "$out" = 2 ] || fail "$shell: two eligible credentials counted as '$out'"
    assert_not_contains "$out" "$FAKE_A" "$shell: counting a .env printed a value"

    # The X-mode-only shape: a real file, and nothing in it reaches a worker.
    envfile="$TMP_ROOT/count-xmode.env"
    write_env "$envfile" <<EOF
FMX_PAIRING_TOKEN=$FAKE_B
FM_CHECK_INTERVAL=30
EOF
    out=$(probe_count "$shell" "$envfile")
    [ "$out" = 0 ] || fail "$shell: an X-mode-only .env counted '$out' names a worker would get"

    # A refused name and a refused value are just as absent for a worker.
    envfile="$TMP_ROOT/count-refused.env"
    write_env "$envfile" <<EOF
PATH=/definitely/not/a/real/bin
NODE_OPTIONS=--require=/definitely/not/a/real/hook.js
this line cannot be parsed at all
EOF
    out=$(probe_count "$shell" "$envfile")
    [ "$out" = 0 ] || fail "$shell: a .env of refused names counted '$out' names a worker would get"
    assert_not_contains "$out" "skipped" \
      "$shell: counting printed a parse diagnostic into a document-generating caller"

    out=$(probe_count "$shell" "$TMP_ROOT/definitely-absent.env")
    [ "$out" = 0 ] || fail "$shell: an absent .env counted '$out' instead of 0"
  done
  pass "fm-worker-env-lib.sh: the exportable count is exactly what a worker would get"
}

# One question with one owner: which file will actually deliver this home's
# worker credentials. bin/fm-spawn.sh loads what this answers and bin/fm-brief.sh
# describes what this answers, so a brief cannot promise one source while a spawn
# reads another.
#
# The predicate is DELIVERY, not existence, and that is the whole point. A .env
# can be present and give a worker nothing - X mode's documented shape is a file
# holding only FMX_PAIRING_TOKEN, and a comment-only file reads the same way - so
# a presence test would suppress the fallback and strand every crewmate on that
# lane silently, which is the failure the fallback exists to prevent.
test_resolution_follows_delivery_not_file_existence() {
  local home primary out shell
  home="$TMP_ROOT/resolve-home"
  primary="$TMP_ROOT/resolve-primary"
  mkdir -p "$home" "$primary"
  write_env "$primary/.env" <<EOF
OPENAI_API_KEY=$FAKE_B
EOF
  for shell in $LOADER_SHELLS; do
    command -v "$shell" >/dev/null 2>&1 || continue

    # A local file that really exports something wins - the isolation case.
    write_env "$home/.env" <<EOF
OPENAI_API_KEY=$FAKE_A
EOF
    out=$(probe_resolve "$shell" "$home" "$primary")
    [ "$out" = "local $home/.env" ] \
      || fail "$shell: a delivering local .env did not win: $out"

    # Present but delivering nothing, in each shape that reaches a real home.
    write_env "$home/.env" <<EOF
FMX_PAIRING_TOKEN=fake-pairing-token-not-a-real-token
EOF
    out=$(probe_resolve "$shell" "$home" "$primary")
    [ "$out" = "primary $primary/.env" ] \
      || fail "$shell: an X-mode-only local .env suppressed the fallback and stranded the lane: $out"

    write_env "$home/.env" <<EOF
# nothing but a comment

EOF
    out=$(probe_resolve "$shell" "$home" "$primary")
    [ "$out" = "primary $primary/.env" ] \
      || fail "$shell: a comment-only local .env suppressed the fallback: $out"

    rm -f "$home/.env"
    out=$(probe_resolve "$shell" "$home" "$primary")
    [ "$out" = "primary $primary/.env" ] \
      || fail "$shell: a home with no .env at all did not read its primary's: $out"

    # A primary that delivers nothing is not chosen: announcing a source that
    # supplies no credential is the same misleading claim one level over.
    write_env "$primary/.env" <<EOF
FMX_PAIRING_TOKEN=fake-pairing-token-not-a-real-token
EOF
    out=$(probe_resolve "$shell" "$home" "$primary")
    [ "$out" = "none $home/.env" ] \
      || fail "$shell: resolution fell back to a primary that delivers nothing: $out"

    # No primary at all is the ordinary single-home case, not an error.
    out=$(probe_resolve "$shell" "$home")
    [ "$out" = "none $home/.env" ] \
      || fail "$shell: a home with no primary did not resolve to its own path: $out"

    write_env "$primary/.env" <<EOF
OPENAI_API_KEY=$FAKE_B
EOF
    # A home that IS its own primary must not be reported as inheriting.
    out=$(probe_resolve "$shell" "$primary" "$primary")
    [ "$out" = "local $primary/.env" ] \
      || fail "$shell: a primary home resolved as if it were inheriting from itself: $out"
  done
  pass "fm-worker-env-lib.sh: the delivering .env is resolved once, for every caller"
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
test_interpreter_hijacking_names_are_refused
test_node_options_value_is_allowlisted
test_exportable_count_follows_the_same_eligibility_rules
test_resolution_follows_delivery_not_file_existence
test_no_value_is_ever_printed
test_declared_value_wins_over_ambient
test_absent_file_is_not_an_error
