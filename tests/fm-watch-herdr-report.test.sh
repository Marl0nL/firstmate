#!/usr/bin/env bash
# Portable unit test for the watcher-side herdr agent-state reporter mapping
# (report_herdr_agent_state in bin/fm-watch.sh). It maps a claude crew's
# supervisory state - the busy verdict plus the last status verb - onto herdr's
# idle|working|blocked agent-panel vocabulary and composes the captain-facing
# blocked toast. The report-agent CLI mechanics themselves are covered by
# tests/fm-backend-herdr.test.sh; here fm_backend_publish_agent_state is mocked
# so only the mapping and toast wording are asserted, with no real herdr.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-watch-herdr-report)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard at the bottom of
# fm-watch.sh returns before the lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

CALLS="$TMP/calls"
: >"$CALLS"
# Capture what the reporter would publish. Args: <backend> <target> <harness>
# <state> [toast_title] [toast_body], one record per line, fields tab-separated.
# shellcheck disable=SC2317  # invoked indirectly through report_herdr_agent_state
fm_backend_publish_agent_state() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${1-}" "${2-}" "${3-}" "${4-}" "${5-}" "${6-}" >>"$CALLS"
}

# report <last-status-line> <busy_now> -> the single captured call record
report() {
  : >"$CALLS"
  report_herdr_agent_state "sess:w1:p2" "$1" "$2"
  cat "$CALLS"
}

field() { printf '%s' "$1" | cut -f"$2"; }

test_busy_pane_maps_to_working() {
  local r
  r=$(report "working: building" 0)
  [ "$(field "$r" 1)" = herdr ] || fail "must dispatch to the herdr backend, got '$(field "$r" 1)'"
  [ "$(field "$r" 2)" = "sess:w1:p2" ] || fail "must pass the window target"
  [ "$(field "$r" 3)" = claude ] || fail "must report the claude harness"
  [ "$(field "$r" 4)" = working ] || fail "a busy pane must map to working, got '$(field "$r" 4)'"
  [ -z "$(field "$r" 5)" ] || fail "working must carry no toast title"
  pass "a busy pane maps to working with no toast"
}

test_idle_pane_maps_to_idle() {
  local r
  r=$(report "done: shipped" 1)
  [ "$(field "$r" 4)" = idle ] || fail "an idle pane with a terminal verb must map to idle, got '$(field "$r" 4)'"
  [ -z "$(field "$r" 5)" ] || fail "idle must carry no toast title"
  pass "an idle pane maps to idle with no toast"
}

test_blocked_verb_maps_to_blocked_with_toast() {
  local r
  r=$(report "blocked: waiting on the captain" 1)
  [ "$(field "$r" 4)" = blocked ] || fail "a blocked verb must map to blocked, got '$(field "$r" 4)'"
  [ "$(field "$r" 5)" = "firstmate: a worker is blocked" ] || fail "blocked toast title wrong: '$(field "$r" 5)'"
  [ "$(field "$r" 6)" = "waiting on the captain" ] || fail "blocked toast body must be the trimmed reason, got '$(field "$r" 6)'"
  pass "a blocked verb maps to blocked and composes a captain-facing toast"
}

test_needs_decision_verb_maps_to_blocked_with_decision_toast() {
  local r
  r=$(report "needs-decision: option A or option B" 1)
  [ "$(field "$r" 4)" = blocked ] || fail "needs-decision must map to blocked, got '$(field "$r" 4)'"
  [ "$(field "$r" 5)" = "firstmate: a worker needs your decision" ] || fail "needs-decision toast title wrong: '$(field "$r" 5)'"
  [ "$(field "$r" 6)" = "option A or option B" ] || fail "needs-decision toast body wrong: '$(field "$r" 6)'"
  pass "a needs-decision verb maps to blocked with a decision-specific toast"
}

test_blocked_verb_outranks_a_busy_pane() {
  local r
  # A worker can render busy-looking output while blocked; the verb must win so
  # the crew floats to the top of the priority panel instead of reading working.
  r=$(report "blocked: spun waiting" 0)
  [ "$(field "$r" 4)" = blocked ] || fail "the blocked verb must outrank the busy verdict, got '$(field "$r" 4)'"
  pass "the blocked verb outranks a busy pane"
}

test_no_status_line_busy_is_working() {
  local r
  r=$(report "" 0)
  [ "$(field "$r" 4)" = working ] || fail "an empty status line with a busy pane must be working, got '$(field "$r" 4)'"
  pass "an empty status line falls back to the busy verdict (working)"
}

test_no_status_line_idle_is_idle() {
  local r
  r=$(report "" 1)
  [ "$(field "$r" 4)" = idle ] || fail "an empty status line with a quiet pane must be idle, got '$(field "$r" 4)'"
  pass "an empty status line falls back to the busy verdict (idle)"
}

test_blocked_toast_body_is_capped() {
  local r long body
  long=$(printf 'x%.0s' $(seq 1 400))
  r=$(report "blocked: $long" 1)
  body=$(field "$r" 6)
  [ "${#body}" -le 200 ] || fail "the blocked toast body must be capped to 200 chars, got ${#body}"
  pass "a verbose blocked reason is capped for the toast"
}

test_busy_pane_maps_to_working
test_idle_pane_maps_to_idle
test_blocked_verb_maps_to_blocked_with_toast
test_needs_decision_verb_maps_to_blocked_with_decision_toast
test_blocked_verb_outranks_a_busy_pane
test_no_status_line_busy_is_working
test_no_status_line_idle_is_idle
test_blocked_toast_body_is_capped
