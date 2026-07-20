#!/usr/bin/env bash
# fm-autostart.sh - bring the firstmate primary agent up unattended at boot.
#
# WHY THIS EXISTS
# `herdr server` is headless: the systemd user unit that runs it at boot brings
# up a server with zero panes, because pane resurrection is CLIENT-side work.
# herdr says so itself in its own boot log ("did you mean to open the Herdr TUI?
# run 'herdr'; you do not need 'herdr server'"). So boot produced a server and
# no firstmate, and the fleet stayed dark until a human attached. This script is
# the missing client-side step, driven over the socket API instead of a TUI:
# `herdr agent start`, which materialises an agent headlessly.
#
# THE ONE RULE: NEVER CREATE A SECOND FIRSTMATE.
# Two firstmates on one home fight over the session lock and the fleet - a
# strictly worse outcome than no autostart at all. Every uncertainty therefore
# resolves to "do not start": a server that never becomes ready, an agent list
# that cannot be read or parsed, an unrecognised response shape - all exit
# non-zero WITHOUT starting anything. The only path that starts an agent is one
# where the server answered and the answer positively contained no firstmate.
#
# WHAT COUNTS AS "a firstmate is already running"
# Either an agent named --name (default `firstmate`), or ANY agent whose working
# directory is the firstmate home. The second test is the load-bearing one: an
# agent herdr resurrected, or one the captain launched by hand, carries no name
# at all (`name` is null for every agent not started through `agent start
# <name>`), so name matching alone would happily start a duplicate next to the
# live firstmate. Directory matching catches it.
#
# PATH ALIASING IS PART OF THAT TEST, NOT A DETAIL.
# On ostree/atomic Fedora `/home` is a symlink to `/var/home`, so the same
# firstmate home has two spellings and herdr may report the one the unit did not
# pass. A string compare would miss the live firstmate and start a duplicate -
# the exact failure this script exists to prevent. Both sides are resolved to a
# physical path before comparison (see data/learnings.md, 2026-07-16).
#
# INSTALLATION IS THE CAPTAIN'S STEP, NOT THIS SCRIPT'S.
# This script never installs or enables a systemd unit. The unit template lives
# at assets/systemd/firstmate-autostart.service; docs/firstmate-autostart.md
# owns the install, rollback, and verification steps.
#
# READINESS IS POLLED, NEVER SLEPT.
# `After=herdr-server.service` orders the unit after the server PROCESS starts,
# which is not the same as the socket being answerable. The script polls
# `herdr status server` until it reports a running, protocol-compatible server,
# bounded by --timeout, and fails with the last status it saw rather than
# guessing a sleep long enough to cover a slow boot.
#
# Usage:
#   fm-autostart.sh [options] [-- <argv>...]
#
# Options:
#   --fm-root PATH   firstmate home to start the agent in
#                    (default: this script's own repo root)
#   --name NAME      agent name to create and to match on (default: firstmate)
#   --timeout SECS   bound on the server-readiness wait (default: 120)
#   --interval SECS  delay between readiness polls, may be fractional (default: 1)
#   --confirm SECS   bound on confirming the started agent appears (default: 20)
#   --dry-run        report the decision and print the command; start nothing
#   --help           print this usage
#   -- <argv>...     command to run in the agent, replacing the default
#
# Default agent argv:
#   claude --dangerously-skip-permissions --remote-control --continue
# The two launch flags are passed explicitly rather than relying on
# bin/fm-claude-shim.sh being installed, so autostart works on a home that never
# installed the shim; injection is idempotent, so passing them is safe on a home
# that did (docs/claude-resume-shim.md). `--continue` resumes the most recent
# conversation IN THAT DIRECTORY, which survives session-id churn; a pinned
# `--resume <id>` goes stale the first time the session id changes and would
# then fail at boot with no human present.
#
# Exit status:
#   0  a firstmate is up: either already present (no-op) or started and confirmed
#   1  usage or environment error (bad flag, no herdr, no jq, no firstmate home)
#   2  the herdr server did not become ready within --timeout
#   3  the agent list could not be read or understood - state unknown, so nothing
#      was started (fail closed)
#   4  the start was attempted and failed, or the agent never appeared
set -eu

SELF="${BASH_SOURCE[0]}"
DEFAULT_ROOT="$(cd "$(dirname "$SELF")/.." && pwd -P)"

FM_ROOT=""
AGENT_NAME="firstmate"
TIMEOUT=120
INTERVAL=1
CONFIRM_TIMEOUT=20
DRY_RUN=0
AGENT_ARGV=()
ARGV_GIVEN=0

usage() {
  sed -n 's/^# \{0,1\}//p' "$SELF" | sed -n '/^Usage:/,/^   4  /p'
}

die() {
  printf 'fm-autostart.sh: %s\n' "$1" >&2
  exit "${2:-1}"
}

# --- argument parsing -------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fm-root) [ "$#" -ge 2 ] || die "--fm-root needs a value"; FM_ROOT=$2; shift 2 ;;
    --name) [ "$#" -ge 2 ] || die "--name needs a value"; AGENT_NAME=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || die "--interval needs a value"; INTERVAL=$2; shift 2 ;;
    --confirm) [ "$#" -ge 2 ] || die "--confirm needs a value"; CONFIRM_TIMEOUT=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --)
      shift
      [ "$#" -gt 0 ] || die "-- needs a command to run in the agent"
      AGENT_ARGV=("$@")
      ARGV_GIVEN=1
      break
      ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

case "$TIMEOUT" in
  '' | *[!0-9]*) die "--timeout must be a whole number of seconds, got '$TIMEOUT'" ;;
esac
case "$CONFIRM_TIMEOUT" in
  '' | *[!0-9]*) die "--confirm must be a whole number of seconds, got '$CONFIRM_TIMEOUT'" ;;
esac
case "$INTERVAL" in
  '' | *[!0-9.]* | '.') die "--interval must be a non-negative number, got '$INTERVAL'" ;;
esac

# Tracked with a flag rather than by testing the array's length: expanding an
# empty array under `set -u` is an error on stock macOS Bash 3.2, and `--` with
# no command is already refused above, so AGENT_ARGV is only ever expanded
# non-empty.
if [ "$ARGV_GIVEN" -eq 0 ]; then
  AGENT_ARGV=(claude --dangerously-skip-permissions --remote-control --continue)
fi

# --- environment ------------------------------------------------------------

[ -n "$FM_ROOT" ] || FM_ROOT=$DEFAULT_ROOT
[ -d "$FM_ROOT" ] || die "firstmate home '$FM_ROOT' is not a directory"
FM_ROOT=$(cd "$FM_ROOT" && pwd -P)
# Structural check, not a name check: refuse to start an unattended supervisor
# in a directory that is not actually a firstmate checkout.
[ -f "$FM_ROOT/AGENTS.md" ] && [ -x "$FM_ROOT/bin/fm-spawn.sh" ] ||
  die "'$FM_ROOT' does not look like a firstmate home (no AGENTS.md + bin/fm-spawn.sh)"

command -v herdr >/dev/null 2>&1 || die "herdr not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH (required to parse herdr's JSON)"

# --- helpers ----------------------------------------------------------------

# Resolve to a physical path so /home and /var/home spellings of one directory
# compare equal. A path that does not exist locally keeps its literal spelling:
# it cannot be the firstmate home, so it can only ever fail to match, which is
# the safe direction only because the home's OWN side always resolves.
physical_path() {
  local raw=$1
  if [ -d "$raw" ]; then
    (cd "$raw" 2>/dev/null && pwd -P) || printf '%s' "$raw"
  else
    printf '%s' "$raw"
  fi
}

# Poll `herdr status server` until it reports a running, compatible server.
# Prints nothing on success; on timeout, reports the last status it saw so the
# journal shows WHY rather than only that a wait elapsed.
wait_for_server() {
  local deadline last="(no response from 'herdr status server')" out
  deadline=$(( $(date +%s) + TIMEOUT ))
  while :; do
    if out=$(herdr status server 2>&1); then
      last=$out
      case "$out" in
        *'status: running'*)
          case "$out" in
            *'compatible: no'*) : ;;
            *) return 0 ;;
          esac
          ;;
      esac
    else
      last=$out
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$INTERVAL"
  done
  printf 'fm-autostart.sh: the herdr server was not ready within %ss; started nothing.\n' \
    "$TIMEOUT" >&2
  printf 'fm-autostart.sh: last status was:\n%s\n' "$last" >&2
  return 1
}

# Answer "is a firstmate already running?" over the socket API.
#   0  yes, one is present (prints the matching agent's identity)
#   1  no, positively absent
#   2  unknown - the list could not be read or understood
firstmate_present() {
  local raw name cwd fgcwd line count seen=0
  raw=$(herdr agent list 2>/dev/null) || return 2
  # A response that does not carry the agents array is an error or an
  # unrecognised shape, not an empty fleet. Never read it as "absent".
  printf '%s' "$raw" | jq -e 'has("result") and (.result | has("agents"))' >/dev/null 2>&1 || return 2
  # How many agents the response claims, so a truncated or failed extraction
  # below cannot masquerade as an empty fleet and green-light a duplicate.
  count=$(printf '%s' "$raw" | jq '(.result.agents // []) | length' 2>/dev/null) || return 2
  case "$count" in
    '' | *[!0-9]*) return 2 ;;
  esac

  # NUL-delimited, three fields per agent, read through a process substitution.
  # Not @tsv and not one-field-per-line: an absent name is the COMMON case, and
  # bash's `read` silently swallows a leading empty field when the delimiter is
  # whitespace (a tab is IFS whitespace), which would misread every unnamed
  # agent's cwd as its name and let a duplicate firstmate through. NUL is the
  # one delimiter that cannot appear in a name or a path.
  while
    IFS= read -r -d '' name &&
      IFS= read -r -d '' cwd &&
      IFS= read -r -d '' fgcwd
  do
    seen=$((seen + 1))
    if [ -n "$name" ] && [ "$name" = "$AGENT_NAME" ]; then
      printf 'agent named %s\n' "$name"
      return 0
    fi
    for line in "$cwd" "$fgcwd"; do
      [ -n "$line" ] || continue
      if [ "$(physical_path "$line")" = "$FM_ROOT" ]; then
        printf 'agent running in %s\n' "$line"
        return 0
      fi
    done
  done < <(printf '%s' "$raw" | jq -j '(.result.agents // [])[] |
      (.name // ""), "\u0000", (.cwd // ""), "\u0000", (.foreground_cwd // ""), "\u0000"')

  # Reaching here means no agent matched. Only trust that as "positively absent"
  # if every agent the response claimed was actually examined; a short read means
  # the extraction failed partway, and an unexamined agent could be the live
  # firstmate.
  [ "$seen" -eq "$count" ] || return 2
  return 1
}

# --- run --------------------------------------------------------------------

wait_for_server || exit 2

set +e
present_desc=$(firstmate_present)
present_rc=$?
set -e

case "$present_rc" in
  0)
    printf 'fm-autostart.sh: firstmate is already up (%s); nothing to do.\n' "$present_desc"
    exit 0
    ;;
  2)
    die "could not read the agent list; refusing to start a possible duplicate firstmate" 3
    ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'fm-autostart.sh: no firstmate present; would run:\n'
  printf '  herdr agent start %s --cwd %s --no-focus --' "$AGENT_NAME" "$FM_ROOT"
  printf ' %s' "${AGENT_ARGV[@]}"
  printf '\n'
  exit 0
fi

printf 'fm-autostart.sh: no firstmate present; starting one in %s.\n' "$FM_ROOT"
# --no-focus matches every other firstmate-driven herdr create: firstmate never
# steals whatever space the captain is watching. In a brand-new empty session
# herdr focuses the first workspace regardless, so a boot-time start still lands
# in view (docs/herdr-backend.md).
if ! herdr agent start "$AGENT_NAME" --cwd "$FM_ROOT" --no-focus -- "${AGENT_ARGV[@]}"; then
  die "'herdr agent start' failed; no firstmate is running" 4
fi

# A created pane is not a started agent: confirm the agent actually shows up
# rather than reporting success on the strength of an exit status alone.
confirm_deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  set +e
  present_desc=$(firstmate_present)
  present_rc=$?
  set -e
  if [ "$present_rc" -eq 0 ]; then
    printf 'fm-autostart.sh: firstmate is up (%s).\n' "$present_desc"
    exit 0
  fi
  [ "$(date +%s)" -lt "$confirm_deadline" ] || break
  sleep "$INTERVAL"
done

die "started the agent but it never appeared in the agent list within ${CONFIRM_TIMEOUT}s" 4
