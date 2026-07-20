#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-autostart.sh - the boot-time step that materialises
# the firstmate agent inside an already-running, headless herdr server.
#
# Every case drives the script against a FAKE `herdr` on PATH, backed by a
# fixture directory that models the server's readiness and its agent list. The
# live herdr server is never contacted: no real `herdr status`, no real
# `herdr agent list`, and above all no real `herdr agent start`, which on the
# captain's machine would create a SECOND firstmate.
#
# What is proven here: the readiness wait polls and times out cleanly without
# starting anything; and - the sharp part - the idempotence guard never creates
# a second firstmate, whether the existing one is matched by name, by working
# directory, or by an aliased (/home vs /var/home) spelling of that directory,
# and whether the list is readable at all.
#
# The other half of that guard is that a matching entry must be LIVE. herdr
# persists its session layout, so after a reboot `agent list`, `pane get` and
# `agent get` all replay GHOST records - complete with agent_status "idle" - for
# agents that are not running; only `pane process-info` sees that no process is
# behind them. The fake herdr below therefore models a pane's state, not just
# the agent list, so the ghost cases can prove the script starts firstmate
# instead of mistaking a replayed record for a live supervisor and doing nothing
# at every boot, forever.
# docs/firstmate-autostart.md owns the install, rollback, and verification steps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-autostart

SCRIPT="$ROOT/bin/fm-autostart.sh"
[ -x "$SCRIPT" ] || fail "bin/fm-autostart.sh must be executable"
command -v jq >/dev/null 2>&1 || fail "jq is required by bin/fm-autostart.sh and by this suite"

TEMPLATE="$ROOT/assets/systemd/firstmate-autostart.service"

# --- fixtures ---------------------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PATH="$FAKEBIN:$PATH"
export PATH

# The fake herdr. Its whole behaviour is files in $FAKE_HERDR_DIR, so a case
# sets up state declaratively and then asserts on what the script did:
#   ready_after   number of `status server` polls before the server reports
#                 running (0 = ready immediately)
#   status_fail   if present, `status server` exits non-zero every time
#   agents.json   the exact `agent list` response body
#   list_fail     if present, `agent list` exits non-zero
#   start_fail    if present, `agent start` exits non-zero
#   start.log     appended with the argv of every `agent start` call
#   polls         appended with one line per `status server` call
#   panes/<id>    this pane's state, one word (default when absent: live):
#                   live      pane get, agent get and process-info all answer
#                   ghost     pane get and agent get answer from the persisted
#                             layout, process-info says pane_not_found - the
#                             post-reboot shape that made this guard a no-op
#                   no-agent  pane exists, nothing registered in it
#                   dead      the pane itself is gone
#                   garbage   pane get answers something unparseable
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
d=${FAKE_HERDR_DIR:?FAKE_HERDR_DIR unset}

pane_state() { cat "$d/panes/$1" 2>/dev/null || printf 'live\n'; }
# Error bodies go to STDERR, exactly as real herdr writes them.
err() { printf '{"error":{"code":"%s","message":"fake"},"id":"cli:fake"}\n' "$1" >&2; exit 1; }
pane_body() {
  printf '{"id":"cli:fake","result":{"%s":{"agent":"claude","agent_status":"idle","cwd":"/x","pane_id":"%s"},"type":"%s"}}\n' \
    "$2" "$1" "$3"
}

case "$1 ${2:-}" in
  "pane get")
    case "$(pane_state "$3")" in
      dead) err pane_not_found ;;
      garbage) printf 'not json at all\n'; exit 0 ;;
      *) pane_body "$3" pane pane_info; exit 0 ;;
    esac
    ;;
  "agent get")
    case "$(pane_state "$3")" in
      dead) err pane_not_found ;;
      no-agent) err agent_not_found ;;
      *) pane_body "$3" agent agent_info; exit 0 ;;
    esac
    ;;
  "pane process-info")
    # `--pane <id>`, unlike the positional forms above.
    pane=""
    while [ "$#" -gt 0 ]; do
      [ "$1" = "--pane" ] && pane=$2
      shift
    done
    case "$(pane_state "$pane")" in
      live)
        printf '{"id":"cli:fake","result":{"process_info":{"foreground_process_group_id":1,"foreground_processes":[{"argv":["claude"]}]},"type":"process_info"}}\n'
        exit 0
        ;;
      *) err pane_not_found ;;
    esac
    ;;
  "status server")
    printf 'x\n' >> "$d/polls"
    [ -e "$d/status_fail" ] && { echo 'connect: no such file or directory' >&2; exit 1; }
    n=$(wc -l < "$d/polls" | tr -d ' ')
    if [ "$n" -gt "$(cat "$d/ready_after" 2>/dev/null || echo 0)" ]; then
      printf 'status: running\nversion: 0.7.4\nprotocol: 16\ncompatible: yes\n'
    else
      printf 'status: not running\n'
    fi
    exit 0
    ;;
  "agent list")
    [ -e "$d/list_fail" ] && exit 1
    cat "$d/agents.json"
    exit 0
    ;;
  "agent start")
    shift 2
    printf '%s\n' "$*" >> "$d/start.log"
    [ -e "$d/start_fail" ] && exit 1
    # A real start makes the agent visible to the next `agent list`; modelling
    # that is what lets a case run the script twice and prove idempotence.
    name=$1
    cwd=""
    while [ "$#" -gt 0 ]; do
      [ "$1" = "--cwd" ] && cwd=$2
      shift
    done
    # A real start produces a real pane with a real process behind it, so the
    # started agent's pane is left at the default `live` state.
    jq --arg n "$name" --arg c "$cwd" \
      '.result.agents += [{"name":$n,"cwd":$c,"agent":"claude","agent_status":"idle","pane_id":"w9:pS"}]' \
      "$d/agents.json" > "$d/agents.json.new" && mv "$d/agents.json.new" "$d/agents.json"
    exit 0
    ;;
esac
echo "fake herdr: unexpected argv: $*" >&2
exit 99
SH
chmod +x "$FAKEBIN/herdr"

# A firstmate-shaped home: the structural markers fm-autostart.sh tests for.
make_home() {
  local dir=$1
  mkdir -p "$dir/bin"
  : > "$dir/AGENTS.md"
  : > "$dir/bin/fm-spawn.sh"
  chmod +x "$dir/bin/fm-spawn.sh"
}

# A fresh fake-server state dir. `agents` is a JSON array literal for the
# response body, so a case spells out exactly the fleet it wants the script to
# see.
new_server() {
  local dir=$1 agents=${2:-[]}
  rm -rf "$dir"
  mkdir -p "$dir"
  mkdir -p "$dir/panes"
  printf '{"id":"cli:agent:list","result":{"agents":%s,"type":"agent_list"}}\n' "$agents" \
    > "$dir/agents.json"
  printf '%s\n' "$dir"
}

# set_pane <server-dir> <pane-id> <state>: what the pane behind a listed agent
# really is. Absent means `live`, so cases that are about MATCHING rather than
# liveness stay readable.
set_pane() {
  mkdir -p "$1/panes"
  printf '%s\n' "$3" > "$1/panes/$2"
}

# run_autostart <server-dir> <fm-root> [extra args...]
run_autostart() {
  local server=$1 root=$2
  shift 2
  FAKE_HERDR_DIR="$server" "$SCRIPT" --fm-root "$root" --interval 0.05 --timeout 2 --confirm 2 "$@" 2>&1
}

started_count() {
  local server=$1
  [ -f "$server/start.log" ] || { printf '0\n'; return; }
  wc -l < "$server/start.log" | tr -d ' '
}

HOME_DIR="$TMP_ROOT/firstmate"
make_home "$HOME_DIR"
HOME_ABS=$(cd "$HOME_DIR" && pwd -P)

# --- readiness wait ---------------------------------------------------------

server=$(new_server "$TMP_ROOT/s-timeout")
printf '9999\n' > "$server/ready_after"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 2 "$rc" "a server that never becomes ready must exit 2"
assert_contains "$out" "was not ready within" "the timeout must say the server was not ready"
assert_contains "$out" "started nothing" "the timeout must state that nothing was started"
[ "$(started_count "$server")" = 0 ] || fail "timing out on readiness must never start an agent"
[ "$(wc -l < "$server/polls" | tr -d ' ')" -gt 1 ] ||
  fail "readiness must be POLLED, not slept once"
pass "readiness: a never-ready server times out cleanly, polling, starting nothing"

server=$(new_server "$TMP_ROOT/s-unreachable")
: > "$server/status_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 2 "$rc" "an unreachable socket must exit 2"
assert_contains "$out" "last status was" "the timeout must report the last status seen"
[ "$(started_count "$server")" = 0 ] || fail "an unreachable server must never start an agent"
pass "readiness: an unreachable socket times out and reports the last status"

server=$(new_server "$TMP_ROOT/s-slow")
printf '2\n' > "$server/ready_after"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a server that becomes ready on a later poll must succeed: $out"
[ "$(started_count "$server")" = 1 ] || fail "a slow-but-ready server must start exactly one agent"
pass "readiness: a server ready only on a later poll is waited for, then used"

# --- the idempotence guard --------------------------------------------------

# Matched by name: the shape `herdr agent start firstmate` itself produces.
server=$(new_server "$TMP_ROOT/s-byname" \
  '[{"name":"firstmate","cwd":"/somewhere/else","agent":"claude","agent_status":"idle","pane_id":"w1:p1"}]')
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "an existing named firstmate must be a clean no-op: $out"
assert_contains "$out" "already up" "a no-op must say firstmate is already up"
[ "$(started_count "$server")" = 0 ] || fail "IDEMPOTENCE: a named firstmate must never be duplicated"
pass "idempotence: an agent named firstmate makes the run a no-op"

# Matched by cwd with NO name - the live shape. Every agent herdr resurrected,
# and every one the captain launched by hand, reports name: null, so this is the
# case that actually stands between the captain and two supervisors.
server=$(new_server "$TMP_ROOT/s-bycwd" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "an unnamed agent in the firstmate home must be a clean no-op: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an unnamed firstmate in the home must never be duplicated"
pass "idempotence: an UNNAMED agent in the firstmate home makes the run a no-op"

# Same, via foreground_cwd only.
server=$(new_server "$TMP_ROOT/s-byfg" \
  "[{\"name\":null,\"cwd\":null,\"foreground_cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"pane_id\":\"w1:p1\"}]")
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "an agent whose foreground_cwd is the home must be a no-op: $out"
[ "$(started_count "$server")" = 0 ] || fail "IDEMPOTENCE: foreground_cwd must also block a duplicate"
pass "idempotence: foreground_cwd in the firstmate home makes the run a no-op"

# Aliased spelling: herdr reports the physical path, the unit passes the /home
# symlink spelling (or vice versa). A string compare would miss and duplicate.
ALIAS_ROOT="$TMP_ROOT/alias"
ln -s "$TMP_ROOT" "$ALIAS_ROOT"
server=$(new_server "$TMP_ROOT/s-alias" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
out=$(run_autostart "$server" "$ALIAS_ROOT/firstmate")
rc=$?
expect_code 0 "$rc" "an aliased path spelling of the home must still be a no-op: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an aliased (/home vs /var/home) spelling must never duplicate firstmate"
pass "idempotence: an aliased path spelling of the home still makes the run a no-op"

# An agent in a DIFFERENT directory with no name must not be mistaken for
# firstmate - the guard has to stay a guard, not become a blanket refusal.
server=$(new_server "$TMP_ROOT/s-other" \
  '[{"name":null,"cwd":"/var/home/marlon/challenges","agent":"claude","agent_status":"idle","pane_id":"w1:p1"}]')
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "an unrelated agent must not block the start: $out"
[ "$(started_count "$server")" = 1 ] ||
  fail "an agent in an unrelated directory must not be mistaken for firstmate"
pass "idempotence: an unrelated agent elsewhere does not block the start"

# --- ghosts: a listed entry is not a running agent --------------------------

# The regression this suite exists for. After a reboot herdr replays the
# persisted session layout, so an agent that is NOT running still appears in
# `agent list` - right cwd, right pane id, agent_status "idle" - and answers
# `pane get` and `agent get` too. Only `pane process-info` knows the truth.
# Reading the list alone made autostart print "firstmate is already up" and
# start nothing at every boot, forever, silently.
server=$(new_server "$TMP_ROOT/s-ghost" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 ghost
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a ghost record must not stop the start: $out"
assert_not_contains "$out" "already up" \
  "GHOST: a replayed record must never be reported as a running firstmate"
[ "$(started_count "$server")" = 1 ] ||
  fail "GHOST: an entry whose pane has no process must not count as a live firstmate"
pass "ghost: a listed 'idle' agent with no process behind it does not block the start"

# The same ghost in its other two shapes: the pane herdr already reaped, and the
# agent-less bare shell a layout restore leaves behind.
for ghost_state in dead no-agent; do
  server=$(new_server "$TMP_ROOT/s-ghost-$ghost_state" \
    "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
  set_pane "$server" w1:p1 "$ghost_state"
  out=$(run_autostart "$server" "$HOME_DIR")
  rc=$?
  expect_code 0 "$rc" "a $ghost_state pane must not stop the start: $out"
  [ "$(started_count "$server")" = 1 ] ||
    fail "GHOST: a $ghost_state pane must not count as a live firstmate"
done
pass "ghost: a dead pane and an agent-less pane both fail to block the start"

# The other side of the same coin, and the dangerous one: a genuinely live
# firstmate must still be a no-op. Liveness verification must not become a
# licence to duplicate.
server=$(new_server "$TMP_ROOT/s-reallive" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 live
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a genuinely live firstmate must be a clean no-op: $out"
assert_contains "$out" "already up" "a live firstmate must be reported as already up"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: a pane with a real process behind it must never be duplicated"
pass "liveness: a confirmed-live firstmate is still a no-op"

# A ghost sitting next to the real thing: the husk must be skipped, and the scan
# must go on to find the live one rather than starting a second supervisor.
server=$(new_server "$TMP_ROOT/s-ghost-and-live" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"},
    {\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p2\"}]")
set_pane "$server" w1:p1 ghost
set_pane "$server" w1:p2 live
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a live firstmate beside a ghost must be a no-op: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: a ghost listed before the live firstmate must not license a start"
pass "liveness: a ghost listed beside the live firstmate does not license a start"

# Uncertainty is still uncertainty: a matching entry whose pane cannot be
# classified is neither live nor a confirmed husk, so nothing is started.
server=$(new_server "$TMP_ROOT/s-paneunknown" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 garbage
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "an unclassifiable matching pane must exit 3: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an unclassifiable pane must never lead to a start"
pass "liveness: a matching entry that cannot be classified fails closed"

# A matching entry that names no pane at all cannot be verified either.
server=$(new_server "$TMP_ROOT/s-nopane" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\"}]")
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "a matching entry with no pane id must exit 3: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an unverifiable matching entry must never lead to a start"
pass "liveness: a matching entry with no pane id fails closed"

# --- the list itself --------------------------------------------------------

# An unreadable or unrecognised list is UNKNOWN, never "absent". Fail closed.
server=$(new_server "$TMP_ROOT/s-listfail")
: > "$server/list_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "an unreadable agent list must exit 3"
assert_contains "$out" "refusing to start a possible duplicate" \
  "an unreadable list must say why it refused"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an unreadable agent list must never lead to a start"
pass "idempotence: an unreadable agent list fails closed and starts nothing"

server=$(new_server "$TMP_ROOT/s-listjunk")
printf '{"id":"cli:agent:list","error":{"code":"nope"}}\n' > "$server/agents.json"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "an error response must exit 3, not be read as an empty fleet"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an error response must never be read as 'no firstmate present'"
pass "idempotence: an error response is unknown state, not an empty fleet"

# The response says it holds agents, but none can be extracted. That is a broken
# read, not an empty fleet, and the live firstmate could be among the ones never
# examined - so it must fail closed rather than start a second supervisor.
server=$(new_server "$TMP_ROOT/s-shortread")
printf '{"id":"cli:agent:list","result":{"agents":"not-an-array","type":"agent_list"}}\n' \
  > "$server/agents.json"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "an agents field that cannot be walked must exit 3"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: a partial or failed extraction must never be read as an empty fleet"
pass "idempotence: an unwalkable agents field fails closed rather than starting"

# --- end-to-end idempotence -------------------------------------------------

server=$(new_server "$TMP_ROOT/s-twice")
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "the first run on an empty server must start firstmate: $out"
[ "$(started_count "$server")" = 1 ] || fail "the first run must start exactly one agent"
assert_contains "$(cat "$server/start.log")" "--cwd $HOME_ABS" \
  "the start must pass the resolved firstmate home as --cwd"
assert_contains "$(cat "$server/start.log")" -- "-- claude" \
  "the start must launch claude"
assert_contains "$(cat "$server/start.log")" "--continue" \
  "the start must use --continue so it survives session-id churn"
assert_contains "$(cat "$server/start.log")" "--dangerously-skip-permissions" \
  "the start must pass the unattended flag rather than depend on the shim"

out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "the second run must be a clean no-op: $out"
assert_contains "$out" "already up" "the second run must report firstmate already up"
[ "$(started_count "$server")" = 1 ] ||
  fail "IDEMPOTENCE: running the unit twice must never produce a second firstmate"
pass "idempotence: running twice against one server starts exactly one firstmate"

# --- start failures ---------------------------------------------------------

server=$(new_server "$TMP_ROOT/s-startfail")
: > "$server/start_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "a failing 'agent start' must exit 4"
assert_contains "$out" "no firstmate is running" "a failed start must say so plainly"
pass "failure: a failing 'agent start' is reported loudly, not swallowed"

# --- dry run and guards -----------------------------------------------------

server=$(new_server "$TMP_ROOT/s-dry")
out=$(run_autostart "$server" "$HOME_DIR" --dry-run)
rc=$?
expect_code 0 "$rc" "--dry-run must succeed: $out"
assert_contains "$out" "herdr agent start firstmate --cwd $HOME_ABS" \
  "--dry-run must print the exact command"
[ "$(started_count "$server")" = 0 ] || fail "--dry-run must never start an agent"
pass "dry run: reports the decision and the command without starting anything"

server=$(new_server "$TMP_ROOT/s-argv")
out=$(run_autostart "$server" "$HOME_DIR" -- echo hello)
rc=$?
expect_code 0 "$rc" "an explicit -- argv must be honoured: $out"
assert_contains "$(cat "$server/start.log")" -- "-- echo hello" \
  "an explicit -- argv must replace the default command"
assert_not_contains "$(cat "$server/start.log")" "--continue" \
  "an explicit -- argv must not also carry the default flags"
pass "argv: an explicit -- command replaces the default"

# A bare `--` must be refused rather than expanding an empty array, which is an
# error under `set -u` on stock macOS Bash 3.2.
server=$(new_server "$TMP_ROOT/s-bareargv")
out=$(run_autostart "$server" "$HOME_DIR" --)
rc=$?
expect_code 1 "$rc" "a bare -- must exit 1"
assert_contains "$out" "needs a command" "a bare -- must say what is missing"
[ "$(started_count "$server")" = 0 ] || fail "a bare -- must never start an agent"
pass "argv: a bare -- is refused with a clear message"

server=$(new_server "$TMP_ROOT/s-nothome")
mkdir -p "$TMP_ROOT/not-firstmate"
out=$(run_autostart "$server" "$TMP_ROOT/not-firstmate")
rc=$?
expect_code 1 "$rc" "a directory that is not a firstmate home must exit 1"
assert_contains "$out" "does not look like a firstmate home" "the refusal must name the reason"
[ "$(started_count "$server")" = 0 ] ||
  fail "a non-firstmate directory must never host an unattended supervisor"
pass "guard: refuses to start a supervisor outside a firstmate home"

# --- the shipped unit template ----------------------------------------------

[ -f "$TEMPLATE" ] || fail "assets/systemd/firstmate-autostart.service must ship in this repo"
tmpl=$(cat "$TEMPLATE")
assert_contains "$tmpl" "__FM_ROOT__/bin/fm-autostart.sh" \
  "the template's ExecStart must run fm-autostart.sh under the placeholder root"
assert_contains "$tmpl" "After=herdr-server.service" "the template must be ordered after herdr-server"
assert_contains "$tmpl" "Wants=herdr-server.service" "the template must want herdr-server"
assert_contains "$tmpl" "Type=oneshot" "the template must be a oneshot"
assert_contains "$tmpl" "RemainAfterExit=yes" "the template must remain after exit"
assert_contains "$tmpl" "WantedBy=default.target" "the template must install into default.target"
# A leaked absolute home would install a unit pointing at someone else's machine.
assert_not_contains "$tmpl" "/var/home/marlon" "the template must carry no captain-specific path"
# ExecStart must not depend on a shell variable: an empty one silently yields a
# broken path, the exact failure mode of the 2026-07-20 dangling-symlink outage.
assert_not_contains "$tmpl" 'ExecStart=$' "the template's ExecStart must not start from a variable"
pass "template: the shipped unit has the required ordering, type, and no baked-in paths"

printf 'ok - fm-autostart tests passed\n'
