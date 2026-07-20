#!/usr/bin/env bash
# tests/fm-lock.test.sh - bin/fm-lock.sh harness identification and takeover.
#
# The lock's whole value is that it names a process that OUTLIVES the tool call
# that wrote it. Two ways that breaks, both covered here:
#   1. under-matching - a real harness the ancestry walk cannot name, so the
#      session refuses its own lock and boots read-only (the 2026-07-20 boot
#      incident: the shim execs ~/.local/share/claude/versions/<v>, whose comm
#      is the bare version string);
#   2. over-matching - selecting the transient per-tool-call shell, whose
#      ARGUMENTS mention a harness path. That pid dies moments later, leaving a
#      lock nobody holds.
#
# Everything is driven through a fake `ps` on PATH with FM_HOME and
# FM_STATE_OVERRIDE pointed at a temp dir: this suite must never read or write
# the live fleet's state/.lock, which the running firstmate holds.
#
# holder_alive() uses a real `kill -0`, which no fake ps can intercept, so
# liveness fixtures use real `sleep` pids and reaped pids rather than invented
# numbers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-lock

LOCK="$ROOT/bin/fm-lock.sh"
BASE_PATH="$PATH"
SLEEPERS=""

cleanup_sleepers() {
  local p
  for p in $SLEEPERS; do kill "$p" 2>/dev/null || true; done
}
trap cleanup_sleepers EXIT

# live_pid <varname>: start a real process and store its pid in <varname>. Not a
# command substitution: a backgrounded child inherits the substitution's stdout,
# so $(...) would block until the sleep exited.
live_pid() {
  sleep 300 >/dev/null 2>&1 &
  SLEEPERS="$SLEEPERS $!"
  printf -v "$1" '%s' "$!"
}

# dead_pid <varname>: a pid that genuinely no longer exists.
dead_pid() {
  local p
  sleep 0 >/dev/null 2>&1 &
  p=$!
  wait "$p" 2>/dev/null || true
  printf -v "$1" '%s' "$p"
}

# make_ancestry_ps <fakebin> <spec>...: a fake `ps` describing one process
# ancestry. Each spec is "pid|comm|args|ppid". The literal pid SELF matches any
# pid not otherwise in the table - that is fm-lock.sh's own pid, which the test
# cannot know in advance because the script runs in its own subshell. A pid
# absent from the table exits non-zero, exactly as real ps does for a dead pid.
make_ancestry_ps() {
  local fakebin=$1; shift
  local table="$fakebin/.ancestry"
  printf '%s\n' "$@" > "$table"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""; prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
row=\$(awk -F'|' -v p="\$pid" '\$1 == p { print; found = 1; exit } END { if (!found) exit 1 }' "$table") \
  || row=\$(awk -F'|' '\$1 == "SELF" { print; exit }' "$table")
[ -n "\$row" ] || exit 1
IFS='|' read -r _ comm args ppid <<< "\$row"
case "\$*" in
  *"comm="*) printf '%s\n' "\$comm"; exit 0 ;;
  *"args="*) printf '%s\n' "\$args"; exit 0 ;;
  *"ppid="*) printf '%s\n' "\$ppid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

new_home() {  # new_home <name> -> prints "<home> <fakebin>"
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name-fake")
  mkdir -p "$home/state"
  printf '%s %s\n' "$home" "$fakebin"
}

run_lock() {  # run_lock <home> <fakebin> [status]
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" "$@" 2>&1
}

# --- identification ----------------------------------------------------------

# The regression the incident produced: the shim execs the versioned binary, so
# comm is a bare version number and only argv[0] identifies the harness.
test_versioned_binary_ancestry_is_identified() {
  local home fakebin out harness
  read -r home fakebin <<<"$(new_home versioned)"
  live_pid harness
  make_ancestry_ps "$fakebin" \
    "SELF|bash|/bin/bash -c source ~/.claude/shell-snapshots/snapshot.sh|$harness" \
    "$harness|2.1.215|/home/marlon/.local/share/claude/versions/2.1.215 --dangerously-skip-permissions --continue|1"

  out=$(run_lock "$home" "$fakebin") || fail "versioned-binary session could not acquire its own lock: $out"
  assert_contains "$out" "lock acquired: harness pid $harness" "lock did not name the versioned harness pid"
  [ "$(cat "$home/state/.lock")" = "$harness" ] \
    || fail "lock file holds $(cat "$home/state/.lock"), not the harness pid $harness"
  pass "a shim-launched versioned-binary harness identifies itself and acquires the lock"
}

# THE TRAP. The shell's ARGUMENTS mention ~/.claude/...; it must be walked past,
# never selected. Its pid is the one that dies right after the lock is written.
test_transient_shell_with_harness_args_is_not_the_holder() {
  local home fakebin out harness lock_pid
  read -r home fakebin <<<"$(new_home trap)"
  live_pid harness
  make_ancestry_ps "$fakebin" \
    "SELF|bash|/bin/bash -c source /home/marlon/.claude/shell-snapshots/snapshot-bash.sh && claude --continue|$harness" \
    "$harness|claude|claude --continue|1"

  out=$(run_lock "$home" "$fakebin") || fail "lock acquire failed: $out"
  assert_contains "$out" "lock acquired: harness pid $harness" "the real harness was not selected"
  lock_pid=$(cat "$home/state/.lock")
  [ "$lock_pid" = "$harness" ] \
    || fail "the transient shell (pid $lock_pid) was written as the lock holder instead of the harness"
  pass "a shell whose arguments mention a harness path is never chosen as the holder"
}

# Same trap on the read side: a lock naming that shell must not read as live.
test_shell_with_harness_args_is_not_a_live_holder() {
  local home fakebin out shell_pid
  read -r home fakebin <<<"$(new_home trap-holder)"
  live_pid shell_pid
  make_ancestry_ps "$fakebin" \
    "$shell_pid|bash|/bin/bash -c source /home/marlon/.claude/shell-snapshots/snapshot-bash.sh|1"
  printf '%s\n' "$shell_pid" > "$home/state/.lock"

  out=$(run_lock "$home" "$fakebin" status)
  assert_contains "$out" "lock: stale" "a live shell whose args mention a harness was accepted as the holder"
  pass "holder liveness rejects a shell that merely has a harness path in its arguments"
}

# No regression on the shapes that already worked, including the claude-real
# wrapper the captain had been resuming through.
test_classic_comm_shapes_still_identified() {
  local home fakebin out comm harness
  for comm in claude claude-real codex opencode grok pi; do
    read -r home fakebin <<<"$(new_home "classic-$comm")"
    live_pid harness
    make_ancestry_ps "$fakebin" \
      "SELF|bash|/bin/bash -c true|$harness" \
      "$harness|$comm|$comm --continue|1"
    out=$(run_lock "$home" "$fakebin") || fail "comm=$comm was not identified: $out"
    assert_contains "$out" "lock acquired: harness pid $harness" "comm=$comm did not acquire the lock"
  done
  pass "classic comm shapes (claude, claude-real, codex, opencode, grok, pi) still identify"
}

# holder_alive must apply the SAME test harness_pid selects with. Before this, a
# versioned holder passed only because its args happened to contain "claude".
test_versioned_holder_is_recognized_as_live() {
  local home fakebin out holder
  read -r home fakebin <<<"$(new_home versioned-holder)"
  live_pid holder
  # argv[0] is the only harness evidence here: no argument names a harness.
  make_ancestry_ps "$fakebin" "$holder|9.9.9|/home/marlon/.local/share/opencode/versions/9.9.9 --resume|1"
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(run_lock "$home" "$fakebin" status)
  assert_contains "$out" "lock: held by live harness pid $holder" \
    "a versioned-binary holder was not recognized as live"
  pass "holder liveness recognizes a versioned-install binary by argv[0], not by luck"
}

# --- takeover and refusal ----------------------------------------------------

test_lock_naming_a_dead_pid_is_taken_over() {
  local home fakebin out harness dead
  read -r home fakebin <<<"$(new_home stale)"
  live_pid harness
  dead_pid dead
  make_ancestry_ps "$fakebin" \
    "SELF|bash|/bin/bash -c true|$harness" \
    "$harness|claude|claude --continue|1"
  printf '%s\n' "$dead" > "$home/state/.lock"

  out=$(run_lock "$home" "$fakebin" status)
  assert_contains "$out" "lock: stale (pid $dead dead or not a harness)" "status did not report the dead holder stale"

  out=$(run_lock "$home" "$fakebin") || fail "a lock naming a dead pid blocked a fresh session: $out"
  assert_contains "$out" "lock acquired: harness pid $harness" "stale lock was not taken over"
  [ "$(cat "$home/state/.lock")" = "$harness" ] || fail "stale lock file was not rewritten to this session"
  pass "a lock naming a pid that no longer exists never blocks a fresh session"
}

test_live_holder_is_refused() {
  local home fakebin out status holder mine
  read -r home fakebin <<<"$(new_home live-holder)"
  live_pid holder
  live_pid mine
  make_ancestry_ps "$fakebin" \
    "SELF|bash|/bin/bash -c true|$mine" \
    "$mine|claude|claude --continue|1" \
    "$holder|claude|claude --continue|1"
  printf '%s\n' "$holder" > "$home/state/.lock"

  status=0
  out=$(run_lock "$home" "$fakebin") || status=$?
  expect_code 1 "$status" "a genuinely live holder must be refused with exit 1"
  assert_contains "$out" "another live firstmate session holds the lock (pid $holder)" "refusal did not name the live holder"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a refused session overwrote the live holder's lock"
  pass "a lock naming a genuinely live harness is refused and left intact"
}

# The two refusals demand opposite responses, so the caller must be able to tell
# them apart: exit 1 = go find the other session; exit 2 = there is none.
test_refusal_reasons_are_distinguishable() {
  local home fakebin out status
  read -r home fakebin <<<"$(new_home unidentifiable)"
  # An ancestry of nothing but shells: no harness anywhere, even though the
  # shell's arguments name one.
  make_ancestry_ps "$fakebin" \
    "SELF|bash|/bin/bash -c source ~/.claude/shell-snapshots/snapshot.sh|1"

  status=0
  out=$(run_lock "$home" "$fakebin") || status=$?
  expect_code 2 "$status" "an unidentifiable session must exit 2, distinct from a live holder's 1"
  assert_contains "$out" "cannot identify this session's own harness process" "exit-2 message did not name the real reason"
  assert_contains "$out" "no other session was found holding one" "exit-2 message did not rule out a competing session"
  assert_absent "$home/state/.lock" "an unidentifiable session wrote a lock anyway"
  pass "cannot-identify-self (2) and another-session-holds-it (1) are distinguishable to the caller"
}

test_versioned_binary_ancestry_is_identified
test_transient_shell_with_harness_args_is_not_the_holder
test_shell_with_harness_args_is_not_a_live_holder
test_classic_comm_shapes_still_identified
test_versioned_holder_is_recognized_as_live
test_lock_naming_a_dead_pid_is_taken_over
test_live_holder_is_refused
test_refusal_reasons_are_distinguishable
