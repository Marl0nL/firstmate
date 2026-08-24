#!/usr/bin/env bash
# One short check of the Crowsnest chat inbox for a pending message.
#
# Inert by default: a HARD no-op (exit 0, no output) unless the Crowsnest is
# opted in via config/crowsnest.env (CROWSNEST_ENABLED truthy). This script is
# the body of the watcher check shim state/chat-watch.check.sh, where the
# contract is "output => wake firstmate, silence => keep sleeping", so the no-op
# keeps the watcher behaving exactly as today until a user opts in.
#
# Unlike X mode's poll, this does NOT reach out over the network: the relay
# (fm-crowsnest-relay.sh) is PUSHED a message by the local-agents-chat backend
# and stashes it locally, so the durable payload already lives on disk. This
# check is the ACTIVE waker and a restart-safe backstop: it surfaces the oldest
# pending inbox entry as one "chat-mention <id>" line, which the watcher turns
# into a check: wake the one live firstmate session handles. The live session
# drains the whole inbox (fmc-respond) and removes each entry once answered, so
# a handled message stops being surfaced on the next cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-crowsnest-lib.sh
. "$SCRIPT_DIR/fm-crowsnest-lib.sh"

fmc_load_config
# Hard no-op when the Crowsnest is off: this is what keeps the check shim inert.
fmc_enabled || exit 0

INBOX=$(fmc_inbox_dir)
[ -d "$INBOX" ] || exit 0

# Surface the oldest pending entry (by modification time) so a burst is drained
# in arrival order across cycles. The id is the filename stem; validate it before
# printing so a stray file can never inject anything unexpected into the wake.
while IFS= read -r f; do
  base=${f##*/}
  id=${base%.json}
  # Skip an unsafe-named stray file rather than letting it stall the whole
  # waker: continue to the next-oldest safe pending entry.
  fmc_safe_id "$id" || continue
  printf 'chat-mention %s\n' "$id"
  exit 0
done < <(ls -1tr "$INBOX"/*.json 2>/dev/null)

exit 0
