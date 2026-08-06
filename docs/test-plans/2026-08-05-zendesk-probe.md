# Zendesk probe — test plan

> **Summary for agents:** Execute T0–T10 in order against the live Zendesk tab.
> Record raw evidence to `local/test-results/zendesk-probe.md`. Read-only: never
> submit, send, or modify a ticket. Do not edit skills. Do not stop at the first
> failure. Do not draw architectural conclusions — that happens after review.

**Date:** 2026-08-05
**Target:** the real, logged-in, managed Chrome tab on your Zendesk instance
**Goal:** decide whether Zendesk can be read through its own API from inside the
authenticated session, and quantify the alternatives if it cannot.

---

## Why this plan exists

A prior autonomous run produced good measurements and one premature conclusion.
It filed `page()` under "wasted effort" because the tool reported needing
`CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS=1` — an unset environment variable, not
a capability limit. That single untested path is the one that decides the whole
architecture, so this plan tests it first and explicitly.

It also found the accessibility tree is 74 KB / 15,000+ elements on Zendesk and
truncates before it can be parsed. That is real and it means "AX tree first" is
wrong for this app. This plan quantifies what a *scoped* read costs instead.

---

## Rules — these are not optional

1. **Record raw output, not summaries.** For every step, paste the first 300
   characters of what the tool actually returned. A conclusion without raw output
   is not evidence.
2. **An empty or zero result is a channel failure until proven otherwise.**
   If any step returns nothing, re-run **T0** before interpreting it. Today an
   empty `innerText` was read as a shadow-DOM limitation when the real cause was
   JavaScript executing in a blank iframe.
3. **Never conclude from an unset flag or a missing permission.** If a tool
   reports a prerequisite, set it and retry. Record both attempts.
4. **Read-only.** No Submit, no Send, no status change, no comment, no macro.
   Reading a ticket is fine. Changing one is not.
5. **Continue past failures.** A failed step is a result. Record it and move on;
   later steps are still informative.
6. **Do not edit any SKILL.md during this run.** Skills are version-controlled in
   this repo and edits mid-run destroy the evidence trail. Propose changes in the
   results file instead.
7. **Results go to `local/test-results/zendesk-probe.md`** — `local/` is
   gitignored, which is what keeps real ticket content out of the repository.
   Never paste ticket bodies anywhere else.
8. **Redact.** Ticket IDs and subjects are fine. Customer names, emails and
   message bodies are not — write `[redacted]`.

---

## Setup (record whether each was already true)

- **S1.** Chrome → Develop menu → **Allow JavaScript from Apple Events** is
  enabled. `page`'s `enable_javascript_apple_events` action can set it.
  *If the Develop menu is hidden: Chrome → Settings → check "Show Develop menu".*
- **S2.** The cua-driver daemon is running with
  `CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS=1`. Restart it if not.
- **S3.** A Zendesk tab is open and logged in. Record its `pid` and `window_id`
  from `list_windows`.
- **S4.** Every `page` call in this plan passes `target_url_contains: "zendesk"`.
  Without it the tool may select one of Zendesk's hidden `about:blank` iframes.

---

## T0 — Prove the channel (run first, and again after any empty result)

**Goal:** establish that JavaScript executes in the tab you think it does.

```
page: action=execute_javascript, target_url_contains="zendesk"
javascript: JSON.stringify({ok: 1+1, url: location.href, title: document.title, ready: document.readyState})
```

**Record:** the raw response.

**Pass:** `ok: 2` and a `url` containing your Zendesk host.
**Fail — nothing returned:** Apple Events JS is blocked. Redo **S1**, retry, record both.
**Fail — `url` is `about:blank`:** wrong target. Confirm **S4** and retry.

> Everything after this depends on T0 passing. If it cannot pass, record why in
> detail and skip to **T6** — the plan's fallback branch.

---

## T1 — Same-origin API read (the decisive test)

**Goal:** can the page read Zendesk's own API using the session already in the browser?

```
javascript: JSON.stringify(await (await fetch('/api/v2/users/me.json')).json()).slice(0,300)
```

**Record:** raw response. Note whether it contains `"id"`, `"role"`, and
`"authenticity_token"`.

**Pass:** JSON describing your user.
**Fail — HTTP 401/403:** record the status and body verbatim.
**Fail — a syntax error about `await`:** the executor may not accept top-level
await. Retry wrapped:
`fetch('/api/v2/users/me.json').then(r=>r.json()).then(d=>JSON.stringify(d).slice(0,300))`
and record whether the wrapped form works. **This distinction matters — do not
report "fetch is blocked" without trying both forms.**

---

## T2 — Locate the unsolved-tickets view

```
javascript: fetch('/api/v2/views.json?per_page=100').then(r=>r.json()).then(d=>JSON.stringify(d.views.map(v=>({id:v.id,title:v.title}))).slice(0,1500))
```

**Record:** the id/title list. Note the id of the view you actually work from
("Unsolved tickets" or your team's equivalent).

---

## T3 — Read the queue by API

Using the view id from T2:

```
javascript: fetch('/api/v2/views/VIEWID/tickets.json?per_page=25').then(r=>r.json()).then(d=>JSON.stringify(d.tickets.map(t=>({id:t.id,status:t.status,subject:t.subject}))).slice(0,2000))
```

**Record:**
- the number of tickets returned
- the first three `id`s (subjects may be redacted)
- **the approximate character count of the full response**

**Cross-check:** do the first three ids match the top three rows in the UI, in the
same order? Record yes/no. If the order differs, that is important — note it.

---

## T4 — Read one ticket by API

Take the first ticket id from T3:

```
javascript: fetch('/api/v2/tickets/TICKETID/comments.json').then(r=>r.json()).then(d=>JSON.stringify({n:d.comments.length, first:(d.comments[0].plain_body||'').length, total:d.comments.reduce((a,c)=>a+(c.plain_body||'').length,0)}))
```

**Record:** comment count, and total body characters. **Do not paste the bodies.**

**Cross-check:** does the comment count match what the UI shows for that ticket?
Record yes/no. If the API shows fewer, note whether private/internal notes are
missing — that would matter for triage.

---

## T5 — Cost comparison, API vs accessibility tree

The point of the whole exercise. Same information, two ways.

**5a — API:** character count from T3 (queue) and T4 (one ticket). Already recorded.

**5b — Scoped AX read** of the same ticket list page:

```
get_window_state: pid=..., window_id=..., include_screenshot=false,
                  max_elements=300, max_depth=10, query="ticket"
```

**Record:** `element_count`, `filtered_element_count`, and the approximate
character count of `tree_markdown`.

**5c — Unscoped AX read** — run once, purely to quantify the ceiling:

```
get_window_state: pid=..., window_id=..., include_screenshot=false
```

**Record:** `element_count` and approximate character count. If it truncates,
record that it truncated and at what size.

**Report the ratio.** Characters for 5a vs 5b vs 5c. This is the number the
architecture decision turns on.

---

## T6 — URL navigation reliability (fallback branch — run regardless)

A prior run reported `set_value` on address bar element `@4` + Enter as 100%
reliable. Verify at slightly larger N and check the assumption underneath it.

For **five** ticket ids from T3 (or from the UI if T1 failed):

1. Read the address bar element index fresh each time — do **not** assume `@4`.
   Record the index you actually found on each iteration.
2. `set_value` the full URL `https://YOURORG.zendesk.com/agent/tickets/{id}`, press Enter.
3. Confirm arrival: `location.href` via T0's method, or the page title if JS is unavailable.

**Record:** 5 rows of `(attempt, address-bar index found, navigated ok?, seconds)`.

**The real question:** was the address bar index stable at `@4` across all five,
or did it move? A navigation method that depends on a fixed index inherits the
same drift problem it was meant to solve.

---

## T7 — Quantify AX index drift

Capture the ticket list **five times**, ~10 seconds apart, without interacting.

```
get_window_state: include_screenshot=false, max_elements=300, max_depth=10, query="ticket"
```

**Record:** for one specific ticket (same id each time), its `element_index` on
each of the five captures.

**Report:** how many distinct indices the same ticket occupied. A prior run saw
`@117 / @121 / @95`. Confirm or refute at rest — drift with no interaction is a
much stronger result than drift after scrolling.

---

## T8 — Does `query` actually scope the payload?

Same page, two calls:

- `max_elements=300, max_depth=10`, **no** `query`
- `max_elements=300, max_depth=10`, `query="ticket"`

**Record:** `element_count`, `filtered_element_count`, and `tree_markdown`
character count for both.

**The question:** does `query` reduce the *bytes returned*, or only the rendered
markdown while the element payload stays full size? Upstream docs say it filters
the rendering. Confirm on the real response.

---

## T9 — Write path, without writing

**Do not perform a write.** Only confirm the token exists.

From T1's response, record whether `authenticity_token` was present.

If it was not:
```
javascript: fetch('/api/v2/users/me.json').then(r=>r.json()).then(d=>JSON.stringify({hasToken: !!d.user.authenticity_token}))
```

**Record:** true/false. This tells us whether an API write path exists *if we
later decide we want one* — it does not authorise using it.

---

## T10 — One end-to-end timing, both ways

Task: **"list the ids and statuses of the top 3 unsolved tickets."**

- **10a — API path:** T3's single call. Record wall-clock seconds and the prompt
  token count reported by the server for that turn.
- **10b — GUI path:** navigate to the view and read the list via scoped AX.
  Record wall-clock seconds and prompt tokens.

**Record both.** If 10a is unavailable because T1 failed, record 10b alone and say so.

---

## Results template

Write to `local/test-results/zendesk-probe.md`:

```markdown
# Zendesk probe — results (YYYY-MM-DD)

## Setup
S1 Apple Events JS: [already on | enabled by me | could not enable — why]
S2 LEGACY_PAGE_MUTATIONS=1: [yes | no — why]
S3 pid / window_id:
S4 target_url_contains used: yes

## T0 channel proof
Command:
Raw response (first 300 chars):
Verdict: PASS | FAIL — reason

## T1 same-origin API
... (one block per test: command, raw response, verdict)

## Summary table
| Test | Result | Evidence |
|------|--------|----------|

## Numbers that matter
- API queue response: ____ chars
- Scoped AX read:     ____ chars
- Unscoped AX read:   ____ chars (truncated? ____)
- Ratio API : scoped : unscoped =
- Address bar index stable across 5 runs? ____
- Distinct indices for one ticket across 5 at-rest captures: ____

## Things that surprised me
(observations that do not fit the plan — these are often the most valuable part)

## Proposed skill changes
(describe only — do NOT edit SKILL.md files)
```

---

## What this plan deliberately does not do

- Does not modify tickets, submit, send, or apply macros.
- Does not edit skills — proposals go in the results file for human review.
- Does not test Jira, Redash or Grafana. Zendesk is the core environment; getting
  it right first means the others can be approached with a known-good pattern
  rather than four parallel unknowns.
- Does not build a replay engine. Replay is only worth building once we know
  whether navigation is even needed for reads.
