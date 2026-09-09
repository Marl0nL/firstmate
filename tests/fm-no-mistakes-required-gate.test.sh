#!/usr/bin/env bash
# Behavior tests for the "Require no-mistakes" PR-body gate
# (.github/workflows/no-mistakes-required.yml).
#
# The gate's check step is a self-contained shell script that consumes only
# PR_BODY/PR_AUTHOR/PR_NUMBER/PR_HEAD_SHA, so these tests extract that script
# from the workflow (parsed as YAML, the intentional machine-consumed contract)
# and execute it against controlled bodies, asserting exit codes and diagnostics.
#
# Two forms satisfy the gate: the no-mistakes pipeline attestation, or a
# self-review attestation whose head_sha must equal the PR's current head sha
# (PR_HEAD_SHA) so a push after the review turns the check red again until
# someone re-attests against the new head.
#
# Either attestation's JSON payload may be written on a single line or
# pretty-printed across several lines: the gate assembles the comment from its
# '<!--' to its ' -->' before parsing, so newlines inside the payload are not a
# rejection. Regression origin: run 34176730965 raised the concern that a
# multi-line payload might never be assembled. The multi-line cases below lock
# the assembled behavior in and prove the head-sha binding and quoted-example
# handling survive a pretty-printed payload.
#
# Regression origin: PR #48. The pipeline's own Testing evidence quoted this
# workflow's source in the PR body - including the literal attestation prefix
# line - BEFORE the genuine attestation comment in the ## Pipeline section.
# First-match extraction landed inside the quotation, extracted non-JSON text,
# and rejected a compliant PR as "missing or unparseable". The gate must scan
# past quoted prefixes to the genuine comment, while still rejecting bodies
# whose every prefix occurrence lacks a valid JSON payload.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP=$(fm_test_tmproot fm-nm-required-gate)

command -v jq >/dev/null 2>&1 \
  || fail "the gate script parses attestation JSON with jq, which was not found"
python3 -c 'import yaml' 2>/dev/null \
  || fail "python3 with PyYAML is required to parse $WORKFLOW as YAML"

GATE="$TMP/gate-run.sh"
python3 - "$WORKFLOW" > "$GATE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
sys.stdout.write(doc["jobs"]["check"]["steps"][0]["run"])
PY
[ -s "$GATE" ] || fail "extracted an empty check script from $WORKFLOW"

MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
ATTESTATION='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"a59cb2dd9184c27a647328aca0e126232788fbeb","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'
# The two quoted-source lines from PR #48's evidence block that broke
# first-match extraction: the gate's own prefix assignment, then its example
# echo whose payload ({"head_sha":"...","steps":[...]}) is NOT valid JSON.
QUOTED_SOURCE=$(cat <<'EOF'
# What the restored gate actually enforces (structured attestation, >= 1.46.0):
    43:            prefix='<!-- no-mistakes-pipeline-attestation:v1 '
    68:                echo '    <!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"...","steps":[...]} -->'
EOF
)

HEAD_SHA='0123456789abcdef0123456789abcdef01234567'
STALE_SHA='fedcba9876543210fedcba9876543210fedcba98'
SELF_REVIEW_PREFIX='<!-- self-review-attestation:v1 '
SELF_REVIEW_ATTESTATION="${SELF_REVIEW_PREFIX}{\"head_sha\":\"${HEAD_SHA}\",\"reviewer\":\"fmtest crewmate\",\"evidence\":\"bin/fm-lint.sh clean; bin/fm-test-run.sh tests/fm-no-mistakes-required-gate.test.sh passed\"} -->"
SELF_REVIEW_SECTION='## Self-review

- Checked correctness of the change and ran the gate tests.'

# run_gate <body>: execute the extracted check step the way the workflow does.
# Captures combined output in GATE_OUT and the exit code in GATE_STATUS.
run_gate() {
  GATE_OUT=$(PR_BODY="$1" PR_AUTHOR=fmtest PR_NUMBER=48 PR_HEAD_SHA="$HEAD_SHA" bash "$GATE" 2>&1)
  GATE_STATUS=$?
}

# --- regression: quoted prefix before the genuine attestation ---------------

run_gate "## Testing

$QUOTED_SOURCE

## Pipeline

$MARKER

$ATTESTATION"
[ "$GATE_STATUS" -eq 0 ] || fail "gate rejected a compliant body whose evidence quotes the attestation prefix (exit=$GATE_STATUS): $GATE_OUT"
case "$GATE_OUT" in
  *'Pipeline step attestation is valid'*) ;;
  *) fail "gate passed but did not report a valid attestation: $GATE_OUT" ;;
esac
pass "quoted attestation prefix in evidence no longer shadows the genuine attestation"

# --- quoted prefix alone is not an attestation ------------------------------

run_gate "$MARKER

$QUOTED_SOURCE"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a body whose only prefix occurrences are quoted source with no JSON payload"
case "$GATE_OUT" in
  *'structured pipeline step attestation is missing or unparseable'*) ;;
  *) fail "expected the missing-attestation diagnostic, got: $GATE_OUT" ;;
esac
pass "quoted prefixes without a valid JSON payload still fail as missing attestation"

# --- signature alone (pre-1.46.0 no-mistakes) is still rejected -------------

run_gate "$MARKER"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a signature-only body with no attestation comment"
case "$GATE_OUT" in
  *'structured pipeline step attestation is missing or unparseable'*) ;;
  *) fail "expected the missing-attestation diagnostic, got: $GATE_OUT" ;;
esac
pass "signature-only body without attestation is still rejected"

# --- a required step that did not complete is still rejected ----------------

run_gate "$MARKER

"'<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"a59cb2dd9184c27a647328aca0e126232788fbeb","steps":[{"step":"review","status":"completed"},{"step":"test","status":"skipped-quota"},{"step":"document","status":"completed"}]} -->'
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted an attestation whose test step is not completed"
case "$GATE_OUT" in
  *'not completed: test=skipped-quota'*) ;;
  *) fail "expected the incomplete-step diagnostic naming test=skipped-quota, got: $GATE_OUT" ;;
esac
pass "attestation with an incomplete required step is still rejected"

# --- a bare body is rejected and the error names BOTH accepted forms --------

run_gate 'Hand-written PR body with no pipeline section at all.'
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a body without either attestation"
case "$GATE_OUT" in
  *'neither a no-mistakes pipeline attestation nor a self-review attestation'*) ;;
  *) fail "expected the neither-form diagnostic, got: $GATE_OUT" ;;
esac
case "$GATE_OUT" in
  *"$MARKER"*) ;;
  *) fail "bare-body diagnostic does not name the no-mistakes signature: $GATE_OUT" ;;
esac
case "$GATE_OUT" in
  *'<!-- no-mistakes-pipeline-attestation:v1 '*) ;;
  *) fail "bare-body diagnostic does not name the pipeline attestation marker: $GATE_OUT" ;;
esac
case "$GATE_OUT" in
  *"$SELF_REVIEW_PREFIX"*) ;;
  *) fail "bare-body diagnostic does not name the self-review attestation marker: $GATE_OUT" ;;
esac
pass "bare body is rejected and the diagnostic names both accepted forms with their markers"

# --- self-review attestation bound to the current head passes ---------------

run_gate "Summary of the change.

$SELF_REVIEW_SECTION

$SELF_REVIEW_ATTESTATION"
[ "$GATE_STATUS" -eq 0 ] || fail "gate rejected a valid self-review attestation bound to the current head (exit=$GATE_STATUS): $GATE_OUT"
case "$GATE_OUT" in
  *"Self-review attestation is valid and bound to PR head ${HEAD_SHA}"*) ;;
  *) fail "gate passed but did not report a valid head-bound self-review: $GATE_OUT" ;;
esac
pass "self-review attestation with matching head_sha passes"

# --- self-review attestation bound to a stale head fails --------------------

run_gate "$SELF_REVIEW_SECTION

${SELF_REVIEW_PREFIX}{\"head_sha\":\"${STALE_SHA}\",\"reviewer\":\"fmtest crewmate\",\"evidence\":\"lint and tests\"} -->"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a self-review attestation whose head_sha is not the PR head"
case "$GATE_OUT" in
  *'the PR head moved'*) ;;
  *) fail "expected the head-moved diagnostic, got: $GATE_OUT" ;;
esac
case "$GATE_OUT" in
  *"bound to ${STALE_SHA} but the PR head is now ${HEAD_SHA}"*) ;;
  *) fail "head-moved diagnostic does not name both shas: $GATE_OUT" ;;
esac
pass "self-review attestation with a stale head_sha fails and says the head moved"

# --- self-review marker without the visible section fails -------------------

run_gate "Summary only, no visible review section.

$SELF_REVIEW_ATTESTATION"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a self-review attestation without the visible ## Self-review section"
case "$GATE_OUT" in
  *"visible '## Self-review' section is missing"*) ;;
  *) fail "expected the missing-section diagnostic, got: $GATE_OUT" ;;
esac
pass "self-review marker without the ## Self-review section fails"

# --- self-review attestation with an empty key fails ------------------------

run_gate "$SELF_REVIEW_SECTION

${SELF_REVIEW_PREFIX}{\"head_sha\":\"${HEAD_SHA}\",\"reviewer\":\"\",\"evidence\":\"lint\"} -->"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a self-review attestation with an empty reviewer"
case "$GATE_OUT" in
  *'missing or empty key(s): reviewer'*) ;;
  *) fail "expected the incomplete-attestation diagnostic naming reviewer, got: $GATE_OUT" ;;
esac
pass "self-review attestation with an empty key fails naming the key"

# --- a quoted self-review example before the genuine comment is skipped -----
# Regression origin: PR #69's own body quoted this gate's bare-body diagnostic,
# whose self-review example carries placeholder values that are valid JSON.
# A first-parseable scan picked the quoted example and reported a stale head.

QUOTED_SELF_REVIEW=$(cat <<'EOF'
    selfreview_prefix='<!-- self-review-attestation:v1 '
    <!-- self-review-attestation:v1 {"head_sha":"<full 40-char sha>","reviewer":"<who/what reviewed>","evidence":"<one line: what was run>"} -->
EOF
)

run_gate "## Evidence

$QUOTED_SELF_REVIEW

$SELF_REVIEW_SECTION

$SELF_REVIEW_ATTESTATION"
[ "$GATE_STATUS" -eq 0 ] || fail "gate rejected a self-review body whose evidence quotes a valid-JSON example before the genuine comment (exit=$GATE_STATUS): $GATE_OUT"
case "$GATE_OUT" in
  *"bound to PR head ${HEAD_SHA}"*) ;;
  *) fail "gate passed but did not bind to the genuine attestation: $GATE_OUT" ;;
esac
pass "quoted self-review example with valid-JSON placeholders does not shadow the genuine head-bound attestation"

# --- a quoted example plus a stale genuine attestation names the stale sha ---

run_gate "$QUOTED_SELF_REVIEW

$SELF_REVIEW_SECTION

${SELF_REVIEW_PREFIX}{\"head_sha\":\"${STALE_SHA}\",\"reviewer\":\"fmtest crewmate\",\"evidence\":\"lint and tests\"} -->"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a stale attestation behind a quoted example"
case "$GATE_OUT" in
  *"bound to ${STALE_SHA} but the PR head is now ${HEAD_SHA}"*) ;;
  *) fail "expected the stale diagnostic to name the genuine stale sha, not the quoted placeholder, got: $GATE_OUT" ;;
esac
pass "with no head-bound candidate the stale diagnostic names the genuine stale attestation, not the quoted placeholder"

# --- quoted self-review prefix alone is not an attestation ------------------

run_gate "$SELF_REVIEW_SECTION

    echo '    <!-- self-review-attestation:v1 {\"head_sha\":\"<full 40-char sha>\",...} -->'"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a body whose only self-review prefix is quoted source with no JSON payload"
case "$GATE_OUT" in
  *'Self-review attestation is unparseable'*) ;;
  *) fail "expected the unparseable self-review diagnostic, got: $GATE_OUT" ;;
esac
pass "quoted self-review prefix without a valid JSON payload fails as unparseable"

# --- pretty-printed (multi-line) JSON payloads are assembled and accepted ----
# The gate extracts the comment across newlines before jq parses it, so a
# pretty-printed payload is valid. These cases prove the head-sha binding and
# the quoted-example handling still hold when the JSON spans several lines.

SELF_REVIEW_ATTESTATION_MULTILINE="<!-- self-review-attestation:v1 {
  \"head_sha\": \"${HEAD_SHA}\",
  \"reviewer\": \"fmtest crewmate\",
  \"evidence\": \"pretty-printed attestation spanning multiple lines\"
} -->"

run_gate "Summary of the change.

$SELF_REVIEW_SECTION

$SELF_REVIEW_ATTESTATION_MULTILINE"
[ "$GATE_STATUS" -eq 0 ] || fail "gate rejected a valid self-review attestation whose JSON is pretty-printed across lines (exit=$GATE_STATUS): $GATE_OUT"
case "$GATE_OUT" in
  *"Self-review attestation is valid and bound to PR head ${HEAD_SHA}"*) ;;
  *) fail "gate passed but did not report a valid head-bound self-review for the multi-line payload: $GATE_OUT" ;;
esac
pass "pretty-printed multi-line self-review attestation is assembled and accepted"

# a stale head on a multi-line payload still fails, so the binding is not
# relaxed by pretty-printing (the brief's wrong-head-sha fixture, multi-line)

run_gate "$SELF_REVIEW_SECTION

<!-- self-review-attestation:v1 {
  \"head_sha\": \"${STALE_SHA}\",
  \"reviewer\": \"fmtest crewmate\",
  \"evidence\": \"lint and tests\"
} -->"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a multi-line self-review attestation whose head_sha is not the PR head"
case "$GATE_OUT" in
  *"bound to ${STALE_SHA} but the PR head is now ${HEAD_SHA}"*) ;;
  *) fail "multi-line stale diagnostic does not name both shas: $GATE_OUT" ;;
esac
pass "pretty-printed self-review attestation with a stale head_sha still fails on the head binding"

# a quoted pretty-printed example before the genuine multi-line attestation is
# skipped for the head-bound one (the brief's quoted-placeholder fixture,
# multi-line)

QUOTED_SELF_REVIEW_MULTILINE=$(cat <<'EOF'
Example of the accepted form, pretty-printed:
<!-- self-review-attestation:v1 {
  "head_sha": "<full 40-char sha>",
  "reviewer": "<who/what reviewed>",
  "evidence": "<one line: what was run>"
} -->
EOF
)

run_gate "## Evidence

$QUOTED_SELF_REVIEW_MULTILINE

$SELF_REVIEW_SECTION

$SELF_REVIEW_ATTESTATION_MULTILINE"
[ "$GATE_STATUS" -eq 0 ] || fail "gate rejected a body whose evidence quotes a pretty-printed example before the genuine multi-line attestation (exit=$GATE_STATUS): $GATE_OUT"
case "$GATE_OUT" in
  *"bound to PR head ${HEAD_SHA}"*) ;;
  *) fail "gate passed but did not bind to the genuine multi-line attestation: $GATE_OUT" ;;
esac
pass "a quoted pretty-printed example does not shadow the genuine multi-line head-bound attestation"

# the no-mistakes pipeline attestation is likewise assembled when pretty-printed

run_gate "$MARKER

<!-- no-mistakes-pipeline-attestation:v1 {
  \"head_sha\": \"a59cb2dd9184c27a647328aca0e126232788fbeb\",
  \"steps\": [
    {\"step\": \"review\", \"status\": \"completed\"},
    {\"step\": \"test\", \"status\": \"completed\"},
    {\"step\": \"document\", \"status\": \"completed\"}
  ]
} -->"
[ "$GATE_STATUS" -eq 0 ] || fail "gate rejected a compliant pipeline attestation whose JSON is pretty-printed across lines (exit=$GATE_STATUS): $GATE_OUT"
case "$GATE_OUT" in
  *'Pipeline step attestation is valid'*) ;;
  *) fail "gate passed but did not report a valid attestation for the multi-line pipeline payload: $GATE_OUT" ;;
esac
pass "pretty-printed multi-line pipeline attestation is assembled and accepted"

# the one boundary the pretty-printing allowance keeps: the closing ' -->' must
# stay on the payload's last line. An attestation whose '-->' sits on its own
# line has no ' -->' (space then arrow) to close the candidate, so the whole
# remaining body is handed to jq and rejected as unparseable.

run_gate "$SELF_REVIEW_SECTION

<!-- self-review-attestation:v1 {
  \"head_sha\": \"${HEAD_SHA}\",
  \"reviewer\": \"fmtest crewmate\",
  \"evidence\": \"closing arrow on its own line\"
}
-->"
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted an attestation whose closing --> is on its own line"
case "$GATE_OUT" in
  *'Self-review attestation is unparseable'*) ;;
  *) fail "expected the unparseable diagnostic for a closing --> on its own line, got: $GATE_OUT" ;;
esac
pass "an attestation whose closing --> is on its own line is rejected as unparseable"

# a CRLF-terminated multi-line body (as pasted from a Windows editor or a
# CRLF-normalising web form) reaches the same accepted verdict: CR is legal JSON
# whitespace and the '## Self-review' heading grep tolerates a trailing CR.

run_gate "$(printf '%s' "$SELF_REVIEW_SECTION

$SELF_REVIEW_ATTESTATION_MULTILINE" | sed 's/$/\r/')"
[ "$GATE_STATUS" -eq 0 ] || fail "gate rejected a CRLF-terminated multi-line self-review attestation (exit=$GATE_STATUS): $GATE_OUT"
case "$GATE_OUT" in
  *"Self-review attestation is valid and bound to PR head ${HEAD_SHA}"*) ;;
  *) fail "gate passed but did not report a valid head-bound self-review for the CRLF multi-line payload: $GATE_OUT" ;;
esac
pass "a CRLF-terminated multi-line self-review attestation reaches the same accepted verdict"

# --- a pipeline body is judged by the pipeline path, never the self-review --

run_gate "$MARKER

$SELF_REVIEW_SECTION

$SELF_REVIEW_ATTESTATION"
[ "$GATE_STATUS" -ne 0 ] || fail "gate let a self-review attestation rescue a signature-only pipeline body"
case "$GATE_OUT" in
  *'structured pipeline step attestation is missing or unparseable'*) ;;
  *) fail "expected the pipeline missing-attestation diagnostic, got: $GATE_OUT" ;;
esac
pass "a body carrying the pipeline signature is judged by the pipeline path alone"
