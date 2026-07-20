#!/usr/bin/env bash
# fm-claude-shim.sh - a fail-open `claude` launcher shim for the firstmate pane.
#
# WHY THIS EXISTS
# When the herdr server crashes and restarts, it re-runs the firstmate pane's
# command as a bare `claude --resume <session-id>`, dropping the launch flags
# firstmate was originally started with. The resumed primary session therefore
# comes back WITHOUT --dangerously-skip-permissions (so it stalls on the first
# permission prompt with no human at the keyboard) and, on a truly fresh
# relaunch, without --remote-control (so it is not remote-reachable). This shim
# is installed as the user's `claude` on PATH and re-adds exactly those two
# flags, but ONLY for the firstmate primary session.
#
# THE ONE RULE: FAIL OPEN.
# Every uncertainty resolves to "exec the real claude with the original
# arguments, untouched". The worst outcome this shim may produce is the flag not
# being added - which is today's behaviour, and merely leaves the gap open. It
# must never be able to break an ordinary `claude` launch, for any user, in any
# directory. Nothing here parses the user's arguments beyond a read-only
# membership test, and nothing here ever removes or rewrites an argument.
#
# INSTALLATION IS THE CAPTAIN'S STEP, NOT THIS SCRIPT'S.
# This script never touches ~/.local/bin/claude or ~/.local/share/claude. See
# docs/claude-resume-shim.md for the install, rollback, and verification steps.
#
# RESOLVING THE REAL BINARY (never a hardcoded version path).
# `claude` auto-updates by rewriting ~/.local/bin/claude to point at a new file
# under ~/.local/share/claude/versions/<version>, so any path captured once goes
# stale at the next update. Resolution order:
#   1. $FM_CLAUDE_SHIM_REAL          explicit override (also the test hook)
#   2. newest entry in versions_dir  tracks auto-update; the normal path
#   3. real= from the config file    a preserved original launcher, for
#                                    non-standard installs
#   4. the first other `claude` on PATH that is not this shim
# A resolved candidate must be an executable file that is not this shim itself,
# so the shim can never exec into a loop.
#
# WHEN THE FLAGS ARE INJECTED - all of these must hold:
#   - the shim is not disabled by $FM_CLAUDE_SHIM_DISABLE
#   - the launch is the firstmate primary session: either $FM_CLAUDE_SHIM_PRIMARY
#     is truthy, or the physical cwd is exactly the configured home= directory
#     (an exact match, never a subdirectory) and that directory still looks like
#     a firstmate checkout
#   - the launch is interactive-shaped: no arguments at all, or a first argument
#     that begins with '-'. A leading positional is a prompt or a subcommand
#     (`claude mcp ...`, `claude update`), and those pass through untouched.
#   - --print/-p is absent, so a one-shot non-interactive run is never made
#     remote-controlled, and --version/--help are absent, so an informational
#     launch stays byte-identical to an unshimmed one
# Injection is idempotent: a flag already present in the arguments, in either
# `--flag` or `--flag=value` form, is never added a second time.
#
# Config file: ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/claude-shim.conf
# (override with $FM_CLAUDE_SHIM_CONF). Recognised keys - see the doc for the
# generated form:
#   home=<firstmate primary checkout>   enables cwd-based primary detection
#   real=<path to the real claude>      fallback for a non-standard install
#   versions_dir=<dir>                  default ~/.local/share/claude/versions
# An absent, unreadable, or partly invalid config is not an error; it only means
# less is known, and less known means less injected.
#
# Usage: install as `claude` on PATH; all arguments, stdin, and the tty pass
# through, and the real claude's exit status is preserved via exec.
#   fm-claude-shim.sh --fm-shim-explain   print the resolved decision and exit
#                                          (diagnostic only; execs nothing)
#
# Deliberately NOT `set -e`: an unexpected non-zero from any check here must
# degrade to pass-through, never abort the launch.
set -u

fm_shim_self() {
  # Physical path of this script, used only to refuse exec'ing into ourselves.
  local dir
  dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename -- "${BASH_SOURCE[0]}")"
}

SELF=$(fm_shim_self 2>/dev/null || true)

# Resolve a path to its physical target when possible, so a shim reached through
# a symlink still compares equal to itself.
fm_shim_realpath() {
  local p=$1
  [ -n "$p" ] || return 1
  if command -v readlink >/dev/null 2>&1; then
    local r
    r=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  fi
  printf '%s\n' "$p"
}

SELF_REAL=$(fm_shim_realpath "$SELF" 2>/dev/null || true)

# A usable candidate is an executable regular file that is not this shim.
fm_shim_usable() {
  local cand=$1 cand_real
  [ -n "$cand" ] || return 1
  [ -f "$cand" ] && [ -x "$cand" ] || return 1
  cand_real=$(fm_shim_realpath "$cand" 2>/dev/null || printf '%s' "$cand")
  [ -n "$SELF_REAL" ] && [ "$cand_real" = "$SELF_REAL" ] && return 1
  [ "$cand_real" = "$SELF" ] && return 1
  return 0
}

# Expand a leading ~/ in a config value; everything else is taken literally.
fm_shim_expand() {
  local v=$1 rest
  rest=${v#\~/}
  if [ "$rest" != "$v" ]; then
    printf '%s/%s\n' "$HOME" "$rest"
  else
    printf '%s\n' "$v"
  fi
}

# --- config -----------------------------------------------------------------

CONF=${FM_CLAUDE_SHIM_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/claude-shim.conf}
CONF_HOME=""
CONF_REAL=""
CONF_VERSIONS_DIR=""

if [ -f "$CONF" ] && [ -r "$CONF" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '#'*|'') continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    [ "$key" != "$line" ] || continue
    # Trim surrounding whitespace from the key so `home = x` still parses.
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%"${val##*[![:space:]]}"}
    case "$key" in
      home) CONF_HOME=$(fm_shim_expand "$val") ;;
      real) CONF_REAL=$(fm_shim_expand "$val") ;;
      versions_dir) CONF_VERSIONS_DIR=$(fm_shim_expand "$val") ;;
      *) : ;;
    esac
  done < "$CONF"
fi

VERSIONS_DIR=${CONF_VERSIONS_DIR:-$HOME/.local/share/claude/versions}

# --- resolve the real claude ------------------------------------------------

# Newest installed version, tracking auto-update. Prefer a version sort over the
# entry names; fall back to modification time where `sort -V` is unavailable.
fm_shim_newest_version() {
  local dir=$1 newest="" cand
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  if printf '1\n2\n' | sort -V >/dev/null 2>&1; then
    while IFS= read -r cand; do
      fm_shim_usable "$cand" && newest=$cand
    done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort -V)
  else
    while IFS= read -r cand; do
      if fm_shim_usable "$cand"; then
        if [ -z "$newest" ] || [ "$cand" -nt "$newest" ]; then
          newest=$cand
        fi
      fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
  fi
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

# The first `claude` on PATH that is not this shim. Walks PATH by hand because
# `command -v claude` would normally resolve back to the installed shim.
fm_shim_path_claude() {
  local entry cand
  local -a dirs=()
  IFS=: read -r -a dirs <<< "$PATH"
  for entry in ${dirs[@]+"${dirs[@]}"}; do
    [ -n "$entry" ] || entry=.
    cand="$entry/claude"
    if fm_shim_usable "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

fm_shim_resolve_real() {
  local cand
  if [ -n "${FM_CLAUDE_SHIM_REAL:-}" ] && fm_shim_usable "$FM_CLAUDE_SHIM_REAL"; then
    printf '%s\n' "$FM_CLAUDE_SHIM_REAL"
    return 0
  fi
  if cand=$(fm_shim_newest_version "$VERSIONS_DIR" 2>/dev/null) && [ -n "$cand" ]; then
    printf '%s\n' "$cand"
    return 0
  fi
  if [ -n "$CONF_REAL" ] && fm_shim_usable "$CONF_REAL"; then
    printf '%s\n' "$CONF_REAL"
    return 0
  fi
  if cand=$(fm_shim_path_claude 2>/dev/null) && [ -n "$cand" ]; then
    printf '%s\n' "$cand"
    return 0
  fi
  return 1
}

REAL=$(fm_shim_resolve_real 2>/dev/null || true)

# --- is this the firstmate primary session? ---------------------------------

# A directory that still looks like a firstmate checkout. Cheap and structural:
# the shim must not depend on firstmate's runtime state being loadable.
fm_shim_looks_like_firstmate() {
  local dir=$1
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  [ -f "$dir/AGENTS.md" ] || return 1
  [ -d "$dir/bin" ] || return 1
  [ -f "$dir/bin/fm-spawn.sh" ] || return 1
  return 0
}

fm_shim_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

fm_shim_is_primary() {
  fm_shim_truthy "${FM_CLAUDE_SHIM_PRIMARY:-}" && return 0
  local home_real cwd_real
  [ -n "$CONF_HOME" ] || return 1
  fm_shim_looks_like_firstmate "$CONF_HOME" || return 1
  home_real=$(CDPATH='' cd -- "$CONF_HOME" 2>/dev/null && pwd -P) || return 1
  cwd_real=$(pwd -P 2>/dev/null) || return 1
  # Exact match only. A crewmate worktree, a project clone under the home, or
  # any subdirectory is NOT the primary session.
  [ "$cwd_real" = "$home_real" ] || return 1
  return 0
}

# --- is this launch shaped like an interactive session? ---------------------

fm_shim_has_flag() {
  local want=$1 arg
  shift
  for arg in "$@"; do
    [ "$arg" = "$want" ] && return 0
    case "$arg" in
      "$want"=*) return 0 ;;
    esac
  done
  return 1
}

# The argument list itself must look like an interactive launch. A first
# argument that does not begin with '-' is a prompt or a subcommand
# (`claude mcp list`, `claude update`), and --print/-p is a one-shot run; both
# pass through untouched.
fm_shim_interactive_shape() {
  local arg
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -*) : ;;
      *) return 1 ;;
    esac
  fi
  for arg in "$@"; do
    case "$arg" in
      -p|--print|--print=*) return 1 ;;
      # Informational launches exit without starting a session, so there is
      # nothing to make autonomous or reachable. Keeping them untouched also
      # makes `claude --version` a clean post-install smoke test.
      -v|--version|-h|--help) return 1 ;;
    esac
  done
  return 0
}

# --- decide -----------------------------------------------------------------

INJECT=()
DECISION=passthrough

if ! fm_shim_truthy "${FM_CLAUDE_SHIM_DISABLE:-}" \
  && fm_shim_is_primary \
  && fm_shim_interactive_shape "$@"; then
  DECISION=inject
  fm_shim_has_flag --dangerously-skip-permissions "$@" \
    || INJECT+=(--dangerously-skip-permissions)
  # --remote-control takes an OPTIONAL value, so it is injected last of the
  # pair: the token that follows it is either nothing or the caller's first
  # argument, which fm_shim_interactive_shape has already proven begins with
  # '-' and so cannot be swallowed as its value.
  fm_shim_has_flag --remote-control "$@" \
    || INJECT+=(--remote-control)
fi

if [ "${1:-}" = "--fm-shim-explain" ]; then
  # Diagnostic surface for the install verification in
  # docs/claude-resume-shim.md. Execs nothing and changes nothing.
  conf_note=""
  [ -f "$CONF" ] || conf_note=" (absent)"
  printf 'shim:        %s\n' "${SELF:-<unresolved>}"
  printf 'config:      %s%s\n' "$CONF" "$conf_note"
  printf 'home:        %s\n' "${CONF_HOME:-<unset>}"
  printf 'versions:    %s\n' "$VERSIONS_DIR"
  printf 'real:        %s\n' "${REAL:-<unresolved>}"
  printf 'cwd:         %s\n' "$(pwd -P 2>/dev/null || printf '<unknown>')"
  if fm_shim_is_primary; then
    printf 'primary:     yes\n'
  else
    printf 'primary:     no\n'
  fi
  printf 'decision:    %s\n' "$DECISION"
  inject_note=${INJECT[*]+"${INJECT[*]}"}
  printf 'would add:   %s\n' "${inject_note:-<nothing>}"
  exit 0
fi

if [ -z "$REAL" ]; then
  # Nothing to exec. This is the one case the shim cannot paper over, so it
  # reports plainly and exits with the conventional "command not found" status
  # rather than pretending to have launched anything.
  printf 'claude: fm-claude-shim.sh could not resolve the real claude binary.\n' >&2
  printf 'claude: looked at the FM_CLAUDE_SHIM_REAL override, %s, the config real= entry, and PATH.\n' \
    "$VERSIONS_DIR" >&2
  printf 'claude: restore the original launcher - see docs/claude-resume-shim.md (Rollback).\n' >&2
  exit 127
fi

exec "$REAL" ${INJECT[@]+"${INJECT[@]}"} "$@"
