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
# (launch_template's `claude)` line for the flag). This file does NOT re-derive
# that command; it checks the one CAUSAL signal that separates a healthy launch
# from a resumed husk: argv carrying --dangerously-skip-permissions. The flag's
# absence is precisely what leaves a resumed claude in manual permission mode,
# and it rides argv, so it is readable from a process table or from `herdr pane
# process-info` argv without reaching into the process environment. The
# HERDR_ENV=0 and CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false env prefixes
# fm-spawn.sh also adds are launch details only, NOT detection signals: whether
# a Herdr resume preserves the original per-command environment is unverified,
# so an environ-based read could silently mask a genuinely degraded husk.
#
# Precision is the priority: a healthy firstmate-launched mate always carries
# the flag in argv, so it is never classified degraded. An unreadable argv is
# `unknown`, which preserves the pane. This file has no side effects on source.

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

# The classifier decision. Given the live Claude process's joined argv $1 (empty
# when unreadable), print:
#
#   healthy   argv carries the permission flag. The mate skips permission
#             prompts, so it cannot silently stall.
#   degraded  argv is readable and the permission flag is provably absent. This
#             is the restored-manual-mode stall shape.
#   unknown   argv is empty/unreadable. Preserve the pane and let a human look.
#
# argv is the SOLE authority: it carries the causal flag, and a firstmate launch
# always carries the flag in argv, so a healthy mate is never degraded.
fm_launch_health_verdict() {  # <argv-joined>
  local argv=$1
  [ -n "$argv" ] || { printf 'unknown'; return 0; }
  if fm_launch_health_argv_has_skip_flag "$argv"; then
    printf 'healthy'
    return 0
  fi
  printf 'degraded'
}
