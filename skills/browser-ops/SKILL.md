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

#### Always pin the target
**`target_url_contains` is mandatory on every `page` call**, not an
optimization. With it unset the tool picks a target for you, and these apps
keep hidden `about:blank` iframes around for embedded apps and auth — so JS
lands in a blank document that reports an empty page with no error.

Use `get_browser_state` first to enumerate tabs, then pin.

#### Make every read self-identifying
Return the execution context alongside the data, always:

    JSON.stringify({ url: location.href, data: /* the actual query */ })

It costs a few tokens and converts a silently-wrong answer into an obviously
wrong one. Without it there is nothing in the result to distinguish "the page
has no such content" from "this isn't the page."

#### An empty result is a channel failure until proven otherwise
`innerText.length === 0`, an empty `query_dom`, a null value — treat all of
these as evidence about the *connection*, not about the page. Before drawing
any conclusion from an empty read, make the tool return something that cannot
legitimately be empty:

    JSON.stringify({url: location.href, title: document.title,
                    ready: document.readyState,
                    bodyKids: document.body.children.length,
                    iframes: document.querySelectorAll('iframe').length,
                    htmlLen: document.documentElement.outerHTML.length})

- nothing returned / error → Apple Events JS is blocked (below)
- `url` is `about:blank` or not the target → wrong target; pin it
- `iframes > 0`, `bodyKids` small → content is in a frame
- `htmlLen` large but no text → *then* investigate the DOM itself

This happened on 2026-08-05: an empty `innerText` in a blank iframe produced a
confident, coherent, and entirely wrong conclusion that the app rendered into
a closed shadow root. The reasoning was fine; the observation was corrupt.

#### Other gotchas
- JS via Apple Events requires Chrome's *Allow JavaScript from Apple Events*
  setting, which is **off by default**. `page` exposes
  `enable_javascript_apple_events` to patch it. A blocked call can return
  empty rather than raising — see above.
- `page` **mutating** actions need `CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS=1`
  set at daemon startup. Reads work without it.
- Shadow DOM: a plain `document.querySelector` cannot reach into a shadow
  root. **Open** roots are traversable via `.shadowRoot`; **closed** roots
  return `null` and are genuinely unreachable from page JS. Distinguish them —
  `[...document.querySelectorAll('*')].filter(e => e.shadowRoot).length` — and
  only conclude "closed" once the execution context is confirmed correct.
  The AX tree pierces both, because accessibility is computed over the flat
  tree; that makes Layer 1 the reliable fallback for component-heavy apps.

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
- **Never build a theory on an empty result.** Prove the channel first (see
  Layer 2). A corrupt observation produces confident, coherent, wrong
  conclusions, and no amount of careful reasoning downstream recovers from it.

## Hard boundaries

- Draft, never send: customer-facing messages (email, ticket replies) are
  composed and left for human review. Do not click Send/Submit on them.
- No credential entry. If a login page appears, stop and ask.
- These are production work tools. Prefer read-only actions; anything
  destructive or irreversible stops for confirmation first.
- See `skills/screen-ops/SKILL.md` for the machine-wide blast-radius policy —
  it governs everything outside the browser window.
