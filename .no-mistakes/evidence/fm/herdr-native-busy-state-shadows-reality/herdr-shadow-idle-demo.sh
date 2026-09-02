#!/usr/bin/env bash
# Reproduction driver for the 2026-09-01 incident: a herdr-backed claude
# secondmate is mid-turn (its pane renders Claude's busy footer) while herdr's
# agent REGISTRY answers idle, because firstmate launches crew by TYPING the
# launch command into a pane rather than `herdr agent start`.
#
# Drives the real firstmate CLI (bin/fm-wake-resident-poll.sh,
# bin/fm-wake-resident.sh standdown) and the real pending-reply reconciliation
# tick against a fake herdr CLI that models exactly that divergence, and prints
# the captain-facing output. Run it against any checkout: ./demo.sh <repo-root>
set -u
ROOT=$1
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-shadow.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

SESSION=default
PANE=w1:p2
TARGET="$SESSION:$PANE"
NAME=hibit
# What the pane actually renders while Claude is mid-turn.
BUSY_FOOTER='  ✻ Wibbling… (9m 41s · esc to interrupt)'

# --- the fake herdr CLI: registry says idle, pane says busy ------------------
FAKEBIN="$SCRATCH/bin"
mkdir -p "$FAKEBIN"
HERDR_LOG="$SCRATCH/herdr.log"
: > "$HERDR_LOG"
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> '$HERDR_LOG'
case "\${1:-} \${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.8.2","protocol":16},"server":{"running":true}}\n' ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "\${3:-}" ;;
  "pane read")
    # The reality-touching read: Claude's rendered busy footer.
    printf '%s\n' 'I will work through this step by step.'
    printf '%s\n' ''
    printf '%s\n' '$BUSY_FOOTER' ;;
  "pane send-text"|"pane send-keys"|"pane run") : ;;
  "agent get")
    # herdr's agent REGISTRY for a pane-TYPED agent: a shadow of reality.
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  "pane process-info")
    printf '{"result":{"process":{"name":"claude"}}}\n' ;;
  "session list"*)
    printf '{"sessions":[{"name":"default","running":true}]}\n' ;;
  "workspace list")
    printf '{"result":{"workspaces":[]}}\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/herdr"
PATH="$FAKEBIN:$PATH"
export PATH

# --- a firstmate home with one herdr-backed wake-resident secondmate --------
HOME_DIR="$SCRATCH/main"
SUB="$SCRATCH/homes/$NAME"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$SUB/state" "$SUB/data"
printf '%s\n' "$NAME" > "$SUB/.fm-secondmate-home"
printf '# Firstmate\n' > "$SUB/AGENTS.md"
printf '# Backlog\n\n## In flight\n- [ ] keep-me\n' > "$SUB/data/backlog.md"
printf 'working: drafting the delivery note\n' > "$HOME_DIR/state/$NAME.status"
printf -- "- %s - advisor charter (home: %s; scope: advice; projects: ; added 2026-08-01)\n" \
  "$NAME" "$SUB" > "$HOME_DIR/data/secondmates.md"
cat > "$HOME_DIR/state/$NAME.meta" <<META
window=$TARGET
backend=herdr
worktree=$SUB
harness=claude
kind=secondmate
mode=secondmate
yolo=off
home=$SUB
META
chmod 600 "$HOME_DIR/state/$NAME.meta"

# A fabricated FM_ROOT holding only the two scripts the lifecycle shells out to.
FAKE_ROOT="$SCRATCH/fakeroot"
mkdir -p "$FAKE_ROOT/bin"
cat > "$FAKE_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >> "$FM_FAKE_SPAWN_LOG"
SH
cat > "$FAKE_ROOT/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf 'send %s\n' "$*" >> "$FM_FAKE_SEND_LOG"
SH
chmod +x "$FAKE_ROOT/bin/fm-spawn.sh" "$FAKE_ROOT/bin/fm-send.sh"
export FM_FAKE_SPAWN_LOG="$SCRATCH/spawn.log" FM_FAKE_SEND_LOG="$SCRATCH/send.log"
: > "$FM_FAKE_SPAWN_LOG"; : > "$FM_FAKE_SEND_LOG"

fm_env() {
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" "$@"
}

fm_env "$ROOT/bin/fm-wake-resident.sh" enable "$NAME" --idle-secs 1800 >/dev/null 2>&1
# Backdate every activity signal so the mate reads as 2h quiet - past the gate.
WHEN=$(( $(date +%s) - 7200 ))
printf 'raised_at=%s\n' "$WHEN" > "$HOME_DIR/state/$NAME.wake-resident"
chmod 600 "$HOME_DIR/state/$NAME.wake-resident"
touch -d "@$WHEN" "$HOME_DIR/state/$NAME.meta"
find "$SUB/state" -mindepth 1 -maxdepth 1 -exec touch -d "@$WHEN" {} + 2>/dev/null || true

echo "================================================================="
echo "SCENARIO  secondmate '$NAME' on backend=herdr target=$TARGET harness=claude"
echo "          quiet 120m (past the 30m stand-down threshold)"
echo "-----------------------------------------------------------------"
printf 'herdr registry  : agent get -> agent_status=%s\n' \
  "$(herdr agent get "$PANE" --session "$SESSION" | jq -r '.result.agent.agent_status')"
printf 'the pane itself : %s\n' "$BUSY_FOOTER"
echo "================================================================="
echo
echo "### 1. what the captain's watcher prints (bin/fm-wake-resident-poll.sh)"
out=$(fm_env "$ROOT/bin/fm-wake-resident-poll.sh" 2>&1)
if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(no output - the poll stayed silent)"; fi
echo
echo "### 2. bin/fm-wake-resident.sh standdown $NAME"
out=$(fm_env "$ROOT/bin/fm-wake-resident.sh" standdown "$NAME" 2>&1); rc=$?
printf '%s\n' "$out"
printf '(exit status %s)\n' "$rc"
echo
echo "### 3. pending-reply reconciliation over the same endpoint"
PR="$SCRATCH/pr"
mkdir -p "$PR/state"
cp "$HOME_DIR/state/$NAME.meta" "$PR/state/$NAME.meta"
printf 'working: drafting the delivery note\n' > "$PR/state/$NAME.status"
NUDGE_LOG="$SCRATCH/nudges.log"
: > "$NUDGE_LOG"
tick_script="$SCRATCH/tick.sh"
cat > "$tick_script" <<SH
set -u
. "$ROOT/bin/fm-pending-reply-lib.sh"
state="$PR/state"
# The repost ladder's send goes through this hook, so the transcript can show
# exactly what firstmate would have typed into the working agent's pane.
record_nudge() { printf 'to %s: %s\n' "\$1" "\$2" >> "$NUDGE_LOG"; }
export -f record_nudge
export FM_PENDING_REPLY_SEND_HOOK=record_nudge
export FM_PENDING_REPLY_NOW=9300
corr=\$(fm_pending_reply_create "$PR" "\$state" "$NAME" "please summarise the delivery note")
fm_pending_reply_mark_delivered "\$state" "\$corr"
rec=\$(fm_pending_reply_path "\$state" "\$corr")
printf 'delivery observation : %s\n' \\
  "\$(fm_pending_reply_backend_observation herdr "$TARGET" fm-$NAME claude)"
for n in 1 2 3 4; do
  export FM_PENDING_REPLY_NOW=\$((9300 + n * 1200))
  fm_pending_reply_tick "\$state"
done
printf 'record phase         : %s\n' "\$(fm_pending_reply_get "\$rec" phase)"
SH
fm_env bash "$tick_script" 2>&1
if [ -s "$NUDGE_LOG" ]; then
  echo 'nudges typed at the working agent:'
  sed 's/^/  /' "$NUDGE_LOG"
else
  echo 'nudges typed at the working agent: (none)'
fi
if grep -q '^blocked \[key=' "$PR/state/$NAME.status" 2>/dev/null; then
  echo 'captain-facing status line:'
  grep '^blocked \[key=' "$PR/state/$NAME.status" | sed 's/^/  /'
else
  echo 'captain-facing status line: (none - nothing escalated)'
fi
echo
