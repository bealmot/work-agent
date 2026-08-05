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
| `-fa on` | — | Flash attention. Helps on its own; the penalty is FA *combined with* quantized KV |
| `-ctk/-ctv` | **f16** | Deliberately unquantized — see "The KV cache trap" below. Override with `WORK_AGENT_KV` |
| `-c` | 65536 | Hermes requires ≥64k; agent loops need the room |
| `--cache-reuse 256` | — | Reuses the stable system+skills prefix across turns instead of re-prefilling it |
| `--keep -1` | — | Pins the initial prompt (see cache caveat below) |
| `--jinja` | *default on* | Not passed explicitly — llama-server enables it already |
| `--context-shift` | *default off* | Left off deliberately: shifting a context holding a rolling window of screenshots discards images mid-task. Fail loudly instead |

## Performance

**Prefill is compute-bound; decode is memory-bandwidth-bound.** On this
hardware those land very differently: the M4 Pro has strong GPU compute
relative to its ~273 GB/s of bandwidth, so it reads a screenshot fast and then
generates tokens comparatively slowly.

Measured on the work machine 2026-08-05: prompt processing fast, decode slow.
An earlier version of this document predicted the opposite — that computer-use
loops would be prefill-bound — and that was wrong. Capping `--image-max-tokens`
helps prefill, but prefill was not where the time was going.

Diagnose before tuning: compare **time-to-first-token** against **tok/s**, and
take the numbers from `llama-bench` rather than from inside an agent loop,
where variable context depth, tool latency, and screenshots all confound the
reading. Decode also slows as the KV grows, so fix the context depth when
comparing configurations.

### The KV cache trap

`-ctk q8_0 -ctv q8_0` halves the KV footprint and *requires* `-fa on` to avoid
dequantizing on every attention op — which makes the two flags look mutually
justifying. On Apple Silicon they are not: Metal has no optimized
quantized-KV flash-attention kernel, and the pair measures **~1/3 slower token
generation** ([#8918](https://github.com/ggml-org/llama.cpp/issues/8918)).

Keep `-fa on`. Leave KV at `f16`. Trading ~3 GB for a third of decode speed is
a bad deal on a 48 GB machine, and quantization is a memory-saving measure
being applied to the bandwidth-bound half of the workload.

### Checking that MTP actually engaged

`--spec-type draft-mtp` is worth nothing if the head never attached.
llama-server prints a draft acceptance rate (e.g. `0.57576, 171 accepted / 297
generated`):

- **>0.6** — working. Structured tool-call output should score well.
- **Low** — speculative decoding is net-negative; you pay draft cost for
  discarded tokens. Set `WORK_AGENT_SPEC=off`.
- **No stats at all** — it never engaged.

### Cheap things to rule out first

- Plugged in, Low Power Mode off — battery and LPM throttle the GPU hard.
- All layers offloaded to GPU in the startup log. An expert on the CPU
  collapses decode.
- No swapping. ~20 GB of weights plus KV plus Chrome plus screenshots is
  tighter on 48 GB than it looks, and if it swaps nothing else matters.

### Order of impact for computer use

1. **KV at f16** (above) — the largest single decode factor found so far.
2. **`--spec-type draft-mtp`**, once verified as engaging.
3. **`--image-max-tokens`** — lower until SOM element numbers stop being
   legible. Prefill is not the bottleneck today, but images also consume the
   context whose growth slows decode.
4. **Prefer `mode="ax"` over screenshots** where the app has a usable
   accessibility tree. See `skills/screen-ops/SKILL.md`.
5. **Take fewer steps.** Layer 1 DOM perception is 1–2 orders of magnitude
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
