# Usage-monitor cutover (re-baseline Phase 2)

This note is the operator runbook for one transition: retiring this fork's home-grown token-usage monitor and adopting upstream's quota model at the re-baseline cutover.
The captain ruled on 2026-08-24 to adopt upstream's quota and dispatch model wholesale and port nothing from the fork's usage-monitor, so that this subsystem carries zero divergence from upstream.
It is fork-specific migration guidance, not a description of a standing feature; once every home has cut over it is kept only as the record of why the usage-monitor is gone and how its configuration mapped forward.

The steady-state model this migrates onto is owned elsewhere and is not restated here: `AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, [`configuration.md`](configuration.md) owns the crew-dispatch and toolchain schemas, and [`quota-array-dispatch`](../.agents/skills/quota-array-dispatch/SKILL.md) owns the profile-array selection procedure.

## What is retired and what replaces it

The fork carried a token-usage monitor: `bin/fm-usage-*` scripts, a `usage-monitor` skill, `docs/usage-monitor.md`, a per-home `config/usage-monitor.env` opt-in, a `data/usage/` state tree, and an advisory dispatch guard that could hold large low-priority work as quota-held until a hot window reset.
None of that exists on the integration trunk; the trunk is pure upstream on this subsystem plus the fork's unrelated Crowsnest feature.
Its role is now filled by upstream's always-available `quota-axi` data tool and firstmate's per-dispatch judgment through `quota-array-dispatch`, with no separate monitor, ledger, or opt-in.

## Operator cutover checklist (per home, including secondmate homes)

These act on local, gitignored files, so firstmate performs them in each home as part of the cutover; nothing here is a tracked-branch change.

1. Retire `config/usage-monitor.env`.
   After cutover no code reads it, so it is inert; remove it from each home to prevent a stale opt-in from being mistaken for a live setting.
2. Remove the stale `data/usage/` state tree.
   Its ledger, checkpoint, attribution, quota, and severity files are no longer produced or read.
3. Remove the orphaned usage-watch check binding.
   Delete `state/usage-watch.check.sh` and `state/usage-watch.check-trust` so the watcher stops trying to run a shim whose `fm-usage-poll.sh` target no longer exists; leaving it registered surfaces a failing or rejected-check wake rather than quieting cleanly.
4. Confirm `quota-axi` is installed and meets the floor.
   Upstream makes `quota-axi` a required bootstrap tool (floor in [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh)), not an opt-in; bootstrap reports `MISSING: quota-axi` until it is present, and profile-array dispatch cannot resolve without it.
5. Keep `config/crew-dispatch.json` as-is.
   Upstream retains this file; its schema only widened, so existing single-object `use` rules validate and behave identically after cutover (see the mapping below).

## What replaces the quota-based dispatch hold

There is no standing quota hold on the trunk.
The fork queued large, low-priority work as quota-held and re-evaluated it when the hot window reset; that queue state and its `usage-quota` wake are gone.
Quota now enters the decision only per dispatch, inside `quota-array-dispatch`: its runway-feasibility gate blocks a candidate whose window would exhaust before the task's likely completion, and `spendPriority` ranks the eligible, in-class candidates so the most economical feasible one is chosen.
When no candidate can be proven feasible or ranked, firstmate escalates rather than parking the work to wait for a reset.
Practically, backlog items previously carried as quota-held are re-evaluated as ordinary dispatchable or blocked work at cutover; none should remain in a quota-held state, because nothing produces or clears that state any longer.

## How the captain's standing dispatch rules translate

Standing crew-dispatch rules carry over verbatim: a rule with a single `use` profile object still selects that concrete harness, model, and effort with no quota step.
To gain quota balancing under the new model, a rule's `use` (or the top-level `default`) becomes a non-empty array of profile objects, optionally with `select`, which firstmate resolves through `quota-array-dispatch`; the single-object form stays fully backward-compatible, so no existing rule must change.
See [`examples/crew-dispatch.json`](examples/crew-dispatch.json) for the array form.

The captain's standing instruction that a quota hold must never stop an explicit captain dispatch is subsumed rather than ported: there is no hold to override, so an explicit captain dispatch simply proceeds, and the only quota interaction left is per-candidate feasibility, which escalates only when the strongest-reasoning-class choice genuinely cannot proceed.
If any captain preference recorded in the home's own `data/captain.md` still describes the usage-monitor or a quota-held queue, update it to this model at cutover so the durable preference record does not point at a retired subsystem.

## Maintaining this file

This is a transitional migration record for the re-baseline; keep it accurate to the cutover it describes and do not grow it into a second owner of the steady-state quota or dispatch contract.
When a fact here duplicates `AGENTS.md` section 4, [`configuration.md`](configuration.md), or [`quota-array-dispatch`](../.agents/skills/quota-array-dispatch/SKILL.md), point at that owner instead of restating it.
