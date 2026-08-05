#!/usr/bin/env bash
# Start llama-server for the agent. Foreground; Ctrl-C to stop.
# Every tuning knob for this stack lives here -- there is no GUI.
set -euo pipefail

command -v llama-server >/dev/null 2>&1 \
  || { echo "ERROR: llama-server not found — run setup/01-install.sh" >&2; exit 1; }

# -hf downloads weights on first run and caches them (LLAMA_CACHE, default
# ~/Library/Caches/llama.cpp). The mmproj projector is fetched automatically
# from the same repo when one is published (--mmproj-auto, on by default).
#
# MTP build: bundles a multi-token-prediction head for self-speculative
# decoding -- ~1.4-2.2x faster generation, no quality loss, no separate draft
# model. Costs ~2.5% more disk and ~2 GB RAM.
#
# If this repo turns out NOT to ship an mmproj, vision breaks and computer use
# degrades to accessibility-tree-only. setup/03-verify.sh probes for exactly
# that. Fall back to the non-MTP repo (trading speed for vision) with:
#   WORK_AGENT_MODEL=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M scripts/serve.sh
MODEL="${WORK_AGENT_MODEL:-unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_M}"
PORT="${WORK_AGENT_PORT:-8080}"
CTX="${WORK_AGENT_CTX:-65536}"

# Vision prefill is the bottleneck in computer-use loops, not decode: this
# model activates ~3B params per token, so it generates fast but spends real
# time *reading* each screenshot. Qwen3.6-VL uses dynamic resolution, so this
# cap is a genuine dial. Lower it until SOM element numbers stop being legible
# -- a full Retina capture is mostly wasted pixels for reading numbered marks.
IMG_MAX_TOKENS="${WORK_AGENT_IMG_MAX_TOKENS:-1024}"

ARGS=(
  -hf "$MODEL"
  --port "$PORT"
  -c "$CTX"
  -ngl all                      # unified memory: everything on the GPU
  -fa on                        # required for quantized KV below
  -ctk q8_0 -ctv q8_0           # halves KV footprint; agent loops fill 64k fast
  --image-max-tokens "$IMG_MAX_TOKENS"
  --cache-reuse 256             # reuse the stable system+skills prefix each turn
  --keep -1                     # pin the initial prompt; see note below
)

# Self-speculative decoding. Opt out with WORK_AGENT_SPEC=off if you switch to
# a non-MTP model -- draft-mtp on weights with no MTP head will fail to load.
[ "${WORK_AGENT_SPEC:-on}" = "on" ] && ARGS+=(--spec-type draft-mtp)

# --context-shift is left at its default (disabled) on purpose. Shifting a
# context that contains a rolling window of screenshots silently discards
# images mid-task; failing loudly at the limit is the better trade here.
#
# --keep -1 matters more than it looks: llama.cpp #23030 (open, closed as
# not-planned) drops the prompt cache on truncation for this model family.
# Pinning the prefix is a partial mitigation, not a fix -- the real lever is
# keeping images small enough that you don't approach the limit.

echo "==> llama-server on :$PORT"
echo "    model: $MODEL"
echo "    ctx: $CTX  image-max-tokens: $IMG_MAX_TOKENS  spec: ${WORK_AGENT_SPEC:-on}"
echo
exec llama-server "${ARGS[@]}"
