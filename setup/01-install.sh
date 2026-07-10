#!/usr/bin/env bash
# work-agent installer — idempotent; safe to re-run.
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

have brew || { echo "ERROR: install Homebrew first: https://brew.sh" >&2; exit 1; }

echo "==> Casks and packages"
brew list --cask lm-studio >/dev/null 2>&1 || brew install --cask lm-studio
for pkg in cliclick node uv; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

echo "==> lms CLI (LM Studio's command-line interface)"
if [ -x "$HOME/.lmstudio/bin/lms" ]; then
  echo "    lms present"
else
  echo "    ACTION REQUIRED: open LM Studio once (creates ~/.lmstudio),"
  echo "    then run: ~/.lmstudio/bin/lms bootstrap"
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
