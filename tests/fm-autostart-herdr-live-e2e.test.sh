#!/usr/bin/env bash
# Live Herdr boot-autostart guard (live-harness-optin family).
#
# `bin/fm-autostart.sh` is the unattended boot step, and its whole verdict comes
# from what the Herdr binary emits: which subcommands exist, which flags they
# take, what `workspace create` reports about the pane it seeded, whether typing
# a launch command into that pane actually produces a running process, and which
# inventory still sees that process afterwards. None of that can be proven by a
# fake CLI - a fake can only confirm the assumption already written into it - so
# this guard drives the REAL installed Herdr end to end and fails naming the
# Herdr version when any of it drifts.
#
# The portable regression tests/fm-autostart.test.sh pins the decision logic
# with real processes and no Herdr; this guard pins the Herdr contract that
# logic is built on. Both are needed: they fail for different reasons.
#
# Herdr 0.8 removed the `agent start --cwd` shape autostart originally used, and
# on 0.8.2 the replacement `agent start --kind claude --pane` never completes its
# readiness detection, so the launch is `workspace create` + `pane run` instead
# (bin/fm-autostart.sh's header owns that reasoning). What must be re-checked on
# every Herdr upgrade is that those two primitives still behave as the script
# depends on, and that the agent registry still cannot be trusted alone to see a
# live agent.
#
# The agent launched here is a stand-in - a copy of /bin/sleep named `claude`,
# which is a real long-lived process carrying a verified-harness name - not a
# real Claude. The subject under test is Herdr, and a real Claude would only add
# vendor startup time and a credentialed dependency to a check that never needs
# either. No real firstmate is ever created: every case runs against a throwaway
# firstmate-shaped home in a temp directory.
#
# Every Herdr call, including bin/backends/herdr.sh's own, is routed through the
# guarded lab helper (bin/fm-herdr-lab.sh): leading --session, refuse-default,
# before/after fleet-state tripwire. The captain's default session is untouched.
#
# That isolation is also a stated LIMIT on what this guard proves. The wrapper
# forces every herdr call into the lab session, so a call the script makes
# bare and a call it makes through fm_backend_herdr_cli converge on the same
# server here no matter what. A session-targeting split between them - the
# defect where the pane enumeration and the close address one server while the
# process-info that authorizes the close answers from another - is therefore
# invisible to this guard by construction, and nothing here should be read as
# evidence against it.
#
# Run explicitly after a Herdr upgrade, and before trusting a refreshed
# docs/verification/runtime-backends.md "Boot autostart launch shape" entry:
#
#   FM_AUTOSTART_HERDR_LIVE=1 tests/fm-autostart-herdr-live-e2e.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_AUTOSTART_HERDR_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AUTOSTART_HERDR_LIVE=1 to run the live Herdr boot-autostart guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_AUTOSTART_HERDR_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_AUTOSTART_HERDR_LIVE=1 but jq is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_AUTOSTART_HERDR_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name autostart-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-autostart-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
AGENTBIN="$TMP_ROOT/agentbin"
mkdir -p "$FAKEBIN" "$AGENTBIN"
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

V=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# Route every `herdr ...` call the script makes - its own, and the adapter's,
# which appends a TRAILING --session the helper refuses as caller-supplied -
# through `fm-herdr-lab.sh run`, which supplies the required LEADING --session
# itself. A trailing --session naming any other session is refused outright, so
# this shim can never widen the blast radius beyond the lab session.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# The stand-in agent: a real long-lived process whose executable name is one the
# fleet-wide harness matcher recognizes (bin/fm-session-lock-lib.sh).
cp "$(command -v sleep)" "$AGENTBIN/claude" || fail "could not build the stand-in agent binary"
AGENT="$AGENTBIN/claude"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

make_home() {  # <dir>
  mkdir -p "$1/bin"
  : > "$1/AGENTS.md"
  : > "$1/bin/fm-spawn.sh"
  chmod +x "$1/bin/fm-spawn.sh"
  (cd "$1" && pwd -P)
}

# Every run is offline by contract: the network gate is about registration, not
# about the Herdr surface this guard measures. HERDR_SESSION is what the script
# resolves its own session from, exactly as an operator who set one would, and
# it keeps the adapter's trailing --session naming the lab session the shim
# accepts.
autostart() {  # <home> [extra args...]
  local home=$1
  shift
  HERDR_SESSION="$SESSION" "$ROOT/bin/fm-autostart.sh" --fm-root "$home" --skip-net-check \
    --interval 0.5 --timeout 30 --confirm 30 "$@" 2>&1
}

# How many panes currently report <cwd> as their working directory.
panes_in() {  # <cwd>
  lab pane list 2>/dev/null |
    jq --arg c "$1" '[.result.panes[]? | select(.cwd == $c or .foreground_cwd == $c)] | length'
}

# --- A. the launch primitives still report what the script reads -------------
# `workspace create` must report both the workspace it made and the pane it
# seeded; that pane id is what the launch command is typed into.
PROBE_DIR="$TMP_ROOT/probe"
mkdir -p "$PROBE_DIR"
ws_out=$(lab workspace create --cwd "$PROBE_DIR" --label fm-autostart-probe --no-focus) ||
  fail "workspace create failed on $V"
probe_ws=$(printf '%s' "$ws_out" | jq -r '.result.workspace.workspace_id // empty')
probe_pane=$(printf '%s' "$ws_out" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$probe_ws" ] ||
  fail "workspace create no longer reports .result.workspace.workspace_id on $V; bin/fm-autostart.sh reads it to identify what it created"
[ -n "$probe_pane" ] ||
  fail "workspace create no longer reports .result.root_pane.pane_id on $V; bin/fm-autostart.sh reads it to locate the pane it launches into and refuses the boot without it"
CHECKED=$((CHECKED + 1))
pass "workspace create reports its workspace ($probe_ws) and seeded pane ($probe_pane) on $V"

# `pane run` must type AND submit a command in one call, leaving a real process.
lab pane run "$probe_pane" "$(printf '%q' "$AGENT") 300" >/dev/null ||
  fail "pane run failed on $V"
probe_fg=""
probe_deadline=$(( $(date +%s) + 20 ))
while :; do
  probe_fg=$(lab pane process-info --pane "$probe_pane" 2>/dev/null |
    jq -r '[.result.process_info.foreground_processes[]?.name] | join(",")')
  case "$probe_fg" in *claude*) break ;; esac
  [ "$(date +%s)" -lt "$probe_deadline" ] || break
  sleep 0.5
done
case "$probe_fg" in
  *claude*) ;;
  *) fail "pane run did not leave the typed command running on $V (foreground: '$probe_fg'); autostart's launch depends on it typing AND submitting" ;;
esac
CHECKED=$((CHECKED + 1))
pass "pane run types and submits a launch command, leaving it running, on $V"

# The premise behind reading BOTH inventories: a pane-typed agent is invisible
# to the agent registry, so the pane inventory is the one that still sees it.
reg=$(lab agent list 2>/dev/null | jq -r '[.result.agents[]?] | length')
[ "$reg" = 0 ] ||
  fail "the agent registry now reports $reg agent(s) for a pane-typed process on $V; re-measure which inventory autostart may trust"
[ "$(panes_in "$PROBE_DIR")" -ge 1 ] ||
  fail "pane list does not report the pane running in $PROBE_DIR on $V; autostart's presence check depends on it"
CHECKED=$((CHECKED + 1))
pass "a pane-typed agent is invisible to the agent registry and visible in the pane inventory on $V"
lab pane close "$probe_pane" >/dev/null 2>&1 || true

# --- B. a real boot brings a firstmate up ------------------------------------
HOME_A=$(make_home "$TMP_ROOT/home-a")
plan=$(autostart "$HOME_A" --dry-run -- "$AGENT" 600 --continue)
[ "$?" = 0 ] || fail "--dry-run failed on $V: $plan"
case "$plan" in
  *"herdr workspace create --cwd $HOME_A --label firstmate --no-focus"*) ;;
  *) fail "--dry-run's plan does not name the create the real path runs on $V: $plan" ;;
esac
planned_cmd=$(printf '%s' "$plan" | sed -n 's/^  herdr pane run <the pane that creates> //p')
[ -n "$planned_cmd" ] || fail "--dry-run printed no launch command on $V: $plan"
[ "$(panes_in "$HOME_A")" = 0 ] || fail "--dry-run created a pane on $V"
CHECKED=$((CHECKED + 1))
pass "--dry-run prints the create and the launch command without touching Herdr on $V"

out=$(autostart "$HOME_A" -- "$AGENT" 600 --continue)
rc=$?
[ "$rc" = 0 ] || fail "a real boot into an empty session failed on $V (exit $rc): $out"
case "$out" in
  *"firstmate is up"*) ;;
  *) fail "a real boot did not confirm the firstmate came up on $V: $out" ;;
esac
[ "$(panes_in "$HOME_A")" = 1 ] ||
  fail "a real boot did not leave exactly one pane in $HOME_A on $V"
CHECKED=$((CHECKED + 1))
pass "a real boot creates the workspace, launches the agent, and confirms it live on $V"

# The plan --dry-run printed must be the line the real path actually typed.
home_a_pane=$(lab pane list 2>/dev/null |
  jq -r --arg c "$HOME_A" 'first(.result.panes[]? | select(.cwd == $c or .foreground_cwd == $c) | .pane_id)')
[ -n "$home_a_pane" ] || fail "could not locate the pane the boot created on $V"
typed=$(lab pane read "$home_a_pane" --source recent-unwrapped --lines 200 2>/dev/null || printf '')
case "$typed" in
  *"$planned_cmd"*) ;;
  *) fail "the launched pane does not show the command --dry-run promised on $V; planned: [$planned_cmd]" ;;
esac
CHECKED=$((CHECKED + 1))
pass "the command --dry-run printed is the command the real boot typed on $V"

# The stand-in agent rejects `--continue` exactly as `claude --continue` does on
# a host with nothing to resume, so this boot really exercised the fallback: the
# process left running must be the one WITHOUT --continue.
fg_argv=$(lab pane process-info --pane "$home_a_pane" 2>/dev/null |
  jq -r '[.result.process_info.foreground_processes[]? | (.argv // []) | join(" ")] | join(" | ")')
case "$fg_argv" in
  *--continue*) fail "the --continue fallback did not take on $V: still running [$fg_argv]" ;;
  *600*) ;;
  *) fail "no launched agent is running after the fallback on $V: [$fg_argv]" ;;
esac
CHECKED=$((CHECKED + 1))
pass "a launch whose --continue form exits leaves the fallback form running on $V"

# --- C. never a second firstmate ---------------------------------------------
out=$(autostart "$HOME_A" -- "$AGENT" 600 --continue)
rc=$?
[ "$rc" = 0 ] || fail "the second run was not a clean no-op on $V (exit $rc): $out"
case "$out" in
  *"already up"*) ;;
  *) fail "the second run did not report the firstmate already up on $V: $out" ;;
esac
[ "$(panes_in "$HOME_A")" = 1 ] ||
  fail "THE ONE RULE: the second run started a second firstmate in $HOME_A on $V"
CHECKED=$((CHECKED + 1))
pass "running twice against the real server starts exactly one firstmate on $V"

# --- D. a restored bare shell is not a firstmate ------------------------------
# Herdr restores persisted panes as plain shells, so the home's pane comes back
# with the right cwd and a real live process and nothing else. Counting that as
# a running firstmate is what once made this unit a permanent silent no-op.
HOME_B=$(make_home "$TMP_ROOT/home-b")
lab workspace create --cwd "$HOME_B" --label fm-autostart-shell --no-focus >/dev/null ||
  fail "could not create the bare-shell workspace on $V"
[ "$(panes_in "$HOME_B")" = 1 ] || fail "the bare-shell pane is not visible in $HOME_B on $V"
out=$(autostart "$HOME_B" -- "$AGENT" 600 --continue)
rc=$?
[ "$rc" = 0 ] || fail "a bare shell in the home blocked the boot on $V (exit $rc): $out"
case "$out" in
  *"already up"*) fail "RESTORED SHELL: a pane holding only a shell was reported as a running firstmate on $V" ;;
esac
[ "$(panes_in "$HOME_B")" = 2 ] ||
  fail "the boot did not add its own pane beside the bare shell in $HOME_B on $V"
CHECKED=$((CHECKED + 1))
pass "a live bare shell in the firstmate home does not block the boot on $V"

# --- E. a launch that never becomes an agent fails loudly and cleans up -------
HOME_C=$(make_home "$TMP_ROOT/home-c")
out=$(HERDR_SESSION="$SESSION" "$ROOT/bin/fm-autostart.sh" --fm-root "$HOME_C" --skip-net-check \
  --interval 0.5 --timeout 30 --confirm 5 -- "$TMP_ROOT/definitely-not-a-command" 2>&1)
rc=$?
[ "$rc" = 4 ] || fail "a launch that never becomes an agent exited $rc, expected 4, on $V: $out"
case "$out" in
  *"no live firstmate appeared"*) ;;
  *) fail "the confirmation timeout did not say what was missing on $V: $out" ;;
esac
# What the failed boot then does with the workspace is release-dependent, and
# both halves are asserted rather than one being skipped. Below the floor where
# an explicit close preserves focus, closing the emptied workspace would move
# the captain off whatever space was being watched, so cleanup deliberately
# leaves it behind and says so; at or above the floor it removes it.
FLOOR_STATUS=$(lab status --json) || fail "could not read the herdr release on $V"
FLOOR_VERSION=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.version else .client.version end')
FLOOR_PROTOCOL=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.protocol else .client.protocol end')
FLOOR_VERDICT=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$FLOOR_PROTOCOL" "$FLOOR_VERSION")
case "$FLOOR_VERDICT" in
  0)
    [ "$(panes_in "$HOME_C")" = 0 ] ||
      fail "a failed boot left its half-started pane behind in $HOME_C on $V, which is at or above the focus-safe-close floor: $out"
    ;;
  1)
    [ "$(panes_in "$HOME_C")" = 1 ] ||
      fail "a failed boot closed its workspace on $V, which is below the focus-safe-close floor where that steals the captain's focus: $out"
    case "$out" in
      *"Close it by hand"*) ;;
      *) fail "a failed boot below the floor on $V did not report the workspace it deliberately left behind: $out" ;;
    esac
    ;;
  *)
    fail "herdr $V (version $FLOOR_VERSION, protocol $FLOOR_PROTOCOL) could not be classified against the focus-safe-close floor, so what cleanup must do is unverifiable"
    ;;
esac
CHECKED=$((CHECKED + 1))
pass "a launch that never becomes an agent exits 4 and disposes of its workspace as the release allows on $V"

[ "$CHECKED" -ge 10 ] || fail "FM_AUTOSTART_HERDR_LIVE=1 completed fewer checks ($CHECKED) than expected"
pass "live Herdr boot-autostart guard complete: $CHECKED checks on $V in isolated session $SESSION"
