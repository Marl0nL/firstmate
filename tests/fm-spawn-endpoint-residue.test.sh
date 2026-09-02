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
# non-sticky kill-window records it "killed" (so list-windows and the
# '#{pane_id}' existence probe then report it gone); a sticky kill leaves it
# present (a teardown that could not be confirmed). Every kill-window is logged
# so a test can prove teardown was attempted. FM_FAKE_STATE toggles a
# preexisting window by pre-touching present. FM_FAKE_SIBLING_WINDOW adds a
# second, always-live window.
#
# The '#{pane_id}' probe reproduces real tmux target resolution: a bare window
# name matches by exact name and then by PREFIX, while a '=name' target matches
# only exactly. That is what makes a sibling window whose name merely starts with
# fm-<id> observable to a test.
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
  *"#{pane_id}"*)
    tgt=; prev=
    for a in "$@"; do
      if [ "$prev" = "-t" ]; then tgt=$a; break; fi
      prev=$a
    done
    want=${tgt#*:}
    live=
    if [ -n "$st" ] && [ -f "$st/present" ] && [ ! -f "$st/killed" ]; then live=$wname; fi
    for w in $live ${FM_FAKE_SIBLING_WINDOW:-}; do
      case "$want" in
        =*) [ "$w" = "${want#=}" ] && { printf '%%1\n'; exit 0; } ;;
        *) case "$w" in "$want"*) printf '%%1\n'; exit 0 ;; esac ;;
      esac
    done
    exit 1 ;;
esac
case "${1:-}" in
  list-windows)
    if [ -n "$st" ] && [ -f "$st/present" ] && [ ! -f "$st/killed" ]; then
      printf '%s\n' "$wname"
    fi
    [ -z "${FM_FAKE_SIBLING_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_SIBLING_WINDOW"
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
  IFS='|' read -r _ HOME_DIR PROJ_DIR CONTESTED FAKEBIN_DIR KILL_LOG FAKE_STATE <<EOF
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
  out=$(run_spawn "$rec" intruder-d4 "$CONTESTED" FM_FAKE_KILL_STICKY=1); status=$?
  [ "$status" -ne 0 ] || fail "a spawn onto an owned slot must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "fm-intruder-d4" "$KILL_LOG" "teardown must still be attempted"
  assert_contains "$out" "could not tear down" "an unconfirmed teardown must warn"
  assert_contains "$out" "tmux kill-window -t '=firstmate:=fm-intruder-d4'" "the warning must carry the exact one-line remedy naming the leftover"
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
  assert_not_contains "$out" "left it behind" \
    "the refusal must not assert a cause it never established - the window may hold a LIVE agent"
  assert_contains "$out" "Verify nothing live is running in it first" \
    "the refusal must tell the operator to check the window before running the destructive command"
  assert_contains "$out" "only if it is not a live agent" \
    "the removal must be offered conditionally, never as an unconditional instruction"
  [ ! -s "$KILL_LOG" ] || fail "a dup refusal must never auto-kill the pre-existing window (it may belong to a live task)"
  pass "fm-spawn: a retry on a leftover window is refused with a named, verify-first conditional remedy"
}

# A completed teardown must not be reported as leftover just because another
# LIVE window's name starts with fm-<id>: tmux resolves a bare window name by
# exact match, then fnmatch, then prefix, so the confirmation probe has to pin
# the exact window the same way the kill and the remedy line do.
test_teardown_confirmation_ignores_prefix_sibling_window() {
  local rec out status
  rec=$(make_case teardown-prefix-sibling)
  read_case "$rec"
  record_meta "$HOME_DIR" owner-f6 "window=firstmate:fm-owner-f6" "worktree=$CONTESTED" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  # fm-fix-g7-auth is a different task's live window; fm-fix-g7 is this spawn's,
  # and its teardown genuinely removes it.
  out=$(run_spawn "$rec" fix-g7 "$CONTESTED" FM_FAKE_SIBLING_WINDOW=fm-fix-g7-auth); status=$?
  [ "$status" -ne 0 ] || fail "a spawn onto an owned slot must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "fm-fix-g7" "$KILL_LOG" "the failed spawn must tear down the window it created"
  assert_not_contains "$out" "could not tear down" \
    "a live sibling window whose name only starts with fm-<id> must not make a completed teardown read as leftover"
  pass "fm-spawn: teardown confirmation matches the exact window, not a prefix sibling"
}

# Every pre-publish refusal is followed by the endpoint teardown, so none of them
# may point the operator at the endpoint they are about to destroy. The isolation
# refusal is the one that still did.
test_isolation_refusal_does_not_point_at_the_torn_down_endpoint() {
  local rec out status
  rec=$(make_case isolation-refusal)
  read_case "$rec"
  # A real directory that is not a git worktree: the lease guard has nothing to
  # say about it, so the isolation check is what refuses.
  out=$(run_spawn "$rec" stray-h8 "$CONTESTED"); status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose pane never entered a worktree must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "did not yield an isolated worktree" "the refusal must report the isolation failure"
  assert_grep "fm-stray-h8" "$KILL_LOG" "the refused spawn must still tear down the window it created"
  assert_not_contains "$out" "Inspect target" \
    "the refusal must not send the operator to an endpoint the teardown is about to destroy"
  assert_contains "$out" "the spawn's endpoint was cleaned up" \
    "the refusal must say the endpoint is gone and how to diagnose instead"
  pass "fm-spawn: a pre-publish isolation refusal reports the endpoint teardown instead of pointing at the destroyed endpoint"
}

test_guard_refusal_tears_down_created_window
test_unconfirmed_teardown_prints_remedy
test_retry_on_residue_gives_actionable_message
test_teardown_confirmation_ignores_prefix_sibling_window
test_isolation_refusal_does_not_point_at_the_torn_down_endpoint
