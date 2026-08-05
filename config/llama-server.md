# llama-server tuning

All serving configuration lives in `scripts/serve.sh` as flags. There is no
GUI and no per-model settings store — the launch command *is* the config.
This file explains the choices; change them via the `WORK_AGENT_*` env vars
the script reads.

## Why not LM Studio

LM Studio was the original serving layer and was removed. It chose the runtime
for you — MLX vs GGUF, chat-template handling, whether a projector got paired —
and when a choice was wrong the failure surfaced three layers up as something
unrelated. The July 2026 outage is the canonical example: LM Studio silently
loaded the MLX build, mlx-vlm rejected Hermes' system-only calls, and it
presented as a jinja template error. Under llama-server those decisions are
explicit flags, so they are debuggable and greppable.

## Flags

| Flag | Value | Why |
|---|---|---|
| `-hf <repo>:<quant>` | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_M` | Downloads and caches weights; auto-fetches the mmproj projector from the same repo |
| `--spec-type draft-mtp` | on | Self-speculative decoding via the bundled MTP head — ~1.4–2.2× faster generation, no quality loss, no separate draft model |
| `--image-max-tokens` | 1024 | Caps vision-prefill cost per screenshot. **The main computer-use latency dial** |
| `-ngl all` | — | Unified memory: all layers on the GPU |
| `-fa on` | — | Flash attention; required for the quantized KV below |
| `-ctk/-ctv q8_0` | — | Halves KV footprint. The old "KV quant off" rule was mlx-vlm-only and no longer applies |
| `-c` | 65536 | Hermes requires ≥64k; agent loops need the room |
| `--cache-reuse 256` | — | Reuses the stable system+skills prefix across turns instead of re-prefilling it |
| `--keep -1` | — | Pins the initial prompt (see cache caveat below) |
| `--jinja` | *default on* | Not passed explicitly — llama-server enables it already |
| `--context-shift` | *default off* | Left off deliberately: shifting a context holding a rolling window of screenshots discards images mid-task. Fail loudly instead |

## Performance: what actually matters

Computer-use loops are **prefill-bound, not decode-bound**. This model
activates ~3B params per token, so it generates quickly but spends real time
*reading* each screenshot.

Diagnose before tuning: compare **time-to-first-token** against **tok/s**. If
TTFT dominates while tok/s looks healthy, decode-side work (`--spec-type`,
quantization) is close to wasted effort and `--image-max-tokens` is your lever.

In rough order of impact for computer use:

1. **`--image-max-tokens`** — lower until SOM element numbers stop being
   legible. A full Retina capture is mostly wasted pixels for reading marks.
2. **Prefer `mode="ax"` over screenshots** where the app has a usable
   accessibility tree — text prefill instead of image prefill. See
   `skills/screen-ops/SKILL.md`.
3. **`--spec-type draft-mtp`** — the decode-side win, once prefill is handled.
4. **Take fewer steps.** Layer 1 DOM perception is 1–2 orders of magnitude
   cheaper than a screenshot round-trip. The escalation discipline in
   `skills/browser-ops/SKILL.md` is a performance feature, not just a safety one.

## Known caveat: prompt cache

llama.cpp [#23030](https://github.com/ggml-org/llama.cpp/issues/23030) — the
prompt cache is dropped rather than reused for this model family when the
context is truncated (`failed to truncate tokens with position >= N - clearing
the memory`). Open, closed as *not planned*, so don't architect around caching
working.

`--keep -1` mitigates it partially by pinning the prefix. The real lever is
keeping images small enough that you never approach the limit — which is the
same fix as everything else on this page.

## Verifying

`setup/03-verify.sh` probes the endpoint, tool-calling, the system-only path
(the check that distinguishes GGUF from MLX), and image input. Trust the
probes over any of the above claims.
