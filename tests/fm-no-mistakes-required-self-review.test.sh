#!/usr/bin/env bash
# Behavior tests for the self-review half of the "Require no-mistakes" PR-body
# check (.github/workflows/no-mistakes-required.yml).
#
# The check accepts two forms. The no-mistakes pipeline attestation is judged
# by the pinned upstream require-no-mistakes action, which these tests do not
# exercise. The second form is a self-review attestation whose head_sha must
# equal the PR's current head sha plus a visible "## Self-review" section; the
# workflow's "self-review" step judges it with inline shell that consumes only
# PR_BODY/PR_AUTHOR/PR_NUMBER/PR_HEAD_SHA plus the PR's head repository,
# base repository and author association, and writes accepted=true|false to
# GITHUB_OUTPUT. A valid attestation skips the action; a body carrying the
# no-mistakes signature or no self-review marker defers to it; a present but
# invalid attestation fails the step. These tests extract that step's script
# from the parsed workflow (the intentional machine-consumed contract) and run
# it against controlled bodies, asserting exit codes, the recorded verdict,
# and diagnostics.
#
# Either attestation payload may be single-line or pretty-printed: the step
# assembles the comment from its prefix to its ' -->' before parsing.
# Regression origins: a PR body quoting the attestation prefix or a
# placeholder example (valid JSON) before the genuine comment once made a
# first-match scan reject a compliant PR, so the scan prefers the candidate
# bound to the PR head.
# The self-review form is honored only for a PR from the base repository or by
# an OWNER, MEMBER, or COLLABORATOR; any other PR defers to the action even
# with a valid or invalid attestation, so an outside author cannot self-attest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP=$(fm_test_tmproot fm-nm-required-gate)

command -v jq >/dev/null 2>&1 \
  || fail "the self-review step parses attestation JSON with jq, which was not found"
python3 -c 'import yaml' 2>/dev/null \
  || fail "python3 with PyYAML is required to parse $WORKFLOW as YAML"

GATE="$TMP/self-review-step.sh"
python3 - "$WORKFLOW" > "$GATE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["check"]["steps"]
matches = [s for s in steps if s.get("id") == "self-review"]
if len(matches) != 1:
    sys.exit("expected exactly one step with id self-review")
sys.stdout.write(matches[0]["run"])
PY
[ -s "$GATE" ] || fail "extracted an empty self-review script from $WORKFLOW"

MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
HEAD_SHA='0123456789abcdef0123456789abcdef01234567'
STALE_SHA='fedcba9876543210fedcba9876543210fedcba98'
PREFIX='<!-- self-review-attestation:v1 '
ATTESTATION="${PREFIX}{\"head_sha\":\"${HEAD_SHA}\",\"reviewer\":\"fmtest crewmate\",\"evidence\":\"bin/fm-lint.sh clean; gate tests passed\"} -->"
STALE_ATTESTATION="${PREFIX}{\"head_sha\":\"${STALE_SHA}\",\"reviewer\":\"fmtest crewmate\",\"evidence\":\"lint and tests\"} -->"
SECTION='## Self-review

- Checked correctness of the change and ran the gate tests.'
MULTILINE_ATTESTATION="<!-- self-review-attestation:v1 {
  \"head_sha\": \"${HEAD_SHA}\",
  \"reviewer\": \"fmtest crewmate\",
  \"evidence\": \"pretty-printed attestation spanning multiple lines\"
} -->"
# A quoted placeholder example whose payload is valid JSON but never names
# the PR head.
QUOTED_EXAMPLE=$(cat <<'EOF'
    prefix='<!-- self-review-attestation:v1 '
    <!-- self-review-attestation:v1 {"head_sha":"<full 40-char sha>","reviewer":"<who/what reviewed>","evidence":"<one line: what was run>"} -->
EOF
)

# run_gate <body>: execute the extracted step as the runner does. Sets
# GATE_OUT (combined output), GATE_STATUS (exit code), and GATE_VERDICT (the
# accepted= value written to GITHUB_OUTPUT, empty when none was written).
# The PR comes from the base repository unless GATE_HEAD_REPO or
# GATE_ASSOCIATION say otherwise.
BASE_REPO='fmtest/firstmate'
run_gate() {
  local out_file="$TMP/github-output"
  : > "$out_file"
  GATE_OUT=$(PR_BODY="$1" PR_AUTHOR=fmtest PR_NUMBER=48 PR_HEAD_SHA="$HEAD_SHA" \
    PR_HEAD_REPO="${GATE_HEAD_REPO-$BASE_REPO}" PR_BASE_REPO="$BASE_REPO" \
    PR_AUTHOR_ASSOCIATION="${GATE_ASSOCIATION-NONE}" \
    GITHUB_OUTPUT="$out_file" bash "$GATE" 2>&1)
  GATE_STATUS=$?
  GATE_VERDICT=$(sed -n 's/^accepted=//p' "$out_file" | tail -1)
}

expect_accepted() {  # <what>
  [ "$GATE_STATUS" -eq 0 ] || fail "$1: step failed (exit=$GATE_STATUS): $GATE_OUT"
  [ "$GATE_VERDICT" = true ] || fail "$1: step did not record accepted=true (got '${GATE_VERDICT}'): $GATE_OUT"
  assert_contains "$GATE_OUT" "Self-review attestation is valid and bound to PR head ${HEAD_SHA}" \
    "$1: step passed without reporting the head-bound attestation"
}

expect_deferred() {  # <what>
  [ "$GATE_STATUS" -eq 0 ] || fail "$1: step failed instead of deferring (exit=$GATE_STATUS): $GATE_OUT"
  [ "$GATE_VERDICT" = false ] \
    || fail "$1: step must record accepted=false so the no-mistakes action judges the PR (got '${GATE_VERDICT}'): $GATE_OUT"
}

expect_rejected() {  # <what> <diagnostic>
  [ "$GATE_STATUS" -ne 0 ] || fail "$1: step accepted an invalid self-review attestation: $GATE_OUT"
  [ "$GATE_VERDICT" != true ] || fail "$1: a failing step must never record accepted=true"
  assert_contains "$GATE_OUT" "$2" "$1: missing the expected diagnostic"
}

test_head_bound_attestation_is_accepted() {
  run_gate "Summary of the change.

$SECTION

$ATTESTATION"
  expect_accepted "a single-line attestation bound to the PR head"
  pass "a self-review attestation bound to the PR head is accepted and skips the action"
}

test_bare_body_defers_and_names_the_self_review_form() {
  run_gate 'Hand-written PR body with no pipeline section at all.'
  expect_deferred "a bare body"
  assert_contains "$GATE_OUT" "$PREFIX" "the deferral notice does not name the self-review marker"
  pass "a body without a self-review marker defers to the no-mistakes action and names the alternative form"
}

test_pipeline_body_is_judged_by_the_action_alone() {
  run_gate "$MARKER

$SECTION

$ATTESTATION"
  expect_deferred "a body carrying the no-mistakes signature"
  pass "a body carrying the no-mistakes signature defers to the pipeline action even with a valid self-review"
}

test_stale_head_is_rejected() {
  run_gate "$SECTION

$STALE_ATTESTATION"
  expect_rejected "a stale head_sha" "bound to ${STALE_SHA} but the PR head is now ${HEAD_SHA}"
  assert_contains "$GATE_OUT" "the PR head moved" "the stale diagnostic does not say the head moved"
  pass "a self-review attestation bound to a stale head fails naming both shas"
}

test_missing_visible_section_is_rejected() {
  run_gate "Summary only, no visible review section.

$ATTESTATION"
  expect_rejected "no visible section" "visible '## Self-review' section is missing"
  pass "a self-review attestation without the visible ## Self-review section fails"
}

test_empty_key_is_rejected() {
  run_gate "$SECTION

${PREFIX}{\"head_sha\":\"${HEAD_SHA}\",\"reviewer\":\"\",\"evidence\":\"lint\"} -->"
  expect_rejected "an empty reviewer" "missing or empty key(s): reviewer"
  pass "a self-review attestation with an empty key fails naming the key"
}

test_quoted_example_does_not_shadow_the_genuine_attestation() {
  run_gate "## Evidence

$QUOTED_EXAMPLE

$SECTION

$ATTESTATION"
  expect_accepted "a quoted valid-JSON example before the genuine comment"
  pass "a quoted placeholder example does not shadow the genuine head-bound attestation"
}

test_stale_diagnostic_names_the_genuine_attestation() {
  run_gate "$QUOTED_EXAMPLE

$SECTION

$STALE_ATTESTATION"
  expect_rejected "a quoted example plus a stale attestation" "bound to ${STALE_SHA} but the PR head is now ${HEAD_SHA}"
  pass "with no head-bound candidate the stale diagnostic names the genuine stale attestation"
}

test_prefix_without_payload_is_unparseable() {
  run_gate "$SECTION

    echo '    <!-- self-review-attestation:v1 {\"head_sha\":\"<full 40-char sha>\",...} -->'"
  expect_rejected "a quoted prefix with no JSON payload" "Self-review attestation is unparseable"
  pass "a self-review prefix without a valid JSON payload fails as unparseable"
}

test_multiline_attestation_is_accepted() {
  run_gate "Summary of the change.

$SECTION

$MULTILINE_ATTESTATION"
  expect_accepted "a pretty-printed attestation"
  pass "a pretty-printed multi-line self-review attestation is assembled and accepted"
}

test_multiline_stale_head_is_rejected() {
  run_gate "$SECTION

<!-- self-review-attestation:v1 {
  \"head_sha\": \"${STALE_SHA}\",
  \"reviewer\": \"fmtest crewmate\",
  \"evidence\": \"lint and tests\"
} -->"
  expect_rejected "a pretty-printed stale attestation" "bound to ${STALE_SHA} but the PR head is now ${HEAD_SHA}"
  pass "a pretty-printed attestation with a stale head_sha still fails on the head binding"
}

test_multiline_quoted_example_does_not_shadow() {
  run_gate "## Evidence

Example of the accepted form, pretty-printed:
<!-- self-review-attestation:v1 {
  \"head_sha\": \"<full 40-char sha>\",
  \"reviewer\": \"<who/what reviewed>\",
  \"evidence\": \"<one line: what was run>\"
} -->

$SECTION

$MULTILINE_ATTESTATION"
  expect_accepted "a quoted pretty-printed example before the genuine multi-line comment"
  pass "a quoted pretty-printed example does not shadow the genuine multi-line attestation"
}

# The one boundary the pretty-printing allowance keeps: the closing ' -->'
# must stay on the payload's last line.
test_closing_arrow_on_its_own_line_is_unparseable() {
  run_gate "$SECTION

<!-- self-review-attestation:v1 {
  \"head_sha\": \"${HEAD_SHA}\",
  \"reviewer\": \"fmtest crewmate\",
  \"evidence\": \"closing arrow on its own line\"
}
-->"
  expect_rejected "a closing --> on its own line" "Self-review attestation is unparseable"
  pass "an attestation whose closing --> is on its own line is rejected as unparseable"
}

test_crlf_body_is_accepted() {
  run_gate "$(printf '%s' "$SECTION

$MULTILINE_ATTESTATION" | sed 's/$/\r/')"
  expect_accepted "a CRLF-terminated multi-line body"
  pass "a CRLF-terminated multi-line self-review attestation reaches the same accepted verdict"
}

test_outside_pr_attestation_defers_to_the_action() {
  local assoc
  for assoc in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR ''; do
    GATE_HEAD_REPO='outsider/firstmate' GATE_ASSOCIATION="$assoc" run_gate "$SECTION

$ATTESTATION"
    expect_deferred "a valid attestation on an outside PR (association '${assoc}')"
    assert_contains "$GATE_OUT" "honored only for a PR from this repository" \
      "the outside-PR deferral does not say why the attestation was ignored"
    GATE_HEAD_REPO='outsider/firstmate' GATE_ASSOCIATION="$assoc" run_gate "$SECTION

$STALE_ATTESTATION"
    expect_deferred "a stale attestation on an outside PR (association '${assoc}')"
  done
  # A deleted head repository arrives as an empty name and is never trusted.
  GATE_HEAD_REPO='' run_gate "$SECTION

$ATTESTATION"
  expect_deferred "a valid attestation whose head repository is unknown"
  pass "an outside PR's self-review attestation is ignored and the no-mistakes action judges it"
}

test_trusted_association_on_an_outside_pr_is_accepted() {
  local assoc
  for assoc in OWNER MEMBER COLLABORATOR; do
    GATE_HEAD_REPO='outsider/firstmate' GATE_ASSOCIATION="$assoc" run_gate "$SECTION

$ATTESTATION"
    expect_accepted "a valid attestation from a cross-repository ${assoc}"
  done
  pass "an owner, member, or collaborator's cross-repository PR may use the self-review form"
}

# N5: a body-supplied head_sha carrying a newline must not start a new
# workflow-command line when the stale diagnostic prints it.
test_stale_diagnostic_strips_line_breaks() {
  run_gate "$SECTION

${PREFIX}{\"head_sha\":\"${STALE_SHA}\\n::warning::injected\\r\",\"reviewer\":\"r\",\"evidence\":\"e\"} -->"
  expect_rejected "a head_sha carrying CR/LF" "Self-review attestation is stale"
  if printf '%s\n' "$GATE_OUT" | grep -q '^::warning::'; then
    fail "a head_sha carrying a newline injected a workflow-command line: $GATE_OUT"
  fi
  assert_contains "$GATE_OUT" "bound to ${STALE_SHA}::warning::injected but" \
    "the stale diagnostic did not print the head_sha with its line breaks removed"
  pass "the stale diagnostic prints a body-supplied head_sha without CR/LF"
}

fm_test_run \
  test_outside_pr_attestation_defers_to_the_action \
  test_trusted_association_on_an_outside_pr_is_accepted \
  test_stale_diagnostic_strips_line_breaks \
  test_head_bound_attestation_is_accepted \
  test_bare_body_defers_and_names_the_self_review_form \
  test_pipeline_body_is_judged_by_the_action_alone \
  test_stale_head_is_rejected \
  test_missing_visible_section_is_rejected \
  test_empty_key_is_rejected \
  test_quoted_example_does_not_shadow_the_genuine_attestation \
  test_stale_diagnostic_names_the_genuine_attestation \
  test_prefix_without_payload_is_unparseable \
  test_multiline_attestation_is_accepted \
  test_multiline_stale_head_is_rejected \
  test_multiline_quoted_example_does_not_shadow \
  test_closing_arrow_on_its_own_line_is_unparseable \
  test_crlf_body_is_accepted
