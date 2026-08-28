#!/usr/bin/env bash
# Behavior tests for the wake-resident secondmate lifecycle:
# bin/fm-wake-resident.sh, bin/fm-wake-resident-poll.sh, and the
# bin/fm-bootstrap.sh liveness-sweep exemption that keeps a deliberately dormant
# secondmate from being resurrected every session start.
#
# The mocks here are lifecycle-specific (a format-aware fake tmux that can pose a
# pane as running an agent or sitting at a bare shell, plus a recording fake
# fm-spawn/fm-send injected through FM_ROOT_OVERRIDE), so they live with this
# suite rather than in tests/lib.sh.
#
# The case that matters most is standdown_preserves_home_and_lease: a stand-down
# is an EXIT, not a teardown, and a stand-down that quietly released the treehouse
# lease or removed the home would destroy a persistent agent that was only meant
# to be asleep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WR="$ROOT/bin/fm-wake-resident.sh"
POLL="$ROOT/bin/fm-wake-resident-poll.sh"

# --- fixtures ---------------------------------------------------------------

# A format-aware fake tmux. `display-message -p -t <target> '<fmt>'` answers:
#   #{pane_id}              - succeeds while $FM_FAKE_PANE_PRESENT is 1
#   #{pane_current_command} - prints $FM_FAKE_PANE_COMMAND, so a test can pose the
#                             pane as a live agent (claude) or a bare shell (bash)
# capture-pane prints $FM_FAKE_PANE_CAPTURE so the busy-signature reader has
# something deterministic to look at.
make_wr_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_PANE_PRESENT:-1}" = 1 ] || exit 1
    for a in "$@"; do
      case "$a" in
        '#{pane_current_command}')
          # Read the FILE, not a captured env var: the pane's command changes
          # mid-run (a spawn starts an agent, an exit leaves a bare shell) and a
          # probe issued after that must see the new value.
          if [ -f "${FM_FAKE_PANE_COMMAND_FILE:-}" ]; then
            cat "$FM_FAKE_PANE_COMMAND_FILE"
          else
            printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}"
          fi
          exit 0
          ;;
        '#{pane_id}') printf '%%1\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "${FM_FAKE_PANE_CAPTURE:-idle prompt}"
    exit 0
    ;;
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
    exit 0
    ;;
  list-windows)
    # The trunk's process-group agent-state inventory greps list-windows for the
    # exact window name before it reads the pane command, so a present pane must
    # list its window; an absent one lists nothing and reads as a missing endpoint.
    printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
    [ "${FM_FAKE_PANE_PRESENT:-1}" = 1 ] || exit 0
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-advisor}"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# A fabricated FM_ROOT holding ONLY the two scripts fm-wake-resident.sh shells
# out to. FM_ROOT_OVERRIDE redirects those calls here while SCRIPT_DIR still
# resolves the real libraries, so the tests exercise the real decision logic and
# only stub the launch and the keystroke.
make_wr_root() {
  local dir=$1 root="$1/fakeroot"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'spawn %s\n' "$*" >> "$FM_FAKE_SPAWN_LOG"
[ -z "${FM_FAKE_SPAWN_FAIL:-}" ] || exit 9
# A real secondmate spawn leaves an agent running in the pane.
printf 'claude\n' > "$FM_FAKE_PANE_COMMAND_FILE"
exit 0
SH
  cat > "$root/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'send %s\n' "$*" >> "$FM_FAKE_SEND_LOG"
# The settle race: the agent exited between the stand-down's liveness read and
# the keystroke, so the composer refuses to type into what is now a bare shell.
if [ -n "${FM_FAKE_SEND_REFUSE_SHELL:-}" ]; then
  printf 'bash\n' > "$FM_FAKE_PANE_COMMAND_FILE"
  exit 1
fi
[ -z "${FM_FAKE_SEND_FAIL:-}" ] || exit 1
# A submitted exit command leaves the pane at a bare shell - unless the test is
# posing the case where the agent accepts the keystroke and keeps running.
[ -n "${FM_FAKE_SEND_NO_EXIT:-}" ] || printf 'bash\n' > "$FM_FAKE_PANE_COMMAND_FILE"
exit 0
SH
  chmod +x "$root/bin/fm-spawn.sh" "$root/bin/fm-send.sh"
  printf '%s\n' "$root"
}

# Build a main home plus one seeded secondmate home for <name>, and echo the
# main home path. The secondmate home carries the artifacts a stand-down must
# never touch: the seed marker, a backlog, a status file, and a treehouse lease
# record standing in for the pool slot.
new_world() {  # <tmp> <name>
  local tmp=$1 name=$2 home sub
  home="$tmp/main"
  sub="$tmp/homes/$name"
  mkdir -p "$home/state" "$home/config" "$home/data" "$sub/state" "$sub/data"
  printf '%s\n' "$name" > "$sub/.fm-secondmate-home"
  printf '# Firstmate\n' > "$sub/AGENTS.md"
  printf '# Backlog\n\n## In flight\n- [ ] keep-me\n' > "$sub/data/backlog.md"
  printf 'working: earlier phase\n' > "$home/state/$name.status"
  printf '%s\n' "$name" > "$tmp/lease"
  printf -- "- %s - advisor charter (home: %s; scope: advice; projects: ; added 2026-07-31)\n" \
    "$name" "$sub" > "$home/data/secondmates.md"
  fm_write_meta "$home/state/$name.meta" \
    "window=firstmate:fm-$name" \
    "worktree=$sub" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$sub"
  printf '%s\n' "$home"
}

# Run a wake-resident command in the fixture environment.
wr() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_FAKE_PANE_COMMAND="$(cat "$PANE_CMD_FILE")" \
    "$WR" "$@" 2>&1
}

poll() {  # <home>
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_PANE_COMMAND="$(cat "$PANE_CMD_FILE")" \
    "$POLL" 2>&1
}

pose_pane() {  # <command>
  printf '%s\n' "$1" > "$PANE_CMD_FILE"
}

# Backdate every activity signal so the fixture reads as long-quiet.
make_quiet() {  # <home> <name> <secs-ago>
  local home=$1 name=$2 ago=$3 sub when
  sub=$(sed -n 's/^home=//p' "$home/state/$name.meta")
  when=$(( $(date +%s) - ago ))
  printf 'raised_at=%s\n' "$when" > "$home/state/$name.wake-resident"
  chmod 600 "$home/state/$name.wake-resident"
  touch -d "@$when" "$home/state/$name.meta" 2>/dev/null || touch -t "$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null)" "$home/state/$name.meta"
  find "$sub/state" -mindepth 1 -maxdepth 1 -exec touch -d "@$when" {} + 2>/dev/null || true
}

TMP=$(fm_test_tmproot fm-wake-resident)
FAKEBIN=$(make_wr_tmux "$TMP")
FAKE_ROOT=$(make_wr_root "$TMP")
PATH="$FAKEBIN:$PATH"
export PATH
PANE_CMD_FILE="$TMP/pane-command"
export FM_FAKE_PANE_COMMAND_FILE="$PANE_CMD_FILE"
export FM_FAKE_SPAWN_LOG="$TMP/spawn.log"
export FM_FAKE_SEND_LOG="$TMP/send.log"
export FM_FAKE_TMUX_LOG="$TMP/tmux.log"
# Every fixture launches its secondmate in window firstmate:fm-advisor, so the
# fake tmux's list-windows inventory reports that window name when a pane exists.
export FM_FAKE_TMUX_WINDOW="fm-advisor"
: > "$FM_FAKE_SPAWN_LOG"
: > "$FM_FAKE_SEND_LOG"
pose_pane bash

# --- tests ------------------------------------------------------------------

test_inert_without_config() {
  local home out
  home=$(new_world "$TMP/inert" advisor)
  out=$(poll "$home")
  [ -z "$out" ] || fail "poll must be a hard no-op with no wake-resident config, got: $out"
  assert_absent "$home/state/wake-resident.check.sh" "sync must not wire a shim with no records"
  pass "the poll is inert and silent until a home opts in"
}

test_enable_wires_and_registers_both_shims() {
  local home out sub
  home=$(new_world "$TMP/enable" advisor)
  sub="$TMP/enable/homes/advisor"
  out=$(wr "$home" enable advisor --idle-secs 1800)
  assert_contains "$out" "advisor enabled" "enable did not report success: $out"
  assert_present "$home/state/wake-resident.check.sh" "enable did not write the main lifecycle shim"
  assert_present "$home/state/wake-resident.check-trust" "enable did not register the main lifecycle shim"
  assert_present "$sub/state/wake-self.check.sh" "enable did not write the in-home inbox shim"
  assert_present "$sub/state/wake-self.check-trust" "enable did not register the in-home inbox shim"
  assert_present "$sub/state/chat-inbox" "enable did not create the default inbox dir"
  assert_grep "advisor idle-secs=1800" "$home/config/wake-resident.conf" "enable did not record the config line"
  out=$(wr "$home" status advisor)
  assert_contains "$out" "inbox shim    : present, registered" "status must confirm the in-home shim is registered: $out"
  pass "enable wires and registers both check shims through the trust path"
}

test_message_to_dormant_emits_one_raise_line() {
  local home out
  home=$(new_world "$TMP/raise-line" advisor)
  wr "$home" enable advisor >/dev/null
  pose_pane bash
  out=$(poll "$home")
  [ -z "$out" ] || fail "an empty inbox must stay silent, got: $out"
  printf '{}' > "$TMP/raise-line/homes/advisor/state/chat-inbox/m1.json"
  out=$(poll "$home")
  assert_contains "$out" "wake-resident advisor: 1 pending message(s), dormant - raise it" \
    "poll did not offer to raise a dormant secondmate with pending mail: $out"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "poll must emit exactly one line, got: $out"
  out=$(poll "$home")
  [ -z "$out" ] || fail "poll must self-throttle a repeated raise offer, got: $out"
  pass "a message to a dormant secondmate produces exactly one throttled raise line"
}

test_resident_with_mail_stays_quiet_then_backstops() {
  local home out inbox
  home=$(new_world "$TMP/deliver" advisor)
  wr "$home" enable advisor --grace-secs 300 >/dev/null
  pose_pane claude
  inbox="$TMP/deliver/homes/advisor/state/chat-inbox"
  printf '{}' > "$inbox/m1.json"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a fresh message to a RESIDENT secondmate is its own shim's job, got: $out"
  touch -d "@$(( $(date +%s) - 900 ))" "$inbox/m1.json"
  out=$(poll "$home")
  assert_contains "$out" "wake-resident advisor: message m1 unread" \
    "poll did not backstop a message left unread past grace-secs: $out"
  pass "a resident secondmate's mail is its own to drain, with a main-home backstop past grace"
}

test_self_shim_surfaces_pending_message() {
  local home sub out
  home=$(new_world "$TMP/selfshim" advisor)
  wr "$home" enable advisor >/dev/null
  sub="$TMP/selfshim/homes/advisor"
  out=$(FM_HOME="$sub" "$POLL" --self "$sub/state/chat-inbox" 2>&1)
  [ -z "$out" ] || fail "the in-home shim must stay silent on an empty inbox, got: $out"
  printf '{}' > "$sub/state/chat-inbox/m7.json"
  out=$(FM_HOME="$sub" "$POLL" --self "$sub/state/chat-inbox" 2>&1)
  assert_contains "$out" "wake-resident message m7 pending" \
    "the in-home shim did not surface the pending entry: $out"
  pass "the in-home shim surfaces a pending message so a resident agent sees it on its own turn"
}

test_first_message_can_raise_a_never_launched_home() {
  local home out sub
  home=$(new_world "$TMP/first" advisor)
  sub="$TMP/first/homes/advisor"
  # A seeded, registered home that has never been launched has no meta at all.
  rm -f "$home/state/advisor.meta"
  wr "$home" enable advisor >/dev/null
  assert_present "$sub/state/wake-self.check.sh" "sync must resolve the home from the registry when no meta exists yet"
  printf '{}' > "$sub/state/chat-inbox/m1.json"
  out=$(poll "$home")
  assert_contains "$out" "dormant - raise it" \
    "the FIRST message to a never-launched wake-resident home must still raise it: $out"
  : > "$FM_FAKE_SPAWN_LOG"
  out=$(wr "$home" raise advisor)
  assert_contains "$out" "advisor raised" "the first raise failed: $out"
  assert_grep "spawn advisor --secondmate" "$FM_FAKE_SPAWN_LOG" "the first raise did not use the normal spawn path"
  pass "the first message raises a seeded home that has never been launched"
}

test_raise_uses_the_normal_spawn_path() {
  local home out
  home=$(new_world "$TMP/raise" advisor)
  wr "$home" enable advisor >/dev/null
  pose_pane bash
  out=$(wr "$home" raise advisor)
  assert_contains "$out" "advisor raised" "raise did not report success: $out"
  assert_grep "spawn advisor --secondmate" "$FM_FAKE_SPAWN_LOG" \
    "raise must go through the ordinary guarded secondmate spawn, not a parallel path"
  assert_grep "raised_at=" "$home/state/advisor.wake-resident" "raise did not record raised_at"
  pass "raise is bin/fm-spawn.sh <name> --secondmate and nothing else"
}

test_double_wake_raises_one_advisor() {
  local home out
  home=$(new_world "$TMP/double" advisor)
  wr "$home" enable advisor >/dev/null
  pose_pane bash
  : > "$FM_FAKE_SPAWN_LOG"

  # Simultaneous: the claim is already held when the second raise arrives.
  mkdir "$home/state/.advisor.wake-raise.claim"
  out=$(wr "$home" raise advisor) && fail "a raise must refuse while another holds the claim: $out"
  assert_contains "$out" "already in flight" "the losing raise gave the wrong reason: $out"
  [ ! -s "$FM_FAKE_SPAWN_LOG" ] || fail "the losing raise must not spawn: $(cat "$FM_FAKE_SPAWN_LOG")"
  rmdir "$home/state/.advisor.wake-raise.claim"

  # Sequential: the first raise wins and leaves the secondmate resident, so the
  # second is a no-op rather than a second agent in one home.
  wr "$home" raise advisor >/dev/null
  out=$(wr "$home" raise advisor)
  assert_contains "$out" "already up" "the second raise did not report an already-resident secondmate: $out"
  [ "$(grep -c 'spawn advisor' "$FM_FAKE_SPAWN_LOG")" = 1 ] \
    || fail "two wakes produced more than one spawn: $(cat "$FM_FAKE_SPAWN_LOG")"
  pass "two wakes arriving together raise exactly one advisor"
}

test_raise_refuses_on_inconclusive_liveness() {
  local home out
  home=$(new_world "$TMP/unknown" advisor)
  wr "$home" enable advisor >/dev/null
  # A bare interpreter name is the documented `unknown` shape for the tmux probe.
  pose_pane node
  : > "$FM_FAKE_SPAWN_LOG"
  out=$(wr "$home" raise advisor) && fail "raise must refuse an inconclusive liveness read: $out"
  assert_contains "$out" "duplicate supervisor" "the refusal did not name the hazard: $out"
  [ ! -s "$FM_FAKE_SPAWN_LOG" ] || fail "an inconclusive read must never license a spawn"
  pass "an inconclusive liveness read licenses neither a raise nor a duplicate supervisor"
}

test_no_standdown_with_work_in_flight() {
  local home out sub
  home=$(new_world "$TMP/inflight" advisor)
  wr "$home" enable advisor >/dev/null
  sub="$TMP/inflight/homes/advisor"
  pose_pane claude
  make_quiet "$home" advisor 7200
  fm_write_meta "$sub/state/child-task.meta" "worktree=$sub/wt" "kind=ship"

  out=$(poll "$home")
  [ -z "$out" ] || fail "poll must not offer a stand-down while the home has work in flight, got: $out"

  out=$(wr "$home" standdown advisor) && fail "standdown must refuse with work in flight: $out"
  assert_contains "$out" "still has work in flight" "the refusal did not name the reason: $out"
  out=$(wr "$home" standdown advisor --force) && fail "--force must NOT waive the work-in-flight refusal: $out"
  assert_contains "$out" "still has work in flight" "--force wrongly waived the work-in-flight gate: $out"
  [ ! -s "$FM_FAKE_SEND_LOG" ] || fail "a refused stand-down must send nothing: $(cat "$FM_FAKE_SEND_LOG")"
  pass "no stand-down while the secondmate has work in flight, with or without --force"
}

test_no_standdown_with_unanswered_message() {
  local home out
  home=$(new_world "$TMP/unanswered" advisor)
  wr "$home" enable advisor >/dev/null
  pose_pane claude
  make_quiet "$home" advisor 7200
  printf '{}' > "$TMP/unanswered/homes/advisor/state/chat-inbox/m1.json"
  : > "$FM_FAKE_SEND_LOG"
  out=$(wr "$home" standdown advisor --force) && fail "standdown must refuse an unanswered message: $out"
  assert_contains "$out" "unanswered message" "the refusal did not name the reason: $out"
  [ ! -s "$FM_FAKE_SEND_LOG" ] || fail "a refused stand-down must send nothing"
  pass "no stand-down while a message is unanswered, even with --force"
}

test_no_standdown_before_the_idle_threshold() {
  local home out
  home=$(new_world "$TMP/tooearly" advisor)
  wr "$home" enable advisor --idle-secs 1800 >/dev/null
  pose_pane claude
  make_quiet "$home" advisor 60
  out=$(poll "$home")
  [ -z "$out" ] || fail "poll must not offer a stand-down 60s into a 1800s threshold, got: $out"
  out=$(wr "$home" standdown advisor) && fail "standdown must refuse before the idle threshold: $out"
  assert_contains "$out" "of the required 1800s" "the refusal did not report the threshold: $out"
  pass "no stand-down before the configured quiet period has actually elapsed"
}

test_standdown_records_a_self_exited_agent() {
  local home out sub lease_before meta_before
  home=$(new_world "$TMP/selfexit" advisor)
  sub="$TMP/selfexit/homes/advisor"
  wr "$home" enable advisor --idle-secs 1800 >/dev/null
  # The agent has already exited itself: the pane is a bare shell, exactly the
  # dormant-healthy shape a self-exited claude leaves behind. No quiet backdating,
  # to prove the quiet-time gate is irrelevant once the agent is already gone.
  pose_pane bash
  : > "$FM_FAKE_SEND_LOG"
  lease_before=$(cat "$TMP/selfexit/lease")
  meta_before=$(cat "$home/state/advisor.meta")

  out=$(wr "$home" standdown advisor)
  assert_contains "$out" "already exited; recorded stand-down" \
    "standdown must record a self-exited agent as a completed stand-down: $out"

  # Nothing is typed at a bare shell - the whole point of the fix.
  [ ! -s "$FM_FAKE_SEND_LOG" ] || fail "a self-exited stand-down must send nothing: $(cat "$FM_FAKE_SEND_LOG")"
  assert_grep "dormant_since=" "$home/state/advisor.wake-resident" "a self-exited stand-down must record dormancy"

  # An exit is not a teardown, on this path exactly as on the submitted-exit one.
  assert_present "$sub" "a self-exited stand-down removed the secondmate home"
  assert_present "$sub/.fm-secondmate-home" "a self-exited stand-down removed the seeded-home marker"
  assert_grep "keep-me" "$sub/data/backlog.md" "a self-exited stand-down damaged the secondmate backlog"
  assert_present "$TMP/selfexit/lease" "a self-exited stand-down released the treehouse lease"
  [ "$(cat "$TMP/selfexit/lease")" = "$lease_before" ] || fail "a self-exited stand-down altered the lease record"
  [ "$(cat "$home/state/advisor.meta")" = "$meta_before" ] || fail "a self-exited stand-down rewrote the task meta"
  assert_present "$home/state/advisor.status" "a self-exited stand-down removed the status file"
  assert_grep "advisor" "$home/data/secondmates.md" "a self-exited stand-down unregistered the secondmate"
  pass "a stand-down of an already-self-exited agent records dormancy with no pane submission"
}

test_self_exited_standdown_still_refuses_work_and_mail() {
  local home out sub
  home=$(new_world "$TMP/selfexit-refuse" advisor)
  sub="$TMP/selfexit-refuse/homes/advisor"
  wr "$home" enable advisor >/dev/null
  # Self-exited shape, but with the two never-waive conditions present: the
  # already-exited success path must run AFTER those refusals, never around them.
  pose_pane bash

  # Unanswered mail: refuse, record nothing, send nothing.
  printf '{}' > "$sub/state/chat-inbox/m1.json"
  : > "$FM_FAKE_SEND_LOG"
  out=$(wr "$home" standdown advisor) \
    && fail "a self-exited stand-down must still refuse an unanswered message: $out"
  assert_contains "$out" "unanswered message" "the refusal did not name the reason: $out"
  assert_absent "$home/state/advisor.wake-resident" "a refused self-exited stand-down must record no dormancy"
  [ ! -s "$FM_FAKE_SEND_LOG" ] || fail "a refused stand-down must send nothing"
  rm -f "$sub/state/chat-inbox/m1.json"

  # Work in flight: refuse, even though the agent process itself is already gone.
  fm_write_meta "$sub/state/child-task.meta" "worktree=$sub/wt" "kind=ship"
  out=$(wr "$home" standdown advisor --force) \
    && fail "a self-exited stand-down must still refuse work in flight, even with --force: $out"
  assert_contains "$out" "still has work in flight" "the refusal did not name the reason: $out"
  assert_absent "$home/state/advisor.wake-resident" "a refused self-exited stand-down must record no dormancy"
  pass "the already-exited success path still refuses work in flight and unanswered mail"
}

test_standdown_records_a_settle_race_self_exit() {
  local home out sub
  home=$(new_world "$TMP/settle" advisor)
  sub="$TMP/settle/homes/advisor"
  wr "$home" enable advisor --idle-secs 1800 >/dev/null
  make_quiet "$home" advisor 7200
  # The settle race: the agent exits right as the stand-down starts, so the
  # liveness read still says resident, and the exit command then meets a bare
  # shell the composer refuses to type into.
  pose_pane claude
  : > "$FM_FAKE_SEND_LOG"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" FM_FAKE_SEND_REFUSE_SHELL=1 \
    "$WR" standdown advisor 2>&1) \
    || fail "a send refused by a now-dormant pane must complete the stand-down: $out"
  assert_contains "$out" "already exited; recorded stand-down" \
    "the settle-race stand-down did not report the self-exited outcome: $out"
  assert_grep "dormant_since=" "$home/state/advisor.wake-resident" \
    "the settle-race stand-down must record dormancy"
  assert_present "$sub" "the settle-race stand-down removed the secondmate home"
  assert_present "$sub/.fm-secondmate-home" "the settle-race stand-down removed the seeded-home marker"
  assert_grep "keep-me" "$sub/data/backlog.md" "the settle-race stand-down damaged the secondmate backlog"
  assert_present "$TMP/settle/lease" "the settle-race stand-down released the treehouse lease"
  assert_present "$home/state/advisor.meta" "the settle-race stand-down dropped the task meta"
  pass "a send refusal whose re-read finds a bare shell records the stand-down instead of failing"
}

test_standdown_send_failure_still_fails_while_resident() {
  local home out
  home=$(new_world "$TMP/sendfail" advisor)
  wr "$home" enable advisor --idle-secs 1800 >/dev/null
  make_quiet "$home" advisor 7200
  # A genuine send failure with the agent still alive: the pane never flips to a
  # bare shell, so the re-read still says resident and the failure must stand.
  pose_pane claude
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" FM_FAKE_SEND_FAIL=1 FM_FAKE_SEND_NO_EXIT=1 \
    "$WR" standdown advisor 2>&1) \
    && fail "a send failure against a still-resident agent must still fail: $out"
  assert_contains "$out" "it is still up" "the failure did not name the reason: $out"
  assert_no_grep "dormant_since=" "$home/state/advisor.wake-resident" \
    "a failed stand-down against a resident agent must record no dormancy"
  pass "a send failure whose re-read still sees a resident agent stays a failure"
}

test_standdown_preserves_home_and_lease() {
  local home out sub lease_before meta_before
  home=$(new_world "$TMP/standdown" advisor)
  sub="$TMP/standdown/homes/advisor"
  wr "$home" enable advisor --idle-secs 1800 >/dev/null
  pose_pane claude
  make_quiet "$home" advisor 7200
  lease_before=$(cat "$TMP/standdown/lease")
  meta_before=$(cat "$home/state/advisor.meta")

  out=$(poll "$home")
  assert_contains "$out" "wake-resident advisor: quiet" "poll did not offer the stand-down: $out"
  assert_contains "$out" "nothing in flight - stand it down" "the stand-down line lost its reason: $out"

  out=$(wr "$home" standdown advisor)
  assert_contains "$out" "advisor stood down" "standdown did not report success: $out"
  assert_grep "/exit" "$FM_FAKE_SEND_LOG" "standdown did not submit the harness exit command"
  assert_no_grep "fm-from-firstmate" "$FM_FAKE_SEND_LOG" \
    "the exit command must go to the backend target, unmarked - a marked /exit is not an exit"

  # THE POINT OF THE WHOLE MECHANISM: an exit is not a teardown.
  assert_present "$sub" "stand-down removed the secondmate home"
  assert_present "$sub/.fm-secondmate-home" "stand-down removed the seeded-home marker"
  assert_present "$sub/data/backlog.md" "stand-down removed the secondmate backlog"
  assert_grep "keep-me" "$sub/data/backlog.md" "stand-down damaged the secondmate backlog"
  assert_present "$TMP/standdown/lease" "stand-down released the treehouse lease"
  [ "$(cat "$TMP/standdown/lease")" = "$lease_before" ] || fail "stand-down altered the lease record"
  assert_present "$home/state/advisor.meta" "stand-down dropped state/advisor.meta - the worktree lease record"
  [ "$(cat "$home/state/advisor.meta")" = "$meta_before" ] || fail "stand-down rewrote the task meta"
  assert_present "$home/state/advisor.status" "stand-down removed the status file"
  assert_grep "advisor" "$home/data/secondmates.md" "stand-down unregistered the secondmate"
  assert_grep "dormant_since=" "$home/state/advisor.wake-resident" "stand-down did not record dormancy"
  assert_contains "$out" "its identity and state are intact" \
    "stand-down must report the persistent axis explicitly, not just success: $out"
  pass "an idle stand-down exits the process and leaves home, lease, meta, backlog and status intact"
}

test_persistence_invariant_catches_a_loss() {
  local home sub snap out
  home=$(new_world "$TMP/persist" advisor)
  sub="$TMP/persist/homes/advisor"
  printf 'You are the advisor.\n' > "$sub/data/charter.md"
  snap="$TMP/persist/snapshot"

  # The manifest is the enumeration of the PERSISTENT axis. Every artifact that
  # carries the identity across a process exit must be in it.
  out=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_persistence_manifest "$2" advisor "$3" "$4"' \
    _ "$ROOT" "$home/state" "$sub" "$home/data")
  assert_contains "$out" "$sub/.fm-secondmate-home" "the manifest lost the seeded-home identity marker"
  assert_contains "$out" "$sub/data/charter.md" "the manifest lost the charter"
  assert_contains "$out" "$sub/data/backlog.md" "the manifest lost the backlog"
  assert_contains "$out" "$home/state/advisor.meta" "the manifest lost the meta that carries the worktree lease"
  assert_contains "$out" "$home/state/advisor.status" "the manifest lost the status log"
  assert_contains "$out" "$home/data/secondmates.md" "the manifest lost the registry route"

  bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_persistence_snapshot "$2" advisor "$3" "$4"' \
    _ "$ROOT" "$home/state" "$sub" "$home/data" > "$snap"

  # Intact: silent, exit 0. Growth is normal - an agent appending a status line on
  # its way out has not lost anything.
  printf 'done: answered\n' >> "$home/state/advisor.status"
  out=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_persistence_verify "$2"' _ "$ROOT" "$snap") \
    || fail "an intact (and grown) identity must verify clean, got: $out"
  [ -z "$out" ] || fail "a clean verify must print nothing, got: $out"

  # Removal is a loss.
  rm -f "$sub/.fm-secondmate-home"
  out=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_persistence_verify "$2"' _ "$ROOT" "$snap") \
    && fail "a removed identity marker must fail verification"
  assert_contains "$out" "LOST file $sub/.fm-secondmate-home" "the loss was not reported by path: $out"

  # Truncation is a loss too - a backlog emptied is a backlog destroyed.
  printf '%s\n' "$sub" > "$sub/.fm-secondmate-home"
  : > "$sub/data/backlog.md"
  out=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_persistence_verify "$2"' _ "$ROOT" "$snap") \
    && fail "a truncated backlog must fail verification"
  assert_contains "$out" "TRUNCATED $sub/data/backlog.md" "the truncation was not reported by path: $out"

  # And a removed HOME is the teardown-shaped catastrophe the check exists for.
  rm -rf "$sub"
  out=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_persistence_verify "$2"' _ "$ROOT" "$snap") \
    && fail "a removed home must fail verification"
  assert_contains "$out" "LOST directory $sub" "a removed home was not reported: $out"

  # Sizes must be BARE DIGITS on every platform: macOS `wc -c` pads its output,
  # and a padded value would fail the all-digits guard and silently skip the
  # shrinkage check on exactly the platform that pads.
  out=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; printf "[%s]" "$(fm_wr_byte_size "$2")"' \
    _ "$ROOT" "$ROOT/AGENTS.md")
  case "$out" in
    '['[0-9]*']') : ;;
    *) fail "fm_wr_byte_size must print bare digits, got: $out" ;;
  esac
  out=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_byte_size "$2"' _ "$ROOT" "$TMP/no-such-file" 2>&1)
  [ "$out" = 0 ] || fail "a missing file must read as 0 with no stray stderr, got: $out"
  pass "the persistence invariant catches removal and truncation, and treats growth as normal"
}

test_next_message_wakes_it_again() {
  local home out
  home=$(new_world "$TMP/again" advisor)
  wr "$home" enable advisor --idle-secs 1800 >/dev/null
  pose_pane claude
  make_quiet "$home" advisor 7200
  wr "$home" standdown advisor >/dev/null
  : > "$FM_FAKE_SPAWN_LOG"

  # A message landing right after the stand-down must not wait out the previous
  # decision's throttle: losing a message is worse than an extra wake.
  printf '{}' > "$TMP/again/homes/advisor/state/chat-inbox/m2.json"
  out=$(poll "$home")
  assert_contains "$out" "dormant - raise it" "the next message did not re-raise the dormant secondmate: $out"
  out=$(wr "$home" raise advisor)
  assert_contains "$out" "advisor raised" "the second raise failed: $out"
  assert_grep "spawn advisor --secondmate" "$FM_FAKE_SPAWN_LOG" "the second raise did not use the normal spawn path"
  pass "the next message wakes it again through the same path"
}

test_standdown_refuses_unknown_harness_exit() {
  local home out
  home=$(new_world "$TMP/grok" advisor)
  wr "$home" enable advisor >/dev/null
  sed -i.bak 's/^harness=claude$/harness=grok/' "$home/state/advisor.meta"
  rm -f "$home/state/advisor.meta.bak"
  pose_pane grok
  make_quiet "$home" advisor 7200
  : > "$FM_FAKE_SEND_LOG"
  out=$(wr "$home" standdown advisor) && fail "standdown must refuse a harness with no submittable exit: $out"
  assert_contains "$out" "no submittable exit command" "the refusal did not name the reason: $out"
  [ ! -s "$FM_FAKE_SEND_LOG" ] || fail "a refused stand-down must send nothing"
  pass "stand-down refuses a harness whose exit is not a submittable line, rather than half-sending it"
}

test_standdown_leaves_it_alone_when_the_exit_does_not_confirm() {
  local home out sub
  home=$(new_world "$TMP/noconfirm" advisor)
  sub="$TMP/noconfirm/homes/advisor"
  wr "$home" enable advisor >/dev/null
  pose_pane claude
  make_quiet "$home" advisor 7200
  # The send succeeds but the agent keeps running.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_WR_STANDDOWN_TIMEOUT=1 FM_FAKE_SEND_NO_EXIT=1 \
    "$WR" standdown advisor 2>&1) && fail "standdown must fail when the exit never confirms: $out"
  assert_contains "$out" "did not confirm its exit" "the failure did not name the reason: $out"
  assert_contains "$out" "rather than killing" "the failure must say it declined to escalate to a kill: $out"
  assert_present "$sub" "a non-confirming stand-down must still leave the home alone"
  pass "a stand-down whose exit never confirms leaves the agent alone instead of killing it"
}

test_disable_leaves_the_home_intact() {
  local home out sub
  home=$(new_world "$TMP/disable" advisor)
  sub="$TMP/disable/homes/advisor"
  wr "$home" enable advisor >/dev/null
  out=$(wr "$home" disable advisor)
  assert_contains "$out" "disabled" "disable did not report success: $out"
  assert_absent "$sub/state/wake-self.check.sh" "disable left the in-home shim behind"
  assert_absent "$sub/state/wake-self.check-trust" "disable left the in-home trust record behind"
  assert_absent "$home/state/wake-resident.check.sh" "disable left the lifecycle shim behind with no records"
  assert_present "$sub" "disable removed the secondmate home"
  assert_present "$home/state/advisor.meta" "disable removed the task meta"
  assert_grep "advisor" "$home/data/secondmates.md" "disable unregistered the secondmate"
  pass "disable removes the wiring and nothing else"
}

test_poll_is_silent_in_away_mode() {
  local home out
  home=$(new_world "$TMP/afk" advisor)
  wr "$home" enable advisor >/dev/null
  pose_pane bash
  printf '{}' > "$TMP/afk/homes/advisor/state/chat-inbox/m1.json"
  : > "$home/state/.afk"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the poll must stay silent while the away daemon owns supervision, got: $out"
  pass "the poll goes silent in away mode rather than queueing work the daemon cannot authorize"
}

test_unsafe_and_unknown_records_are_dropped() {
  local home out
  home=$(new_world "$TMP/records" advisor)
  mkdir -p "$home/config"
  cat > "$home/config/wake-resident.conf" <<'EOF'
# comment only
../escape idle-secs=60
adv* idle-secs=60
advisor idle-secs=notanumber grace-secs=0 inbox=relative/path
advisor idle-secs=99
EOF
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      . "$1/bin/fm-wake-resident-lib.sh"
      fm_wr_names "$2"
      fm_wr_load "$2" advisor && printf "idle=%s grace=%s inbox=%s\n" "$FM_WR_IDLE_SECS" "$FM_WR_GRACE_SECS" "${FM_WR_INBOX:-default}"
    ' _ "$ROOT" "$home/config")
  assert_not_contains "$out" "escape" "an unsafe record name must be dropped, not resolved"
  assert_not_contains "$out" "adv*" "a glob-shaped record name must be dropped, not resolved"
  assert_contains "$out" "idle=1800 grace=300 inbox=default" \
    "invalid field values must fall back to defaults rather than be trusted: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^advisor$')" = 1 ] \
    || fail "a duplicate record must not produce a second name: $out"

  # A `*` in the file must stay a literal that fails validation, never a glob
  # expanded against the working directory - this parse decides what gets spawned.
  printf 'advisor inbox=/nowhere/*\n' > "$home/config/wake-resident.conf"
  out=$(cd "$TMP" && bash -c '
      . "$1/bin/fm-wake-resident-lib.sh"
      fm_wr_load "$2" advisor && printf "inbox=%s\n" "$FM_WR_INBOX"
      case $- in *f*) printf "LEAKED-NOGLOB\n" ;; esac
    ' _ "$ROOT" "$home/config")
  assert_contains "$out" "inbox=/nowhere/*" "a glob in a record value must stay literal: $out"
  assert_not_contains "$out" "LEAKED-NOGLOB" "the parser leaked its noglob setting back to the caller"
  pass "unsafe names, globs, bad values, and duplicate records are dropped rather than guessed at"
}

test_liveness_sweep_exempts_a_dormant_wake_resident() {
  local home out sub
  home=$(new_world "$TMP/sweep" advisor)
  sub="$TMP/sweep/homes/advisor"
  pose_pane bash
  : > "$FM_FAKE_SPAWN_LOG"

  # Without a record the sweep sees a dead agent behind a live shell and respawns.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_FAKE_PANE_COMMAND=bash bash -c '
      SCRIPT_DIR="$1/bin"
      FM_ROOT="$2"
      STATE="$3"
      CONFIG="$4"
      first_line() { head -1; }
      # The trunk sweep is timed and split into a per-secondmate body plus a
      # relaunch reporter, so extract that whole set and source the timing lib to
      # run the sweep exactly as bootstrap does. local_phase is stubbed because
      # report_relaunch consults it and bootstrap itself is not sourced here.
      local_phase() { return 0; }
      . "$1/bin/fm-backend.sh"
      . "$1/bin/fm-timing-lib.sh"
      . "$1/bin/fm-wake-resident-lib.sh"
      eval "$(awk "/^report_relaunch\\(\\)/,/^}/" "$1/bin/fm-bootstrap.sh")"
      eval "$(awk "/^secondmate_liveness_one\\(\\)/,/^}/" "$1/bin/fm-bootstrap.sh")"
      eval "$(awk "/^secondmate_liveness_sweep\\(\\)/,/^}/" "$1/bin/fm-bootstrap.sh")"
      secondmate_liveness_sweep
    ' _ "$ROOT" "$FAKE_ROOT" "$home/state" "$home/config" 2>&1)
  assert_grep "spawn advisor --secondmate" "$FM_FAKE_SPAWN_LOG" \
    "the control case must respawn an ordinary dead secondmate (sweep output: $out)"

  # With a record, the same dormant shape must be left alone.
  : > "$FM_FAKE_SPAWN_LOG"
  wr "$home" enable advisor >/dev/null
  # Reset the shared pane-command file the control sub-case's respawn left at
  # `claude`: without this the exempt sweep would read a LIVE agent and skip it
  # regardless of the exemption, so the assertions below would pass vacuously.
  # `bash` restores the dead-agent-behind-a-live-shell shape the exemption exists
  # for, making the exemption the only reason the sweep leaves it alone.
  pose_pane bash
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_FAKE_PANE_COMMAND=bash bash -c '
      SCRIPT_DIR="$1/bin"
      FM_ROOT="$2"
      STATE="$3"
      CONFIG="$4"
      first_line() { head -1; }
      # The trunk sweep is timed and split into a per-secondmate body plus a
      # relaunch reporter, so extract that whole set and source the timing lib to
      # run the sweep exactly as bootstrap does. local_phase is stubbed because
      # report_relaunch consults it and bootstrap itself is not sourced here.
      local_phase() { return 0; }
      . "$1/bin/fm-backend.sh"
      . "$1/bin/fm-timing-lib.sh"
      . "$1/bin/fm-wake-resident-lib.sh"
      eval "$(awk "/^report_relaunch\\(\\)/,/^}/" "$1/bin/fm-bootstrap.sh")"
      eval "$(awk "/^secondmate_liveness_one\\(\\)/,/^}/" "$1/bin/fm-bootstrap.sh")"
      eval "$(awk "/^secondmate_liveness_sweep\\(\\)/,/^}/" "$1/bin/fm-bootstrap.sh")"
      secondmate_liveness_sweep
    ' _ "$ROOT" "$FAKE_ROOT" "$home/state" "$home/config" 2>&1)
  [ ! -s "$FM_FAKE_SPAWN_LOG" ] \
    || fail "the liveness sweep resurrected a deliberately dormant wake-resident secondmate: $(cat "$FM_FAKE_SPAWN_LOG")"
  [ -z "$out" ] || fail "the exempt sweep must stay silent, got: $out"
  assert_present "$sub" "the sweep must not touch the dormant home"
  pass "the session-start liveness sweep leaves a dormant wake-resident secondmate asleep"
}

test_exit_commands_match_harness_adapters() {
  local skill harness documented actual
  skill="$ROOT/.agents/skills/harness-adapters/SKILL.md"
  assert_present "$skill" "the harness-adapters skill is missing"
  for harness in claude codex opencode pi; do
    documented=$(awk -v h="$harness" '
      $0 ~ "^## " h "( |$)" { inblock = 1; next }
      inblock && /^## / { exit }
      inblock && /^\| Exit command \|/ { print; exit }
    ' "$skill")
    [ -n "$documented" ] || fail "harness-adapters has no Exit command row for $harness"
    actual=$(bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_exit_command "$2"' _ "$ROOT" "$harness")
    case "$documented" in
      *"\`$actual\`"*) : ;;
      *) fail "fm_wr_exit_command $harness returns '$actual' but harness-adapters documents: $documented" ;;
    esac
  done
  bash -c '. "$1/bin/fm-wake-resident-lib.sh"; fm_wr_exit_command grok' _ "$ROOT" >/dev/null 2>&1 \
    && fail "grok must have no submittable exit command (its exit is an interactive double Ctrl+Q)"
  pass "the executable exit-command table agrees with harness-adapters"
}

test_inert_without_config
test_enable_wires_and_registers_both_shims
test_message_to_dormant_emits_one_raise_line
test_resident_with_mail_stays_quiet_then_backstops
test_self_shim_surfaces_pending_message
test_first_message_can_raise_a_never_launched_home
test_raise_uses_the_normal_spawn_path
test_double_wake_raises_one_advisor
test_raise_refuses_on_inconclusive_liveness
test_no_standdown_with_work_in_flight
test_no_standdown_with_unanswered_message
test_no_standdown_before_the_idle_threshold
test_standdown_records_a_self_exited_agent
test_self_exited_standdown_still_refuses_work_and_mail
test_standdown_records_a_settle_race_self_exit
test_standdown_send_failure_still_fails_while_resident
test_standdown_preserves_home_and_lease
test_persistence_invariant_catches_a_loss
test_next_message_wakes_it_again
test_standdown_refuses_unknown_harness_exit
test_standdown_leaves_it_alone_when_the_exit_does_not_confirm
test_disable_leaves_the_home_intact
test_poll_is_silent_in_away_mode
test_unsafe_and_unknown_records_are_dropped
test_liveness_sweep_exempts_a_dormant_wake_resident
test_exit_commands_match_harness_adapters
