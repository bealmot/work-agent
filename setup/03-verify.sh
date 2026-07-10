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

check "cliclick installed"        command -v cliclick
check "node installed"            command -v node
check "uv installed"              command -v uv
check "hermes installed"          command -v hermes
check "lms CLI present"           test -x "$HOME/.lmstudio/bin/lms"
check "LM Studio endpoint up"     curl -sf http://localhost:1234/v1/models
check "model loaded"              sh -c 'curl -sf http://localhost:1234/v1/models | grep -qi qwen'
check "playwright mcp cached"     npx -y @playwright/mcp@0.0.32 --version
if curl -sf http://localhost:9222/json/version >/dev/null 2>&1; then
  echo "PASS  chrome CDP up (optional)"; PASS=$((PASS+1))
else
  echo "SKIP  chrome CDP up (optional — run scripts/chrome-debug.sh later)"
fi

echo "==> Tool-call round trip"
RESP=$(curl -sf http://localhost:1234/v1/chat/completions \
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
  echo "FAIL  model emits tool_calls — check the prompt template (see config/lmstudio-settings.md)"
  FAIL=$((FAIL+1))
fi

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
