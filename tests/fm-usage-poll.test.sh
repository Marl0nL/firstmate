#!/usr/bin/env bash
# tests/fm-usage-poll.test.sh - behavior tests for the token-usage ledger poll
# (bin/fm-usage-poll.sh). Exercises the correctness rules from the design:
# content-block requestId dedup, cross-file resume-fork dedup, <synthetic> skip,
# subagent (recursive glob) inclusion, per-record mid-session cwd change,
# incremental offset resume, and idempotent re-run (no double-append). Also covers
# the quota-severity wake DEBOUNCE (fm_usage_confirmed_level / record_severity and
# the end-to-end poll wake): a lone extreme reading never wakes, a sustained
# crossing still alarms on the first confirmation, and a drop re-arms the alarm.
#
# Hermetic: a temp FM_HOME plus a temp transcript dir via FM_USAGE_TRANSCRIPTS_DIR.
# jq is the real tool (the poll requires it); no network is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-usage-poll: jq unavailable, skipping"; exit 0; }

POLL="$ROOT/bin/fm-usage-poll.sh"
fm_test_tmproot TMP fm-usage-poll
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

# --- --if-due: the decoupled, self-gated wake-drain trigger -------------------
# It must (1) stay inert unless the monitor is opted in, (2) run and mark on the
# first opted-in call, (3) skip a rescan within the min-interval even with new
# data present, and (4) always dedupe so no combination double-counts.
MARKER="$HOME_DIR/data/usage/.last-poll"
run_ifdue() { # extra env assignments passed as $@
  env "$@" FM_HOME="$HOME_DIR" FM_USAGE_TRANSCRIPTS_DIR="$TMP/tx" "$POLL" --if-due
}

# (1) monitor OFF: a new record is NOT ingested and no marker is written.
arec req_off sess2 /work/wt-a claude-opus-4-8 5 5 "" false "$S2"
before=$(count)
run_ifdue FM_USAGE_ENABLED=0 >/dev/null 2>&1
[ "$(count)" = "$before" ] || fail "--if-due must be inert while the monitor is opted out"
[ -z "$(field req_off request_id)" ] || fail "--if-due must not ingest while opted out"
[ ! -e "$MARKER" ] || fail "--if-due must not write the min-interval marker while opted out"
pass "--if-due is inert while the monitor is opted out"

# (2) monitor ON, marker absent: the new record IS ingested and the marker set.
run_ifdue FM_USAGE_ENABLED=1 >/dev/null 2>&1
[ "$(count)" = "$((before + 1))" ] || fail "first opted-in --if-due should ingest the pending record"
[ "$(field req_off input_tokens)" = 5 ] || fail "opted-in --if-due should record the new request"
[ -e "$MARKER" ] || fail "opted-in --if-due should write the min-interval marker"
pass "--if-due ingests and marks on the first opted-in run"

# (3) marker fresh, default interval: a further record is NOT rescanned.
arec req_skip sess2 /work/wt-a claude-opus-4-8 6 6 "" false "$S2"
after_first=$(count)
run_ifdue FM_USAGE_ENABLED=1 >/dev/null 2>&1
[ "$(count)" = "$after_first" ] || fail "--if-due within the min-interval must skip the rescan"
[ -z "$(field req_skip request_id)" ] || fail "skipped --if-due must not ingest the new record yet"
pass "--if-due honors the min-interval (skips the rescan when marked recently)"

# (4) interval disabled: the deferred record is caught up, deduped, once.
run_ifdue FM_USAGE_ENABLED=1 FM_USAGE_POLL_MIN_INTERVAL=0 >/dev/null 2>&1
[ "$(count)" = "$((after_first + 1))" ] || fail "--if-due with interval 0 should catch up exactly the one new record"
[ "$(field req_skip output_tokens)" = 6 ] || fail "the deferred record should be recorded after the interval gate is disabled"
[ "$(jq -r 'select(.request_id=="req_off")|.request_id' "$LEDGER" | grep -c .)" = 1 ] \
  || fail "--if-due must not double-count across runs"
pass "--if-due catches up once the interval elapses, without double-counting"

# (5) the marker is advanced only AFTER a real scan: a held single-writer lock
# must defer the scan without ingesting or advancing .last-poll, so the next
# --if-due still catches up rather than being suppressed for the interval.
rm -f "$MARKER"
arec req_lock sess2 /work/wt-a claude-opus-4-8 7 7 "" false "$S2"
LOCKDIR="$HOME_DIR/data/usage/.poll.lock"
mkdir "$LOCKDIR"                       # simulate a concurrent poll holding the lock
before_lock=$(count)
run_ifdue FM_USAGE_ENABLED=1 >/dev/null 2>&1
[ "$(count)" = "$before_lock" ] || fail "--if-due must not ingest while the single-writer lock is held"
[ ! -e "$MARKER" ] || fail "--if-due must NOT advance the marker when the held lock blocked the scan"
rmdir "$LOCKDIR"
run_ifdue FM_USAGE_ENABLED=1 >/dev/null 2>&1   # lock free: catch up the deferred record
[ "$(count)" = "$((before_lock + 1))" ] || fail "--if-due should catch up once the lock frees (marker was not suppressed)"
[ "$(field req_lock output_tokens)" = 7 ] || fail "the lock-deferred record should be recorded on the next run"
pass "--if-due advances the marker only after a real scan (held lock defers, never suppresses)"

# --- quota-severity wake debounce --------------------------------------------
# The wake DECISION is debounced so a lone intermittent extreme between normal
# reads never cries wolf, while a genuine SUSTAINED crossing still alarms promptly
# and re-arms after it eases. Three layers: the pure confirmed-level function, the
# stateful recorder (history + watermark + re-arm), and the end-to-end poll wake.

LIB="$ROOT/bin/fm-usage-lib.sh"

# The pure debounced level: the highest level the last N samples ALL reach.
lvl_confirm() {  # <n> <levels oldest..newest...>
  FM_HOME="$HOME_DIR" bash -c '. "$1"; shift; fm_usage_confirmed_level "$@"' _ "$LIB" "$@"
}
[ "$(lvl_confirm 2 0 2)"   = 0 ] || fail "confirmed_level: a lone spike (0,2) must not confirm"
[ "$(lvl_confirm 2 2 2)"   = 2 ] || fail "confirmed_level: two consecutive criticals confirm 2"
[ "$(lvl_confirm 2 2)"     = 0 ] || fail "confirmed_level: a single critical (cold start) must not confirm"
[ "$(lvl_confirm 2 2 0)"   = 0 ] || fail "confirmed_level: (2,0) confirms 0"
[ "$(lvl_confirm 2 1 1)"   = 1 ] || fail "confirmed_level: two consecutive warnings confirm 1"
[ "$(lvl_confirm 3 2 2 2)" = 2 ] || fail "confirmed_level: N=3 needs three consecutive"
[ "$(lvl_confirm 3 2 0 2)" = 0 ] || fail "confirmed_level: N=3 with a normal in between confirms 0"
[ "$(lvl_confirm 2 2 2 0)" = 0 ] || fail "confirmed_level: only the last N count - (...,2,0) is 0"
[ "$(lvl_confirm 2 0 2 2)" = 2 ] || fail "confirmed_level: only the last N count - (...,2,2) is 2"
pass "confirmed-level debounce: lone spikes never confirm; N consecutive samples do"

# The stateful recorder: appends the inspectable history, decides the wake, and
# tracks the last-surfaced confirmed level in the watermark (rises, then re-arms).
rec() {  # <home> <level> -> "<rc> <confirmed>"  (rc 0 == a wake should surface)
  local out rc
  out=$(FM_HOME="$1" bash -c '. "$1"; fm_usage_record_severity "$2"' _ "$LIB" "$2"); rc=$?
  printf '%s %s' "$rc" "$out"
}
rec_env() {  # <home> <level> <env=val...> -> "<rc> <confirmed>"
  local home=$1 level=$2; shift 2
  local out rc
  # The $1/$2 in the single quotes are the inner bash's positional args (the lib
  # path and the level), not this shell's. The env prefix hides the bash -c from
  # the linter's usual special-casing, so an explicit disable is needed here.
  # shellcheck disable=SC2016
  out=$(env "$@" FM_HOME="$home" bash -c '. "$1"; fm_usage_record_severity "$2"' _ "$LIB" "$level"); rc=$?
  printf '%s %s' "$rc" "$out"
}

SEV="$TMP/sev"; mkdir -p "$SEV/data/usage"
WM="$SEV/data/usage/severity-watermark"
HIST="$SEV/data/usage/severity-history"

# (1) A lone extreme between normal reads produces NO wake.
[ "$(rec "$SEV" 0)" = "1 0" ] || fail "recorder: a normal sample is silent (confirmed 0)"
[ "$(rec "$SEV" 2)" = "1 0" ] || fail "recorder: a critical bracketed by a normal read must not wake"
[ "$(rec "$SEV" 0)" = "1 0" ] || fail "recorder: returning to normal after a lone spike is silent"
[ "$(cat "$WM")" = 0 ] || fail "recorder: watermark stays 0 through a lone spike"
[ "$(grep -c . "$HIST")" = 3 ] || fail "recorder: history appends one line per sample (inspectable)"
[ "$(awk -F'\t' 'NR==2{print $3"/"$4"/"$5}' "$HIST")" = "2/0/0" ] \
  || fail "recorder: the spike line records raw=2 confirmed=0 emitted=0"

# (2) A genuine SUSTAINED critical still alarms - on the first CONFIRMED crossing.
[ "$(rec "$SEV" 2)" = "1 0" ] || fail "recorder: first critical (recent read normal) is still bracketed"
[ "$(rec "$SEV" 2)" = "0 2" ] || fail "recorder: the second consecutive critical CONFIRMS and wakes"
[ "$(cat "$WM")" = 2 ] || fail "recorder: watermark rises to 2 on the confirmed critical"
[ "$(rec "$SEV" 2)" = "1 2" ] || fail "recorder: a sustained critical is deduped, not re-fired"

# (3) The transition back down to normal RE-ARMS the alarm for a later crossing.
[ "$(rec "$SEV" 0)" = "1 0" ] || fail "recorder: recovery to normal is silent"
[ "$(cat "$WM")" = 0 ] || fail "recorder: watermark falls back to 0 (re-armed)"
[ "$(rec "$SEV" 2)" = "1 0" ] || fail "recorder: re-armed first critical is bracketed"
[ "$(rec "$SEV" 2)" = "0 2" ] || fail "recorder: re-armed second consecutive critical wakes AGAIN"
pass "recorder debounce: lone spike suppressed, sustained alarms promptly, re-arms after recovery"

# Sustained WARNING surfaces a warning wake on its second consecutive sample.
SEVW="$TMP/sevw"; mkdir -p "$SEVW/data/usage"
[ "$(rec "$SEVW" 1)" = "1 0" ] || fail "recorder: a lone warning is bracketed"
[ "$(rec "$SEVW" 1)" = "0 1" ] || fail "recorder: two consecutive warnings surface a warning"
pass "recorder debounce: warning level confirms on its own"

# The confirm count is a config knob but is clamped to a floor of 2: a value of 1
# (which would be no debounce - the original bug) must NOT restore cry-wolf.
SEVC="$TMP/sevc"; mkdir -p "$SEVC/data/usage"
[ "$(rec_env "$SEVC" 2 FM_USAGE_ALARM_CONFIRM=1)" = "1 0" ] \
  || fail "recorder: FM_USAGE_ALARM_CONFIRM=1 must be clamped to 2 - a single critical cannot fire"
[ "$(rec_env "$SEVC" 2 FM_USAGE_ALARM_CONFIRM=1)" = "0 2" ] \
  || fail "recorder: clamped N=2 fires on the second consecutive critical"
# A larger confirm count defers confirmation to N consecutive samples.
SEV3="$TMP/sev3"; mkdir -p "$SEV3/data/usage"
[ "$(rec_env "$SEV3" 2 FM_USAGE_ALARM_CONFIRM=3)" = "1 0" ] || fail "recorder: N=3 first critical no fire"
[ "$(rec_env "$SEV3" 2 FM_USAGE_ALARM_CONFIRM=3)" = "1 0" ] || fail "recorder: N=3 second critical no fire yet"
[ "$(rec_env "$SEV3" 2 FM_USAGE_ALARM_CONFIRM=3)" = "0 2" ] || fail "recorder: N=3 third consecutive critical fires"
pass "recorder debounce: confirm count is clamped >=2 and honors a larger N"

# End-to-end through the poll: a stub quota command feeds the wake path (mirrors
# fm-usage-guard.sh's FM_USAGE_QUOTA_CMD seam) so no network/credentials are used.
mkqc() {  # <path> <signal-json>
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s\n' '$2'
SH
  chmod +x "$1"
}
sigwin() { printf '{"source":"live","degraded":false,"windows":{"session":%s,"weekly":{"percent":57,"severity":"normal"},"scoped":[]}}' "$1"; }
CRITCMD="$TMP/qc-crit"; mkqc "$CRITCMD" "$(sigwin '{"percent":100,"severity":"critical","resets_at":"R"}')"
NORMCMD="$TMP/qc-norm"; mkqc "$NORMCMD" "$(sigwin '{"percent":1,"severity":"normal"}')"

E2E="$TMP/e2e"; mkdir -p "$E2E/state" "$E2E/data" "$E2E/tx"
poll_wake() {  # <quota-cmd>
  env FM_USAGE_QUOTA_CMD="$1" FM_USAGE_ENABLED=1 FM_USAGE_GUARD_ENABLED=1 \
      FM_HOME="$E2E" FM_USAGE_TRANSCRIPTS_DIR="$E2E/tx" "$POLL" 2>/dev/null
}
assert_not_contains "$(poll_wake "$CRITCMD")" "usage-quota" "e2e: first critical must not wake (bracketed)"
assert_contains     "$(poll_wake "$CRITCMD")" "usage-quota critical" "e2e: second consecutive critical wakes"
assert_not_contains "$(poll_wake "$CRITCMD")" "usage-quota" "e2e: a sustained critical is deduped"
assert_not_contains "$(poll_wake "$NORMCMD")" "usage-quota" "e2e: recovery to normal re-arms silently"
assert_not_contains "$(poll_wake "$CRITCMD")" "usage-quota" "e2e: re-armed first critical is bracketed"
assert_contains     "$(poll_wake "$CRITCMD")" "usage-quota critical" "e2e: re-armed second critical wakes again"
pass "e2e poll wake: sustained critical alarms once per crossing, lone samples never do"

# End-to-end lone spike: normal, one critical, normal -> the poll never wakes.
E2S="$TMP/e2s"; mkdir -p "$E2S/state" "$E2S/data" "$E2S/tx"
poll_spike() { env FM_USAGE_QUOTA_CMD="$1" FM_USAGE_ENABLED=1 FM_USAGE_GUARD_ENABLED=1 \
      FM_HOME="$E2S" FM_USAGE_TRANSCRIPTS_DIR="$E2S/tx" "$POLL" 2>/dev/null; }
assert_not_contains "$(poll_spike "$NORMCMD")" "usage-quota" "e2e spike: a normal read is silent"
assert_not_contains "$(poll_spike "$CRITCMD")" "usage-quota" "e2e spike: a lone critical does not wake"
assert_not_contains "$(poll_spike "$NORMCMD")" "usage-quota" "e2e spike: back to normal, the spike stayed suppressed"
[ "$(grep -c . "$E2S/data/usage/severity-history")" = 3 ] || fail "e2e spike: all three samples are on the inspectable history"
pass "e2e poll wake: a lone intermittent critical is fully suppressed"

pass "fm-usage-poll: all checks passed"
