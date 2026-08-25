#!/usr/bin/env bash
# Live Herdr agent-recognition recalibration harness (live-harness-optin family).
#
# Track U phases U0 (measurement) and U2 (the recognition fix). Herdr's per-pane
# agent recognition is a harness-dependent surface: whether a live Claude crew
# registers an agent record, whether `pane report-agent` drives and sticks a
# state, and whether the OS process probe can tell a live agent from a husk are
# all things Herdr and Claude emit, not things a stub can prove. This harness
# ports the design report's exp1-exp7 registration counterfactuals
# (data/design-herdr-interface/report.md, appendix) onto the installed
# Herdr/Claude.
#
# U0 measured the false-negative: on herdr 0.8.2 a live Claude crew registers no
# agent record, so the trunk classifier read every live crew as no-agent/dead.
# U2 composed the reality-touching foreground-process probe back into
# fm_backend_herdr_pane_agent_state so a live Claude crew reads live/alive while
# a genuine bare shell still reads no-agent/dead. This harness now guards BOTH
# halves live: it proves the underlying herdr environment still does NOT register
# a Claude crew (so the fix is doing real work), AND that the composed classifier
# now returns the correct four-way verdict for a live crew, a bare-shell husk, a
# report-agent-registered pane, and a structurally gone pane. A Herdr or Claude
# upgrade that changes any of it fails LOUDLY, naming both versions, instead of
# letting the liveness/husk/spawn/exit classifiers drift silently.
#
# It exercises the real bin/backends/herdr.sh classifiers, never source bytes,
# and every Herdr call - including the adapter's own - is routed through the
# guarded lab helper (bin/fm-herdr-lab.sh): leading --session, refuse-default,
# before/after fleet-state tripwire. The captain's default session is untouched.
#
# Run explicitly after a Herdr or Claude upgrade, and before trusting a
# refreshed docs/verification/runtime-backends.md "Herdr agent recognition"
# entry:
#
#   FM_HERDR_RECAL_LIVE=1 tests/fm-herdr-recalibration-live-e2e.test.sh
#
# It launches real (cheap, idle, un-prompted) Claude panes, so it is opt-in and
# self-skips without the env var, exactly like the other live-harness guards.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_RECAL_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_RECAL_LIVE=1 to run the live Herdr agent-recognition recalibration harness"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_HERDR_RECAL_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_HERDR_RECAL_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_HERDR_RECAL_LIVE=1 but Claude Code is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_HERDR_RECAL_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-recal-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-recal-live.XXXXXX")
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
# lab helper: the adapter appends a TRAILING --session, which the helper refuses
# as caller-supplied, so this shim strips it and re-issues through `run`, which
# supplies the required LEADING --session itself. A foreign session is refused.
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

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

new_pane() {  # <label>
  lab tab create --workspace "$WS" --cwd "$WORK" --label "$1" --no-focus \
    | jq -er '.result.root_pane.pane_id'
}
seq_ns() { date +%s%N; }
wait_claude_ready() {  # <pane>
  lab pane wait-output "$1" --regex 'bypass permissions' --timeout 60000 >/dev/null 2>&1
  sleep 3
}

WS=$(lab workspace create --cwd "$WORK" --label fm-recal --no-focus \
  | jq -er '.result.workspace.workspace_id') \
  || fail "could not create the isolated recalibration workspace"

# --- F. Presentation projection version floor (Q4) ---------------------------
# 0.8.0/protocol 19 is the default-on floor; 0.8.2/protocol 20 must clear it, so
# an unconfigured home projects each task into its own workspace.
FLOOR_VER=$(printf '%s' "$HERDR_VER" | awk '{print $2}')
FLOOR_PROTO=$(lab status --json 2>/dev/null | jq -r '.server.protocol // empty')
[ -n "$FLOOR_PROTO" ] || fail "could not read the running Herdr server protocol"
floor_rc=0
fm_backend_herdr_release_floor_verdict "$FLOOR_PROTO" "$FLOOR_VER" || floor_rc=$?
[ "$floor_rc" = 0 ] \
  || fail "presentation floor: $V (protocol $FLOOR_PROTO) is not classified default-on (verdict rc=$floor_rc); the U0 premise that projection is default-on above 0.8.0 no longer holds - re-measure"
CHECKED=$((CHECKED + 1))
pass "presentation projection is default-on (floor $FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION/proto $FM_BACKEND_HERDR_MIN_PRESENTATION_PROTOCOL cleared) on $V"

# --- A. report-agent is the load-bearing fix primitive (exp3/exp6) -----------
# On an UNCLAIMED pane, `report-agent --state` must register the pane, drive the
# adapter's `live` verdict, and STICK (Herdr must not override it from its own
# screen detection). This is the primitive U2's reporter is built on; if it ever
# stops working the whole recognition fix is void.
BARE=$(new_pane bare) || fail "could not create the bare-shell pane"
sleep 2
base_state=$(fm_backend_herdr_pane_agent_state "$SESSION" "$BARE")
[ "$base_state" = no-agent ] \
  || fail "report-agent primitive: a fresh bare shell classified '$base_state', expected no-agent, on $V"
lab pane report-agent "$BARE" --source firstmate --agent claude --state working --seq "$(seq_ns)" >/dev/null 2>&1 \
  || fail "report-agent working was rejected on an unclaimed pane on $V"
st_working=$(fm_backend_herdr_pane_agent_state "$SESSION" "$BARE")
[ "$st_working" = live ] \
  || fail "report-agent primitive: after report working, an unclaimed pane classified '$st_working', expected live, on $V - the fix primitive is broken"
sleep 6
st_stick=$(fm_backend_herdr_pane_agent_state "$SESSION" "$BARE")
[ "$st_stick" = live ] \
  || fail "report-agent primitive: reported state did not stick after 6s (classified '$st_stick', expected live) on $V - Herdr is now overriding firstmate-reported state"
lab pane report-agent "$BARE" --source firstmate --agent claude --state blocked --seq "$(seq_ns)" >/dev/null 2>&1 \
  || fail "report-agent blocked was rejected on an unclaimed pane on $V"
blk=$(lab pane get "$BARE" | jq -r '.result.pane.agent_status // empty')
[ "$blk" = blocked ] \
  || fail "report-agent primitive: after report blocked, agent_status was '$blk', expected blocked, on $V"
CHECKED=$((CHECKED + 1))
pass "report-agent drives and sticks working/blocked on an unclaimed pane (the U2 fix primitive works) on $V"

# --- B. The recognition fix: a live claimed Claude crew reads live/alive ------
# A live pane-typed Claude crew (fm-spawn style, integration-claimed) registers
# NO agent record on herdr 0.8.2, so the trunk metadata read alone said no-agent
# and the recovery-grade classifier said dead - the false-negative that misfired
# spawn start-confirmation, fm-control exit-verification, the liveness sweep, and
# wake-resident raise confirmation. U2 composed the foreground-process reality
# probe back in, so the SAME crew now reads live/alive. This asserts the raw
# herdr environment STILL does not register the crew (the fix is doing real
# work), AND that the composed classifier now recognizes it.
CLAUDE=$(new_pane claude-live) || fail "could not create the live-Claude pane"
lab pane send-text "$CLAUDE" "claude --dangerously-skip-permissions" >/dev/null \
  || fail "could not type the Claude launch command"
lab pane send-keys "$CLAUDE" enter >/dev/null || fail "could not submit the Claude launch command"
wait_claude_ready "$CLAUDE"
# Prove Claude is genuinely live in the pane before trusting any verdict.
proc_state=$(fm_backend_herdr_pane_process_state "$SESSION" "$CLAUDE")
[ "$proc_state" = live ] \
  || fail "the live-Claude pane's process probe read '$proc_state', expected live; Claude ($CLAUDE_VER) never came up in the pane on $HERDR_VER"
claude_fg=$(lab pane process-info --pane "$CLAUDE" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].argv[0] // empty')
case "$claude_fg" in
  *claude*) : ;;
  *) fail "the live-Claude pane's foreground process was '$claude_fg', not Claude; Claude ($CLAUDE_VER) never came up in the pane on $HERDR_VER, so the recognition verdict cannot be trusted" ;;
esac
# The underlying herdr environment must still leave the crew unregistered: the
# fix targets exactly this gap, and if herdr began registering Claude (e.g. a v8
# integration landed) the whole recalibration must be re-measured.
raw_agent=$(lab agent get "$CLAUDE" 2>&1 | jq -rc '.error.code // "record"')
[ "$raw_agent" = agent_not_found ] \
  || fail "herdr now registers the Claude crew (agent get -> '$raw_agent') on $V; the v7/v8 integration environment changed - re-run the U0 recalibration and update docs/verification/runtime-backends.md before trusting the composed classifier"
# The composed classifier must now recognize the live crew from its process.
claude_meta=$(fm_backend_herdr_pane_agent_state "$SESSION" "$CLAUDE")
claude_recovery=$(fm_backend_herdr_agent_state "$SESSION:$CLAUDE")
[ "$claude_meta" = live ] \
  || fail "recognition fix regressed on $V: a live claimed Claude crew classified metadata '$claude_meta', expected live (herdr agent get is still agent_not_found, so only the process probe can recognize it)"
[ "$claude_recovery" = alive ] \
  || fail "recognition fix regressed on $V: a live claimed Claude crew classified recovery '$claude_recovery', expected alive"
CHECKED=$((CHECKED + 1))
pass "recognition fix: a live claimed Claude crew (herdr still answers agent_not_found) reads metadata live / recovery alive on $V"

# --- C. The four-way husk cell + the process discriminator (U2 signal) --------
# The negative cell: a GENUINE bare shell (no report-agent, no Claude) must still
# read no-agent / dead so a restored husk stays reclaimable - the fix must not
# turn every pane live. And the process probe - the signal U2 composed back in -
# must distinguish the live Claude above from that shell, because herdr's
# metadata alone cannot (both answer agent_not_found). BARE from A is now
# report-agent-registered, so a fresh husk pane is used for the negative cell.
HUSK=$(new_pane husk) || fail "could not create the bare-shell husk pane"
sleep 2
husk_meta=$(fm_backend_herdr_pane_agent_state "$SESSION" "$HUSK")
husk_recovery=$(fm_backend_herdr_agent_state "$SESSION:$HUSK")
[ "$husk_meta" = no-agent ] \
  || fail "four-way husk cell regressed on $V: a genuine bare shell classified metadata '$husk_meta', expected no-agent (a real husk must stay reclaimable even though a live crew is now recognized as live)"
[ "$husk_recovery" = dead ] \
  || fail "four-way husk cell regressed on $V: a genuine bare shell classified recovery '$husk_recovery', expected dead (reclaimable)"
husk_fg=$(lab pane process-info --pane "$HUSK" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].name // empty')
case "$claude_fg" in
  *claude*) : ;;
  *) fail "U2 signal: the live-Claude pane's foreground process was '$claude_fg', which does not identify Claude, on $V - the process-probe fix direction cannot distinguish a live crew from a husk" ;;
esac
case "$husk_fg" in
  bash|sh|zsh|dash|ash|fish|-bash|-sh|-zsh|*/bash|*/sh|*/zsh) : ;;
  *) fail "U2 signal: the bare-shell husk's foreground process was '$husk_fg', expected a shell, on $V (its classifier verdict was correctly no-agent, but the shape moved)" ;;
esac
CHECKED=$((CHECKED + 1))
pass "four-way husk cell: a genuine bare shell reads no-agent/dead while the process probe separates the live Claude crew ('$claude_fg') from the shell ('$husk_fg') on $V"

# --- D. report-agent is IGNORED on an integration-claimed pane (exp7) ---------
# The same call that worked in A is silently ignored on the claimed Claude pane,
# so a fix cannot simply report state onto a claimed crew - it must un-claim
# first (design report 3.1). The "ignored" signal is the RAW herdr registry:
# agent get stays agent_not_found and agent_status never becomes the reported
# state. (The composed classifier now reads this pane as live from its process -
# that is crew recognition, not report-agent acceptance, which is why the raw
# registry, not the classifier, is the probe here.)
lab pane report-agent "$CLAUDE" --source firstmate --agent claude --state working --seq "$(seq_ns)" >/dev/null 2>&1 || true
lab pane report-agent "$CLAUDE" --source herdr:claude --agent claude --state working --seq "$(seq_ns)" >/dev/null 2>&1 || true
claimed_raw=$(lab agent get "$CLAUDE" 2>&1 | jq -rc '.error.code // "record"')
[ "$claimed_raw" = agent_not_found ] \
  || fail "claimed-ignore no longer holds on $V: report-agent onto an integration-claimed Claude pane produced a registry record (agent get -> '$claimed_raw'); the un-claim requirement may be obsolete - re-measure"
claimed_status=$(lab pane get "$CLAUDE" | jq -r '.result.pane.agent_status // empty')
[ "$claimed_status" != working ] \
  || fail "claimed-ignore no longer holds on $V: report-agent set agent_status=working on an integration-claimed Claude pane"
CHECKED=$((CHECKED + 1))
pass "report-agent onto an integration-claimed Claude pane is still ignored by herdr (un-claim remains required) on $V"

# --- E. `agent start --kind claude` does not yield a usable registration (exp2)
# The native start path timed out on 0.7.5 and again on 0.8.2; whatever it does,
# it does not leave a cleanly REGISTERED live Claude agent for our pane-typed
# model (herdr agent get is still agent_not_found). With the reality probe
# composed in, the classifier's verdict now tracks what is actually running: a
# live Claude process reads live, a bare shell reads no-agent.
ASTART=$(new_pane astart) || fail "could not create the agent-start pane"
start_code=$(lab agent start probe --kind claude --pane "$ASTART" --timeout 15000 -- --dangerously-skip-permissions 2>&1 \
  | jq -rc '.error.code // "ok"' 2>/dev/null || printf 'unparsed')
sleep 2
astart_raw=$(lab agent get "$ASTART" 2>&1 | jq -rc '.error.code // "record"')
[ "$astart_raw" = agent_not_found ] \
  || fail "agent start behavior changed on $V: it left a registered agent (agent get -> '$astart_raw', start result '$start_code') - the native start path may now register Claude, re-measure"
astart_meta=$(fm_backend_herdr_pane_agent_state "$SESSION" "$ASTART")
astart_fg=$(lab pane process-info --pane "$ASTART" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].argv[0] // .result.process_info.foreground_processes[0].name // empty')
case "$astart_fg" in
  *claude*)
    [ "$astart_meta" = live ] \
      || fail "composed classifier on $V: the agent-start pane runs Claude ('$astart_fg') but classified '$astart_meta', expected live" ;;
  *)
    [ "$astart_meta" = no-agent ] \
      || fail "composed classifier on $V: the agent-start pane runs no harness ('$astart_fg') but classified '$astart_meta', expected no-agent" ;;
esac
CHECKED=$((CHECKED + 1))
pass "agent start --kind claude leaves the pane unregistered (result '$start_code'); the composed classifier tracks the real process ('$astart_fg' -> $astart_meta) on $V"

# --- G. Composer/detection surface still classifies an idle Claude (exp-composer)
# `pane read --source detection` + `agent explain --file` is the state feed the
# reporter design leans on; confirm the manifest still resolves an idle Claude.
CAP="$WORK/detection.txt"
lab pane read "$CLAUDE" --source detection --lines 40 > "$CAP" 2>/dev/null || fail "detection read failed on $V"
explain=$(lab agent explain --file "$CAP" --agent claude --json 2>/dev/null | jq -rc '.state // empty')
[ "$explain" = idle ] \
  || fail "detection surface changed on $V: agent explain --file classified an idle Claude screen as '$explain', expected idle - the manifest/detection feed the reporter design relies on has drifted"
CHECKED=$((CHECKED + 1))
pass "agent explain --file classifies an idle Claude screen as idle (detection feed intact) on $V"

[ "$CHECKED" -ge 7 ] || fail "FM_HERDR_RECAL_LIVE=1 completed fewer checks ($CHECKED) than expected"
pass "Herdr agent-recognition recalibration complete: $CHECKED checks on $V in isolated session $SESSION"
