#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- NBSP composer padding (2026-07-17 incident) ----------------------------
# Real claude 2.x pads its EMPTY composer row with U+00A0 after the prompt glyph
# ("❯" + NBSP), and glibc's en_US.UTF-8 [:space:] does not include U+00A0, so a
# plain bash trim leaves it attached. fm_composer_trim normalizes it BEFORE the
# glyph cases run, which is what both fixes the false `pending` AND keeps the
# dead-shell rule intact. See docs/herdr-backend.md "Incident (2026-07-17)".
NBSP=$'\xc2\xa0'   # explicit UTF-8 bytes: see FM_COMPOSER_NBSP in the owner

test_nbsp_padded_agent_glyph_is_empty() {
  local g out
  for g in '❯' '›'; do
    out=$(classify 0 "${g}${NBSP}")
    [ "$out" = empty ] \
      || fail "an NBSP-padded agent glyph '$g' must read empty (a real idle claude composer), got '$out'"
  done
  out=$(classify 0 "❯${NBSP}${NBSP}")
  [ "$out" = empty ] || fail "repeated NBSP padding must still read empty, got '$out'"
  pass "fm_composer_classify_content: an NBSP-padded agent prompt glyph reads empty (the 2026-07-17 wedge shape)"
}

# The safety rule must survive the normalization: the NBSP is trimmed BEFORE the
# exact glyph cases, so a padded shell husk trims back to a bare glyph and stays
# unknown rather than stripping the glyph and hitting the post-strip empty path.
test_nbsp_padded_shell_glyphs_are_still_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "${g}${NBSP}")
    [ "$out" = unknown ] \
      || fail "an NBSP-padded bare shell glyph '$g' must still read unknown (dead shell), got '$out'"
    out=$(classify 1 "${g}${NBSP}")
    [ "$out" = empty ] \
      || fail "an NBSP-padded shell glyph '$g' INSIDE a composer box must still read empty, got '$out'"
  done
  pass "fm_composer_classify_content: NBSP padding never widens a dead-shell prompt into an injection target"
}

test_nbsp_padded_real_text_is_pending() {
  local out
  out=$(classify 0 "❯${NBSP}land pr 416 now")
  [ "$out" = pending ] || fail "NBSP-padded real text must still read pending, got '$out'"
  out=$(classify 0 "${NBSP}❯ land pr 416 now${NBSP}")
  [ "$out" = pending ] || fail "NBSP-surrounded real text must still read pending, got '$out'"
  pass "fm_composer_classify_content: NBSP padding never hides real unsubmitted text"
}

test_composer_trim_normalizes_nbsp_and_space() {
  local out
  out=$(fm_composer_trim "${NBSP} ❯ hi ${NBSP}")
  [ "$out" = '❯ hi' ] || fail "fm_composer_trim must trim NBSP and ASCII blanks from both ends, got '$out'"
  out=$(fm_composer_trim "${NBSP}${NBSP}")
  [ -z "$out" ] || fail "an NBSP-only row must trim to empty, got '$out'"
  out=$(fm_composer_trim $'\xe2\x9d\xaf\xc2\xa0\r')
  [ "$out" = '❯' ] || fail "the real claude row ('❯' + NBSP + CR) must trim to a bare glyph, got '$out'"
  pass "fm_composer_trim: trims NBSP padding and CR alongside the locale's [:space:] class"
}

# --- Queued-message placeholder (2026-07-17b incident) ----------------------
# When claude is mid-turn it QUEUES a submitted message instead of starting a
# new turn, and repaints its now-EMPTY composer row as the placeholder below.
# The row is rendered dim, so the two ANSI-capable adapters already dropped it
# as ghost text - but ONLY when a styled capture is available. herdr falls back
# to a plain capture when its ANSI read fails, and orca/cmux never have styling
# at all; on those paths the placeholder survived as ordinary text and the row
# read `pending`, so fm-send reported "Enter swallowed" for a message that had
# in fact been queued and delivered. See docs/herdr-backend.md
# "Incident (2026-07-17b)".
#
# These fixtures use the REAL captured row shape - claude's NBSP padding after
# the glyph and the trailing CR that herdr's capture carries - because every
# pre-existing fixture used a plain ASCII prompt, which is exactly how three
# composer incidents reached production green.
QUEUED_PLACEHOLDER='Press up to edit queued messages'

test_queued_placeholder_reads_empty() {
  local out
  # The real plain-capture row: "❯" + NBSP + placeholder + CR.
  out=$(classify 0 $'\xe2\x9d\xaf\xc2\xa0'"$QUEUED_PLACEHOLDER"$'\r')
  [ "$out" = empty ] \
    || fail "the real captured queued row ('❯' + NBSP + placeholder + CR) must read empty (submitted and queued), got '$out'"
  # Matched after the glyph is stripped, and on its own with no glyph at all.
  out=$(classify 0 "❯ $QUEUED_PLACEHOLDER")
  [ "$out" = empty ] || fail "'❯ <queued placeholder>' must read empty, got '$out'"
  out=$(classify 0 "$QUEUED_PLACEHOLDER")
  [ "$out" = empty ] || fail "a bare queued placeholder must read empty, got '$out'"
  # Every adapter gets it, with or without a per-harness idle_re passed.
  out=$(classify 0 "❯ $QUEUED_PLACEHOLDER" '^Type a message\.\.\.$')
  [ "$out" = empty ] || fail "the queued placeholder must read empty alongside a harness idle_re, got '$out'"
  out=$(classify 1 "$QUEUED_PLACEHOLDER")
  [ "$out" = empty ] || fail "the queued placeholder must read empty inside a bordered box, got '$out'"
  pass "fm_composer_classify_content: claude's queued-message placeholder reads empty on every adapter, styled capture or not"
}

# The other direction, and the one that matters most: recognizing the queued
# state must NEVER become a blanket "claude is mid-turn, assume it landed".
# A genuinely swallowed Enter leaves REAL text on the composer row and must
# still read `pending` so fm-send fails closed (the grok 2026-07-03 incident).
test_swallowed_enter_still_reads_pending() {
  local out
  # The real captured shape of a swallowed Enter: same NBSP padding, real text.
  out=$(classify 0 $'\xe2\x9d\xaf\xc2\xa0fix findings 1 and 3\r')
  [ "$out" = pending ] \
    || fail "real typed text on the NBSP-padded claude row must read pending (swallowed Enter), got '$out'"
  # Text that merely CONTAINS the placeholder phrase is not the placeholder: the
  # pattern is anchored end-to-end so a transcript line or a crewmate quoting it
  # cannot manufacture a false success.
  out=$(classify 0 "❯ tell the crew: $QUEUED_PLACEHOLDER")
  [ "$out" = pending ] || fail "text merely containing the placeholder phrase must read pending, got '$out'"
  out=$(classify 0 "❯ $QUEUED_PLACEHOLDER now")
  [ "$out" = pending ] || fail "the placeholder with a real trailing word must read pending, got '$out'"
  pass "fm_composer_classify_content: a genuinely swallowed Enter still reads pending; the placeholder match is anchored, not a substring"
}

# The queued placeholder must not weaken the dead-shell injection-safety rule:
# a bare shell husk stays unknown even though claude's placeholder now resolves.
test_queued_placeholder_does_not_weaken_dead_shell_rule() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "${g}${NBSP}")
    [ "$out" = unknown ] \
      || fail "an NBSP-padded shell husk '$g' must still read unknown, got '$out'"
  done
  pass "fm_composer_classify_content: the queued placeholder leaves the dead-shell 'unknown' rule intact"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_queued_placeholder_reads_empty
test_swallowed_enter_still_reads_pending
test_queued_placeholder_does_not_weaken_dead_shell_rule
test_nbsp_padded_agent_glyph_is_empty
test_nbsp_padded_shell_glyphs_are_still_unknown
test_nbsp_padded_real_text_is_pending
test_composer_trim_normalizes_nbsp_and_space
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
