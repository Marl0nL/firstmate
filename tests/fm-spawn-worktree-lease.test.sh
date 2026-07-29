#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's worktree-lease guard (assert_worktree_unleased).
#
# Twice on 2026-07-29 a spawn was handed a worktree a LIVE task was already
# working in: the pool judges a slot free from live process cwds, and an agent
# whose process cwd is the pane's launch dir leaves an owned slot looking free.
# The main home lost a crewmate's uncommitted fixes to it; a secondmate home had
# a live branch reset to the default branch mid-flight. This home's own
# state/*.meta is the record that knows the slot is taken, so fm-spawn now
# consults it before the new agent touches anything.
#
# These drive the real fm-spawn against a fake tmux whose reported
# #{pane_current_path} IS the worktree the spawn "receives", so a test can hand a
# spawn any worktree it likes, and a fake state dir supplying the competing metas.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot TMP_ROOT fm-spawn-worktree-lease

# A fake tmux that reports FM_FAKE_PANE_PATH as the pane cwd (so the treehouse-get
# poll resolves immediately to that path) and logs every send-keys line, so a test
# can prove an aborted spawn never launched anything.
make_lease_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'claude\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%0\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|kill-window|set-window-option) exit 0 ;;
  new-window) printf '@1\n'; exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:?}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> -> record "case_dir|home|proj|wt_a|wt_b|fakebin|sendlog"
# Two real worktrees of one project: wt_a is the contested slot, wt_b a free one.
make_case() {
  local name=$1 case_dir home proj wt_a wt_b fakebin sendlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt_a="$case_dir/wt-a"
  wt_b="$case_dir/wt-b"
  sendlog="$case_dir/send.log"
  fakebin=$(make_lease_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt_a" "wt-a-$name"
  git -C "$proj" worktree add --quiet -b "wt-b-$name" "$wt_b"
  touch "$home/state/.last-watcher-beat"
  : > "$sendlog"
  printf '%s\n' "$case_dir|$home|$proj|$wt_a|$wt_b|$fakebin|$sendlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_A WT_B FAKEBIN_DIR SENDLOG <<EOF
$1
EOF
}

# run_spawn_raw <record> <worktree-the-spawn-receives> <fm-spawn args...>
run_spawn_raw() {
  local rec=$1 pane_path=$2
  shift 2
  read_case "$rec"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane_path" FM_FAKE_SENDLOG="$SENDLOG" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# run_spawn <record> <id> <worktree-the-spawn-receives>: an ordinary ship spawn.
run_spawn() {
  local rec=$1 id=$2 pane_path=$3
  read_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  run_spawn_raw "$rec" "$pane_path" "$id" "$PROJ_DIR"
}

# A minimally seeded secondmate home: the marker, an AGENTS.md, and a charter are
# what validate_firstmate_home_for_spawn and the brief lookup require.
seed_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

# fm-spawn creates /tmp/fm-<id>, outside fm_test_tmproot's tree and normally
# reaped by fm-teardown, which never runs here. Register it for EXIT cleanup from
# the parent shell (not inside run_spawn's command-substitution subshell).
register_task_tmp() { FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$1"); }

# Count literal (-l) sends: the launch command is sent that way, the spawn-time
# `treehouse get` line is not. grep -c prints 0 and exits 1 on no match.
launch_sends() {
  local n
  n=$(grep -c -e ' -l ' "$SENDLOG" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

# The hazard itself: the pool hands out a slot another task of this home already
# records. The spawn must abort, name the owner, and touch nothing.
test_refuses_worktree_owned_by_another_task() {
  local rec out status
  rec=$(make_case lease-conflict)
  read_case "$rec"
  register_task_tmp lease-victim-a1
  register_task_tmp lease-intruder-b2
  fm_write_meta "$HOME_DIR/state/lease-victim-a1.meta" \
    "window=firstmate:fm-lease-victim-a1" \
    "worktree=$WT_A" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship"
  out=$(run_spawn "$rec" lease-intruder-b2 "$WT_A"); status=$?
  [ "$status" -ne 0 ] || fail "a spawn onto another task's recorded worktree must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "lease-victim-a1" "the refusal must name the OWNING task id"
  assert_contains "$out" "$WT_A" "the refusal must name the contested worktree"
  assert_not_contains "$out" "spawned lease-intruder-b2" "an aborted spawn must not report success"
  assert_absent "$HOME_DIR/state/lease-intruder-b2.meta" "an aborted spawn must not record meta"
  assert_present "$HOME_DIR/state/lease-victim-a1.meta" "the victim's meta must be left untouched"
  [ "$(launch_sends)" = 0 ] || fail "an aborted spawn must not send a launch (literal sends=$(launch_sends))"
  pass "fm-spawn: refuses a worktree another task of this home records, naming the owner, before any launch"
}

# A respawn of the SAME task id into its own recorded worktree is legitimate
# (recovery, restart, /updatefirstmate) and must stay allowed.
test_allows_same_task_respawn_into_own_worktree() {
  local rec out status
  rec=$(make_case lease-respawn)
  read_case "$rec"
  register_task_tmp lease-respawn-c3
  fm_write_meta "$HOME_DIR/state/lease-respawn-c3.meta" \
    "window=firstmate:fm-lease-respawn-c3" \
    "worktree=$WT_A" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship"
  out=$(run_spawn "$rec" lease-respawn-c3 "$WT_A"); status=$?
  expect_code 0 "$status" "a respawn of the same id into its own worktree must succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "spawned lease-respawn-c3" "a same-id respawn should report spawned"
  assert_grep "worktree=$WT_A" "$HOME_DIR/state/lease-respawn-c3.meta" "the respawn should re-record its own worktree"
  pass "fm-spawn: a respawn of the same task id into its recorded worktree is still allowed"
}

# The ordinary case: a genuinely free slot, with an unrelated task holding a
# DIFFERENT worktree, is unaffected.
test_allows_genuinely_free_worktree() {
  local rec out status
  rec=$(make_case lease-free)
  read_case "$rec"
  register_task_tmp lease-neighbour-d4
  register_task_tmp lease-fresh-e5
  fm_write_meta "$HOME_DIR/state/lease-neighbour-d4.meta" \
    "window=firstmate:fm-lease-neighbour-d4" \
    "worktree=$WT_A" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship"
  out=$(run_spawn "$rec" lease-fresh-e5 "$WT_B"); status=$?
  expect_code 0 "$status" "a spawn into a free worktree must succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "spawned lease-fresh-e5" "a free-slot spawn should report spawned"
  assert_grep "worktree=$WT_B" "$HOME_DIR/state/lease-fresh-e5.meta" "the free-slot spawn should record its own worktree"
  pass "fm-spawn: a spawn into a genuinely free worktree is unaffected by the lease guard"
}

# A secondmate spawn takes a different code path (its home is supplied, not
# leased), so it carries its own guard call - and that call must land BEFORE the
# pre-launch fast-forward and config push, which would otherwise write into a
# home this home's own records say belongs to another task.
test_refuses_secondmate_home_owned_by_another_task() {
  local rec sm out status
  rec=$(make_case lease-secondmate)
  read_case "$rec"
  register_task_tmp lease-sm-intruder-g7
  sm="$CASE_DIR/secondmate-home"
  seed_secondmate_home "$sm" lease-sm-intruder-g7
  fm_write_meta "$HOME_DIR/state/lease-sm-owner-f6.meta" \
    "window=firstmate:fm-lease-sm-owner-f6" \
    "worktree=$sm" \
    "project=$sm" \
    "harness=claude" \
    "kind=secondmate" \
    "home=$sm"
  out=$(run_spawn_raw "$rec" "$WT_A" lease-sm-intruder-g7 "$sm" --secondmate); status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn onto another task's recorded home must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "lease-sm-owner-f6" "the refusal must name the OWNING task id"
  assert_absent "$HOME_DIR/state/lease-sm-intruder-g7.meta" "an aborted secondmate spawn must not record meta"
  assert_absent "$sm/config" "an aborted secondmate spawn must not push config into the contested home"
  [ "$(launch_sends)" = 0 ] || fail "an aborted secondmate spawn must not send a launch (literal sends=$(launch_sends))"
  pass "fm-spawn: refuses a secondmate home another task records, before the pre-launch sync and config push"
}

test_refuses_worktree_owned_by_another_task
test_allows_same_task_respawn_into_own_worktree
test_allows_genuinely_free_worktree
test_refuses_secondmate_home_owned_by_another_task
