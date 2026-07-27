#!/usr/bin/env bash
# fm-check-register.sh - register a watcher check script through the trust path.
#
# The watcher executes state/<id>.check.sh every check cycle and REFUSES any
# check that is not bound to its exact bytes. This is how a check gets bound.
# bin/fm-check-lib.sh owns the record format and the verification rules.
#
# Registration asserts that the file's current content is intended, so READ THE
# FILE FIRST. Registering also sets the check to mode 700.
#
# Usage:
#   fm-check-register.sh <id> [<id>...]   register state/<id>.check.sh
#   fm-check-register.sh --list           list every check and its trust state
#   fm-check-register.sh --verify <id>    report whether <id> is registered
#   fm-check-register.sh --help
#
# <id> is the file stem: state/usage-watch.check.sh has id "usage-watch".
# Honors FM_HOME and FM_STATE_OVERRIDE like the rest of bin/.
#
# Exit status: 0 on success, 1 on a failed registration or a failed --verify,
# 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
fm-check-register.sh - register a watcher check script through the trust path.

The watcher executes state/<id>.check.sh every check cycle and REFUSES any check
that is not bound to its exact bytes. This is how a check gets bound.
Registration asserts the file's current content is intended, so READ THE FILE
FIRST. Registering also sets the check to mode 700.

Usage:
  fm-check-register.sh <id> [<id>...]   register state/<id>.check.sh
  fm-check-register.sh --list           list every check and its trust state
  fm-check-register.sh --verify <id>    report whether <id> is registered
  fm-check-register.sh --help

<id> is the file stem: state/usage-watch.check.sh has id "usage-watch".
Honors FM_HOME and FM_STATE_OVERRIDE like the rest of bin/.
EOF
}

list_checks() {
  local c id found=0
  for c in "$STATE"/*.check.sh; do
    [ -e "$c" ] || continue
    found=1
    id=$(basename "$c" .check.sh)
    if fm_custom_check_registered "$STATE" "$id"; then
      printf 'registered    %s\n' "$id"
    else
      printf 'UNREGISTERED  %s (refused by the watcher; inspect %s, then: bin/fm-check-register.sh %s)\n' \
        "$id" "$c" "$id"
    fi
  done
  [ "$found" -eq 1 ] || echo "no check scripts in $STATE"
}

case "${1-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list)
    [ "$#" -eq 1 ] || { echo "error: --list takes no arguments" >&2; exit 2; }
    list_checks
    exit 0
    ;;
  --verify)
    [ "$#" -eq 2 ] || { echo "error: --verify takes exactly one id" >&2; exit 2; }
    if fm_custom_check_registered "$STATE" "$2"; then
      printf 'registered: state/%s.check.sh\n' "$2"
      exit 0
    fi
    printf 'UNREGISTERED: state/%s.check.sh\n' "$2"
    exit 1
    ;;
  '')
    usage >&2
    exit 2
    ;;
  -*)
    echo "error: unknown option $1" >&2
    exit 2
    ;;
esac

status=0
for id in "$@"; do
  if ! fm_check_id_valid "$id"; then
    echo "error: invalid check id: $id" >&2
    status=1
    continue
  fi
  if [ ! -f "$STATE/$id.check.sh" ]; then
    echo "error: no such check: $STATE/$id.check.sh" >&2
    status=1
    continue
  fi
  if fm_custom_check_register "$STATE" "$id"; then
    printf 'registered: state/%s.check.sh (%s)\n' "$id" "$FM_CUSTOM_CHECK_HASH"
  else
    echo "error: could not register $STATE/$id.check.sh" >&2
    status=1
  fi
done
exit "$status"
