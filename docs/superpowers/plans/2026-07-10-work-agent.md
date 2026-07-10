# work-agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the public bootstrap repo (scripts, configs, skill templates) that assembles a fully local support-engineer agent stack — LM Studio + Qwen3.6-35B-A3B + Hermes CLI + layered Playwright browser control — on a 48 GB Apple Silicon work machine.

**Architecture:** Everything in this repo is generic and public; the work machine clones it and runs the setup scripts. Hermes CLI is the harness, pointed at LM Studio's OpenAI-compatible endpoint (`provider: lmstudio`). Browser control is layered: Playwright MCP over CDP against the user's real Chrome profile (Layer 1, DOM in/DOM out), with an OS-level `cliclick` fallback whose coordinates are derived from the DOM (Layer 2). Work-specific data (site selectors, runbooks) lives only in a git-ignored `local/` directory on the work machine.

**Tech Stack:** bash, Python 3 (stdlib only for helpers; pytest for tests), Hermes CLI (NousResearch/hermes-agent), LM Studio + `lms` CLI, `@playwright/mcp`, `cliclick`, Homebrew.

## Global Constraints

- No work data, credentials, internal URLs, or selectors in this repo — generic templates only; specifics go in `local/` (git-ignored).
- All scripts idempotent: safe to run twice, "ensure exists" not "append/install blindly".
- Fail loud: `set -euo pipefail` in every bash script; no silent error swallows.
- Skill files follow the agentskills.io format Hermes uses: a directory per skill containing `SKILL.md` with YAML frontmatter (`name`, `description`).
- Hermes config keys must match `cli-config.yaml.example` from NousResearch/hermes-agent: `model.provider: "lmstudio"`, `model.base_url`, `skills.external_dirs`, `mcp_servers.<name>.command/args`.
- Python helpers: stdlib only (the work machine may not have network-permitted pip); tests with pytest via `uv run --with pytest`.
- Commits: conventional format, lowercase, imperative, <72 chars.
- The plan builds and tests everything possible on the dev machine; steps that require the work machine (real model load, real sites) are captured in `docs/runbook.md`, not silently skipped.

---

### Task 1: Installer script

**Files:**
- Create: `setup/01-install.sh`

**Interfaces:**
- Produces: an idempotent installer later tasks assume has run (`brew` casks/packages: `lm-studio`, `cliclick`, `node`, `uv`; Hermes CLI; Playwright MCP npx cache; `lms` CLI bootstrapped).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# work-agent installer — idempotent; safe to re-run.
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

have brew || { echo "ERROR: install Homebrew first: https://brew.sh" >&2; exit 1; }

echo "==> Casks and packages"
brew list --cask lm-studio >/dev/null 2>&1 || brew install --cask lm-studio
for pkg in cliclick node uv; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

echo "==> lms CLI (LM Studio's command-line interface)"
if [ -x "$HOME/.lmstudio/bin/lms" ]; then
  echo "    lms present"
else
  echo "    ACTION REQUIRED: open LM Studio once (creates ~/.lmstudio),"
  echo "    then run: ~/.lmstudio/bin/lms bootstrap"
fi

echo "==> Hermes CLI"
if have hermes; then
  echo "    hermes present"
else
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
fi

echo "==> Playwright MCP (prime the npx cache)"
npx -y @playwright/mcp@latest --version

echo "==> Done. Next: setup/02-model.sh"
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n setup/01-install.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Idempotency spot-check (dev machine)**

Run: `bash setup/01-install.sh` twice on the dev machine.
Expected: second run performs no installs, only "present" messages (LM Studio cask may install fresh the first time — acceptable).

- [ ] **Step 4: Commit**

```bash
git add setup/01-install.sh
git commit -m "feat: idempotent installer for agent stack dependencies"
```

---

### Task 2: Model download/serve script + LM Studio settings doc

**Files:**
- Create: `setup/02-model.sh`
- Create: `config/lmstudio-settings.md`

**Interfaces:**
- Consumes: `lms` CLI from Task 1.
- Produces: LM Studio serving the model on `http://localhost:1234/v1` with 32k context; a settings doc the runbook references.

- [ ] **Step 1: Write `setup/02-model.sh`**

```bash
#!/usr/bin/env bash
# Download (if needed), load, and serve the model via LM Studio.
set -euo pipefail

LMS="$HOME/.lmstudio/bin/lms"
[ -x "$LMS" ] || { echo "ERROR: lms not found — run setup/01-install.sh first" >&2; exit 1; }

# Exact catalog name may drift; override with WORK_AGENT_MODEL.
# Find candidates with: lms get qwen3.6 (interactive search)
MODEL="${WORK_AGENT_MODEL:-qwen3.6-35b-a3b-mlx}"

echo "==> Server"
"$LMS" server start || true   # no-op if already running

echo "==> Model download (skips if cached)"
"$LMS" get "$MODEL" --yes || {
  echo "ERROR: '$MODEL' not found in catalog. Search with: lms get qwen3.6" >&2
  exit 1
}

echo "==> Load with 32k context"
"$LMS" load "$MODEL" --context-length 32768 --yes

echo "==> Verify endpoint"
curl -sf http://localhost:1234/v1/models | grep -qi "qwen" \
  && echo "OK: model serving on http://localhost:1234/v1" \
  || { echo "ERROR: endpoint up but model not listed" >&2; exit 1; }
```

- [ ] **Step 2: Write `config/lmstudio-settings.md`**

```markdown
# LM Studio settings (set once in the GUI)

These cannot all be set from `lms`; configure them as the model's
**per-model defaults** (My Models → gear icon → Inference) so every
client request inherits them.

## Inference (anti-stall starting points — tune from here)
| Setting | Value | Why |
|---------|-------|-----|
| Temperature | 0.7 | Enough variance to escape action loops |
| Min-P | 0.05 | Cuts the degenerate tail without killing diversity |
| Repeat penalty | 1.05 | Mild — discourages literal action repetition |
| Context length | 32768 | Agent loops need room; below ~16k Hermes compresses constantly |

## App settings
| Setting | Value | Why |
|---------|-------|-----|
| KV cache quantization | 8-bit | ~halves KV memory at 32k context; negligible quality loss |
| Context overflow | Truncate middle | Keeps system prompt + recent turns; prevents silent context-death stalls |
| Keep model loaded | On | Avoids reload latency between tasks |

## Verification
`setup/03-verify.sh` exercises the endpoint including a tool-call
round-trip. If tool calls come back malformed, check that the model's
prompt template in LM Studio is the built-in Qwen3.6 template, not a
generic fallback.
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n setup/02-model.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add setup/02-model.sh config/lmstudio-settings.md
git commit -m "feat: model serve script and lm studio settings doc"
```

---

### Task 3: Hermes config template

**Files:**
- Create: `config/cli-config.yaml`

**Interfaces:**
- Consumes: LM Studio endpoint (Task 2); skills directory (Tasks 7–8); Chrome CDP port 9222 (Task 4).
- Produces: the config the runbook copies to `~/.hermes/cli-config.yaml` (or merges into an existing one).

- [ ] **Step 1: Write the config**

```yaml
# work-agent Hermes configuration.
# Copy to ~/.hermes/cli-config.yaml (or merge if one exists).
# Keys follow NousResearch/hermes-agent cli-config.yaml.example.

model:
  default: "qwen3.6-35b-a3b-mlx"      # must match the id in `lms ps`
  provider: "lmstudio"                 # alias for custom OpenAI-compatible
  base_url: "http://localhost:1234/v1"
  context_length: 32768                # match the lms load --context-length

skills:
  creation_nudge_interval: 15
  # Read-only external skills from the cloned repo; adjust path if cloned
  # elsewhere. Hermes-created skills still write to ~/.hermes/skills/.
  external_dirs:
    - ~/work-agent/skills

agent:
  max_turns: 60

mcp_servers:
  playwright:
    command: npx
    args:
      - "-y"
      - "@playwright/mcp@latest"
      - "--cdp-endpoint"
      - "http://localhost:9222"
    timeout: 120
```

- [ ] **Step 2: Validate YAML parses**

Run: `uv run python -c "import yaml,sys; yaml.safe_load(open('config/cli-config.yaml')); print('OK')" --with pyyaml`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add config/cli-config.yaml
git commit -m "feat: hermes config template for lm studio + playwright mcp"
```

---

### Task 4: Chrome CDP launcher

**Files:**
- Create: `scripts/chrome-debug.sh`

**Interfaces:**
- Produces: Chrome (real profile) listening on CDP port 9222, which the `mcp_servers.playwright` entry in Task 3 attaches to.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Launch Chrome with CDP enabled on the user's real profile.
# Playwright MCP attaches to this via --cdp-endpoint http://localhost:9222.
set -euo pipefail

PORT="${CDP_PORT:-9222}"

if curl -sf "http://localhost:${PORT}/json/version" >/dev/null; then
  echo "OK: Chrome already listening on :${PORT}"
  exit 0
fi

if pgrep -xq "Google Chrome"; then
  echo "ERROR: Chrome is running without a debug port." >&2
  echo "Quit Chrome fully (Cmd+Q), then re-run this script." >&2
  exit 1
fi

open -a "Google Chrome" --args --remote-debugging-port="${PORT}"

for _ in $(seq 1 20); do
  if curl -sf "http://localhost:${PORT}/json/version" >/dev/null; then
    echo "OK: Chrome launched with CDP on :${PORT}"
    exit 0
  fi
  sleep 0.5
done
echo "ERROR: Chrome started but CDP port never came up (corporate policy may strip the flag)." >&2
echo "Fallback: use a dedicated persistent Playwright profile — see docs/runbook.md." >&2
exit 1
```

- [ ] **Step 2: Syntax-check, then live-test on dev machine**

Run: `bash -n scripts/chrome-debug.sh && echo OK`
Expected: `OK`
Then (dev machine, Chrome closed): `bash scripts/chrome-debug.sh`
Expected: `OK: Chrome launched with CDP on :9222`, and `curl -s localhost:9222/json/version` returns JSON.
Re-run: `bash scripts/chrome-debug.sh` → `OK: Chrome already listening on :9222` (idempotent).

- [ ] **Step 3: Commit**

```bash
git add scripts/chrome-debug.sh
git commit -m "feat: chrome cdp launcher for real-profile attach"
```

---

### Task 5: Layer-2 OS-level click helper (TDD)

**Files:**
- Create: `scripts/osclick.py`
- Test: `tests/test_osclick.py`

**Interfaces:**
- Consumes: `cliclick` binary (Task 1).
- Produces: CLI `python3 scripts/osclick.py '<json>'` where json is `{"bbox": {x,y,width,height}, "win": {screenX,screenY,outerHeight,innerHeight}, "action": "c"}`; and pure function `dom_to_screen(bbox, win) -> (int, int)` used by the browser-ops skill (Task 7). Actions are cliclick verbs: `c`=click, `dc`=double-click, `rc`=right-click, `m`=move only.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_osclick.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from osclick import dom_to_screen


def test_center_of_bbox_offset_by_window_and_chrome():
    # Window at (10, 40); browser chrome (toolbars) = outer 900 - inner 800 = 100px.
    bbox = {"x": 100, "y": 200, "width": 50, "height": 20}
    win = {"screenX": 10, "screenY": 40, "outerHeight": 900, "innerHeight": 800}
    # x: 10 + 100 + 25 = 135 ; y: 40 + 100 + 200 + 10 = 350
    assert dom_to_screen(bbox, win) == (135, 350)


def test_rounds_to_integer_pixels():
    bbox = {"x": 0.4, "y": 0.4, "width": 1, "height": 1}
    win = {"screenX": 0, "screenY": 0, "outerHeight": 100, "innerHeight": 100}
    assert dom_to_screen(bbox, win) == (1, 1)  # 0.4 + 0.5 = 0.9 -> 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run --with pytest pytest tests/test_osclick.py -v`
Expected: FAIL / error — `ModuleNotFoundError: No module named 'osclick'`

- [ ] **Step 3: Write the implementation**

```python
#!/usr/bin/env python3
"""Layer-2 actuation: DOM bounding box -> real OS cursor click via cliclick.

Perception stays in the DOM (Playwright reads the element's bbox and window
metrics); only the input event is OS-level, so sites that reject synthetic
events see a genuine click. macOS screen coordinates are points, which match
CSS pixels at default page zoom — keep page zoom at 100%.

Usage:
  python3 osclick.py '{"bbox": {"x":100,"y":200,"width":50,"height":20},
                       "win": {"screenX":10,"screenY":40,
                                "outerHeight":900,"innerHeight":800},
                       "action": "c"}'

Get `win` in the page via:
  ({screenX: window.screenX, screenY: window.screenY,
    outerHeight: window.outerHeight, innerHeight: window.innerHeight})
"""
import json
import subprocess
import sys


def dom_to_screen(bbox, win):
    """Return integer screen coords of the bbox center.

    The browser chrome (tab strip, toolbars) sits between the window origin
    and the viewport; its height is outerHeight - innerHeight.
    """
    chrome_height = win["outerHeight"] - win["innerHeight"]
    x = win["screenX"] + bbox["x"] + bbox["width"] / 2
    y = win["screenY"] + chrome_height + bbox["y"] + bbox["height"] / 2
    return round(x), round(y)


def actuate(x, y, action="c"):
    subprocess.run(["cliclick", f"{action}:{x},{y}"], check=True)


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    data = json.loads(sys.argv[1])
    x, y = dom_to_screen(data["bbox"], data["win"])
    actuate(x, y, data.get("action", "c"))
    print(json.dumps({"action": data.get("action", "c"), "screen": [x, y]}))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run --with pytest pytest tests/test_osclick.py -v`
Expected: 2 passed

- [ ] **Step 5: Manual smoke test (dev machine)**

Run: `python3 scripts/osclick.py '{"bbox": {"x":10,"y":10,"width":2,"height":2}, "win": {"screenX":0,"screenY":0,"outerHeight":100,"innerHeight":100}, "action": "m"}'`
Expected: cursor visibly moves to near top-left; prints `{"action": "m", "screen": [11, 11]}`. (`m` = move only, no click.)

- [ ] **Step 6: Commit**

```bash
git add scripts/osclick.py tests/test_osclick.py
git commit -m "feat: layer-2 os-level click helper with dom-to-screen math"
```

---

### Task 6: Per-site actuation config template

**Files:**
- Create: `config/sites.yaml.example`

**Interfaces:**
- Produces: the schema the browser-ops skill (Task 7) reads from `local/sites.yaml` on the work machine.

- [ ] **Step 1: Write the template**

```yaml
# Per-site actuation config — TEMPLATE.
# Copy to local/sites.yaml on the work machine and fill in real hosts.
# local/ is git-ignored; never commit real internal hostnames.
#
# layer: 1 = DOM actions via Playwright (default, preferred)
#        2 = DOM perception + OS-level clicks via scripts/osclick.py
# probe notes: record what failed when you tried layer 1, and the date —
# sites change; re-probe when a layer-2 site gets a big UI update.

sites:
  - name: zendesk
    host: example.zendesk.com
    layer: 1
    notes: ""

  - name: outlook-web
    host: outlook.office.com
    layer: 1
    notes: ""

  - name: kibana
    host: kibana.internal.example.com
    layer: 1
    notes: ""

  - name: grafana
    host: grafana.internal.example.com
    layer: 1
    notes: "canvas panels unreadable via DOM — layer 3 candidate, read-only"

  - name: redash
    host: redash.internal.example.com
    layer: 1
    notes: ""

  - name: webapp-mgmt
    host: mgmt.internal.example.com
    layer: 2
    notes: "example: rejects synthetic events on action buttons (probed YYYY-MM-DD)"
```

- [ ] **Step 2: Validate YAML parses**

Run: `uv run python -c "import yaml; yaml.safe_load(open('config/sites.yaml.example')); print('OK')" --with pyyaml`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add config/sites.yaml.example
git commit -m "feat: per-site actuation config template"
```

---

### Task 7: browser-ops skill

**Files:**
- Create: `skills/browser-ops/SKILL.md`

**Interfaces:**
- Consumes: Playwright MCP tools (from Task 3 config), `scripts/osclick.py` (Task 5), `local/sites.yaml` (Task 6 schema).
- Produces: the operating procedure every browser task follows, including the probe procedure that classifies sites into layers.

- [ ] **Step 1: Write the skill**

```markdown
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
```

- [ ] **Step 2: Validate frontmatter parses**

Run: `uv run python -c "import yaml; t=open('skills/browser-ops/SKILL.md').read(); fm=t.split('---')[1]; d=yaml.safe_load(fm); assert d['name']=='browser-ops'; print('OK')" --with pyyaml`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add skills/browser-ops/SKILL.md
git commit -m "feat: browser-ops skill with layered actuation and loop guards"
```

---

### Task 8: ticket-triage skill template

**Files:**
- Create: `skills/ticket-triage/SKILL.md`

**Interfaces:**
- Consumes: browser-ops skill (Task 7); work-specific specifics from `local/triage.md` (created on the work machine, git-ignored).
- Produces: the milestone workflow — the generic procedure with an explicit hook for local specifics.

- [ ] **Step 1: Write the skill**

```markdown
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
```

- [ ] **Step 2: Validate frontmatter parses**

Run: `uv run python -c "import yaml; t=open('skills/ticket-triage/SKILL.md').read(); fm=t.split('---')[1]; d=yaml.safe_load(fm); assert d['name']=='ticket-triage'; print('OK')" --with pyyaml`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add skills/ticket-triage/SKILL.md
git commit -m "feat: ticket-triage skill template with local-specifics hook"
```

---

### Task 9: Verify script

**Files:**
- Create: `setup/03-verify.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: a pass/fail checklist run on the work machine after setup (phase-1 gate in the runbook).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Post-setup verification. Run after 01-install.sh and 02-model.sh.
set -uo pipefail  # no -e: run all checks, report at the end

PASS=0; FAIL=0
check() {  # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $label"; PASS=$((PASS+1))
  else
    echo "FAIL  $label"; FAIL=$((FAIL+1))
  fi
}

check "cliclick installed"        command -v cliclick
check "node installed"            command -v node
check "uv installed"              command -v uv
check "hermes installed"          command -v hermes
check "lms CLI present"           test -x "$HOME/.lmstudio/bin/lms"
check "LM Studio endpoint up"     curl -sf http://localhost:1234/v1/models
check "model loaded"              sh -c 'curl -sf http://localhost:1234/v1/models | grep -qi qwen'
check "playwright mcp cached"     npx -y @playwright/mcp@latest --version
check "chrome CDP up (optional)"  curl -sf http://localhost:9222/json/version

echo "==> Tool-call round trip"
RESP=$(curl -sf http://localhost:1234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "any",
    "messages": [{"role": "user", "content": "What time is it? Use the tool."}],
    "tools": [{"type": "function", "function": {"name": "get_time",
      "description": "Get the current time",
      "parameters": {"type": "object", "properties": {}}}}]
  }' 2>/dev/null)
if echo "$RESP" | grep -q '"tool_calls"'; then
  echo "PASS  model emits tool_calls"; PASS=$((PASS+1))
else
  echo "FAIL  model emits tool_calls — check the prompt template (see config/lmstudio-settings.md)"
  FAIL=$((FAIL+1))
fi

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n setup/03-verify.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Partial live test (dev machine)**

Run: `bash setup/03-verify.sh; echo "exit=$?"`
Expected on the dev machine: tool checks PASS where installed; LM Studio checks may FAIL (not running here) — script completes all checks and exits non-zero. Confirms the no-early-exit structure works.

- [ ] **Step 4: Commit**

```bash
git add setup/03-verify.sh
git commit -m "feat: post-setup verification script with tool-call smoke test"
```

---

### Task 10: Work-machine runbook + README update

**Files:**
- Create: `docs/runbook.md`
- Modify: `README.md` (add runbook link under "Start here")

**Interfaces:**
- Consumes: every prior task.
- Produces: the ordered, verifiable procedure the user follows on the work machine (spec phases 1–5).

- [ ] **Step 1: Write `docs/runbook.md`**

```markdown
# Work-machine runbook

Each phase gates the next. Do not skip verification steps.

## Phase 0 — Preflight
- [ ] Confirm employer policy permits locally-run models and browser
      automation on this machine. Everything below is on-device, but the
      check is yours to make.
- [ ] Clone this repo to `~/work-agent` (or adjust `skills.external_dirs`
      in the Hermes config to match your path).

## Phase 1 — Inference stack
- [ ] `bash setup/01-install.sh` (open LM Studio once + `lms bootstrap` if prompted, then re-run)
- [ ] `bash setup/02-model.sh` (set `WORK_AGENT_MODEL` if the default catalog name has drifted — search with `lms get qwen3.6`)
- [ ] Apply the GUI settings in `config/lmstudio-settings.md`
- [ ] Copy `config/cli-config.yaml` to `~/.hermes/cli-config.yaml` (merge if you already have one; set `model.default` to the exact id shown by `lms ps`)
- [ ] `bash setup/03-verify.sh` → all PASS except possibly "chrome CDP"
- [ ] **Gate:** give Hermes a real multi-step coding task (e.g. "write and test a script that parses a sample pcap with tshark"). It must complete without stalling. If it stalls, tune sampling per `config/lmstudio-settings.md` before proceeding.

## Phase 2 — Browser attach
- [ ] Quit Chrome fully, run `bash scripts/chrome-debug.sh`, log into your work tools as normal
- [ ] Start `hermes`; ask it to open your ticket queue and read one ticket title back
- [ ] **Gate:** Hermes navigates and reads Zendesk in your logged-in session
- [ ] If corporate policy strips the debug flag: fall back to a dedicated persistent Playwright profile (remove `--cdp-endpoint` from the config so Playwright MCP launches its own browser; log into your tools once in that browser — state persists)

## Phase 3 — Per-site probe
- [ ] `cp config/sites.yaml.example local/sites.yaml`
- [ ] For each of the five webapps, run the probe procedure in
      `skills/browser-ops/SKILL.md` and record layer + dated notes
- [ ] **Gate:** every site classified in `local/sites.yaml`

## Phase 4 — Layer 2 (only for sites that need it)
- [ ] Verify `python3 scripts/osclick.py` moves the cursor (action "m") at 100% page zoom
- [ ] For each `layer: 2` site: perform one harmless real click end-to-end via the browser-ops Layer 2 procedure
- [ ] **Gate:** flagged sites operable via OS-level input

## Phase 5 — Ticket triage milestone
- [ ] Create `local/triage.md` per the template section in `skills/ticket-triage/SKILL.md`
- [ ] Run `/ticket-triage` on three real tickets
- [ ] **Gate:** three usable drafts, zero sends. The flywheel is live —
      from here, ask Hermes to build the next skill.
```

- [ ] **Step 2: Update README "Start here" section**

In `README.md`, change:

```markdown
## Start here

- **Design spec:** [docs/superpowers/specs/2026-07-10-work-agent-design.md](docs/superpowers/specs/2026-07-10-work-agent-design.md)
```

to:

```markdown
## Start here

1. **Design spec:** [docs/superpowers/specs/2026-07-10-work-agent-design.md](docs/superpowers/specs/2026-07-10-work-agent-design.md)
2. **Work-machine runbook:** [docs/runbook.md](docs/runbook.md) — the ordered setup + verification procedure
```

- [ ] **Step 3: Verify links resolve**

Run: `test -f docs/runbook.md && grep -q "runbook.md" README.md && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit and push**

```bash
git add docs/runbook.md README.md
git commit -m "docs: work-machine runbook and readme start-here update"
git push
```
