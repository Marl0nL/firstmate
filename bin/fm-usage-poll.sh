#!/usr/bin/env bash
# Incremental, requestId-deduped token-usage ledger update over the Claude Code
# transcript tree, plus the optional quota-severity wake used as the watcher
# check-shim body (state/usage-watch.check.sh).
#
# Usage:
#   fm-usage-poll.sh            incremental update; silent unless a quota-severity
#                               threshold is FIRST crossed (then one wake line)
#   fm-usage-poll.sh --backfill full rescan (ignores the offset checkpoint) so a
#                               stretch consumed while the watcher was down, or a
#                               line missed by a mid-write read, is recovered;
#                               still requestId-deduped, so never double-counts
#   fm-usage-poll.sh --quiet    never print a wake line (ledger-only)
#
# What it does each run (see docs/usage-monitor.md for the schema and the
# dedup/attribution rationale):
#   - scans ~/.claude/projects/**/*.jsonl RECURSIVELY (incl. subagents/)
#   - for each grown/new file, reads only the new, complete-line tail
#   - extracts assistant records, skips <synthetic>, and records each requestId
#     EXACTLY ONCE globally (content-block duplication and resume-forks collapse)
#   - attributes each record by its inline cwd joined to state/<id>.meta:worktree=,
#     with a durable per-session snapshot so post-teardown records still attribute
#   - appends one ledger.jsonl line per unique request; never copies message text
#
# Privacy: only token counts + attribution metadata are extracted. No transcript
# message content is ever written under data/usage/.
#
# The transcript schema and the quota endpoint are undocumented/best-effort:
# every field is parsed defensively (missing -> 0/empty), a version is recorded
# per line, and the poll never hard-fails a watcher cycle (always exits 0).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-usage-lib.sh
. "$SCRIPT_DIR/fm-usage-lib.sh"

BACKFILL=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --backfill) BACKFILL=1 ;;
    --quiet) QUIET=1 ;;
    *) : ;;  # ignore unknown args so a future flag never breaks a watcher cycle
  esac
done

command -v jq >/dev/null 2>&1 || exit 0
[ -d "$FM_USAGE_TRANSCRIPTS_DIR" ] || exit 0
mkdir -p "$FM_USAGE_DIR" 2>/dev/null || exit 0

# Platform-portable mtime and size (mirrors fm-watch.sh's stat handling).
if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
  file_size()  { stat -f %z "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
  file_size()  { stat -c %s "$1" 2>/dev/null; }
fi

# Single-writer lock: the watcher runs one poll at a time, but a session-start
# backfill could overlap. A fresh, held lock means "another poll is running" ->
# exit cleanly. A stale lock (older than the check timeout budget) is reclaimed.
LOCK="$FM_USAGE_DIR/.poll.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lock_age=$(( "$(date +%s 2>/dev/null || echo 0)" - "$(file_mtime "$LOCK" 2>/dev/null || echo 0)" ))
  if [ "$lock_age" -lt 120 ] 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT

# --- load durable state once ------------------------------------------------

# Global seen-set of already-recorded requestIds, derived from the ledger itself
# (one source of truth). This is what makes both content-block duplication and
# cross-file resume-forks collapse to one recorded request.
declare -A SEEN=()
if [ -s "$FM_USAGE_LEDGER" ]; then
  while IFS= read -r rid; do
    [ -n "$rid" ] && SEEN["$rid"]=1
  done < <(jq -r '.request_id // empty' "$FM_USAGE_LEDGER" 2>/dev/null)
fi

# Offset/signature checkpoint per absolute transcript path.
declare -A CKPT_OFF=()
declare -A CKPT_SIG=()
if [ "$BACKFILL" -eq 0 ] && [ -s "$FM_USAGE_CHECKPOINT" ]; then
  while IFS=$'\t' read -r path sig off; do
    [ -n "$path" ] || continue
    CKPT_SIG["$path"]=$sig
    CKPT_OFF["$path"]=$off
  done < <(jq -r 'to_entries[] | [.key, ((.value.size|tostring)+":"+(.value.mtime|tostring)), (.value.offset|tostring)] | @tsv' "$FM_USAGE_CHECKPOINT" 2>/dev/null)
fi

# Per-session attribution snapshot (survives teardown), keyed by sessionId. The
# in-memory value is the five fields tab-joined ("id\tproject\tharness\tkind\t
# worktree"), matching the snapshot written in attribute() and the save below.
declare -A ATTR=()
if [ -s "$FM_USAGE_ATTRIBUTION" ]; then
  while IFS=$'\t' read -r sid a_t a_p a_h a_k a_wt; do
    [ -n "$sid" ] || continue
    ATTR["$sid"]=$(printf '%s\t%s\t%s\t%s\t%s' "$a_t" "$a_p" "$a_h" "$a_k" "$a_wt")
  done < <(jq -r 'to_entries[] | [.key, (.value.task_id // ""), (.value.project // ""), (.value.harness // ""), (.value.kind // ""), (.value.worktree // "")] | @tsv' "$FM_USAGE_ATTRIBUTION" 2>/dev/null)
fi

# Live task metas: worktree= -> "id\tproject\tharness\tkind". Read once so the
# per-record join is an O(1) lookup.
declare -A META_BY_WT=()
for meta in "$FM_USAGE_STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  wt=$(grep -E '^worktree=' "$meta" 2>/dev/null | tail -n1); wt=${wt#worktree=}
  [ -n "$wt" ] || continue
  proj=$(grep -E '^project=' "$meta" 2>/dev/null | tail -n1); proj=${proj#project=}
  harn=$(grep -E '^harness=' "$meta" 2>/dev/null | tail -n1); harn=${harn#harness=}
  knd=$(grep -E '^kind=' "$meta" 2>/dev/null | tail -n1); knd=${knd#kind=}
  META_BY_WT["$wt"]=$(printf '%s\t%s\t%s\t%s' "$id" "$(basename "${proj:-unknown}")" "${harn:-claude}" "${knd:-ship}")
done

# Registered secondmate home paths -> id, from data/secondmates.md, so a
# secondmate's own supervision session attributes to it (its crews attribute in
# that secondmate's own home poll; see docs/usage-monitor.md).
declare -A SECONDMATE_HOME=()
SECONDMATES_MD="$FM_USAGE_DATA/secondmates.md"
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*"home:"*)
        smid=${line#- }; smid=${smid%% *}
        smhome=${line#*home: }; smhome=${smhome%%;*}; smhome=${smhome%%)*}
        smhome=${smhome%"${smhome##*[![:space:]]}"}
        [ -n "$smid" ] && [ -n "$smhome" ] && SECONDMATE_HOME["$smhome"]=$smid
        ;;
    esac
  done < "$SECONDMATES_MD"
fi

# --- attribution ------------------------------------------------------------
# Resolve one record's (session_id, cwd, git_branch) to task/project/harness/kind
# plus is_uncategorised, into the globals A_ID/A_PROJ/A_HARN/A_KIND/A_UNCAT. This
# is a plain function (NOT a subshell/command-substitution) so its snapshot write
# to ATTR persists in the caller. The live-meta match on cwd runs FIRST
# (per-record, so a session that cd's around still attributes each record
# correctly); the frozen snapshot and the fm/<id> branch are fallbacks for
# post-teardown records.
attribute() {
  local sid=$1 cwd=$2 branch=$3 fields
  A_UNCAT=0
  # 1. live meta whose worktree == this record's cwd
  if [ -n "${META_BY_WT[$cwd]:-}" ]; then
    fields=${META_BY_WT[$cwd]}
    # Snapshot on first sighting so a later, post-teardown record still resolves.
    [ -n "${ATTR[$sid]:-}" ] || ATTR["$sid"]=$(printf '%s\t%s' "$fields" "$cwd")
    IFS=$'\t' read -r A_ID A_PROJ A_HARN A_KIND <<<"$fields"
    return 0
  fi
  # 2. the primary firstmate checkout is firstmate's own supervision cost
  if [ "$cwd" = "$FM_ROOT" ]; then
    A_ID=firstmate-primary; A_PROJ=firstmate; A_HARN=claude; A_KIND=primary
    return 0
  fi
  # 3. a registered secondmate home
  if [ -n "${SECONDMATE_HOME[$cwd]:-}" ]; then
    A_ID="firstmate-secondmate-${SECONDMATE_HOME[$cwd]}"; A_PROJ=firstmate; A_HARN=claude; A_KIND=secondmate
    return 0
  fi
  # 4. frozen per-session snapshot (survives teardown / resume-forks)
  if [ -n "${ATTR[$sid]:-}" ]; then
    IFS=$'\t' read -r A_ID A_PROJ A_HARN A_KIND _ <<<"${ATTR[$sid]}"
    return 0
  fi
  # 5. a ship crew's fm/<id> branch still names the task even with no snapshot
  case "$branch" in
    fm/?*)
      A_ID=${branch#fm/}; A_PROJ=$(basename "$cwd"); A_HARN=claude; A_KIND=ship
      return 0
      ;;
  esac
  # 6. no firstmate task -> uncategorised, tagged with the cwd's project leaf
  A_ID=uncategorised; A_PROJ=$(basename "${cwd:-unknown}"); A_HARN=claude; A_KIND=unknown; A_UNCAT=1
}

# --- incremental read -------------------------------------------------------

NEW_LINES=$(mktemp "${TMPDIR:-/tmp}/fm-usage-new.XXXXXX") || exit 0
NEW_TAIL=$(mktemp "${TMPDIR:-/tmp}/fm-usage-tail.XXXXXX") || { rm -f "$NEW_LINES"; exit 0; }
trap 'rm -f "$NEW_LINES" "$NEW_TAIL"; rm -rf "$LOCK" 2>/dev/null || true' EXIT

# Defensive per-line extraction: raw-read each line, parse with fromjson? so a
# malformed or partial line is silently skipped, keep only assistant records with
# a real requestId and a non-<synthetic> model, and emit the minimal field set.
# shellcheck disable=SC2016  # single quotes are deliberate: the $-names are jq bindings, not shell vars.
EXTRACT='
  fromjson?
  | select(.type == "assistant")
  | (.message.model // "") as $model
  | select($model != "<synthetic>")
  | (.requestId // "") as $rid
  | select($rid != "")
  | (.message.usage // {}) as $u
  | {
      request_id: $rid,
      ts: (.timestamp // ""),
      session_id: (.sessionId // ""),
      model: $model,
      cwd: (.cwd // ""),
      git_branch: (.gitBranch // ""),
      is_sidechain: (.isSidechain // false),
      cc_version: (.version // ""),
      service_tier: ($u.service_tier // ""),
      input_tokens: ($u.input_tokens // 0),
      output_tokens: ($u.output_tokens // 0),
      cache_read_input_tokens: ($u.cache_read_input_tokens // 0),
      cache_creation_input_tokens: ($u.cache_creation_input_tokens // 0)
    }
  | [.request_id, .ts, .session_id, .model, .cwd, .git_branch,
     (.is_sidechain|tostring), .cc_version, .service_tier,
     (.input_tokens|tostring), (.output_tokens|tostring),
     (.cache_read_input_tokens|tostring), (.cache_creation_input_tokens|tostring)]
  | join("\u001f")
'

: > "$NEW_LINES"
declare -A NEXT_SIG=()
declare -A NEXT_OFF=()
appended=0

while IFS= read -r f; do
  [ -f "$f" ] || continue
  size=$(file_size "$f"); mtime=$(file_mtime "$f")
  [ -n "$size" ] || continue
  sig="$size:$mtime"
  off=${CKPT_OFF[$f]:-0}
  # Unchanged since last checkpoint -> skip entirely.
  if [ "${CKPT_SIG[$f]:-}" = "$sig" ]; then
    NEXT_SIG["$f"]=$sig; NEXT_OFF["$f"]=$off
    continue
  fi
  # A shrunk file (rotation/truncation) or a backfill reads from the start.
  if [ "$off" -gt "$size" ] 2>/dev/null; then off=0; fi
  if [ "$size" -le "$off" ] 2>/dev/null; then
    # Only mtime moved; no new bytes.
    NEXT_SIG["$f"]=$sig; NEXT_OFF["$f"]=$off
    continue
  fi
  # Read the new bytes, then trim to complete lines only: advance the offset to
  # just past the last newline so a line still being written is picked up next
  # run rather than half-read now.
  if ! tail -c +"$((off + 1))" "$f" > "$NEW_TAIL" 2>/dev/null; then
    continue
  fi
  if [ -z "$(tail -c1 "$NEW_TAIL" 2>/dev/null)" ]; then
    adv=$(file_size "$NEW_TAIL")   # ends in newline: all lines complete
  else
    # bytes up to (not including) the trailing partial line; LC_ALL=C -> byte lengths
    adv=$(LC_ALL=C awk '{ if (NR > 1) acc += p + 1; p = length($0) } END { print acc + 0 }' "$NEW_TAIL")
  fi
  case "$adv" in ''|*[!0-9]*) adv=0 ;; esac
  newoff=$((off + adv))
  NEXT_SIG["$f"]=$sig
  NEXT_OFF["$f"]=$newoff
  [ "$adv" -gt 0 ] || continue

  # The unit separator (0x1f) delimits fields: it never appears in transcript
  # values and is NOT IFS-whitespace, so an empty field (e.g. service_tier) is
  # preserved rather than collapsed the way a tab would be.
  while IFS=$'\x1f' read -r rid ts sid model cwd branch sidechain ccver tier intok outtok crtok cctok; do
    [ -n "$rid" ] || continue
    [ -n "${SEEN[$rid]:-}" ] && continue
    SEEN["$rid"]=1
    # Plain call (not a subshell): attribute sets A_* globals and may snapshot ATTR.
    attribute "$sid" "$cwd" "$branch"
    case "$sidechain" in true|false) : ;; *) sidechain=false ;; esac
    case "$intok" in ''|*[!0-9]*) intok=0 ;; esac
    case "$outtok" in ''|*[!0-9]*) outtok=0 ;; esac
    case "$crtok" in ''|*[!0-9]*) crtok=0 ;; esac
    case "$cctok" in ''|*[!0-9]*) cctok=0 ;; esac
    jq -cn \
      --arg ts "$ts" --arg rid "$rid" --arg sid "$sid" \
      --arg task "$A_ID" --arg project "$A_PROJ" --arg harness "$A_HARN" --arg kind "$A_KIND" \
      --arg model "$model" --arg cwd "$cwd" --arg branch "$branch" \
      --arg tier "$tier" --arg ccver "$ccver" \
      --argjson sidechain "$sidechain" --argjson uncat "${A_UNCAT:-0}" \
      --argjson intok "$intok" --argjson outtok "$outtok" \
      --argjson crtok "$crtok" --argjson cctok "$cctok" \
      '{ts:$ts,request_id:$rid,session_id:$sid,task_id:$task,project:$project,
        harness:$harness,kind:$kind,model:$model,cwd:$cwd,git_branch:$branch,
        input_tokens:$intok,output_tokens:$outtok,cache_read_input_tokens:$crtok,
        cache_creation_input_tokens:$cctok,service_tier:$tier,cc_version:$ccver,
        is_sidechain:$sidechain,is_uncategorised:($uncat==1)}' >> "$NEW_LINES" 2>/dev/null || true
    appended=$((appended + 1))
  done < <(head -c "$adv" "$NEW_TAIL" | jq -rR "$EXTRACT" 2>/dev/null)
done < <(find "$FM_USAGE_TRANSCRIPTS_DIR" -type f -name '*.jsonl' 2>/dev/null)

# Append new ledger lines atomically-enough for the single writer.
if [ "$appended" -gt 0 ] && [ -s "$NEW_LINES" ]; then
  cat "$NEW_LINES" >> "$FM_USAGE_LEDGER" 2>/dev/null || true
fi

# Rewrite the checkpoint from the merged old+new signatures/offsets.
ckpt_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-usage-ckpt.XXXXXX") || ckpt_tmp=
if [ -n "$ckpt_tmp" ]; then
  if {
        for f in "${!NEXT_SIG[@]}"; do
          printf '%s\t%s\t%s\n' "$f" "${NEXT_SIG[$f]}" "${NEXT_OFF[$f]}"
        done
      } | jq -Rn '
          reduce (inputs | split("\t")) as $r ({};
            ($r[1] | split(":")) as $sm
            | .[$r[0]] = {size:($sm[0]|tonumber? // 0), mtime:($sm[1]|tonumber? // 0), offset:($r[2]|tonumber? // 0)})
        ' > "$ckpt_tmp" 2>/dev/null; then
    mv -f "$ckpt_tmp" "$FM_USAGE_CHECKPOINT" 2>/dev/null || rm -f "$ckpt_tmp"
  else
    rm -f "$ckpt_tmp"
  fi
fi

# Rewrite the attribution snapshot (may have grown this run).
attr_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-usage-attr.XXXXXX") || attr_tmp=
if [ -n "$attr_tmp" ]; then
  if {
        for sid in "${!ATTR[@]}"; do
          printf '%s\t%s\n' "$sid" "${ATTR[$sid]}"
        done
      } | jq -Rn '
          reduce (inputs | split("\t")) as $r ({};
            .[$r[0]] = {task_id:($r[1]//""), project:($r[2]//""), harness:($r[3]//""),
                        kind:($r[4]//""), worktree:($r[5]//"")})
        ' > "$attr_tmp" 2>/dev/null; then
    mv -f "$attr_tmp" "$FM_USAGE_ATTRIBUTION" 2>/dev/null || rm -f "$attr_tmp"
  else
    rm -f "$attr_tmp"
  fi
fi

# --- quota-severity wake (opt-in) -------------------------------------------
# The ledger update above is a silent side effect on every cycle. A wake line is
# printed ONLY when the quota severity FIRST crosses up into warning/critical,
# so the watcher's check sweep never spams firstmate: the watermark records the
# last-surfaced level, and only an increase surfaces.
[ "$QUIET" -eq 1 ] && exit 0
fm_usage_enabled || exit 0
fm_usage_guard_enabled || exit 0
[ -x "$SCRIPT_DIR/fm-usage-quota.sh" ] || exit 0

SIGNAL=$(mktemp "${TMPDIR:-/tmp}/fm-usage-sig.XXXXXX") || exit 0
if ! "$SCRIPT_DIR/fm-usage-quota.sh" --signal > "$SIGNAL" 2>/dev/null; then
  rm -f "$SIGNAL"; exit 0
fi
level=$(fm_usage_signal_level "$SIGNAL")
rm -f "$SIGNAL"
case "$level" in ''|*[!0-9]*) level=0 ;; esac

prev=0
[ -f "$FM_USAGE_WATERMARK" ] && prev=$(cat "$FM_USAGE_WATERMARK" 2>/dev/null)
case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
printf '%s' "$level" > "$FM_USAGE_WATERMARK" 2>/dev/null || true

if [ "$level" -gt "$prev" ] && [ "$level" -ge 1 ]; then
  if [ "$level" -ge 2 ]; then
    printf 'usage-quota critical: token quota crossed into critical; new large/low-priority dispatch should hold\n'
  else
    printf 'usage-quota warning: token quota crossed the high-water mark; review before large/low-priority dispatch\n'
  fi
fi
exit 0
