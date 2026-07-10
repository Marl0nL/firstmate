#!/usr/bin/env bash
# Crowsnest operator lifecycle CLI: turn firstmate's two-way Google Chat bridge
# on or off, register/unregister the `firstmate` agent with the local-agents-chat
# backend, inspect state, and (best-effort) autostart the backend.
#
# Subcommands:
#   enable [--autostart]   ensure config/crowsnest.env is on, wire the watcher
#                          check shim, and register the agent (and, with
#                          --autostart, start the backend if it is not running)
#   disable                turn config off, unwire the shim, unregister the agent
#   register               (re)register the agent with the resolved relay command
#   unregister             remove the registered agent
#   autostart              start the backend if it is not already running
#   status                 print resolved config and live state
#
# All state-changing work is scoped to THIS firstmate home ($FM_HOME). The
# registered relay command bakes in this home so the backend's subprocess writes
# to the right inbox even though it runs from the backend's own working directory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_ROOT FM_HOME STATE
# shellcheck source=bin/fm-crowsnest-lib.sh
. "$SCRIPT_DIR/fm-crowsnest-lib.sh"

CONFIG_FILE="$CONFIG/crowsnest.env"

usage() {
  cat >&2 <<'EOF'
usage: fm-crowsnest.sh <enable [--autostart] | disable | register | unregister | autostart | status>
EOF
}

# Set KEY=VALUE in the config file, replacing an existing assignment or appending.
set_config_key() {
  local key=$1 value=$2 tmp
  mkdir -p "$CONFIG" 2>/dev/null || return 1
  [ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"
  tmp=$(mktemp "$CONFIG/.crowsnest.env.XXXXXX") || return 1
  if ! { grep -vE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$CONFIG_FILE" 2>/dev/null || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
}

relay_command() {
  # One shell-style string local-agents shlex-splits into argv. The relay reads
  # the message from stdin and LOCAL_AGENTS_* env; no placeholders needed.
  printf 'env FM_HOME=%s %s' "$FM_HOME" "$FM_ROOT/bin/fm-crowsnest-relay.sh"
}

require_cli() {
  fmc_load_config
  if [ -z "${FMC_CLI:-}" ]; then
    echo "fm-crowsnest: no local-agents(-chat) CLI on PATH; set CROWSNEST_LA_CLI in $CONFIG_FILE" >&2
    return 1
  fi
}

cli_config_args() {
  [ -n "${FMC_LA_CONFIG:-}" ] && printf '%s\0%s\0' --config "$FMC_LA_CONFIG"
}

do_register() {
  require_cli || return 1
  local desc cmd
  desc="Firstmate - reaches the live firstmate session; acknowledges immediately and replies asynchronously from live fleet state."
  cmd=$(relay_command)
  local -a extra=()
  while IFS= read -r -d '' a; do extra+=("$a"); done < <(cli_config_args)
  if "$FMC_CLI" "${extra[@]}" register \
      --name "$FMC_AGENT" \
      --description "$desc" \
      --command "$cmd"; then
    echo "crowsnest: registered '$FMC_AGENT' with $FMC_CLI"
  else
    echo "fm-crowsnest: registration failed" >&2
    return 1
  fi
}

do_unregister() {
  require_cli || return 1
  local -a extra=()
  while IFS= read -r -d '' a; do extra+=("$a"); done < <(cli_config_args)
  if "$FMC_CLI" "${extra[@]}" unregister --name "$FMC_AGENT"; then
    echo "crowsnest: unregistered '$FMC_AGENT'"
  else
    echo "fm-crowsnest: unregister failed (was it registered?)" >&2
    return 1
  fi
}

backend_running() {
  # Match a running local-agents(-chat) backend whose argv carries the `run`
  # subcommand, tolerating an interposed `--config <path>` between the CLI and
  # `run`. POSIX ERE only (no GNU-only \b): ` run` must be a separate arg,
  # bounded by whitespace or end-of-string, so it works on BSD/macOS pgrep too.
  pgrep -f 'local[-_]agents(-chat)?.*[[:space:]]run([[:space:]]|$)' >/dev/null 2>&1
}

do_autostart() {
  require_cli || return 1
  if backend_running; then
    echo "crowsnest: backend already running"
    return 0
  fi
  local log="$STATE/chat-backend.log"
  mkdir -p "$STATE" 2>/dev/null || true
  local -a extra=()
  while IFS= read -r -d '' a; do extra+=("$a"); done < <(cli_config_args)
  echo "crowsnest: starting backend: $FMC_CLI ${extra[*]} run (log: $log)"
  nohup "$FMC_CLI" "${extra[@]}" run >>"$log" 2>&1 &
  local pid=$!
  # Give it a moment to fail fast (missing cloud extra / GCP config).
  sleep 1
  if kill -0 "$pid" 2>/dev/null && backend_running; then
    echo "crowsnest: backend started (pid $pid)"
    return 0
  fi
  echo "fm-crowsnest: backend did not stay up; last log lines:" >&2
  tail -n 15 "$log" >&2 2>/dev/null || true
  echo "fm-crowsnest: the backend needs the local-agents 'cloud' extra and GCP setup (see its INSTALL guide)" >&2
  return 1
}

do_enable() {
  local autostart=0
  case "${1:-}" in --autostart) autostart=1 ;; esac
  set_config_key CROWSNEST_ENABLED 1 || { echo "fm-crowsnest: could not write $CONFIG_FILE" >&2; return 1; }
  fmc_load_config
  fmc_wire_shim || { echo "fm-crowsnest: could not wire the watcher check shim" >&2; return 1; }
  echo "crowsnest: enabled; check shim at $STATE/chat-watch.check.sh"
  do_register || echo "fm-crowsnest: enabled but registration failed; fix the CLI and rerun 'fm-crowsnest.sh register'" >&2
  if [ "$autostart" -eq 1 ]; then
    do_autostart || true
  fi
}

do_disable() {
  set_config_key CROWSNEST_ENABLED 0 || echo "fm-crowsnest: could not update $CONFIG_FILE" >&2
  fmc_load_config
  fmc_unwire_shim && echo "crowsnest: disabled; removed the watcher check shim" \
    || echo "fm-crowsnest: could not remove the check shim" >&2
  do_unregister || true
}

do_status() {
  fmc_load_config
  echo "Crowsnest status (home: $FM_HOME)"
  echo "  enabled        : $([ -n "${FMC_ON:-}" ] && echo yes || echo no)"
  echo "  config file    : $CONFIG_FILE $([ -f "$CONFIG_FILE" ] && echo '(present)' || echo '(absent)')"
  echo "  agent name     : $FMC_AGENT"
  echo "  local-agents   : ${FMC_CLI:-<not found>}"
  echo "  python         : ${FMC_PY:-<not found>}"
  echo "  la config      : ${FMC_LA_CONFIG:-<default>}"
  echo "  check shim     : $([ -f "$STATE/chat-watch.check.sh" ] && echo present || echo absent)"
  local n=0
  [ -d "$(fmc_inbox_dir)" ] && n=$(find "$(fmc_inbox_dir)" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "  pending inbox  : $n"
  if backend_running; then echo "  backend        : running"; else echo "  backend        : not running"; fi
  if [ -n "${FMC_CLI:-}" ]; then
    local -a extra=()
    while IFS= read -r -d '' a; do extra+=("$a"); done < <(cli_config_args)
    if "$FMC_CLI" "${extra[@]}" agents 2>/dev/null | grep -qiE "^${FMC_AGENT}[[:space:]].*registered"; then
      echo "  registered     : yes"
    else
      echo "  registered     : no"
    fi
  fi
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  enable) do_enable "$@" ;;
  disable) do_disable ;;
  register) do_register ;;
  unregister) do_unregister ;;
  autostart) require_cli && do_autostart ;;
  status) do_status ;;
  ''|--help|-h) usage; [ "$cmd" = "" ] && exit 2 || exit 0 ;;
  *) echo "fm-crowsnest: unknown subcommand: $cmd" >&2; usage; exit 2 ;;
esac
