#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's post-launch agent-start confirmation.
#
# fm-spawn used to print `spawned` the moment it had created a pane and sent the
# launch text - success meant "I typed a command", never "an agent is running".
# Observed live (2026-07-17): three herdr spawns whose launch send never landed
# against a freshly restarted server all printed `spawned`, went In flight, and
# ran nothing. These tests drive fm-spawn against a fake tmux whose reported
# foreground command is what the launch actually produced, so a launch that
# never starts an agent must now FAIL loudly instead of reporting success.
#
# The fake reports #{pane_current_command} from a launch-driven signal: it prints
# the "pre" command (a bare shell) until the Nth literal launch send has landed,
# then the "alive" command (a real harness name). N lets a test model "starts on
# first launch" (N=1), "never starts" (N huge), "starts only after the retry"
# (N=2), or "always unverifiable" (pre==alive==node).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot TMP_ROOT fm-spawn-agent-confirm

# A fake tmux driven by three files under FM_FAKE_STATE:
#   literal-count  - incremented on every `send-keys ... -l ...` (one per launch)
#   pane-path      - printed for #{pane_current_path} (the worktree, so the
#                    treehouse-get poll breaks immediately)
# and three env knobs: FM_FAKE_ALIVE_AFTER (N), FM_FAKE_PRE_CMD, FM_FAKE_ALIVE_CMD.
make_confirm_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_STATE:?}
lc="$state/literal-count"
case "$*" in
  *"#{pane_current_command}"*)
    count=$(cat "$lc" 2>/dev/null || printf 0)
    if [ "$count" -ge "${FM_FAKE_ALIVE_AFTER:-1}" ]; then
      printf '%s\n' "${FM_FAKE_ALIVE_CMD:-claude}"
    else
      printf '%s\n' "${FM_FAKE_PRE_CMD:-bash}"
    fi
    exit 0
    ;;
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*) printf '%%0\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|kill-window|set-window-option) exit 0 ;;
  new-window) printf '@1\n'; exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then
        count=$(cat "$lc" 2>/dev/null || printf 0)
        printf '%s\n' "$((count + 1))" > "$lc"
      fi
      prev=$a
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> [harness] -> record "home|proj|wt|fakebin|state"
make_case() {
  local name=$1 harness=${2:-claude} case_dir home proj wt fakebin state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  state="$case_dir/state-fake"
  fakebin=$(make_confirm_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$state"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$name"
  printf 'brief for %s\n' "$name" > "$home/data/$name/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$state"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR STATE_FAKE <<EOF
$1
EOF
}

# run_confirm <record> <id> <ALIVE_AFTER> <PRE_CMD> <ALIVE_CMD> [EXTRA_ENV...]
# Runs fm-spawn with the confirmation ENABLED and a short, fast poll window.
run_confirm() {
  local rec=$1 id=$2 after=$3 pre=$4 alive=$5; shift 5
  read_case "$rec"
  : > "$STATE_FAKE/literal-count"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_STATE="$STATE_FAKE" FM_FAKE_ALIVE_AFTER="$after" \
    FM_FAKE_PRE_CMD="$pre" FM_FAKE_ALIVE_CMD="$alive" \
    FM_SPAWN_CONFIRM=1 FM_SPAWN_CONFIRM_TIMEOUT=1 FM_SPAWN_CONFIRM_INTERVAL=0.2 \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$@" "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

literal_count() { cat "$STATE_FAKE/literal-count" 2>/dev/null || printf 0; }

# fm-spawn creates the per-task temp root /tmp/fm-<id> (bin/fm-spawn.sh), which
# lives OUTSIDE fm_test_tmproot's tree and is normally reaped by fm-teardown -
# never run here. Register it for the suite's EXIT cleanup so a real spawn under
# test leaves no /tmp leak. Must run in the parent shell (fm_test_tmproot already
# installed the trap), not inside run_confirm's command-substitution subshell.
register_task_tmp() { FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$1"); }

test_success_when_agent_appears() {
  local rec id out status
  id=confirm-alive-a1
  rec=$(make_case "$id")
  read_case "$rec"
  register_task_tmp "$id"
  out=$(run_confirm "$rec" "$id" 1 bash claude); status=$?
  expect_code 0 "$status" "a launch that produces a live agent must succeed"
  assert_contains "$out" "spawned $id harness=claude" "confirmed spawn should still report success"
  assert_present "$HOME_DIR/state/$id.meta" "successful spawn should record meta"
  [ "$(literal_count)" = 1 ] || fail "a healthy start must not re-send the launch (literal count=$(literal_count))"
  pass "fm-spawn: a launch that starts an agent is confirmed and reported as spawned, with no retry"
}

test_fail_loud_when_agent_never_starts() {
  local rec id out status
  id=confirm-dead-b2
  rec=$(make_case "$id")
  read_case "$rec"
  register_task_tmp "$id"
  # ALIVE_AFTER huge: the pane stays a bare shell no matter how many launches land.
  out=$(run_confirm "$rec" "$id" 999 bash claude); status=$?
  [ "$status" -ne 0 ] || fail "a launch that never starts an agent must exit non-zero"$'\n'"--- output ---"$'\n'"$out"
  assert_not_contains "$out" "spawned $id" "a dead launch must NOT print the spawned success line"
  assert_contains "$out" "agent did not start" "a dead launch must fail with a clear message"
  assert_contains "$out" "$id" "the failure message must name the failing task"
  # The race-mitigation retry ran: two launch sends, both unconfirmed, then loud failure.
  [ "$(literal_count)" = 2 ] || fail "a dead first launch must be re-sent exactly once (literal count=$(literal_count))"
  pass "fm-spawn: a launch that never starts an agent fails loudly, does not print spawned, after one retry"
}

test_retry_recovers_a_race() {
  local rec id out status
  id=confirm-race-c3
  rec=$(make_case "$id")
  read_case "$rec"
  register_task_tmp "$id"
  # ALIVE_AFTER=2: the agent appears only once the SECOND launch send lands -
  # the suspected pane-creation/launch-send race the retry exists to mitigate.
  out=$(run_confirm "$rec" "$id" 2 bash claude); status=$?
  expect_code 0 "$status" "a race that the retry recovers must ultimately succeed"
  assert_contains "$out" "spawned $id harness=claude" "a recovered race should report spawned"
  assert_contains "$out" "re-sending launch" "a recovered race should note the retry on stderr"
  [ "$(literal_count)" = 2 ] || fail "the retry should re-send the launch exactly once (literal count=$(literal_count))"
  pass "fm-spawn: a launch that starts only after a retry is recovered and reported as spawned"
}

test_unknown_proceeds_with_warning() {
  local rec id out status
  id=confirm-unknown-d4
  rec=$(make_case "$id")
  read_case "$rec"
  register_task_tmp "$id"
  # An inconclusive probe (a bare `node`, never a shell and never a known harness)
  # must never be treated as a failure: proceed, but say so.
  out=$(run_confirm "$rec" "$id" 1 node node); status=$?
  expect_code 0 "$status" "an inconclusive probe must not fail the spawn"
  assert_contains "$out" "spawned $id" "an unverified-but-not-dead launch still reports spawned"
  assert_contains "$out" "could not confirm agent liveness" "an inconclusive probe should warn"
  [ "$(literal_count)" = 1 ] || fail "an inconclusive probe is not a dead verdict and must not trigger a retry (literal count=$(literal_count))"
  pass "fm-spawn: an inconclusive liveness probe proceeds with a warning, never a false failure and never a retry"
}

test_unverifiable_harness_skips_confirmation() {
  local rec id out status
  id=confirm-pi-e5
  rec=$(make_case "$id" pi)
  read_case "$rec"
  register_task_tmp "$id"
  # pi on tmux execs into a generic node process the probe can only read as
  # unknown, so the pair is not verifiable: confirmation is skipped entirely and
  # a bare-shell pane does NOT fail the spawn (documented gap, pre-fix behaviour).
  out=$(run_confirm "$rec" "$id" 999 bash claude); status=$?
  expect_code 0 "$status" "an unverifiable harness must keep the pre-confirmation behaviour"
  assert_contains "$out" "spawned $id harness=pi" "an unverifiable harness still reports spawned"
  assert_not_contains "$out" "agent did not start" "an unverifiable harness must not run the dead-agent check"
  [ "$(literal_count)" = 1 ] || fail "a skipped confirmation must not retry (literal count=$(literal_count))"
  pass "fm-spawn: an unverifiable backend+harness skips confirmation instead of paying an unresolvable poll"
}

test_probe_verifiable_predicate() {
  # Unit-check the capability gate directly across every spawn-capable backend.
  ( set +u
    export FM_HOME="$TMP_ROOT" FM_ROOT_OVERRIDE="$ROOT"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_agent_probe_verifiable herdr claude || exit 21
    fm_backend_agent_probe_verifiable herdr pi     || exit 22
    fm_backend_agent_probe_verifiable tmux claude  || exit 23
    fm_backend_agent_probe_verifiable tmux grok    || exit 24
    fm_backend_agent_probe_verifiable tmux pi      && exit 25
    fm_backend_agent_probe_verifiable zellij claude && exit 26
    fm_backend_agent_probe_verifiable orca claude   && exit 27
    fm_backend_agent_probe_verifiable cmux claude   && exit 28
    exit 0
  )
  expect_code 0 $? "fm_backend_agent_probe_verifiable must gate exactly herdr(any) and tmux(non-pi)"
  pass "fm_backend_agent_probe_verifiable: herdr(any) and tmux(non-pi) verifiable; tmux(pi), zellij, orca, cmux are not"
}

# fm_backend_agent_confirmed_absent gates the re-send that TYPES the whole
# launch command into the pane. It must NOT be the negation of the `alive`
# verdict: an `unknown` read licenses neither acting-as-alive nor writing into
# the pane. If it ever collapsed to `[ verdict != alive ]`, an inconclusive
# probe over a slowly-starting agent would let fm-spawn type a second brief on
# top of a running agent - the D3 destructive half. This pins the asymmetry at
# the generic layer the re-send actually calls.
test_agent_confirmed_absent_is_not_negation_of_alive() {
  # Run in a fresh `bash -c` (the idiom the herdr suite uses) so the classifier
  # override and the assertions are fully isolated from this file's env.
  bash -c '
    set +u
    . "$0/bin/fm-backend.sh"
    fm_backend_source herdr
    # herdr: reality unknown -> confirmed_absent must REFUSE, even though it is
    # also not `alive`. This is the exact middle state the polarity trap hides.
    fm_backend_herdr_pane_agent_reality() { printf "unknown"; }
    fm_backend_agent_confirmed_absent herdr sess:p1 && exit 31
    # reality dead -> confirmed absent.
    fm_backend_herdr_pane_agent_reality() { printf "dead"; }
    fm_backend_agent_confirmed_absent herdr sess:p1 || exit 32
    # reality live -> not absent.
    fm_backend_herdr_pane_agent_reality() { printf "live"; }
    fm_backend_agent_confirmed_absent herdr sess:p1 && exit 33
    # A backend with no verified classifier can never CONFIRM absence, so the
    # guarded re-send never fires there.
    fm_backend_agent_confirmed_absent zellij sess:win && exit 34
    fm_backend_agent_confirmed_absent orca sess:win && exit 35
    exit 0
  ' "$ROOT"
  expect_code 0 $? "fm_backend_agent_confirmed_absent must refuse unknown, confirm only dead, and never confirm on an unverified backend"

  # End-to-end through the REAL reality composition (finding 1), in a fresh
  # shell so the real fm_backend_herdr_pane_agent_reality is intact: a pane with
  # no agent metadata but a LIVE NON-SHELL foreground process is a running-but-
  # undetected agent and must NOT read confirmed-absent (else fm-spawn re-types
  # the brief onto it); the same shape with a bare-shell foreground IS absent.
  bash -c '
    set +u
    . "$0/bin/fm-backend.sh"
    fm_backend_source herdr
    fm_backend_herdr_pane_agent_state() { printf "no-agent"; }
    fm_backend_herdr_pane_process_state() { printf "live"; }
    fm_backend_herdr_pane_foreground_is_shell() { return 1; }   # a claude/node process
    fm_backend_agent_confirmed_absent herdr sess:p1 && exit 36
    fm_backend_herdr_pane_foreground_is_shell() { return 0; }   # a bare shell
    fm_backend_agent_confirmed_absent herdr sess:p1 || exit 37
    exit 0
  ' "$ROOT"
  expect_code 0 $? "fm_backend_agent_confirmed_absent must refuse a live non-shell process (undetected agent) and confirm only a bare-shell/gone pane"
  pass "fm_backend_agent_confirmed_absent: confirms a bare-shell/gone pane; refuses unknown, a running-but-undetected agent, and unverified backends (the re-send never fires)"
}

test_success_when_agent_appears
test_fail_loud_when_agent_never_starts
test_retry_recovers_a_race
test_unknown_proceeds_with_warning
test_unverifiable_harness_skips_confirmation
test_probe_verifiable_predicate
test_agent_confirmed_absent_is_not_negation_of_alive
printf '# all fm-spawn-agent-confirm tests passed\n'
