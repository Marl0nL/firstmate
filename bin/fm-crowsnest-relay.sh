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

# Backend-forwarded thread context (the report's "Option A"). The local-agents
# backend now sets these on the relay command, so the TRUE replied-to/quoted
# message and the sender's display name arrive WITHOUT any Chat API read. Prefer
# the compact JSON blob; the convenience scalars are the fallback. A message with
# no quote leaves all of these empty and the entry is stashed exactly as before.
# The same falsey CROWSNEST_THREAD_CONTEXT kill switch that disables the read-back
# also reverts this to text-only stashing.
CTX_JSON=${LOCAL_AGENTS_CONTEXT_JSON:-}
SENDER_DN=${LOCAL_AGENTS_SENDER_DISPLAY_NAME:-}
QUOTED_TEXT=${LOCAL_AGENTS_QUOTED_TEXT:-}
QUOTED_SENDER=${LOCAL_AGENTS_QUOTED_SENDER:-}
QUOTED_NAME=${LOCAL_AGENTS_QUOTED_NAME:-}
if [ -z "${FMC_CONTEXT:-}" ]; then
  CTX_JSON=""; SENDER_DN=""; QUOTED_TEXT=""; QUOTED_SENDER=""; QUOTED_NAME=""
fi

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

# Normalize the forwarded context to a valid JSON value (null when absent or
# unparseable) so the entry-build jq can consume it with --argjson, and classify
# the forwarded quote so the detached read-back is only spawned when it can add
# something the relay did not already stash.
#   text -> an inline quote whose content is authoritative (no read needed)
#   name -> only the quoted message name (the report's F4 get-hydrate case)
#   none -> no forwarded quote (fall back to the best-effort thread read)
if [ -z "$CTX_JSON" ] || ! printf '%s' "$CTX_JSON" | jq -e . >/dev/null 2>&1; then
  CTX_JSON=null
fi
if [ "$CTX_JSON" != null ]; then
  q_text=$(printf '%s' "$CTX_JSON" | jq -r '(.quoted_message.snapshot.text // .quoted_message.snapshot.formatted_text) // ""' 2>/dev/null)
  q_name=$(printf '%s' "$CTX_JSON" | jq -r '.quoted_message.name // ""' 2>/dev/null)
else
  q_text=""; q_name=""
fi
[ -n "$q_text" ] || q_text=$QUOTED_TEXT
[ -n "$q_name" ] || q_name=$QUOTED_NAME
if [ -n "$q_text" ]; then QSTATE=text
elif [ -n "$q_name" ]; then QSTATE=name
else QSTATE=none; fi

ID=$(fmc_new_id)
INBOX=$(fmc_inbox_dir)
NOW=$(date +%s 2>/dev/null || echo 0)

if ! mkdir -p "$INBOX" 2>/dev/null; then
  diag "cannot create inbox dir"
  ack
  exit 0
fi

# Stash the message atomically so a concurrent reader never sees a half file.
# The forwarded context (report "Option A") is folded in here so the durable base
# entry itself carries the TRUE quoted message and the sender display name, with
# no network read: `sender_display_name` for the captain, `quoted` for the full
# quoted-message metadata, and `reply_to` (the accurate replacement for the old
# best-effort guess) whenever the quote carries inline text. A message with no
# forwarded quote adds none of these and is stashed exactly as before.
if jq -cn \
  --arg id "$ID" \
  --arg space "$SPACE" \
  --arg thread "$THREAD" \
  --arg sender "$SENDER" \
  --arg mode "$MODE" \
  --arg text "$TEXT" \
  --argjson received "$NOW" \
  --argjson ctx "$CTX_JSON" \
  --arg sender_dn "$SENDER_DN" \
  --arg q_text "$QUOTED_TEXT" \
  --arg q_sender "$QUOTED_SENDER" \
  --arg q_name "$QUOTED_NAME" \
  '
  ($ctx.sender_display_name // (if $sender_dn == "" then null else $sender_dn end)) as $disp
  | ( if ($ctx.quoted_message != null) then $ctx.quoted_message
      elif ($q_name == "" and $q_text == "" and $q_sender == "") then null
      else {}
           + (if $q_name != "" then {name: $q_name} else {} end)
           + (if ($q_text != "" or $q_sender != "")
              then {snapshot: ({}
                     + (if $q_text != "" then {text: $q_text} else {} end)
                     + (if $q_sender != "" then {sender: $q_sender} else {} end))}
              else {} end)
      end ) as $q
  | (($q.snapshot.text // $q.snapshot.formatted_text) // null) as $qtxt
  | {id:$id, space:$space,
     thread:(if $thread == "" then null else $thread end),
     sender:$sender, mode:$mode, text:$text, received_epoch:$received}
    + (if ($disp != null and $disp != "") then {sender_display_name: $disp} else {} end)
    + (if $q != null then {quoted: $q} else {} end)
    + (if ($q != null and $qtxt != null and $qtxt != "")
       then {reply_to: {sender: "", sender_display_name: ($q.snapshot.sender // null),
                        text: $qtxt, create_time: ($q.snapshot.create_time // "")}}
       else {} end)
  ' \
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

# Best-effort thread-context enrichment. The durable base entry and wake are
# already written above, so this only ADDS context and can never lose a message.
# It is spawned DETACHED so the instant ack (this script's whole point) is never
# gated on a Chat API read; the live session drains the inbox on its next check
# cycle, by which point enrichment has long since landed. FMC_CONTEXT_SYNC forces
# an inline run for deterministic tests/debugging.
#
# The read-back is spawned only when it can still add something the relay did not
# already stash: an inline forwarded quote (QSTATE=text) is authoritative, so the
# read is skipped entirely; a name-only quote (QSTATE=name) is hydrated by a
# single spaces.messages.get; and the no-quote case (QSTATE=none) keeps the old
# best-effort thread read, which needs a thread to read.
CTX_CMD=${FMC_CONTEXT_CMD:-$FM_ROOT/bin/fm-crowsnest-context.sh}
spawn_ctx=""
case "$QSTATE" in
  text) spawn_ctx="" ;;
  name) spawn_ctx=1 ;;
  *)    [ -n "$THREAD" ] && spawn_ctx=1 ;;
esac
if [ -n "${FMC_CONTEXT:-}" ] && [ -n "$spawn_ctx" ] && [ -x "$CTX_CMD" ]; then
  if [ -n "${FMC_CONTEXT_SYNC:-}" ]; then
    "$CTX_CMD" "$ID" >/dev/null 2>&1 || true
  else
    nohup "$CTX_CMD" "$ID" >/dev/null 2>&1 </dev/null &
  fi
fi

ack
exit 0
