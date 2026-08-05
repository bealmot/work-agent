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

PORT="${WORK_AGENT_PORT:-8080}"

# Refuse to start if something already holds the port. Without this the health
# poll below answers against the FOREIGN server and reports success while our
# llama-server is dead -- the exact silent-wrong-server failure this repo
# exists to avoid. A stale qwen36-run.sh is the usual culprit.
#
# lsof, not bash's /dev/tcp. An earlier version used /dev/tcp because it needs
# no external binary and sees listeners owned by other users. But probing a
# port blocks forever against a listener that has stopped accepting: the
# backlog fills and connect() has no timeout, and macOS ships no `timeout`
# binary to bound it. A wedged server is exactly what you would be trying to
# diagnose here, so the check must not be able to hang on it.
#
# lsof's blind spot -- other users' processes, without sudo -- is covered
# downstream rather than here: if it misses a listener, serve.sh simply fails
# to bind, and the liveness check below catches the early exit and reports it.
# A loud late failure beats a hang.
if command -v lsof >/dev/null 2>&1 \
   && [ -n "$(lsof -ti ":$PORT" -sTCP:LISTEN 2>/dev/null)" ]; then
  echo "ERROR: something is already listening on port $PORT:" >&2
  lsof -i ":$PORT" -sTCP:LISTEN >&2
  echo >&2
  echo "Stop it so there is ONE launch path:" >&2
  echo "  bash scripts/restart.sh      # stops the holder, then serves" >&2
  echo "or pick another port:" >&2
  echo "  WORK_AGENT_PORT=8081 bash setup/02-model.sh" >&2
  exit 1
fi

# Start the server briefly to force the download, then stop it. --dry-run
# isn't a thing; a health poll is the portable way to know it's ready.
"$(dirname "$0")/../scripts/serve.sh" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

echo "==> Waiting for the server to come up (downloads can take a while)"
for _ in $(seq 1 600); do
  # Liveness BEFORE the health probe: if our process died, a green /health can
  # only be coming from something else.
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: llama-server exited during startup. Scroll up for its output." >&2
    echo "       Common causes: port taken (see above), or --spec-type" >&2
    echo "       draft-mtp against weights with no MTP head — retry with" >&2
    echo "       WORK_AGENT_SPEC=off." >&2
    exit 1
  fi
  if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo "OK: weights are cached and the model loads cleanly."
    echo
    echo "  ** This script now STOPS the server again — it only pre-fetches. **"
    echo "  ** Nothing is serving after this exits. Start it yourself:       **"
    echo
    echo "      terminal 1:  bash scripts/serve.sh      (leave it running)"
    echo "      terminal 2:  bash setup/03-verify.sh"
    exit 0
  fi
  sleep 1
done

echo "ERROR: server did not become healthy within 10 minutes." >&2
exit 1
