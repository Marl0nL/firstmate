#!/usr/bin/env python3
"""Semantic verification of the CI-trigger change (fm/ci-manual-trigger).

Parses the workflow YAML files into their semantic model (the same structure
GitHub Actions consumes) and asserts trigger *meaning*, not text:

  1. ci.yml is workflow_dispatch-only, with an optional string `ref` input.
  2. Every job in ci.yml consumes `inputs.ref` in its checkout step, so the
     dispatch input can actually point the suite at a branch or PR head.
  3. The `invariants` job was removed from ci.yml and reappears in
     repo-invariants.yml with semantically identical steps (same names, same
     run scripts) — the split lost nothing.
  4. repo-invariants.yml is auto-triggered on push/pull_request to main.
  5. no-mistakes-required.yml is auto-triggered (and unchanged vs base,
     asserted separately via git diff).
  6. windows-herdr-spike.yml is workflow_dispatch-only.
  7. The gh command CONTRIBUTING.md documents targets ci.yml and passes an
     input name that ci.yml actually declares.
"""
import re
import subprocess
import sys

import yaml

ROOT = sys.argv[1]
BASE = sys.argv[2]

failures = []


def check(desc, cond):
    print(("PASS" if cond else "FAIL") + ": " + desc)
    if not cond:
        failures.append(desc)


def load(path):
    with open(ROOT + "/" + path) as f:
        return yaml.safe_load(f)


def triggers(wf):
    # YAML 1.1 parses the bare key `on` as boolean True.
    on = wf.get("on", wf.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on


ci = load(".github/workflows/ci.yml")
inv = load(".github/workflows/repo-invariants.yml")
req = load(".github/workflows/no-mistakes-required.yml")
spike = load(".github/workflows/windows-herdr-spike.yml")

# 1. ci.yml: manual-only, optional ref input.
ci_on = triggers(ci)
check("ci.yml triggers are exactly {workflow_dispatch} (no push/pull_request)",
      set(ci_on) == {"workflow_dispatch"})
ref_input = (ci_on.get("workflow_dispatch") or {}).get("inputs", {}).get("ref")
check("ci.yml workflow_dispatch declares a `ref` input",
      ref_input is not None)
check("ci.yml `ref` input is optional (required: false)",
      ref_input is not None and ref_input.get("required") is False)
check("ci.yml `ref` input is a string",
      ref_input is not None and ref_input.get("type") == "string")

# 2. Every ci.yml job's checkout consumes inputs.ref.
for job_id, job in ci["jobs"].items():
    checkouts = [s for s in job.get("steps", [])
                 if str(s.get("uses", "")).startswith("actions/checkout")]
    consumes = all("${{ inputs.ref }}" == (s.get("with") or {}).get("ref")
                   for s in checkouts)
    check(f"ci.yml job `{job_id}` checkout consumes the dispatch ref input",
          bool(checkouts) and consumes)

# 3. Invariants job moved intact: removed from ci.yml, identical in the new file.
check("ci.yml no longer contains the `invariants` job",
      "invariants" not in ci["jobs"])
base_ci_text = subprocess.run(
    ["git", "-C", ROOT, "show", f"{BASE}:.github/workflows/ci.yml"],
    capture_output=True, text=True, check=True).stdout
base_inv_job = yaml.safe_load(base_ci_text)["jobs"]["invariants"]
new_inv_job = inv["jobs"]["invariants"]
check("repo-invariants.yml job steps are semantically identical to the "
      "invariants job removed from base ci.yml",
      base_inv_job["steps"] == new_inv_job["steps"]
      and base_inv_job["runs-on"] == new_inv_job["runs-on"]
      and base_inv_job["name"] == new_inv_job["name"])

# 4. repo-invariants.yml auto-triggers.
inv_on = triggers(inv)
check("repo-invariants.yml auto-triggers on push to main",
      (inv_on.get("push") or {}).get("branches") == ["main"])
check("repo-invariants.yml auto-triggers on pull_request to main",
      (inv_on.get("pull_request") or {}).get("branches") == ["main"])

# 5. no-mistakes-required.yml stays auto-triggered.
req_on = triggers(req)
check("no-mistakes-required.yml still auto-triggers on pull_request",
      "pull_request" in req_on or "pull_request_target" in req_on)

# 6. windows-herdr-spike.yml stays manual-only.
check("windows-herdr-spike.yml triggers are exactly {workflow_dispatch}",
      set(triggers(spike)) == {"workflow_dispatch"})

# 7. CONTRIBUTING.md's documented trigger command is consistent with ci.yml.
with open(ROOT + "/CONTRIBUTING.md") as f:
    contributing = f.read()
cmds = re.findall(r"gh workflow run (\S+)((?:\s+-{1,2}\S+(?:[= ]\S+)?)*)",
                  contributing)
check("CONTRIBUTING.md documents `gh workflow run ci.yml`",
      any(c[0] == "ci.yml" for c in cmds))
doc_inputs = set(re.findall(r"-f\s+(\w+)=", contributing))
declared_inputs = set((ci_on.get("workflow_dispatch") or {}).get("inputs", {}))
check(f"every workflow input CONTRIBUTING.md passes ({sorted(doc_inputs)}) is "
      f"declared by ci.yml ({sorted(declared_inputs)})",
      doc_inputs <= declared_inputs and bool(doc_inputs))

print()
if failures:
    print(f"{len(failures)} FAILURE(S)")
    sys.exit(1)
print("ALL SEMANTIC CHECKS PASSED")
