#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-autostart.sh - the boot-time step that materialises
# the firstmate agent inside an already-running, headless herdr server.
#
# Every case drives the script against a FAKE `herdr` on PATH, backed by a
# fixture directory that models the server's readiness, its agent list, its
# pane list, and what each pane really holds. The live herdr server is never
# contacted: no real `herdr status`, no real inventory reads, and above all no
# real `herdr workspace create` or `herdr pane run`, which on the captain's
# machine would create a SECOND firstmate.
#
# What is proven here: the readiness wait polls and times out cleanly without
# starting anything; and - the sharp part - the idempotence guard never creates
# a second firstmate, whether the existing one is matched by name, by working
# directory, or by an aliased (/home vs /var/home) spelling of that directory,
# whether it is visible in the agent registry or only in the pane inventory,
# and whether either inventory is readable at all.
#
# The other half of that guard is that a matching entry must be LIVE. herdr
# persists its session layout, so after a reboot `agent list`, `pane get` and
# `agent get` all replay GHOST records - complete with agent_status "idle" - for
# agents that are not running; only `pane process-info` sees that no process is
# behind them. The fake herdr below therefore models a pane's state, not just
# the inventories, so the ghost cases can prove the script starts firstmate
# instead of mistaking a replayed record for a live supervisor and doing nothing
# at every boot, forever.
#
# Liveness is judged on `pane process-info` alone - existence of a process, its
# identity as a verified harness, and its kernel-reported cwd for a cwd-matched
# entry - because on herdr 0.7.4 `agent get`'s agent_status reports "unknown"
# for a genuinely live agent, and consulting it made the unit declare two
# working boots failures (verified 2026-07-20). The fake's process-info
# therefore carries the real body shape, including per-process argv and cwd, so
# a restored BARE SHELL in the firstmate home is modelled distinctly from a
# live agent there, and a pane whose body says nothing at all is modelled
# distinctly from both, because "could not read it" must never be scored as the
# husk verdict that licenses a start.
#
# Which identity a launched pane must show depends on what the run was asked to
# launch: a harness argv (the default) must show a verified harness, while the
# `-- <argv>` escape hatch's own command - which is by definition not one of our
# harnesses - must show a process that is not merely the pane's own shell. Both
# arms are exercised, including that cleanup never closes over a custom command
# that did come up.
#
# The launch itself is two calls - `workspace create` then `pane run` - and the
# fake models their real consequences (a new pane appears in the pane list and
# starts out holding nothing but a shell; typing the launch command is what
# puts an agent in it), so the end-to-end cases exercise the same sequence a
# boot really performs.
#
# The suite also drives the NETWORK GATE against fake `curl` and `ping` on
# PATH: reachable, unreachable (bounded, polled, exit 5, nothing started),
# reachable-only-later, ICMP-filtered-but-endpoint-fine, and the no-op and
# dry-run paths that must not depend on the network at all. No real network is
# ever probed.
# docs/firstmate-autostart.md owns the install, rollback, and verification steps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-autostart)

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
#   panes.json    the exact `pane list` response body
#   list_fail     if present, `agent list` exits non-zero
#   panelist_fail if present, `pane list` exits non-zero
#   panelist_ws_fail  if present, only `pane list --workspace` exits non-zero,
#                 so the cleanup path cannot prove a workspace is agent-free
#   release       "<version> <protocol>" the fake reports for both `status
#                 server` and `status --json` (default 0.8.2 20, at or above the
#                 floor where an explicit workspace close preserves focus);
#                 "0.7.4 16" is provably below it and "? ?" is unclassifiable
#   statusjson_fail  if present, only `status --json` exits non-zero, so the
#                 release cannot be classified at all
#   ws_fail       if present, `workspace create` exits non-zero
#   ws_nopane     if present, `workspace create` omits root_pane, which no
#                 supported release does and which must be refused loudly
#   create_pane_state  the state the pane `workspace create` seeds starts in
#                 (default `shell`), so a case can model a pane whose
#                 process-info does not yet answer when the launch is typed
#   run_fail      if present, `pane run` exits non-zero
#   run_inert     if present, `pane run` succeeds but leaves the pane a bare
#                 shell - the launch that types fine and never becomes an agent
#   run_leaves    the pane state `pane run` leaves behind (default `live`), so
#                 a case can model a launch that produces a non-harness command
#                 or a pane that stops answering
#   run_cwd       if present, the cwd `pane run` records for the agent it
#                 leaves running, instead of the workspace's own cwd
#   launch.log    appended with the argv of every `pane run` call
#   create.log    appended with the argv of every `workspace create` call
#   closed.log    appended with the workspace id of every `workspace close`
#   polls         appended with one line per `status server` call
#   panes/<id>    this pane's state: a state word, optionally followed by the
#                 cwd process-info should report for the live process (default
#                 when the file is absent: live, cwd /x):
#                   live [cwd]  process-info answers with a real claude process
#                               body carrying the given cwd - the real shape,
#                               with the agent running as the pane shell's
#                               child, which is what a typed launch produces
#                   custom [cwd] the same, but the running process is an
#                               ordinary non-harness command: what the
#                               `-- <argv>` escape hatch actually leaves behind
#                   shell [cwd] process-info answers with a real /bin/bash
#                               process body carrying the given cwd, its pid
#                               the pane's own shell_pid - the restored bare
#                               shell herdr leaves behind, which is a husk
#                               however live its shell is
#                   opaque      process-info answers with a real process_info
#                               body that carries no walkable
#                               foreground_processes: readable enough to prove
#                               the pane exists, not readable enough to prove
#                               what is in it
#                   ghost       pane get and agent get answer from the persisted
#                               layout, process-info says pane_not_found - the
#                               post-reboot shape that made this guard a no-op
#                   no-agent    pane exists, nothing registered in it
#                   dead        the pane itself is gone
#                   garbage     pane get and process-info answer unparseably
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
d=${FAKE_HERDR_DIR:?FAKE_HERDR_DIR unset}

pane_state() { cat "$d/panes/$1" 2>/dev/null || printf 'live\n'; }
pane_state_kind() { pane_state "$1" | { read -r kind _ || :; printf '%s' "${kind:-live}"; }; }
pane_state_cwd() { pane_state "$1" | { read -r _ cwd || :; printf '%s' "${cwd:-/x}"; }; }
# Error bodies go to STDERR, exactly as real herdr writes them.
err() { printf '{"error":{"code":"%s","message":"fake"},"id":"cli:fake"}\n' "$1" >&2; exit 1; }
pane_body() {
  printf '{"id":"cli:fake","result":{"%s":{"agent":"claude","agent_status":"idle","cwd":"/x","pane_id":"%s"},"type":"%s"}}\n' \
    "$2" "$1" "$3"
}

case "$1 ${2:-}" in
  "pane get")
    case "$(pane_state_kind "$3")" in
      dead) err pane_not_found ;;
      garbage) printf 'not json at all\n'; exit 0 ;;
      *) pane_body "$3" pane pane_info; exit 0 ;;
    esac
    ;;
  "agent get")
    case "$(pane_state_kind "$3")" in
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
    case "$(pane_state_kind "$pane")" in
      live)
        # The verified herdr body: foreground_processes entries carry argv,
        # cmdline, cwd, name, and pid. A command TYPED into the pane runs as
        # the shell's child, so its pid is not the pane's shell_pid.
        printf '{"id":"cli:fake","result":{"process_info":{"foreground_process_group_id":2,"shell_pid":1,"pane_id":"%s","foreground_processes":[{"argv":["claude"],"cmdline":"claude","cwd":"%s","name":"claude","pid":2}]},"type":"pane_process_info"}}\n' \
          "$pane" "$(pane_state_cwd "$pane")"
        exit 0
        ;;
      custom)
        # The same shape for a command that is deliberately NOT one of our
        # harnesses - the `-- <argv>` escape hatch's launched process.
        printf '{"id":"cli:fake","result":{"process_info":{"foreground_process_group_id":2,"shell_pid":1,"pane_id":"%s","foreground_processes":[{"argv":["/usr/local/bin/my-supervisor"],"cmdline":"/usr/local/bin/my-supervisor","cwd":"%s","name":"my-supervisor","pid":2}]},"type":"pane_process_info"}}\n' \
          "$pane" "$(pane_state_cwd "$pane")"
        exit 0
        ;;
      opaque)
        # A body herdr answered but nothing can be read out of: the pane is
        # there, what runs in it is unprovable.
        printf '{"id":"cli:fake","result":{"process_info":{"shell_pid":1,"pane_id":"%s"},"type":"pane_process_info"}}\n' \
          "$pane"
        exit 0
        ;;
      shell)
        # The restored bare shell: a real live process with a real cwd, and no
        # agent anywhere in it. Verified body shape (herdr 0.8.2): the pane's
        # own shell is its whole foreground process group.
        printf '{"id":"cli:fake","result":{"process_info":{"foreground_process_group_id":1,"shell_pid":1,"pane_id":"%s","foreground_processes":[{"argv":["/bin/bash"],"cmdline":"/bin/bash","cwd":"%s","name":"bash","pid":1}]},"type":"pane_process_info"}}\n' \
          "$pane" "$(pane_state_cwd "$pane")"
        exit 0
        ;;
      garbage) printf 'not json at all\n'; exit 0 ;;
      *) err pane_not_found ;;
    esac
    ;;
  "status server")
    printf 'x\n' >> "$d/polls"
    [ -e "$d/status_fail" ] && { echo 'connect: no such file or directory' >&2; exit 1; }
    n=$(wc -l < "$d/polls" | tr -d ' ')
    if [ "$n" -gt "$(cat "$d/ready_after" 2>/dev/null || echo 0)" ]; then
      read -r v p < "$d/release"
      printf 'status: running\nversion: %s\nprotocol: %s\ncompatible: yes\n' "$v" "$p"
    else
      printf 'status: not running\n'
    fi
    exit 0
    ;;
  "status --json")
    # The machine-readable release surface bin/backends/herdr.sh classifies
    # against its focus-safe-close floor. One fixture drives both status forms,
    # so the release a case declares is the release the whole run sees.
    [ -e "$d/statusjson_fail" ] && { echo 'connect: no such file or directory' >&2; exit 1; }
    read -r v p < "$d/release"
    # Real herdr reports protocol as a number; a fixture that names no usable
    # protocol reports null, which is what an unclassifiable release looks like.
    case "$p" in '' | *[!0-9]*) p=null ;; esac
    printf '{"client":{"version":"%s","protocol":%s},"server":{"running":true,"version":"%s","protocol":%s}}\n' \
      "$v" "$p" "$v" "$p"
    exit 0
    ;;
  "agent list")
    [ -e "$d/list_fail" ] && exit 1
    cat "$d/agents.json"
    exit 0
    ;;
  "pane list")
    [ -e "$d/panelist_fail" ] && exit 1
    # `pane list --workspace <id>` selects only the panes a `workspace create`
    # put in that workspace; pre-existing fixture panes belong to none.
    if [ "${3:-}" = "--workspace" ]; then
      [ -e "$d/panelist_ws_fail" ] && exit 1
      jq --arg w "${4:-}" '.result.panes |= map(select(.workspace_id == $w))' "$d/panes.json"
      exit 0
    fi
    cat "$d/panes.json"
    exit 0
    ;;
  "workspace create")
    shift 2
    printf '%s\n' "$*" >> "$d/create.log"
    [ -e "$d/ws_fail" ] && exit 1
    cwd=""
    while [ "$#" -gt 0 ]; do
      [ "$1" = "--cwd" ] && cwd=$2
      shift
    done
    printf '%s' "$cwd" > "$d/ws_cwd"
    # A real create seeds one tab holding one pane at a SHELL PROMPT: live, but
    # holding no agent at all until something is typed into it.
    printf '%s %s\n' "$(cat "$d/create_pane_state" 2>/dev/null || printf 'shell')" "$cwd" \
      > "$d/panes/w9:pS1"
    jq --arg p "w9:pS1" --arg c "$cwd" \
      '.result.panes += [{"pane_id":$p,"cwd":$c,"foreground_cwd":$c,"workspace_id":"w9"}]' \
      "$d/panes.json" > "$d/panes.json.new" && mv "$d/panes.json.new" "$d/panes.json"
    if [ -e "$d/ws_nopane" ]; then
      printf '{"id":"cli:fake","result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"type":"workspace_created"}}\n'
    else
      printf '{"id":"cli:fake","result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:pS1","cwd":"%s","tab_id":"w9:t1","workspace_id":"w9"},"type":"workspace_created"}}\n' "$cwd"
    fi
    exit 0
    ;;
  "workspace close")
    printf '%s\n' "$3" >> "$d/closed.log"
    for p in $(jq -r --arg w "$3" '.result.panes[]? | select(.workspace_id == $w) | .pane_id' "$d/panes.json"); do
      printf 'dead\n' > "$d/panes/$p"
    done
    jq --arg w "$3" '.result.panes |= map(select(.workspace_id != $w))' \
      "$d/panes.json" > "$d/panes.json.new" && mv "$d/panes.json.new" "$d/panes.json"
    printf '{"id":"cli:fake","result":{"type":"workspace_closed"}}\n'
    exit 0
    ;;
  "pane run")
    # `pane run <pane_id> <command>`: $3 is the pane, $4 the command line.
    printf '%s\n' "$4" >> "$d/launch.log"
    [ -e "$d/run_fail" ] && exit 1
    # Typing the launch command is what puts a real agent in the pane - unless
    # the case is modelling a launch that types fine and never becomes one.
    [ -e "$d/run_inert" ] ||
      printf '%s %s\n' "$(cat "$d/run_leaves" 2>/dev/null || printf 'live')" \
        "$(cat "$d/run_cwd" 2>/dev/null || cat "$d/ws_cwd" 2>/dev/null)" > "$d/panes/$3"
    printf '{"id":"cli:fake","result":{"type":"pane_run"}}\n'
    exit 0
    ;;
esac
echo "fake herdr: unexpected argv: $*" >&2
exit 99
SH
chmod +x "$FAKEBIN/herdr"

# The fake network probes. The script's decisive probe is curl against the
# registration endpoint; ping is diagnostic only. Both log every call so cases
# can prove the gate polled (bounded, repeated) rather than hung or slept.
#   net_curl_fail      if present, curl fails every time
#   net_curl_ok_after  curl fails until it has been called this many times
#   net_ping_fail      if present, ping gets no reply
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
d=${FAKE_HERDR_DIR:?FAKE_HERDR_DIR unset}
printf '%s\n' "$*" >> "$d/net_curl.log"
[ -e "$d/net_curl_fail" ] && exit 7
n=$(wc -l < "$d/net_curl.log" | tr -d ' ')
after=$(cat "$d/net_curl_ok_after" 2>/dev/null || echo 0)
[ "$n" -gt "$after" ] || exit 7
exit 0
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/ping" <<'SH'
#!/usr/bin/env bash
d=${FAKE_HERDR_DIR:?FAKE_HERDR_DIR unset}
printf '%s\n' "$*" >> "$d/net_ping.log"
[ -e "$d/net_ping_fail" ] && exit 1
exit 0
SH
chmod +x "$FAKEBIN/ping"

# A firstmate-shaped home: the structural markers fm-autostart.sh tests for.
make_home() {
  local dir=$1
  mkdir -p "$dir/bin"
  : > "$dir/AGENTS.md"
  : > "$dir/bin/fm-spawn.sh"
  chmod +x "$dir/bin/fm-spawn.sh"
}

# A fresh fake-server state dir. `agents` and `panes` are JSON array literals
# for the two inventory response bodies, so a case spells out exactly the fleet
# it wants the script to see - including the herdr 0.8.2 shape, where the agent
# registry is empty and only the pane inventory sees the live firstmate.
new_server() {
  local dir=$1 agents=${2:-[]} panes=${3:-[]}
  rm -rf "$dir"
  mkdir -p "$dir"
  mkdir -p "$dir/panes"
  printf '{"id":"cli:agent:list","result":{"agents":%s,"type":"agent_list"}}\n' "$agents" \
    > "$dir/agents.json"
  printf '{"id":"cli:pane:list","result":{"panes":%s,"type":"pane_list"}}\n' "$panes" \
    > "$dir/panes.json"
  # At or above the focus-safe-close floor unless a case says otherwise, so the
  # cases that assert a workspace was removed keep testing the removal.
  printf '0.8.2 20\n' > "$dir/release"
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

# One "start" is one launch command typed into a pane. Counting the typing
# rather than the workspace create is what the ONE RULE is really about: a
# second firstmate is a second launched agent.
started_count() {
  local server=$1
  [ -f "$server/launch.log" ] || { printf '0\n'; return; }
  wc -l < "$server/launch.log" | tr -d ' '
}

# One "cleanup" is one workspace this run created and then removed.
closed_count() {
  local server=$1
  [ -f "$server/closed.log" ] || { printf '0\n'; return; }
  wc -l < "$server/closed.log" | tr -d ' '
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
set_pane "$server" w1:p1 "live $HOME_ABS"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "an unnamed agent in the firstmate home must be a clean no-op: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an unnamed firstmate in the home must never be duplicated"
pass "idempotence: an UNNAMED agent in the firstmate home makes the run a no-op"

# Same, via foreground_cwd only.
server=$(new_server "$TMP_ROOT/s-byfg" \
  "[{\"name\":null,\"cwd\":null,\"foreground_cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 "live $HOME_ABS"
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
set_pane "$server" w1:p1 "live $HOME_ABS"
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
set_pane "$server" w1:p1 "live $HOME_ABS"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a genuinely live firstmate must be a clean no-op: $out"
assert_contains "$out" "already up" "a live firstmate must be reported as already up"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: a pane with a real process behind it must never be duplicated"
pass "liveness: a confirmed-live firstmate is still a no-op"

# THE HERDR 0.8.2 REGISTRY BLIND SPOT. A live Claude registers no agent record
# at all there, so `agent list` answers with an empty array right next to the
# running firstmate and the pane inventory is the only one that still sees it.
# Reading the registry alone would report "no firstmate present" and start a
# second supervisor - the exact outcome THE ONE RULE exists to prevent.
server=$(new_server "$TMP_ROOT/s-registry-blind" '[]' \
  "[{\"pane_id\":\"w1:p1\",\"cwd\":\"$HOME_ABS\",\"foreground_cwd\":\"$HOME_ABS\"}]")
set_pane "$server" w1:p1 "live $HOME_ABS"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a firstmate visible only in the pane inventory must be a no-op: $out"
assert_contains "$out" "already up" "a pane-only firstmate must be reported as already up"
[ "$(started_count "$server")" = 0 ] ||
  fail "REGISTRY BLIND SPOT: an empty agent registry must never license a duplicate"
pass "idempotence: a firstmate visible only in the pane inventory blocks the start"

# The other side of that coin. Herdr restores its persisted panes as plain
# shells after a server restart, so the firstmate home's pane comes back with
# the right cwd and a real live process - its own shell - and nothing else.
# Counting that as a running firstmate would no-op every boot forever, which is
# the failure this whole script was written to end.
server=$(new_server "$TMP_ROOT/s-restored-shell" '[]' \
  "[{\"pane_id\":\"w1:p1\",\"cwd\":\"$HOME_ABS\",\"foreground_cwd\":\"$HOME_ABS\"}]")
set_pane "$server" w1:p1 "shell $HOME_ABS"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a restored bare shell must not stop the start: $out"
assert_not_contains "$out" "already up" \
  "RESTORED SHELL: a pane holding nothing but a shell is not a running firstmate"
[ "$(started_count "$server")" = 1 ] ||
  fail "RESTORED SHELL: a bare shell in the firstmate home must not block the start"
pass "liveness: a restored bare shell in the home does not count as a firstmate"

# ... and the same shell must not be mistaken for a firstmate when it appears
# in the agent registry either, which is where the pre-0.8 ghost records live.
server=$(new_server "$TMP_ROOT/s-restored-shell-agent" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 "shell $HOME_ABS"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a registry entry backed by a bare shell must not stop the start: $out"
[ "$(started_count "$server")" = 1 ] ||
  fail "RESTORED SHELL: a registry entry over a bare shell must not block the start"
pass "liveness: a registry entry backed by only a shell does not count as a firstmate"

# A ghost sitting next to the real thing: the husk must be skipped, and the scan
# must go on to find the live one rather than starting a second supervisor.
server=$(new_server "$TMP_ROOT/s-ghost-and-live" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"},
    {\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p2\"}]")
set_pane "$server" w1:p1 ghost
set_pane "$server" w1:p2 "live $HOME_ABS"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a live firstmate beside a ghost must be a no-op: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: a ghost listed before the live firstmate must not license a start"
pass "liveness: a ghost listed beside the live firstmate does not license a start"

# THE 2026-07-20 BOOT REGRESSION. herdr 0.7.4 reports agent_status "unknown"
# for a genuinely live, registered, captain-serving firstmate - verified live
# against the running one. Judging liveness on that metadata made two real
# boots report failure (exit 4 after a successful start, exit 3 on the
# already-up no-op). A live process must be believed regardless of what
# agent_status claims.
server=$(new_server "$TMP_ROOT/s-status-unknown" \
  "[{\"name\":\"firstmate\",\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"unknown\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 "live $HOME_ABS"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a live firstmate with agent_status 'unknown' must be a clean no-op: $out"
assert_contains "$out" "already up" \
  "REGRESSION: the herdr 0.7.4 'unknown' status must not hide a live firstmate"
[ "$(started_count "$server")" = 0 ] ||
  fail "REGRESSION: agent_status 'unknown' must never license a duplicate start"
pass "regression: agent_status 'unknown' (herdr 0.7.4) no longer breaks the no-op"

# The identity guard behind a cwd match: the MATCH came from replayable
# metadata, so the pane's live process must really work in the firstmate home.
# A live process that cannot be tied to the home is unknown - it might be the
# firstmate mid-tool-call - so nothing is started and nothing is claimed.
server=$(new_server "$TMP_ROOT/s-cwd-mismatch" \
  "[{\"name\":null,\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 "live /somewhere/entirely/else"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "a cwd-matched entry whose process works elsewhere must fail closed: $out"
assert_not_contains "$out" "already up" \
  "IDENTITY: a process that cannot be tied to the home must not count as firstmate"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDENTITY: an unconfirmable process must never license a start"
pass "identity: a cwd-matched entry needs the process really working in the home"

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

# The same uncertainty one layer in: process-info ANSWERS for this pane, so the
# pane is real and a process is behind it, but the body carries nothing that
# says what is running there. "Could not read it" is not "there is only a
# shell", and only the husk verdict licenses a start, so this must fail closed
# rather than start a second supervisor beside a live firstmate.
server=$(new_server "$TMP_ROOT/s-pane-opaque" '[]' \
  "[{\"pane_id\":\"w1:p1\",\"cwd\":\"$HOME_ABS\",\"foreground_cwd\":\"$HOME_ABS\"}]")
set_pane "$server" w1:p1 opaque
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "a pane whose process-info says nothing must exit 3: $out"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an unreadable process-info must never be scored a husk and license a start"
pass "liveness: a pane whose process-info cannot be read fails closed, not as a husk"

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

# The pane inventory is now load-bearing, so losing it is exactly as unknown as
# losing the agent registry: the live firstmate could be the entry never read.
server=$(new_server "$TMP_ROOT/s-panelistfail")
: > "$server/panelist_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "an unreadable pane list must exit 3"
assert_contains "$out" "refusing to start a possible duplicate" \
  "an unreadable pane list must say why it refused"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: an unreadable pane list must never lead to a start"
pass "idempotence: an unreadable pane list fails closed and starts nothing"

server=$(new_server "$TMP_ROOT/s-panelistjunk")
printf '{"id":"cli:pane:list","error":{"code":"nope"}}\n' > "$server/panes.json"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "a pane-list error response must exit 3, not be read as an empty fleet"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: a pane-list error must never be read as 'no firstmate present'"
pass "idempotence: a pane-list error response is unknown state, not an empty fleet"

server=$(new_server "$TMP_ROOT/s-paneshortread")
printf '{"id":"cli:pane:list","result":{"panes":"not-an-array","type":"pane_list"}}\n' \
  > "$server/panes.json"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 3 "$rc" "a panes field that cannot be walked must exit 3"
[ "$(started_count "$server")" = 0 ] ||
  fail "IDEMPOTENCE: a partial pane extraction must never be read as an empty fleet"
pass "idempotence: an unwalkable panes field fails closed rather than starting"

# --- end-to-end idempotence -------------------------------------------------

server=$(new_server "$TMP_ROOT/s-twice")
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "the first run on an empty server must start firstmate: $out"
[ "$(started_count "$server")" = 1 ] || fail "the first run must start exactly one agent"
assert_contains "$(cat "$server/create.log")" "--cwd $HOME_ABS" \
  "the workspace must be created in the resolved firstmate home"
assert_contains "$(cat "$server/create.log")" "--no-focus" \
  "the workspace create must never steal the captain's focus"
assert_contains "$(cat "$server/launch.log")" "claude" \
  "the launch command must run claude"
assert_contains "$(cat "$server/launch.log")" "--continue" \
  "the launch must use --continue so it survives session-id churn"
assert_contains "$(cat "$server/launch.log")" "--dangerously-skip-permissions" \
  "the launch must pass the unattended flag rather than depend on the shim"
# The fallback is what keeps a host with nothing to resume from booting into a
# dead pane: `claude --continue` exits non-zero there.
assert_contains "$(cat "$server/launch.log")" "|| claude --dangerously-skip-permissions --remote-control" \
  "the launch must fall back to a fresh session when there is nothing to continue"

out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "the second run must be a clean no-op: $out"
assert_contains "$out" "already up" "the second run must report firstmate already up"
[ "$(started_count "$server")" = 1 ] ||
  fail "IDEMPOTENCE: running the unit twice must never produce a second firstmate"
pass "idempotence: running twice against one server starts exactly one firstmate"

# --- the network gate -------------------------------------------------------

# Unreachable network: the gate must poll (not sleep once), stay bounded by
# --net-timeout, exit 5 - its own distinct code - and start NOTHING. The
# failure report must name the endpoint and say which layer looks broken.
server=$(new_server "$TMP_ROOT/s-netdown")
: > "$server/net_curl_fail"
: > "$server/net_ping_fail"
out=$(run_autostart "$server" "$HOME_DIR" --net-timeout 1)
rc=$?
expect_code 5 "$rc" "an unreachable network must exit 5: $out"
assert_contains "$out" "network gate FAILED" "the gate must fail loudly"
assert_contains "$out" "api.anthropic.com" "the failure must name the endpoint it probed"
assert_contains "$out" "started nothing" "the failure must state that nothing was started"
assert_contains "$out" "ICMP" "the failure must report the routing diagnosis too"
[ "$(started_count "$server")" = 0 ] ||
  fail "NETWORK GATE: an unreachable network must never start an agent"
[ "$(wc -l < "$server/net_curl.log" | tr -d ' ')" -gt 1 ] ||
  fail "NETWORK GATE: reachability must be POLLED, not probed once and slept"
pass "network gate: an unreachable network exits 5, bounded, polling, starting nothing"

# Reachable only on a later poll: the captain accepts boot delay, so the gate
# waits and then proceeds. This is the slow-DHCP/slow-WiFi boot.
server=$(new_server "$TMP_ROOT/s-netlater")
printf '3\n' > "$server/net_curl_ok_after"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a network that comes up during the wait must allow the start: $out"
assert_contains "$out" "network gate passed" "the gate must log that it passed, and when"
[ "$(started_count "$server")" = 1 ] ||
  fail "NETWORK GATE: a late-arriving network must still produce exactly one firstmate"
pass "network gate: a network arriving on a later poll is waited for, then used"

# ICMP filtered but the endpoint reachable: ping is diagnostic only, and a
# network that filters ICMP must never wedge the boot.
server=$(new_server "$TMP_ROOT/s-noicmp")
: > "$server/net_ping_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a filtered-ICMP network with a reachable endpoint must start: $out"
[ "$(started_count "$server")" = 1 ] ||
  fail "NETWORK GATE: filtered ICMP must not block a start when the endpoint answers"
pass "network gate: filtered ICMP does not block a reachable start"

# An already-live firstmate needs nothing from the network: the no-op must
# stay exit 0 with the network fully down, or a WiFi blip would flip the unit
# to failed over a fleet that is fine.
server=$(new_server "$TMP_ROOT/s-netdown-noop" \
  "[{\"name\":\"firstmate\",\"cwd\":\"$HOME_ABS\",\"agent\":\"claude\",\"agent_status\":\"unknown\",\"pane_id\":\"w1:p1\"}]")
set_pane "$server" w1:p1 "live $HOME_ABS"
: > "$server/net_curl_fail"
: > "$server/net_ping_fail"
out=$(run_autostart "$server" "$HOME_DIR" --net-timeout 1)
rc=$?
expect_code 0 "$rc" "the already-up no-op must not depend on the network: $out"
assert_contains "$out" "already up" "the no-op must still report firstmate already up"
pass "network gate: the already-up no-op succeeds with the network down"

# --skip-net-check is the deliberate offline escape hatch.
server=$(new_server "$TMP_ROOT/s-netskip")
: > "$server/net_curl_fail"
out=$(run_autostart "$server" "$HOME_DIR" --skip-net-check)
rc=$?
expect_code 0 "$rc" "--skip-net-check must bypass the gate: $out"
[ "$(started_count "$server")" = 1 ] ||
  fail "NETWORK GATE: --skip-net-check must still start exactly one agent"
[ -f "$server/net_curl.log" ] && fail "--skip-net-check must not probe at all"
pass "network gate: --skip-net-check starts without probing"

# --- start failures ---------------------------------------------------------

server=$(new_server "$TMP_ROOT/s-runfail")
: > "$server/run_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "a launch command that cannot be sent must exit 4"
assert_contains "$out" "no firstmate is running" "a failed launch must say so plainly"
[ "$(closed_count "$server")" = 1 ] ||
  fail "a failed launch must not leave its half-built workspace behind"
pass "failure: a launch that cannot be sent is reported loudly and cleaned up"

# A workspace that cannot be created is a refusal, not a silent no-op, and
# nothing may be typed anywhere.
server=$(new_server "$TMP_ROOT/s-wsfail")
: > "$server/ws_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "a failing workspace create must exit 4"
assert_contains "$out" "could not create the firstmate workspace" \
  "a failed create must name what could not be created"
[ "$(started_count "$server")" = 0 ] || fail "a failed create must never launch anything"
pass "failure: a workspace that cannot be created is refused loudly"

# A create response with no pane of its own. Every supported release reports
# one, so this is release drift, and it is refused loudly rather than routed
# around: typing a firstmate launch into a pane picked by some other rule is
# worse than not starting.
server=$(new_server "$TMP_ROOT/s-nopane-response")
: > "$server/ws_nopane"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "a create response carrying no pane must exit 4"
assert_contains "$out" "root_pane" "the refusal must name the field that was missing"
[ "$(started_count "$server")" = 0 ] ||
  fail "a create response with no pane must never be launched into"
[ "$(closed_count "$server")" = 1 ] ||
  fail "a create response with no pane must not leave the workspace it created behind"
pass "failure: a create response carrying no pane is refused loudly and cleaned up"

# The launch typed fine and never became an agent. That is a failure, loudly,
# and the pane this run created must not be left for the next boot to inherit.
server=$(new_server "$TMP_ROOT/s-inert")
: > "$server/run_inert"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "a launch that never becomes an agent must exit 4"
assert_contains "$out" "no live firstmate appeared" "the confirmation timeout must say what was missing"
[ "$(closed_count "$server")" = 1 ] ||
  fail "a launch that never became an agent must not leave its pane behind"
pass "failure: a launch that never becomes an agent is reported and cleaned up"

# Cleanup must never be the thing that kills a firstmate. Here the launched
# agent is real but cannot be tied to the home, so the boot cannot confirm it -
# and the workspace must be LEFT ALONE, loudly, rather than closed over a live
# agent.
server=$(new_server "$TMP_ROOT/s-cleanup-live")
printf '/somewhere/entirely/else\n' > "$server/run_cwd"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "an unconfirmable launch must still exit 4"
assert_contains "$out" "an agent is running in pane" \
  "cleanup must say which live agent it refused to close over"
[ "$(closed_count "$server")" = 0 ] ||
  fail "CLEANUP: a workspace holding a live agent must never be closed"
pass "failure: cleanup refuses to close a workspace that holds a live agent"

# ... and it refuses just as firmly when it cannot PROVE the workspace is
# agent-free, rather than closing on an unreadable answer.
server=$(new_server "$TMP_ROOT/s-cleanup-blind")
: > "$server/run_inert"
: > "$server/panelist_ws_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "an unconfirmable launch must still exit 4"
assert_contains "$out" "could not inspect workspace" \
  "cleanup must say it could not inspect what it left behind"
[ "$(closed_count "$server")" = 0 ] ||
  fail "CLEANUP: an unprovable workspace must never be closed"
pass "failure: cleanup refuses to close a workspace it cannot prove is agent-free"

# ... and the same refusal when it is the PANE, not the list, that cannot be
# read. The identity probe answers "no agent here" and "I could not look" with
# the same non-zero, so a pane whose process state is unknown must never be
# taken for proof of emptiness: the firstmate may be coming up in it, and
# closing over that is the one outcome worse than reporting the failure.
server=$(new_server "$TMP_ROOT/s-cleanup-unreadable")
printf 'garbage\n' > "$server/run_leaves"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "an unconfirmable launch must still exit 4"
assert_contains "$out" "could not be inspected" \
  "cleanup must say which pane it could not prove empty"
[ "$(closed_count "$server")" = 0 ] ||
  fail "CLEANUP: a pane that cannot be inspected must never be closed over"
pass "failure: cleanup refuses to close over a pane it cannot inspect"

# The fourth refusal, and the only one that is about the RELEASE rather than the
# workspace. Below the floor where an explicit close preserves focus, closing an
# emptied workspace hands focus to its right neighbor, so a boot that failed
# while the captain was working would yank the captain off the space being
# watched. A stray workspace is recoverable; that is not.
server=$(new_server "$TMP_ROOT/s-cleanup-belowfloor")
printf '0.7.4 16\n' > "$server/release"
: > "$server/run_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "a failed launch must still exit 4 below the floor"
assert_contains "$out" "is below the 0.8.0 floor" \
  "the refusal must name the release and the floor it is below"
assert_contains "$out" "Close it by hand" "the refusal must say the workspace was left behind"
[ "$(closed_count "$server")" = 0 ] ||
  fail "FOCUS: a workspace must never be closed on a release where that steals the captain's focus"
pass "failure: cleanup refuses to close below the focus-safe-close floor"

# ... and an unreadable release refuses just as firmly, because an unprovable
# read never licenses the risky action anywhere else in this script either.
server=$(new_server "$TMP_ROOT/s-cleanup-nofloor")
: > "$server/statusjson_fail"
: > "$server/run_fail"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 4 "$rc" "a failed launch must still exit 4 on an unreadable release"
assert_contains "$out" "could not be read" \
  "the refusal must say the release could not be classified"
[ "$(closed_count "$server")" = 0 ] ||
  fail "FOCUS: an unverifiable release must never license a focus-stealing close"
pass "failure: cleanup refuses to close on a release it cannot classify"

# Nothing waits for the seeded pane's shell before typing into it: `workspace
# create` returns a pane that is already at a prompt (verified on both supported
# releases). Here process-info does not answer for that pane at all, which the
# old readiness loop would have spent the whole --confirm budget on and then
# failed; the launch must simply be typed, and the boot must succeed.
server=$(new_server "$TMP_ROOT/s-nowait")
printf 'dead\n' > "$server/create_pane_state"
out=$(run_autostart "$server" "$HOME_DIR")
rc=$?
expect_code 0 "$rc" "a created pane that does not answer process-info must still be launched into: $out"
[ "$(started_count "$server")" = 1 ] ||
  fail "the launch must be typed without first probing the new pane's shell"
assert_not_contains "$out" "never came up" \
  "the removed pane-shell readiness failure must no longer be reachable"
[ "$(closed_count "$server")" = 0 ] || fail "a successful boot must not close its own workspace"
pass "launch: the launch is typed straight into the created pane, with no readiness wait"

# --- dry run and guards -----------------------------------------------------

server=$(new_server "$TMP_ROOT/s-dry")
out=$(run_autostart "$server" "$HOME_DIR" --dry-run)
rc=$?
expect_code 0 "$rc" "--dry-run must succeed: $out"
assert_contains "$out" "herdr workspace create --cwd $HOME_ABS --label firstmate --no-focus" \
  "--dry-run must print the exact create it would run"
assert_contains "$out" "herdr pane run" "--dry-run must print the exact launch it would run"
assert_contains "$out" "claude --dangerously-skip-permissions --remote-control --continue ||" \
  "--dry-run's plan must be the command the real path would actually type"
[ "$(started_count "$server")" = 0 ] || fail "--dry-run must never start an agent"
assert_contains "$out" "network gate would pass" \
  "--dry-run must report the gate's current verdict"
pass "dry run: reports the decision and the command without starting anything"

# A dry run on a dead network still succeeds - it reports what a real run
# would do (poll, then exit 5) instead of holding the shell for --net-timeout.
server=$(new_server "$TMP_ROOT/s-dry-netdown")
: > "$server/net_curl_fail"
: > "$server/net_ping_fail"
out=$(run_autostart "$server" "$HOME_DIR" --dry-run)
rc=$?
expect_code 0 "$rc" "--dry-run must succeed even offline: $out"
assert_contains "$out" "would currently FAIL" \
  "an offline dry run must report the gate verdict without failing"
assert_contains "$out" "would run:" "an offline dry run must still print the command"
[ "$(started_count "$server")" = 0 ] || fail "an offline --dry-run must never start an agent"
[ "$(wc -l < "$server/net_curl.log" | tr -d ' ')" -le 2 ] ||
  fail "an offline --dry-run must probe once, not poll for --net-timeout"
pass "dry run: reports an offline gate verdict without waiting or failing"

server=$(new_server "$TMP_ROOT/s-argv")
out=$(run_autostart "$server" "$HOME_DIR" -- echo hello)
rc=$?
expect_code 0 "$rc" "an explicit -- argv must be honoured: $out"
assert_contains "$(cat "$server/launch.log")" "echo hello" \
  "an explicit -- argv must replace the default command"
assert_not_contains "$(cat "$server/launch.log")" "--continue" \
  "an explicit -- argv must not also carry the default flags"
assert_not_contains "$(cat "$server/launch.log")" "||" \
  "an argv that never asked to continue must not carry a fallback"
pass "argv: an explicit -- command replaces the default"

# The `-- <argv>` escape hatch has to be able to SUCCEED, and its command is by
# definition not one of our harnesses. Confirmation therefore asks the question
# such a command can answer - the pane holds a real process that is not merely
# its own shell, working in the firstmate home - so a custom supervisor that
# comes up is confirmed and, critically, is not destroyed by the failure
# cleanup afterwards.
server=$(new_server "$TMP_ROOT/s-argv-custom")
printf 'custom\n' > "$server/run_leaves"
out=$(run_autostart "$server" "$HOME_DIR" -- /usr/local/bin/my-supervisor)
rc=$?
expect_code 0 "$rc" "a custom command that comes up must be confirmed: $out"
assert_contains "$out" "firstmate is up" "a confirmed custom command must report the firstmate up"
[ "$(started_count "$server")" = 1 ] || fail "a custom command must be launched exactly once"
[ "$(closed_count "$server")" = 0 ] ||
  fail "ESCAPE HATCH: cleanup must never close the workspace over a custom command it just started"
pass "argv: a custom non-harness command is confirmed and left running"

# ... and the bare-shell hole stays closed on that path too: a custom command
# that exits leaves the pane holding nothing but its own shell, which is a husk,
# not a running supervisor.
server=$(new_server "$TMP_ROOT/s-argv-custom-inert")
: > "$server/run_inert"
out=$(run_autostart "$server" "$HOME_DIR" -- /usr/local/bin/my-supervisor)
rc=$?
expect_code 4 "$rc" "a custom command that leaves only a shell must exit 4"
assert_contains "$out" "no live firstmate appeared" "the confirmation timeout must say what was missing"
[ "$(closed_count "$server")" = 1 ] ||
  fail "a custom command that never came up must not leave its pane behind"
pass "argv: a custom command that leaves only a shell is still a husk"

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
assert_contains "$tmpl" "After=network-online.target" \
  "the template must carry the captain-decided network ordering"
assert_contains "$tmpl" "Wants=network-online.target" \
  "the template must pull in network-online.target where a provider exists"
assert_contains "$tmpl" 'Environment="PATH=%h/.local/bin' \
  "the template must set the PATH a user unit does not inherit (herdr lives in ~/.local/bin)"
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
