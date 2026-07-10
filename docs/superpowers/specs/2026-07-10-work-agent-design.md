# work-agent — Local Support-Engineer Agent Stack

**Date:** 2026-07-10
**Status:** Approved design, pre-implementation
**Target:** MacBook Pro M4, 48 GB unified memory, fully local inference

## Problem

A support engineer's daily workflow lives in browser-based tools (Zendesk,
Outlook on the web, Redash, Grafana, Kibana, a webapp management interface)
plus Wireshark. Cloud coding agents are unavailable in this environment, so
the goal is a fully local agent stack that can (a) act as a coding agent to
build its own tooling, and (b) operate the browser-based support workflow.

Prior attempts used pixel-based computer use (screenshot → VLM → click) with
a local model and repeatedly stalled: the agent stops emitting tool calls and
"thinks in circles." Root causes identified: per-step screenshot tokens
bloating context, weak server-side chat-template/tool-call handling in
`mlx_lm.server`, and unsuitable sampling defaults for repetitive
observation-action loops.

## Design decision

Drop pixel-based computer use as the primary mechanism. Drive the user's
real, logged-in browser through its DOM/accessibility tree as text, with a
layered actuation model for sites that resist synthetic input. No vision
model in the loop.

Constraint honored throughout: **no data transfer onto the work machine.**
Everything arrives via public downloads (this repo, LM Studio, models,
Homebrew packages). No work data, credentials, or personal data ever lives in
this repo.

## Architecture

```
┌────────────┐   OpenAI API    ┌───────────────────────────┐
│ Hermes CLI │ ──────────────▶ │ LM Studio (localhost:1234)│
│ (harness + │                 │ Qwen3.6-35B-A3B 4-bit MLX │
│  skills)   │                 └───────────────────────────┘
│            │   MCP (stdio)   ┌───────────────────────────┐
│            │ ──────────────▶ │ Playwright MCP ──CDP──▶   │
│            │                 │ user's real Chrome profile│
│            │   Bash tool     ┌───────────────────────────┐
│            │ ──────────────▶ │ cliclick / tshark / etc.  │
└────────────┘                 └───────────────────────────┘
```

### 1. Delivery

- This repo (`bealmot/work-agent`, public) is the bootstrap artifact: spec,
  setup scripts, skill templates. The work machine clones it.
- Generic improvements built at work are re-authored by the user and
  contributed back here. Work-specific configuration (site adapters with
  internal URLs, selectors, runbooks) stays local on the work machine in a
  git-ignored `local/` directory.

### 2. Runtime stack

- **LM Studio** as the inference server, OpenAI-compatible API on
  `localhost:1234`. Chosen over `mlx_lm.server` for: correct chat templates,
  native tool-call parsing, KV-cache quantization, context-overflow policy,
  and server-side sampling defaults.
- **Model:** Qwen3.6-35B-A3B, 4-bit MLX (~19 GB). MoE with ~3B active params
  keeps per-step latency low across long agent loops; fits 48 GB with
  headroom for browser + tools.
- **Server-side settings (starting points, to be tuned):**
  - temperature 0.7, min-p 0.05, repeat penalty 1.05
  - KV cache quantized to 8-bit
  - context ≥ 32k, overflow policy: truncate middle
- **Hermes CLI** (NousResearch/hermes-agent, public GitHub) pointed at the
  LM Studio endpoint as a custom OpenAI-compatible provider. One harness for
  both building tools and running support workflows.

### 3. Browser control — layered actuation

- **Layer 1 (default): DOM perception, DOM action.** Playwright MCP
  connected over CDP to the user's already-running Chrome profile (not a
  fresh automation profile). SSO sessions carry over; most bot-detection
  heuristics (fresh profile, `navigator.webdriver`, empty history) don't
  fire. Perception = accessibility-tree snapshot (compact text). Action =
  element-ref click/type.
- **Layer 2 (per-site fallback): DOM perception, OS-level actuation.** For
  sites that reject synthetic events: read the target element's bounding box
  from the DOM, then move the real cursor and click with `cliclick`
  (Homebrew). Input events are genuine OS events; still no vision model. A
  per-site config (`local/sites.yaml`) records which apps need Layer 2.
- **Layer 3 (deferred): screenshot read-only.** A small VLM for one-shot
  reads of canvas-only content (e.g. some Grafana panels). Read-only, never
  driving clicks. Not built until a real task demands it.

### 4. Hermes configuration and anti-stall guards

- Existing user-written skills (agentskills.io-compatible format) slot into
  Hermes' skill directory on the work machine.
- The browser-operation skill embeds loop guards:
  - hard max-steps per task
  - "same action twice in a row → stop and reassess" rule
  - stale page snapshots trimmed from context each turn (only the latest
    snapshot is retained)

### 5. First milestone — ticket triage

End-to-end proof: Hermes opens an assigned Zendesk ticket (Layer 1), pulls
relevant Kibana query results and Grafana dashboard state for the
customer/timeframe, and drafts an internal note. **Draft only — a human
reviews and sends.** This constraint holds until the stack has an
established track record.

### 6. Build order (each phase verified before the next)

| # | Phase | Verify |
|---|-------|--------|
| 1 | LM Studio + model + Hermes wired up | Multi-turn tool-calling coding task completes without stall |
| 2 | Playwright MCP over CDP | Agent reads and navigates Zendesk in the logged-in session |
| 3 | Per-site probe | Each of the five webapps classified: DOM actions OK vs needs Layer 2; recorded in `local/sites.yaml` |
| 4 | Layer 2 (`cliclick`) | Sites flagged in phase 3 operable via OS-level input |
| 5 | Ticket-triage skill | Three real tickets triaged with usable drafts |

## Error handling

- Agent-level: loop guards above; on max-steps, the agent stops and reports
  state rather than continuing.
- Browser-level: every Playwright action failure returns the error text to
  the model (fail loud); the skill instructs re-snapshot before retry, one
  retry max, then escalate to the user.
- Server-level: LM Studio overflow policy prevents silent context-death;
  Hermes `/usage` monitored during long tasks.

## Out of scope

- Pixel-based computer use as a driving mechanism
- Any automated *sending* of customer-facing communication
- Work-specific selectors, URLs, or data in this repo
- Fine-tuning or training (revisit after the flywheel produces trajectories)

## Open questions / risks

- Employer policy on locally-run models and browser automation should be
  verified by the user before production use. All inference is on-device,
  which is the strongest posture, but the check is the user's to make.
- Qwen3.6-35B-A3B tool-calling quality through LM Studio's template is
  assumed good based on prior use via mlx_lm; phase 1 verifies it.
- CDP-attach to a running Chrome requires launching Chrome with
  `--remote-debugging-port`; if corporate policy blocks that flag, fall back
  to a persistent dedicated Playwright profile (logs in once, keeps state).
