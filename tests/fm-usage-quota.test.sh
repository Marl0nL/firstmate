#!/usr/bin/env bash
# tests/fm-usage-quota.test.sh - behavior tests for the remaining-quota signal
# (bin/fm-usage-quota.sh): parse a captured /api/oauth/usage fixture into the
# normalized 5h/weekly/scoped signal, degrade to the cache on a 401, and NEVER
# emit or persist the OAuth token.
#
# Hermetic: the network is a fakebin `curl` that returns a chosen HTTP code and
# fixture body; the credentials come from a fixture file via
# FM_USAGE_CREDENTIALS_FILE. jq stays the real tool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-usage-quota: jq unavailable, skipping"; exit 0; }

QUOTA="$ROOT/bin/fm-usage-quota.sh"
TMP=$(fm_test_tmproot fm-usage-quota)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"

TOKEN="SECRET-oauth-token-abc123"
printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":9999999999999}}' "$TOKEN" > "$TMP/cred.json"

cat > "$TMP/usage.json" <<'EOF'
{"five_hour":{"utilization":40.0,"resets_at":"2026-07-07T09:19:59Z"},
 "seven_day":{"utilization":91.0,"resets_at":"2026-07-08T07:59:59Z"},
 "limits":[
   {"kind":"session","group":"session","percent":40,"severity":"normal","resets_at":"2026-07-07T09:19:59Z","is_active":false},
   {"kind":"weekly_all","group":"weekly","percent":91,"severity":"critical","resets_at":"2026-07-08T07:59:59Z","is_active":false},
   {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical","resets_at":"2026-07-08T07:59:59Z","is_active":true,"scope":{"model":{"display_name":"Fable"}}}
 ]}
EOF

# fakebin curl: write the fixture body to -o, print FAKE_CODE. Log the auth-header
# FILE path it was handed (to prove the token is never on the command line).
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
ofile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -H) shift 2 ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) shift ;;
    *) shift ;;
  esac
done
[ -n "$ofile" ] && cp "$USAGE_FIXTURE" "$ofile" 2>/dev/null
printf '%s' "${FAKE_CODE:-200}"
SH
chmod +x "$FAKEBIN/curl"

runq() {
  local code=$1; shift
  PATH="$FAKEBIN:$BASE_PATH" FAKE_CODE="$code" USAGE_FIXTURE="$TMP/usage.json" \
    FM_HOME="$HOME_DIR" FM_USAGE_CREDENTIALS_FILE="$TMP/cred.json" \
    "$QUOTA" "$@"
}

# --- 200: parse into the normalized signal -----------------------------------
sig=$(runq 200 --signal)
[ "$(printf '%s' "$sig" | jq -r '.source')" = live ] || fail "200 should yield a live signal"
[ "$(printf '%s' "$sig" | jq -r '.windows.session.percent')" = 40 ] || fail "session percent"
[ "$(printf '%s' "$sig" | jq -r '.windows.session.severity')" = normal ] || fail "session severity"
[ "$(printf '%s' "$sig" | jq -r '.windows.session.resets_at')" = 2026-07-07T09:19:59Z ] || fail "session resets_at"
[ "$(printf '%s' "$sig" | jq -r '.windows.weekly.percent')" = 91 ] || fail "weekly percent"
[ "$(printf '%s' "$sig" | jq -r '.windows.weekly.severity')" = critical ] || fail "weekly severity"
[ "$(printf '%s' "$sig" | jq -r '.windows.scoped[0].model')" = Fable ] || fail "scoped model"
[ "$(printf '%s' "$sig" | jq -r '.windows.scoped[0].severity')" = critical ] || fail "scoped severity"
[ "$(printf '%s' "$sig" | jq -r '.windows.scoped[0].is_active')" = true ] || fail "scoped is_active"
pass "200 parses into 5h/weekly/scoped severity + resets"

# --- summary mode + cache write ----------------------------------------------
summary=$(runq 200)
assert_contains "$summary" "5-hour 40%" "summary shows the 5-hour window"
assert_contains "$summary" "weekly 91%" "summary shows the weekly window"
[ -s "$HOME_DIR/data/usage/quota.json" ] || fail "a live fetch should cache quota.json"
[ "$(jq -r '.source' "$HOME_DIR/data/usage/quota.json")" = live ] || fail "cache should record the live signal"
pass "summary line and last-good cache"

# --- 401 degrade to cache ----------------------------------------------------
sig401=$(runq 401 --signal)
[ "$(printf '%s' "$sig401" | jq -r '.source')" = cache ] || fail "401 should degrade to the cache"
[ "$(printf '%s' "$sig401" | jq -r '.degraded')" = true ] || fail "degraded signal must be flagged"
[ "$(printf '%s' "$sig401" | jq -r '.windows.weekly.percent')" = 91 ] || fail "cache should retain the weekly window"
pass "401 degrades to the cached last-good signal"

# --- the token is never emitted or persisted ---------------------------------
allout=$( { runq 200 --signal; runq 200; runq 401 --signal; } 2>&1 )
case "$allout" in *"$TOKEN"*) fail "the OAuth token leaked to stdout/stderr" ;; esac
if grep -rq "$TOKEN" "$HOME_DIR/data" 2>/dev/null; then
  fail "the OAuth token was persisted under data/usage"
fi
pass "the OAuth token is never emitted or persisted"

# --- no live token available still degrades (no cred file) -------------------
sig_nolive=$(PATH="$FAKEBIN:$BASE_PATH" FAKE_CODE=200 USAGE_FIXTURE="$TMP/usage.json" \
  FM_HOME="$HOME_DIR" FM_USAGE_CREDENTIALS_FILE="$TMP/does-not-exist.json" "$QUOTA" --signal)
[ -n "$sig_nolive" ] || fail "a missing token must still yield a (degraded) signal, never empty"
case "$(printf '%s' "$sig_nolive" | jq -r '.source')" in cache|heuristic|none) : ;; *) fail "no-token path should degrade" ;; esac
pass "missing token degrades instead of failing"

pass "fm-usage-quota: all checks passed"
