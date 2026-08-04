---
name: screen-ops
description: Operate native apps and DOM-less UIs through OS-level screen control (Hermes computer_use). Use ONLY when browser-ops layers 1-2 cannot perceive the target — never as the first approach for a website.
---

# Screen Operations (Layer 3)

OS-level perception **and** actuation via Hermes' `computer_use` tool. This is
the last resort tier. `skills/browser-ops/SKILL.md` owns anything with a DOM.

## When this applies

| | Perceive | Act | Use for |
|---|---|---|---|
| Layer 1 | DOM snapshot | DOM | Any normal website (default) |
| Layer 2 | DOM snapshot | OS click | Sites that reject synthetic input |
| **Layer 3** | **Screenshot** | **OS click** | Native macOS apps, Electron, canvas/custom-rendered UIs |

**The escalation trigger is perception, not actuation.** If you can still read
the target in a DOM snapshot, you are in Layer 1 or 2 — stay there. Escalate
only when there is nothing to snapshot: a native app window, or a web UI that
renders to canvas so the accessibility tree is empty where the content is.

Escalating early is the common failure. Screenshots cost far more context than
snapshots, and coordinates are guesses in a way element refs are not.

## Procedure

1. **Capture with SOM first.** `capture(mode="som")` screenshots and numbers
   every interactive element; you then click by index. Prefer this over raw
   coordinates always — it turns "predict a pixel location" into "choose an
   element," which is a far easier problem and a far cheaper mistake.
2. **If SOM returns few or no marks**, the AX tree is sparse (typical for
   canvas and custom-drawn UIs). Fall back to `capture(mode="ax")` to inspect
   structure, and only then to raw coordinates.
3. **Re-capture after every action** and confirm the screen changed as
   expected before planning the next one. Never chain blind actions.
4. Prefer keyboard over mouse where an equivalent exists — menu shortcuts and
   tab traversal are deterministic; coordinates are not.

## Notes

- The driver acts **in the background**: it does not move your cursor or steal
  keyboard focus, so you can keep working while it operates. Do not assume the
  target window is frontmost — verify in the capture, don't infer it.
- Both **Accessibility** and **Screen Recording** must be granted to the
  terminal app. Without them events are dropped silently, with no error.
  Run `hermes computer-use doctor` if actions appear to do nothing.
- Screenshots are context-hungry. Keep only the latest capture in reasoning;
  do not re-quote earlier ones.

## Loop guards (hard rules)

- **Max 15 screen actions per task** — lower than browser-ops' 25, because
  errors here are less recoverable and each step costs more context. At the
  limit: stop, summarize, ask the user.
- **Never repeat an action that didn't change the screen.** Twice with the
  same result → reassess. A third identical attempt is forbidden.
- On any uncertainty about *what* you are about to click — stop and ask. A
  misplaced click at this layer can land in any application on the machine.

## Hard boundaries

Layer 3 is not sandboxed to the browser. A wrong coordinate can hit any window
on the Mac, including system dialogs. Inherit every boundary from
`skills/browser-ops/SKILL.md` (draft-never-send; no credential entry), and:

<!-- TODO(andrew): define the blast-radius policy for this machine.
     This one needs your knowledge of what actually lives on the work Mac
     and what your employer's policy covers -- I should not guess it.

     Write 5-10 lines below covering:
       - Which applications are OFF LIMITS entirely (Slack? Mail? Finder?
         password manager? anything with a Send button?)
       - What to do when a system dialog or permission prompt appears
         mid-task (always stop and hand back? dismiss known-safe ones?)
       - Whether the agent may operate a window it did not itself open
       - The one irreversible action class you most want blocked

     Trade-off worth weighing: an allowlist ("only these apps") is far safer
     but you will hit it constantly and have to keep editing it; a denylist
     ("anything but these") flows better day to day but fails open -- the app
     you forgot to list is the one that gets clicked. Given this is a work
     machine driving real tickets, I'd lean allowlist, but the friction cost
     is yours to judge, not mine. -->

- _(policy to be filled in — until then, treat every app except the browser
  as off limits and stop for human confirmation before any click outside it)_
