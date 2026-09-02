#!/usr/bin/env bash
# Live Herdr busy-state guard (live-harness-optin family).
#
# Herdr registers NO agent record for a pane-typed Claude (firstmate launches it
# by TYPING the command rather than `herdr agent start`), so its native busy
# verdict is a shadow of reality for a whole landed turn: agent get answers
# agent_not_found - unknown in an isolated lab, or idle from firstmate's own
# report-agent echo in the live fleet (the 2026-09-01 incident) - never busy. A
# stub can only confirm the assumption already written into it, so this guard
# drives a REAL Claude turn in an isolated Herdr lab and requires the busy/idle
# consumers to read BUSY from the pane while the native registry is NOT reading
# busy. It fails naming the harness and version rather than degrading quietly,
# and refuses a pass that observed nothing.
#
# Run explicitly with FM_HERDR_BUSY_STATE_LIVE=1 after a Herdr or Claude upgrade,
# and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr pane-typed busy state" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh
# (the adapter derives the session from the "<session>:<pane>" target and appends
# the trailing --session the lab wrapper requires).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_BUSY_STATE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_BUSY_STATE_LIVE=1 to run the live Herdr busy-state guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_HERDR_BUSY_STATE_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_HERDR_BUSY_STATE_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_HERDR_BUSY_STATE_LIVE=1 but Claude Code is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_HERDR_BUSY_STATE_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-busy-state-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-busy-state-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
OBSERVED=0

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

cat > "$FAKEBIN/herdr" <<EOF
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

# The busy/idle consumers under test and their whole dependency chain.
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-resident-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-busylive --no-focus) \
  || fail "could not create the isolated busy-state workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# Launch claim-suppressed exactly as bin/fm-spawn.sh does (HERDR_ENV=0), so the
# pane is a plain firstmate-launched Claude, not integration-claimed.
lab pane run "$PANE" "HERDR_ENV=0 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

# Readiness is the composer, NOT the agent registry: herdr registers no agent
# record for a pane-typed Claude (agent get answers agent_not_found), so its
# agent_status stays empty and the native busy verdict is unknown - which is the
# whole point. Wait for the composer to settle empty instead.
ready=0
i=0
while [ "$i" -lt 60 ]; do
  if [ "$(fm_backend_composer_state herdr "$TARGET" 2>/dev/null)" = empty ]; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$ready" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never presented a ready composer in the lab pane"

# A generation-heavy prompt so the busy footer stays up long enough to sample.
# The verdict itself is not asserted: a swallowed send is caught by the OBSERVED
# gate below (the busy footer would never render).
PROMPT='Think step by step and write a thorough 600-word technical essay explaining how TCP congestion control works, covering slow start, congestion avoidance, fast retransmit, and fast recovery. Do not stop early.'
fm_backend_herdr_send_text_submit "$TARGET" "$PROMPT" 3 0.4 0.4 >/dev/null \
  || fail "could not submit the busy-inducing prompt to Claude Code ($VERSION) on $HERDR_VER"

# Poll until the pane's own busy footer is visible, then take ONE observation of
# every consumer at that moment. The registry is read at the same instant to
# prove the divergence.
native='' consumer='' wr_rc='' owner_rc=''
i=0
while [ "$i" -lt 45 ]; do
  cap=$(fm_backend_capture herdr "$TARGET" 40 2>/dev/null || true)
  if printf '%s\n' "$cap" | grep -v '^[[:space:]]*$' | tail -6 | fm_busy_lines_match claude; then
    native=$(fm_backend_busy_state herdr "$TARGET" 2>/dev/null || printf 'read-failed')
    consumer=$(fm_pending_reply_backend_observation herdr "$TARGET" fm-busylive claude)
    if fm_wr_confirmed_busy herdr "$TARGET" claude; then wr_rc=busy; else wr_rc=not-busy; fi
    if fm_busy_native_busy herdr "$TARGET" claude; then owner_rc=trusted-busy; else owner_rc=deferred; fi
    OBSERVED=1
    break
  fi
  i=$((i + 1))
  sleep 1
done

[ "$OBSERVED" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the busy footer never rendered, so no busy/idle divergence could be observed"

# The consumers must classify BUSY from the pane.
[ "$consumer" = busy ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: pending-reply observation read '$consumer', not busy, for a mid-turn pane"
[ "$wr_rc" = busy ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: wake-resident confirmed-busy read '$wr_rc', not busy, for a mid-turn pane"
# A claude pane's native verdict is firstmate's own echo, never an independent
# signal, so the one owner must defer to the capture rather than assert busy.
[ "$owner_rc" = deferred ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: fm_busy_native_busy returned '$owner_rc' for claude - it must never trust a claude native verdict"
# The divergence itself: the registry must NOT be reading busy while the pane is.
# If a future Herdr version DOES detect a claude turn, this fails loudly naming
# the versions rather than letting the guarantee rot into a false claim.
[ "$native" != busy ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the native registry read busy for a claude pane (no divergence to guard) - re-verify the report-agent echo assumption"

pass "live Herdr busy state: Claude Code ($VERSION) on $HERDR_VER reads native='$native' yet the consumers classify busy from the pane in isolated session $SESSION"
