#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire
#        fm-lock.sh status    print holder and liveness; always exits 0
# Acquire exit codes, distinct because they demand opposite responses:
#   0  lock acquired
#   1  another live session holds it - a competing session really exists
#   2  this session cannot identify its own harness process - nobody else holds
#      anything; the ancestry walk found no known harness. Both refuse to take
#      the lock, so the caller stays read-only either way, but only 1 means
#      "go look for the other session".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

# A harness launched from its versioned install directory reports the VERSION as
# its process name (comm=2.1.215 for ~/.local/share/claude/versions/2.1.215),
# which HARNESS_RE cannot match. That is the shape the boot-autostart path
# produces, because the shim execs the real versioned binary - so firstmate
# failed to identify itself, refused its own session lock, and came up read-only
# and unable to supervise. Verified live 2026-07-20 after the first successful
# unattended boot. Matched against argv[0] only; see is_harness_proc.
HARNESS_ARGV0_RE='/(claude|codex|opencode|grok|pi)/versions/[^/]+$'

# is_harness_proc <comm> <args>: true if the process is a known harness.
#
# ANCHORED TO THE EXECUTABLE, NEVER THE ARGUMENTS. A tool call's transient shell
# carries ~/.claude/... in its command line; matching that would name a subshell
# PID as the lock holder, dead moments after it is written - the exact failure
# this script's header exists to prevent. So argument text is only ever consulted
# when comm itself proves the process is a bare interpreter, which a shell is not.
is_harness_proc() {
  local comm=$1 args=$2
  [ -n "$comm" ] || return 1
  if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && return 0 ;;
  esac
  # Versioned-install binary: identify it by argv[0] alone (see above).
  printf '%s' "${args%% *}" | grep -qE "$HARNESS_ARGV0_RE"
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if is_harness_proc "$comm" "$args"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# holder_alive <pid>: true if $1 is a live process that looks like a harness.
# Deliberately the same test harness_pid selects with, so a holder this script
# wrote can never fail to be recognized by the next session that reads the lock.
holder_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  is_harness_proc "$comm" "$(ps -o args= -p "$pid" 2>/dev/null)"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || {
  echo "error: cannot identify this session's own harness process in its ancestry; no lock was taken and no other session was found holding one" >&2
  exit 2
}
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
