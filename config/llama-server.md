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
| `--jinja` | *default on* | Not passed explicitly — llama-server enables it already |
| `--context-shift` | *default off* | Force-disabled by the mmproj anyway; left unset explicitly |

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
- **All layers offloaded**, not merely "Metal exists". Two different things:

      llama-server --list-devices          # is there a Metal device at all
      # and in serve.sh's startup log:
      ggml_metal_init: found device: Apple M4 Pro
      load_tensors: offloaded 49/49 layers to GPU     # <- the one that matters

  A partial offload (`48/49`) leaves work on the CPU and collapses decode,
  and it does not look like an error. `setup/03-verify.sh` only checks the
  first of these — the offload count has to be read from the server log.
  (Note `--version` never mentions Metal; use `--list-devices`.)
- No swapping. ~20 GB of weights plus KV plus Chrome plus screenshots is
  tighter on 48 GB than it looks, and if it swaps nothing else matters.

### Order of impact for computer use

Most of the win is **above** the server, in how many tokens each step costs
and how many steps there are. Flags come second.

1. **`include_screenshot: false` on every `get_window_state`.** It defaults to
   *true*, so the "text-only" path ships a full image per call unless you say
   otherwise. (`capture_mode` is deprecated and ignored.) Removes image
   prefill from the loop entirely.
2. **No thinking tokens** — `--reasoning-budget 0` plus
   `--chat-template-kwargs '{"enable_thinking": false}'`, both set by
   `scripts/serve.sh`. A reasoning block before every GUI step is pure latency
   on the bandwidth-bound half of the workload. `WORK_AGENT_THINK=on` to
   restore it for judgment-heavy work.
3. **Scope the AX tree** — `query`, and lower `max_elements` (default 2000) /
   `max_depth` (default 25). A full page tree is thousands of tokens; a
   filtered read is tens to hundreds.
4. **Targeted DOM extraction over full-state perception** — once a site's
   selectors are known, `query_dom` returns what you need directly. Record
   them in `local/sites.yaml`.
5. **KV at f16** — the largest single *flag*-level decode factor found so far.
6. **`--spec-type draft-mtp`**, once verified as engaging.
7. **`--image-max-tokens`** — only matters on the pixel fallback now.
8. **Take fewer steps.** The fastest action is one that needs no model call:
   deterministic skills for known sequences, model involvement only for
   judgment. This dwarfs every flag on this page.

## The append-only contract — read this before tuning anything

**Caching works. Reuse with holes does not.** Ordinary longest-common-prefix
reuse is what makes later turns cheap — measured 2026-08-05: a cold turn is
~24k tokens of prefill, a warm append-only turn is a fraction of that.

What does not work is reusing a prefix you have *edited*. Qwen3.6-35B-A3B is 30
Gated-DeltaNet (recurrent) layers interleaved with 10 attention layers, and
recurrent state cannot be shifted or partially reused. So any mid-history
rewrite — pruning an old tool result, dropping a screenshot, compacting,
editing an earlier turn — invalidates the cache from the edit point and forces
a full re-prefill of everything after it.

**Context is append-only. Compression happens at write time, by emitting fewer
tokens, or it does not happen at all.** A "helpful" prune turns every
subsequent turn cold. This is the single most expensive mistake available in
this stack, and an earlier version of this document licensed it by telling the
reader not to architect around caching working. That was wrong.

Truncation is still worth avoiding —
[#23030](https://github.com/ggml-org/llama.cpp/issues/23030) drops the cache
when the context is truncated — but the fix is bounded observations, not
pruning. Bounded reads keep you clear of the ceiling, which keeps the expensive
prefix alive.

### Two flags were removed as dead

- **`--cache-reuse`** reuses cache via KV *shifting*, and llama-server forces it
  to 0 at startup when an mmproj is loaded — which this stack does, since the
  vision probe passes — logging `cache_reuse is not supported by multimodal, it
  will be disabled`. Check the startup log: that warning is confirmation, not a
  problem.
- **`--keep`** is only read inside the context-shift branch, and context shift
  is off, so `--keep -1` did nothing.

Neither removal changes behaviour. They were describing a mechanism that was
never running.

## When prompt processing is the bottleneck

Observed 2026-08-05 once decode was fixed. Prefill is what you wait for before
the first token, so it dominates felt latency in a stepping loop.

**Diagnose the prompt cache first.** The system prompt (skills) is identical
every turn and should be reused, not re-processed. llama-server reports how
many tokens were cached versus evaluated — if the stable prefix is being
re-processed each turn, nothing else matters.

The likely reason it would not be cached is
[#23030](https://github.com/ggml-org/llama.cpp/issues/23030): the cache is
dropped on truncation for this model family. Large AX-tree reads push the
context toward its limit, truncation fires, and the cache is cleared — so
every turn pays a full re-prefill. That makes tree scoping a *prefill* fix as
well as a context fix, and it is the first thing to attack.

**Then check what is constant per turn.** Every loaded skill is prefill cost
on every request. The cua-driver pack is the full tool reference and is heavy;
its own maintainers describe it as too heavy to load every time. If it is
always resident, that is a fixed tax on each turn — worth loading on demand
rather than always, if Hermes allows it.

**Then the flags.** `-ub` (micro-batch) is how many tokens the GPU processes
per pass and is the direct prefill lever; `-b` is the logical batch above it.
Upstream defaults are 2048 / 512:

    WORK_AGENT_UBATCH=1024 bash scripts/restart.sh
    WORK_AGENT_UBATCH=2048 bash scripts/restart.sh

Larger micro-batches cost memory, so measure rather than assuming bigger wins.

Order of attack: append-only discipline → per-turn constant size (skills, AX
tree scope) → `-ub`. The first two change how many tokens you prefill; the
flag only changes how fast you prefill them.

## Restarting

`scripts/restart.sh` stops whatever holds the port and relaunches with the env
you pass — the A/B loop:

    bash scripts/restart.sh                      # baseline
    WORK_AGENT_SPEC=off  bash scripts/restart.sh # isolate MTP
    WORK_AGENT_THINK=on  bash scripts/restart.sh # isolate thinking cost
    WORK_AGENT_KV=q8_0   bash scripts/restart.sh # confirm the #8918 penalty

Check the startup banner each time: it prints `kv:`, `spec:` and the image cap,
so you can confirm the variant took rather than trusting what you typed.

SIGTERM is not instant — ~20 GB to unmap and a Metal context to tear down, and
the process may sit in a GPU wait. The script waits 30s, then escalates to
SIGKILL. If `kill <pid>` seemed not to work by hand, that was probably either
this delay or a *second* llama-server: killing one leaves the other, and lsof
still shows a listener.

## Verifying

`setup/03-verify.sh` probes the endpoint, tool-calling, the system-only path
(the check that distinguishes GGUF from MLX), and image input. Trust the
probes over any of the above claims.
