#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-claude-shim.sh - the fail-open `claude` launcher
# shim that re-adds firstmate's launch flags after a herdr auto-resume.
#
# Every case drives the shim against a FAKE claude binary that echoes its own
# argv and exits with a controllable status. The real ~/.local/bin/claude and
# ~/.local/share/claude are never read, written, or executed by this suite: the
# fake is selected through FM_CLAUDE_SHIM_REAL and through a fixture versions
# directory pointed at by the shim's own config file.
#
# What is proven here: injection only in the firstmate primary session,
# idempotence, untouched pass-through everywhere else, dynamic (never
# version-pinned) resolution of the real binary, sane behaviour when nothing
# resolves, and exit-status/argv fidelity through the exec.
# docs/claude-resume-shim.md owns the install, rollback, and verification steps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-claude-shim

SHIM="$ROOT/bin/fm-claude-shim.sh"
[ -x "$SHIM" ] || fail "bin/fm-claude-shim.sh must be executable"

# --- fixtures ---------------------------------------------------------------

# A fake claude: prints one argument per line prefixed with ARG, so an assertion
# can check exact argv content AND exact ordering. FAKE_EXIT lets a case prove
# the real binary's status survives the shim's exec.
make_fake_claude() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG:%s\n' "$a"; done
exit "${FAKE_EXIT:-0}"
SH
  chmod +x "$path"
}

# A firstmate-shaped primary checkout: the structural markers the shim tests for
# before it will treat a cwd as the firstmate home.
make_home_fixture() {
  local dir=$1
  mkdir -p "$dir/bin"
  : > "$dir/AGENTS.md"
  : > "$dir/bin/fm-spawn.sh"
  printf '%s\n' "$dir"
}

write_conf() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local kv
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$path"
  done
}

HOME_DIR=$(make_home_fixture "$TMP_ROOT/firstmate")
OTHER_DIR="$TMP_ROOT/elsewhere"
mkdir -p "$OTHER_DIR"
FAKE="$TMP_ROOT/fake/claude"
make_fake_claude "$FAKE"

CONF="$TMP_ROOT/conf/claude-shim.conf"
write_conf "$CONF" "home=$HOME_DIR"

# run_shim <cwd> -- <args...>: invoke the shim from <cwd> with the fixture
# config and the fake binary, capturing stdout. Deliberately runs in a subshell
# so a case cannot leak env into the next.
run_shim() {
  local cwd=$1
  shift
  [ "${1:-}" = "--" ] && shift
  (
    cd "$cwd" || exit 1
    FM_CLAUDE_SHIM_CONF="$CONF" \
    FM_CLAUDE_SHIM_REAL="$FAKE" \
      "$SHIM" "$@"
  )
}

# argv_of <output>: collapse the fake's ARG: lines into one space-joined string
# for an exact-match assertion.
argv_of() {
  printf '%s' "$1" | sed -n 's/^ARG://p' | tr '\n' ' ' | sed 's/ $//'
}

# --- (a) firstmate home adds both flags exactly once -------------------------

out=$(run_shim "$HOME_DIR" -- --resume abc123)
argv=$(argv_of "$out")
[ "$argv" = "--dangerously-skip-permissions --remote-control --resume abc123" ] \
  || fail "primary session argv wrong: '$argv'"
pass "primary session: injects both flags ahead of the original args"

# Exactly once, not merely present: count the occurrences.
n_skip=$(printf '%s\n' "$out" | grep -c '^ARG:--dangerously-skip-permissions$')
n_rc=$(printf '%s\n' "$out" | grep -c '^ARG:--remote-control$')
[ "$n_skip" = 1 ] || fail "--dangerously-skip-permissions appeared $n_skip times"
[ "$n_rc" = 1 ] || fail "--remote-control appeared $n_rc times"
pass "primary session: each injected flag appears exactly once"

# A bare launch with no arguments at all is still the primary session shape.
out=$(run_shim "$HOME_DIR")
argv=$(argv_of "$out")
[ "$argv" = "--dangerously-skip-permissions --remote-control" ] \
  || fail "bare primary launch argv wrong: '$argv'"
pass "primary session: bare launch gets both flags"

# The explicit env marker is an alternative to the cwd match, so a launch from a
# different directory can still be declared primary by firstmate itself.
out=$(cd "$OTHER_DIR" && FM_CLAUDE_SHIM_CONF="$CONF" FM_CLAUDE_SHIM_REAL="$FAKE" \
  FM_CLAUDE_SHIM_PRIMARY=1 "$SHIM" --resume x)
argv=$(argv_of "$out")
[ "$argv" = "--dangerously-skip-permissions --remote-control --resume x" ] \
  || fail "FM_CLAUDE_SHIM_PRIMARY argv wrong: '$argv'"
pass "primary session: the explicit env marker also enables injection"

# --- (b) idempotence: a flag already present is never duplicated -------------

out=$(run_shim "$HOME_DIR" -- --dangerously-skip-permissions --resume abc)
argv=$(argv_of "$out")
[ "$argv" = "--remote-control --dangerously-skip-permissions --resume abc" ] \
  || fail "idempotence (skip-permissions) argv wrong: '$argv'"
n_skip=$(printf '%s\n' "$out" | grep -c '^ARG:--dangerously-skip-permissions$')
[ "$n_skip" = 1 ] || fail "--dangerously-skip-permissions duplicated ($n_skip)"
pass "idempotence: an existing --dangerously-skip-permissions is not re-added"

out=$(run_shim "$HOME_DIR" -- --remote-control --resume abc)
n_rc=$(printf '%s\n' "$out" | grep -c '^ARG:--remote-control$')
[ "$n_rc" = 1 ] || fail "--remote-control duplicated ($n_rc)"
pass "idempotence: an existing --remote-control is not re-added"

# The --flag=value form counts as present too.
out=$(run_shim "$HOME_DIR" -- --remote-control=mypane --resume abc)
n_rc=$(printf '%s\n' "$out" | grep -c '^ARG:--remote-control$')
[ "$n_rc" = 0 ] || fail "--remote-control added despite --remote-control=value"
pass "idempotence: the --flag=value form also counts as present"

# Both already present: nothing is added at all.
out=$(run_shim "$HOME_DIR" -- --remote-control --dangerously-skip-permissions --resume abc)
argv=$(argv_of "$out")
[ "$argv" = "--remote-control --dangerously-skip-permissions --resume abc" ] \
  || fail "both-present argv changed: '$argv'"
pass "idempotence: with both flags present the args are unchanged"

# A near-miss flag must not be mistaken for --remote-control.
out=$(run_shim "$HOME_DIR" -- --remote-control-session-name-prefix fm)
n_rc=$(printf '%s\n' "$out" | grep -c '^ARG:--remote-control$')
[ "$n_rc" = 1 ] || fail "--remote-control-session-name-prefix confused the flag test"
pass "idempotence: a longer flag with the same prefix is not a false match"

# --- (c) any other cwd passes through completely unchanged -------------------

out=$(run_shim "$OTHER_DIR" -- --resume abc123)
argv=$(argv_of "$out")
[ "$argv" = "--resume abc123" ] || fail "non-home cwd was modified: '$argv'"
pass "pass-through: an unrelated cwd is untouched"

# A subdirectory of the home is NOT the primary session - a crewmate worktree or
# a project clone must never be given the flags.
mkdir -p "$HOME_DIR/projects/example"
out=$(run_shim "$HOME_DIR/projects/example" -- --resume abc)
argv=$(argv_of "$out")
[ "$argv" = "--resume abc" ] || fail "home subdirectory was modified: '$argv'"
pass "pass-through: a subdirectory of the home is not the primary session"

# A leading positional is a prompt or a subcommand, never an interactive resume.
out=$(run_shim "$HOME_DIR" -- mcp list)
argv=$(argv_of "$out")
[ "$argv" = "mcp list" ] || fail "subcommand launch was modified: '$argv'"
pass "pass-through: a subcommand launch from the home is untouched"

# A one-shot --print run must not be made remote-controlled.
out=$(run_shim "$HOME_DIR" -- --print --model sonnet)
argv=$(argv_of "$out")
[ "$argv" = "--print --model sonnet" ] || fail "--print launch was modified: '$argv'"
pass "pass-through: a --print run from the home is untouched"

out=$(run_shim "$HOME_DIR" -- -p)
argv=$(argv_of "$out")
[ "$argv" = "-p" ] || fail "-p launch was modified: '$argv'"
pass "pass-through: a -p run from the home is untouched"

# Informational launches start no session, and `claude --version` is the
# documented post-install smoke test, so it must be byte-identical to unshimmed.
for informational in --version -v --help -h; do
  out=$(run_shim "$HOME_DIR" -- "$informational")
  argv=$(argv_of "$out")
  [ "$argv" = "$informational" ] || fail "$informational launch was modified: '$argv'"
done
pass "pass-through: --version/--help launches from the home are untouched"

# A cwd that matches home= but no longer looks like a firstmate checkout is not
# trusted: the shim degrades to pass-through rather than guessing.
NOT_FM="$TMP_ROOT/not-firstmate"
mkdir -p "$NOT_FM"
write_conf "$TMP_ROOT/conf/nofm.conf" "home=$NOT_FM"
out=$(cd "$NOT_FM" && FM_CLAUDE_SHIM_CONF="$TMP_ROOT/conf/nofm.conf" \
  FM_CLAUDE_SHIM_REAL="$FAKE" "$SHIM" --resume abc)
argv=$(argv_of "$out")
[ "$argv" = "--resume abc" ] || fail "non-firstmate home= was trusted: '$argv'"
pass "pass-through: a home= that is not a firstmate checkout is not trusted"

# No config at all: nothing is known, so nothing is injected.
out=$(cd "$HOME_DIR" && FM_CLAUDE_SHIM_CONF="$TMP_ROOT/conf/absent.conf" \
  FM_CLAUDE_SHIM_REAL="$FAKE" "$SHIM" --resume abc)
argv=$(argv_of "$out")
[ "$argv" = "--resume abc" ] || fail "absent config still injected: '$argv'"
pass "pass-through: an absent config file injects nothing"

# The kill switch wins even in the primary session.
out=$(cd "$HOME_DIR" && FM_CLAUDE_SHIM_CONF="$CONF" FM_CLAUDE_SHIM_REAL="$FAKE" \
  FM_CLAUDE_SHIM_DISABLE=1 "$SHIM" --resume abc)
argv=$(argv_of "$out")
[ "$argv" = "--resume abc" ] || fail "FM_CLAUDE_SHIM_DISABLE ignored: '$argv'"
pass "pass-through: FM_CLAUDE_SHIM_DISABLE suppresses injection"

# --- dynamic resolution: never a pinned version path -------------------------

# A versions directory shaped like claude's own: several executable version
# files side by side. The shim must select the newest by version order, so an
# auto-update that drops a new file in is picked up with no config change.
VERSIONS="$TMP_ROOT/versions"
for v in 2.1.9 2.1.10 2.1.212; do
  make_fake_claude "$VERSIONS/$v"
done
write_conf "$TMP_ROOT/conf/versions.conf" "home=$HOME_DIR" "versions_dir=$VERSIONS"

explain=$(cd "$HOME_DIR" && FM_CLAUDE_SHIM_CONF="$TMP_ROOT/conf/versions.conf" \
  "$SHIM" --fm-shim-explain)
assert_contains "$explain" "real:        $VERSIONS/2.1.212" \
  "versions dir resolution should pick the highest version"
pass "resolution: the newest entry in the versions dir wins (version order, not lexical)"

# Simulate an auto-update: a newer version appears, and the shim follows it with
# no edit to the config. This is the whole point of resolving dynamically.
make_fake_claude "$VERSIONS/2.1.215"
explain=$(cd "$HOME_DIR" && FM_CLAUDE_SHIM_CONF="$TMP_ROOT/conf/versions.conf" \
  "$SHIM" --fm-shim-explain)
assert_contains "$explain" "real:        $VERSIONS/2.1.215" \
  "a newly installed version should be picked up with no config change"
pass "resolution: a new version installed by auto-update is followed automatically"

# The real= entry is the documented fallback for a non-standard install.
write_conf "$TMP_ROOT/conf/real.conf" "home=$HOME_DIR" \
  "versions_dir=$TMP_ROOT/no-such-versions" "real=$FAKE"
out=$(cd "$HOME_DIR" && FM_CLAUDE_SHIM_CONF="$TMP_ROOT/conf/real.conf" "$SHIM" --resume abc)
argv=$(argv_of "$out")
[ "$argv" = "--dangerously-skip-permissions --remote-control --resume abc" ] \
  || fail "real= fallback did not resolve: '$argv'"
pass "resolution: the config real= entry is used when the versions dir is empty"

# The shim must never resolve to itself, or it would exec into a loop. Put a
# copy of the shim on PATH under the name `claude` and give it nothing else to
# find: it must report failure rather than re-enter itself.
LOOPBIN="$TMP_ROOT/loopbin"
mkdir -p "$LOOPBIN"
cp "$SHIM" "$LOOPBIN/claude"
chmod +x "$LOOPBIN/claude"
write_conf "$TMP_ROOT/conf/loop.conf" "home=$HOME_DIR" \
  "versions_dir=$TMP_ROOT/no-such-versions"
set +e
loop_out=$(cd "$HOME_DIR" && PATH="$LOOPBIN:/usr/bin:/bin" \
  FM_CLAUDE_SHIM_CONF="$TMP_ROOT/conf/loop.conf" \
  FM_CLAUDE_SHIM_REAL="" \
  HOME="$TMP_ROOT/emptyhome" "$LOOPBIN/claude" --resume abc 2>&1)
loop_code=$?
set -e
expect_code 127 "$loop_code" "self-resolution must fail rather than loop"
assert_contains "$loop_out" "could not resolve the real claude binary" \
  "self-resolution should report the unresolved binary"
pass "resolution: the shim refuses to exec itself"

# --- (d) unresolvable real binary fails open sanely --------------------------

mkdir -p "$TMP_ROOT/emptybin"
set +e
unresolved=$(cd "$HOME_DIR" && PATH="$TMP_ROOT/emptybin:/usr/bin:/bin" \
  FM_CLAUDE_SHIM_CONF="$TMP_ROOT/conf/absent.conf" \
  HOME="$TMP_ROOT/emptyhome" "$SHIM" --resume abc 2>&1)
unresolved_code=$?
set -e
expect_code 127 "$unresolved_code" "unresolved real binary should exit 127"
assert_contains "$unresolved" "could not resolve the real claude binary" \
  "unresolved real binary should say so plainly"
assert_contains "$unresolved" "Rollback" \
  "the unresolved message should point at the rollback steps"
pass "fail-open: an unresolvable real binary reports plainly and exits 127"

# The diagnostic surface never execs anything, even with a real binary present.
explain=$(cd "$HOME_DIR" && FM_CLAUDE_SHIM_CONF="$CONF" FM_CLAUDE_SHIM_REAL="$FAKE" \
  "$SHIM" --fm-shim-explain)
assert_contains "$explain" "primary:     yes" "explain should report primary detection"
assert_contains "$explain" "decision:    inject" "explain should report the decision"
assert_not_contains "$explain" "ARG:" "explain must not exec the real binary"
pass "fail-open: --fm-shim-explain reports the decision without exec'ing"

explain=$(cd "$OTHER_DIR" && FM_CLAUDE_SHIM_CONF="$CONF" FM_CLAUDE_SHIM_REAL="$FAKE" \
  "$SHIM" --fm-shim-explain)
assert_contains "$explain" "primary:     no" "explain should report a non-primary cwd"
assert_contains "$explain" "decision:    passthrough" "explain should report pass-through"
pass "fail-open: --fm-shim-explain reports pass-through outside the home"

# --- (e) exit status and argument fidelity ----------------------------------

set +e
(cd "$HOME_DIR" && FM_CLAUDE_SHIM_CONF="$CONF" FM_CLAUDE_SHIM_REAL="$FAKE" \
  FAKE_EXIT=42 "$SHIM" --resume abc >/dev/null)
code=$?
set -e
expect_code 42 "$code" "the real binary's exit status must survive the exec"
pass "fidelity: the real binary's exit status is preserved"

set +e
(cd "$OTHER_DIR" && FM_CLAUDE_SHIM_CONF="$CONF" FM_CLAUDE_SHIM_REAL="$FAKE" \
  FAKE_EXIT=7 "$SHIM" --resume abc >/dev/null)
code=$?
set -e
expect_code 7 "$code" "exit status must survive the pass-through path too"
pass "fidelity: the exit status is preserved on the pass-through path"

# Arguments with spaces, empty strings, globs, and quotes must arrive byte-exact
# on both paths. The fake prints one line per argument, so a count plus an
# exact-content check catches any word splitting or glob expansion.
check_arg_fidelity() {
  local cwd=$1 label=$2 skip=$3 out n
  out=$(cd "$cwd" && FM_CLAUDE_SHIM_CONF="$CONF" FM_CLAUDE_SHIM_REAL="$FAKE" \
    "$SHIM" --resume 'a b c' --model '' --append-system-prompt '*' --x "it's \"quoted\"")
  n=$(printf '%s\n' "$out" | grep -c '^ARG:')
  [ "$n" = "$((8 + skip))" ] || fail "$label: expected $((8 + skip)) args, got $n"
  assert_contains "$out" 'ARG:a b c' "$label: an argument with spaces must stay one argument"
  assert_contains "$out" 'ARG:*' "$label: a glob argument must not be expanded"
  assert_contains "$out" 'ARG:it'"'"'s "quoted"' "$label: quotes must pass through literally"
  # The empty argument must survive as an empty argument, not be dropped.
  printf '%s\n' "$out" | grep -qx 'ARG:' || fail "$label: the empty argument was dropped"
}
check_arg_fidelity "$HOME_DIR" "primary session" 2
check_arg_fidelity "$OTHER_DIR" "pass-through" 0
pass "fidelity: argument boundaries, empties, globs, and quotes survive both paths"

printf 'all fm-claude-shim tests passed\n'
