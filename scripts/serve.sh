#!/usr/bin/env bash
# Start llama-server for the agent. Foreground; Ctrl-C to stop.
# Every tuning knob for this stack lives here -- there is no GUI.
set -euo pipefail

command -v llama-server >/dev/null 2>&1 \
  || { echo "ERROR: llama-server not found — run setup/01-install.sh" >&2; exit 1; }

# -hf downloads weights on first run and caches them (LLAMA_CACHE, default
# ~/Library/Caches/llama.cpp). This server runs TEXT ONLY -- the projector is
# explicitly not loaded, see --no-mmproj-auto below.
#
# MTP build: bundles a multi-token-prediction head for self-speculative
# decoding -- ~1.4-2.2x faster generation, no quality loss, no separate draft
# model. Costs ~2.5% more disk and ~2 GB RAM.
MODEL="${WORK_AGENT_MODEL:-unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_M}"
PORT="${WORK_AGENT_PORT:-8080}"
CTX="${WORK_AGENT_CTX:-65536}"

# KV cache type. f16 on purpose -- do NOT set this to q8_0 without measuring.
#
# Quantizing the KV cache looks free (it halves the footprint) and it needs
# flash attention to avoid dequantizing on every attention op, so "-ctk q8_0
# -ctv q8_0 -fa on" reads as a coherent pairing. On Apple Silicon it is not:
# Metal has no optimized quantized-KV flash-attention kernel, and the
# combination measures ~1/3 SLOWER token generation.
#   https://github.com/ggml-org/llama.cpp/issues/8918
#
# Decode here is memory-bandwidth-bound (the M4 Pro has strong GPU compute
# relative to its ~273 GB/s), so anything adding per-token memory traffic hits
# generation hard while barely touching prefill. Roughly 3 GB of KV is a good
# trade for that on a 48 GB machine.
#
# Measure with llama-bench before changing, not from inside the agent loop:
#   WORK_AGENT_KV=q8_0 scripts/serve.sh
KV_TYPE="${WORK_AGENT_KV:-f16}"

# Prompt-processing (prefill) throughput. -b is the logical batch; -ub is the
# physical micro-batch -- how many tokens the GPU actually chews per pass, and
# the direct lever on prefill speed. Upstream defaults are 2048 / 512; kept
# here so raising them is a one-line A/B rather than a rebuild:
#
#   WORK_AGENT_UBATCH=1024 bash scripts/restart.sh
#
# Larger micro-batches cost memory. There is headroom on 48 GB next to ~20 GB
# of weights, but raise it deliberately and measure -- an unmeasured "obvious"
# improvement is how the q8_0 KV regression got in.
BATCH="${WORK_AGENT_BATCH:-2048}"
UBATCH="${WORK_AGENT_UBATCH:-512}"

# Thinking mode. Qwen3.6 has thinking and non-thinking modes in one model; if
# thinking is on, it emits a reasoning block BEFORE every action. In a
# computer-use loop that is hundreds of wasted tokens per step, on the
# bandwidth-bound half of the workload -- easily the largest latency item.
#
# enable_thinking:false alone is not reliably sufficient on Qwen3 in llama.cpp
# (models keep emitting Thinking blocks); --reasoning-budget 0 is what
# actually forces termination, by counting reasoning tokens and appending the
# end sequence. Set both.
#
# TRADE-OFF: thinking may help judgment-heavy work (ticket triage, drafting)
# and hurts nothing but speed there. It is off by default because GUI stepping
# is the latency-sensitive path. WORK_AGENT_THINK=on to restore it.
THINK="${WORK_AGENT_THINK:-off}"

# Where warm KV slots are persisted. Enables POST /slots/{id}?action=save|restore
# so a stable prefix can be prefilled ONCE and restored per session, instead of
# paying ~24k tokens of cold prefill every time. The flag only creates the
# directory contract -- something has to call the endpoints. See
# config/llama-server.md.
SLOTS="${WORK_AGENT_SLOTS:-$HOME/.cache/work-agent-slots}"
mkdir -p "$SLOTS"

ARGS=(
  -hf "$MODEL"
  --port "$PORT"
  -c "$CTX"
  -ngl all                      # unified memory: everything on the GPU
  -fa on                        # helps regardless; the penalty is FA + quantized KV
  -ctk "$KV_TYPE" -ctv "$KV_TYPE"
  -b "$BATCH" -ub "$UBATCH"

  # TEXT ONLY -- do not load a vision projector on this server.
  #
  # llama.cpp #21133: when an mmproj is loaded, has_mtmd is set on every slot
  # as a CAPABILITY flag, not a data flag. The server then treats every
  # conversation as multimodal and disables slot persistence, context shift and
  # cache reuse -- even for text-only requests, which is all of ours.
  # #23371 additionally reports MTP + Vision OOMing during mmproj restore on
  # this model family, and we run MTP.
  #
  # Vision is not lost: it moved to a second server. scripts/serve-vlm.sh runs a
  # small VLM whose only job is describing ticket attachments, called one-shot
  # and out of band so images never enter this model's context or its cache.
  --no-mmproj-auto

  # Now meaningful again, because the mmproj was what disabled it. Reuses the
  # stable system+skills prefix across turns via KV shifting.
  --cache-reuse 256

  --slot-save-path "$SLOTS"
)

# Self-speculative decoding. Opt out with WORK_AGENT_SPEC=off if you switch to
# a non-MTP model -- draft-mtp on weights with no MTP head will fail to load.
[ "${WORK_AGENT_SPEC:-on}" = "on" ] && ARGS+=(--spec-type draft-mtp)

if [ "$THINK" = "off" ]; then
  ARGS+=(--reasoning-budget 0
         --chat-template-kwargs '{"enable_thinking": false}')
fi

# --keep stays out: it is read only inside the context-shift branch, and
# --context-shift is left at its default (disabled) deliberately. Failing
# loudly at the limit beats silently discarding the start of a conversation.
#
# --cache-reuse is back as of 2026-08-06. It was removed on the 5th as "dead",
# which was true but for the wrong reason: the mmproj was disabling it, and we
# were treating the mmproj as fixed. It is not -- see --no-mmproj-auto above.

echo "==> llama-server on :$PORT"
echo "    model: $MODEL"
echo "    ctx: $CTX  kv: $KV_TYPE  batch: $BATCH/$UBATCH  spec: ${WORK_AGENT_SPEC:-on}  think: $THINK"
echo "    text-only (no mmproj) -- vision lives on scripts/serve-vlm.sh"
echo "    slots: $SLOTS"
echo "    Watch the startup log for: all layers offloaded to GPU, and (if spec"
echo "    is on) a draft acceptance rate once generation starts. No acceptance"
echo "    stats at all means draft-mtp never engaged."
echo
exec llama-server "${ARGS[@]}"
