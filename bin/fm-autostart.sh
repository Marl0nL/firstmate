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
# An agent list ENTRY IS NOT ENOUGH. The entry must first MATCH this home -
# either an agent named --name (default `firstmate`), or ANY agent whose
# working directory is the firstmate home - and then that match must be
# CONFIRMED LIVE against the pane it claims to occupy.
#
# The directory match is the load-bearing half of matching: an agent herdr
# resurrected, or one the captain launched by hand, carries no name at all
# (`name` is absent or null for every agent not started through `agent start
# <name>`), so name matching alone would happily start a duplicate next to the
# live firstmate.
#
# The liveness confirmation is the load-bearing half of the answer, and it is
# why this script once never started anything at all. `herdr agent list` is
# served from the session layout herdr persists in ~/.config/herdr/session.json,
# so after a reboot it REPLAYS records - agent, cwd, pane_id, even
# agent_status "idle" - for agents that are not running. Matching those GHOST
# records made the guard report "firstmate is already up" and start nothing, at
# every boot, forever, silently: a permanent no-op wearing the costume of
# idempotence. Verified live 2026-07-20 (herdr 0.7.4): two listed "idle" agents
# claimed the firstmate home while exactly one claude process existed on the
# machine, and neither of those panes had any process behind it.
#
# Confirmation asks bin/backends/herdr.sh, which owns this classification for
# the whole fleet, about the entry's pane - and it deliberately asks ONLY the
# reality-touching questions, never the metadata ones:
#   fm_backend_herdr_pane_process_state  - is there a real PROCESS behind the
#                                          pane (live), or none (dead)?
#   fm_backend_herdr_pane_process_cwds   - where do those processes actually
#                                          run, per the kernel, not per herdr?
# A name-matched entry needs a live process; a cwd-matched entry additionally
# needs some foreground process whose real working directory is the firstmate
# home, because the cwd that MATCHED came from replayable metadata and only the
# process's own cwd is evidence. Only `pane process-info` sees reality: a ghost
# passes `pane get` and `agent get` intact - they replay from the same
# persisted layout the list came from. Anything else, including an entry that
# names no pane at all, is UNKNOWN, and unknown never licenses a start (see THE
# ONE RULE above).
#
# `agent get`'s agent_status is deliberately NOT consulted. On herdr 0.7.4 /
# protocol 16 it is miscalibrated in both directions: a genuinely live,
# registered, captain-serving firstmate reports agent_status "unknown"
# (verified live 2026-07-20 against the running firstmate), so requiring a
# "real" status made this script declare a working boot a failure (exit 4) at
# every reboot, and made the already-up no-op path exit 3 instead of 0. The
# false-failure was worse than cosmetic: a unit that always reports failure
# invites a retry-on-failure that would try to start a SECOND supervisor.
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
# THE NETWORK GATE: NO AGENT ON A DEAD NETWORK.
# The agent this script starts registers with Anthropic's remote-control
# service the moment it launches, and a launch before the network is usable
# produced a firstmate that was invisible to the captain's app and never
# self-healed (verified across two reboots, 2026-07-20). The captain's decision:
# there is no point running an agent without the network, so wait for it, and
# extra boot delay is acceptable. Before starting anything (never for the
# already-up no-op), the script therefore polls until the network is genuinely
# usable, bounded by --net-timeout, and fails LOUDLY with exit 5 - its own
# distinct code - rather than starting an agent that cannot register.
#
# The decisive probe is an HTTPS request to https://api.anthropic.com/ (curl,
# bounded by --max-time): it proves DNS resolution, routing, TCP, and TLS to
# the endpoint registration actually depends on. A ping to 8.8.8.8 proves only
# routing, and ICMP is filtered on many networks, so ping is used purely as a
# DIAGNOSTIC: when the gate fails, the failure report says whether basic
# routing was up (pointing at DNS/endpoint trouble) or not (no network at
# all). Without curl, a bounded /dev/tcp connect to api.anthropic.com:443
# stands in (DNS + TCP, no TLS); with no way to run a bounded probe at all the
# gate fails closed rather than hanging boot or starting blind.
#
# Usage:
#   fm-autostart.sh [options] [-- <argv>...]
#
# Options:
#   --fm-root PATH      firstmate home to start the agent in
#                       (default: this script's own repo root)
#   --name NAME         agent name to create and to match on (default: firstmate)
#   --timeout SECS      bound on the server-readiness wait (default: 120)
#   --interval SECS     delay between readiness polls, may be fractional (default: 1)
#   --confirm SECS      bound on confirming the started agent appears (default: 20)
#   --net-timeout SECS  bound on the network-reachability wait (default: 120)
#   --skip-net-check    skip the network gate (for a deliberately offline start;
#                       the gate otherwise refuses to start an agent that
#                       cannot register)
#   --dry-run           report the decision and print the command; start nothing
#   --help              print this usage
#   -- <argv>...        command to run in the agent, replacing the default
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
#   3  the agent list could not be read or understood, or an entry matching this
#      home could not be classified live-or-not - state unknown, so nothing was
#      started (fail closed)
#   4  the start was attempted and failed, or the agent never appeared
#   5  the network gate failed: no usable route to the registration endpoint
#      within --net-timeout, so nothing was started
set -eu

SELF="${BASH_SOURCE[0]}"
DEFAULT_ROOT="$(cd "$(dirname "$SELF")/.." && pwd -P)"

FM_ROOT=""
AGENT_NAME="firstmate"
TIMEOUT=120
INTERVAL=1
CONFIRM_TIMEOUT=20
NET_TIMEOUT=120
SKIP_NET_CHECK=0
DRY_RUN=0
AGENT_ARGV=()
ARGV_GIVEN=0

# The endpoint remote-control registration depends on: resolving and reaching
# Anthropic's API host. See THE NETWORK GATE in the header for why this, and
# not a ping, is the decisive probe.
NET_PROBE_URL="https://api.anthropic.com/"
NET_PROBE_HOST="api.anthropic.com"
NET_PROBE_PORT=443
NET_DIAG_HOST="8.8.8.8"

usage() {
  sed -n 's/^# \{0,1\}//p' "$SELF" | sed -n '/^Usage:/,/within --net-timeout, so nothing was started/p'
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
    --net-timeout) [ "$#" -ge 2 ] || die "--net-timeout needs a value"; NET_TIMEOUT=$2; shift 2 ;;
    --skip-net-check) SKIP_NET_CHECK=1; shift ;;
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
case "$NET_TIMEOUT" in
  '' | *[!0-9]*) die "--net-timeout must be a whole number of seconds, got '$NET_TIMEOUT'" ;;
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

# The pane classifiers are owned by the herdr adapter, not restated here: one
# owner for "what does this pane actually hold" keeps this script and the
# watcher/spawn paths from drifting apart about what counts as alive. FM_ROOT
# is this script's own resolved home and the adapter assigns its own meaning to
# that name, so it is saved across the source and restored immediately.
FM_AUTOSTART_ROOT=$FM_ROOT
# shellcheck source=bin/backends/herdr.sh
. "$DEFAULT_ROOT/bin/backends/herdr.sh"
FM_ROOT=$FM_AUTOSTART_ROOT
# The same session `herdr agent start` below lands in: ambient HERDR_SESSION if
# the operator set one, herdr's own `default` otherwise. Held in its own
# variable rather than assigned back into HERDR_SESSION, which would change
# which session the start itself targets.
HERDR_SESSION_NAME=$(fm_backend_herdr_session)

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

# Probe basic routing with one bounded ICMP ping. Diagnostic only - the gate
# never succeeds or fails on this alone (ICMP is filtered on many networks and
# ping may not be installed).
#   0 routing up, 1 no reply, 2 could not probe
probe_icmp() {
  command -v ping >/dev/null 2>&1 || return 2
  ping -n -c 1 -W 2 "$NET_DIAG_HOST" >/dev/null 2>&1 || return 1
}

# The decisive probe: can the registration endpoint be resolved and reached
# RIGHT NOW? curl exits 0 for any completed HTTPS exchange (an HTTP error
# status still proves DNS + route + TCP + TLS, which is all the gate needs);
# the /dev/tcp fallback proves DNS + route + TCP. Every path is bounded: an
# unbounded probe would turn a broken network into a boot that hangs forever.
#   0 reachable, 1 not reachable, 2 no bounded probe is possible on this host
probe_endpoint() {
  if command -v curl >/dev/null 2>&1; then
    curl --silent --output /dev/null --max-time 5 "$NET_PROBE_URL" 2>/dev/null || return 1
  elif command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -c "exec 3<>/dev/tcp/$NET_PROBE_HOST/$NET_PROBE_PORT" 2>/dev/null || return 1
  else
    return 2
  fi
}

# One diagnostic line for logs: what the failed gate can say about WHICH layer
# is broken, so the journal distinguishes "no network at all" from "network up
# but the endpoint does not resolve or connect".
net_diagnosis() {
  if probe_icmp; then
    printf 'routing is up (ICMP ping to %s answers), so the failure is DNS, TLS, or reachability of %s specifically' \
      "$NET_DIAG_HOST" "$NET_PROBE_HOST"
  else
    printf 'ICMP ping to %s got no reply either (routing may be down, or ICMP is filtered on this network)' \
      "$NET_DIAG_HOST"
  fi
}

# Poll the endpoint probe until it answers or --net-timeout elapses. Prints one
# line on success (how long the wait was, so a slow boot is visible in the
# journal); on failure reports the layer diagnosis and returns 1 so the caller
# can exit 5 having started nothing.
wait_for_network() {
  local start deadline waited rc
  start=$(date +%s)
  deadline=$(( start + NET_TIMEOUT ))
  while :; do
    # rc captured in an else-branch: after an if whose condition failed and
    # which has no else, $? is 0, not the condition's status.
    if probe_endpoint; then
      waited=$(( $(date +%s) - start ))
      printf 'fm-autostart.sh: network gate passed: %s reachable after %ss.\n' \
        "$NET_PROBE_HOST" "$waited"
      return 0
    else
      rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
      printf 'fm-autostart.sh: network gate cannot run: neither curl nor timeout is available for a bounded probe; started nothing.\n' >&2
      return 1
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$INTERVAL"
  done
  printf 'fm-autostart.sh: network gate FAILED: %s not reachable within %ss; started nothing.\n' \
    "$NET_PROBE_HOST" "$NET_TIMEOUT" >&2
  printf 'fm-autostart.sh: %s\n' "$(net_diagnosis)" >&2
  return 1
}

# Confirm that a matching agent-list entry is a LIVE firstmate rather than a
# ghost record replayed from herdr's persisted session layout (see the
# header). Judged ONLY on reality-touching signals - `pane process-info` and
# the processes' kernel-reported working directories - never on `agent get`
# metadata, whose agent_status reports "unknown" for a genuinely live agent on
# herdr 0.7.4 and made this guard cry failure over a working boot.
#   0  live      - a real process runs behind the pane, and (for a cwd match)
#                  some foreground process really works in the firstmate home
#   1  not live  - positively a husk: no process behind the pane
#   2  unknown   - could not be classified; the caller must fail closed
entry_is_live() {
  local pane=$1 matched_by=$2 cwds line
  # No pane id means nothing to verify against. That is not evidence of a ghost
  # and not evidence of a live firstmate, so it is unknown, never "absent".
  [ -n "$pane" ] || return 2
  case "$(fm_backend_herdr_pane_process_state "$HERDR_SESSION_NAME" "$pane")" in
    dead) return 1 ;;
    live) : ;;
    *) return 2 ;;
  esac
  # A name match is strong identity on its own: only `agent start <name>`
  # produces it, herdr's server-global name registry keeps a second agent from
  # ever taking the same name, and replayed ghost records carry no name (both
  # observed boots re-registered the name freely after restart). A live
  # process behind a name-matched pane is the firstmate.
  [ "$matched_by" = name ] && return 0
  # A cwd match came from replayable METADATA, so the process itself must
  # corroborate it: some foreground process must really work in the firstmate
  # home per the kernel. A live process that cannot be tied to the home is
  # UNKNOWN, not a husk - it may be the firstmate mid-tool-call (a child
  # process working elsewhere could momentarily front the group) - and unknown
  # refuses the start rather than licensing a duplicate.
  cwds=$(fm_backend_herdr_pane_process_cwds "$HERDR_SESSION_NAME" "$pane") || return 2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(physical_path "$line")" = "$FM_ROOT" ] && return 0
  done <<EOF
$cwds
EOF
  return 2
}

# Answer "is a firstmate already running?" over the socket API.
#   0  yes, one is present and confirmed live (prints the matching identity)
#   1  no, positively absent
#   2  unknown - the list could not be read or understood, or a matching entry
#      could not be confirmed live-or-not
firstmate_present() {
  local raw name cwd fgcwd pane line desc matched_by count seen=0 rc unknown=0
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

  # NUL-delimited, four fields per agent, read through a process substitution.
  # Not @tsv and not one-field-per-line: an absent name is the COMMON case, and
  # bash's `read` silently swallows a leading empty field when the delimiter is
  # whitespace (a tab is IFS whitespace), which would misread every unnamed
  # agent's cwd as its name and let a duplicate firstmate through. NUL is the
  # one delimiter that cannot appear in a name or a path.
  while
    IFS= read -r -d '' name &&
      IFS= read -r -d '' cwd &&
      IFS= read -r -d '' fgcwd &&
      IFS= read -r -d '' pane
  do
    seen=$((seen + 1))
    # Match first, then verify. A matching entry that turns out to be a ghost
    # simply does not count, and the scan continues: another entry may still be
    # the real firstmate.
    desc=""
    matched_by=""
    if [ -n "$name" ] && [ "$name" = "$AGENT_NAME" ]; then
      desc="agent named $name"
      matched_by=name
    else
      for line in "$cwd" "$fgcwd"; do
        [ -n "$line" ] || continue
        if [ "$(physical_path "$line")" = "$FM_ROOT" ]; then
          desc="agent running in $line"
          matched_by=cwd
          break
        fi
      done
    fi
    [ -n "$desc" ] || continue

    # `if`, not a bare call plus $?: a non-zero return here is an ordinary,
    # expected answer, and a bare call would be an errexit trip the moment a
    # caller runs this function without disabling it.
    if entry_is_live "$pane" "$matched_by"; then rc=0; else rc=$?; fi
    case "$rc" in
      0)
        printf '%s\n' "$desc"
        return 0
        ;;
      # Positively a husk: a stale record of a firstmate that is not running.
      # Not a reason to refuse - it is the exact state autostart exists to fix.
      1) : ;;
      # Matched but unclassifiable. Remembered rather than returned at once, so
      # a later entry that IS confirmed live still wins and produces the clean
      # no-op; only a scan that finds no live match at all fails closed.
      *) unknown=1 ;;
    esac
  done < <(printf '%s' "$raw" | jq -j '(.result.agents // [])[] |
      (.name // ""), "\u0000", (.cwd // ""), "\u0000", (.foreground_cwd // ""),
      "\u0000", (.pane_id // ""), "\u0000"')

  # Reaching here means no agent both matched and was confirmed live. Only trust
  # that as "positively absent" if every agent the response claimed was actually
  # examined - a short read means the extraction failed partway, and an
  # unexamined agent could be the live firstmate - and if no entry that DID match
  # was left unclassified.
  [ "$seen" -eq "$count" ] || return 2
  [ "$unknown" -eq 0 ] || return 2
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
    # The no-op path deliberately runs BEFORE the network gate: an already-live
    # firstmate needs nothing from this script, and a downed network must not
    # turn "nothing to do" into a failed unit.
    printf 'fm-autostart.sh: firstmate is already up (%s); nothing to do.\n' "$present_desc"
    exit 0
    ;;
  2)
    die "could not determine whether a firstmate is already running; refusing to start a possible duplicate firstmate" 3
    ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  # One probe round, reported but never waited on and never fatal: a dry run
  # reports the decision, it does not hold the shell for --net-timeout.
  if [ "$SKIP_NET_CHECK" -eq 1 ]; then
    printf 'fm-autostart.sh: network gate skipped (--skip-net-check).\n'
  elif probe_endpoint; then
    printf 'fm-autostart.sh: network gate would pass (%s reachable now).\n' "$NET_PROBE_HOST"
  else
    printf 'fm-autostart.sh: network gate would currently FAIL (%s not reachable; %s); a real run would poll up to %ss, then exit 5.\n' \
      "$NET_PROBE_HOST" "$(net_diagnosis)" "$NET_TIMEOUT"
  fi
  printf 'fm-autostart.sh: no firstmate present; would run:\n'
  printf '  herdr agent start %s --cwd %s --no-focus --' "$AGENT_NAME" "$FM_ROOT"
  printf ' %s' "${AGENT_ARGV[@]}"
  printf '\n'
  exit 0
fi

if [ "$SKIP_NET_CHECK" -eq 0 ]; then
  wait_for_network || exit 5
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
