#!/usr/bin/env bash
# fm-wake-resident.sh - operate the WAKE-RESIDENT secondmate lifecycle: opt a
# secondmate in, raise it when a message arrives, and stand it down once it has
# been quiet. bin/fm-wake-resident-lib.sh owns the record format and the shared
# predicates; docs/wake-resident.md owns the narrative.
#
# A wake-resident secondmate is DORMANT by default. Raising it is the ordinary
# guarded secondmate launch (bin/fm-spawn.sh <name> --secondmate) and nothing
# else, so it comes up with its charter, its inherited config, and its home
# exactly as any other secondmate does. There is no second spawn path here.
#
# PERSISTENT and WAKE-RESIDENT are different axes (bin/fm-wake-resident-lib.sh's
# header owns that distinction in full). A stand-down ends the PROCESS only. The
# IDENTITY and STATE - home, seed marker, charter, backlog, status log,
# state/<name>.meta and its worktree lease, and the data/secondmates.md route -
# are permanent, so the next raise RESUMES a persistent agent that was merely
# asleep.
#
# STAND-DOWN IS THEREFORE NOT TEARDOWN. It submits the harness's own exit command,
# and it PROVES the persistent axis survived: the manifest is snapshotted before
# the exit and verified after, and a loss is a loud internal failure rather than a
# reported success. Retiring a secondmate for good stays bin/fm-teardown.sh's job
# and an explicit captain decision; this script never calls it, never returns a
# worktree, and never removes a home.
#
# Usage:
#   fm-wake-resident.sh enable <name> [--idle-secs <n>] [--grace-secs <n>] [--inbox <dir>]
#   fm-wake-resident.sh disable <name>
#   fm-wake-resident.sh sync                 converge the check shims with the config
#   fm-wake-resident.sh status [<name>]
#   fm-wake-resident.sh raise <name>         guarded, single-claim spawn
#   fm-wake-resident.sh standdown <name> [--force]
#   fm-wake-resident.sh --help
#
# enable/disable rewrite this home's config/wake-resident.conf, then converge both
# check shims: state/wake-resident.check.sh here (the lifecycle detector) and
# <home>/state/wake-self.check.sh in the secondmate home (the fast path that lets
# a resident agent see its own inbox on its own turn). Both are registered through
# bin/fm-check-lib.sh's trust path in the same operation that writes them.
#
# raise refuses unless the secondmate is CONFIDENTLY dormant, and holds a claim
# directory for the duration, so two wakes arriving together produce one agent and
# the loser says so instead of launching a duplicate supervisor.
#
# standdown refuses - always, with no override - while the secondmate has work in
# flight or an unanswered message, because leaving it up costs a little quota and
# standing it down wrongly drops someone's work. --force waives only the quiet-time
# and busy-pane gates, never those two. When a LIVE agent needs an exit command it
# refuses on a harness whose exit is not a submittable line (grok), rather than
# half-sending something and reporting success. But an agent that has ALREADY
# exited itself, leaving a bare shell, is exactly the state a stand-down wants:
# standdown records that without any pane submission (on any harness) instead of
# firing a doomed exit command a bare shell cannot accept.
#
# Exit status: 0 on success or an already-in-the-requested-state no-op, 1 on a
# refusal or failure, 2 on a usage error.
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
# fm_custom_check_registered (used by status) reads the trust record through
# fm-pr-lib.sh helpers, so that lib must be present alongside fm-check-lib.sh.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# fm_wr_home resolves a secondmate home through the single owner of the
# data/secondmates.md record format.
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-resident-lib.sh
. "$SCRIPT_DIR/fm-wake-resident-lib.sh"

STANDDOWN_TIMEOUT=${FM_WR_STANDDOWN_TIMEOUT:-30}
case "$STANDDOWN_TIMEOUT" in ''|*[!0-9]*) STANDDOWN_TIMEOUT=30 ;; esac

usage() {
  sed -n '/^# Usage:/,/^# *fm-wake-resident\.sh --help$/p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "fm-wake-resident: $*" >&2; exit 1; }
usage_error() { echo "fm-wake-resident: $*" >&2; echo >&2; usage >&2; exit 2; }

conf_file() { fm_wr_config_file "$CONFIG"; }

# Clear the poll's per-kind throttle stamps for <name>. Called after every
# successful transition so the NEXT transition is never suppressed by the
# previous one's cooldown - a message arriving a minute after a stand-down must
# raise immediately, not wait out a stale throttle.
clear_throttles() {  # <name>
  local name=$1 kind
  for kind in raise deliver standdown; do
    rm -f "$STATE/.wake-resident-$name-$kind.last" 2>/dev/null || true
  done
}

# --- enable / disable / sync ------------------------------------------------

write_record() {  # <name> <idle> <grace> <inbox>
  local name=$1 idle=$2 grace=$3 inbox=$4 conf tmp line
  conf=$(conf_file)
  mkdir -p "$CONFIG" 2>/dev/null || die "cannot create $CONFIG"
  line="$name idle-secs=$idle grace-secs=$grace"
  [ -n "$inbox" ] && line="$line inbox=$inbox"
  tmp="$conf.tmp.$$"
  {
    if [ -f "$conf" ]; then
      # Drop any existing record for this name; keep comments and other records.
      awk -v n="$name" '{ stripped=$0; sub(/#.*/, "", stripped); split(stripped, f, " "); if (f[1] == n) next; print }' "$conf"
    else
      printf '# wake-resident secondmates - bin/fm-wake-resident-lib.sh owns this format\n'
      printf '# <name> [idle-secs=<n>] [grace-secs=<n>] [inbox=<abs-dir>]\n'
    fi
    printf '%s\n' "$line"
  } > "$tmp" || { rm -f "$tmp"; die "cannot write $conf"; }
  mv -f "$tmp" "$conf" || { rm -f "$tmp"; die "cannot publish $conf"; }
}

drop_record() {  # <name>
  local name=$1 conf tmp
  conf=$(conf_file)
  [ -f "$conf" ] || return 0
  tmp="$conf.tmp.$$"
  awk -v n="$name" '{ stripped=$0; sub(/#.*/, "", stripped); split(stripped, f, " "); if (f[1] == n) next; print }' "$conf" > "$tmp" \
    || { rm -f "$tmp"; die "cannot rewrite $conf"; }
  mv -f "$tmp" "$conf" || { rm -f "$tmp"; die "cannot publish $conf"; }
}

# Converge both shims with the config. Idempotent, so bootstrap can call it every
# session start. Prints one WAKE_RESIDENT: line per ACTIONABLE failure and nothing
# at all when everything is already as it should be.
cmd_sync() {
  local names name home inbox rc=0
  names=$(fm_wr_names "$CONFIG")
  if [ -z "$names" ]; then
    if [ -e "$STATE/wake-resident.check.sh" ]; then
      fm_wr_unwire_main_shim "$STATE" \
        || { echo "WAKE_RESIDENT: cannot remove the lifecycle check shim in $STATE"; rc=1; }
    fi
    return "$rc"
  fi
  mkdir -p "$STATE" 2>/dev/null || { echo "WAKE_RESIDENT: cannot create $STATE"; return 1; }
  fm_wr_wire_main_shim "$FM_ROOT" "$FM_HOME" "$STATE" "$SCRIPT_DIR" \
    || { echo "WAKE_RESIDENT: cannot wire the lifecycle check shim in $STATE"; rc=1; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fm_wr_load "$CONFIG" "$name" || continue
    if ! home=$(fm_wr_home "$STATE" "$name" "$DATA"); then
      # Not yet spawned even once, or not a seeded home for this id. The main
      # shim still covers it; only the in-home fast path needs the home.
      continue
    fi
    inbox=$(fm_wr_inbox_dir "$home")
    mkdir -p "$inbox" 2>/dev/null || true
    fm_wr_wire_self_shim "$FM_ROOT" "$home" "$inbox" "$SCRIPT_DIR" \
      || { echo "WAKE_RESIDENT: secondmate $name: cannot wire the inbox check shim in $home/state"; rc=1; }
  done <<EOF
$names
EOF
  return "$rc"
}

cmd_enable() {
  local name=${1-} idle=$FM_WR_DEFAULT_IDLE_SECS grace=$FM_WR_DEFAULT_GRACE_SECS inbox=
  shift || true
  [ -n "$name" ] || usage_error "enable needs a secondmate name"
  fm_wr_safe_name "$name" || die "unsafe secondmate name '$name'"
  while [ $# -gt 0 ]; do
    case "$1" in
      --idle-secs) shift; idle=${1-}; fm_wr_positive_int "$idle" || usage_error "--idle-secs needs a positive integer" ;;
      --grace-secs) shift; grace=${1-}; fm_wr_positive_int "$grace" || usage_error "--grace-secs needs a positive integer" ;;
      --inbox) shift; inbox=${1-}; case "$inbox" in /*) ;; *) usage_error "--inbox needs an absolute directory" ;; esac ;;
      *) usage_error "unknown option '$1'" ;;
    esac
    shift || true
  done
  grep -qE "^- $name( |$)" "$DATA/secondmates.md" 2>/dev/null \
    || echo "fm-wake-resident: note - $name is not in data/secondmates.md yet; enable is recorded, but a raise needs a seeded, registered secondmate home" >&2
  write_record "$name" "$idle" "$grace" "$inbox"
  cmd_sync
  echo "wake-resident: $name enabled (idle-secs=$idle grace-secs=$grace)"
}

cmd_disable() {
  local name=${1-} home
  [ -n "$name" ] || usage_error "disable needs a secondmate name"
  fm_wr_safe_name "$name" || die "unsafe secondmate name '$name'"
  if fm_wr_load "$CONFIG" "$name" && home=$(fm_wr_home "$STATE" "$name" "$DATA"); then
    fm_wr_unwire_self_shim "$home" || echo "fm-wake-resident: could not remove the inbox check shim in $home/state" >&2
  fi
  drop_record "$name"
  cmd_sync
  echo "wake-resident: $name disabled (its home, lease and state are untouched)"
}

# --- status -----------------------------------------------------------------

status_one() {  # <name>
  local name=$1 home inbox pending residency raised dormant_since
  printf '%s\n' "$name"
  if ! fm_wr_load "$CONFIG" "$name"; then
    printf '  record        : ABSENT (not wake-resident)\n'
    return 0
  fi
  printf '  idle-secs     : %s\n' "$FM_WR_IDLE_SECS"
  printf '  grace-secs    : %s\n' "$FM_WR_GRACE_SECS"
  if ! home=$(fm_wr_home "$STATE" "$name" "$DATA"); then
    printf '  home          : UNRESOLVED (no kind=secondmate meta, or the home is not seeded for this id)\n'
    return 0
  fi
  inbox=$(fm_wr_inbox_dir "$home")
  pending=$(fm_wr_pending_count "$inbox")
  residency=$(fm_wr_residency "$STATE" "$name")
  printf '  home          : %s\n' "$home"
  printf '  inbox         : %s (%s pending)\n' "$inbox" "$pending"
  printf '  residency     : %s\n' "$residency"
  if fm_wr_has_inflight_work "$home"; then
    printf '  work in flight: yes (stand-down refuses)\n'
  else
    printf '  work in flight: no\n'
  fi
  raised=$(fm_wr_record_get "$STATE" "$name" raised_at 2>/dev/null) || raised=
  dormant_since=$(fm_wr_record_get "$STATE" "$name" dormant_since 2>/dev/null) || dormant_since=
  printf '  raised_at     : %s\n' "${raised:-never}"
  printf '  dormant_since : %s\n' "${dormant_since:-never}"
  if [ -f "$home/state/wake-self.check.sh" ]; then
    if fm_custom_check_registered "$home/state" wake-self; then
      printf '  inbox shim    : present, registered\n'
    else
      printf '  inbox shim    : present but UNREGISTERED - the watcher refuses it\n'
    fi
  else
    printf '  inbox shim    : absent\n'
  fi
}

cmd_status() {
  local name=${1-} names
  if [ -n "$name" ]; then
    status_one "$name"
    return 0
  fi
  names=$(fm_wr_names "$CONFIG")
  if [ -z "$names" ]; then
    echo "no wake-resident records in $(conf_file)"
    return 0
  fi
  if [ -f "$STATE/wake-resident.check.sh" ]; then
    if fm_custom_check_registered "$STATE" wake-resident; then
      echo "lifecycle shim : present, registered"
    else
      echo "lifecycle shim : present but UNREGISTERED - the watcher refuses it; run bin/fm-check-register.sh wake-resident"
    fi
  else
    echo "lifecycle shim : absent - run bin/fm-wake-resident.sh sync"
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    status_one "$name"
  done <<EOF
$names
EOF
}

# --- raise ------------------------------------------------------------------

# The raise claim is released from an EXIT trap, so it survives a `die` on any
# path between taking it and finishing. Held in a variable rather than baked into
# the trap string so a state path with a quote in it cannot break the release.
FM_WR_HELD_CLAIM=
release_claim() {
  [ -n "$FM_WR_HELD_CLAIM" ] || return 0
  rm -rf -- "$FM_WR_HELD_CLAIM" 2>/dev/null || true
  FM_WR_HELD_CLAIM=
}

cmd_raise() {
  local name=${1-} claim residency age mtime rc
  [ -n "$name" ] || usage_error "raise needs a secondmate name"
  fm_wr_safe_name "$name" || die "unsafe secondmate name '$name'"
  fm_wr_load "$CONFIG" "$name" || die "$name has no wake-resident record in $(conf_file)"

  # One claim, one agent. Two wakes handled back to back must not both launch:
  # a duplicate supervisor in one home is the worst outcome this whole mechanism
  # can produce, so the loser refuses loudly instead of racing.
  claim="$STATE/.$name.wake-raise.claim"
  if ! mkdir "$claim" 2>/dev/null; then
    mtime=$(fm_wr_mtime "$claim") || mtime=0
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    age=$(( $(fm_wr_now) - mtime ))
    if [ "$mtime" -gt 0 ] && [ "$age" -lt "$FM_WR_RAISE_CLAIM_SECS" ]; then
      die "a raise for $name is already in flight (claim held ${age}s); not launching a second agent"
    fi
    rm -rf "$claim" 2>/dev/null || true
    mkdir "$claim" 2>/dev/null || die "cannot take the raise claim for $name"
  fi
  FM_WR_HELD_CLAIM=$claim
  trap release_claim EXIT

  residency=$(fm_wr_residency "$STATE" "$name")
  case "$residency" in
    resident)
      echo "wake-resident: $name is already up; nothing to raise"
      return 0
      ;;
    unknown)
      die "cannot confirm whether $name is up (inconclusive liveness read); refusing to risk a duplicate supervisor - inspect its endpoint first"
      ;;
  esac

  # The ordinary guarded secondmate launch, and only that.
  if FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-spawn.sh" "$name" --secondmate; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || die "fm-spawn refused or failed to raise $name (exit $rc)"
  fm_wr_record_set "$STATE" "$name" raised_at "$(fm_wr_now)" || true
  clear_throttles "$name"
  echo "wake-resident: $name raised"
}

# --- standdown --------------------------------------------------------------

cmd_standdown() {
  local name=${1-} force=0 home inbox pending residency meta backend target harness
  local exit_cmd waited quiet raised last_seen activity idle snapshot lost
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) usage_error "unknown option '$1'" ;;
    esac
    shift
  done
  [ -n "$name" ] || usage_error "standdown needs a secondmate name"
  fm_wr_safe_name "$name" || die "unsafe secondmate name '$name'"
  fm_wr_load "$CONFIG" "$name" || die "$name has no wake-resident record in $(conf_file)"
  home=$(fm_wr_home "$STATE" "$name" "$DATA") \
    || die "cannot resolve a seeded secondmate home for $name; refusing to act on an unverified path"

  # The two refusals that --force must never waive. They gate a stand-down no
  # matter what the liveness read below says: a secondmate with its own work in
  # flight or unanswered mail must be left for that work to finish or that mail to
  # raise it again, even when its own agent process has already exited.
  if fm_wr_has_inflight_work "$home"; then
    die "$name still has work in flight in $home/state; leaving it up. Let that work finish, or retire the secondmate deliberately with bin/fm-teardown.sh"
  fi
  inbox=$(fm_wr_inbox_dir "$home")
  pending=$(fm_wr_pending_count "$inbox")
  if [ "$pending" -gt 0 ]; then
    die "$name has $pending unanswered message(s) in $inbox; leaving it up so nothing is dropped"
  fi

  # The liveness decision, read after those refusals so a just-exited agent is
  # seen as gone rather than caught mid-settle. A wake-resident agent that has
  # already exited itself leaves a bare shell behind (the "Resume this session
  # with: claude --resume ..." prompt docs/wake-resident.md calls dormant-healthy),
  # and that IS the outcome a stand-down is trying to reach. So record the
  # stand-down without any pane submission, rather than typing an exit command a
  # bare shell cannot accept and then reporting that refusal as a failure. Nothing
  # is sent on this path, so it also cleanly stands a self-exited agent down on a
  # harness whose exit is not a submittable line (grok). No exit action is taken
  # here, so there is nothing to snapshot-and-verify: fm_wr_home already confirmed
  # the persistent home and its identity marker exist. `unknown` still licenses
  # nothing in either direction.
  residency=$(fm_wr_residency "$STATE" "$name")
  case "$residency" in
    dormant)
      fm_wr_record_set "$STATE" "$name" dormant_since "$(fm_wr_now)" || true
      clear_throttles "$name"
      echo "wake-resident: $name agent had already exited; recorded stand-down (no exit command sent)"
      return 0
      ;;
    unknown)
      die "cannot confirm whether $name is up (inconclusive liveness read); refusing to type an exit command into an unverified pane"
      ;;
  esac

  meta="$STATE/$name.meta"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || die "no runtime endpoint recorded for $name"
  # fm-send applies the from-firstmate marker to a TASK SELECTOR whose meta is
  # kind=secondmate, and a marked "/exit" is not an exit command - it is a
  # sentence typed at the agent. The explicit backend target avoids that, so
  # refuse rather than send if the recorded endpoint would itself resolve as a
  # selector.
  case "$target" in
    "$name"|fm-*) die "the recorded endpoint for $name ('$target') would resolve as a task selector, which marks the send; stand it down by hand" ;;
  esac
  harness=$(fm_meta_get "$meta" harness)
  exit_cmd=$(fm_wr_exit_command "$harness") \
    || die "harness '${harness:-unknown}' has no submittable exit command (grok's exit is an interactive double Ctrl+Q); stand $name down by hand instead"

  if [ "$force" -eq 0 ]; then
    if fm_wr_confirmed_busy "$backend" "$target"; then
      die "$name is busy right now; leaving it up"
    fi
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
    idle=$(( $(fm_wr_now) - quiet ))
    if [ "$quiet" -le 0 ] || [ "$idle" -lt "$FM_WR_IDLE_SECS" ]; then
      die "$name has only been quiet ${idle}s of the required ${FM_WR_IDLE_SECS}s; leaving it up (--force waives this gate)"
    fi
  fi

  # Snapshot the PERSISTENT axis before touching the process, so "an exit loses
  # nothing" is verified below rather than asserted.
  snapshot=$(mktemp "${TMPDIR:-/tmp}/fm-wake-resident-persist.XXXXXX") || die "cannot stage the persistence snapshot"
  fm_wr_persistence_snapshot "$STATE" "$name" "$home" "$DATA" > "$snapshot" \
    || { rm -f "$snapshot"; die "cannot read $name's persistent state; refusing to exit a process whose identity I cannot account for"; }

  # THE EXIT. Sent to the explicit backend target rather than the task selector,
  # so fm-send does NOT prefix its from-firstmate marker - a marked "/exit" is not
  # an exit command, it is a sentence typed at the agent.
  if ! FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-send.sh" "$target" "$exit_cmd" >/dev/null; then
    rm -f "$snapshot"
    die "could not submit '$exit_cmd' to $name at $target; it is still up"
  fi

  # "Agent confirmed absent" is the agent-state contract's dead/missing verdict:
  # fm_backend_agent_alive returns `dead` ONLY for a confidently agent-free or
  # authoritatively-missing endpoint, and `unknown` for every inconclusive read.
  # Testing `= dead` therefore preserves the fail-safe direction - an exit that
  # does not confirm is left alone rather than declared done.
  waited=0
  while [ "$waited" -lt "$STANDDOWN_TIMEOUT" ]; do
    if ! fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
      break
    fi
    if [ "$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null)" = dead ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if fm_backend_target_exists "$backend" "$target" 2>/dev/null \
     && [ "$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null)" != dead ]; then
    rm -f "$snapshot"
    die "$name did not confirm its exit within ${STANDDOWN_TIMEOUT}s; leaving it alone rather than killing a possibly-working agent"
  fi

  # The PERSISTENT axis, checked. Only the PROCESS was supposed to end; if any of
  # the identity or state this secondmate is made of went with it, that is a
  # destroyed persistent agent, not a completed stand-down, and it must be loud.
  if ! lost=$(fm_wr_persistence_verify "$snapshot"); then
    rm -f "$snapshot"
    echo "$lost" >&2
    die "INTERNAL: $name lost persistent state during a stand-down - an exit must never do this; inspect the paths above before raising it again"
  fi
  rm -f "$snapshot"

  fm_wr_record_set "$STATE" "$name" dormant_since "$(fm_wr_now)" || true
  clear_throttles "$name"
  echo "wake-resident: $name stood down; the process ended, its identity and state are intact"
}

case "${1---help}" in
  --help|-h|help) usage; exit 0 ;;
  enable) shift; cmd_enable "$@" ;;
  disable) shift; cmd_disable "$@" ;;
  sync) shift; [ $# -eq 0 ] || usage_error "sync takes no arguments"; cmd_sync ;;
  status) shift; cmd_status "$@" ;;
  raise) shift; cmd_raise "$@" ;;
  standdown) shift; cmd_standdown "$@" ;;
  *) usage_error "unknown command '$1'" ;;
esac
