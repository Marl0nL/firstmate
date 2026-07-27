#!/usr/bin/env bash
# tests/fm-check-trust.test.sh - watcher check-script authentication.
#
# The watcher EXECUTES state/*.check.sh, so a check runs only when it is bound to
# its exact bytes through the trust path (bin/fm-check-lib.sh). This suite covers
# the library rules, the bin/fm-check-register.sh entry point, the producers that
# must arm and register in one operation, and the watcher end to end: a registered
# check runs, and an unregistered, tampered, or non-private one is REFUSED without
# execution and surfaced as an actionable wake rather than silently skipped.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"

fm_test_tmproot TMP_ROOT fm-check-trust

# A state dir holding one unregistered check script, the starting point for the
# library cases below. The watcher cases define their own bodies inline, because
# there "did it execute?" has to be observable rather than inferred.
make_state() {  # <name> [<id>]
  local name=$1 id=${2:-task} state
  state="$TMP_ROOT/$name/state"
  mkdir -p "$state"
  cat > "$state/$id.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  printf '%s\n' "$state"
}

file_mode() { fm_check_file_mode "$1"; }

# --- library: the trust record ----------------------------------------------

test_register_binds_bytes_and_modes() {
  local state trust
  state=$(make_state register)
  fm_custom_check_register "$state" task || fail "registration must succeed"
  trust="$state/task.check-trust"
  assert_present "$trust" "registration must publish a trust record"
  [ "$(file_mode "$state/task.check.sh")" = 700 ] || fail "the check must end at mode 700"
  [ "$(file_mode "$trust")" = 600 ] || fail "the trust record must be mode 600"
  [ "$(wc -l < "$trust" | tr -d ' ')" = 2 ] || fail "the trust record must be exactly two lines"
  [ "$(head -1 "$trust")" = fm-custom-check-v1 ] || fail "the trust record must carry its version"
  [ "$(sed -n 2p "$trust")" = "$(fm_custom_check_sha256 "$state/task.check.sh")" ] \
    || fail "the trust record must carry the check's sha256"
  fm_custom_check_registered "$state" task || fail "a freshly registered check must verify"
  pass "registration binds a check to its exact bytes with private modes"
}

test_unregistered_check_is_refused() {
  local state
  state=$(make_state unregistered)
  chmod 700 "$state/task.check.sh"
  ! fm_custom_check_registered "$state" task || fail "an unregistered check must not verify"
  ! fm_custom_check_snapshot_prepare "$state" task || fail "an unregistered check must not be staged"
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || fail "a refused check must leave no staged snapshot"
  [ "$(find "$state" -maxdepth 1 -name '.fm-custom-check.*' | wc -l | tr -d ' ')" = 0 ] \
    || fail "a refused check must leave no snapshot temporary behind"
  pass "an unregistered check is refused and stages nothing"
}

test_changed_content_after_registration_is_refused() {
  local state
  state=$(make_state tampered)
  fm_custom_check_register "$state" task || fail "setup registration failed"
  fm_custom_check_registered "$state" task || fail "setup verification failed"
  printf 'printf "owned\\n"\n' >> "$state/task.check.sh"
  ! fm_custom_check_registered "$state" task || fail "a hash mismatch must not verify"
  ! fm_custom_check_snapshot_prepare "$state" task || fail "a hash mismatch must not be staged"
  pass "a check rewritten after registration is refused on the hash"
}

test_wrong_modes_are_refused() {
  local state
  state=$(make_state modes)
  fm_custom_check_register "$state" task || fail "setup registration failed"
  chmod 755 "$state/task.check.sh"
  ! fm_custom_check_registered "$state" task || fail "a group/other-readable check must be refused"
  ! fm_custom_check_snapshot_prepare "$state" task || fail "a wrong-mode check must not be staged"
  chmod 700 "$state/task.check.sh"
  fm_custom_check_registered "$state" task || fail "restoring mode 700 must restore trust"
  chmod 644 "$state/task.check-trust"
  ! fm_custom_check_registered "$state" task || fail "a world-readable trust record must be refused"
  pass "a check or trust record at the wrong mode is refused"
}

test_symlinked_and_linked_artifacts_are_refused() {
  local state elsewhere
  state=$(make_state links)
  fm_custom_check_register "$state" task || fail "setup registration failed"
  elsewhere="$TMP_ROOT/links/elsewhere.sh"
  cp "$state/task.check.sh" "$elsewhere"
  chmod 700 "$elsewhere"
  rm -f "$state/task.check.sh"
  ln -s "$elsewhere" "$state/task.check.sh"
  ! fm_custom_check_registered "$state" task || fail "a symlinked check must be refused"
  rm -f "$state/task.check.sh"
  ln "$elsewhere" "$state/task.check.sh"
  ! fm_custom_check_registered "$state" task || fail "a hardlinked check must be refused"
  pass "a symlinked or hardlinked check is refused even with a matching hash"
}

test_appended_trust_record_is_refused() {
  local state
  state=$(make_state appended)
  fm_custom_check_register "$state" task || fail "setup registration failed"
  printf 'extra\n' >> "$state/task.check-trust"
  chmod 600 "$state/task.check-trust"
  ! fm_custom_check_registered "$state" task || fail "an appended trust record must be refused"
  pass "a trust record with a trailing line is refused"
}

test_snapshot_is_a_private_copy_of_the_verified_bytes() {
  local state snapshot
  state=$(make_state snapshot)
  fm_custom_check_register "$state" task || fail "setup registration failed"
  fm_custom_check_snapshot_prepare "$state" task || fail "a registered check must stage"
  snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
  [ -n "$snapshot" ] || fail "staging must publish a snapshot path"
  cmp -s "$snapshot" "$state/task.check.sh" || fail "the snapshot must be the verified bytes"
  [ "$(file_mode "$snapshot")" = 600 ] || fail "the snapshot must be private"
  case "$(basename "$snapshot")" in .*) : ;; *) fail "the snapshot must not match the *.check.sh sweep glob" ;; esac
  fm_custom_check_snapshot_cleanup
  [ ! -e "$snapshot" ] || fail "cleanup must remove the snapshot"
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || fail "cleanup must clear the snapshot path"
  pass "execution runs a private snapshot of the bytes that were verified"
}

test_trust_remove_drops_the_registration() {
  local state
  state=$(make_state remove)
  fm_custom_check_register "$state" task || fail "setup registration failed"
  fm_custom_check_trust_remove "$state" task || fail "trust removal must succeed"
  assert_absent "$state/task.check-trust" "trust removal must delete the record"
  ! fm_custom_check_registered "$state" task || fail "a removed registration must not verify"
  pass "removing a trust record drops the registration"
}

test_invalid_ids_are_refused() {
  local state
  state=$(make_state ids)
  ! fm_check_id_valid '../escape' || fail "a traversing id must be refused"
  ! fm_check_id_valid '' || fail "an empty id must be refused"
  ! fm_check_id_valid '.hidden' || fail "a dotfile id must be refused"
  ! fm_custom_check_register "$state" '../escape' || fail "registration must refuse a traversing id"
  pass "an unsafe check id is refused before anything is written"
}

# --- bin/fm-check-register.sh ------------------------------------------------

test_cli_registers_lists_and_verifies() {
  local state out rc
  state=$(make_state cli)
  out=$(FM_STATE_OVERRIDE="$state" "$REGISTER" --list) || fail "--list must succeed"
  assert_contains "$out" "UNREGISTERED  task" "--list must name an unregistered check"
  assert_contains "$out" "fm-check-register.sh task" "--list must show how to register it"
  rc=0
  FM_STATE_OVERRIDE="$state" "$REGISTER" --verify task >/dev/null || rc=$?
  expect_code 1 "$rc" "--verify on an unregistered check"
  out=$(FM_STATE_OVERRIDE="$state" "$REGISTER" task) || fail "registering must succeed"
  assert_contains "$out" "registered: state/task.check.sh" "registration must confirm what it bound"
  FM_STATE_OVERRIDE="$state" "$REGISTER" --verify task >/dev/null || fail "--verify must pass after registering"
  out=$(FM_STATE_OVERRIDE="$state" "$REGISTER" --list) || fail "--list must succeed after registering"
  assert_contains "$out" "registered    task" "--list must report the check as registered"
  rc=0
  FM_STATE_OVERRIDE="$state" "$REGISTER" missing >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "registering a nonexistent check"
  rc=0
  FM_STATE_OVERRIDE="$state" "$REGISTER" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no arguments"
  pass "fm-check-register.sh registers, lists, and verifies checks"
}

# --- producers: arming and registering are one operation ---------------------

test_pr_check_arms_and_registers_its_merge_poll() {
  local dir state fakebin out
  dir="$TMP_ROOT/pr-check"
  state="$dir/state"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$state"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    "$PR_CHECK" task-a https://github.com/o/r/pull/1) || fail "fm-pr-check.sh must succeed"
  assert_contains "$out" "armed: state/task-a.check.sh" "fm-pr-check.sh must report the armed poll"
  fm_custom_check_registered "$state" task-a \
    || fail "an armed merge poll must be registered, or the watcher refuses it"
  pass "fm-pr-check.sh registers the merge poll it arms"
}

test_pr_check_refuses_an_unsafe_task_id() {
  local dir state rc
  dir="$TMP_ROOT/pr-check-id"
  state="$dir/state"
  mkdir -p "$state"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$PR_CHECK" ../escape https://github.com/o/r/pull/1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "fm-pr-check.sh with a traversing task id"
  pass "fm-pr-check.sh refuses an unsafe task id before writing anything"
}

test_teardown_removes_the_trust_record_with_the_check() {
  # A trust record must never outlive its check: a later check reusing the id
  # would otherwise inherit a registration nobody made for it.
  local state
  state=$(make_state teardown)
  fm_custom_check_register "$state" task || fail "setup registration failed"
  grep -q 'check-trust' "$ROOT/bin/fm-teardown.sh" \
    || fail "fm-teardown.sh must remove state/<id>.check-trust alongside the check"
  pass "teardown removes a task's trust record with its check"
}

# --- the watcher -------------------------------------------------------------

# Run the watcher against <state> until it wakes (or the timeout), then print its
# output. FM_CHECK_INTERVAL=0 makes the check sweep due immediately.
run_watcher() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 60
}

test_watcher_runs_a_registered_check() {
  local dir state out drain_out
  dir=$(make_case watch-registered)
  state="$dir/state"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  cat > "$state/task.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  fm_custom_check_register "$state" task || fail "setup registration failed"
  run_watcher "$state" "$dir/fakebin" "$out" || fail "watcher did not exit for a registered check"
  grep -F "check: $state/task.check.sh: merged: https://example.test/pr/1" "$out" >/dev/null \
    || fail "a registered check's output must reach the wake reason: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F 'merged: https://example.test/pr/1' >/dev/null \
    || fail "the check wake was not queued durably"
  pass "the watcher runs a registered check and surfaces its output"
}

test_watcher_refuses_an_unregistered_check_loudly() {
  local dir state out drain_out
  dir=$(make_case watch-unregistered)
  state="$dir/state"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  cat > "$state/task.check.sh" <<SH
#!/usr/bin/env bash
printf 'ran\n' > "$dir/executed"
printf 'merged: never\n'
SH
  chmod 700 "$state/task.check.sh"
  run_watcher "$state" "$dir/fakebin" "$out" || fail "watcher did not exit for a refused check"
  assert_absent "$dir/executed" "an unregistered check must never execute"
  grep -F 'check: rejected unauthenticated state checks:' "$out" >/dev/null \
    || fail "a refusal must be surfaced, not silently skipped: $(cat "$out")"
  grep -F "$state/task.check.sh" "$out" >/dev/null || fail "the refusal must name the refused file"
  grep -F 'fm-check-register.sh' "$out" >/dev/null || fail "the refusal must state the remedy"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F 'rejected unauthenticated state checks' >/dev/null \
    || fail "the refusal must be queued durably like any other actionable check wake"
  pass "the watcher refuses an unregistered check without running it and surfaces the refusal"
}

test_watcher_refuses_a_check_changed_after_registration() {
  local dir state out
  dir=$(make_case watch-tampered)
  state="$dir/state"
  out="$dir/watch.out"
  cat > "$state/task.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  fm_custom_check_register "$state" task || fail "setup registration failed"
  cat > "$state/task.check.sh" <<SH
#!/usr/bin/env bash
printf 'ran\n' > "$dir/executed"
printf 'merged: https://example.test/pr/1\n'
SH
  chmod 700 "$state/task.check.sh"
  run_watcher "$state" "$dir/fakebin" "$out" || fail "watcher did not exit for a tampered check"
  assert_absent "$dir/executed" "a check rewritten after registration must never execute"
  grep -F 'check: rejected unauthenticated state checks:' "$out" >/dev/null \
    || fail "a hash mismatch must be surfaced as a refusal: $(cat "$out")"
  pass "the watcher refuses a check whose bytes changed after registration"
}

test_watcher_refuses_a_group_writable_check() {
  local dir state out
  dir=$(make_case watch-writable)
  state="$dir/state"
  out="$dir/watch.out"
  cat > "$state/task.check.sh" <<SH
#!/usr/bin/env bash
printf 'ran\n' > "$dir/executed"
printf 'merged: https://example.test/pr/1\n'
SH
  fm_custom_check_register "$state" task || fail "setup registration failed"
  chmod 770 "$state/task.check.sh"
  run_watcher "$state" "$dir/fakebin" "$out" || fail "watcher did not exit for a group-writable check"
  assert_absent "$dir/executed" "a group-writable check must never execute"
  grep -F 'check: rejected unauthenticated state checks:' "$out" >/dev/null \
    || fail "a group-writable check must be surfaced as a refusal: $(cat "$out")"
  pass "the watcher refuses a group-writable check even when its hash matches"
}

test_watcher_still_runs_registered_checks_beside_a_refused_one() {
  # A refusal must not take the authenticated checks down with it: the refusal
  # surfaces first, and the next sweep runs the good check while the unchanged
  # refusal is held on its bounded re-surface cadence.
  local dir state out drain_out
  dir=$(make_case watch-mixed)
  state="$dir/state"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  cat > "$state/good.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/9\n'
SH
  fm_custom_check_register "$state" good || fail "setup registration failed"
  cat > "$state/bad.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'merged: never\n'
SH
  chmod 700 "$state/bad.check.sh"
  run_watcher "$state" "$dir/fakebin" "$out" || fail "watcher did not exit for the refusal"
  grep -F 'rejected unauthenticated state checks:' "$out" >/dev/null \
    || fail "the refusal must surface first: $(cat "$out")"
  : > "$out"
  run_watcher "$state" "$dir/fakebin" "$out" || fail "watcher did not exit for the registered check"
  grep -F "check: $state/good.check.sh: merged: https://example.test/pr/9" "$out" >/dev/null \
    || fail "the registered check must still run once the refusal is held: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain failed"
  grep -F 'merged: https://example.test/pr/9' "$drain_out" >/dev/null \
    || fail "the registered check's wake was not queued"
  pass "a refused check does not starve the registered checks beside it"
}

# --- end to end: the usage-monitor shim --------------------------------------

test_bootstrap_arms_and_registers_the_usage_shim_and_it_fires() {
  # The one check this home actually ships. Bootstrap owns arming it, so it must
  # also own registering it, or its wakes would die the moment the watcher started
  # authenticating checks. Drive the real producer, then the real watcher.
  local dir home fakeroot fakebin out drain_out boot
  dir="$TMP_ROOT/usage-e2e"
  home="$dir/home"
  fakeroot="$dir/fakeroot"
  mkdir -p "$home/state" "$home/config" "$home/data" "$fakeroot/bin"
  fakebin=$(fm_fakebin "$dir")
  make_fake_crew_state "$fakebin" >/dev/null
  for t in jq curl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"
    chmod +x "$fakebin/$t"
  done
  # Stand in for the real poll body: the trust path is what is under test here,
  # not the quota arithmetic that bin/fm-usage-poll.sh does behind the network.
  cat > "$fakeroot/bin/fm-usage-poll.sh" <<'SH'
#!/usr/bin/env bash
printf 'usage-quota warning: token quota crossed the high-water mark\n'
SH
  chmod +x "$fakeroot/bin/fm-usage-poll.sh"
  printf 'FM_USAGE_ENABLED=1\n' > "$home/config/usage-monitor.env"

  boot=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fakeroot" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null) || fail "bootstrap must not fail"
  assert_contains "$boot" "USAGE: monitor on" "bootstrap must arm the usage poll"
  assert_present "$home/state/usage-watch.check.sh" "bootstrap must write the usage shim"
  fm_custom_check_registered "$home/state" usage-watch \
    || fail "bootstrap must register the usage shim it arms"
  [ "$(file_mode "$home/state/usage-watch.check.sh")" = 700 ] \
    || fail "the armed usage shim must be private"

  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  run_watcher "$home/state" "$fakebin" "$out" || fail "watcher did not exit for the usage check"
  grep -F 'usage-quota warning' "$out" >/dev/null \
    || fail "the registered usage shim must still fire end to end: $(cat "$out")"
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$drain_out" || fail "drain failed"
  grep -F 'usage-quota warning' "$drain_out" >/dev/null || fail "the usage wake was not queued"

  # Opting back out must take the registration with the shim.
  printf 'FM_USAGE_ENABLED=0\n' > "$home/config/usage-monitor.env"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fakeroot" \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 || fail "bootstrap opt-out must not fail"
  assert_absent "$home/state/usage-watch.check.sh" "opt-out must remove the shim"
  assert_absent "$home/state/usage-watch.check-trust" "opt-out must remove the trust record"
  pass "bootstrap arms, registers, and later unregisters the usage-monitor check, and it fires"
}

test_register_binds_bytes_and_modes
test_unregistered_check_is_refused
test_changed_content_after_registration_is_refused
test_wrong_modes_are_refused
test_symlinked_and_linked_artifacts_are_refused
test_appended_trust_record_is_refused
test_snapshot_is_a_private_copy_of_the_verified_bytes
test_trust_remove_drops_the_registration
test_invalid_ids_are_refused
test_cli_registers_lists_and_verifies
test_pr_check_arms_and_registers_its_merge_poll
test_pr_check_refuses_an_unsafe_task_id
test_teardown_removes_the_trust_record_with_the_check
test_watcher_runs_a_registered_check
test_watcher_refuses_an_unregistered_check_loudly
test_watcher_refuses_a_check_changed_after_registration
test_watcher_refuses_a_group_writable_check
test_watcher_still_runs_registered_checks_beside_a_refused_one
test_bootstrap_arms_and_registers_the_usage_shim_and_it_fires
