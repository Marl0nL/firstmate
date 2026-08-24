#!/usr/bin/env bash
# Shared extraction of secondmate registry summary and scope from a charter.
# Source only. FM_SECONDMATE_CHARTER and FM_SECONDMATE_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

# A registry line's tail is "(home: ...; scope: ...; projects: ...; added ...)",
# and secondmate_registry_field (bin/fm-secondmate-registry-lib.sh) splits that
# tail on ";" and "()". Every field written into the tail - summary and scope -
# must therefore never contain those characters, or the split misreads field
# boundaries. This stays required even though the summary is now short (below):
# a short phrase can still carry a stray "(" or ";" as ordinary punctuation.
normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

# The registry line is printed in full at every session start in every home that
# has a secondmate, so the summary field must stay a scannable one-liner even
# when the charter behind it runs to thousands of words. 200 characters is about
# two short sentences: enough to identify the domain at a glance, small enough
# that it can never dominate the digest. The full charter is never lost; it is
# copied verbatim to <home>/data/charter.md by the seed path.
REGISTRY_SUMMARY_CAP=200

truncate_registry_summary() {
  local text=$1 cap=$2 truncated
  [ "${#text}" -le "$cap" ] && { printf '%s\n' "$text"; return; }
  truncated=${text:0:$cap}
  # Prefer breaking on the last full word inside the cap; if the cap lands
  # mid-word with no earlier space, fall back to the hard cut.
  case "$truncated" in
    *' '*) truncated=${truncated% *} ;;
  esac
  printf '%s...\n' "$truncated"
}

registry_summary_for_brief() {
  local brief=$1 raw
  if [ -n "${FM_SECONDMATE_SUMMARY:-}" ]; then
    raw=$(printf '%s\n' "$FM_SECONDMATE_SUMMARY" | normalize_registry_text)
  elif [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    raw=$(printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text)
  else
    raw=$(brief_section_text "$brief" "Charter" | normalize_registry_text)
  fi
  truncate_registry_summary "$raw" "$REGISTRY_SUMMARY_CAP"
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}
