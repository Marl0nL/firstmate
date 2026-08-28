#!/usr/bin/env bash
# Portable unit test for bin/fm-launch-health-lib.sh - the classifier that
# separates a healthy firstmate-launched Claude from a Herdr-resumed husk that
# dropped --dangerously-skip-permissions (the restored manual-permission-mode
# stall). It pins the decision logic with pure strings AND with real processes
# read through /proc, so CI enforces the classifier without needing Herdr or a
# real Claude. That the flag is the shape a real firstmate launch actually
# carries is a harness-dependent fact recorded in
# docs/verification/runtime-backends.md and proven live by the lab e2e
# (tests/fm-secondmate-manual-mode-e2e.test.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-launch-health-lib.sh
. "$ROOT/bin/fm-launch-health-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-launch-health-lib)

assert_verdict() {  # <label> <want> <argv>
  local got
  got=$(fm_launch_health_verdict "$3")
  [ "$got" = "$2" ] || fail "$1: want verdict '$2' got '$got'"
}

# --- The causal permission flag is the sole authority for the verdict ------

# Healthy: the real launch shape - version path, permission flag, model/effort.
assert_verdict "flag present in the real launch shape" healthy \
  '/home/u/.local/share/claude/versions/2.1.250 --dangerously-skip-permissions --model claude-opus-4-8 --effort xhigh'

# A present flag alone is healthy: the mate skips permission prompts and cannot
# silently stall.
assert_verdict "flag present alone" healthy \
  '/home/u/.local/share/claude/versions/2.1.250 --dangerously-skip-permissions'

# Degraded: the herdr resume shape - a --resume line with the flag dropped.
assert_verdict "flag absent on a resume line" degraded \
  '/home/u/.local/share/claude/versions/2.1.250 --resume 17ac2d21-172d-4965-990a'
assert_verdict "flag absent on a bare launch" degraded \
  '/home/u/claude --resume abc'

# Unreadable argv preserves the pane.
assert_verdict "empty argv is unknown" unknown ''

# Token-boundary safety: a longer flag that only starts the same must NOT count
# as the permission flag, so the mate reads degraded (the real flag is absent).
assert_verdict "longer look-alike flag is not the flag" degraded \
  '/home/u/claude --dangerously-skip-permissions-extra'

# --- The predicate helper in isolation --------------------------------------

fm_launch_health_argv_has_skip_flag 'a --dangerously-skip-permissions b' \
  || fail "argv predicate: should match a middle token"
fm_launch_health_argv_has_skip_flag 'claude --dangerously-skip-permissions' \
  || fail "argv predicate: should match a trailing token"
! fm_launch_health_argv_has_skip_flag 'claude --model m' \
  || fail "argv predicate: must not match when the flag is absent"

# --- End-to-end against REAL processes (Linux /proc) -----------------------
# Confirm the classifier reaches the right verdict from a genuine process's
# argv, not just from hand-built strings. Skips where /proc is unavailable
# (e.g. macOS), where the herdr backend does not run anyway.
if [ -r "/proc/$$/cmdline" ]; then
  FAKE_DIR="$TMP_ROOT/claude/versions/9.9.9"
  mkdir -p "$FAKE_DIR"
  # A process whose install path carries a 'claude' component, so
  # fm_harness_process_matches would identify it exactly as a real version-named
  # Claude Code binary is identified. It blocks so its /proc is readable and
  # exits on a signal; each short sleep child inherits the /dev/null fds the
  # launch redirect gives it, so nothing here holds this test's stdout open.
  cat > "$FAKE_DIR/claude" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$FAKE_DIR/claude"

  read_proc_argv() {  # <pid> -> joined argv on stdout
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
  }
  verdict_of_pid() {  # <pid> -> verdict from its real argv
    fm_launch_health_verdict "$(read_proc_argv "$1")"
  }

  # Each fake is launched with its own fds detached from this test's stdout so a
  # lingering process can never keep the runner's output pipe open.
  # Healthy: launched with the flag (and the launch-detail env prefixes a real
  # firstmate launch also carries, which the verdict deliberately ignores).
  HERDR_ENV=0 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    "$FAKE_DIR/claude" --dangerously-skip-permissions --model m >/dev/null 2>&1 &
  healthy_pid=$!
  # Degraded: a resume shape - no flag.
  "$FAKE_DIR/claude" --resume abc-123 >/dev/null 2>&1 &
  degraded_pid=$!
  # Give each process a moment to exec into the fake claude.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -r "/proc/$healthy_pid/cmdline" ] && grep -q 'skip-permissions' <(read_proc_argv "$healthy_pid") && break
    sleep 0.2
  done

  # Assert the divergence itself so the case cannot go quietly vacuous: the
  # healthy process's real argv MUST carry the flag and the degraded one MUST NOT.
  read_proc_argv "$healthy_pid" | grep -q -- '--dangerously-skip-permissions' \
    || fail "real-process: healthy argv should carry the permission flag"
  read_proc_argv "$degraded_pid" | grep -q -- '--dangerously-skip-permissions' \
    && fail "real-process: degraded argv must not carry the permission flag" || true

  got=$(verdict_of_pid "$healthy_pid"); [ "$got" = healthy ] \
    || fail "real-process healthy: want healthy got '$got'"
  got=$(verdict_of_pid "$degraded_pid"); [ "$got" = degraded ] \
    || fail "real-process degraded: want degraded got '$got'"

  for p in "$healthy_pid" "$degraded_pid"; do
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
  wait "$healthy_pid" "$degraded_pid" 2>/dev/null || true
else
  echo "note: /proc unavailable; skipped the real-process classifier checks"
fi

echo "ok - fm-launch-health-lib"
