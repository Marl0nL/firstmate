#!/usr/bin/env bash
# tests/fm-secondmate-charter-lib.test.sh - the registry charter-summary field
# must stay a short, scannable one-liner even when the charter behind it is huge,
# because data/secondmates.md is printed in full at every session start. These
# drive the real registry_summary_for_brief / truncate_registry_summary /
# registry_scope_for_brief functions (bin/fm-secondmate-charter-lib.sh) and
# assert their output, never the source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-secondmate-charter-lib.sh
. "$ROOT/bin/fm-secondmate-charter-lib.sh"

test_truncate_registry_summary_caps_long_text() {
  local long out
  long=$(printf 'word %.0s' $(seq 1 400))
  out=$(truncate_registry_summary "$long" "$REGISTRY_SUMMARY_CAP")
  [ "${#out}" -le "$((REGISTRY_SUMMARY_CAP + 3))" ] \
    || fail "truncate_registry_summary left a long string long (${#out} chars)"
  case "$out" in
    *'...') ;;
    *) fail "a truncated summary must end with an ellipsis marker: $out" ;;
  esac
  pass "truncate_registry_summary caps long text and marks the cut"
}

test_truncate_registry_summary_leaves_short_text() {
  local short out
  short='ops domain for widgets'
  out=$(truncate_registry_summary "$short" "$REGISTRY_SUMMARY_CAP")
  [ "$out" = "$short" ] || fail "a short summary was altered: '$out'"
  case "$out" in
    *'...') fail "a short summary was marked as truncated: $out" ;;
  esac
  pass "truncate_registry_summary leaves text that fits the cap untouched"
}

test_registry_summary_truncates_a_huge_charter() {
  local long out
  # A charter far past the cap, with parentheses and semicolons (ordinary
  # English punctuation) that the registry field-split parser cannot tolerate.
  long="This domain owns everything about widgets (and gadgets); $(printf 'word %.0s' $(seq 1 400))"
  out=$(FM_SECONDMATE_CHARTER="$long" registry_summary_for_brief /dev/null)
  [ "${#out}" -le "$((REGISTRY_SUMMARY_CAP + 3))" ] \
    || fail "registry summary stayed long despite a huge charter (${#out} chars): $out"
  case "$out" in
    *';'*|*'('*|*')'*) fail "registry summary still contains a raw parser delimiter: $out" ;;
  esac
  pass "registry_summary_for_brief truncates a huge charter to a short, delimiter-safe line"
}

test_registry_summary_honors_explicit_override() {
  local out
  out=$(FM_SECONDMATE_SUMMARY='widget ops domain' FM_SECONDMATE_CHARTER='a much longer charter body that should be ignored' \
    registry_summary_for_brief /dev/null)
  [ "$out" = 'widget ops domain' ] \
    || fail "FM_SECONDMATE_SUMMARY did not override the derived summary: '$out'"
  pass "registry_summary_for_brief honors an explicit FM_SECONDMATE_SUMMARY override"
}

test_registry_scope_is_never_truncated() {
  local long out
  long=$(printf 'scope %.0s' $(seq 1 100))
  out=$(FM_SECONDMATE_SCOPE="$long" registry_scope_for_brief /dev/null)
  # normalize collapses whitespace but must not shorten the routing scope.
  case "$out" in
    *'...') fail "the routing scope was truncated: $out" ;;
  esac
  [ "${#out}" -ge "$REGISTRY_SUMMARY_CAP" ] \
    || fail "the routing scope was capped like the summary (${#out} chars)"
  pass "registry_scope_for_brief never truncates the routing scope"
}

test_truncate_registry_summary_caps_long_text
test_truncate_registry_summary_leaves_short_text
test_registry_summary_truncates_a_huge_charter
test_registry_summary_honors_explicit_override
test_registry_scope_is_never_truncated
