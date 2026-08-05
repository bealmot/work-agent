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

# Hard gate: if nothing answers, stop here. Every check below talks to this
# endpoint, so a dead socket produces a wall of failures each blaming the
# model -- broken chat template, mlx-vlm, missing mmproj -- when the real
# cause is that no server is running. Diagnose the socket before the model.
#
# Note curl -s prints NOTHING on connection refused (exit 7), which is why
# this reads as "no output" rather than as an error.
if ! curl -s -o /dev/null "$API/health" 2>/dev/null; then
  echo "ERROR: nothing is listening at $API" >&2
  echo >&2
  echo "setup/02-model.sh only PRE-DOWNLOADS the weights — it stops the" >&2
  echo "server again when it finishes. Start the real one and leave it up:" >&2
  echo >&2
  echo "  terminal 1:  bash scripts/serve.sh" >&2
  echo "  terminal 2:  bash setup/03-verify.sh" >&2
  echo >&2
  echo "If serve.sh IS running, confirm it is on the same port this script" >&2
  echo "is checking (${WORK_AGENT_PORT:-8080}) — both read WORK_AGENT_PORT." >&2
  exit 1
fi

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

# The model id the server actually advertises. An earlier version of this
# script hardcoded "any" in every probe on the assumption llama-server ignores
# the field. If it ever validates it, ALL probes fail identically and each one
# reports its own guessed cause -- three misleading diagnoses from one upstream
# problem. Ask the server instead of assuming.
MODEL_ID=$(curl -s "$API/v1/models" 2>/dev/null \
  | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$MODEL_ID" ] || MODEL_ID="any"
echo "==> Using model id: $MODEL_ID"

# probe <label> <expect-substring> <json-body> [hint...]
#
# Reports what the server ACTUALLY said on failure. The earlier version used
# `curl -sf`, which discards the response body on an HTTP error -- making a
# 400 from the server indistinguishable from a model that simply didn't
# comply. Hints below are possibilities to check, NOT diagnoses: read the
# server's own message first.
probe() {
  local label="$1" expect="$2" body="$3"; shift 3
  local out code
  out=$(curl -s -w $'\n%{http_code}' "$API/v1/chat/completions" \
        -H "Content-Type: application/json" -d "$body" 2>/dev/null)
  code=$(printf '%s' "$out" | tail -n1)
  out=$(printf '%s' "$out" | sed '$d')
  if printf '%s' "$out" | grep -q "$expect"; then
    echo "PASS  $label"; PASS=$((PASS+1)); return 0
  fi
  echo "FAIL  $label  (HTTP ${code:-none})"
  if [ -z "$out" ]; then
    echo "      empty response — nothing answered at $API"
  else
    echo "      server said: $(printf '%s' "$out" | tr -d '\n' | head -c 300)"
  fi
  local h; for h in "$@"; do echo "      $h"; done
  FAIL=$((FAIL+1)); return 1
}

echo "==> Tool-call round trip"
probe "model emits tool_calls" '"tool_calls"' "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What time is it? Use the tool.\"}],
    \"tools\": [{\"type\": \"function\", \"function\": {\"name\": \"get_time\",
      \"description\": \"Get the current time\",
      \"parameters\": {\"type\": \"object\", \"properties\": {}}}}]
  }" \
  "possible: GGUF carries a broken embedded chat template (--jinja is on by" \
  "default); override with --chat-template-file. See config/llama-server.md."

# A bare user message passes even on the broken MLX/mlx-vlm path. The real
# failure mode is a SYSTEM-ONLY request: mlx-vlm scans for a user message to
# anchor images on and rejects when there is none, which is how Hermes makes
# some internal calls. Kept as a regression guard now that we serve GGUF.
echo "==> System-only prompt (B-probe)"
probe "system-only prompt renders" '"content"' "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [{\"role\": \"system\", \"content\": \"Reply with the single word: ok\"}],
    \"max_tokens\": 8
  }" \
  "possible: something other than llama-server is answering on this port —" \
  "under llama.cpp the mlx-vlm jinja bug cannot occur. Check with: lsof -i"

# Computer use sends screenshots to this model. A 1x1 transparent PNG is
# enough to prove the multimodal path accepts image parts at all.
echo "==> Vision path (required for computer use)"
PNG="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
probe "model accepts image input" '"content"' "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [{\"role\": \"user\", \"content\": [
      {\"type\": \"text\", \"text\": \"Reply with the single word: ok\"},
      {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,$PNG\"}}
    ]}],
    \"max_tokens\": 8
  }" \
  "possible: no mmproj projector loaded — the -hf repo may publish none." \
  "Fall back to the non-MTP repo, or point -mm at one explicitly." \
  "Without this, computer use degrades to accessibility-tree-only (mode=ax)."

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
