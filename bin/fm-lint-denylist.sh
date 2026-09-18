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
while IFS= read -r pattern || [ -n "$pattern" ]; do
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
  # -l lists matching paths, -i is case-insensitive, -F is a fixed substring,
  # and -e protects a pattern that begins with a dash.
  if hits=$(git -C "$top" grep -I -l -i -F -e "$pattern" 2>/dev/null) && [ -n "$hits" ]; then
    if [ "$rc" -eq 0 ]; then
      printf 'fm-lint-denylist.sh: strings from config/public-denylist appear in tracked files:\n' >&2
    fi
    printf '  pattern %s:\n' "$pattern" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    rc=1
  fi
done < "$denylist"

exit "$rc"
