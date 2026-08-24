#!/usr/bin/env bash
# One short check of the wake-resident secondmate lifecycle.
#
# Inert by default: a HARD no-op (exit 0, no output) unless this home's
# config/wake-resident.conf holds at least one record. This script is the body of
# two generated check shims, where the contract is "output => wake the one live
# firstmate, silence => keep sleeping", so the no-op keeps the watcher behaving
# exactly as it does today until an operator opts a secondmate in.
#
# Usage:
#   fm-wake-resident-poll.sh              MAIN-home mode: the lifecycle detector
#   fm-wake-resident-poll.sh --self <dir> SECONDMATE-home mode: surface this
#                                         home's own oldest pending inbox entry
#
# MAIN-home mode emits AT MOST ONE line per configured record per cycle, and only
# for a state the live firstmate must act on:
#
#   wake-resident <name>: <n> pending message(s), dormant - raise it with ...
#   wake-resident <name>: message <id> unread <s>s while resident - deliver it with ...
#   wake-resident <name>: quiet <m>m, nothing in flight - stand it down with ...
#
# It DETECTS ONLY. It never spawns, never sends, never exits an agent. That is the
# whole point: an inbox message becomes a wake that the ONE live firstmate handles
# on its own turn, so servicing chat can never grow a second supervision cycle
# (AGENTS.md section 8, docs/crowsnest.md's single-threaded rule).
#
# Everything is fail-silent: an unreadable config, a missing home, a backend that
# cannot be probed, or an inconclusive liveness read all stay quiet rather than
# manufacture a wake. A false silence costs one check interval; a false wake costs
# a firstmate turn, and a false wake that says "dormant" about a live agent costs
# a duplicate supervisor.
#
# Away mode: while state/.afk exists the daemon owns supervision, so this poll
# goes silent rather than queue lifecycle work the daemon has no authority to
# perform (a raise and a stand-down are both fleet mutations).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# fm_wr_home resolves a secondmate home through the single owner of the
# data/secondmates.md record format.
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-resident-lib.sh
. "$SCRIPT_DIR/fm-wake-resident-lib.sh"

# --- secondmate-home mode ---------------------------------------------------
#
# Deliberately minimal: presence of a pending entry, nothing else. The resident
# agent owns what a message MEANS and how it is answered (its charter and the
# console's chat contract); this only makes sure a message reaches its turn.
if [ "${1-}" = --self ]; then
  INBOX=${2-}
  [ -n "$INBOX" ] || exit 0
  msg=$(fm_wr_oldest_pending "$INBOX") || exit 0
  printf 'wake-resident message %s pending in %s\n' "$msg" "$INBOX"
  exit 0
fi

# --- main-home mode ---------------------------------------------------------

[ -f "$(fm_wr_config_file "$CONFIG")" ] || exit 0
[ -e "$STATE/.afk" ] && exit 0

# Self-throttle: the watcher runs checks far more often than a lifecycle
# transition can meaningfully change, and re-emitting the same actionable line
# every cycle would wake firstmate repeatedly for one decision it is already
# holding. The throttle is per record and per KIND of line, so a stand-down
# suggestion never suppresses a raise.
THROTTLE=${FM_WAKE_RESIDENT_THROTTLE:-600}
case "$THROTTLE" in ''|*[!0-9]*) THROTTLE=600 ;; esac

NOW=$(fm_wr_now)

throttled() {  # <name> <kind>
  local stamp="$STATE/.wake-resident-$1-$2.last" last
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    case "$last" in (*[!0-9]*|'') last=0 ;; esac
    [ $((NOW - last)) -lt "$THROTTLE" ] && return 0
  fi
  printf '%s' "$NOW" > "$stamp" 2>/dev/null || true
  return 1
}

emit_for() {  # <name>
  local name=$1 home inbox pending residency msg newest age idle quiet meta
  local backend target last_seen activity raised

  fm_wr_load "$CONFIG" "$name" || return 0
  home=$(fm_wr_home "$STATE" "$name" "$DATA") || return 0
  inbox=$(fm_wr_inbox_dir "$home")
  pending=$(fm_wr_pending_count "$inbox")
  residency=$(fm_wr_residency "$STATE" "$name")

  # An inconclusive liveness read licenses nothing in either direction.
  [ "$residency" = unknown ] && return 0

  if [ "$pending" -gt 0 ]; then
    if [ "$residency" = dormant ]; then
      throttled "$name" raise && return 0
      printf 'wake-resident %s: %s pending message(s), dormant - raise it with bin/fm-wake-resident.sh raise %s\n' \
        "$name" "$pending" "$name"
      return 0
    fi
    # Resident with unread mail. The secondmate's own shim normally gets there
    # first, so only a message left sitting past grace-secs is worth a main-home
    # turn - that is the durable backstop for a secondmate whose own supervision
    # cycle is not up.
    msg=$(fm_wr_oldest_pending "$inbox") || return 0
    newest=$(fm_wr_newest_pending_mtime "$inbox")
    [ "$newest" -gt 0 ] 2>/dev/null || return 0
    age=$((NOW - newest))
    [ "$age" -ge "$FM_WR_GRACE_SECS" ] || return 0
    throttled "$name" deliver && return 0
    printf 'wake-resident %s: message %s unread %ss while resident - deliver it with bin/fm-send.sh %s "<nudge>"\n' \
      "$name" "$msg" "$age" "$name"
    return 0
  fi

  # No pending mail. Only a RESIDENT secondmate can be stood down, and only when
  # nothing of its own is running.
  [ "$residency" = resident ] || return 0
  fm_wr_has_inflight_work "$home" && return 0

  meta="$STATE/$name.meta"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || return 0
  fm_wr_confirmed_busy "$backend" "$target" && return 0

  # Quiet since the LATEST of: this residency starting, the last message seen,
  # and the home's own most recent working footprint. Anything newer than the
  # threshold means it is not actually 30 quiet minutes yet.
  quiet=0
  raised=$(fm_wr_record_get "$STATE" "$name" raised_at 2>/dev/null) || raised=
  case "$raised" in ''|*[!0-9]*) raised=$(fm_wr_mtime "$meta") ;; esac
  case "$raised" in ''|*[!0-9]*) raised=0 ;; esac
  [ "$raised" -gt "$quiet" ] 2>/dev/null && quiet=$raised
  last_seen=$(fm_wr_record_get "$STATE" "$name" last_seen_msg 2>/dev/null) || last_seen=0
  case "$last_seen" in ''|*[!0-9]*) last_seen=0 ;; esac
  [ "$last_seen" -gt "$quiet" ] 2>/dev/null && quiet=$last_seen
  activity=$(fm_wr_home_activity "$home")
  [ "$activity" -gt "$quiet" ] 2>/dev/null && quiet=$activity

  [ "$quiet" -gt 0 ] 2>/dev/null || return 0
  idle=$((NOW - quiet))
  [ "$idle" -ge "$FM_WR_IDLE_SECS" ] || return 0
  throttled "$name" standdown && return 0
  printf 'wake-resident %s: quiet %sm, nothing in flight - stand it down with bin/fm-wake-resident.sh standdown %s\n' \
    "$name" "$((idle / 60))" "$name"
}

# Remember the newest message mtime BEFORE anything is drained, so a stand-down
# cannot later measure quiet time from an inbox that has since been emptied.
note_last_seen() {  # <name>
  local name=$1 home inbox newest prev
  fm_wr_load "$CONFIG" "$name" || return 0
  home=$(fm_wr_home "$STATE" "$name" "$DATA") || return 0
  inbox=$(fm_wr_inbox_dir "$home")
  newest=$(fm_wr_newest_pending_mtime "$inbox")
  [ "$newest" -gt 0 ] 2>/dev/null || return 0
  prev=$(fm_wr_record_get "$STATE" "$name" last_seen_msg 2>/dev/null) || prev=0
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  [ "$newest" -gt "$prev" ] 2>/dev/null || return 0
  fm_wr_record_set "$STATE" "$name" last_seen_msg "$newest" || true
}

while IFS= read -r wr_name; do
  [ -n "$wr_name" ] || continue
  note_last_seen "$wr_name"
  emit_for "$wr_name"
done < <(fm_wr_names "$CONFIG")

exit 0
