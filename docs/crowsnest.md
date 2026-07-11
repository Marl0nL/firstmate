# The Crowsnest: a two-way Google Chat <-> live-firstmate relay

The Crowsnest lets the captain reach the LIVE firstmate session from a Google
Chat thread, and lets firstmate post back, without spawning a second agent that
would compete with the live session for fleet control.
It is committed firstmate infrastructure, inert until explicitly enabled, and it
reuses the `local-agents-chat` backend (the package is being renamed from
`local-agents`; the Crowsnest resolves the CLI and module name at runtime so it
works across the rename).

It is the Google Chat analogue of X mode (see `docs/configuration.md` "X mode
(.env)"): a message becomes a WAKE that the one live firstmate session handles on
its own turn.
The single-threaded supervision guarantee is the whole point.
A chat message never launches a parallel fleet-aware agent in the firstmate home.

## The reply model: async ack, then the real answer

1. A Google Chat message routed to the `firstmate` agent runs the thin relay
   `bin/fm-crowsnest-relay.sh` as a backend subprocess.
   The relay stashes the message and returns an immediate acknowledgement ("on
   it, captain") as its stdout, which the backend posts straight back to Chat.
2. The relay does NOT answer.
   It enqueues the message as a wake for the live firstmate session.
3. Firstmate composes the real answer from live fleet state on its own turn and
   posts it back into the originating space/thread.

This async model (immediate ack, then a full reply when firstmate has composed
it) was chosen over a blocking reply so the backend's per-request timeout never
gates on firstmate's actual work.

## Thread and reply context

When the captain replies inside a thread, the earlier messages are the context
that makes the reply intelligible ("is it green?" only means something next to
the message it answers).
The `local-agents-chat` subprocess agent forwards only the message text plus
`space`/`thread`/`sender` - never the replied-to message, the raw event, or any
prior history - so the relay alone cannot see that context.
The Crowsnest recovers it by reading the thread back from the Chat API.

After the relay has durably stashed the base inbox entry and enqueued the wake,
it spawns `bin/fm-crowsnest-context.sh` DETACHED (so the instant ack is never
gated on a network read).
That helper issues an authenticated `spaces.messages.list` for the thread -
reusing the backend `ChatClient`'s own credentials via `bin/fm_crowsnest_chat.py`
- and merges the recent messages into the inbox entry as:

- `thread_context` - a bounded, oldest-first list of `{sender, sender_display_name, text, create_time}` (the just-received message is de-duplicated out).
- `reply_to` - the most recent prior message in the thread (best-effort; the true quoted-message metadata is not forwarded by the backend, so this is "the last thing said before the captain's message").
- `sender_display_name` - the captain's display name, harvested from the thread listing (the subprocess agent only forwards the opaque `users/<id>`).

Everything about this is best-effort and additive.
The durable base entry and the wake are written first, so a failed or slow read
never loses a message; if the read fails for any reason - no thread, no
interpreter, no backend, no credentials, no scope, a network error - the entry
is left exactly as it was and the Crowsnest behaves precisely as it did before
context existed.
Enrichment is on by default and switched off with a falsey
`CROWSNEST_THREAD_CONTEXT`.
Bounds are tunable via `FMC_CONTEXT_LIMIT` (messages, default 10),
`FMC_CONTEXT_MAXCHARS` (per-message truncation, default 1200), and
`FMC_CONTEXT_TIMEOUT` (read seconds, default 20).
`FMC_CONTEXT_SYNC` forces the enrichment to run inline instead of detached, for
deterministic tests and debugging; `FMC_CONTEXT_FIXTURE` feeds the reader a
canned `spaces.messages.list` response so the whole path is exercised offline.

## Posting credentials

Both the post tool and the context reader authenticate as the Chat app exactly
the way the running backend does, resolved once in `bin/fm_crowsnest_chat.py`.
When no `--config` / `CROWSNEST_LA_CONFIG` is given they fall back to the
backend's DEFAULT config path (`~/.config/local-agents/config.toml`), so
`gcp.credentials_path` (the Chat app's service-account key) is actually read and
posts go out as the app.
`LOCAL_AGENTS_CREDENTIALS_PATH` and `GOOGLE_APPLICATION_CREDENTIALS` still
override, mirroring the backend.
This is the fix for the 403 ("insufficient authentication scopes") that used to
require manually exporting `GOOGLE_APPLICATION_CREDENTIALS` before a reply would
post: the tool previously passed no config path, so it read no credentials and
silently fell back to user ADC.
`bin/fm-crowsnest.sh status` now prints a `posting id` line (from the same
resolution) so an operator can see at a glance whether posts will use the
service account or fall back to ADC.

## Components

| Artifact | Role |
| --- | --- |
| `bin/fm-crowsnest-lib.sh` | Shared config resolution, inbox helpers, and the check-shim wiring; sourced, never executed. |
| `bin/fm-crowsnest-relay.sh` | The command registered as the `firstmate` agent. Stashes the message, enqueues a durable wake, returns the ack. Never spawns an agent. |
| `bin/fm-crowsnest-poll.sh` | The watcher check-shim body. Surfaces the oldest pending inbox entry as a `chat-mention <id>` line. Inert unless enabled. |
| `bin/fm-crowsnest-post.sh` | The post-back and reverse channel: reply to a pending message, or post proactively into any space/thread. Dry-run capable. |
| `bin/fm-crowsnest-post.py` | The transport half of the post tool; reuses the backend's own `ChatClient` (no reinvented OAuth). |
| `bin/fm-crowsnest-context.sh` | Best-effort thread-context enrichment: reads recent thread messages back and merges them into the inbox entry. Spawned detached by the relay so the ack stays instant. |
| `bin/fm-crowsnest-context.py` | The read half of enrichment; issues the authenticated `spaces.messages.list` for the thread reusing the `ChatClient` credentials. |
| `bin/fm_crowsnest_chat.py` | Shared transport helper: imports the backend and resolves its config + credentials one way for both the post and context tools. |
| `bin/fm-crowsnest.sh` | Operator lifecycle CLI: `enable`, `disable`, `register`, `unregister`, `autostart`, `status`. |
| `.agents/skills/fmc-respond` | Agent-only operating reference: how the live session handles a `chat-mention` wake and posts back. |

## Runtime state (all gitignored under `state/`)

- `state/chat-inbox/<id>.json` - a pending message: `{id, space, thread, sender, mode, text, received_epoch}`. Present = pending; the live session removes it after answering. Thread-context enrichment (below) may add the optional `thread_context`, `reply_to`, and `sender_display_name` fields; treat them as absent-by-default.
- `state/chat-outbox/<id>.json` - a dry-run record of a would-be post (only when `CROWSNEST_DRY_RUN` is set).
- `state/chat-watch.check.sh` - the generated watcher check shim that execs `bin/fm-crowsnest-poll.sh`. Written when enabled, removed when disabled.
- `state/chat-poll.error` - a one-line relay diagnostic (missing `jq`, an inbox write failure); cleared on the next healthy relay.
- `state/chat-backend.log` - the backend's own log when started via `autostart`.

## The wake path

The relay enqueues a durable `check` wake (`fm_wake_append check "chat-inbox"
"chat-mention <id>"`) so a message survives a watcher gap or a firstmate restart:
the queue is drained at session start and at the top of every wake-handling turn.
The check shim `state/chat-watch.check.sh` is the ACTIVE waker: on each watcher
check cycle it prints the oldest pending `chat-mention <id>`, which the watcher
turns into a `check:` wake that ends the current supervision wait.
Both paths lead to the same handler, which drains the whole inbox, so a duplicate
or already-handled wake is a cheap no-op.
This is purely additive to the watcher: no change is made to `bin/fm-watch.sh`,
`bin/fm-watch-arm.sh`, or `bin/fm-wake-lib.sh`, exactly like X mode.

### Latency and cadence

The watcher runs check shims every `FM_CHECK_INTERVAL` seconds (default 300).
The async ack hides that latency from the captain, and the full reply lands on
the next check cycle.
An instance that also runs X mode already polls at 30s (via `config/x-mode.env`),
so its chat replies are correspondingly fast; a Crowsnest-only instance that
wants faster idle-fleet replies can lower `FM_CHECK_INTERVAL` for its watcher.
The Crowsnest deliberately does not introduce its own cadence file, to keep the
supervision-cadence contract single-owner.

## Enabling

The Crowsnest is presence-gated on `config/crowsnest.env` (local, gitignored)
with a truthy `CROWSNEST_ENABLED`, so a home with no such config sees zero
behaviour change.
Copy `docs/examples/crowsnest.env` to `config/crowsnest.env` and run:

```sh
bin/fm-crowsnest.sh enable            # wire the shim + register the agent
bin/fm-crowsnest.sh enable --autostart # also start the backend if it is down
bin/fm-crowsnest.sh status            # inspect resolved config and live state
bin/fm-crowsnest.sh disable           # unwire, unregister, turn off
```

`enable` persists `CROWSNEST_ENABLED=1`, wires the check shim, and registers the
`firstmate` agent whose launch command is the relay with this home baked in
(`env FM_HOME=<home> <root>/bin/fm-crowsnest-relay.sh`).
Registration and autostart are the only steps that reach outside this home, so
bootstrap never performs them automatically; bootstrap only wires/unwires the
local check shim (the `CROWSNEST:` line in the session-start digest).

### Config keys (`config/crowsnest.env`)

| Key | Default | Meaning |
| --- | --- | --- |
| `CROWSNEST_ENABLED` | (off) | Truthy turns the Crowsnest on. The presence gate. |
| `CROWSNEST_AGENT_NAME` | `firstmate` | The agent name people target from Chat. |
| `CROWSNEST_ACK` | "On it, captain ..." | The immediate acknowledgement text. |
| `CROWSNEST_LA_CLI` | resolved | Override the local-agents(-chat) CLI path. |
| `CROWSNEST_LA_CONFIG` | backend default | Path to the backend `config.toml` (registry + credentials). |
| `CROWSNEST_PYTHON` | resolved | Override the interpreter that imports the backend. |
| `CROWSNEST_THREAD_CONTEXT` | (on) | Falsey turns off thread-context enrichment; the relay then stashes text only. |
| `CROWSNEST_DRY_RUN` | (off) | Truthy makes `fm-crowsnest-post.sh` record to the outbox instead of posting. |

## Posting back and the reverse channel

```sh
# Reply to a pending chat message (the common case; fmc-respond drives this):
bin/fm-crowsnest-post.sh --reply <id> --text-file <path>

# Proactive post into any space/thread (e.g. an away-mode escalation):
bin/fm-crowsnest-post.sh --space spaces/AAA --thread spaces/AAA/threads/T --text-file <path>
```

Both reuse the backend's `ChatClient.create_message` (`spaces.messages.create`
as the `chat.bot` app), with a threaded reply setting `thread.name` plus
`messageReplyOption`.
The reply tool does not remove the inbox entry on success; that cleanup belongs
to the live session after the reply is confirmed, mirroring how `fmx-respond`
owns `x-inbox` cleanup.

## Verification

- Hermetic behaviour tests: `tests/fm-crowsnest.test.sh` (relay, poll, post
  dry-run, lib, lifecycle against a fakebin CLI, bootstrap activation).
- Offline end-to-end against the real backend, no GCP: register the agent into an
  isolated registry, then replay a Chat event and confirm the backend runs the
  relay and returns the ack:

  ```sh
  local-agents-chat --config <isolated.toml> replay <chat-event.json>
  ```

  Observed 2026-07-10 with `local-agents-chat` (pipx): the backend dispatched to
  the `firstmate` agent, the relay stashed `state/chat-inbox/<id>.json` and
  enqueued `chat-mention <id>`, and the backend posted the async ack into the
  thread.
- Live posting requires the backend's `cloud` extra and GCP credentials; the
  dry-run path (`CROWSNEST_DRY_RUN=1`) exercises the full compose-and-record loop
  without them.
- Thread-context enrichment is exercised offline with `FMC_CONTEXT_FIXTURE` (a
  canned `spaces.messages.list` response) plus `FMC_CONTEXT_SYNC=1` (inline
  instead of detached), so the reader, the merge, and the relay's enrichment path
  all run in `tests/fm-crowsnest.test.sh` with no network or GCP.
- Live context read requires the bot's credentials to be authorized to list
  messages in the space; when they are not, the read 403s and enrichment simply
  no-ops, leaving the entry as text-only.
