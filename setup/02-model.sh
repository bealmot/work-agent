#!/usr/bin/env bash
# Download (if needed), load, and serve the model via LM Studio.
set -euo pipefail

LMS="$HOME/.lmstudio/bin/lms"
[ -x "$LMS" ] || { echo "ERROR: lms not found — run setup/01-install.sh first" >&2; exit 1; }

# Exact catalog name may drift; override with WORK_AGENT_MODEL.
# Find candidates with: lms get qwen3.6 (interactive search)
MODEL="${WORK_AGENT_MODEL:-qwen3.6-35b-a3b-mlx}"

echo "==> Server"
"$LMS" server start || true   # no-op if already running

echo "==> Model download (skips if cached)"
"$LMS" get "$MODEL" --yes || {
  echo "ERROR: '$MODEL' not found in catalog. Search with: lms get qwen3.6" >&2
  exit 1
}

echo "==> Load with 32k context"
if "$LMS" ps 2>/dev/null | grep -qi "$MODEL"; then
  echo "    already loaded"
else
  "$LMS" load "$MODEL" --context-length 32768 --yes
fi

echo "==> Verify endpoint"
curl -sf http://localhost:1234/v1/models | grep -qi "qwen" \
  && echo "OK: model serving on http://localhost:1234/v1" \
  || { echo "ERROR: endpoint up but model not listed" >&2; exit 1; }
