#!/usr/bin/env bash
# tests/fm-supervision-selfsustaining.test.sh - supervision must stay live and
# stay honest without the agent remembering anything.
#
# These pin the 2026-07-30/31 silent-lapse incident (docs/turnend-guard.md). The
# fleet ran unsupervised for stretches of 15 minutes to 4.8 hours while every
# surface an agent could consult said it was fine. Three defects combined:
#
#   1. FALSE ALL-CLEAR. bin/fm-guard.sh answered watcher liveness from the beacon
#      age alone, so for the whole grace window after a watcher exited it printed
#      NOTHING - and an agent that ran it to verify a correct turn-end block read
#      that silence as proof supervision was healthy. Measured five times out of
#      five. This is the specific failure the suite exists to keep dead.
#   2. NO SELF-SUSTAINING LOOP. Only a re-arm restarted the watcher, so a missed
#      re-arm meant nothing was watching at all.
#   3. HALF A CONTRACT. Every guard checked whether a watcher was DETECTING and
#      none checked whether an arm was there to DELIVER.
#
# Grouped: PREDICATE (bin/fm-supervision-lib.sh), GUARD (bin/fm-guard.sh),
# TURN-END (bin/fm-turnend-guard.sh), RENEWAL (bin/fm-watch.sh, real processes).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
GUARD="$ROOT/bin/fm-guard.sh"

fm_test_tmproot TMP_ROOT fm-supervision-selfsustaining

# A home with one in-flight task, so every guard is in scope.
make_home() {  # <name>
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  fm_write_meta "$dir/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

# Pose a watcher that EXITED cleanly <age> seconds ago: beacon left behind, lock
# released. This is the ordinary post-wake shape and the exact state that used to
# read as healthy.
pose_exited_watcher() {  # <home> <beacon-age-seconds>
  local home=$1 age=$2
  rm -rf "$home/state/.watch.lock" "$home/state/.watch-waiter"
  touch -d "$age seconds ago" "$home/state/.last-watcher-beat" 2>/dev/null \
    || touch -A "-0000$(printf '%02d' "$age")" "$home/state/.last-watcher-beat"
}

# Pose a LIVE watcher: a real sleeper process recorded in the lock the way
# bin/fm-watch.sh records itself, with a fresh beacon.
# The recorded watcher-path must be the one the CALLER will resolve, because
# fm_watcher_healthy compares them: a home with its own bin/ (the turn-end cases)
# resolves its own copy, and recording the repo's path there would fail the
# identity match and mask the condition under test as a plain "no live watcher".
POSED_WATCHER_PID=
pose_live_watcher() {  # <home>
  local home=$1 lock="$1/state/.watch.lock" watch_path="$WATCH"
  [ -e "$home/bin/fm-watch.sh" ] && watch_path="$home/bin/fm-watch.sh"
  mkdir -p "$lock"
  sleep 120 &
  POSED_WATCHER_PID=$!
  printf '%s\n' "$POSED_WATCHER_PID" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$watch_path" > "$lock/watcher-path"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$POSED_WATCHER_PID" > "$lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

# Record a live arm as the home's waiter, using the production helper.
pose_live_waiter() {  # <home> <pid>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '. "$1"; fm_waiter_record "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$1/state" "$2" >/dev/null
}

run_guard() {  # <home>
  FM_ROOT_OVERRIDE="$TMP_ROOT/not-a-git-repo" FM_HOME="$1" "$GUARD" 2>&1
}

# --- PREDICATE: bin/fm-supervision-lib.sh ------------------------------------

test_predicate_beacon_alone_is_not_liveness() {
  local home out
  home=$(make_home predicate-beacon-not-liveness)
  pose_exited_watcher "$home" 60

  # With fm-wake-lib.sh available the predicate must answer from the LOCK.
  out=$(FM_HOME="$home" bash -c '
    . "$1"; . "$2"
    fm_supervision_status "$3" 300 "$4" "$5"
    printf "%s %s %s\n" "$FM_SUP_WATCHER_FRESH" "$FM_SUP_BEACON_FRESH" "$FM_SUP_LIVENESS_BASIS"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervision-lib.sh" "$home/state" "$WATCH" "$home")

  [ "$out" = "false true lock" ] \
    || fail "beacon-fresh + no live watcher must read as NOT live on the lock basis, got: $out"
  pass "predicate: a fresh beacon with no live watcher is not liveness (basis=lock)"
}

test_predicate_reports_a_degraded_basis() {
  local home out
  home=$(make_home predicate-degraded-basis)
  pose_exited_watcher "$home" 60

  # Without fm-wake-lib.sh the lock cannot be read. Falling back to the beacon is
  # allowed; passing that off as the strong answer is not.
  out=$(FM_HOME="$home" bash -c '
    . "$1"
    fm_supervision_status "$2" 300
    printf "%s %s\n" "$FM_SUP_WATCHER_FRESH" "$FM_SUP_LIVENESS_BASIS"
  ' _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state")

  [ "$out" = "true beacon" ] \
    || fail "degraded answer must declare basis=beacon, got: $out"
  pass "predicate: a beacon-only answer declares its weaker basis"
}

test_predicate_tracks_the_waiter() {
  local home out
  home=$(make_home predicate-waiter)
  pose_live_watcher "$home"

  out=$(FM_HOME="$home" bash -c '
    . "$1"; . "$2"
    fm_supervision_status "$3" 300 "$4" "$5"
    printf "%s\n" "$FM_SUP_WAITER_ALIVE"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervision-lib.sh" "$home/state" "$WATCH" "$home")
  [ "$out" = false ] || fail "no waiter recorded must read false, got: $out"

  pose_live_waiter "$home" "$$"
  out=$(FM_HOME="$home" bash -c '
    . "$1"; . "$2"
    fm_supervision_status "$3" 300 "$4" "$5"
    printf "%s\n" "$FM_SUP_WAITER_ALIVE"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervision-lib.sh" "$home/state" "$WATCH" "$home")
  [ "$out" = true ] || fail "a live recorded waiter must read true, got: $out"

  kill "$POSED_WATCHER_PID" 2>/dev/null || true
  pass "predicate: FM_SUP_WAITER_ALIVE tracks the recorded arm"
}

test_dead_waiter_pid_does_not_pass() {
  local home dead out
  home=$(make_home predicate-dead-waiter)
  pose_live_watcher "$home"
  # A pid that is definitely gone: start one and reap it.
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  pose_live_waiter "$home" "$dead"

  out=$(FM_HOME="$home" bash -c '
    . "$1"; . "$2"
    fm_supervision_status "$3" 300 "$4" "$5"
    printf "%s\n" "$FM_SUP_WAITER_ALIVE"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervision-lib.sh" "$home/state" "$WATCH" "$home")
  [ "$out" = false ] || fail "a dead waiter pid must not read as alive, got: $out"
  kill "$POSED_WATCHER_PID" 2>/dev/null || true
  pass "predicate: an arm killed without cleanup does not pass as a live waiter"
}

# --- GUARD: bin/fm-guard.sh --------------------------------------------------

# THE REGRESSION TEST. This is the precise state that produced all five measured
# lapses: a watcher gone, a beacon still inside the grace window, work in flight,
# and an agent asking this script whether supervision is healthy.
test_guard_is_never_silent_in_the_handoff_window() {
  local home out
  home=$(make_home guard-handoff-window)
  pose_exited_watcher "$home" 60

  out=$(run_guard "$home")

  [ -n "$out" ] \
    || fail "SILENT ALL-CLEAR REGRESSION: fm-guard.sh printed nothing while no watcher was running (beacon 60s, 1 task in flight). This exact silence cost 15min-4.8h of unsupervised fleet, five times."
  case "$out" in
    *"WATCHER DOWN"*) ;;
    *) fail "handoff-window warning must name the condition, got: $out" ;;
  esac
  case "$out" in
    *"NOT an all-clear"*) ;;
    *) fail "handoff-window warning must refuse to read as an all-clear, got: $out" ;;
  esac
  case "$out" in
    *"fm-watch-arm.sh"*) ;;
    *) fail "handoff-window warning must name the repair, got: $out" ;;
  esac
  pass "guard: the wake-handoff window warns instead of falling silent"
}

test_guard_still_escalates_past_grace() {
  local home out
  home=$(make_home guard-past-grace)
  pose_exited_watcher "$home" 900

  out=$(run_guard "$home")
  case "$out" in
    *"WATCHER DOWN - SUPERVISION IS OFF"*) ;;
    *) fail "a watcher gone past grace must still get the full banner, got: $out" ;;
  esac
  pass "guard: a lapse past the grace window still gets the full banner"
}

test_guard_silent_only_when_supervision_is_whole() {
  local home out
  home=$(make_home guard-healthy-silent)
  pose_live_watcher "$home"
  pose_live_waiter "$home" "$$"

  out=$(run_guard "$home")
  kill "$POSED_WATCHER_PID" 2>/dev/null || true

  [ -z "$out" ] || fail "a live watcher WITH a live waiter must stay silent, got: $out"
  pass "guard: silence is reserved for a watcher and a waiter both alive"
}

# The MISSING-ARM case is deliberately turn-end only, and this pins that split.
# fm-guard.sh runs from the wake drain at the top of every wake-handling turn,
# where the arm has necessarily just exited and the re-arm is seconds away, so
# warning here would fire on every wake and train the reader to skip the guard -
# rebuilding the ignorable-alarm failure this change exists to remove.
test_guard_leaves_the_missing_arm_to_turn_end() {
  local home out
  home=$(make_home guard-unattended)
  pose_live_watcher "$home"

  out=$(run_guard "$home")
  kill "$POSED_WATCHER_PID" 2>/dev/null || true

  [ -z "$out" ] \
    || fail "the pull guard must not warn about a missing arm on every wake drain (turn-end owns it), got: $out"
  pass "guard: a mid-turn missing arm is left to the turn-end guard, not warned every wake"
}

# --- TURN-END: bin/fm-turnend-guard.sh ---------------------------------------

# The turn-end guard only runs inside a real primary checkout, so give it one.
make_turnend_home() {  # <name>
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  git init -q "$dir" 2>/dev/null
  printf '# firstmate\n' > "$dir/AGENTS.md"
  for f in fm-wake-lib.sh fm-supervision-lib.sh fm-supervision-instructions.sh fm-turnend-guard.sh fm-watch.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-supervision-instructions.sh"
  fm_write_meta "$dir/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

# FM_ROOT_OVERRIDE must name THIS home: wake-helpers.sh exports one pointing at a
# throwaway non-git dir (to keep the tangle check inert), and the turn-end guard
# scopes itself off FM_ROOT - so leaving that in place makes it a silent no-op and
# every assertion below passes vacuously.
run_turnend() {  # <home>
  printf '{"stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$1/bin/fm-turnend-guard.sh" 2>&1
}

test_turnend_blocks_a_live_but_unattended_watcher() {
  local home out rc
  home=$(make_turnend_home turnend-unattended)
  pose_live_watcher "$home"

  out=$(run_turnend "$home") && rc=0 || rc=$?
  kill "$POSED_WATCHER_PID" 2>/dev/null || true

  [ "$rc" -eq 2 ] || fail "a turn ending with no arm waiting must block (exit 2), got rc=$rc: $out"
  case "$out" in
    *"reaches nobody"*) ;;
    *) fail "block reason must say the wake reaches nobody, got: $out" ;;
  esac
  pass "turn-end: blocks when a live watcher has no arm to deliver its wakes"
}

test_turnend_blocks_on_undrained_wakes() {
  local home out rc
  home=$(make_turnend_home turnend-queued)
  pose_live_watcher "$home"
  pose_live_waiter "$home" "$$"
  append_wake "$home/state" signal task.status "signal: $home/state/task.status"

  out=$(run_turnend "$home") && rc=0 || rc=$?
  kill "$POSED_WATCHER_PID" 2>/dev/null || true

  [ "$rc" -eq 2 ] || fail "a turn ending on an undrained wake must block (exit 2), got rc=$rc: $out"
  case "$out" in
    *"queued and undrained"*) ;;
    *) fail "block reason must name the undrained queue, got: $out" ;;
  esac
  pass "turn-end: blocks on a wake already queued and unhandled"
}

test_turnend_allows_a_whole_supervision_contract() {
  local home out rc
  home=$(make_turnend_home turnend-healthy)
  pose_live_watcher "$home"
  pose_live_waiter "$home" "$$"

  out=$(run_turnend "$home") && rc=0 || rc=$?
  kill "$POSED_WATCHER_PID" 2>/dev/null || true

  [ "$rc" -eq 0 ] || fail "watcher live + waiter live + queue empty must allow the stop, got rc=$rc: $out"
  [ -z "$out" ] || fail "a healthy turn end must be silent, got: $out"
  pass "turn-end: allows the stop when detection, delivery, and the queue are all clear"
}

# --- RENEWAL: bin/fm-watch.sh, real processes --------------------------------

# Run a real watcher against a hermetic home and wait for it to exit on a wake.
# Returns the pid recorded in the lock once it is up.
# Results are assigned to RENEW_* directly, NEVER echoed for a caller to capture:
# `first=$(start_watcher ...)` would run the whole helper in a throwaway subshell,
# so RENEW_STATE would come back empty in the parent and every later step would
# operate on "/..." paths. tests/lib.sh records the same trap behind the
# 2026-07-16 /tmp-exhaustion incident.
RENEW_HOME=
RENEW_STATE=
RENEW_OUT=
RENEW_PID=
start_watcher() {  # <case-name> [extra env assignments...]
  local name=$1; shift
  local i=0
  RENEW_HOME=$(make_case "$name")
  RENEW_STATE="$RENEW_HOME/state"
  RENEW_OUT="$RENEW_HOME/watch.out"
  RENEW_PID=
  fm_write_meta "$RENEW_STATE/task.meta" "window=firstmate:fm-task" "kind=ship"
  # FM_POLL=1 for a prompt cycle; every other cadence pinned off so only the
  # signal under test can wake it.
  env PATH="$RENEW_HOME/fakebin:$PATH" FM_HOME="$RENEW_HOME" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    "$WATCH" > "$RENEW_OUT" 2>&1 &
  while [ "$i" -lt 100 ]; do
    [ -s "$RENEW_STATE/.watch.lock/pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  RENEW_PID=$(cat "$RENEW_STATE/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$RENEW_PID" ] || fail "watcher did not start for $name: $(cat "$RENEW_OUT" 2>/dev/null)"
}

# Fire an actionable signal the watcher must surface.
fire_signal() {  # <state>
  printf 'blocked: needs a decision\n' >> "$1/task.status"
}

# Wait until the lock names a live pid other than <old>, or time out.
await_successor() {  # <state> <old-pid> <tenths>
  local state=$1 old=$2 limit=$3 i=0 pid
  while [ "$i" -lt "$limit" ]; do
    pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && [ "$pid" != "$old" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# THE STRUCTURAL TEST. Nothing re-arms here - no arm exists at all. If the loop
# still depends on someone remembering to restart it, this fails.
test_watcher_hands_off_to_a_successor() {
  local first successor
  start_watcher renew-handoff FM_WATCH_RENEW=1
  first=$RENEW_PID
  fire_signal "$RENEW_STATE"

  successor=$(await_successor "$RENEW_STATE" "$first" 200) \
    || fail "NO SUCCESSOR: the watcher exited on a wake and nothing replaced it, so supervision again depends on an agent re-arming. Output: $(cat "$RENEW_OUT")"

  kill -0 "$first" 2>/dev/null \
    && fail "the original watcher must be gone after handing off (would be two watchers)"
  grep -q '^signal:' "$RENEW_OUT" \
    || fail "the wake reason must still be printed for the arm to deliver: $(cat "$RENEW_OUT")"

  kill -TERM "$successor" 2>/dev/null || true
  pass "renewal: an actionable wake hands the singleton to a live successor, with no re-arm"
}

test_successor_owns_the_lock_alone() {
  local first successor holder
  start_watcher renew-singleton FM_WATCH_RENEW=1
  first=$RENEW_PID
  fire_signal "$RENEW_STATE"
  successor=$(await_successor "$RENEW_STATE" "$first" 200) || fail "no successor appeared"

  holder=$(cat "$RENEW_STATE/.watch.lock/pid")
  [ "$holder" = "$successor" ] || fail "lock must name the successor, names $holder"
  FM_HOME="$RENEW_HOME" bash -c '
    . "$1"
    fm_watcher_healthy "$2" "$3" 300 "$4"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$RENEW_STATE" "$WATCH" "$RENEW_HOME" \
    || fail "the successor must satisfy the production liveness check"

  kill -TERM "$successor" 2>/dev/null || true
  pass "renewal: the successor holds the singleton lock cleanly and reads as healthy"
}

# Away mode is non-negotiable: the daemon owns triage and needs a one-shot watcher.
test_no_renewal_under_away_mode() {
  local first pid
  start_watcher renew-afk FM_WATCH_RENEW=1
  first=$RENEW_PID
  : > "$RENEW_STATE/.afk"
  fire_signal "$RENEW_STATE"

  # Let the watcher exit, then confirm nothing took its place.
  local i=0
  while [ "$i" -lt 100 ] && kill -0 "$first" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$first" 2>/dev/null && fail "watcher did not exit on its wake under afk"
  sleep 1
  pid=$(cat "$RENEW_STATE/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "AWAY-MODE VIOLATION: a successor was spawned while state/.afk exists; the daemon owns triage and the watcher must stay one-shot"
  fi
  pass "renewal: away mode keeps the watcher strictly one-shot"
}

# Renewal is OPT-IN, and this is why: bin/fm-watch-checkpoint.sh (codex) runs the
# watcher in the foreground and runs it again next checkpoint, and
# bin/fm-supervise-daemon.sh re-runs it per wake. A successor left behind by an
# un-opted-in run would hold the singleton, so their next run would report
# "already running" and return no wake - supervision silently dead for that
# harness. Only bin/fm-watch-arm.sh opts in, because only an arm gives a later
# re-arm something to attach to.
test_no_renewal_unless_opted_in() {
  local first pid out
  start_watcher renew-default-off
  first=$RENEW_PID
  fire_signal "$RENEW_STATE"
  local i=0
  while [ "$i" -lt 100 ] && kill -0 "$first" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  sleep 1
  pid=$(cat "$RENEW_STATE/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "ONE-SHOT BROKEN: a watcher nobody opted in renewed anyway. The next foreground checkpoint would find the singleton held and return no wake."
  fi

  # And a second run in the same home must behave like a first run, which is
  # exactly what the checkpoint and daemon loops depend on.
  out=$(env PATH="$RENEW_HOME/fakebin:$PATH" FM_HOME="$RENEW_HOME" FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 20 "$WATCH" 2>&1)
  case "$out" in
    *"already running"*) fail "a second one-shot run hit a leftover singleton: $out" ;;
  esac
  pass "renewal: off unless opted in, so foreground checkpoint and daemon loops stay one-shot"
}

test_arm_opts_the_watcher_in() {
  grep -q 'export FM_WATCH_RENEW=' "$ROOT/bin/fm-watch-arm.sh" \
    || fail "bin/fm-watch-arm.sh must opt its watcher into renewal; without it supervision is back to depending on the agent"
  pass "renewal: the arm is what opts its watcher in"
}

# A wake that re-fires instantly would make renewal a fork bomb. The budget stops
# it - and stopping SILENTLY would rebuild the very failure this change is for, so
# the refusal has to be loud.
test_rapid_cycle_budget_refuses_loudly() {
  local first pid i=0
  # MAX_RAPID=1 means the first sub-MIN_CYCLE cycle spends the budget outright.
  start_watcher renew-budget FM_WATCH_RENEW=1 FM_WATCH_RENEW_MIN_CYCLE=9999 FM_WATCH_RENEW_MAX_RAPID=1
  first=$RENEW_PID
  fire_signal "$RENEW_STATE"
  while [ "$i" -lt 100 ] && kill -0 "$first" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done

  grep -q 'SELF-RENEWAL DISABLED' "$RENEW_OUT" \
    || fail "SILENT GIVE-UP: the rapid-cycle budget stopped renewal without saying so. Output: $(cat "$RENEW_OUT")"
  grep -q 'REFUSED self-renewal' "$RENEW_STATE/.watch-triage.log" \
    || fail "a refusal must also be recorded in the triage log"

  sleep 1
  pid=$(cat "$RENEW_STATE/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "a spent budget must actually stop renewing"
  fi
  pass "renewal: a spent rapid-cycle budget refuses loudly, never silently"
}

# Renewal must not swallow the wake it was spawned around: an arm attached to a
# watcher that hands off has to EXIT so the harness notification fires.
test_attached_arm_exits_when_its_watcher_hands_off() {
  local first successor armpid rc
  start_watcher renew-attach FM_WATCH_RENEW=1
  first=$RENEW_PID

  # Attach a real arm to the running watcher.
  FM_HOME="$RENEW_HOME" "$ROOT/bin/fm-watch-arm.sh" > "$RENEW_HOME/arm.out" 2>&1 &
  armpid=$!
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -q 'watcher: attached' "$RENEW_HOME/arm.out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -q 'watcher: attached' "$RENEW_HOME/arm.out" \
    || { kill -KILL "$armpid" 2>/dev/null; fail "arm did not attach: $(cat "$RENEW_HOME/arm.out")"; }

  fire_signal "$RENEW_STATE"
  successor=$(await_successor "$RENEW_STATE" "$first" 200) || successor=

  i=0
  while [ "$i" -lt 150 ] && kill -0 "$armpid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$armpid" 2>/dev/null; then
    kill -KILL "$armpid" 2>/dev/null || true
    [ -n "$successor" ] && kill -TERM "$successor" 2>/dev/null
    fail "SWALLOWED WAKE: the attached arm re-attached to the successor instead of exiting, so the harness was never notified. An arm that never exits looks perfectly healthy while every wake goes undelivered."
  fi
  wait "$armpid" 2>/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "an attached arm whose cycle ended must exit 0, got $rc"

  [ -n "$successor" ] && kill -TERM "$successor" 2>/dev/null
  pass "renewal: an attached arm exits on handoff so the wake is still delivered"
}

test_predicate_beacon_alone_is_not_liveness
test_predicate_reports_a_degraded_basis
test_predicate_tracks_the_waiter
test_dead_waiter_pid_does_not_pass
test_guard_is_never_silent_in_the_handoff_window
test_guard_still_escalates_past_grace
test_guard_silent_only_when_supervision_is_whole
test_guard_leaves_the_missing_arm_to_turn_end
test_turnend_blocks_a_live_but_unattended_watcher
test_turnend_blocks_on_undrained_wakes
test_turnend_allows_a_whole_supervision_contract
test_watcher_hands_off_to_a_successor
test_successor_owns_the_lock_alone
test_no_renewal_under_away_mode
test_no_renewal_unless_opted_in
test_arm_opts_the_watcher_in
test_rapid_cycle_budget_refuses_loudly
test_attached_arm_exits_when_its_watcher_hands_off
