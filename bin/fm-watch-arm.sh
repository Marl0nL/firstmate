#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script launches the watcher DETACHED from its own process tree (see the
# DETACH CONTRACT below), then VERIFIES the outcome before it settles in.
# It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - arm mode found a live+fresh watcher
#                                                          holding the lock; this arm attaches and
#                                                          waits until that cycle ends
#   watcher: healthy pid=<N> (beacon <age>s)             - restart mode found a live+fresh
#                                                          watcher it did not own
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it stays live for the whole watcher cycle and
# propagates the wake reason; on attached it stays live until the
# identity-matched holder is no longer
# healthy, then exits zero so the harness background-notify fires then (not as a
# false empty wake). On restart-only healthy it exits zero after the duplicate
# child stands down. On FAILED it exits non-zero so the failure is loud. A live
# cycle already present means re-arm attaches - do not start a second watcher.
#
# DETACH CONTRACT (why the watcher is not this script's child):
# A harness that stops its own tracked background task kills the arm's process
# TREE, walking live parent links - measured 2026-07-30 on Claude Code 2.1.220
# inside a herdr pane; see docs/turnend-guard.md for the probe and its table.
# setsid alone does NOT survive that: a new session/process group does not break
# the parent link the walk follows, so the previous own-session fork still took
# the watcher down with every stopped arm task.
# So the watcher is launched DOUBLE-FORKED: `( setsid <self> --detach-launch ... & )`
# exits its intermediate subshell immediately, which reparents the launch away
# from this arm (to the init/user manager) before the arm returns. Nothing in the
# launch descends from the arm, so a tree kill aimed at the arm cannot reach it.
# BOTH halves of that launch are load-bearing and neither is redundant: the double
# fork defeats a kill that walks parent links, and the setsid defeats one scoped to
# the arm's process group. Every reproduced measurement says the stop follows
# parentage, but an independent probe once reported the group being killed too, and
# that observation did not reproduce; keeping the setsid costs nothing and is the
# only thing standing between a group-scoped stop and the original bug. Do not
# remove it as belt-and-braces. tests/fm-watcher-lock.test.sh pins each leg with its
# own kill shape.
# The cost is that the watcher is no longer a wait-able child: this arm polls the
# recorded pid and reads the status the detach launcher records, which keeps the
# arm alive for exactly as long as the watcher runs. That preserves the whole
# supervision contract - the arm stays the harness-visible waiter whose exit
# notifies the harness, the singleton lock and liveness beacon are untouched, and
# a killed arm now costs only a cheap re-arm that ATTACHES to the still-live
# watcher instead of restarting supervision.
#
# WAITER RECORD (state/.watch-waiter):
# For as long as this arm is waiting - started or attached - it records itself as
# the home's live waiter (bin/fm-wake-lib.sh owns the record and its liveness
# test). The arm's exit is the ONLY path a wake has to the agent, and since
# fm-watch.sh self-renews, a home can now have a live watcher and no arm at all:
# seeing everything, able to tell nobody. The record is what lets the guards
# notice that, instead of reading a live watcher as a healthy home.
#
# --detach-launch <dir>: INTERNAL re-exec of this script, never called by hand.
# It is the small process that owns the watcher: it records its own pid, forks the
# watcher, records the watcher pid, and records the watcher's exit status in <dir>
# so the polling arm can report it honestly.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or report restart-only healthy if a
# live peer still holds the lock after the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings. Restart never
# takes the attach path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Absolute path to THIS script, for the --detach-launch re-exec: read off
# BASH_SOURCE rather than hardcoded, so a copy under another name re-execs itself
# and not whatever fm-watch-arm.sh happens to sit beside it.
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  fm_same_path "$lock_home" "$FM_HOME" || return 0
  fm_same_path "$lock_path" "$WATCH" || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

# Register/unregister this arm as the home's live WAITER - the harness-tracked
# task whose exit is the only path a wake has to the agent. See the waiter block
# in bin/fm-wake-lib.sh for why both halves have to be observable.
# Registered on every path where this arm settles in to wait (started or
# attached), cleared on every path where it stops waiting, including signals.
ARM_PID=$$
register_waiter() { fm_waiter_record "$STATE" "$ARM_PID" >/dev/null 2>&1 || true; }
release_waiter()  { fm_waiter_clear "$STATE" "$ARM_PID" >/dev/null 2>&1 || true; }

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

# Stay alive until the attached identity-matched healthy holder is gone.
# Does not reprint the starter arm's wake reason line; exit 0 lets the harness
# notify, and firstmate drains state/.wake-queue on background completion.
#
# THE PID-CHANGED CASE IS A FORK, and getting it wrong silently swallows wakes.
# Two different events both present as "the lock now names a different pid":
#   1. The attached watcher EXITED and a successor took over - the ordinary shape
#      since fm-watch.sh gained self-renewal. Its cycle ENDED, which is precisely
#      the event this arm exists to report, so it must exit and let the harness
#      notify. Re-attaching here would leave the arm waiting forever while
#      successor after successor enqueued wakes nobody was told about - the arm
#      would look perfectly healthy the whole time.
#   2. A live peer STOLE the singleton while the attached watcher is still
#      running (rare, racy arms). Nothing ended, so re-attach and keep waiting.
# The discriminator is whether the pid this arm attached to is still ALIVE.
attach_and_wait() {
  local attached_pid=$1
  register_waiter
  trap 'release_waiter; exit 143' TERM INT
  trap 'release_waiter; exit 129' HUP
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        if fm_pid_alive "$attached_pid"; then
          # Case 2: genuine steal from a still-running holder.
          attached_pid=$HEALTHY_PID
          report_attached
        else
          # Case 1: the attached cycle ended. Report it by exiting.
          release_waiter
          exit 0
        fi
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    # Attached cycle ended (pid gone, identity mismatch, or beacon no longer fresh).
    release_waiter
    exit 0
  done
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  --detach-launch) mode=detach-launch ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

# INTERNAL detach launcher (see the DETACH CONTRACT above). This process owns the
# watcher so the ARM never does: it is already reparented away from the arm's tree
# by the time it runs. It records everything the polling arm needs and interprets
# nothing.
if [ "$mode" = detach-launch ]; then
  launch_dir=${2:-}
  [ -n "$launch_dir" ] && [ -d "$launch_dir" ] || {
    echo "usage: $(basename "$0") --detach-launch <launch-dir>" >&2
    exit 2
  }
  printf '%s\n' "$$" > "$launch_dir/launcher.pid"
  # Opt this watcher into self-renewal (bin/fm-watch.sh owns the rules). Only an
  # ARM-driven watcher may renew: a successor is useful precisely because a later
  # re-arm ATTACHES to it, and harmful to the callers that run the watcher as a
  # deliberate one-shot. The watcher re-checks state/.afk itself, so away mode is
  # covered whether or not this flag is set.
  export FM_WATCH_RENEW=${FM_WATCH_RENEW:-1}
  "$WATCH" > "$launch_dir/out" 2>&1 </dev/null &
  detached_watcher=$!
  printf '%s\n' "$detached_watcher" > "$launch_dir/watcher.pid"
  wait "$detached_watcher"
  detached_rc=$?
  # A best-effort write: the arm may already have removed the launch dir (it does
  # that when it is signalled), and losing the status file must not change the
  # watcher's own outcome.
  printf '%s\n' "$detached_rc" > "$launch_dir/rc" 2>/dev/null || true
  exit "$detached_rc"
fi

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# LAUNCH_PRUNE_MIN_AGE guards a launch dir a concurrent arm has only just created
# (its pid files land within milliseconds, but nothing is atomic).
LAUNCH_PRUNE_MIN_AGE=30

# Remove launch dirs whose arm, watcher, AND launcher are all gone. An arm killed
# outright (SIGKILL, or a harness tree kill that outran the trap) cannot clean up
# after itself, and a stopped arm task is now an ordinary, frequent event, so the
# next arm sweeps the leftovers instead of letting them accumulate in state/.
# A launch with ANY of the three still alive is never touched. All three matter:
# the watcher and launcher are the obvious owners, and the ARM is the process that
# still needs the capture to read the wake reason and exit status out of it - a
# launch whose launcher was killed can outlive its rc file while its arm is still
# reading, and pruning that from under a concurrent arm would silently swallow a
# real wake reason.
# This runs BEFORE the attach short-circuit below, because the frequent case is
# exactly a killed arm whose watcher SURVIVED: the next arm attaches and never
# reaches the launch path, so a prune placed there would never sweep anything.
prune_dead_launch_dirs() {
  local d owner alive
  for d in "$STATE"/.watch-arm.*; do
    [ -d "$d" ] || continue
    [ "$(fm_path_age "$d")" -ge "$LAUNCH_PRUNE_MIN_AGE" ] || continue
    alive=0
    for owner in arm.pid watcher.pid launcher.pid; do
      fm_pid_alive "$(tr -d '[:space:]' 2>/dev/null < "$d/$owner" || true)" && { alive=1; break; }
    done
    [ "$alive" -eq 1 ] && continue
    rm -rf "$d" 2>/dev/null || true
  done
}

prune_dead_launch_dirs

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  report_attached
  attach_and_wait "$HEALTHY_PID"
fi

# Launch the watcher DETACHED from this arm's process tree (see the DETACH
# CONTRACT in the header) and confirm it before settling in.
# Intentional watcher teardown is --restart only (an explicit kill of the recorded
# lock pid), so a reaped arm leaves proactive supervision running instead of
# taking it down.
child=
child_out=
launch_dir=
launcher_pid=

# Read a recorded number (a pid, or the watcher exit status) from the current
# launch dir, or fail if it is absent or not a plain number yet.
# The stderr redirect comes BEFORE the input redirect on purpose: redirections are
# applied left to right, so a `< missing-file 2>/dev/null` would still print the
# shell's own "No such file or directory" - straight into the arm's output, which
# firstmate reads as a wake reason. Polling for a file that is not there yet is
# the normal case here, so it must be genuinely silent.
read_launch_number() {  # <file-name>
  local value
  value=$(tr -d '[:space:]' 2>/dev/null < "$launch_dir/$1" || true)
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

# rm_launch_dir removes ONLY the arm's own temp capture directory.
# It deliberately does NOT kill the watcher, so a signal to this arm cannot take
# the detached watcher down with it. The watcher's wake reason is already durable
# in state/.wake-queue before it exits, so discarding this capture loses nothing.
rm_launch_dir() {
  if [ -n "$launch_dir" ]; then
    rm -rf "$launch_dir" 2>/dev/null || true
  fi
}
# kill_child stops the detached watcher launch explicitly.
# It is used ONLY on the FAILED-to-confirm path, where the launch never became the
# healthy singleton and must not be left behind; it is intentionally NOT wired
# into the signal traps.
# The watcher goes first: killing its launcher first would orphan a watcher this
# arm just declared unconfirmable.
# The launcher is then stopped by PROCESS GROUP where that is provably safe. On the
# path where the watcher pid never landed, the arm knows the launcher but not the
# watcher the launcher may already have forked, and a pid-only kill would leave
# exactly the orphan this function exists to prevent. setsid makes the launcher its
# own session and group leader, so its pgid equals its pid; that equality is
# re-verified here before any negative signal, because signalling a group the arm
# does not own could reach the arm's own siblings.
kill_child() {
  local watcher pgid
  watcher=$(read_launch_number watcher.pid) || watcher=$child
  if [ -n "$watcher" ] && fm_pid_alive "$watcher"; then
    kill -TERM "$watcher" 2>/dev/null || true
  fi
  if [ -n "$launcher_pid" ] && fm_pid_alive "$launcher_pid"; then
    pgid=$(ps -o pgid= -p "$launcher_pid" 2>/dev/null | tr -d '[:space:]')
    if [ "$pgid" = "$launcher_pid" ]; then
      kill -TERM "-$launcher_pid" 2>/dev/null || true
    else
      kill -TERM "$launcher_pid" 2>/dev/null || true
    fi
  fi
}
trap 'release_waiter; rm_launch_dir; exit 129' HUP
trap 'release_waiter; rm_launch_dir; exit 143' TERM INT

# The recorded status of a detached watcher that has already exited. The launcher
# writes it right after the watcher exits, so a short poll covers that ordering.
# If it never lands, the launcher itself was killed, so fall back to the watcher's
# own output rather than inventing a success.
# If the whole capture is GONE, report success: the capture is the only thing that
# was lost, the wake reason itself was appended to state/.wake-queue before the
# watcher exited, and a non-zero exit here would tell firstmate a healthy cycle
# FAILED and send it chasing a watcher that ran perfectly well.
detached_status() {
  local rc i=0
  while [ "$i" -lt 25 ]; do
    if rc=$(read_launch_number rc); then
      printf '%s\n' "$rc"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$child_out" ]; then
    printf '0\n'
  elif watch_output_has_wake "$child_out"; then
    printf '0\n'
  else
    printf '1\n'
  fi
}

# Block for as long as the detached watcher runs.
# This is the poll-based stand-in for `wait <child>`, and it is what keeps this arm
# alive as the harness-visible waiter for the whole watcher cycle.
# It reuses ATTACH_POLL rather than adding a second cadence knob: this is the same
# kind of long wait attach_and_wait already performs, and the extra sub-second
# latency it can add to a wake is nothing beside the harness's own notify latency.
# It must NOT be called inside a command substitution and must not print the
# status itself: bash defers a trapped signal until the current foreground command
# finishes, so a long poll running inside `$( )` would hold the HUP/TERM trap off
# for the entire watcher cycle - the arm would ignore a graceful stop and never
# clean up its launch dir. `wait <child>` was interruptible; this has to stay
# interruptible too, so the caller waits here and reads the status afterwards.
detached_wait() {
  while fm_pid_alive "$child"; do
    sleep "$ATTACH_POLL"
  done
}

# Bounded best-effort wait for a stood-down launch to disappear, used on the paths
# where a peer watcher won the singleton and this launch is irrelevant.
wait_for_child_exit() {  # <tenths>
  local limit=$1 i=0
  while [ "$i" -lt "$limit" ] && fm_pid_alive "$child"; do
    sleep 0.1
    i=$((i + 1))
  done
}

launch_dir=$(mktemp -d "$STATE/.watch-arm.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
child_out="$launch_dir/out"
# Record this arm as an owner of the capture, so another arm's prune can see that
# someone still needs it even after the launcher is gone.
printf '%s\n' "$$" > "$launch_dir/arm.pid" 2>/dev/null || true
# The double fork: the intermediate subshell backgrounds the setsid'd launcher and
# exits immediately, so the launch is reparented off this arm's tree (see the
# DETACH CONTRACT). setsid additionally gives it its own session, so no
# process-group- or session-scoped signal aimed at the arm reaches it either, and
# full stdio redirection keeps it off the arm's streams and off any terminal.
# SELF is resolved absolutely because the arm never controls its caller's cwd.
( setsid "$SELF" --detach-launch "$launch_dir" >/dev/null 2>&1 </dev/null & )
# The launcher records its own pid first, then the watcher's, so poll for the
# watcher pid the confirm loop matches on. Bounded by the confirm timeout: if it
# never lands, the honest answer is the FAILED line below.
launch_deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  launcher_pid=$(read_launch_number launcher.pid) || launcher_pid=
  child=$(read_launch_number watcher.pid) || child=
  [ -n "$child" ] && break
  if [ "$(date +%s)" -ge "$launch_deadline" ]; then
    trap - HUP TERM INT
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    kill_child
    rm_launch_dir
    exit 1
  fi
  sleep 0.05
done
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "watcher: started pid=$child (beacon fresh)"
      register_waiter
      detached_wait
      rc=$(detached_status)
      print_watch_output "$child_out"
      release_waiter
      rm_launch_dir
      exit "$rc"
    fi
    # Another watcher won the singleton; our child stood down.
    if [ "$mode" = arm ]; then
      report_attached
      wait_for_child_exit 50
      rm_launch_dir
      child=
      child_out=
      launch_dir=
      trap - HUP TERM INT
      attach_and_wait "$HEALTHY_PID"
    fi
    report_healthy
    wait_for_child_exit 50
    release_waiter
    rm_launch_dir
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    rc=$(detached_status)
    child_done=1
    if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
      print_watch_output "$child_out"
      release_waiter
      rm_launch_dir
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
kill_child
wait_for_child_exit 20
release_waiter
rm_launch_dir
exit 1
