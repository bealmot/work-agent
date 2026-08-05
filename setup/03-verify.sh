#!/usr/bin/env bash
# Post-setup verification. Run after 01-install.sh and 02-model.sh.
set -uo pipefail  # no -e: run all checks, report at the end

PASS=0; FAIL=0
check() {  # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $label"; PASS=$((PASS+1))
  else
    echo "FAIL  $label"; FAIL=$((FAIL+1))
  fi
}

API="http://localhost:${WORK_AGENT_PORT:-8080}"

check "cliclick installed"        command -v cliclick
check "node installed"            command -v node
check "uv installed"              command -v uv
check "hermes installed"          command -v hermes
check "llama-server installed"    command -v llama-server
check "metal backend"             sh -c 'llama-server --version 2>&1 | grep -qi metal'
check "llama-server up"           curl -sf "$API/health"
check "model listed"              curl -sf "$API/v1/models"
check "playwright mcp cached"     npx -y @playwright/mcp@0.0.32 --version
if curl -sf http://localhost:9222/json/version >/dev/null 2>&1; then
  echo "PASS  chrome CDP up (optional)"; PASS=$((PASS+1))
else
  echo "SKIP  chrome CDP up (optional — run scripts/chrome-debug.sh later)"
fi

echo "==> Tool-call round trip"
RESP=$(curl -sf "$API/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "any",
    "messages": [{"role": "user", "content": "What time is it? Use the tool."}],
    "tools": [{"type": "function", "function": {"name": "get_time",
      "description": "Get the current time",
      "parameters": {"type": "object", "properties": {}}}}]
  }' 2>/dev/null)
if echo "$RESP" | grep -q '"tool_calls"'; then
  echo "PASS  model emits tool_calls"; PASS=$((PASS+1))
else
  echo "FAIL  model emits tool_calls — llama-server enables --jinja by default;"
  echo "      if this fails the GGUF may carry a broken embedded chat template."
  echo "      Override with --chat-template-file (see config/llama-server.md)."
  FAIL=$((FAIL+1))
fi

# The round trip above sends a bare user message, which passes even on the
# broken MLX/mlx-vlm path. The actual failure mode is a SYSTEM-ONLY request:
# mlx-vlm scans for a user message to anchor images on and rejects when there
# is none, which is how Hermes makes some of its internal calls. This is the
# bisect's B-probe -- it is the check that distinguishes GGUF from MLX.
echo "==> System-only prompt (B-probe: fails on mlx-vlm, passes on llama.cpp)"
BRESP=$(curl -sf "$API/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "any",
    "messages": [{"role": "system", "content": "Reply with the single word: ok"}],
    "max_tokens": 8
  }' 2>/dev/null)
if echo "$BRESP" | grep -q '"content"'; then
  echo "PASS  system-only prompt renders"; PASS=$((PASS+1))
else
  echo "FAIL  system-only prompt — mlx-vlm jinja bug ('No user query found in messages')."
  echo "      You are on the MLX build. Re-run setup/02-model.sh to get GGUF."
  FAIL=$((FAIL+1))
fi

# Computer use sends screenshots to this model. A 1x1 transparent PNG is
# enough to prove the multimodal path accepts image parts at all.
echo "==> Vision path (required for computer use)"
PNG="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
VRESP=$(curl -sf "$API/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"any\",
    \"messages\": [{\"role\": \"user\", \"content\": [
      {\"type\": \"text\", \"text\": \"Reply with the single word: ok\"},
      {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,$PNG\"}}
    ]}],
    \"max_tokens\": 8
  }" 2>/dev/null)
if echo "$VRESP" | grep -q '"content"'; then
  echo "PASS  model accepts image input"; PASS=$((PASS+1))
else
  echo "FAIL  model rejects image input — no mmproj projector loaded."
  echo "      The -hf repo in scripts/serve.sh publishes no projector, or"
  echo "      --mmproj-auto did not find one. Either point -mm at a projector"
  echo "      explicitly, or fall back to the non-MTP repo which is known to"
  echo "      ship one (see scripts/serve.sh). Without this, computer use"
  echo "      degrades to accessibility-tree-only (mode=ax)."
  FAIL=$((FAIL+1))
fi

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
