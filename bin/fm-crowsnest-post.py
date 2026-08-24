#!/usr/bin/env python3
"""Post one message into a Google Chat space/thread via the local-agents-chat
backend's own ChatClient.

This is the transport half of bin/fm-crowsnest-post.sh - the Crowsnest's reverse
channel. It deliberately reuses the backend's ChatClient (spaces.messages.create
as the chat.bot app) rather than reinventing OAuth token minting or the Chat REST
shape in shell. Credential resolution is shared with the thread-context reader in
bin/fm_crowsnest_chat.py so both authenticate as the Chat app the same way the
backend does (see that module for the credential-resolution contract).

Usage:
  fm-crowsnest-post.py --space <spaces/AAA> [--thread <spaces/.../threads/BBB>]
                       [--config <config.toml>] [--reply-option <OPT>]
                       (--text-file <path> | --text-stdin)

On success prints the created message resource name (or "(no name)") to stdout
and exits 0. On any failure prints a diagnostic to stderr and exits non-zero.
"""

from __future__ import annotations

import argparse
import os
import sys

# Import the sibling shared helper by absolute location so this standalone script
# works no matter the caller's working directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_crowsnest_chat as chatlib  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="fm-crowsnest-post.py")
    parser.add_argument("--space", required=True, help="parent resource name, spaces/AAA")
    parser.add_argument("--thread", default=None, help="thread resource name to reply into")
    parser.add_argument("--config", default=None, help="path to the backend config.toml")
    parser.add_argument(
        "--reply-option",
        default="REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD",
        help="messageReplyOption when a thread is given",
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--text-file", help="read message text from this file")
    src.add_argument("--text-stdin", action="store_true", help="read message text from stdin")
    args = parser.parse_args(argv)

    if args.text_stdin:
        text = sys.stdin.read()
    else:
        with open(args.text_file, "r", encoding="utf-8") as fh:
            text = fh.read()
    text = text.strip()
    if not text:
        print("fm-crowsnest-post: refusing to post empty text", file=sys.stderr)
        return 2

    try:
        client, _cfg = chatlib.load_client(args.config)
    except Exception as exc:  # missing/invalid config or credentials - surface cleanly
        print(f"fm-crowsnest-post: config load failed: {exc}", file=sys.stderr)
        return 1

    reply_option = args.reply_option if args.thread else None
    try:
        result = client.create_message(
            args.space,
            text=text,
            thread_name=args.thread,
            message_reply_option=reply_option,
        )
    except Exception as exc:  # network / auth / API error - surface, do not crash
        print(f"fm-crowsnest-post: send failed: {exc}", file=sys.stderr)
        return 1

    name = result.get("name") if isinstance(result, dict) else None
    print(name or "(no name)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
