# treehouse path contract

This document records the empirical path contract behind `bin/fm-teardown.sh`'s `treehouse_recorded_path`.
It exists because the correct handling of a path depends on **who owns its spelling**, and firstmate needs both answers in the same codebase - one of them is the opposite of the other.

Verified against treehouse v2.0.0 on Fedora/Bazzite (ostree), 2026-07-16.

## The two rules

| Situation | Rule | Owner |
| --- | --- | --- |
| Comparing two firstmate-resolved paths | **Canonicalize both sides** before comparing | `fm_same_path` (`bin/fm-wake-lib.sh`) |
| Handing a path to an external tool that recorded its own spelling | **Never canonicalize**; hand back the tool's spelling | `treehouse_recorded_path` (`bin/fm-teardown.sh`) |

A blanket `pwd -P`/`realpath` sweep across `bin/` satisfies the first rule and permanently breaks the second.
Before changing any path resolution, ask which of the two situations it is.

## Why the spellings differ

On every ostree/atomic Fedora variant (Silverblue, Kinoite, Bazzite), `/home` is a symlink to `/var/home`.
So `$HOME/x` and `/var/home/<user>/x` are the same inode spelled two ways, and a path's spelling depends on who produced it.

```
$ readlink /home
/var/home
```

## treehouse owns its spelling, and matches on the string

treehouse records the `$HOME` spelling and string-matches `return` against it, resolving neither side:

```
$ cat ~/.treehouse/<pool>/treehouse-state.json
{
  "worktrees": [
    {
      "name": "1",
      "path": "/home/marlon/.treehouse/<pool>/1/<repo>",
      ...
```

Back to back, on the very same worktree:

```
$ treehouse return /home/marlon/.treehouse/<pool>/1/<repo>
Worktree returned to pool.
$ treehouse return /var/home/marlon/.treehouse/<pool>/1/<repo>
worktree /var/home/marlon/.treehouse/<pool>/1/<repo> is not managed by treehouse
```

`treehouse return [path]` takes a path and nothing else - there is no opaque worktree id to hand back instead, unlike `orca worktree rm --worktree "id:<id>"`.
So firstmate must produce treehouse's own spelling.

## Firstmate never receives that spelling for a crew worktree

`treehouse get --lease` prints its path to stdout, and `bin/fm-home-seed.sh` captures it for secondmate homes.
But a **crew worktree** is acquired by typing `treehouse get` into the task's pane and polling the pane's cwd, and every backend reports that OS-resolved:

```
$ tmux list-panes -a -F '#{pane_current_path}'
/var/home/marlon/.treehouse/<pool>/1/<repo>
```

So there is no verbatim string to keep - the physical spelling is the only thing the pane can report.
`treehouse_recorded_path` therefore asks treehouse's own inventory which spelling is its, matching on **physical identity** rather than on the string, at the moment of the handoff.

Doing it at the handoff boundary (rather than recording it at spawn) means it also repairs metadata written before the fix, so no migration is needed.

## `treehouse status` output shapes

The inventory is human-formatted, so `treehouse_status_path_candidates` parses defensively.
Rows are `<name>  <state>  <path>`, with the path `$HOME`-abbreviated.
treehouse abbreviates with the same `$HOME` it recorded the absolute path under, so expanding `~` reproduces the stored spelling exactly.

An **in-use** row is followed by an indented process continuation line:

```
1     in-use       ~/.treehouse/firstmate-b902f9/1/firstmate
                   bash (104471), claude (104628)
```

A **leased** row appends a holder annotation *after* the path:

```
1     leased       ~/.treehouse/proj-866a4b/1/proj  (held by fm-e2e-test)
```

An **available** row is bare:

```
1     available    ~/.treehouse/proj-866a4b/1/proj
```

That trailing `  (held by ...)` is why the parser emits *candidate* readings of a row rather than assuming the path is the rest of the line (a path may itself contain spaces, so neither reading is always right).
The caller keeps whichever candidate resolves to the worktree it is looking for, so a wrong candidate is discarded rather than returned.
`treehouse status` has no `--json`, so there is no machine-readable alternative to parse instead:

```
$ treehouse status --json
unknown flag: --json
```

If the format changes, no candidate resolves, and `treehouse_recorded_path` returns the caller's path unchanged - degrading to the pre-fix behavior rather than to a wrong argument.

## Verification

A mocked treehouse cannot prove this fix: the bug lives in the handoff, and a stub that accepts any spelling passes while every real teardown fails.
It is verified two ways.

`tests/fm-teardown.test.sh` builds the alias with `ln -s` rather than reading it off the host, so the coverage holds on a developer box whose `/home` is not a symlink, and its fake treehouse string-matches like the real tool.
`tests/fm-turnend-guard.test.sh` covers the internal-comparison half the same way.

End to end against the real tool, on the same lease, back to back:

```
$ treehouse get --lease --lease-holder fm-e2e-test
/home/marlon/.treehouse/proj-866a4b/1/proj      # treehouse's spelling
$ cd /home/marlon/.treehouse/proj-866a4b/1/proj && pwd -P
/var/home/marlon/.treehouse/proj-866a4b/1/proj  # what the pane reports, and what meta records

# before the fix
$ bin/fm-teardown.sh e2e-x1 --force
worktree /var/home/marlon/.treehouse/proj-866a4b/1/proj is not managed by treehouse
error: treehouse return failed for worktree /var/home/...; teardown aborted

# after the fix, no hand-patched meta
$ bin/fm-teardown.sh e2e-x1 --force
🌳 Worktree returned to pool.
$ treehouse status
1     available    ~/.treehouse/proj-866a4b/1/proj
```

## Audit of other path handoffs

- **Orca** (`bin/backends/orca.sh`) is already immune: it removes by opaque id (`orca worktree rm --worktree "id:<id>"`), and `fm-spawn.sh` records Orca's reported path verbatim rather than canonicalizing it. Its one path comparison (`require_orca_worktree_path_match`) canonicalizes *both* sides, which is the correct internal-comparison rule.
- **herdr** (`bin/backends/herdr.sh`) passes a path only as a launch cwd; it closes tabs and workspaces by id, never by matching a recorded path string.
- **`fm_backend_hometag`** (`bin/fm-backend-hometag-lib.sh`) canonicalizes `FM_ROOT` before hashing it into a label. That is correct: it derives a stable identity for one home, and every consumer derives it through the same function.
- **`bin/fm-home-seed.sh`** canonicalizes the `treehouse get --lease` path in `verify_firstmate_home`, so a secondmate home's recorded `home=` is the physical spelling rather than treehouse's. This is harmless *today* only because the teardown boundary re-resolves it before the handoff; it is left alone deliberately, since the registered `home=` string is compared elsewhere and changing it carries risk the boundary fix does not need. Worth revisiting if the lease path ever reaches treehouse by a route that bypasses `teardown_treehouse_return`.
