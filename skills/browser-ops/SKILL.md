---
name: browser-ops
description: Operate browser-based work tools by driving the real managed Chrome through cua-driver — posture constraints, observation discipline, and hard boundaries. Use for ANY task that touches a website, before improvising with raw tools.
---

# Browser Operations

**This skill covers policy, not the tool API.** cua-driver ships its own
version-matched skill pack describing its tools and parameters
(`cua-driver skills install`, `cua-driver list-tools`,
`cua-driver describe <tool>`). Use that as the reference for *how* to call
things. Where the two disagree about the API, the pack wins — it moves with
the driver and this file does not.

What follows is what the pack cannot know: this machine's constraints, and
what has actually gone wrong here.

## The posture constraint

All work tools enforce **device posture** against the managed Chrome profile.
This is the defining constraint of the whole setup:

- **Attach to the existing logged-in profile.** Approval uses the
  `existing_profile` strategy. The `isolated_new` / `isolated_named` modes
  spawn an *unmanaged* profile, which conditional access rejects.
- **Never launch a second browser**, never pass `--user-data-dir`, never use
  Playwright's bundled Chromium. All of these are unmanaged profiles.
- **Never attach via CDP.** Chrome 136+ refuses `--remote-debugging-port` on
  the default profile, and policy may strip the flag. Confirmed failing
  2026-07-10 and 2026-08-05.

If a tool bounces you to a compliance page, you are on the wrong profile.
Stop and say so — do not try another attachment mode.

## Perception order

Actuation is always element-indexed. Perception escalates only as needed:

1. **Accessibility tree** — text, cheap, precise. The default.
2. **DOM** — when the AX tree lacks what you need.
3. **Pixels** — only on a concrete signal: `suspected_noop`, `degraded`,
   repeated labels `element_index` cannot disambiguate, or the tree visibly
   disagreeing with the screen. A hunch is not a signal.

Two standing cost rules, whatever the current parameter names are:

- **Do not take screenshots by default.** Screenshot capture has historically
  been opt-*out* (`include_screenshot` defaults to true), so a read that looks
  text-only can be shipping a full image. Verify against the pack and turn it
  off explicitly.
- **Bound the tree walk.** Element/depth caps limit what is actually walked
  and are the real payload control. Text-filtering options may only trim the
  rendered output, which focuses attention without reducing size.

Record each site's needed layer in `local/sites.yaml`.

## Observation discipline

Learned the hard way here; none of it is in the vendor docs.

### Always pin the target
Target selection is not optional. Unpinned, the tool picks for you, and these
apps keep hidden `about:blank` iframes for embedded apps and auth — so JS
lands in a blank document and reports an empty page with no error. Enumerate
first, then pin by URL.

### Make every read self-identifying
Return the execution context alongside the data:

    JSON.stringify({ url: location.href, data: /* the actual query */ })

A few tokens converts a silently-wrong answer into an obviously wrong one.
Without it nothing distinguishes "no such content" from "not this page."

### An empty result is a channel failure until proven otherwise
`innerText.length === 0`, an empty query, a null value — treat these as
evidence about the *connection*, not the page. Prove the channel with
something that cannot legitimately be empty:

    JSON.stringify({url: location.href, title: document.title,
                    ready: document.readyState,
                    bodyKids: document.body.children.length,
                    iframes: document.querySelectorAll('iframe').length,
                    htmlLen: document.documentElement.outerHTML.length})

- nothing returned / error → JS execution is blocked
- `url` is `about:blank` or not the target → wrong target; pin it
- `iframes > 0`, `bodyKids` small → content is in a frame
- `htmlLen` large but no text → *then* investigate the DOM itself

On 2026-08-05 an empty `innerText` in a blank iframe produced a confident,
coherent, entirely wrong conclusion that the app rendered into a closed shadow
root. The reasoning was fine; the observation was corrupt.

### Shadow DOM
A plain `document.querySelector` cannot reach into a shadow root. **Open**
roots are traversable via `.shadowRoot`; **closed** roots return `null` and
are unreachable from page JS. Distinguish them —
`[...document.querySelectorAll('*')].filter(e => e.shadowRoot).length` — and
only conclude "closed" once the execution context is confirmed correct. The
AX tree pierces both, because accessibility is computed over the flat tree.

## Loop guards (hard rules)

- **Max 25 actions per task.** At the limit: stop, summarize state, ask.
- **Never repeat an action that didn't change the page.** Same action twice
  with the same result → reassess. A third identical attempt is forbidden.
- **Keep context lean.** Only the latest window state matters; do not re-quote
  earlier reads. Drop screenshots once read.
- On any tool error: re-read state, retry once with a corrected action, then
  escalate. Never claim success without a fresh read proving the change.
- **Never build a theory on an empty result.** Prove the channel first. A
  corrupt observation produces confident, coherent, wrong conclusions, and no
  amount of careful reasoning downstream recovers from it.

## Hard boundaries

- Draft, never send: customer-facing messages (email, ticket replies) are
  composed and left for human review. Do not click Send/Submit on them.
- No credential entry. If a login page appears, stop and ask the user to sign
  in. Never touch an SSO or MFA prompt.
- These are production work tools. Prefer read-only actions; anything
  destructive or irreversible stops for confirmation first.
- See `skills/screen-ops/SKILL.md` for the machine-wide blast-radius policy —
  it governs everything outside the browser window.
