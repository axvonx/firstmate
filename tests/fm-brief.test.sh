#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_visual_evidence_contract_is_opt_in_and_complete() {
  local home id brief
  home="$TMP_ROOT/visual-evidence-home"
  write_registry "$home"

  # The contract renders for every ship delivery mode, since a change needs the
  # same evidence whether it lands through the pipeline, a direct PR, or locally.
  for id_proj in "brief-visual-nm-e1:no-registry-proj" "brief-visual-dpr-e2:direct-proj" "brief-visual-lo-e3:local-proj"; do
    id=${id_proj%%:*}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "${id_proj##*:}" --visual-evidence >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: --visual-evidence brief was not scaffolded"
    assert_grep "# Visual evidence - show the change, do not describe it" "$brief" \
      "$id: visual-evidence brief missing its section heading"
    assert_grep "Before is a capture of the real surface as it stands today" "$brief" \
      "$id: visual-evidence contract lost the real-surface before requirement"
    assert_grep "the real page at the real route, the real command with its real output, the real generated content" "$brief" \
      "$id: visual-evidence contract lost the per-surface before media"
    assert_grep "A written description of the current look is never a before." "$brief" \
      "$id: visual-evidence contract allowed a prose before"
    assert_grep "The one exception is a surface that does not exist yet" "$brief" \
      "$id: visual-evidence contract demanded a before for a surface that cannot be captured"
    assert_grep "After is always an artifact, never prose alone" "$brief" \
      "$id: visual-evidence contract lost the artifact-after requirement"
    assert_grep "a capture of the change running in a throwaway prototype; a mock rendered in the project's own design system; a diagram" "$brief" \
      "$id: visual-evidence contract lost the ordered after-artifact preference"
    assert_grep "that is evidence the change is under-specified" "$brief" \
      "$id: visual-evidence contract lost the under-specified consequence"
    assert_grep "It is not an exemption." "$brief" \
      "$id: visual-evidence contract offered a cost-based exemption"
    assert_grep "One tight capture per claim, placed beside the claim it evidences" "$brief" \
      "$id: visual-evidence contract lost per-claim colocation"
    assert_grep "Do not dump a single full-page image or an entire transcript at the top" "$brief" \
      "$id: visual-evidence contract allowed a page dump at the top"
    assert_grep "Crop and annotate down to the region that changed" "$brief" \
      "$id: visual-evidence contract lost the crop-and-annotate requirement"
    assert_grep "Prose is reserved for what cannot be shown" "$brief" \
      "$id: visual-evidence contract lost the prose-is-for-the-unshowable rule"
    # The medium follows the surface, so a CLI or file surface is capturable too.
    assert_grep "terminal or CLI output as the real transcript of the real command" "$brief" \
      "$id: visual-evidence contract is browser-only and unsatisfiable for a CLI surface"
    assert_grep "a generated file or payload as its real content" "$brief" \
      "$id: visual-evidence contract lost the generated-content medium"
    assert_grep "Capture browser surfaces with \`chrome-devtools-axi\`." "$brief" \
      "$id: visual-evidence contract lost the browser capture tool as a browser-scoped example"
    # The after carve-out is narrow and conditional: a still that cannot hold the
    # change is not a licence to fall back to prose.
    assert_grep "The single carve-out is a change no still capture can hold, meaning motion, timing, or a measurement" "$brief" \
      "$id: visual-evidence contract lost the narrow motion/timing/measurement carve-out"
    assert_grep "Name the form you used and why a still could not carry the claim." "$brief" \
      "$id: visual-evidence carve-out did not require naming the artifact form and its justification"
    assert_grep "\"I could not show it\" with nothing attached is not a carve-out; it is a missing after." "$brief" \
      "$id: visual-evidence carve-out allowed an unattached claim to pass as an after"
    # Rule 2 stands: prototypes and captures are built inside the worktree in one
    # conventional self-ignoring scratch dir, never committed to the code branch.
    assert_grep "Build every prototype and capture inside this worktree, under \`.fm-scratch/\`" "$brief" \
      "$id: visual-evidence contract did not confine artifact production to the worktree"
    assert_grep "write a single \`*\` line into \`.fm-scratch/.gitignore\`" "$brief" \
      "$id: visual-evidence contract lost the self-ignoring scratch directory mechanism"
    assert_grep "never commit it to your \`fm/$id\` branch" "$brief" \
      "$id: visual-evidence contract let a scratch prototype land on the code branch"
    assert_grep "append \`blocked: {why}\` and stop; that is an escalation, not a licence to write anywhere else" "$brief" \
      "$id: visual-evidence contract turned an impossible capture into licence to write anywhere else"
    assert_no_grep "Those artifacts and the status file are the only things you write outside the worktree." "$brief" \
      "$id: visual-evidence contract still carves an unnamed exception out of ship rule 2"
    # The artifacts presented go to this task's own record directory, which
    # outlives the worktree, and nowhere else.
    assert_grep "Copy every artifact you present out of \`.fm-scratch/\` into this task's own evidence directory" "$brief" \
      "$id: visual-evidence contract lost the record-directory delivery destination"
    assert_grep "run \`mkdir -p '$home/data/$id/evidence'\` and copy them there" "$brief" \
      "$id: visual-evidence contract did not name the task's own absolute evidence directory"
    assert_grep "Link each artifact by its path beside the claim it evidences" "$brief" \
      "$id: visual-evidence contract lost per-claim colocation of the artifact paths"
    assert_grep "never as a block at the bottom" "$brief" \
      "$id: visual-evidence contract allowed an artifact block at the bottom"
    # The link that lands in a publishable body is the home-relative path, so the
    # absolute path stays confined to the local mkdir that has to resolve.
    assert_grep "Write that path in the home-relative form \`data/$id/evidence/{file}\`" "$brief" \
      "$id: visual-evidence contract did not name the home-relative link form"
    assert_grep "never the absolute path you just gave \`mkdir\`" "$brief" \
      "$id: visual-evidence contract left the absolute path as the link written into a shared surface"
    assert_grep "would put this machine's account name and home layout in it" "$brief" \
      "$id: visual-evidence contract lost the reason a published body must not carry the absolute path"
    assert_grep "run \`mkdir -p '$home/data/$id/evidence'\`" "$brief" \
      "$id: visual-evidence contract lost the absolute path from the local mkdir that must resolve"
    # Who authors the pull request body, and when the links go in, for a mode
    # whose pipeline opens the pull request on the worker's behalf.
    assert_grep "When the pull request is opened for you, add those links to its body with \`gh-axi\` as soon as it exists" "$brief" \
      "$id: visual-evidence contract gave no owner or timing for a pull request body opened for the worker"
    assert_grep "when you open it yourself, write them into the body you author; when there is no pull request, name this directory in the hand-back you return" "$brief" \
      "$id: visual-evidence contract left the self-opened and no-pull-request cases unstated"
    # A body that already exists may carry a signature or section a required check
    # greps for, so the edit is an append and never a replacement.
    assert_grep "appending to the body it already has and preserving every line of it" "$brief" \
      "$id: visual-evidence contract let the worker replace a pull request body instead of appending to it"
    assert_grep "a project can require a signature or a section in that body" "$brief" \
      "$id: visual-evidence contract gave no reason a replaced body fails a required check"
    # A rerun republishes a pipeline-owned body, so the links are verified again
    # at the done gate rather than written once and assumed to survive.
    assert_grep "Treat that as check-then-repair rather than a one-shot edit" "$brief" \
      "$id: visual-evidence contract added the links once and never re-checked them"
    assert_grep "a rerun or any other republish overwrites what you wrote" "$brief" \
      "$id: visual-evidence contract did not say a rerun can drop the links it required"
    assert_grep "confirm every link is still present before you report this task done, and add them again if they are gone" "$brief" \
      "$id: visual-evidence contract left the links unverified at the done gate"
    assert_grep "Adding those links is not a code edit and not a findings fix, so it is not the hand-editing that an active validation run forbids." "$brief" \
      "$id: visual-evidence contract reads as licence to hand-edit during an active validation run"
    assert_grep "Write each claim so the prose carries it on its own" "$brief" \
      "$id: visual-evidence contract left the prose unreadable to anyone who cannot open the files"
    assert_grep "That is not prose standing in for an after; the artifact stays mandatory." "$brief" \
      "$id: visual-evidence contract let self-carrying prose weaken the artifact requirement"
    assert_grep "a reviewer who is not on this machine cannot open these files" "$brief" \
      "$id: visual-evidence contract papered over the accepted limitation of a local artifact home"
    assert_grep "not to a gist and not to any other host" "$brief" \
      "$id: visual-evidence contract lost the no-other-host prohibition"
    assert_grep "a secret gist is unlisted rather than access-controlled" "$brief" \
      "$id: visual-evidence contract lost the reason a gist is not an artifact home"
    # The withdrawn evidence-ref mechanism must not come back in any form.
    assert_no_grep "fm/$id-evidence" "$brief" \
      "$id: visual-evidence contract still carries the withdrawn sibling evidence ref"
    assert_no_grep "git switch --orphan" "$brief" \
      "$id: visual-evidence contract still carries the withdrawn orphan-ref mechanics"
    assert_no_grep "evidence:" "$brief" \
      "$id: visual-evidence contract still carries the withdrawn evidence commit prefix"
    assert_no_grep "must be deleted" "$brief" \
      "$id: visual-evidence contract still carries the withdrawn ref-deletion requirement"
    # Rule 2 keeps its absolute opening and gains exactly one named exception.
    assert_grep "2. Stay inside this worktree; modify nothing outside it." "$brief" \
      "$id: visual-evidence brief weakened the opening of ship rule 2"
    assert_grep "The single exception is this task's own visual-evidence directory \`'$home/data/$id/evidence'\`" "$brief" \
      "$id: ship rule 2 did not name the one authorized write outside the worktree"
    assert_grep "the same class of write, to the same home, as the status file you append to in rule 4" "$brief" \
      "$id: ship rule 2 carve-out lost the status-file precedent that bounds it"
    assert_grep "It authorizes nothing else - not another task's record directory, not that home's shared files, not any other path." "$brief" \
      "$id: ship rule 2 carve-out did not bound its own scope"
    assert_no_grep "EOF" "$brief" \
      "$id: visual-evidence brief leaked a heredoc EOF marker"
  done

  # Absent by default: a brief for work with no user-visible surface must not
  # carry the contract, and unlike --herdr-lab it leaves no declaration behind.
  # Every brief interpolates two host paths nobody here controls - the checkout
  # ($FM_ROOT, in the project-memory section) and the firstmate home ($FM_HOME,
  # under the status-file line) - so a bare-word absence assertion run against the
  # rendered brief would false-fail whenever a checkout or home directory name
  # happens to contain "evidence" or "screenshot", and would blame the generator
  # for content it never emitted. The absence assertions therefore read a copy
  # with those two paths replaced, and two self-checks below keep the scrub honest.
  local plain_home plain_rendered plain_brief
  plain_home="$TMP_ROOT/no-contract-home"
  write_registry "$plain_home"
  id="brief-default-ship-e4"
  FM_HOME="$plain_home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj >/dev/null 2>&1
  brief="$plain_home/data/$id/brief.md"
  assert_present "$brief" "$id: default ship brief was not scaffolded"
  plain_rendered=$(cat "$brief")
  plain_rendered=${plain_rendered//"$ROOT"/FM-CHECKOUT-PATH}
  plain_rendered=${plain_rendered//"$plain_home"/FM-HOME-PATH}
  plain_brief="$TMP_ROOT/no-contract-brief-host-paths-scrubbed.md"
  printf '%s\n' "$plain_rendered" > "$plain_brief"
  assert_no_grep "$ROOT" "$plain_brief" \
    "$id: checkout path survived the scrub, so the absence assertions are coupled to its directory name"
  assert_no_grep "$plain_home" "$plain_brief" \
    "$id: firstmate home path survived the scrub, so the absence assertions are coupled to its directory name"
  assert_no_grep "Visual evidence" "$plain_brief" \
    "$id: default ship brief carried the visual-evidence contract"
  assert_no_grep "visual-evidence" "$plain_brief" \
    "$id: default ship brief carried a visual-evidence declaration or regeneration notice"
  assert_no_grep "screenshot" "$plain_brief" \
    "$id: default ship brief bloated with screenshot instructions"
  assert_no_grep ".fm-scratch" "$plain_brief" \
    "$id: default ship brief carried the visual-evidence scratch convention"
  assert_no_grep "evidence" "$plain_brief" \
    "$id: default ship brief carried the visual-evidence delivery convention"
  # Rule 2 is byte-identical to the unflagged shape: the carve-out is opt-in too.
  assert_grep "2. Stay inside this worktree; modify nothing outside it." "$brief" \
    "$id: default ship brief lost ship rule 2"
  assert_no_grep "The single exception is this task's own" "$plain_brief" \
    "$id: default ship brief carried the rule 2 carve-out without the flag"
  assert_no_grep "add those links to its body" "$plain_brief" \
    "$id: default ship brief carried the visual-evidence pull-request-body clause"
  assert_no_grep "check-then-repair" "$plain_brief" \
    "$id: default ship brief carried the visual-evidence link re-check clause"
  assert_no_grep "appending to the body it already has" "$plain_brief" \
    "$id: default ship brief carried the visual-evidence append-not-replace clause"

  # Every scaffold still documents the flag through --help.
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "--visual-evidence adds the visual-evidence contract" \
    "fm-brief.sh --help does not document --visual-evidence"
  assert_contains "$help" "The medium follows the surface" \
    "fm-brief.sh --help still documents the contract as browser-only"
  assert_contains "$help" "self-ignoring .fm-scratch/ and are never committed to the code branch" \
    "fm-brief.sh --help does not document where the artifacts are produced"
  assert_contains "$help" "data/<task-id>/evidence/" \
    "fm-brief.sh --help does not document where the artifacts are delivered"
  assert_contains "$help" "single exception to" \
    "fm-brief.sh --help does not document the rule 2 carve-out the flag adds"
  assert_contains "$help" "pull request body as soon as it exists, whoever opened it" \
    "fm-brief.sh --help does not document when the per-claim links reach the pull request body"
  assert_contains "$help" "data/<task-id>/evidence/<file>, never the absolute path the copy step needs" \
    "fm-brief.sh --help does not document that the link is home-relative rather than absolute"
  assert_contains "$help" "appended to an existing body rather than replacing it" \
    "fm-brief.sh --help does not document that the links append to an existing pull request body"
  assert_contains "$help" "links are re-checked and re-added before the task reports done" \
    "fm-brief.sh --help does not document that a republished pull request body is repaired"
  assert_not_contains "$help" "-evidence ref" \
    "fm-brief.sh --help still documents the withdrawn evidence ref"
  pass "fm-brief.sh: --visual-evidence emits the full contract and is absent otherwise"
}

test_visual_evidence_is_ship_only() {
  local home status
  home="$TMP_ROOT/visual-evidence-misuse-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" visual-scout someproj --scout --visual-evidence >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--visual-evidence on a scout brief must fail"
  assert_absent "$home/data/visual-scout/brief.md" "rejected scout --visual-evidence still wrote a brief"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops \
    "$ROOT/bin/fm-brief.sh" visual-mate --secondmate --no-projects --visual-evidence >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--visual-evidence on a secondmate charter must fail"
  assert_absent "$home/data/visual-mate/brief.md" "rejected secondmate --visual-evidence still wrote a brief"
  pass "fm-brief.sh: --visual-evidence is ship-only and rejects misuse without writing a brief"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# PATH with EVERY directory holding an executable `av` removed, so the
# vault-absent branch is deterministic on a host that has Automic Vault installed
# more than once - dropping only the directory `command -v av` resolved first
# would just uncover the next copy. An empty entry means the current directory and
# is dropped for the same reason. A host with no `av` anywhere on PATH loses
# nothing, which is already the absent case.
path_without_av() {
  local entry out=""
  local IFS=:
  for entry in $PATH; do
    [ -n "$entry" ] || continue
    [ -x "${entry%/}/av" ] && continue
    out="${out}${out:+:}$entry"
  done
  printf '%s\n' "$out"
}

# The credential rule exists because a crewmate once echoed an API key's value,
# which put it in a prompt sent to a model provider. Its first half - never print
# a credential - holds on every host. The vault call pattern is added only where
# Automic Vault is installed, so a host without it is never told to reach for a
# tool it does not have. Both branches are driven through PATH rather than an
# ambient host fact, so each is exercised wherever the suite runs.
test_credential_rule_covers_ship_and_scout() {
  local home id brief kind fakebin novault probe_line inject_line
  home="$TMP_ROOT/credential-home"
  write_registry "$home"
  fakebin=$(fm_fakebin "$TMP_ROOT/credential-vault")
  fm_fake_exit0 "$fakebin" av
  # An exported shell function named `av` would be inherited by the scaffold and
  # satisfy its `command -v av` gate no matter what PATH says, so drop it too.
  unset -f av 2>/dev/null || true
  novault=$(path_without_av)

  for kind in ship scout; do
    id="brief-credentials-$kind"
    if [ "$kind" = scout ]; then
      PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj --scout >/dev/null 2>&1
    else
      PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind: credential brief was not scaffolded"

    # Half one: the value never leaves, and the reason it must not.
    assert_grep "8. Never print, echo, log, or paste the VALUE of an API key, token, or other credential" "$brief" \
      "$kind: brief lost the never-print-a-credential rule"
    assert_grep "not into your pane, not into a file you write, and not into a commit, a status line, or a pull request body" "$brief" \
      "$kind: never-print rule did not cover the surfaces a value can leak into"
    assert_grep "Everything you print is sent to a model provider, so a printed credential is a leaked credential that has to be rotated." "$brief" \
      "$kind: never-print rule lost the reason printing a credential leaks it and forces a rotation"
    # shellcheck disable=SC2016  # literal brief text: the parameter expansion must not expand here
    assert_grep 'test it (`[ -n "${SOME_API_KEY:-}" ]`) rather than printing it' "$brief" \
      "$kind: never-print rule left the worker no way to check a credential without printing it"

    # The realistic leak is INDIRECT. The one real incident was a worker echoing
    # a key that was in its environment, and moving credentials from a
    # machine-wide `launchctl setenv` into a per-home .env that fm-spawn loads
    # keeps MORE keys reliably in a worker's environment, so the rule has to name
    # the commands that print a value nobody typed - not just forbid `echo $KEY`.
    assert_grep "the leak you are most likely to cause an INDIRECT one: a command that prints a value you never typed" "$brief" \
      "$kind: never-print rule did not warn that the realistic leak is indirect"
    # That framing is unconditional, so it must be true for a home that vaults
    # everything too. A brief that says credentials are ambient and then says
    # they belong in the vault instead is worse than either version alone,
    # because a worker follows whichever it read last.
    assert_no_grep "Most of the credentials you can reach are sitting in your environment" "$brief" \
      "$kind: the never-print framing asserted this home's credentials are ambient into every home's brief"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'Never dump the environment - no bare `env`, `printenv`, `export -p`, or `set`' "$brief" \
      "$kind: never-print rule left a whole-environment dump unaddressed"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep '`set -x` and `bash -x` echo the expanded command line' "$brief" \
      "$kind: never-print rule left shell tracing echoing a credentialed command line"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'Never run an authenticated request under `curl -v`' "$brief" \
      "$kind: never-print rule left a verbose curl printing the Authorization header"
    assert_grep "Never print a config, client, or settings object whole" "$brief" \
      "$kind: never-print rule left a debug dump of a loaded config object unaddressed"
    assert_grep "Never let a raw crash reach your pane on a credentialed path" "$brief" \
      "$kind: never-print rule left a stack trace carrying a credential unaddressed"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'cassette, recorded HTTP interaction, or `.env.example` out of live environment values' "$brief" \
      "$kind: never-print rule let a fixture be built from a live credential"
    # A leak that has happened is only recoverable if it is reported: the key has
    # to be rotated, and a quiet scrub leaves a live key in a transcript.
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'append `blocked: {which credential leaked and where}` to the status file' "$brief" \
      "$kind: never-print rule gave an actual leak no route into stop-and-report"
    assert_grep "do not try to scrub it quietly" "$brief" \
      "$kind: never-print rule left hiding a leak as an option"

    # Half two opens with an identity probe: `av` is a name, not proof of the tool
    # behind it, and other tools ship a command by that name. A worker that pipes a
    # credential through a foreign `av` has leaked it to whatever that program is.
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'Before you use `av` for anything, confirm the `av` on this machine IS Automic Vault' "$brief" \
      "$kind: vault guidance let the worker trust a command by name alone"
    assert_grep "av help 2>&1 | grep -q 'automicvault\.com'" "$brief" \
      "$kind: vault guidance did not give the worker a concrete identity probe to run"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep '`av` is only a command name and other tools ship one by that same name' "$brief" \
      "$kind: vault guidance did not say why a name is not proof of the tool"
    # A failed probe is an escalation, not a puzzle to work around.
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'append `blocked: av on this machine is not Automic Vault` to the status file and stop' "$brief" \
      "$kind: a failed identity probe did not route into the brief's stop-and-report path"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'other output, an error, or no `av` on this machine at all' "$brief" \
      "$kind: identity probe left a missing or foreign av as an undefined case"
    assert_grep "Never guess at another vault command and never fall back to reading the credential out of the ambient environment" "$brief" \
      "$kind: identity probe left the ambient environment open as a fallback"
    assert_grep "reaching a vaulted key that way is exactly the exposure this rule exists to remove, so stopping and reporting is correct here and improvising is not" "$brief" \
      "$kind: brief did not say why stopping beats falling back to the ambient environment"
    # The probe only protects the worker if it is read before the tool is used.
    probe_line=$(grep -nF "automicvault" "$brief" | head -1 | cut -d: -f1)
    inject_line=$(grep -nF 'av inject +SERVICE_API_KEY' "$brief" | head -1 | cut -d: -f1)
    [ -n "$probe_line" ] && [ -n "$inject_line" ] && [ "$probe_line" -lt "$inject_line" ] \
      || fail "$kind: identity probe must be stated before the av inject invocation it guards"

    # Half two: how to actually reach a credential, keys named at the call site.
    assert_grep "Credentials belong in Automic Vault rather than the ambient environment" "$brief" \
      "$kind: brief did not tell the worker where credentials actually live"
    assert_grep "any command that authenticates or spends money names the keys it needs at the call site" "$brief" \
      "$kind: vault guidance did not require naming keys at the call site"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep '`av inject +SERVICE_API_KEY +OTHER_TOKEN -- pnpm run benchmark`' "$brief" \
      "$kind: vault guidance lost the concrete explicit +KEY invocation"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'One `+KEY` per credential, then `--`, then the command' "$brief" \
      "$kind: vault guidance did not spell out the invocation shape"
    assert_grep "the command itself needs no change, because it still reads the same variables it always did" "$brief" \
      "$kind: vault guidance implied a credential consumer must be edited"
    # The scaffold teaches the pattern; it must never carry a key list that rots.
    assert_grep "Name the keys YOUR task actually needs instead of copying that example" "$brief" \
      "$kind: vault guidance let the worker copy the example keys instead of naming its own"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep '`av list` shows the names this machine holds' "$brief" \
      "$kind: vault guidance gave no way to discover the real key names"
    assert_grep "An authentication failure or an unset key is the signal that a command needs" "$brief" \
      "$kind: vault guidance did not name the failure that means a credential is missing"
    assert_grep "never a reason to hunt for the value, read it out of a config file, or ask for it to be pasted to you" "$brief" \
      "$kind: vault guidance left an auth failure as licence to go looking for the raw value"
    # With no declared split, every credential is the vault's, so nothing here
    # may route a missing one to the environment instead.
    assert_no_grep "An unset credential that is NOT one of those names" "$brief" \
      "$kind: the unnarrowed rule carried the narrowed routing for a non-vaulted key"
    # Discovery needs the vault's approval service, so a failed listing says
    # nothing about whether a key exists; only the probe works without it.
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep '`av list` is not a liveness check for the vault' "$brief" \
      "$kind: vault guidance let a failed listing pass as a vault verdict"
    assert_grep "a failed listing is not proof that a key is absent" "$brief" \
      "$kind: vault guidance let a down approval service read as an absent key"

    # Every failure on the vault path stops, not only a failed identity probe:
    # the worker's natural next move - drop the wrapper and rerun - can still be
    # satisfied by a copy of the key that should not exist, and would leave no
    # trace of having spent it.
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'the identity probe fails, `av inject` fails, the key you named is not in the vault, or the credential otherwise never arrives' "$brief" \
      "$kind: stop-and-report still covers only a failed probe, not the whole vault path"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'append `blocked: {the vault failure}` to the status file and stop' "$brief" \
      "$kind: a failed vault call had no route into the brief's stop-and-report path"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'Never rerun the command bare, meaning never drop the `av inject ... --` wrapper' "$brief" \
      "$kind: brief left dropping the wrapper as an unstated option after a vault failure"
    assert_grep "a bare rerun can quietly succeed on a copy of the key that should not exist" "$brief" \
      "$kind: brief did not say a bare rerun silently spends a copy that should not exist"
    assert_grep "A fallback that works is worse than an error here: the error is visible and the silent success is not" "$brief" \
      "$kind: brief did not say why a working fallback is worse than a failure"
    # The widened stop must not swallow ordinary debugging: a wrapped command that
    # fails on its own merits is normal work, still run under the wrapper.
    assert_grep "That is a rule about the wrapper and not about the wrapped command's own exit code" "$brief" \
      "$kind: brief turned every non-zero exit of a wrapped command into a stop"
    assert_grep "debug it normally, and keep every rerun under the same \`av inject\` wrapper" "$brief" \
      "$kind: brief left ordinary debugging either blocked or unwrapped"
    # The explicit form is deliberate: av bless approves a script by path, which
    # inside a project would mix a local approval into the shipped change.
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'Do not use `av bless`: it approves a script by path' "$brief" \
      "$kind: vault guidance did not rule out the bless-a-path form"
    # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
    assert_grep 'mix a local approval into the change you are shipping, and the explicit `+KEY` form needs no blessing at all' "$brief" \
      "$kind: vault guidance lost why blessing a project file is wrong and the explicit form needs none"
    assert_no_grep "EOF" "$brief" \
      "$kind: credential brief leaked a heredoc EOF marker"

    # Same brief on a host with no vault: the rule keeps its unconditional half
    # and says nothing about a tool that is not installed.
    id="brief-credentials-novault-$kind"
    if [ "$kind" = scout ]; then
      PATH="$novault" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj --scout >/dev/null 2>&1
    else
      PATH="$novault" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind: vault-absent brief was not scaffolded"
    assert_grep "8. Never print, echo, log, or paste the VALUE of an API key, token, or other credential" "$brief" \
      "$kind: vault-absent brief dropped the unconditional never-print rule"
    assert_no_grep "Automic Vault" "$brief" \
      "$kind: vault-absent brief names a vault this host does not have"
    assert_no_grep "av inject" "$brief" \
      "$kind: vault-absent brief instructs a command this host does not have"
    assert_no_grep "av bless" "$brief" \
      "$kind: vault-absent brief carried the bless prohibition with no vault installed"
    assert_no_grep "av list" "$brief" \
      "$kind: vault-absent brief carried vault discovery with no vault installed"
    assert_no_grep "automicvault" "$brief" \
      "$kind: vault-absent brief carried the vault identity probe with no vault installed"
    assert_no_grep "av help" "$brief" \
      "$kind: vault-absent brief instructs a help command this host does not have"
    assert_no_grep "rerun the command bare" "$brief" \
      "$kind: vault-absent brief carried vault failure routing with no vault installed"
  done

  # A secondmate is a firstmate in its own home, where AGENTS.md reinforces the
  # invariant in one line and points here for the contract, so its charter must
  # not restate a crewmate rule list.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" brief-credentials-mate --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/brief-credentials-mate/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_no_grep "av inject" "$brief" \
    "secondmate charter duplicated the crewmate credential rule"

  # The contract and the reason the explicit form was chosen are documented.
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "never print a credential value" \
    "fm-brief.sh --help does not document the unconditional half of the credential rule"
  assert_contains "$help" "av inject +KEY [+KEY...] -- <command>" \
    "fm-brief.sh --help does not document the vault call pattern it teaches"
  assert_contains "$help" "renders only when" \
    "fm-brief.sh --help does not document that the vault half is conditional"
  assert_contains "$help" "is on PATH at scaffold time" \
    "fm-brief.sh --help does not document how the vault half is gated"
  assert_contains "$help" "identity probe" \
    "fm-brief.sh --help does not document the runtime identity probe the brief requires"
  assert_contains "$help" "av help 2>&1 | grep -q 'automicvault\.com'" \
    "fm-brief.sh --help does not document the concrete probe command"
  assert_contains "$help" "Gate and probe are complementary" \
    "fm-brief.sh --help does not document that the scaffold gate and the runtime probe decide different things"
  assert_contains "$help" "the whole vault path" \
    "fm-brief.sh --help does not document that stopping covers every vault failure, not just the probe"
  assert_contains "$help" "never reruns the command bare" \
    "fm-brief.sh --help does not document the never-rerun-bare prohibition the brief carries"
  assert_contains "$help" "it hard-codes no key list of" \
    "fm-brief.sh --help does not document that the scaffold carries no rotting key list"
  assert_contains "$help" "config/vault-only-keys" \
    "fm-brief.sh --help does not document where a home declares which keys the vault covers"
  assert_contains "$help" "Absent means the original unnarrowed contract" \
    "fm-brief.sh --help does not document that an absent list keeps every credential on the vault"
  pass "fm-brief.sh: ship and scout briefs teach vault-backed credential access and never print a value"
}

# The keys moved: most credentials now sit in the home's .env and reach a worker
# through its environment, while a declared few stay vault-only. A home says
# which with config/vault-only-keys. The failure this guards against is a brief
# that sends a worker to the vault for a key the vault does not hold: that worker
# stops and reports a blocker it can never clear, and because every lane reads
# the same generated rule, they all stop the same way at once.
test_vault_scope_follows_declared_key_list() {
  local home brief fakebin help out rc
  home="$TMP_ROOT/vault-scope-home"
  write_registry "$home"
  fakebin=$(fm_fakebin "$TMP_ROOT/vault-scope-vault")
  fm_fake_exit0 "$fakebin" av
  unset -f av 2>/dev/null || true
  mkdir -p "$home/config"
  printf '# money and compliance, deliberately not in the environment\nSTRIPE_SECRET_KEY\nSTRIPE_WEBHOOK_SECRET\n' \
    > "$home/config/vault-only-keys"

  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-vault-scope no-registry-proj >/dev/null 2>&1
  brief="$home/data/brief-vault-scope/brief.md"
  assert_present "$brief" "narrowed-scope brief was not scaffolded"

  # The covered names are stated up front, so a worker can tell which world it is
  # in by reading, without running anything.
  assert_grep "reached through Automic Vault instead: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET." "$brief" \
    "narrowed brief did not name the credentials the vault actually holds"
  assert_grep "applies to those names and to nothing else" "$brief" \
    "narrowed brief did not bound the vault rule to the declared names"
  # The clause that keeps a lane from stalling on a vault that cannot help it.
  assert_grep "Every other credential is already in your environment: read it normally, wrap the command in nothing, and do not go looking for a vault" "$brief" \
    "narrowed brief left non-vaulted credentials routed through the vault"
  # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
  assert_grep 'that is a missing credential to report, never a reason to reach for `av`' "$brief" \
    "narrowed brief let an absent environment key send the worker to the vault anyway"
  # The mode-specific sentences swap; the shared body does not.
  assert_grep "A vaulted credential is deliberately absent from your environment" "$brief" \
    "narrowed brief kept the all-credentials framing of the call-site sentence"
  assert_grep "Name only the vaulted keys YOUR task actually needs" "$brief" \
    "narrowed brief still told the worker to name any key it needs"
  assert_no_grep "Credentials belong in Automic Vault rather than the ambient environment" "$brief" \
    "narrowed brief kept the unnarrowed claim that every credential is vaulted"
  # The sentence with a trigger condition is the one that matters most here: "an
  # unset key means use `av inject`" fires on exactly the case the narrowing
  # exists for - a key that should have come from the environment and did not -
  # and unnarrowed it would send that worker to a vault which does not hold the
  # key, ending in a stop-and-report naming a vault failure it can never clear.
  assert_grep "An authentication failure, or an unset value for one of those vaulted names, is the signal that a command needs" "$brief" \
    "narrowed brief did not scope the unset-key trigger to the keys the vault holds"
  assert_no_grep "An authentication failure or an unset key is the signal" "$brief" \
    "narrowed brief kept the unscoped unset-key trigger, which routes an absent environment key into the vault"
  # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
  assert_grep 'An unset credential that is NOT one of those names is a missing credential and nothing more: it should have arrived from this home'"'"'s `.env`' "$brief" \
    "narrowed brief did not say where an unset non-vaulted credential should have come from"
  # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
  assert_grep 'append `blocked: {which credential is missing}` to the status file and stop there - never call `av` for it, and never report it as a vault failure' "$brief" \
    "narrowed brief left an unset non-vaulted credential routed through av or reported as a vault failure"
  # The full discipline is intact for the names it does cover - narrowed scope,
  # not a weakened rule.
  assert_grep "av help 2>&1 | grep -q 'automicvault\.com'" "$brief" \
    "narrowed brief dropped the identity probe for the keys still in the vault"
  # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
  assert_grep 'append `blocked: {the vault failure}` to the status file and stop' "$brief" \
    "narrowed brief dropped stop-and-report for the keys still in the vault"
  # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
  assert_grep 'Never rerun the command bare, meaning never drop the `av inject ... --` wrapper' "$brief" \
    "narrowed brief dropped the never-rerun-bare prohibition"
  # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
  assert_grep 'Do not use `av bless`' "$brief" \
    "narrowed brief dropped the bless prohibition"
  assert_no_grep "EOF" "$brief" \
    "narrowed brief leaked a heredoc EOF marker"

  # A home with a .env is told where its values are and that the file never
  # travels; a home without one is never sent looking for a file it does not have.
  assert_no_grep "mode-600 gitignored" "$brief" \
    "brief described a .env this home does not have"

  # A .env that declares only FM_*/FMX_* names is the documented X-mode-only
  # shape, and the loader puts none of it into a worker. Telling that worker its
  # variables are simply there would be a false statement in a generated brief,
  # which is the same defect class as every other finding in this rule, so the
  # paragraph is gated on the loader's eligibility count and not on the file.
  printf 'FMX_PAIRING_TOKEN=fake-pairing-token-not-a-real-token\n' > "$home/.env"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-vault-scope-xmode no-registry-proj >/dev/null 2>&1
  brief="$home/data/brief-vault-scope-xmode/brief.md"
  assert_present "$brief" "brief was not scaffolded with an X-mode-only .env"
  assert_no_grep "mode-600 gitignored" "$brief" \
    "brief promised loaded variables for a .env that puts nothing into a worker's environment"

  printf 'PLACEHOLDER_NOT_A_REAL_KEY=placeholder\n' > "$home/.env"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-vault-scope-env no-registry-proj >/dev/null 2>&1
  brief="$home/data/brief-vault-scope-env/brief.md"
  assert_present "$brief" "brief was not scaffolded with a .env present"
  # shellcheck disable=SC2016  # literal brief text: backticks must stay literal
  assert_grep 'The values live in one mode-600 gitignored `.env` in the firstmate home' "$brief" \
    "brief did not tell the worker where its credentials actually come from"
  assert_grep "firstmate loads it into your environment when it launches you" "$brief" \
    "brief did not say the credentials arrive without the worker fetching them"
  assert_grep "Never commit that file, never copy it or its contents into a project" "$brief" \
    "brief left the .env commitable, which is the whole reason environment credentials are safe"
  assert_grep "Never open it to see what a value is" "$brief" \
    "brief left reading a value out of the .env as an option"

  # A list that covers nothing, or a name that is not a name, would silently drop
  # a credential out of vault discipline. Both refuse instead, and write no brief.
  printf '# declared, but empty\n\n' > "$home/config/vault-only-keys"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-vault-empty no-registry-proj 2>&1) && rc=0 || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "an empty vault-only list scaffolded a brief instead of refusing"
  case "$out" in
    *"lists no key names"*) ;;
    *) fail "empty vault-only list did not explain itself: $out" ;;
  esac
  [ -e "$home/data/brief-vault-empty/brief.md" ] \
    && fail "refused scaffold still wrote a brief"

  printf 'STRIPE_SECRET_KEY\nnot a key name\n' > "$home/config/vault-only-keys"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-vault-bad no-registry-proj 2>&1) && rc=0 || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "an unusable vault-only key name scaffolded a brief instead of refusing"
  case "$out" in
    *"not a usable environment variable name"*) ;;
    *) fail "unusable vault-only key name did not explain itself: $out" ;;
  esac

  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "one environment variable name per line" \
    "fm-brief.sh --help does not document the vault-only-keys file format"
  assert_contains "$help" "hard errors rather than being" \
    "fm-brief.sh --help does not document that a bad or empty list refuses instead of silently narrowing"
  pass "fm-brief.sh: the vault rule covers exactly the keys a home declares vault-only"
}

# Ship and scout briefs carry ONE browser rule, identical in both variants: the
# session is private to the task and needs no cleanup. The deleted shared-session
# parking rule must not survive in either variant.
test_browser_teardown_contract() {
  local home brief ship_rule scout_rule help
  home="$TMP_ROOT/browser-teardown-home"
  write_registry "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-browser-ship no-registry-proj >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-browser-scout no-registry-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"

  for id in brief-browser-ship brief-browser-scout; do
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations." "$brief" \
      "$id: brief must still name the browser tool"
    assert_grep "Your browser is private to this task - no other worker can see or touch your pages, and you cannot disturb theirs - so open what you need and leave it open." "$brief" \
      "$id: brief must state the isolation fact before the instruction that depends on it"
    assert_grep "Do not park, close, or stop anything, do not change \`CHROME_DEVTOOLS_AXI_SESSION\`, and do not add browser cleanup later: the whole session is retired for you when this task ends, however it ends." "$brief" \
      "$id: brief must forbid every cleanup variant and say the session is retired for the worker"
    assert_no_grep "park every page" "$brief" \
      "$id: the deleted page-ownership parking rule reappeared"
    assert_no_grep "about:blank" "$brief" \
      "$id: the deleted about:blank parking rule reappeared"
    assert_no_grep "serves every worker" "$brief" \
      "$id: the deleted shared-session rationale reappeared, and it is now false"
    assert_no_grep "chrome-devtools-axi stop" "$brief" \
      "$id: brief must never instruct stopping a browser session"
  done

  # One rule, one spelling: the two variants must agree byte for byte.
  ship_rule=$(grep -A 2 -F 'Use gh-axi for GitHub operations' "$home/data/brief-browser-ship/brief.md")
  scout_rule=$(grep -A 2 -F 'Use gh-axi for GitHub operations' "$home/data/brief-browser-scout/brief.md")
  [ "$ship_rule" = "$scout_rule" ] \
    || fail "ship and scout briefs spell the browser rule differently"$'\n'"--- ship ---"$'\n'"$ship_rule"$'\n'"--- scout ---"$'\n'"$scout_rule"

  help=$("$ROOT/bin/fm-brief.sh" --help 2>&1) || fail "fm-brief.sh --help exited non-zero"
  assert_contains "$help" "private to its task and needs no" \
    "fm-brief.sh --help does not document the generated private-session browser rule"
  assert_contains "$help" "The old about:blank parking rule is deleted on purpose" \
    "fm-brief.sh --help does not record that the parking rule was removed deliberately"
  pass "fm-brief.sh: ship and scout briefs carry one private-session browser rule and no parking rule"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_visual_evidence_contract_is_opt_in_and_complete
test_visual_evidence_is_ship_only
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_credential_rule_covers_ship_and_scout
test_vault_scope_follows_declared_key_list
test_browser_teardown_contract
