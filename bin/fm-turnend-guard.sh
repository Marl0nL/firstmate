#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Fail-open on the REAL hook path is deliberate and unchanged: an empty or
# unreadable payload, or a missing jq, exits 0 in silence rather than risking a
# wedged session over a payload it cannot parse.
# A run with no payload channel at all - someone running this script BY HAND - is
# the opposite hazard and is NOT silent: it prints a loud "nothing was checked"
# block and exits 3, because a silent 0 there reads as an all-clear this guard
# never gave. See the stdin block below for the evidence behind that.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Is stdin obviously NOT a hook payload channel? Every tracked adapter in this repo
# writes the JSON down a pipe and closes it (claude, codex, and grok through a shell
# pipe; opencode and pi through a spawned stdin pipe), so the shapes below are ones
# no real hook produces: an interactive terminal, or a character device such as
# /dev/null.
# The test is deliberately NEGATIVE - anything it cannot positively identify as a
# hand run is treated as a real hook channel and keeps the silent fail-open. A
# positive "is this a pipe/socket/regular file" test would have to be right about
# /dev/stdin on every platform this repo runs on (Linux and Darwin), and being
# wrong there would make a real hook noisy; being wrong this way only costs the
# loud line on an exotic hand run, which the read timeout below catches anyway.
fm_stdin_is_hand_run_channel() {
  [ -t 0 ] && return 0
  [ -c /dev/stdin ] && return 0
  return 1
}

# Read the whole turn-end hook payload once, BOUNDED: `cat` blocks forever on a
# stdin nobody ever closes, and that is the normal shape of an agent's shell (a
# harness-held socket on fd 0, measured 2026-07-30 on Claude Code 2.1.220), so a
# hand run used to hang instead of answering. Every real hook writes its payload in
# one go and closes, so a read that times out means either no payload at all or a
# writer that is not behaving like a hook.
# `read -d ''` consumes to EOF (or the timeout) and still assigns what it got.
# Its own stderr is silenced because a closed fd 0 makes the builtin print a raw
# "read error: Bad file descriptor" that the old `cat 2>/dev/null` swallowed, and
# callers scrape this script's stderr as a reason string.
PAYLOAD_TIMEOUT=${FM_TURNEND_PAYLOAD_TIMEOUT:-2}
PAYLOAD=
PAYLOAD_READ_STATUS=0
IFS= read -r -d '' -t "$PAYLOAD_TIMEOUT" PAYLOAD 2>/dev/null || PAYLOAD_READ_STATUS=$?
PAYLOAD_TIMED_OUT=0
[ "$PAYLOAD_READ_STATUS" -gt 128 ] && PAYLOAD_TIMED_OUT=1

# The timeout is a TOTAL budget, not an idle timeout, so a writer that dribbles the
# payload can leave a PARTIAL one here. That parses as nothing, and the jq failure
# below would then fail open in silence - the same false all-clear this script now
# refuses to give. Say it, and still fail open: a payload this script could not read
# whole is not grounds for blocking a turn.
if [ -n "$PAYLOAD" ] && [ "$PAYLOAD_TIMED_OUT" -eq 1 ]; then
  {
    printf 'fm-turnend-guard: HOOK PAYLOAD TRUNCATED after %ss - NOTHING WAS CHECKED.\n' "$PAYLOAD_TIMEOUT"
    printf 'fm-turnend-guard: This is NOT a supervision health check and NOT an all-clear.\n'
    printf 'fm-turnend-guard: Raise FM_TURNEND_PAYLOAD_TIMEOUT if this hook really is that slow.\n'
  } >&2
  exit 0
fi
if [ -z "$PAYLOAD" ]; then
  # On the real hook path an empty/unreadable payload stays a SILENT exit 0. That
  # fail-open is deliberate: without the payload we cannot read the loop guard, and
  # a guard that blocks on a payload it cannot parse could wedge a live session.
  # A real hook closes its payload channel, so that path always reaches EOF; a
  # channel still held open when the read times out is not a hook delivering
  # nothing, it is a shell whose stdin belongs to something else.
  if [ "$PAYLOAD_TIMED_OUT" -eq 0 ] && ! fm_stdin_is_hand_run_channel; then
    exit 0
  fi
  # A hand run is the opposite problem. Exiting 0 and printing nothing looks
  # exactly like a clean bill of health, so on 2026-07-29 a hand-run of this script
  # was read as proof that supervision was live while it had in fact checked
  # nothing at all - the guard's own warnings were true positives the whole time.
  # Say so unmistakably, and exit 3: distinct from a pass (0) and from the block
  # this guard uses to stop a blind turn end (2), so no caller can score a hand run
  # as either verdict.
  {
    printf 'fm-turnend-guard: NO HOOK PAYLOAD ON STDIN - NOTHING WAS CHECKED.\n'
    printf 'fm-turnend-guard: This is NOT a supervision health check and NOT an all-clear.\n'
    printf 'fm-turnend-guard: Only a real turn-end hook payload exercises this guard.\n'
    printf 'fm-turnend-guard: To check supervision now, run bin/fm-guard.sh (pull-based alarm)\n'
    printf 'fm-turnend-guard: or bin/fm-crew-state.sh for current fleet state.\n'
    printf 'fm-turnend-guard: A SILENT fm-guard.sh means no alarm fired, which is not the same\n'
    printf 'fm-turnend-guard: claim as "supervision is live" - it never contradicts a block above.\n'
  } >&2
  exit 3
fi

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# Return 0 when $1 (a firstmate root) carries a GENUINE secondmate-home marker.
# bin/fm-home-seed.sh writes .fm-secondmate-home at a seeded secondmate home's
# root (gitignored, so it never propagates into a child worktree); its content is
# the secondmate id. Validate the marker's form so a stray/empty/symlink file
# cannot spoof inclusion and an unmarked child is never guarded by accident: it
# must be a regular (non-symlink) file whose first line, with all whitespace
# removed, is a non-empty id token (letters, digits, dot, underscore, dash only).
# The allowlist is matched under forced C (ASCII) collation - `local LC_ALL=C`,
# restored on return - so a locale-crafted non-ASCII id cannot slip through the
# range match and spoof force-inclusion. This is a deliberately lightweight
# guard-local presence check, distinct from fm-ff-lib.sh's validate_secondmate_home
# (which matches an EXPECTED id and does path-safety); the guard does not source
# that heavier library.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
if ! fm_root_is_secondmate_home "$FM_ROOT"; then
  GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
  GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
  [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
fi
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE" "$WATCH" "$FM_HOME"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0

# Ending a turn is safe only when BOTH halves of supervision hold and nothing is
# already waiting to be handled:
#   watcher live   - something is detecting fleet events (lock-based; the beacon
#                    alone was never a liveness test - see fm-supervision-lib.sh)
#   waiter alive   - an arm is waiting, so the next wake has a path to the agent.
#                    Since fm-watch.sh self-renews, a live watcher no longer
#                    implies anyone is listening, and a turn that ends with no
#                    arm goes deaf until the captain next speaks.
#   queue empty    - a wake already enqueued and undrained is an unhandled
#                    supervision event; ending the turn on one buries it.
# AWAY MODE EXEMPTS THE WAITER CHECK, and only that one.
# While state/.afk exists the sub-supervisor daemon runs the watcher itself and
# delivers by INJECTING into the session, so there is legitimately no arm and
# never will be one. Requiring a waiter there would block every single turn of an
# away-mode session on a condition the session is forbidden to fix - AGENTS.md
# bars arming a separate watcher while the daemon owns supervision.
afk=0
[ -e "$STATE/.afk" ] && afk=1

BLIND_REASON=
if [ "$FM_SUP_WATCHER_FRESH" != true ]; then
  BLIND_REASON="no live watcher holds this home lock (last beat: $FM_SUP_BEACON_DESC)"
elif [ "$FM_SUP_WAITER_ALIVE" != true ] && [ "$afk" -eq 0 ]; then
  BLIND_REASON="a watcher is running but no arm is waiting on it, so its next wake reaches nobody"
elif [ "$FM_SUP_QUEUE_PENDING" = true ]; then
  BLIND_REASON="wakes are queued and undrained - handle them with bin/fm-wake-drain.sh"
fi
[ -n "$BLIND_REASON" ] || exit 0

x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight, but %s.\n' "$FM_SUP_IN_FLIGHT" "$BLIND_REASON"
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2
