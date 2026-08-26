#!/usr/bin/env bash
# Live Herdr lab e2e for Track U phase U3: firstmate's report-agent STATE
# PUBLISHING (fm_backend_herdr_publish_agent_state). It proves, against a real
# Herdr, that publishing registers a crew in `herdr agent list` with live
# idle->working->blocked transitions, that the reporter is RECONCILING (a
# re-publish of the same state issues no new report and does not bump the
# registry's state_change_seq, which is what makes a per-poll call cheap and
# self-healing), that a claim-suppressed (HERDR_ENV=0) Claude crew is the
# unclaimed pane this publishing takes on, and that the blocked toast call is
# accepted. It EXTENDS the U0 recognition harness
# (tests/fm-herdr-recalibration-live-e2e.test.sh); the report-agent PRIMITIVE and
# the four-way liveness table live there, the state-PUBLISHING policy lives here.
#
# The captain-visible half - the attention-sorted agent panel floating a blocked
# crew to the top - depends on the GLOBAL config (agent_panel_sort="priority")
# and Herdr's GUI, which are server-global and not scriptable from an isolated
# lab session, so that remains a captain visual confirmation after
# bin/fm-herdr-attention-config.sh runs; this harness proves the data the panel
# sorts on (the registered agents and their states) is correct.
#
# All Herdr lifecycle runs through bin/fm-herdr-lab.sh (non-default fm-lab-*
# session, refuse-default, byte-identical default-session tripwire). Gated:
#   FM_HERDR_ATTENTION_LIVE=1 tests/fm-herdr-attention-live-e2e.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_ATTENTION_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_ATTENTION_LIVE=1 to run the live Herdr U3 attention state-publishing harness"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_HERDR_ATTENTION_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_HERDR_ATTENTION_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_HERDR_ATTENTION_LIVE=1 but Claude Code is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_HERDR_ATTENTION_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-attention-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-attention-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
WORK="$TMP_ROOT/work"
mkdir -p "$FAKEBIN" "$WORK"
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
# lab helper (see the U0 harness for the shim rationale).
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

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
new_pane() { lab tab create --workspace "$WS" --cwd "$WORK" --label "$1" --no-focus | jq -er '.result.root_pane.pane_id'; }
agent_status_of() { lab agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // "none"'; }
state_change_seq_of() { lab agent get "$1" 2>/dev/null | jq -r '.result.agent.state_change_seq // -1'; }
agent_list_has() { lab agent list 2>/dev/null | jq -e --arg p "$1" '.result.agents[]? | select(.pane_id == $p)' >/dev/null 2>&1; }

WS=$(lab workspace create --cwd "$WORK" --label fm-attn --no-focus | jq -er '.result.workspace.workspace_id') \
  || fail "could not create the isolated attention workspace"

# --- A. Publish idle -> working -> blocked; each must land in the registry -----
PANE=$(new_pane pub) || fail "could not create the publish pane"
sleep 2

fm_backend_herdr_publish_agent_state "$SESSION:$PANE" claude idle >/dev/null 2>&1 \
  || fail "publish idle failed on $V"
[ "$(agent_status_of "$PANE")" = idle ] || fail "publish idle: registry shows '$(agent_status_of "$PANE")', expected idle, on $V"
agent_list_has "$PANE" || fail "publish idle: the pane is absent from 'agent list' on $V"
CHECKED=$((CHECKED + 1))
pass "publishing registers the crew in agent list with state idle on $V"

fm_backend_herdr_publish_agent_state "$SESSION:$PANE" claude working >/dev/null 2>&1 \
  || fail "publish working failed on $V"
[ "$(agent_status_of "$PANE")" = working ] || fail "publish working: registry shows '$(agent_status_of "$PANE")', expected working, on $V"
seq_after_working=$(state_change_seq_of "$PANE")
CHECKED=$((CHECKED + 1))
pass "publishing drives an idle->working transition in the registry on $V"

# --- B. Reconciling: re-publishing the SAME state must be a no-op --------------
fm_backend_herdr_publish_agent_state "$SESSION:$PANE" claude working >/dev/null 2>&1 \
  || fail "re-publish working (no-op) returned an error on $V"
seq_after_noop=$(state_change_seq_of "$PANE")
[ "$seq_after_working" = "$seq_after_noop" ] \
  || fail "reconciling: re-publishing working bumped state_change_seq ($seq_after_working -> $seq_after_noop) - the reporter is not a no-op on unchanged state, on $V"
CHECKED=$((CHECKED + 1))
pass "re-publishing an unchanged state issues no new report (state_change_seq stable) on $V"

# --- C. blocked publishes and the toast call is accepted -----------------------
fm_backend_herdr_publish_agent_state "$SESSION:$PANE" claude blocked "firstmate: a worker is blocked" "waiting on the captain" >/dev/null 2>&1 \
  || fail "publish blocked (with toast) failed on $V"
[ "$(agent_status_of "$PANE")" = blocked ] || fail "publish blocked: registry shows '$(agent_status_of "$PANE")', expected blocked, on $V"
CHECKED=$((CHECKED + 1))
pass "publishing a blocked transition lands blocked and its toast call is accepted on $V"

# The reported state must STICK (Herdr must not override firstmate's report from
# its own detection) - the whole reporter design depends on this.
sleep 5
[ "$(agent_status_of "$PANE")" = blocked ] \
  || fail "reported blocked did not stick after 5s (now '$(agent_status_of "$PANE")') on $V - Herdr is overriding firstmate-reported state"
CHECKED=$((CHECKED + 1))
pass "a firstmate-reported state sticks and is not overridden by Herdr on $V"

# --- D. A claim-suppressed (HERDR_ENV=0) Claude crew is the unclaimed pane ------
# fm-spawn launches crew claude with HERDR_ENV=0 so the integration hook does not
# claim the pane; publishing then takes on it. Prove the end-to-end path.
CLAUDE_PANE=$(new_pane claude-crew) || fail "could not create the Claude crew pane"
lab pane send-text "$CLAUDE_PANE" "env HERDR_ENV=0 claude --dangerously-skip-permissions" >/dev/null \
  || fail "could not type the claim-suppressed Claude launch"
lab pane send-keys "$CLAUDE_PANE" enter >/dev/null || fail "could not submit the Claude launch"
lab pane wait-output "$CLAUDE_PANE" --regex 'bypass permissions' --timeout 60000 >/dev/null 2>&1
sleep 3
# Unclaimed: no self-registered agent_session, so herdr registers nothing until
# firstmate publishes. (A claimed pane would silently ignore report-agent.)
sess_before=$(lab pane get "$CLAUDE_PANE" 2>/dev/null | jq -c '.result.pane.agent_session // "null"')
[ "$sess_before" = null ] || [ "$sess_before" = '"null"' ] \
  || fail "claim-suppression: the crew pane carries an agent_session ($sess_before) - HERDR_ENV=0 did not suppress the integration claim, on $V"
fm_backend_herdr_publish_agent_state "$SESSION:$CLAUDE_PANE" claude working >/dev/null 2>&1 \
  || fail "publish working on the claim-suppressed Claude crew failed on $V"
[ "$(agent_status_of "$CLAUDE_PANE")" = working ] \
  || fail "the claim-suppressed Claude crew did not accept a published state (got '$(agent_status_of "$CLAUDE_PANE")') on $V"
agent_list_has "$CLAUDE_PANE" || fail "the claim-suppressed Claude crew is absent from 'agent list' after publishing on $V"
CHECKED=$((CHECKED + 1))
pass "a claim-suppressed (HERDR_ENV=0) Claude crew is unclaimed and accepts firstmate's published state on $V"

[ "$CHECKED" -ge 6 ] || fail "expected at least 6 live checks, ran $CHECKED"
pass "U3 attention state-publishing live harness completed ($CHECKED checks) on $V"
