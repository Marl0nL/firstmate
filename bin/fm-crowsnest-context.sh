#!/usr/bin/env bash
# Enrich a pending Crowsnest inbox entry with thread/reply context that the relay
# could not stash for free.
#
#   fm-crowsnest-context.sh <inbox-id>
#
# The backend now forwards the TRUE replied-to/quoted message, so the relay
# already stashed accurate reply context for the common Reply/Quote case (see
# docs/crowsnest.md, "Thread and reply context"). This tool covers only the two
# cases that still need a Chat API read, dispatching on the forwarded quote:
#   * a name-only forwarded quote (the report's F4 case) is hydrated with a single
#     spaces.messages.get (which accepts chat.bot), filling in `quoted.snapshot`
#     and `reply_to`;
#   * a message with no forwarded quote falls back to the best-effort thread
#     spaces.messages.list read (known-broken on chat.bot; see docs), merging
#     `thread_context`/`reply_to`/`sender_display_name`.
# An already-inline forwarded quote is authoritative, so this tool is a no-op for
# it (and the relay does not even spawn it). It reuses the backend's ChatClient
# credentials via bin/fm-crowsnest-context.py / bin/fm_crowsnest_chat.py.
#
# It is ENTIRELY best-effort and side-effect-safe: the relay writes the durable
# base entry (with any forwarded quote) and enqueues the wake BEFORE spawning
# this, so if anything here fails (no interpreter, no backend, no credentials, no
# scope, a network error) the inbox entry keeps whatever the relay stashed and the
# Crowsnest behaves exactly as before context existed. It never exits non-zero in
# a way that matters and never touches anything but the one inbox entry.
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

MAXCHARS=${FMC_CONTEXT_MAXCHARS:-1200}

# Run bin/fm-crowsnest-context.py with a bounded timeout so a hung network call
# can never wedge enrichment. Prints its stdout; returns its exit code.
run_ctx() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${FMC_CONTEXT_TIMEOUT:-20}" "$@"
  else
    "$@"
  fi
}

# Atomically replace the inbox entry with FILTER applied. Re-checks the entry
# still exists right before replacing it: `mv -f` recreates the destination, so
# if the live session answered and removed this entry meanwhile, an unconditional
# mv would RESURRECT the answered message and re-surface it as a duplicate reply.
merge_into_entry() {
  local filter=$1 payload=$2 tmp="$INBOX_FILE.ctx.$$"
  if jq -c --argjson e "$payload" "$filter" "$INBOX_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if [ -f "$INBOX_FILE" ]; then
      mv -f "$tmp" "$INBOX_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Prefer the backend-forwarded quote (report "Option A"): when the relay already
# stashed the TRUE replied-to/quoted message there is no need to read the thread
# back over the (chat.bot-broken) spaces.messages.list at all.
#   text -> the quoted content is inline; reply context is authoritative already.
#   name -> only the quoted message NAME was forwarded (the report's F4 case);
#           hydrate its content with a single authenticated spaces.messages.get,
#           which - unlike list - accepts the chat.bot scope this token carries.
#   none -> no forwarded quote; fall through to the best-effort thread read.
QSTATE=$(jq -r '
  (.quoted) as $q
  | if $q == null then "none"
    elif (($q.snapshot.text // $q.snapshot.formatted_text) // "") != "" then "text"
    else "name" end' "$INBOX_FILE" 2>/dev/null)
[ -n "$QSTATE" ] || QSTATE=none

# Authoritative inline quote already stashed: nothing to read.
[ "$QSTATE" = text ] && exit 0

if [ "$QSTATE" = name ]; then
  # F4 hydrate: fetch just the quoted message by name (get accepts chat.bot).
  QUOTED_NAME=$(jq -r '.quoted.name // ""' "$INBOX_FILE" 2>/dev/null)
  [ -n "$QUOTED_NAME" ] || exit 0
  [ -n "${FMC_PY:-}" ] || exit 0
  gargv=("$FMC_PY" "$FM_ROOT/bin/fm-crowsnest-context.py" --get-message "$QUOTED_NAME" --max-chars "$MAXCHARS")
  [ -n "${FMC_LA_CONFIG:-}" ] && gargv+=(--config "$FMC_LA_CONFIG")
  HYDRATE=$(run_ctx "${gargv[@]}" 2>/dev/null) || exit 0
  [ -n "$HYDRATE" ] || exit 0
  # Only a well-formed object that actually adds content may touch the entry.
  printf '%s' "$HYDRATE" | jq -e 'type == "object" and ((.reply_to != null) or ((.quoted_snapshot // {}) | length > 0))' >/dev/null 2>&1 || exit 0
  # shellcheck disable=SC2016  # the $e/$-names in the filter are jq bindings, not shell vars.
  merge_into_entry '
      . + (if $e.reply_to != null then {reply_to: $e.reply_to} else {} end)
        + {quoted: ((.quoted // {}) + (if (($e.quoted_snapshot // {}) | length) > 0 then {snapshot: $e.quoted_snapshot} else {} end))}
    ' "$HYDRATE"
  exit 0
fi

# --- no forwarded quote: best-effort thread read (chat.bot+list is known-broken,
# see docs/crowsnest.md, so this is genuinely best-effort and usually a no-op) ---
# No thread means nothing to read back: leave the entry exactly as today.
[ -n "$SPACE" ] || exit 0
[ -n "$THREAD" ] || exit 0
[ -n "${FMC_PY:-}" ] || exit 0

LIMIT=${FMC_CONTEXT_LIMIT:-10}

argv=("$FMC_PY" "$FM_ROOT/bin/fm-crowsnest-context.py" --space "$SPACE" --thread "$THREAD"
  --limit "$LIMIT" --max-chars "$MAXCHARS")
[ -n "$SENDER" ] && argv+=(--sender "$SENDER")
[ -n "$TEXT" ] && argv+=(--exclude-text "$TEXT")
[ -n "${FMC_LA_CONFIG:-}" ] && argv+=(--config "$FMC_LA_CONFIG")

ENRICH=$(run_ctx "${argv[@]}" 2>/dev/null) || exit 0
[ -n "$ENRICH" ] || exit 0
# Guard against a garbage read; only a well-formed object with a context array
# is allowed to touch the inbox entry.
printf '%s' "$ENRICH" | jq -e 'type == "object" and (.thread_context | type == "array")' >/dev/null 2>&1 || exit 0

# Merge context into the inbox entry atomically. An empty context array with no
# reply_to adds nothing meaningful, so skip the rewrite entirely in that case.
if [ "$(printf '%s' "$ENRICH" | jq -r '((.thread_context | length) > 0) or (.reply_to != null) or (.sender_display_name != null)')" != "true" ]; then
  exit 0
fi

# shellcheck disable=SC2016  # the $e/$-names in the filter are jq bindings, not shell vars.
merge_into_entry '
      . + {thread_context: $e.thread_context, reply_to: $e.reply_to}
        + (if $e.sender_display_name != null then {sender_display_name: $e.sender_display_name} else {} end)
    ' "$ENRICH"
exit 0
