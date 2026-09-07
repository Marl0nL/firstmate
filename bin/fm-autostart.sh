#!/usr/bin/env bash
# fm-autostart.sh - bring the firstmate primary agent up unattended at boot.
#
# WHY THIS EXISTS
# `herdr server` is headless: the systemd user unit that runs it at boot brings
# up a server with zero panes, because pane resurrection is CLIENT-side work.
# herdr says so itself in its own boot log ("did you mean to open the Herdr TUI?
# run 'herdr'; you do not need 'herdr server'"). So boot produced a server and
# no firstmate, and the fleet stayed dark until a human attached. This script is
# the missing client-side step, driven over the socket API instead of a TUI: it
# creates the firstmate workspace and types the launch command into its pane.
#
# HOW THE AGENT IS LAUNCHED, AND WHY NOT `herdr agent start`.
# The launch is two calls: `herdr workspace create --cwd <home> --label <name>
# --no-focus`, which seeds exactly one tab holding one pane at a shell prompt,
# then `herdr pane run <pane> <command>`, which types the launch command into
# that pane and submits it. This is the same shape bin/backends/herdr.sh uses
# for every crewmate firstmate spawns (docs/herdr-backend.md: firstmate launches
# every crew by TYPING the launch command into a pane), and both primitives are
# present unchanged across the whole supported Herdr range - verified against
# the real 0.7.4 binary CI pins (bin/fm-install-herdr.sh) and the installed
# 0.8.2 - so there is no version-dependent launch shape to gate on.
#
# Nothing waits for that seeded pane's shell before typing into it, because the
# pane really is at an interactive prompt when `workspace create` returns:
# issuing `pane run` as the very next call, with no readiness wait at all,
# executed the command in 40 of 40 trials - 10 idle and 10 under full CPU load
# on each of 0.7.4 and 0.8.2, measured 2026-09-07 in isolated lab sessions
# (docs/verification/runtime-backends.md, "Boot autostart launch shape"). A
# readiness loop here would only add a second --confirm budget and a failure
# path of its own; the post-launch confirmation below already covers a launch
# that never takes.
#
# `herdr agent start` was the original mechanism and is deliberately gone.
# Herdr 0.8 split "make a pane" from "start an agent in it": 0.7.4 spells it
# `agent start <name> [--cwd PATH] [--focus|--no-focus] -- <argv...>` while
# 0.8.2 spells it `agent start <NAME> --kind <KIND> --pane <ID> [--timeout MS]`
# and accepts neither --cwd nor --no-focus, so the old call fails outright on
# any 0.8 host and no firstmate comes up. Rewriting it into the 0.8 shape does
# not fix it either: `agent start --kind claude --pane <P>` types the command
# and the agent really does come up, but its readiness detection never
# completes - the call burns the whole --timeout and then exits non-zero with
# {"error":{"code":"timeout"}}, registering nothing, so `agent list` stays
# empty and the call can never report success (measured 2026-09-07 on Herdr
# 0.8.2 / protocol 20 with the current v8 Claude integration installed and the
# workspace already trusted; docs/verification/runtime-backends.md, "Boot
# autostart launch shape"). A boot step cannot be built on a primitive whose
# success is indistinguishable from its failure. `--kind` also takes only
# Herdr's own fixed list of agent kinds, which would silently break this
# script's `-- <argv>` escape hatch for any other command.
#
# THE `--continue` FALLBACK.
# `claude --continue` exits 1 with no usable prior conversation for the
# directory (verified 2026-09-07), so a first boot on a fresh machine would
# leave a dead pane rather than a fresh firstmate. The typed command therefore
# carries its own fallback - `<argv> || <argv without --continue>` - whenever
# the argv asks for --continue. That needs no knowledge of where the harness
# keeps its conversations, so nothing here rots when that storage layout
# changes, and the fresh session it starts is what the next boot resumes.
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
# A listed ENTRY IS NOT ENOUGH. The entry must first MATCH this home - either
# an agent named --name (default `firstmate`), or ANY entry whose working
# directory is the firstmate home - and then that match must be CONFIRMED LIVE
# against the pane it claims to occupy.
#
# The inventory is read from BOTH `herdr agent list` AND `herdr pane list`,
# because on Herdr 0.8.2 the agent registry alone cannot see a live firstmate:
# a Claude crew registers no agent record there at all, so `agent list` answers
# with an empty array for a genuinely live, integration-claimed Claude pane
# (docs/herdr-backend.md, "Restart and liveness behavior"). Reading only the
# registry would report "no firstmate present" next to the running one and
# start a second supervisor - the one outcome this script exists to prevent.
# `pane list` carries each pane's cwd and foreground_cwd on every supported
# release, so it is the inventory that still sees the firstmate. Pane entries
# never carry an AGENT name (a pane label is a different thing), so they can
# only ever match by directory; that is the load-bearing half of matching
# anyway, for the reason below.
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
#   fm_backend_herdr_pane_process_state      - is there a real PROCESS behind
#                                              the pane (live), or none (dead)?
#   fm_backend_herdr_pane_process_cwds       - where do those processes actually
#                                              run, per the kernel, not per
#                                              herdr?
#   fm_backend_herdr_pane_foreground_harness - is one of those processes one of
#                                              OUR agents, per the fleet-wide
#                                              fm_harness_process_matches?
#   ..._pane_foreground_beyond_shell         - or, for a non-harness argv, is
#                                              any of them something other than
#                                              the pane's own shell?
# A name-matched entry needs a live process. A cwd-matched entry needs two more
# things, because the cwd that MATCHED came from replayable metadata and only
# the processes themselves are evidence: the pane must really hold what this
# run launches, and some foreground process must really work in the firstmate
# home.
#
# The cwd read runs FIRST, before the identity probe, purely to prove the
# process-info body is readable at all. Both identity probes answer non-zero
# for "not there" AND for "could not read", and only the cwd read distinguishes
# them, so asking it first is what keeps an unreadable body out of the "husk"
# verdict - the one verdict that licenses starting a firstmate.
#
# The harness half is what keeps a RESTORED BARE SHELL from reading as a live
# supervisor. Herdr restores its persisted panes as plain shells after a server
# restart, and such a pane still reports the firstmate home as its cwd and a
# real live process (its own /bin/bash) - so process existence plus a cwd match
# would call the emptiest possible pane a running firstmate and no-op forever.
# docs/herdr-backend.md ("Restart and liveness behavior") owns that rule for the
# fleet: a pane with no verified-harness foreground process is a husk.
#
# THE HARNESS TEST IS CONDITIONAL ON WHAT THIS SCRIPT WAS ASKED TO LAUNCH.
# `-- <argv>` is documented, long-standing behaviour: it replaces the launched
# command outright, and nothing requires that command to be one of our
# harnesses. Requiring a verified harness unconditionally would make such a
# command IMPOSSIBLE to confirm - and worse than a plain failure, because the
# command really does launch and the failure cleanup below would then close the
# workspace over the process this run just started. So the identity test is
# chosen from the resolved argv, using the fleet-wide harness vocabulary in
# bin/fm-session-lock-lib.sh rather than a second list here:
#   harness argv (the default `claude ...`, or a `-- <argv>` naming one)
#     the pane must hold a verified-harness foreground process. Unchanged, and
#     deliberately so: this is the restored-bare-shell guard.
#   any other argv
#     the pane must hold a foreground process that is not merely the pane's own
#     shell (fm_backend_herdr_pane_foreground_beyond_shell). A bare shell is
#     still a husk on this path too, so the hole stays closed; the test is just
#     one a non-harness command can actually pass.
# Narrowing the option to harness commands, and dropping the identity test
# outright, were both considered and refused: the first breaks a documented
# escape hatch, the second reopens the bare-shell no-op.
#
# Only `pane process-info` sees reality: a ghost passes `pane get` and `agent
# get` intact - they replay from the same persisted layout the list came from.
# Anything else, including an entry that names no pane at all, is UNKNOWN, and
# unknown never licenses a start (see THE ONE RULE above).
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
# `herdr status --json` until the session's own server reports running and has
# not declared itself incompatible, bounded by --timeout, and fails with the
# last response it saw rather than guessing a sleep long enough to cover a slow
# boot.
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
#   --dry-run           report the decision and print the plan; start nothing
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
# then fail at boot with no human present. This script header's THE `--continue`
# FALLBACK note owns what happens when there is nothing to resume.
#
# Exit status:
#   0  a firstmate is up: either already present (no-op) or started and confirmed
#   1  usage or environment error (bad flag, no herdr, no jq, no firstmate home)
#   2  the herdr server did not become ready within --timeout
#   3  the fleet inventory could not be read or understood, or an entry matching
#      this home could not be classified live-or-not - state unknown, so nothing
#      was started (fail closed)
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
# The one session this whole run addresses: ambient HERDR_SESSION if the
# operator set one, herdr's own `default` otherwise.
#
# EVERY herdr call this script makes goes through fm_backend_herdr_cli with
# this name, never bare, and that is a correctness requirement rather than a
# style one. bin/backends/herdr.sh records it verified: the HERDR_SESSION env
# var alone is NOT reliably honored by CLI subcommands once any other herdr
# server is bound on the machine - a query silently falls back to whatever
# server IS running - while `--session <name>` always routes correctly. A bare
# call and an adapter call can therefore reach DIFFERENT servers, and this
# script's destructive step is gated on exactly those adapter probes: the pane
# enumeration and the close would run against one server while the
# process-info that proves the workspace agent-free answered from another,
# where those panes do not exist and every one of them reads `dead`. The
# live-agent refusal would never fire and the close would land on a firstmate
# that genuinely came up. The readiness poll is routed for the same reason and
# is no exception: a scoped status call queries the named session and starts
# nothing (see wait_for_server), so nothing is gained by leaving it ambient and
# a gate that certified a different server would be no gate at all.
#
# The --dry-run plan prints these calls the way the adapter really issues them,
# trailing --session included, because a plan an operator cannot paste is not
# the plan this script runs.
HERDR_SESSION_NAME=$(fm_backend_herdr_session)

# Which identity test a launched pane has to pass, decided once from the argv
# this run will actually type (see THE HARNESS TEST IS CONDITIONAL in the
# header). fm_harness_process_matches is the fleet's own harness vocabulary,
# sourced above with the adapter, and is asked here exactly as it is asked of a
# running process: command name plus full argument string.
if fm_harness_process_matches "${AGENT_ARGV[0]}" "${AGENT_ARGV[*]}"; then
  ARGV_IS_HARNESS=1
else
  ARGV_IS_HARNESS=0
fi

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

# Poll `herdr status --json` until the session's own server is running and has
# not declared itself incompatible. Prints nothing on success; on timeout,
# reports the last response it saw so the journal distinguishes a server that
# never came up from one that came up incompatible from one that answered
# something unreadable, rather than only saying a wait elapsed.
#
# `status --json` rather than `status server` because this is the boot's first
# gate and it may not rest on an unmeasured argument shape. Scoped through the
# adapter, `status --json` is the exact call bin/backends/herdr.sh already makes
# in production to decide whether a session's server is up
# (fm_backend_herdr_server_ensure, which also records the verified fact that
# such a call QUERIES and never auto-starts a server); starting one is a
# separate call this script never makes. Its body carries both fields this poll
# reads, .server.running and .server.compatible, so nothing here has to derive a
# verdict the response does not state.
#
# The two fields are weighed differently, and deliberately so. Running must be
# positively true: a body that cannot be parsed, or that does not say the server
# is up, is not a ready server and keeps the poll waiting. Compatibility only
# ever BLOCKS, and only when the server positively says so - null, absent, or
# unreadable does not hold a running server back. That is the polarity the
# pre-0.8 text surface had (it passed on a running server unless the output said
# `compatible: no`), and requiring positive proof instead would turn a signal a
# release merely omits into a permanent boot failure, 120s at a time, with the
# journal blaming a readiness timeout.
#
# Routed for the same reason every other call is: left bare, this poll could
# certify a DIFFERENT server than the one every later call addresses, so the
# gate would pass while the session this run targets was still down.
wait_for_server() {
  local deadline last="(no response from 'herdr status --json')" out
  deadline=$(( $(date +%s) + TIMEOUT ))
  while :; do
    if out=$(fm_backend_herdr_cli "$HERDR_SESSION_NAME" status --json 2>&1); then
      last=$out
      if printf '%s' "$out" |
        jq -e '.server.running == true and .server.compatible != false' >/dev/null 2>&1; then
        return 0
      fi
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

# True when <pane> holds the kind of process THIS run launches, per the
# conditional identity test described in the header. Both arms are owned by
# bin/backends/herdr.sh; this only picks between them. Non-zero means either
# "the pane holds nothing but a shell" or "process-info was unreadable", so
# every caller must first have proven the body readable (entry_is_live) or
# treat the answer as unproven (discard_created_workspace).
pane_holds_launched_agent() {  # <pane_id>
  local pane=$1
  if [ "$ARGV_IS_HARNESS" -eq 1 ]; then
    fm_backend_herdr_pane_foreground_harness "$HERDR_SESSION_NAME" "$pane"
  else
    fm_backend_herdr_pane_foreground_beyond_shell "$HERDR_SESSION_NAME" "$pane"
  fi
}

# Confirm that a matching inventory entry is a LIVE firstmate rather than a
# ghost record replayed from herdr's persisted session layout, or the bare
# shell a restore leaves behind (see the header). Judged ONLY on
# reality-touching signals - `pane process-info`, the identity of the processes
# it reports, and their kernel-reported working directories - never on
# `agent get` metadata, whose agent_status reports "unknown" for a genuinely
# live agent on herdr 0.7.4 and made this guard cry failure over a working boot.
#   0  live      - a real process runs behind the pane, and (for a cwd match)
#                  that pane holds one of our agents, working in the firstmate
#                  home
#   1  not live  - positively a husk: no process behind the pane, or (for a cwd
#                  match) no agent in it, only a shell
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
  # process behind a name-matched pane is the firstmate. This script no longer
  # creates such a name itself, but a firstmate the captain started that way
  # still carries one, and it is still the strongest identity available.
  [ "$matched_by" = name ] && return 0
  # A cwd match came from replayable METADATA, so the processes themselves must
  # corroborate it twice over.
  #
  # Read the working directories FIRST, before asking who the processes are.
  # This call is the only one of the three that distinguishes "the body says
  # no" from "there is no readable body": both identity probes answer non-zero
  # for either. Asking identity first would score an unreadable process-info as
  # a HUSK - the single verdict that licenses starting a firstmate - and start a
  # second supervisor beside a live one. Its non-zero is UNKNOWN, so the rest of
  # this function runs only on a body that was proven readable.
  cwds=$(fm_backend_herdr_pane_process_cwds "$HERDR_SESSION_NAME" "$pane") || return 2
  # First corroboration: the pane must really hold what this run launches.
  # Without it, the bare shell herdr restores into a persisted pane after a
  # server restart - a real live process, reporting the firstmate home as its
  # cwd - would read as a running firstmate and no-op the boot forever.
  # bin/backends/herdr.sh owns both husk rules for the whole fleet, so a pane
  # that fails the test is positively a husk here too, not merely
  # unclassifiable.
  pane_holds_launched_agent "$pane" || return 1
  # Second: some foreground process must really work in the firstmate home per
  # the kernel. A live agent that cannot be tied to the home is UNKNOWN, not
  # a husk - it may be the firstmate mid-tool-call (a child process working
  # elsewhere could momentarily front the group) - and unknown refuses the
  # start rather than licensing a duplicate.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(physical_path "$line")" = "$FM_ROOT" ] && return 0
  done <<EOF
$cwds
EOF
  return 2
}

# Answer "is a firstmate already running?" over the socket API.
#
# The inventory is the union of `agent list` and `pane list`, because neither
# alone sees every firstmate: the agent registry carries the NAME an
# `agent start` once produced, while on herdr 0.8.2 it carries no record at all
# for a live Claude and only the pane inventory still sees it (see WHAT COUNTS
# AS "a firstmate is already running" in the header). A pane appearing in both
# is simply classified twice, which is harmless; missing it in both is the
# failure that starts a second supervisor.
#
#   0  yes, one is present and confirmed live (prints the matching identity)
#   1  no, positively absent
#   2  unknown - an inventory could not be read or understood, or a matching
#      entry could not be confirmed live-or-not
firstmate_present() {
  local agents panes name cwd fgcwd pane line desc matched_by count seen=0 rc unknown=0
  local agent_count pane_count
  agents=$(fm_backend_herdr_cli "$HERDR_SESSION_NAME" agent list 2>/dev/null) || return 2
  panes=$(fm_backend_herdr_cli "$HERDR_SESSION_NAME" pane list 2>/dev/null) || return 2
  # A response that does not carry its array is an error or an unrecognised
  # shape, not an empty fleet. Never read either one as "absent".
  printf '%s' "$agents" | jq -e 'has("result") and (.result | has("agents"))' >/dev/null 2>&1 || return 2
  printf '%s' "$panes" | jq -e 'has("result") and (.result | has("panes"))' >/dev/null 2>&1 || return 2
  # How many entries the responses claim, so a truncated or failed extraction
  # below cannot masquerade as an empty fleet and green-light a duplicate.
  agent_count=$(printf '%s' "$agents" | jq '(.result.agents // []) | length' 2>/dev/null) || return 2
  pane_count=$(printf '%s' "$panes" | jq '(.result.panes // []) | length' 2>/dev/null) || return 2
  case "$agent_count" in
    '' | *[!0-9]*) return 2 ;;
  esac
  case "$pane_count" in
    '' | *[!0-9]*) return 2 ;;
  esac
  count=$((agent_count + pane_count))

  # NUL-delimited, four fields per entry, read through a process substitution.
  # Not @tsv and not one-field-per-line: an absent name is the COMMON case -
  # universal for pane entries, which have no agent name at all - and bash's
  # `read` silently swallows a leading empty field when the delimiter is
  # whitespace (a tab is IFS whitespace), which would misread every unnamed
  # entry's cwd as its name and let a duplicate firstmate through. NUL is the
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
  done < <(
    printf '%s' "$agents" | jq -j '(.result.agents // [])[] |
      (.name // ""), "\u0000", (.cwd // ""), "\u0000", (.foreground_cwd // ""),
      "\u0000", (.pane_id // ""), "\u0000"'
    # A pane carries no agent name - `pane rename` labels are a different
    # namespace entirely - so the name field is emitted empty and pane entries
    # can only ever match this home by directory.
    printf '%s' "$panes" | jq -j '(.result.panes // [])[] |
      "", "\u0000", (.cwd // ""), "\u0000", (.foreground_cwd // ""),
      "\u0000", (.pane_id // ""), "\u0000"'
  )

  # Reaching here means no entry both matched and was confirmed live. Only trust
  # that as "positively absent" if every entry the responses claimed was actually
  # examined - a short read means the extraction failed partway, and an
  # unexamined entry could be the live firstmate - and if no entry that DID match
  # was left unclassified.
  [ "$seen" -eq "$count" ] || return 2
  [ "$unknown" -eq 0 ] || return 2
  return 1
}

# The exact command line typed into the firstmate pane: AGENT_ARGV, shell-quoted
# so a path with a space survives the trip through the terminal. When the argv
# asks for `--continue`, the line carries its own `|| <argv without --continue>`
# fallback, so a host with no conversation to resume still comes up with a
# firstmate rather than a dead pane (see THE `--continue` FALLBACK in the
# header). A later non-zero exit re-runs the fallback once, which is the right
# outcome for an unattended supervisor; a clean exit re-runs nothing.
launch_command() {
  local a primary="" fallback="" has_continue=0
  for a in "${AGENT_ARGV[@]}"; do
    primary="${primary}${primary:+ }$(printf '%q' "$a")"
    if [ "$a" = "--continue" ]; then
      has_continue=1
      continue
    fi
    fallback="${fallback}${fallback:+ }$(printf '%q' "$a")"
  done
  if [ "$has_continue" -eq 1 ] && [ -n "$fallback" ]; then
    printf '%s || %s' "$primary" "$fallback"
  else
    printf '%s' "$primary"
  fi
}

# The only value in the printed plan that a dry run cannot know yet: the pane
# id `workspace create` will report. Deliberately free of shell metacharacters
# so it survives quoting and stays obvious as a placeholder.
PLAN_PANE_PLACEHOLDER=PANE_ID

# One line of the --dry-run plan, built from the SAME argv the real path hands
# to the adapter, shell-quoted so pasting the line reproduces that argv element
# for element - including the trailing `--session` fm_backend_herdr_cli
# appends. The flag is not decoration in a printed plan: per the session note
# above, a bare call and a scoped call can reach different servers, so a plan
# without it is precisely the version an operator must not run by hand.
plan_line() {  # <herdr-arg>...
  local a out=""
  for a in "$@"; do
    case "$a" in
      # Nothing a shell would touch: print it as the operator would type it.
      '') a="''" ;;
      *[!A-Za-z0-9_./:=-]*)
        case "$a" in
          *\'*) a=$(printf '%q' "$a") ;;
          *) a="'$a'" ;;
        esac
        ;;
    esac
    out="${out}${out:+ }$a"
  done
  printf '  herdr %s --session %s\n' "$out" "$(printf '%q' "$HERDR_SESSION_NAME")"
}

# Create the firstmate workspace and print "<workspace_id> <pane_id>".
# `workspace create` seeds the workspace with exactly one tab holding one pane
# at a shell prompt, and its response carries that pane as .result.root_pane
# (verified against the real herdr 0.7.4 and 0.8.2 binaries by
# tests/fm-autostart-herdr-live-e2e.test.sh, which fails by name the moment a
# release stops reporting it). A release that reports the workspace but not its
# pane is REFUSED, loudly, rather than routed around: no supported release does
# it, typing a firstmate launch into a pane picked by some other rule is worse
# than not starting, and a silent fallback would swallow exactly the drift
# signal the live guard exists to raise.
create_firstmate_workspace() {
  local out ws pane
  out=$(fm_backend_herdr_cli "$HERDR_SESSION_NAME" workspace create --cwd "$FM_ROOT" --label "$AGENT_NAME" --no-focus 2>&1) || {
    printf 'fm-autostart.sh: creating the firstmate workspace failed; herdr said:\n%s\n' "$out" >&2
    return 1
  }
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null) || ws=""
  if [ -z "$ws" ]; then
    printf 'fm-autostart.sh: creating the firstmate workspace returned no workspace id; herdr said:\n%s\n' "$out" >&2
    return 1
  fi
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null) || pane=""
  if [ -z "$pane" ]; then
    printf 'fm-autostart.sh: workspace %s was created but its response carried no .result.root_pane.pane_id, so there is no pane to launch into; herdr said:\n%s\n' \
      "$ws" "$out" >&2
    discard_created_workspace "$ws"
    return 1
  fi
  printf '%s %s' "$ws" "$pane"
}

# Remove a workspace THIS run just created, after its launch failed. Without
# this, every failed boot would leave a half-built container behind for the
# next one to inherit, and they would accumulate.
#
# A workspace holding a live agent is NEVER closed. By this point the firstmate
# may genuinely be coming up, and closing it would be the one outcome worse
# than reporting the failure. Neither is one this function cannot PROVE is
# agent-free, and there are two ways to fail that proof: an unreadable pane
# list, and a pane whose process-info cannot be read.
#
# That second one is why each pane is asked twice before its identity answer is
# believed. The identity probe returns non-zero for "nothing there" AND for
# "could not read", and `pane process-info` has more than one unreadable shape:
# it can error outright, which process_state reports as `unknown`, but it can
# also answer a body that parses and says nothing about processes, which
# process_state reports as `live` because a body IS there. Reading a non-zero
# identity answer as "agent-free" on either would close over a pane nothing was
# ever proven about. So a live pane must first produce readable process
# information - fm_backend_herdr_pane_process_cwds, the same readability proof
# entry_is_live runs before it trusts the same probe - and only then does a
# non-zero identity answer mean the pane is empty. Every refusal, and a close
# that fails, says exactly what was left behind and why, so the journal never
# has to guess which one fired.
#
# The close itself is gated on the release, for the third refusal. Below Herdr
# 0.8.0 an EXPLICIT close that empties a workspace - `workspace close` included
# - routes through close_selected_workspace, which hands focus to the CLOSING
# workspace's right neighbor and ignores whatever the captain was watching
# (bin/backends/herdr.sh records both upstream fixes and the releases carrying
# them). That is exactly what FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION floors,
# so this asks that owner - fm_backend_herdr_presentation_release_supported -
# rather than comparing versions again here; the floor is not borrowed from an
# unrelated setting, it IS "an explicit close preserves focus". An
# indeterminate verdict refuses too, matching this script's rule everywhere
# else that an unprovable read never licenses the risky action.
# bin/fm-teardown.sh already refuses `workspace close` for this same reason.
# A stray workspace is recoverable and is already the outcome of this
# function's other refusals; hijacking the captain's focus mid-work is not.
#
# Only a workspace this same run created is ever passed here - `workspace
# create` always creates, so the id can never name something that was already
# the captain's.
discard_created_workspace() {  # <workspace_id>
  local ws=$1 panes pane floor=0
  panes=$(fm_backend_herdr_cli "$HERDR_SESSION_NAME" pane list --workspace "$ws" 2>/dev/null) || panes=""
  if ! printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
    printf 'fm-autostart.sh: could not inspect workspace %s to remove it; close it by hand before the next boot.\n' \
      "$ws" >&2
    return 0
  fi
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    case "$(fm_backend_herdr_pane_process_state "$HERDR_SESSION_NAME" "$pane")" in
      # No process behind it at all: nothing to close over.
      dead) continue ;;
      live) : ;;
      *)
        printf 'fm-autostart.sh: leaving workspace %s in place: pane %s could not be inspected, so it cannot be proven agent-free. Check it before the next boot.\n' \
          "$ws" "$pane" >&2
        return 0
        ;;
    esac
    if ! fm_backend_herdr_pane_process_cwds "$HERDR_SESSION_NAME" "$pane" >/dev/null; then
      printf 'fm-autostart.sh: leaving workspace %s in place: pane %s reported no readable process information, so it cannot be proven agent-free. Check it before the next boot.\n' \
        "$ws" "$pane" >&2
      return 0
    fi
    if pane_holds_launched_agent "$pane"; then
      printf 'fm-autostart.sh: leaving workspace %s in place: an agent is running in pane %s. Check it before the next boot.\n' \
        "$ws" "$pane" >&2
      return 0
    fi
  done <<EOF
$(printf '%s' "$panes" | jq -r '.result.panes[]?.pane_id // empty' 2>/dev/null)
EOF
  fm_backend_herdr_presentation_release_supported "$HERDR_SESSION_NAME" || floor=$?
  case "$floor" in
    0) : ;;
    1)
      printf 'fm-autostart.sh: leaving workspace %s in place: herdr %s is below the %s floor where an explicit workspace close preserves focus, so closing it would move the captain off the space being watched. Close it by hand before the next boot.\n' \
        "$ws" "$FM_BACKEND_HERDR_PRESENTATION_RELEASE" \
        "$FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION" >&2
      return 0
      ;;
    *)
      printf 'fm-autostart.sh: leaving workspace %s in place: the herdr release could not be read, so it cannot be verified against the %s floor where an explicit workspace close preserves focus. Close it by hand before the next boot.\n' \
        "$ws" "$FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION" >&2
      return 0
      ;;
  esac
  fm_backend_herdr_cli "$HERDR_SESSION_NAME" workspace close "$ws" >/dev/null 2>&1 ||
    printf 'fm-autostart.sh: could not remove the half-started workspace %s; close it by hand before the next boot.\n' \
      "$ws" >&2
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
  plan_line workspace create --cwd "$FM_ROOT" --label "$AGENT_NAME" --no-focus
  plan_line pane run "$PLAN_PANE_PLACEHOLDER" "$(launch_command)"
  printf 'fm-autostart.sh: %s above is the pane workspace create seeds (.result.root_pane.pane_id), which a real run reads back from the response.\n' \
    "$PLAN_PANE_PLACEHOLDER"
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
created=$(create_firstmate_workspace) ||
  die "could not create the firstmate workspace; no firstmate is running" 4
started_workspace=${created%% *}
started_pane=${created#* }

if ! fm_backend_herdr_cli "$HERDR_SESSION_NAME" pane run "$started_pane" "$(launch_command)" >/dev/null; then
  discard_created_workspace "$started_workspace"
  die "the launch command could not be sent to pane $started_pane; no firstmate is running" 4
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

# The launch was typed but nothing recognisable as a firstmate ever appeared.
# Clean up what this run created, which leaves a genuinely slow agent alone
# (discard_created_workspace refuses a workspace that holds one), and report the
# failure rather than leaving a stray pane for the next boot to inherit.
discard_created_workspace "$started_workspace"
die "started the agent but no live firstmate appeared within ${CONFIRM_TIMEOUT}s" 4
