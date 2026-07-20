#!/usr/bin/env bash
# tests/fm-watch-capture-failure.test.sh - the watcher's endpoint-gone
# detection (D0) and the reporting surfaces' confirmed-vs-unconfirmed
# endpoint distinction (D4).
#
# WHY D0 EXISTS. bin/fm-watch.sh used to discard terminal-capture failures
# with a bare `|| continue`. Capture is the one signal that must reach a real
# terminal, so a failure is the CORRECT detection of a gone endpoint - and the
# watcher threw that answer away. A crew whose pane died in a herdr server
# restart (reboot, update, service restart) was therefore skipped on every
# poll forever: it never got a pane hash, so it never accumulated a stale
# count, so it never reached stale triage, so the watcher was structurally
# incapable of ever mentioning it again. The task stalled silently and
# permanently. capture_failure counts consecutive failures and surfaces one
# endpoint-gone wake at the threshold, while still swallowing a transient
# socket blip.
#
# WHY D4 EXISTS. The session-start digest, the fleet snapshot and the fleet
# view all reported endpoint PRESENCE as liveness. On a backend that replays a
# persisted session layout across a server restart (herdr), a crew whose
# process died still reports present, so a dead crew read `alive` in the
# startup digest and on every heartbeat. AGENTS.md section 5 tells firstmate
# to trust the digest and not re-derive from it, which makes a wrong digest
# load-bearing. These surfaces now qualify the claim with whatever
# process-level corroboration the backend can give, so they stop asserting
# more than they know.
#
# SCOPE NOTE: this branch carries D0 and D4 only. The composed liveness
# helpers and the D1/D2 husk-close and secondmate-kill fixes are PARKED on a
# separate branch and remain unfixed - see the PR body. Nothing here depends
# on them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fm_test_tmproot TMP_ROOT fm-watch-capture-failure

# --- D0: consecutive capture failures surface an endpoint-gone wake ---------
# Sources the real bin/fm-watch.sh: its source guard returns before the
# singleton lock and the blocking loop, so only the functions load (the same
# technique tests/fm-supervision-events.test.sh uses).

# run_capture_failures <n> -> echoes "WAKES=<count>" plus the wake reasons
run_capture_failures() {  # <consecutive failures>
  local dir state n=$1
  dir="$TMP_ROOT/d0-$n"
  state="$dir/state"
  mkdir -p "$state"
  : > "$dir/wakes.log"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
  FM_D0_WAKES="$dir/wakes.log" FM_D0_N="$n" \
    bash -c '
      set -u
      . "$1/bin/fm-watch.sh"
      FM_CAPTURE_FAIL_WAKE_COUNT=3
      triage_log() { :; }
      wake() { :; }
      fm_wake_append() { printf "%s\n" "$3" >> "$FM_D0_WAKES"; }
      i=0
      while [ "$i" -lt "$FM_D0_N" ]; do
        capture_failure "sess:p1" "sess_p1"
        i=$(( i + 1 ))
      done
    ' bash "$ROOT" >/dev/null 2>&1
  printf 'WAKES=%s\n' "$(wc -l < "$dir/wakes.log" | tr -d ' ')"
  cat "$dir/wakes.log"
}

test_d0_capture_failures_surface_a_wake() {
  local out

  out=$(run_capture_failures 1)
  case "$out" in
    "WAKES=0"*) : ;;
    *) fail "D0: a single capture failure must stay quiet (transient blip tolerance), got: $out" ;;
  esac

  out=$(run_capture_failures 2)
  case "$out" in
    "WAKES=0"*) : ;;
    *) fail "D0: two consecutive capture failures must still stay quiet, got: $out" ;;
  esac

  out=$(run_capture_failures 3)
  case "$out" in
    "WAKES=0"*) fail "D0 REGRESSION: three consecutive capture failures produced no wake - a crew whose endpoint is gone stays silently unsupervised forever" ;;
  esac
  case "$out" in
    *"backend target gone"*) : ;;
    *) fail "D0: the wake should carry fm-crew-state.sh's 'backend target gone' verdict, got: $out" ;;
  esac

  # Surfaced once per gone episode, not every poll.
  out=$(run_capture_failures 6)
  case "$out" in
    "WAKES=1"*) : ;;
    *) fail "D0: a gone endpoint should surface exactly one wake per episode, got: $out" ;;
  esac

  pass "D0: capture failures tolerate a blip, then surface one endpoint-gone wake"
}

test_d0_success_resets_the_episode() {
  # A blip that resolves must leave no trace, so a LATER real disappearance
  # surfaces fresh instead of being swallowed by the first episode's
  # already-surfaced marker.
  local dir state wakes count
  dir="$TMP_ROOT/d0-episodes"
  state="$dir/state"
  mkdir -p "$state"
  wakes="$dir/wakes.log"
  : > "$wakes"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_D0_WAKES="$wakes" \
    bash -c '
      set -u
      . "$1/bin/fm-watch.sh"
      FM_CAPTURE_FAIL_WAKE_COUNT=3
      triage_log() { :; }
      wake() { :; }
      fm_wake_append() { printf "%s\n" "$3" >> "$FM_D0_WAKES"; }
      fail3() { capture_failure "sess:p1" "sess_p1"; capture_failure "sess:p1" "sess_p1"; capture_failure "sess:p1" "sess_p1"; }
      fail3
      [ "$(wc -l < "$FM_D0_WAKES")" -eq 1 ] || { echo "episode 1 should wake once" >&2; exit 1; }
      # Exactly what the watcher does on a successful capture.
      rm -f "$STATE/.capfail-sess_p1" "$STATE/.capfail-surfaced-sess_p1"
      capture_failure "sess:p1" "sess_p1"
      capture_failure "sess:p1" "sess_p1"
      [ "$(wc -l < "$FM_D0_WAKES")" -eq 1 ] || { echo "two failures after a reset must stay quiet" >&2; exit 1; }
      capture_failure "sess:p1" "sess_p1"
      [ "$(wc -l < "$FM_D0_WAKES")" -eq 2 ] || { echo "a second gone episode must surface its own wake" >&2; exit 1; }
    ' bash "$ROOT" >/dev/null 2>&1 \
    || fail "D0: capture-failure episodes did not reset correctly across a successful capture"

  count=$(wc -l < "$wakes" | tr -d ' ')
  [ "$count" = 2 ] || fail "D0: expected two wakes across two gone episodes, got $count"

  # And the watcher itself must actually perform that reset on the success
  # path - the assertion above is only meaningful if it does.
  grep -q 'capfail-.key. ..STATE/.capfail-surfaced-' "$ROOT/bin/fm-watch.sh" \
    || fail "D0: bin/fm-watch.sh must clear both capfail markers on a successful capture"

  pass "D0: a successful capture resets the episode, so a later disappearance wakes again"
}

# --- D4: fm_backend_process_state, the corroboration primitive -------------

test_process_state_reports_unsupported_where_there_is_no_probe() {
  local out b
  # A backend with no verified process probe must say `unsupported`, NOT
  # `unknown`: callers distinguish "no corroboration available here" (nothing
  # to hedge about) from "corroboration attempted and inconclusive" (hedge).
  for b in tmux zellij orca cmux bogus; do
    out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_process_state "$1" sess:win' "$ROOT" "$b")
    [ "$out" = unsupported ] || fail "fm_backend_process_state should report unsupported for $b, got '$out'"
  done

  # An unparseable herdr target cannot be probed and must not masquerade as a
  # verdict either way.
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_process_state herdr no-colon-target' "$ROOT")
  [ "$out" = unknown ] || fail "an unparseable herdr target should report unknown, got '$out'"

  pass "fm_backend_process_state: unsupported where no probe exists, unknown for an unreadable target"
}

test_process_state_dispatches_to_herdr() {
  local out
  out=$(bash -c 'ROOT_DIR=$0; VERDICT=$1
    . "$ROOT_DIR/bin/fm-backend.sh"
    fm_backend_source herdr
    fm_backend_herdr_pane_process_state() { printf "%s" "$VERDICT"; }
    fm_backend_process_state herdr sess:p1' "$ROOT" live)
  [ "$out" = live ] || fail "fm_backend_process_state should route herdr to the pane process probe, got '$out'"

  out=$(bash -c 'ROOT_DIR=$0; VERDICT=$1
    . "$ROOT_DIR/bin/fm-backend.sh"
    fm_backend_source herdr
    fm_backend_herdr_pane_process_state() { printf "%s" "$VERDICT"; }
    fm_backend_process_state herdr sess:p1' "$ROOT" dead)
  [ "$out" = dead ] || fail "fm_backend_process_state should pass through the herdr dead verdict, got '$out'"

  pass "fm_backend_process_state: routes herdr to fm_backend_herdr_pane_process_state"
}

# --- D4: the fleet view stops rendering presence as health -----------------
# fm-fleet-view.sh shells out to fm-fleet-snapshot.sh, so a stub snapshot in a
# copied SCRIPT_DIR drives the renderer against exact endpoint shapes.

render_view() {  # <endpoint json> -> echoes the rendered view
  local dir=$1 endpoint=$2 bin
  bin="$dir/bin"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-fleet-view.sh" "$bin/"
  cat > "$bin/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{"generated_at":"2026-07-20T00:00:00Z","home":"/tmp/home","tasks":[
 {"id":"t1","kind":"crew","harness":"claude","mode":"ship","yolo":"","project":"p","backend":"herdr",
  "paths":{"meta":{"path":"/tmp/m","present":true},"status_log":{"path":"/tmp/s","present":true,"last_event":null},
           "worktree":{"path":null,"present":false},"home":{"path":null,"present":false},"report":{"path":null,"present":false}},
  "secondmate_projects":[],
  "current_state":{"state":"working","source":"pane","detail":"","observed_at":"x","freshness":"fresh"},
  "endpoint":$endpoint,
  "pr":{"url":null,"source":""},
  "hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[],"scout_report_present":false,"last_event_text":""},
  "actions":{"watch":"bin/fm-peek.sh fm-t1","steer":"bin/fm-send.sh fm-t1 '<instruction>'","return_channel_note":null}}],
 "scout_reports":[],"secondmate_current":{"records":[],"total":0,"shown":0,"truncated":false},
 "secondmate_landed":{"records":[],"truncated":[],"unreadable":[]},"secondmate_guidance":""}
JSON
SH
  chmod +x "$bin/fm-fleet-snapshot.sh"
  bash "$bin/fm-fleet-view.sh" 2>&1
}

test_d4_view_distinguishes_confirmed_from_unconfirmed() {
  local out d
  d="$TMP_ROOT/view"; mkdir -p "$d"

  # A replayed ghost: the record is present, no process is behind it. This is
  # the case that used to render a bare "present" and let a dead crew look
  # healthy on every heartbeat.
  out=$(render_view "$d/ghost" '{"target":"sess:p1","exists":true,"agent_alive":"not_checked","process_state":"dead","status":"absent","observed_at":"x","freshness":"fresh"}')
  case "$out" in
    *ghost*) : ;;
    *) fail "D4 REGRESSION: an endpoint with no process behind it must not render as plainly present; got: $out" ;;
  esac

  # A process-confirmed endpoint says so.
  out=$(render_view "$d/live" '{"target":"sess:p1","exists":true,"agent_alive":"not_checked","process_state":"live","status":"unknown","observed_at":"x","freshness":"fresh"}')
  case "$out" in
    *process-confirmed*) : ;;
    *) fail "D4: a process-confirmed endpoint should say so; got: $out" ;;
  esac

  # Corroboration attempted, inconclusive: hedged, not asserted.
  out=$(render_view "$d/unk" '{"target":"sess:p1","exists":true,"agent_alive":"not_checked","process_state":"unknown","status":"unknown","observed_at":"x","freshness":"fresh"}')
  case "$out" in
    *"present?"*) : ;;
    *) fail "D4: an inconclusive corroboration should render hedged, not asserted; got: $out" ;;
  esac

  # No probe for this backend: nothing is being hidden, so no hedge.
  out=$(render_view "$d/unsup" '{"target":"sess:win","exists":true,"agent_alive":"not_checked","process_state":"unsupported","status":"unknown","observed_at":"x","freshness":"fresh"}')
  case "$out" in
    *"present?"*|*ghost*) fail "D4: a backend with no process probe should render a plain present, not a hedge; got: $out" ;;
    *present*) : ;;
    *) fail "D4: expected a plain present for an unsupported-probe backend; got: $out" ;;
  esac

  # A genuinely absent endpoint still reads absent.
  out=$(render_view "$d/absent" '{"target":"sess:p1","exists":false,"agent_alive":"not_checked","process_state":"dead","status":"absent","observed_at":"x","freshness":"fresh"}')
  case "$out" in
    *absent*) : ;;
    *) fail "D4: an absent endpoint must still render absent; got: $out" ;;
  esac

  pass "D4: the fleet view distinguishes process-confirmed, ghost, hedged and no-probe endpoints"
}

test_d0_capture_failures_surface_a_wake
test_d0_success_resets_the_episode
test_process_state_reports_unsupported_where_there_is_no_probe
test_process_state_dispatches_to_herdr
test_d4_view_distinguishes_confirmed_from_unconfirmed

echo "OK: tests/fm-watch-capture-failure.test.sh"
