#!/usr/bin/env bash
# Operator-level walkthrough of the watcher singleton fix on branch
# fm/watcher-duplicate-cycles-lock-pingpong. Real firstmate processes, real CLI
# surfaces (bin/fm-watch.sh, bin/fm-watch-arm.sh, bin/fm-turnend-guard.sh,
# bin/fm-wake-drain.sh) over hermetic demo homes.
set -u

REPO=${REPO:?set REPO to the firstmate worktree}
WATCH="$REPO/bin/fm-watch.sh"
ARM="$REPO/bin/fm-watch-arm.sh"
GUARD="$REPO/bin/fm-turnend-guard.sh"
DRAIN="$REPO/bin/fm-wake-drain.sh"
LIB="$REPO/bin/fm-wake-lib.sh"

ROOTDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-singleton-demo.XXXXXX")
trap 'rm -rf "$ROOTDIR"' EXIT

hdr()  { printf '\n══════════════════════════════════════════════════════════════════════\n%s\n══════════════════════════════════════════════════════════════════════\n' "$1"; }
step() { printf '\n$ %s\n' "$1"; }
note() { printf '  %s\n' "$1"; }
ok()   { printf '  ✔ %s\n' "$1"; }
bad()  { printf '  ✘ %s\n' "$1"; FAILED=1; }
FAILED=0

FAKEBIN="$ROOTDIR/fakebin"
mkdir -p "$FAKEBIN"

# Safety seam: no real desktop notification can escape this demo.
cat > "$FAKEBIN/wedge-rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
exit 0
REC
chmod +x "$FAKEBIN/wedge-rec"

# Fake tmux backend. capture-pane emits a changing first line so the pane never
# accumulates two identical hashes: the STALE path stays quiet and the scenarios
# below exercise the SIGNAL path deliberately.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0 ;;
  capture-pane) printf 'tick %s\nno-mistakes axi run: validating...\n' "$(date +%s%N)"; exit 0 ;;
  display-message) case "$*" in *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;; esac ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/tmux"

CREW_PROBE="$ROOTDIR/crew-probe-ran"
cat > "$FAKEBIN/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
set -u
: > "$CREW_PROBE"
printf '%s\n' 'state: unknown · source: none · demo default'
exit 0
SH
chmod +x "$FAKEBIN/fm-crew-state.sh"

WINDOW="demo:fm-parked"

make_home() {  # <name>  -> prints home path
  local home="$ROOTDIR/$1" state
  state="$home/state"
  mkdir -p "$state"
  git init -q "$home"
  git -C "$home" -c user.email=demo@example.invalid -c user.name=demo commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  printf 'fm-pr-check-migration-scan-v1\n' > "$state/.pr-check-migration-scan-v1"
  printf 'fm-pr-check-migration-v1\n' > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  printf 'window=%s\nkind=ship\n' "$WINDOW" > "$state/task.meta"
  printf '%s\n' "$home"
}

# Run a firstmate binary against <home> with the hermetic backend wired in.
in_home() {  # <home> <cmd...>
  local home=$1; shift
  env PATH="$FAKEBIN:$PATH" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
      FM_FAKE_TMUX_WINDOW="$WINDOW" \
      FM_WEDGE_ALARM_EXEC="$FAKEBIN/wedge-rec" \
      "$@"
}

lock_pid()  { cat "$1/state/.watch.lock/pid" 2>/dev/null || true; }
alive()     { kill -0 "$1" 2>/dev/null; }
wait_gone() { local p=$1 i=0; while [ "$i" -lt "${2:-250}" ]; do alive "$p" || return 0; sleep 0.1; i=$((i+1)); done; return 1; }
wait_lock() { local h=$1 i=0; while [ "$i" -lt "${2:-120}" ]; do
                [ -s "$h/state/.watch.lock/pid" ] && [ -s "$h/state/.watch.lock/pid-identity" ] \
                  && [ -e "$h/state/.last-watcher-beat" ] && return 0
                sleep 0.1; i=$((i+1)); done; return 1; }

printf 'firstmate watcher singleton - end-to-end walkthrough\n'
printf 'branch : fm/watcher-duplicate-cycles-lock-pingpong (head %s)\n' "$(git -C "$REPO" rev-parse --short HEAD)"
printf 'setup  : hermetic demo homes, fake tmux backend, no real notifications\n'

# =============================================================================
hdr 'SCENARIO 1 - three watchers race admission; exactly one is admitted'
note 'Field symptom: three concurrent watcher processes racing the singleton lock.'
H1=$(make_home home-admission)
step "bin/fm-watch.sh  x3, launched simultaneously against the same home"
for n in 1 2 3; do
  in_home "$H1" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash "$WATCH" > "$ROOTDIR/w$n.out" 2>&1 &
  eval "P$n=$!"
done
sleep 5
HOLDER=$(lock_pid "$H1")
LIVE=0; REFUSED=0
for n in 1 2 3; do
  eval "p=\$P$n"
  if alive "$p"; then LIVE=$((LIVE+1)); MARK='running '; else MARK='exited  '; fi
  LINE=$(head -1 "$ROOTDIR/w$n.out" 2>/dev/null || true)
  printf '  launch #%s  %s  %s\n' "$n" "$MARK" "${LINE:-<no output - it is supervising>}"
  case "$LINE" in "watcher: already running pid $HOLDER") REFUSED=$((REFUSED+1)) ;; esac
done
step "cat state/.watch.lock/pid"
printf '  %s\n' "$HOLDER"
[ "$LIVE" -eq 1 ] && ok "exactly one watcher process survived admission" || bad "expected 1 live watcher, got $LIVE"
[ "$REFUSED" -eq 2 ] && ok "the other two were REFUSED at admission, naming the holder ($HOLDER) back" \
                     || bad "expected 2 admission refusals naming pid $HOLDER, got $REFUSED"
alive "$HOLDER" && ok "the lock names a live watcher - no split cycle, no ping-pong" || bad "lock pid $HOLDER is not alive"
for n in 1 2 3; do eval "p=\$P$n"; kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
kill "$HOLDER" 2>/dev/null || true

# =============================================================================
hdr 'SCENARIO 2 - a takeover mid-iteration: the superseded watcher commits nothing'
note 'Field symptom: a superseded watcher finished its iteration and enqueued /'
note 'absorbed work it no longer owned, so the same parked pane was re-absorbed.'
H2=$(make_home home-takeover)
S2="$H2/state"
rm -f "$CREW_PROBE"
in_home "$H2" FM_POLL=1 FM_SIGNAL_GRACE=8 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  bash "$WATCH" > "$ROOTDIR/incumbent.out" 2>&1 &
ENVPID=$!
wait_lock "$H2" || { printf '%s\n' "$(cat "$ROOTDIR/incumbent.out")"; bad "incumbent never took the lock"; }
INC=$(lock_pid "$H2")
step "bin/fm-watch.sh   # the incumbent watcher for this home"
printf '  watcher pid=%s holds state/.watch.lock (identity published, beacon fresh)\n' "$INC"

step 'fm_supervision_status state/ 300   # is supervision even needed here?'
SUPOUT=$(in_home "$H2" bash -c '. "$1"; fm_supervision_status "$2" 300; printf "FM_SUP_IN_FLIGHT=%s FM_SUP_NEEDED=%s FM_SUP_WATCHER_FRESH=%s\n" "$FM_SUP_IN_FLIGHT" "$FM_SUP_NEEDED" "$FM_SUP_WATCHER_FRESH"' _ "$REPO/bin/fm-supervision-lib.sh" "$S2")
printf '  %s\n' "$SUPOUT"
case "$SUPOUT" in *FM_SUP_NEEDED=true*) ok "supervision IS needed (a task is in flight), so the guard below is a real check" ;;
  *) bad "supervision was not needed - the guard result below would be vacuous" ;; esac

step "bin/fm-turnend-guard.sh   < {\"stop_hook_active\":false}"
GOUT=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 in_home "$H2" bash "$GUARD" 2>&1); GRC=$?
if [ "$GRC" -eq 0 ] && [ -z "$GOUT" ]; then
  printf '  (no output, exit 0)\n'
  ok "turn-end guard is silent: one live watcher holds this home lock, the turn may end"
else
  printf '%s\n' "$GOUT"; bad "turn-end guard did not pass with a healthy single watcher (exit $GRC)"
fi

# Hand-shake onto a poll-iteration boundary so the takeover lands mid-iteration.
: > "$ROOTDIR/beat-ref"
i=0; while [ "$i" -lt 200 ] && [ ! "$S2/.last-watcher-beat" -nt "$ROOTDIR/beat-ref" ]; do sleep 0.1; i=$((i+1)); done
step "echo 'working: crew turn ended' > state/task.status   # a crew signal lands"
printf 'working: crew turn ended\n' > "$S2/task.status"
sleep 2
alive "$INC" && note "the incumbent is now inside its multi-second signal-grace span" \
             || bad "the incumbent exited before the takeover could land mid-iteration"

step "echo <successor-pid> > state/.watch.lock/pid   # a takeover lands mid-iteration"
sleep 600 & SUCC=$!
printf '%s\n' "$SUCC" > "$S2/.watch.lock/pid"
printf '  the singleton now names pid %s; pid %s is superseded\n' "$SUCC" "$INC"

wait_gone "$INC" 300 && ok "the superseded watcher stood down (exit 0) instead of finishing its iteration" \
                     || bad "the superseded watcher was still running"
kill "$ENVPID" 2>/dev/null || true; wait "$ENVPID" 2>/dev/null || true

step 'cat state/.wake-queue ; cat state/.watch-triage.log ; ls state/.seen-*'
printf '  .wake-queue        : %s\n' "$( [ -s "$S2/.wake-queue" ] && cat "$S2/.wake-queue" || echo '(empty)')"
printf '  .watch-triage.log  : %s\n' "$( [ -s "$S2/.watch-triage.log" ] && cat "$S2/.watch-triage.log" || echo '(empty)')"
SEEN=$(ls "$S2"/.seen-* 2>/dev/null | tr '\n' ' ')
printf '  seen-markers       : %s\n' "${SEEN:-(none)}"
printf '  crew-state probe   : %s\n' "$( [ -e "$CREW_PROBE" ] && echo 'ran' || echo 'never ran - stood down at the grace gate, ahead of triage')"
[ ! -s "$S2/.wake-queue" ] && ok "no wake was enqueued by the watcher that lost the lock" || bad "superseded watcher enqueued a wake"
! grep -q absorbed "$S2/.watch-triage.log" 2>/dev/null && ok "nothing was absorbed by the watcher that lost the lock" || bad "superseded watcher absorbed a signal"
[ -z "$SEEN" ] && ok "the crew signal is still UNMARKED - durable for the rightful holder" || bad "superseded watcher advanced a seen-marker"
[ "$(lock_pid "$H2")" = "$SUCC" ] && ok "the successor's lock was left untouched" || bad "the superseded watcher clobbered the lock"

# =============================================================================
hdr 'SCENARIO 3 - the work the superseded watcher left behind is still delivered'
note 'The stood-down watcher marked nothing, so the signal is still pending. This is'
note 'the real operator loop: the successor re-engages, the primary drains, the next'
note 'watcher delivers the crew signal itself.'
kill "$SUCC" 2>/dev/null || true; wait "$SUCC" 2>/dev/null || true

run_watcher() {  # <stdout-file>; runs one real watcher until it surfaces and exits
  local out=$1 p i=0
  in_home "$H2" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash "$WATCH" > "$out" 2>&1 &
  p=$!
  while [ "$i" -lt 400 ]; do alive "$p" || break; sleep 0.1; i=$((i+1)); done
  kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
}

step "bin/fm-watch.sh   # the rightful holder takes the home over"
run_watcher "$ROOTDIR/w1.out"
sed 's/^/  /' "$ROOTDIR/w1.out"
grep -qx 'check: rearm-resurface' "$ROOTDIR/w1.out" \
  && ok "the successor re-engages the primary after its predecessor stood down - the home is not blind" \
  || bad "expected the successor to surface check: rearm-resurface, got: $(cat "$ROOTDIR/w1.out")"

step "bin/fm-wake-drain.sh   # the primary handles that turn and acknowledges"
in_home "$H2" bash "$DRAIN" > "$ROOTDIR/d1.out" 2> "$ROOTDIR/d1.err" || true
sed 's/^/  /' "$ROOTDIR/d1.err"
SEQ=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$ROOTDIR/d1.err")
GEN=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \(.*\)$/\1/p' "$ROOTDIR/d1.err")
in_home "$H2" bash "$DRAIN" --ack-through "$SEQ" --recovery-generation "$GEN" \
  && ok "acknowledged (--ack-through $SEQ)" || bad "drain acknowledgement failed"

step "bin/fm-watch.sh   # the next watcher of the cycle"
run_watcher "$ROOTDIR/w2.out"
sed 's/^/  /' "$ROOTDIR/w2.out"
SIGLINES=$(grep -c "^signal: .*task\.status$" "$ROOTDIR/w2.out" || true)
[ "${SIGLINES:-0}" -eq 1 ] \
  && ok "the crew signal the superseded watcher declined to touch is delivered - nothing was lost" \
  || bad "expected exactly one 'signal: ...task.status' wake, got ${SIGLINES:-0}"
step 'ls state/.seen-*'
SEEN2=$(ls "$S2"/.seen-* 2>/dev/null | tr '\n' ' ')
printf '  %s\n' "${SEEN2:-(none)}"
[ -n "$SEEN2" ] && ok "the seen-marker is advanced only now, by the watcher that owned the lock" \
               || bad "the delivering watcher did not advance the seen-marker"
LP=$(lock_pid "$H2"); [ -n "$LP" ] && kill "$LP" 2>/dev/null || true

# =============================================================================
hdr 'SCENARIO 4 - the arm refuses to fork a competing watcher during a live renewal'
note 'A Claude Stop auto-arm continuity renewal is a controlled hand-off. A fresh arm'
note 'forking into its brief unheld window is what compounded the duplicate cycles.'
H3=$(make_home home-renewal)
S3="$H3/state"
rm -f "$S3/task.meta"
sleep 600 & RENEWER=$!
FM_STATE_OVERRIDE="$S3" bash -c '. "$1"; fm_autoarm_renewal_request "$2" "$3" stop-renewal' _ "$LIB" "$S3" "$RENEWER"
step 'cat state/.claude-autoarm-renewal'
sed 's/^/  /' "$S3/.claude-autoarm-renewal"
printf '  (arm pid %s is alive - the renewal is genuinely in flight)\n' "$RENEWER"

step "bin/fm-watch-arm.sh   # a fresh arm fires while that renewal is in flight"
in_home "$H3" FM_ARM_CONFIRM_TIMEOUT=25 FM_POLL=5 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bash "$ARM" > "$ROOTDIR/arm.out" 2>&1 &
ARMPID=$!
RACED=0
i=0; while [ "$i" -lt 50 ]; do
  grep -q 'watcher: started' "$ROOTDIR/arm.out" 2>/dev/null && RACED=1
  [ -e "$S3/.watch.lock/pid" ] && RACED=1
  sleep 0.1; i=$((i+1))
done
printf '  arm stdout after 5s of a live renewal : %s\n' "$( [ -s "$ROOTDIR/arm.out" ] && tr '\n' '|' < "$ROOTDIR/arm.out" || echo '(nothing - it is waiting)')"
printf '  state/.watch.lock                     : %s\n' "$( [ -e "$S3/.watch.lock/pid" ] && cat "$S3/.watch.lock/pid" || echo '(no watcher forked)')"
[ "$RACED" -eq 0 ] && ok "the arm did NOT fork a competing watcher into the renewal window" \
                   || bad "the arm forked a watcher during a live renewal"
alive "$ARMPID" && ok "the arm is waiting (bounded), not dead and not blind" || bad "the arm exited during the renewal wait"

step "kill <renewal arm pid>   # the renewal clears"
kill "$RENEWER" 2>/dev/null || true; wait "$RENEWER" 2>/dev/null || true
i=0; while [ "$i" -lt 300 ]; do grep -q 'watcher: started pid=' "$ROOTDIR/arm.out" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
printf '  arm stdout: %s\n' "$(grep 'watcher: started pid=' "$ROOTDIR/arm.out" 2>/dev/null || tr '\n' '|' < "$ROOTDIR/arm.out")"
grep -q 'watcher: started pid=' "$ROOTDIR/arm.out" 2>/dev/null \
  && ok "the arm fell through to a normal start once the renewal cleared - the home is never left blind" \
  || bad "the arm never started a watcher after the renewal cleared"
LP=$(lock_pid "$H3")
kill "$ARMPID" 2>/dev/null || true; [ -n "$LP" ] && kill "$LP" 2>/dev/null || true
wait "$ARMPID" 2>/dev/null || true

hdr 'RESULT'
if [ "$FAILED" -eq 0 ]; then printf 'ALL SCENARIOS BEHAVED AS INTENDED\n'; else printf 'ONE OR MORE SCENARIOS FAILED\n'; fi
exit "$FAILED"
