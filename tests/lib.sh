#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Disable fm-spawn.sh's post-launch agent-start confirmation for the suite
# (bin/fm-spawn.sh). Behaviour tests drive fm-spawn against FAKE panes that never
# host a real harness process, so the liveness probe could only ever time out and
# either fail the spawn or waste its full window - noise unrelated to what each
# test checks. The confirmation has its own dedicated coverage in
# tests/fm-spawn-agent-confirm.test.sh, which models the probe explicitly and
# sets FM_SPAWN_CONFIRM=1. A test that wants the check simply overrides this.
export FM_SPAWN_CONFIRM=0

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- /tmp headroom preflight -------------------------------------------------
#
# The 2026-07-16 incident: leaked fm-secondmate-safety fixtures (~365MB each,
# several accumulated across runs) filled a RAM-backed /tmp tmpfs solid, taking
# every shell on the host down with "Disk quota exceeded" - including the shell
# needed to diagnose it. This suite creates its scratch fixtures under
# ${TMPDIR:-/tmp}; fail loudly here, before a single mktemp runs, rather than
# risk wedging the host the same way again. This check runs at source time
# (top level, not inside a command-substitution subshell) so `exit` here
# actually stops the sourcing test script instead of just the subshell - see
# wake-helpers.sh's near-identical caveat about fm_test_tmproot itself.
# FM_TEST_TMP_MIN_KB overrides the default floor for an unusual environment.
if [ -z "${FM_TEST_TMP_GUARD_DONE:-}" ]; then
  FM_TEST_TMP_GUARD_DONE=1
  fm_test_tmp_dir=${TMPDIR:-/tmp}
  fm_test_tmp_min_kb=${FM_TEST_TMP_MIN_KB:-524288}
  fm_test_tmp_avail_kb=$(df -Pk "$fm_test_tmp_dir" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -n "$fm_test_tmp_avail_kb" ] && [ "$fm_test_tmp_avail_kb" -lt "$fm_test_tmp_min_kb" ] 2>/dev/null; then
    printf 'fatal: %s has only %dK free (need >= %dK) - refusing to start tests that create temp fixtures there.\n' \
      "$fm_test_tmp_dir" "$fm_test_tmp_avail_kb" "$fm_test_tmp_min_kb" >&2
    printf 'Free space under %s (or set TMPDIR elsewhere) before running tests; see the 2026-07-16 /tmp-exhaustion incident.\n' \
      "$fm_test_tmp_dir" >&2
    exit 1
  fi
  unset fm_test_tmp_dir fm_test_tmp_min_kb fm_test_tmp_avail_kb
fi

# --- supervision-liveness fixtures ------------------------------------------
#
# Touching state/.last-watcher-beat used to be enough to make a fixture look
# supervised, because fm-guard.sh judged liveness by beacon age. Since 2026-07-31
# liveness is answered from the singleton LOCK (bin/fm-supervision-lib.sh), after
# a beacon-only "healthy" fixture turned out to be the shape that hid a real
# 4.8-hour supervision lapse. A fixture that wants a guard to stay silent must now
# pose a watcher that is genuinely running.
#
# fm_test_pose_live_watcher <state-dir> [home] [watch-path]
# Starts a real placeholder process, records it in the watcher lock exactly as
# bin/fm-watch.sh does, and freshens the beacon. Sets FM_TEST_POSED_WATCHER_PID.
# Register fm_test_stop_posed_watcher for cleanup, or call it when done.
# Posed placeholders are tracked in a FILE, not just a shell array, and their
# stdio is fully redirected. Both details are load-bearing:
#   - Fixture builders are routinely called as `w=$(new_world ...)`. A background
#     job started inside a command substitution INHERITS its stdout, so the
#     substitution cannot close and the caller hangs until the placeholder exits.
#     Full redirection is what keeps `$( )` from blocking.
#   - That same subshell discards any array append, so an on-disk list keyed to
#     the test process is the only record that survives back to the EXIT trap.
# Reaping is always by EXACT recorded pid, never a pattern kill: every firstmate
# home on this machine runs a process whose command line matches fm-watch.sh.
FM_TEST_POSED_WATCHER_PID=
FM_TEST_POSED_PIDFILE="${TMPDIR:-/tmp}/fm-test-posed-watchers.$$"

fm_test_pose_live_watcher() {  # <state-dir> [home] [watch-path]
  local state=$1 home=${2:-} watch=${3:-"$ROOT/bin/fm-watch.sh"} lock="$1/.watch.lock"
  [ -n "$home" ] || home=$(cd "$state/.." && pwd)
  mkdir -p "$lock"
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ] && [ ! -e "$FM_TEST_POSED_PIDFILE" ]; then
    trap fm_test_cleanup EXIT
  fi
  # stdout AND stderr, because either one left attached to a command
  # substitution keeps it from closing. stdin needs no redirect - sleep never
  # reads it - and adding one only trips SC2217.
  sleep 300 >/dev/null 2>&1 &
  FM_TEST_POSED_WATCHER_PID=$!
  printf '%s\n' "$FM_TEST_POSED_WATCHER_PID" >> "$FM_TEST_POSED_PIDFILE"
  printf '%s\n' "$FM_TEST_POSED_WATCHER_PID" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$watch" > "$lock/watcher-path"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$FM_TEST_POSED_WATCHER_PID" > "$lock/pid-identity"
  touch "$state/.last-watcher-beat"
}

fm_test_stop_posed_watcher() {
  [ -n "$FM_TEST_POSED_WATCHER_PID" ] || return 0
  kill -TERM "$FM_TEST_POSED_WATCHER_PID" 2>/dev/null || true
  wait "$FM_TEST_POSED_WATCHER_PID" 2>/dev/null || true
  FM_TEST_POSED_WATCHER_PID=
}

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <varname> <prefix> creates a fresh temp dir, registers it for
# removal on EXIT, and assigns its path to <varname> directly (never through
# command substitution: `VAR=$(fm_test_tmproot ...)` runs the whole function -
# trap install and array append included - inside a throwaway subshell, so
# none of it survives back into the caller. This was the actual mechanism
# behind the 2026-07-16 /tmp-exhaustion incident: the trap fired and cleaned
# up inside that dead-end subshell, the real script process never had a trap
# at all, and every later `mkdir -p "$TMP_ROOT/..."` silently recreated the
# directory the doomed trap had just deleted). The first call installs the
# cleanup trap. A test file that needs extra teardown (e.g. killing a daemon)
# should define its own EXIT trap and call fm_test_cleanup from inside it so
# registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d pid
  if [ -n "${FM_TEST_POSED_PIDFILE:-}" ] && [ -e "$FM_TEST_POSED_PIDFILE" ]; then
    while read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill -TERM "$pid" 2>/dev/null || true
    done < "$FM_TEST_POSED_PIDFILE"
    rm -f "$FM_TEST_POSED_PIDFILE"
  fi
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local __fm_test_tmproot_var=$1 prefix=${2:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf -v "$__fm_test_tmproot_var" '%s' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
