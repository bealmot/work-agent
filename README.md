# work-agent

A fully local AI agent stack for a support-engineer workflow on Apple Silicon
(48 GB): Hermes CLI + llama.cpp + Qwen3.6-35B-A3B + in-place control of the
real managed Chrome.

Work tools enforce device posture, so the browser is driven where it already
is — no automation profile, no debug port. See `docs/runbook.md` Phase 2.

No cloud inference. No data leaves the machine. This repo is the public
bootstrap artifact — clone it on the target machine and follow the spec.
Machine-specific configuration (site adapters, selectors, runbooks) lives in
a git-ignored `local/` directory and is never committed here.

## Start here

1. **Design spec:** [docs/superpowers/specs/2026-07-10-work-agent-design.md](docs/superpowers/specs/2026-07-10-work-agent-design.md)
2. **Work-machine runbook:** [docs/runbook.md](docs/runbook.md) — the ordered setup + verification procedure

## Stack at a glance

| Component | Role |
|-----------|------|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`) | Local inference server, OpenAI-compatible on `:8080`. Replaced LM Studio — every runtime choice is an explicit flag (`config/llama-server.md`) |
| Qwen3.6-35B-A3B-MTP GGUF (Q4_K_M) + mmproj | The model — MoE, fast per-step latency in long agent loops. GGUF, **not** MLX (see `setup/02-model.sh` for why). MTP head gives self-speculative decoding |
| [Hermes CLI](https://github.com/NousResearch/hermes-agent) | Agent harness — skills, memory, subagents; both coding and operating |
| [cua-driver](https://github.com/trycua/cua) via `hermes computer_use` | **The only browser path.** Drives the real managed Chrome in place — accessibility tree, DOM via Apple Events, pixels last. Background: no cursor movement, no focus steal |
