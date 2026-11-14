---
name: herdr-desk
description: >-
  Load at session start when `command -v desk` succeeds and `$HC_TERMINAL_ID` is set (the captain runs Herdr's Desk layout), whether primary firstmate or secondmate, and before creating or removing config/herdr-desk.
user-invocable: false
metadata:
  internal: true
---

# herdr-desk

The captain may run Herdr's Desk layout, which shows a panel for the focused agent.
A supervisor gets a kanban of the work it hands out, and a crewmate gets a sheet over its terminal with what it is on, what it has found, and what is next.
Agents fill it in themselves with the `desk` CLI: labels on their own terminal plus one board file on their own machine.
`desk help` owns the command syntax; this skill owns when a firstmate home uses it.

The desk is presentation for the captain's glance.
It never carries status, decisions, or authority: status lines, the steering inbox, and captain chat keep every contract they have.
A missing, failing, or slow `desk` never blocks or delays supervision; skip the desk step and carry on.
Never write another agent's board or labels.

## At session start

1. Declare yourself once: `desk init manager --name <name>`.
   The name is a lasting board name: `firstmate` for a primary home, the secondmate's own name for a secondmate.
   A secondmate adds `--parent <address>` with the main firstmate's terminal address from its charter's `# Herdr desk` section, so the captain sees it nested under the main firstmate.
   Pass `--tags` only with tags the captain gave you; an existing board keeps its tags when `--tags` is omitted.
2. Make sure this home's `config/herdr-desk` presence flag exists, so ship and scout briefs and secondmate charters scaffolded from here carry their `# Herdr desk` section.
   [`docs/configuration.md`](../../../docs/configuration.md#herdr-desk-configherdr-desk) owns the flag.
3. Mirror live work that already exists: one task per in-flight crewmate, as below.

When `desk` is absent or `$HC_TERMINAL_ID` is unset, do none of this, and remove `config/herdr-desk` if it exists, because crews scaffolded here would then be told to use a desk the captain cannot see.

## Keeping the kanban

Update the board at the supervision events you already act on, never on a timer:

- Spawn: `desk task add <id> --title "<a few words>" --status doing --agent fm-<id>`; the desk links the card to that crewmate's terminal by its `firstmate.task` label.
- A crewmate's `needs-decision:` or `blocked:`: `desk task move <id> blocked --note "<what it needs>"`.
- PR ready, ready-in-branch, or a scout report waiting on the captain: `desk task move <id> review --note "<PR URL or report>"`.
- Landed, delivered, or torn down: `desk task move <id> done`.
- Keep `desk summary "<one line>"` to what the fleet is doing now when it changes, and add a `desk card` for anything the captain should see at a glance, such as a decision waiting on them.

A secondmate routed work counts as a task on the main firstmate's board, with `--agent` naming the secondmate.

## Crewmates

Crewmates learn the desk from their brief: with `config/herdr-desk` present, `bin/fm-brief.sh` adds a `# Herdr desk` section that has them declare `desk init crew` and keep their summary, findings, and next steps current.
Do not add desk instructions to a brief by hand, and do not steer a crewmate only to update its desk.
