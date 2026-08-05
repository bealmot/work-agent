# Work-machine runbook

Each phase gates the next. Do not skip verification steps.

## Phase 0 — Preflight
- [ ] Confirm employer policy permits locally-run models and browser
      automation on this machine. Everything below is on-device, but the
      check is yours to make.
- [ ] Clone this repo to `~/work-agent` (or adjust `skills.external_dirs`
      in the Hermes config to match your path).
- [ ] If the network does TLS interception (corporate proxy), trust the
      proxy cert in the system keychain first — otherwise `curl`/`npx`
      downloads in the installer fail on certificate errors.

## Phase 1 — Inference stack
> **Migrating from LM Studio?** It was removed in favour of llama.cpp
> (rationale in `config/llama-server.md`). Uninstall the app and delete the
> `~/.lmstudio` model cache once Phase 1 passes — leaving an MLX copy around
> is exactly how the July 2026 jinja bug happened. The Hermes endpoint also
> moves from `:1234` to `:8080`, so re-copy `cli-config.yaml` rather than
> hand-editing the old one.

- [ ] `bash setup/01-install.sh` (warns if the llama.cpp build lacks Metal)
- [ ] `bash setup/02-model.sh` — pre-downloads ~20 GB and confirms the server
      comes up healthy. Override the repo with `WORK_AGENT_MODEL` if needed.
- [ ] Leave `bash scripts/serve.sh` running in its own terminal. All tuning
      lives in its flags — read `config/llama-server.md` before changing any.
- [ ] `bash scripts/install-hermes-config.sh` — renders
      `config/cli-config.yaml` into `~/.hermes/cli-config.yaml` with absolute
      paths substituted, and backs up any existing config. Do not hand-copy:
      the Playwright profile path must be absolute and MCP args get no tilde
      or variable expansion
- [ ] `bash setup/03-verify.sh` → all PASS except possibly "chrome CDP"
- [ ] **Gate:** the `system-only prompt` check must PASS. It is the B-probe —
      if it fails you are still on the MLX build and hit the mlx-vlm jinja bug
      (`No user query found in messages`). Under llama.cpp this should be
      impossible — if it fires, something is still serving on `:8080`. The
      plain tool-call check passes either way, so do not read it as proof the
      stack is good.
- [ ] **Gate:** the `model accepts image input` check must PASS if you intend
      to use Phase 4b — it means the mmproj projector loaded (`config/llama-server.md`).
- [ ] **Gate:** give Hermes a real multi-step coding task (e.g. "write and test a script that parses a sample pcap with tshark"). It must complete without stalling. If it stalls, see `config/llama-server.md` before proceeding.
      Note: `tshark` isn't installed by `01-install.sh` — Wireshark's bundle has it at
      `/Applications/Wireshark.app/Contents/MacOS/tshark` (add to PATH), or pick any
      other multi-step task; the gate is about sustained tool-calling, not pcaps.

## Phase 2 — Browser attach
The default config drives the **installed Chrome against a dedicated profile**
(`~/.work-agent-profile`). Playwright launches it; there is nothing to start
by hand and no debug port involved.

- [ ] Confirm `scripts/install-hermes-config.sh` has been run (Phase 1) — it
      writes the absolute profile path, which MCP args cannot expand
- [ ] Start `hermes`; ask it to open your ticket queue
- [ ] Log into your work tools **once** in the browser window it opens. The
      profile persists from then on
- [ ] Ask it to read one ticket title back
- [ ] **Gate:** Hermes navigates and reads Zendesk in your logged-in session

### Why not CDP against your real profile
Chrome 136+ refuses `--remote-debugging-port` on the default user-data-dir as
a security change, and managed/corporate policy may strip the flag outright.
Confirmed failing here twice (2026-07-10, 2026-08-05) — `scripts/chrome-debug.sh`
remains only for installs where policy still permits it.

### Why not Playwright's bundled Chromium
SSO/conditional-access commonly rejects it as an unmanaged browser. `--browser
chrome` uses the real installed Chrome, which is what passed SSO first try on
2026-07-10.

## Phase 3 — Per-site probe
- [ ] `mkdir -p local && cp config/sites.yaml.example local/sites.yaml`
- [ ] For each of the five webapps, run the probe procedure in
      `skills/browser-ops/SKILL.md` and record layer + dated notes
- [ ] **Gate:** every site classified in `local/sites.yaml`

## Phase 4 — Layer 2 (only for sites that need it)
- [ ] Grant Accessibility permission to your terminal app (System Settings →
      Privacy & Security → Accessibility) — without it, `cliclick` events are
      silently ignored: the cursor won't move and no error is raised.
- [ ] Verify `python3 scripts/osclick.py` moves the cursor (action "m") at 100% page zoom
- [ ] For each `layer: 2` site: perform one harmless real click end-to-end via the browser-ops Layer 2 procedure
- [ ] **Gate:** flagged sites operable via OS-level input

## Phase 4b — Layer 3 / computer use (optional)
Only needed for targets with **no usable DOM**: native macOS apps, Electron
windows, canvas-rendered UIs. Anything with a DOM stays in Phase 4.
- [ ] `bash setup/04-computer-use.sh` (refuses to proceed if the vision probe
      from Phase 1 is failing — fix the mmproj first, don't work around it)
- [ ] Grant **Screen Recording** in addition to the Accessibility grant from
      Phase 4, then fully quit and reopen the terminal — macOS only re-reads
      these grants on process start, so a running terminal keeps failing
      silently even after you tick the box
- [ ] `hermes computer-use doctor` → all checks green
- [ ] Read `skills/screen-ops/SKILL.md` and fill in the blast-radius policy at
      the bottom. It ships deliberately unfinished; until it's written the
      skill treats every non-browser app as off limits.
- [ ] `hermes -t computer_use chat`, then one harmless real action in a native
      app (open a menu, focus a field — no submits)
- [ ] **Gate:** the agent captures with SOM, clicks the right element, and the
      cursor never moves. If your cursor jumps, you're on the cliclick path
      (Phase 4), not cua-driver — recheck the tool actually loaded.

## Phase 5 — Ticket triage milestone
- [ ] Create `local/triage.md` per the template section in `skills/ticket-triage/SKILL.md`
- [ ] Run `/ticket-triage` on three real tickets
- [ ] **Gate:** three usable drafts, zero sends. The flywheel is live —
      from here, ask Hermes to build the next skill.
