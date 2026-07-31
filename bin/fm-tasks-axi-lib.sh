# shellcheck shell=bash
# Shared tasks-axi backend selection, home-scoped path resolution, and
# compatibility probe for bootstrap, teardown, decision holds, and secondmate
# backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
#
# Home-scoped resolution (fm_backlog_file / fm_tasks_axi_run) is the single owner
# of "which backlog file does this call mean". tasks-axi resolves BOTH its
# .tasks.toml config and the backlog path that config names from the PROCESS
# WORKING DIRECTORY, so a shell standing anywhere inside a project clone reads an
# absent backlog as an empty one and writes a stray backlog.md into the clone -
# a write to a project, which AGENTS.md forbids outright. The false-empty READ is
# the worse half: it returns a confident wrong answer that gets acted on, where a
# stray write at least announces itself as an untracked file in a dirty clone.
# bin/fm-cd-pretool-check.sh guards the directory CHANGE and is unaffected by
# this; it cannot see a cwd that was inherited from a spawn or left behind by an
# allowed scoped change, which is exactly when this bites. Every tasks-axi call
# in bin/ therefore names its file explicitly and absolutely.

# Absolute path of the backlog file inside <data-dir>. Purely lexical: neither
# the file nor its directory need exist yet, which is what callers that seed a
# fresh destination backlog require.
fm_backlog_file() {  # <data-dir>
  local data=$1
  case "$data" in
    /*) ;;
    *) data="$PWD/$data" ;;
  esac
  while [ "$data" != "/" ] && [ "${data%/}" != "$data" ]; do
    data=${data%/}
  done
  printf '%s/backlog.md\n' "$data"
}

# Run one tasks-axi command against a home's backlog, wherever the caller's shell
# happens to be standing. `--file` goes after the command, per `tasks-axi --help`.
# Both halves are deliberate: --file pins the file itself, and the cd pins which
# .tasks.toml supplies the archive path and Done retention for that same call.
fm_tasks_axi_run() {  # <home> <data-dir> <command> [args...]
  local home=$1 data=$2 cmd=$3 file
  shift 3
  file=$(fm_backlog_file "$data")
  (cd "$home" && tasks-axi "$cmd" --file "$file" "$@")
}

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
