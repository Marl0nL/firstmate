"""Shared transport helpers for the Crowsnest's Chat tools.

Both bin/fm-crowsnest-post.py (outbound reply) and bin/fm-crowsnest-context.py
(inbound thread-context read) import this so credential resolution lives in ONE
place. It is deliberately dependency-free at import time: the backend package,
``requests``, and ``google-auth`` are all imported lazily, so importing this
module (and running the unit tests) needs none of them.

The one job that matters here is resolving credentials EXACTLY as the running
backend does, so the post/read tools authenticate as the Chat app (a service
account) instead of silently falling back to user ADC and getting a 403:

  * When no ``--config`` is given, resolve the backend's DEFAULT config path
    (``config.default_config_path()``), mirroring ``local-agents run`` whose
    ``--config`` argparse default is ``str(default_config_path())``. The prior
    bug was passing ``None`` to ``load_config``, which reads NO file and leaves
    ``credentials_path`` empty, so posts fell through to ADC.
  * ``load_config`` then applies the backend's own ``LOCAL_AGENTS_CREDENTIALS_PATH``
    env override on top of the file.
  * ``GOOGLE_APPLICATION_CREDENTIALS`` is honored by the ChatClient itself when
    ``credentials_path`` is empty (it calls ``google.auth.default()``), exactly
    like the backend.
"""

from __future__ import annotations

import importlib
from typing import Any

# Candidate module roots, newest package name first, so the tools keep working
# across the local-agents -> local-agents-chat rename without a code change.
_CANDIDATE_MODULES = ("local_agents_chat", "local_agents")


def import_backend() -> tuple[Any, Any]:
    """Import the backend's ``chat_client`` and ``config`` modules.

    Returns ``(chat_client, config)``. Raises SystemExit with an actionable
    message when neither candidate package is installed.
    """
    last_err = None
    for root in _CANDIDATE_MODULES:
        try:
            chat_client = importlib.import_module(f"{root}.chat_client")
            config = importlib.import_module(f"{root}.config")
            return chat_client, config
        except ImportError as exc:  # try the next candidate
            last_err = exc
    raise SystemExit(
        "fm-crowsnest: cannot import the local-agents-chat backend "
        f"(tried {', '.join(_CANDIDATE_MODULES)}): {last_err}"
    )


def resolve_config_path(config, explicit: str | None) -> str | None:
    """Resolve the backend config path the same way ``local-agents run`` does.

    An explicit ``--config`` wins; otherwise fall back to the backend's default
    path so ``load_config`` actually reads the file (and its ``credentials_path``)
    rather than silently getting defaults. Returns a path string, or ``None``
    only if the backend somehow exposes no default (then ``load_config`` still
    applies env overrides).
    """
    if explicit:
        return explicit
    try:
        return str(config.default_config_path())
    except Exception:  # noqa: BLE001 - never let path resolution crash the tool
        return None


def load_client(explicit_config: str | None) -> tuple[Any, Any]:
    """Build a ChatClient authenticated exactly as the backend would.

    Returns ``(client, cfg)``. Raises on a config-load failure so the caller can
    surface it cleanly.
    """
    chat_client, config = import_backend()
    cfg = config.load_config(resolve_config_path(config, explicit_config))
    client = chat_client.ChatClient(credentials_path=cfg.credentials_path or None)
    return client, cfg


def _identity_main(argv: list[str] | None = None) -> int:
    """Print how the post tool WILL authenticate, for `fm-crowsnest.sh status`.

    Surfaces the #1 Crowsnest misconfig - posting with user ADC instead of the
    Chat app's service account (the 403 the credential resolution above fixes) -
    at inspection time instead of only on a failed post. Never raises.
    """
    import argparse

    parser = argparse.ArgumentParser(prog="fm_crowsnest_chat.py identity")
    parser.add_argument("--config", default=None, help="path to the backend config.toml")
    args = parser.parse_args(argv)
    try:
        client, _cfg = load_client(args.config)
        ident = client.posting_identity()
        # Build the whole line inside the try so a malformed identity object
        # cannot raise past this diagnostic's never-crash contract.
        label = "app auth (service account)" if ident.is_app_auth else f"NOT app auth ({ident.kind})"
        line = f"{label}: {ident.detail}"
    except (Exception, SystemExit) as exc:  # noqa: BLE001 - a diagnostic must never crash
        # SystemExit is what import_backend raises when the backend is absent;
        # surface it as a normal line so `status` shows a reason, not <unknown>.
        print(f"unavailable: {exc}")
        return 0
    print(line)
    return 0


if __name__ == "__main__":
    import sys

    _args = sys.argv[1:]
    if _args and _args[0] == "identity":
        raise SystemExit(_identity_main(_args[1:]))
    print("usage: fm_crowsnest_chat.py identity [--config <config.toml>]", file=sys.stderr)
    raise SystemExit(2)
