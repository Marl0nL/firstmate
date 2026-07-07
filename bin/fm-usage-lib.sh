#!/usr/bin/env bash
# Shared helpers for the firstmate token-usage monitor: config resolution,
# the ledger/quota data paths, the OAuth-token read, the severity model, and
# the quota-signal decision rule. Sourced by fm-usage-poll.sh, fm-usage-quota.sh,
# fm-usage-guard.sh, and fm-usage-report.sh - never executed directly.
#
# The full statement of the transcript schema, the /api/oauth/usage wire format,
# the requestId-dedup rationale, and the attribution mechanics lives in
# docs/usage-monitor.md; this file owns only the mechanics those docs point at.
#
# It defines:
#   fm_usage_env_get <key> <file>   - read one KEY=VALUE from an env-style file
#   fm_usage_config <key> <default> - env var wins, then config/usage-monitor.env,
#                                     then <default>
#   fm_usage_truthy <val>           - 0 when <val> is a truthy string
#   fm_usage_enabled                - 0 when the master opt-in is truthy
#   fm_usage_guard_enabled          - 0 when the dispatch guard is opted in
#   fm_usage_high_water             - the percent high-water for holds/alerts
#   fm_usage_quota_ttl              - seconds a cached quota.json stays "fresh"
#   fm_usage_weight <class>         - the report weight for a token class
#   fm_usage_slug <abs-path>        - the (forward, lossy) transcript dir slug
#   fm_usage_credentials_file       - the OAuth credentials path
#   fm_usage_oauth_token            - print the fresh access token (never logged)
#   fm_usage_severity_rank <sev>    - map a severity string to 0|1|2
#   fm_usage_signal_level <file>    - the alert level (0|1|2) of a signal JSON
#   fm_usage_decision <file> <model> <priority> <captain> - allow/hold rule
# Callers set FM_HOME (and may set the FM_*_OVERRIDE vars) before sourcing.
set -u

# The path variables below are the module's single source of truth for its data
# layout; several are consumed only by the scripts that source this lib, so they
# read as "unused" here (SC2034) but are deliberately defined once.
_FM_USAGE_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FM_USAGE_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$_FM_USAGE_ROOT}}"
# shellcheck disable=SC2034
FM_USAGE_STATE="${FM_STATE_OVERRIDE:-$FM_USAGE_HOME/state}"
FM_USAGE_DATA="${FM_DATA_OVERRIDE:-$FM_USAGE_HOME/data}"
FM_USAGE_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_USAGE_HOME/config}"
# All ledger/quota state lives under one per-home, gitignored directory.
FM_USAGE_DIR="${FM_USAGE_DIR_OVERRIDE:-$FM_USAGE_DATA/usage}"
# shellcheck disable=SC2034
FM_USAGE_LEDGER="$FM_USAGE_DIR/ledger.jsonl"
# shellcheck disable=SC2034
FM_USAGE_CHECKPOINT="$FM_USAGE_DIR/checkpoint.json"
# shellcheck disable=SC2034
FM_USAGE_ATTRIBUTION="$FM_USAGE_DIR/attribution.json"
# shellcheck disable=SC2034
FM_USAGE_QUOTA_CACHE="$FM_USAGE_DIR/quota.json"
# shellcheck disable=SC2034
FM_USAGE_WATERMARK="$FM_USAGE_DIR/severity-watermark"
# The config knobs live in one sourced-style env file (never executed - parsed
# key by key like the .env), and the transcript tree defaults to the standard
# Claude Code location. Both are override-friendly so tests stay hermetic.
FM_USAGE_CONFIG_FILE="${FM_USAGE_CONFIG_FILE:-$FM_USAGE_CONFIG_DIR/usage-monitor.env}"
FM_USAGE_TRANSCRIPTS_DIR="${FM_USAGE_TRANSCRIPTS_DIR:-$HOME/.claude/projects}"

# Read the value of KEY from an env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching quotes.
# Prints nothing (and succeeds) when the file or key is absent.
fm_usage_env_get() {
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

# Resolve one knob: an explicit environment variable of the same name wins, then
# the config file, then the supplied default.
fm_usage_config() {
  local key=$1 default=${2:-} val
  if [ -n "${!key+x}" ]; then
    printf '%s' "${!key-}"
    return 0
  fi
  val=$(fm_usage_env_get "$key" "$FM_USAGE_CONFIG_FILE")
  if [ -n "$val" ]; then
    printf '%s' "$val"
  else
    printf '%s' "$default"
  fi
}

# 0 (true) when the value reads as truthy; 1 otherwise. Empty/0/false/no/off are
# false, anything else is true.
fm_usage_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Master opt-in: automatic polling, the watcher check shim, and quota wakes are
# all inert unless this is truthy. Default off, so a home that never opts in sees
# zero behavior change (the poll/report can still be run by hand).
fm_usage_enabled() {
  fm_usage_truthy "$(fm_usage_config FM_USAGE_ENABLED 0)"
}

# The dispatch guard is a second, independent opt-in (advisory by default).
fm_usage_guard_enabled() {
  fm_usage_truthy "$(fm_usage_config FM_USAGE_GUARD_ENABLED 0)"
}

# Percent high-water for both the hold decision and the wake threshold; clamped
# to a sane 1..100 integer.
fm_usage_high_water() {
  local hw
  hw=$(fm_usage_config FM_USAGE_HIGH_WATER 80)
  case "$hw" in ''|*[!0-9]*) hw=80 ;; esac
  [ "$hw" -ge 1 ] 2>/dev/null || hw=80
  [ "$hw" -le 100 ] 2>/dev/null || hw=100
  printf '%s' "$hw"
}

# Seconds a cached quota.json is still trusted before it is treated as stale.
fm_usage_quota_ttl() {
  local ttl
  ttl=$(fm_usage_config FM_USAGE_QUOTA_TTL 900)
  case "$ttl" in ''|*[!0-9]*) ttl=900 ;; esac
  printf '%s' "$ttl"
}

# Relative report weight for a token class. The defaults are a rough API-parity
# heuristic for RANKING expensive operations, not the subscription's server-side
# limit accounting (see docs/usage-monitor.md). Weights may be fractional and are
# only ever consumed by jq, so they are returned as strings.
fm_usage_weight() {
  case "$1" in
    input)           fm_usage_config FM_USAGE_WEIGHT_INPUT 1 ;;
    output)          fm_usage_config FM_USAGE_WEIGHT_OUTPUT 5 ;;
    cache_creation)  fm_usage_config FM_USAGE_WEIGHT_CACHE_CREATION 1.25 ;;
    cache_read)      fm_usage_config FM_USAGE_WEIGHT_CACHE_READ 0.1 ;;
    *) printf '0' ;;
  esac
}

# The forward transcript dir-slug: Claude Code maps every '/' and '.' in the
# working dir to '-'. The transform is lossy (both chars collapse to '-'), so it
# is computed FROM a path and never reversed - the ledger keys on each record's
# inline cwd instead. Provided for documentation/backfill symmetry only.
fm_usage_slug() {
  printf '%s' "$1" | tr '/.' '--'
}

# The OAuth credentials file, override-friendly so the quota tests never read the
# operator's real token.
fm_usage_credentials_file() {
  printf '%s' "${FM_USAGE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
}

# Print the fresh OAuth access token read straight from the credentials file.
# Returns non-zero (and prints nothing) when the file, jq, or the token is
# missing. The token is NEVER written to a log, a cache, or the ledger; callers
# pass it only into a curl auth header on a private temp file.
fm_usage_oauth_token() {
  local cred token
  cred=$(fm_usage_credentials_file)
  [ -f "$cred" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null) || return 1
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

# Map a severity string from the /api/oauth/usage limits[] array to a rank:
#   0 normal/ok, 1 warning/elevated, 2 critical. An unrecognized string ranks 0
# so a schema change never over-alerts (the percent high-water still gates).
fm_usage_severity_rank() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    critical|blocked|exceeded) printf '2' ;;
    warning|warn|elevated|high) printf '1' ;;
    *) printf '0' ;;
  esac
}

# The alert level (0|1|2) of a normalized quota-signal JSON file: the max over the
# session window (severity or percent high-water), the weekly window (severity
# only), and any active per-model scoped cap (severity or 100% percent). These
# thresholds mirror fm_usage_decision so the wake never fires without a matching
# hold. Missing fields default to level 0.
fm_usage_signal_level() {
  local file=$1 hw
  [ -f "$file" ] || { printf '0'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0'; return 0; }
  hw=$(fm_usage_high_water)
  jq -r --argjson hw "$hw" '
    def rank(s):
      (s // "" | ascii_downcase) as $s
      | if ($s|test("critical|blocked|exceeded")) then 2
        elif ($s|test("warning|warn|elevated|high")) then 1
        else 0 end;
    def sessionLvl(w):
      if (w == null) then 0
      elif (rank(w.severity) >= 2 or (w.percent // 0) >= 100) then 2
      elif ((w.percent // 0) >= $hw) then 1
      else 0 end;
    def weeklyLvl(w):
      if (w == null) then 0
      elif (rank(w.severity) >= 2) then 2
      else 0 end;
    def scopedLvl(w):
      if (w == null) then 0
      elif (rank(w.severity) >= 2 or (w.percent // 0) >= 100) then 2
      else 0 end;
    ([ sessionLvl(.windows.session),
       weeklyLvl(.windows.weekly),
       ( (.windows.scoped // []) | map(select(.is_active == true) | scopedLvl(.)) | (max // 0) )
     ] | max) // 0
  ' "$file" 2>/dev/null || printf '0'
}

# The advisory hold/allow decision. Prints one line - "allow: <reason>" or
# "hold: <reason with window and resets_at>" - and returns 0 to allow or 3 to
# advise a hold. The guard NEVER hard-blocks: an explicit captain dispatch
# (captain=1) or high-priority work (priority=high) always allows.
#   <file>     normalized quota-signal JSON (may be absent -> allow, no signal)
#   <model>    optional model/display name to match a scoped weekly cap ("" = none)
#   <priority> low|high (default low: the guard is asked about large/low work)
#   <captain>  1 = explicit captain order (always allow)
fm_usage_decision() {
  local file=$1 model=${2:-} priority=${3:-low} captain=${4:-0} hw
  if [ "$captain" = 1 ]; then
    printf 'allow: explicit captain dispatch overrides the quota guard\n'
    return 0
  fi
  if [ "$priority" = high ]; then
    printf 'allow: high-priority work is never held\n'
    return 0
  fi
  if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    printf 'allow: no quota signal available; proceeding\n'
    return 0
  fi
  hw=$(fm_usage_high_water)
  # jq decides; it prints "HOLD\t<reason>" or "ALLOW\t<reason>" so the token is
  # never at risk and the reason carries the binding window and its reset time.
  local out verdict reason
  out=$(jq -r --argjson hw "$hw" --arg model "$model" '
    def rank(s):
      (s // "" | ascii_downcase) as $s
      | if ($s|test("critical|blocked|exceeded")) then 2
        elif ($s|test("warning|warn|elevated|high")) then 1
        else 0 end;
    (.windows.session // {}) as $s5
    | (.windows.weekly // {}) as $sw
    | ( (.windows.scoped // [])
        | map(select(.is_active == true
                     and ($model != "")
                     and ((.model // "") | ascii_downcase) == ($model | ascii_downcase)))
        | .[0] ) as $sc
    | if (rank($s5.severity) >= 2) or (($s5.percent // 0) >= $hw)
        then "HOLD\tthe 5-hour window is at \($s5.percent // 0)%, frees at \($s5.resets_at // "?")"
      elif (rank($sw.severity) >= 2)
        then "HOLD\tthe weekly window is critical at \($sw.percent // 0)%, frees at \($sw.resets_at // "?")"
      elif ($sc != null and (rank($sc.severity) >= 2 or ($sc.percent // 0) >= 100))
        then "HOLD\tthe weekly cap for \($sc.model // $model) is at \($sc.percent // 0)%, frees at \($sc.resets_at // "?")"
      else "ALLOW\tquota headroom is fine (5-hour \($s5.percent // 0)%, weekly \($sw.percent // 0)%)"
      end
  ' "$file" 2>/dev/null) || { printf 'allow: quota signal unreadable; proceeding\n'; return 0; }
  verdict=${out%%$'\t'*}
  reason=${out#*$'\t'}
  if [ "$verdict" = HOLD ]; then
    printf 'hold: %s\n' "$reason"
    return 3
  fi
  printf 'allow: %s\n' "$reason"
  return 0
}
