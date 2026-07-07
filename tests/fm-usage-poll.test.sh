#!/usr/bin/env bash
# tests/fm-usage-poll.test.sh - behavior tests for the token-usage ledger poll
# (bin/fm-usage-poll.sh). Exercises the correctness rules from the design:
# content-block requestId dedup, cross-file resume-fork dedup, <synthetic> skip,
# subagent (recursive glob) inclusion, per-record mid-session cwd change,
# incremental offset resume, and idempotent re-run (no double-append).
#
# Hermetic: a temp FM_HOME plus a temp transcript dir via FM_USAGE_TRANSCRIPTS_DIR.
# jq is the real tool (the poll requires it); no network is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-usage-poll: jq unavailable, skipping"; exit 0; }

POLL="$ROOT/bin/fm-usage-poll.sh"
TMP=$(fm_test_tmproot fm-usage-poll)
HOME_DIR="$TMP/home"
TX="$TMP/tx/proj"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$TX/subagents"

# A live task meta whose worktree matches the fixture cwd.
fm_write_meta "$HOME_DIR/state/fix-a-k1.meta" \
  "worktree=/work/wt-a" "project=/home/u/Reposit/myapp" "harness=claude" "kind=ship" "model=default"

run_poll() {
  FM_HOME="$HOME_DIR" FM_USAGE_TRANSCRIPTS_DIR="$TMP/tx" "$POLL" --quiet
}
LEDGER="$HOME_DIR/data/usage/ledger.jsonl"
count() { [ -s "$LEDGER" ] && grep -c . "$LEDGER" || printf '0'; }
field() { jq -r "select(.request_id==\"$1\") | .$2" "$LEDGER" 2>/dev/null; }

# assistant record helper: $1 rid, $2 sessionId, $3 cwd, $4 model, $5 in, $6 out,
# $7 gitBranch, $8 isSidechain, $9 file (appended)
arec() {
  jq -cn --arg rid "$1" --arg sid "$2" --arg cwd "$3" --arg model "$4" \
    --argjson in "$5" --argjson out "$6" --arg branch "$7" --argjson side "$8" \
    '{type:"assistant",requestId:$rid,uuid:($rid+"-"+(now|tostring)),timestamp:"2026-07-07T07:42:07.667Z",
      cwd:$cwd,gitBranch:$branch,sessionId:$sid,version:"2.1.202",isSidechain:$side,
      message:{model:$model,usage:{input_tokens:$in,output_tokens:$out,cache_read_input_tokens:1,cache_creation_input_tokens:2}}}' \
    >> "$9"
}

# --- fixture: sess1 with a 3-content-block request + a <synthetic> record ------
S1="$TX/sess1.jsonl"
: > "$S1"
printf '%s\n' '{"type":"user","message":{"role":"user"}}' >> "$S1"
arec req_1 sess1 /work/wt-a claude-opus-4-8 100 20 fm/fix-a-k1 false "$S1"
arec req_1 sess1 /work/wt-a claude-opus-4-8 100 20 fm/fix-a-k1 false "$S1"
arec req_1 sess1 /work/wt-a claude-opus-4-8 100 20 fm/fix-a-k1 false "$S1"
arec req_syn sess1 /work/wt-a '<synthetic>' 0 0 fm/fix-a-k1 false "$S1"

# subagent transcript (recursive glob inclusion)
SUB="$TX/subagents/agent-1.jsonl"
: > "$SUB"
arec req_sub sess1 /work/wt-a claude-opus-4-8 10 2 fm/fix-a-k1 true "$SUB"

run_poll >/dev/null 2>&1

# content-block dedup: req_1 recorded exactly once
[ "$(jq -r 'select(.request_id=="req_1")|.request_id' "$LEDGER" | grep -c .)" = 1 ] \
  || fail "content-block dedup: req_1 should appear exactly once"
[ "$(field req_1 input_tokens)" = 100 ] || fail "req_1 tokens wrong"
# <synthetic> skipped
[ -z "$(field req_syn request_id)" ] || fail "<synthetic> record must be skipped"
# subagent included and attributed to the same task
[ "$(field req_sub task_id)" = fix-a-k1 ] || fail "subagent record must be included and attributed"
[ "$(field req_sub input_tokens)" = 10 ] || fail "subagent tokens misaligned (empty-field collapse regression)"
# attribution used the transcript's real model, not meta's default
[ "$(field req_1 model)" = claude-opus-4-8 ] || fail "should prefer transcript model over meta default"
[ "$(field req_1 project)" = myapp ] || fail "project should be the meta project leaf"
pass "content-block dedup, <synthetic> skip, subagent inclusion, model/project attribution"

# --- cross-file resume-fork dedup ---------------------------------------------
S2="$TX/sess2.jsonl"
: > "$S2"
arec req_1 sess2 /work/wt-a claude-opus-4-8 100 20 "" false "$S2"   # replay of req_1 -> must dedup
arec req_2 sess2 /work/wt-a claude-fable-5 200 40 "" false "$S2"    # new request
run_poll >/dev/null 2>&1
[ "$(jq -r 'select(.request_id=="req_1")|.request_id' "$LEDGER" | grep -c .)" = 1 ] \
  || fail "resume-fork dedup: req_1 replayed in a second file must not double-count"
[ "$(field req_2 input_tokens)" = 200 ] || fail "new request req_2 should be recorded"
pass "cross-file resume-fork dedup"

# --- idempotent re-run (no changes -> no new lines) ---------------------------
before=$(count)
run_poll >/dev/null 2>&1
[ "$(count)" = "$before" ] || fail "idempotent re-run appended duplicates ($before -> $(count))"
pass "idempotent re-run"

# --- incremental offset resume (append one record, only it is read) -----------
arec req_3 sess2 /work/wt-a claude-opus-4-8 7 3 "" false "$S2"
run_poll >/dev/null 2>&1
[ "$(count)" = "$((before + 1))" ] || fail "incremental resume should add exactly one line"
[ "$(field req_3 output_tokens)" = 3 ] || fail "appended req_3 not recorded"
pass "incremental offset resume"

# --- mid-session cwd change: a record under a different cwd, no live meta ------
# The frozen per-session snapshot must still attribute it to the task.
arec req_cwd sess1 /some/other/dir claude-opus-4-8 1 1 main false "$S1"
run_poll >/dev/null 2>&1
[ "$(field req_cwd task_id)" = fix-a-k1 ] \
  || fail "mid-session cwd change should attribute via the frozen session snapshot"
pass "mid-session cwd change via frozen snapshot"

# --- uncategorised bucket for an unknown session + cwd ------------------------
UNK="$TX/sessX.jsonl"
: > "$UNK"
arec req_unk sessX /home/cap/other-repo claude-opus-4-8 9 9 dev false "$UNK"
run_poll >/dev/null 2>&1
[ "$(field req_unk is_uncategorised)" = true ] || fail "unknown session/cwd should be uncategorised"
[ "$(field req_unk project)" = other-repo ] || fail "uncategorised should tag the cwd project leaf"
pass "uncategorised bucket"

# --- ledger never contains transcript message content (privacy) ---------------
if grep -q '"content"\|"role"' "$LEDGER" 2>/dev/null; then
  fail "ledger must not contain transcript message content"
fi
pass "ledger carries only counts + attribution metadata (no message content)"

pass "fm-usage-poll: all checks passed"
