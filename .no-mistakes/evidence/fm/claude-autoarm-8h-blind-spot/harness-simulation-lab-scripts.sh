#!/usr/bin/env bash
# Harness-simulation lab for the Claude Stop auto-arm declared-timeout renewal.
#
# It reproduces exactly what Claude Code does to an asyncRewake Stop hook: the
# hook runs in its own process group and, at the DECLARED timeout, the harness
# SIGTERMs that whole group (hook + arm + watcher). No real Claude session is
# launched; the harness behavior is the only thing simulated.
set -u

LAB=/tmp/fm-renewal-lab
REPO=$1              # firstmate worktree (target commit)
BASE_SRC=$2          # materialized base-commit tree
OUTDIR=$3
DECLARED=${4:-25}    # simulated .claude/settings.json "timeout" (seconds)
BUDGET=${5:-10}      # FM_CLAUDE_AUTOARM_RENEWAL_BUDGET
BASE_REF=43ead08bb3833f1f5753e56a8b04c1b253e99b70

FAKEBIN=$LAB/fakebin
mkdir -p "$FAKEBIN" "$OUTDIR"
[ -e "$FAKEBIN/claude" ] || ln -s /bin/bash "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
printf '%s\n' '{"session_id":"sess-lab","stop_hook_active":false}' > "$OUTDIR/payload.json"

build_home() {  # <home> <src-bin>
  local home=$1 src=$2 f
  rm -rf "$home"; mkdir -p "$home/bin" "$home/state"
  git init -q "$home"
  git -C "$home" -c user.name=fmlab -c user.email=fmlab@example.invalid commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  for f in fm-claude-stop-autoarm.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
           fm-wake-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh \
           fm-lock.sh fm-watch-arm.sh; do
    cp "$src/$f" "$home/bin/$f"
  done
  chmod +x "$home/bin/"*.sh
  cat > "$home/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
# Parked stand-in watcher: publish a verifiable singleton lock and a fresh
# beacon, then block the way a quiet supervised park does.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$$" > "$STATE/.watch.lock/pid-identity"
trap 'exit 143' TERM
while :; do touch "$STATE/.last-watcher-beat"; sleep 1; done
SH
  chmod +x "$home/bin/fm-watch.sh"
  : > "$home/state/task.meta"   # work in flight -> supervision needed
}

FIRE_RC=
FIRE_LEADER=
# Start one Stop firing in its own process group, exactly as Claude Code does.
start_stop() {  # <home> <label> <budget>
  local home=$1 label=$2 budget=$3 i
  rm -f "$OUTDIR/$label.pid" "$OUTDIR/$label.harness"
  setsid env FM_HOME="$home" FM_CLAUDE_AUTOARM_RENEWAL_BUDGET="$budget" \
    "$FAKEBIN/claude" -c '
        printf "%s\n" "$$" > "$FM_LAB_PIDFILE"
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' < "$OUTDIR/payload.json" > "$OUTDIR/$label.stdout" 2> "$OUTDIR/$label.stderr" &
  FIRE_JOB=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    FIRE_LEADER=$(cat "$OUTDIR/$label.pid" 2>/dev/null || true)
    [ -n "$FIRE_LEADER" ] && break
    sleep 0.3
  done
}
export FM_LAB_PIDFILE=

# Run one firing to completion under a harness that enforces DECLARED by
# group-SIGTERM, the way Claude Code enforces a command hook's timeout.
fire_stop() {  # <home> <label> <budget>
  local home=$1 label=$2 budget=$3 killer
  export FM_LAB_PIDFILE="$OUTDIR/$label.pid"
  start_stop "$home" "$label" "$budget"
  (
    sleep "$DECLARED"
    kill -TERM "-$FIRE_LEADER" 2>/dev/null
    printf 'harness: declared timeout %ss reached - SIGTERM to the hook-owned process group %s\n' \
      "$DECLARED" "$FIRE_LEADER" > "$OUTDIR/$label.harness"
  ) &
  killer=$!
  FIRE_RC=0
  wait "$FIRE_JOB" || FIRE_RC=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
}

watcher_state() {  # <home>
  local home=$1 pid age
  pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    age=$(( $(date +%s) - $(stat -c %Y "$home/state/.last-watcher-beat" 2>/dev/null || echo 0) ))
    printf 'watcher pid=%s LIVE, beacon_age=%ss -> home is supervised\n' "$pid" "$age"
  else
    printf 'watcher pid=%s not running\n' "${pid:-none}"
  fi
}

trim_row() { sed 's/lock_before=[^\t]*/lock_before=<identity>/; s/lock_after=[^\t]*/lock_after=<identity>/'; }

echo "=============================================================================="
echo "Claude Stop auto-arm: declared-timeout blind spot vs. continuity renewal"
echo "Simulated declared Stop-hook timeout: ${DECLARED}s  (real registration: 28800s)"
echo "Renewal budget under test:            ${BUDGET}s   (real default: 27000s)"
echo "Real bin/fm-claude-stop-autoarm.sh + real bin/fm-watch-arm.sh + parked stub watcher."
echo "Only Claude Code's own behavior is simulated: own process group, group-TERM at"
echo "the declared timeout, and a Stop firing after each turn end."
echo "=============================================================================="

echo
echo "### BEFORE - base commit $(git -C "$REPO" rev-parse --short $BASE_REF), one Stop firing, session left idle"
BEFORE=$LAB/home-before
build_home "$BEFORE" "$BASE_SRC/bin"
t0=$(date +%s)
fire_stop "$BEFORE" before ""
t1=$(date +%s)
sleep 2   # let the closing arm finish appending its lifecycle row
echo "$(cat "$OUTDIR/before.harness" 2>/dev/null)"
echo "hook exit code: $FIRE_RC  (143 = killed by the harness group SIGTERM; no exit-2 rewake)"
if [ -s "$OUTDIR/before.stderr" ]; then
  echo "hook stderr:"; sed 's/^/    | /' "$OUTDIR/before.stderr"
else
  echo "hook stderr: <empty> - the session is told nothing and never wakes"
fi
echo "elapsed: $((t1-t0))s"
echo "lifecycle ledger (state/.watch-cycle-exits.log):"
trim_row < "$BEFORE/state/.watch-cycle-exits.log" | sed 's/^/    /'
echo "supervision now: $(watcher_state "$BEFORE") -> home is BLIND until the next real turn end"
echo ">>> BEFORE: at the declared bound the group kill closed arm and watcher as"
echo ">>> 'reason=arm-interrupted ... successor=none' and nothing re-armed."

echo
echo "### AFTER - target commit $(git -C "$REPO" rev-parse --short HEAD), same idle session, no captain turn"
AFTER=$LAB/home-after
build_home "$AFTER" "$REPO/bin"
start=$(date +%s)
for cycle in 1 2 3; do
  echo
  echo "--- Stop firing #$cycle (t+$(( $(date +%s) - start ))s) ---"
  fire_stop "$AFTER" "after-$cycle" "$BUDGET"
  echo "hook exit code: $FIRE_RC  (2 = rewake; Claude renders this hook's stderr as 'Stop hook feedback')"
  echo "hook stderr, verbatim - what the idle session is shown:"
  sed 's/^/    | /' "$OUTDIR/after-$cycle.stderr"
  echo "epoch ledger: $(cat "$AFTER/state/.claude-autoarm-epoch")"
  [ -s "$OUTDIR/after-$cycle.harness" ] && echo "$(cat "$OUTDIR/after-$cycle.harness")"
  sleep 1
  echo "after the renewal close: $(watcher_state "$AFTER") - closed with its arm, no orphan"
  echo "(the model drains the wake queue, finds nothing, ends the turn -> next Stop fires)"
  sleep 2
done

echo
echo "--- Stop firing #4 (t+$(( $(date +%s) - start ))s): parked, and left running past the declared bound ---"
export FM_LAB_PIDFILE="$OUTDIR/after-4.pid"
start_stop "$AFTER" after-4 600
sleep 8
echo "t+$(( $(date +%s) - start ))s (> ${DECLARED}s declared bound): $(watcher_state "$AFTER")"
echo "(BEFORE, the same session had no watcher at all from t+${DECLARED}s onward)"
echo
echo "lifecycle ledger across the whole idle period (state/.watch-cycle-exits.log):"
trim_row < "$AFTER/state/.watch-cycle-exits.log" | sed 's/^/    /'
echo
printf 'continuity-renewal rows: %s    arm-interrupted rows: %s\n' \
  "$(grep -c 'reason=continuity-renewal' "$AFTER/state/.watch-cycle-exits.log")" \
  "$(grep -c 'reason=arm-interrupted' "$AFTER/state/.watch-cycle-exits.log" || true)"
echo ">>> AFTER: every close is 'reason=continuity-renewal ... successor=stop-renewal',"
echo ">>> each handed to a fresh Stop firing, and the home is still supervised past the"
echo ">>> declared bound that used to end supervision until the next real turn."

echo
echo "### teardown - the harness kills the hook-owned group when the session ends"
kill -TERM "-$FIRE_LEADER" 2>/dev/null || true
sleep 2
wpid=$(cat "$AFTER/state/.watch.lock/pid" 2>/dev/null || true)
if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
  echo "ORPHAN watcher survived teardown: pid $wpid"
else
  echo "watcher pid ${wpid:-none} did not survive teardown"
fi
if ps -eo args | grep -F "$LAB/home-" | grep -v grep > /dev/null; then
  echo "ORPHAN lab processes:"; ps -eo pid,args | grep -F "$LAB/home-" | grep -v grep
else
  echo "no surviving lab fm-* process (no-orphan teardown)"
fi
#!/usr/bin/env bash
# Operator-visible budget guard: what a home is told when FM_CLAUDE_AUTOARM_RENEWAL_BUDGET
# would let the arm park until Claude Code's declared-timeout kill.
set -u
LAB=/tmp/fm-renewal-lab
REPO=$1
HOME_DIR=$LAB/home-budget
FAKEBIN=$LAB/fakebin
export PATH="$FAKEBIN:$PATH"

rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" -c user.name=fmlab -c user.email=fmlab@example.invalid commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
for f in fm-claude-stop-autoarm.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
         fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh fm-lock.sh; do
  cp "$REPO/bin/$f" "$HOME_DIR/bin/$f"
done
chmod +x "$HOME_DIR/bin/"*.sh
cat > "$HOME_DIR/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture actionable\n'
SH
chmod +x "$HOME_DIR/bin/fm-watch-arm.sh"

declared=$(awk '
  { text = text $0 " " }
  END {
    depth = 0
    for (i = 1; i <= length(text); i++) {
      c = substr(text, i, 1)
      if (c == "{") { start[++depth] = i; continue }
      if (c != "}" || depth == 0) continue
      object = substr(text, start[depth], i - start[depth] + 1); depth--
      if (object ~ /fm-claude-stop-autoarm\.sh/ && match(object, /"timeout"[[:space:]]*:[[:space:]]*[0-9]+/)) {
        found = substr(object, RSTART, RLENGTH); sub(/^[^0-9]*/, "", found); print found; exit
      }
    }
  }' "$REPO/.claude/settings.json")

echo "=============================================================================="
echo "Renewal budget guard - the value that decides whether a home parks past the kill timer"
echo "=============================================================================="
echo "declared Stop-hook timeout in the tracked .claude/settings.json: ${declared}s"
echo "  (at this bound Claude Code SIGTERMs the hook's whole process group, watcher included)"
echo
for budget in "$declared" 00 000 not-a-number 0 999999999 27000 3600; do
  : > "$HOME_DIR/state/task.meta"
  out=$(printf '%s\n' '{"session_id":"sess-budget","stop_hook_active":false}' \
    | FM_HOME="$HOME_DIR" FM_CLAUDE_AUTOARM_RENEWAL_BUDGET="$budget" "$FAKEBIN/claude" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); rc=$?
  printf 'FM_CLAUDE_AUTOARM_RENEWAL_BUDGET=%-12s -> exit %s\n' "$budget" "$rc"
  notice=$(printf '%s\n' "$out" | grep -F 'refusing FM_CLAUDE_AUTOARM_RENEWAL_BUDGET' || true)
  if [ -n "$notice" ]; then
    printf '    refused on stderr: %s\n' "$notice"
  else
    printf '    accepted silently: the arm may park for %ss, below the %ss kill timer\n' "$budget" "$declared"
  fi
done
echo
echo "An idle home (nothing in flight) must stay byte-for-byte silent whatever the fleet exports:"
rm -f "$HOME_DIR/state/task.meta"
out=$(printf '%s\n' '{"session_id":"sess-budget","stop_hook_active":false}' \
  | FM_HOME="$HOME_DIR" FM_CLAUDE_AUTOARM_RENEWAL_BUDGET=99999 "$FAKEBIN/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
    ' 2>&1); rc=$?
printf '    FM_CLAUDE_AUTOARM_RENEWAL_BUDGET=99999 on an idle home -> exit %s, output: %s\n' "$rc" "${out:-<empty>}"
#!/usr/bin/env bash
# Decision (iii): the ceiling must bind the UNCONFIGURED default too, so a home
# that lowers the declared settings.json timeout (and the matching ceiling)
# cannot keep parking on a stale default that outlives the kill timer.
set -u
LAB=/tmp/fm-renewal-lab
HOME_DIR=$LAB/home-budget
FAKEBIN=$LAB/fakebin
export PATH="$FAKEBIN:$PATH"
: > "$HOME_DIR/state/task.meta"
run_at_ceiling() {  # <ceiling> <requested>
  sed -i "s/^RENEWAL_BUDGET_CEILING=.*/RENEWAL_BUDGET_CEILING=$1/" "$HOME_DIR/bin/fm-claude-stop-autoarm.sh"
  printf '%s\n' '{"session_id":"sess-ceiling","stop_hook_active":false}' \
    | FM_HOME="$HOME_DIR" FM_CLAUDE_AUTOARM_RENEWAL_BUDGET="$2" "$FAKEBIN/claude" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 | grep -F 'refusing FM_CLAUDE_AUTOARM_RENEWAL_BUDGET' | sed 's/.*below the /fallback for a /; s/ timeout declared for this hook, at which Claude Code kills the arm and its watcher unsupervised;/ ceiling:/; s/\.$//'
}
echo
echo "=============================================================================="
echo "The declared-timeout ceiling binds the unconfigured default, not just requests"
echo "=============================================================================="
echo "shipped ceiling 28800s (mirrors the tracked registration):"
echo "    $(run_at_ceiling 28800 28800)"
echo "ceiling lowered to 3600s, as a home would do alongside a lowered declared timeout:"
echo "    $(run_at_ceiling 3600 3600)"
echo "ceiling lowered to 600s:"
echo "    $(run_at_ceiling 600 600)"
echo
echo ">>> the fallback every unconfigured home parks for follows the ceiling down and"
echo ">>> stays below it, so a lowered kill timer can never leave a stale 27000s default"
echo ">>> parked past the deadline - the original 8h blind spot in miniature."
