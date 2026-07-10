# work-agent

A fully local AI agent stack for a support-engineer workflow on Apple Silicon
(48 GB): Hermes CLI + LM Studio + Qwen3.6-35B-A3B + DOM-based browser control.

No cloud inference. No data leaves the machine. This repo is the public
bootstrap artifact — clone it on the target machine and follow the spec.
Machine-specific configuration (site adapters, selectors, runbooks) lives in
a git-ignored `local/` directory and is never committed here.

## Start here

- **Design spec:** [docs/superpowers/specs/2026-07-10-work-agent-design.md](docs/superpowers/specs/2026-07-10-work-agent-design.md)

## Stack at a glance

| Component | Role |
|-----------|------|
| [LM Studio](https://lmstudio.ai) | Local inference server (OpenAI-compatible, chat templates, tool-call parsing, KV-cache quant) |
| Qwen3.6-35B-A3B 4-bit MLX | The model — MoE, fast per-step latency in long agent loops |
| [Hermes CLI](https://github.com/NousResearch/hermes-agent) | Agent harness — skills, memory, subagents; both coding and operating |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | DOM/accessibility-tree browser control via CDP against the real browser profile |
| `cliclick` | OS-level cursor fallback for sites that reject synthetic input |
