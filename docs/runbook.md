# Work-machine runbook

Each phase gates the next. Do not skip verification steps.

## Phase 0 — Preflight
- [ ] Confirm employer policy permits locally-run models and browser
      automation on this machine. Everything below is on-device, but the
      check is yours to make.
- [ ] Clone this repo to `~/work-agent` (or adjust `skills.external_dirs`
      in the Hermes config to match your path).
- [ ] If the network does TLS interception (corporate proxy), trust the
      proxy cert in the system keychain first — otherwise `curl` downloads
      in the installer fail on certificate errors.

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
      substituting `__HOME__` by hand is how typos get in on a machine with
      no clipboard
- [ ] `bash setup/03-verify.sh` → all checks PASS
- [ ] **Gate:** the `system-only prompt` check must PASS. It is the B-probe —
      if it fails you are still on the MLX build and hit the mlx-vlm jinja bug
      (`No user query found in messages`). Under llama.cpp this should be
      impossible — if it fires, something is still serving on `:8080`. The
      plain tool-call check passes either way, so do not read it as proof the
      stack is good.
- [ ] **Gate:** the `model accepts image input` check must PASS if you intend
      to fall back to pixels in Phase 2 — it means the mmproj projector
      loaded (`config/llama-server.md`). The accessibility-tree path does not
      need it.
- [ ] **Gate:** give Hermes a real multi-step coding task (e.g. "write and test a script that parses a sample pcap with tshark"). It must complete without stalling. If it stalls, see `config/llama-server.md` before proceeding.
      Note: `tshark` isn't installed by `01-install.sh` — Wireshark's bundle has it at
      `/Applications/Wireshark.app/Contents/MacOS/tshark` (add to PATH), or pick any
      other multi-step task; the gate is about sustained tool-calling, not pcaps.

## Phase 2 — Computer use (browser control)
Every work tool enforces **device posture** against the managed Chrome
profile, so the browser is driven in place: no second profile, no debug port.
`computer_use` (cua-driver) reads and clicks the real Chrome window you are
already signed into, in the background — cursor does not move, focus does not
change.

- [ ] `bash setup/04-computer-use.sh` (refuses to proceed if the Phase 1
      vision probe is failing — fix the mmproj rather than working around it)
- [ ] Grant **Accessibility** and **Automation** to your terminal app, then
      FULLY QUIT and reopen it — macOS only re-reads these grants on process
      start, so a running terminal keeps failing silently after you tick the
      box. Screen Recording is optional: it is needed only for screenshots,
      and the accessibility tree is the default path.
- [ ] `hermes computer-use doctor` → all checks green
- [ ] Read `skills/screen-ops/SKILL.md` and fill in the blast-radius policy at
      the bottom. It ships deliberately unfinished; until it is written the
      skill treats every non-browser app as off limits.
- [ ] Sign into your work tools in Chrome as normal (as a human, once)
- [ ] `hermes -t computer_use chat`; ask it to read one ticket title back
- [ ] **Gate:** Hermes reads Zendesk from your logged-in session, and your
      cursor never moves. If the cursor jumps, cua-driver is not the path
      being used — recheck the tool actually loaded.

### Why not Playwright, CDP, or a dedicated profile
All three were tried and all three break posture:
- **Dedicated profile / bundled Chromium** — an unmanaged profile;
  conditional access rejects it.
- **CDP attach** — Chrome 136+ refuses `--remote-debugging-port` on the
  default user-data-dir, and policy may strip the flag. Confirmed failing
  2026-07-10 and again 2026-08-05.

Playwright was removed from the stack on 2026-08-05 for this reason. DOM
access is still available where the accessibility tree is insufficient — via
the `javascript` param / `page` tool, which query the real browser through
Apple Events. See `skills/browser-ops/SKILL.md`.

## Phase 3 — Per-site probe
- [ ] `mkdir -p local && cp config/sites.yaml.example local/sites.yaml`
- [ ] For each of the five webapps, classify the PERCEPTION layer it needs
      (AX tree / DOM-via-JS / pixels) per `skills/browser-ops/SKILL.md` and
      record layer + dated notes
- [ ] **Gate:** every site classified in `local/sites.yaml`

## Phase 4 — Ticket triage milestone
- [ ] Create `local/triage.md` per the template section in `skills/ticket-triage/SKILL.md`
- [ ] Run `/ticket-triage` on three real tickets
- [ ] **Gate:** three usable drafts, zero sends. The flywheel is live —
      from here, ask Hermes to build the next skill.
