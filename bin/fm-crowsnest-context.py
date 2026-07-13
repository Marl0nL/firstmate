#!/usr/bin/env python3
"""Read Google Chat context so the live firstmate session can see what the
captain is replying to. Two modes, both reusing the backend's ChatClient
credentials (bin/fm_crowsnest_chat.py) so they authenticate as the Chat app
exactly like the post tool, and both degrading to empty output on ANY failure
(no scope, no network, no membership) so the Crowsnest behaves exactly as before
when context is unavailable.

This is the read half of the Crowsnest's thread-context enrichment; the write
half is bin/fm-crowsnest-context.sh, which merges the result into the inbox
entry.

Primary source (no network): the backend now forwards the TRUE replied-to/quoted
message and the sender display name to the relay, which stashes them directly -
so for the common Reply/Quote case this tool is not called at all. This tool
covers the two cases that still need a read:

* ``--get-message <spaces/.../messages/M>`` - hydrate a quote whose NAME was
  forwarded but whose text was not (the report's F4 case). Issues a single
  ``spaces.messages.get``, which - unlike ``list`` - accepts the ``chat.bot``
  scope this token carries. Prints:
    {"reply_to": {sender, sender_display_name, text, create_time}|null,
     "quoted_snapshot": {text, formatted_text, sender, create_time}}

* ``--space``/``--thread`` (the legacy no-quote path) - best-effort recovery of
  prior thread history via ``spaces.messages.list``. This read is KNOWN-BROKEN:
  ``list`` no longer accepts the ``chat.bot`` scope the ChatClient mints, so it
  403s and this path is a near-total no-op today (report Gap 3). It is retained
  only as best-effort for the no-quote case. Prints:
    {"thread_context": [ {sender, sender_display_name, text, create_time}, ... ],
     "reply_to": {..}|null, "sender_display_name": "..."|null}
  where ``thread_context`` is oldest-first and bounded and ``reply_to`` is the
  most recent prior message (a guess, not the true quote).

Both reuse the ChatClient's own auth (its token + HTTP session) for the GET
rather than reinventing OAuth; the client only implements outbound create, so
the read is issued here against the same authenticated session. On failure both
print a diagnostic to stderr and exit non-zero, which the shell wrapper treats
as "no context".

Usage:
  fm-crowsnest-context.py --get-message <spaces/.../messages/M>
                          [--config <config.toml>] [--max-chars M]
  fm-crowsnest-context.py --space <spaces/AAA> --thread <spaces/.../threads/BBB>
                          [--config <config.toml>] [--sender users/X]
                          [--exclude-text <TEXT>] [--limit N] [--max-chars M]

Testing hooks: FMC_CONTEXT_FIXTURE points to a ``spaces.messages.list`` response
({"messages": [...]}) for the list path; FMC_GET_FIXTURE points to a single
``spaces.messages.get`` message object for the get path. Either bypasses the
network entirely so the parse/shape logic is unit-testable offline.
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


def _fetch_message(name: str, config: str | None) -> dict:
    """Return one Chat message resource by name via ``spaces.messages.get``.

    ``get`` accepts the ``chat.bot`` scope the ChatClient mints (unlike ``list``),
    so this hydrates a forwarded quote whose text was not inlined without any new
    scope. Honors FMC_GET_FIXTURE (a single message object) for offline testing.
    """
    fixture = os.environ.get("FMC_GET_FIXTURE")
    if fixture:
        with open(fixture, "r", encoding="utf-8") as fh:
            return dict(json.load(fh) or {})

    chat_client, config_mod = chatlib.import_backend()
    cfg = config_mod.load_config(chatlib.resolve_config_path(config_mod, config))
    client = chat_client.ChatClient(credentials_path=cfg.credentials_path or None)
    token = client._get_token()  # noqa: SLF001 - intentional reuse of the backend auth
    session = client._get_session()  # noqa: SLF001
    resp = session.get(
        f"{chat_client.BASE_URL}/{name}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    resp.raise_for_status()
    return dict(resp.json() or {})


def build_get_enrichment(message: dict, *, max_chars: int) -> dict:
    """Turn one fetched quoted message into the get-hydrate enrichment object.

    ``reply_to`` mirrors the list path's shape so the consumer reads it the same
    way; ``quoted_snapshot`` mirrors the backend's forwarded snapshot shape so the
    shell wrapper can graft it onto the already-stashed ``quoted`` field. Both
    carry only the sub-fields that are actually present.
    """
    norm = _normalize(message, max_chars)
    sender_obj = message.get("sender") or {}
    snapshot: dict = {}
    if norm["text"]:
        snapshot["text"] = norm["text"]
    formatted_text = message.get("formattedText")
    if formatted_text:
        snapshot["formatted_text"] = str(formatted_text)
    snap_sender = sender_obj.get("displayName") or sender_obj.get("name")
    if snap_sender:
        snapshot["sender"] = snap_sender
    if norm["create_time"]:
        snapshot["create_time"] = norm["create_time"]
    return {
        "reply_to": norm if norm["text"] else None,
        "quoted_snapshot": snapshot,
    }


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
    parser.add_argument("--get-message", default=None, help="hydrate one quoted message by name")
    parser.add_argument("--space", default=None, help="parent resource name, spaces/AAA")
    parser.add_argument("--thread", default=None, help="thread resource name to read")
    parser.add_argument("--config", default=None, help="path to the backend config.toml")
    parser.add_argument("--sender", default=None, help="the message sender's resource name")
    parser.add_argument("--exclude-text", default=None, help="drop one echo of this text")
    parser.add_argument("--limit", type=int, default=10, help="max context messages (default 10)")
    parser.add_argument("--max-chars", type=int, default=1200, help="truncate each message text")
    args = parser.parse_args(argv)

    # Get-hydrate mode: fetch a single quoted message by name (the F4 case).
    if args.get_message:
        try:
            message = _fetch_message(args.get_message, args.config)
        except Exception as exc:  # noqa: BLE001 - any failure => no context, handled by caller
            print(f"fm-crowsnest-context: get failed: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(build_get_enrichment(message, max_chars=args.max_chars)))
        return 0

    if not args.space or not args.thread:
        parser.error("--space and --thread are required unless --get-message is given")

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
