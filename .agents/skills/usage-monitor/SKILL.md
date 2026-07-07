---
name: usage-monitor
description: >-
  Agent-only reference for firstmate's token-usage monitor: how to read the quota signal, interpret severity, run the consumption report, and apply the advisory dispatch guard.
  Use before deciding whether to hold large/low-priority dispatch on quota grounds, when producing a token-usage report, on a "usage-quota ..." check wake, and when interpreting the session-start token-usage line.
  Loaded only when the usage monitor is opted in.
user-invocable: false
metadata:
  internal: true
---

# usage-monitor

The token-usage monitor tracks how many tokens the fleet's claude-harness crews burn and where, and reads a remaining-quota signal that can advise holding large, low-priority work when the subscription's windows run hot.
The full design - transcript schema, the `/api/oauth/usage` wire format, the requestId-dedup rationale, attribution and pooled-reuse mechanics, and calibration - lives in `docs/usage-monitor.md`.
This skill is the operating reference: when to consult the signal, how to read it, and what to do.

It is relevant only when the monitor is opted in (`config/usage-monitor.env` with `FM_USAGE_ENABLED=1`; see `docs/examples/usage-monitor.env`).
When it is off, firstmate polls nothing automatically and there is nothing to act on - but `bin/fm-usage-report.sh` and `bin/fm-usage-poll.sh` can still be run by hand.

## Scope caveat, always

The ledger covers claude-harness crews only; crews on codex/opencode/pi/grok write no `~/.claude` transcripts and are invisible to the per-task ledger.
The quota signal is account-wide, so it does reflect all usage on the subscription.
Whenever you relay a fleet total to the captain, say "claude-harness usage" so the number is not mistaken for the whole fleet.

## The commands

- `bin/fm-usage-quota.sh` - print a one-line human summary of the freshest quota (5-hour %, weekly %, active per-model caps, and reset times). Add `--signal` for the normalized JSON the guard/poll consume.
- `bin/fm-usage-guard.sh [--model <name>] [--priority low|high] [--captain]` - the advisory hold/allow decision. Prints `allow: ...` (exit 0) or `hold: ...` (exit 3, with the binding window and its `resets_at`).
- `bin/fm-usage-report.sh [--no-open] [--out <path>]` - aggregate the ledger into an HTML report and open it in lavish-axi.
- `bin/fm-usage-poll.sh [--backfill] [--quiet]` - the incremental ledger update; the watcher runs it as the check shim, and a session-start backfill catches idle-time usage. You rarely run this by hand except a one-off `--backfill`.

## Interpreting severity

The signal normalizes each window to `{percent, severity, resets_at}` plus a `scoped[]` array of active per-model caps.
`severity` is `normal`, `warning`, or `critical`; an unrecognized value ranks as normal so a schema change never over-alerts, and the percent high-water still gates.
The 5-hour window is the primary gate the captain cares about; the weekly window and per-model caps are additional gates.
A `degraded` or `source: cache`/`heuristic` signal is a best-effort estimate (the live endpoint was unreachable) - treat it as soft and say "estimated" when you relay a percentage from it.

## The dispatch guard (readiness outcome `quota-held`)

At intake, before spawning large or low-priority work, consult the guard when the monitor is on.
Run `bin/fm-usage-guard.sh --priority low --model <the task's model>`.

- exit 0 (`allow`): proceed - this is the normal path.
- exit 3 (`hold`): this is the `quota-held` readiness outcome (alongside Dispatchable/Blocked in AGENTS.md section 7). Do not spawn the large/low-priority work yet. Tell the captain in outcome terms which window is hot and when it frees ("holding new large work; the 5-hour window is at 92%, frees at 09:20"), and re-evaluate the held item when that `resets_at` passes - a natural fit for the existing time/date-gated queue re-evaluation.

The guard is advisory and never hard-blocks:

- An explicit captain dispatch always proceeds - pass `--captain`, or simply honor the captain's order; the guard is a hint, not a gate.
- Small or high-priority work always proceeds - use `--priority high`.
- A red-hot weekly or per-model cap can also warrant holding just that model/harness while others are fine; check the `scoped[]` entries for the task's model.

Never let the guard stop you from serving an explicit captain instruction, and never surface the guard's internal vocabulary to the captain - translate to plain outcomes.

## The quota-severity wake

When the monitor is on, the watcher check shim emits an actionable wake only when the quota severity first crosses upward into warning or critical (deduped by `severity-watermark`), arriving as a `check:` wake whose line begins `usage-quota warning:` or `usage-quota critical:`.
On such a wake: read the current signal with `bin/fm-usage-quota.sh`, then pause new large/low-priority dispatch and, if anything large is queued, hold it and tell the captain the window and its reset in plain terms.
A drop back to normal resets the watermark, so a later re-cross re-alerts; no action is needed on the drop itself.

## Producing the report

When the captain wants a usage picture, or to find the most expensive operations to optimize, run `bin/fm-usage-report.sh`.
It opens a lavish-axi review surface with headline 5-hour/weekly tiles, weighted consumption per day, and breakdowns by project, task, model, and harness, plus the token-class split.
Weighted cost is a relative ranking heuristic (output is weighted most, cache-reads least), not the subscription's server-side limit accounting - say so if the captain reads the weighted numbers as real limit consumption.
If the ledger is empty, run `bin/fm-usage-poll.sh --backfill` first.

## Session-start line

The session-start digest surfaces one "Token usage" line with the current 5-hour and weekly utilization and resets when the monitor is on.
Read it as headroom context for the session; it is informational, not a prompt to act unless a window is already hot.
