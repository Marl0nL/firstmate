# Test evidence - fm/fm-spawn-preshield-recorded-worktrees

All of it was produced against **real tmux 3.5a** on this machine (Fedora/Bazzite,
Linux 6.17.7 x86_64), on private tmux sockets, with the real `bin/fm-spawn.sh`
from each checkout. `firstmate` is a terminal tool, so the operator-visible
surface is the CLI transcript plus the state of the tmux server and the worktree
pool - both are captured here.

| file | what it shows |
| --- | --- |
| `defect-a-acquisition-reset-real-tmux.txt` | Defect A closed end to end. Identical fixture at base vs HEAD: at base a parked crew's owned worktree is judged free, handed out and reset (branch, landed commit and uncommitted WIP destroyed) before the lease guard can refuse; at HEAD the pre-shields hold it, the spawn is handed the genuinely free slot and succeeds, and no shield is left behind. |
| `defect-b-endpoint-residue-real-tmux.txt` | Defect B closed end to end, three-way. Base leaves the tmux window behind and the retry dies on "already exists"; 11a61e3 (before the last probe fix) tears it down but reports it as leftover and offers a `kill-window` that errors `can't find window`; HEAD tears it down, says nothing, and the retry is clean. |
| `tmux-3.5a-endpoint-absence-probe.txt` | Independent re-run of the vendor transcript that `docs/verification/runtime-backends.md` "Endpoint absence probe" records, reproducing every line: `display-message -p -t '=probe:=fm-a'` prints a *sibling's* name with rc 0 after the window is killed (CMD_FIND_CANFAIL), `list-windows -t` fails rc 1, a bare target prefix-matches the live sibling, and a dead server fails both `has-session` and `list-windows`. |
| `new-tests-fail-before-fix.txt` | Both new test files, unchanged, fail against the pre-fix `bin/` and pass at HEAD. |
| `targeted-tests.txt` | The targeted suite run: the two new spawn test files plus the five existing files this change touched. |
