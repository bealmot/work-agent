#!/usr/bin/env bash
# Launch Chrome with CDP enabled on the user's real profile.
# Playwright MCP attaches to this via --cdp-endpoint http://localhost:9222.
set -euo pipefail

PORT="${CDP_PORT:-9222}"

if curl -sf "http://localhost:${PORT}/json/version" >/dev/null; then
  echo "OK: Chrome already listening on :${PORT}"
  exit 0
fi

if pgrep -xq "Google Chrome"; then
  echo "ERROR: Chrome is running without a debug port." >&2
  echo "Quit Chrome fully (Cmd+Q), then re-run this script." >&2
  exit 1
fi

open -a "Google Chrome" --args --remote-debugging-port="${PORT}"

for _ in $(seq 1 20); do
  if curl -sf "http://localhost:${PORT}/json/version" >/dev/null; then
    echo "OK: Chrome launched with CDP on :${PORT}"
    exit 0
  fi
  sleep 0.5
done
echo "ERROR: Chrome started but CDP port never came up (Chrome 136+ refuses --remote-debugging-port on the default user-data-dir as a security change; corporate policy may also strip the flag)." >&2
echo "Fallback: use a dedicated persistent Playwright profile — see docs/runbook.md." >&2
exit 1
