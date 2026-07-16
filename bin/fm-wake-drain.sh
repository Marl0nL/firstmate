#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based alarm (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# Decoupled, failure-isolated token-usage ledger catch-up. This runs at the top
# of every wake-handling turn regardless of watcher liveness, so the ledger keeps
# accumulating even when the watcher background task is reaped (the check-shim
# then rarely runs). It is deliberately:
#   - opt-out-cheap: the monitor's check-shim exists only while the monitor is
#     opted in (bootstrap creates/removes it), so its absence means "not opted in"
#     and we skip the fork entirely on the common default-off hot path. The poll
#     still self-gates authoritatively (--if-due checks fm_usage_enabled), so this
#     is only a cheap pre-filter, not a second source of truth;
#   - self-gated: fm-usage-poll.sh --if-due no-ops unless the monitor is opted in
#     and its min-interval has elapsed, and only reads new transcript bytes;
#   - silent: --if-due implies --quiet and all output is discarded, so it never
#     pollutes the drain output and never emits a wake;
#   - non-blocking: run detached in the background so a slow scan can NEVER delay
#     the drain or the wake-queue lock it still holds here - on ANY platform, not
#     just where `timeout` exists - with `timeout` layered on where available as a
#     secondary bound. Unlike the watcher, a reaped or slow poll is harmless: it is
#     idempotent and single-writer-locked, and session start plus the next drain
#     catch the ledger up. Failure is swallowed and can never change the drain's
#     exit status.
# The session-start backfill and the watcher check-shim are the belt-and-braces
# catch-ups; see docs/usage-monitor.md.
opportunistic_usage_poll() {
  [ -e "$STATE/usage-watch.check.sh" ] || return 0
  local poll="$SCRIPT_DIR/fm-usage-poll.sh"
  [ -x "$poll" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    ( timeout "${FM_USAGE_WAKE_POLL_TIMEOUT:-10}" "$poll" --if-due >/dev/null 2>&1 || true ) &
  else
    ( "$poll" --if-due >/dev/null 2>&1 || true ) &
  fi
  return 0
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    fm_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  opportunistic_usage_poll
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

fm_wake_print_deduped "$DRAIN_TMP" || exit "$?"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
opportunistic_usage_poll
assert_watcher_liveness
exit 0
