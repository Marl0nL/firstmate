# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# ONE definition of watcher liveness, for every guard in this repo.
#
# THE BUG THIS FILE EXISTS TO PREVENT (measured 2026-07-31, see
# docs/turnend-guard.md "The 2026-07-30 silent-lapse incident"): liveness used to
# have TWO definitions that disagreed. This library answered it from the BEACON
# AGE alone, so a watcher that had exited cleanly seconds ago still read as
# "fresh" for the whole grace window, and bin/fm-guard.sh printed nothing.
# bin/fm-turnend-guard.sh answered it from the LOCK, saw the truth, and blocked.
# The agent, correctly prompted by the turn-end block, then verified with
# fm-guard.sh, was told supervision was healthy, and stood down. That happened on
# five separate occasions in 27 hours and cost between 15 minutes and 4.8 hours of
# unsupervised fleet each time.
#
# So the beacon is NOT the liveness test and must never be used as one on its own.
# A beacon only records when a watcher last ran; the singleton lock records
# whether one is running NOW. FM_SUP_WATCHER_FRESH is therefore the LOCK-based
# answer, and every caller gets the same verdict the turn-end guard acts on.
# fm_supervision_status needs bin/fm-wake-lib.sh sourced for that check; without
# it the beacon is all we have, so it degrades to the beacon and says so through
# FM_SUP_LIVENESS_BASIS rather than quietly answering a weaker question.

FM_SUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds] [watcher-path] [home]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT       count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH   true/false - a watcher is RUNNING NOW (lock-based; see
#                          the header). Never true off the beacon alone.
#   FM_SUP_BEACON_DESC     human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_BEACON_FRESH    true/false - beacon age alone, within grace. Reporting
#                          only: it is what distinguishes a watcher that JUST
#                          exited (a wake handoff) from one long gone, so banners
#                          can say which. Never a liveness verdict.
#   FM_SUP_LIVENESS_BASIS  "lock" or "beacon" - which question was actually
#                          answered, so a degraded answer can never pass as the
#                          strong one
#   FM_SUP_WAITER_ALIVE    true/false - an arm is waiting, i.e. a wake has a path
#                          to the agent. Only meaningful on the lock basis.
#   FM_SUP_QUEUE_PENDING   true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300.
# watcher-path defaults to bin/fm-watch.sh beside this library, home to $FM_HOME.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  local watch_path=${3:-} home=${4:-${FM_HOME:-}}
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_LIVENESS_BASIS=beacon
  FM_SUP_WAITER_ALIVE=false
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_BEACON_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # The liveness verdict. fm_watcher_healthy (bin/fm-wake-lib.sh) is the one
  # owner: it requires the singleton lock to name a LIVE process whose identity
  # still matches, AND the beacon to be fresh. A caller that did not source
  # fm-wake-lib.sh cannot ask that question, so it falls back to the beacon and
  # the basis field records the downgrade instead of hiding it.
  if declare -F fm_watcher_healthy >/dev/null 2>&1; then
    [ -n "$watch_path" ] || watch_path="$FM_SUP_LIB_DIR/fm-watch.sh"
    # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
    FM_SUP_LIVENESS_BASIS=lock
    if fm_watcher_healthy "$state" "$watch_path" "$grace" "$home"; then
      FM_SUP_WATCHER_FRESH=true
    fi
    if declare -F fm_waiter_alive >/dev/null 2>&1 && fm_waiter_alive "$state" "$home"; then
      # shellcheck disable=SC2034 # Read by callers (fm-turnend-guard.sh) after sourcing.
      FM_SUP_WAITER_ALIVE=true
    fi
  else
    FM_SUP_WATCHER_FRESH=$FM_SUP_BEACON_FRESH
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds] [watcher-path] [home]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher is running. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
