#!/usr/bin/env bash
# Behavior tests for the Crowsnest - firstmate's two-way Google Chat bridge via
# the local-agents-chat backend (bin/fm-crowsnest-*.sh, bin/fm-crowsnest-lib.sh).
#
# The Crowsnest must be INERT by default (no config/crowsnest.env -> the relay
# acknowledges but enqueues nothing, the poll is a hard no-op, and bootstrap
# writes/prints nothing) and additive when on. The invariant under test: a chat
# message becomes a WAKE the one live session handles, never a second agent. The
# local-agents CLI is stubbed with a fakebin so lifecycle tests stay hermetic;
# jq stays the real tool. End-to-end verification against the real backend is
# done out of band (see docs/crowsnest.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crowsnest-tests)
RELAY="$ROOT/bin/fm-crowsnest-relay.sh"
POLL="$ROOT/bin/fm-crowsnest-poll.sh"
POST="$ROOT/bin/fm-crowsnest-post.sh"
CLI="$ROOT/bin/fm-crowsnest.sh"

# A fresh, isolated firstmate home. Pass "on" to enable the Crowsnest.
make_home() {
  local name=$1 mode=${2:-off} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state"
  if [ "$mode" = on ]; then
    printf 'CROWSNEST_ENABLED=1\n' > "$home/config/crowsnest.env"
  fi
  printf '%s' "$home"
}

# A fakebin local-agents(-chat) CLI that records calls and emulates the registry
# via a marker file, so enable/disable/status are deterministic offline.
make_fake_cli() {
  local dir=$1 name=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
args=("$@")
sub=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) shift 2 ;;
    register|unregister|agents|run) sub=$1; shift; break ;;
    *) shift ;;
  esac
done
[ -n "${FAKE_LA_LOG:-}" ] && printf '%s\n' "${args[*]}" >> "$FAKE_LA_LOG"
case "$sub" in
  register) : > "${FAKE_LA_MARK:-/dev/null}"; echo "registered" ;;
  unregister) rm -f "${FAKE_LA_MARK:-/dev/null}"; echo "unregistered" ;;
  agents) [ -f "${FAKE_LA_MARK:-/dev/null}" ] && echo "firstmate  desc  [registered]"; echo "echo  stub  [config]" ;;
  run) echo "running" ;;
esac
SH
  chmod +x "$fakebin/$name"
  printf '%s' "$fakebin"
}

first_inbox_id() {
  local home=$1 f
  for f in "$home"/state/chat-inbox/*.json; do
    [ -e "$f" ] || return 1
    f=${f##*/}; printf '%s' "${f%.json}"; return 0
  done
  return 1
}

# --- relay ------------------------------------------------------------------

test_relay_enabled_stashes_enqueues_and_acks() {
  local home out id
  home=$(make_home relay-on on)
  out=$(printf 'is the deploy green?' | env FM_HOME="$home" \
    LOCAL_AGENTS_SPACE='spaces/AAA' LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' \
    LOCAL_AGENTS_SENDER='users/9' LOCAL_AGENTS_MODE='slash' "$RELAY")
  assert_contains "$out" "On it, captain" "relay must return an immediate ack"
  id=$(first_inbox_id "$home") || fail "relay must stash an inbox entry"
  assert_grep '"space":"spaces/AAA"' "$home/state/chat-inbox/$id.json" "inbox must record the space"
  assert_grep '"thread":"spaces/AAA/threads/T1"' "$home/state/chat-inbox/$id.json" "inbox must record the thread"
  assert_grep '"text":"is the deploy green?"' "$home/state/chat-inbox/$id.json" "inbox must record the text"
  assert_grep "chat-mention $id" "$home/state/.wake-queue" "relay must enqueue a durable chat-mention wake"
  # The wake is a check wake so the existing check-drain path handles it.
  assert_grep "	check	chat-inbox	chat-mention $id" "$home/state/.wake-queue" "wake must be a check wake keyed to chat-inbox"
  pass "relay stashes the message, enqueues a durable wake, and acks"
}

test_relay_disabled_is_inert() {
  local home out
  home=$(make_home relay-off off)
  out=$(printf 'hello' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/X' "$RELAY")
  assert_contains "$out" "not currently on watch" "a disabled relay must still ack (non-empty stdout)"
  assert_absent "$home/state/chat-inbox" "a disabled relay must not stash anything"
  assert_absent "$home/state/.wake-queue" "a disabled relay must not enqueue a wake"
  pass "relay is inert when the Crowsnest is off"
}

test_relay_empty_text_acks_without_inbox() {
  local home out
  home=$(make_home relay-empty on)
  out=$(printf '' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/X' "$RELAY")
  [ -n "$out" ] || fail "relay must always print a non-empty ack"
  assert_absent "$home/state/chat-inbox" "empty text must not stash an inbox entry"
  pass "relay acks empty text without stashing"
}

# --- poll -------------------------------------------------------------------

test_poll_inert_when_disabled() {
  local home out
  home=$(make_home poll-off off)
  mkdir -p "$home/state/chat-inbox"
  : > "$home/state/chat-inbox/chat-1-aa.json"
  out=$(env FM_HOME="$home" "$POLL")
  [ -z "$out" ] || fail "a disabled poll must print nothing (got: $out)"
  pass "poll is a hard no-op when disabled"
}

test_poll_silent_when_inbox_empty() {
  local home out
  home=$(make_home poll-empty on)
  out=$(env FM_HOME="$home" "$POLL")
  [ -z "$out" ] || fail "poll must be silent with no pending messages"
  pass "poll is silent when the inbox is empty"
}

test_poll_surfaces_oldest_pending() {
  local home out
  home=$(make_home poll-order on)
  mkdir -p "$home/state/chat-inbox"
  : > "$home/state/chat-inbox/chat-100-old.json"
  sleep 1
  : > "$home/state/chat-inbox/chat-200-new.json"
  out=$(env FM_HOME="$home" "$POLL")
  assert_contains "$out" "chat-mention chat-100-old" "poll must surface the oldest pending entry"
  assert_not_contains "$out" "chat-200-new" "poll surfaces one entry per cycle"
  pass "poll surfaces the oldest pending message as a chat-mention line"
}

test_poll_ignores_unsafe_stray_file() {
  local home out
  home=$(make_home poll-stray on)
  mkdir -p "$home/state/chat-inbox"
  : > "$home/state/chat-inbox/..evil.json"
  out=$(env FM_HOME="$home" "$POLL")
  [ -z "$out" ] || fail "poll must not surface an unsafe id (got: $out)"
  pass "poll refuses an unsafe inbox filename"
}

# --- post (dry-run) ---------------------------------------------------------

test_post_dry_run_reply_records_outbox() {
  local home id out
  home=$(make_home post-reply on)
  printf 'is the deploy green?' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "setup: relay must stash"
  out=$(printf 'Aye captain, all green.' | env FM_HOME="$home" CROWSNEST_DRY_RUN=1 "$POST" --reply "$id" -)
  assert_contains "$out" "dry-run: recorded reply to spaces/AAA" "post must resolve the space from the inbox"
  assert_grep '"space":"spaces/AAA"' "$home/state/chat-outbox/$id.json" "outbox must record the resolved space"
  assert_grep '"thread":"spaces/AAA/threads/T1"' "$home/state/chat-outbox/$id.json" "outbox must record the resolved thread"
  assert_grep 'Aye captain, all green.' "$home/state/chat-outbox/$id.json" "outbox must record the reply text"
  assert_present "$home/state/chat-inbox/$id.json" "post must NOT remove the inbox entry (the live session owns cleanup)"
  pass "post --reply resolves the thread and records a dry-run reply without touching the inbox"
}

test_post_dry_run_proactive_space_thread() {
  local home out key
  home=$(make_home post-proactive on)
  out=$(printf 'Captain, a crew job needs your call.' | env FM_HOME="$home" CROWSNEST_DRY_RUN=1 \
    "$POST" --space 'spaces/ZZZ' --thread 'spaces/ZZZ/threads/Q' -)
  assert_contains "$out" "recorded reply to spaces/ZZZ" "proactive post must target the given space"
  key=$(find "$home/state/chat-outbox" -name '*.json' | head -n1)
  [ -n "$key" ] || fail "proactive post must write an outbox record"
  assert_grep '"space":"spaces/ZZZ"' "$key" "proactive outbox must record the space"
  pass "post supports a proactive space/thread post (the reverse channel)"
}

test_post_reply_unknown_id_errors() {
  local home rc
  home=$(make_home post-unknown on)
  printf 'x' | env FM_HOME="$home" CROWSNEST_DRY_RUN=1 "$POST" --reply chat-nope-1 - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "post --reply for an unknown id must fail"
  pass "post --reply errors on an unknown inbox id"
}

test_post_refuses_empty_text() {
  local home rc
  home=$(make_home post-empty on)
  printf '   \n' | env FM_HOME="$home" CROWSNEST_DRY_RUN=1 "$POST" --space 'spaces/A' - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "post must refuse whitespace-only text"
  pass "post refuses empty/whitespace-only text"
}

test_post_rejects_reply_and_space_together() {
  local home rc
  home=$(make_home post-both on)
  printf 'x' | env FM_HOME="$home" CROWSNEST_DRY_RUN=1 "$POST" --reply chat-a-1 --space 'spaces/A' - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "post must reject --reply and --space together"
  pass "post rejects --reply and --space together"
}

# --- library ----------------------------------------------------------------

test_lib_safe_id() {
  # shellcheck disable=SC2016  # $0 is expanded by the inner bash, not here.
  bash -c '
    . "$0/bin/fm-crowsnest-lib.sh"
    fmc_safe_id "chat-123-abc" || exit 1
    fmc_safe_id "../etc/passwd" && exit 1
    fmc_safe_id ".hidden" && exit 1
    fmc_safe_id "has space" && exit 1
    exit 0
  ' "$ROOT" || fail "fmc_safe_id must accept safe slugs and reject traversal/dot/space"
  pass "fmc_safe_id validates inbox slugs"
}

test_resolve_cli_prefers_new_name() {
  local home bin got
  home=$(make_home cli-name off)
  bin="$home/fakebin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n' > "$bin/local-agents"; chmod +x "$bin/local-agents"
  printf '#!/usr/bin/env bash\n' > "$bin/local-agents-chat"; chmod +x "$bin/local-agents-chat"
  # shellcheck disable=SC2016  # $0 is expanded by the inner bash, not here.
  got=$(env "PATH=$bin:$PATH" bash -c '. "$0/bin/fm-crowsnest-lib.sh"; fmc_resolve_cli' "$ROOT")
  case "$got" in
    */local-agents-chat) : ;;
    *) fail "fmc_resolve_cli must prefer local-agents-chat (got: $got)" ;;
  esac
  pass "fmc_resolve_cli prefers the renamed local-agents-chat CLI"
}

test_wire_unwire_shim() {
  local home shim
  home=$(make_home shim off)
  shim="$home/state/chat-watch.check.sh"
  # shellcheck disable=SC2016  # $FM_ROOT is expanded by the inner bash, not here.
  env FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$FM_ROOT/bin/fm-crowsnest-lib.sh"; fmc_wire_shim' \
    || fail "fmc_wire_shim must succeed"
  assert_present "$shim" "wire must create the check shim"
  [ -x "$shim" ] || fail "the check shim must be executable"
  assert_grep "fm-crowsnest-poll.sh" "$shim" "the shim must exec the poll script"
  assert_grep "$home" "$shim" "the shim must bake in the home"
  # shellcheck disable=SC2016  # $FM_ROOT is expanded by the inner bash, not here.
  env FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$FM_ROOT/bin/fm-crowsnest-lib.sh"; fmc_unwire_shim' \
    || fail "fmc_unwire_shim must succeed"
  assert_absent "$shim" "unwire must remove the check shim"
  pass "fmc_wire_shim / fmc_unwire_shim manage the watcher check shim"
}

# --- lifecycle CLI (fake local-agents) --------------------------------------

test_enable_wires_and_registers() {
  local home bin log mark out
  home=$(make_home life-enable off)
  log="$home/la.log"; mark="$home/la.mark"
  bin=$(make_fake_cli "$home" local-agents-chat)
  out=$( env "PATH=$bin:$PATH" FAKE_LA_LOG="$log" FAKE_LA_MARK="$mark" FM_HOME="$home" "$CLI" enable )
  assert_contains "$out" "enabled" "enable must report enabling"
  assert_contains "$out" "registered 'firstmate'" "enable must register the agent"
  assert_present "$home/state/chat-watch.check.sh" "enable must wire the check shim"
  assert_grep 'CROWSNEST_ENABLED=1' "$home/config/crowsnest.env" "enable must persist the flag"
  assert_grep 'register --name firstmate' "$log" "enable must call register with the firstmate name"
  assert_grep 'fm-crowsnest-relay.sh' "$log" "the registered command must be the relay"
  assert_grep "FM_HOME=$home" "$log" "the registered command must bake in this home"
  pass "enable wires the shim, persists the flag, and registers the relay"
}

test_disable_unwires_and_unregisters() {
  local home bin log mark
  home=$(make_home life-disable off)
  log="$home/la.log"; mark="$home/la.mark"
  bin=$(make_fake_cli "$home" local-agents-chat)
  env "PATH=$bin:$PATH" FAKE_LA_LOG="$log" FAKE_LA_MARK="$mark" FM_HOME="$home" "$CLI" enable >/dev/null
  env "PATH=$bin:$PATH" FAKE_LA_LOG="$log" FAKE_LA_MARK="$mark" FM_HOME="$home" "$CLI" disable >/dev/null
  assert_absent "$home/state/chat-watch.check.sh" "disable must remove the check shim"
  assert_grep 'CROWSNEST_ENABLED=0' "$home/config/crowsnest.env" "disable must clear the flag"
  assert_grep 'unregister --name firstmate' "$log" "disable must unregister the agent"
  pass "disable unwires the shim, clears the flag, and unregisters"
}

test_status_reports_registration_state() {
  local home bin log mark out
  home=$(make_home life-status off)
  log="$home/la.log"; mark="$home/la.mark"
  bin=$(make_fake_cli "$home" local-agents-chat)
  env "PATH=$bin:$PATH" FAKE_LA_LOG="$log" FAKE_LA_MARK="$mark" FM_HOME="$home" "$CLI" enable >/dev/null
  out=$( env "PATH=$bin:$PATH" FAKE_LA_LOG="$log" FAKE_LA_MARK="$mark" FM_HOME="$home" "$CLI" status )
  assert_contains "$out" "enabled        : yes" "status must show enabled"
  assert_contains "$out" "check shim     : present" "status must show the shim"
  assert_contains "$out" "registered     : yes" "status must detect registration"
  pass "status reports resolved config and registration state"
}

# --- bootstrap activation ---------------------------------------------------

test_bootstrap_arms_when_enabled() {
  local home out sum1 sum2 n
  home=$(make_home boot-on on)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "CROWSNEST: on" "bootstrap must announce the Crowsnest"
  assert_present "$home/state/chat-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/chat-watch.check.sh" ] || fail "the check shim must be executable"
  assert_grep "fm-crowsnest-poll.sh" "$home/state/chat-watch.check.sh" "the shim must exec the poll script"
  sum1=$(shasum < "$home/state/chat-watch.check.sh")
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(shasum < "$home/state/chat-watch.check.sh")
  [ "$sum1" = "$sum2" ] || fail "bootstrap Crowsnest setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'chat-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap arms the Crowsnest from config, idempotently"
}

test_bootstrap_inert_without_config() {
  local home out
  home=$(make_home boot-inert off)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "CROWSNEST:" "bootstrap must stay silent about the Crowsnest when unconfigured"
  assert_absent "$home/state/chat-watch.check.sh" "no shim without config"
  pass "bootstrap is inert about the Crowsnest without config"
}

test_bootstrap_opt_out_removes_shim() {
  local home out
  home=$(make_home boot-optout on)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/chat-watch.check.sh" "setup: shim armed"
  printf 'CROWSNEST_ENABLED=0\n' > "$home/config/crowsnest.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "CROWSNEST: off" "bootstrap must report the opt-out cleanup"
  assert_absent "$home/state/chat-watch.check.sh" "opt-out must remove the shim"
  pass "bootstrap removes the shim on opt-out"
}

test_relay_enabled_stashes_enqueues_and_acks
test_relay_disabled_is_inert
test_relay_empty_text_acks_without_inbox
test_poll_inert_when_disabled
test_poll_silent_when_inbox_empty
test_poll_surfaces_oldest_pending
test_poll_ignores_unsafe_stray_file
test_post_dry_run_reply_records_outbox
test_post_dry_run_proactive_space_thread
test_post_reply_unknown_id_errors
test_post_refuses_empty_text
test_post_rejects_reply_and_space_together
test_lib_safe_id
test_resolve_cli_prefers_new_name
test_wire_unwire_shim
test_enable_wires_and_registers
test_disable_unwires_and_unregisters
test_status_reports_registration_state
test_bootstrap_arms_when_enabled
test_bootstrap_inert_without_config
test_bootstrap_opt_out_removes_shim

echo "all fm-crowsnest tests passed"
