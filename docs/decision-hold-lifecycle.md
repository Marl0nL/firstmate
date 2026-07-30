# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

A home whose configured backlog backend is not tasks-axi (`config/backlog-backend`, owned by `bin/fm-tasks-axi-lib.sh`) has no store for a structured hold.
There `hold` and `resolve` refuse rather than fabricate a durable record, while `complete` and `verify` degrade to the status-fold inventory: the attestation and the every-open-decision-is-inventoried gate still apply, no transfer event is written, and the status decision keeps carrying the item.
Degraded runs say so on stdout, so the weaker guarantee is never silent, and scout teardown stays gated instead of permanently refused.

A resolved hold eventually leaves the live backlog: Done retention prunes a closed record into the configured archive (`[markdown] archive` in the home's `.tasks.toml`, `data/done-archive.md` by default), and `tasks-axi prune` moves rather than deletes it.
`verify` and `complete` therefore accept an archived record for a hold that is missing from `data/backlog.md`, but only when that record is closed, kind `captain`, and carries the resolution record `resolve` writes, judged one archived record at a time.
That combination is what distinguishes a pruned-after-resolution hold from a hold that never existed, which before this distinction existed left such a scout permanently unable to pass the gate and its scratch worktree leased.
An archived record that does not prove resolution - a still-open hold pruned out of another section, a closed record with no resolution body, or a record of another kind - still refuses, so a genuinely unresolved captain decision keeps blocking teardown.
For the same reason `hold` refuses to re-create an identity whose archived record proves resolution, and `resolve` reports that durable fact instead of reopening it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The gate is strictly additional: it can refuse a scout teardown the report check would have allowed, and it never relaxes another refusal.
It is not consulted on the ship path at all, so the unlanded-work refusal is untouched by a decision inventory in any state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Status vocabulary and state reads

`captain-held` is DECISION BOOKKEEPING, the sibling of `resolved`, and `bin/fm-classify-lib.sh` owns both through `status_line_is_bookkeeping`.
Every consumer that must look past bookkeeping to a task's real state verb reads that owner rather than listing verbs itself.
`last_state_status_line` therefore skips a trailing transfer event, which is what keeps a finished scout terminal after its decision moves to a durable owner instead of being handed to the stale seam as a possible wedge.

The two bookkeeping verbs then diverge in `bin/fm-crew-state.sh`, because they mean different things about the line they reveal.
A `resolved` event CLOSED its key, so the state it was attached to is over and only a terminal revealed verb is promoted.
A `captain-held` event REHOMES its key and changes nothing about what the crew is doing, so the revealed real state verb stands as-is: a crew parked on a `needs-decision` is still parked once that decision gains a durable backlog owner.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
Its secondmate-home summary classifies an active captain hold as `captain_decision` and preserves the owning home.

`bin/fm-bearings-snapshot.sh` renders Captain's Call as the UNION of two authoritative sources: the canonical snapshot's `hints.open_decisions` status fold and active structured captain holds.
The union is deliberate.
A live crew's `needs-decision:` or `blocked:` has no durable owner during the window before firstmate registers one, so a backlog-only projection would hide exactly the decisions that are freshest, and a live blocker would stop reaching the captain at all.
The `captain-held` transfer verb, not source suppression, is what prevents a double render: once a decision has a verified durable owner its status copy is closed in the fold, so it appears once.
Holds are excluded from ordinary queued gates, and completed kind `captain` records are excluded from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-26, on this repository's port of the upstream feature.
The upstream feature and its quoted `blocked_by` follow-up were verified upstream on 2026-07-14 and 2026-07-17; this record is the evidence for the port, which rebased the design onto this tree's diverged classifier, crew-state reader, and Bearings projection.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the teardown gate refuses to erase the source.
Further regressions cover tasks-axi's quoted multi-entry `blocked_by` output, a hold surviving the loss of all volatile state, and a manual-backlog home degrading instead of bricking scout teardown.

Pruned-resolution date: 2026-07-30, after a scout hit the gap live on 2026-07-28 with resolved holds aged out of Done retention.
Its two regressions drive the real `tasks-axi prune --keep 0 --state done` path rather than a hand-written fixture for the positive case, and use hand-written archive fixtures for the refusal cases that tasks-axi will not produce on its own.
The refusal cases include a resolution record that belongs to a neighbouring archived row, which must not clear the gate for the hold's own row.

The verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a captain hold survives a restart that loses all volatile state and stays answerable
ok - a resolved hold pruned into the archive stays distinguishable from one that never existed
ok - an archived record clears the gate only when it proves resolution
ok - a manual-backlog home refuses hold mutations and degrades the gate instead of bricking teardown

$ bash tests/fm-watch-triage.test.sh
ok - the captain-held transfer verb closes only its own status copy and never masks the real state verb
(38 ok lines, no failures)

$ bash tests/fm-crew-state.test.sh
ok - a captain-held transfer preserves the revealed state verb instead of reading unknown
(44 ok lines, no failures)

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides
(13 ok lines, no failures)

$ bash tests/fm-bearings-snapshot.test.sh
ok - Captain's Call unions a live status decision with durable holds and never double-renders a transferred one
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
(31 ok lines, no failures)

$ bash tests/fm-teardown.test.sh
ok - a satisfied decision inventory never bypasses the unlanded-work refusal
(33 ok lines, no failures)

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
(15 ok lines, no failures)

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)
```

Four live-herdr smoke and e2e scripts (`fm-backend-autodetect-smoke`, `fm-backend-herdr-smoke`, `fm-backend-herdr-respawn-idem-e2e`, `fm-backend-herdr-workspace-per-home-e2e`) fail on this host against the installed herdr.
They fail at agent launch or at herdr tab replacement, before reaching any code this feature touches, so they are environment-dependent and unrelated to the decision-hold lifecycle.
