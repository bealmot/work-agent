#!/usr/bin/env bash
# Pre-download the model so the first agent run isn't a silent 20 GB stall,
# then hand off to scripts/serve.sh. Idempotent: cached weights are reused.
set -euo pipefail

command -v llama-server >/dev/null 2>&1 \
  || { echo "ERROR: llama-server not found — run setup/01-install.sh first" >&2; exit 1; }

MODEL="${WORK_AGENT_MODEL:-unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_M}"

# GGUF/llama.cpp, NOT MLX. The MLX build of this model loads through mlx-vlm,
# whose prompt pipeline asserts a user message exists to anchor images on --
# even for requests carrying no images. Hermes makes some internal calls with
# a system message only, so they fail with:
#   "Error rendering prompt with jinja template: No user query found in messages"
# llama.cpp splices images per-message and handles system-only and tool roles
# fine. Confirmed by bisect 2026-07-20 (bare user OK, system-only fails).
# Under llama.cpp this is enforced by which file you download; there is no
# runtime to pick the wrong one for you.

echo "==> Fetching weights (cached after the first run)"
echo "    $MODEL"
echo "    Cache: ${LLAMA_CACHE:-~/Library/Caches/llama.cpp}"
echo "    ~20 GB on first run. The mmproj projector is fetched automatically"
echo "    from the same repo when one is published."
echo

# Start the server briefly to force the download, then stop it. --dry-run
# isn't a thing; a health poll is the portable way to know it's ready.
"$(dirname "$0")/../scripts/serve.sh" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

PORT="${WORK_AGENT_PORT:-8080}"
echo "==> Waiting for the server to come up (downloads can take a while)"
for _ in $(seq 1 600); do
  if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo "OK: model loaded and serving on http://localhost:$PORT"
    echo
    echo "Next: leave scripts/serve.sh running in its own terminal, then"
    echo "      bash setup/03-verify.sh"
    exit 0
  fi
  # Surface an early crash instead of polling for ten minutes against nothing.
  kill -0 "$SERVER_PID" 2>/dev/null || {
    echo "ERROR: llama-server exited during startup. Scroll up for its output." >&2
    echo "       If it failed on --spec-type draft-mtp, the model has no MTP" >&2
    echo "       head: re-run with WORK_AGENT_SPEC=off." >&2
    exit 1
  }
  sleep 1
done

echo "ERROR: server did not become healthy within 10 minutes." >&2
exit 1
