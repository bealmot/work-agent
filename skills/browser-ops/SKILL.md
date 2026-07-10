---
name: browser-ops
description: Operate browser-based work tools through layered automation — DOM actions by default, OS-level clicks for resistant sites. Use for ANY task that touches a website, before improvising with raw browser tools.
---

# Browser Operations

## Before acting
1. Read `local/sites.yaml`. Find the entry whose `host` matches the target.
   No entry → treat as layer 1 and run the **probe procedure** below first.
2. Confirm Chrome CDP is up (the playwright MCP tools respond). If not,
   tell the user to run `scripts/chrome-debug.sh` and stop.

## Layer 1 — DOM in, DOM out (default)
- Perceive with the page snapshot (accessibility tree), never screenshots.
- Act on element refs from the snapshot (click/type/select).
- After each action, re-snapshot and confirm the page actually changed as
  expected before planning the next action.

## Layer 2 — DOM perception, OS-level actuation
For sites marked `layer: 2`:
1. Locate the target element in the snapshot as usual.
2. Evaluate in the page to get geometry:
   `el.getBoundingClientRect()` for the bbox, and
   `({screenX: window.screenX, screenY: window.screenY, outerHeight: window.outerHeight, innerHeight: window.innerHeight})`.
3. Bring the browser window to the front, then click through the OS:
   `python3 scripts/osclick.py '{"bbox": {...}, "win": {...}, "action": "c"}'`
4. Re-snapshot to confirm the effect. Page zoom must be 100%.

## Probe procedure (new site, or layer-2 site after a UI update)
1. Perform a harmless layer-1 action (focus a search box, open a menu).
2. If the UI responds normally → record `layer: 1` in `local/sites.yaml`.
3. If actions are ignored, a bot warning appears, or you get logged out →
   record `layer: 2` with a dated note describing what failed.
4. Never probe with destructive actions (no submits, no deletes).

## Loop guards (hard rules)
- **Max 25 browser actions per task.** At the limit: stop, summarize state,
  ask the user how to proceed.
- **Never repeat an action that didn't change the page.** Same action twice
  with the same snapshot result → stop and reassess the approach; a third
  identical attempt is forbidden.
- **Keep context lean.** Only the latest snapshot matters; do not re-quote
  old snapshots in your reasoning.
- On any tool error: re-snapshot, retry once with a corrected action, then
  escalate to the user. Fail loud — never claim success without a snapshot
  that proves the expected change.

## Hard boundaries
- Draft, never send: customer-facing messages (email, ticket replies) are
  composed and left for human review. Do not click Send/Submit on them.
- No credential entry. If a login page appears, stop and ask the user to
  log in manually.
