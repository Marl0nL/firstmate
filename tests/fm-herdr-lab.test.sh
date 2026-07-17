#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-herdr-lab
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
ARGV_LOG="$TMP_ROOT/herdr-argv.log"
TARGET_LOG="$TMP_ROOT/herdr-target.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
US=$(printf '\037')
mkdir -p "$FAKE_STATE"
printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"
: > "$ARGV_LOG"
: > "$TARGET_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
# Record argv verbatim, one argument per unit-separator-delimited field, so the
# boundary tests can assert exactly where --session landed.
printf '%s\x1f' "$@" >> "$FM_FAKE_HERDR_ARGV_LOG"
printf '\n' >> "$FM_FAKE_HERDR_ARGV_LOG"
state=$FM_FAKE_HERDR_STATE
# Resolve --session the way the real client does: it is a GLOBAL option, and
# global scanning stops at a `--` separator - everything past it belongs to the
# agent being started, not to herdr.  With no --session of its own, herdr falls
# back to the ambient session, which on a real host is the live default one.
# Emulating that faithfully is the point: a wrapper that mispositions the flag
# must show up here as a call targeting `default`, exactly as it did live.
session=default
args=()
seen_separator=
while [ "$#" -gt 0 ]; do
  if [ -z "$seen_separator" ]; then
    case "$1" in
      --session) session=${2:?fake herdr: --session without a value}; shift 2; continue ;;
      --session=*) session=${1#--session=}; shift; continue ;;
      --) seen_separator=1 ;;
    esac
  fi
  args+=("$1")
  shift
done
set -- ${args[@]+"${args[@]}"}
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
printf '%s\n' "$session" >> "$FM_FAKE_HERDR_TARGET_LOG"
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server ")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=bin/fm-herdr-lab.sh
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_ARGV_LOG="$ARGV_LOG" \
    FM_FAKE_HERDR_TARGET_LOG="$TARGET_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  : > "$ARGV_LOG"
  : > "$TARGET_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      "--session$US$name$US"*) : ;;
      *) fail "Herdr call is not led by the lab session flag: $(printf '%s' "$line" | tr "$US" ' ')" ;;
    esac
  done < "$ARGV_LOG"
  ! grep -qx default "$TARGET_LOG" || fail "a lab Herdr call resolved to the live default session"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  : > "$ARGV_LOG"
  : > "$TARGET_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  : > "$ARGV_LOG"
  : > "$TARGET_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  : > "$ARGV_LOG"
  : > "$TARGET_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  : > "$ARGV_LOG"
  : > "$TARGET_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  : > "$ARGV_LOG"
  : > "$TARGET_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

# The tool under test IS the isolation mechanism, so its scoping is proven at
# the argument-construction layer against a fake Herdr that records argv
# verbatim.  A real-binary check cannot prove this safely: a regression here
# creates agents in the live default session, which is exactly the failure it
# would be testing for.
test_agent_start_is_session_scoped() {
  local name="fm-lab-argv-$$" recorded expected target status=0
  : > "$ARGV_LOG"
  : > "$TARGET_LOG"
  run_with_fake fm_herdr_lab_cli "$name" \
    agent start probe --cwd /tmp --no-focus -- sleep 600 >/dev/null \
    || fail "agent start through the lab helper failed"
  recorded=$(tr "$US" ' ' < "$ARGV_LOG" | sed 's/ $//')
  expected="--session $name agent start probe --cwd /tmp --no-focus -- sleep 600"
  [ "$recorded" = "$expected" ] || fail "agent start argv mismatch: got [$recorded] want [$expected]"

  # The precise regression: --session must not appear after the `--` separator,
  # where Herdr hands it to the agent instead of consuming it itself.
  case "${recorded#*' -- '}" in
    *--session*) fail "the lab session flag leaked into the started agent's argv" ;;
  esac

  # And the symptom that made this dangerous: the call must resolve to the lab
  # session, never to the ambient default one the live fleet runs in.
  target=$(cat "$TARGET_LOG")
  [ "$target" = "$name" ] \
    || fail "agent start targeted session '$target', not the lab session '$name'"

  # Every other trailing-argv shape the wrapper can forward must refuse rather
  # than forward when the caller supplies its own --session.
  status=0
  run_with_fake fm_herdr_lab_cli "$name" \
    agent start probe -- sleep 600 --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a caller --session after '--' must be refused, not forwarded"
  pass "fm-herdr-lab: agent start is scoped to the lab session, never the agent argv"
}

test_refuses_unsafe_names
test_agent_start_is_session_scoped
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
