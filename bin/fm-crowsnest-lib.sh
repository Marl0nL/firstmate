#!/usr/bin/env bash
# Shared config resolution and helpers for the Crowsnest - firstmate's two-way
# bridge to a Google Chat thread via the local-agents-chat backend.
#
# The Crowsnest mirrors X mode's relay pattern (bin/fm-x-lib.sh): a chat message
# becomes a WAKE the one live firstmate session handles on its own turn, never a
# second fleet-aware agent. This file is sourced, never executed. It defines:
#   fmc_env_get <key> <file>   - read one KEY=VALUE from a .env-style file
#   fmc_load_config            - resolve FMC_ON, FMC_AGENT, FMC_ACK, FMC_CLI,
#                                FMC_LA_CONFIG, FMC_PY, FMC_DRY (env wins over the
#                                config file)
#   fmc_enabled                - return 0 when the Crowsnest is opted in
#   fmc_resolve_cli            - print the resolved local-agents(-chat) CLI path,
#                                name-agnostic across the package rename
#   fmc_resolve_python <cli>   - print the interpreter that can import the backend
#   fmc_safe_id <id>           - return 0 when <id> is a safe inbox slug
#   fmc_new_id                 - print a fresh, filesystem-safe chat message id
#   fmc_inbox_dir / fmc_outbox_dir - print the inbox / dry-run outbox dir paths
#   fmc_wire_shim / fmc_unwire_shim - write / remove the watcher check shim
# Callers must have FM_HOME (and FM_ROOT for the shim helpers) set first.
#
# Opt-in is presence-gated exactly like X mode: inert unless config/crowsnest.env
# sets a truthy CROWSNEST_ENABLED, so a home with no Crowsnest config behaves
# exactly as before.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching quotes.
# Prints nothing (and succeeds) when the file or key is absent.
fmc_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

_fmc_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Resolve the local-agents CLI. The package/CLI is being renamed from
# local-agents to local-agents-chat, so prefer the new name, fall back to the
# old, and always honor an explicit override. Prints the resolved path or
# nothing.
fmc_resolve_cli() {
  local override=${1:-}
  if [ -n "$override" ]; then
    command -v "$override" 2>/dev/null || { [ -x "$override" ] && printf '%s' "$override"; }
    return 0
  fi
  command -v local-agents-chat 2>/dev/null && return 0
  command -v local-agents 2>/dev/null && return 0
  return 0
}

# Resolve the interpreter that can import the backend. Prefer an explicit
# override, then the CLI's own shebang interpreter (a pipx/venv python that has
# the package installed), then a plain python3.
fmc_resolve_python() {
  local cli=${1:-} override=${2:-} shebang interp
  if [ -n "$override" ]; then printf '%s' "$override"; return 0; fi
  if [ -n "$cli" ] && [ -r "$cli" ]; then
    shebang=$(head -n1 "$cli" 2>/dev/null)
    case "$shebang" in
      '#!'*)
        interp=${shebang#\#!}
        interp=${interp#"${interp%%[![:space:]]*}"}
        interp=${interp%% *}
        case "$interp" in
          */python*|python*) [ -x "$interp" ] && { printf '%s' "$interp"; return 0; } ;;
        esac
        ;;
    esac
  fi
  command -v python3 2>/dev/null && return 0
  command -v python 2>/dev/null && return 0
  return 0
}

# Resolve every Crowsnest setting into FMC_* globals. An explicit environment
# variable always wins over the config file so tests and one-off calls can
# override any axis without editing config/crowsnest.env.
fmc_load_config() {
  local cfg enabled
  cfg="${FMC_ENV_FILE:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/crowsnest.env}"
  # shellcheck disable=SC2034 # FMC_CONFIG_FILE is read by callers after sourcing.
  FMC_CONFIG_FILE=$cfg

  if [ -n "${CROWSNEST_ENABLED+x}" ]; then enabled=${CROWSNEST_ENABLED-}; else enabled=$(fmc_env_get CROWSNEST_ENABLED "$cfg"); fi
  if _fmc_truthy "$enabled"; then FMC_ON=1; else FMC_ON=""; fi

  if [ -n "${CROWSNEST_AGENT_NAME+x}" ]; then FMC_AGENT=${CROWSNEST_AGENT_NAME-}; else FMC_AGENT=$(fmc_env_get CROWSNEST_AGENT_NAME "$cfg"); fi
  [ -n "$FMC_AGENT" ] || FMC_AGENT=firstmate

  if [ -n "${CROWSNEST_ACK+x}" ]; then FMC_ACK=${CROWSNEST_ACK-}; else FMC_ACK=$(fmc_env_get CROWSNEST_ACK "$cfg"); fi
  [ -n "$FMC_ACK" ] || FMC_ACK="On it, captain - firstmate is on the bridge and will report back shortly."

  local cli_override
  if [ -n "${CROWSNEST_LA_CLI+x}" ]; then cli_override=${CROWSNEST_LA_CLI-}; else cli_override=$(fmc_env_get CROWSNEST_LA_CLI "$cfg"); fi
  FMC_CLI=$(fmc_resolve_cli "$cli_override")

  # shellcheck disable=SC2034 # FMC_LA_CONFIG is read by callers after sourcing.
  if [ -n "${CROWSNEST_LA_CONFIG+x}" ]; then FMC_LA_CONFIG=${CROWSNEST_LA_CONFIG-}; else FMC_LA_CONFIG=$(fmc_env_get CROWSNEST_LA_CONFIG "$cfg"); fi

  local py_override
  if [ -n "${CROWSNEST_PYTHON+x}" ]; then py_override=${CROWSNEST_PYTHON-}; else py_override=$(fmc_env_get CROWSNEST_PYTHON "$cfg"); fi
  # shellcheck disable=SC2034 # FMC_PY is read by callers after sourcing.
  FMC_PY=$(fmc_resolve_python "$FMC_CLI" "$py_override")

  local dry
  if [ -n "${CROWSNEST_DRY_RUN+x}" ]; then dry=${CROWSNEST_DRY_RUN-}; else dry=$(fmc_env_get CROWSNEST_DRY_RUN "$cfg"); fi
  # shellcheck disable=SC2034 # FMC_DRY is read by callers after sourcing.
  if _fmc_truthy "$dry"; then FMC_DRY=1; else FMC_DRY=""; fi

  # Thread-context enrichment is ON by default; a falsey CROWSNEST_THREAD_CONTEXT
  # is the kill switch that reverts the relay to text-only stashing.
  local ctx
  if [ -n "${CROWSNEST_THREAD_CONTEXT+x}" ]; then ctx=${CROWSNEST_THREAD_CONTEXT-}; else ctx=$(fmc_env_get CROWSNEST_THREAD_CONTEXT "$cfg"); fi
  # shellcheck disable=SC2034 # FMC_CONTEXT is read by callers after sourcing.
  if [ -z "$ctx" ] || _fmc_truthy "$ctx"; then FMC_CONTEXT=1; else FMC_CONTEXT=""; fi
}

fmc_enabled() {
  [ -n "${FMC_ON:-}" ]
}

# A safe inbox slug: no path separators, no leading dot, only [A-Za-z0-9._-].
fmc_safe_id() {
  case "${1:-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# A fresh, monotonic-ish, filesystem-safe id. Combines epoch, pid, and a random
# suffix so two messages in the same second never collide.
fmc_new_id() {
  local epoch rand
  epoch=$(date +%s 2>/dev/null || echo 0)
  rand=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$rand" ] || rand="$$${RANDOM:-0}"
  printf 'chat-%s-%s' "$epoch" "$rand"
}

fmc_inbox_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/chat-inbox"
}

fmc_outbox_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/chat-outbox"
}

# Write the watcher check shim state/chat-watch.check.sh. The watcher runs it
# each check cycle; its stdout becomes a check: wake. Idempotent - only rewrites
# when the body changes. Needs FM_ROOT (for the poll script) and FM_HOME (baked
# into the shim so it resolves the right home's inbox). Returns non-zero on a
# write failure.
fmc_wire_shim() {
  local state shim body
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  shim="$state/chat-watch.check.sh"
  mkdir -p "$state" 2>/dev/null || return 1
  body=$(cat <<EOF
#!/usr/bin/env bash
# Auto-generated - Crowsnest chat relay poll shim.
# The watcher runs this each check cycle; output becomes a check: wake.
export FM_HOME=$(printf '%q' "$FM_HOME")
exec $(printf '%q' "$FM_ROOT/bin/fm-crowsnest-poll.sh")
EOF
)
  if [ -f "$shim" ] && [ "$(cat "$shim" 2>/dev/null)" = "$body" ]; then
    chmod +x "$shim" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$body" > "$shim" || return 1
  chmod +x "$shim" 2>/dev/null || true
}

# Remove the watcher check shim. Returns 0 when it is gone afterwards.
fmc_unwire_shim() {
  local state shim
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  shim="$state/chat-watch.check.sh"
  rm -f "$shim" 2>/dev/null || true
  [ ! -e "$shim" ]
}
