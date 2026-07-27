#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# The poll is registered through the check trust path in the same operation that
# writes it (bin/fm-check-lib.sh); an unregistered poll is refused by the watcher
# instead of running, so arming and registering are never separable steps here.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2
# The id names a state file, so refuse anything that is not a single safe path
# component before writing or registering anything.
fm_check_id_valid "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

mkdir -p "$STATE"
umask 077
cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
if ! fm_custom_check_register "$STATE" "$ID"; then
  rm -f "$STATE/$ID.check.sh"
  fm_custom_check_trust_remove "$STATE" "$ID" || true
  echo "error: could not register the merge poll for $ID; the PR was recorded but merge monitoring is NOT armed" >&2
  exit 1
fi
echo "armed: state/$ID.check.sh polls $URL"
