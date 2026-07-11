#!/usr/bin/env bash
# Enrich a pending Crowsnest inbox entry with recent thread context.
#
#   fm-crowsnest-context.sh <inbox-id>
#
# The relay stashes only the captain's own message (space/thread/sender/text),
# because the local-agents-chat subprocess agent forwards nothing about the
# replied-to message or the prior thread. This tool reads the recent thread
# messages back from the Chat API (bin/fm-crowsnest-context.py, reusing the
# backend's ChatClient credentials) and MERGES them into
# state/chat-inbox/<id>.json as `thread_context`, `reply_to`, and
# `sender_display_name`, so the live firstmate session can compose with the
# context the captain is replying to.
#
# It is ENTIRELY best-effort and side-effect-safe: the relay writes the durable
# base entry and enqueues the wake BEFORE spawning this, so if anything here
# fails (no thread, no interpreter, no backend, no credentials, no scope, a
# network error) the inbox entry is simply left as it was and the Crowsnest
# behaves exactly as before context existed. It never exits non-zero in a way
# that matters and never touches anything but the one inbox entry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_ROOT FM_HOME
# shellcheck source=bin/fm-crowsnest-lib.sh
. "$SCRIPT_DIR/fm-crowsnest-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "fm-crowsnest-context: usage: fm-crowsnest-context.sh <inbox-id>" >&2; exit 2; }

fmc_load_config
fmc_enabled || exit 0
fmc_safe_id "$ID" || { echo "fm-crowsnest-context: unsafe id: $ID" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || exit 0

INBOX_FILE="$(fmc_inbox_dir)/$ID.json"
[ -f "$INBOX_FILE" ] || exit 0

SPACE=$(jq -r '.space // ""' "$INBOX_FILE" 2>/dev/null)
THREAD=$(jq -r '.thread // ""' "$INBOX_FILE" 2>/dev/null)
SENDER=$(jq -r '.sender // ""' "$INBOX_FILE" 2>/dev/null)
TEXT=$(jq -r '.text // ""' "$INBOX_FILE" 2>/dev/null)

# No thread means nothing to read back: leave the entry exactly as today.
[ -n "$SPACE" ] || exit 0
[ -n "$THREAD" ] || exit 0
[ -n "${FMC_PY:-}" ] || exit 0

LIMIT=${FMC_CONTEXT_LIMIT:-10}
MAXCHARS=${FMC_CONTEXT_MAXCHARS:-1200}

argv=("$FMC_PY" "$FM_ROOT/bin/fm-crowsnest-context.py" --space "$SPACE" --thread "$THREAD"
  --limit "$LIMIT" --max-chars "$MAXCHARS")
[ -n "$SENDER" ] && argv+=(--sender "$SENDER")
[ -n "$TEXT" ] && argv+=(--exclude-text "$TEXT")
[ -n "${FMC_LA_CONFIG:-}" ] && argv+=(--config "$FMC_LA_CONFIG")

# Bound the read so a hung network call can never wedge enrichment.
ENRICH=""
if command -v timeout >/dev/null 2>&1; then
  ENRICH=$(timeout "${FMC_CONTEXT_TIMEOUT:-20}" "${argv[@]}" 2>/dev/null) || exit 0
else
  ENRICH=$("${argv[@]}" 2>/dev/null) || exit 0
fi
[ -n "$ENRICH" ] || exit 0
# Guard against a garbage read; only a well-formed object with a context array
# is allowed to touch the inbox entry.
printf '%s' "$ENRICH" | jq -e 'type == "object" and (.thread_context | type == "array")' >/dev/null 2>&1 || exit 0

# Merge context into the inbox entry atomically. An empty context array with no
# reply_to adds nothing meaningful, so skip the rewrite entirely in that case.
if [ "$(printf '%s' "$ENRICH" | jq -r '((.thread_context | length) > 0) or (.reply_to != null) or (.sender_display_name != null)')" != "true" ]; then
  exit 0
fi

TMP="$INBOX_FILE.ctx.$$"
if jq -c --argjson ctx "$ENRICH" '
      . + {thread_context: $ctx.thread_context, reply_to: $ctx.reply_to}
        + (if $ctx.sender_display_name != null then {sender_display_name: $ctx.sender_display_name} else {} end)
    ' "$INBOX_FILE" > "$TMP" 2>/dev/null && [ -s "$TMP" ]; then
  # Re-check the entry still exists right before replacing it. `mv -f` recreates
  # the destination, so if the live session answered and removed this entry
  # between the jq read above and here, an unconditional mv would RESURRECT the
  # answered message and the poll would re-surface it as a duplicate reply. This
  # narrows that window to the check-then-mv gap; a resurrection is far worse
  # than losing a best-effort context merge.
  if [ -f "$INBOX_FILE" ]; then
    mv -f "$TMP" "$INBOX_FILE" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
  else
    rm -f "$TMP" 2>/dev/null || true
  fi
else
  rm -f "$TMP" 2>/dev/null || true
fi
exit 0
