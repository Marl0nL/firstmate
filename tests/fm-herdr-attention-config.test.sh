#!/usr/bin/env bash
# Portable unit test for bin/fm-herdr-attention-config.sh - the guarded,
# idempotent helper that applies the three captain-consented Herdr attention
# settings to the GLOBAL config. It uses a throwaway config via HERDR_CONFIG_PATH
# and a fake `herdr` (config check / reload-config), so no real Herdr is needed
# and the captain's own config is never touched. That the three keys are actually
# schema-valid on the installed Herdr is a harness-dependent fact proven by the
# live guard tests/fm-herdr-attention-live-e2e.test.sh, not here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-herdr-attention-config.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-attention-config)
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 required"; exit 0; }

# A fake `herdr` whose `config check` succeeds unless FM_FAKE_CHECK_FAIL=1, and
# whose `server reload-config` succeeds unless FM_FAKE_RELOAD_FAIL=1. Every call
# is logged to $FM_FAKE_HERDR_LOG.
make_fake_herdr() {  # <dir> -> echoes fakebin dir
  local fb
  fb=$(fm_fakebin "$1")
  cat >"$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FM_FAKE_HERDR_LOG:-/dev/null}"
if [ "${1:-}" = config ] && [ "${2:-}" = check ]; then
  [ "${FM_FAKE_CHECK_FAIL:-0}" = 1 ] && { echo "config: issues found" >&2; exit 1; }
  echo "config: ok"; exit 0
fi
if [ "${1:-}" = server ] && [ "${2:-}" = reload-config ]; then
  [ "${FM_FAKE_RELOAD_FAIL:-0}" = 1 ] && exit 1
  echo '{"result":{"status":"applied"}}'; exit 0
fi
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s' "$fb"
}

setup_case() {  # <name> <initial-config-content> -> sets CFG, FB, LOG
  local name=$1 content=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  CFG="$dir/config.toml"
  printf '%s' "$content" >"$CFG"
  LOG="$dir/herdrlog"
  : >"$LOG"
  FB=$(make_fake_herdr "$dir")
}

test_apply_seeds_all_three_settings_and_validates() {
  setup_case seed $'onboarding = false\n'
  PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" apply >/dev/null 2>&1 \
    || fail "apply must succeed on a minimal config"
  assert_grep 'agent_panel_sort = "priority"' "$CFG" "agent_panel_sort not set"
  assert_grep 'delivery = "herdr"' "$CFG" "toast delivery not set"
  assert_grep 'enabled = true' "$CFG" "sound not enabled"
  assert_grep 'onboarding = false' "$CFG" "the pre-existing onboarding key must be preserved"
  assert_grep 'config check' "$LOG" "apply must validate with herdr config check"
  assert_grep 'server reload-config' "$LOG" "apply must reload the running server"
  pass "apply seeds the three settings, preserves other keys, validates, and reloads"
}

test_apply_is_idempotent_no_second_backup() {
  setup_case idem $'onboarding = false\n'
  PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" apply >/dev/null 2>&1
  local n1 out n2
  n1=$(find "$(dirname "$CFG")" -name 'config.toml.fm-backup-*' | wc -l)
  out=$(PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" apply 2>&1)
  n2=$(find "$(dirname "$CFG")" -name 'config.toml.fm-backup-*' | wc -l)
  assert_contains "$out" "already applied" "a re-run must report an already-applied no-op"
  [ "$n1" = "$n2" ] || fail "an idempotent re-run must not create a second backup ($n1 -> $n2)"
  pass "apply is idempotent: a re-run is a no-op and takes no new backup"
}

test_check_reports_state_without_writing() {
  setup_case check $'onboarding = false\n'
  local before after
  before=$(cat "$CFG")
  PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" check >/dev/null 2>&1
  local rc=$?
  after=$(cat "$CFG")
  [ "$rc" = 10 ] || fail "check on an unapplied config must exit 10, got $rc"
  [ "$before" = "$after" ] || fail "check must not modify the config"
  [ "$(find "$(dirname "$CFG")" -name 'config.toml.fm-backup-*' | wc -l)" = 0 ] \
    || fail "check must not take a backup"
  PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" apply --no-reload >/dev/null 2>&1
  if ! PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" check >/dev/null 2>&1; then
    fail "check after apply must exit 0"
  fi
  pass "check reports applied/unapplied without writing or backing up"
}

test_replaces_a_wrong_value_in_place_without_duplicate_tables() {
  setup_case replace $'[ui]\n# my prefs\naccent = "cyan"\nagent_panel_sort = "spaces"\n'
  PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" apply --no-reload >/dev/null 2>&1 \
    || fail "apply must succeed on a config with an existing [ui] table"
  assert_grep 'agent_panel_sort = "priority"' "$CFG" "the wrong value must be replaced in place"
  assert_no_grep 'agent_panel_sort = "spaces"' "$CFG" "the old value must be gone"
  assert_grep 'accent = "cyan"' "$CFG" "an unrelated key in the same table must survive"
  assert_grep '# my prefs' "$CFG" "a comment in the table must survive"
  [ "$(grep -c '^\[ui\]' "$CFG")" = 1 ] || fail "there must be exactly one [ui] header (no duplicate table)"
  pass "a wrong value is replaced in place with no duplicate table header"
}

test_restores_backup_when_validation_fails() {
  setup_case restore $'onboarding = false\n'
  local before out
  before=$(cat "$CFG")
  out=$(PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" FM_FAKE_CHECK_FAIL=1 "$HELPER" apply 2>&1)
  local rc=$?
  [ "$rc" != 0 ] || fail "apply must fail when 'herdr config check' rejects the edit"
  [ "$(cat "$CFG")" = "$before" ] || fail "a rejected edit must be rolled back to the original config"
  assert_contains "$out" "restoring backup" "the failure must announce the restore"
  assert_no_grep 'server reload-config' "$LOG" "a rejected edit must never reload the server"
  pass "a failed validation restores the backup and never reloads"
}

test_no_reload_skips_the_server_reload() {
  setup_case noreload $'onboarding = false\n'
  PATH="$FB:$PATH" HERDR_CONFIG_PATH="$CFG" FM_FAKE_HERDR_LOG="$LOG" "$HELPER" apply --no-reload >/dev/null 2>&1 \
    || fail "apply --no-reload must succeed"
  assert_grep 'config check' "$LOG" "--no-reload must still validate"
  assert_no_grep 'server reload-config' "$LOG" "--no-reload must not reload the running server"
  pass "--no-reload validates but does not touch the running server"
}

test_apply_seeds_all_three_settings_and_validates
test_apply_is_idempotent_no_second_backup
test_check_reports_state_without_writing
test_replaces_a_wrong_value_in_place_without_duplicate_tables
test_restores_backup_when_validation_fails
test_no_reload_skips_the_server_reload
