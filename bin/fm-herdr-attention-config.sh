#!/usr/bin/env bash
# fm-herdr-attention-config.sh - apply firstmate's managed Herdr GLOBAL config
# keys. It is the single owner of firstmate's edits to the captain's global Herdr
# config, so one guarded backup/validate/reload mechanism covers them all rather
# than competing editors of one file. It touches EXACTLY these four keys and
# nothing else, in two groups with distinct authorities:
#
#   Attention view (captain-consented; Track U phase U3, see
#   docs/verification/runtime-backends.md "Agent-state publishing (U3)" and the
#   captain's scoped consent in data/decisions/herdr-integration-decisions-2026-08-24.md).
#   These make Herdr's own agent panel a fleet-wide attention view for
#   firstmate's report-agent state publishing:
#     [ui]        agent_panel_sort = "priority"   # attention-sorted agent panel
#     [ui.toast]  delivery         = "herdr"      # in-app toasts on state change
#     [ui.sound]  enabled          = true         # background-space state sounds
#
#   Restart safety (fix for the fleet-wide silent stall after a host restart; see
#   docs/herdr-backend.md "Restart and liveness behavior"). Disabling Herdr's
#   resume-on-restart makes a restored Claude pane come back as a plain shell -
#   the existing dead-mate relaunch path - instead of a live process Herdr resumed
#   WITHOUT firstmate's launch flags, which would freeze in manual permission mode.
#   This is beneficial for every managed pane and the captain's own, and is fully
#   reversible (remove the key or set it true):
#     [session]   resume_agents_on_restore = false  # no flag-less agent resume
#
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
#   apply        (default) back up if needed, apply the four managed keys,
#                validate, reload the running server. --no-reload skips the reload
#                (edit and validate only - used by tests and by hosts with no
#                running server). A no-op run reports "already applied" and
#                reloads nothing.
#   check        report whether the four managed keys are already applied; make no
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
      sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
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
# ever sets the four managed keys and preserves every other line verbatim.
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
      echo "firstmate-managed Herdr settings: already applied ($CONFIG_PATH)"
      exit 0
    fi
    echo "firstmate-managed Herdr settings already applied; nothing to do ($CONFIG_PATH)"
    exit 0
    ;;
  0) ;;
  *)
    echo "error: could not compute the Herdr config edit (see above)" >&2
    exit 1
    ;;
esac

if [ "$CMD" = check ]; then
  echo "firstmate-managed Herdr settings: NOT applied - run 'apply' ($CONFIG_PATH)"
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
  echo "applied firstmate-managed Herdr settings to $CONFIG_PATH (backup: $backup)"
  exit 0
fi

echo "applied firstmate-managed Herdr settings to $CONFIG_PATH"
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
