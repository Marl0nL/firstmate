#!/usr/bin/env bash
# fm-wake-resident-lib.sh - the single owner of the WAKE-RESIDENT secondmate
# record format and its shared predicates. Sourced, never executed.
#
# PERSISTENT and WAKE-RESIDENT are DIFFERENT AXES, and conflating them is how a
# sleeping agent gets destroyed:
#
#   Persistent    - the IDENTITY and STATE are permanent. The home, the seed
#                   marker, the charter, the backlog, the status log, the runtime
#                   metadata that carries the worktree lease, and the registry
#                   route all survive everything, and are removed only by
#                   bin/fm-teardown.sh on an explicit captain decision.
#   Wake-resident - the PROCESS is not permanent. A message in its chat inbox
#                   raises it through the ordinary secondmate spawn, and an idle
#                   window exits it again.
#
# The standard secondmate wording assumes always-on and so runs the two axes
# together; a wake-resident secondmate is the exception, and it is persistent on
# the first axis exactly as much as any other secondmate.
#
# AN EXIT IS NOT A TEARDOWN AND LOSES NOTHING. That is not an assertion here, it
# is a checked invariant: fm_wr_persistence_* below enumerates what carries the
# identity across a process exit, and the stand-down path snapshots it before the
# exit and verifies it after. docs/wake-resident.md carries the narrative and the
# verification record; this header owns the format.
#
# Config - <home>/config/wake-resident.conf, one record per line:
#   <name> [idle-secs=<n>] [grace-secs=<n>] [inbox=<abs-dir>]
# Blank lines and lines whose first non-blank character is `#` are ignored.
#   name        the secondmate id, exactly as in data/secondmates.md
#   idle-secs   quiet seconds before a stand-down is offered (default 1800)
#   grace-secs  seconds a message may sit unread while the secondmate is already
#               resident before the main home offers to nudge it (default 300)
#   inbox       the chat inbox directory (default <secondmate-home>/state/chat-inbox)
# An unparseable or unsafe record is DROPPED, never guessed at: a wake-resident
# record drives a spawn, so a malformed line must go silent rather than resolve
# to some other home.
#
# Inbox contract - CONSUMED, not defined here. It is docs/crowsnest.md's inbox
# shape, which the quant console writes as its chat transport: `<inbox>/<id>.json`,
# where PRESENT means pending and the answering agent removes the file once it has
# answered. This library reads only the PRESENCE and the mtime of those files and
# never their contents, so the entry's JSON fields stay entirely the producer's to
# shape. Anything more than presence would have to be agreed with the console's
# owner first.
#
# Dormancy record - <state>/<name>.wake-resident, a key=value file this library
# owns. It records the lifecycle's own timestamps and NOTHING that another owner
# already holds:
#   raised_at=<epoch>       last successful raise
#   dormant_since=<epoch>   last successful stand-down
#   last_seen_msg=<epoch>   newest inbox-entry mtime observed by a poll
# It is bookkeeping, not truth: residency is always re-read from the backend.
#
# NOT teardown. Nothing here removes a home, releases a treehouse lease, drops a
# `state/<name>.meta`, edits `data/secondmates.md`, or touches a backlog. Retiring
# a secondmate stays bin/fm-teardown.sh's job and an explicit captain decision.

# The loaded-record surface, declared before first use so sourcing under `set -u`
# is safe. FM_WR_NAME is set for callers, not read in here.
# shellcheck disable=SC2034
FM_WR_NAME=
FM_WR_IDLE_SECS=
FM_WR_GRACE_SECS=
FM_WR_INBOX=

FM_WR_DEFAULT_IDLE_SECS=1800
FM_WR_DEFAULT_GRACE_SECS=300

# Seconds an in-flight raise claim is honored before it is treated as abandoned.
FM_WR_RAISE_CLAIM_SECS=${FM_WR_RAISE_CLAIM_SECS:-180}

fm_wr_now() { date +%s; }

# Portable stat, split the same way bin/fm-check-lib.sh splits it.
if [ "$(uname)" = Darwin ]; then
  fm_wr_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  fm_wr_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# A record name is a secondmate id, so it must be one safe path component.
fm_wr_safe_name() {  # <name>
  local name=${1-}
  local LC_ALL=C
  case "$name" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_wr_positive_int() {  # <value>
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
  esac
}

fm_wr_config_file() {  # <config-dir>
  printf '%s/wake-resident.conf' "$1"
}

# Print the name of every well-formed record, in file order. A record for a name
# already printed is ignored: the FIRST record wins, so a later duplicate cannot
# silently redirect a raise.
#
# Field splitting runs with pathname expansion OFF throughout: this parse decides
# which home gets spawned, so a stray `*` in the file must stay a literal that
# fails validation, never a glob that expands against the working directory. The
# subshell is what scopes `set -f` here; fm_wr_load below sets globals, so it
# saves and restores the flag by hand instead.
fm_wr_names() {  # <config-dir>
  local conf
  conf=$(fm_wr_config_file "$1")
  [ -f "$conf" ] || return 0
  (
    set -f
    local line name seen=' '
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      # shellcheck disable=SC2086
      set -- $line
      name=${1-}
      [ -n "$name" ] || continue
      fm_wr_safe_name "$name" || continue
      case "$seen" in *" $name "*) continue ;; esac
      seen="$seen$name "
      printf '%s\n' "$name"
    done < "$conf"
  )
}

# Load one record into FM_WR_*, resolving every default. Returns non-zero when
# <name> has no well-formed record, so callers fail closed on a typo.
fm_wr_load() {  # <config-dir> <name>
  local conf=$1 name=$2 line first tok rc=1 had_noglob=0
  FM_WR_NAME=
  FM_WR_IDLE_SECS=
  FM_WR_GRACE_SECS=
  FM_WR_INBOX=
  fm_wr_safe_name "$name" || return 1
  conf=$(fm_wr_config_file "$conf")
  [ -f "$conf" ] || return 1
  case $- in *f*) had_noglob=1 ;; esac
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # shellcheck disable=SC2086
    set -- $line
    first=${1-}
    [ "$first" = "$name" ] || continue
    shift
    FM_WR_NAME=$name
    FM_WR_IDLE_SECS=$FM_WR_DEFAULT_IDLE_SECS
    FM_WR_GRACE_SECS=$FM_WR_DEFAULT_GRACE_SECS
    FM_WR_INBOX=
    for tok in "$@"; do
      case "$tok" in
        idle-secs=*)
          tok=${tok#idle-secs=}
          fm_wr_positive_int "$tok" && FM_WR_IDLE_SECS=$tok
          ;;
        grace-secs=*)
          tok=${tok#grace-secs=}
          fm_wr_positive_int "$tok" && FM_WR_GRACE_SECS=$tok
          ;;
        inbox=*)
          tok=${tok#inbox=}
          case "$tok" in /*) FM_WR_INBOX=$tok ;; esac
          ;;
      esac
    done
    rc=0
    break
  done < "$conf"
  [ "$had_noglob" = 1 ] || set +f
  return "$rc"
}

# Resolve and VERIFY the secondmate home behind <name>.
#
# The meta is preferred, and must record kind=secondmate. A home that has never
# been launched has no meta yet, so the registry is the documented fallback -
# the same one secondmate-provisioning's recovery uses - and without it the very
# FIRST message to a newly seeded wake-resident secondmate could never raise it.
#
# Whichever source supplies the path, it is then verified the same way: an
# absolute directory carrying the seeded-secondmate marker for this exact id.
# Anything else prints nothing and fails, because every later step reads or
# writes against this path.
fm_wr_home() {  # <state> <name> [data]
  local state=$1 name=$2 data=${3:-} meta home marker_id line
  fm_wr_safe_name "$name" || return 1
  meta="$state/$name.meta"
  home=
  if [ -f "$meta" ] && grep -q '^kind=secondmate$' "$meta" 2>/dev/null; then
    home=$(fm_meta_get "$meta" home)
    [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
  fi
  if [ -z "$home" ]; then
    [ -n "$data" ] || data="${state%/state}/data"
    [ -f "$data/secondmates.md" ] || return 1
    line=$(grep -E "^- $name( |$)" "$data/secondmates.md" 2>/dev/null | tail -1) || return 1
    home=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p')
  fi
  [ -n "$home" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  [ -d "$home" ] || return 1
  [ -f "$home/.fm-secondmate-home" ] || return 1
  marker_id=$(head -1 "$home/.fm-secondmate-home" 2>/dev/null)
  [ "$marker_id" = "$name" ] || return 1
  printf '%s\n' "$home"
}

# The inbox directory for a loaded record: the explicit `inbox=` when it was
# given, else the home's Crowsnest-shaped chat inbox.
fm_wr_inbox_dir() {  # <home>
  if [ -n "$FM_WR_INBOX" ]; then
    printf '%s\n' "$FM_WR_INBOX"
  else
    printf '%s/state/chat-inbox\n' "$1"
  fi
}

fm_wr_pending_count() {  # <inbox>
  local inbox=$1 f n=0
  [ -d "$inbox" ] || { printf '0\n'; return 0; }
  for f in "$inbox"/*.json; do
    [ -f "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# The oldest pending entry's id, so a burst is surfaced in arrival order across
# cycles exactly as bin/fm-crowsnest-poll.sh does.
fm_wr_oldest_pending() {  # <inbox>
  local inbox=$1 f base id
  [ -d "$inbox" ] || return 1
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    base=${f##*/}
    id=${base%.json}
    fm_wr_safe_name "$id" || continue
    printf '%s\n' "$id"
    return 0
  done < <(ls -1tr "$inbox"/*.json 2>/dev/null)
  return 1
}

# Newest mtime among the pending entries, or 0 when the inbox is empty.
fm_wr_newest_pending_mtime() {  # <inbox>
  local inbox=$1 f m newest=0
  [ -d "$inbox" ] || { printf '0\n'; return 0; }
  for f in "$inbox"/*.json; do
    [ -f "$f" ] || continue
    m=$(fm_wr_mtime "$f") || continue
    [ "$m" -gt "$newest" ] 2>/dev/null && newest=$m
  done
  printf '%s\n' "$newest"
}

# 0 when the secondmate home holds work of its own. The predicate is deliberately
# IDENTICAL to bin/fm-teardown.sh's secondmate refusal - any state/*.meta in that
# home is a live direct report - so "has work in flight" means the same thing to
# the thing that stands a secondmate down and the thing that retires it.
fm_wr_has_inflight_work() {  # <home>
  local home=$1 sub_state meta
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 1
  for meta in "$sub_state"/*.meta; do
    [ -e "$meta" ] || return 1
    return 0
  done
  return 1
}

# Newest mtime anywhere under the home's state dir: the secondmate's own working
# footprint. Used as an activity signal, never as a liveness verdict.
fm_wr_home_activity() {  # <home>
  local home=$1 f m newest=0
  [ -d "$home/state" ] || { printf '0\n'; return 0; }
  for f in "$home/state"/*; do
    [ -e "$f" ] || continue
    m=$(fm_wr_mtime "$f") || continue
    [ "$m" -gt "$newest" ] 2>/dev/null && newest=$m
  done
  printf '%s\n' "$newest"
}

# --- dormancy record --------------------------------------------------------

fm_wr_record_file() {  # <state> <name>
  printf '%s/%s.wake-resident' "$1" "$2"
}

fm_wr_record_get() {  # <state> <name> <key>
  local rec
  rec=$(fm_wr_record_file "$1" "$2")
  [ -f "$rec" ] || return 1
  grep "^$3=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Set one key, preserving the others. Published through a same-directory temp and
# a rename so a concurrent reader never sees a half-written record.
fm_wr_record_set() {  # <state> <name> <key> <value>
  local state=$1 name=$2 key=$3 value=$4 rec tmp
  fm_wr_safe_name "$name" || return 1
  rec=$(fm_wr_record_file "$state" "$name")
  tmp="$rec.tmp.$$"
  {
    [ -f "$rec" ] && grep -v "^$key=" "$rec" 2>/dev/null
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec" || { rm -f "$tmp"; return 1; }
}

# --- the persistent axis ----------------------------------------------------
#
# Everything that carries a wake-resident secondmate's IDENTITY and STATE across
# a process exit, enumerated in exactly one place so the stand-down path and its
# tests cannot disagree about what "loses nothing" means. Prints one path per
# line; a caller that adds an artifact here immediately strengthens the check.
fm_wr_persistence_manifest() {  # <state> <name> <home> <data>
  local state=$1 name=$2 home=$3 data=$4
  printf '%s\n' \
    "$home" \
    "$home/.fm-secondmate-home" \
    "$home/data/charter.md" \
    "$home/data/backlog.md" \
    "$home/state" \
    "$state/$name.meta" \
    "$state/$name.status" \
    "$data/secondmates.md"
}

# Byte size of <path> as bare digits. macOS `wc -c` pads its output, and a padded
# value would fail the all-digits guard in fm_wr_persistence_verify and silently
# skip the shrinkage check on exactly the platform that pads - so strip here, in
# the one place both the snapshot and the verify read sizes through.
# The brace group carries the redirect so a missing file is silent: `2>/dev/null`
# on wc alone does not suppress the SHELL's own "no such file" for a failed input
# redirection, and a lifecycle check must never leak stray stderr.
fm_wr_byte_size() {  # <path>
  local n
  n=$( { wc -c < "$1"; } 2>/dev/null | tr -cd '0-9' )
  printf '%s\n' "${n:-0}"
}

# Snapshot the manifest as `<path>\t<kind>\t<size>` lines, skipping what is
# legitimately absent for this home (not every secondmate has a backlog yet).
fm_wr_persistence_snapshot() {  # <state> <name> <home> <data>
  local path
  while IFS= read -r path; do
    if [ -d "$path" ]; then
      printf '%s\tdir\t0\n' "$path"
    elif [ -f "$path" ]; then
      printf '%s\tfile\t%s\n' "$path" "$(fm_wr_byte_size "$path")"
    fi
  done < <(fm_wr_persistence_manifest "$1" "$2" "$3" "$4")
}

# Compare a snapshot against reality and print one line per LOSS, nothing when
# the identity is intact. Returns 0 when intact, 1 when anything was lost.
#
# The test is presence plus no-shrinkage rather than byte-equality on purpose: a
# status line the agent appends on its way out is its own work, and growth is
# normal. Only removal and truncation are losses.
fm_wr_persistence_verify() {  # <snapshot-file>
  local snap=$1 path kind size now lost=0
  while IFS=$'\t' read -r path kind size; do
    [ -n "$path" ] || continue
    case "$kind" in
      dir)
        if [ ! -d "$path" ]; then
          printf 'LOST directory %s\n' "$path"
          lost=1
        fi
        ;;
      file)
        if [ ! -f "$path" ]; then
          printf 'LOST file %s\n' "$path"
          lost=1
          continue
        fi
        now=$(fm_wr_byte_size "$path")
        # A size that is not bare digits means the snapshot line was malformed,
        # which is itself a loss of the record - report it rather than skip it.
        if case "$now$size" in ''|*[!0-9]*) true ;; *) false ;; esac; then
          printf 'UNREADABLE %s (recorded size %s, current %s)\n' "$path" "${size:-<none>}" "${now:-<none>}"
          lost=1
          continue
        fi
        if [ "$now" -lt "$size" ]; then
          printf 'TRUNCATED %s (%s bytes, was %s)\n' "$path" "$now" "$size"
          lost=1
        fi
        ;;
    esac
  done < "$snap"
  [ "$lost" -eq 0 ]
}

# --- residency --------------------------------------------------------------

# Print resident|dormant|unknown for <name>.
#
# `unknown` is never license to act, in EITHER direction: raising on a false
# dormant would put two supervisors in one home, and standing down on a false
# resident would type an exit command into a pane that is doing something else.
# Only these harnesses have an empirically verified agent classifier
# (bin/fm-backend.sh, docs/tmux-backend.md, docs/herdr-backend.md), so a `dead`
# verdict from any other harness is downgraded to unknown exactly as
# bin/fm-bootstrap.sh's secondmate-liveness sweep already does. A target that is
# structurally GONE needs no classifier and is dormant for any harness.
fm_wr_residency() {  # <state> <name>
  local state=$1 name=$2 meta harness backend target verdict
  meta="$state/$name.meta"
  # No meta at all means nothing has ever been launched for this id, so there is
  # no endpoint to misread - that is dormant, not inconclusive. It is the shape a
  # freshly seeded wake-resident secondmate has before its first message.
  [ -f "$meta" ] || { printf 'dormant\n'; return 0; }
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || { printf 'dormant\n'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  if ! fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
    printf 'dormant\n'
    return 0
  fi
  harness=$(fm_meta_get "$meta" harness)
  verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict=unknown
  case "$harness" in
    claude|codex|opencode|pi|grok) ;;
    *) [ "$verdict" = dead ] && verdict=unknown ;;
  esac
  case "$verdict" in
    alive) printf 'resident\n' ;;
    dead) printf 'dormant\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# 0 only when the endpoint is CONFIRMED busy. An unknown busy-state falls back to
# tmux's shared pane-regex reader and otherwise answers "not confirmed busy" -
# the other stand-down gates carry the safety, and this one only ever adds a
# refusal.
fm_wr_confirmed_busy() {  # <backend> <target>
  local backend=$1 target=$2 st
  st=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null) || st=unknown
  case "$st" in
    busy) return 0 ;;
    idle) return 1 ;;
  esac
  [ "$backend" = tmux ] || return 1
  fm_pane_is_busy "$target"
}

# --- harness exit command ---------------------------------------------------

# The text a stand-down submits to make the agent exit its session cleanly.
#
# ONE-OWNER NOTE: the captain-facing table of these lives in the harness-adapters
# skill ("Exit command" row per harness). This function is the executable copy the
# stand-down path needs, and tests/fm-wake-resident.test.sh asserts the two agree,
# so they cannot drift. Add a harness here only after adding its verified row
# there.
#
# grok deliberately has NO entry: its exit is a double Ctrl+Q press within 1000ms,
# a confirmed destructive-action dialog that fm-send's one-line text/--key
# transport cannot express. Stand-down refuses on grok rather than half-sending
# something and reporting success.
fm_wr_exit_command() {  # <harness>
  case "${1-}" in
    claude) printf '/exit\n' ;;
    codex) printf '/quit\n' ;;
    opencode) printf '/exit\n' ;;
    pi) printf '/quit\n' ;;
    *) return 1 ;;
  esac
}

# --- check shims ------------------------------------------------------------

# The MAIN home's shim: one detector for every configured record. Silent unless
# there is something for the one live firstmate to do.
fm_wr_wire_main_shim() {  # <fm-root> <fm-home> <state>
  local root=$1 home=$2 state=$3 shim body
  shim="$state/wake-resident.check.sh"
  mkdir -p "$state" 2>/dev/null || return 1
  body=$(cat <<EOF
#!/usr/bin/env bash
# Auto-generated - wake-resident secondmate lifecycle poll shim.
# The watcher runs this each check cycle; output becomes a check: wake.
export FM_HOME=$(printf '%q' "$home")
exec $(printf '%q' "$root/bin/fm-wake-resident-poll.sh")
EOF
)
  if [ ! -f "$shim" ] || [ "$(cat "$shim" 2>/dev/null)" != "$body" ]; then
    ( umask 077; printf '%s\n' "$body" > "$shim" ) || return 1
  fi
  fm_custom_check_register "$state" wake-resident
}

fm_wr_unwire_main_shim() {  # <state>
  local state=$1 shim="$1/wake-resident.check.sh"
  rm -f "$shim" 2>/dev/null || true
  fm_custom_check_trust_remove "$state" wake-resident || true
  [ ! -e "$shim" ] && [ ! -e "$state/wake-resident.check-trust" ]
}

# The SECONDMATE home's shim: the fast path that lets a resident agent notice its
# own inbox on its OWN turn, without routing every message through the main
# firstmate. It is an optimisation, not the guarantee - the main home's poll
# still surfaces a message left unread past grace-secs, so delivery does not
# depend on the secondmate's watcher being up.
fm_wr_wire_self_shim() {  # <fm-root> <secondmate-home> <inbox>
  local root=$1 home=$2 inbox=$3 state shim body
  state="$home/state"
  shim="$state/wake-self.check.sh"
  mkdir -p "$state" 2>/dev/null || return 1
  body=$(cat <<EOF
#!/usr/bin/env bash
# Auto-generated - wake-resident inbox poll shim for this home.
# The watcher runs this each check cycle; output becomes a check: wake.
export FM_HOME=$(printf '%q' "$home")
exec $(printf '%q' "$root/bin/fm-wake-resident-poll.sh") --self $(printf '%q' "$inbox")
EOF
)
  if [ ! -f "$shim" ] || [ "$(cat "$shim" 2>/dev/null)" != "$body" ]; then
    ( umask 077; printf '%s\n' "$body" > "$shim" ) || return 1
  fi
  fm_custom_check_register "$state" wake-self
}

fm_wr_unwire_self_shim() {  # <secondmate-home>
  local state="$1/state" shim="$1/state/wake-self.check.sh"
  [ -d "$state" ] || return 0
  rm -f "$shim" 2>/dev/null || true
  fm_custom_check_trust_remove "$state" wake-self || true
  [ ! -e "$shim" ] && [ ! -e "$state/wake-self.check-trust" ]
}
