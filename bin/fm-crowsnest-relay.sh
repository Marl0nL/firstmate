#!/usr/bin/env bash
# Crowsnest relay - the thin command registered as the `firstmate` agent with the
# local-agents-chat backend. When a Google Chat message is routed to firstmate,
# the backend runs THIS script as a subprocess: the message text arrives on stdin
# and as LOCAL_AGENTS_* env vars, and this script's stdout becomes the immediate
# Chat reply.
#
# It deliberately does NOT spawn a fleet-aware agent. Spawning a second Claude
# here would create a parallel supervisor competing with the one live firstmate
# session for fleet control - the exact thing the Crowsnest exists to avoid.
# Instead it:
#   1. stashes the message to state/chat-inbox/<id>.json (space/thread/sender/
#      text), the durable payload the live session reads later, and
#   2. enqueues a durable "chat-mention <id>" check wake so the message survives
#      a watcher gap or a firstmate restart, and
#   3. returns an immediate async acknowledgement ("on it, captain") as its
#      reply.
# The live firstmate session composes and posts the real answer on its own turn
# (see the fmc-respond skill), via bin/fm-crowsnest-post.sh.
#
# Contract with the backend (local_agents.agents.subprocess_agent): stdout must
# be non-empty and the exit code must be 0, or the backend reports an agent
# error to Chat. So this script ALWAYS prints an ack and exits 0, even when a
# stash or enqueue step fails - a lost reply is worse than a lost message, and
# the diagnostic is recorded to state/chat-poll.error for the operator.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_ROOT FM_HOME STATE
# shellcheck source=bin/fm-crowsnest-lib.sh
. "$SCRIPT_DIR/fm-crowsnest-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fmc_load_config

diag() {
  # Record a one-line operator diagnostic without ever failing the ack path.
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf 'crowsnest-relay %s\n' "$1" > "$STATE/chat-poll.error" 2>/dev/null || true
}

ack() {
  # The reply text Chat shows immediately. Always non-empty.
  printf '%s\n' "$FMC_ACK"
}

# Inputs. stdin carries the full prompt; env vars carry the routing context. Fall
# back to LOCAL_AGENTS_PROMPT if stdin was empty (some callers only set env).
TEXT=$(cat 2>/dev/null || true)
[ -n "$TEXT" ] || TEXT=${LOCAL_AGENTS_PROMPT:-}
SPACE=${LOCAL_AGENTS_SPACE:-}
THREAD=${LOCAL_AGENTS_THREAD:-}
SENDER=${LOCAL_AGENTS_SENDER:-}
MODE=${LOCAL_AGENTS_MODE:-}

if ! fmc_enabled; then
  # Opted out: acknowledge politely but enqueue nothing. Registration is the
  # opt-in, so this only happens if the config was toggled off while registered.
  printf 'The Crowsnest is not currently on watch, captain.\n'
  exit 0
fi

if [ -z "$TEXT" ]; then
  # Nothing to relay; still satisfy the non-empty-stdout contract.
  ack
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  diag "missing jq; message not stashed"
  ack
  exit 0
fi

ID=$(fmc_new_id)
INBOX=$(fmc_inbox_dir)
NOW=$(date +%s 2>/dev/null || echo 0)

if ! mkdir -p "$INBOX" 2>/dev/null; then
  diag "cannot create inbox dir"
  ack
  exit 0
fi

# Stash the message atomically so a concurrent reader never sees a half file.
if jq -cn \
  --arg id "$ID" \
  --arg space "$SPACE" \
  --arg thread "$THREAD" \
  --arg sender "$SENDER" \
  --arg mode "$MODE" \
  --arg text "$TEXT" \
  --argjson received "$NOW" \
  '{id:$id, space:$space,
    thread:(if $thread == "" then null else $thread end),
    sender:$sender, mode:$mode, text:$text, received_epoch:$received}' \
  > "$INBOX/$ID.json.tmp" 2>/dev/null && mv -f "$INBOX/$ID.json.tmp" "$INBOX/$ID.json" 2>/dev/null; then
  :
else
  rm -f "$INBOX/$ID.json.tmp" 2>/dev/null || true
  diag "cannot write inbox entry"
  ack
  exit 0
fi

# Durable wake so the message is handled even across a watcher gap or a restart.
# A fixed key coalesces a burst of messages to one queue entry; the live session
# drains the whole inbox on handling, so no message is lost.
if fm_wake_append check "chat-inbox" "chat-mention $ID" 2>/dev/null; then
  rm -f "$STATE/chat-poll.error" 2>/dev/null || true
else
  diag "wrote inbox entry $ID but could not enqueue the wake"
fi
ack
exit 0
