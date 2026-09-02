# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists), an X-mode relay poll (state/x-watch.check.sh),
# a registered process-event source (state/procevent/*.source), a durable wake
# queue (state/.wake-queue) holding an ackable record still to be delivered, or an
# in-progress deferred network stage (bin/fm-startup-network.sh) that will still
# publish a wake; and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# The queue and network-stage conditions keep the cycle armed until a wake
# enqueued out of band into an otherwise idle home - e.g. the deferred stage
# finishing its sweeps after the reconcile turn ended - is delivered and
# acknowledged, instead of sitting undelivered until the parent notices.
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_sup_status_field <status-file> <key>
# Print the last value of a key=value line in a bin/fm-startup-network.sh status
# record. Last wins, matching how that script rewrites the record whole.
fm_sup_status_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

# fm_sup_network_stage_active <state-dir>
# Exit 0 (true) when a deferred startup-network stage (bin/fm-startup-network.sh)
# is genuinely in progress in this home: its status record reads state=running
# and its recorded worker pid is alive and recent. That worker publishes a
# durable `check: startup-network` wake when it finishes, so supervision must
# stay armed across the window between the reconcile turn ending and that wake
# landing, or an idle home never delivers it.
# A terminal record (done/timeout/failed) reads true only across the pre-append
# gap: that script writes the terminal state BEFORE appending the wake, so a
# status sampled between those two steps would otherwise read neither a running
# stage nor a pending queue, and the wake would land in a home that just decided
# it needed no supervision. The bridge is therefore gated on an EMPTY wake queue
# and on a `finished` stamp within 3 seconds - once the row is appended the queue
# condition takes over, and a cycle already drained and acknowledged is seconds
# past the grace, so a finished stage is never reported as still in progress. A
# .startup-network.delivered marker ends the bridge immediately, since an inline
# harvest already took the result and no wake is coming.
# bin/fm-startup-network.sh owns the stage lifecycle and the .startup-network
# .status format (see its worker_alive); this is a deliberately conservative
# liveness gate for the supervision decision only. A dead or abandoned worker
# reads false, so a crashed stage never holds a turn open, and the started-age
# bound (the stage's own aggregate deadline) keeps a recycled pid from pinning
# supervision on forever.
fm_sup_network_stage_active() {
  local state=$1 status_file stage pid started finished budget age
  status_file="$state/.startup-network.status"
  [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
  stage=$(fm_sup_status_field "$status_file" state)
  case "$stage" in
    running) ;;
    done|timeout|failed)
      [ -e "$state/.startup-network.delivered" ] && return 1
      [ -s "$state/.wake-queue" ] && return 1
      finished=$(fm_sup_status_field "$status_file" finished)
      case "$finished" in ''|*[!0-9]*) return 1 ;; esac
      age=$(( $(date +%s) - finished ))
      [ "$age" -ge 0 ] && [ "$age" -le 3 ]
      return $?
      ;;
    *) return 1 ;;
  esac
  pid=$(fm_sup_status_field "$status_file" pid)
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started=$(fm_sup_status_field "$status_file" started)
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  budget=${FM_STARTUP_NETWORK_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  age=$(( $(date +%s) - started ))
  [ "$age" -le "$(( budget + 30 ))" ]
}

# fm_sup_queue_pending <state-dir>
# Exit 0 (true) when state/.wake-queue holds at least one record the drain can
# actually consume and acknowledge: a row with the full five tab-separated fields
# and a numeric sequence, the same shape bin/fm-wake-drain.sh's ack filter drops.
# A row that fails either test (truncated by a hard host restart or ENOSPC) is
# RETAINED by every drain forever, so counting it as pending would arm the cycle
# in an idle home on every turn end with nothing able to clear it.
fm_sup_queue_pending() {
  local queue="$1/.wake-queue"
  [ -s "$queue" ] || return 1
  awk -F '\t' '
    NF >= 5 && $2 ~ /^[0-9]+$/ { found = 1; exit }
    END { exit !found }
  ' "$queue" 2>/dev/null
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue holds a valid, ackable
#                         wake row still waiting to be delivered
#   FM_SUP_NETWORK_STAGE  true/false - a deferred network stage is in progress
#   FM_SUP_XWATCH         true/false - state/x-watch.check.sh (X-mode relay poll)
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata), a
#                         pending durable wake queue, or an in-progress deferred
#                         network stage that will still publish a wake
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false
  FM_SUP_NETWORK_STAGE=false
  FM_SUP_XWATCH=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  # A queued-but-undelivered wake and an in-progress deferred network stage each
  # keep supervision armed until the wake reaches the agent and is acknowledged.
  fm_sup_queue_pending "$state" && FM_SUP_QUEUE_PENDING=true
  fm_sup_network_stage_active "$state" && FM_SUP_NETWORK_STAGE=true
  [ -f "$state/x-watch.check.sh" ] && FM_SUP_XWATCH=true
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ "$FM_SUP_XWATCH" = true ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_QUEUE_PENDING" = true ] \
    || [ "$FM_SUP_NETWORK_STAGE" = true ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
