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
4. Only then starts one:

```
herdr agent start firstmate --cwd /var/home/marlon/firstmate --no-focus -- \
  claude --dangerously-skip-permissions --remote-control --continue
```

5. Confirms the agent actually appears in the agent list before reporting success.
   A created pane is not a started agent.

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

So a match is now confirmed against the pane it claims, through the two classifiers `bin/backends/herdr.sh` owns for the whole fleet:

| Question | Owner | Must answer |
| --- | --- | --- |
| Does the pane exist and hold a registered agent? | `fm_backend_herdr_pane_agent_state` | `live` |
| Is there a real process behind it? | `fm_backend_herdr_pane_process_state` | `live` |

The second is not redundant.
A ghost passes `pane get` **and** `agent get` intact, because those replay from the same persisted layout the list came from; only `pane process-info` reaches an actual process and answers `pane_not_found`.
Verified live on the captain's host on 2026-07-20 (herdr 0.7.4, protocol 16): two listed `idle` agents claimed the firstmate home while the machine held exactly one claude process, and neither of those panes had a process behind it.

A confirmed husk - no pane, no agent, or no process - simply does not count, and the scan continues; another entry may still be the real firstmate.
Anything that cannot be classified, including a matching entry that names no pane at all, is unknown, and unknown still starts nothing and exits 3.

One limit worth knowing: this guard sees only agents herdr knows about.
A firstmate running outside herdr entirely is invisible to it.
That is safe at boot, when nothing else is up yet, and firstmate's own session lock remains the backstop in every other case.

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
#    one already up.
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

For the behavioural contract, `tests/fm-autostart.test.sh` drives the script against a fake `herdr` and covers the bounded readiness wait, the timeout path, the idempotence guard by name, by working directory, by `foreground_cwd`, and across aliased path spellings, plus failing closed on an unreadable agent list.
It never contacts the real herdr server and never starts a real agent.
