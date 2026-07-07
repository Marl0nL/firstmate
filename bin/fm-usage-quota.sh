#!/usr/bin/env bash
# Fetch the remaining-quota signal and normalize it for the guard and the poll.
#
# Primary source: GET https://api.anthropic.com/api/oauth/usage with the OAuth
# access token read fresh from ~/.claude/.credentials.json and the required
# header "anthropic-beta: oauth-2025-04-20". This is the same call Claude Code's
# interactive /usage view makes; it is undocumented/best-effort, so every field
# is parsed defensively and any failure degrades rather than erroring out.
#
# Degrade chain: live 200 -> cached data/usage/quota.json (trusted only while
# within FM_USAGE_QUOTA_TTL seconds of its fetched_at) -> a ledger-derived
# burn-rate heuristic. The 5-hour window is the captain's primary gate.
#
# Usage:
#   fm-usage-quota.sh            print a one-line human summary (session-start,
#                                manual use)
#   fm-usage-quota.sh --signal   print the normalized signal JSON (guard/poll)
#
# PRIVACY: the token is read fresh, passed only via a 0600 temp auth-header file
# into curl, and is NEVER written to a log, the cache, the ledger, or stdout.
# The wire format and the normalized schema are documented in docs/usage-monitor.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-usage-lib.sh
. "$SCRIPT_DIR/fm-usage-lib.sh"

MODE=summary
for arg in "$@"; do
  case "$arg" in
    --signal) MODE=signal ;;
    *) : ;;
  esac
done

USAGE_URL="${FM_USAGE_QUOTA_URL:-https://api.anthropic.com/api/oauth/usage}"
BETA_HEADER="${FM_USAGE_QUOTA_BETA:-oauth-2025-04-20}"

now_epoch() { date +%s 2>/dev/null || echo 0; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ''; }

mkdir -p "$FM_USAGE_DIR" 2>/dev/null || true

# Normalize the raw /api/oauth/usage response into the shared signal shape. The
# limits[] array is the cleanest input; kinds map session -> windows.session,
# weekly_all -> windows.weekly, weekly_scoped -> windows.scoped[]. Falls back to
# the top-level five_hour/seven_day objects if limits[] is absent. Missing fields
# default to 0/normal so a schema drift never crashes the parse.
normalize_raw() {
  local raw_file=$1 source=$2 degraded=$3 fetched=$4
  jq -c \
    --arg source "$source" --argjson degraded "$degraded" --arg fetched "$fetched" '
    def win(o): {
      percent: (o.percent // o.utilization // 0),
      severity: (o.severity // "normal"),
      resets_at: (o.resets_at // "")
    };
    (.limits // []) as $lim
    | ($lim | map(select(.kind == "session"))     | .[0]) as $s
    | ($lim | map(select(.kind == "weekly_all"))  | .[0]) as $w
    | ($lim | map(select(.kind == "weekly_scoped"))) as $sc
    | {
        source: $source,
        degraded: $degraded,
        fetched_at: $fetched,
        windows: {
          session: (if $s != null then win($s) else win(.five_hour // {}) end),
          weekly:  (if $w != null then win($w) else win(.seven_day // {}) end),
          scoped: [ $sc[] | {
            model: (.scope.model.display_name // .scope.model.model // "unknown"),
            percent: (.percent // 0),
            severity: (.severity // "normal"),
            is_active: (.is_active // false),
            resets_at: (.resets_at // "")
          } ]
        }
      }
  ' "$raw_file" 2>/dev/null
}

# Derive an approximate signal from ledger.jsonl alone when the endpoint is
# unreachable. Sums weighted tokens over fixed trailing 5h and 7d rolling windows
# against a conservative, configurable ceiling; percent is explicitly ESTIMATED.
# resets_at is left empty because the true window anchor is server-side and
# unknown offline.
heuristic_signal() {
  local now fetched hw c5 cw
  now=$(now_epoch); fetched=$(now_iso)
  hw=$(fm_usage_high_water)
  c5=$(fm_usage_config FM_USAGE_EST_5H_CEILING 40000000)
  cw=$(fm_usage_config FM_USAGE_EST_WEEKLY_CEILING 400000000)
  case "$c5" in ''|*[!0-9]*) c5=40000000 ;; esac
  case "$cw" in ''|*[!0-9]*) cw=400000000 ;; esac
  [ "$c5" -ge 1 ] 2>/dev/null || c5=40000000
  [ "$cw" -ge 1 ] 2>/dev/null || cw=400000000
  if [ ! -s "$FM_USAGE_LEDGER" ]; then
    jq -cn --arg fetched "$fetched" '{source:"heuristic",degraded:true,fetched_at:$fetched,
      windows:{session:{percent:0,severity:"normal",resets_at:""},
               weekly:{percent:0,severity:"normal",resets_at:""},scoped:[]}}'
    return 0
  fi
  jq -cs \
    --argjson now "$now" --arg fetched "$fetched" --argjson hw "$hw" \
    --argjson c5 "$c5" --argjson cw "$cw" \
    --argjson wi "$(fm_usage_weight input)" --argjson wo "$(fm_usage_weight output)" \
    --argjson wcc "$(fm_usage_weight cache_creation)" --argjson wcr "$(fm_usage_weight cache_read)" '
    def epoch: (. // "") | sub("\\.[0-9]+";"") | (try fromdateiso8601 catch 0);
    def weight(r): (r.input_tokens*$wi) + (r.output_tokens*$wo)
                 + (r.cache_creation_input_tokens*$wcc) + (r.cache_read_input_tokens*$wcr);
    def sev(p): if p >= 100 then "critical" elif p >= $hw then "warning" else "normal" end;
    map(. + {e: (.ts|epoch)}) as $rows
    | ($now - 18000) as $t5
    | ($now - 604800) as $tw
    | ([$rows[] | select(.e >= $t5) | weight(.)] | add // 0) as $sum5
    | ([$rows[] | select(.e >= $tw) | weight(.)] | add // 0) as $sumw
    | (($sum5 / $c5) * 100 | floor) as $p5raw
    | (($sumw / $cw) * 100 | floor) as $pwraw
    | (if $p5raw > 100 then 100 else $p5raw end) as $p5
    | (if $pwraw > 100 then 100 else $pwraw end) as $pw
    | {source:"heuristic",degraded:true,fetched_at:$fetched,
       windows:{
         session:{percent:$p5,severity:sev($p5),resets_at:""},
         weekly:{percent:$pw,severity:sev($pw),resets_at:""},
         scoped:[]}}
  ' "$FM_USAGE_LEDGER" 2>/dev/null
}

# Resolve the freshest signal. On success also refreshes the quota.json cache.
resolve_signal() {
  local token body code auth_file signal ttl now cache_epoch
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
     && token=$(fm_usage_oauth_token); then
    body=$(mktemp "${TMPDIR:-/tmp}/fm-usage-quota.XXXXXX") || body=
    auth_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-usage-auth.XXXXXX") || auth_file=
    # Guarantee the token-bearing 0600 temp (and the body temp) are removed even
    # if the process is interrupted between the token write and the explicit rm.
    trap 'rm -f "${body:-}" "${auth_file:-}" 2>/dev/null' EXIT
    trap 'exit 143' HUP INT TERM
    if [ -n "$body" ] && [ -n "$auth_file" ]; then
      # Token lives only in this 0600 header file, never on a command line.
      printf 'Authorization: Bearer %s\n' "$token" > "$auth_file" 2>/dev/null
      chmod 600 "$auth_file" 2>/dev/null || true
      code=$(curl -m 8 -s -o "$body" -w '%{http_code}' \
        -H "@$auth_file" \
        -H "anthropic-beta: $BETA_HEADER" \
        -H 'Accept: application/json' \
        "$USAGE_URL" 2>/dev/null) || code=000
      rm -f "$auth_file"
      unset token
      if [ "$code" = 200 ] && [ -s "$body" ]; then
        signal=$(normalize_raw "$body" live false "$(now_iso)")
        rm -f "$body"
        if [ -n "$signal" ]; then
          if printf '%s\n' "$signal" > "$FM_USAGE_QUOTA_CACHE.tmp" 2>/dev/null; then
            mv -f "$FM_USAGE_QUOTA_CACHE.tmp" "$FM_USAGE_QUOTA_CACHE" 2>/dev/null || rm -f "$FM_USAGE_QUOTA_CACHE.tmp"
          else
            rm -f "$FM_USAGE_QUOTA_CACHE.tmp"
          fi
          printf '%s' "$signal"
          return 0
        fi
      fi
      rm -f "$body" 2>/dev/null || true
    fi
    if [ -n "${auth_file:-}" ]; then rm -f "$auth_file" 2>/dev/null || true; fi
  fi
  # Live failed (or no token): degrade to the cached signal, but only while it is
  # still within the TTL (live -> cached<=TTL -> heuristic). Mark it degraded.
  if [ -s "$FM_USAGE_QUOTA_CACHE" ] && command -v jq >/dev/null 2>&1; then
    ttl=$(fm_usage_quota_ttl)
    now=$(now_epoch)
    cache_epoch=$(jq -r '
      (.fetched_at // "") | sub("\\.[0-9]+";"") | (try fromdateiso8601 catch 0)
    ' "$FM_USAGE_QUOTA_CACHE" 2>/dev/null) || cache_epoch=0
    case "$cache_epoch" in ''|*[!0-9]*) cache_epoch=0 ;; esac
    if [ "$cache_epoch" -gt 0 ] 2>/dev/null && [ "$((now - cache_epoch))" -le "$ttl" ] 2>/dev/null; then
      signal=$(jq -c '.source="cache" | .degraded=true' "$FM_USAGE_QUOTA_CACHE" 2>/dev/null)
      if [ -n "$signal" ]; then
        printf '%s' "$signal"
        return 0
      fi
    fi
  fi
  # No fresh cache (absent, older than the TTL, or unparseable fetched_at): fall
  # back to the ledger burn-rate heuristic.
  heuristic_signal
}

SIGNAL=$(resolve_signal)
[ -n "$SIGNAL" ] || SIGNAL='{"source":"none","degraded":true,"fetched_at":"","windows":{"session":{"percent":0,"severity":"normal","resets_at":""},"weekly":{"percent":0,"severity":"normal","resets_at":""},"scoped":[]}}'

if [ "$MODE" = signal ]; then
  printf '%s\n' "$SIGNAL"
  exit 0
fi

# Human one-line summary for the session-start digest and manual use.
printf '%s\n' "$SIGNAL" | jq -r '
  def tag: if .degraded then " (estimated)" else "" end;
  "5-hour \(.windows.session.percent)%\(if .windows.session.resets_at != "" then " (resets \(.windows.session.resets_at))" else "" end)"
  + ", weekly \(.windows.weekly.percent)%\(if .windows.weekly.resets_at != "" then " (resets \(.windows.weekly.resets_at))" else "" end)"
  + ( (.windows.scoped // []) | map(select(.is_active)) | if length>0 then "; per-model: " + ( map("\(.model) \(.percent)%") | join(", ") ) else "" end )
  + (. | tag)
' 2>/dev/null || printf 'quota signal unavailable\n'
exit 0
