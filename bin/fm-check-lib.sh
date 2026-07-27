#!/usr/bin/env bash
# fm-check-lib.sh - the single owner of watcher check-script authentication.
#
# Why this exists: bin/fm-watch.sh EXECUTES state/<id>.check.sh on every check
# cycle. An unregistered or group-writable check file is therefore a
# code-execution path into the supervisor itself. A check runs only when it is
# REGISTERED - the home holds a trust record that binds the check to its exact
# bytes, and both files pass a private-artifact test at execution time.
#
# Trust record - state/<id>.check-trust, mode 600, exactly two lines:
#   fm-custom-check-v1
#   <64 lowercase hex sha256 of state/<id>.check.sh>
#
# Enforced on every execution, all of them, fail-closed:
#   - state/ is a real directory, not a symlink
#   - state/<id>.check.sh is a regular non-symlink file, mode 700, link count 1,
#     on the same device as state/
#   - state/<id>.check-trust is the same but mode 600
#   - the check file's current sha256 equals the recorded hash
# A check that fails any of these is REFUSED WITHOUT EXECUTION, and the watcher
# surfaces the refusal as a check: wake. A refused check is never a silent skip.
#
# What actually runs is a private mode-600 snapshot copy taken AFTER the hash
# matched and re-verified against the same hash, so a rewrite racing the
# verification cannot substitute the bytes that get executed.
#
# Registration means "these exact bytes are intended", so inspect a check file
# before registering it. Producers register in the same operation that writes a
# shim (fm_custom_check_register); bin/fm-check-register.sh is the by-hand entry
# point and the documented way to register a future check. Anything that removes
# a check must also drop its trust record (fm_custom_check_trust_remove).
#
# Ported from upstream firstmate PR #556 onto this fork's watcher.
# docs/architecture.md carries the narrative; this header owns the format.

# Set by fm_custom_check_trust_read / fm_custom_check_snapshot_prepare. Declared
# here so sourcing under `set -u` is safe before the first call.
FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

# Portable stat, detected once. Same platform split - and the same prohibition on
# the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form - as bin/fm-watch.sh's
# stat_mtime; see the comment there for why that fallback silently corrupts output
# on Linux.
if [ "$(uname)" = Darwin ]; then
  fm_check_file_mode() { stat -f %Lp "$1" 2>/dev/null; }
  fm_check_file_device() { stat -f %d "$1" 2>/dev/null; }
  fm_check_file_link_count() { stat -f %l "$1" 2>/dev/null; }
else
  fm_check_file_mode() { stat -c %a "$1" 2>/dev/null; }
  fm_check_file_device() { stat -c %d "$1" 2>/dev/null; }
  fm_check_file_link_count() { stat -c %h "$1" 2>/dev/null; }
fi

# A check id is the state-file stem, so it must be a single safe path component.
fm_check_id_valid() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_custom_check_sha256() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# A private artifact: a regular file, not a symlink, at exactly <mode>, with a
# single link, on the same device as the state directory that vouches for it.
# The link-count and device tests are what stop a hardlink or a cross-device
# lookalike from standing in for the verified file.
fm_check_private_file_valid() {  # <path> <mode> <state-device>
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_check_file_mode "$path")" = "$mode" ] || return 1
  [ "$(fm_check_file_device "$path")" = "$device" ] || return 1
  [ "$(fm_check_file_link_count "$path")" = 1 ]
}

# A publication destination: absent, or an already-private single-link regular
# file on the right device. Refuses publishing through a symlink or a hardlink.
fm_check_destination_or_absent() {  # <path> <state-device>
  local path=$1 device=$2
  [ ! -L "$path" ] || return 1
  [ -e "$path" ] || return 0
  [ -f "$path" ] || return 1
  [ "$(fm_check_file_link_count "$path")" = 1 ] || return 1
  [ "$(fm_check_file_device "$path")" = "$device" ]
}

# Resolve the state device once, refusing a symlinked or missing state dir.
fm_check_state_device() {  # <state>
  local state=$1 device
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_check_file_device "$state") || return 1
  [ -n "$device" ] || return 1
  printf '%s\n' "$device"
}

# Read and validate the trust record, setting FM_CUSTOM_CHECK_HASH on success.
# The record must be EXACTLY two lines: a trailing third line means the file was
# appended to, which is a tampering signal, not a formatting quirk.
fm_custom_check_trust_read() {  # <state> <id>
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_check_id_valid "$id" || return 1
  state_device=$(fm_check_state_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_check_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _ <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

# True when state/<id>.check.sh is registered and still matches its record.
# Verification only - it never prepares anything to execute.
fm_custom_check_registered() {  # <state> <id>
  local state=$1 id=$2 check hash state_device
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_check_state_device "$state") || return 1
  check="$state/$id.check.sh"
  fm_check_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_cleanup() {
  [ -z "${FM_CUSTOM_CHECK_SNAPSHOT:-}" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}

# Authenticate state/<id>.check.sh and stage the exact bytes to execute in
# FM_CUSTOM_CHECK_SNAPSHOT. The caller runs the SNAPSHOT, not the original, and
# calls fm_custom_check_snapshot_cleanup afterwards. Returns non-zero - with no
# snapshot left behind - for any unregistered, tampered, or non-private check.
fm_custom_check_snapshot_prepare() {  # <state> <id>
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_check_state_device "$state") || return 1
  check="$state/$id.check.sh"
  fm_check_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || {
    FM_CUSTOM_CHECK_SNAPSHOT=
    return 1
  }
  # Every failure past this point must clear the staged snapshot, so the caller
  # can never execute a partially verified copy.
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  fm_check_private_file_valid "$FM_CUSTOM_CHECK_SNAPSHOT" 600 "$state_device" \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

# Bind state/<id>.check.sh to its CURRENT bytes. This is the trust decision, so
# the caller is asserting the file's content is intended: a producer that just
# wrote the shim, or an operator who read it. Sets mode 700 on the check itself,
# since the registrar owns the artifact's privacy. Publishes the record through
# a same-directory private temp plus a guarded rename, so a concurrent reader
# never sees a half-written record and a symlinked destination is refused.
fm_custom_check_register() {  # <state> <id>
  local state=$1 id=$2 check trust state_device hash tmp
  fm_check_id_valid "$id" || return 1
  state_device=$(fm_check_state_device "$state") || return 1
  check="$state/$id.check.sh"
  trust="$state/$id.check-trust"
  [ -f "$check" ] && [ ! -L "$check" ] || return 1
  chmod 700 "$check" 2>/dev/null || return 1
  fm_check_private_file_valid "$check" 700 "$state_device" || return 1
  fm_check_destination_or_absent "$trust" "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ -n "$hash" ] || return 1
  tmp=$(mktemp "$state/.fm-custom-check-trust.XXXXXX") || return 1
  if ! {
    printf '%s\n%s\n' fm-custom-check-v1 "$hash" > "$tmp" \
      && chmod 600 "$tmp" \
      && fm_check_destination_or_absent "$trust" "$state_device" \
      && mv -f -- "$tmp" "$trust"
  }; then
    rm -f -- "$tmp"
    return 1
  fi
  # Prove the published record actually authenticates the check; a record that
  # does not is worse than none, so it is removed rather than left in place.
  fm_custom_check_registered "$state" "$id" || { rm -f -- "$trust"; return 1; }
}

# Drop a check's trust record. Call wherever a check file is removed, so a later
# file at the same id can never inherit an old registration.
fm_custom_check_trust_remove() {  # <state> <id>
  local state=$1 id=$2
  fm_check_id_valid "$id" || return 1
  rm -f -- "$state/$id.check-trust" 2>/dev/null || true
  [ ! -e "$state/$id.check-trust" ]
}

# Remove snapshot and trust temporaries orphaned by a killed process. Safe only
# for a caller that holds the watcher singleton lock.
fm_custom_check_sweep_temporaries() {  # <state>
  local state=$1
  rm -f -- "$state"/.fm-custom-check.?????? "$state"/.fm-custom-check-trust.?????? 2>/dev/null || true
}
