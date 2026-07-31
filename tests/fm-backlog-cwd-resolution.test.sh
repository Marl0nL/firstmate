#!/usr/bin/env bash
# tests/fm-backlog-cwd-resolution.test.sh - the backlog is resolved from the HOME,
# never from the process working directory.
#
# The 2026-07-31 incident: a tasks-axi call issued from a shell already standing
# inside projects/<clone> created a stray backlog.md INSIDE that project - a write
# to a project, which AGENTS.md section 1 forbids outright - and, earlier the same
# day, the same trap returned a false "the backlog is empty" reading.
# bin/fm-cd-pretool-check.sh was NOT the hole and is untouched by this suite: it
# guards the directory CHANGE and works, but tasks-axi resolves its data file from
# the CURRENT DIRECTORY, so a cwd inherited from a spawn or left behind by an
# allowed scoped change needs no `cd` at all to trigger this.
#
# Every case below actually RUNS from inside a project directory rather than
# asserting a path string, and treats the READ half as load-bearing as the write
# half: a stray write eventually announces itself as an untracked file, while a
# false-empty read returns a confident wrong answer that gets acted on with no
# alarm. bin/fm-tasks-axi-lib.sh owns the resolution these cases exercise.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

# These cases exercise the real resolver, so they need the real binary; skip
# cleanly when it is absent, matching the delegated-handoff suite.
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required to exercise real backlog resolution)"; exit 0; }

# The real library under test. Sourcing it here rather than inside each subshell
# is equivalent - a subshell inherits its parent's functions - and keeps the
# source path static for shellcheck.
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$ROOT/bin/fm-tasks-axi-lib.sh"

HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"
HOLD="$ROOT/bin/fm-decision-hold.sh"

fm_test_tmproot TMP_ROOT fm-backlog-cwd

# A home with a seeded backlog plus a stand-in project clone holding one tracked
# file, so a stray write is visible as a manifest change rather than only as a
# guessed filename.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample-clone/src"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf 'int main(void) { return 0; }\n' > "$home/projects/sample-clone/src/main.c"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] cwd-item - resolve against the home (repo: sample)
  body line that must survive

## Done
EOF
  printf '%s\n' "$home"
}

# Where a real supervisor's shell was standing when the incident happened: not the
# clone root, but a working subdirectory inside it.
project_cwd() {  # <home>
  printf '%s\n' "$1/projects/sample-clone/src"
}

clone_manifest() {  # <home>
  (cd "$1/projects/sample-clone" && find . | LC_ALL=C sort)
}

assert_clone_untouched() {  # <home> <before-manifest> <label>
  local after
  after=$(clone_manifest "$1")
  [ "$after" = "$2" ] || {
    printf 'clone before:\n%s\nclone after:\n%s\n' "$2" "$after" >&2
    fail "$3"
  }
}

# The hazard itself, pinned. A bare call from this exact directory must still
# report an EMPTY backlog: if that ever stops being true, every case below would
# pass for the wrong reason.
assert_bare_call_is_blind() {  # <project-cwd>
  local out
  out=$(cd "$1" && tasks-axi list 2>&1)
  printf '%s\n' "$out" | grep -F 'count: 0' >/dev/null \
    || fail "fixture no longer reproduces the false-empty read from a project cwd: $out"
}

test_read_from_a_project_cwd_reads_the_home_backlog() {
  local home proj before out
  home=$(make_home read-half)
  proj=$(project_cwd "$home")
  before=$(clone_manifest "$home")
  assert_bare_call_is_blind "$proj"

  out=$(cd "$proj" && fm_tasks_axi_run "$home" "$home/data" list 2>&1) \
    || fail "home-scoped read failed from a project cwd: $out"
  printf '%s\n' "$out" | grep -F 'cwd-item' >/dev/null \
    || fail "read from a project cwd did not see the home backlog: $out"

  assert_clone_untouched "$home" "$before" "a home-scoped read wrote into the project clone"
  pass "a backlog read issued from inside a project resolves to the home backlog"
}

# The write half of the same hazard, pinned against the real binary rather than
# only described: the identical command without an explicit file creates exactly
# the stray backlog.md inside the clone that the 2026-07-31 incident produced.
test_bare_write_from_a_project_cwd_still_strays_into_the_clone() {
  local home proj
  home=$(make_home stray-proof)
  proj=$(project_cwd "$home")

  (cd "$proj" && tasks-axi add stray-x "written blind" --queue >/dev/null 2>&1) \
    || fail "bare add from a project cwd unexpectedly failed"
  assert_present "$proj/backlog.md" \
    "the incident's stray-write shape no longer reproduces; the rest of this suite would pass for the wrong reason"
  assert_no_grep 'stray-x' "$home/data/backlog.md" "a blind write unexpectedly reached the home backlog"
  pass "a bare write from inside a project still strays into the clone - the hazard this fix routes around"
}

test_write_from_a_project_cwd_lands_in_the_home_backlog() {
  local home proj before out
  home=$(make_home write-half)
  proj=$(project_cwd "$home")
  before=$(clone_manifest "$home")
  assert_bare_call_is_blind "$proj"

  out=$(cd "$proj" && fm_tasks_axi_run "$home" "$home/data" add cwd-added "added from a project cwd" --queue 2>&1) \
    || fail "home-scoped write failed from a project cwd: $out"

  assert_grep 'cwd-added' "$home/data/backlog.md" "write from a project cwd did not reach the home backlog"
  assert_grep 'cwd-item' "$home/data/backlog.md" "write from a project cwd disturbed the existing item"
  assert_clone_untouched "$home" "$before" "a home-scoped write left a stray file in the project clone"
  pass "a backlog write issued from inside a project lands in the home backlog"
}

# bin/fm-teardown.sh emits its backlog-refresh commands for an operator to run by
# hand, from whatever directory that operator's shell is already in - the
# incident's own path, end to end. Run the emitted shape from inside a project.
test_teardown_shaped_command_runs_correctly_from_a_project_cwd() {
  local home proj before backlog out
  home=$(make_home teardown-shape)
  proj=$(project_cwd "$home")
  before=$(clone_manifest "$home")
  assert_bare_call_is_blind "$proj"

  backlog=$(cd "$proj" && fm_backlog_file "$home/data")
  [ "$backlog" = "$home/data/backlog.md" ] \
    || fail "resolution of an absolute data dir changed with the cwd: got $backlog"

  out=$(cd "$proj" && tasks-axi "done" --file "$backlog" cwd-item --pr https://example.invalid/pull/1 2>&1) \
    || fail "the emitted done command failed from a project cwd: $out"
  assert_grep '- [x] cwd-item' "$home/data/backlog.md" "the emitted done command did not close the item in the home backlog"

  out=$(cd "$proj" && tasks-axi ready --file "$backlog" 2>&1) \
    || fail "the emitted ready command failed from a project cwd: $out"
  assert_clone_untouched "$home" "$before" "the emitted backlog commands left a stray file in the project clone"
  pass "the backlog commands teardown emits stay correct when hand-run from inside a project"
}

# The resolved data dir wins over the home's own data/, which the previous
# cd-into-FM_HOME approach could not express: with FM_DATA_OVERRIDE set, a hold
# written from a project cwd must land in the overridden dir and must not
# recreate a backlog under FM_HOME/data.
test_decision_hold_from_a_project_cwd_uses_the_resolved_data_dir() {
  local home proj before out id
  home=$(make_home hold-override)
  proj=$(project_cwd "$home")
  mkdir -p "$home/alt-data"
  mv "$home/data/backlog.md" "$home/alt-data/backlog.md"
  fm_write_meta "$home/state/scout-x1.meta" \
    "window=firstmate:fm-scout-x1" \
    "project=$home/projects/sample-clone" \
    "kind=scout"
  before=$(clone_manifest "$home")
  assert_bare_call_is_blind "$proj"

  out=$(cd "$proj" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/alt-data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$HOLD" hold scout-x1 route --title "Choose the route" --reason "captain decision pending" 2>&1) \
    || fail "captain hold failed from a project cwd: $out"
  id=$(printf '%s\n' "$out" | tail -1)
  [ "$id" = scout-x1-decision-route ] || fail "unexpected hold identity from a project cwd: $out"

  assert_grep "$id" "$home/alt-data/backlog.md" "captain hold did not land in the resolved data dir"
  assert_absent "$home/data/backlog.md" "captain hold recreated a backlog under FM_HOME/data, ignoring the resolved data dir"
  assert_clone_untouched "$home" "$before" "captain hold left a stray file in the project clone"

  # Re-running is idempotent only if the READ half resolved too: a blind read
  # would see no existing hold and try to create the identity a second time.
  out=$(cd "$proj" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/alt-data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$HOLD" hold scout-x1 route --title "Choose the route" --reason "captain decision pending" 2>&1) \
    || fail "repeat captain hold failed from a project cwd: $out"
  [ "$(grep -cE "^- \[ \] $id -" "$home/alt-data/backlog.md")" = 1 ] \
    || fail "repeat hold from a project cwd duplicated the decision item"

  pass "a captain hold issued from inside a project reads and writes the resolved home backlog"
}

# Handoff is the call where getting resolution wrong would move work into the
# WRONG home, so it must resolve BOTH endpoints from a project cwd.
handoff_fixture() {  # <name> -> sets HF_HOME HF_SUB
  local name=$1
  HF_HOME=$(make_home "$name")
  HF_SUB="$TMP_ROOT/$name-sub"
  seed_secondmate_home_marker "$HF_SUB" design
  local sub_abs
  sub_abs=$(cd "$HF_SUB" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: sample; added 2026-07-31)\n' \
    "$sub_abs" > "$HF_HOME/data/secondmates.md"
}

test_handoff_from_a_project_cwd_moves_between_the_right_two_homes() {
  local before out
  handoff_fixture handoff-both-ends
  local home=$HF_HOME sub=$HF_SUB proj
  proj=$(project_cwd "$home")
  before=$(clone_manifest "$home")
  assert_bare_call_is_blind "$proj"

  out=$(cd "$proj" && FM_HOME="$home" "$HANDOFF" design cwd-item 2>&1) \
    || fail "handoff failed from a project cwd: $out"

  assert_no_grep 'cwd-item' "$home/data/backlog.md" "handoff from a project cwd left the item in the source home"
  assert_no_grep 'body line that must survive' "$home/data/backlog.md" "handoff from a project cwd orphaned the item body"
  assert_grep 'cwd-item' "$sub/data/backlog.md" "handoff from a project cwd did not reach the destination home"
  assert_grep '  body line that must survive' "$sub/data/backlog.md" "handoff from a project cwd dropped the item body"
  assert_clone_untouched "$home" "$before" "handoff left a stray backlog in the project clone"
  pass "handoff issued from inside a project moves the item between the right two homes"
}

test_manual_backend_still_opts_routine_mutations_out() {
  local home
  home=$(make_home manual-optout)
  printf '%s\n' manual > "$home/config/backlog-backend"

  fm_backlog_backend_manual "$home/config" \
    || fail "config/backlog-backend=manual was not detected"
  ! fm_tasks_axi_backend_available "$home/config" \
    || fail "manual backend did not opt routine mutations out of tasks-axi"

  # And the default is unchanged when the knob is absent.
  rm -f "$home/config/backlog-backend"
  fm_tasks_axi_backend_available "$home/config" \
    || fail "default backend stopped selecting compatible tasks-axi"
  pass "config/backlog-backend=manual still opts routine mutations out of tasks-axi"
}

# The other half of that split: a validated secondmate handoff always delegates to
# `tasks-axi mv`, manual opt-out or not, and that stays true from a project cwd.
test_manual_backend_still_delegates_handoff_from_a_project_cwd() {
  local before out
  handoff_fixture handoff-manual
  local home=$HF_HOME sub=$HF_SUB proj
  proj=$(project_cwd "$home")
  printf '%s\n' manual > "$home/config/backlog-backend"
  before=$(clone_manifest "$home")

  out=$(cd "$proj" && FM_HOME="$home" "$HANDOFF" design cwd-item 2>&1) \
    || fail "handoff refused under the manual backlog backend: $out"

  assert_no_grep 'cwd-item' "$home/data/backlog.md" "manual-backend handoff left the item in the source home"
  assert_grep 'cwd-item' "$sub/data/backlog.md" "manual-backend handoff did not reach the destination home"
  assert_clone_untouched "$home" "$before" "manual-backend handoff left a stray backlog in the project clone"
  pass "the manual backlog backend still delegates validated handoffs to tasks-axi mv"
}

# The library only protects bin/. Agents call tasks-axi from their own turns, so
# the always-loaded contract has to carry the same rule or the hand-run half of
# the incident stays open.
test_agents_md_states_the_home_scoped_rule() {
  local agents="$ROOT/AGENTS.md"
  assert_grep 'A home-scoped command must never infer its target from the working directory' "$agents" \
    "AGENTS.md lost the home-scoped backlog rule; hand-run calls are unguarded again"
  # shellcheck disable=SC2016 # The literal $FM_HOME the contract prints, not this shell's.
  assert_grep 'tasks-axi <command> --file "$FM_HOME/data/backlog.md"' "$agents" \
    "AGENTS.md no longer shows the explicit-file form a hand-run call must use"
  pass "AGENTS.md carries the home-scoped rule for hand-run backlog calls"
}

test_agents_md_states_the_home_scoped_rule
test_read_from_a_project_cwd_reads_the_home_backlog
test_bare_write_from_a_project_cwd_still_strays_into_the_clone
test_write_from_a_project_cwd_lands_in_the_home_backlog
test_teardown_shaped_command_runs_correctly_from_a_project_cwd
test_decision_hold_from_a_project_cwd_uses_the_resolved_data_dir
test_handoff_from_a_project_cwd_moves_between_the_right_two_homes
test_manual_backend_still_opts_routine_mutations_out
test_manual_backend_still_delegates_handoff_from_a_project_cwd

echo "ALL TESTS PASSED"
