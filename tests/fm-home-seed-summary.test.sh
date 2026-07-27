#!/usr/bin/env bash
# tests/fm-home-seed-summary.test.sh - the registry charter-summary field must
# stay a short, scannable one-liner even when the charter behind it is huge,
# because data/secondmates.md is printed in full at every session start.
# Regression coverage for the multi-thousand-word-charter inlining defect.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-home-seed-summary

test_seed_truncates_long_charter_into_short_registry_summary() {
  local home subhome err summary_line long_charter head summary
  home="$TMP_ROOT/long-charter-home"
  subhome="$TMP_ROOT/long-charter-subhome"
  err="$TMP_ROOT/long-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/long-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  # A charter far past REGISTRY_SUMMARY_CAP, with parentheses and semicolons
  # (ordinary English punctuation) that the registry parser cannot tolerate
  # unescaped in a field.
  long_charter=$(printf 'This domain owns everything about widgets (and gadgets); ')
  long_charter="$long_charter$(printf 'word %.0s' $(seq 1 400))"

  FM_HOME="$home" FM_SECONDMATE_CHARTER="$long_charter" FM_SECONDMATE_SCOPE='widget domain' \
    "$ROOT/bin/fm-home-seed.sh" widgets "$subhome" alpha >/dev/null 2>"$err" \
    || fail "seed with a long charter failed: $(cat "$err")"

  assert_present "$subhome/data/charter.md" "seed did not copy the charter into the subhome"
  assert_grep "$long_charter" "$subhome/data/charter.md" "long charter was not copied verbatim into the subhome"

  summary_line=$(grep -E '^- widgets ' "$home/data/secondmates.md") \
    || fail "seed did not write a registry line for widgets"
  head=${summary_line%% (home:*}
  summary=${head#- widgets - }
  [ "${#summary}" -le 210 ] \
    || fail "registry summary field stayed long despite a huge charter (${#summary} chars): $summary"
  case "$summary" in
    *';'*|*'('*|*')'*) fail "registry summary still contains a raw parser delimiter: $summary" ;;
  esac
  assert_grep 'scope: widget domain' "$home/data/secondmates.md" \
    "registry scope was altered even though FM_SECONDMATE_SCOPE was short"

  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "fm-home-seed.sh validate rejected the registry after a long-charter seed"
  pass "seeding with a huge charter produces a short registry summary and an intact charter.md"
}

test_seed_leaves_short_charter_unaffected() {
  local home subhome summary_line
  home="$TMP_ROOT/short-charter-home"
  subhome="$TMP_ROOT/short-charter-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/short-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops domain for widgets' FM_SECONDMATE_SCOPE='ops domain for widgets' \
    "$ROOT/bin/fm-home-seed.sh" ops "$subhome" alpha >/dev/null \
    || fail "seed with a short charter failed"

  summary_line=$(grep -E '^- ops ' "$home/data/secondmates.md") \
    || fail "seed did not write a registry line for ops"
  case "$summary_line" in
    *'ops domain for widgets'*) ;;
    *) fail "short charter summary was altered: $summary_line" ;;
  esac
  case "$summary_line" in
    *'...'*) fail "short charter summary was truncated when it fit well under the cap: $summary_line" ;;
  esac
  pass "seeding with a short charter leaves the registry summary unchanged"
}

test_seed_honors_explicit_summary_override() {
  local home subhome summary_line
  home="$TMP_ROOT/summary-override-home"
  subhome="$TMP_ROOT/summary-override-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/summary-override-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='the full long-form charter text lives only in charter.md' \
    FM_SECONDMATE_SCOPE='design domain' FM_SECONDMATE_SUMMARY='design domain lead' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null \
    || fail "seed with an explicit summary override failed"

  summary_line=$(grep -E '^- design ' "$home/data/secondmates.md") \
    || fail "seed did not write a registry line for design"
  assert_contains "$summary_line" 'design domain lead' \
    "explicit FM_SECONDMATE_SUMMARY was not used for the registry summary"
  case "$summary_line" in
    *'full long-form charter text'*) fail "registry summary fell back to the charter despite an explicit override: $summary_line" ;;
  esac
  pass "FM_SECONDMATE_SUMMARY overrides the derived registry summary"
}

test_seed_truncates_long_charter_into_short_registry_summary
test_seed_leaves_short_charter_unaffected
test_seed_honors_explicit_summary_override
