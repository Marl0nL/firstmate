#!/usr/bin/env bash
# tests/fm-usage-guard.test.sh - behavior tests for the advisory dispatch guard
# (bin/fm-usage-guard.sh): the hold/allow truth table across 5h/weekly/scoped
# severities and the high-water knob, plus the always-allow overrides
# (explicit captain dispatch and high-priority work).
#
# Hermetic: the guard's quota signal is injected via FM_USAGE_QUOTA_CMD, a stub
# that echoes a chosen normalized signal, so no network or credentials are used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-usage-guard: jq unavailable, skipping"; exit 0; }

GUARD="$ROOT/bin/fm-usage-guard.sh"
TMP=$(fm_test_tmproot fm-usage-guard)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

# Build a signal JSON: $1 session-window, $2 weekly-window, $3 scoped-array.
sig() { printf '{"source":"live","degraded":false,"windows":{"session":%s,"weekly":%s,"scoped":%s}}' "$1" "$2" "${3:-[]}"; }

# Write a stub quota command that prints the given signal on `--signal`.
mkcmd() {
  local name=$1 signal=$2 path
  path="$TMP/qc-$name"
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' '$signal'
SH
  chmod +x "$path"
  printf '%s' "$path"
}

# Run the guard against a stub signal; echo "exit=<code> <line>".
guard() {
  local cmd=$1; shift
  local out rc
  out=$(FM_HOME="$HOME_DIR" FM_USAGE_QUOTA_CMD="$cmd" "$GUARD" "$@" 2>&1); rc=$?
  printf '%s|%s' "$rc" "$out"
}
verdict() { printf '%s' "${1%%|*}"; }
line() { printf '%s' "${1#*|}"; }

NORMAL=$(mkcmd normal "$(sig '{"percent":40,"severity":"normal","resets_at":"R5"}' '{"percent":50,"severity":"normal","resets_at":"RW"}')")
S5CRIT=$(mkcmd s5crit "$(sig '{"percent":92,"severity":"critical","resets_at":"09:20"}' '{"percent":50,"severity":"normal"}')")
S5HI=$(mkcmd s5hi "$(sig '{"percent":85,"severity":"normal","resets_at":"R5"}' '{"percent":50,"severity":"normal"}')")
WCRIT=$(mkcmd wcrit "$(sig '{"percent":40,"severity":"normal"}' '{"percent":100,"severity":"critical","resets_at":"RW"}')")
SCOPED=$(mkcmd scoped "$(sig '{"percent":40,"severity":"normal"}' '{"percent":50,"severity":"normal"}' '[{"model":"Fable","percent":100,"severity":"critical","is_active":true,"resets_at":"RS"}]')")

# --- allow when everything is healthy ----------------------------------------
r=$(guard "$NORMAL"); [ "$(verdict "$r")" = 0 ] || fail "healthy quota should allow (got $r)"
assert_contains "$(line "$r")" "allow:" "healthy verdict line"
pass "allow when 5h/weekly are healthy"

# --- hold on 5h critical -----------------------------------------------------
r=$(guard "$S5CRIT"); [ "$(verdict "$r")" = 3 ] || fail "5h critical should hold (got $r)"
assert_contains "$(line "$r")" "5-hour" "hold names the 5-hour window"
assert_contains "$(line "$r")" "09:20" "hold reports the reset time"
pass "hold on 5-hour critical"

# --- hold on weekly critical -------------------------------------------------
r=$(guard "$WCRIT"); [ "$(verdict "$r")" = 3 ] || fail "weekly critical should hold (got $r)"
assert_contains "$(line "$r")" "weekly" "hold names the weekly window"
pass "hold on weekly critical"

# --- per-model scoped cap: holds only for the matching model -----------------
r=$(guard "$SCOPED" --model Fable); [ "$(verdict "$r")" = 3 ] || fail "scoped cap for Fable should hold (got $r)"
assert_contains "$(line "$r")" "Fable" "hold names the capped model"
r=$(guard "$SCOPED" --model Opus); [ "$(verdict "$r")" = 0 ] || fail "scoped cap for Fable must not hold Opus work (got $r)"
r=$(guard "$SCOPED"); [ "$(verdict "$r")" = 0 ] || fail "scoped cap with no --model must not hold (got $r)"
pass "per-model scoped cap holds only the matching model"

# --- high-water knob ---------------------------------------------------------
r=$(FM_HOME="$HOME_DIR" FM_USAGE_HIGH_WATER=90 FM_USAGE_QUOTA_CMD="$S5HI" "$GUARD"; echo "|$?")
case "$r" in *"|0") : ;; *) fail "5h=85 with high-water 90 should allow (got $r)" ;; esac
r=$(FM_HOME="$HOME_DIR" FM_USAGE_HIGH_WATER=80 FM_USAGE_QUOTA_CMD="$S5HI" "$GUARD"; echo "|$?")
case "$r" in *"|3") : ;; *) fail "5h=85 with high-water 80 should hold (got $r)" ;; esac
pass "high-water knob gates the hold"

# --- overrides always allow, even under critical -----------------------------
r=$(guard "$S5CRIT" --captain); [ "$(verdict "$r")" = 0 ] || fail "captain override must always allow (got $r)"
assert_contains "$(line "$r")" "captain" "captain override reason"
r=$(guard "$S5CRIT" --priority high); [ "$(verdict "$r")" = 0 ] || fail "high-priority work must always allow (got $r)"
pass "captain override and high-priority always allow"

# --- no signal at all -> allow (advisory, never blocks) ----------------------
r=$(guard /bin/false); [ "$(verdict "$r")" = 0 ] || fail "no signal should allow, not block (got $r)"
pass "no signal allows (guard is advisory)"

pass "fm-usage-guard: all checks passed"
