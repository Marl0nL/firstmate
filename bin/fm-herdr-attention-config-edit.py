#!/usr/bin/env python3
"""Pure text transform for bin/fm-herdr-attention-config.sh.

Reads the current Herdr config.toml on stdin and writes the desired config on
stdout. It sets EXACTLY the three captain-consented attention keys and preserves
every other line (comments and keys) verbatim:

    [ui]        agent_panel_sort = "priority"
    [ui.toast]  delivery         = "herdr"
    [ui.sound]  enabled          = true

Exit status: 0 = a change was written to stdout; 3 = already applied, nothing
written; 1 = the current config is not valid TOML (nothing written). The .sh
owns backup, validation, and reload; this file never touches the filesystem.
"""
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("error: python3 >= 3.11 (tomllib) is required\n")
    sys.exit(1)

# (dotted-path, parsed-want, table, key, toml-literal)
DESIRED = [
    ("ui.agent_panel_sort", "priority", "ui", "agent_panel_sort", '"priority"'),
    ("ui.toast.delivery", "herdr", "ui.toast", "delivery", '"herdr"'),
    ("ui.sound.enabled", True, "ui.sound", "enabled", "true"),
]


def get(data, path):
    cur = data
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def header_of(line):
    s = line.strip()
    if s.startswith("[[") or not (s.startswith("[") and s.endswith("]")):
        return None
    return s[1:-1].strip()


def set_key(lines, table, key, lit):
    header_idx = -1
    for i, ln in enumerate(lines):
        if header_of(ln) == table:
            header_idx = i
            break
    if header_idx == -1:
        block = []
        if any(ln.strip() for ln in lines) and lines and lines[-1].strip():
            block.append("")
        block += ["[%s]" % table, "%s = %s" % (key, lit)]
        return lines + block
    region_end = len(lines)
    for j in range(header_idx + 1, len(lines)):
        if header_of(lines[j]) is not None:
            region_end = j
            break
    keyre = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
    for j in range(header_idx + 1, region_end):
        if lines[j].lstrip().startswith("#"):
            continue
        if keyre.match(lines[j]):
            lines[j] = "%s = %s" % (key, lit)
            return lines
    return lines[: header_idx + 1] + ["%s = %s" % (key, lit)] + lines[header_idx + 1 :]


def main():
    src = sys.stdin.read()
    try:
        data = tomllib.loads(src)
    except tomllib.TOMLDecodeError as exc:
        sys.stderr.write("error: current Herdr config is not valid TOML: %s\n" % exc)
        return 1
    lines = src.split("\n")
    changed = False
    for path, want, table, key, lit in DESIRED:
        if get(data, path) == want:
            continue
        changed = True
        lines = set_key(lines, table, key, lit)
    if not changed:
        return 3
    sys.stdout.write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
