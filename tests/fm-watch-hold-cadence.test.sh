#!/usr/bin/env bash
# tests/fm-watch-hold-cadence.test.sh - the BOUNDED HOLD CADENCE in bin/fm-watch.sh.
#
# A crew that is idle ON PURPOSE - because what it waits on is already tracked
# somewhere firstmate looks - must not re-wake the supervisor on the ordinary stale
# interval. bin/fm-watch.sh's header names the three holds that earn that: a
# declared external-wait pause (paused:), a durable captain-held transfer
# (captain-held:), and a crew parked awaiting merge (reconciled done plus a
# REGISTERED merge monitor). All three share one cadence, PAUSE_RESURFACE_SECS.
#
# These cases drive a real fm-watch.sh subprocess and assert the two halves that
# make the absorb safe rather than merely quiet:
#   - a hold is ABSORBED on the ordinary stale interval, arms no wedge timer, and
#     survives the churny/unchanged-hash repeats that used to re-decide it;
#   - a hold still RE-SURFACES once past the bounded window, and a crew that stops
#     being held (busy pane, verb moved off the hold) instantly returns to full
#     stale sensitivity and wedge-escalates like any working crew.
#
# The pure classifier predicates behind them (status_is_paused_or_captain_held,
# crew_is_parked_awaiting_merge and its registration gate) live in
# tests/fm-watch-triage.test.sh; the away-mode daemon's side of the shared
# classifier lives in tests/fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

fm_test_tmproot TMP_ROOT fm-watch-hold-cadence-tests

wait_live() {  # 0 if <pid> is still alive after <limit> 0.1s ticks
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

backdate() {  # <file> <seconds-ago>
  local f=$1 secs=$2 back
  back=$(( $(date +%s) - secs ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$f"
  else touch -m -d "@$back" "$f"; fi
}

# run_watch <state> <fakebin> <window> <capture-file> <out> [NAME=VALUE...]
# Starts a real watcher against a hermetic state dir and returns its pid in RUN_PID.
# Dispatched through `env` rather than a bare assignment prefix: a shell applies an
# assignment prefix only to LITERAL NAME=VALUE tokens, so a per-case knob arriving
# through "$@" would be parsed as the command name instead of an assignment.
run_watch() {
  local state=$1 fakebin=$2 window=$3 capture=$4 out=$5
  shift 5
  env PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$out" &
  RUN_PID=$!
}

# --- captain-held: the durable transfer reaches the TERMINAL stale branch -------
# A crew whose open decision moved to a captain-held backlog item ends its log
#   needs-decision [key=...]: ...
#   captain-held  [key=...]: tracked by <hold-id>
# The transfer line is BOOKKEEPING, so the terminal reader looks past it to the
# needs-decision: underneath and this lands on the stale seam's TERMINAL branch -
# NOT the non-terminal one the upstream port placed its captain-held handling on.
# Without handling it there, every fresh idle-pane hash re-surfaced the same
# already-tracked decision on the ordinary stale interval.
test_captain_held_stale_uses_bounded_cadence() {
  local dir state fakebin out drain_out capture window key statusf sig
  dir=$(make_case captain-held-bounded); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture="$dir/pane.txt"
  window="test:fm-held-scout"
  statusf="$state/held-scout.status"
  printf 'idle, decision handed to the captain' > "$capture"
  printf 'window=%s\nkind=scout\n' "$window" > "$state/held-scout.meta"
  printf 'needs-decision [key=route]: north or south\ncaptain-held [key=route]: tracked by held-scout-decision-route\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "idle, decision handed to the captain")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # fm-crew-state reads PAST the bookkeeping line, so a captain-held crew reconciles
  # to its revealed verb - `parked`, never `paused`. That is exactly the verdict that
  # used to fall through to a surface.
  export FM_FAKE_CREW_STATE='state: parked · source: status-log · north or south'

  # Phase A: a fresh transfer under a high re-surface threshold is ABSORBED, with no
  # wedge timer - the decision is already tracked by its captain-held backlog item.
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_PAUSE_RESURFACE_SECS=999
  if ! wait_live "$RUN_PID" 30; then
    reap "$RUN_PID"; fail "watcher exited for a fresh captain-held transfer (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a captain-held crew printed a wake reason during absorb: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a captain-held crew enqueued a wake during absorb"
  [ -e "$state/.paused-$key" ] || fail "the captain-held hold marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a captain-held absorb must not arm the wedge timer"
  reap "$RUN_PID"

  # Phase B: age the transfer past the bounded window; it re-surfaces ONCE as a hold
  # recheck, never as a possible wedge.
  backdate "$statusf" 500
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-scout_status"
  : > "$out"
  printf 'idle, decision handed to the captain (redraw 2)' > "$capture"
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_PAUSE_RESURFACE_SECS=240
  wait_for_exit "$RUN_PID" 40 || fail "a captain-held crew did not re-surface past the bounded window"
  grep -F "stale: $window" "$out" >/dev/null || fail "the captain-held recheck printed no stale wake: $(cat "$out")"
  grep -F "declared hold" "$out" >/dev/null || fail "the captain-held recheck was not labeled a declared hold: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a captain-held crew was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the captain-held re-surface throttle was not recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the captain-held recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the captain-held recheck was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a captain-held crew is absorbed on the terminal stale branch and rechecked on the bounded cadence, never wedged"
}

# --- parked awaiting merge: absorbed, and BOUNDED rather than silent forever ----
# The live 2026-07-27 case: a crew that had finished and pushed its PR re-waked the
# supervisor on the ordinary stale interval while it waited for the captain's merge
# word, and the only way to quiet it was to hand-steer a paused: line into its log.
# A parked crew now shares the declared-hold cadence: absorbed between rechecks, and
# re-surfaced once per window so a PR whose merge word never comes cannot sit
# unwatched forever (the previous behavior absorbed it with no re-surface at all).
test_parked_awaiting_merge_resurfaces_on_bounded_cadence() {
  local dir state fakebin out drain_out capture window key statusf sig
  dir=$(make_case parked-bounded); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture="$dir/pane.txt"
  window="test:fm-parked-b"
  statusf="$state/parked-b.status"
  printf 'PR open, awaiting the merge word' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked-b.meta"
  printf 'done: PR https://example.test/pr/21\n' > "$statusf"
  arm_registered_check "$state" parked-b
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked-b_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "PR open, awaiting the merge word")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: status-log · done: PR https://example.test/pr/21'

  # Phase A: fresh park under a high window -> absorbed, hold marker records the
  # PARKED kind, no wedge timer.
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_PAUSE_RESURFACE_SECS=999
  if ! wait_live "$RUN_PID" 30; then
    reap "$RUN_PID"; fail "watcher exited for a parked-awaiting-merge crew (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a parked crew printed a wake reason during absorb: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a parked crew enqueued a wake during absorb"
  [ "$(cat "$state/.paused-$key" 2>/dev/null || true)" = parked ] \
    || fail "the hold marker did not record the parked kind: $(cat "$state/.paused-$key" 2>/dev/null || true)"
  [ ! -e "$state/.stale-since-$key" ] || fail "a parked crew must not arm a wedge timer"
  reap "$RUN_PID"

  # Phase B: age the park past the bounded window -> exactly one recheck, worded as a
  # merge-monitor recheck rather than a wedge, so the absorb can never rot invisibly.
  backdate "$statusf" 500
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked-b_status"
  : > "$out"
  printf 'PR open, awaiting the merge word (redraw 2)' > "$capture"
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_PAUSE_RESURFACE_SECS=240
  wait_for_exit "$RUN_PID" 40 || fail "a parked crew never re-surfaced past the bounded window"
  grep -F "stale: $window" "$out" >/dev/null || fail "the parked recheck printed no stale wake: $(cat "$out")"
  grep -F "awaiting merge" "$out" >/dev/null || fail "the parked recheck was not labeled a merge recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a parked crew was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the parked re-surface throttle was not recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the parked recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the parked recheck was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a parked-awaiting-merge crew is absorbed and rechecked on the bounded cadence, never wedged"
}

# --- the churny idle pane: a hash that changes every poll ----------------------
# A redraw-jittered idle pane (a clock, a token counter) never produces two
# identical hashes, so it never reaches the stale triage at all - it lands on the
# CHANGED-hash route every poll. That route used to clear a parked crew's hold
# tracking each time, which is what made the absorb unable to hold across redraws.
test_parked_churny_pane_keeps_its_hold() {
  local dir state fakebin out capture window key statusf sig
  dir=$(make_case parked-churny); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-churny"
  statusf="$state/churny.status"
  printf 'PR open · 1 tokens' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/churny.meta"
  printf 'done: PR https://example.test/pr/33\n' > "$statusf"
  arm_registered_check "$state" churny
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-churny_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: done · source: status-log · done: PR https://example.test/pr/33'

  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_PAUSE_RESURFACE_SECS=999
  # Jitter the pane under the running watcher so every poll sees a brand-new hash.
  local i=0
  while [ "$i" -lt 12 ]; do
    printf 'PR open · %s tokens' "$i" > "$capture"
    sleep 0.3
    i=$((i + 1))
  done
  kill -0 "$RUN_PID" 2>/dev/null \
    || fail "the watcher exited for a churny parked idle pane (should absorb every redraw): $(cat "$out")"
  [ ! -s "$out" ] || fail "a churny parked pane printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a churny parked pane enqueued a wake"
  [ "$(cat "$state/.paused-$key" 2>/dev/null || true)" = parked ] \
    || fail "the parked hold was dropped by the changed-hash route"
  reap "$RUN_PID"
  unset FM_FAKE_CREW_STATE
  pass "a parked crew's redraw-jittered idle pane keeps its hold across changing hashes"
}

# --- a hold NEVER swallows a wedge --------------------------------------------
# The absorb is only ever granted while authoritative state agrees the crew is not
# working. A crew that WAS held and is then put back to work (busy pane) loses the
# hold on the spot, arms the ordinary wedge timer, and escalates past the threshold
# with the escalation count and the demand-deep-inspection marker intact - the
# safety property that separates a bounded cadence from a blind spot.
test_reactivated_held_crew_still_wedge_escalates() {
  local dir state fakebin out capture window key statusf sig
  dir=$(make_case held-reactivated); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-reheld"
  statusf="$state/reheld.status"
  printf 'back at work, frozen mid-edit' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/reheld.meta"
  printf 'done: PR https://example.test/pr/44\n' > "$statusf"
  arm_registered_check "$state" reheld
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-reheld_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "back at work, frozen mid-edit")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A leftover parked hold from the previous phase of this crew's life.
  printf 'parked' > "$state/.paused-$key"
  printf '%s' "$(hash_text "back at work, frozen mid-edit")" > "$state/.stale-$key"
  # Authoritative state now says WORKING (re-tasked, busy pane), which outranks the
  # hold. fm-crew-state is the single authority here, exactly as for every other
  # absorb decision.
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'

  # Phase A: the hold is dropped and the ordinary wedge timer is armed.
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_STALE_ESCALATE_SECS=999
  if ! wait_live "$RUN_PID" 30; then
    reap "$RUN_PID"; fail "watcher exited for a re-activated crew under a high wedge threshold: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || fail "a re-activated crew kept its stale hold marker"
  [ -s "$state/.stale-since-$key" ] || fail "a re-activated crew did not arm the ordinary wedge timer"
  reap "$RUN_PID"

  # Phase B: it genuinely wedges. Backdate the timer past the threshold and confirm
  # the ordinary escalation - count included - still fires.
  # The wedge timer stores its epoch as file CONTENT (wedge_timer_check reads it),
  # unlike the hold cadence which is anchored on the status file's mtime.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_STALE_ESCALATE_SECS=240
  wait_for_exit "$RUN_PID" 40 || fail "a re-activated, wedged crew did not escalate"
  grep -F "possible wedge" "$out" >/dev/null || fail "the wedge escalation lost its possible-wedge label: $(cat "$out")"
  grep -F "escalation 1" "$out" >/dev/null || fail "the wedge escalation lost its escalation count: $(cat "$out")"

  # Phase C: repeated escalations on the SAME pane still reach the
  # demand-deep-inspection marker, so a hold can never quietly disarm it.
  printf '2\n' > "$state/.wedge-escalations-$key"
  # The wedge timer stores its epoch as file CONTENT (wedge_timer_check reads it),
  # unlike the hold cadence which is anchored on the status file's mtime.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_STALE_ESCALATE_SECS=240 FM_WEDGE_DEMAND_INSPECT_COUNT=3
  wait_for_exit "$RUN_PID" 40 || fail "the repeated wedge escalation did not fire"
  grep -F "escalation 3" "$out" >/dev/null || fail "the escalation counter did not accumulate: $(cat "$out")"
  grep -F "demand-deep-inspection" "$out" >/dev/null \
    || fail "the demand-deep-inspection marker was lost at the threshold: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a re-activated crew loses its hold instantly and still wedge-escalates with count and demand-deep-inspection"
}

# --- an uncorroborated hold: ONE immediate look, then bounded ------------------
# A declared pause whose authoritative state will not corroborate it (fm-crew-state
# reports the crew stopped) is a deliberate fail-open: firstmate gets one immediate
# surface. What must NOT happen afterwards is the ordinary cadence - before this
# port the unchanged-hash repeat re-armed a wedge timer and escalated at
# STALE_ESCALATE_SECS. It now falls onto the bounded hold cadence instead.
test_uncorroborated_hold_surfaces_once_then_bounds() {
  local dir state fakebin out capture window key statusf sig
  dir=$(make_case hold-failopen); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-failopen"
  statusf="$state/failopen.status"
  printf 'idle at a decision gate' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/failopen.meta"
  printf 'paused: awaiting the vendor rate-limit reset\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-failopen_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "idle at a decision gate")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The declared pause is NOT corroborated: authoritative state says stopped.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Phase A: one immediate surface.
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_PAUSE_RESURFACE_SECS=999
  wait_for_exit "$RUN_PID" 40 || fail "an uncorroborated declared hold was not surfaced at all"
  grep -F "stale: $window" "$out" >/dev/null || fail "the fail-open surface printed no stale wake: $(cat "$out")"
  [ -e "$state/.paused-$key" ] || fail "the fail-open surface did not re-arm the hold markers"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the fail-open surface did not stamp the re-surface throttle"
  [ ! -e "$state/.stale-since-$key" ] || fail "the fail-open surface left a wedge timer armed"

  # Phase B: the SAME unchanged hash on the next poll must stay absorbed on the
  # bounded cadence - no second wake, and specifically no wedge timer to escalate.
  : > "$out"
  run_watch "$state" "$fakebin" "$window" "$capture" "$out" FM_PAUSE_RESURFACE_SECS=999 FM_STALE_ESCALATE_SECS=1
  if ! wait_live "$RUN_PID" 30; then
    reap "$RUN_PID"; fail "the unchanged hash re-surfaced instead of using the bounded cadence: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the unchanged uncorroborated hold woke firstmate again: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] || fail "the unchanged uncorroborated hold armed a wedge timer"
  reap "$RUN_PID"
  unset FM_FAKE_CREW_STATE
  pass "an uncorroborated declared hold surfaces once, then uses the bounded cadence instead of the wedge timer"
}

test_captain_held_stale_uses_bounded_cadence
test_parked_awaiting_merge_resurfaces_on_bounded_cadence
test_parked_churny_pane_keeps_its_hold
test_reactivated_held_crew_still_wedge_escalates
test_uncorroborated_hold_surfaces_once_then_bounds
