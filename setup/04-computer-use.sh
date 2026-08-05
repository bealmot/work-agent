#!/usr/bin/env bash
# Install and check Hermes' computer-use tool (OS-level GUI control).
# Run after 03-verify.sh passes. Optional: only needed for Layer 3 sites.
set -euo pipefail

command -v hermes >/dev/null 2>&1 \
  || { echo "ERROR: hermes not found — run setup/01-install.sh first" >&2; exit 1; }

# Computer use drives the SAME model that runs the agent, and it drives it
# with screenshots. If the vision path is broken, the install still succeeds
# and the failure only shows up mid-task as blind clicking -- so gate on it.
echo "==> Checking the vision path (optional)"
# Capture first rather than piping: 03-verify.sh exits nonzero when ANY check
# fails, and under `set -o pipefail` that failure would mask grep's match.
#
# NOT a hard gate. The accessibility tree is the default perception path and
# needs no images at all -- vision only matters for the pixel fallback, which
# should be rare. Blocking install on it would be stricter than the
# architecture requires.
VERIFY_OUT="$(bash "$(dirname "$0")/03-verify.sh" 2>/dev/null || true)"
if printf '%s' "$VERIFY_OUT" | grep -q "FAIL  model accepts image input"; then
  echo "WARNING: the served model rejects image input." >&2
  echo "         The accessibility-tree path still works — this only removes" >&2
  echo "         the pixel fallback (browser-ops Layer 3). Fix the mmproj if" >&2
  echo "         you need it; see setup/02-model.sh." >&2
else
  echo "OK: model accepts images (pixel fallback available)"
fi

echo "==> Install cua-driver"
# Background automation driver. On macOS it uses the AX APIs and SkyLight
# SPIs (SLPSPostEventRecordTo) rather than CGEvent injection, so it clicks
# and types WITHOUT moving your cursor or stealing keyboard focus -- you can
# keep working while the agent operates. It is also the only browser-control
# path that preserves device posture: it drives the real managed Chrome in
# place rather than launching an unmanaged profile.
hermes computer-use install

echo "==> Doctor (permissions + driver + platform matrix)"
# Prints a per-check matrix. Grants attach to the TERMINAL APP running hermes,
# not to hermes itself. Without them input events are silently dropped, with
# no error raised.
#
#   Accessibility     -- required. Every element read and every click.
#   Automation        -- required for the DOM-via-Apple-Events path that
#                        browser-ops Layer 2 depends on (Chrome must be
#                        listed under the terminal app). macOS prompts for
#                        this the first time it is used, not at install.
#   Screen Recording  -- only needed for screenshots. The accessibility tree
#                        works without it, and AX is the default path here,
#                        so this is optional if you never fall to pixels.
hermes computer-use doctor || {
  echo >&2
  echo "Doctor reported problems. Grant permissions at:" >&2
  echo "  System Settings -> Privacy & Security -> Accessibility   (required)" >&2
  echo "  System Settings -> Privacy & Security -> Automation      (required)" >&2
  echo "  System Settings -> Privacy & Security -> Screen Recording (pixels only)" >&2
  echo "Add your terminal app, then FULLY QUIT and reopen it -- macOS only" >&2
  echo "re-reads these grants on process start -- and re-run." >&2
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
