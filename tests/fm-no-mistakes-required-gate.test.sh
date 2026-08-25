#!/usr/bin/env bash
# Behavior tests for the "Require no-mistakes" PR-body gate
# (.github/workflows/no-mistakes-required.yml).
#
# The gate's check step is a self-contained shell script that consumes only
# PR_BODY/PR_AUTHOR/PR_NUMBER, so these tests extract that script from the
# workflow (parsed as YAML, the intentional machine-consumed contract) and
# execute it against controlled bodies, asserting exit codes and diagnostics.
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

# run_gate <body>: execute the extracted check step the way the workflow does.
# Captures combined output in GATE_OUT and the exit code in GATE_STATUS.
run_gate() {
  GATE_OUT=$(PR_BODY="$1" PR_AUTHOR=fmtest PR_NUMBER=48 bash "$GATE" 2>&1)
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

# --- a body without the signature is still rejected -------------------------

run_gate 'Hand-written PR body with no pipeline section at all.'
[ "$GATE_STATUS" -ne 0 ] || fail "gate accepted a body without the no-mistakes signature"
case "$GATE_OUT" in
  *'not raised through no-mistakes'*) ;;
  *) fail "expected the not-raised-through-no-mistakes diagnostic, got: $GATE_OUT" ;;
esac
pass "body without the no-mistakes signature is still rejected"
