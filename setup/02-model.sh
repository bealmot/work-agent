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
# The test is bash's /dev/tcp rather than lsof, for two reasons: it needs no
# external binary (so the guard cannot silently pass because a tool is
# missing), and it sees listeners owned by OTHER users, which lsof without
# sudo does not. lsof is used only to attribute the port, never to decide.
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  echo "ERROR: something is already listening on port $PORT." >&2
  if command -v lsof >/dev/null 2>&1; then
    lsof -i ":$PORT" -sTCP:LISTEN >&2 2>/dev/null \
      || echo "       lsof cannot see it — likely another user's process." >&2
    echo "       If nothing is listed above, try: sudo lsof -i :$PORT" >&2
  else
    echo "       (lsof unavailable — cannot identify the process)" >&2
  fi
  echo >&2
  echo "Stop it so there is ONE launch path, or pick another port:" >&2
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
    echo "OK: model loaded and serving on http://localhost:$PORT"
    echo
    echo "Next: leave scripts/serve.sh running in its own terminal, then"
    echo "      bash setup/03-verify.sh"
    exit 0
  fi
  sleep 1
done

echo "ERROR: server did not become healthy within 10 minutes." >&2
exit 1
