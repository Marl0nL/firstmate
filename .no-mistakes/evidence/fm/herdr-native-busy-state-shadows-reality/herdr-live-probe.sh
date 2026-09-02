#!/usr/bin/env bash
# Live reproduction against the REAL herdr 0.8.2 CLI, in an isolated
# bin/fm-herdr-lab.sh session (the live default session is never touched).
#
# Reproduces the 2026-09-01 divergence without a Claude turn: a real pane-TYPED
# process renders a Claude-shaped busy footer, and firstmate's own U3
# `pane report-agent` publish puts `idle` in herdr's real agent registry - the
# exact shadow the fix is about. Then reads the two consumers from the checkout
# passed as $1, so the same probe can be run against the pre-fix tree.
#
#   ./herdr-live-probe.sh <repo-root-under-test>
set -u
ROOT=$1
LAB="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
SESSION=$("$LAB" name busyshadow)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-live-probe.XXXXXX")
FOOTER='  ✻ Wibbling… (9m 41s · esc to interrupt)'

cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB" teardown "$SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

lab() { env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "$@"; }

# The adapter appends a TRAILING --session; this wrapper strips it and refuses
# any session other than the lab's, then forwards through the lab helper.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/herdr" <<EOF
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
exec env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$TMP/bin/herdr"

"$LAB" provision "$SESSION" >/dev/null || { echo "could not provision the lab"; exit 1; }
WS=$(lab workspace create --cwd "$ROOT" --label fm-busyshadow --no-focus) \
  || { echo "workspace create failed"; exit 1; }
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id') || exit 1
TARGET="$SESSION:$PANE"

# A pane-TYPED long-running process rendering the busy footer, exactly the shape
# a firstmate-launched crew has (fm-spawn TYPES the launch command).
lab pane run "$PANE" "printf '%s\n' '$FOOTER'; sleep 600" >/dev/null
sleep 3
# Firstmate's own U3 publish: this is what puts `idle` in herdr's registry for a
# pane it cannot detect itself.
lab pane report-agent "$PANE" --source firstmate --agent claude --state idle \
  --seq "$(date +%s%N)" >/dev/null 2>&1

export PATH="$TMP/bin:$ORIGINAL_PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-resident-lib.sh"

echo "herdr client/server        : $(PATH=$ORIGINAL_PATH herdr --version 2>/dev/null | head -1)"
echo "isolated lab session       : $SESSION  (pane $PANE)"
echo "raw registry (agent get)   : $(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")"
echo "fm_backend_busy_state      : $(fm_backend_busy_state herdr "$TARGET")"
echo "the pane's last live line  : $(fm_backend_capture herdr "$TARGET" 40 | grep -v '^[[:space:]]*$' | tail -1)"
echo "--- what the consumers conclude -------------------------------"
echo "pending-reply observation  : $(fm_pending_reply_backend_observation herdr "$TARGET" fm-busyshadow claude)"
if fm_wr_confirmed_busy herdr "$TARGET" claude; then
  echo "wake-resident stand-down   : REFUSED (endpoint confirmed busy)"
else
  echo "wake-resident stand-down   : ALLOWED (endpoint read as not busy)"
fi
