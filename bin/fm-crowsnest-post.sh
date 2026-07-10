#!/usr/bin/env bash
# Post a message into a Google Chat space/thread - the Crowsnest's post-back and
# reverse channel. Two modes:
#
#   Reply to a pending chat message (the common case, driven by fmc-respond):
#     fm-crowsnest-post.sh --reply <id> --text-file <path>
#     fm-crowsnest-post.sh --reply <id> -            # text on stdin
#       Reads state/chat-inbox/<id>.json for the originating space + thread and
#       posts a threaded reply back into that conversation.
#
#   Proactive post (reverse channel, e.g. an away-mode escalation):
#     fm-crowsnest-post.sh --space <spaces/AAA> [--thread <spaces/.../threads/BBB>] --text-file <path>
#     fm-crowsnest-post.sh --space <spaces/AAA> [--thread ...] -
#
# The actual send reuses the backend's own ChatClient via bin/fm-crowsnest-post.py
# (reuse, not reinvent). This wrapper resolves the target, reads the text, and -
# under CROWSNEST_DRY_RUN - records the would-be post to state/chat-outbox/<key>.json
# instead of sending, so the full loop is testable without GCP credentials.
#
# It does NOT remove the inbox entry on a successful reply; that cleanup belongs
# to the live session (fmc-respond) after the reply is confirmed, mirroring how
# fmx-respond owns x-inbox cleanup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-crowsnest-lib.sh
. "$SCRIPT_DIR/fm-crowsnest-lib.sh"

usage() {
  echo "usage: fm-crowsnest-post.sh --reply <id> (--text-file <path> | -)" >&2
  echo "       fm-crowsnest-post.sh --space <space> [--thread <thread>] (--text-file <path> | -)" >&2
}

fmc_load_config

REPLY_ID=""
SPACE=""
THREAD=""
TEXT_FILE=""
READ_STDIN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --reply) REPLY_ID=${2:-}; shift 2 || { usage; exit 2; } ;;
    --space) SPACE=${2:-}; shift 2 || { usage; exit 2; } ;;
    --thread) THREAD=${2:-}; shift 2 || { usage; exit 2; } ;;
    --text-file) TEXT_FILE=${2:-}; shift 2 || { usage; exit 2; } ;;
    -) READ_STDIN=1; shift ;;
    *) echo "fm-crowsnest-post: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "$REPLY_ID" ] && [ -n "$SPACE" ]; then
  echo "fm-crowsnest-post: use either --reply or --space, not both" >&2; exit 2
fi
if [ -z "$REPLY_ID" ] && [ -z "$SPACE" ]; then
  usage; exit 2
fi
if [ -z "$TEXT_FILE" ] && [ "$READ_STDIN" -eq 0 ]; then
  echo "fm-crowsnest-post: no text source (--text-file <path> or -)" >&2; usage; exit 2
fi

KEY=""
if [ -n "$REPLY_ID" ]; then
  fmc_safe_id "$REPLY_ID" || { echo "fm-crowsnest-post: unsafe id: $REPLY_ID" >&2; exit 2; }
  INBOX_FILE="$(fmc_inbox_dir)/$REPLY_ID.json"
  if [ ! -f "$INBOX_FILE" ]; then
    echo "fm-crowsnest-post: no pending inbox entry for $REPLY_ID" >&2; exit 2
  fi
  command -v jq >/dev/null 2>&1 || { echo "fm-crowsnest-post: jq required to read the inbox entry" >&2; exit 3; }
  SPACE=$(jq -r '.space // ""' "$INBOX_FILE" 2>/dev/null)
  THREAD=$(jq -r '.thread // ""' "$INBOX_FILE" 2>/dev/null)
  KEY=$REPLY_ID
fi
[ -n "$KEY" ] || KEY=$(fmc_new_id)

if [ -z "$SPACE" ]; then
  echo "fm-crowsnest-post: no target space resolved" >&2; exit 2
fi

# Read the reply text into a temp file so both the dry-run record and the live
# send read from a single concrete source.
TEXT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-crowsnest-post.XXXXXX") || exit 1
trap 'rm -f "$TEXT_TMP"' EXIT
if [ "$READ_STDIN" -eq 1 ]; then
  cat > "$TEXT_TMP"
else
  [ -r "$TEXT_FILE" ] || { echo "fm-crowsnest-post: cannot read text file: $TEXT_FILE" >&2; exit 2; }
  cat "$TEXT_FILE" > "$TEXT_TMP"
fi
if [ ! -s "$TEXT_TMP" ] || ! grep -q '[^[:space:]]' "$TEXT_TMP"; then
  echo "fm-crowsnest-post: refusing to post empty text" >&2; exit 2
fi

# Dry-run: record the would-be post and mutate nothing else. Works without the
# backend installed or any credentials, so the loop is testable offline.
if [ -n "${FMC_DRY:-}" ]; then
  OUTBOX=$(fmc_outbox_dir)
  mkdir -p "$OUTBOX" 2>/dev/null || { echo "fm-crowsnest-post: cannot create outbox" >&2; exit 1; }
  if command -v jq >/dev/null 2>&1; then
    jq -Rsc \
      --arg space "$SPACE" \
      --arg thread "$THREAD" \
      --arg key "$KEY" \
      '{key:$key, space:$space, thread:(if $thread == "" then null else $thread end), text:.}' \
      < "$TEXT_TMP" > "$OUTBOX/$KEY.json" 2>/dev/null \
      || { echo "fm-crowsnest-post: cannot write outbox record" >&2; exit 1; }
  else
    cp "$TEXT_TMP" "$OUTBOX/$KEY.txt" 2>/dev/null || true
  fi
  echo "dry-run: recorded reply to $SPACE${THREAD:+ (thread $THREAD)} in $OUTBOX/$KEY.json"
  exit 0
fi

# Live post: needs the Crowsnest enabled and a working interpreter for the
# backend transport.
fmc_enabled || { echo "fm-crowsnest-post: the Crowsnest is not enabled (config/crowsnest.env)" >&2; exit 3; }
if [ -z "${FMC_PY:-}" ]; then
  echo "fm-crowsnest-post: no python interpreter for the local-agents-chat backend" >&2; exit 3
fi

argv=("$FMC_PY" "$FM_ROOT/bin/fm-crowsnest-post.py" --space "$SPACE" --text-file "$TEXT_TMP")
[ -n "$THREAD" ] && argv+=(--thread "$THREAD")
[ -n "${FMC_LA_CONFIG:-}" ] && argv+=(--config "$FMC_LA_CONFIG")

"${argv[@]}"
