Mode: OpenCode TUI plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. First cycle: let `.opencode/plugins/fm-primary-watch-arm.js` arm supervision after the OpenCode session goes idle.
3. The plugin listens for `session.idle`, spawns `bin/fm-watch-arm.sh --restart` without awaiting it in the idle handler, and calls `client.session.promptAsync` when the child exits with an actionable watcher reason or failure.
4. Ordinary wake: if the plugin reports `watcher: healthy ...`, do not start another cycle.
5. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
6. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
7. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and a secondmate's own home, and stays silent only in child crewmate and scout worktrees.

The watcher restarts itself after a wake, so a re-arm now normally prints `attached` rather than `started`; both mean one live cycle exists.
Re-arming is still mandatory, because the watcher only DETECTS - the arm's exit is the only thing that DELIVERS a wake to you, so a running watcher with no arm sees everything and tells nobody.
Silence from `bin/fm-guard.sh` is the absence of an alarm, not a certification that supervision is live, and it never overrides a turn-end block.
