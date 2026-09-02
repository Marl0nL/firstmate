#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn. A lock left behind by a claim whose
#     ledger outcome is already terminal, or whose recorded pid-identity no
#     longer matches its live pid, is reclaimed once rather than deferred to
#     forever (fm_autoarm_claim_abandoned in bin/fm-wake-lib.sh).
#   - Waited arm: the owner runs bin/fm-watch-arm.sh as a child it WAITS on
#     inside this hook-owned process tree (never fire-and-forget); Claude owns
#     the process group, so its timeout/session teardown kills arm and watcher
#     together, and the hook never exits while its own arm or watcher lives.
#   - Renewal: Claude enforces the declared hook timeout by SIGTERMing that
#     process group, and no unbounded timeout exists, so an idle park used to
#     go blind at exactly that bound (verified 2026-09-02, Claude 2.1.258;
#     docs/turnend-guard.md). Shortly before the deadline
#     (FM_CLAUDE_AUTOARM_RENEWAL_BUDGET seconds, default 27000, safely below
#     the declared 28800, and refused by the arming owner with a stderr notice
#     when it would reach that ceiling) a watchdog closes the arm under the
#     pid-matched renewal
#     marker so the lifecycle ledger records continuity-renewal, then the owner
#     exits 2 with a benign renewal banner: one bounded turn ends, the next
#     Stop fires, and a fresh firing arms with a fresh budget. The renewal
#     re-checks the AFK, supervision-need, live-watcher, and post-alarm gates
#     first - a close that leaves another verified live watcher costs no turn
#     at all - and otherwise records outcome=renewal so the synchronous guard
#     treats it as owned recovery without consuming its block budget.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). A close that reports no actionable reason is
#     benign when a live identity-matched watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
RENEWAL_MARKER="$STATE/.claude-autoarm-renewal"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac
# Seconds this hook may hold an arm open before renewing continuity. At the
# declared "timeout" on this hook's .claude/settings.json entry Claude Code
# SIGTERMs this whole process group, watcher included, with no re-arm until the
# session's next real turn end, so a budget that reaches that ceiling silently
# reinstates the exact blind spot the renewal exists to close. Refuse any such
# value - and any value that is not a positive number of seconds - and fall back
# to the safe default rather than arming past the deadline.
# RENEWAL_BUDGET_CEILING mirrors the declared timeout, which lives in
# .claude/settings.json; tests/fm-claude-stop-autoarm.test.sh pins the tracked
# registration against this ceiling so the two files cannot drift apart.
# The fallback is DERIVED from that ceiling rather than written beside it, so the
# ceiling binds the unconfigured default too: lowering the declared timeout and
# this ceiling lowers every home's budget with them instead of leaving a stale
# default parked past the kill timer, which would restore the original blind spot
# for exactly the homes that configured nothing.
HOOK_START=$(date +%s)
RENEWAL_BUDGET_CEILING=28800
RENEWAL_BUDGET_DEFAULT=$((RENEWAL_BUDGET_CEILING - RENEWAL_BUDGET_CEILING / 16))
RENEWAL_BUDGET_REQUESTED=${FM_CLAUDE_AUTOARM_RENEWAL_BUDGET:-$RENEWAL_BUDGET_DEFAULT}
RENEWAL_BUDGET=$RENEWAL_BUDGET_DEFAULT
RENEWAL_BUDGET_OK=0
case "$RENEWAL_BUDGET_REQUESTED" in
  # The nine-digit arm keeps the comparison below inside the shell's integer
  # range; anything that long is far past the ceiling anyway.
  ''|*[!0-9]*|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) : ;;
  *)
    # "10#" strips leading zeros, and the positive test is what refuses the
    # zeros a case pattern cannot enumerate - "00", "000" - rather than letting
    # them through as budget 0, which renews the instant the arm starts and
    # rewakes forever without a watcher ever running.
    if [ "$((10#$RENEWAL_BUDGET_REQUESTED))" -gt 0 ] &&
      [ "$((10#$RENEWAL_BUDGET_REQUESTED))" -lt "$RENEWAL_BUDGET_CEILING" ]; then
      RENEWAL_BUDGET=$((10#$RENEWAL_BUDGET_REQUESTED))
      RENEWAL_BUDGET_OK=1
    fi
    ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner runs the arm as a waited child and translates its close; every other
# firing exits 0 so one watcher cycle maps to at most one exit-2 rewake.
#
# A claim whose own ledger entry or recorded pid-identity proves its supervision
# decision already finished is abandoned, not in flight: deferring to it forever
# is what leaves a home unsupervised with no watcher and no lock
# (fm_autoarm_claim_abandoned in bin/fm-wake-lib.sh owns that proof and its
# race-free reclaim). Reclaim it once and retry; anything still genuinely
# deciding keeps the lock and this firing stays inert.
if ! fm_lock_try_acquire "$OWNER_LOCK"; then
  fm_autoarm_release_abandoned "$STATE" || exit 0
  fm_lock_try_acquire "$OWNER_LOCK" || exit 0
fi
# Record WHO this claim is before publishing the role both Stop participants read
# as ownership. A bare pid the operating system later hands to an unrelated live
# process is exactly what makes a killed claim look in flight forever, in the two
# shapes the ledger cannot settle: an entry still reading arming, and no entry at
# all. Best effort; a home whose identity cannot be recorded keeps the ledger-only
# boundary rather than losing its claim.
fm_autoarm_claim_record_identity "$STATE" || true
if ! fm_lock_set_role "$OWNER_LOCK" autoarm; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# Terminal handling for any close this home survives with a verified live,
# identity-matched watcher still beating: the supervision the model would be
# woken for already exists, so the failure episode is over and this firing
# stays silent. When the episode reset cannot complete (its lock is busy) the
# episode is still unresolved, so keep the Stop-owned retry alive exactly as the
# failure progression does, unless the attended fail-open already fired.
close_with_healthy_watcher() {
  if fm_failure_episode_reset "$STATE"; then
    write_epoch clean
    exit 0
  fi
  write_epoch failed-suppressed
  [ -e "$FAILURE_ALARM" ] && exit 0
  exit 2
}

# Every firing that cannot park an arm - a child worktree, a non-owner session,
# an away or idle home - stays byte-for-byte silent per this file's contract, so
# the budget refusal belongs to the one owner whose arm the value would govern.
if [ "$RENEWAL_BUDGET_OK" -eq 0 ]; then
  printf 'firstmate: refusing FM_CLAUDE_AUTOARM_RENEWAL_BUDGET=%s - a Claude Stop auto-arm budget must be a positive number of seconds below the %ss timeout declared for this hook, at which Claude Code kills the arm and its watcher unsupervised; using %ss instead.\n' \
    "$RENEWAL_BUDGET_REQUESTED" "$RENEWAL_BUDGET_CEILING" "$RENEWAL_BUDGET" >&2
fi

write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- run the real arm wrapper as a waited child --------------------------------
# NEVER fire-and-forget: this hook process tree is the harness-owned lifecycle,
# the arm runs as a child this hook waits on to completion, and the arm forks
# the watcher as its own tracked child exactly as it does for the model-driven
# background-task path, propagating the wake reason on close. Every
# non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
# --- declared-timeout continuity renewal --------------------------------------
# Claude Code enforces this hook's declared timeout by SIGTERMing the whole
# hook-owned process group, watcher included, and no unbounded timeout exists
# (an absent value falls back to Claude's own default), so a park that reaches
# the bound used to close as arm-interrupted with no successor and leave the
# home blind until the next real turn end. The arm therefore runs as a waited
# child of this hook - still inside the hook-owned process group, so harness
# timeout and session teardown kill arm and watcher together exactly as before -
# while a watchdog sibling requests a MARKED close shortly before the deadline:
# it publishes the pid-matched renewal marker, then TERMs the arm, whose signal
# handler records the close as continuity-renewal instead of arm-interrupted.
# The owner then hands continuity to the next Stop-owned firing through one
# benign bounded turn (the renewal branch after the loop below).
RENEWED=0
ARM_CHILD=
run_arm_cycle() {  # <output-file-or-empty>
  local target=$1 watchdog arm_rc
  rm -f "$RENEWAL_MARKER" 2>/dev/null || true
  if [ -n "$target" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$target" 2>&1 &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_CHILD=$!
  # Bounded-chunk countdown, so a killed watchdog leaves at most one short
  # orphan sleep instead of a multi-hour one, and a small test budget still
  # fires promptly. If the marker cannot be written the watchdog does nothing
  # and the pre-renewal behavior (the harness's own group kill) remains.
  # The watchdog holds none of this hook's standard descriptors: a leftover
  # sleep keeping the hook's output pipe open would stall any reader waiting
  # on that pipe's EOF long after the hook itself finished.
  (
    while :; do
      remaining=$((RENEWAL_BUDGET - ($(date +%s) - HOOK_START)))
      [ "$remaining" -le 0 ] && break
      [ "$remaining" -gt 30 ] && remaining=30
      sleep "$remaining"
    done
    fm_autoarm_renewal_request "$STATE" "$ARM_CHILD" stop-renewal || exit 0
    kill -TERM "$ARM_CHILD" 2>/dev/null || true
  ) >/dev/null 2>&1 </dev/null &
  watchdog=$!
  wait "$ARM_CHILD"
  arm_rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  RENEWED=0
  if [ "$arm_rc" -eq 143 ] && fm_autoarm_renewal_claim "$STATE" "$ARM_CHILD"; then
    RENEWED=1
  fi
  rm -f "$RENEWAL_MARKER" 2>/dev/null || true
  ARM_CHILD=
  return 0
}

OUT=
ACTIONABLE=0
HEALTHY=0
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  run_arm_cycle "$OUT"

  # A renewal close is not a cycle outcome to classify; the renewal branch
  # after this loop owns the decision.
  if [ "$RENEWED" -eq 1 ]; then
    break
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# --- renewal close ------------------------------------------------------------
# The arm was closed under the continuity-renewal marker because this hook was
# approaching its declared timeout with nothing actionable. Re-check the same
# gates that keep an away, idle, or already-supervised home quiet, then hand
# continuity to the next Stop-owned firing through one benign bounded turn:
# exit 2 rewakes the primary, its handling turn ends, the next Stop fires, and a
# fresh firing arms with a fresh declared-timeout budget. A renewal is owned
# recovery, not a duplicate continuation: it records outcome=renewal for the
# synchronous guard and never advances the guard's block budget or the failure
# progression.
if [ "$RENEWED" -eq 1 ]; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    exit 0
  fi
  if ! need_supervision; then
    write_epoch clean
    exit 0
  fi
  # An attached arm closes only itself: the peer watcher it was following is
  # untouched by the renewal TERM, so a home that still has a verified live
  # watcher with a fresh beacon needs no turn at all. Zero-turn continuity is
  # the point, so take the same benign close every other healthy path takes.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    close_with_healthy_watcher
  fi
  # After the guard consumed the episode's attended fail-open, do not create
  # another exit-2 continuation that could defeat it.
  if [ -e "$FAILURE_ALARM" ]; then
    write_epoch failed-suppressed
    exit 0
  fi
  write_epoch renewal
  {
    printf 'firstmate watcher continuity renewal - no supervision event occurred; the watcher cycle was closed cleanly before this Stop hook'\''s declared timeout could interrupt it unsupervised.\n'
    printf 'Run bin/fm-wake-drain.sh first as on any wake; if it presents nothing actionable, end the turn immediately so the next turn end starts a fresh watcher cycle automatically. Do NOT run bin/fm-watch-arm.sh.\n'
  } >&2
  exit 2
fi

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  close_with_healthy_watcher
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  write_epoch rewake
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop.
if [ ! -e "$FAILURE_NOTICE" ]; then
  write_epoch failed
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  : > "$FAILURE_NOTICE" 2>/dev/null || true
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
write_epoch failed-suppressed
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2
