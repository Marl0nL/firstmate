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

When the captain replies inside a thread, the message they replied to is the
context that makes the reply intelligible ("is it green?" only means something
next to the message it answers).

The primary source of that context is the backend, with no network read.
The `local-agents-chat` subprocess agent now forwards the TRUE replied-to/quoted
message and the sender's display name to the relay as `LOCAL_AGENTS_*` env vars -
a compact `LOCAL_AGENTS_CONTEXT_JSON` blob (`{sender_display_name,
space_display_name, quoted_message}`) plus the convenience scalars
`LOCAL_AGENTS_SENDER_DISPLAY_NAME`, `LOCAL_AGENTS_QUOTED_TEXT`,
`LOCAL_AGENTS_QUOTED_SENDER`, `LOCAL_AGENTS_QUOTED_NAME`.
So for the common Reply/Quote case the relay stashes the exact quoted message
directly, without any Chat API read.
`bin/fm-crowsnest-relay.sh` prefers the JSON blob (scalars as fallback) and, when
a quote is present, writes it into the inbox entry as:

- `sender_display_name` - the captain's display name (the subprocess agent otherwise forwards only the opaque `users/<id>`); set for any forwarded message, quote or not.
- `quoted` - the true quoted-message metadata `{name, quote_type, snapshot: {text, formatted_text, sender, create_time}}` (only the present sub-fields), carrying the exact message the captain replied to.
- `reply_to` - the accurate replacement for the old best-effort guess: `{sender, sender_display_name, text, create_time}` built from the quote's inline text, whenever the quote carries it.

A message with no quote adds none of `quoted`/`reply_to` and is stashed exactly
as before, and a falsey `CROWSNEST_THREAD_CONTEXT` reverts the relay to text-only
stashing.

Two cases still need a read, so after stashing the base entry and enqueueing the
wake the relay spawns `bin/fm-crowsnest-context.sh` DETACHED (the instant ack is
never gated on a network read), reusing the backend `ChatClient`'s own
credentials via `bin/fm_crowsnest_chat.py`:

- Name-only quote (the report's F4 case): when the backend forwarded a quoted message `name` but no inline text, the helper hydrates it with a single authenticated `spaces.messages.get(name)` - which, unlike `list`, accepts the `chat.bot` scope this token carries - and fills in the quote's `snapshot` and `reply_to`. An inline quote is already authoritative, so no read is spawned for it.
- No quote at all: the helper falls back to a best-effort `spaces.messages.list` for the thread and merges a bounded, oldest-first `thread_context` (a list of `{sender, sender_display_name, text, create_time}`, the just-received message de-duplicated out). This `chat.bot`+`list` read is KNOWN-BROKEN - `spaces.messages.list` no longer accepts the `chat.bot` scope, so it 403s and this path is a near-total no-op today; it is retained only as best-effort for the no-quote case.

Everything about the read half is best-effort and additive.
The durable base entry and the wake are written first, so a failed or slow read
never loses a message; if the read fails for any reason - no thread, no
interpreter, no backend, no credentials, no scope, a network error - the entry
keeps whatever the relay already stashed and the Crowsnest behaves precisely as
it did before context existed.
Enrichment is on by default and switched off with a falsey
`CROWSNEST_THREAD_CONTEXT` (which disables both the forwarded stash and the read).
Bounds are tunable via `FMC_CONTEXT_LIMIT` (messages, default 10),
`FMC_CONTEXT_MAXCHARS` (per-message truncation, default 1200), and
`FMC_CONTEXT_TIMEOUT` (read seconds, default 20).
`FMC_CONTEXT_SYNC` forces the enrichment to run inline instead of detached, for
deterministic tests and debugging; `FMC_CONTEXT_FIXTURE` feeds the reader a
canned `spaces.messages.list` response and `FMC_GET_FIXTURE` a canned
`spaces.messages.get` message, so the whole path is exercised offline.

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
| `bin/fm-crowsnest-context.sh` | The read half's dispatcher: hydrates a name-only forwarded quote via `spaces.messages.get`, or falls back to the best-effort thread `list`, and merges the result into the inbox entry. Spawned detached by the relay (never for an already-inline quote) so the ack stays instant. |
| `bin/fm-crowsnest-context.py` | The read transport: `--get-message` hydrates one quoted message (`get` accepts `chat.bot`); `--space`/`--thread` is the best-effort thread `list` (known-broken on `chat.bot`). Reuses the `ChatClient` credentials. |
| `bin/fm_crowsnest_chat.py` | Shared transport helper: imports the backend and resolves its config + credentials one way for both the post and context tools. |
| `bin/fm-crowsnest.sh` | Operator lifecycle CLI: `enable`, `disable`, `register`, `unregister`, `autostart`, `status`. |
| `.agents/skills/fmc-respond` | Agent-only operating reference: how the live session handles a `chat-mention` wake and posts back. |

## Runtime state (all gitignored under `state/`)

- `state/chat-inbox/<id>.json` - a pending message: `{id, space, thread, sender, mode, text, received_epoch}`. Present = pending; the live session removes it after answering. Thread and reply context (above) may add the optional `sender_display_name`, `quoted`, `reply_to`, and `thread_context` fields; treat them as absent-by-default.
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
- Thread and reply context is exercised offline in `tests/fm-crowsnest.test.sh`
  with no network or GCP: the relay's forwarded-quote stash is env-driven, the
  name-only get-hydrate uses `FMC_GET_FIXTURE` (a canned `spaces.messages.get`
  message), and the best-effort thread `list` uses `FMC_CONTEXT_FIXTURE` (a canned
  `spaces.messages.list` response); `FMC_CONTEXT_SYNC=1` runs enrichment inline
  instead of detached.
- The common Reply/Quote case needs no live read: the backend forwards the true
  quoted message, so reply context is accurate offline and in DMs/private threads.
- The best-effort thread `list` read is known-broken: `spaces.messages.list` no
  longer accepts the `chat.bot` scope the `ChatClient` mints, so it 403s and the
  no-quote enrichment path simply no-ops, leaving the entry with whatever the
  relay already stashed (see the report's Gap 3).
