#!/usr/bin/env bash
# Real-Herdr E2E for the restored-manual-mode detection and remediation
# (docs/herdr-backend.md "Restart and liveness behavior"). It proves the one
# harness-dependent fact the portable tests must assume: that REAL
# `herdr pane process-info` exposes a pane's foreground argv, so
# fm_backend_agent_launch_health can tell a Claude carrying
# --dangerously-skip-permissions (healthy) from one Herdr resumed without it
# (degraded, the manual-permission-mode stall), and that interrupting the
# degraded pane returns it to a reclaimable shell (the exit half of the cycle).
#
# Every Herdr CLI call goes through one guarded named non-default lab session:
# test-setup calls via the lab helper directly, and the production adapter's own
# `herdr --session <lab>` calls via a fakebin shim that strips that exact pair
# and re-routes through the helper. Lab teardown verifies the default fleet
# session is byte-identical. The live fleet is never touched.
#
# The Claude foreground is faked with a plain blocker whose argv[0] carries a
# `claude` path component (exactly how a version-named Claude Code binary is
# identified, per bin/fm-session-lock-lib.sh), so no real Claude is needed. The
# agent_state=alive precondition and the full exit->respawn cycle are covered by
# the portable sweep tests in tests/fm-secondmate-liveness.test.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-secondmate-manual-mode-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
FAKECLAUDE="$TMP_ROOT/claude/versions/9.9.9/claude"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config" "$(dirname "$FAKECLAUDE")"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-secondmate-manual-mode)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# The production adapter appends `--session <lab>` to every call; this shim
# strips that exact trailing pair, refuses every other caller-supplied session,
# and delegates the rest to the guarded helper (which re-adds a LEADING
# --session). --version passes straight through to the real binary.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# launch_health <pane>: the production classifier, reached through the reroute
# shim so its own `herdr --session` calls stay scoped to the lab.
launch_health() {
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_agent_launch_health herdr "$2"' \
      _ "$ROOT/bin/fm-backend.sh" "$HERDR_LAB_SESSION:$1"
}

# run_fake_claude <pane> <flags...>: foreground a blocker in <pane> whose
# argv[0] is a claude-path component, carrying <flags> in its argv. Waits until
# `herdr pane process-info` reports the claude argv as a foreground process.
run_fake_claude() {
  local pane=$1; shift
  local cmd="exec -a '$FAKECLAUDE' bash -c 'trap \"exit 0\" INT TERM; sleep 3600' claude-fake $*"
  lab pane send-text "$pane" "$cmd" >/dev/null
  lab pane send-keys "$pane" enter >/dev/null
  local attempt=0
  while [ "$attempt" -lt 40 ]; do
    if lab pane process-info --pane "$pane" \
      | jq -e '[.result.process_info.foreground_processes[]?.argv[0]? // "" | select(test("/claude/"))] | length > 0' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  return 1
}

new_pane() {  # <label> -> pane id
  local ws
  ws=$(lab workspace create --cwd "$ROOT" --label "$1" --no-focus) \
    || fail "could not create lab workspace $1"
  printf '%s' "$ws" | jq -r '.result.root_pane.pane_id'
}

# --- Detection: healthy vs degraded from REAL process-info argv --------------

PANE_HEALTHY=$(new_pane manual-mode-healthy)
run_fake_claude "$PANE_HEALTHY" --dangerously-skip-permissions --model m \
  || fail "the flag-carrying fake Claude never appeared in process-info"
got=$(launch_health "$PANE_HEALTHY")
[ "$got" = healthy ] \
  || fail "a live Claude carrying --dangerously-skip-permissions must read healthy, got '$got'"
pass "real Herdr: a flag-carrying Claude foreground reads healthy"

PANE_DEGRADED=$(new_pane manual-mode-degraded)
run_fake_claude "$PANE_DEGRADED" --resume 17ac2d21-172d-4965-990a \
  || fail "the flag-less fake Claude never appeared in process-info"
got=$(launch_health "$PANE_DEGRADED")
[ "$got" = degraded ] \
  || fail "a live Claude resumed WITHOUT the permission flag must read degraded, got '$got'"
pass "real Herdr: a Claude resumed without the permission flag reads degraded"

# --- Remediation transition: interrupting the degraded pane clears the husk ---
# The guarded exit begins by interrupting the frozen pane; here we prove that on
# a real pane it returns the degraded Claude to a reclaimable shell (no Claude
# foreground), which the ordinary dead-mate relaunch then handles.
lab pane send-keys "$PANE_DEGRADED" C-c >/dev/null 2>&1 \
  || lab pane send-keys "$PANE_DEGRADED" ctrl-c >/dev/null 2>&1 || true
attempt=0
cleared=0
while [ "$attempt" -lt 40 ]; do
  if [ "$(launch_health "$PANE_DEGRADED")" = unknown ]; then
    cleared=1
    break
  fi
  sleep 0.2
  attempt=$((attempt + 1))
done
[ "$cleared" = 1 ] \
  || fail "interrupting the degraded pane must clear the Claude foreground (launch health -> unknown)"
pass "real Herdr: interrupting a degraded pane returns it to a reclaimable shell"

echo "# all fm-secondmate-manual-mode-e2e checks passed"
