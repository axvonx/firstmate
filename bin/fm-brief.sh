#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab] [--visual-evidence]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
#   --visual-evidence adds the visual-evidence contract to a ship brief, for work
#   that changes a user-visible surface. The generated contract requires: a
#   "before" that is a capture of the real surface as it stands today, unless the
#   surface does not exist yet; an "after" that is always an artifact, preferring
#   a capture of the change running in a throwaway prototype, then a mock rendered
#   in the project's own design system, then a diagram; one tight capture per
#   claim placed beside that claim; cropping and annotation down to the region
#   that changed; and prose reserved for rationale, trade-offs, and open
#   questions. The after has one carve-out, for motion, timing, or a measurement
#   no still capture can hold, which the worker must name and justify; an
#   unattached "I could not show it" stays a missing after.
#   The medium follows the surface (a browser view is a screenshot of the real
#   route, CLI output is the real transcript of the real command, a generated file
#   is its real content), so the contract fits non-browser surfaces too.
#   Prototypes and captures are built inside the task worktree under a
#   self-ignoring .fm-scratch/ and are never committed to the code branch; the
#   artifacts that are presented are copied to this task's own record directory,
#   data/<task-id>/evidence/, which the flag also names as the single exception to
#   the brief's stay-inside-the-worktree rule 2 - the same class of write as the
#   status file, scoped to this task and nothing else.
#   Each artifact is linked by its path beside the claim it evidences - in the
#   pull request body as soon as it exists, whoever opened it, or in the hand-back
#   when the mode opens none. The link is the home-relative path
#   data/<task-id>/evidence/<file>, never the absolute path the copy step needs,
#   so a body that may be published carries no account name or home layout. Links
#   are appended to an existing body rather than replacing it, because a project
#   can require a signature or a section there that a replacement drops; and
#   because the pipeline owns a body it opened and a rerun republishes it, the
#   links are re-checked and re-added before the task reports done.
#   The prose must carry that claim on its own, because a reviewer who is not on
#   this machine cannot open the file: for upstream-facing work the artifacts are
#   the captain's verification rather than the upstream reviewer's, which is an
#   accepted limitation and the reason captures go to no other host.
#   Prototyping the after costs budget when the worker chooses and only repays a
#   review round later, so the brief has to require it or no worker spends it.
#   The flag is explicit because {TASK} is filled in after scaffolding, so the
#   scaffold cannot tell whether the work is visual. It is ship-only, and omitting
#   it emits nothing at all: unlike Herdr lifecycle isolation, a missing visual
#   contract costs a review round, not safety, so briefs for work with no
#   user-visible surface must not carry a declaration.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see the project-management skill
# and AGENTS.md task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Ship and scout briefs both carry a credential rule, in three parts.
# The first is unconditional: never print a credential value, because everything
# a crewmate prints reaches a model provider, so a printed key is a leaked key.
# That half deliberately spends most of its length on INDIRECT leaks - an `env`
# or `printenv` dump, `set -x` tracing echoing an expanded command line, `curl
# -v` printing an Authorization header, a debug print of a whole config or client
# object, a raw crash trace on a credentialed path, and a fixture or
# `.env.example` built from live values. Naming them is the point: the one leak
# this repo has actually suffered was a worker echoing a key that was in its
# environment, and moving credentials out of a machine-wide `launchctl setenv`
# and into a per-home .env that fm-spawn loads makes MORE keys reliably present
# in a worker's environment, not fewer. The direct `echo $KEY` was never the
# realistic failure; a command that prints a value nobody typed is.
# The second part renders only when the home actually has a .env: it says where
# the values are, that the file is mode 600 and gitignored, that it is never
# committed or copied into a project, and that a worker tests a variable rather
# than opening the file to look at a value.
# The third is the vault call pattern, and it renders only when `av` (Automic
# Vault) is on PATH at scaffold time, so a machine without the vault keeps the
# first parts and is never told to reach for a tool it does not have.
# WHICH credentials that vault pattern covers is a per-home policy, not a
# property of this shared repo, so it is read from config/vault-only-keys, which
# holds one environment variable name per line, `#` comments and blanks ignored.
# Absent means the original unnarrowed contract, every credential through the
# vault, which is what every home had before the file existed and is the safe
# default for a home whose split nobody has declared. Present means the vault
# pattern applies to exactly those names and to nothing else, and the brief says
# so up front and tells the worker to read every other credential straight from
# its environment with no vault call and no stop-and-report. That last clause is
# load-bearing: a worker that blocks waiting for a vault which does not hold its
# key has failed for no reason, and every lane would fail that way at once.
# Present-but-empty and an unusable name are both hard errors rather than being
# skipped, because either one would silently drop a key out of vault discipline.
# The two sentences whose meaning differs between the narrowed and unnarrowed
# forms are substituted into one shared body rather than the body being kept in
# two copies that would drift.
# That gate proves only that something named `av` is there, and other tools ship
# a command by the same name, so the vault half opens with an identity probe the
# worker actually runs before reaching for the tool:
# `av help 2>&1 | grep -q 'automicvault\.com'` must succeed, and a probe that
# fails - a foreign `av`, or none at all in the pane's own PATH - requires a
# `blocked:` status line and a stop, never a guess at another command and never a
# fallback to the ambient environment, which is the exposure the rule removes.
# Gate and probe are complementary: the gate decides whether the vault half is
# emitted at all, the probe decides whether the worker may use what it found.
# Stopping is not probe-only: the brief routes the whole vault path the same way
# - a failed probe, a failed `av inject`, a key the vault does not hold, or a
# credential that otherwise never arrives - since `av list` cannot stand in for
# any of that (it fails while the vault's approval service is down, which is why
# the probe is built on `av help` instead).
# The prohibition is positive rather than implied: after a vault failure the
# worker never reruns the command bare, because a bare rerun can succeed silently
# on a copy of the key that should not exist - a leftover ambient value, a config
# file, a pasted note - and a fallback that works hides what a visible error
# would show. That reasoning is stated without depending on an ambient copy being
# present, so it holds both for a home that vaults every credential and for one
# that vaults only the names in config/vault-only-keys.
# That routing is separate from the wrapped command's own exit code: a failing
# test or a bug in the script is debugged normally, under the same wrapper, so
# the rule contains the credential path without blocking ordinary work.
# The pattern taught is the explicit `av inject +KEY [+KEY...] -- <command>`
# form, deliberately not `av bless` plus a bare `av inject --`: naming the keys
# at the call site keeps a money-spending command's credentials visible, and
# `av bless` approves a script by path, which for a project script would mix a
# local approval into the change being shipped. The scaffold teaches the pattern
# and tells the worker to name its own task's keys; it hard-codes no key list of
# its own, which would rot and would be wrong for every other home besides.
# Secondmate charters carry no such rule: a secondmate operates
# from its home's AGENTS.md, which keeps a one-line reinforcement of the
# invariant and points here for the contract, so this script is the single owner
# of the credential rule for every audience.
# Ship and scout briefs both carry a browser rule, byte-identical in the two
# variants: the worker's browser session is private to its task and needs no
# cleanup, because fm-spawn gives the task a per-task
# CHROME_DEVTOOLS_AXI_SESSION and teardown plus the watcher's orphan sweep
# reclaim it (bin/fm-browser-lib.sh owns naming, ownership, and reclaim). The
# rule's promise holds for the whole life of the task, including after a wedged
# agent is relaunched in its pane, because fm-spawn exports that session into
# the pane shell as well as putting it on the launch command.
# The old about:blank parking rule is deleted on purpose, and the trade-off is
# deliberate: pages a worker leaves open now burn CPU only inside that worker's
# own session and die with it, so the brief buys a rule that cannot be
# misapplied - no page-ownership judgement, no half-applied cleanup command - at
# the cost of some in-task CPU. A browser that cannot start at all, for example
# a session whose hashed port collides, routes through the existing `blocked:`
# protocol and needs no rule of its own.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
KIND=ship
HERDR_LAB=0
VISUAL_EVIDENCE=0
NO_PROJECTS=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --visual-evidence) VISUAL_EVIDENCE=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

# Ship-only: the contract is about how a change is shown for review, and only a
# ship brief delivers a change. A scout already owes evidence through its report.
if [ "$VISUAL_EVIDENCE" -eq 1 ] && [ "$KIND" != ship ]; then
  echo "error: --visual-evidence applies only to crewmate ship briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
# Two forms of the evidence directory. The absolute one is for local commands
# that have to resolve; the home-relative one is the only form a brief may put
# into a shareable surface, so no pull request body can carry the operator's
# account name or home layout. The fallback keeps that property when the data
# root is configured outside the home.
EVIDENCE_DIR=$(shell_quote "$DATA/$ID/evidence")
EVIDENCE_REL="${DATA#"$FM_HOME"/}/$ID/evidence"
case "$EVIDENCE_REL" in
  /*) EVIDENCE_REL="${DATA##*/}/$ID/evidence" ;;
esac

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

# Credential rule for ship and scout briefs, quoted heredocs throughout so the
# backticks and `${VAR:-}` snippets reach the crewmate verbatim. The first half
# holds on every machine. The vault half is added only where Automic Vault is
# actually installed, so a machine without it never sees the vault instructions.
IFS= read -r -d '' CREDENTIALS_RULE <<'EOF' || true
8. Never print, echo, log, or paste the VALUE of an API key, token, or other credential - not into your pane, not into a file you write, and not into a commit, a status line, or a pull request body.
   Everything you print is sent to a model provider, so a printed credential is a leaked credential that has to be rotated.
   Refer to a credential by its variable name, and when you need to know whether one is set, test it (`[ -n "${SOME_API_KEY:-}" ]`) rather than printing it.
   Most of the credentials you can reach are sitting in your environment, so the leak you are most likely to cause is INDIRECT: a command that prints a value you never typed.
   Never dump the environment - no bare `env`, `printenv`, `export -p`, or `set` - and never write one into a file, a log, a paste, or a bug report; when you want to know about one variable, test that one variable by name.
   Never turn on shell tracing around a command that carries a credential: `set -x` and `bash -x` echo the expanded command line, so the command prints its own secret before it runs.
   Never run an authenticated request under `curl -v`, `--trace`, or `--trace-ascii`, because those print the request headers and the Authorization header is one of them; use `-s` and read the response body.
   Never print a config, client, or settings object whole - a debug print, `console.log`, `repr`, `dump`, or pretty-printer usually carries the loaded key inside it - and print the one non-secret field you actually wanted.
   Never let a raw crash reach your pane on a credentialed path: a stack trace, an assertion message, or an error that interpolates the failed request can carry the value in a frame, so catch around the risky call and report without the payload.
   Never build a test fixture, snapshot, cassette, recorded HTTP interaction, or `.env.example` out of live environment values; invent an obvious fake like `sk-test-not-a-real-key` and use that.
   If a value does land in your pane, a file, or a commit despite all of this, stop immediately, append `blocked: {which credential leaked and where}` to the status file, and do not try to scrub it quietly - that key has to be rotated, and an unreported leak costs far more than a reported one.
EOF
CREDENTIALS_RULE=${CREDENTIALS_RULE%$'\n'}
# Where the values actually are, stated only for a home that actually has the
# file, so a home without one is never sent looking for it. fm-spawn.sh loads it
# into the worker's pane shell (bin/fm-worker-env-lib.sh); this half of the rule
# is what stops a worker from committing it or reading it out to look at a value.
if [ -f "$FM_HOME/.env" ]; then
  IFS= read -r -d '' CREDENTIALS_LOCATION <<'EOF' || true
   The values live in one mode-600 gitignored `.env` in the firstmate home, and firstmate loads it into your environment when it launches you, so the variables are simply there for you to use.
   Never commit that file, never copy it or its contents into a project, a fixture, or an image, and never add it to a repository's tracked files - the reason it is safe to keep credentials in your environment at all is that this one file stays out of every repo.
   Never open it to see what a value is: test the variable instead, the same way you would test any other credential.
EOF
  CREDENTIALS_RULE="$CREDENTIALS_RULE"$'\n'"${CREDENTIALS_LOCATION%$'\n'}"
fi
# Which credentials the vault discipline actually covers. This repo is a shared
# template and each home's split between vault and environment is a local policy
# decision, so the names cannot be hard-coded here: config/vault-only-keys is
# that home's declaration, one KEY name per line, `#` comments and blanks
# ignored. Absent means the unnarrowed original contract - every credential goes
# through the vault - which is both the safe default and what every existing home
# already had, so this file's absence changes nothing for anyone.
# Present-but-empty is an error rather than a third "no vault at all" mode: a
# list that silently covers no key would turn the protection off without anyone
# reading a diff, and deleting the file is the explicit way back to covering all.
# An unusable name is an error for the same reason - dropping it would quietly
# route a vaulted credential to the environment instead.
VAULT_ONLY_KEYS=""
VAULT_ONLY_FILE="$CONFIG/vault-only-keys"
if [ -f "$VAULT_ONLY_FILE" ]; then
  while IFS= read -r vault_line || [ -n "$vault_line" ]; do
    vault_line=${vault_line%$'\r'}
    vault_line=${vault_line#"${vault_line%%[![:space:]]*}"}
    vault_line=${vault_line%"${vault_line##*[![:space:]]}"}
    case "$vault_line" in
      ''|'#'*) continue ;;
      *[!A-Za-z0-9_]*|[!A-Za-z_]*)
        echo "error: $VAULT_ONLY_FILE: not a usable environment variable name: $vault_line" >&2
        exit 1
        ;;
    esac
    if [ -n "$VAULT_ONLY_KEYS" ]; then
      VAULT_ONLY_KEYS="$VAULT_ONLY_KEYS, $vault_line"
    else
      VAULT_ONLY_KEYS="$vault_line"
    fi
  done < "$VAULT_ONLY_FILE"
  if [ -z "$VAULT_ONLY_KEYS" ]; then
    echo "error: $VAULT_ONLY_FILE lists no key names; delete the file to apply vault discipline to every credential" >&2
    exit 1
  fi
fi
if command -v av >/dev/null 2>&1; then
  # Scoped mode names the covered keys up front, so a worker can tell which world
  # it is in without running anything. Everything else is read from the
  # environment with no vault call and no stop: a worker that blocks waiting for
  # a vault which does not hold its key has failed for no reason at all, and it
  # would fail that way on every lane at once.
  if [ -n "$VAULT_ONLY_KEYS" ]; then
    IFS= read -r -d '' CREDENTIALS_VAULT_SCOPE <<EOF || true
   Exactly these credentials are kept out of that file and out of your environment, and are reached through Automic Vault instead: $VAULT_ONLY_KEYS.
   They stay in the vault because leaking one of them is money and a compliance incident rather than an API bill, so everything from here to the end of this rule applies to those names and to nothing else.
   Every other credential is already in your environment: read it normally, wrap the command in nothing, and do not go looking for a vault - if a key you need is missing, that is a missing credential to report, never a reason to reach for \`av\`.
EOF
    CREDENTIALS_RULE="$CREDENTIALS_RULE"$'\n'"${CREDENTIALS_VAULT_SCOPE%$'\n'}"
  fi
  IFS= read -r -d '' CREDENTIALS_VAULT <<'EOF' || true
   Before you use `av` for anything, confirm the `av` on this machine IS Automic Vault by running `av help 2>&1 | grep -q 'automicvault\.com'`, which must succeed.
   `av` is only a command name and other tools ship one by that same name, so an `av` that fails that probe is a different program, and naming a credential to it would hand that credential to whatever it actually is.
   If the probe does not confirm the vault - other output, an error, or no `av` on this machine at all - append `blocked: av on this machine is not Automic Vault` to the status file and stop.
   Never guess at another vault command and never fall back to reading the credential out of the ambient environment: reaching a vaulted key that way is exactly the exposure this rule exists to remove, so stopping and reporting is correct here and improvising is not.
__VAULT_REACH_SENTENCE__
   One `+KEY` per credential, then `--`, then the command; the command itself needs no change, because it still reads the same variables it always did and only the way you launch it changes.
__VAULT_NAMING_SENTENCE__
   `av list` is not a liveness check for the vault: it fails while the vault's approval service is not running, so a failed listing is not proof that a key is absent, and the identity probe above is the one check that does not depend on that service.
   An authentication failure or an unset key is the signal that a command needs `av inject`; it is never a reason to hunt for the value, read it out of a config file, or ask for it to be pasted to you.
   When the vault path itself fails - the identity probe fails, `av inject` fails, the key you named is not in the vault, or the credential otherwise never arrives - append `blocked: {the vault failure}` to the status file and stop.
   Never rerun the command bare, meaning never drop the `av inject ... --` wrapper and launch the command directly, because a bare rerun can quietly succeed on a copy of the key that should not exist - a leftover ambient value, a config file, a note someone pasted - and that silent success is the exact exposure this rule exists to remove.
   A fallback that works is worse than an error here: the error is visible and the silent success is not, so a failed vault call ends the attempt instead of being worked around.
   That is a rule about the wrapper and not about the wrapped command's own exit code: when the command itself runs and fails on its own merits - a failing test, a compile error, a bug in the script - debug it normally, and keep every rerun under the same `av inject` wrapper.
   Do not use `av bless`: it approves a script by path, so blessing a file inside the project would mix a local approval into the change you are shipping, and the explicit `+KEY` form needs no blessing at all.
EOF
  # Two sentences carry the whole all-credentials-vs-listed-keys difference, so
  # they are substituted rather than the body being kept in two near-identical
  # copies that would drift the first time only one was edited.
  if [ -n "$VAULT_ONLY_KEYS" ]; then
    VAULT_REACH_SENTENCE="   A vaulted credential is deliberately absent from your environment, so a command that needs one names it at the call site: \`av inject +SERVICE_API_KEY +OTHER_TOKEN -- pnpm run benchmark\`."
    VAULT_NAMING_SENTENCE="   Name only the vaulted keys YOUR task actually needs instead of copying that example, and reach every other credential straight from the environment; \`av help\` covers the rest."
  else
    VAULT_REACH_SENTENCE="   Credentials belong in Automic Vault rather than the ambient environment, so any command that authenticates or spends money names the keys it needs at the call site: \`av inject +SERVICE_API_KEY +OTHER_TOKEN -- pnpm run benchmark\`."
    VAULT_NAMING_SENTENCE="   Name the keys YOUR task actually needs instead of copying that example - \`av list\` shows the names this machine holds, and \`av help\` covers the rest."
  fi
  CREDENTIALS_VAULT=${CREDENTIALS_VAULT//__VAULT_REACH_SENTENCE__/$VAULT_REACH_SENTENCE}
  CREDENTIALS_VAULT=${CREDENTIALS_VAULT//__VAULT_NAMING_SENTENCE__/$VAULT_NAMING_SENTENCE}
  CREDENTIALS_RULE="$CREDENTIALS_RULE"$'\n'"${CREDENTIALS_VAULT%$'\n'}"
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
   Your browser is private to this task - no other worker can see or touch your pages, and you cannot disturb theirs - so open what you need and leave it open.
   Do not park, close, or stop anything, do not change \`CHROME_DEVTOOLS_AXI_SESSION\`, and do not add browser cleanup later: the whole session is retired for you when this task ends, however it ends.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
$CREDENTIALS_RULE

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief because the worker never owns approval decisions;
# firstmate applies the authority contract in AGENTS.md section 7, so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its \`AGENTS.md\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

# Opt-in visual-evidence contract. It stays empty unless --visual-evidence was
# passed, and it carries its own leading newline so an omitted section leaves the
# surrounding brief byte-identical to a brief scaffolded without the flag.
RULE2='2. Stay inside this worktree; modify nothing outside it.'
VISUAL_EVIDENCE_SECTION=""
if [ "$VISUAL_EVIDENCE" -eq 1 ]; then
IFS= read -r -d '' RULE2 <<EOF || true
2. Stay inside this worktree; modify nothing outside it.
   The single exception is this task's own visual-evidence directory \`$EVIDENCE_DIR\` in the firstmate home, described under Visual evidence below.
   That is the same class of write, to the same home, as the status file you append to in rule 4: every brief already writes that one file outside its worktree.
   It authorizes nothing else - not another task's record directory, not that home's shared files, not any other path.
EOF
RULE2=${RULE2%$'\n'}
IFS= read -r -d '' VISUAL_EVIDENCE_SECTION <<EOF || true
# Visual evidence - show the change, do not describe it
This task changes a user-visible surface, so every claim about how it looks must arrive as a capture of the real thing, not as prose.
The medium follows the surface: a browser view is captured as a screenshot of the real page at the real route, terminal or CLI output as the real transcript of the real command, a generated file or payload as its real content.

1. **Before is a capture of the real surface as it stands today.** Run the project, reach the affected surface, and capture it: the real page at the real route, the real command with its real output, the real generated content. A written description of the current look is never a before. The one exception is a surface that does not exist yet - say so in a line and go straight to the after.
2. **After is always an artifact, never prose alone.** In order of preference: a capture of the change running in a throwaway prototype; a mock rendered in the project's own design system; a diagram. If prototyping the after looks too expensive, that is evidence the change is under-specified - settle what it should be first. It is not an exemption.
   The single carve-out is a change no still capture can hold, meaning motion, timing, or a measurement, and then a recording or the measured result is the artifact. Name the form you used and why a still could not carry the claim. "I could not show it" with nothing attached is not a carve-out; it is a missing after.
3. **One tight capture per claim, placed beside the claim it evidences.** Do not dump a single full-page image or an entire transcript at the top and leave the reader to map it back onto the text.
4. **Crop and annotate down to the region that changed.** A full-page image offered as proof that one element moved, or a whole log offered as proof of one changed line, makes the reviewer do the diffing.
5. **Prose is reserved for what cannot be shown** - rationale, trade-offs, and open questions.

## Producing the artifacts
Build every prototype and capture inside this worktree, under \`.fm-scratch/\`: create the directory and write a single \`*\` line into \`.fm-scratch/.gitignore\`, which hides the whole directory from git without touching the project's own ignore file.
A prototype is scratch: never commit it to your \`fm/$ID\` branch, and expect it to die with this worktree.
Capture browser surfaces with \`chrome-devtools-axi\`.
If you conclude an artifact cannot be produced without writing outside this worktree and its evidence directory, append \`blocked: {why}\` and stop; that is an escalation, not a licence to write anywhere else.

## Delivering the artifacts
Copy every artifact you present out of \`.fm-scratch/\` into this task's own evidence directory, which outlives this worktree: run \`mkdir -p $EVIDENCE_DIR\` and copy them there, keeping the layout flat with one file per claim.
Link each artifact by its path beside the claim it evidences - in the pull request body when this project opens one, in the summary you hand back when it does not - never as a block at the bottom.
Write that path in the home-relative form \`$EVIDENCE_REL/{file}\`, never the absolute path you just gave \`mkdir\`: a pull request body can be published, and the absolute form would put this machine's account name and home layout in it.
When the pull request is opened for you, add those links to its body with \`gh-axi\` as soon as it exists, appending to the body it already has and preserving every line of it rather than replacing it, because a project can require a signature or a section in that body and a replacement drops it and fails a required check; when you open it yourself, write them into the body you author; when there is no pull request, name this directory in the hand-back you return.
Treat that as check-then-repair rather than a one-shot edit: the pipeline owns a body it opened and a rerun or any other republish overwrites what you wrote, so read the body back with \`gh-axi\`, confirm every link is still present before you report this task done, and add them again if they are gone.
Adding those links is not a code edit and not a findings fix, so it is not the hand-editing that an active validation run forbids.
Write each claim so the prose carries it on its own: a path is opaque to a reader who cannot open the file, so the sentence states what changed and the artifact confirms it. That is not prose standing in for an after; the artifact stays mandatory.
Accept the one limitation rather than working around it: a reviewer who is not on this machine cannot open these files, so for work whose pull request goes to a public upstream the artifacts are the captain's verification rather than the upstream reviewer's, and the self-carrying prose above is what keeps that pull request readable for both.
That is also why the artifacts go nowhere else, not to a gist and not to any other host: a secret gist is unlisted rather than access-controlled, so anyone holding the link could read captures of a private product.
EOF
# The leading newline opens the blank line before the heading, and the trailing
# newline read -r -d '' preserved closes the blank line before "# Project memory".
VISUAL_EVIDENCE_SECTION=$'\n'${VISUAL_EVIDENCE_SECTION}
fi

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
$RULE2
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
   Your browser is private to this task - no other worker can see or touch your pages, and you cannot disturb theirs - so open what you need and leave it open.
   Do not park, close, or stop anything, do not change \`CHROME_DEVTOOLS_AXI_SESSION\`, and do not add browser cleanup later: the whole session is retired for you when this task ends, however it ends.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will apply the configured authority and reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
$CREDENTIALS_RULE
$VISUAL_EVIDENCE_SECTION
# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
