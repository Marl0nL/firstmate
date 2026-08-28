#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's failed-spawn endpoint-residue teardown.
#
# A spawn that is refused AFTER creating its tmux window / herdr tab leaves that
# endpoint (and its bare subshell) holding the slot; a retry then dies on the
# backend's "already exists" refusal (observed live 2026-08-27 on a herdr
# respawn). fm-spawn now tears the created endpoint back down in the same failure
# path, and where teardown cannot be confirmed it prints the exact one-line
# remedy. The backend create_task refusals were also made actionable: they name
# the leftover and the exact command to remove it.
#
# The tmux path is the reference backend and is driven end to end through the real
# fm-spawn here; the herdr create_task actionable-refusal wording is asserted in
# tests/fm-backend-herdr.test.sh alongside the rest of that function's coverage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-endpoint-residue)

# A stateful fake tmux. new-window records that the window is "present"; a
# non-sticky kill-window records it "killed" (so list-windows then reports it
# gone); a sticky kill leaves it present (a teardown that could not be
# confirmed). Every kill-window is logged so a test can prove teardown was
# attempted. FM_FAKE_STATE toggles a preexisting window by pre-touching present.
make_residue_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
st=${FM_FAKE_STATE:-}
wname=${FM_FAKE_WINDOW_NAME:-}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_CMD:-}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    if [ -n "$st" ] && [ -f "$st/present" ] && [ ! -f "$st/killed" ]; then
      printf '%s\n' "$wname"
    fi
    exit 0 ;;
  new-window)
    [ -z "$st" ] || touch "$st/present"
    printf '@1\n'; exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    if [ -n "$st" ] && [ "${FM_FAKE_KILL_STICKY:-0}" != 1 ]; then touch "$st/killed"; fi
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> -> "case_dir|home|proj|contested|fakebin|killlog|state"
# contested is a real dir another task records, so the lease guard refuses the
# spawn AFTER the window is created - the residue path under test.
make_case() {
  local name=$1 case_dir home proj contested fakebin killlog state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  contested="$case_dir/contested"
  killlog="$case_dir/kill.log"
  state="$case_dir/fakestate"
  fakebin=$(make_residue_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$contested" "$state"
  printf 'claude\n' > "$home/config/crew-harness"
  # A real project so validate_spawn_worktree's later checks are reachable; the
  # lease guard runs first, so contested only needs to be a real directory.
  fm_git_worktree "$proj" "$case_dir/scratch-wt" "scratch-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$killlog"
  printf '%s\n' "$case_dir|$home|$proj|$contested|$fakebin|$killlog|$state"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR CONTESTED FAKEBIN_DIR KILL_LOG FAKE_STATE <<EOF
$1
EOF
}

# run_spawn <record> <id> <pane_path> [extra env assignments as NAME=VAL ...]
run_spawn() {
  local rec=$1 id=$2 pane_path=$3
  shift 3
  read_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  env \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane_path" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$HOME_DIR/grok-home" \
    FM_SPAWN_SHIELD_TTL=1 \
    FM_FAKE_WINDOW_NAME="fm-$id" FM_FAKE_STATE="$FAKE_STATE" FM_FAKE_KILL_LOG="$KILL_LOG" \
    "$@" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

record_meta() {
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "$@"
}

# A guard-refused spawn tears the created window back down in the same failure
# path, and (teardown confirmed) prints no leftover remedy.
test_guard_refusal_tears_down_created_window() {
  local rec out status
  rec=$(make_case teardown-clean)
  read_case "$rec"
  record_meta "$HOME_DIR" owner-a1 "window=firstmate:fm-owner-a1" "worktree=$CONTESTED" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  out=$(run_spawn "$rec" intruder-b2 "$CONTESTED"); status=$?
  [ "$status" -ne 0 ] || fail "a spawn onto an owned slot must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "owner-a1" "the refusal must name the owning task"
  assert_grep "fm-intruder-b2" "$KILL_LOG" "the failed spawn must tear down the window it created"
  assert_not_contains "$out" "could not tear down" "a confirmed teardown must print no leftover remedy"
  assert_absent "$HOME_DIR/state/intruder-b2.meta" "an aborted spawn must not record meta"
  pass "fm-spawn: a guard-refused spawn tears down the tmux window it created, leaving no residue"
}

# When teardown cannot be confirmed (the endpoint stays alive), fm-spawn prints
# the exact one-line remedy naming the leftover.
test_unconfirmed_teardown_prints_remedy() {
  local rec out status
  rec=$(make_case teardown-stuck)
  read_case "$rec"
  record_meta "$HOME_DIR" owner-c3 "window=firstmate:fm-owner-c3" "worktree=$CONTESTED" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  out=$(run_spawn "$rec" intruder-d4 "$CONTESTED" FM_FAKE_KILL_STICKY=1 FM_FAKE_PANE_CMD=claude); status=$?
  [ "$status" -ne 0 ] || fail "a spawn onto an owned slot must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "fm-intruder-d4" "$KILL_LOG" "teardown must still be attempted"
  assert_contains "$out" "could not tear down" "an unconfirmed teardown must warn"
  assert_contains "$out" "tmux kill-window -t 'firstmate:fm-intruder-d4'" "the warning must carry the exact one-line remedy naming the leftover"
  pass "fm-spawn: an unconfirmed endpoint teardown prints the exact one-line remedy"
}

# A retry landing on a preexisting leftover window gets an actionable refusal
# that names the leftover and the exact command to remove it.
test_retry_on_residue_gives_actionable_message() {
  local rec out status
  rec=$(make_case retry-residue)
  read_case "$rec"
  # Simulate the leftover from a prior failed spawn: the window already exists.
  touch "$FAKE_STATE/present"
  out=$(run_spawn "$rec" stuck-e5 "$CONTESTED"); status=$?
  [ "$status" -ne 0 ] || fail "a spawn onto a preexisting window must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "already exists" "the refusal must report the duplicate window"
  assert_contains "$out" "fm-stuck-e5" "the refusal must name the leftover window"
  assert_contains "$out" "tmux kill-window -t" "the refusal must carry the exact remedy command"
  pass "fm-spawn: a retry on a leftover window is refused with an actionable, named remedy"
}

test_guard_refusal_tears_down_created_window
test_unconfirmed_teardown_prints_remedy
test_retry_on_residue_gives_actionable_message
