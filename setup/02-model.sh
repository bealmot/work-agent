#!/usr/bin/env bash
# Download (if needed), load, and serve the model via LM Studio.
set -euo pipefail

LMS="$HOME/.lmstudio/bin/lms"
[ -x "$LMS" ] || { echo "ERROR: lms not found — run setup/01-install.sh first" >&2; exit 1; }

# Exact catalog name may drift; override with WORK_AGENT_MODEL.
# Find candidates with: lms get qwen3.6 (interactive search)
MODEL="${WORK_AGENT_MODEL:-qwen/qwen3.6-35b-a3b}"

# GGUF (llama.cpp), NOT MLX. The MLX build of this model loads through
# mlx-vlm, whose prompt pipeline asserts a user message exists to anchor
# images on -- even for zero-image requests. Hermes' system-only internal
# calls have no user message, so they fail with:
#   "Error rendering prompt with jinja template: No user query found in messages"
# llama.cpp splices images per-message instead and handles system-only +
# tool roles fine. Confirmed by bisect 2026-07-20 (bare user OK, system-only
# fails). Vision survives the switch: this model ships an mmproj projector.
QUANT="${WORK_AGENT_QUANT:-Q4_K_M}"

echo "==> Server"
"$LMS" server start || true   # no-op if already running

echo "==> Model download (skips if cached)"
"$LMS" get "$MODEL" --gguf --yes || {
  echo "ERROR: '$MODEL' GGUF not found in catalog. Search with: lms get qwen3.6" >&2
  exit 1
}

# Two formats of the same id on disk make `lms load <id>` ambiguous. If an
# MLX copy is still present, loading may silently pick it and reintroduce
# the jinja bug -- fail loud rather than guess which one got loaded.
if "$LMS" ls 2>/dev/null | grep -iF "$MODEL" | grep -qi mlx; then
  echo "ERROR: an MLX copy of '$MODEL' is still on disk alongside the GGUF." >&2
  echo "       'lms load' cannot disambiguate. Remove the MLX copy first:" >&2
  echo "         lms rm $MODEL   # select the MLX entry" >&2
  exit 1
fi

echo "==> Load with 64k context (Hermes requires >= 64k)"
if "$LMS" ps 2>/dev/null | grep -qiF "$MODEL"; then
  echo "    already loaded"
else
  "$LMS" load "$MODEL" --context-length 65536 --yes
fi

echo "==> Verify endpoint"
curl -sf http://localhost:1234/v1/models | grep -qiF "$MODEL" \
  && echo "OK: model serving on http://localhost:1234/v1" \
  || { echo "ERROR: endpoint up but model not listed" >&2; exit 1; }

cat <<'EOF'

==> Manual check: vision
Computer use needs the model to accept images. llama.cpp only enables image
input when the multimodal projector (mmproj) is loaded alongside the weights.

  LM Studio -> My Models -> this model -> confirm the "Vision" badge.

If the badge is absent, LM Studio did not pair an mmproj. Serve with
standalone llama-server instead:

  llama-server -m <model>.gguf --mmproj <mmproj>.gguf --jinja -c 65536

(--jinja is required either way; without it the Qwen3.6 chat template is not
applied and the model emits malformed turns.)

Then: bash setup/03-verify.sh
EOF
