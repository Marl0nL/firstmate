#!/usr/bin/env bash
# fm-herdr-attention-config.sh - apply the captain-consented Herdr attention
# settings to the GLOBAL Herdr config so Herdr's own agent panel becomes a
# fleet-wide attention view for firstmate's report-agent state publishing (Track
# U phase U3; see docs/verification/runtime-backends.md "Agent-state publishing
# (U3)" and the captain's scoped consent recorded in
# data/decisions/herdr-integration-decisions-2026-08-24.md).
#
# This is the ONE authorized global-config edit. It touches EXACTLY three keys
# and nothing else:
#   [ui]        agent_panel_sort = "priority"   # attention-sorted agent panel
#   [ui.toast]  delivery         = "herdr"      # in-app toasts on state change
#   [ui.sound]  enabled          = true         # background-space state sounds
# It is idempotent (a no-op once applied), takes a dated backup before its first
# write, validates the result with `herdr config check`, restores the backup on
# any validation failure, and only then reloads the running server. It never
# edits keybindings, colours, or any other key, and never runs any other
# server-global operation. Because it mutates the captain's global config and the
# live default server, firstmate runs it on the captain's host AFTER this change
# lands - never a crewmate from an isolated worktree.
#
# Usage:
#   fm-herdr-attention-config.sh [apply] [--no-reload]
#   fm-herdr-attention-config.sh check
#   fm-herdr-attention-config.sh --help
#
#   apply        (default) back up if needed, apply the three settings, validate,
#                reload the running server. --no-reload skips the reload (edit and
#                validate only - used by tests and by hosts with no running
#                server). A no-op run reports "already applied" and reloads
#                nothing.
#   check        report whether the three settings are already applied; make no
#                change. Exit 0 = all applied, 10 = one or more differ.
#
# Env:
#   HERDR_CONFIG_PATH  overrides the config file path (Herdr's own override; used
#                      by tests to target a throwaway config).
set -u

CMD=apply
NO_RELOAD=0
for arg in "$@"; do
  case "$arg" in
    apply) CMD=apply ;;
    check) CMD=check ;;
    --no-reload) NO_RELOAD=1 ;;
    -h | --help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument '$arg' (see --help)" >&2
      exit 2
      ;;
  esac
done

CONFIG_PATH=${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDIT_PY="$SCRIPT_DIR/fm-herdr-attention-config-edit.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to edit the Herdr config safely" >&2
  exit 1
fi
if [ ! -f "$EDIT_PY" ]; then
  echo "error: config editor not found at $EDIT_PY" >&2
  exit 1
fi

# The pure text transform lives in fm-herdr-attention-config-edit.py: it reads
# the current config on stdin and writes the desired config on stdout, exiting 0
# when a change was made, 3 when already applied, 1 on a parse error. It only
# ever sets the three authorized keys and preserves every other line verbatim.
fm_herdr_attention_transform() {
  python3 "$EDIT_PY"
}

if [ ! -f "$CONFIG_PATH" ]; then
  # An absent config is the fresh-install default; seed a minimal one so the
  # transform has a valid base. Never overwrite an existing file here.
  cfg_dir=$(dirname "$CONFIG_PATH")
  mkdir -p "$cfg_dir" || { echo "error: cannot create $cfg_dir" >&2; exit 1; }
  : >"$CONFIG_PATH" || { echo "error: cannot create $CONFIG_PATH" >&2; exit 1; }
fi

current=$(cat "$CONFIG_PATH") || { echo "error: cannot read $CONFIG_PATH" >&2; exit 1; }
desired=$(printf '%s' "$current" | fm_herdr_attention_transform)
rc=$?

case "$rc" in
  3)
    if [ "$CMD" = check ]; then
      echo "herdr attention settings: already applied ($CONFIG_PATH)"
      exit 0
    fi
    echo "herdr attention settings already applied; nothing to do ($CONFIG_PATH)"
    exit 0
    ;;
  0) ;;
  *)
    echo "error: could not compute the Herdr config edit (see above)" >&2
    exit 1
    ;;
esac

if [ "$CMD" = check ]; then
  echo "herdr attention settings: NOT applied - run 'apply' ($CONFIG_PATH)"
  exit 10
fi

# A change is needed. Back up first, then write, validate, and reload.
ts=$(date +%Y%m%d-%H%M%S)
backup="$CONFIG_PATH.fm-backup-$ts"
cp -p "$CONFIG_PATH" "$backup" || { echo "error: backup to $backup failed" >&2; exit 1; }

printf '%s\n' "$desired" >"$CONFIG_PATH" || {
  echo "error: writing $CONFIG_PATH failed; restoring backup" >&2
  cp -p "$backup" "$CONFIG_PATH" || echo "error: RESTORE FAILED; backup at $backup" >&2
  exit 1
}

if command -v herdr >/dev/null 2>&1; then
  if ! HERDR_CONFIG_PATH="$CONFIG_PATH" herdr config check >/dev/null 2>&1; then
    echo "error: 'herdr config check' rejected the edited config; restoring backup" >&2
    cp -p "$backup" "$CONFIG_PATH" || echo "error: RESTORE FAILED; backup at $backup" >&2
    exit 1
  fi
else
  echo "warning: herdr not on PATH; skipped 'herdr config check' and reload" >&2
  echo "applied herdr attention settings to $CONFIG_PATH (backup: $backup)"
  exit 0
fi

echo "applied herdr attention settings to $CONFIG_PATH"
echo "backup: $backup"

if [ "$NO_RELOAD" -eq 1 ]; then
  echo "note: --no-reload set; run 'herdr server reload-config' to apply to the running server"
  exit 0
fi

if HERDR_CONFIG_PATH="$CONFIG_PATH" herdr server reload-config >/dev/null 2>&1; then
  echo "reloaded the running Herdr server"
else
  echo "note: 'herdr server reload-config' did not succeed (no running server?); the file is written and will apply on next start"
fi
exit 0
