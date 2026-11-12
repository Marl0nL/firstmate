#!/usr/bin/env bash
# fm-lint-denylist.sh - LOCAL guard against committing operator-private strings.
#
# When the gitignored file config/public-denylist exists in the repository
# root, this fails if any TRACKED file contains one of its case-insensitive
# substrings, one substring per line (blank lines and lines beginning with #
# are ignored). The denylist never ships - it is gitignored - so in CI, a fresh
# clone, or any home without it, the file is absent and this check is a silent
# no-op. It exists only so an operator's own push cannot reintroduce a private
# string into public, tracked files.
#
# bin/fm-lint.sh runs this as part of its default (no-explicit-path) lint; see
# docs/configuration.md "Operator-private denylist" for the file's contract.
#
# It operates on the git repository containing the current working directory and
# reads config/public-denylist from that repository's top level.
#
# Usage:
#   fm-lint-denylist.sh          check tracked files against the denylist
#   fm-lint-denylist.sh --help   print this usage
set -u

case "${1:-}" in
  --help|-h)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  '') : ;;
  *)
    printf 'fm-lint-denylist.sh: unexpected argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

command -v git >/dev/null 2>&1 || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
denylist="$top/config/public-denylist"
[ -f "$denylist" ] || exit 0

rc=0
lineno=0
while IFS= read -r pattern || [ -n "$pattern" ]; do
  lineno=$((lineno + 1))
  case "$pattern" in
    ''|'#'*) continue ;;
  esac
  # Ignore whitespace-only lines so a stray blank never becomes an empty fixed
  # string, which would otherwise match every tracked file.
  case "$pattern" in
    *[![:space:]]*) : ;;
    *) continue ;;
  esac
  # git grep searches tracked files in the working tree. -I skips binary files,
  # -n reports each hit as path:linenumber:content, -i is case-insensitive, -F
  # is a fixed substring, and -e protects a pattern that begins with a dash.
  #
  # The report deliberately keeps only path:linenumber and a count. It never
  # echoes the matched string or the matched line, because this guard's output
  # flows into the no-mistakes pre-push gate's logs and review agents, and from
  # there potentially into public PR text - which is the exact leak this guard
  # exists to prevent. It identifies the offending denylist entry by its line
  # number in config/public-denylist rather than by its content.
  if raw=$(git -C "$top" grep -I -n -i -F -e "$pattern" 2>/dev/null) && [ -n "$raw" ]; then
    locations=$(printf '%s\n' "$raw" | awk -F: '{ print $1 ":" $2 }')
    count=$(printf '%s\n' "$locations" | wc -l | tr -d '[:space:]')
    if [ "$rc" -eq 0 ]; then
      printf 'fm-lint-denylist.sh: entries from config/public-denylist appear in tracked files (matched strings withheld):\n' >&2
    fi
    printf '  denylist entry #%d: %s match(es)\n' "$lineno" "$count" >&2
    printf '%s\n' "$locations" | sed 's/^/    /' >&2
    rc=1
  fi
done < "$denylist"

exit "$rc"
