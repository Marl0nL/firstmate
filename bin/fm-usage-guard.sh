#!/usr/bin/env bash
# Advisory dispatch guard: should firstmate hold large/low-priority work given
# the current token quota? Prints one line and returns an exit code:
#   exit 0  allow  ("allow: <reason>")
#   exit 3  hold   ("hold: <reason with the binding window and its resets_at>")
#
# The 5-hour window is the primary gate; the weekly window and any active
# per-model weekly cap are additional gates. The high-water percent is
# configurable (FM_USAGE_HIGH_WATER, default 80). The guard is ADVISORY and
# NEVER hard-blocks: an explicit captain dispatch (--captain) or high-priority
# work (--priority high) always allows. It also allows when it has no signal.
#
# Usage:
#   fm-usage-guard.sh [--model <name>] [--priority low|high] [--captain]
#
# The signal comes from fm-usage-quota.sh --signal (live -> cached -> heuristic);
# set FM_USAGE_QUOTA_CMD to override that command in tests. Decision logic lives
# in fm-usage-lib.sh (fm_usage_decision), shared with the poll's wake test so the
# two never drift. See docs/usage-monitor.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-usage-lib.sh
. "$SCRIPT_DIR/fm-usage-lib.sh"

MODEL=""
PRIORITY=low
CAPTAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=${2:-}; shift 2 ;;
    --priority) PRIORITY=${2:-low}; shift 2 ;;
    --captain) CAPTAIN=1; shift ;;
    *) shift ;;
  esac
done
case "$PRIORITY" in low|high) : ;; *) PRIORITY=low ;; esac

# Captain override and high-priority never need a signal (and never fail): decide
# straight away without spending a network call.
if [ "$CAPTAIN" = 1 ] || [ "$PRIORITY" = high ]; then
  fm_usage_decision /nonexistent "$MODEL" "$PRIORITY" "$CAPTAIN"
  exit $?
fi

QUOTA_CMD=${FM_USAGE_QUOTA_CMD:-$SCRIPT_DIR/fm-usage-quota.sh}
SIGNAL=$(mktemp "${TMPDIR:-/tmp}/fm-usage-guard.XXXXXX") || {
  printf 'allow: could not stage a quota signal; proceeding\n'
  exit 0
}
trap 'rm -f "$SIGNAL"' EXIT

if ! $QUOTA_CMD --signal > "$SIGNAL" 2>/dev/null || [ ! -s "$SIGNAL" ]; then
  printf 'allow: no quota signal available; proceeding\n'
  exit 0
fi

fm_usage_decision "$SIGNAL" "$MODEL" "$PRIORITY" "$CAPTAIN"
exit $?
