#!/usr/bin/env bash
# Start the vision model. Foreground; Ctrl-C to stop. Second server, second port.
#
# Its ONLY job is describing images from ticket attachments. The agent never
# talks to it directly and images never enter the agent's context: something
# calls scripts/describe-image.sh, which returns a few hundred tokens of text.
#
# Why a separate server rather than one multimodal model:
#   llama.cpp #21133 -- loading an mmproj sets has_mtmd on every slot as a
#   CAPABILITY flag, not a data flag, so the server disables slot persistence,
#   context shift AND cache reuse for text-only conversations too. On the agent
#   server that is fatal: it is what turns a long session into the compaction
#   death spiral (config/llama-server.md).
#   #23371 also reports MTP + Vision OOMing during mmproj restore on this model
#   family, and the agent server runs MTP.
#
# Quarantining vision here keeps the agent server text-only and fully cached,
# while losing no capability. Memory: ~5 GB at Q4 for an 8B-class VLM, next to
# ~20 GB for the agent model, on 48 GB.
set -euo pipefail

command -v llama-server >/dev/null 2>&1 \
  || { echo "ERROR: llama-server not found — run setup/01-install.sh" >&2; exit 1; }

# An 8B-class vision model is ample for "read the error in this screenshot".
# If this repo id does not resolve, search for a current Qwen3-VL GGUF that
# ships an mmproj and set WORK_AGENT_VLM to it. The requirement is only that
# the repo publishes a projector -- without one this server is pointless.
VLM="${WORK_AGENT_VLM:-unsloth/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M}"
VLM_PORT="${WORK_AGENT_VLM_PORT:-8081}"

# Small context on purpose. Every call is one-shot: one image, one question, one
# answer. Nothing accumulates, so there is no reason to reserve KV for it.
VLM_CTX="${WORK_AGENT_VLM_CTX:-8192}"

# Bounds what one image costs. Qwen3-VL uses dynamic resolution, so this is a
# real dial: lower it until text in a screenshot stops being legible. It bounds
# THIS server's work, not the agent's context -- the agent only ever sees the
# resulting description.
VLM_IMG_MAX="${WORK_AGENT_VLM_IMG_MAX:-1536}"

echo "==> vision model on :$VLM_PORT"
echo "    model: $VLM"
echo "    ctx: $VLM_CTX  image-max-tokens: $VLM_IMG_MAX"
echo "    mmproj REQUIRED here (unlike scripts/serve.sh, which forbids it)."
echo "    If the startup log shows no projector, this server cannot see and"
echo "    describe-image.sh will return text-only guesses. Pick another repo."
echo

exec llama-server \
  -hf "$VLM" \
  --port "$VLM_PORT" \
  -c "$VLM_CTX" \
  -ngl all \
  -fa on \
  --image-max-tokens "$VLM_IMG_MAX" \
  --mmproj-auto
