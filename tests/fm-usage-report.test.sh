#!/usr/bin/env bash
# tests/fm-usage-report.test.sh - behavior tests for the token-usage report's
# real per-model pricing (bin/fm-usage-lib.sh's fm_usage_model_cost /
# fm_usage_pricing_json, and bin/fm-usage-report.sh's cost aggregation).
#
# Covers the pricing-math rules from the design: per-model $/MTok rates, the
# input/output/cache-read/cache-write split, exact + longest-prefix + default
# model matching, the labelled-default fallback for unknown models, config
# overlay and malformed-config fallback, and the end-to-end report cost blob.
#
# Hermetic: a temp FM_HOME (no config) selects the built-in table; a temp
# FM_USAGE_PRICING_FILE drives the overlay cases. jq is the real tool; no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-usage-report: jq unavailable, skipping"; exit 0; }

fm_test_tmproot TMP fm-usage-report
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/usage"

# Source the lib against the temp home so no live operator config is read.
# shellcheck source=bin/fm-usage-lib.sh
FM_HOME="$HOME_DIR" . "$ROOT/bin/fm-usage-lib.sh"

# --- per-model rates: exact matches (built-in table) --------------------------
# 1M tokens of each class -> cost is exactly the sum of that model's four rates.
# opus-4-8: 5 + 25 + 0.5 + 6.25 = 36.75
[ "$(fm_usage_model_cost 1000000 1000000 1000000 1000000 claude-opus-4-8)" = 36.75 ] \
  || fail "opus-4-8 all-class cost should be 36.75 (5/25/0.5/6.25 per MTok)"
# output-only isolates the output rate per model (opus 25, fable 50, haiku 5).
[ "$(fm_usage_model_cost 0 1000000 0 0 claude-opus-4-8)" = 25 ] || fail "opus-4-8 output rate should be 25/MTok"
[ "$(fm_usage_model_cost 0 1000000 0 0 claude-fable-5)" = 50 ] || fail "fable-5 output rate should be 50/MTok (pricier than opus)"
[ "$(fm_usage_model_cost 0 1000000 0 0 claude-haiku-4-5)" = 5 ] || fail "haiku-4-5 output rate should be 5/MTok (cheapest)"
# input-only, and the cache classes, resolve to the right per-model rates.
[ "$(fm_usage_model_cost 1000000 0 0 0 claude-fable-5)" = 10 ] || fail "fable-5 input rate should be 10/MTok"
[ "$(fm_usage_model_cost 0 0 1000000 0 claude-opus-4-8)" = 0.5 ] || fail "opus-4-8 cache-read rate should be 0.1x input = 0.5/MTok"
[ "$(fm_usage_model_cost 0 0 0 1000000 claude-opus-4-8)" = 6.25 ] || fail "opus-4-8 cache-write rate should be 1.25x input = 6.25/MTok"
pass "per-model exact rates: input/output/cache-read/cache-write split is real per-model pricing"

# --- longest-prefix matching (1M-context and dated variants) ------------------
[ "$(fm_usage_model_cost 1000000 0 0 0 "claude-opus-4-8[1m]")" = 5 ] \
  || fail "1M-context variant should prefix-match claude-opus-4-8 (input 5/MTok)"
[ "$(fm_usage_model_cost 1000000 0 0 0 claude-haiku-4-5-20251001)" = 1 ] \
  || fail "dated haiku id should prefix-match claude-haiku-4-5 (input 1/MTok)"
pass "longest-prefix matching resolves [1m] and dated model-id variants"

# --- unknown model falls back to the labelled default, never a silent zero -----
[ "$(fm_usage_model_cost 0 1000000 0 0 some-future-model)" = 25 ] \
  || fail "unknown model must use the default rate (25/MTok output), not zero"
matched=$(jq -n --argjson p "$(fm_usage_pricing_json)" "$FM_USAGE_PRICING_JQ_DEFS"'priceMatched($p; "some-future-model")')
[ "$matched" = false ] || fail "priceMatched must report false for an unknown model (so the report flags it)"
matched=$(jq -n --argjson p "$(fm_usage_pricing_json)" "$FM_USAGE_PRICING_JQ_DEFS"'priceMatched($p; "claude-opus-4-8[1m]")')
[ "$matched" = true ] || fail "priceMatched must report true for a prefix-matched model"
pass "unknown models use a labelled default (priceMatched=false), never a silent zero"

# --- config overlay: merge by id, add models, replace default -----------------
CFG="$TMP/usage-pricing.json"
cat > "$CFG" <<'EOF'
{"models":{"claude-opus-4-8":{"input":99,"output":99,"cache_read":0,"cache_write":0},
           "team-custom-model":{"input":2,"output":8,"cache_read":0.2,"cache_write":2.5}},
 "default":{"input":7,"output":7,"cache_read":0,"cache_write":0}}
EOF
[ "$(FM_USAGE_PRICING_FILE="$CFG" fm_usage_model_cost 1000000 0 0 0 claude-opus-4-8)" = 99 ] \
  || fail "config must override a built-in model's rate (opus input -> 99)"
[ "$(FM_USAGE_PRICING_FILE="$CFG" fm_usage_model_cost 0 1000000 0 0 team-custom-model)" = 8 ] \
  || fail "config must add a new model (team-custom-model output -> 8)"
[ "$(FM_USAGE_PRICING_FILE="$CFG" fm_usage_model_cost 0 1000000 0 0 claude-fable-5)" = 50 ] \
  || fail "built-in models not listed in config must be preserved (fable output stays 50)"
[ "$(FM_USAGE_PRICING_FILE="$CFG" fm_usage_model_cost 1000000 0 0 0 unlisted-model)" = 7 ] \
  || fail "config default must replace the built-in default (unknown input -> 7)"
pass "config overlay merges by id, adds models, and replaces the default"

# --- malformed / structurally-invalid config falls back (never zeroes cost) ----
BAD="$TMP/bad.json"
printf '{ not valid json\n' > "$BAD"
[ "$(FM_USAGE_PRICING_FILE="$BAD" fm_usage_model_cost 1000000 0 0 0 claude-opus-4-8)" = 5 ] \
  || fail "an unparseable config must fall back to the built-in table, not zero the cost"
# Parseable but structurally invalid (a scalar 'default') must ALSO fall back to
# the built-in table rather than crash costing or silently zero - the documented
# guarantee. A bare jq-parse check would wrongly accept this.
STRUCT="$TMP/struct-bad.json"
printf '{"default":"oops"}\n' > "$STRUCT"
[ "$(FM_USAGE_PRICING_FILE="$STRUCT" fm_usage_model_cost 0 1000000 0 0 claude-opus-4-8)" = 25 ] \
  || fail "a scalar-default config must fall back to built-in (opus output 25)"
[ "$(FM_USAGE_PRICING_FILE="$STRUCT" fm_usage_model_cost 0 1000000 0 0 unknown-x)" = 25 ] \
  || fail "a scalar-default config must not crash an unknown-model cost; use built-in default 25"
SBAD="$TMP/struct-bad-model.json"
printf '{"models":{"claude-opus-4-8":"oops"}}\n' > "$SBAD"
[ "$(FM_USAGE_PRICING_FILE="$SBAD" fm_usage_model_cost 0 1000000 0 0 claude-opus-4-8)" = 25 ] \
  || fail "a scalar-rate model entry must fall back to built-in (opus output 25)"
pass "malformed and structurally-invalid configs fall back to the built-in table"

# --- example template validity + FULL parity with the built-in table ----------
# The example restates every built-in rate, so assert the whole models+default
# object matches - a single-row check would let a later built-in rate change drift
# the shipped template silently.
jq -e . "$ROOT/docs/examples/usage-pricing.json" >/dev/null 2>&1 \
  || fail "docs/examples/usage-pricing.json must be valid JSON"
builtin_rates=$(printf '%s' "$FM_USAGE_PRICING_DEFAULTS" | jq -S '{models, default}')
example_rates=$(jq -S '{models, default}' "$ROOT/docs/examples/usage-pricing.json")
[ "$builtin_rates" = "$example_rates" ] \
  || fail "docs/examples/usage-pricing.json must match the built-in rate table exactly (models + default)"
pass "docs/examples/usage-pricing.json is valid and matches the built-in defaults in full"

# --- end-to-end report: real $ cost per model in the embedded data blob --------
L="$HOME_DIR/data/usage/ledger.jsonl"
lrec() { # rid model in out
  jq -cn --arg rid "$1" --arg m "$2" --argjson in "$3" --argjson out "$4" \
    '{ts:"2026-07-08T01:00:00Z",request_id:$rid,task_id:("t-"+$rid),project:"proj",harness:"claude",
      model:$m,input_tokens:$in,output_tokens:$out,cache_read_input_tokens:0,cache_creation_input_tokens:0}'
}
{ lrec r1 claude-opus-4-8 1000000 1000000     # 5 + 25 = 30
  lrec r2 claude-fable-5 0 1000000            # 50
  lrec r3 claude-haiku-4-5 0 1000000          # 5
  lrec r4 mystery-model 0 1000000; } > "$L"   # default output 25, priced=false
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-usage-report.sh" --no-open --out "$TMP/report.html" >/dev/null 2>&1 \
  || fail "fm-usage-report.sh --no-open should succeed on a non-empty ledger"

# Pull the embedded application/json blob back out and assert the computed costs.
DATA=$(sed -n '/type="application\/json">/,/<\/script>/p' "$TMP/report.html" | sed '1d;$d')
[ -n "$DATA" ] || fail "report should embed a JSON data blob"
[ "$(printf '%s' "$DATA" | jq '.totals.cost')" = 110 ] || fail "total cost should be 30+50+5+25 = 110"
[ "$(printf '%s' "$DATA" | jq -r '.by_model[] | select(.key=="claude-fable-5") | .cost')" = 50 ] || fail "fable-5 by_model cost should be 50"
[ "$(printf '%s' "$DATA" | jq -r '.by_model[] | select(.key=="claude-opus-4-8") | .cost')" = 30 ] || fail "opus-4-8 by_model cost should be 30"
[ "$(printf '%s' "$DATA" | jq -r '.by_model[] | select(.key=="mystery-model") | .priced')" = false ] || fail "unknown model row should be flagged priced=false"
# by_model is ranked by real cost, so fable (50) outranks opus (30).
[ "$(printf '%s' "$DATA" | jq -r '.by_model[0].key')" = claude-fable-5 ] || fail "by_model should rank by real \$ cost (fable first)"
assert_grep 'default rate' "$TMP/report.html" "report HTML should tag the default-priced model"
assert_grep 'Total cost' "$TMP/report.html" "report HTML should show a total-cost tile"
pass "end-to-end report headlines real per-model \$ cost and flags default-rate models"

pass "fm-usage-report: all checks passed"
