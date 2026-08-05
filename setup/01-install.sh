#!/usr/bin/env bash
# work-agent installer — idempotent; safe to re-run.
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

have brew || { echo "ERROR: install Homebrew first: https://brew.sh" >&2; exit 1; }

echo "==> Packages"
for pkg in llama.cpp cliclick node uv; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

echo "==> llama-server sanity"
have llama-server || { echo "ERROR: llama-server not on PATH after install" >&2; exit 1; }
# Metal is what makes this viable on the M4. A CPU-only build will run, but
# the vision projector alone can take minutes per screenshot -- which reads
# as "the agent is hung" rather than as a build problem.
if llama-server --version 2>&1 | grep -qi metal; then
  echo "    Metal backend present"
else
  echo "    WARNING: no Metal backend detected in llama-server --version." >&2
  echo "    Expect very slow image prefill. Reinstall with: brew reinstall llama.cpp" >&2
fi

echo "==> Hermes CLI"
if have hermes; then
  echo "    hermes present"
else
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
fi

echo "==> Playwright MCP (prime the npx cache)"
npx -y @playwright/mcp@0.0.32 --version

echo "==> Done. Next: setup/02-model.sh"
