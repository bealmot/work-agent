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

echo "==> Permissions"
# Grant through cua-driver, NOT by adding your terminal in System Settings.
# `permissions grant` launches CuaDriver via LaunchServices so the dialogs
# attribute to the app itself, requests Accessibility + Screen Recording (and
# Tahoe's direct-capture consent), then verifies live capture. The read-only
# `permissions status` never triggers that probe, so it cannot be used to set
# things up -- and with no daemon running it reports "unknown" rather than
# your terminal's grants.
#
# Which app the grants attach to depends on who owns the runtime: `mcp
# --direct` deliberately attributes TCC to the invoking host instead. If
# permissions look granted but actions are silently dropped, that mismatch is
# the first thing to check.
if command -v cua-driver >/dev/null 2>&1; then
  cua-driver permissions grant || {
    echo "WARNING: permissions grant did not complete cleanly." >&2
    echo "         Re-run it directly: cua-driver permissions grant" >&2
  }
else
  echo "WARNING: cua-driver not on PATH; skipping permissions grant." >&2
fi

echo "==> Vendor skill pack"
# Version-matched, vendor-authored guidance for the driver's own tool surface.
# Prefer it over hand-written descriptions of the tool API -- the API moves,
# and skills/browser-ops/SKILL.md deliberately no longer tries to document it.
if command -v cua-driver >/dev/null 2>&1; then
  cua-driver skills install || echo "    (skill pack install skipped)"
  PACK="$(cua-driver skills path 2>/dev/null || true)"
  if [ -n "$PACK" ]; then
    echo
    echo "    Skill pack: $PACK"
    echo "    Hermes is NOT in the driver's auto-detect list (Claude Code,"
    echo "    Codex, OpenClaw, OpenCode), so add that path to the"
    echo "    skills.external_dirs list in ~/.hermes/cli-config.yaml."
  fi
fi

echo "==> Doctor (permissions + driver + platform matrix)"
hermes computer-use doctor || {
  echo >&2
  echo "Doctor reported problems. Try, in order:" >&2
  echo "  cua-driver permissions grant     # the correct grant path" >&2
  echo "  cua-driver doctor                # driver's own diagnostics" >&2
  echo "After granting, FULLY QUIT and reopen the terminal -- macOS only" >&2
  echo "re-reads grants on process start -- and re-run." >&2
  exit 1
}

cat <<'EOF'

==> Browser attachment (required before the browser tools work)
Attaching to a browser is gated behind an explicit approval. Use the
EXISTING-PROFILE strategy -- the isolated_new / isolated_named modes spawn an
unmanaged profile, which fails device posture on corporate tools:

  cua-driver browser-approve --strategy existing_profile --pid <chrome-pid> \
             --window-id <id> --session <session>

To pre-authorize it for the daemon's lifetime instead of per-request, start
the daemon with:

  cua-driver serve --grant existing-profile

Find the pid/window id with: cua-driver call list_windows

OK: computer use ready.

Start a session with the tool enabled:

  hermes -t computer_use chat

Or enable it permanently -- config/cli-config.yaml already lists it under
`tools:`; copy that file to ~/.hermes/cli-config.yaml.

Telemetry is disabled by default (computer_use.cua_telemetry: false).
Nothing in this path makes network calls; the driver is local.

Read skills/screen-ops/SKILL.md before pointing this at a real work tool.
EOF
