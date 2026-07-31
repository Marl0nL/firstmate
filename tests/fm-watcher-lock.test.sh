#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

fm_test_tmproot TMP_ROOT fm-watcher-lock-tests

# --- process-ancestry helpers for the watcher-detachment tests ---------------
#
# The arm's detach contract has two independent legs, and these helpers cover the
# ancestry one. A harness that stops its own tracked background task kills the
# launching shell's process TREE by walking live parent links, which is why the
# arm's former own-session child was still reaped every time. So these helpers let
# a test see the tree the way that harness does.
# The other leg is signal scoping, covered separately by the process-group test
# below: the launch is also setsid'd out of the arm's process group, and that is not
# redundant belt-and-braces. See the DETACH CONTRACT in bin/fm-watch-arm.sh and the
# 2026-07-30 section of docs/turnend-guard.md for the measurements and for the one
# contrary observation that keeps both legs load-bearing.

# Every live descendant pid of <pid>, one per line, walked recursively from ONE ps
# snapshot. `ps -A` rather than `ps -e`, because -e means "also show the
# environment" on BSD/macOS ps while -A is "all processes" everywhere.
pid_descendants() {  # <pid>
  local top=$1 table frontier next seen pid ppid
  table=$(ps -A -o pid=,ppid= 2>/dev/null || true)
  frontier=" $top "
  seen=" "
  while [ -n "$frontier" ]; do
    next=
    while read -r pid ppid; do
      [ -n "$pid" ] || continue
      case "$frontier" in *" $ppid "*) ;; *) continue ;; esac
      case "$seen" in *" $pid "*) continue ;; esac
      seen="$seen$pid "
      next="$next$pid "
      printf '%s\n' "$pid"
    done <<< "$table"
    frontier=$next
    [ -n "$frontier" ] && frontier=" $frontier"
  done
}

# The parent chain above <pid>, one pid per line, up to init. Bounded so a ps
# snapshot that shifts under us can never spin.
pid_ancestors() {  # <pid>
  local pid=$1 parent i=0
  while [ "$i" -lt 40 ]; do
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$parent" in
      ''|0|*[!0-9]*) return 0 ;;
    esac
    printf '%s\n' "$parent"
    [ "$parent" = 1 ] && return 0
    pid=$parent
    i=$((i + 1))
  done
}

# The basenames of the arm's temp capture dirs currently in <state>, in glob order.
# A test compares this before and after a re-arm: an arm that attaches to a live
# watcher never creates one, so an unchanged list proves it did not fork a second
# watcher. Built from a glob rather than `ls` so it stays shellcheck-clean.
launch_dirs() {  # <state>
  local state=$1 d out=
  for d in "$state"/.watch-arm.*; do
    [ -d "$d" ] || continue
    out="$out$(basename "$d") "
  done
  printf '%s\n' "$out"
}

# Read a path's mtime through the production helper, so an "advancing beacon" check
# compares exactly the timestamps supervision itself reads.
path_mtime() {  # <state> <path>
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_path_mtime "$2"' _ "$LIB" "$2"
}

# Bounded reap of a backgrounded arm: poll for its exit, return its status, and
# SIGKILL it if it outlived the window (returning 124 the way wait_for_exit does).
# Deliberately NOT wait_for_exit: that helper falls back to a TERM plus a BLOCKING
# `wait`, and an arm that cannot run its signal trap - because it is parked in a
# command substitution polling the detached watcher - wedges the whole suite there
# instead of failing the one assertion.
reap_arm() {  # <pid> <tenths>
  local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

# Stop a detached launch by EXACT pid: the watcher first, then the launcher that
# waits on it. Never a pattern kill - every firstmate home runs a process whose
# command line matches fm-watch.sh, so `pkill -f fm-watch` would reap siblings,
# including the captain's live watcher.
stop_detached_watcher() {  # <watcher-pid> <launcher-pid>
  local watcher=$1 launcher=${2:-} i=0
  if [ -n "$watcher" ]; then
    kill -TERM "$watcher" 2>/dev/null || true
    while [ "$i" -lt 50 ] && is_live_non_zombie "$watcher"; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -KILL "$watcher" 2>/dev/null || true
  fi
  [ -n "$launcher" ] || return 0
  # The launcher exits on its own once the watcher it waits on is gone.
  i=0
  while [ "$i" -lt 50 ] && is_live_non_zombie "$launcher"; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$launcher" 2>/dev/null || true
}

# Arm a fresh watcher for <case-name>, then kill the ARM exactly the way a harness
# stops its own tracked background task: the arm pid plus every live descendant,
# SIGKILL, with no chance for a trap to run. On the way it asserts that nothing in
# the detached launch is reachable from the arm, because that ancestry - not signal
# scoping - is what decides whether the watcher dies with its launcher.
#
# The scenario is recorded in the ARMED_* variables instead of printed, because a
# fail inside a command substitution would only exit that subshell and let the suite
# carry on reporting ok.
#
# FM_POLL=1 keeps the liveness beacon beating about once a second so a caller can
# watch it advance inside a bounded window; every other cadence is pinned off so the
# watcher never wakes and exits on its own mid-test.
ARMED_DIR=
ARMED_STATE=
ARMED_ARMOUT=
ARMED_WATCHER=
ARMED_LAUNCHER=
ARMED_BEAT=
arm_then_tree_kill() {  # <case-name>
  local case_name=$1 fakebin armpid desc p i=0
  local -a tree
  ARMED_DIR=$(make_case "$case_name")
  ARMED_STATE="$ARMED_DIR/state"
  ARMED_ARMOUT="$ARMED_DIR/arm.out"
  fakebin="$ARMED_DIR/fakebin"
  # stdout AND stderr, because the harness hands firstmate one merged stream and
  # reads it as the wake reason.
  PATH="$fakebin:$PATH" FM_HOME="$ARMED_DIR" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$ARMED_ARMOUT" 2>&1 &
  armpid=$!
  while [ "$i" -lt 150 ]; do
    grep -qF 'watcher: started pid=' "$ARMED_ARMOUT" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$ARMED_ARMOUT" \
    || fail "arm ($case_name) did not start a watcher: $(cat "$ARMED_ARMOUT")"
  ARMED_WATCHER=$(cat "$ARMED_STATE/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$ARMED_WATCHER" ] || fail "arm ($case_name) recorded no watcher lock pid"
  ARMED_LAUNCHER=$(ps -o ppid= -p "$ARMED_WATCHER" 2>/dev/null | tr -d ' ')
  [ -n "$ARMED_LAUNCHER" ] || fail "arm ($case_name) watcher has no parent to identify the detach launcher"
  ARMED_BEAT=$(path_mtime "$ARMED_STATE" "$ARMED_STATE/.last-watcher-beat")
  [ -n "$ARMED_BEAT" ] || fail "arm ($case_name) watcher wrote no liveness beacon"
  [ "$ARMED_LAUNCHER" != "$armpid" ] \
    || fail "arm ($case_name) watcher is still a direct child of the arm $armpid"
  # The regression: the watcher used to be a setsid'd CHILD of the arm, so it sat in
  # this descendant set and a tree kill reached it through the live parent link.
  # A session of its own did not save it, because a tree walk follows parentage.
  tree=("$armpid")
  desc=$(pid_descendants "$armpid")
  for p in $desc; do
    [ "$p" != "$ARMED_WATCHER" ] \
      || fail "arm ($case_name) watcher $p is a descendant of the arm $armpid - a harness tree kill would reap it"
    [ "$p" != "$ARMED_LAUNCHER" ] \
      || fail "arm ($case_name) detach launcher $p is a descendant of the arm $armpid - a harness tree kill would reap the whole launch"
    tree+=("$p")
  done
  kill -KILL "${tree[@]}" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
}


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'repair missing watcher supervision' "$err" >/dev/null || fail "guard banner missing the harness-aware fix command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, repair missing watcher supervision' "$err" >/dev/null || fail "guard did not order supervision repair after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  # A genuinely RUNNING watcher, not just a fresh beacon: liveness is answered
  # from the singleton lock, so a beacon-only fixture is the wake-handoff window
  # and warns on purpose (tests/fm-supervision-selfsustaining.test.sh).
  fm_test_pose_live_watcher "$state" "$dir"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  fm_test_stop_posed_watcher
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm forks the fresh watcher as a tracked child and waits on it, so
  # the lock now names that child, not the arm invocation. The property is the
  # same: the stale reused-pid lock is replaced by a genuinely live watcher, which
  # the arm confirms before reporting it. Wait for that confirmation, not just for
  # the lock pid to appear (identity and beacon land a beat later).
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$out" >/dev/null || fail "restart did not report the fresh watcher it confirmed"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_watch_restart_reports_healthy_peer_without_attaching() {
  local dir state fakebin out peer identity armpid status
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  node -e 'process.on("SIGTERM", () => {}); setTimeout(() => {}, 300000)' &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "restart did not exit zero after reporting healthy peer (status $status): $(cat "$out")"
  grep -qF "watcher: healthy pid=$peer" "$out" || fail "restart did not report the healthy peer: $(cat "$out")"
  ! grep -qF 'watcher: attached' "$out" || fail "restart attached to a peer watcher instead of preserving restart ownership contract"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "watch restart reports a healthy peer without attaching to it"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies, the attached arm must exit 0 (cycle ended).
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after seed died (status $status)"
  pass "arm attaches to a live fresh watcher and exits only when that cycle ends"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1; i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    [ -z "$dead_pid" ] || [ "$lock_pid" != "$dead_pid" ] || fail "arm ($row) did not replace the dead-pid lock with a live watcher"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts+confirms a fresh watcher on a clean lock and self-heals a dead-pid lock (never healthy off a dead pid)"
}

test_arm_hup_leaves_detached_watcher_running() {
  # A signal to the arm must NOT take the watcher down with it, and the stronger
  # property the current implementation owes: the watcher must not even be REACHABLE
  # from the arm. It is launched double-forked, so the launch is reparented off the
  # arm's tree (to init or the user manager) before the arm returns - see the DETACH
  # CONTRACT in bin/fm-watch-arm.sh. setsid alone was NOT enough, because a new
  # session does not break the parent link a harness tree kill walks, so these
  # assertions are about ancestry rather than the old "watcher is its own session
  # leader" shape (it no longer is: the detach launcher leads that session).
  # The arm still exits 129 on HUP, its traps still deliberately spare the watcher,
  # and it still removes its own temp capture DIR - state/.watch-arm.*, which
  # replaced the old single .watch-arm-output.* file.
  local dir state fakebin armout i armpid lock_pid launcher status wsess armsess desc p anc saw_init
  dir=$(make_case arm-hup-survives)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP survival check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || fail "arm did not record a watcher lock pid"
  # The watcher's parent is the detach launcher, never the arm.
  launcher=$(ps -o ppid= -p "$lock_pid" 2>/dev/null | tr -d ' ')
  [ -n "$launcher" ] || fail "watcher has no parent to identify the detach launcher"
  [ "$launcher" != "$armpid" ] || fail "watcher is still a direct child of the arm (ppid $launcher)"
  # The launch also gets its own session, so no process-group- or session-scoped
  # signal aimed at the arm can reach it either.
  wsess=$(ps -o sess= -p "$lock_pid" 2>/dev/null | tr -d ' ')
  armsess=$(ps -o sess= -p "$armpid" 2>/dev/null | tr -d ' ')
  [ -n "$wsess" ] && [ -n "$armsess" ] || fail "could not read the watcher and arm sessions"
  [ "$wsess" != "$armsess" ] || fail "watcher shares the arm's session (sess '$wsess')"
  # Nothing in the launch may appear anywhere in the arm's descendant set. Sampled
  # while the arm is still alive, because that is when a harness would walk it.
  desc=$(pid_descendants "$armpid")
  for p in $desc; do
    [ "$p" != "$lock_pid" ] || fail "watcher $p is a descendant of the arm $armpid"
    [ "$p" != "$launcher" ] || fail "detach launcher $p is a descendant of the arm $armpid"
  done
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  # PROMPTLY 129: the arm is the harness-visible waiter, so a signalled arm has to
  # die and let the harness notify. A trap that only runs when the watcher finally
  # exits is the same as no trap - the signal that was supposed to release the arm
  # instead leaves it parked for the whole watcher cycle.
  reap_arm "$armpid" 100
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit 129 within 10s of HUP (got $status) - its HUP trap cannot run while it is parked in the detached-watcher poll"
  # Let the arm's death settle, then confirm the watcher is still alive.
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$lock_pid" || fail "HUP on the arm reaped the watcher (regression: the watcher must survive its launcher)"
  [ "$(ps -o ppid= -p "$lock_pid" 2>/dev/null | tr -d ' ')" != "$armpid" ] \
    || fail "watcher's parent is still the dead arm"
  # Its parent chain must climb to init (through the launcher and whatever adopted
  # it) without ever passing through the arm.
  saw_init=0
  anc=$(pid_ancestors "$lock_pid")
  for p in $anc; do
    [ "$p" != "$armpid" ] || fail "arm $armpid is still an ancestor of the surviving watcher"
    [ "$p" = 1 ] && saw_init=1
  done
  [ "$saw_init" -eq 1 ] || fail "surviving watcher's parent chain does not reach init (chain: $(echo "$anc" | tr '\n' ' '))"
  [ -z "$(launch_dirs "$state")" ] || fail "HUP left the arm temp capture dir behind: $(launch_dirs "$state")"
  # The surviving watcher and its launcher are now this test's to stop (the arm no
  # longer does).
  stop_detached_watcher "$lock_pid" "$launcher"
  pass "arm leaves a detached watcher running on HUP (not reachable from the arm's tree, temp capture dir cleaned)"
}

test_arm_group_kill_leaves_watcher_supervising() {
  # The detach contract's SECOND leg. Ancestry is what a process-tree stop follows,
  # but a signal aimed at the arm's whole PROCESS GROUP would reach an orphan that
  # still shared that group, so the launch is setsid'd into its own session and group
  # as well. That setsid is not redundant belt-and-braces, and this test exists so a
  # future cleanup cannot quietly drop it: an orphan in the killed group dies.
  # The arm itself is started through setsid here, purely so the negative signal
  # below can only ever reach the arm's own group - never this test's.
  local dir state fakebin armout armpid armpgid selfpgid watcher launcher wpgid beat_before after i
  dir=$(make_case arm-group-kill)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 setsid "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start a watcher: $(cat "$armout")"
  watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher" ] || fail "arm recorded no watcher lock pid"
  launcher=$(ps -o ppid= -p "$watcher" 2>/dev/null | tr -d ' ')
  beat_before=$(path_mtime "$state" "$state/.last-watcher-beat")
  [ -n "$beat_before" ] || fail "watcher wrote no liveness beacon"
  # A negative signal is destructive, so prove the target group before sending one:
  # it must be the arm's own group and it must NOT be this test's group.
  armpgid=$(ps -o pgid= -p "$armpid" 2>/dev/null | tr -d ' ')
  selfpgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  [ "$armpgid" = "$armpid" ] || fail "arm is not its own process-group leader (pgid '$armpgid'), refusing to group-kill"
  [ "$armpgid" != "$selfpgid" ] || fail "arm shares this test's process group, refusing to group-kill"
  wpgid=$(ps -o pgid= -p "$watcher" 2>/dev/null | tr -d ' ')
  [ "$wpgid" != "$armpgid" ] \
    || fail "watcher $watcher is in the arm's process group $armpgid - a group-scoped stop would reap it"
  kill -KILL "-$armpgid" 2>/dev/null || true
  reap_arm "$armpid" 50 >/dev/null 2>&1 || true
  is_live_non_zombie "$armpid" && fail "arm survived a SIGKILL to its own process group"
  is_live_non_zombie "$watcher" \
    || fail "a process-group kill on the arm reaped the watcher (regression: the launch must be setsid'd out of the arm's group)"
  after=$beat_before
  i=0
  while [ "$i" -lt 200 ]; do
    after=$(path_mtime "$state" "$state/.last-watcher-beat")
    [ -n "$after" ] && [ "$after" -gt "$beat_before" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  { [ -n "$after" ] && [ "$after" -gt "$beat_before" ]; } \
    || fail "liveness beacon stopped advancing after the group kill (was $beat_before, still $after)"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] \
    || fail "surviving watcher no longer holds the singleton lock with its own pid"
  stop_detached_watcher "$watcher" "$launcher"
  pass "a process-group kill on the arm leaves the watcher alive, beating, and holding the lock"
}

test_arm_tree_kill_leaves_watcher_supervising() {
  # The regression this pins is the measured bug (2026-07-30, Claude Code 2.1.220):
  # when the harness stops its own tracked background task it kills the launching
  # shell's process TREE by live parent links, so the previous own-session child died
  # with every stopped arm - dozens of watcher deaths in one session. A process-tree
  # kill aimed at the arm must now leave supervision completely untouched.
  local watcher launcher state armout beat_before after i line
  arm_then_tree_kill arm-tree-kill
  watcher=$ARMED_WATCHER
  launcher=$ARMED_LAUNCHER
  state=$ARMED_STATE
  armout=$ARMED_ARMOUT
  beat_before=$ARMED_BEAT
  # Let the kill settle before judging survival.
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$watcher" \
    || fail "a process-tree kill on the arm reaped the watcher (regression: the harness stopping its arm task must not take supervision down)"
  # Alive is not enough. Only an ADVANCING liveness beacon proves the watcher is
  # still running its cycle rather than sitting wedged or unparented mid-poll.
  after=$beat_before
  i=0
  while [ "$i" -lt 200 ]; do
    after=$(path_mtime "$state" "$state/.last-watcher-beat")
    [ -n "$after" ] && [ "$after" -gt "$beat_before" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  { [ -n "$after" ] && [ "$after" -gt "$beat_before" ]; } \
    || fail "liveness beacon stopped advancing after the tree kill (was $beat_before, still $after) - the watcher survived but is no longer supervising"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] \
    || fail "surviving watcher no longer holds the singleton lock with its own pid (lock '$(cat "$state/.watch.lock/pid" 2>/dev/null || true)', watcher '$watcher')"
  # The arm's whole captured stream must be status lines only. Firstmate reads this
  # merged stdout+stderr as the wake reason, so a stray shell diagnostic - e.g. a
  # redirection error from reading a pid file that has not landed yet - becomes a
  # fabricated wake.
  while read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      'watcher: started pid='*) ;;
      *) fail "arm printed a line that is not one of its status lines - firstmate reads this stream as a wake reason (got '$line')" ;;
    esac
  done < "$armout"
  stop_detached_watcher "$watcher" "$launcher"
  pass "a process-tree kill on the arm leaves the watcher alive, beating, and holding the lock"
}

test_rearm_after_tree_kill_attaches_to_surviving_watcher() {
  # The payoff of detaching: a stopped arm task now costs only a CHEAP re-arm. The
  # fresh arm must attach to the watcher that outlived the tree kill - same pid - and
  # must not fork a second watcher, disturb the lock, or exit early; it exits zero
  # only when that watcher's cycle actually ends, which is what makes the harness
  # notify fire at the right moment instead of as a false empty wake.
  local watcher launcher state armout fakebin before_dirs after_dirs armpid status i
  arm_then_tree_kill arm-rearm-after-tree-kill
  watcher=$ARMED_WATCHER
  launcher=$ARMED_LAUNCHER
  state=$ARMED_STATE
  fakebin="$ARMED_DIR/fakebin"
  armout="$ARMED_DIR/rearm.out"
  # The killed arm could not clean up its own capture dir, so the leftover is part of
  # the pre-state: what matters is that the re-arm adds NO new one, which is only
  # possible if it never forked a launch.
  before_dirs=$(launch_dirs "$state")
  PATH="$fakebin:$PATH" FM_HOME="$ARMED_DIR" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF "watcher: attached pid=$watcher" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$watcher" "$armout" \
    || fail "re-arm did not attach to the watcher that survived the tree kill: $(cat "$armout")"
  ! grep -qF 'watcher: started' "$armout" || fail "re-arm started a second watcher instead of attaching to the survivor"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "re-arm reported FAILED for a healthy surviving watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] || fail "re-arm disturbed the surviving watcher's lock"
  after_dirs=$(launch_dirs "$state")
  [ "$after_dirs" = "$before_dirs" ] \
    || fail "re-arm created a launch dir, so it forked a watcher instead of attaching cheaply (before '$before_dirs', after '$after_dirs')"
  is_live_non_zombie "$armpid" || fail "re-arm exited while the surviving watcher was still healthy"
  # Ending that watcher's cycle is what releases the attached arm, with exit 0.
  stop_detached_watcher "$watcher" "$launcher"
  reap_arm "$armpid" 100
  status=$?
  [ "$status" -eq 0 ] || fail "attached re-arm did not exit zero after the surviving watcher's cycle ended (status $status): $(cat "$armout")"
  pass "re-arm after a tree kill attaches to the surviving watcher without restarting supervision"
}

test_arm_prunes_only_dead_launch_dirs() {
  # A tree-killed arm cannot clean up its own capture dir, and a stopped arm task is
  # now an ordinary, frequent event, so the next arm sweeps the leftovers. It may
  # only remove what is PROVABLY finished: both recorded pids dead and the dir older
  # than the prune age. A dir whose watcher or launcher is still alive belongs to a
  # live cycle - possibly a concurrent arm's - and a young dir with no pid files yet
  # is an arm mid-launch, so removing either would sabotage real supervision.
  local dir state fakebin armout dead live_pid armpid lock_pid launcher i
  dir=$(make_case arm-prune-launch-dirs)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  dead=$(dead_pid)
  sleep 300 &
  live_pid=$!
  mkdir "$state/.watch-arm.deadold"
  printf '%s\n' "$dead" > "$state/.watch-arm.deadold/watcher.pid"
  printf '%s\n' "$dead" > "$state/.watch-arm.deadold/launcher.pid"
  mkdir "$state/.watch-arm.livewatcher"
  printf '%s\n' "$live_pid" > "$state/.watch-arm.livewatcher/watcher.pid"
  printf '%s\n' "$dead" > "$state/.watch-arm.livewatcher/launcher.pid"
  mkdir "$state/.watch-arm.livelauncher"
  printf '%s\n' "$dead" > "$state/.watch-arm.livelauncher/watcher.pid"
  printf '%s\n' "$live_pid" > "$state/.watch-arm.livelauncher/launcher.pid"
  # Backdate past the prune age only AFTER writing the pid files, because writing a
  # file bumps the directory mtime the age is read from.
  touch -t 200001010000 \
    "$state/.watch-arm.deadold" \
    "$state/.watch-arm.livewatcher" \
    "$state/.watch-arm.livelauncher"
  mkdir "$state/.watch-arm.freshnew"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start while pruning leftover launch dirs: $(cat "$armout")"
  [ ! -d "$state/.watch-arm.deadold" ] || fail "arm kept an aged launch dir whose watcher and launcher are both dead"
  [ -d "$state/.watch-arm.livewatcher" ] || fail "arm pruned a launch dir whose recorded watcher is still alive"
  [ -d "$state/.watch-arm.livelauncher" ] || fail "arm pruned a launch dir whose recorded launcher is still alive"
  [ -d "$state/.watch-arm.freshnew" ] || fail "arm pruned a launch dir younger than the prune age"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || fail "pruning arm recorded no watcher lock pid"
  launcher=$(ps -o ppid= -p "$lock_pid" 2>/dev/null | tr -d ' ')
  # End the watcher's cycle before reaping the arm: the arm only leaves its poll when
  # the watcher it launched is gone.
  stop_detached_watcher "$lock_pid" "$launcher"
  reap_arm "$armpid" 100 || true
  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  pass "arm prunes only launch dirs that are aged with both recorded pids dead"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  # An unregistered check is refused by the watcher, so bind it first.
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register the check fixture"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate arm wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer beater identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  (
    sleep 1
    touch "$state/.last-watcher-beat"
  ) &
  beater=$!
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=4 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$beater" 2>/dev/null || true
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies, the attached arm must exit 0 (same as pre-fork attach).
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after peer died (status $status): $(cat "$armout")"
  pass "arm attaches to a peer watcher after child stands down and exits when peer dies"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" >/dev/null || fail "arm did not print the FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_pid_identity_is_locale_invariant() {
  # The watcher records its process identity under one locale; arm/guard/turn-end
  # re-read it under the machine's ambient locale. ps's lstart date format follows
  # LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR) would differ only
  # in the date portion and reject a genuinely live watcher. The fix pins LC_ALL=C
  # inside fm_pid_identity, so its output must be byte-identical regardless of the
  # caller's exported LC_ALL/LC_TIME. That invariant holds on any host because the
  # pin is internal, so this stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live baseline via_lc_all via_lc_time
  sleep 300 &
  live=$!
  baseline=$(LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_reports_healthy_peer_without_attaching
test_watcher_self_evicts_on_lock_takeover
test_arm_attaches_and_waits_for_live_fresh_watcher
test_arm_starts_and_self_heals
test_arm_hup_leaves_detached_watcher_running
test_arm_tree_kill_leaves_watcher_supervising
test_arm_group_kill_leaves_watcher_supervising
test_rearm_after_tree_kill_attaches_to_surviving_watcher
test_arm_prunes_only_dead_launch_dirs
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
