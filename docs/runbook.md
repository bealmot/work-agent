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
- [ ] Try first: quit Chrome fully, run `bash scripts/chrome-debug.sh`, log into your work tools as normal. This attaches to your real profile via CDP, but on Chrome 136+ the default profile typically refuses `--remote-debugging-port` (some managed/older installs still allow it, which is why it's worth trying first).
- [ ] Start `hermes`; ask it to open your ticket queue and read one ticket title back
- [ ] **Gate:** Hermes navigates and reads Zendesk in your logged-in session
- [ ] **Expected path on current Chrome (136+):** if the CDP attach is refused, fall back to a dedicated persistent Playwright profile — remove `--cdp-endpoint` from the Hermes config so Playwright MCP launches its own browser; log into your work tools once in that browser and state persists from then on.

## Phase 3 — Per-site probe
- [ ] `mkdir -p local && cp config/sites.yaml.example local/sites.yaml`
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
