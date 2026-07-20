# Boot autostart: bringing firstmate up with no human

`bin/fm-autostart.sh` starts the firstmate agent inside an already-running herdr server, over herdr's socket API, with nobody at the keyboard.
`assets/systemd/firstmate-autostart.service` is the user unit that runs it at boot.
This document owns the install, rollback, and verification steps; the script's own header owns its flags, exit codes, and decision rules.

## The gap it closes

`herdr-server.service` already starts at boot and needs no help: linger brings up `user@1000.service` without a login, and the server follows a second later.
But `herdr server` is **headless**, and pane resurrection is client-side work.
herdr says so in its own boot log:

```
did you mean to open the Herdr TUI? run 'herdr'; you do not need 'herdr server'
```

So boot produced a server with zero panes and no firstmate.
The fleet stayed dark - no supervision, no wake handling, nothing - until a human ran `herdr` and attached.
That is the last manual step between a reboot and a working fleet, and this unit removes it.

The mechanism is `herdr agent start`, which materialises an agent over the socket API with no TUI and no attached client.

## What it does

On start, the script:

1. Resolves the firstmate home and refuses to continue unless it structurally looks like one (`AGENTS.md` plus an executable `bin/fm-spawn.sh`).
2. **Polls** `herdr status server` until the server reports running and protocol-compatible, bounded by `--timeout` (120s in the shipped unit).
   `After=herdr-server.service` orders the unit after the server *process* starts, which is not the same as the socket being answerable; a fixed `sleep` would be a guess in both directions.
   On timeout it exits non-zero and prints the last status it saw, so the journal records *why*.
3. Asks whether a firstmate is already **running** - a listed agent that is confirmed live, not merely a record - and **exits 0 as a no-op if one is**.
   The no-op deliberately needs no network: a downed network must not turn "nothing to do" into a failed unit.
4. **Waits for a genuinely usable network** - the gate described below - bounded by `--net-timeout`, and exits 5 having started nothing if it never comes up.
5. Only then starts one:

```
herdr agent start firstmate --cwd /var/home/marlon/firstmate --no-focus -- \
  claude --dangerously-skip-permissions --remote-control --continue
```

6. Confirms the agent actually appears in the agent list **with a real process behind its pane** before reporting success.
   A created pane is not a started agent, and a replayed record is not a process.

### The network gate: no agent on a dead network

The agent registers with Anthropic's remote-control service the moment it launches.
On 2026-07-20 two consecutive reboots launched claude 4-5 seconds **before** `network-online.target`, and on the second the agent came up locally fine but never appeared in the Claude app's remote-control list - and never self-healed, even with the network up for many minutes afterwards.
The captain's decision: there is no point running an agent without the network, so wait for it, and extra boot delay is acceptable.

The gate's decisive probe is a bounded HTTPS request to `https://api.anthropic.com/` (curl `--max-time 5`), because that is the dependency registration actually has: DNS resolution, a route, TCP, and TLS to Anthropic's endpoint.
The captain's suggested `ping 8.8.8.8` is implemented, but as a **diagnostic**, not the gate: a ping proves only routing (not DNS or the endpoint), ICMP is filtered on many networks, and `ping` may not be installed - so a failed ping must never wedge boot, and a successful ping must never green-light it.
When the gate fails, the journal says which layer looks broken: "routing is up, so the failure is DNS/TLS/reachability of api.anthropic.com" versus "no ICMP reply either".
Without curl the probe falls back to a `timeout`-bounded `/dev/tcp` connect to `api.anthropic.com:443` (DNS + TCP, no TLS); with no bounded probe possible at all the gate fails closed rather than hanging or starting blind.
Every path is bounded: `--net-timeout` (default 120s) caps the wait, and the unit's `TimeoutStartSec` is sized above the sum of all three waits.
`--skip-net-check` exists for a deliberately offline start.

The unit also carries `Wants=network-online.target` and `After=network-online.target`.
Know what those lines can and cannot do: they order against the **user** manager's `network-online.target`, and a user manager typically has no provider for it - verified on the captain's host 2026-07-20 (`systemctl --user list-unit-files 'network*'` lists nothing, and the target is permanently inactive) - because a user unit cannot order against system targets.
So on this host they are inert, and the script's own gate is the mechanism that actually enforces "network before agent".
The lines ship anyway: they are harmless, self-documenting, and engage on any host that does provide a user-scope target.

### Never a second firstmate

This is the sharp edge, not a nicety.
Two firstmates on one home fight over the session lock and the fleet, which is strictly worse than no autostart at all.
So every uncertainty resolves to *do not start*: a server that never becomes ready, an agent list that cannot be read, an unrecognised response shape, a matching agent whose pane cannot be classified - all exit non-zero having started nothing.
The only path that starts an agent is one where the server answered and the answer positively contained no firstmate.

"A firstmate is already running" is two tests, and an agent-list entry alone satisfies neither.

**First, does the entry match this home?**
Either it is an agent named `firstmate`, or its working directory is the firstmate home.
The second half is the load-bearing one.
`name` is absent or null for every agent not created through `agent start <name>` - which includes the firstmate the captain launched by hand and any pane herdr resurrected - so name matching alone would cheerfully start a duplicate right next to the live one.

**Second, is the matching entry actually alive?**
This half was missing when the script first shipped, and its absence made the whole unit a silent permanent no-op.
herdr persists its session layout in `~/.config/herdr/session.json`, so after a reboot `agent list` **replays records for agents that are not running** - full entries carrying `agent`, `cwd`, `pane_id` and an `agent_status` of `idle`.
The guard matched one of those ghosts, printed `firstmate is already up`, and started nothing, at every boot.

So a match is now confirmed against the pane it claims, through the **reality-touching** probes `bin/backends/herdr.sh` owns for the whole fleet - and only those:

| Question | Owner | Must answer |
| --- | --- | --- |
| Is there a real process behind the pane? | `fm_backend_herdr_pane_process_state` | `live` |
| Where does that process really run (cwd-matched entries only)? | `fm_backend_herdr_pane_process_cwds` | some process cwd resolves to the firstmate home |

Only `pane process-info` reaches an actual process.
A ghost passes `pane get` **and** `agent get` intact, because those replay from the same persisted layout the list came from, and process-info answers `pane_not_found` for it.
Verified live on the captain's host on 2026-07-20 (herdr 0.7.4, protocol 16): two listed `idle` agents claimed the firstmate home while the machine held exactly one claude process, and neither of those panes had a process behind it.

`agent get`'s `agent_status` is deliberately **not** consulted, because on herdr 0.7.4 it is miscalibrated: a genuinely live, registered, captain-serving firstmate reports `agent_status: "unknown"` - verified live 2026-07-20 against the running firstmate itself (`herdr agent get w1:p2R`).
Requiring a "real" status made the unit declare both of that day's working boots failures (`started the agent but it never appeared in the agent list within 20s`, exit 4, `status=4/NOPERMISSION` in systemd) while the started firstmate was already serving the captain, and made the already-up no-op exit 3 instead of 0.
A unit that cannot tell a working boot from a broken one is worse than cosmetically wrong: the captain cannot distinguish a real failure from a fake one, and any future retry-on-failure would ask for a second supervisor.

The name-matched and cwd-matched halves need different identity evidence.
A **name** match is strong on its own - only `agent start firstmate` produces it, and herdr's server-global name registry refuses to register the name twice - so a live process behind a name-matched pane is the firstmate.
A **cwd** match came from replayable metadata, so the process itself must corroborate it: some foreground process must really work in the firstmate home per the kernel's `cwd` in `pane process-info`.
A live process that cannot be tied to the home is *unknown*, not a husk - it may be the firstmate mid-tool-call, with a child momentarily fronting the process group from another directory - and unknown refuses to start rather than duplicating.

A confirmed husk - no process behind the pane - simply does not count, and the scan continues; another entry may still be the real firstmate.
Anything that cannot be classified, including a matching entry that names no pane at all, is unknown, and unknown still starts nothing and exits 3.

One limit worth knowing: this guard sees only agents herdr knows about.
A firstmate running outside herdr entirely is invisible to it.
That is safe at boot, when nothing else is up yet, and firstmate's own session lock remains the backstop in every other case.

### The first unattended boot came up read-only

The first boot this unit actually completed produced a firstmate that was alive but could not supervise anything: it refused its own session lock and dropped into read-only mode, so it could not spawn, steer, merge, or arm a watcher.

`bin/fm-lock.sh` identifies the harness by walking the shell's process ancestry.
This unit launches through `~/.local/bin/claude`, which on a shim-installed home is `bin/fm-claude-shim.sh`, and the shim `exec`s the real versioned binary under `~/.local/share/claude/versions/<version>` (see [claude-resume-shim.md](claude-resume-shim.md)).
A process `exec`ed from that path reports the **version number** as its command name, so the ancestry walk saw nothing it could name.
Observed on the captain's host, 2026-07-20:

```
7491 comm=bash     args=/bin/bash -c source ~/.claude/shell-snapshots/...
2026 comm=2.1.215  args=/home/marlon/.local/share/claude/versions/2.1.215 --dangerously-skip-permissions --remote-control --continue
1775 comm=herdr    args=/var/home/marlon/.local/bin/herdr server
1741 comm=systemd
```

It had never been seen before because resuming by hand went through `claude-real`, whose command name matches directly; the shim path is the first launch that reaches the versioned binary, and boot autostart always takes it.

`fm-lock.sh` now also identifies a harness by `argv[0]` when it points into a `<harness>/versions/<version>` install directory, and its header owns that rule.
The matching is anchored to the executable and never to the arguments, because a tool call's transient shell carries `~/.claude/...` in its command line: matching that would write a subshell pid as the lock holder, dead moments later.
`tests/fm-lock.test.sh` covers both halves.

Two refusals reach the caller as distinct exit codes, because they demand opposite responses: another live session really holds the lock, versus this session cannot identify itself and nobody holds anything.
Both stay read-only, and `bin/fm-session-start.sh`'s banner names which one happened rather than sending the captain looking for a competing session that does not exist.

Path spellings are resolved to physical paths before comparison.
On this ostree Fedora `/home` is a symlink to `/var/home`, so the same home has two spellings and herdr may report the one the unit did not pass; a string compare would miss the live firstmate and duplicate it.
That is the same aliasing that bit firstmate twice before (see `data/learnings.md`, 2026-07-16).

### Why `--continue` and not `--resume <id>`

`--continue` restores the most recent conversation *in that working directory*, so it keeps working across session-id churn - every new session, every fresh start, every compaction.
A pinned `--resume <session-id>` goes stale the first time the id changes, and it fails at boot, which is exactly when no human is present to notice or repair it.
The failure modes are asymmetric: `--continue` at worst resumes a conversation slightly older than intended, while a stale `--resume` yields no firstmate at all.

### Why the launch flags are passed explicitly

`--dangerously-skip-permissions` and `--remote-control` are passed on the command line rather than left to `bin/fm-claude-shim.sh`, so autostart works on a home that never installed the shim.
Injection is idempotent, so passing them is equally safe on a home that did (see [claude-resume-shim.md](claude-resume-shim.md)).

## Install

The unit ships as a **template** and is never installed automatically: putting a supervisor on the boot path is a deliberate captain step.
`__FM_ROOT__` in the template is a placeholder, not a shell variable.

The template sets its own `PATH` (`%h/.local/bin` plus the system directories, expanded by systemd), because a systemd user unit does not inherit a login shell's PATH and `herdr` lives in `~/.local/bin`.
An earlier install worked only because that line had been added to the installed copy by hand; the template now carries it, so a fresh render no longer regresses to `herdr not found on PATH` (`data/learnings.md`, 2026-07-20).

Re-running the install over an existing unit is the intended upgrade path: re-render (step 1), verify (step 2), then `systemctl --user daemon-reload` picks up the change; the idempotence guard makes the immediate re-run in step 4 a no-op while a firstmate is live.

Every command below uses absolute literal paths on purpose.
A step that depends on a shell variable silently produces a broken path when re-run in a fresh shell - that is exactly how the 2026-07-20 dangling-symlink outage happened (`data/learnings.md`).
Substitute your own firstmate home if it is not `/var/home/marlon/firstmate`, but substitute a **literal path**, never a variable.

```sh
# 1. Render the template into the user unit directory, replacing the placeholder
#    with the absolute firstmate home.
mkdir -p /var/home/marlon/.config/systemd/user
sed 's|__FM_ROOT__|/var/home/marlon/firstmate|g' \
  /var/home/marlon/firstmate/assets/systemd/firstmate-autostart.service \
  > /var/home/marlon/.config/systemd/user/firstmate-autostart.service

# 2. Prove the rendered unit is valid and carries no leftover placeholder
#    BEFORE enabling it.
grep -n '^ExecStart=\|__FM_ROOT__' /var/home/marlon/.config/systemd/user/firstmate-autostart.service
systemd-analyze --user verify /var/home/marlon/.config/systemd/user/firstmate-autostart.service

# 3. Dry-run the script itself against the live server. It starts nothing; it
#    only reports what it would decide. Expect "already up" while a firstmate is
#    running, or the exact command it would run if none is.
/var/home/marlon/firstmate/bin/fm-autostart.sh --dry-run

# 4. Enable for boot, and run it once now.
systemctl --user daemon-reload
systemctl --user enable --now firstmate-autostart.service
```

Step 2 must print an `ExecStart` line with a real absolute path and **no** `__FM_ROOT__` match, and `systemd-analyze` must print nothing.
If it still shows the placeholder, stop: the `sed` did not apply, and enabling that unit would only produce a failed unit at every boot.

`systemd-analyze` also resolves the `ExecStart` path, so it fails with `is not executable: No such file or directory` if the firstmate home does not yet carry `bin/fm-autostart.sh`.
That is the check working, not a false alarm: update the home first, then re-run step 2.

`--now` in step 4 is safe while firstmate is already running: the idempotence guard makes it a no-op.
That is the point - enabling mid-session must not disturb the live fleet.

## Rollback

```sh
systemctl --user disable --now firstmate-autostart.service
rm -f /var/home/marlon/.config/systemd/user/firstmate-autostart.service
systemctl --user daemon-reload
```

One caveat worth knowing before running that with a live firstmate.
The agent is spawned by the herdr **server**, not as a child of `ExecStart`, so stopping this oneshot unit is expected to leave the running firstmate alone.
That expectation is unverified: confirming it requires starting a real agent through the unit, which would create a second supervisor on a machine that already has one, so it was deliberately not tested.
If you want zero risk of disturbing a live firstmate, drop the `--now`:

```sh
systemctl --user disable firstmate-autostart.service
```

That removes it from the boot path without stopping anything.
To check the expectation for yourself after the unit has genuinely started an agent, compare the cgroups - the agent should sit under `herdr-server.service`, not under `firstmate-autostart.service`:

```sh
systemctl --user status firstmate-autostart.service
systemd-cgls --user-unit herdr-server.service
```

## Verification

The real test is a reboot with no human action:

```sh
# 1. Reboot, then wait for the desktop and do NOT run `herdr` or attach.

# 2. The unit ran and stayed active (oneshot + RemainAfterExit).
#    Expect "active (exited)" and an ExecStart status of 0.
systemctl --user status firstmate-autostart.service

# 3. What it decided, in its own words: either it started firstmate, or it found
#    one already up. On a start, expect "network gate passed: api.anthropic.com
#    reachable after Ns" BEFORE "starting one", then "firstmate is up".
journalctl --user -u firstmate-autostart.service -b

# 4. A firstmate agent exists in the headless server, with no client ever
#    attached. Note its pane_id.
herdr agent list

# 5. The proof. `agent list` alone is NOT proof: it replays records for agents
#    that are not running. Ask for the pane's actual process instead - it must
#    return a real foreground_process_group_id and a claude argv.
herdr pane process-info --pane <pane_id>

# 6. Only now attach and confirm the pane is a live firstmate.
herdr
```

Step 5 is the one that matters, and step 4 alone is the trap.
`agent list` talks to the server over the socket, so a firstmate showing up there before any attach is the gap this unit closes - but a post-reboot list also replays ghost records for agents that are not running, which is precisely what once fooled the guard.
Only `pane process-info` distinguishes the two.

For the behavioural contract, `tests/fm-autostart.test.sh` drives the script against a fake `herdr`, a fake `curl`, and a fake `ping`, and covers the bounded readiness wait, the timeout path, the network gate (bounded, polled, exit 5, ICMP-filtered, late-arriving network, offline no-op and dry run), the idempotence guard by name, by working directory, by `foreground_cwd`, and across aliased path spellings, the herdr 0.7.4 `agent_status: "unknown"` regression, the cwd identity guard, plus failing closed on an unreadable agent list.
It never contacts the real herdr server, never probes the real network, and never starts a real agent.

## Open question: can registration still fail with the network up?

The gate guarantees the network is genuinely usable - DNS, routing, TCP, and TLS to `api.anthropic.com` - at the moment claude launches, which removes the only mechanism the 2026-07-20 evidence actually demonstrated (launching 4-5s before `network-online.target`).
It is **not** proof that the app-visibility failure cannot recur: on both of that day's boots the race existed, yet only one boot came up invisible to the app, so the failure was nondeterministic and the exact mechanism inside claude's registration path is unobserved.
What would settle it: a boot whose journal shows `network gate passed` and which still comes up invisible in the app's agent list.
That outcome would point at claude's remote-control registration itself (no retry after a failed initial registration, or a server-side issue) and would justify an upstream report; until it is observed, no upstream bug should be asserted.
