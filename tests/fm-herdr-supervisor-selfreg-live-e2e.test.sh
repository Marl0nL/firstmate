#!/usr/bin/env bash
# Live Herdr lab e2e for supervisor-pane SELF-REGISTRATION: firstmate's watcher
# publishes not only crew/scout panes but also the secondmate SUPERVISOR panes
# into herdr's own attention-sorted agent panel. It proves, against a real Herdr,
# that the watcher's real reporter gate (maybe_report_herdr_agent_state ->
# report_herdr_agent_state -> fm_backend_publish_agent_state) registers a live,
# claim-suppressed (HERDR_ENV=0) claude pane whose task record is kind=secondmate
# - the exact shape a secondmate supervisor pane has - drives its idle/working/
# blocked transitions, is reconciling (a re-publish of the same state issues no
# new report), and is REALITY-GATED so a crashed supervisor's stale record is
# released and a dormant wake-resident advisor's BARE SHELL never registers.
#
# The publish PRIMITIVE and the four-way liveness table are proven on real herdr
# in tests/fm-herdr-attention-live-e2e.test.sh and
# tests/fm-herdr-recalibration-live-e2e.test.sh; this harness adds the one thing
# those do not: that the watcher's kind-agnostic gate publishes a kind=secondmate
# window (the exclusion that scoped publishing to non-secondmate windows is
# lifted). The captain's OWN primary pane is deliberately never published: it is
# not a recorded window and is launched by the captain (integration-claimed), so
# report-agent would be ignored on it and un-claiming it would disturb the
# captain's own herdr session - secondmates-only by design.
#
# All Herdr lifecycle runs through bin/fm-herdr-lab.sh (non-default fm-lab-*
# session, refuse-default, byte-identical default-session tripwire). Gated:
#   FM_HERDR_SUPERVISOR_SELFREG_LIVE=1 tests/fm-herdr-supervisor-selfreg-live-e2e.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_SUPERVISOR_SELFREG_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_SUPERVISOR_SELFREG_LIVE=1 to run the live Herdr supervisor self-registration harness"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_HERDR_SUPERVISOR_SELFREG_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_HERDR_SUPERVISOR_SELFREG_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_HERDR_SUPERVISOR_SELFREG_LIVE=1 but Claude Code is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUPERVISOR_SELFREG_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-supervisor-selfreg)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-supervisor-selfreg.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
WORK="$TMP_ROOT/work"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$FAKEBIN" "$WORK" "$STATE_DIR"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
CLAUDE_VER=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'claude-unknown')
V="$HERDR_VER / $CLAUDE_VER"

# Route the adapter's own `herdr ... --session <name>` calls through the guarded
# lab helper (same shim rationale as the attention harness): the adapter appends
# `--session <session>` last (fm_backend_herdr_cli), which this shim enforces.
cat >"$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# Load the REAL watcher functions (the guard at fm-watch.sh's main entry returns
# on source, so the lock/loop never runs) with STATE pointed at our fixture dir,
# so window_backend/window_harness resolve from the secondmate meta we write and
# the gate publishes through the real reporter path. backends/herdr.sh is sourced
# for the direct reality-gate/liveness assertions below.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
new_pane() { lab tab create --workspace "$WS" --cwd "$WORK" --label "$1" --no-focus | jq -er '.result.root_pane.pane_id'; }
agent_status_of() { lab agent get "$1" 2>&1 | jq -r 'if .error != null then "none" else (.result.agent.agent_status // "none") end' 2>/dev/null; }
state_change_seq_of() { lab agent get "$1" 2>&1 | jq -r 'if .error != null then -1 else (.result.agent.state_change_seq // -1) end' 2>/dev/null; }
agent_list_has() { lab agent list 2>/dev/null | jq -e --arg p "$1" '.result.agents[]? | select(.pane_id == $p)' >/dev/null 2>&1; }

# Write a live kind=secondmate task record so the watcher's window_kind/backend/
# harness resolve the pane as a herdr claude SUPERVISOR window.
write_secondmate_meta() {  # <task-id> <session:pane>
  {
    printf 'window=%s\n' "$2"
    printf 'kind=secondmate\n'
    printf 'harness=claude\n'
    printf 'backend=herdr\n'
  } > "$STATE_DIR/$1.meta"
}

WS=$(lab workspace create --cwd "$WORK" --label fm-sup --no-focus | jq -er '.result.workspace.workspace_id') \
  || fail "could not create the isolated supervisor workspace"

# --- A. A claim-suppressed (HERDR_ENV=0) claude SUPERVISOR pane is unclaimed ----
# A secondmate supervisor is a claude firstmate launched claim-suppressed exactly
# like a crew (bin/fm-spawn.sh no longer excludes kind=secondmate), so herdr does
# not manage it and the watcher can publish onto it.
SUP_PANE=$(new_pane secondmate-supervisor) || fail "could not create the supervisor pane"
lab pane send-text "$SUP_PANE" "env HERDR_ENV=0 claude --dangerously-skip-permissions" >/dev/null \
  || fail "could not type the claim-suppressed supervisor launch"
lab pane send-keys "$SUP_PANE" enter >/dev/null || fail "could not submit the supervisor launch"
lab pane wait-output "$SUP_PANE" --regex 'bypass permissions' --timeout 60000 >/dev/null 2>&1
sleep 3
sess_before=$(lab pane get "$SUP_PANE" 2>/dev/null | jq -c '.result.pane.agent_session // "null"')
[ "$sess_before" = null ] || [ "$sess_before" = '"null"' ] \
  || fail "claim-suppression: the supervisor pane carries an agent_session ($sess_before) - HERDR_ENV=0 did not suppress the claim, on $V"
write_secondmate_meta sup "$SESSION:$SUP_PANE"
[ "$(window_kind "$SESSION:$SUP_PANE")" = secondmate ] \
  || fail "the fixture meta must resolve window_kind=secondmate, got '$(window_kind "$SESSION:$SUP_PANE")'"
CHECKED=$((CHECKED + 1))
pass "a claim-suppressed (HERDR_ENV=0) claude SUPERVISOR pane is unclaimed and reads kind=secondmate on $V"

# --- B. The watcher gate PUBLISHES a kind=secondmate supervisor window ----------
# Idle first (busy_now=1 -> idle), then working (busy_now=0). If the old
# secondmate exclusion were still in force, neither would land.
maybe_report_herdr_agent_state "$SESSION:$SUP_PANE" "" 1 \
  || fail "the gate returned non-zero publishing an idle supervisor on $V"
[ "$(agent_status_of "$SUP_PANE")" = idle ] \
  || fail "the gate did not register the secondmate supervisor as idle (got '$(agent_status_of "$SUP_PANE")') on $V"
agent_list_has "$SUP_PANE" || fail "the supervisor pane is absent from 'agent list' after publish on $V"
CHECKED=$((CHECKED + 1))
pass "the watcher gate registers a kind=secondmate supervisor pane (idle) in herdr's agent panel on $V"

maybe_report_herdr_agent_state "$SESSION:$SUP_PANE" "" 0 \
  || fail "the gate returned non-zero publishing a working supervisor on $V"
[ "$(agent_status_of "$SUP_PANE")" = working ] \
  || fail "the gate did not drive the supervisor idle->working (got '$(agent_status_of "$SUP_PANE")') on $V"
seq_after_working=$(state_change_seq_of "$SUP_PANE")
CHECKED=$((CHECKED + 1))
pass "the gate drives a supervisor idle->working transition on $V"

# --- C. Reconciling: re-publishing the SAME state issues no new report ----------
maybe_report_herdr_agent_state "$SESSION:$SUP_PANE" "" 0 \
  || fail "the gate returned non-zero re-publishing an unchanged supervisor state on $V"
seq_after_noop=$(state_change_seq_of "$SUP_PANE")
[ "$seq_after_working" != -1 ] && [ "$seq_after_working" = "$seq_after_noop" ] \
  || fail "reconciling: re-publishing working bumped state_change_seq ($seq_after_working -> $seq_after_noop) on $V"
CHECKED=$((CHECKED + 1))
pass "re-publishing an unchanged supervisor state issues no new report (state_change_seq stable) on $V"

# --- D. A blocked status verb floats the supervisor to the top with a toast -----
maybe_report_herdr_agent_state "$SESSION:$SUP_PANE" "blocked: a worker needs the captain" 0 \
  || fail "the gate returned non-zero publishing a blocked supervisor on $V"
[ "$(agent_status_of "$SUP_PANE")" = blocked ] \
  || fail "a blocked status verb did not land blocked (got '$(agent_status_of "$SUP_PANE")') on $V"
sleep 4
[ "$(agent_status_of "$SUP_PANE")" = blocked ] \
  || fail "the reported blocked state did not stick after 4s (now '$(agent_status_of "$SUP_PANE")') on $V"
CHECKED=$((CHECKED + 1))
pass "a blocked status verb lands blocked and sticks (herdr does not override the report) on $V"

# --- E. Reality-gated release on supervisor exit --------------------------------
# Kill the supervisor's claude process: the pane drops to a bare shell still
# carrying firstmate's blocked record. The next gate call must RELEASE it (the
# reality gate refuses to keep publishing onto a pane with no live claude), so the
# pane returns to agent_not_found and classifies no-agent / husk-reclaimable.
sup_pids=$(lab pane process-info --pane "$SUP_PANE" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[]?.pid // empty')
[ -n "$sup_pids" ] || fail "could not read the supervisor's foreground pids for the exit simulation on $V"
for pid in $sup_pids; do kill -9 "$pid" 2>/dev/null || true; done
for _ in 1 2 3 4 5 6 7 8 9 10; do
  fm_backend_herdr_pane_foreground_harness "$SESSION" "$SUP_PANE" || break
  sleep 1
done
fm_backend_herdr_pane_foreground_harness "$SESSION" "$SUP_PANE" \
  && fail "the supervisor pane still reports a harness foreground process after the kill on $V"
maybe_report_herdr_agent_state "$SESSION:$SUP_PANE" "blocked: a worker needs the captain" 0 \
  || fail "the gate must release the stale record on a dead supervisor pane and return 0 on $V"
[ "$(agent_status_of "$SUP_PANE")" = none ] \
  || fail "release: the dead supervisor pane still carries an agent record ('$(agent_status_of "$SUP_PANE")') on $V"
agent_list_has "$SUP_PANE" && fail "release: the dead supervisor pane is still listed in 'agent list' on $V"
[ "$(fm_backend_herdr_pane_agent_state "$SESSION" "$SUP_PANE")" = no-agent ] \
  || fail "the released supervisor pane must classify no-agent on $V"
CHECKED=$((CHECKED + 1))
pass "a crashed supervisor's stale record is released and the pane reads no-agent on exit on $V"

# --- F. A dormant wake-resident advisor's BARE SHELL must NOT register ----------
# A wake-resident advisor that has stood down is a bare shell with a kind=secondmate
# record. The reality gate must refuse it exactly as it refuses any bare shell, so
# raise/standdown is unaffected and a dormant advisor never appears in the panel.
ADVISOR_PANE=$(new_pane dormant-advisor) || fail "could not create the dormant-advisor pane"
sleep 2
write_secondmate_meta advisor "$SESSION:$ADVISOR_PANE"
maybe_report_herdr_agent_state "$SESSION:$ADVISOR_PANE" "" 1 \
  || fail "the gate must cleanly refuse a bare-shell advisor pane (rc 0) on $V"
[ "$(agent_status_of "$ADVISOR_PANE")" = none ] \
  || fail "reality gate: a dormant advisor's bare shell got a published state ('$(agent_status_of "$ADVISOR_PANE")') on $V"
agent_list_has "$ADVISOR_PANE" && fail "reality gate: the dormant advisor's bare shell appeared in 'agent list' on $V"
CHECKED=$((CHECKED + 1))
pass "a dormant wake-resident advisor's bare shell never registers (reality gate holds) on $V"

[ "$CHECKED" -ge 7 ] || fail "expected at least 7 live checks, ran $CHECKED"
pass "Herdr supervisor self-registration live harness completed ($CHECKED checks) on $V"
