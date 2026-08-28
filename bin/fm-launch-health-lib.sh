#!/usr/bin/env bash
# Shared launch-signature health for a firstmate-launched Claude agent.
#
# ONE owner of the decision "does this live Claude process carry the launch
# signature firstmate gives its agents, or is it a husk that was resumed WITHOUT
# it?". It exists for the fleet-wide silent stall after a host restart: Herdr's
# restore-on-restart can bring a Claude pane back into its native conversation
# (see [session] resume_agents_on_restore in docs/herdr-backend.md) but re-runs
# the process with Herdr's own launch line, dropping every firstmate launch
# prefix. The most damaging drop is --dangerously-skip-permissions: without it a
# restored mate sits in manual permission mode and freezes on its first
# non-allowlisted command, with nobody watching - a fleet-wide silent stall.
#
# The launch command firstmate actually uses is owned by bin/fm-spawn.sh
# (launch_template's `claude)` line for the flag, and the HERDR_ENV=0 /
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false env prefixes it adds for a herdr
# claude). This file does NOT re-derive that command; it checks the CAUSAL
# subset that separates a healthy launch from a resumed husk:
#
#   A. permission flag  argv carries --dangerously-skip-permissions
#      This is the CAUSAL signal for the stall: its absence is precisely what
#      leaves a resumed claude in manual permission mode. It rides argv, so it
#      is readable from a process table or from `herdr pane process-info` argv
#      without reaching into the process environment.
#   B. claim suppression        environ has HERDR_ENV=0
#   C. prompt-ghost suppression environ has CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
#      B and C are firstmate spawn markers that ride the process ENVIRONMENT
#      (VAR=val command prefixes, not argv), so they are readable only from
#      /proc/<pid>/environ where the pid is local and same-user. They corroborate
#      that a flag-less pane is a herdr resume rather than something firstmate
#      launched, and they only ever make the verdict MORE conservative.
#
# Precision is the priority: a healthy firstmate-launched mate always carries A,
# so it is never classified degraded. Every uncertain read (unreadable argv, no
# Claude foreground) is `unknown`, which preserves the pane. This file has no
# side effects on source.
set -u

# The causal permission flag firstmate always passes (bin/fm-spawn.sh's claude
# launch template). A boolean flag; no value form, but the `=` form is matched
# defensively so a future spelling cannot slip past the guard.
FM_LAUNCH_HEALTH_SKIP_FLAG='--dangerously-skip-permissions'

# True when the joined argv string $1 carries --dangerously-skip-permissions as a
# whole token. Matching a padded token (not a bare substring) keeps a longer
# flag that merely starts with the same characters from reading as a match.
fm_launch_health_argv_has_skip_flag() {  # <argv-joined>
  case " $1 " in
    *" $FM_LAUNCH_HEALTH_SKIP_FLAG "*) return 0 ;;
    *" $FM_LAUNCH_HEALTH_SKIP_FLAG="*) return 0 ;;
  esac
  return 1
}

# True when the newline-joined environment $1 carries BOTH firstmate spawn
# markers exactly. Each is matched as a whole line, so a differing value never
# reads as a match.
fm_launch_health_environ_markers_present() {  # <environ-newline-joined>
  local environ=$1
  printf '%s\n' "$environ" | grep -qxF 'HERDR_ENV=0' || return 1
  printf '%s\n' "$environ" | grep -qxF 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false' || return 1
  return 0
}

# Print the NUL-separated environment of local pid $1 as newlines, or return
# non-zero when it cannot be read (remote pane, race, or restricted). Callers
# treat an unreadable environ as absent corroboration, never as proof of health.
# FM_PROC_ROOT_OVERRIDE lets a test point at a fixture proc tree, matching the
# convention in bin/fm-cursor-lib.sh and bin/fm-wake-lib.sh.
fm_launch_health_read_environ() {  # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} environ_file
  [ -n "$pid" ] || return 1
  environ_file="$proc_root/$pid/environ"
  [ -r "$environ_file" ] || return 1
  tr '\0' '\n' < "$environ_file" 2>/dev/null
}

# The classifier decision. Given the live Claude process's joined argv $1 and its
# newline-joined environment $2 (either may be empty when unreadable), print:
#
#   healthy   argv carries the permission flag. The mate skips permission
#             prompts, so it cannot silently stall, regardless of B/C.
#   degraded  argv is readable and the permission flag is provably absent, and
#             the environ does not contradict that (see below). This is the
#             restored-manual-mode stall shape.
#   unknown   argv is empty/unreadable, OR the flag is absent yet BOTH firstmate
#             env markers are present - an anomalous "firstmate-launched but
#             flag-less" shape we refuse to auto-cycle. Preserve and let a human
#             look.
#
# argv is authoritative for the stall verdict because it carries the causal
# flag; the env markers can only veto a degraded verdict, never create one, so a
# healthy mate (which carries all three) is never degraded and an anomalous pane
# is never cycled.
fm_launch_health_verdict() {  # <argv-joined> <environ-newline-joined>
  local argv=$1 environ=$2
  [ -n "$argv" ] || { printf 'unknown'; return 0; }
  if fm_launch_health_argv_has_skip_flag "$argv"; then
    printf 'healthy'
    return 0
  fi
  if [ -n "$environ" ] && fm_launch_health_environ_markers_present "$environ"; then
    printf 'unknown'
    return 0
  fi
  printf 'degraded'
}
