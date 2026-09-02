#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's acquisition-reset preshield
# (spawn_preshield_start / spawn_preshield_stop).
#
# Treehouse v2 judges a slot free from live-process cwd. A parked done-crew's
# agent process keeps its cwd at the pane launch dir, so its recorded slot reads
# "available" and `treehouse get` RESETS it at acquisition - before
# assert_worktree_unleased can refuse (observed 2026-08-19: a live crew's worktree
# reset to detached HEAD). fm-spawn now holds every worktree this home already
# records with a cheap shield process for the duration of the get, so the pool
# cannot hand out an owned slot, and reaps the shields immediately afterward on
# every exit path.
#
# These drive the real fm-spawn against a fake tmux whose reported
# #{pane_current_path} IS the worktree the spawn "receives". FM_SPAWN_SHIELD_CMD
# injects an observable shield that records its own cwd on start ("up"), on exit
# ("down"), and a live pidfile carrying that cwd; the fake tmux samples the live
# pidfiles on every path poll (which only runs while the shields are up), so a
# test can prove the shields were live DURING acquisition and reaped after.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-preshield)

# One observable shield, shared across cases. On start it appends "up<TAB><cwd>"
# to SHIELD_LOG and drops a pidfile whose contents are its cwd; on ANY exit
# (including the kill fm-spawn sends) its trap appends "down<TAB><cwd>" and
# removes the pidfile. SHIELD_SLEEP is long, so a vanished pidfile can only mean
# the shield was reaped, never that it expired on its own.
SHIELD_SCRIPT="$TMP_ROOT/shield.sh"
mkdir -p "$TMP_ROOT"
cat > "$SHIELD_SCRIPT" <<'SH'
#!/usr/bin/env bash
d=$(pwd -P)
printf 'up\t%s\n' "$d" >> "$SHIELD_LOG"
printf '%s\n' "$d" > "$SHIELD_PIDDIR/$$"
trap 'printf "down\t%s\n" "$d" >> "$SHIELD_LOG"; rm -f "$SHIELD_PIDDIR/$$"' EXIT
sleep "${SHIELD_SLEEP:-30}"
SH
chmod +x "$SHIELD_SCRIPT"

# A fake tmux that reports FM_FAKE_PANE_PATH as the pane cwd and, on every path
# poll, records the cwd of each currently-live shield into GET_SNAPSHOT - a poll
# only ever happens while the shields are up, so anything captured there was
# provably alive during acquisition.
make_preshield_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${SHIELD_PIDDIR:-}" ] && [ -d "$SHIELD_PIDDIR" ]; then
      for f in "$SHIELD_PIDDIR"/*; do
        [ -e "$f" ] || continue
        cat "$f" >> "${GET_SNAPSHOT:-/dev/null}"
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys) exit "${FM_FAKE_SEND_KEYS_EXIT:-0}" ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> -> record "case_dir|home|proj|wt_get|fakebin|shield_log|piddir|get_snapshot"
# wt_get is a real, free git worktree the spawn acquires (FM_FAKE_PANE_PATH).
make_case() {
  local name=$1 case_dir home proj wt_get fakebin shield_log piddir get_snapshot
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt_get="$case_dir/wt-get"
  shield_log="$case_dir/shield.log"
  piddir="$case_dir/pids"
  get_snapshot="$case_dir/get-snapshot.log"
  fakebin=$(make_preshield_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$piddir"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt_get" "wt-get-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$shield_log"; : > "$get_snapshot"
  printf '%s\n' "$case_dir|$home|$proj|$wt_get|$fakebin|$shield_log|$piddir|$get_snapshot"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_GET FAKEBIN_DIR SHIELD_LOG PIDDIR GET_SNAPSHOT <<EOF
$1
EOF
}

# run_spawn <record> <id> [extra env assignments as NAME=VAL ...]: an ordinary
# ship spawn that acquires WT_GET, with the observable shield injected.
run_spawn() {
  local rec=$1 id=$2
  shift 2
  read_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  env \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_GET" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$HOME_DIR/grok-home" \
    FM_SPAWN_SHIELD_CMD="$SHIELD_SCRIPT" SHIELD_LOG="$SHIELD_LOG" \
    SHIELD_PIDDIR="$PIDDIR" GET_SNAPSHOT="$GET_SNAPSHOT" SHIELD_SLEEP=30 \
    "$@" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# record_meta <home> <id> <key=val>...: a recorded task slot in this home.
record_meta() {
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "$@"
}

piddir_empty() { ! find "$PIDDIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; }

# On a successful acquisition, every owned slot is shielded for the duration of
# the get and every shield is reaped afterward - no orphan sleeps survive.
test_shields_live_during_get_then_reaped_on_success() {
  local rec out status owned sm
  rec=$(make_case success)
  read_case "$rec"
  owned="$CASE_DIR/owned-wt"; sm="$CASE_DIR/sm-home"
  mkdir -p "$owned" "$sm"
  record_meta "$HOME_DIR" owner-a1 "window=firstmate:fm-owner-a1" "worktree=$owned" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  record_meta "$HOME_DIR" mate-b2 "window=firstmate:fm-mate-b2" "worktree=$sm" \
    "project=$sm" "harness=claude" "kind=secondmate" "home=$sm"
  out=$(run_spawn "$rec" fresh-c3); status=$?
  expect_code 0 "$status" "a spawn into a free slot must succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "spawned fresh-c3" "the free-slot spawn should report spawned"
  assert_grep $'up\t'"$owned" "$SHIELD_LOG" "the owned worktree must be shielded before the get"
  assert_grep $'up\t'"$sm" "$SHIELD_LOG" "the secondmate home must be shielded before the get"
  assert_grep "$owned" "$GET_SNAPSHOT" "the owned worktree's shield must be live during acquisition"
  assert_grep "$sm" "$GET_SNAPSHOT" "the secondmate home's shield must be live during acquisition"
  piddir_empty || fail "every shield must be reaped after a successful acquisition (no orphan sleeps)"
  pass "fm-spawn: shields every owned slot during the get and reaps them all on a successful acquisition"
}

# A guard-refused spawn (lease conflict) still reaps every shield on the failure
# exit path. This refusal lands AFTER the get resolved, so the inline reap is
# what clears the shields here; the trap-only path is pinned separately below.
test_shields_reaped_on_failure_exit() {
  local rec out status owned
  rec=$(make_case failure)
  read_case "$rec"
  owned="$CASE_DIR/owned-wt"
  mkdir -p "$owned"
  # The contested slot the pool hands out is one this home already records, so
  # the lease guard refuses AFTER the get - exercising the failure exit path.
  record_meta "$HOME_DIR" owner-d4 "window=firstmate:fm-owner-d4" "worktree=$WT_GET" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  record_meta "$HOME_DIR" owner-e5 "window=firstmate:fm-owner-e5" "worktree=$owned" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  out=$(run_spawn "$rec" intruder-f6); status=$?
  [ "$status" -ne 0 ] || fail "a spawn onto an owned slot must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "owner-d4" "the refusal must still name the owning task"
  assert_grep "$owned" "$GET_SNAPSHOT" "the owned worktree's shield must have been live during acquisition"
  piddir_empty || fail "every shield must be reaped on the failure exit path (no orphan sleeps)"
  pass "fm-spawn: reaps every shield on a guard-refused spawn's failure exit"
}

# Enumeration: shields cover both a task's worktree= and a secondmate's home=,
# skip a recorded path that no longer exists, and never double-shield one path a
# secondmate records as both worktree= and home=.
test_enumeration_covers_worktree_and_home_skips_vanished() {
  local rec out status owned sm gone up_owned up_gone up_sm_count
  rec=$(make_case enumerate)
  read_case "$rec"
  owned="$CASE_DIR/owned-wt"; sm="$CASE_DIR/sm-home"; gone="$CASE_DIR/vanished-wt"
  mkdir -p "$owned" "$sm"
  # gone is deliberately never created.
  record_meta "$HOME_DIR" owner-g7 "window=firstmate:fm-owner-g7" "worktree=$owned" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  record_meta "$HOME_DIR" mate-h8 "window=firstmate:fm-mate-h8" "worktree=$sm" \
    "project=$sm" "harness=claude" "kind=secondmate" "home=$sm"
  record_meta "$HOME_DIR" owner-i9 "window=firstmate:fm-owner-i9" "worktree=$gone" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  out=$(run_spawn "$rec" fresh-j0); status=$?
  expect_code 0 "$status" "the spawn must succeed"$'\n'"--- output ---"$'\n'"$out"
  up_owned=$(grep -c -F "$owned" "$SHIELD_LOG" 2>/dev/null || true)
  up_gone=$(grep -c -F "$gone" "$SHIELD_LOG" 2>/dev/null || true)
  # Count distinct "up" starts for the secondmate home (worktree= and home= both
  # name it, and must collapse to exactly one shield).
  up_sm_count=$(grep -c -F "up"$'\t'"$sm" "$SHIELD_LOG" 2>/dev/null || true)
  [ "$up_owned" -ge 1 ] || fail "a recorded worktree= must be shielded"
  [ "$up_sm_count" = 1 ] || fail "a secondmate home recorded as both worktree= and home= must be shielded exactly once, saw $up_sm_count"
  [ "$up_gone" = 0 ] || fail "a recorded path that no longer exists must be skipped, not shielded"
  pass "fm-spawn: shields cover worktree= and home= rows, dedupe one path, and skip vanished paths"
}

# A fresh (non-relaunch) spawn that REUSES an id whose record survived - the
# agent and its window are gone, but state/<id>.meta and its worktree still hold
# uncommitted work - must shield that id's OWN recorded worktree too. Nothing
# refuses this spawn (the window is gone, and the lease guard exempts the same
# id), so an unshielded own slot is exactly the slot `treehouse get` can hand
# back and reset at acquisition, before any guard runs.
test_shields_own_id_recorded_worktree_on_reused_id() {
  local rec out status own
  rec=$(make_case reused-id)
  read_case "$rec"
  own="$CASE_DIR/own-wt"
  mkdir -p "$own"
  record_meta "$HOME_DIR" revive-k1 "window=firstmate:fm-revive-k1" "worktree=$own" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  out=$(run_spawn "$rec" revive-k1); status=$?
  expect_code 0 "$status" "respawning a dead id must succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_grep $'up\t'"$own" "$SHIELD_LOG" \
    "the respawned id's own recorded worktree must be shielded before the get"
  assert_grep "$own" "$GET_SNAPSHOT" \
    "the respawned id's own recorded worktree must be held for the duration of the get"
  piddir_empty || fail "every shield must be reaped after the get (no orphan sleeps)"
  pass "fm-spawn: shields the spawning id's own recorded worktree when a dead id is respawned fresh"
}

# The trap path proper: a spawn that dies BETWEEN starting the shields and the
# inline post-get reap never runs that inline reap, so spawn_abort_cleanup is the
# only thing left that can stop the shields - the intent's "no orphan sleeps on
# any exit path". Here the send that launches `treehouse get` fails, so fm-spawn
# aborts under set -e with the shields still up.
test_shields_reaped_by_trap_when_the_get_never_starts() {
  local rec out status owned
  rec=$(make_case trap-reap)
  read_case "$rec"
  owned="$CASE_DIR/owned-wt"
  mkdir -p "$owned"
  record_meta "$HOME_DIR" owner-m1 "window=firstmate:fm-owner-m1" "worktree=$owned" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  out=$(run_spawn "$rec" fresh-n2 FM_FAKE_SEND_KEYS_EXIT=1); status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose 'treehouse get' send fails must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_grep $'up\t'"$owned" "$SHIELD_LOG" \
    "the shields must have been started before the failing send (otherwise this case proves nothing about the trap)"
  piddir_empty || fail "the abort-cleanup trap must reap every shield when the spawn dies before the inline reap (no orphan sleeps)"
  pass "fm-spawn: the abort-cleanup trap reaps the shields when a spawn dies before the get resolves"
}

# A REMOTE secondmate's meta lives in this home's state dir but its worktree=
# and home= name paths on ANOTHER host. Treehouse lays slots out deterministically
# per pool and slot, so that same path can exist locally as a different,
# genuinely free slot - shielding it protects nothing and can starve the pool of
# the last free slot this spawn needs.
test_remote_secondmate_rows_are_not_shielded() {
  local rec out status remote_path local_path
  rec=$(make_case remote-rows)
  read_case "$rec"
  remote_path="$CASE_DIR/remote-home"; local_path="$CASE_DIR/local-wt"
  mkdir -p "$remote_path" "$local_path"
  # The remote secondmate's recorded path exists HERE too - the collision this
  # skip exists for - while an ordinary local task records the other path.
  record_meta "$HOME_DIR" mate-r1 "window=remote:mate-r1" "worktree=$remote_path" \
    "project=$remote_path" "harness=claude" "kind=secondmate" "home=$remote_path" \
    "remote_host=elsewhere.local" "remote_root=/srv/fm"
  record_meta "$HOME_DIR" owner-s2 "window=firstmate:fm-owner-s2" "worktree=$local_path" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship"
  out=$(run_spawn "$rec" fresh-t3); status=$?
  expect_code 0 "$status" "the spawn must succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_grep $'up\t'"$local_path" "$SHIELD_LOG" "a local task's recorded worktree must still be shielded"
  if grep -qF "$remote_path" "$SHIELD_LOG" 2>/dev/null; then
    fail "a REMOTE secondmate's recorded path must not be shielded locally - the local directory of that name is a different, unowned slot"
  fi
  pass "fm-spawn: shields skip a remote secondmate's recorded paths and still cover local rows"
}

test_shields_live_during_get_then_reaped_on_success
test_shields_reaped_on_failure_exit
test_remote_secondmate_rows_are_not_shielded
test_shields_reaped_by_trap_when_the_get_never_starts
test_enumeration_covers_worktree_and_home_skips_vanished
test_shields_own_id_recorded_worktree_on_reused_id
