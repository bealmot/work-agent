#!/usr/bin/env bash
# Install and check Hermes' computer-use tool (OS-level GUI control).
# Run after 03-verify.sh passes. Optional: only needed for Layer 3 sites.
set -euo pipefail

command -v hermes >/dev/null 2>&1 \
  || { echo "ERROR: hermes not found — run setup/01-install.sh first" >&2; exit 1; }

# Computer use drives the SAME model that runs the agent, and it drives it
# with screenshots. If the vision path is broken, the install still succeeds
# and the failure only shows up mid-task as blind clicking -- so gate on it.
echo "==> Precondition: vision path"
# Capture first rather than piping: 03-verify.sh exits nonzero when ANY check
# fails, and under `set -o pipefail` that failure would mask grep's match --
# silently skipping the very error this gate exists to catch.
VERIFY_OUT="$(bash "$(dirname "$0")/03-verify.sh" 2>/dev/null || true)"
if printf '%s' "$VERIFY_OUT" | grep -q "FAIL  model accepts image input"; then
  echo "ERROR: the served model rejects image input." >&2
  echo "       Computer use would fall back to accessibility-tree-only." >&2
  echo "       Fix the mmproj first (see setup/02-model.sh), or proceed" >&2
  echo "       deliberately with mode=ax per skills/screen-ops/SKILL.md." >&2
  exit 1
fi
echo "OK: model accepts images"

echo "==> Install cua-driver"
# Background automation driver. On macOS it uses the AX APIs and SkyLight
# SPIs (SLPSPostEventRecordTo) rather than CGEvent injection, so it clicks
# and types WITHOUT moving your cursor or stealing keyboard focus -- you can
# keep working while the agent operates. This is the main advantage over
# scripts/osclick.py (cliclick), which drives the real cursor.
hermes computer-use install

echo "==> Doctor (permissions + driver + platform matrix)"
# Prints a per-check matrix. Accessibility AND Screen Recording must both be
# granted to the TERMINAL APP running hermes, not to hermes itself. Without
# them, input events are silently dropped -- no error is raised.
hermes computer-use doctor || {
  echo >&2
  echo "Doctor reported problems. Grant permissions at:" >&2
  echo "  System Settings -> Privacy & Security -> Accessibility" >&2
  echo "  System Settings -> Privacy & Security -> Screen Recording" >&2
  echo "Add your terminal app to BOTH, then fully quit and reopen it" >&2
  echo "(macOS only re-reads these grants on process start), and re-run." >&2
  exit 1
}

cat <<'EOF'

OK: computer use ready.

Start a session with the tool enabled:

  hermes -t computer_use chat

Or enable it permanently -- config/cli-config.yaml already lists it under
`tools:`; copy that file to ~/.hermes/cli-config.yaml.

Telemetry is disabled by default (computer_use.cua_telemetry: false).
Nothing in this path makes network calls; the driver is local.

Read skills/screen-ops/SKILL.md before pointing this at a real work tool.
EOF
