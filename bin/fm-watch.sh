#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A DECLARED HOLD is the separate idle
# absorb case: a crew that is idle on purpose because what it waits on is already
# tracked elsewhere. There are three, and all three share ONE bounded cadence
# (PAUSE_RESURFACE_SECS) rather than the ordinary stale path:
#   - a declared external-wait pause (paused:), tracked by the crew's own reason;
#   - a durable captain-held transfer (captain-held:), tracked by its captain-held
#     backlog item;
#   - a crew parked awaiting merge (reconciled done + a REGISTERED merge monitor),
#     tracked by that merge monitor's own check wake.
# A hold is absorbed but never swallowed: every one of them re-surfaces once per
# bounded window for a recheck, so a hold nobody cleared cannot rot invisibly, and
# a held crew's initial no-verb status signal still surfaces in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          hold (pause, captain-held, or parked-awaiting-merge) is
#                          absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active.
#   check: <script>: <out> per-task check output, always actionable. Only an
#                          AUTHENTICATED check can produce this (bin/fm-check-lib.sh)
#   check: rejected unauthenticated state checks: <paths>
#                          check files that are unregistered, tampered, or not
#                          private were REFUSED WITHOUT EXECUTION; register or
#                          remove them. Always actionable
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crew entering `blocked` wakes its supervisor
# sub-second; the poll loop stays live every cycle as the permanent fail-closed
# backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# Check-script authentication. This watcher EXECUTES state/*.check.sh, so every
# check is verified against its trust record and run from a private snapshot;
# anything unregistered or tampered is refused without execution and surfaced.
# bin/fm-check-lib.sh owns the record format and the verification rules.
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
# Seconds before an UNCHANGED set of refused checks is surfaced again. A refusal
# is a security event, so a new or changed refusal wakes immediately; this only
# bounds the repeat, so a refusal nobody has fixed yet can neither rot silently
# nor starve the checks that are still authenticated.
CHECK_REJECT_RESURFACE=${FM_CHECK_REJECT_RESURFACE:-3600}
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# The bounded cadence shared by all three declared holds (see the file header):
# a declared external-wait pause (paused:), a durable captain-held transfer
# (captain-held:), and a crew parked awaiting merge. Each is idling on something
# already tracked elsewhere, so its stale pane is absorbed rather than
# wedge-escalated; it re-surfaces once for a recheck every PAUSE_RESURFACE_SECS -
# far longer than the wedge threshold, but finite so a forgotten hold cannot rot
# invisibly. fm-classify-lib.sh owns the default so both supervisors agree.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Consecutive terminal-capture failures required before an unreadable endpoint
# wakes firstmate. Capture is the one signal that touches reality (it must
# reach a real terminal), so a failure is the CORRECT detection of a gone
# endpoint - but it is also what a transient socket blip looks like, so the
# first failures are tolerated silently. 3 keeps a blip quiet while still
# surfacing a genuinely gone endpoint within a few polls, matching the spirit
# of the 2-consecutive-hashes stale threshold below.
FM_CAPTURE_FAIL_WAKE_COUNT=${FM_CAPTURE_FAIL_WAKE_COUNT:-3}

# capture_failure: count one consecutive capture failure for <window> and, at
# the threshold, surface an endpoint-gone wake.
#
# This exists because the alternative - the bare `|| continue` this replaced -
# threw away the only correct signal firstmate had. A crew whose pane dies in
# a herdr server restart (reboot, update, service restart) leaves a REPLAYED
# metadata record behind, so every presence check still reports it healthy;
# only capture notices. With `|| continue` that crew was skipped every poll
# forever: it never got a pane hash, so it never accumulated a stale count, so
# it never reached stale triage, so the watcher became structurally incapable
# of ever mentioning it again. The task stalled silently and permanently.
#
# Surfaced ONCE per gone episode (.capfail-surfaced-<key>), mirroring the
# once-per-distinct-stale-hash convention below rather than re-waking every
# poll; the heartbeat's whole-fleet review is the backstop if firstmate does
# not act. Both markers are cleared as soon as capture succeeds again, so a
# blip that resolves leaves no trace and a later real disappearance surfaces
# fresh. The wake reason deliberately quotes fm-crew-state.sh's existing
# verdict for this case ("backend target gone") rather than inventing a second
# vocabulary for it - that script stays the owner of the verdict.
capture_failure() {  # <window> <key>
  local win=$1 key=$2 cff n reason
  cff="$STATE/.capfail-$key"
  n=$(( $(cat "$cff" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$cff"
  if [ "$n" -lt "$FM_CAPTURE_FAIL_WAKE_COUNT" ]; then
    triage_log "absorbed capture failure $n/$FM_CAPTURE_FAIL_WAKE_COUNT (transient?): $win"
    return 0
  fi
  [ -e "$STATE/.capfail-surfaced-$key" ] && return 0
  reason="stale: $win (backend target gone: $n consecutive terminal-capture failures - the endpoint cannot be read, so the crew is unsupervised; confirm with bin/fm-crew-state.sh and recover or tear down, demand-deep-inspection)"
  fm_wake_append stale "$win" "$reason" || exit 1
  : > "$STATE/.capfail-surfaced-$key"
  wake "$reason"
}

# Absorb a stale pane whose crew is in a DECLARED HOLD, and re-surface it once
# every PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. <kind>
# selects which hold is being absorbed and therefore what the recheck asks the
# supervisor to confirm; it changes the reason wording ONLY, never the cadence,
# because the three holds are one policy with one owner:
#   paused (default) - a declared external-wait pause (paused:) or a durable
#                      captain-held transfer (captain-held:); both say "idle on
#                      purpose, the wait is recorded in the status log itself".
#   parked           - a finished crew idling on its open PR behind a REGISTERED
#                      merge monitor (crew_is_parked_awaiting_merge).
# Called on any stale poll once the hold is established (first sight, after
# hold_state_class; repeat sights gated by the
# .paused-<key> flag), so it must be cheap: it NEVER re-reads the crew state. The
# re-surface age is anchored on the hold's own STATUS-FILE mtime, not a per-hash
# marker, so a churny idle pane (a ticking clock, a token counter) cannot keep
# resetting the cadence the way a hash-tied timer would. A
# .paused-resurfaced-<key> throttle marker records the last re-surface epoch so,
# once past the window, it fires once per window rather than every poll. Advances
# the stale suppressor to <hash> and flags the key held.
handle_paused_stale() {  # <window> <task> <hash> [kind]
  local win=$1 task=$2 h=$3 kind=${4:-paused} key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  # The flag file CARRIES the hold kind, so hold_state_class's cheap path can
  # re-assert the same hold without another authoritative read. An older watcher
  # left this file empty; an empty value simply misses the cheap path and takes the
  # authoritative re-read, so the format change self-heals across a restart.
  printf '%s' "$kind" > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    case "$kind" in
      parked) reason="stale: $win (parked ${age}s awaiting merge - its merge monitor is the live signal, rechecked on a long cadence not a wedge; confirm the PR is still open and still watched)" ;;
      *)      reason="stale: $win (paused ${age}s, awaiting external - declared hold, rechecked on a long cadence not a wedge; confirm the wait still holds)" ;;
    esac
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale ($kind hold, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# hold_state_class: THE single decision of which declared hold, if any, owns this
# stale pane right now. Prints exactly one token, which every stale-seam caller
# switches on:
#   working - authoritative state says the crew is actively working (an active
#             no-mistakes run-step or a busy pane). Outranks every hold: full
#             wedge sensitivity resumes with no manual re-arm.
#   parked  - a finished crew idling on its open PR behind a REGISTERED merge
#             monitor (crew_is_parked_awaiting_merge). Bounded hold cadence.
#   paused  - the status log DECLARES a hold - an external-wait pause (paused:) or
#             a durable captain-held transfer (captain-held:) - and authoritative
#             state does not contradict it. Bounded hold cadence.
#   none    - no hold and no positive working evidence: surface it.
#
# This replaced the narrower pause-only classifier so all three holds share one
# throttle and one owner. Cost discipline is unchanged: the expensive
# fm-crew-state.sh read happens at most once per STALE_ESCALATE_SECS per window,
# because an ESTABLISHED hold (its kind recorded in .paused-<key> by
# handle_paused_stale) stands on the cheap path until the .paused-rechecked-<key>
# window elapses. The parked test is ordered first among the authoritative reads
# and is itself gated on check registration, which costs no state read at all for
# the crews that have no merge monitor.
#
# Reconciles the DECLARED HOLD in the status log (paused: or captain-held:) against
# authoritative crew state.
#
# NO AGENT-LIVENESS GATE, deliberately, and this is where this port diverges from
# upstream firstmate PR #743. Upstream additionally required
# fm_backend_agent_alive to report `dead` before allowing the bounded cadence, so
# that "a still-alive agent parked at an external-decision gate surfaces
# immediately". That gate was written against upstream's METADATA-ONLY herdr
# classifier, which mapped agent_state `no-agent` straight to `dead` - and our own
# 0.7.4 recalibration measured `no-agent` for effectively every pane-typed
# crewmate, so on herdr the gate answered `dead` almost always and never actually
# fired. Under THIS tree's composed classifier (bin/backends/herdr.sh
# fm_backend_herdr_pane_agent_reality) the same crew reads `alive` whenever its
# harness process is still up and idle at its prompt, which is the NORMAL shape of
# a deliberately held crew. Porting the gate verbatim would therefore invert it:
# it would surface, on the ordinary stale path, exactly the held crew this cadence
# exists to quiet. Our measurement wins, so the gate is not ported.
#
# What still keeps a wedge from being swallowed is unchanged and does not need
# liveness: the hold must be DECLARED in the crew's own status log, and
# crew_absorb_class must not report `working` - the moment an active run-step or a
# busy pane says otherwise, this returns working and full wedge sensitivity
# resumes. The bounded cadence itself is the backstop: every hold re-surfaces for
# a recheck once per PAUSE_RESURFACE_SECS, so even a crew that declared a hold and
# then died reaches the supervisor.
hold_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class cached
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  cached=$(cat "$STATE/.paused-$key" 2>/dev/null || true)

  # Cheap path: an ALREADY-ESTABLISHED hold stands until its recheck window
  # elapses, so a held pane costs no authoritative read per poll. A `paused` hold
  # additionally re-reads the (already loaded) status line, so a crew that appends
  # a new verb loses the hold on the very next poll rather than waiting out the
  # window; a `parked` hold has no such log signal to watch, and its own re-read is
  # bounded by the same window.
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    case "$cached" in
      parked) printf 'parked'; return ;;
      paused)
        if status_is_paused_or_captain_held "$last"; then
          printf 'paused'
          return
        fi
        ;;
    esac
  fi

  # Authoritative re-read. Parked first: its gate is check REGISTRATION, which
  # costs no fm-crew-state.sh read for a crew with no merge monitor at all.
  if crew_is_parked_awaiting_merge "$task" "$STATE"; then
    date +%s > "$recheck_file"
    printf 'parked'
    return
  fi
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  class=$(crew_absorb_class "$task")
  # A verified durable captain-held transfer earns the bounded cadence on its own.
  # crew_absorb_class can never answer `paused` for one: bin/fm-crew-state.sh reads
  # PAST the bookkeeping line to the state verb underneath, so a captain-held crew
  # reconciles to parked/done/blocked and lands here as `none`. That `none` is not
  # evidence of a wedge - bin/fm-decision-hold.sh appends `captain-held:` only after
  # VERIFYING that a captain-held backlog item owns the decision, which is stronger
  # positive evidence than any pane read: it proves firstmate is already tracking
  # the exact thing this crew waits on. `working` is deliberately not upgraded, so
  # a re-activated crew still outranks the hold.
  if [ "$class" = none ] && status_line_is_captain_held "$last"; then
    class=paused
  fi
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# Surface a stale pane on the ordinary (non-hold) path. When the crew's log
# DECLARES a hold, this is a deliberate fail-open: authoritative state refused to
# corroborate the hold, so firstmate gets ONE immediate look - but the hold markers
# are then (re)armed and the re-surface throttle stamped, so the very next poll
# falls onto the bounded cadence instead of the wedge timer. Without that, a crew
# whose hold cannot be corroborated would surface, then re-arm a wedge timer and
# escalate as a possible wedge at STALE_ESCALATE_SECS, which is the ordinary stale
# cadence this change exists to stop. Ported from upstream firstmate PR #743.
surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    printf 'paused' > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

# Should this cycle surface the current set of refused checks? A set that is new
# or has changed always surfaces immediately; an unchanged set surfaces again
# every CHECK_REJECT_RESURFACE. The marker records the set itself, not just a
# timestamp, so removing one refused check and adding another is a change, not a
# suppressed repeat.
check_rejection_due() {  # <space-separated refused paths>
  local sig=$1 marker
  marker="$STATE/.check-rejected"
  if [ "$sig" != "$(cat "$marker" 2>/dev/null || true)" ]; then
    printf '%s\n' "$sig" > "$marker"
    return 0
  fi
  if [ "$(age_of "$marker")" -ge "$CHECK_REJECT_RESURFACE" ]; then
    printf '%s\n' "$sig" > "$marker"
    return 0
  fi
  return 1
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# declared-pause exemption (a crew waiting on a known external dependency is not
# a surprise block - absorb it on the poll loop's long pause cadence instead),
# and otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane to
# diagnose") is exactly right for a blocked crew, and the drain/dedupe/guard
# machinery already understands it (queued by key=window, so a later poll-path
# stale for the same pane collapses on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
trap 'fm_custom_check_snapshot_cleanup; fm_lock_release "$WATCH_LOCK"' EXIT
# Now that the singleton lock is held, no other watcher can be mid-verification,
# so any check temporary still on disk was orphaned by a killed process.
fm_custom_check_sweep_temporaries "$STATE"
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  # Every check is AUTHENTICATED before it can run (bin/fm-check-lib.sh): the
  # file must match its trust record and pass the private-artifact test, and what
  # executes is the verified snapshot, never the path on disk. Classification is
  # a separate first pass that executes nothing, so a refusal is decided - and
  # surfaced - before any check runs and can never be starved by a chatty
  # authenticated check that wakes and ends the cycle first.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    runnable=()
    rejected=()
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      if fm_custom_check_registered "$STATE" "$(basename "$c" .check.sh)"; then
        runnable+=("$c")
      else
        rejected+=("$c")
      fi
    done
    [ "${#rejected[@]}" -gt 0 ] || rm -f "$STATE/.check-rejected"
    if [ "${#rejected[@]}" -gt 0 ] && check_rejection_due "${rejected[*]}"; then
      reason="check: rejected unauthenticated state checks: ${rejected[*]} (refused without running; inspect each file, then register it with bin/fm-check-register.sh <id>, or remove it)"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    for c in ${runnable[@]+"${runnable[@]}"}; do
      [ -e "$c" ] || continue
      if ! fm_custom_check_snapshot_prepare "$STATE" "$(basename "$c" .check.sh)"; then
        # Lost the race with a rewrite between classification and execution.
        # Refusing is the whole point; the next sweep surfaces it.
        fm_custom_check_snapshot_cleanup
        continue
      fi
      out=$(run_check "$FM_CUSTOM_CHECK_SNAPSHOT")
      fm_custom_check_snapshot_cleanup
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    # Drop hold tracking the moment the log stops declaring one - EXCEPT for a
    # parked-awaiting-merge hold, which is never declared by a status verb at all
    # (its evidence is `done:` plus a registered merge monitor), so a log test can
    # never see it and would otherwise wipe its bounded cadence on every poll.
    # hold_state_class is what retires a parked hold, by ceasing to return `parked`.
    if [ -e "$STATE/.paused-$key" ] \
       && ! status_is_paused_or_captain_held "$last" \
       && [ "$(cat "$STATE/.paused-$key" 2>/dev/null || true)" != parked ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    if ! tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null); then
      capture_failure "$w" "$key"
      continue
    fi
    rm -f "$STATE/.capfail-$key" "$STATE/.capfail-surfaced-$key"
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's current stale is a declared pause
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(hold_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          # The two declared holds that reach THIS branch rather than the
          # non-terminal one below both look terminal on purpose:
          #   - parked awaiting merge: the crew's real state verb IS done:;
          #   - captain-held: that line is BOOKKEEPING, so the terminal reader looks
          #     past it to the needs-decision:/done: underneath.
          # So hold_state_class has to be consulted here too, not only below - the
          # upstream port placed it on the non-terminal path alone, where a
          # captain-held crew never lands.
          new_hash=0
          [ "$(cat "$sf" 2>/dev/null || true)" = "$h" ] || new_hash=1
          if [ "$new_hash" = 1 ] || [ -e "$pf" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(hold_state_class "$w" "$task")" in
              parked)
                # Parked awaiting merge: a finished crew (reconciled done) with a
                # REGISTERED merge monitor idling on its open PR. Its merge-check, not
                # this churny idle-pane hash, is the live signal, so ABSORB the stale
                # wake and arm NO wedge timer (a parked crew has nothing to wedge on;
                # handle_paused_stale clears any leftover timer from a prior working
                # phase). Re-evaluated, never latched: the moment the crew is
                # re-activated (busy pane, or its latest state verb moves off done) it
                # stops reporting done and full stale sensitivity resumes. The done:
                # PR-ready itself already reached firstmate via the signal path when the
                # crew appended it, so an immediate re-surface of this idle pane adds
                # nothing - but the bounded cadence still rechecks it, so a PR whose
                # merge word never comes cannot sit unwatched forever.
                handle_paused_stale "$w" "$task" "$h" parked
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              working)
                # A NEW hash is a fresh stale episode, so the wedge timer restarts;
                # re-entering on an unchanged hash (a hold that authoritative state
                # just overrode) must NOT keep resetting it, or a crew that wedges
                # right after a hold lifts would never reach the threshold.
                clear_pause_state "$w"
                printf '%s' "$h" > "$sf"
                if [ "$new_hash" = 1 ] || [ ! -e "$ssf" ]; then date +%s > "$ssf"; fi
                triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
                ;;
              *)
                clear_pause_state "$w"
                fm_wake_append stale "$w" "stale: $w" || exit 1
                printf '%s' "$h" > "$sf"
                rm -f "$ssf"
                mark_surfaced "$STATE/$task.status"
                wake "stale: $w"
                ;;
            esac
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly run-step read runs only
          # on first sight, never every poll) via hold_state_class:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - parked / paused: a declared hold, so absorb on the long
          #     PAUSE_RESURFACE_SECS recheck cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     hold - the crew has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(hold_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              parked)
                handle_paused_stale "$w" "$task" "$h" parked
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(hold_state_class "$w" "$task")" in
                parked)  handle_paused_stale "$w" "$task" "$h" parked ;;
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared hold)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                # An unchanged hash whose hold authoritative state will not
                # corroborate stays on the bounded cadence rather than re-surfacing
                # every poll: the crew already got its one immediate look from
                # surface_nonterminal_stale, which armed these markers precisely so
                # the repeat lands here. Ported from upstream firstmate PR #743.
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        # Reaching here with n>=2 means the pane is BUSY - the crew is working again -
        # so every hold, parked included, is retired. The undeclared-hold arm keeps
        # its parked exemption for the same reason as at the top of the loop: a
        # parked hold is never declared by a status verb, so a log test cannot see it.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || { [ "$(cat "$pf" 2>/dev/null || true)" != parked ] \
             && ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      task=$(window_to_task "$w" "$STATE")
      # The CHANGED-hash route, and the one that matters most for a held crew: a
      # redraw-jittered idle pane (a clock, a token counter) never produces two
      # identical hashes, so it never reaches the stale triage above at all - it lands
      # here on every single poll. Keeping the bounded cadence alive here is what stops
      # a held crew from being re-evaluated from scratch each poll.
      #
      # The pre-gate is deliberately three CHEAP tests, because hold_state_class can
      # cost an fm-crew-state.sh read and this runs every poll for every window: a
      # declared hold in the line already read, an established hold marker, or the mere
      # PRESENCE of a check file (the only crews that can be parked). A crew with none
      # of those cannot be held, so it never pays for the read.
      if ! afk_present \
         && { status_is_paused_or_captain_held "$last" || [ -e "$pf" ] || [ -f "$STATE/$task.check.sh" ]; } \
         && ! window_is_busy "$w" "$tail40"; then
        case "$(hold_state_class "$w" "$task")" in
          parked) handle_paused_stale "$w" "$task" "$h" parked ;;
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      [ -e "$pf" ] && clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
