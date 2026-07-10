---
name: fmc-respond
description: >-
  Agent-only playbook for handling Crowsnest chat mentions - firstmate's two-way
  Google Chat bridge. Use on a "chat-mention <id>" check wake to drain the chat
  inbox, compose the real answer from live fleet state, and post it back into the
  originating space/thread. Also use to post proactively into a chat thread (the
  reverse channel), e.g. an away-mode escalation. Loaded only when the Crowsnest
  is enabled.
user-invocable: false
metadata:
  internal: true
---

# fmc-respond

The Crowsnest lets the captain reach the LIVE firstmate session from a Google
Chat thread, and lets firstmate post back.
A chat message arrives through the watcher as a `check:` wake whose payload is
`chat-mention <id>`.
The message was already acknowledged instantly ("on it, captain") by the thin
relay; this skill composes and posts the REAL answer from live fleet state, on
this one live session's own turn.

This runs only when the Crowsnest is on (`config/crowsnest.env` with a truthy
`CROWSNEST_ENABLED`; see AGENTS.md section 15 and `docs/crowsnest.md`).
If you ever see a `chat-mention` wake without the Crowsnest configured, do
nothing.

## The one rule that must never bend

The captain reaches the live session precisely so a chat message is handled by
the ONE firstmate that owns the fleet, not a parallel agent.
Never spawn a crewmate, secondmate, or any fleet-aware agent to "answer the
chat".
You compose the reply yourself, here, on this turn, exactly as you would answer
the captain in the terminal.
If answering needs project work (an investigation, a change), dispatch that work
through the normal lifecycle and reply with the outcome or a "looking into it"
per captain etiquette - but the chat REPLY itself is always composed and posted
by this live session.

## The asker is your captain - answer autonomously

The message came from the captain's own Chat.
Enabling the Crowsnest is the standing authorization to answer autonomously and
to take normal reversible lifecycle actions the message asks for.
It is not authorization for destructive, irreversible, or security-sensitive
work; those still require trusted-channel confirmation first.
Compose and post the reply yourself; never route a reply back through chat for
approval, and never stage a worthwhile reply for a chat-side OK.
Dry-run (`CROWSNEST_DRY_RUN`) is a testing switch, not a permission gate.

## Handling a `chat-mention` wake: drain the inbox

This is a drain over `state/chat-inbox/`, not a single reply.
Treat the inbox as the source of truth and process **every** `*.json` file you
find there, not just the `<id>` named in the wake (the wake is only the nudge;
the relay may have stashed several messages, and a duplicate wake is a no-op once
the inbox is empty).

For each `state/chat-inbox/<id>.json`:

1. **Read it.** The object carries `space`, `thread`, `sender`, `mode`, `text`,
   and `received_epoch`. `text` is the captain's message.
2. **Compose the answer from live fleet state**, in the captain-facing voice of
   AGENTS.md section 9: talk in outcomes, never firstmate internals (no crewmate,
   worktree, watcher, task-id, harness, or backend vocabulary), and address the
   captain at least once. Give full PR URLs, never bare `#numbers`. Google Chat
   renders simple markdown; keep it scannable.
3. **Post the reply** into the originating thread:

   ```sh
   printf '%s' "$reply" | bin/fm-crowsnest-post.sh --reply <id> -
   # or from a file:
   bin/fm-crowsnest-post.sh --reply <id> --text-file <path>
   ```

   `--reply <id>` resolves the space and thread from the inbox entry and posts a
   threaded reply, so the answer lands in the same conversation.
4. **On a successful post, remove that inbox entry:** `rm -f
   state/chat-inbox/<id>.json` (and any temp reply file). This is what stops the
   poll from re-surfacing it. The post tool deliberately does NOT remove it - that
   cleanup is yours, only after the post is confirmed, mirroring how fmx-respond
   owns `x-inbox` cleanup.
5. **On a failed post** (a non-zero exit), leave the inbox entry in place, move on
   to the next, and do not retry blindly. It will be re-surfaced on a later cycle;
   if a specific message keeps failing to post, surface the blocker to the captain
   through the terminal.

Nothing worth answering should be skipped. If a message genuinely needs no reply
(a bare "thanks"), still remove its inbox entry so it stops being surfaced.

## The reverse channel: posting proactively

The same post tool posts INTO a chat thread without a pending message - the
reverse channel. Use it to reach the captain in Chat when that is the right
surface, for example an away-mode escalation or a proactive "your PR is ready"
notice into a known thread:

```sh
printf '%s' "$note" | bin/fm-crowsnest-post.sh --space spaces/AAA --thread spaces/AAA/threads/T -
```

Only post proactively into a space/thread the captain has used with the Crowsnest
(so you are replying in an established conversation, not cold-messaging a space).
The same captain-facing voice and approval rules apply: routine progress and
outcomes are fine; destructive/irreversible/security-sensitive matters and PR
merges still follow the normal approval gates in AGENTS.md sections 1 and 9.

## Dry-run

With `CROWSNEST_DRY_RUN` truthy, `fm-crowsnest-post.sh` records the would-be post
to `state/chat-outbox/<id>.json` instead of sending, and mutates nothing else.
The full compose-and-record loop runs without GCP credentials, so you can verify
a reply offline. In dry-run, still remove the inbox entry as in step 4 so the
loop completes exactly as a live post would.

## Do not

- Do not edit `bin/fm-crowsnest-relay.sh`, `bin/fm-crowsnest-poll.sh`, or the
  watcher to "answer faster"; the cadence is owned by the check mechanism and the
  session-start wiring (see `docs/crowsnest.md`).
- Do not answer a chat message by spawning an agent, and do not relay the
  captain's chat message to a secondmate as if it were routed work; the live
  session answers Chat.
- Do not expose firstmate internals or task machinery in a reply.
