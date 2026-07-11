#!/usr/bin/env python3
"""Read recent messages from a Google Chat thread so the live firstmate session
can see what the captain is replying to.

This is the read half of the Crowsnest's thread-context enrichment (the write
half is bin/fm-crowsnest-context.sh, which merges the result into the inbox
entry). The subprocess agent that runs the relay only forwards the message text
plus space/thread/sender - never the replied-to message, the raw event, or any
history - so the ONLY way to recover thread context is to read it back from the
Chat API. This tool does that reusing the backend's ChatClient credentials
(bin/fm_crowsnest_chat.py), so it authenticates as the Chat app exactly like the
post tool, and it degrades to empty context on ANY failure (no scope, no
network, no membership) so the Crowsnest behaves exactly as before when context
is unavailable.

It reuses the ChatClient's own auth (its token + HTTP session) for the
``spaces.messages.list`` GET rather than reinventing OAuth; the client only
implements outbound create, so the read is issued here against the same
authenticated session.

Usage:
  fm-crowsnest-context.py --space <spaces/AAA> --thread <spaces/.../threads/BBB>
                          [--config <config.toml>] [--sender users/X]
                          [--exclude-text <TEXT>] [--limit N] [--max-chars M]

Prints an enrichment JSON object to stdout and exits 0:
  {"thread_context": [ {sender, sender_display_name, text, create_time}, ... ],
   "reply_to": {..}|null, "sender_display_name": "..."|null}
``thread_context`` is oldest-first and bounded; ``reply_to`` is the most recent
prior message in the thread (best-effort - the true quoted-message metadata is
not forwarded by the backend). On failure prints a diagnostic to stderr and
exits non-zero, which the shell wrapper treats as "no context".

Testing hook: set FMC_CONTEXT_FIXTURE to a JSON file shaped like a
``spaces.messages.list`` response ({"messages": [...]}) to bypass the network
entirely, so the parse/shape logic is unit-testable offline.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_crowsnest_chat as chatlib  # noqa: E402


def _msg_text(message: dict) -> str:
    """The best available human text of a Chat message."""
    for key in ("text", "argumentText", "formattedText"):
        val = message.get(key)
        if val:
            return str(val)
    return ""


def _normalize(message: dict, max_chars: int) -> dict:
    sender = message.get("sender") or {}
    text = _msg_text(message).strip()
    if max_chars > 0 and len(text) > max_chars:
        text = text[: max_chars - 1].rstrip() + "…"
    return {
        "sender": sender.get("name") or "",
        "sender_display_name": sender.get("displayName") or None,
        "text": text,
        "create_time": message.get("createTime") or "",
    }


def _fetch_messages(space: str, thread: str, config: str | None, limit: int) -> list[dict]:
    """Return the raw ``messages`` array for the thread, newest first.

    Honors FMC_CONTEXT_FIXTURE for offline testing; otherwise issues the
    authenticated ``spaces.messages.list`` GET reusing the ChatClient session.
    """
    fixture = os.environ.get("FMC_CONTEXT_FIXTURE")
    if fixture:
        with open(fixture, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return list(data.get("messages") or [])

    chat_client, config_mod = chatlib.import_backend()
    cfg = config_mod.load_config(chatlib.resolve_config_path(config_mod, config))
    client = chat_client.ChatClient(credentials_path=cfg.credentials_path or None)
    # Reuse the client's own authenticated session + token (same auth path as a
    # post) to issue the read the client itself does not expose.
    token = client._get_token()  # noqa: SLF001 - intentional reuse of the backend auth
    session = client._get_session()  # noqa: SLF001
    url = f"{chat_client.BASE_URL}/{space}/messages"
    params = {
        "filter": f'thread.name = "{thread}"',
        "pageSize": max(1, min(limit * 3, 100)),
        "orderBy": "createTime desc",
    }
    resp = session.get(
        url,
        params=params,
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    resp.raise_for_status()
    return list((resp.json() or {}).get("messages") or [])


def build_enrichment(
    messages: list[dict],
    *,
    sender: str | None,
    exclude_text: str | None,
    limit: int,
    max_chars: int,
) -> dict:
    """Turn a newest-first raw messages list into the inbox enrichment object."""
    norm = [_normalize(m, max_chars) for m in messages]
    norm = [m for m in norm if m["text"]]

    # The captain's display name: the displayName on any message from this sender
    # (usually the just-received message echoed back in the listing).
    sender_display_name = None
    if sender:
        for m in norm:
            if m["sender"] == sender and m["sender_display_name"]:
                sender_display_name = m["sender_display_name"]
                break

    # Drop the just-received message once so context is the PRIOR conversation,
    # not an echo of what firstmate is already handling.
    if exclude_text is not None:
        stripped = exclude_text.strip()
        for i, m in enumerate(norm):
            if m["text"] == stripped and (sender is None or m["sender"] == sender):
                del norm[i]
                break

    reply_to = norm[0] if norm else None  # most recent prior message (best-effort)
    recent = norm[: max(0, limit)]
    recent.reverse()  # oldest-first for natural reading order
    return {
        "thread_context": recent,
        "reply_to": reply_to,
        "sender_display_name": sender_display_name,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="fm-crowsnest-context.py")
    parser.add_argument("--space", required=True, help="parent resource name, spaces/AAA")
    parser.add_argument("--thread", required=True, help="thread resource name to read")
    parser.add_argument("--config", default=None, help="path to the backend config.toml")
    parser.add_argument("--sender", default=None, help="the message sender's resource name")
    parser.add_argument("--exclude-text", default=None, help="drop one echo of this text")
    parser.add_argument("--limit", type=int, default=10, help="max context messages (default 10)")
    parser.add_argument("--max-chars", type=int, default=1200, help="truncate each message text")
    args = parser.parse_args(argv)

    try:
        messages = _fetch_messages(args.space, args.thread, args.config, args.limit)
    except Exception as exc:  # noqa: BLE001 - any failure => no context, handled by caller
        print(f"fm-crowsnest-context: read failed: {exc}", file=sys.stderr)
        return 1

    enrichment = build_enrichment(
        messages,
        sender=args.sender,
        exclude_text=args.exclude_text,
        limit=args.limit,
        max_chars=args.max_chars,
    )
    print(json.dumps(enrichment))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
