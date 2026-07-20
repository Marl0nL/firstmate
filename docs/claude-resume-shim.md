# The claude resume shim

`bin/fm-claude-shim.sh` is a user-space `claude` launcher that re-adds firstmate's launch flags when something else relaunches the firstmate pane without them.
This document owns the install, rollback, and verification steps; the script's own header owns the resolution order, the injection conditions, and the config keys.

## The gap it closes

Firstmate's primary pane is launched with `--dangerously-skip-permissions` (so it can run unattended) and `--remote-control` (so it is reachable).
When the herdr server crashes and restarts, it re-runs that pane's command as a bare `claude --resume <session-id>`, dropping both flags.
The resumed session then stalls at the first permission prompt with nobody at the keyboard.

Installing the shim as the user's `claude` closes the gap at the only layer that sees every relaunch, including ones firstmate never initiated.

`--remote-control` persists across a resume, so on a crash-resume of an already-remote-controlled session it is usually already in effect.
Its value here is guaranteeing it on a genuinely fresh relaunch, where nothing carries over.
`--dangerously-skip-permissions` is the flag that actually goes missing on the common path.

## What it does

The shim injects those two flags only when the launch is the firstmate primary session, and passes every other invocation through completely unchanged.
The primary session is detected narrowly: either `FM_CLAUDE_SHIM_PRIMARY` is truthy, or the physical working directory is exactly the configured `home=` directory and that directory still looks like a firstmate checkout.
A subdirectory of the home, a crewmate worktree, a project clone, and any unrelated workspace are all pass-through.
Subcommands, `--print`/`-p` runs, and `--version`/`--help` are pass-through too.
Injection is idempotent: a flag already present, in either `--flag` or `--flag=value` form, is never added twice.

The shim never hardcodes a version path.
`claude` auto-updates by rewriting `~/.local/bin/claude` to point at a new file under `~/.local/share/claude/versions/<version>`, so it resolves the newest entry in that versions directory at every launch and follows an update with no config change.

Every uncertainty resolves to "exec the real `claude` with the original arguments, untouched".
The worst thing the shim can do is fail to add a flag, which is exactly today's behaviour.

## Install

The shim ships in this repo but is never installed automatically: swapping the captain's `claude` launcher is a deliberate manual step.
Run these as the captain, in order.
`FM_HOME_DIR` must be the firstmate primary checkout, not a worktree.

```sh
FM_HOME_DIR=/var/home/marlon/firstmate

# 1. Tell the shim where the firstmate home is and where versions live.
#    Written with printf rather than a heredoc on purpose: a heredoc here
#    silently breaks if this block is ever pasted inside another heredoc, and
#    the commands below it would then run unintentionally.
mkdir -p ~/.config/firstmate
printf 'home=%s\nreal=%s\nversions_dir=%s\n' \
  "$FM_HOME_DIR" \
  "$HOME/.local/bin/claude-real" \
  "$HOME/.local/share/claude/versions" \
  > ~/.config/firstmate/claude-shim.conf

# 2. Preserve the original launcher, symlink and all, as a fallback.
cp -P ~/.local/bin/claude ~/.local/bin/claude-real

# 3. Prove the preserved launcher works BEFORE giving up the original.
~/.local/bin/claude-real --version

# 4. Swap in the shim. `ln -sfn` replaces the symlink in one step.
ln -sfn "$FM_HOME_DIR/bin/fm-claude-shim.sh" ~/.local/bin/claude
```

Do not run step 4 until step 3 prints a version.
If it does not, stop: the rollback below has nothing to restore from.

`claude`'s own auto-updater may rewrite `~/.local/bin/claude` and displace the shim.
That is a silent revert to today's behaviour, not a breakage; re-run step 4 to restore it.
Check with the `shim:` line of `claude --fm-shim-explain`.

## Rollback

One command, restoring the original launcher exactly as it was, symlink and all:

```sh
cp -P --remove-destination ~/.local/bin/claude-real ~/.local/bin/claude
```

To disable the shim without uninstalling it, set `FM_CLAUDE_SHIM_DISABLE=1` in the environment, or delete `~/.config/firstmate/claude-shim.conf` so nothing is known and nothing is injected.

## Verification

`--fm-shim-explain` prints the resolved decision and execs nothing, so every check below is safe to run against the live install.

```sh
# 1. From the firstmate home: the shim is active, resolves a real binary, and
#    would inject. Expect `primary: yes`, `decision: inject`, and a `real:`
#    path under ~/.local/share/claude/versions.
cd /var/home/marlon/firstmate && claude --fm-shim-explain

# 2. From anywhere else: expect `primary: no` and `decision: passthrough`.
cd /tmp && claude --fm-shim-explain

# 3. The real binary still launches and reports its own version.
claude --version

# 4. The resolved `real:` path matches the version the launcher points at.
readlink -f ~/.local/bin/claude-real
```

Step 4 is the dynamic-resolution check: after `claude` auto-updates, re-run step 1 and confirm the `real:` line has moved to the new version with no edit to the config.

For the full behavioural contract, `tests/fm-claude-shim.test.sh` drives the shim against a fake `claude` binary and covers injection, idempotence, pass-through, dynamic resolution, self-exec refusal, and exit-status fidelity.
It never touches the real launcher.
