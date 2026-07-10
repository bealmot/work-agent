---
name: ticket-triage
description: Triage an assigned support ticket end-to-end — read the ticket, gather log/dashboard context, draft an internal note. Use when asked to triage, investigate, or summarize a ticket.
---

# Ticket Triage

Follow browser-ops for every browser interaction. Output is a DRAFT internal
note — never send or submit anything customer-facing.

## Local specifics
Read `local/triage.md` first. It defines (on the work machine only):
the ticket queue URL, which Kibana index/saved-searches to use, which
Grafana dashboards map to which products, and the internal note template.
If `local/triage.md` is missing, stop and ask the user to create it from
this file's "Local file template" section below.

## Procedure
1. **Read the ticket.** Open the ticket URL (or the queue and pick the
   assigned ticket). Extract: customer, product/component, timeframe,
   symptom description, any error strings or attachment names.
2. **Gather context.**
   - Kibana: search the relevant index for the customer/timeframe/error
     strings from step 1. Capture the 3–5 most relevant log lines verbatim.
   - Grafana: open the dashboard mapped to the product; note any panel in
     an abnormal state during the timeframe (read values from the DOM
     legend/tooltips; if a panel is canvas-only, note that it needs a
     human look — do not guess).
3. **Synthesize.** Correlate symptom ↔ logs ↔ metrics. State a working
   hypothesis and what evidence supports or contradicts it. Say "no
   correlation found" when that is the truth.
4. **Draft the internal note** using the template from `local/triage.md`:
   summary, evidence (with timestamps), hypothesis, suggested next step.
   Leave it as a draft in the ticket (do not submit) OR print it for the
   user — whichever `local/triage.md` specifies.
5. **Report** to the user: link to ticket, the draft, and anything you
   could not verify.

## Local file template
When the user needs to create `local/triage.md`, it must define:
- `queue_url:` — where assigned tickets live
- `kibana:` — index patterns / saved searches per product
- `grafana:` — product → dashboard URL map
- `note_template:` — the team's internal note format
- `delivery:` — "draft-in-ticket" or "print-only"
