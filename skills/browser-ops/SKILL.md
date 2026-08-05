---
name: browser-ops
description: Operate browser-based work tools by driving the real managed Chrome through computer_use — accessibility tree first, DOM via JavaScript second, pixels last. Use for ANY task that touches a website, before improvising with raw tools.
---

# Browser Operations

All work tools enforce **device posture** against the managed Chrome profile.
That constrains the approach more than it looks:

- A separate browser profile is an *unmanaged* profile — conditional access
  rejects it. So no dedicated automation profile.
- Chrome 136+ refuses `--remote-debugging-port` on the default profile, and
  policy may strip the flag. So no CDP attach.

The only compliant path is to drive the **real Chrome window you are already
signed into**, via `computer_use` (cua-driver). It acts in the background
using the accessibility APIs — your cursor does not move and focus does not
change, so the user can keep working.

**Never** launch a second browser, never pass `--user-data-dir`, never attach
to a debug port. Those all break posture and the tool will bounce you to a
compliance page.

## Layers

| | Perceive | Act | When |
|---|---|---|---|
| **1** | AX tree (`get_window_state`) | `element_index` | Default. Always start here |
| **2** | DOM via `javascript` param / `page` tool | `element_index` | AX tree lacks the data you need |
| **3** | Screenshot | pixel coords | Only on a real signal (below) |

### Layer 1 — accessibility tree
`get_window_state` returns a structured tree; act on `element_index`, not
coordinates.

**Always pass `include_screenshot: false`.** It defaults to **true**, so every
call otherwise grabs the screen and ships a full image you did not ask for.
This is the single most expensive mistake available in this skill. (`capture_mode`
is deprecated and ignored — it does not give you a text-only read.)

**Always scope the tree.** Defaults are `max_elements: 2000` and
`max_depth: 25`, which serialize far more of a page than any one step needs:

- `query` — case-insensitive filter returning matching actionable rows plus
  their actionable ancestors. It does **not** renumber `element_index`, so
  filtering is free of consistency risk. Use it whenever you know roughly what
  you are looking for ("Submit", "ticket", "assignee").
- `max_elements` / `max_depth` — lower them for deep or sprawling pages.

Read `element_count` vs `filtered_element_count` to see how much you pulled.

Chrome's AX tree is sometimes sparse on first read — if it comes back thin,
retry once before concluding anything.

### Layer 2 — DOM
Prefer **`get_browser_state` and the typed `browser_*` tools** for exact
targeting. Fall back to the legacy `page` tool only if those cannot express
what you need — it supports `execute_javascript`, `get_text`, `query_dom`,
`click_element`, `insert_text`.

Targeted extraction beats full-state perception by a wide margin: a
`query_dom` for one selector returns tens of tokens where a tree read returns
thousands. Once a site's selectors are known, record them in `local/sites.yaml`
and go straight here.

Two gotchas:
- `page` **mutating** actions need `CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS=1`
  set at daemon startup. Reads work without it.
- JS via Apple Events requires Chrome's *Allow JavaScript from Apple Events*
  setting. `page` exposes `enable_javascript_apple_events` to patch it.
- `target_url_contains` picks the right tab on a multi-tab window — use it
  rather than assuming the active tab.

### Layer 3 — pixels
Escalate **only on a concrete signal**, never on a hunch:
- `suspected_noop` or `degraded` in a tool result
- repeated identical labels that `element_index` can't disambiguate
- the tree visibly disagrees with what's on screen

Then re-capture and confirm. Do not chain blind pixel actions.

## Gotchas

- **Never mix coordinate spaces.** `elements[].frame` is in logical points;
  pixel actions use window-local screenshot pixels. Mixing them misclicks
  silently. Staying on `element_index` avoids the problem entirely.
- **Right-click is unreliable via synthesized events** — Chromium's
  renderer-IPC filter drops the right-click subtype bit. Use an
  element-indexed right-click, or briefly foreground the window.
- **Login pages mean the session expired.** Stop and ask the user to sign in.
  Never enter credentials, never touch an SSO or MFA prompt.

## Loop guards (hard rules)

- **Max 25 actions per task.** At the limit: stop, summarize state, ask.
- **Never repeat an action that didn't change the page.** Same action twice
  with the same result → reassess. A third identical attempt is forbidden.
- **Keep context lean.** Only the latest window state matters; do not
  re-quote earlier snapshots. Screenshots especially — drop them once read.
- On any tool error: re-read state, retry once with a corrected action, then
  escalate to the user. Fail loud — never claim success without a fresh
  read that proves the expected change.

## Hard boundaries

- Draft, never send: customer-facing messages (email, ticket replies) are
  composed and left for human review. Do not click Send/Submit on them.
- No credential entry. If a login page appears, stop and ask.
- These are production work tools. Prefer read-only actions; anything
  destructive or irreversible stops for confirmation first.
- See `skills/screen-ops/SKILL.md` for the machine-wide blast-radius policy —
  it governs everything outside the browser window.
