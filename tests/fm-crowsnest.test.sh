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

test_poll_skips_unsafe_and_surfaces_next_safe() {
  local home out
  home=$(make_home poll-skip on)
  mkdir -p "$home/state/chat-inbox"
  # An unsafe-named stray file is the OLDEST entry; it must not stall the waker -
  # the poll must skip it and surface the next-oldest SAFE pending message.
  : > "$home/state/chat-inbox/..evil.json"
  sleep 1
  : > "$home/state/chat-inbox/chat-9-safe.json"
  out=$(env FM_HOME="$home" "$POLL")
  assert_contains "$out" "chat-mention chat-9-safe" "poll must skip the unsafe stray and surface the next safe entry"
  pass "poll skips an unsafe stray and continues to the next safe pending entry"
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

# --- thread-context enrichment ----------------------------------------------

CTX_PY="$ROOT/bin/fm-crowsnest-context.py"
CTX_SH="$ROOT/bin/fm-crowsnest-context.sh"

# jq_true <json-string> <filter>: succeed iff the filter is truthy.
jq_true() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

# Write a fake spaces.messages.list response (newest-first) to a temp file and
# print its path. A prior captain msg, a firstmate reply, then the just-sent msg.
make_ctx_fixture() {
  local home=$1 fix
  fix="$home/ctx-fixture.json"
  cat > "$fix" <<'JSON'
{"messages":[
  {"name":"m3","sender":{"name":"users/cap","displayName":"Captain Marlon"},"text":"is the deploy green?","createTime":"2026-07-11T10:00:03Z"},
  {"name":"m2","sender":{"name":"users/bot","displayName":"firstmate"},"text":"Captain, the login PR is up: https://github.com/x/y/pull/9","createTime":"2026-07-11T10:00:02Z"},
  {"name":"m1","sender":{"name":"users/cap","displayName":"Captain Marlon"},"text":"how is the login fix going?","createTime":"2026-07-11T10:00:01Z"}
]}
JSON
  printf '%s' "$fix"
}

test_context_reader_builds_enrichment() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home fix out
  home=$(make_home ctx-reader on)
  fix=$(make_ctx_fixture "$home")
  out=$(FMC_CONTEXT_FIXTURE="$fix" python3 "$CTX_PY" \
    --space spaces/AAA --thread spaces/AAA/threads/T \
    --sender users/cap --exclude-text 'is the deploy green?' --limit 5)
  jq_true "$out" '.thread_context | length == 2' || fail "reader must drop the just-sent echo and keep 2 prior msgs"
  jq_true "$out" '.thread_context[0].text == "how is the login fix going?"' || fail "thread_context must be oldest-first"
  jq_true "$out" '.reply_to.sender == "users/bot"' || fail "reply_to must be the most recent prior (firstmate) message"
  jq_true "$out" '.sender_display_name == "Captain Marlon"' || fail "reader must harvest the captain's display name"
  pass "context reader dedups the echo, orders oldest-first, and extracts reply_to + display name"
}

test_context_reader_bounds_limit() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home fix out
  home=$(make_home ctx-bound on)
  fix="$home/big.json"
  {
    echo '{"messages":['
    for i in $(seq 1 12); do
      [ "$i" -gt 1 ] && echo ','
      printf '{"name":"m%s","sender":{"name":"users/cap","displayName":"Cap"},"text":"msg %s","createTime":"2026-07-11T10:%02d:00Z"}' "$i" "$i" "$i"
    done
    echo ']}'
  } > "$fix"
  out=$(FMC_CONTEXT_FIXTURE="$fix" python3 "$CTX_PY" \
    --space spaces/AAA --thread spaces/AAA/threads/T --limit 3)
  jq_true "$out" '.thread_context | length == 3' || fail "reader must bound thread_context to --limit"
  pass "context reader bounds thread_context to the requested limit"
}

test_context_sh_merges_into_inbox() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home id fix
  home=$(make_home ctx-merge on)
  printf 'is the deploy green?' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T' LOCAL_AGENTS_SENDER='users/cap' \
    CROWSNEST_THREAD_CONTEXT=0 "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "setup: relay must stash a base entry"
  assert_no_grep 'thread_context' "$home/state/chat-inbox/$id.json" "base entry must have no context yet"
  fix=$(make_ctx_fixture "$home")
  env FM_HOME="$home" FMC_CONTEXT_FIXTURE="$fix" "$CTX_SH" "$id"
  assert_grep '"thread_context"' "$home/state/chat-inbox/$id.json" "context.sh must merge thread_context into the inbox entry"
  assert_grep '"reply_to"' "$home/state/chat-inbox/$id.json" "context.sh must merge reply_to"
  assert_grep 'Captain Marlon' "$home/state/chat-inbox/$id.json" "context.sh must merge the captain display name"
  # The original base fields survive the merge.
  assert_grep '"text":"is the deploy green?"' "$home/state/chat-inbox/$id.json" "merge must preserve the original message text"
  pass "context.sh merges thread context into the inbox entry without losing base fields"
}

test_context_sh_no_thread_is_noop() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home id fix
  home=$(make_home ctx-nothread on)
  printf 'hello' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' LOCAL_AGENTS_SENDER='users/cap' \
    CROWSNEST_THREAD_CONTEXT=0 "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "setup: relay must stash"
  fix=$(make_ctx_fixture "$home")
  env FM_HOME="$home" FMC_CONTEXT_FIXTURE="$fix" "$CTX_SH" "$id"
  assert_no_grep 'thread_context' "$home/state/chat-inbox/$id.json" "a thread-less message must stay exactly as today"
  pass "context.sh is a no-op for a message with no thread"
}

test_context_sh_empty_messages_is_noop() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home id fix
  home=$(make_home ctx-empty on)
  printf 'q' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T' LOCAL_AGENTS_SENDER='users/cap' \
    CROWSNEST_THREAD_CONTEXT=0 "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "setup: relay must stash"
  fix="$home/empty.json"; echo '{"messages":[]}' > "$fix"
  env FM_HOME="$home" FMC_CONTEXT_FIXTURE="$fix" "$CTX_SH" "$id"
  assert_no_grep 'thread_context' "$home/state/chat-inbox/$id.json" "empty context must not rewrite the entry"
  pass "context.sh does not touch the entry when no thread messages come back"
}

test_context_sh_inert_when_disabled() {
  local home
  home=$(make_home ctx-disabled off)
  mkdir -p "$home/state/chat-inbox"
  printf '{"id":"chat-1-a","space":"spaces/A","thread":"spaces/A/threads/T","sender":"users/c","text":"hi"}' \
    > "$home/state/chat-inbox/chat-1-a.json"
  env FM_HOME="$home" "$CTX_SH" chat-1-a
  assert_no_grep 'thread_context' "$home/state/chat-inbox/chat-1-a.json" "context.sh must be inert when the Crowsnest is off"
  pass "context.sh is a hard no-op when the Crowsnest is disabled"
}

test_context_sh_never_resurrects_missing_entry() {
  # Guards the ctx-mv-resurrect fix: enrichment must never CREATE an inbox entry
  # that is not (or is no longer) present - otherwise a message the live session
  # already answered and deleted would be resurrected and re-surfaced as a
  # duplicate reply. Here the entry does not exist when enrichment runs.
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home fix
  home=$(make_home ctx-resurrect on)
  mkdir -p "$home/state/chat-inbox"
  fix=$(make_ctx_fixture "$home")
  env FM_HOME="$home" FMC_CONTEXT_FIXTURE="$fix" "$CTX_SH" chat-gone-1
  assert_absent "$home/state/chat-inbox/chat-gone-1.json" "enrichment must not create/resurrect a missing inbox entry"
  pass "context.sh never resurrects an inbox entry that is not present"
}

test_relay_sync_enrichment_merges_context() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home id fix out
  home=$(make_home relay-ctx on)
  fix=$(make_ctx_fixture "$home")
  out=$(printf 'is the deploy green?' | env FM_HOME="$home" FMC_CONTEXT_SYNC=1 FMC_CONTEXT_FIXTURE="$fix" \
    LOCAL_AGENTS_SPACE='spaces/AAA' LOCAL_AGENTS_THREAD='spaces/AAA/threads/T' \
    LOCAL_AGENTS_SENDER='users/cap' "$RELAY")
  assert_contains "$out" "On it, captain" "relay must still return the instant ack with enrichment on"
  id=$(first_inbox_id "$home") || fail "relay must stash a base entry"
  assert_grep '"thread_context"' "$home/state/chat-inbox/$id.json" "relay must enrich the entry with thread context"
  assert_grep 'Captain Marlon' "$home/state/chat-inbox/$id.json" "relay enrichment must include the display name"
  pass "relay enriches the inbox entry with thread context while still acking instantly"
}

test_relay_context_killswitch() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home id fix out
  home=$(make_home relay-ctx-off on)
  fix=$(make_ctx_fixture "$home")
  out=$(printf 'is the deploy green?' | env FM_HOME="$home" CROWSNEST_THREAD_CONTEXT=0 \
    FMC_CONTEXT_SYNC=1 FMC_CONTEXT_FIXTURE="$fix" \
    LOCAL_AGENTS_SPACE='spaces/AAA' LOCAL_AGENTS_THREAD='spaces/AAA/threads/T' \
    LOCAL_AGENTS_SENDER='users/cap' "$RELAY")
  assert_contains "$out" "On it, captain" "relay must ack even with context disabled"
  id=$(first_inbox_id "$home") || fail "relay must stash a base entry"
  assert_no_grep 'thread_context' "$home/state/chat-inbox/$id.json" "CROWSNEST_THREAD_CONTEXT=0 must disable enrichment"
  pass "CROWSNEST_THREAD_CONTEXT=0 reverts the relay to text-only stashing"
}

test_config_path_resolution_fixes_credentials() {
  # The credential bug: the post tool passed --config=None, and load_config(None)
  # reads NO file, leaving credentials_path empty -> ADC -> 403. The shared
  # resolver now falls back to the backend's default config path. This pins that
  # behavior hermetically with a fake config module (no backend needed).
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local out
  out=$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/bin")
import fm_crowsnest_chat as c

class FakeConfig:
    @staticmethod
    def default_config_path():
        return "/backend/default/config.toml"

assert c.resolve_config_path(FakeConfig, None) == "/backend/default/config.toml", "None must fall back to the backend default"
assert c.resolve_config_path(FakeConfig, "/explicit.toml") == "/explicit.toml", "explicit --config must win"
print("ok")
PY
)
  assert_contains "$out" "ok" "resolver must fall back to the backend default when --config is omitted"
  pass "shared resolver fixes the credential fallback (None -> backend default config path)"
}

# --- forwarded quote context (backend "Option A") ---------------------------
#
# The backend now forwards the TRUE replied-to/quoted message + sender display
# name to the relay as LOCAL_AGENTS_* env vars, so the relay populates reply
# context directly with NO Chat API read for the common Reply/Quote case. These
# are fixture-/env-driven and touch no network.

# entry_jq <home> <jq-filter>: succeed iff the filter is truthy against the
# home's single stashed inbox entry.
entry_jq() {
  local home=$1 filter=$2 id
  id=$(first_inbox_id "$home") || return 1
  jq -e "$filter" "$home/state/chat-inbox/$id.json" >/dev/null 2>&1
}

# A compact LOCAL_AGENTS_CONTEXT_JSON blob carrying a true inline quote.
QUOTE_CTX_JSON='{"sender_display_name":"Captain Marlon","space_display_name":"Ops","quoted_message":{"name":"spaces/AAA/messages/M1","quote_type":"REPLY","snapshot":{"text":"the login PR is up","formatted_text":"the *login PR* is up","sender":"firstmate","create_time":"2026-07-13T10:00:00Z"}}}'

test_relay_forwarded_quote_json_populates_entry() {
  local home
  home=$(make_home fwd-quote-json on)
  printf 'ship it' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' LOCAL_AGENTS_SENDER='users/cap' \
    LOCAL_AGENTS_CONTEXT_JSON="$QUOTE_CTX_JSON" "$RELAY" >/dev/null
  entry_jq "$home" '.sender_display_name == "Captain Marlon"' || fail "relay must set sender_display_name from the forwarded blob"
  entry_jq "$home" '.quoted.snapshot.text == "the login PR is up"' || fail "relay must stash the true quoted message text"
  entry_jq "$home" '.quoted.quote_type == "REPLY"' || fail "relay must preserve the quote type"
  entry_jq "$home" '.reply_to.text == "the login PR is up"' || fail "relay must set reply_to from the true quote"
  entry_jq "$home" '.reply_to.sender_display_name == "firstmate"' || fail "reply_to must name the quoted sender"
  pass "relay populates quoted/reply_to/sender_display_name from LOCAL_AGENTS_CONTEXT_JSON"
}

test_relay_forwarded_quote_scalar_fallback() {
  local home
  home=$(make_home fwd-quote-scalar on)
  # No JSON blob; only the convenience scalars are set.
  printf 'ok' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' LOCAL_AGENTS_SENDER='users/cap' \
    LOCAL_AGENTS_SENDER_DISPLAY_NAME='Cap' LOCAL_AGENTS_QUOTED_TEXT='prior message' \
    LOCAL_AGENTS_QUOTED_SENDER='firstmate' LOCAL_AGENTS_QUOTED_NAME='spaces/AAA/messages/M9' \
    "$RELAY" >/dev/null
  entry_jq "$home" '.sender_display_name == "Cap"' || fail "scalar fallback must set the display name"
  entry_jq "$home" '.quoted.name == "spaces/AAA/messages/M9"' || fail "scalar fallback must stash the quoted name"
  entry_jq "$home" '.quoted.snapshot.text == "prior message"' || fail "scalar fallback must stash the quoted text"
  entry_jq "$home" '.reply_to.text == "prior message"' || fail "scalar fallback must set reply_to"
  pass "relay falls back to the convenience scalars when no JSON blob is forwarded"
}

test_relay_forwarded_display_name_without_quote() {
  local home id
  home=$(make_home fwd-noquote on)
  printf 'hi' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' LOCAL_AGENTS_SENDER='users/cap' \
    LOCAL_AGENTS_CONTEXT_JSON='{"sender_display_name":"Cap","space_display_name":"Ops","quoted_message":null}' \
    "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "relay must stash"
  entry_jq "$home" '.sender_display_name == "Cap"' || fail "relay must set the display name even without a quote"
  assert_no_grep '"quoted"' "$home/state/chat-inbox/$id.json" "a no-quote entry must not carry a quoted field"
  assert_no_grep '"reply_to"' "$home/state/chat-inbox/$id.json" "a no-quote entry must not carry a reply_to field"
  pass "relay forwards the sender display name for a no-quote message without inventing a quote"
}

test_relay_no_forwarded_context_is_unchanged() {
  local home id
  home=$(make_home fwd-none on)
  printf 'plain message' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' LOCAL_AGENTS_SENDER='users/cap' "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "relay must stash"
  assert_no_grep 'sender_display_name' "$home/state/chat-inbox/$id.json" "no forwarded context must add no display name"
  assert_no_grep 'quoted' "$home/state/chat-inbox/$id.json" "no forwarded context must add no quoted field"
  assert_no_grep 'reply_to' "$home/state/chat-inbox/$id.json" "no forwarded context must add no reply_to"
  assert_grep '"text":"plain message"' "$home/state/chat-inbox/$id.json" "the base entry is stashed exactly as before"
  pass "relay stashes exactly as before when the backend forwards no context"
}

test_relay_forwarded_quote_killswitch() {
  local home id
  home=$(make_home fwd-kill on)
  printf 'x' | env FM_HOME="$home" CROWSNEST_THREAD_CONTEXT=0 LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' LOCAL_AGENTS_SENDER='users/cap' \
    LOCAL_AGENTS_CONTEXT_JSON="$QUOTE_CTX_JSON" "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "relay must stash"
  assert_no_grep 'quoted' "$home/state/chat-inbox/$id.json" "the kill switch must revert to text-only stashing"
  assert_no_grep 'sender_display_name' "$home/state/chat-inbox/$id.json" "the kill switch must drop forwarded context"
  pass "CROWSNEST_THREAD_CONTEXT=0 reverts forwarded-context stashing to text-only"
}

test_context_py_get_message_builds_enrichment() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home fix out
  home=$(make_home get-py on)
  fix="$home/get.json"
  cat > "$fix" <<'JSON'
{"name":"spaces/AAA/messages/M7","sender":{"name":"users/bot","displayName":"firstmate"},"text":"the login PR is up","formattedText":"the *login PR* is up","createTime":"2026-07-13T09:59:00Z"}
JSON
  out=$(FMC_GET_FIXTURE="$fix" python3 "$CTX_PY" --get-message spaces/AAA/messages/M7)
  jq_true "$out" '.reply_to.text == "the login PR is up"' || fail "get enrichment must carry reply_to text"
  jq_true "$out" '.reply_to.sender_display_name == "firstmate"' || fail "get enrichment reply_to must name the sender"
  jq_true "$out" '.quoted_snapshot.text == "the login PR is up"' || fail "get enrichment must carry the quoted snapshot text"
  jq_true "$out" '.quoted_snapshot.formatted_text == "the *login PR* is up"' || fail "get enrichment must carry formatted text"
  pass "context.py --get-message hydrates one quoted message into reply_to + quoted_snapshot"
}

test_context_sh_get_hydrates_name_only_quote() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home id fix
  home=$(make_home ctx-hydrate on)
  # Relay stashes a name-only quote (no inline snapshot text) - the report's F4 case.
  printf 'ship it' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' LOCAL_AGENTS_SENDER='users/cap' \
    LOCAL_AGENTS_CONTEXT_JSON='{"sender_display_name":"Cap","quoted_message":{"name":"spaces/AAA/messages/M7","quote_type":"REPLY"}}' \
    "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "relay must stash a name-only quote"
  entry_jq "$home" '.quoted.name == "spaces/AAA/messages/M7"' || fail "setup: the quote name must be stashed"
  entry_jq "$home" '.reply_to == null' || fail "setup: a name-only quote has no reply_to yet"
  fix="$home/get.json"
  cat > "$fix" <<'JSON'
{"name":"spaces/AAA/messages/M7","sender":{"name":"users/bot","displayName":"firstmate"},"text":"the login PR is up","createTime":"2026-07-13T09:59:00Z"}
JSON
  env FM_HOME="$home" FMC_GET_FIXTURE="$fix" "$CTX_SH" "$id"
  entry_jq "$home" '.quoted.snapshot.text == "the login PR is up"' || fail "get-hydrate must fill in the quoted snapshot text"
  entry_jq "$home" '.quoted.quote_type == "REPLY"' || fail "get-hydrate must preserve the original quote metadata"
  entry_jq "$home" '.reply_to.text == "the login PR is up"' || fail "get-hydrate must set reply_to from the fetched message"
  pass "context.sh hydrates a name-only forwarded quote via a single spaces.messages.get"
}

test_context_sh_inline_quote_skips_readback() {
  command -v python3 >/dev/null 2>&1 || { pass "python3 not installed, skipping"; return; }
  local home id fix before after
  home=$(make_home ctx-inline on)
  # Relay stashes an inline quote (text present) -> reply context is authoritative.
  printf 'ship it' | env FM_HOME="$home" LOCAL_AGENTS_SPACE='spaces/AAA' \
    LOCAL_AGENTS_THREAD='spaces/AAA/threads/T1' LOCAL_AGENTS_SENDER='users/cap' \
    LOCAL_AGENTS_CONTEXT_JSON="$QUOTE_CTX_JSON" "$RELAY" >/dev/null
  id=$(first_inbox_id "$home") || fail "relay must stash an inline quote"
  before=$(jq -c '.reply_to' "$home/state/chat-inbox/$id.json")
  # Even handed a list fixture that WOULD produce a different guess, context.sh
  # must not overwrite the authoritative forwarded reply_to.
  fix=$(make_ctx_fixture "$home")
  env FM_HOME="$home" FMC_CONTEXT_FIXTURE="$fix" "$CTX_SH" "$id"
  after=$(jq -c '.reply_to' "$home/state/chat-inbox/$id.json")
  [ "$before" = "$after" ] || fail "an inline forwarded quote must not be clobbered by the read-back"
  assert_no_grep 'thread_context' "$home/state/chat-inbox/$id.json" "an inline quote must skip the thread read entirely"
  pass "context.sh treats an inline forwarded quote as authoritative and skips the read-back"
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
test_poll_skips_unsafe_and_surfaces_next_safe
test_post_dry_run_reply_records_outbox
test_post_dry_run_proactive_space_thread
test_post_reply_unknown_id_errors
test_post_refuses_empty_text
test_post_rejects_reply_and_space_together
test_context_reader_builds_enrichment
test_context_reader_bounds_limit
test_context_sh_merges_into_inbox
test_context_sh_no_thread_is_noop
test_context_sh_empty_messages_is_noop
test_context_sh_inert_when_disabled
test_context_sh_never_resurrects_missing_entry
test_relay_sync_enrichment_merges_context
test_relay_context_killswitch
test_config_path_resolution_fixes_credentials
test_relay_forwarded_quote_json_populates_entry
test_relay_forwarded_quote_scalar_fallback
test_relay_forwarded_display_name_without_quote
test_relay_no_forwarded_context_is_unchanged
test_relay_forwarded_quote_killswitch
test_context_py_get_message_builds_enrichment
test_context_sh_get_hydrates_name_only_quote
test_context_sh_inline_quote_skips_readback
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
