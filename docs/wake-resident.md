# Wake-resident secondmates

Most secondmates in a firstmate fleet are always-resident: spawned once, supervised forever, idle when their queue is empty.
A **wake-resident** secondmate is the other shape.
It is dormant by default, a message in its chat inbox raises it through the ordinary secondmate spawn, and it stands down again after a quiet interval.

## Two axes, not one

**Persistent** and **wake-resident** are different axes, and conflating them is how a sleeping agent gets destroyed.

| Axis | What it governs | For a wake-resident secondmate |
| --- | --- | --- |
| Persistent | **Identity and state.** The home, the seed marker, the charter, the backlog, the status log, the runtime metadata carrying the worktree lease, and the registry route. | **Permanent.** Removed only by `bin/fm-teardown.sh`, on an explicit captain decision. |
| Wake-resident | **The process.** The running agent behind the endpoint. | **Not permanent.** A message raises it; an idle window exits it. |

The standard secondmate wording ("persistent by default, do not exit just because your queue is empty") runs the two together, because an always-on secondmate is permanent on both.
A wake-resident secondmate is the exception, and it is persistent on the first axis exactly as much as any other secondmate.

**An exit is not a teardown and loses nothing.**
That is not a claim this document makes; it is a checked invariant, described under [Stand-down is not teardown](#stand-down-is-not-teardown) below.

This exists for a domain whose work is conversational and bursty rather than continuous.
An always-on agent for that shape burns quota sitting at an empty prompt, and a fresh agent per message loses the durable home that makes a secondmate a persistent identity in the first place.
Wake-residency keeps the persistent identity and pays only for the conversations.

The lifecycle is off unless a home opts a secondmate in, and a home with no records behaves exactly as it does today.

## The rule that must not bend

An inbox message becomes a **wake** that the ONE live firstmate handles on its own turn.
Nothing here ever spawns an agent from a watcher check, and nothing here services chat in parallel with supervision.
That is the same single-threaded rule [crowsnest.md](crowsnest.md) is built around, and it is why the poll below detects but never acts.

## Shape

Two generated check shims, one guarded operator script, one config file.

| Artifact | Home | What it does |
| --- | --- | --- |
| `config/wake-resident.conf` | main | One record per wake-resident secondmate. `bin/fm-wake-resident-lib.sh`'s header owns the format. |
| `state/wake-resident.check.sh` | main | The lifecycle detector. Runs `bin/fm-wake-resident-poll.sh` each check cycle; its output becomes a `check:` wake. |
| `state/wake-self.check.sh` | secondmate | The fast path: surfaces this home's own oldest pending inbox entry so a resident agent notices it on its own turn. |
| `state/<name>.wake-resident` | main | Dormancy bookkeeping: `raised_at`, `dormant_since`, `last_seen_msg`. |
| `bin/fm-wake-resident.sh` | main | `enable`, `disable`, `sync`, `status`, `raise`, `standdown`. |

Both shims are written and registered through `bin/fm-check-lib.sh`'s trust path in the same operation, so the watcher never meets an unregistered check it has to refuse.

## Lifecycle

1. **Dormant.**
   No agent is running.
   `state/<name>.meta`, the secondmate home, its treehouse lease, its backlog and its status file all sit on disk untouched.
2. **A message arrives.**
   The console (or any producer of the inbox shape below) writes `<inbox>/<id>.json`.
3. **The main home's poll notices**, on its next check cycle, that the secondmate is confidently dormant and has pending mail, and prints one line.
4. **Firstmate raises it on its own turn** with `bin/fm-wake-resident.sh raise <name>`, which is a guarded wrapper around `bin/fm-spawn.sh <name> --secondmate` and nothing else.
   It comes up with its charter, its inherited config, and its home exactly as any other secondmate does.
5. **Resident.**
   Further messages reach it through its own home's `wake-self` shim, so an ordinary conversation costs the main firstmate no turns at all.
   If a message sits unread past `grace-secs` - the shape a secondmate whose own supervision cycle is down would produce - the main home surfaces it as a backstop, so delivery never depends on the secondmate's watcher being up.
6. **Quiet.**
   Once nothing is pending, nothing of its own is in flight, its pane is not busy, and `idle-secs` have passed, the poll offers a stand-down.
7. **Stand-down.**
   `bin/fm-wake-resident.sh standdown <name>` submits the harness's own exit command and stops there.
   If the agent has already exited itself - leaving the bare shell of step 1 - there is nothing to submit, so the stand-down simply records the dormancy.
   Either way, back to step 1, with the same home.

## Stand-down is not teardown

This distinction is the whole safety story, so it is stated once, here, in full.

`bin/fm-teardown.sh` **retires** a secondmate.
It ends both axes: it kills the endpoint, removes the home, releases the durable treehouse lease so the pool slot is freed, drops `state/<name>.meta`, and unregisters it from `data/secondmates.md`.
That is correct for a secondmate that is finished forever, and it is a captain decision.

A stand-down **exits** one.
It ends the process axis only.
It submits the harness's exit command, confirms the agent is gone, and writes a timestamp.
It never calls `fm-teardown.sh`, never returns a worktree, never removes a home, never touches the registry, the backlog, the status file, or the meta.

Because getting this backwards would destroy a persistent agent that was only meant to be asleep, the persistent axis is **verified, not assumed**.
`bin/fm-wake-resident-lib.sh` enumerates it once as a manifest; `bin/fm-wake-resident.sh` snapshots that manifest before the exit and re-checks it after, and a loss is a loud internal failure rather than a reported success.

The check is **presence plus no-shrinkage**, not byte-equality, and that is deliberate.
A status line the agent appends on its way out is its own work, so growth is normal; only removal and truncation are losses.
Adding an artifact to the manifest immediately strengthens the check for every stand-down, which is why the enumeration lives in one place rather than as scattered assertions.

## What it refuses

Refusals are deliberately asymmetric: leaving a secondmate up costs a little quota, standing one down wrongly drops someone's work, so every uncertain case leaves it up.

| Situation | Behaviour |
| --- | --- |
| Work in flight in the secondmate home (any `state/*.meta`) | Stand-down refuses. **`--force` does not waive this.** |
| An unanswered message in the inbox | Stand-down refuses. **`--force` does not waive this.** |
| The pane is confirmed busy | Stand-down refuses; `--force` waives. |
| Fewer than `idle-secs` quiet | Stand-down refuses; `--force` waives. |
| The agent has already exited itself (a bare shell) | Stand-down **succeeds** with no pane submission: it records the dormancy, because that bare shell is exactly the state a stand-down is trying to reach. This works on any harness, grok included, since nothing is sent. The work-in-flight and unanswered-message refusals above still apply first. |
| A **live** agent on a harness whose exit is not a submittable line (grok) | Stand-down refuses outright, rather than half-sending something and reporting success. |
| The agent does not confirm its exit in time | Stand-down fails and leaves it alone. It never escalates to a kill. |
| Liveness read is inconclusive | Both raise and stand-down refuse. |
| A raise is already in flight | The second raise refuses. One claim, one agent. |

The in-flight predicate is deliberately identical to `fm-teardown.sh`'s secondmate refusal - any `state/*.meta` in that home - so "has work in flight" means the same thing to the thing that stands a secondmate down and the thing that retires it.

## Races

- **Two wakes together.**
  `raise` holds a claim directory for its whole run.
  The loser refuses and says so; it never launches a duplicate supervisor into one home.
- **A message racing an exit.**
  Losing a message is worse than an extra wake, so the design prefers waking again.
  Stand-down re-reads the inbox immediately before exiting and refuses if anything is pending; a message that lands after that check leaves a pending entry against a now-dormant secondmate, which is exactly the state the poll raises on.
  The throttle stamps are cleared on every successful transition, so that raise fires on the next cycle rather than waiting out the previous decision's cooldown.
- **Quiet time and a drained inbox.**
  The poll records the newest message mtime it has seen (`last_seen_msg`) *before* anything is drained, so a stand-down can never measure quiet time from an inbox that has since been emptied.
- **Inconclusive liveness.**
  `unknown` licenses nothing in either direction, for the same reason `bin/fm-bootstrap.sh`'s secondmate-liveness sweep acts only on a confident verdict, never an ambiguous one.

## The liveness-sweep exemption

`bin/fm-bootstrap.sh`'s `secondmate_liveness_sweep` respawns a secondmate whose agent has exited behind a live shell.
A dormant wake-resident secondmate is *exactly* that shape.
The sweep therefore skips any id with a wake-resident record, or every session start would resurrect an agent that is deliberately asleep.
A wake-resident secondmate is brought up by a message, never by liveness alone.

## The reread-nudge exemption

A firstmate self-update sends each running secondmate a one-line "re-read your AGENTS.md" nudge, and that nudge is a typed submission into the secondmate's own terminal - the steering doorbell on `fm-send`'s inbox plane.
A dormant wake-resident secondmate must never receive it: its agent is asleep behind a bare shell, so the doorbell would run as a stray shell line, and on the from-firstmate marked plane it would strand a pending-reply expectation no dormant agent can answer.
It also gains nothing, because a raise re-reads AGENTS.md fresh anyway.
So both nudge callers skip a dormant wake-resident home with an explicit report line: `bin/fm-bootstrap.sh`'s fleet-update nudge (`BOOTSTRAP_INFO: skipped fm-<id>: dormant wake-resident - reads instructions fresh on raise`) and `bin/fm-update.sh`'s nudge listing (a `nudge-skipped: fm-<id> - ...` line, dropping it from `nudge-secondmates:`).
`bin/fm-wake-resident-lib.sh` owns both predicates: `fm_wr_dormant_wake_resident` is the shared skip, and `fm_wr_nudge_suppressed` is bootstrap's own guard, which additionally refuses to type into any confirmed bare shell (`fm_backend_agent_alive` = dead) even for an ordinary secondmate - defense in depth for the same typed-into-a-shell hazard.
A `dead` verdict counts as confirmed only for a harness with an empirically verified classifier, the same convention `fm_wr_residency` applies, because a live secondmate launched via the raw-launch-command escape hatch is itself a shell the tmux classifier reads as dead - any other harness stays nudged.
`unknown` licenses nothing here either, so an unclassifiable idle screen is still nudged, exactly as the steering doorbell is otherwise best-effort.
A remote secondmate is steered over its remote transport rather than a local typed submission, so neither skip applies to it.

## Away mode

While `state/.afk` exists the daemon owns supervision, so the poll goes silent.
A raise and a stand-down are both fleet mutations, and away mode never expands approval authority; queueing lifecycle work the daemon has no authority to perform would only produce noise the captain has to clear on return.

## The inbox contract - consumed, not defined here

The inbox shape is [crowsnest.md](crowsnest.md)'s, which the quant console writes as its chat transport:

```
<inbox>/<id>.json     present = pending; the answering agent removes it once answered
```

This mechanism reads only the **presence** and the **mtime** of those files, never their contents.
The entry's JSON fields stay entirely the producer's to shape, and any dependency beyond presence would have to be agreed with the console's owner first.

`<inbox>` defaults to `<secondmate-home>/state/chat-inbox`, the same place a Crowsnest-enabled home keeps its own, and is overridable per record with `inbox=`.

## Enabling one

```
bin/fm-wake-resident.sh enable advisor --idle-secs 1800
bin/fm-wake-resident.sh status
```

`enable` records the config, wires and registers both shims, and creates the inbox directory.
`sync` re-converges everything and runs at every session start from bootstrap, so a home that gains its shim after the secondmate's first spawn self-heals.
`disable` removes the record and both shims and touches nothing else - a disabled wake-resident secondmate is an ordinary secondmate again, with its home and state intact.

The secondmate's own charter has to say it is wake-resident, because the agent needs to know that a fresh start is normal rather than lost context, and that it should keep its supervision cycle live while resident so the `wake-self` shim can reach it.
`bin/fm-brief.sh --secondmate --wake-resident` scaffolds that clause; `secondmate-provisioning` owns applying it to an already-seeded home.

## Verification

2026-09-02, this branch:

```
$ bash tests/fm-wake-resident.test.sh | grep -c '^ok - '
33
```

The suite drives the real `fm-wake-resident.sh` and `fm-wake-resident-poll.sh` against a format-aware fake tmux whose pane can be posed as a live agent, a bare shell, or an unreadable interpreter, with the launch and the keystroke stubbed through `FM_ROOT_OVERRIDE`; that pane can also be posed mid-turn with a rendered busy footer, and the last case drives the `fm_wr_confirmed_busy` predicate itself against a stubbed backend registry and capture.

The cases, in order: inert with no config; both shims wired and registered; one throttled raise line for a dormant secondmate with mail; a resident secondmate's mail left to its own shim until `grace-secs`; the in-home shim surfacing a pending entry; the first message raising a seeded home that has never been launched and so has no metadata yet; a raise going through `fm-spawn.sh <name> --secondmate` and nothing else; two wakes producing exactly one advisor, both simultaneously and sequentially; a raise refused on an inconclusive liveness read; **no stand-down with work in flight, with or without `--force`**; no stand-down with an unanswered message; no stand-down before the quiet threshold; **a stand-down of an already-self-exited agent recording dormancy with no pane submission while leaving the home, lease, meta, backlog, status and registry intact**, and that same self-exited path still refusing work in flight and an unanswered message before it can succeed; a stand-down whose exit command is refused by a pane that immediately re-reads as a bare shell recorded as a completed stand-down (the agent exited inside the classifier's settle window, after the liveness read), while a send failure against a still-resident agent stays a failure and records nothing; **an idle stand-down leaving the treehouse lease, the home, `state/<name>.meta`, the backlog, the status file and the registry entry byte-identical**; a mate whose pane still renders a busy footer past the quiet threshold refused the stand-down offer while an otherwise identical world with a quiet pane is offered one; the persistence invariant catching a removed identity marker, a truncated backlog and a removed home while treating an appended status line as normal growth; the next message waking it again; a refusal on a harness with no submittable exit; leaving the agent alone when its exit never confirms; `disable` removing the wiring and nothing else; silence in away mode; unsafe, malformed and duplicate records dropped; **the liveness sweep leaving a dormant wake-resident secondmate asleep** (with a control case proving the same fixture without a record IS respawned); **both nudge predicates dropping a dormant wake-resident home, keeping a resident one, bootstrap's guard alone refusing a bare shell an ordinary secondmate left behind, neither skip touching a remote endpoint, and a dead verdict from a harness with no verified classifier still nudged**; the executable exit-command table agreeing with `harness-adapters`; and `fm_wr_confirmed_busy` never trusting Herdr's registry `idle` for a pane-typed agent - it reads the pane's own busy footer instead, still confirms busy even when the registry signal is lost entirely, leaves a genuinely quiet pane not confirmed busy, and short-circuits only on a trusted native busy from a Herdr-detected harness ([`herdr-backend.md`](herdr-backend.md#restart-and-liveness-behavior) owns that trust rule).
The dormant-wake-resident skip is also proven end to end against the real `bin/fm-update.sh` in `tests/fm-update.test.sh` (T12): the home fast-forwards, is reported on its own `nudge-skipped:` line, and is dropped from `nudge-secondmates:` while a live sibling is still listed.
