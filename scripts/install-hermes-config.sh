#!/usr/bin/env bash
# Render config/cli-config.yaml into ~/.hermes/cli-config.yaml, substituting
# absolute paths. Idempotent; backs up any existing config first.
#
# This exists because MCP server args get no tilde expansion and no variable
# expansion -- the Playwright profile path has to be a literal absolute path
# containing your username. Hand-editing that on a machine with no clipboard
# is how typos get in, so it is generated.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/config/cli-config.yaml"
DEST_DIR="$HOME/.hermes"
DEST="$DEST_DIR/cli-config.yaml"
PROFILE="$HOME/.work-agent-profile"

[ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

mkdir -p "$DEST_DIR"

if [ -f "$DEST" ]; then
  # Never silently clobber: a Hermes config may hold hand-tuned settings, and
  # on this machine it is not reconstructible from anywhere else.
  BACKUP="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$DEST" "$BACKUP"
  echo "==> Existing config backed up to $BACKUP"
  echo "    Merge anything you had customised — this writes a fresh file."
fi

sed "s|__HOME__|$HOME|g" "$SRC" > "$DEST"

if grep -q "__HOME__" "$DEST"; then
  echo "ERROR: placeholder substitution failed — $DEST still contains __HOME__" >&2
  exit 1
fi

mkdir -p "$PROFILE"

echo "==> Wrote $DEST"
echo "    Playwright profile: $PROFILE"
echo
echo "The profile starts empty. Hermes will launch the installed Chrome"
echo "against it; log into your work tools once and the session persists."
