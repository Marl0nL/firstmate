# Token-usage monitor

The token-usage monitor gives firstmate two things: a consumption ledger of how many tokens the fleet's crews are burning and where, and a remaining-quota signal that can advise holding large, low-priority work when the subscription's windows run hot.
It is built from the Claude Code transcript tree and the OAuth usage endpoint, both of which are undocumented and parsed on a best-effort basis.

This document is the single full statement of the transcript schema, the `/api/oauth/usage` wire format, the requestId-dedup rationale, the attribution and pooled-reuse mechanics, and the calibration notes.
`AGENTS.md`, the `usage-monitor` skill, and the four `bin/fm-usage-*.sh` scripts all point here rather than restating any of it.

## Native scope: claude-harness crews only

The ledger is built from `~/.claude/projects/**/*.jsonl`, which only the `claude` harness writes.
Crews on `codex`, `opencode`, `pi`, or `grok` do not write those transcripts, so their token use is invisible to this module.
On a fleet whose `config/crew-harness` resolves to `claude` that is effectively all crew work, but every fleet total the report shows is labeled "claude-harness usage" so the number is never mistaken for the whole fleet.
The quota signal is subscription-wide (it is the same account-level limit the interactive `/usage` view reads), so it does reflect all usage on the account regardless of harness; only the per-task/per-project ledger attribution is claude-only.

## Opt-in and inertness

The monitor is inert by default.
With no `config/usage-monitor.env` (or `FM_USAGE_ENABLED` unset/0) firstmate polls nothing automatically, the watcher check shim is never written, and the session-start digest surfaces no quota line - zero behavior change.
`bin/fm-usage-poll.sh` and `bin/fm-usage-report.sh` can still be run by hand at any time to build and view the ledger.
Opting in is a local, gitignored `config/usage-monitor.env` with `FM_USAGE_ENABLED=1`; see `docs/examples/usage-monitor.env` for every knob.
The dispatch guard and the quota-severity wake are a second opt-in, `FM_USAGE_GUARD_ENABLED=1`, and are advisory: the guard never hard-blocks an explicit captain dispatch.

## Data layout

All module state is per-home and gitignored under `data/usage/`:

- `ledger.jsonl` - append-only, one line per unique request; the durable record.
- `checkpoint.json` - `{ "<abs jsonl path>": {size, mtime, offset}, ... }`; the incremental read cursor.
- `attribution.json` - `{ "<sessionId>": {task_id, project, harness, kind, worktree}, ... }`; the per-session snapshot that survives teardown.
- `quota.json` - the last-good normalized quota signal, with `fetched_at`.
- `severity-watermark` - the last alert level surfaced, so the wake fires only on an upward crossing.
- `.last-poll` - mtime marker for the `--if-due` min-interval gate (the wake-drain trigger); `.poll.lock` is the single-writer lock.
- `report.html` - the generated report (overwritten each run).

## Goal A - the consumption ledger

### Transcript JSONL schema

Claude Code writes one `*.jsonl` per session under `~/.claude/projects/<dir-slug>/`, plus subagent transcripts under `<dir-slug>/subagents/agent-*.jsonl`.
The filename is the `sessionId`.
The scan glob must be recursive (`**/*.jsonl`) so the `subagents/` tree is included; subagents carry full usage and inherit the parent's `cwd`/`gitBranch`, so they attribute to the same task automatically.

Only records with `type == "assistant"` carry token usage.
An assistant record has these fields (the monitor reads only the small subset below and defaults every missing field to 0/empty):

- top level: `requestId`, `uuid`, `timestamp`, `cwd`, `sessionId`, `version`, `gitBranch`, `isSidechain`.
- `message.model` - the actual model (e.g. `claude-opus-4-8`, `claude-fable-5`).
- `message.usage` - `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `service_tier`.

`<synthetic>` records carry an all-zero usage block and are skipped.
The `version` (Claude Code version, e.g. `2.1.202`) is recorded per ledger line so a future schema break is detectable in the ledger itself.

### The requestId-dedup rule

The unit of consumption is one `requestId`.
Two duplication mechanisms make naive per-line or per-file summation overcount:

1. A single API request produces several assistant lines - one per content block (a text block plus each tool_use) - and every one carries the identical `usage` totals.
2. Resume and compaction fork a new session file that copies prior history, replaying old assistant records with their original `requestId`s; measured on real data, ~11% of requestIds appear in more than one file.

So the ledger records each `requestId` exactly once, taking the usage from whichever line is seen first (they are identical), and maintains a global seen-set to ignore every later duplicate.
The seen-set is derived from `ledger.jsonl` itself at the start of each run (one source of truth), so both duplication kinds collapse regardless of read order.
The four token classes are stored raw and separately, never pre-summed, because they carry very different weight (see Weighting).

### Attribution

The join to a firstmate task is `transcript.cwd == state/<id>.meta:worktree=`.
Attribution is per-record, not per-file, because `cwd` can vary within one session (the primary firstmate session cd's into projects to read them).
Each record resolves in this order:

1. A live `state/<id>.meta` whose `worktree=` equals the record's `cwd` - the universal key for ship, scout, and secondmate work. The transcript's actual `model` is preferred over the meta's `model=`, which often reads `default`.
2. The primary firstmate checkout (`cwd == FM_ROOT`) - firstmate's own supervision cost, attributed to a synthetic `firstmate-primary` task.
3. A registered secondmate home (from `data/secondmates.md`) - the secondmate's own supervision session; its crews attribute in that secondmate's own home poll.
4. The frozen per-session snapshot in `attribution.json` (see Pooled-worktree reuse and teardown).
5. A ship crew's `gitBranch` of the form `fm/<id>`, which names the task even with no snapshot.
6. Otherwise `uncategorised`, tagged with the `cwd`'s project leaf and the branch - e.g. the captain's own direct Claude Code sessions in their repos.

The dir-slug transform (Claude Code maps every `/` and `.` in the working dir to `-`) is lossy and never reversed; the slug is computed from a path, never parsed back, and the primary key is the record's inline `cwd`.

### Pooled-worktree reuse and teardown

`bin/fm-teardown.sh` deletes `state/<id>.meta`, so a record seen after its task is torn down can no longer be joined to a live meta.
Two mitigations cover this:

- The poll runs while tasks are live, so most records are attributed in real time.
- On the first sighting of a record whose `cwd` matches a live meta, the poll snapshots that meta into `attribution.json` keyed by `sessionId`; later records - post-teardown and resume-forks - attribute from the frozen snapshot.

Pooled worktrees (treehouse leases the same worktree path to different tasks over time) are disambiguated by the fresh `sessionId` per lease and, for ship crews, by the `fm/<id>` branch, so `cwd` alone is never trusted across time.

### Incremental, idempotent update

A full dedup rescan of the whole tree is cheap (~1.5s on a real ~338MB tree), so it is a viable backfill, but the steady-state watcher path must stay cheap:

1. For each `*.jsonl`, compare `(size, mtime)` to `checkpoint.json`; unchanged files are skipped, new files are read from offset 0, and grown files are read only from `last_offset`.
2. New bytes are trimmed to complete lines only - the offset advances to just past the last newline - so a line still being written is picked up next run rather than half-read now.
3. Each assistant record in the new bytes is skipped if `<synthetic>` or if its `requestId` is already in the seen-set; otherwise it is attributed and appended as one `ledger.jsonl` line.

The result is idempotent by construction: the requestId gate never double-appends and the offset gate never re-reads bytes, so the poll is safe to run every watcher cycle and to re-run after a crash.
`--backfill` forces a full rescan (offsets reset to 0); it stays requestId-deduped, so it recovers a stretch consumed while the watcher was down, or a line missed by a mid-write read, without ever double-counting.
A single-writer lock (`data/usage/.poll.lock`) keeps a session-start backfill from racing a watcher poll.

### Reliable, watcher-independent gathering

Data gathering must not depend on the watcher staying alive.
In some environments the watcher background task is frequently reaped, so the check shim below rarely runs and the ledger would otherwise sit empty until a manual backfill.
The ledger therefore catches up from three independent triggers, so any one being down does not stop accumulation:

1. **Session start.** `bin/fm-session-start.sh` runs a bounded `--backfill --quiet` poll on every locked (non-read-only) session start, so each session opens with the ledger current.
2. **Wake-drain (the decoupled, always-hit trigger).** `bin/fm-wake-drain.sh` runs at the top of every wake-handling turn regardless of watcher liveness, and fires `bin/fm-usage-poll.sh --if-due`.
   `--if-due` is self-gated: it no-ops unless the monitor is opted in AND the last `--if-due` run touched `data/usage/.last-poll` more than `FM_USAGE_POLL_MIN_INTERVAL` seconds ago (default 60), and it relies on the same offset/mtime checkpoint so it only reads new transcript bytes.
   It implies `--quiet` (never emits a wake) and the wake-drain call wraps it in a bounded `timeout` and `|| true`, so a slow or failing poll can never slow, break, or change the exit status of the drain or the supervision path.
3. **Watcher check shim (belt and braces).** `state/usage-watch.check.sh` still execs the poll each watcher cycle when the watcher is alive (below).

All three collapse to the same requestId-deduped, offset-checkpointed ledger, so running any combination of them never double-counts.

### Weighting

The four token classes carry very different real cost - measured lifetime totals on one fleet were roughly `output=11.6M`, `cache_creation=98.5M`, `input=2.6M`, `cache_read=4.40B`, so cache reads dominate volume but are the cheapest per token while output is the most expensive.
The report therefore stores the four classes raw and applies configurable weights (default `output=5`, `cache_creation=1.25`, `input=1`, `cache_read=0.1`) so "expensive operations" ranks by weighted cost rather than raw token count.
This weighting is a heuristic for relative ranking only; it is not the subscription's actual server-side limit accounting, and it deliberately does NOT reflect per-model price differences (see below).

### Real per-model cost

The token-class weighting above is uniform across models, so it cannot compare cost across models: it treats an output token on Haiku the same as one on Fable, when Fable is actually the priciest tier and Haiku the cheapest.
The report's headline cost is therefore computed from real per-model pricing, applied at aggregation time from the `model` already recorded on every ledger line (no re-scan needed).

The rate table lives in `fm_usage_pricing_json` (`bin/fm-usage-lib.sh`).
Its built-in defaults (`FM_USAGE_PRICING_DEFAULTS`) carry one rate object per model - `input`, `output`, `cache_read`, `cache_write` - in **USD per million tokens (MTok)**, so the numbers match Anthropic's published pricing page 1:1.
`cache_read` is the 0.1x-input cache-read rate and `cache_write` is the 1.25x-input 5-minute cache-creation rate (the cache class the ledger records); `costOf` sums each raw token class times its per-model rate and divides by 1,000,000.
The built-in rates were sourced from the `claude-api` reference; **verify them against current Anthropic pricing before trusting the numbers - rates drift.**
Each rate is labelled with its units and that verify caveat in the code, the report UI, and the config template.

A local, gitignored `config/usage-pricing.json` (template: `docs/examples/usage-pricing.json`) overlays the built-ins: each model listed there merges over the built-in table by id, and a `default` there replaces the built-in default.
An absent or malformed config falls back to the built-in table verbatim, so a bad edit never silently zeroes every cost.
Model matching is exact id first, then the longest built-in/config key that is a prefix of the model (so `claude-opus-4-8[1m]` and dated `-20251001` variants resolve), then the labelled `default`.
An unknown model uses `default` and is flagged `default rate` in the report - never a silent zero.

The shared jq definitions (`FM_USAGE_PRICING_JQ_DEFS`: `rateFor`, `priceMatched`, `costOf`) are the single owner of the lookup and cost formula; `fm_usage_model_cost` (single-value, used by tests) and `bin/fm-usage-report.sh`'s one-pass aggregation both use them, so the math is stated once.
The report's model, task, project, and harness breakdowns rank by real $ cost, with the token-class `weighted` number kept alongside only as the relative-ranking heuristic.

## Goal B - the remaining-quota signal

### The `/api/oauth/usage` wire format

`bin/fm-usage-quota.sh` fetches `GET https://api.anthropic.com/api/oauth/usage` with the OAuth access token read fresh from `~/.claude/.credentials.json` (`.claudeAiOauth.accessToken`) and the required header `anthropic-beta: oauth-2025-04-20`.
This is the same call the interactive `/usage` view makes; it is undocumented and best-effort.
A real 200 response looks like:

```json
{
  "five_hour": {"utilization": 40.0, "resets_at": "2026-07-07T09:19:59+00:00"},
  "seven_day": {"utilization": 91.0, "resets_at": "2026-07-08T07:59:59+00:00"},
  "limits": [
    {"kind": "session",       "group": "session", "percent": 40,  "severity": "normal",   "resets_at": "...", "is_active": false},
    {"kind": "weekly_all",    "group": "weekly",  "percent": 91,  "severity": "critical", "resets_at": "...", "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly",  "percent": 100, "severity": "critical", "resets_at": "...", "is_active": true,
     "scope": {"model": {"display_name": "Fable"}}}
  ]
}
```

The `limits[]` array is the cleanest input: it normalizes every window to `{kind, group, percent, severity, resets_at, is_active, scope}`.
`kind == "session"` is the 5-hour window, `kind == "weekly_all"` is the weekly window, and each `kind == "weekly_scoped"` is a per-model cap keyed by `scope.model.display_name`.
`severity` and `percent` are the ready-made decision inputs and `resets_at` gives the reset times directly.
The parser falls back to the top-level `five_hour`/`seven_day` objects when `limits[]` is absent, and defaults every missing field to `0`/`normal` so a schema drift never crashes the parse.

The quota script normalizes all of this into one shared signal shape that the guard and the poll consume:

```json
{"source": "live|cache|heuristic", "degraded": false, "fetched_at": "...",
 "windows": {
   "session": {"percent": 40, "severity": "normal",   "resets_at": "..."},
   "weekly":  {"percent": 91, "severity": "critical",  "resets_at": "..."},
   "scoped":  [{"model": "Fable", "percent": 100, "severity": "critical", "is_active": true, "resets_at": "..."}]}}
```

### Privacy

The access token is read fresh on every call, passed only into a `curl` auth header on a private 0600 temp file, and is never written to a log, the cache, the ledger, or stdout.
The ledger extracts only token counts and attribution metadata; no transcript message content is ever copied under `data/usage/`.

### Degrade chain

The live endpoint is primary.
On any failure - including a `401` when the on-disk token has expired - the quota script degrades to the cached `quota.json` (marked `degraded`) while it is still within `FM_USAGE_QUOTA_TTL` seconds of its `fetched_at`, and if there is no cache or the cache is older than that TTL, to a ledger burn-rate heuristic.
It never attempts a token refresh: refreshing `.credentials.json` is Claude Code's job, and a standalone refresh would risk racing the client's token rotation.
A degraded signal is a soft warning, never a blocker, and never fails a watcher cycle.

### Ledger burn-rate heuristic

When the endpoint is unreachable the heuristic derives an approximate signal from `ledger.jsonl` alone: the weighted token sum over the trailing 5-hour and 7-day windows against a conservative, configurable ceiling.
It tracks consumption precisely; only the remaining-percent is an estimate, because the true per-tier limits are server-side and unpublished, so the number is labeled "estimated".

### Calibration

The heuristic's ceilings can be calibrated opportunistically: whenever a live `/api/oauth/usage` succeeds, the pair `(weighted tokens since the window anchor, utilization%)` implies a ceiling that can be persisted per `rateLimitTier`.
Until calibrated, the conservative configured ceilings (`FM_USAGE_EST_5H_CEILING`, `FM_USAGE_EST_WEEKLY_CEILING`) are used and the estimate is labeled as such.
This closed-loop calibration is a documented follow-up; the current build uses the configured ceilings.

### Decision rule and hook points

`bin/fm-usage-guard.sh` answers "should firstmate hold large/low-priority work?" gating primarily on the 5-hour window, with the weekly window and any active per-model cap as additional gates.
It advises a hold (exit 3) when the 5-hour severity is critical or its percent is at/above the configurable high-water (default 80), or the weekly window is critical, or an active per-model cap for the task's model is critical/at 100%.
It always allows (exit 0) an explicit captain dispatch (`--captain`) or high-priority work (`--priority high`), and when it has no signal - the guard advises, it never hard-blocks.
The decision logic lives in `fm_usage_decision` in `bin/fm-usage-lib.sh`, shared between the guard and the poll's wake so the two never drift.

The quota-severity WAKE rides the existing watcher backbone with no changes to `fm-watch.sh`; the LEDGER gathering is decoupled from watcher liveness (see Reliable, watcher-independent gathering above):

- The check shim `state/usage-watch.check.sh` (generated by bootstrap on opt-in, mirroring X mode's `x-watch.check.sh`) execs `bin/fm-usage-poll.sh` each cycle. The ledger update is a silent side effect; the poll prints a wake line only when the quota severity first crosses into warning/critical, tracked by `severity-watermark` so it never spams. This is the only path that can emit the quota wake, and it fires only while the watcher is alive.
- Session start runs a bounded backfill and surfaces the current 5-hour + weekly utilization and resets as one line, so every session opens knowing the headroom.
- Wake-drain runs `--if-due` on every wake-handling turn to keep the ledger current even when the watcher is dead; it is silent, self-gated, and failure-isolated, and never emits a wake.
- Intake (`AGENTS.md` section 7) gains a `quota-held` readiness outcome checked just before spawn, pointing at the guard.

## Risks

- Transcript-format stability: the schema is undocumented and has evolved before; the ledger reads only a small defensively-parsed field set, defaults missing fields to 0, records `version` per line, and never hard-fails a watcher cycle.
- `/api/oauth/usage` is unofficial: it could change or rate-limit; treat it as best-effort, cache last-good, degrade to the heuristic, and never block supervision on it.
- Guard authority: the guard stays advisory and never overrides an explicit captain dispatch.
